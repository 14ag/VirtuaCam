#include <windows.h>
#include <commctrl.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <shlobj.h>
#include <shellapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <format>
#include <string>
#include <vector>

#include "resource.h"

using Microsoft::WRL::ComPtr;

#pragma comment(linker,"\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

namespace
{
    constexpr wchar_t kWindowClass[] = L"VirtuaCamSetupWindow";
    constexpr wchar_t kSettingsSubkey[] = L"Software\\VirtuaCam\\Settings";

    constexpr int IDC_STATUS = 1001;
    constexpr int IDC_CHECKS = 1002;
    constexpr int IDC_VERIFY = 1003;
    constexpr int IDC_CLOSE = 1004;

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
    HWND g_status = nullptr;
    HWND g_checks = nullptr;

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

    std::filesystem::path FindRepoRoot()
    {
        std::vector<std::filesystem::path> seeds;
        seeds.push_back(std::filesystem::current_path());
        seeds.push_back(ExeDir());

        for (const auto& seed : seeds) {
            std::filesystem::path current = seed;
            for (int i = 0; i < 8 && !current.empty(); ++i) {
                if (std::filesystem::exists(current / L"scripts" / L"build-all.ps1")) {
                    return current;
                }
                if (!current.has_parent_path() || current.parent_path() == current) {
                    break;
                }
                current = current.parent_path();
            }
        }

        if (ExeDir().filename() == L"output") {
            return ExeDir().parent_path();
        }
        return ExeDir();
    }

    std::filesystem::path DefaultJsonPath(const std::wstring& mode)
    {
        SYSTEMTIME st = {};
        GetLocalTime(&st);
        std::filesystem::path dir = FindRepoRoot() / L"test-reports" / L"wizard";
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
            FindRepoRoot().c_str(),
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

    RunResult RunMode(const std::wstring& mode, const std::filesystem::path& jsonPath)
    {
        if (mode == L"verify-only") {
            return RunFirstRunChecks(mode, jsonPath);
        }
        RunResult result;
        result.mode = mode;
        result.jsonPath = jsonPath.empty() ? DefaultJsonPath(mode) : jsonPath;
        result.success = false;
        result.checks.push_back({ L"Mode", false, L"Unknown mode" });
        WriteRunJson(result);
        return result;
    }

    void ResizeControls(HWND hwnd)
    {
        RECT rc = {};
        GetClientRect(hwnd, &rc);
        const int pad = 12;
        const int buttonH = 30;
        const int buttonW = 92;
        const int statusH = 28;
        const int buttonY = rc.bottom - pad - buttonH;
        MoveWindow(g_status, pad, pad, rc.right - pad * 2, statusH, TRUE);
        MoveWindow(g_checks, pad, pad + statusH + 8, rc.right - pad * 2, buttonY - (pad + statusH + 16), TRUE);

        int x = pad;
        for (int id : { IDC_VERIFY, IDC_CLOSE }) {
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
        const RunResult result = RunMode(mode, {});
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
            g_status = CreateWindowW(
                L"STATIC",
                L"Choose verify to check the current VirtuaCam install.",
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
            CreateWindowW(L"BUTTON", L"&Verify", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, ControlId(IDC_VERIFY), g_instance, nullptr);
            CreateWindowW(L"BUTTON", L"E&xit", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, ControlId(IDC_CLOSE), g_instance, nullptr);
            ResizeControls(hwnd);
            SetFocus(GetDlgItem(hwnd, IDC_VERIFY));
            return 0;
        }
        case WM_SIZE:
            ResizeControls(hwnd);
            return 0;
        case WM_COMMAND:
            switch (LOWORD(wParam)) {
            case IDC_VERIFY: RunUiAction(L"verify-only"); return 0;
            case IDC_CLOSE: DestroyWindow(hwnd); return 0;
            default: break;
            }
            break;
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

        WNDCLASSEXW wc = {};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = WindowProc;
        wc.hInstance = g_instance;
        wc.hIcon = LoadIconW(g_instance, MAKEINTRESOURCEW(IDI_VIRTUACAM_SETUP));
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
        wc.lpszClassName = kWindowClass;
        RegisterClassExW(&wc);

        g_hwnd = CreateWindowExW(
            0,
            kWindowClass,
            L"VirtuaCam Setup",
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            640,
            420,
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
        while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
            if (!IsDialogMessageW(g_hwnd, &msg)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        return static_cast<int>(msg.wParam);
    }
}

int APIENTRY wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR, int)
{
    g_instance = hInstance;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    MFStartup(MF_VERSION);

    const std::vector<std::wstring> args = ParseArgs();
    const bool quiet = HasArg(args, L"--quiet") || HasArg(args, L"/quiet");
    std::wstring mode;
    if (HasArg(args, L"--verify-only") || HasArg(args, L"/verify")) mode = L"verify-only";

    int exitCode = 0;
    if (!mode.empty()) {
        const RunResult result = RunMode(mode, GetJsonArg(args));
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
