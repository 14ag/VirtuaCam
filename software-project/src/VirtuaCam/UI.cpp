#include "pch.h"
#include "App.h"
#include "UI.h"
#include "Tools.h"
#include "Formats.h"
#include "Discovery.h"
#include "RuntimeLog.h"
#include <dshow.h>
#include <wrl/client.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <commdlg.h>
#include <cwctype>
#include <filesystem>
#include <map>

#pragma comment(lib, "dwmapi.lib")

using namespace Microsoft::WRL;

extern const VirtuaCam::Discovery* GetGlobalDiscovery();
extern void InformBroker();
void ShutdownSystem();
extern void RequestDriverDisconnect();

extern const SourceState& GetMainSourceState();
extern void SetSourceMode(SourceMode newMode, DWORD_PTR context);
extern void SetSourceFileMode(SourceMode newMode, const std::wstring& path);

extern const SourceState& GetPipSourceState(PipPosition pos);
extern void SetPipSource(PipPosition pos, SourceMode newMode, DWORD_PTR context);
extern const wchar_t* SourceModeToString(SourceMode mode);
extern std::wstring GetRuntimeDriverStatusText();
extern std::wstring GetRuntimeAudioStatusText();

extern bool GetPipTlEnabled();
extern bool GetPipTrEnabled();
extern bool GetPipBlEnabled();
extern void TogglePipTl();
extern void TogglePipTr();
extern void TogglePipBl();
extern AspectRatioMode GetAspectRatioMode();
extern void SetAspectRatioMode(AspectRatioMode mode);
extern ULONG GetAllowedAspectRatioMask();

namespace
{
    const GUID kDriverPropertySet = { 0xcb043957, 0x7b35, 0x456e, { 0x9b, 0x61, 0x55, 0x13, 0x93, 0x0f, 0x4d, 0x8e } };
    constexpr ULONG kDriverPropertyId = 0;

    bool ContainsNoCase(const std::wstring& value, const wchar_t* needle)
    {
        if (!needle || !*needle) return true;
        std::wstring haystack = value;
        std::wstring target = needle;
        std::transform(haystack.begin(), haystack.end(), haystack.begin(), [](wchar_t ch) {
            return static_cast<wchar_t>(towlower(ch));
        });
        std::transform(target.begin(), target.end(), target.begin(), [](wchar_t ch) {
            return static_cast<wchar_t>(towlower(ch));
        });
        return haystack.find(target) != std::wstring::npos;
    }

    bool IsVirtuaCamVideoSource(const std::wstring& name, const std::wstring& link)
    {
        return ContainsNoCase(name, L"VirtuaCam") ||
            ContainsNoCase(name, L"Virtual Camera Driver") ||
            ContainsNoCase(link, L"VirtuaCam") ||
            ContainsNoCase(link, L"avshws");
    }

    std::filesystem::path RepoRootFromExeDir()
    {
        std::filesystem::path exeDir = VirtuaCamLog::GetExeDir();
        if (exeDir.filename() == L"output") {
            return exeDir.parent_path();
        }
        return exeDir;
    }

    void ShellOpenPath(const std::filesystem::path& path)
    {
        ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }

    void RunPowerShellScript(const std::filesystem::path& scriptPath, const wchar_t* extraArgs = nullptr)
    {
        if (!std::filesystem::exists(scriptPath)) {
            VirtuaCamLog::LogLine(std::format(L"Advanced tool missing: {}", scriptPath.wstring()));
            MessageBoxW(nullptr, scriptPath.c_str(), L"VirtuaCam tool missing", MB_OK | MB_ICONWARNING);
            return;
        }

        std::wstring args = std::format(
            L"-NoProfile -ExecutionPolicy Bypass -File \"{}\"",
            scriptPath.wstring());
        if (extraArgs && extraArgs[0] != L'\0') {
            args += L" ";
            args += extraArgs;
        }
        ShellExecuteW(nullptr, L"open", L"powershell.exe", args.c_str(), RepoRootFromExeDir().c_str(), SW_SHOWNORMAL);
    }

    bool IsDriverOutputCamera(IMoniker* moniker)
    {
        if (!moniker) {
            return false;
        }

        ComPtr<IBaseFilter> filter;
        if (FAILED(moniker->BindToObject(nullptr, nullptr, IID_PPV_ARGS(&filter))) || !filter) {
            return false;
        }

        ComPtr<IKsPropertySet> propertySet;
        if (FAILED(filter->QueryInterface(IID_PPV_ARGS(&propertySet))) || !propertySet) {
            return false;
        }

        DWORD supportFlags = 0;
        return SUCCEEDED(propertySet->QuerySupported(kDriverPropertySet, kDriverPropertyId, &supportFlags)) &&
            ((supportFlags & KSPROPERTY_SUPPORT_SET) == KSPROPERTY_SUPPORT_SET);
    }
}

BOOL CALLBACK EnumWindowsProc(HWND hwnd, LPARAM lParam) {
    auto* windows = reinterpret_cast<std::vector<CapturableWindow>*>(lParam);
    if (!windows) {
        return TRUE;
    }
    if (!IsWindowVisible(hwnd) || GetWindowTextLength(hwnd) == 0 || (GetWindowLong(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) {
        return TRUE;
    }
    BOOL isCloaked = FALSE;
    DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &isCloaked, sizeof(isCloaked));
    if (isCloaked) return TRUE;

    wchar_t title[256];
    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    windows->push_back({ hwnd, title });
    return TRUE;
}
std::vector<CapturableWindow> EnumerateWindows() {
    std::vector<CapturableWindow> result;
    EnumWindows(EnumWindowsProc, reinterpret_cast<LPARAM>(&result));
    return result;
}

BOOL CALLBACK EnumDisplayProc(HMONITOR monitor, HDC, LPRECT rect, LPARAM lParam)
{
    auto* displays = reinterpret_cast<std::vector<CapturableDisplay>*>(lParam);
    if (!displays || !rect) {
        return TRUE;
    }

    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, &info)) {
        return TRUE;
    }

    const int index = static_cast<int>(displays->size());
    std::wstring name = L"Display " + std::to_wstring(index + 1);
    if (info.szDevice[0] != L'\0') {
        name += L" (";
        name += info.szDevice;
        name += L")";
    }
    if ((info.dwFlags & MONITORINFOF_PRIMARY) != 0) {
        name += L" Primary";
    }

    displays->push_back({ index, name, *rect, (info.dwFlags & MONITORINFOF_PRIMARY) != 0 });
    return TRUE;
}

