#include <windows.h>
#include <commctrl.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <d3dcompiler.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <shlobj.h>
#include <shellapi.h>
#include <setupapi.h>
#include <newdev.h>
#include <wincrypt.h>
#include <uxtheme.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <format>
#include <optional>
#include <string>
#include <vector>

#include "resource.h"

using Microsoft::WRL::ComPtr;

#pragma comment(linker,"\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

namespace
{
    constexpr wchar_t kWindowClass[] = L"VirtuaCamSetupWindow";
    constexpr wchar_t kPreviewClass[] = L"VirtuaCamSetupPreview";
    constexpr wchar_t kBrokerTextureName[] = L"Local\\VirtuaCast_Broker_Texture";
    constexpr wchar_t kSettingsSubkey[] = L"Software\\VirtuaCam\\Settings";

    constexpr int IDC_PREVIEW = 1000;
    constexpr int IDC_STATUS = 1001;
    constexpr int IDC_CHECKS = 1002;
    constexpr int IDC_VERIFY = 1003;
    constexpr int IDC_CLOSE = 1004;
    constexpr int IDC_INSTALL = 1005;
    constexpr int IDC_UNINSTALL = 1006;
    constexpr int IDC_DEBUG = 1007;

    struct CheckResult
    {
        std::wstring name;
        bool success = false;
        std::wstring detail;
    };

    struct RunResult
    {
        std::wstring mode;
        bool success = false;
        std::vector<CheckResult> checks;
        std::filesystem::path jsonPath;
    };

    struct SetupOptions
    {
        bool skipDllRegister = false;
        bool skipCertificateImport = false;
        bool skipWatcherService = false;
    };

    class SourceReaderCallback final : public IMFSourceReaderCallback
    {
    public:
        SourceReaderCallback()
            : m_event(CreateEventW(nullptr, TRUE, FALSE, nullptr))
        {
        }

        ~SourceReaderCallback()
        {
            if (m_event) {
                CloseHandle(m_event);
            }
        }

        STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override
        {
            if (!ppv) {
                return E_POINTER;
            }
            if (riid == IID_IUnknown || riid == __uuidof(IMFSourceReaderCallback)) {
                *ppv = static_cast<IMFSourceReaderCallback*>(this);
                AddRef();
                return S_OK;
            }
            *ppv = nullptr;
            return E_NOINTERFACE;
        }

        ULONG STDMETHODCALLTYPE AddRef() override
        {
            return static_cast<ULONG>(InterlockedIncrement(&m_ref));
        }

        ULONG STDMETHODCALLTYPE Release() override
        {
            const ULONG ref = static_cast<ULONG>(InterlockedDecrement(&m_ref));
            if (ref == 0) {
                delete this;
            }
            return ref;
        }

        STDMETHODIMP OnReadSample(HRESULT hrStatus, DWORD, DWORD flags, LONGLONG timestamp, IMFSample* sample) override
        {
            m_status = hrStatus;
            m_flags = flags;
            m_timestamp = timestamp;
            m_sample = sample;
            if (m_event) {
                SetEvent(m_event);
            }
            return S_OK;
        }

        STDMETHODIMP OnEvent(DWORD, IMFMediaEvent*) override
        {
            return S_OK;
        }

        STDMETHODIMP OnFlush(DWORD) override
        {
            return S_OK;
        }

        HANDLE EventHandle() const { return m_event; }
        HRESULT Status() const { return m_status; }
        DWORD Flags() const { return m_flags; }
        LONGLONG Timestamp() const { return m_timestamp; }
        IMFSample* Sample() const { return m_sample.Get(); }

    private:
        LONG m_ref = 1;
        HANDLE m_event = nullptr;
        HRESULT m_status = E_PENDING;
        DWORD m_flags = 0;
        LONGLONG m_timestamp = 0;
        ComPtr<IMFSample> m_sample;
    };

    HINSTANCE g_instance = nullptr;
    HWND g_hwnd = nullptr;
    HWND g_preview = nullptr;
    HWND g_status = nullptr;
    HWND g_checks = nullptr;
    HWND g_debug = nullptr;
    HFONT g_uiFont = nullptr;
    HBRUSH g_windowBrush = nullptr;
    HBRUSH g_panelBrush = nullptr;

    ComPtr<ID3D11Device> g_previewDevice;
    ComPtr<ID3D11DeviceContext> g_previewContext;
    ComPtr<IDXGISwapChain> g_previewSwapChain;
    ComPtr<ID3D11RenderTargetView> g_previewRtv;
    ComPtr<ID3D11VertexShader> g_previewVs;
    ComPtr<ID3D11PixelShader> g_previewPs;
    ComPtr<ID3D11SamplerState> g_previewSampler;
    ComPtr<ID3D11ShaderResourceView> g_previewSrv;
    ComPtr<ID3D11Texture2D> g_previewTexture;

    const char* g_vertexShaderHlsl = R"(
struct VOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
VOut main(uint vid : SV_VertexID) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0, 1);
    o.uv = uv; return o;
})";

    const char* g_pixelShaderHlsl = R"(
