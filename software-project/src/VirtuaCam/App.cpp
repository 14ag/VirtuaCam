#include "pch.h"
#include "App.h"
#include "UI.h"
#include "WASAPI.h"
#include "Tools.h"
#include "Discovery.h"
#include "DriverBridge.h"
#include "RuntimeLog.h"
#include <wrl.h>
#include <filesystem>
#include <algorithm>
#include <map>

using namespace Microsoft::WRL;

static HWND g_hMainWnd = NULL;
static std::unique_ptr<WASAPICapture> g_audioCapture;
static std::unique_ptr<VirtuaCam::Discovery> g_discovery;
static std::unique_ptr<DriverBridge> g_driverBridge;

typedef void (*PFN_InitializeBroker)();
typedef void (*PFN_ShutdownBroker)();
typedef void (*PFN_RenderBrokerFrame)();
typedef ID3D11Texture2D* (*PFN_GetSharedTexture)();
typedef BrokerState (*PFN_GetBrokerState)();
typedef void (*PFN_UpdateProducerPriorityList)(const DWORD*, int);
typedef void (*PFN_SetCompositingMode)(bool);

static HMODULE g_hBrokerDll = nullptr;
static PFN_InitializeBroker g_pfnInitializeBroker = nullptr;
static PFN_ShutdownBroker g_pfnShutdownBroker = nullptr;
static PFN_RenderBrokerFrame g_pfnRenderBrokerFrame = nullptr;
static PFN_GetSharedTexture g_pfnGetSharedTexture = nullptr;
static PFN_GetBrokerState g_pfnGetBrokerState = nullptr;
static PFN_UpdateProducerPriorityList g_pfnUpdateProducerPriorityList = nullptr;
static PFN_SetCompositingMode g_pfnSetCompositingMode = nullptr;

static SourceState g_mainSourceState;
static SourceState g_pip_tl_state;
static SourceState g_pip_tr_state;
static SourceState g_pip_bl_state;
static SourceState g_pip_br_state;
static std::map<std::wstring, PROCESS_INFORMATION> g_producerProcesses;

static bool g_showPipTL = false;
static bool g_showPipTR = false;
static bool g_showPipBL = false;
const WCHAR* REG_SUBKEY = L"Software\\VirtuaCam";
const WCHAR* REG_VAL_PIPTL = L"ShowPipTopLeft";
const WCHAR* REG_VAL_PIPTR = L"ShowPipTopRight";
const WCHAR* REG_VAL_PIPBL = L"ShowPipBottomLeft";

bool IsRunningAsAdmin();
bool GetDriverBridgeStatus();
HRESULT LoadBroker();
void ShutdownSystem();
void OnIdle();
void TrySendBrokerFrameToDriver(bool brokerFrameRendered);
void InformBroker();
void LoadSettings();
void SaveSettings();

bool GetPipTlEnabled() { return g_showPipTL; }
bool GetPipTrEnabled() { return g_showPipTR; }
bool GetPipBlEnabled() { return g_showPipBL; }
void TogglePipTl() { g_showPipTL = !g_showPipTL; SaveSettings(); }
void TogglePipTr() { g_showPipTR = !g_showPipTR; SaveSettings(); }
void TogglePipBl() { g_showPipBL = !g_showPipBL; SaveSettings(); }

const VirtuaCam::Discovery* GetGlobalDiscovery() { return g_discovery.get(); }
bool GetDriverBridgeStatus() { return g_driverBridge && g_driverBridge->IsActive(); }
const SourceState& GetMainSourceState() { return g_mainSourceState; }
const SourceState& GetPipSourceState(PipPosition pos) {
    switch (pos) {
        case PipPosition::TL: return g_pip_tl_state;
        case PipPosition::TR: return g_pip_tr_state;
        case PipPosition::BL: return g_pip_bl_state;
        case PipPosition::BR: return g_pip_br_state;
    }
    return g_pip_br_state;
}