std::vector<CapturableDisplay> EnumerateDisplays()
{
    std::vector<CapturableDisplay> displays;
    EnumDisplayMonitors(nullptr, nullptr, EnumDisplayProc, reinterpret_cast<LPARAM>(&displays));
    return displays;
}

std::vector<std::wstring> EnumerateCameras() {
    std::vector<std::wstring> cameraNames;
    // Keep a parallel list of device paths so the app can launch camera producers
    // using a stable identifier.
    extern std::vector<std::wstring> g_cameraDevicePaths;
    extern std::vector<std::wstring> g_cameraDeviceNamesCache;
    g_cameraDevicePaths.clear();
    g_cameraDeviceNamesCache.clear();

    ComPtr<IMFAttributes> attributes;
    if (FAILED(MFCreateAttributes(&attributes, 1))) {
        return cameraNames;
    }
    if (FAILED(attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID))) {
        return cameraNames;
    }

    UINT32 count = 0;
    IMFActivate** devices = nullptr;
    HRESULT hr = MFEnumDeviceSources(attributes.Get(), &devices, &count);
    if (FAILED(hr) || !devices || count == 0) {
        if (devices) CoTaskMemFree(devices);
        return cameraNames;
    }

    for (UINT32 i = 0; i < count; ++i) {
        wil::unique_cotaskmem_string friendlyName;
        wil::unique_cotaskmem_string symbolicLink;
        if (!devices[i]) {
            continue;
        }

        (void)devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendlyName, nullptr);
        (void)devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &symbolicLink, nullptr);

        std::wstring name = friendlyName.get() ? friendlyName.get() : L"Video Capture Device";
        std::wstring link = symbolicLink.get() ? symbolicLink.get() : L"";
        if (IsVirtuaCamVideoSource(name, link)) {
            continue;
        }

        cameraNames.push_back(name);
        g_cameraDeviceNamesCache.push_back(name);
        g_cameraDevicePaths.push_back(link);
    }

    for (UINT32 i = 0; i < count; ++i) {
        if (devices[i]) {
            devices[i]->Release();
        }
    }
    CoTaskMemFree(devices);

    return cameraNames;
}

static HINSTANCE g_instance;
static HWND g_hMainWnd = NULL;
static WCHAR g_windowClass[MAX_LOADSTRING];
static std::function<void(int)> g_audioSelectionCallback;
static std::vector<std::wstring> g_captureDeviceNames;
std::vector<std::wstring> g_cameraDevicePaths;
std::vector<std::wstring> g_cameraDeviceNamesCache;
static int g_currentAudioDevice = ID_AUDIO_DEVICE_NONE;
static bool g_debugUiEnabled = false;
static std::function<void()> g_onIdle;
static BrokerState g_lastBrokerState = (BrokerState)-1;
static bool g_lastDriverConnected = false;

static std::map<UINT, HWND> g_mainSourceWindowMap;
static std::map<UINT, HWND> g_pipTlWindowMap;
static std::map<UINT, HWND> g_pipTrWindowMap;
static std::map<UINT, HWND> g_pipBlWindowMap;
static std::map<UINT, HWND> g_pipWindowMap;

enum class PreferredAppMode
{
    Default,
    AllowDark,
    ForceDark,
    ForceLight,
    Max
};

using AllowDarkModeForWindowFn = BOOL(WINAPI*)(HWND, BOOL);
using SetPreferredAppModeFn = PreferredAppMode(WINAPI*)(PreferredAppMode);
using FlushMenuThemesFn = void(WINAPI*)();
using SetWindowThemeFn = HRESULT(WINAPI*)(HWND, LPCWSTR, LPCWSTR);

void EnableNativeDarkMenus(HWND hwnd)
{
    static bool initialized = false;
    static AllowDarkModeForWindowFn allowDarkModeForWindow = nullptr;
    static SetPreferredAppModeFn setPreferredAppMode = nullptr;
    static FlushMenuThemesFn flushMenuThemes = nullptr;
    static SetWindowThemeFn setWindowTheme = nullptr;

    if (!initialized) {
        initialized = true;
        HMODULE uxtheme = LoadLibraryW(L"uxtheme.dll");
        if (uxtheme) {
            allowDarkModeForWindow = reinterpret_cast<AllowDarkModeForWindowFn>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(133)));
            setPreferredAppMode = reinterpret_cast<SetPreferredAppModeFn>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)));
            flushMenuThemes = reinterpret_cast<FlushMenuThemesFn>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(136)));
            setWindowTheme = reinterpret_cast<SetWindowThemeFn>(GetProcAddress(uxtheme, "SetWindowTheme"));
        }
        if (setPreferredAppMode) {
            setPreferredAppMode(PreferredAppMode::AllowDark);
        }
        if (flushMenuThemes) {
            flushMenuThemes();
        }
    }

    if (hwnd && allowDarkModeForWindow) {
        allowDarkModeForWindow(hwnd, TRUE);
    }
    if (hwnd && setWindowTheme) {
        setWindowTheme(hwnd, L"DarkMode_Explorer", nullptr);
    }
}

LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
INT_PTR CALLBACK About(HWND, UINT, WPARAM, LPARAM);
void AddTrayIcon(HWND hwnd, bool add);
void UpdateTrayTooltip(BrokerState brokerState, bool driverConnected);
std::wstring BrokerStateText(BrokerState brokerState);
std::wstring SourceSummaryText(const SourceState& state, BrokerState brokerState);
std::wstring BuildSupportStatusText(BrokerState brokerState, bool driverConnected);
void ShowContextMenu(HWND hwnd);
void HandleMenuCommand(UINT id);
ATOM MyRegisterClass(HINSTANCE instance);
bool SelectSourceFile(HWND owner, bool video, std::wstring& outPath);