Texture2D tex : register(t0); SamplerState smp : register(s0);
float4 main(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_Target {
    return tex.Sample(smp, uv);
})";

    HMENU ControlId(int id)
    {
        return reinterpret_cast<HMENU>(static_cast<INT_PTR>(id));
    }

    std::wstring ToLower(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
            return static_cast<wchar_t>(towlower(ch));
        });
        return value;
    }

    bool ContainsNoCase(const std::wstring& text, const std::wstring& needle)
    {
        return ToLower(text).find(ToLower(needle)) != std::wstring::npos;
    }

    bool EqualsNoCase(const std::wstring& left, const std::wstring& right)
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
    }

    bool IsVirtuaCamDeviceName(const std::wstring& name)
    {
        return EqualsNoCase(name, L"VirtuaCam") ||
            EqualsNoCase(name, L"Virtual Camera Driver") ||
            EqualsNoCase(name, L"Virtual Camera Source");
    }

    std::wstring Utf8ToWide(const std::string& value)
    {
        if (value.empty()) return {};
        int chars = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
        if (chars <= 0) {
            chars = MultiByteToWideChar(CP_ACP, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
            if (chars <= 0) return {};
            std::wstring result(chars, L'\0');
            MultiByteToWideChar(CP_ACP, 0, value.data(), static_cast<int>(value.size()), result.data(), chars);
            return result;
        }
        std::wstring result(chars, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), chars);
        return result;
    }

    std::string WideToUtf8(const std::wstring& value)
    {
        if (value.empty()) return {};
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
        std::string result(bytes, '\0');
        WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), bytes, nullptr, nullptr);
        return result;
    }

    std::string JsonEscape(const std::wstring& value)
    {
        std::string utf8 = WideToUtf8(value);
        std::string out;
        out.reserve(utf8.size() + 8);
        for (char ch : utf8) {
            switch (ch) {
            case '\\': out += "\\\\"; break;
            case '"': out += "\\\""; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(ch) < 0x20) {
                    out += std::format("\\u{:04X}", static_cast<unsigned char>(ch));
                } else {
                    out += ch;
                }
                break;
            }
        }
        return out;
    }

    std::filesystem::path ExePath()
    {
        std::wstring buffer(32768, L'\0');
        const DWORD len = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        buffer.resize(len);
        return buffer;
    }

    std::filesystem::path ExeDir()
    {
        return ExePath().parent_path();
    }

    std::filesystem::path PackageRoot()
    {
        return ExeDir();
    }

    std::filesystem::path LogDir()
    {
        std::filesystem::path dir = PackageRoot() / L"logs";
        std::error_code ec;
        std::filesystem::create_directories(dir, ec);
        return dir;
    }

    std::filesystem::path InstallLogPath()
    {
        return LogDir() / L"driver-install.log";
    }

    std::filesystem::path DefaultJsonPath(const std::wstring& mode)
    {
        SYSTEMTIME st = {};
        GetLocalTime(&st);
        std::filesystem::path dir = LogDir() / L"wizard";
        std::error_code ec;
        std::filesystem::create_directories(dir, ec);
        return dir / std::format(
            L"virtuacam-setup-{}-{:04}{:02}{:02}-{:02}{:02}{:02}.json",
            mode,
            st.wYear,
            st.wMonth,
            st.wDay,
            st.wHour,
            st.wMinute,
            st.wSecond);
    }

    void AddCheckLine(const CheckResult& check)
    {
        if (!g_checks) return;
        std::wstring line = std::format(
            L"{}  {}{}",
            check.success ? L"OK " : L"FAIL",
            check.name,
            check.detail.empty() ? L"" : (L" - " + check.detail));
        SendMessageW(g_checks, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(line.c_str()));
    }

    void SetStatusText(const std::wstring& text)
    {
        if (g_status) {
            SetWindowTextW(g_status, text.c_str());
            NotifyWinEvent(EVENT_OBJECT_NAMECHANGE, g_status, OBJID_CLIENT, CHILDID_SELF);
        }
    }

    std::wstring SystemToolPath(const wchar_t* fileName)
    {
        wchar_t systemDir[MAX_PATH] = {};
        GetSystemDirectoryW(systemDir, ARRAYSIZE(systemDir));
        return (std::filesystem::path(systemDir) / fileName).wstring();
    }

    bool RunProcessCapture(const std::wstring& commandLine, DWORD timeoutMs, DWORD& exitCode, std::wstring& output)
    {
        output.clear();
        exitCode = ERROR_PROCESS_ABORTED;

        SECURITY_ATTRIBUTES sa = {};
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;

        HANDLE readPipe = nullptr;
        HANDLE writePipe = nullptr;
        if (!CreatePipe(&readPipe, &writePipe, &sa, 0)) {
            output = L"CreatePipe failed";
            return false;
        }
        SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);

        STARTUPINFOW si = {};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
        si.hStdOutput = writePipe;
        si.hStdError = writePipe;
        si.wShowWindow = SW_HIDE;

        PROCESS_INFORMATION pi = {};
        std::wstring mutableCommand = commandLine;
        BOOL ok = CreateProcessW(
            nullptr,
            mutableCommand.data(),
            nullptr,
            nullptr,
            TRUE,
            CREATE_NO_WINDOW,
            nullptr,
            PackageRoot().c_str(),
            &si,
            &pi);
        CloseHandle(writePipe);

        if (!ok) {
            output = std::format(L"CreateProcess failed: {}", GetLastError());
            CloseHandle(readPipe);
            return false;
        }

        std::string bytes;
        const DWORD startTick = GetTickCount();
        bool timedOut = false;
        for (;;) {
            DWORD available = 0;
            if (PeekNamedPipe(readPipe, nullptr, 0, nullptr, &available, nullptr) && available > 0) {
                std::string chunk(available, '\0');
                DWORD read = 0;
                if (ReadFile(readPipe, chunk.data(), available, &read, nullptr) && read > 0) {
                    chunk.resize(read);
                    bytes += chunk;
                }
            }

            const DWORD wait = WaitForSingleObject(pi.hProcess, 50);
            if (wait == WAIT_OBJECT_0) {
                DWORD remaining = 0;
                if (!PeekNamedPipe(readPipe, nullptr, 0, nullptr, &remaining, nullptr) || remaining == 0) {
                    break;
                }
            }

            if (timeoutMs != INFINITE && GetTickCount() - startTick > timeoutMs) {
                TerminateProcess(pi.hProcess, ERROR_TIMEOUT);
                timedOut = true;
                break;
            }
        }

        GetExitCodeProcess(pi.hProcess, &exitCode);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        CloseHandle(readPipe);

        output = Utf8ToWide(bytes);
        if (timedOut) {
            output += L"\nTimed out.";
            exitCode = ERROR_TIMEOUT;
        }
        return exitCode == 0;
    }

    void WriteInstallLog(const std::wstring& message)
    {
        std::wofstream stream(InstallLogPath(), std::ios::app);
        if (!stream) return;
        SYSTEMTIME st = {};
        GetLocalTime(&st);
        stream << std::format(
            L"[{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}] {}\n",
            st.wYear,
            st.wMonth,
            st.wDay,
            st.wHour,
            st.wMinute,
            st.wSecond,
            st.wMilliseconds,
            message);
    }

    void LogStep(const std::wstring& message)
    {
        WriteInstallLog(L"--- [STEP] " + message + L" ---");
    }

    void LogInfo(const std::wstring& message)
    {
        WriteInstallLog(L"INFO: " + message);
    }

    void LogSuccess(const std::wstring& message)
    {
        WriteInstallLog(L"SUCCESS: " + message);
    }

    std::wstring QuoteCommandArg(const std::wstring& value)
    {
        std::wstring escaped = L"\"";
        for (wchar_t ch : value) {
            if (ch == L'"') escaped += L"\\\"";
            else escaped += ch;
        }
        escaped += L"\"";
        return escaped;
    }

    std::wstring BuildCommandLine(const std::wstring& exe, const std::vector<std::wstring>& args)
    {
        std::wstring command = QuoteCommandArg(exe);
        for (const auto& arg : args) {
            command += L" ";
            command += QuoteCommandArg(arg);
        }
        return command;
    }

    bool IsAllowedExitCode(DWORD exitCode, const std::vector<DWORD>& allowed)
    {
        return std::find(allowed.begin(), allowed.end(), exitCode) != allowed.end();
    }

    bool RunLoggedCommand(
        const std::wstring& exe,
        const std::vector<std::wstring>& args,
        const std::vector<DWORD>& allowedExitCodes,
        DWORD timeoutMs,
        DWORD& exitCode,
        std::wstring& output)
    {
        const std::wstring command = BuildCommandLine(exe, args);
        WriteInstallLog(L"> " + command);
        const bool zeroExit = RunProcessCapture(command, timeoutMs, exitCode, output);
        if (!output.empty()) {
            size_t start = 0;
            while (start < output.size()) {
                size_t end = output.find_first_of(L"\r\n", start);
                std::wstring line = output.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start);
                if (!line.empty()) WriteInstallLog(line);
                if (end == std::wstring::npos) break;
                start = end + 1;
                while (start < output.size() && (output[start] == L'\r' || output[start] == L'\n')) ++start;
            }
        }
        return (zeroExit || IsAllowedExitCode(exitCode, allowedExitCodes)) && IsAllowedExitCode(exitCode, allowedExitCodes);
    }

    bool RunLoggedCommand(
        const std::wstring& exe,
        const std::vector<std::wstring>& args,
        const std::vector<DWORD>& allowedExitCodes = { 0 },
        DWORD timeoutMs = INFINITE)
    {
        DWORD exitCode = 0;
        std::wstring output;
        return RunLoggedCommand(exe, args, allowedExitCodes, timeoutMs, exitCode, output);
    }

    void WriteRunJson(const RunResult& result)
    {
        std::error_code ec;
        if (result.jsonPath.has_parent_path()) {
            std::filesystem::create_directories(result.jsonPath.parent_path(), ec);
        }
        std::ofstream stream(result.jsonPath, std::ios::binary | std::ios::trunc);
        if (!stream) return;

        SYSTEMTIME utc = {};
        GetSystemTime(&utc);
        stream << "{\n";
        stream << "  \"mode\": \"" << JsonEscape(result.mode) << "\",\n";
        stream << "  \"success\": " << (result.success ? "true" : "false") << ",\n";
        stream << "  \"checkedAtUtc\": \"" << std::format(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            utc.wYear,
            utc.wMonth,
            utc.wDay,
            utc.wHour,
            utc.wMinute,
            utc.wSecond) << "\",\n";
        stream << "  \"checks\": [\n";
        for (size_t i = 0; i < result.checks.size(); ++i) {
            const auto& check = result.checks[i];
            stream << "    {\"name\": \"" << JsonEscape(check.name)
                   << "\", \"success\": " << (check.success ? "true" : "false")
                   << ", \"detail\": \"" << JsonEscape(check.detail) << "\"}";
            stream << (i + 1 == result.checks.size() ? "\n" : ",\n");
        }
        stream << "  ]\n";
        stream << "}\n";
    }

    CheckResult DeleteLegacySettings()
    {
        CheckResult result{ L"Legacy settings cleanup", true, L"No legacy file found" };
        PWSTR localAppData = nullptr;
        PWSTR roamingAppData = nullptr;
        std::vector<std::filesystem::path> paths;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &localAppData)) && localAppData) {
            paths.emplace_back(std::filesystem::path(localAppData) / L"VirtuaCam" / L"settings.ini");
        }
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &roamingAppData)) && roamingAppData) {
            paths.emplace_back(std::filesystem::path(roamingAppData) / L"VirtuaCam" / L"settings.ini");
        }
        CoTaskMemFree(localAppData);
        CoTaskMemFree(roamingAppData);

        for (const auto& path : paths) {
            std::error_code ec;
            const bool removed = std::filesystem::remove(path, ec);
            if (ec) {
                result.success = false;
                result.detail = std::format(L"Delete failed: {} error={}", path.wstring(), ec.value());
                return result;
            }
            if (removed) {
                result.detail = std::format(L"Deleted {}", path.wstring());
            }
        }
        return result;
    }

    bool EnsureStringValue(HKEY key, const wchar_t* name, const wchar_t* value)
    {
        DWORD type = 0;
        wchar_t buffer[256] = {};
        DWORD cb = sizeof(buffer);
        if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, &type, buffer, &cb) == ERROR_SUCCESS && type == REG_SZ) {
            return true;
        }
        return RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value), static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
    }

    bool EnsureDwordValue(HKEY key, const wchar_t* name, DWORD value)
    {
        DWORD existing = 0;
        DWORD type = 0;
        DWORD cb = sizeof(existing);
        if (RegGetValueW(key, nullptr, name, RRF_RT_REG_DWORD, &type, &existing, &cb) == ERROR_SUCCESS && type == REG_DWORD) {
            return true;
        }
        return RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS;
    }

    bool ReadSettingsDword(const wchar_t* name, DWORD defaultValue)
    {
        DWORD value = defaultValue;
        DWORD type = 0;
        DWORD cb = sizeof(value);
        if (RegGetValueW(HKEY_CURRENT_USER, kSettingsSubkey, name, RRF_RT_REG_DWORD, &type, &value, &cb) == ERROR_SUCCESS && type == REG_DWORD) {
            return value != 0;
        }
        return defaultValue != 0;
    }

    bool WriteSettingsDword(const wchar_t* name, DWORD value)
    {
        HKEY key = nullptr;
        const LSTATUS status = RegCreateKeyExW(
            HKEY_CURRENT_USER,
            kSettingsSubkey,
            0,
            nullptr,
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            nullptr,
            &key,
            nullptr);
        if (status != ERROR_SUCCESS) {
            return false;
        }
        const bool ok = RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS;
        RegCloseKey(key);
        return ok;
    }

    CheckResult EnsureRegistrySettings()
    {
        CheckResult result{ L"HKCU settings registry", false, L"" };
        HKEY key = nullptr;
        const LSTATUS status = RegCreateKeyExW(
            HKEY_CURRENT_USER,
            kSettingsSubkey,
            0,
            nullptr,
            REG_OPTION_NON_VOLATILE,
            KEY_READ | KEY_SET_VALUE,
            nullptr,
            &key,
            nullptr);
        if (status != ERROR_SUCCESS) {
            result.detail = std::format(L"RegCreateKeyEx failed: {}", status);
            return result;
        }

        const bool ok =
            EnsureDwordValue(key, L"ShowPipTopLeft", 0) &&
            EnsureDwordValue(key, L"ShowPipTopRight", 0) &&
            EnsureDwordValue(key, L"ShowPipBottomLeft", 0) &&
            EnsureDwordValue(key, L"StartDebugMode", 0) &&
            EnsureStringValue(key, L"AspectRatio", L"16:9") &&
            EnsureStringValue(key, L"AudioCaptureDeviceName", L"Stereo Mix");
        RegCloseKey(key);

        result.success = ok;
        result.detail = ok ? L"HKCU\\Software\\VirtuaCam\\Settings ready" : L"Default value write failed";
        return result;
    }

    CheckResult CheckPnpDevice(const std::wstring& name, const std::wstring& instanceId)
    {
        DWORD exitCode = 0;
        std::wstring output;
        const std::wstring command = std::format(
            L"\"{}\" /enum-devices /instanceid {}",
            SystemToolPath(L"pnputil.exe"),
            instanceId);
        const bool ok = RunProcessCapture(command, 60000, exitCode, output);
        CheckResult result{ name, false, L"" };
        if (!ok) {
            result.detail = std::format(L"pnputil exit={} {}", exitCode, output.substr(0, std::min<size_t>(160, output.size())));
            return result;
        }
        result.success = ContainsNoCase(output, L"Status:") &&
            (ContainsNoCase(output, L"Status:                     Started") ||
             ContainsNoCase(output, L"Status:                     OK"));
        result.detail = result.success ? instanceId + L" status started" : L"Device not started or not present";
        return result;
    }

    CheckResult CheckWatcherService()
    {
        CheckResult result{ L"Watcher service", false, L"" };
        SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
        if (!manager) {
            result.detail = std::format(L"OpenSCManager failed: {}", GetLastError());
            return result;
        }
        SC_HANDLE service = OpenServiceW(manager, L"VirtuaCamWatcher", SERVICE_QUERY_STATUS);
        if (!service) {
            result.detail = L"VirtuaCamWatcher missing";
            CloseServiceHandle(manager);
            return result;
        }
        SERVICE_STATUS_PROCESS status = {};
        DWORD needed = 0;
        const BOOL ok = QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, reinterpret_cast<LPBYTE>(&status), sizeof(status), &needed);
        CloseServiceHandle(service);
        CloseServiceHandle(manager);
        result.success = ok != FALSE && status.dwCurrentState == SERVICE_RUNNING;
        result.detail = ok ? std::format(L"State={}", status.dwCurrentState) : std::format(L"Query failed: {}", GetLastError());
        return result;
    }

    std::vector<std::wstring> EnumerateVideoDevices()
    {
        std::vector<std::wstring> names;
        ComPtr<IMFAttributes> attrs;
        if (FAILED(MFCreateAttributes(&attrs, 1))) return names;
        if (FAILED(attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID))) return names;

        IMFActivate** devices = nullptr;
        UINT32 count = 0;
        if (FAILED(MFEnumDeviceSources(attrs.Get(), &devices, &count))) return names;
        for (UINT32 i = 0; i < count; ++i) {
            wchar_t* friendly = nullptr;
            UINT32 cch = 0;
            if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendly, &cch)) && friendly) {
                names.emplace_back(friendly);
            }
            CoTaskMemFree(friendly);
            devices[i]->Release();
        }
        CoTaskMemFree(devices);
        return names;
    }

    CheckResult CheckVirtualCameraEnumeration()
    {
        const auto names = EnumerateVideoDevices();
        for (const auto& name : names) {
            if (IsVirtuaCamDeviceName(name)) {
                return { L"Camera enumeration", true, name };
            }
        }
        return { L"Camera enumeration", false, std::format(L"No virtual camera in {} video device(s)", names.size()) };
    }

    CheckResult CheckVirtualCameraOpen()
    {
        ComPtr<IMFAttributes> attrs;
        if (FAILED(MFCreateAttributes(&attrs, 2))) {
            return { L"Camera capture open", false, L"MFCreateAttributes failed" };
        }
        attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);

        IMFActivate** devices = nullptr;
        UINT32 count = 0;
        if (FAILED(MFEnumDeviceSources(attrs.Get(), &devices, &count))) {
            return { L"Camera capture open", false, L"MFEnumDeviceSources failed" };
        }

        CheckResult result{ L"Camera capture open", false, L"Virtual camera not found" };
        for (UINT32 i = 0; i < count; ++i) {
            wchar_t* friendly = nullptr;
            UINT32 cch = 0;
            const bool gotName = SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendly, &cch)) && friendly;
            const std::wstring name = gotName ? friendly : L"";
            if (IsVirtuaCamDeviceName(name)) {
                ComPtr<IMFMediaSource> source;
                const HRESULT hr = devices[i]->ActivateObject(IID_PPV_ARGS(&source));
                result.success = SUCCEEDED(hr);
                result.detail = result.success ? (L"Opened " + name) : std::format(L"ActivateObject failed: 0x{:08X}", static_cast<unsigned>(hr));
                if (source) source->Shutdown();
                CoTaskMemFree(friendly);
                break;
            }
            CoTaskMemFree(friendly);
        }
        for (UINT32 i = 0; i < count; ++i) {
            devices[i]->Release();
        }
        CoTaskMemFree(devices);
        return result;
    }

    CheckResult OpenVirtualCameraSource(ComPtr<IMFMediaSource>& source, std::wstring& name)
    {
        ComPtr<IMFAttributes> attrs;
        if (FAILED(MFCreateAttributes(&attrs, 2))) {
            return { L"Final test frame", false, L"MFCreateAttributes failed" };
        }
        attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);

        IMFActivate** devices = nullptr;
        UINT32 count = 0;
        if (FAILED(MFEnumDeviceSources(attrs.Get(), &devices, &count))) {
            return { L"Final test frame", false, L"MFEnumDeviceSources failed" };
        }

        CheckResult result{ L"Final test frame", false, L"Virtual camera not found" };
        for (UINT32 i = 0; i < count; ++i) {
            wchar_t* friendly = nullptr;
            UINT32 cch = 0;
            const bool gotName = SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendly, &cch)) && friendly;
            const std::wstring candidate = gotName ? friendly : L"";
            if (IsVirtuaCamDeviceName(candidate)) {
                const HRESULT hr = devices[i]->ActivateObject(IID_PPV_ARGS(&source));
                result.success = SUCCEEDED(hr);
                result.detail = result.success ? (L"Opened " + candidate) : std::format(L"ActivateObject failed: 0x{:08X}", static_cast<unsigned>(hr));
                name = candidate;
                CoTaskMemFree(friendly);
                break;
            }
            CoTaskMemFree(friendly);
        }
        for (UINT32 i = 0; i < count; ++i) {
            devices[i]->Release();
        }
        CoTaskMemFree(devices);
        return result;
    }

    std::vector<std::wstring> EnumerateCaptureEndpoints()
    {
        std::vector<std::wstring> names;
        ComPtr<IMMDeviceEnumerator> enumerator;
        if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return names;

        ComPtr<IMMDeviceCollection> collection;
        if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection))) return names;

        UINT count = 0;
        collection->GetCount(&count);
        for (UINT i = 0; i < count; ++i) {
            ComPtr<IMMDevice> device;
            if (FAILED(collection->Item(i, &device))) continue;
            ComPtr<IPropertyStore> props;
            if (FAILED(device->OpenPropertyStore(STGM_READ, &props))) continue;
            PROPVARIANT var;
            PropVariantInit(&var);
            if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &var)) && var.vt == VT_LPWSTR && var.pwszVal) {
                names.emplace_back(var.pwszVal);
            }
            PropVariantClear(&var);
        }
        return names;
    }

    CheckResult CheckMicEnumeration()
    {
        const auto names = EnumerateCaptureEndpoints();
        if (!names.empty()) {
            return { L"Mic enumeration", true, std::format(L"{} active capture endpoint(s)", names.size()) };
        }
        return { L"Mic enumeration", false, L"No active capture endpoints" };
    }

    CheckResult CheckMicOpen()
    {
        ComPtr<IMMDeviceEnumerator> enumerator;
        if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
            return { L"Mic capture open", false, L"MMDeviceEnumerator failed" };
        }

        ComPtr<IMMDeviceCollection> collection;
        if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection))) {
            return { L"Mic capture open", false, L"EnumAudioEndpoints failed" };
        }

        UINT count = 0;
        collection->GetCount(&count);
        for (UINT i = 0; i < count; ++i) {
            ComPtr<IMMDevice> device;
            if (FAILED(collection->Item(i, &device))) continue;

            ComPtr<IPropertyStore> props;
            std::wstring name;
            if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
                PROPVARIANT var;
                PropVariantInit(&var);
                if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &var)) && var.vt == VT_LPWSTR && var.pwszVal) {
                    name = var.pwszVal;
                }
                PropVariantClear(&var);
            }

            ComPtr<IAudioClient> audioClient;
            HRESULT hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(audioClient.GetAddressOf()));
            if (FAILED(hr)) {
                return { L"Mic capture open", false, std::format(L"Activate failed: 0x{:08X}", static_cast<unsigned>(hr)) };
            }
            WAVEFORMATEX* mixFormat = nullptr;
            hr = audioClient->GetMixFormat(&mixFormat);
            CoTaskMemFree(mixFormat);
            if (SUCCEEDED(hr)) {
                return { L"Mic capture open", true, name.empty() ? L"Opened capture endpoint" : (L"Opened " + name) };
            }
        }

        return { L"Mic capture open", false, L"No active capture endpoint opened" };
    }

    CheckResult CheckTestFrameOpen()
    {
        ComPtr<IMFMediaSource> source;
        std::wstring name;
        CheckResult opened = OpenVirtualCameraSource(source, name);
        if (!opened.success || !source) {
            return opened;
        }

        SourceReaderCallback* callbackRaw = new SourceReaderCallback();
        if (!callbackRaw->EventHandle()) {
            delete callbackRaw;
            source->Shutdown();
            return { L"Final test frame", false, L"CreateEvent failed" };
        }

        ComPtr<IMFSourceReaderCallback> callback;
        callback.Attach(callbackRaw);

        ComPtr<IMFAttributes> attrs;
        HRESULT hr = MFCreateAttributes(&attrs, 1);
        if (SUCCEEDED(hr)) {
            hr = attrs->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback.Get());
        }

        ComPtr<IMFSourceReader> reader;
        if (SUCCEEDED(hr)) {
            hr = MFCreateSourceReaderFromMediaSource(source.Get(), attrs.Get(), &reader);
        }
        if (SUCCEEDED(hr)) {
            reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
            hr = reader->SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
        }
        if (SUCCEEDED(hr)) {
            hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr, nullptr, nullptr, nullptr);
        }
        if (FAILED(hr)) {
            source->Shutdown();
            return { L"Final test frame", false, std::format(L"ReadSample start failed: 0x{:08X}", static_cast<unsigned>(hr)) };
        }

        const DWORD wait = WaitForSingleObject(callbackRaw->EventHandle(), 5000);
        if (wait != WAIT_OBJECT_0) {
            source->Shutdown();
            return { L"Final test frame", false, wait == WAIT_TIMEOUT ? L"Timed out waiting for frame sample" : L"Frame wait failed" };
        }

        hr = callbackRaw->Status();
        if (FAILED(hr)) {
            source->Shutdown();
            return { L"Final test frame", false, std::format(L"ReadSample failed: 0x{:08X}", static_cast<unsigned>(hr)) };
        }
        if ((callbackRaw->Flags() & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM)) != 0) {
            source->Shutdown();
            return { L"Final test frame", false, std::format(L"Reader flags=0x{:08X}", callbackRaw->Flags()) };
        }
        IMFSample* sample = callbackRaw->Sample();
        if (!sample) {
            source->Shutdown();
            return { L"Final test frame", false, L"No sample returned" };
        }

        DWORD bytes = 0;
        (void)sample->GetTotalLength(&bytes);
        source->Shutdown();
        return {
            L"Final test frame",
            true,
            std::format(L"Frame sample from {}: {} bytes timestamp={}", name, bytes, callbackRaw->Timestamp())
        };
    }

    RunResult RunFirstRunChecks(const std::wstring& mode, const std::filesystem::path& jsonPath)
    {
        RunResult result;
        result.mode = mode;
        result.jsonPath = jsonPath.empty() ? DefaultJsonPath(mode) : jsonPath;

        auto add = [&](CheckResult check) {
            result.success = result.success && check.success;
            result.checks.push_back(check);
            AddCheckLine(result.checks.back());
        };

        result.success = true;
        SetStatusText(L"Running first-run checks...");
        add(DeleteLegacySettings());
        add(EnsureRegistrySettings());
        add(CheckPnpDevice(L"Camera devnode", L"ROOT\\AVSHWS\\0000"));
        add(CheckWatcherService());
        add(CheckVirtualCameraEnumeration());
        add(CheckMicEnumeration());
        add(CheckVirtualCameraOpen());
        add(CheckMicOpen());
        add(CheckTestFrameOpen());

        WriteRunJson(result);
        SetStatusText(result.success ? L"Checks passed." : L"One or more checks failed. See JSON report.");
        return result;
    }

    std::filesystem::path GetJsonArg(const std::vector<std::wstring>& args)
    {
        for (size_t i = 0; i + 1 < args.size(); ++i) {
            if (args[i] == L"--json") {
                return args[i + 1];
            }
        }
        return {};
    }

    std::vector<std::wstring> ParseArgs()
    {
        int argc = 0;
        LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        std::vector<std::wstring> args;
        for (int i = 1; i < argc; ++i) {
            args.emplace_back(argv[i]);
        }
        LocalFree(argv);
        return args;
    }

    bool HasArg(const std::vector<std::wstring>& args, const wchar_t* value)
    {
        return std::any_of(args.begin(), args.end(), [&](const std::wstring& arg) {
            return _wcsicmp(arg.c_str(), value) == 0;
        });
    }

    std::wstring QuoteArg(const std::filesystem::path& path)
    {
        std::wstring value = path.wstring();
        std::wstring escaped;
        escaped.reserve(value.size() + 2);
        escaped.push_back(L'"');
        for (wchar_t ch : value) {
            if (ch == L'"') {
                escaped += L"\\\"";
            } else {
                escaped.push_back(ch);
            }
        }
        escaped.push_back(L'"');
        return escaped;
    }

    bool IsAdministrator()
    {
        BOOL isAdmin = FALSE;
        PSID administrators = nullptr;
        SID_IDENTIFIER_AUTHORITY ntAuthority = SECURITY_NT_AUTHORITY;
        if (AllocateAndInitializeSid(
            &ntAuthority,
            2,
            SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_ADMINS,
            0, 0, 0, 0, 0, 0,
            &administrators)) {
            CheckTokenMembership(nullptr, administrators, &isAdmin);
            FreeSid(administrators);
        }
        return isAdmin != FALSE;
    }

    SetupOptions GetSetupOptions(const std::vector<std::wstring>& args)
    {
        SetupOptions options;
        options.skipDllRegister = HasArg(args, L"--skip-dll-register") || HasArg(args, L"/skip-dll-register");
        options.skipCertificateImport = HasArg(args, L"--skip-certificate-import") || HasArg(args, L"/skip-certificate-import");
        options.skipWatcherService = HasArg(args, L"--skip-watcher-service") || HasArg(args, L"/skip-watcher-service");
        return options;
    }

    std::vector<std::wstring> InstallArtifacts()
    {
        return {
            L"VirtuaCam.exe",
            L"VirtuaCamProcess.exe",
            L"DirectPortBroker.dll",
            L"DirectPortClient.dll",
            L"VirtuaCamSetup.exe",
            L"msvcp140.dll",
            L"vcruntime140.dll",
            L"vcruntime140_1.dll",
            L"avshws.sys",
            L"avshws.inf",
            L"avshws.cat",
            L"VirtualCameraDriver-TestSign.cer",
            L"virtuacam_mic.sys",
            L"virtuacam-mic.inf",
            L"virtuacam-mic.cat"
        };
    }

    std::wstring Sha256File(const std::filesystem::path& path)
    {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return {};

        HCRYPTPROV provider = 0;
        HCRYPTHASH hash = 0;
        std::wstring result;
        if (CryptAcquireContextW(&provider, nullptr, nullptr, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) &&
            CryptCreateHash(provider, CALG_SHA_256, 0, 0, &hash)) {
            BYTE buffer[64 * 1024] = {};
            DWORD read = 0;
            while (ReadFile(file, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
                CryptHashData(hash, buffer, read, 0);
            }
            BYTE digest[32] = {};
            DWORD digestSize = sizeof(digest);
            if (CryptGetHashParam(hash, HP_HASHVAL, digest, &digestSize, 0)) {
                for (DWORD i = 0; i < digestSize; ++i) {
                    result += std::format(L"{:02X}", digest[i]);
                }
            }
        }
        if (hash) CryptDestroyHash(hash);
        if (provider) CryptReleaseContext(provider, 0);
        CloseHandle(file);
        return result;
    }

    std::vector<std::wstring> BoundDriverInfNames(const std::wstring& instanceId)
    {
        DWORD exitCode = 0;
        std::wstring output;
        std::vector<std::wstring> names;
        if (!RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/enum-devices", L"/instanceid", instanceId, L"/drivers" }, { 0 }, 60000, exitCode, output)) {
            return names;
        }
        const std::wstring needle = L"Driver Name:";
        size_t pos = 0;
        while ((pos = output.find(needle, pos)) != std::wstring::npos) {
            pos += needle.size();
            while (pos < output.size() && iswspace(output[pos])) ++pos;
            const size_t end = output.find_first_of(L"\r\n", pos);
            std::wstring value = output.substr(pos, end == std::wstring::npos ? std::wstring::npos : end - pos);
            if (value.starts_with(L"oem") && value.ends_with(L".inf") &&
                std::find(names.begin(), names.end(), value) == names.end()) {
                names.push_back(value);
            }
        }
        return names;
    }

    void RemoveDriverPackagesForInstance(const std::wstring& instanceId)
    {
        for (const auto& inf : BoundDriverInfNames(instanceId)) {
            RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/delete-driver", inf, L"/uninstall", L"/force" }, { 0, 2, 259, 3010, 3758096956u }, 120000);
        }
    }

    bool DeviceStartedOrOk(const std::wstring& instanceId)
    {
        DWORD exitCode = 0;
        std::wstring output;
        if (!RunProcessCapture(
            std::format(L"\"{}\" /enum-devices /instanceid {}", SystemToolPath(L"pnputil.exe"), instanceId),
            60000,
            exitCode,
            output)) {
            return false;
        }
        return ContainsNoCase(output, L"Status:") &&
            (ContainsNoCase(output, L"Status:                     Started") ||
             ContainsNoCase(output, L"Status:                     OK"));
    }

    bool CreateRootDevice(const std::wstring& hardwareId, const std::wstring& className, const std::wstring& description, const GUID& classGuid, std::wstring& detail)
    {
        HDEVINFO info = SetupDiCreateDeviceInfoList(&classGuid, nullptr);
        if (info == INVALID_HANDLE_VALUE) {
            detail = std::format(L"SetupDiCreateDeviceInfoList failed: {}", GetLastError());
            return false;
        }

        SP_DEVINFO_DATA data = {};
        data.cbSize = sizeof(data);
        bool ok = false;
        if (!SetupDiCreateDeviceInfoW(info, className.c_str(), &classGuid, description.c_str(), nullptr, DICD_GENERATE_ID, &data)) {
            detail = std::format(L"SetupDiCreateDeviceInfo failed: {}", GetLastError());
        } else {
            std::wstring multiSz = hardwareId + L'\0' + L'\0';
            if (!SetupDiSetDeviceRegistryPropertyW(
                    info,
                    &data,
                    SPDRP_HARDWAREID,
                    reinterpret_cast<const BYTE*>(multiSz.c_str()),
                    static_cast<DWORD>(multiSz.size() * sizeof(wchar_t)))) {
                detail = std::format(L"SetupDiSetDeviceRegistryProperty failed: {}", GetLastError());
            } else if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, info, &data)) {
                detail = std::format(L"SetupDiCallClassInstaller failed: {}", GetLastError());
            } else {
                ok = true;
            }
        }

        SetupDiDestroyDeviceInfoList(info);
        return ok;
    }

    bool BindDriver(const std::wstring& hardwareId, const std::filesystem::path& infPath, const std::wstring& label, std::wstring& detail)
    {
        BOOL rebootRequired = FALSE;
        if (UpdateDriverForPlugAndPlayDevicesW(nullptr, hardwareId.c_str(), infPath.c_str(), INSTALLFLAG_FORCE, &rebootRequired)) {
            if (rebootRequired) {
                LogInfo(label + L" bind requested reboot.");
            }
            return true;
        }
        const DWORD error = GetLastError();
        if (error == ERROR_NO_SUCH_DEVINST || error == 0xE000020B) {
            return true;
        }
        detail = std::format(L"{} UpdateDriverForPlugAndPlayDevices failed: 0x{:08X}", label, error);
        return false;
    }

    bool WriteRegistryString(HKEY root, const wchar_t* subkey, const wchar_t* name, const std::wstring& value)
    {
        HKEY key = nullptr;
        if (RegCreateKeyExW(root, subkey, 0, nullptr, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
            return false;
        }
        const bool ok = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()), static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
        RegCloseKey(key);
        return ok;
    }

    void DeleteRegistryValue(HKEY root, const wchar_t* subkey, const wchar_t* name)
    {
        HKEY key = nullptr;
        if (RegOpenKeyExW(root, subkey, 0, KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
            RegDeleteValueW(key, name);
            RegCloseKey(key);
        }
    }

    void StopRuntime()
    {
        LogInfo(L"Stopping watcher service and runtime processes before driver install.");
        RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"stop", L"VirtuaCamWatcher" }, { 0, 1060, 1062 }, 30000);
        RunLoggedCommand(SystemToolPath(L"taskkill.exe"), { L"/IM", L"VirtuaCam.exe", L"/F" }, { 0, 128 }, 30000);
        RunLoggedCommand(SystemToolPath(L"taskkill.exe"), { L"/IM", L"VirtuaCamProcess.exe", L"/F" }, { 0, 128 }, 30000);
    }

    CheckResult RunNativeInstall(const SetupOptions& options)
    {
        CheckResult result{ L"Native install", false, L"" };
        if (!IsAdministrator()) {
            result.detail = L"Administrator rights required";
            return result;
        }

        std::error_code ec;
        std::filesystem::create_directories(LogDir(), ec);
        std::filesystem::remove(InstallLogPath(), ec);
        WriteInstallLog(L"============================================================");
        WriteInstallLog(L" Install All");
        WriteInstallLog(L"============================================================");
        LogInfo(L"OutputRoot: " + PackageRoot().wstring());

        LogStep(L"Verify artifacts in output");
        for (const auto& name : InstallArtifacts()) {
            const auto path = PackageRoot() / name;
            if (!std::filesystem::exists(path)) {
                result.detail = L"Missing staged artifact: " + path.wstring();
                WriteInstallLog(L"FATAL: " + result.detail);
                return result;
            }
        }
        LogSuccess(L"Artifacts present");

        LogStep(L"Install driver from output");
        StopRuntime();
        DWORD exitCode = 0;
        std::wstring bcdOutput;
        RunLoggedCommand(SystemToolPath(L"bcdedit.exe"), { L"/enum", L"{current}" }, { 0 }, 60000, exitCode, bcdOutput);
        if (!ContainsNoCase(bcdOutput, L"testsigning") || !ContainsNoCase(bcdOutput, L"Yes")) {
            result.detail = L"TESTSIGNING is OFF. Enable then reboot: bcdedit /set testsigning on";
            WriteInstallLog(L"FATAL: " + result.detail);
            return result;
        }

        const auto driverCer = PackageRoot() / L"VirtualCameraDriver-TestSign.cer";
        if (!options.skipCertificateImport && std::filesystem::exists(driverCer)) {
            RunLoggedCommand(SystemToolPath(L"certutil.exe"), { L"-f", L"-addstore", L"Root", driverCer.wstring() }, { 0 }, 60000);
            RunLoggedCommand(SystemToolPath(L"certutil.exe"), { L"-f", L"-addstore", L"TrustedPublisher", driverCer.wstring() }, { 0 }, 60000);
        } else if (options.skipCertificateImport) {
            LogInfo(L"Skip test certificate import");
        } else {
            LogInfo(L"Certificate missing. Continuing without import.");
        }

        RemoveDriverPackagesForInstance(L"ROOT\\AVSHWS\\0000");
        RemoveDriverPackagesForInstance(L"ROOT\\VIRTUACAMMIC\\0000");

        const auto cameraInf = PackageRoot() / L"avshws.inf";
        if (!RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/add-driver", cameraInf.wstring(), L"/install" }, { 0, 2, 259, 3010 }, 120000)) {
            result.detail = L"pnputil camera driver install failed";
            return result;
        }
        if (!DeviceStartedOrOk(L"ROOT\\AVSHWS\\0000")) {
            LogInfo(L"No ROOT\\AVSHWS device present. Creating it now.");
            const GUID cameraClassGuid = { 0xca3e7ab9, 0xb4c3, 0x4ae6, { 0x82, 0x51, 0x57, 0x9e, 0xf9, 0x33, 0x89, 0x0f } };
            std::wstring detail;
            if (!CreateRootDevice(L"AVSHWS", L"AVSHWS", L"Virtual Camera Driver", cameraClassGuid, detail)) {
                result.detail = detail;
                return result;
            }
        } else {
            LogInfo(L"ROOT\\AVSHWS already exists. Reusing existing device node.");
        }
        if (!BindDriver(L"AVSHWS", cameraInf, L"Camera", result.detail)) return result;
        RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/scan-devices" }, { 0 }, 60000);
        RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/restart-device", L"ROOT\\AVSHWS\\0000" }, { 0, 2, 259, 3010 }, 60000);
        RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/scan-devices" }, { 0 }, 60000);
        if (!DeviceStartedOrOk(L"ROOT\\AVSHWS\\0000")) {
            result.detail = L"Installed camera device not started";
            return result;
        }
        LogSuccess(L"Fresh driver install OK from " + PackageRoot().wstring());

        LogStep(L"Install virtual microphone driver from output");
        const auto micInf = PackageRoot() / L"virtuacam-mic.inf";
        if (!RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/add-driver", micInf.wstring(), L"/install" }, { 0, 2, 259, 3010 }, 120000)) {
            result.detail = L"pnputil microphone driver install failed";
            return result;
        }
        if (!DeviceStartedOrOk(L"ROOT\\VIRTUACAMMIC\\0000")) {
            LogInfo(L"No ROOT\\VIRTUACAMMIC device present. Creating it now.");
            const GUID mediaClassGuid = { 0x4d36e96c, 0xe325, 0x11ce, { 0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18 } };
            std::wstring detail;
            if (!CreateRootDevice(L"ROOT\\VIRTUACAMMIC", L"VIRTUACAMMIC", L"VirtuaCam Microphone", mediaClassGuid, detail)) {
                result.detail = detail;
                return result;
            }
        } else {
            LogInfo(L"ROOT\\VIRTUACAMMIC already exists. Reusing existing device node.");
        }
        if (!BindDriver(L"ROOT\\VIRTUACAMMIC", micInf, L"Audio", result.detail)) return result;
        RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/scan-devices" }, { 0 }, 60000);
        RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/restart-device", L"ROOT\\VIRTUACAMMIC\\0000" }, { 0, 2, 259, 3010 }, 60000);
        RunLoggedCommand(SystemToolPath(L"pnputil.exe"), { L"/scan-devices" }, { 0 }, 60000);
        if (!DeviceStartedOrOk(L"ROOT\\VIRTUACAMMIC\\0000")) {
            result.detail = L"Installed microphone device not started";
            return result;
        }
        LogSuccess(L"VirtuaCam Microphone driver install OK from " + PackageRoot().wstring());

        if (!options.skipDllRegister) {
            LogStep(L"Register software components from output");
            const auto clientDll = PackageRoot() / L"DirectPortClient.dll";
            if (!RunLoggedCommand(SystemToolPath(L"regsvr32.exe"), { L"/s", clientDll.wstring() }, { 0 }, 60000)) {
                result.detail = L"regsvr32 DirectPortClient.dll failed";
                return result;
            }
            LogSuccess(L"Registered: " + clientDll.wstring());
        } else {
            LogInfo(L"Skip DLL register");
        }

        LogStep(L"Configure registry and startup from output");
        DeleteLegacySettings();
        const auto virtuaCamExe = std::filesystem::weakly_canonical(PackageRoot() / L"VirtuaCam.exe");
        const auto processExe = std::filesystem::weakly_canonical(PackageRoot() / L"VirtuaCamProcess.exe");
        const auto installDir = std::filesystem::weakly_canonical(PackageRoot());
        WriteRegistryString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtuaCam", L"InstallDir", installDir.wstring());
        WriteRegistryString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtuaCam", L"VirtuaCamExe", virtuaCamExe.wstring());
        WriteRegistryString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtuaCam", L"ProcessExe", processExe.wstring());
        WriteRegistryString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtuaCam", L"VirtuaCamExeSha256", Sha256File(virtuaCamExe));
        WriteRegistryString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtuaCam", L"ProcessExeSha256", Sha256File(processExe));
        DeleteRegistryValue(HKEY_CURRENT_USER, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", L"VirtuaCamProcess");
        DeleteRegistryValue(HKEY_CURRENT_USER, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", L"VirtuaCam");

        if (options.skipWatcherService) {
            RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"stop", L"VirtuaCamWatcher" }, { 0, 1060, 1062 }, 30000);
            RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"delete", L"VirtuaCamWatcher" }, { 0, 1060 }, 30000);
            LogSuccess(L"Configured HKLM\\SOFTWARE\\VirtuaCam without watcher service startup");
        } else {
            const std::wstring binPath = L"\"" + processExe.wstring() + L"\" --service";
            RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"stop", L"VirtuaCamWatcher" }, { 0, 1060, 1062 }, 30000);
            RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"create", L"VirtuaCamWatcher", L"binPath=", binPath, L"start=", L"auto", L"DisplayName=", L"VirtuaCam Watcher" }, { 0, 1073 }, 30000);
            RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"config", L"VirtuaCamWatcher", L"binPath=", binPath, L"start=", L"auto" }, { 0 }, 30000);
            RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"description", L"VirtuaCamWatcher", L"Starts VirtuaCam when the virtual camera is accessed." }, { 0 }, 30000);
            RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"start", L"VirtuaCamWatcher" }, { 0, 1056 }, 30000);
            LogSuccess(L"Configured HKLM\\SOFTWARE\\VirtuaCam and watcher service startup");
        }

        WriteInstallLog(L"============================================================");
        WriteInstallLog(L" INSTALL-ALL SUCCEEDED");
        WriteInstallLog(L"============================================================");
        result.success = true;
        result.detail = L"Drivers and software installed; log: " + InstallLogPath().wstring();
        return result;
    }

    CheckResult RunNativeUninstall()
    {
        CheckResult result{ L"Native uninstall", false, L"" };
        if (!IsAdministrator()) {
            result.detail = L"Administrator rights required";
            return result;
        }
        std::filesystem::create_directories(LogDir());
        WriteInstallLog(L"============================================================");
        WriteInstallLog(L" Uninstall All");
        WriteInstallLog(L"============================================================");
        RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"stop", L"VirtuaCamWatcher" }, { 0, 1060, 1062 }, 30000);
        RunLoggedCommand(SystemToolPath(L"sc.exe"), { L"delete", L"VirtuaCamWatcher" }, { 0, 1060 }, 30000);
        RemoveDriverPackagesForInstance(L"ROOT\\VIRTUACAMMIC\\0000");
        RemoveDriverPackagesForInstance(L"ROOT\\AVSHWS\\0000");
        DeleteRegistryValue(HKEY_CURRENT_USER, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", L"VirtuaCamProcess");
        DeleteRegistryValue(HKEY_CURRENT_USER, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run", L"VirtuaCam");
        RegDeleteTreeW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtuaCam");
        RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\VirtuaCam\\Settings");
        LogSuccess(L"Uninstall cleanup complete");
        result.success = true;
        result.detail = L"Drivers, service, startup, and registry entries removed; files kept";
        return result;
    }

    std::wstring BuildSelfElevatedArgs(const wchar_t* action)
    {
        return std::wstring(action);
    }

    bool RelaunchElevated(const wchar_t* action)
    {
        const std::wstring exe = ExePath().wstring();
        const std::wstring dir = PackageRoot().wstring();
        const std::wstring args = BuildSelfElevatedArgs(action);
        SHELLEXECUTEINFOW info = {};
        info.cbSize = sizeof(info);
        info.fMask = SEE_MASK_NOCLOSEPROCESS;
        info.lpVerb = L"runas";
        info.lpFile = exe.c_str();
        info.lpParameters = args.c_str();
        info.lpDirectory = dir.c_str();
        info.nShow = SW_SHOWNORMAL;
        if (!ShellExecuteExW(&info)) {
            return false;
        }
        if (info.hProcess) {
            CloseHandle(info.hProcess);
        }
        return true;
    }

    RunResult RunUninstallChecks(const std::filesystem::path& jsonPath)
    {
        RunResult result;
        result.mode = L"uninstall";
        result.jsonPath = jsonPath.empty() ? DefaultJsonPath(result.mode) : jsonPath;
        result.success = true;

        auto add = [&](CheckResult check) {
            result.success = result.success && check.success;
            result.checks.push_back(check);
            AddCheckLine(result.checks.back());
        };

        SetStatusText(L"Checking uninstall state...");
        CheckResult service = CheckWatcherService();
        service.success = !service.success;
        service.detail = service.success ? L"VirtuaCamWatcher not running or missing" : service.detail;
        add(service);

        CheckResult camera = CheckPnpDevice(L"Camera devnode removed", L"ROOT\\AVSHWS\\0000");
        camera.success = !camera.success;
        camera.detail = camera.success ? L"ROOT\\AVSHWS\\0000 not started or not present" : L"Camera devnode still present";
        add(camera);

        CheckResult mic = CheckPnpDevice(L"Mic devnode removed", L"ROOT\\VIRTUACAMMIC\\0000");
        mic.success = !mic.success;
        mic.detail = mic.success ? L"ROOT\\VIRTUACAMMIC\\0000 not started or not present" : L"Mic devnode still present";
        add(mic);

        WriteRunJson(result);
        SetStatusText(result.success ? L"Uninstall checks passed." : L"Uninstall checks failed.");
        return result;
    }

    RunResult RunMode(const std::wstring& mode, const std::filesystem::path& jsonPath, const SetupOptions& options)
    {
        if (mode == L"verify-only") {
            return RunFirstRunChecks(mode, jsonPath);
        }
        if (mode == L"install" || mode == L"uninstall") {
            RunResult result;
            result.mode = mode;
            result.jsonPath = jsonPath.empty() ? DefaultJsonPath(mode) : jsonPath;
            result.success = true;

            SetStatusText(mode == L"install" ? L"Installing VirtuaCam..." : L"Uninstalling VirtuaCam...");
            CheckResult install = (mode == L"uninstall") ? RunNativeUninstall() : RunNativeInstall(options);
            result.success = install.success;
            result.checks.push_back(install);
            AddCheckLine(result.checks.back());

            if (install.success && mode == L"install") {
                RunResult verify = RunFirstRunChecks(L"install-verify", {});
                result.checks.insert(result.checks.end(), verify.checks.begin(), verify.checks.end());
            } else if (install.success && mode == L"uninstall") {
                RunResult verify = RunUninstallChecks({});
                result.success = result.success && verify.success;
                result.checks.insert(result.checks.end(), verify.checks.begin(), verify.checks.end());
            }

            WriteRunJson(result);
            SetStatusText(std::format(
                L"{} {}. Report: {}",
                mode,
                result.success ? L"succeeded" : L"failed",
                result.jsonPath.wstring()));
            return result;
        }
        RunResult result;
        result.mode = mode;
        result.jsonPath = jsonPath.empty() ? DefaultJsonPath(mode) : jsonPath;
        result.success = false;
        result.checks.push_back({ L"Mode", false, L"Unknown mode" });
        WriteRunJson(result);
        return result;
    }

    void ApplyModernWindowTheme(HWND hwnd)
    {
        BOOL dark = TRUE;
        (void)DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
        (void)SetWindowTheme(hwnd, L"DarkMode_Explorer", nullptr);
    }

    HRESULT InitPreviewD3D(HWND hwnd)
    {
        DXGI_SWAP_CHAIN_DESC scd = {};
        scd.BufferCount = 2;
        scd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        scd.OutputWindow = hwnd;
        scd.SampleDesc.Count = 1;
        scd.Windowed = TRUE;
        scd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        HRESULT hr = D3D11CreateDeviceAndSwapChain(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            flags,
            nullptr,
            0,
            D3D11_SDK_VERSION,
            &scd,
            &g_previewSwapChain,
            &g_previewDevice,
            nullptr,
            &g_previewContext);
        if (FAILED(hr)) {
            hr = D3D11CreateDeviceAndSwapChain(
                nullptr,
                D3D_DRIVER_TYPE_WARP,
                nullptr,
                flags,
                nullptr,
                0,
                D3D11_SDK_VERSION,
                &scd,
                &g_previewSwapChain,
                &g_previewDevice,
                nullptr,
                &g_previewContext);
        }
        if (FAILED(hr)) return hr;

        ComPtr<ID3D11Texture2D> buffer;
        hr = g_previewSwapChain->GetBuffer(0, IID_PPV_ARGS(&buffer));
        if (FAILED(hr)) return hr;
        return g_previewDevice->CreateRenderTargetView(buffer.Get(), nullptr, &g_previewRtv);
    }

    HRESULT LoadPreviewShaders()
    {
        ComPtr<ID3DBlob> vsBlob;
        ComPtr<ID3DBlob> psBlob;
        HRESULT hr = D3DCompile(g_vertexShaderHlsl, strlen(g_vertexShaderHlsl), nullptr, nullptr, nullptr, "main", "vs_5_0", 0, 0, &vsBlob, nullptr);
        if (FAILED(hr)) return hr;
        hr = D3DCompile(g_pixelShaderHlsl, strlen(g_pixelShaderHlsl), nullptr, nullptr, nullptr, "main", "ps_5_0", 0, 0, &psBlob, nullptr);
        if (FAILED(hr)) return hr;
        hr = g_previewDevice->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &g_previewVs);
        if (FAILED(hr)) return hr;
        hr = g_previewDevice->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &g_previewPs);
        if (FAILED(hr)) return hr;

        D3D11_SAMPLER_DESC sd = {};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
        return g_previewDevice->CreateSamplerState(&sd, &g_previewSampler);
    }

    void CleanupPreviewD3D()
    {
        if (g_previewContext) g_previewContext->ClearState();
        g_previewSrv.Reset();
        g_previewTexture.Reset();
        g_previewSampler.Reset();
        g_previewPs.Reset();
        g_previewVs.Reset();
        g_previewRtv.Reset();
        g_previewSwapChain.Reset();
        g_previewContext.Reset();
        g_previewDevice.Reset();
    }

    void ResizePreviewBackbuffer(HWND hwnd)
    {
        if (!g_previewSwapChain || !g_previewDevice) return;
        RECT rc = {};
        GetClientRect(hwnd, &rc);
        const UINT width = static_cast<UINT>(std::max<LONG>(1, rc.right - rc.left));
        const UINT height = static_cast<UINT>(std::max<LONG>(1, rc.bottom - rc.top));
        if (g_previewContext) g_previewContext->OMSetRenderTargets(0, nullptr, nullptr);
        g_previewRtv.Reset();
        if (FAILED(g_previewSwapChain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0))) return;
        ComPtr<ID3D11Texture2D> buffer;
        if (FAILED(g_previewSwapChain->GetBuffer(0, IID_PPV_ARGS(&buffer)))) return;
        (void)g_previewDevice->CreateRenderTargetView(buffer.Get(), nullptr, &g_previewRtv);
    }

    void RenderPreviewFrame()
    {
        if (!g_preview || !g_previewDevice || !g_previewContext || !g_previewRtv) return;

        if (!g_previewSrv) {
            ComPtr<ID3D11Device1> device1;
            if (SUCCEEDED(g_previewDevice.As(&device1))) {
                HRESULT openHr = device1->OpenSharedResourceByName(
                    kBrokerTextureName,
                    DXGI_SHARED_RESOURCE_READ,
                    __uuidof(ID3D11Texture2D),
                    reinterpret_cast<void**>(g_previewTexture.GetAddressOf()));
                if (SUCCEEDED(openHr) && g_previewTexture) {
                    (void)g_previewDevice->CreateShaderResourceView(g_previewTexture.Get(), nullptr, &g_previewSrv);
                }
            }
        }

        const float clearColor[] = { 0.075f, 0.078f, 0.086f, 1.0f };
        g_previewContext->ClearRenderTargetView(g_previewRtv.Get(), clearColor);

        if (g_previewSrv) {
            RECT rc = {};
            GetClientRect(g_preview, &rc);
            D3D11_VIEWPORT vp = { 0, 0, static_cast<float>(rc.right), static_cast<float>(rc.bottom), 0, 1 };
            g_previewContext->RSSetViewports(1, &vp);
            g_previewContext->OMSetRenderTargets(1, g_previewRtv.GetAddressOf(), nullptr);
            g_previewContext->VSSetShader(g_previewVs.Get(), nullptr, 0);
            g_previewContext->PSSetShader(g_previewPs.Get(), nullptr, 0);
            g_previewContext->PSSetShaderResources(0, 1, g_previewSrv.GetAddressOf());
            g_previewContext->PSSetSamplers(0, 1, g_previewSampler.GetAddressOf());
            g_previewContext->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            g_previewContext->Draw(3, 0);
        }

        (void)g_previewSwapChain->Present(1, 0);
    }

    LRESULT CALLBACK PreviewProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
    {
        switch (message) {
        case WM_CREATE:
            ApplyModernWindowTheme(hwnd);
            if (FAILED(InitPreviewD3D(hwnd)) || FAILED(LoadPreviewShaders())) {
                SetStatusText(L"Preview unavailable: D3D initialization failed.");
            }
            return 0;
        case WM_SIZE:
            ResizePreviewBackbuffer(hwnd);
            return 0;
        case WM_DESTROY:
            CleanupPreviewD3D();
            return 0;
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam);
        }
    }

    void ResizeControls(HWND hwnd)
    {
        RECT rc = {};
        GetClientRect(hwnd, &rc);
        const int pad = 16;
        const int buttonH = 34;
        const int buttonW = 104;
        const int statusH = 28;
        const int checksH = 92;
        const int debugH = 24;
        const int buttonY = rc.bottom - pad - buttonH;
        const int debugY = buttonY - 8 - debugH;
        const int checksY = debugY - pad - checksH;
        const int statusY = checksY - 8 - statusH;
        const int previewBottom = std::max(pad + 120, statusY - pad);

        const int previewWidth = std::max(1, static_cast<int>(rc.right) - pad * 2);
        const int previewHeight = std::max(1, previewBottom - pad);
        MoveWindow(g_preview, pad, pad, previewWidth, previewHeight, TRUE);
        MoveWindow(g_status, pad, statusY, rc.right - pad * 2, statusH, TRUE);
        MoveWindow(g_checks, pad, checksY, rc.right - pad * 2, checksH, TRUE);
        MoveWindow(g_debug, pad, debugY, std::min(260, std::max(1, static_cast<int>(rc.right) - pad * 2)), debugH, TRUE);

        int x = pad;
        for (int id : { IDC_INSTALL, IDC_UNINSTALL, IDC_VERIFY, IDC_CLOSE }) {
            HWND child = GetDlgItem(hwnd, id);
            MoveWindow(child, x, buttonY, buttonW, buttonH, TRUE);
            x += buttonW + 8;
        }
    }

    void ClearChecks()
    {
        if (g_checks) {
            SendMessageW(g_checks, LB_RESETCONTENT, 0, 0);
        }
    }

    void RunUiAction(const std::wstring& mode)
    {
        ClearChecks();
        if ((mode == L"install" || mode == L"uninstall") && !IsAdministrator()) {
            if (RelaunchElevated(mode == L"install" ? L"--install" : L"--uninstall")) {
                SetStatusText(mode == L"install" ? L"Elevated install window opened." : L"Elevated uninstall window opened.");
            } else {
                SetStatusText(L"Elevation was cancelled or failed.");
            }
            return;
        }
        const SetupOptions options;
        const RunResult result = RunMode(mode, {}, options);
        SetStatusText(std::format(
            L"{} {}. Report: {}",
            mode,
            result.success ? L"succeeded" : L"failed",
            result.jsonPath.wstring()));
    }

    LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
    {
        switch (message) {
        case WM_CREATE:
        {
            ApplyModernWindowTheme(hwnd);
            g_preview = CreateWindowExW(
                0,
                kPreviewClass,
                nullptr,
                WS_CHILD | WS_VISIBLE,
                0, 0, 0, 0,
                hwnd,
                ControlId(IDC_PREVIEW),
                g_instance,
                nullptr);
            g_status = CreateWindowW(
                L"STATIC",
                L"Preview ready. Install, uninstall, or verify VirtuaCam.",
                WS_CHILD | WS_VISIBLE | SS_LEFT,
                0, 0, 0, 0,
                hwnd,
                ControlId(IDC_STATUS),
                g_instance,
                nullptr);
            g_checks = CreateWindowW(
                L"LISTBOX",
                nullptr,
                WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | WS_VSCROLL | LBS_NOINTEGRALHEIGHT,
                0, 0, 0, 0,
                hwnd,
                ControlId(IDC_CHECKS),
                g_instance,
                nullptr);
            CreateWindowW(L"BUTTON", L"&Install", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, ControlId(IDC_INSTALL), g_instance, nullptr);
            CreateWindowW(L"BUTTON", L"&Uninstall", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, ControlId(IDC_UNINSTALL), g_instance, nullptr);
            CreateWindowW(L"BUTTON", L"&Verify", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, ControlId(IDC_VERIFY), g_instance, nullptr);
            CreateWindowW(L"BUTTON", L"E&xit", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, ControlId(IDC_CLOSE), g_instance, nullptr);
            g_debug = CreateWindowW(
                L"BUTTON",
                L"&Debug next session",
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX,
                0, 0, 0, 0,
                hwnd,
                ControlId(IDC_DEBUG),
                g_instance,
                nullptr);
            SendMessageW(g_debug, BM_SETCHECK, ReadSettingsDword(L"StartDebugMode", 0) ? BST_CHECKED : BST_UNCHECKED, 0);
            for (int id : { IDC_STATUS, IDC_CHECKS, IDC_INSTALL, IDC_UNINSTALL, IDC_VERIFY, IDC_CLOSE, IDC_DEBUG }) {
                HWND child = GetDlgItem(hwnd, id);
                if (child && g_uiFont) {
                    SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(g_uiFont), TRUE);
                }
                if (child) {
                    ApplyModernWindowTheme(child);
                }
            }
            ResizeControls(hwnd);
            SetFocus(GetDlgItem(hwnd, IDC_INSTALL));
            return 0;
        }
        case WM_SIZE:
            ResizeControls(hwnd);
            return 0;
        case WM_COMMAND:
            switch (LOWORD(wParam)) {
            case IDC_INSTALL: RunUiAction(L"install"); return 0;
            case IDC_UNINSTALL: RunUiAction(L"uninstall"); return 0;
            case IDC_VERIFY: RunUiAction(L"verify-only"); return 0;
            case IDC_CLOSE: DestroyWindow(hwnd); return 0;
            case IDC_DEBUG:
            {
                const bool enabled = SendMessageW(g_debug, BM_GETCHECK, 0, 0) == BST_CHECKED;
                if (WriteSettingsDword(L"StartDebugMode", enabled ? 1 : 0)) {
                    SetStatusText(enabled ? L"Debug mode will start next session." : L"Debug mode disabled for next session.");
                } else {
                    SetStatusText(L"Could not save debug setting.");
                }
                return 0;
            }
            default: break;
            }
            break;
        case WM_CTLCOLORSTATIC:
        {
            HDC dc = reinterpret_cast<HDC>(wParam);
            SetBkColor(dc, RGB(32, 32, 36));
            SetTextColor(dc, RGB(242, 242, 242));
            return reinterpret_cast<LRESULT>(g_panelBrush);
        }
        case WM_CTLCOLORLISTBOX:
        {
            HDC dc = reinterpret_cast<HDC>(wParam);
            SetBkColor(dc, RGB(24, 24, 28));
            SetTextColor(dc, RGB(242, 242, 242));
            return reinterpret_cast<LRESULT>(g_panelBrush);
        }
        case WM_KEYDOWN:
            if (wParam == VK_ESCAPE) {
                DestroyWindow(hwnd);
                return 0;
            }
            break;
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        default:
            break;
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    int RunUi()
    {
        INITCOMMONCONTROLSEX icc = { sizeof(icc), ICC_STANDARD_CLASSES | ICC_LISTVIEW_CLASSES };
        InitCommonControlsEx(&icc);

        g_windowBrush = CreateSolidBrush(RGB(32, 32, 36));
        g_panelBrush = CreateSolidBrush(RGB(24, 24, 28));
        g_uiFont = CreateFontW(
            -16,
            0,
            0,
            0,
            FW_NORMAL,
            FALSE,
            FALSE,
            FALSE,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            DEFAULT_PITCH | FF_SWISS,
            L"Segoe UI");

        WNDCLASSEXW wc = {};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = WindowProc;
        wc.hInstance = g_instance;
        wc.hIcon = LoadIconW(g_instance, MAKEINTRESOURCEW(IDI_VIRTUACAM_SETUP));
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = g_windowBrush;
        wc.lpszClassName = kWindowClass;
        RegisterClassExW(&wc);

        WNDCLASSEXW previewClass = {};
        previewClass.cbSize = sizeof(previewClass);
        previewClass.lpfnWndProc = PreviewProc;
        previewClass.hInstance = g_instance;
        previewClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        previewClass.hbrBackground = g_panelBrush;
        previewClass.lpszClassName = kPreviewClass;
        RegisterClassExW(&previewClass);

        g_hwnd = CreateWindowExW(
            0,
            kWindowClass,
            L"VirtuaCam Setup",
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            900,
            720,
            nullptr,
            nullptr,
            g_instance,
            nullptr);
        if (!g_hwnd) {
            return 1;
        }

        ShowWindow(g_hwnd, SW_SHOWNORMAL);
        UpdateWindow(g_hwnd);

        MSG msg = {};
        for (;;) {
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
                if (msg.message == WM_QUIT) {
                    if (g_uiFont) DeleteObject(g_uiFont);
                    if (g_windowBrush) DeleteObject(g_windowBrush);
                    if (g_panelBrush) DeleteObject(g_panelBrush);
                    return static_cast<int>(msg.wParam);
                }
                if (!IsDialogMessageW(g_hwnd, &msg)) {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
            RenderPreviewFrame();
            Sleep(16);
        }
    }
}

int APIENTRY wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR, int)
{
    g_instance = hInstance;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    MFStartup(MF_VERSION);

    const std::vector<std::wstring> args = ParseArgs();
    const bool quiet = HasArg(args, L"--quiet") || HasArg(args, L"/quiet");
    const SetupOptions options = GetSetupOptions(args);
    std::wstring mode;
    if (HasArg(args, L"--verify-only") || HasArg(args, L"/verify")) mode = L"verify-only";
    if (HasArg(args, L"--install") || HasArg(args, L"/install")) mode = L"install";
    if (HasArg(args, L"--uninstall") || HasArg(args, L"/uninstall")) mode = L"uninstall";

    int exitCode = 0;
    if (!mode.empty()) {
        const RunResult result = RunMode(mode, GetJsonArg(args), options);
        exitCode = result.success ? 0 : 1;
        if (!quiet) {
            std::wstring message = std::format(
                L"{} {}\n\nReport:\n{}",
                mode,
                result.success ? L"succeeded" : L"failed",
                result.jsonPath.wstring());
            MessageBoxW(nullptr, message.c_str(), L"VirtuaCam Setup", result.success ? MB_OK | MB_ICONINFORMATION : MB_OK | MB_ICONWARNING);
        }
    } else {
        exitCode = RunUi();
    }

    MFShutdown();
    CoUninitialize();
    return exitCode;
}