void TerminateProducer(const std::wstring& key)
{
    if (g_producerProcesses.count(key))
    {
        TerminateProcess(g_producerProcesses[key].hProcess, 0);
        CloseHandle(g_producerProcesses[key].hProcess);
        CloseHandle(g_producerProcesses[key].hThread);
        g_producerProcesses.erase(key);
    }
}

DWORD LaunchProducer(const std::wstring& key, const std::wstring& args)
{
    TerminateProducer(key);

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {};

    std::filesystem::path childExe = std::filesystem::path(VirtuaCamLog::GetExeDir()) / L"VirtuaCamProcess.exe";
    std::wstring exePath = childExe.wstring();

    std::wstring cmdLine = std::format(L"\"{}\" {}", exePath, args);
    std::vector<wchar_t> cmdLineMutable(cmdLine.begin(), cmdLine.end());
    cmdLineMutable.push_back(L'\0');

    if (CreateProcessW(exePath.c_str(), cmdLineMutable.data(), NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
    {
        g_producerProcesses[key] = pi;
        Sleep(200);
        return pi.dwProcessId;
    }
    VirtuaCamLog::LogWin32(std::format(L"CreateProcessW failed: {}", exePath), GetLastError());
    return 0;
}

void SetSourceMode(SourceMode newMode, DWORD_PTR context = 0) {
    if (newMode == g_mainSourceState.mode && newMode != SourceMode::Window && newMode != SourceMode::Camera) return;

    g_mainSourceState.pid = 0;
    g_mainSourceState.cameraIndex = -1;
    TerminateProducer(L"main_camera");
    TerminateProducer(L"main_window");
    g_mainSourceState.hwnd = nullptr;

    switch (newMode) {
        case SourceMode::Camera:
            g_mainSourceState.cameraIndex = static_cast<int>(context);
            g_mainSourceState.pid = LaunchProducer(L"main_camera", L"--type camera --device " + std::to_wstring(g_mainSourceState.cameraIndex));
            break;
        case SourceMode::Window:
            g_mainSourceState.hwnd = reinterpret_cast<HWND>(context);
            if(g_mainSourceState.hwnd) {
                g_mainSourceState.pid = LaunchProducer(L"main_window", L"--type capture --hwnd " + std::to_wstring((UINT64)g_mainSourceState.hwnd));
            }
            break;
        case SourceMode::Discovered:
        case SourceMode::Consumer:
            g_mainSourceState.pid = static_cast<DWORD>(context);
            break;
        case SourceMode::Off:
        default:
            break;
    }
    g_mainSourceState.mode = newMode;
    InformBroker();
}

void SetPipSource(PipPosition pos, SourceMode newMode, DWORD_PTR context = 0)
{
    SourceState* state_ptr = nullptr;
    switch (pos) {
        case PipPosition::TL: state_ptr = &g_pip_tl_state; break;
        case PipPosition::TR: state_ptr = &g_pip_tr_state; break;
        case PipPosition::BL: state_ptr = &g_pip_bl_state; break;
        case PipPosition::BR: state_ptr = &g_pip_br_state; break;
    }
    if (!state_ptr) return;
    SourceState& state = *state_ptr;

    if (newMode == state.mode && newMode != SourceMode::Window && newMode != SourceMode::Camera) return;

    state.pid = 0;
    state.cameraIndex = -1;
    std::wstring key_prefix = L"pip_" + std::to_wstring((int)pos);
    TerminateProducer(key_prefix + L"_camera");
    TerminateProducer(key_prefix + L"_window");
    state.hwnd = nullptr;

    switch (newMode) {
        case SourceMode::Camera:
            state.cameraIndex = static_cast<int>(context);
            state.pid = LaunchProducer(key_prefix + L"_camera", L"--type camera --device " + std::to_wstring(state.cameraIndex));
            break;
        case SourceMode::Window:
            state.hwnd = reinterpret_cast<HWND>(context);
            if (state.hwnd) {
                state.pid = LaunchProducer(key_prefix + L"_window", L"--type capture --hwnd " + std::to_wstring((UINT64)state.hwnd));
            }
            break;
        case SourceMode::Discovered:
        case SourceMode::Consumer:
            state.pid = static_cast<DWORD>(context);
            break;
        case SourceMode::Off:
        default:
             break;
    }
    state.mode = newMode;
    InformBroker();
}

int APIENTRY wWinMain(_In_ HINSTANCE hInstance, _In_opt_ HINSTANCE, _In_ LPWSTR, _In_ int) {
    VirtuaCamLog::InitOptions logOpts;
    logOpts.logFileName = L"virtuacam-runtime.log";
    logOpts.attachConsole = true;
    logOpts.allocConsoleIfMissing = false;
    VirtuaCamLog::Init(logOpts);

    LoadSettings();
    RETURN_IF_FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));

    HRESULT hrBroker = LoadBroker();
    if (FAILED(hrBroker)) {
         VirtuaCamLog::ShowAndLogError(NULL, L"Failed to load DirectPortBroker.dll.", L"Error", hrBroker);
         CoUninitialize(); return 1;
    }

    g_discovery = std::make_unique<VirtuaCam::Discovery>();
    ComPtr<ID3D11Device> tempDevice;
    if (SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, nullptr, 0, D3D11_SDK_VERSION, &tempDevice, nullptr, nullptr))) {
        g_discovery->Initialize(tempDevice.Get());
    }

    UI_Initialize(hInstance, g_hMainWnd, g_pfnGetSharedTexture);
    if (!g_hMainWnd) {
        ShutdownSystem(); CoUninitialize(); return FALSE;
    }

    SetTimer(g_hMainWnd, 1, 1000, nullptr);
    InformBroker();

    g_audioCapture = std::make_unique<WASAPICapture>();
    if (SUCCEEDED(g_audioCapture->EnumerateCaptureDevices())) {
        UI_UpdateAudioDeviceLists(g_audioCapture->GetCaptureDeviceNames());
        UI_SetAudioSelectionCallback([](int id) {
            if (id == ID_AUDIO_DEVICE_NONE) g_audioCapture->StopCapture();
            else if (id >= ID_AUDIO_CAPTURE_FIRST) g_audioCapture->StartCapture(id - ID_AUDIO_CAPTURE_FIRST, false);
        });
    }

    g_driverBridge = std::make_unique<DriverBridge>();
    HRESULT hrDriver = g_driverBridge->Initialize();
    if (FAILED(hrDriver)) {
        VirtuaCamLog::LogHr(L"DriverBridge::Initialize failed", hrDriver);
        VirtuaCamLog::LogLine(std::format(L"DriverBridge last error: {}", g_driverBridge->GetLastError()));
        std::wstring message =
            L"DriverBridge failed to connect to the avshws kernel driver.\n"
            L"Make sure driver-project is installed.";
        VirtuaCamLog::ShowAndLogError(g_hMainWnd, message.c_str(), L"Error", hrDriver);
    }

    VirtuaCamLog::LogLine(L"Entering message loop.");
    UI_RunMessageLoop(OnIdle);

    ShutdownSystem();
    CoUninitialize();
    return 0;
}