void UI_Initialize(HINSTANCE instance, HWND& outMainWnd) {
    g_instance = instance;
    LoadStringW(instance, IDC_VIRTUACAM, g_windowClass, MAX_LOADSTRING);
    MyRegisterClass(instance);

    g_hMainWnd = CreateWindowEx(
        0,
        g_windowClass,
        L"VirtuaCam Message Window",
        0, 0, 0, 0, 0,
        HWND_MESSAGE,
        nullptr,
        instance,
        nullptr
    );

    if (g_hMainWnd) {
        AddTrayIcon(g_hMainWnd, true);
    }
    outMainWnd = g_hMainWnd;
}

void UI_SetDebugMode(bool enabled)
{
    g_debugUiEnabled = enabled;
}

void UI_RunMessageLoop(std::function<void()> onIdle) {
    g_onIdle = onIdle;
    MSG msg = {};
    while (msg.message != WM_QUIT) {
        if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        } else {
            if (g_onIdle) g_onIdle();
            Sleep(10);
        }
    }
}

void UI_Shutdown() {
    AddTrayIcon(g_hMainWnd, false);
}

void UI_UpdateAudioDeviceLists(const std::vector<std::wstring>& captureDevices) {
    g_captureDeviceNames = captureDevices;
}

void UI_SetAudioSelectionCallback(std::function<void(int)> callback) {
    g_audioSelectionCallback = callback;
}

void UI_SetCurrentAudioDeviceId(int id)
{
    g_currentAudioDevice = id;
}

int UI_GetCurrentAudioDeviceId()
{
    return g_currentAudioDevice;
}

std::vector<std::wstring> UI_RefreshCameraDeviceList()
{
    return EnumerateCameras();
}

const wchar_t* UI_GetCameraDevicePath(int index)
{
    if (index < 0 || static_cast<size_t>(index) >= g_cameraDevicePaths.size()) {
        return nullptr;
    }
    if (g_cameraDevicePaths[index].empty()) {
        return nullptr;
    }
    return g_cameraDevicePaths[index].c_str();
}

const wchar_t* UI_GetCameraDeviceName(int index)
{
    if (index < 0 || static_cast<size_t>(index) >= g_cameraDeviceNamesCache.size()) {
        return nullptr;
    }
    return g_cameraDeviceNamesCache[index].c_str();
}

ATOM MyRegisterClass(HINSTANCE instance) {
    WNDCLASSEXW wcex = {};
    wcex.cbSize = sizeof(WNDCLASSEX); wcex.lpfnWndProc = WndProc;
    wcex.hInstance = instance; wcex.lpszClassName = g_windowClass;
    wcex.hIcon = LoadIcon(instance, MAKEINTRESOURCE(IDI_VIRTUACAM));
    wcex.hIconSm = LoadIcon(instance, MAKEINTRESOURCE(IDI_SMALL));
    return RegisterClassExW(&wcex);
}

void HandlePipCommand(PipPosition pos, UINT id) {
    const auto* discovery = GetGlobalDiscovery();
    const auto& streams = discovery ? discovery->GetDiscoveredStreams() : std::vector<VirtuaCam::DiscoveredSharedStream>();
    int streamIndex;

    switch (pos) {
    case PipPosition::TL:
        if (id >= ID_PIP_TL_DISCOVERED_FIRST) {
            streamIndex = id - ID_PIP_TL_DISCOVERED_FIRST;
            if (streamIndex >= 0 && (size_t)streamIndex < streams.size()) SetPipSource(pos, SourceMode::Discovered, streams[streamIndex].processId);
        } else if (id >= ID_PIP_TL_WINDOW_FIRST) {
            if (g_pipTlWindowMap.count(id)) SetPipSource(pos, SourceMode::Window, reinterpret_cast<DWORD_PTR>(g_pipTlWindowMap[id]));
        } else if (id >= ID_PIP_TL_CAMERA_FIRST) {
            SetPipSource(pos, SourceMode::Camera, id - ID_PIP_TL_CAMERA_FIRST);
        } else if (id == ID_PIP_TL_OFF) {
            SetPipSource(pos, SourceMode::Off, 0);
        }
        break;

    case PipPosition::TR:
        if (id >= ID_PIP_TR_DISCOVERED_FIRST) {
            streamIndex = id - ID_PIP_TR_DISCOVERED_FIRST;
            if (streamIndex >= 0 && (size_t)streamIndex < streams.size()) SetPipSource(pos, SourceMode::Discovered, streams[streamIndex].processId);
        } else if (id >= ID_PIP_TR_WINDOW_FIRST) {
            if (g_pipTrWindowMap.count(id)) SetPipSource(pos, SourceMode::Window, reinterpret_cast<DWORD_PTR>(g_pipTrWindowMap[id]));
        } else if (id >= ID_PIP_TR_CAMERA_FIRST) {
            SetPipSource(pos, SourceMode::Camera, id - ID_PIP_TR_CAMERA_FIRST);
        } else if (id == ID_PIP_TR_OFF) {
            SetPipSource(pos, SourceMode::Off, 0);
        }
        break;

    case PipPosition::BL:
        if (id >= ID_PIP_BL_DISCOVERED_FIRST) {
            streamIndex = id - ID_PIP_BL_DISCOVERED_FIRST;
            if (streamIndex >= 0 && (size_t)streamIndex < streams.size()) SetPipSource(pos, SourceMode::Discovered, streams[streamIndex].processId);
        } else if (id >= ID_PIP_BL_WINDOW_FIRST) {
            if (g_pipBlWindowMap.count(id)) SetPipSource(pos, SourceMode::Window, reinterpret_cast<DWORD_PTR>(g_pipBlWindowMap[id]));
        } else if (id >= ID_PIP_BL_CAMERA_FIRST) {
            SetPipSource(pos, SourceMode::Camera, id - ID_PIP_BL_CAMERA_FIRST);
        } else if (id == ID_PIP_BL_OFF) {
            SetPipSource(pos, SourceMode::Off, 0);
        }
        break;

    case PipPosition::BR:
        if (id >= ID_PIP_DISCOVERED_FIRST) {
            streamIndex = id - ID_PIP_DISCOVERED_FIRST;
            if (streamIndex >= 0 && (size_t)streamIndex < streams.size()) SetPipSource(pos, SourceMode::Discovered, streams[streamIndex].processId);
        } else if (id >= ID_PIP_WINDOW_FIRST) {
            if (g_pipWindowMap.count(id)) SetPipSource(pos, SourceMode::Window, reinterpret_cast<DWORD_PTR>(g_pipWindowMap[id]));
        } else if (id >= ID_PIP_CAMERA_FIRST) {
            SetPipSource(pos, SourceMode::Camera, id - ID_PIP_CAMERA_FIRST);
        } else if (id == ID_PIP_OFF) {
            SetPipSource(pos, SourceMode::Off, 0);
        }
        break;
    }
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_TIMER:
        if (wParam == 1) InformBroker();
        break;
    case WM_APP_TRAY_MSG:
        if (lParam == WM_RBUTTONUP || lParam == WM_CONTEXTMENU ||
            lParam == WM_LBUTTONUP || lParam == NIN_SELECT || lParam == WM_LBUTTONDBLCLK) {
            ShowContextMenu(hwnd);
        }
        break;
    case WM_APP_MENU_COMMAND:
    {
        UINT id = (UINT)wParam;
        HandleMenuCommand(id);
        break;
    }
    case WM_QUERYENDSESSION:
        RequestDriverDisconnect();
        return TRUE;
    case WM_ENDSESSION:
        if (wParam) {
            RequestDriverDisconnect();
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        break;
    default:
        return DefWindowProc(hwnd, message, wParam, lParam);
    }
    return 0;
}

