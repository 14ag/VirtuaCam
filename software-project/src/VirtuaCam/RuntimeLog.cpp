#include "pch.h"
#include "RuntimeLog.h"
#include "Tools.h"

#include <cstdio>
#include <filesystem>
#include <mutex>
#include <cwctype>

namespace
{
    std::mutex g_logMutex;
    HANDLE g_logFile = INVALID_HANDLE_VALUE;
    std::wstring g_logPath;
    bool g_initialized = false;

    std::wstring GetEnvW(PCWSTR name)
    {
        DWORD needed = GetEnvironmentVariableW(name, nullptr, 0);
        if (needed == 0)
            return {};
        std::wstring value;
        value.resize(needed);
        DWORD written = GetEnvironmentVariableW(name, value.data(), needed);
        if (written == 0)
            return {};
        if (!value.empty() && value.back() == L'\0')
            value.pop_back();
        return value;
    }

    std::wstring FormatTimestamp()
    {
        SYSTEMTIME st{};
        GetLocalTime(&st);
        return std::format(L"{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    }

    std::wstring FormatWin32Message(DWORD error)
    {
        wchar_t* buffer = nullptr;
        DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS;
        DWORD langId = MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT);
        DWORD len = FormatMessageW(flags, nullptr, error, langId, reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
        if (!len || !buffer)
            return std::format(L"Win32 error {} (0x{:08X})", error, error);

        std::wstring msg(buffer, len);
        LocalFree(buffer);
        while (!msg.empty() && (msg.back() == L'\r' || msg.back() == L'\n'))
            msg.pop_back();
        return std::format(L"Win32 error {} (0x{:08X}): {}", error, error, msg);
    }

    bool EnsureConsole(bool attachConsole, bool allocConsoleIfMissing)
    {
        if (!attachConsole)
            return false;

        if (GetConsoleWindow() != nullptr)
            return true;

        if (AttachConsole(ATTACH_PARENT_PROCESS) != FALSE)
            return true;

        DWORD err = GetLastError();
        if (err == ERROR_ACCESS_DENIED)
            return true;

        if (!allocConsoleIfMissing)
            return false;

        if (AllocConsole() == FALSE)
            return false;

        FILE* dummy = nullptr;
        _wfreopen_s(&dummy, L"CONOUT$", L"w", stdout);
        _wfreopen_s(&dummy, L"CONOUT$", L"w", stderr);
        SetConsoleOutputCP(CP_UTF8);
        return true;
    }

    std::filesystem::path GetExePathFs()
    {
        std::wstring path = VirtuaCamLog::GetExePath();
        return std::filesystem::path(path);
    }

    std::filesystem::path GetLogDirFs()
    {
        auto exeDir = GetExePathFs().parent_path();
        std::error_code ec;
        auto preferred = exeDir / L"logs";
        std::filesystem::create_directories(preferred, ec);
        return preferred;
    }

    void WriteLineLocked(const std::wstring& line)
    {
        if (g_logFile != INVALID_HANDLE_VALUE)
        {
            std::wstring withNewline = line + L"\r\n";
            DWORD written = 0;
            WriteFile(g_logFile, withNewline.data(), static_cast<DWORD>(withNewline.size() * sizeof(wchar_t)), &written, nullptr);
        }

        if (GetConsoleWindow() != nullptr)
        {
            fwprintf(stderr, L"%s\n", line.c_str());
            fflush(stderr);
        }
    }

    bool WantsConsoleAlloc()
    {
        if (IsDebuggerPresent())
            return true;

        auto v = GetEnvW(L"VIRTUACAM_CONSOLE");
        if (v.empty())
            return false;

        for (auto& ch : v)
            ch = static_cast<wchar_t>(towlower(ch));

        return (v == L"1" || v == L"true" || v == L"yes" || v == L"on");
    }
}

namespace VirtuaCamLog
{
    void ConfigureDllSearchPaths()
    {
        HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
        if (!kernel32)
            return;

        using SetDefaultDllDirectoriesFn = BOOL(WINAPI*)(DWORD);
        using AddDllDirectoryFn = DLL_DIRECTORY_COOKIE(WINAPI*)(PCWSTR);

        auto pSetDefault = reinterpret_cast<SetDefaultDllDirectoriesFn>(GetProcAddress(kernel32, "SetDefaultDllDirectories"));
        auto pAddDir = reinterpret_cast<AddDllDirectoryFn>(GetProcAddress(kernel32, "AddDllDirectory"));

        if (!pSetDefault || !pAddDir)
            return;

        // Search only safe default dirs + our exe dir (user dir).
        pSetDefault(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_USER_DIRS);

        auto exeDir = GetExeDir();
        if (!exeDir.empty())
        {
            (void)pAddDir(exeDir.c_str());
        }
    }

    std::wstring GetExePath()
    {
        std::wstring path;
        path.resize(32768);
        DWORD len = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
        if (len == 0)
            return {};
        path.resize(len);
        return path;
    }

    std::wstring GetExeDir()
    {
        auto exe = GetExePathFs();
        return exe.parent_path().wstring();
    }

    std::wstring GetCurrentDir()
    {
        DWORD needed = GetCurrentDirectoryW(0, nullptr);
        if (needed == 0)
            return {};
        std::wstring dir;
        dir.resize(needed);
        DWORD written = GetCurrentDirectoryW(needed, dir.data());
        if (written == 0)
            return {};
        if (!dir.empty() && dir.back() == L'\0')
            dir.pop_back();
        return dir;
    }

    std::wstring GetLogPath()
    {
        std::scoped_lock lock(g_logMutex);
        return g_logPath;
    }

    void Init(const InitOptions& options)
    {
        std::scoped_lock lock(g_logMutex);
        if (g_initialized)
            return;

        ConfigureDllSearchPaths();

        if (!options.enabled)
        {
            g_logPath.clear();
            return;
        }

        bool allocConsole = options.allocConsoleIfMissing || WantsConsoleAlloc();
        (void)EnsureConsole(options.attachConsole, allocConsole);

        auto logDir = GetLogDirFs();
        g_logPath = (logDir / options.logFileName).wstring();

        wil::unique_hlocal_security_descriptor sd;
        SECURITY_ATTRIBUTES sa = {};
        (void)CreateCurrentUserOnlySecurityAttributes(sd, sa);

        g_logFile = CreateFileW(
            g_logPath.c_str(),
            FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            sa.lpSecurityDescriptor ? &sa : nullptr,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            nullptr);

        g_initialized = true;

        WriteLineLocked(std::format(L"[{}] logging init: {}", FormatTimestamp(), g_logPath));
        WriteLineLocked(std::format(L"[{}] exe: {}", FormatTimestamp(), GetExePath()));
        WriteLineLocked(std::format(L"[{}] cwd: {}", FormatTimestamp(), GetCurrentDir()));
    }

    void Shutdown()
    {
        std::scoped_lock lock(g_logMutex);
        if (g_logFile != INVALID_HANDLE_VALUE)
        {
            CloseHandle(g_logFile);
            g_logFile = INVALID_HANDLE_VALUE;
        }
        g_logPath.clear();
        g_initialized = false;
    }

    void LogLine(const std::wstring& message)
    {
        std::scoped_lock lock(g_logMutex);
        if (!g_initialized)
            return;
        WriteLineLocked(std::format(L"[{}] {}", FormatTimestamp(), message));
    }

    void LogWin32(const std::wstring& context, DWORD error)
    {
        LogLine(std::format(L"{} -> {}", context, FormatWin32Message(error)));
    }

    void LogHr(const std::wstring& context, HRESULT hr)
    {
        LogLine(std::format(L"{} -> HRESULT 0x{:08X}", context, static_cast<unsigned>(hr)));
        if ((hr & 0xFFFF0000) == 0x80070000)
        {
            DWORD win32 = HRESULT_CODE(hr);
            LogLine(std::format(L"  {}", FormatWin32Message(win32)));
        }
    }

    void ShowAndLogError(HWND hwnd, PCWSTR message, PCWSTR title, HRESULT hr)
    {
        std::wstring msg = (message ? message : L"");
        std::wstring ttl = (title ? title : L"");
        LogLine(std::format(L"GUI error: {} (HRESULT 0x{:08X})", msg, static_cast<unsigned>(hr)));
        MessageBoxW(hwnd, msg.c_str(), ttl.c_str(), MB_OK | MB_ICONERROR);
    }
}