void OnIdle() {
    const bool brokerFrameRendered = (g_pfnRenderBrokerFrame != nullptr);
    if (brokerFrameRendered) {
        g_pfnRenderBrokerFrame();
    }

    if (g_pfnGetBrokerState) UpdateTelemetry(g_pfnGetBrokerState(), GetDriverBridgeStatus());
    TrySendBrokerFrameToDriver(brokerFrameRendered);
}

void TrySendBrokerFrameToDriver(bool brokerFrameRendered) {
    static bool s_loggedNullTexture = false;

    if (!brokerFrameRendered || !g_driverBridge || !g_driverBridge->IsActive() || !g_pfnGetSharedTexture) {
        return;
    }

    wil::com_ptr_nothrow<ID3D11Texture2D> sharedTexture;
    sharedTexture.attach(g_pfnGetSharedTexture());
    if (!sharedTexture) {
        if (!s_loggedNullTexture) {
            VirtuaCamLog::LogLine(L"GetSharedTexture returned null");
            s_loggedNullTexture = true;
        }
        return;
    }

    s_loggedNullTexture = false;

    HRESULT hr = g_driverBridge->SendFrame(sharedTexture.get());
    if (FAILED(hr)) {
        if (hr == HRESULT_FROM_WIN32(ERROR_RETRY)) {
            VirtuaCamLog::LogLine(L"DriverBridge::SendFrame requested retry after reinitialize");
        } else {
            VirtuaCamLog::LogHr(L"DriverBridge::SendFrame failed", hr);
        }
    }
}