void HandleMenuCommand(UINT id)
{
    if (id == 0) {
        return;
    }

    if (id == ID_TRAY_PREVIEW_WINDOW) CreatePreviewWindow();
    else if (id == ID_TRAY_ABOUT) {
        MessageBoxW(g_hMainWnd, BuildSupportStatusText(g_lastBrokerState, g_lastDriverConnected).c_str(), L"About VirtuaCam", MB_OK | MB_ICONINFORMATION);
    }
    else if (id == ID_TRAY_OPEN_LOGS) {
        const std::filesystem::path logPath = VirtuaCamLog::GetLogPath();
        ShellOpenPath(logPath.empty() ? std::filesystem::path(VirtuaCamLog::GetExeDir()) : logPath.parent_path());
    }
    else if (id == ID_TRAY_EXIT) {
        RequestDriverDisconnect();
        DestroyWindow(g_hMainWnd);
    }
    else if (id == ID_ADV_OPEN_LOG_DIR) {
        const std::filesystem::path logPath = VirtuaCamLog::GetLogPath();
        ShellOpenPath(logPath.empty() ? std::filesystem::path(VirtuaCamLog::GetExeDir()) : logPath.parent_path());
    }
    else if (id == ID_ADV_RUN_HOST_PROOF) {
        RunPowerShellScript(RepoRootFromExeDir() / L"scripts" / L"host-media-capture-auto-proof.ps1");
    }
    else if (id == ID_ADV_RUN_VM_VERIFIER_PROOF) {
        RunPowerShellScript(RepoRootFromExeDir() / L"scripts" / L"hyperv-proof-chrome.ps1", L"-EnableVerifier");
    }
    else if (id == ID_ADV_RUN_SETUP_VERIFY) {
        CreatePreviewWindow();
    }
    else if (id == ID_SETTINGS_PIP_TL) TogglePipTl();
    else if (id == ID_SETTINGS_PIP_TR) TogglePipTr();
    else if (id == ID_SETTINGS_PIP_BL) TogglePipBl();
    else if (id == ID_ASPECT_RATIO_16_9) SetAspectRatioMode(AspectRatioMode::R16_9);
    else if (id == ID_ASPECT_RATIO_9_16) SetAspectRatioMode(AspectRatioMode::R9_16);
    else if (id == ID_ASPECT_RATIO_4_3) SetAspectRatioMode(AspectRatioMode::R4_3);
    else if (id == ID_ASPECT_RATIO_3_4) SetAspectRatioMode(AspectRatioMode::R3_4);
    else if (id == ID_SOURCE_IMAGE_FILE || id == ID_SOURCE_VIDEO_FILE) {
        std::wstring path;
        const bool video = id == ID_SOURCE_VIDEO_FILE;
        if (SelectSourceFile(g_hMainWnd, video, path)) {
            SetSourceFileMode(video ? SourceMode::Video : SourceMode::Image, path);
        }
    }
    else if (id >= ID_PIP_OFF) HandlePipCommand(PipPosition::BR, id);
    else if (id >= ID_PIP_BL_OFF) HandlePipCommand(PipPosition::BL, id);
    else if (id >= ID_PIP_TR_OFF) HandlePipCommand(PipPosition::TR, id);
    else if (id >= ID_PIP_TL_OFF) HandlePipCommand(PipPosition::TL, id);
    else if (id >= ID_SOURCE_OFF) {
        if (id == ID_SOURCE_OFF) SetSourceMode(SourceMode::Off, 0);
        else if (id >= ID_SOURCE_CAMERA_FIRST && id < ID_SOURCE_DISPLAY_FIRST) {
            SetSourceMode(SourceMode::Camera, id - ID_SOURCE_CAMERA_FIRST);
        }
        else if (id >= ID_SOURCE_DISPLAY_FIRST && id < ID_SOURCE_WINDOW_FIRST) {
            SetSourceMode(SourceMode::Display, id - ID_SOURCE_DISPLAY_FIRST);
        }
        else if (id >= ID_SOURCE_WINDOW_FIRST && id < ID_SOURCE_DISCOVERED_FIRST) {
            if (g_mainSourceWindowMap.count(id)) {
                SetSourceMode(SourceMode::Window, reinterpret_cast<DWORD_PTR>(g_mainSourceWindowMap[id]));
            }
        }
        else if (id >= ID_SOURCE_DISCOVERED_FIRST) {
            const auto* discovery = GetGlobalDiscovery();
            if (discovery) {
                int index = id - ID_SOURCE_DISCOVERED_FIRST;
                const auto& streams = discovery->GetDiscoveredStreams();
                if (index >= 0 && (size_t)index < streams.size()) {
                    SetSourceMode(SourceMode::Discovered, streams[index].processId);
                }
            }
        }
    }
    else if (id >= ID_AUDIO_DEVICE_NONE) {
        g_currentAudioDevice = id;
        if (g_audioSelectionCallback) g_audioSelectionCallback(id);
    }
}

void AddNativeMenuItem(HMENU menu, const std::wstring& text, UINT id, bool checked = false, bool enabled = true)
{
    UINT flags = MF_STRING;
    if (checked) flags |= MF_CHECKED;
    if (!enabled) flags |= MF_GRAYED;
    AppendMenuW(menu, flags, id, text.c_str());
}

void AddNativeSeparator(HMENU menu)
{
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
}

bool SelectSourceFile(HWND owner, bool video, std::wstring& outPath)
{
    outPath.clear();
    wchar_t fileName[MAX_PATH] = {};
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFile = fileName;
    ofn.nMaxFile = ARRAYSIZE(fileName);
    ofn.lpstrTitle = video ? L"Select video source" : L"Select image source";
    ofn.lpstrFilter = video
        ? L"Video Files\0*.mp4;*.mov;*.mkv;*.avi;*.wmv;*.webm\0All Files\0*.*\0"
        : L"Image Files\0*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff\0All Files\0*.*\0";
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&ofn)) {
        return false;
    }
    outPath = fileName;
    return !outPath.empty();
}

HMENU BuildMainVideoSourceSubMenu(
    const std::vector<std::wstring>& cameras,
    const std::vector<CapturableWindow>& windows,
    const std::vector<CapturableDisplay>& displays)
{
    HMENU subMenu = CreatePopupMenu();
    if (!subMenu) return nullptr;

    const SourceState& state = GetMainSourceState();
    g_mainSourceWindowMap.clear();

    AddNativeMenuItem(subMenu, L"Off", ID_SOURCE_OFF, state.mode == SourceMode::Off);
    AddNativeSeparator(subMenu);

    AddNativeMenuItem(subMenu, L"Windows and Games", 0, false, false);
    for (size_t i = 0; i < windows.size() && i < (ID_SOURCE_DISCOVERED_FIRST - ID_SOURCE_WINDOW_FIRST); ++i) {
        UINT menuId = ID_SOURCE_WINDOW_FIRST + (UINT)i;
        g_mainSourceWindowMap[menuId] = windows[i].hwnd;
        std::wstring title = windows[i].title;
        if (title.length() > 48) title = title.substr(0, 45) + L"...";
        AddNativeMenuItem(subMenu, title, menuId, state.mode == SourceMode::Window && state.hwnd == windows[i].hwnd);
    }

    AddNativeSeparator(subMenu);
    AddNativeMenuItem(subMenu, L"Displays", 0, false, false);
    for (size_t i = 0; i < displays.size() && i < 100; ++i) {
        std::wstring name = displays[i].name;
        if (name.length() > 48) name = name.substr(0, 45) + L"...";
        AddNativeMenuItem(subMenu, name, ID_SOURCE_DISPLAY_FIRST + (UINT)i, state.mode == SourceMode::Display && state.displayIndex == (int)i);
    }

    AddNativeSeparator(subMenu);
    AddNativeMenuItem(subMenu, L"Video Capture Devices", 0, false, false);
    for (size_t i = 0; i < cameras.size() && i < (ID_SOURCE_DISPLAY_FIRST - ID_SOURCE_CAMERA_FIRST); ++i) {
        std::wstring name = cameras[i];
        if (name.length() > 48) name = name.substr(0, 45) + L"...";
        AddNativeMenuItem(subMenu, name, ID_SOURCE_CAMERA_FIRST + (UINT)i, state.mode == SourceMode::Camera && state.cameraIndex == (int)i);
    }

    AddNativeSeparator(subMenu);
    AddNativeMenuItem(subMenu, L"Files", 0, false, false);
    AddNativeMenuItem(subMenu, L"Image...", ID_SOURCE_IMAGE_FILE, state.mode == SourceMode::Image);
    AddNativeMenuItem(subMenu, L"Video...", ID_SOURCE_VIDEO_FILE, state.mode == SourceMode::Video);

    const auto* discovery = GetGlobalDiscovery();
    if (discovery && !discovery->GetDiscoveredStreams().empty()) {
        AddNativeSeparator(subMenu);
        AddNativeMenuItem(subMenu, L"DirectPort Streams", 0, false, false);
        size_t count = 0;
        for (size_t i = 0; i < discovery->GetDiscoveredStreams().size() && i < (ID_SOURCE_IMAGE_FILE - ID_SOURCE_DISCOVERED_FIRST); ++i) {
            const auto& stream = discovery->GetDiscoveredStreams()[i];
            if (stream.processName == L"VirtuaCamProcess.exe") {
                continue;
            }
            std::wstring label = stream.processName + L" (PID: " + std::to_wstring(stream.processId) + L")";
            if (label.length() > 48) label = label.substr(0, 45) + L"...";
            AddNativeMenuItem(subMenu, label, ID_SOURCE_DISCOVERED_FIRST + (UINT)i, state.mode == SourceMode::Discovered && state.pid == stream.processId);
            ++count;
        }
    }
    return subMenu;
}