void InformBroker() {
    if (!g_discovery || !g_pfnUpdateProducerPriorityList || !g_pfnSetCompositingMode) return;

    g_discovery->DiscoverStreams();
    
    bool isGridMode = (g_mainSourceState.mode == SourceMode::Consumer);
    g_pfnSetCompositingMode(isGridMode);

    if (isGridMode) {
        const auto& streams = g_discovery->GetDiscoveredStreams();
        std::vector<DWORD> pids;
        for (const auto& s : streams) {
            if (s.processName != L"VirtuaCam.exe") {
                 pids.push_back(s.processId);
            }
        }
        g_pfnUpdateProducerPriorityList(pids.data(), static_cast<int>(pids.size()));
    } else {
        DWORD pids[5] = {0};
        pids[0] = g_mainSourceState.pid;
        pids[1] = g_pip_tl_state.pid;
        pids[2] = g_pip_tr_state.pid;
        pids[3] = g_pip_bl_state.pid;
        pids[4] = g_pip_br_state.pid;
        g_pfnUpdateProducerPriorityList(pids, 5);
    }
}

HRESULT LoadBroker() {
    g_hBrokerDll = LoadLibraryExW(L"DirectPortBroker.dll", nullptr, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!g_hBrokerDll) {
        DWORD err = GetLastError();
        VirtuaCamLog::LogWin32(L"LoadLibraryExW DirectPortBroker.dll failed", err);
        VirtuaCamLog::LogLine(std::format(L"exe dir: {}", VirtuaCamLog::GetExeDir()));
        VirtuaCamLog::LogLine(std::format(L"cwd: {}", VirtuaCamLog::GetCurrentDir()));
        wchar_t found[MAX_PATH];
        DWORD n = SearchPathW(nullptr, L"DirectPortBroker.dll", nullptr, ARRAYSIZE(found), found, nullptr);
        if (n > 0 && n < ARRAYSIZE(found)) {
            VirtuaCamLog::LogLine(std::format(L"SearchPathW found: {}", found));
        } else {
            VirtuaCamLog::LogLine(L"SearchPathW: not found");
        }
        return HRESULT_FROM_WIN32(err);
    }
    g_pfnInitializeBroker = (PFN_InitializeBroker)GetProcAddress(g_hBrokerDll, "InitializeBroker");
    g_pfnShutdownBroker = (PFN_ShutdownBroker)GetProcAddress(g_hBrokerDll, "ShutdownBroker");
    g_pfnRenderBrokerFrame = (PFN_RenderBrokerFrame)GetProcAddress(g_hBrokerDll, "RenderBrokerFrame");
    g_pfnGetSharedTexture = (PFN_GetSharedTexture)GetProcAddress(g_hBrokerDll, "GetSharedTexture");
    g_pfnGetBrokerState = (PFN_GetBrokerState)GetProcAddress(g_hBrokerDll, "GetBrokerState");
    g_pfnUpdateProducerPriorityList = (PFN_UpdateProducerPriorityList)GetProcAddress(g_hBrokerDll, "UpdateProducerPriorityList");
    g_pfnSetCompositingMode = (PFN_SetCompositingMode)GetProcAddress(g_hBrokerDll, "SetCompositingMode");
    if (!g_pfnInitializeBroker || !g_pfnShutdownBroker || !g_pfnRenderBrokerFrame || !g_pfnGetSharedTexture || !g_pfnGetBrokerState || !g_pfnUpdateProducerPriorityList || !g_pfnSetCompositingMode) {
        VirtuaCamLog::LogLine(L"DirectPortBroker.dll missing expected exports");
        return E_FAIL;
    }
    g_pfnInitializeBroker();
    return S_OK;
}