HMENU BuildSourceSubMenu(
    const std::vector<std::wstring>& cameras,
    const std::vector<CapturableWindow>& windows,
    bool isPip,
    PipPosition pos = PipPosition::BR) {
    HMENU subMenu = CreatePopupMenu();
    if (!subMenu) return nullptr;

    UINT id_off, id_camera_first, id_window_first, id_discovered_first;
    std::map<UINT, HWND>* windowMap = nullptr;
    const SourceState* state = nullptr;

    if (!isPip) {
        id_off = ID_SOURCE_OFF; id_camera_first = ID_SOURCE_CAMERA_FIRST;
        id_window_first = ID_SOURCE_WINDOW_FIRST; id_discovered_first = ID_SOURCE_DISCOVERED_FIRST;
        windowMap = &g_mainSourceWindowMap; state = &GetMainSourceState();
    }
    else {
        switch (pos) {
        case PipPosition::TL:
            id_off = ID_PIP_TL_OFF; id_camera_first = ID_PIP_TL_CAMERA_FIRST;
            id_window_first = ID_PIP_TL_WINDOW_FIRST; id_discovered_first = ID_PIP_TL_DISCOVERED_FIRST;
            windowMap = &g_pipTlWindowMap; state = &GetPipSourceState(PipPosition::TL);
            break;
        case PipPosition::TR:
            id_off = ID_PIP_TR_OFF; id_camera_first = ID_PIP_TR_CAMERA_FIRST;
            id_window_first = ID_PIP_TR_WINDOW_FIRST; id_discovered_first = ID_PIP_TR_DISCOVERED_FIRST;
            windowMap = &g_pipTrWindowMap; state = &GetPipSourceState(PipPosition::TR);
            break;
        case PipPosition::BL:
            id_off = ID_PIP_BL_OFF; id_camera_first = ID_PIP_BL_CAMERA_FIRST;
            id_window_first = ID_PIP_BL_WINDOW_FIRST; id_discovered_first = ID_PIP_BL_DISCOVERED_FIRST;
            windowMap = &g_pipBlWindowMap; state = &GetPipSourceState(PipPosition::BL);
            break;
        case PipPosition::BR:
            id_off = ID_PIP_OFF; id_camera_first = ID_PIP_CAMERA_FIRST;
            id_window_first = ID_PIP_WINDOW_FIRST; id_discovered_first = ID_PIP_DISCOVERED_FIRST;
            windowMap = &g_pipWindowMap; state = &GetPipSourceState(PipPosition::BR);
            break;
        }
    }

    windowMap->clear();

    AddNativeMenuItem(subMenu, L"Off", id_off, state->mode == SourceMode::Off);
    AddNativeSeparator(subMenu);

    if (!cameras.empty()) {
        AddNativeMenuItem(subMenu, L"Video Capture Devices", 0, false, false);
        for (size_t i = 0; i < cameras.size(); ++i) {
            std::wstring name = cameras[i];
            if (name.length() > 32) name = name.substr(0, 29) + L"...";
            AddNativeMenuItem(subMenu, name, id_camera_first + (UINT)i, state->mode == SourceMode::Camera && state->cameraIndex == (int)i);
        }
        AddNativeSeparator(subMenu);
    }

    if (!windows.empty()) {
        AddNativeMenuItem(subMenu, L"Windows and Games", 0, false, false);
        for (size_t i = 0; i < windows.size() && i < (ID_SOURCE_DISCOVERED_FIRST - ID_SOURCE_WINDOW_FIRST); ++i) {
            UINT menuId = id_window_first + (UINT)i;
            (*windowMap)[menuId] = windows[i].hwnd;
            std::wstring title = windows[i].title;
            if (title.length() > 32) title = title.substr(0, 29) + L"...";
            AddNativeMenuItem(subMenu, title, menuId, state->mode == SourceMode::Window && state->hwnd == windows[i].hwnd);
        }
    }

    const auto* discovery = GetGlobalDiscovery();
    if (discovery && !discovery->GetDiscoveredStreams().empty()) {
        bool separatorAdded = false;
        int discoveredCount = 0;
        constexpr size_t discoveredLimit = 500;
        for (size_t i = 0; i < discovery->GetDiscoveredStreams().size() && i < discoveredLimit; ++i) {
            const auto& stream = discovery->GetDiscoveredStreams()[i];
            if (stream.processName != L"VirtuaCamProcess.exe") {
                if (!separatorAdded) {
                    if (!windows.empty()) {
                        AddNativeSeparator(subMenu);
                    }
                    AddNativeMenuItem(subMenu, L"DirectPort Streams", 0, false, false);
                    separatorAdded = true;
                }
                std::wstring label = stream.processName + L" (PID: " + std::to_wstring(stream.processId) + L")";
                if (label.length() > 32) label = label.substr(0, 29) + L"...";
                AddNativeMenuItem(subMenu, label, id_discovered_first + (UINT)i, state->mode == SourceMode::Discovered && state->pid == stream.processId);
                discoveredCount++;
            }
        }
    }

    return subMenu;
}