void ShutdownSystem() {
    if (g_audioCapture) {
        g_audioCapture->StopCapture();
        g_audioCapture.reset();
    }

    if (g_driverBridge) {
        g_driverBridge->Shutdown();
        g_driverBridge.reset();
    }

    if (g_pfnShutdownBroker) g_pfnShutdownBroker();
    if (g_hBrokerDll) {
        FreeLibrary(g_hBrokerDll);
        g_hBrokerDll = nullptr;
    }

    for (auto const& [key, pi] : g_producerProcesses)
    {
        if (pi.hProcess) {
            TerminateProcess(pi.hProcess, 0);
            WaitForSingleObject(pi.hProcess, 5000);
            CloseHandle(pi.hProcess);
        }
        if (pi.hThread) {
            CloseHandle(pi.hThread);
        }
    }
    g_producerProcesses.clear();

    if (g_discovery) {
        g_discovery->Teardown();
        g_discovery.reset();
    }

    UI_Shutdown();
}

bool IsRunningAsAdmin() {
    BOOL fIsAdmin = FALSE; HANDLE hToken = NULL; TOKEN_ELEVATION elevation; DWORD dwSize;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken)) {
        if (GetTokenInformation(hToken, TokenElevation, &elevation, sizeof(elevation), &dwSize)) fIsAdmin = (elevation.TokenIsElevated != 0);
        CloseHandle(hToken);
    }
    return fIsAdmin;
}

void LoadSettings() {
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, REG_SUBKEY, 0, KEY_READ, &hKey) == ERROR_SUCCESS) {
        DWORD dwValue = 0;
        DWORD dwSize = sizeof(dwValue);
        if (RegQueryValueExW(hKey, REG_VAL_PIPTL, NULL, NULL, (LPBYTE)&dwValue, &dwSize) == ERROR_SUCCESS) {
            g_showPipTL = (dwValue != 0);
        }
        if (RegQueryValueExW(hKey, REG_VAL_PIPTR, NULL, NULL, (LPBYTE)&dwValue, &dwSize) == ERROR_SUCCESS) {
            g_showPipTR = (dwValue != 0);
        }
        if (RegQueryValueExW(hKey, REG_VAL_PIPBL, NULL, NULL, (LPBYTE)&dwValue, &dwSize) == ERROR_SUCCESS) {
            g_showPipBL = (dwValue != 0);
        }
        RegCloseKey(hKey);
    }
}

void SaveSettings() {
    HKEY hKey;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, REG_SUBKEY, 0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL) == ERROR_SUCCESS) {
        DWORD dwValueTL = g_showPipTL ? 1 : 0;
        DWORD dwValueTR = g_showPipTR ? 1 : 0;
        DWORD dwValueBL = g_showPipBL ? 1 : 0;
        RegSetValueExW(hKey, REG_VAL_PIPTL, 0, REG_DWORD, (const BYTE*)&dwValueTL, sizeof(dwValueTL));
        RegSetValueExW(hKey, REG_VAL_PIPTR, 0, REG_DWORD, (const BYTE*)&dwValueTR, sizeof(dwValueTR));
        RegSetValueExW(hKey, REG_VAL_PIPBL, 0, REG_DWORD, (const BYTE*)&dwValueBL, sizeof(dwValueBL));
        RegCloseKey(hKey);
    }
}