void ShowContextMenu(HWND hwnd) {
    POINT pt; GetCursorPos(&pt);
    SetCursor(LoadCursor(nullptr, IDC_ARROW));
    EnableNativeDarkMenus(hwnd);

    const auto cameras = UI_RefreshCameraDeviceList();
    const auto windows = EnumerateWindows();
    const auto displays = EnumerateDisplays();

    HMENU menu = CreatePopupMenu();
    if (!menu) return;

    AddNativeMenuItem(menu, L"Show Preview", ID_TRAY_PREVIEW_WINDOW);

    HMENU sourceMenu = BuildMainVideoSourceSubMenu(cameras, windows, displays);
    if (sourceMenu) AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(sourceMenu), L"Video Source");

    HMENU audioSubMenu = CreatePopupMenu();
    if (audioSubMenu) {
        AddNativeMenuItem(audioSubMenu, L"Auto", ID_AUDIO_DEVICE_AUTO, g_currentAudioDevice == ID_AUDIO_DEVICE_AUTO);
        AddNativeMenuItem(audioSubMenu, L"None", ID_AUDIO_DEVICE_NONE, g_currentAudioDevice == ID_AUDIO_DEVICE_NONE);
        if (!g_captureDeviceNames.empty()) {
            AddNativeSeparator(audioSubMenu);
            for (size_t i = 0; i < g_captureDeviceNames.size(); ++i) {
                UINT id = ID_AUDIO_CAPTURE_FIRST + (UINT)i;
                AddNativeMenuItem(audioSubMenu, g_captureDeviceNames[i], id, g_currentAudioDevice == id);
            }
        }
        AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(audioSubMenu), L"Audio Source");
    }

    HMENU aspectMenuTop = CreatePopupMenu();
    if (aspectMenuTop) {
        const AspectRatioMode currentAspect = GetAspectRatioMode();
        const ULONG allowedAspectMask = GetAllowedAspectRatioMask();
        AddNativeMenuItem(aspectMenuTop, L"16:9", ID_ASPECT_RATIO_16_9, currentAspect == AspectRatioMode::R16_9, (allowedAspectMask & ASPECT_RATIO_MASK_16_9) != 0);
        AddNativeMenuItem(aspectMenuTop, L"9:16", ID_ASPECT_RATIO_9_16, currentAspect == AspectRatioMode::R9_16, (allowedAspectMask & ASPECT_RATIO_MASK_9_16) != 0);
        AddNativeMenuItem(aspectMenuTop, L"4:3", ID_ASPECT_RATIO_4_3, currentAspect == AspectRatioMode::R4_3, (allowedAspectMask & ASPECT_RATIO_MASK_4_3) != 0);
        AddNativeMenuItem(aspectMenuTop, L"3:4", ID_ASPECT_RATIO_3_4, currentAspect == AspectRatioMode::R3_4, (allowedAspectMask & ASPECT_RATIO_MASK_3_4) != 0);
        AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(aspectMenuTop), L"Aspect Ratio");
    }

    if (g_debugUiEnabled) {
        HMENU advancedMenu = CreatePopupMenu();
        if (advancedMenu) {
            if (GetPipTlEnabled()) {
                HMENU pipMenu = BuildSourceSubMenu(cameras, windows, true, PipPosition::TL);
                if (pipMenu) AppendMenuW(advancedMenu, MF_POPUP, reinterpret_cast<UINT_PTR>(pipMenu), L"PIP (Top Left)");
            }
            if (GetPipTrEnabled()) {
                HMENU pipMenu = BuildSourceSubMenu(cameras, windows, true, PipPosition::TR);
                if (pipMenu) AppendMenuW(advancedMenu, MF_POPUP, reinterpret_cast<UINT_PTR>(pipMenu), L"PIP (Top Right)");
            }
            if (GetPipBlEnabled()) {
                HMENU pipMenu = BuildSourceSubMenu(cameras, windows, true, PipPosition::BL);
                if (pipMenu) AppendMenuW(advancedMenu, MF_POPUP, reinterpret_cast<UINT_PTR>(pipMenu), L"PIP (Bottom Left)");
            }

            HMENU pipMenu = BuildSourceSubMenu(cameras, windows, true, PipPosition::BR);
            if (pipMenu) AppendMenuW(advancedMenu, MF_POPUP, reinterpret_cast<UINT_PTR>(pipMenu), L"Picture-in-Picture");

            AddNativeSeparator(advancedMenu);
            AddNativeMenuItem(advancedMenu, L"PIP Top Left", ID_SETTINGS_PIP_TL, GetPipTlEnabled());
            AddNativeMenuItem(advancedMenu, L"PIP Top Right", ID_SETTINGS_PIP_TR, GetPipTrEnabled());
            AddNativeMenuItem(advancedMenu, L"PIP Bottom Left", ID_SETTINGS_PIP_BL, GetPipBlEnabled());
            AddNativeSeparator(advancedMenu);

            HMENU aspectMenu = CreatePopupMenu();
            if (aspectMenu) {
                const AspectRatioMode currentAspect = GetAspectRatioMode();
                const ULONG allowedAspectMask = GetAllowedAspectRatioMask();
                AddNativeMenuItem(aspectMenu, L"16:9", ID_ASPECT_RATIO_16_9, currentAspect == AspectRatioMode::R16_9, (allowedAspectMask & ASPECT_RATIO_MASK_16_9) != 0);
                AddNativeMenuItem(aspectMenu, L"9:16", ID_ASPECT_RATIO_9_16, currentAspect == AspectRatioMode::R9_16, (allowedAspectMask & ASPECT_RATIO_MASK_9_16) != 0);
                AddNativeMenuItem(aspectMenu, L"4:3", ID_ASPECT_RATIO_4_3, currentAspect == AspectRatioMode::R4_3, (allowedAspectMask & ASPECT_RATIO_MASK_4_3) != 0);
                AddNativeMenuItem(aspectMenu, L"3:4", ID_ASPECT_RATIO_3_4, currentAspect == AspectRatioMode::R3_4, (allowedAspectMask & ASPECT_RATIO_MASK_3_4) != 0);
                AppendMenuW(advancedMenu, MF_POPUP, reinterpret_cast<UINT_PTR>(aspectMenu), L"Aspect Ratio");
            }

            AddNativeSeparator(advancedMenu);
            AddNativeMenuItem(advancedMenu, L"Run Host Media Proof", ID_ADV_RUN_HOST_PROOF);
            AddNativeMenuItem(advancedMenu, L"Run VM Verifier Proof", ID_ADV_RUN_VM_VERIFIER_PROOF);
            AddNativeMenuItem(advancedMenu, L"Open Setup", ID_ADV_RUN_SETUP_VERIFY);
            AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(advancedMenu), L"Advanced");
        }
    }

    AddNativeSeparator(menu);
    AddNativeMenuItem(menu, L"Open Logs", ID_TRAY_OPEN_LOGS);
    AddNativeMenuItem(menu, L"About", ID_TRAY_ABOUT);
    AddNativeMenuItem(menu, L"Exit", ID_TRAY_EXIT);

    SetForegroundWindow(hwnd);
    const UINT command = TrackPopupMenuEx(
        menu,
        TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
        pt.x,
        pt.y,
        hwnd,
        nullptr);
    if (command != 0) {
        HandleMenuCommand(command);
    }
    PostMessage(hwnd, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

INT_PTR CALLBACK About(HWND hDlg, UINT message, WPARAM wParam, LPARAM lParam) {
    UNREFERENCED_PARAMETER(lParam);
    switch (message) {
    case WM_INITDIALOG: {
        LONG_PTR exStyle = GetWindowLongPtr(hDlg, GWL_EXSTYLE);
        exStyle &= ~WS_EX_TOOLWINDOW;
        exStyle |= WS_EX_APPWINDOW;
        SetWindowLongPtr(hDlg, GWL_EXSTYLE, exStyle);
        EnableNativeDarkMenus(hDlg);
        CenterWindow(hDlg, true);
        return (INT_PTR)TRUE;
    }
    case WM_COMMAND: if (LOWORD(wParam) == IDOK || LOWORD(wParam) == IDCANCEL) { EndDialog(hDlg, LOWORD(wParam)); return (INT_PTR)TRUE; } break;
    }
    return (INT_PTR)FALSE;
}

void AddTrayIcon(HWND hwnd, bool add) {
    NOTIFYICONDATA nid = { sizeof(nid) }; nid.hWnd = hwnd; nid.uID = 1;
    if (add) {
        nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        nid.uCallbackMessage = WM_APP_TRAY_MSG;
        nid.hIcon = (HICON)LoadImage(g_instance, MAKEINTRESOURCE(IDI_VIRTUACAM), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
        wcscpy_s(nid.szTip, L"VirtuaCam");
        Shell_NotifyIcon(NIM_ADD, &nid);
    } else {
        Shell_NotifyIcon(NIM_DELETE, &nid);
    }
}

void CreatePreviewWindow() {
    const std::filesystem::path setup = std::filesystem::path(VirtuaCamLog::GetExeDir()) / L"VirtuaCamSetup.exe";
    if (!std::filesystem::exists(setup)) {
        VirtuaCamLog::LogLine(std::format(L"Setup preview missing: {}", setup.wstring()));
        MessageBoxW(g_hMainWnd, setup.c_str(), L"VirtuaCam setup not staged", MB_OK | MB_ICONWARNING);
        return;
    }

    HINSTANCE launched = ShellExecuteW(
        nullptr,
        L"open",
        setup.c_str(),
        nullptr,
        VirtuaCamLog::GetExeDir().c_str(),
        SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(launched) <= 32) {
        VirtuaCamLog::LogLine(std::format(L"Setup preview launch failed: {}", reinterpret_cast<INT_PTR>(launched)));
        MessageBoxW(g_hMainWnd, L"Failed to open VirtuaCam setup window.", L"VirtuaCam", MB_OK | MB_ICONERROR);
    }
}

void UpdateTelemetry(BrokerState currentState, bool driverConnected) {
    static std::wstring lastSourceText;
    static bool hasState = false;
    const std::wstring sourceText = SourceSummaryText(GetMainSourceState(), currentState);

    if (!hasState ||
        currentState != g_lastBrokerState ||
        driverConnected != g_lastDriverConnected ||
        sourceText != lastSourceText) {
        hasState = true;
        g_lastBrokerState = currentState;
        g_lastDriverConnected = driverConnected;
        lastSourceText = sourceText;

        UpdateTrayTooltip(currentState, driverConnected);
    }
}

std::wstring BrokerStateText(BrokerState brokerState)
{
    switch (brokerState) {
    case BrokerState::Searching: return L"Searching";
    case BrokerState::Connected: return L"Connected";
    case BrokerState::Failed: return L"Disconnected";
    default: return L"Unknown";
    }
}

std::wstring SourceSummaryText(const SourceState& state, BrokerState brokerState)
{
    if (state.mode == SourceMode::Off) {
        return L"Off (default feed)";
    }
    std::wstring text = SourceModeToString(state.mode);
    if (state.mode == SourceMode::Camera && state.cameraIndex >= 0) {
        text += L" #" + std::to_wstring(state.cameraIndex);
    } else if (state.mode == SourceMode::Display && state.displayIndex >= 0) {
        text += L" #" + std::to_wstring(state.displayIndex + 1);
    } else if ((state.mode == SourceMode::Window || state.mode == SourceMode::Discovered) && state.pid != 0) {
        text += L" PID " + std::to_wstring(state.pid);
    } else if ((state.mode == SourceMode::Image || state.mode == SourceMode::Video) && !state.filePath.empty()) {
        text += L" " + std::filesystem::path(state.filePath).filename().wstring();
    }
    if (brokerState != BrokerState::Connected) {
        text += L" (default feed fallback)";
    }
    return text;
}

void UpdateTrayTooltip(BrokerState brokerState, bool driverConnected) {
    if (!g_hMainWnd) return;

    std::wstring tip = std::format(
        L"VirtuaCam | Driver: {} | Source: {}",
        driverConnected ? L"active" : L"idle/offline",
        SourceSummaryText(GetMainSourceState(), brokerState));
    NOTIFYICONDATA nid = { sizeof(nid) };
    if (tip.size() >= ARRAYSIZE(nid.szTip)) {
        tip.resize(ARRAYSIZE(nid.szTip) - 1);
    }
    nid.hWnd = g_hMainWnd;
    nid.uID = 1;
    nid.uFlags = NIF_TIP;
    wcscpy_s(nid.szTip, tip.c_str());
    Shell_NotifyIcon(NIM_MODIFY, &nid);
}

std::wstring BuildSupportStatusText(BrokerState brokerState, bool driverConnected)
{
    UNREFERENCED_PARAMETER(driverConnected);
    const std::filesystem::path logPath = VirtuaCamLog::GetLogPath();
    const std::filesystem::path logDir = logPath.empty()
        ? std::filesystem::path(VirtuaCamLog::GetExeDir()) / L"logs"
        : logPath.parent_path();
    const SourceState& source = GetMainSourceState();
    return std::format(
        L"VirtuaCam\n\n"
        L"Driver: {}\n"
        L"Broker: {}\n"
        L"Source: {}\n"
        L"Audio: {}\n"
        L"Aspect ratio: {}\n"
        L"Logs: {}\n\n"
        L"Use -debug to show advanced proof tools. Open Logs is available from the tray menu.",
        GetRuntimeDriverStatusText(),
        BrokerStateText(brokerState),
        SourceSummaryText(source, brokerState),
        GetRuntimeAudioStatusText(),
        VirtuaCamConfig::AspectRatioName(GetAspectRatioMode()),
        logDir.wstring());
}

