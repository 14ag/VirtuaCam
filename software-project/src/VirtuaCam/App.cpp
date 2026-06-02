#include "pch.h"
#include "App.h"
#include "UI.h"
#include "WASAPI.h"
#include "Tools.h"
#include "Discovery.h"
#include "DriverBridge.h"
#include "RuntimeLog.h"
#include <wrl.h>
#include <mfreadwrite.h>
#include <filesystem>
#include <algorithm>
#include <map>
#include <cmath>
#include <cwctype>

using namespace Microsoft::WRL;

static HWND g_hMainWnd = NULL;
static std::unique_ptr<WASAPICapture> g_audioCapture;
static std::unique_ptr<VirtuaCam::Discovery> g_discovery;
static std::unique_ptr<DriverBridge> g_driverBridge;
static bool g_disconnectAttempted = false;
static bool g_debugLoggingEnabled = false;
static bool g_silentStart = false;

typedef void (*PFN_InitializeBroker)();
typedef void (*PFN_ShutdownBroker)();
typedef void (*PFN_RenderBrokerFrame)();
typedef ID3D11Texture2D* (*PFN_GetSharedTexture)();
typedef BrokerState (*PFN_GetBrokerState)();
typedef UINT64 (*PFN_GetBrokerFrameValue)();
typedef void (*PFN_UpdateProducerPriorityList)(const DWORD*, int);
typedef void (*PFN_RegisterExpectedProducer)(DWORD, UINT64);
typedef void (*PFN_SetCompositingMode)(bool);

static HMODULE g_hBrokerDll = nullptr;
static PFN_InitializeBroker g_pfnInitializeBroker = nullptr;
static PFN_ShutdownBroker g_pfnShutdownBroker = nullptr;
static PFN_RenderBrokerFrame g_pfnRenderBrokerFrame = nullptr;
static PFN_GetSharedTexture g_pfnGetSharedTexture = nullptr;
static PFN_GetBrokerState g_pfnGetBrokerState = nullptr;
static PFN_GetBrokerFrameValue g_pfnGetBrokerFrameValue = nullptr;
static PFN_UpdateProducerPriorityList g_pfnUpdateProducerPriorityList = nullptr;
static PFN_RegisterExpectedProducer g_pfnRegisterExpectedProducer = nullptr;
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
static AspectRatioMode g_aspectRatioMode = AspectRatioMode::R16_9;
static ULONG g_allowedAspectRatioMask = ASPECT_RATIO_MASK_ALL;
static AudioRoutingMode g_audioRoutingMode = AudioRoutingMode::Auto;
static std::wstring g_audioCaptureDeviceName = L"Stereo Mix";
static bool g_startDebugMode = false;
static constexpr ULONGLONG kAppFrameIntervalMs = 33;
static constexpr ULONGLONG kDefaultFeedRefreshMs = 1000;
static constexpr ULONGLONG kSilentDriverInactiveExitMs = 5ull * 60ull * 1000ull;

const wchar_t* SourceModeToString(SourceMode mode)
{
    switch (mode) {
    case SourceMode::Off: return L"Off";
    case SourceMode::Camera: return L"Camera";
    case SourceMode::Window: return L"Window";
    case SourceMode::Display: return L"Display";
    case SourceMode::Image: return L"Image";
    case SourceMode::Video: return L"Video";
    case SourceMode::Discovered: return L"Discovered";
    default: return L"Unknown";
    }
}

const wchar_t* PipPositionToString(PipPosition pos)
{
    switch (pos) {
    case PipPosition::TL: return L"TL";
    case PipPosition::TR: return L"TR";
    case PipPosition::BL: return L"BL";
    case PipPosition::BR: return L"BR";
    default: return L"?";
    }
}

bool IsRunningAsAdmin();
bool GetDriverBridgeStatus();
HRESULT LoadBroker();
void ShutdownSystem();
void RequestDriverDisconnect();
void OnIdle();
void TrySendBrokerFrameToDriver(bool brokerFrameRendered, BrokerState brokerState, UINT64 brokerFrameValue);
void InformBroker();
void ForceDefaultBrokerFrameToDriver(const wchar_t* reason);
void LoadSettings();
void SaveSettings();
void InitializeAudio();
void SelectAudioForCameraPassthrough(int cameraIndex);
void SetSourceFileMode(SourceMode newMode, const std::wstring& path);
void ApplySavedAudioSelection();
bool HasArg(const std::wstring& cmdLine, const wchar_t* arg);
bool TryGetArgU64(const std::wstring& cmdLine, const wchar_t* arg, UINT64& outValue);
int PrintCapturableWindowsJson();
std::wstring JsonEscape(const std::wstring& value);
bool WriteStdoutText(const std::wstring& text);

ULONG AspectRatioMask(AspectRatioMode mode)
{
    switch (mode) {
    case AspectRatioMode::R9_16: return ASPECT_RATIO_MASK_9_16;
    case AspectRatioMode::R4_3: return ASPECT_RATIO_MASK_4_3;
    case AspectRatioMode::R3_4: return ASPECT_RATIO_MASK_3_4;
    case AspectRatioMode::R16_9:
    default: return ASPECT_RATIO_MASK_16_9;
    }
}

bool IsAspectRatioAllowed(AspectRatioMode mode)
{
    return (g_allowedAspectRatioMask & AspectRatioMask(mode)) != 0;
}

AspectRatioMode FirstAspectRatioFromMask(ULONG mask)
{
    if (mask & ASPECT_RATIO_MASK_16_9) return AspectRatioMode::R16_9;
    if (mask & ASPECT_RATIO_MASK_9_16) return AspectRatioMode::R9_16;
    if (mask & ASPECT_RATIO_MASK_4_3) return AspectRatioMode::R4_3;
    if (mask & ASPECT_RATIO_MASK_3_4) return AspectRatioMode::R3_4;
    return AspectRatioMode::R16_9;
}

bool SizeMatchesAspect(UINT32 width, UINT32 height, AspectRatioMode mode)
{
    if (width == 0 || height == 0) {
        return false;
    }

    const double observed = static_cast<double>(width) / static_cast<double>(height);
    const double target = static_cast<double>(VirtuaCamConfig::AspectRatioValue(mode));
    return std::abs(observed - target) <= (target * 0.02);
}

bool TryGetAspectFromSize(UINT32 width, UINT32 height, AspectRatioMode& mode)
{
    const AspectRatioMode modes[] = {
        AspectRatioMode::R16_9,
        AspectRatioMode::R9_16,
        AspectRatioMode::R4_3,
        AspectRatioMode::R3_4
    };

    for (const AspectRatioMode candidate : modes) {
        if (SizeMatchesAspect(width, height, candidate)) {
            mode = candidate;
            return true;
        }
    }
    return false;
}

bool TryScanCameraAspectMask(const wchar_t* devicePath, ULONG& outMask, AspectRatioMode& outFirstMode)
{
    outMask = 0;
    outFirstMode = AspectRatioMode::R16_9;
    if (!devicePath || !*devicePath) {
        return false;
    }

    ComPtr<IMFAttributes> attributes;
    if (FAILED(MFCreateAttributes(&attributes, 1))) {
        return false;
    }
    if (FAILED(attributes->SetGUID(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID))) {
        return false;
    }

    IMFActivate** devices = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFEnumDeviceSources(attributes.Get(), &devices, &count);
    if (FAILED(hr) || !devices || count == 0) {
        if (devices) CoTaskMemFree(devices);
        return false;
    }

    ComPtr<IMFMediaSource> source;
    for (UINT32 i = 0; i < count; ++i) {
        wil::unique_cotaskmem_string symbolicLink;
        if (SUCCEEDED(devices[i]->GetAllocatedString(
                MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                &symbolicLink,
                nullptr)) &&
            symbolicLink.get() &&
            _wcsicmp(symbolicLink.get(), devicePath) == 0) {
            hr = devices[i]->ActivateObject(IID_PPV_ARGS(&source));
            break;
        }
    }

    for (UINT32 i = 0; i < count; ++i) {
        devices[i]->Release();
    }
    CoTaskMemFree(devices);

    if (!source) {
        return false;
    }

    ComPtr<IMFAttributes> readerAttributes;
    if (FAILED(MFCreateAttributes(&readerAttributes, 1)) ||
        FAILED(readerAttributes->SetUINT32(MF_READWRITE_DISABLE_CONVERTERS, TRUE))) {
        return false;
    }

    ComPtr<IMFSourceReader> reader;
    if (FAILED(MFCreateSourceReaderFromMediaSource(source.Get(), readerAttributes.Get(), &reader))) {
        return false;
    }

    for (DWORD i = 0;; ++i) {
        ComPtr<IMFMediaType> nativeType;
        hr = reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &nativeType);
        if (hr == MF_E_NO_MORE_TYPES) {
            break;
        }
        if (FAILED(hr)) {
            return false;
        }

        UINT32 width = 0;
        UINT32 height = 0;
        if (FAILED(MFGetAttributeSize(nativeType.Get(), MF_MT_FRAME_SIZE, &width, &height))) {
            continue;
        }

        AspectRatioMode mode = AspectRatioMode::R16_9;
        if (TryGetAspectFromSize(width, height, mode)) {
            const ULONG bit = AspectRatioMask(mode);
            if ((outMask & bit) == 0 && outMask == 0) {
                outFirstMode = mode;
            }
            outMask |= bit;
        }
    }

    outMask &= ASPECT_RATIO_MASK_ALL;
    return outMask != 0;
}

void SetAllowedAspectRatioMask(ULONG mask, const wchar_t* reason)
{
    mask &= ASPECT_RATIO_MASK_ALL;
    if (mask == 0) {
        mask = ASPECT_RATIO_MASK_ALL;
    }

    g_allowedAspectRatioMask = mask;
    VirtuaCamLog::LogLine(std::format(
        L"Allowed aspect ratio mask: 0x{:X} reason={}",
        g_allowedAspectRatioMask,
        reason ? reason : L""));
}

bool GetPipTlEnabled() { return g_showPipTL; }
bool GetPipTrEnabled() { return g_showPipTR; }
bool GetPipBlEnabled() { return g_showPipBL; }
void TogglePipTl() { g_showPipTL = !g_showPipTL; SaveSettings(); }
void TogglePipTr() { g_showPipTR = !g_showPipTR; SaveSettings(); }
void TogglePipBl() { g_showPipBL = !g_showPipBL; SaveSettings(); }
AspectRatioMode GetAspectRatioMode() { return g_aspectRatioMode; }
ULONG GetAllowedAspectRatioMask() { return g_allowedAspectRatioMask; }
void ApplyDriverAspectPolicy()
{
    if (!g_driverBridge || !g_driverBridge->IsActive()) {
        return;
    }

    ULONG driverAspectMask = AspectRatioMask(g_aspectRatioMode);
    if ((driverAspectMask & g_allowedAspectRatioMask) == 0) {
        driverAspectMask = g_allowedAspectRatioMask;
    }

    HRESULT hr = g_driverBridge->SetAspectPolicy(g_aspectRatioMode, driverAspectMask);
    if (FAILED(hr)) {
        VirtuaCamLog::LogHr(L"DriverBridge::SetAspectPolicy failed", hr);
        return;
    }

    hr = g_driverBridge->Disconnect();
    if (FAILED(hr) && hr != S_FALSE) {
        VirtuaCamLog::LogHr(L"DriverBridge::Disconnect after aspect change failed", hr);
    }
}
void SetAspectRatioMode(AspectRatioMode mode)
{
    if (!IsAspectRatioAllowed(mode)) {
        VirtuaCamLog::LogLine(std::format(
            L"Aspect ratio ignored because it is disabled by current source: {} allowedMask=0x{:X}",
            VirtuaCamConfig::AspectRatioName(mode),
            g_allowedAspectRatioMask));
        return;
    }

    if (g_aspectRatioMode == mode) {
        return;
    }

    g_aspectRatioMode = mode;
    SaveSettings();
    VirtuaCamLog::LogLine(std::format(
        L"Aspect ratio changed: {} settings={}",
        VirtuaCamConfig::AspectRatioName(g_aspectRatioMode),
        VirtuaCamConfig::GetSettingsRegistryPath()));
    ApplyDriverAspectPolicy();
}

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

std::wstring ToLowerInvariant(std::wstring value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
        return static_cast<wchar_t>(std::towlower(ch));
    });
    return value;
}

bool ContainsText(const std::wstring& value, const std::wstring& needle)
{
    if (needle.empty()) {
        return true;
    }
    return ToLowerInvariant(value).find(ToLowerInvariant(needle)) != std::wstring::npos;
}

int FindAudioCaptureDeviceByName(const std::wstring& requestedName)
{
    if (!g_audioCapture || requestedName.empty()) {
        return -1;
    }

    const auto& names = g_audioCapture->GetCaptureDeviceNames();
    const std::wstring requestedLower = ToLowerInvariant(requestedName);
    for (size_t i = 0; i < names.size(); ++i) {
        if (ToLowerInvariant(names[i]) == requestedLower) {
            return static_cast<int>(i);
        }
    }

    for (size_t i = 0; i < names.size(); ++i) {
        if (ContainsText(names[i], requestedName) || ContainsText(requestedName, names[i])) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

int FindStereoMixAudioDevice()
{
    if (!g_audioCapture) {
        return -1;
    }

    const auto& names = g_audioCapture->GetCaptureDeviceNames();
    for (size_t i = 0; i < names.size(); ++i) {
        if (ContainsText(names[i], L"Stereo Mix")) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

bool LooksLikeUsbCamera(const wchar_t* cameraName, const wchar_t* devicePath)
{
    const std::wstring name = cameraName ? cameraName : L"";
    const std::wstring path = devicePath ? devicePath : L"";
    return ContainsText(name, L"USB") || ContainsText(path, L"usb#") || ContainsText(path, L"vid_");
}

int FindCameraMicrophoneDevice(const wchar_t* cameraName, const wchar_t* devicePath)
{
    if (!g_audioCapture) {
        return -1;
    }

    const std::wstring camera = cameraName ? cameraName : L"";
    const auto& names = g_audioCapture->GetCaptureDeviceNames();

    if (!camera.empty()) {
        for (size_t i = 0; i < names.size(); ++i) {
            if (ContainsText(names[i], camera)) {
                return static_cast<int>(i);
            }
        }
    }

    if (LooksLikeUsbCamera(cameraName, devicePath)) {
        for (size_t i = 0; i < names.size(); ++i) {
            if (ContainsText(names[i], L"microphone") &&
                ContainsText(names[i], L"usb") &&
                ContainsText(names[i], L"camera")) {
                return static_cast<int>(i);
            }
        }
    }

    return -1;
}

void SelectAudioCaptureDevice(int captureIndex, bool save, const wchar_t* reason)
{
    if (!g_audioCapture) {
        return;
    }

    const auto& names = g_audioCapture->GetCaptureDeviceNames();
    if (captureIndex < 0 || static_cast<size_t>(captureIndex) >= names.size()) {
        g_audioCapture->StopCapture();
        g_audioCaptureDeviceName.clear();
        UI_SetCurrentAudioDeviceId(ID_AUDIO_DEVICE_NONE);
        if (save) {
            SaveSettings();
        }
        VirtuaCamLog::LogLine(std::format(
            L"Audio source selected: None reason={}",
            reason ? reason : L""));
        return;
    }

    HRESULT hr = g_audioCapture->StartCapture(captureIndex, false);
    if (FAILED(hr)) {
        UI_SetCurrentAudioDeviceId(ID_AUDIO_DEVICE_NONE);
        VirtuaCamLog::LogHr(std::format(
            L"Audio source failed: {} reason={}",
            names[captureIndex],
            reason ? reason : L""),
            hr);
        return;
    }

    g_audioCaptureDeviceName = names[captureIndex];
    UI_SetCurrentAudioDeviceId(ID_AUDIO_CAPTURE_FIRST + captureIndex);
    if (save) {
        SaveSettings();
    }
    VirtuaCamLog::LogLine(std::format(
        L"Audio source selected: {} reason={}",
        g_audioCaptureDeviceName,
        reason ? reason : L""));
}

void SelectAudioMenuId(int id, bool save, const wchar_t* reason)
{
    if (id == ID_AUDIO_DEVICE_AUTO) {
        g_audioRoutingMode = AudioRoutingMode::Auto;
        ApplySavedAudioSelection();
        if (save) {
            SaveSettings();
        }
        VirtuaCamLog::LogLine(L"Audio routing mode selected: Auto");
        return;
    }

    g_audioRoutingMode = AudioRoutingMode::Manual;
    if (id == ID_AUDIO_DEVICE_NONE) {
        SelectAudioCaptureDevice(-1, save, reason);
        return;
    }

    if (id >= ID_AUDIO_CAPTURE_FIRST) {
        SelectAudioCaptureDevice(id - ID_AUDIO_CAPTURE_FIRST, save, reason);
    }
}

void ApplySavedAudioSelection()
{
    if (!g_audioCapture) {
        return;
    }

    int index = -1;
    if (g_audioRoutingMode == AudioRoutingMode::Manual) {
        index = FindAudioCaptureDeviceByName(g_audioCaptureDeviceName);
        if (index < 0 && !g_audioCaptureDeviceName.empty()) {
            VirtuaCamLog::LogLine(std::format(
                L"Saved audio source missing: {}; falling back to Stereo Mix",
                g_audioCaptureDeviceName));
        }
    }
    if (index < 0) {
        index = FindStereoMixAudioDevice();
    }
    if (g_audioRoutingMode == AudioRoutingMode::Auto) {
        UI_SetCurrentAudioDeviceId(ID_AUDIO_DEVICE_AUTO);
    }
    SelectAudioCaptureDevice(index, true, L"startup default");
    if (g_audioRoutingMode == AudioRoutingMode::Auto) {
        UI_SetCurrentAudioDeviceId(ID_AUDIO_DEVICE_AUTO);
    }
}

void InitializeAudio()
{
    g_audioCapture = std::make_unique<WASAPICapture>();
    if (FAILED(g_audioCapture->EnumerateCaptureDevices())) {
        VirtuaCamLog::LogLine(L"Audio capture enumeration failed");
        g_audioCapture.reset();
        return;
    }

    UI_UpdateAudioDeviceLists(g_audioCapture->GetCaptureDeviceNames());
    UI_SetAudioSelectionCallback([](int id) {
        SelectAudioMenuId(id, true, L"menu");
    });
    ApplySavedAudioSelection();
}

void SelectAudioForCameraPassthrough(int cameraIndex)
{
    if (!g_audioCapture) {
        return;
    }
    if (g_audioRoutingMode != AudioRoutingMode::Auto) {
        VirtuaCamLog::LogLine(L"Camera passthrough audio: manual audio route active");
        return;
    }

    const wchar_t* cameraName = UI_GetCameraDeviceName(cameraIndex);
    const wchar_t* devicePath = UI_GetCameraDevicePath(cameraIndex);
    if (!LooksLikeUsbCamera(cameraName, devicePath)) {
        return;
    }

    const int micIndex = FindCameraMicrophoneDevice(cameraName, devicePath);
    if (micIndex < 0) {
        VirtuaCamLog::LogLine(std::format(
            L"Camera passthrough audio: no matching USB webcam mic found for {}",
            cameraName ? cameraName : L""));
        return;
    }

    SelectAudioCaptureDevice(micIndex, true, L"camera passthrough");
    UI_SetCurrentAudioDeviceId(ID_AUDIO_DEVICE_AUTO);
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

    UINT64 brokerNonce = 0;
    if (FAILED(BCryptGenRandom(
            nullptr,
            reinterpret_cast<PUCHAR>(&brokerNonce),
            sizeof(brokerNonce),
            BCRYPT_USE_SYSTEM_PREFERRED_RNG)) ||
        brokerNonce == 0) {
        LARGE_INTEGER counter = {};
        QueryPerformanceCounter(&counter);
        brokerNonce = (static_cast<UINT64>(GetCurrentProcessId()) << 32) ^
            static_cast<UINT64>(counter.QuadPart) ^
            GetTickCount64();
    }

    std::wstring argsWithBroker = std::format(
        L"{} --broker-pid {} --broker-nonce {}",
        args,
        GetCurrentProcessId(),
        brokerNonce);
    std::wstring cmdLine = std::format(L"\"{}\" {}", exePath, argsWithBroker);
    if (g_debugLoggingEnabled) {
        cmdLine += L" -debug";
    }
    VirtuaCamLog::LogLine(std::format(L"LaunchProducer request: key={} args={}", key, argsWithBroker));
    std::vector<wchar_t> cmdLineMutable(cmdLine.begin(), cmdLine.end());
    cmdLineMutable.push_back(L'\0');

    if (CreateProcessW(exePath.c_str(), cmdLineMutable.data(), NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
    {
        g_producerProcesses[key] = pi;
        if (g_pfnRegisterExpectedProducer) {
            g_pfnRegisterExpectedProducer(pi.dwProcessId, brokerNonce);
        }
        VirtuaCamLog::LogLine(std::format(L"LaunchProducer success: key={} pid={} args={}", key, pi.dwProcessId, argsWithBroker));
        Sleep(200);
        return pi.dwProcessId;
    }
    VirtuaCamLog::LogLine(std::format(L"LaunchProducer failed: key={} args={}", key, argsWithBroker));
    VirtuaCamLog::LogWin32(std::format(L"CreateProcessW failed: {}", exePath), GetLastError());
    return 0;
}

std::wstring QuoteProcessArg(const std::wstring& value)
{
    std::wstring quoted = L"\"";
    for (wchar_t ch : value) {
        if (ch == L'\"' || ch == L'\\') {
            quoted.push_back(L'\\');
        }
        quoted.push_back(ch);
    }
    quoted.push_back(L'\"');
    return quoted;
}

bool TryLaunchWindowProducer(
    const std::wstring& key,
    DWORD_PTR context,
    DWORD& outPid,
    HWND& outHwnd)
{
    outPid = 0;
    outHwnd = reinterpret_cast<HWND>(context);

    VirtuaCamLog::LogLine(std::format(
        L"Window source request: key={} hwnd={}",
        key,
        static_cast<UINT64>(reinterpret_cast<UINT_PTR>(outHwnd))));

    if (!outHwnd) {
        VirtuaCamLog::LogLine(std::format(L"Skip window producer launch: {} received null hwnd", key));
        return false;
    }

    if (!IsWindow(outHwnd)) {
        VirtuaCamLog::LogLine(std::format(L"Skip window producer launch: {} received stale hwnd {}", key, static_cast<UINT64>(reinterpret_cast<UINT_PTR>(outHwnd))));
        outHwnd = nullptr;
        return false;
    }

    outPid = LaunchProducer(
        key,
        L"--type capture --hwnd " + std::to_wstring(static_cast<UINT64>(reinterpret_cast<UINT_PTR>(outHwnd))));
    return outPid != 0;
}

void SetSourceMode(SourceMode newMode, DWORD_PTR context = 0) {
    if (newMode == g_mainSourceState.mode && newMode != SourceMode::Window && newMode != SourceMode::Camera) return;

    VirtuaCamLog::LogLine(std::format(
        L"Main source selection: mode={} context={}",
        SourceModeToString(newMode),
        static_cast<UINT64>(context)));

    g_mainSourceState.pid = 0;
    g_mainSourceState.cameraIndex = -1;
    g_mainSourceState.displayIndex = -1;
    g_mainSourceState.filePath.clear();
    TerminateProducer(L"main_camera");
    TerminateProducer(L"main_window");
    TerminateProducer(L"main_display");
    TerminateProducer(L"main_media");
    g_mainSourceState.hwnd = nullptr;
    g_mainSourceState.mode = SourceMode::Off;
    InformBroker();
    ForceDefaultBrokerFrameToDriver(L"source switch clear");

    switch (newMode) {
        case SourceMode::Camera:
            g_mainSourceState.cameraIndex = static_cast<int>(context);
            if (const wchar_t* devicePath = UI_GetCameraDevicePath(g_mainSourceState.cameraIndex)) {
                ULONG cameraMask = 0;
                AspectRatioMode firstSupportedAspect = AspectRatioMode::R16_9;
                if (TryScanCameraAspectMask(devicePath, cameraMask, firstSupportedAspect)) {
                    SetAllowedAspectRatioMask(cameraMask, L"main camera passthrough");
                    if ((cameraMask & AspectRatioMask(g_aspectRatioMode)) == 0) {
                        g_aspectRatioMode = firstSupportedAspect;
                        SaveSettings();
                        VirtuaCamLog::LogLine(std::format(
                            L"Aspect ratio auto-selected for camera passthrough: {} allowedMask=0x{:X}",
                            VirtuaCamConfig::AspectRatioName(g_aspectRatioMode),
                            cameraMask));
                    }
                } else {
                    SetAllowedAspectRatioMask(ASPECT_RATIO_MASK_ALL, L"main camera scan failed");
                    VirtuaCamLog::LogLine(L"Camera aspect scan failed; allowing all VirtuaCam ratios");
                }

                g_mainSourceState.pid = LaunchProducer(
                    L"main_camera",
                    std::format(L"--type camera --device-path \"{}\"", devicePath));
            } else {
                SetAllowedAspectRatioMask(ASPECT_RATIO_MASK_ALL, L"main camera no device path");
                // Fallback: old index-based selection (best-effort).
                g_mainSourceState.pid = LaunchProducer(
                    L"main_camera",
                    L"--type camera --device " + std::to_wstring(g_mainSourceState.cameraIndex));
            }
            SelectAudioForCameraPassthrough(g_mainSourceState.cameraIndex);
            break;
        case SourceMode::Window:
            SetAllowedAspectRatioMask(ASPECT_RATIO_MASK_ALL, L"main window source");
            if (!TryLaunchWindowProducer(L"main_window", context, g_mainSourceState.pid, g_mainSourceState.hwnd)) {
                newMode = SourceMode::Off;
            }
            break;
        case SourceMode::Display:
            SetAllowedAspectRatioMask(ASPECT_RATIO_MASK_ALL, L"main display source");
            g_mainSourceState.displayIndex = static_cast<int>(context);
            g_mainSourceState.pid = LaunchProducer(
                L"main_display",
                L"--type capture --monitor " + std::to_wstring(g_mainSourceState.displayIndex));
            if (g_mainSourceState.pid == 0) {
                newMode = SourceMode::Off;
                g_mainSourceState.displayIndex = -1;
            }
            break;
        case SourceMode::Discovered:
            SetAllowedAspectRatioMask(ASPECT_RATIO_MASK_ALL, L"main non-camera source");
            g_mainSourceState.pid = static_cast<DWORD>(context);
            break;
        case SourceMode::Off:
        default:
            SetAllowedAspectRatioMask(ASPECT_RATIO_MASK_ALL, L"main source off");
            break;
    }
    g_mainSourceState.mode = newMode;
    VirtuaCamLog::LogLine(std::format(
        L"Main source active: mode={} pid={} cameraIndex={} hwnd={}",
        SourceModeToString(g_mainSourceState.mode),
        g_mainSourceState.pid,
        g_mainSourceState.cameraIndex,
        static_cast<UINT64>(reinterpret_cast<UINT_PTR>(g_mainSourceState.hwnd))));
    InformBroker();
    ApplyDriverAspectPolicy();
}

void SetSourceFileMode(SourceMode newMode, const std::wstring& path)
{
    if ((newMode != SourceMode::Image && newMode != SourceMode::Video) || path.empty()) {
        return;
    }

    SetAllowedAspectRatioMask(ASPECT_RATIO_MASK_ALL, newMode == SourceMode::Image ? L"main image source" : L"main video source");
    g_mainSourceState.pid = 0;
    g_mainSourceState.cameraIndex = -1;
    g_mainSourceState.displayIndex = -1;
    g_mainSourceState.hwnd = nullptr;
    g_mainSourceState.filePath = path;
    TerminateProducer(L"main_camera");
    TerminateProducer(L"main_window");
    TerminateProducer(L"main_display");
    TerminateProducer(L"main_media");
    g_mainSourceState.mode = SourceMode::Off;
    InformBroker();
    ForceDefaultBrokerFrameToDriver(L"file source switch clear");

    g_mainSourceState.pid = LaunchProducer(
        L"main_media",
        std::format(
            L"--type media --media-kind {} --file {}",
            newMode == SourceMode::Image ? L"image" : L"video",
            QuoteProcessArg(path)));
    g_mainSourceState.mode = (g_mainSourceState.pid != 0) ? newMode : SourceMode::Off;
    VirtuaCamLog::LogLine(std::format(
        L"Main source active: mode={} pid={} file={}",
        SourceModeToString(g_mainSourceState.mode),
        g_mainSourceState.pid,
        path));
    InformBroker();
    ApplyDriverAspectPolicy();
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

    VirtuaCamLog::LogLine(std::format(
        L"PIP source selection: slot={} mode={} context={}",
        PipPositionToString(pos),
        SourceModeToString(newMode),
        static_cast<UINT64>(context)));

    state.pid = 0;
    state.cameraIndex = -1;
    state.displayIndex = -1;
    state.filePath.clear();
    std::wstring key_prefix = L"pip_" + std::to_wstring((int)pos);
    TerminateProducer(key_prefix + L"_camera");
    TerminateProducer(key_prefix + L"_window");
    state.hwnd = nullptr;

    switch (newMode) {
        case SourceMode::Camera:
            state.cameraIndex = static_cast<int>(context);
            if (const wchar_t* devicePath = UI_GetCameraDevicePath(state.cameraIndex)) {
                state.pid = LaunchProducer(
                    key_prefix + L"_camera",
                    std::format(L"--type camera --device-path \"{}\"", devicePath));
            } else {
                state.pid = LaunchProducer(
                    key_prefix + L"_camera",
                    L"--type camera --device " + std::to_wstring(state.cameraIndex));
            }
            break;
        case SourceMode::Window:
            if (!TryLaunchWindowProducer(key_prefix + L"_window", context, state.pid, state.hwnd)) {
                newMode = SourceMode::Off;
            }
            break;
        case SourceMode::Discovered:
            state.pid = static_cast<DWORD>(context);
            break;
        case SourceMode::Off:
        default:
             break;
    }
    state.mode = newMode;
    VirtuaCamLog::LogLine(std::format(
        L"PIP source active: slot={} mode={} pid={} cameraIndex={} hwnd={}",
        PipPositionToString(pos),
        SourceModeToString(state.mode),
        state.pid,
        state.cameraIndex,
        static_cast<UINT64>(reinterpret_cast<UINT_PTR>(state.hwnd))));
    InformBroker();
}

int APIENTRY wWinMain(_In_ HINSTANCE hInstance, _In_opt_ HINSTANCE, _In_ LPWSTR, _In_ int) {
    const std::wstring cmdLine = GetCommandLineW() ? GetCommandLineW() : L"";
    g_debugLoggingEnabled = HasArg(cmdLine, L"-debug");

    VirtuaCamLog::InitOptions logOpts;
    logOpts.logFileName = L"virtuacam-runtime.log";
    logOpts.attachConsole = true;
    logOpts.allocConsoleIfMissing = false;
    logOpts.enabled = g_debugLoggingEnabled;
    VirtuaCamLog::Init(logOpts);

    if (HasArg(cmdLine, L"--windows")) {
        return PrintCapturableWindowsJson();
    }

    g_silentStart = HasArg(cmdLine, L"/startup") || HasArg(cmdLine, L"-startup");
    if (g_silentStart) {
        VirtuaCamLog::LogLine(L"Startup mode: /startup (tray-silent)");
    }

    LoadSettings();
    if (g_startDebugMode && !g_debugLoggingEnabled) {
        g_debugLoggingEnabled = true;
        VirtuaCamLog::Shutdown();
        logOpts.enabled = true;
        VirtuaCamLog::Init(logOpts);
        VirtuaCamLog::LogLine(L"Debug mode enabled from settings");
    }
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

    UI_Initialize(hInstance, g_hMainWnd);
    UI_SetDebugMode(g_debugLoggingEnabled);
    if (!g_hMainWnd) {
        ShutdownSystem(); CoUninitialize(); return FALSE;
    }

    InitializeAudio();
    SetTimer(g_hMainWnd, 1, 1000, nullptr);
    UINT64 startupWindowHwnd = 0;
    UINT64 startupCameraIndex = 0;
    UINT64 startupDisplayIndex = 0;
    if (TryGetArgU64(cmdLine, L"--source-window-hwnd", startupWindowHwnd)) {
        VirtuaCamLog::LogLine(std::format(L"Startup source: window hwnd={}", startupWindowHwnd));
        SetSourceMode(SourceMode::Window, static_cast<DWORD_PTR>(startupWindowHwnd));
    } else if (TryGetArgU64(cmdLine, L"--source-display-index", startupDisplayIndex)) {
        VirtuaCamLog::LogLine(std::format(L"Startup source: display index={}", startupDisplayIndex));
        SetSourceMode(SourceMode::Display, static_cast<DWORD_PTR>(startupDisplayIndex));
    } else if (TryGetArgU64(cmdLine, L"--source-camera-index", startupCameraIndex)) {
        const auto cameras = UI_RefreshCameraDeviceList();
        if (startupCameraIndex < cameras.size()) {
            VirtuaCamLog::LogLine(std::format(
                L"Startup source: camera index={} name={}",
                startupCameraIndex,
                cameras[static_cast<size_t>(startupCameraIndex)]));
            SetSourceMode(SourceMode::Camera, static_cast<DWORD_PTR>(startupCameraIndex));
        } else {
            VirtuaCamLog::LogLine(std::format(
                L"Startup source camera index out of range: {} cameraCount={}",
                startupCameraIndex,
                cameras.size()));
            SetSourceMode(SourceMode::Off, 0);
        }
    } else {
        VirtuaCamLog::LogLine(L"Startup source: off");
        SetSourceMode(SourceMode::Off, 0);
    }
    InformBroker();

    g_driverBridge = std::make_unique<DriverBridge>();
    HRESULT hrDriver = g_driverBridge->Initialize();
    if (FAILED(hrDriver)) {
        VirtuaCamLog::LogHr(L"DriverBridge::Initialize failed", hrDriver);
        VirtuaCamLog::LogLine(std::format(L"DriverBridge last error: {}", g_driverBridge->GetLastError()));
        if (!g_silentStart) {
            std::wstring message =
                L"DriverBridge failed to connect to the avshws kernel driver.\n"
                L"Make sure driver-project is installed.";
            VirtuaCamLog::ShowAndLogError(g_hMainWnd, message.c_str(), L"Error", hrDriver);
        }
    } else {
        ApplyDriverAspectPolicy();
    }

    VirtuaCamLog::LogLine(L"Entering message loop.");
    UI_RunMessageLoop(OnIdle);

    ShutdownSystem();
    CoUninitialize();
    return 0;
}

void OnIdle() {
    static ULONGLONG s_nextFrameTick = 0;
    static BrokerState s_lastBrokerState = BrokerState::Searching;
    static bool s_lastDriverActive = false;
    static ULONGLONG s_driverInactiveSinceTick = 0;
    const ULONGLONG now = GetTickCount64();
    const ULONGLONG frameIntervalMs = (s_lastDriverActive && s_lastBrokerState == BrokerState::Connected)
        ? kAppFrameIntervalMs
        : kDefaultFeedRefreshMs;
    if (s_nextFrameTick != 0 && now < s_nextFrameTick) {
        return;
    }
    s_nextFrameTick = now + frameIntervalMs;

    BrokerState brokerState = BrokerState::Searching;
    const bool brokerFrameRendered = (g_pfnRenderBrokerFrame != nullptr);
    if (brokerFrameRendered) {
        g_pfnRenderBrokerFrame();
    }

    if (g_pfnGetBrokerState) {
        brokerState = g_pfnGetBrokerState();
        const bool driverActive = GetDriverBridgeStatus();
        UpdateTelemetry(brokerState, driverActive);
        if (driverActive) {
            s_driverInactiveSinceTick = 0;
        } else if (g_silentStart) {
            if (s_driverInactiveSinceTick == 0) {
                s_driverInactiveSinceTick = now;
            } else if (now - s_driverInactiveSinceTick >= kSilentDriverInactiveExitMs) {
                VirtuaCamLog::LogLine(L"Startup mode: driver inactive for 5 minutes; exiting app while watcher remains active");
                PostMessageW(g_hMainWnd, WM_CLOSE, 0, 0);
                return;
            }
        }
        s_lastBrokerState = brokerState;
        s_lastDriverActive = driverActive;
    }
    const UINT64 brokerFrameValue = g_pfnGetBrokerFrameValue ? g_pfnGetBrokerFrameValue() : 0;
    TrySendBrokerFrameToDriver(brokerFrameRendered, brokerState, brokerFrameValue);
}

void TrySendBrokerFrameToDriver(bool brokerFrameRendered, BrokerState brokerState, UINT64 brokerFrameValue) {
    static bool s_loggedNullTexture = false;
    static bool s_loggedFirstTexture = false;
    static bool s_loggedDefaultFeed = false;
    static UINT s_driverWarmupRetryLogCount = 0;
    static UINT s_driverReadbackRetryLogCount = 0;
    static bool s_hasSentFrame = false;
    static UINT64 s_lastSentFrameValue = 0;
    static ULONGLONG s_lastDefaultFeedSendTick = 0;

    if (!brokerFrameRendered || !g_driverBridge || !g_driverBridge->IsActive() || !g_pfnGetSharedTexture) {
        return;
    }

    if (brokerState != BrokerState::Connected) {
        if (!s_loggedDefaultFeed) {
            VirtuaCamLog::LogLine(L"Broker has no live producer; sending generated default feed to DriverBridge");
            s_loggedDefaultFeed = true;
        }
        const ULONGLONG now = GetTickCount64();
        if (s_hasSentFrame &&
            brokerFrameValue == s_lastSentFrameValue &&
            s_lastDefaultFeedSendTick != 0 &&
            now - s_lastDefaultFeedSendTick < kDefaultFeedRefreshMs) {
            return;
        }
    }
    else {
        s_loggedDefaultFeed = false;
        if (s_hasSentFrame && brokerFrameValue != 0 && brokerFrameValue == s_lastSentFrameValue) {
            return;
        }
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
    if (!s_loggedFirstTexture) {
        VirtuaCamLog::LogLine(L"First broker shared texture acquired; sending frames to DriverBridge");
        s_loggedFirstTexture = true;
    }

    HRESULT hr = g_driverBridge->SendFrame(sharedTexture.get());
    if (FAILED(hr)) {
        if (hr == DXGI_ERROR_WAS_STILL_DRAWING) {
            ++s_driverReadbackRetryLogCount;
            if (s_driverReadbackRetryLogCount == 1 || (s_driverReadbackRetryLogCount % 120) == 0) {
                VirtuaCamLog::LogLine(L"DriverBridge::SendFrame readback not ready");
            }
        } else if (hr == HRESULT_FROM_WIN32(ERROR_RETRY)) {
            ++s_driverWarmupRetryLogCount;
            if (s_driverWarmupRetryLogCount == 1 || (s_driverWarmupRetryLogCount % 120) == 0) {
                VirtuaCamLog::LogLine(L"DriverBridge::SendFrame waiting for driver stream to start");
            }
        } else {
            VirtuaCamLog::LogHr(L"DriverBridge::SendFrame failed", hr);
        }
    } else {
        s_driverWarmupRetryLogCount = 0;
        s_driverReadbackRetryLogCount = 0;
        s_hasSentFrame = true;
        s_lastSentFrameValue = brokerFrameValue;
        if (brokerState != BrokerState::Connected) {
            s_lastDefaultFeedSendTick = GetTickCount64();
        }
    }
}

void ForceDefaultBrokerFrameToDriver(const wchar_t* reason)
{
    if (!g_pfnSetCompositingMode || !g_pfnUpdateProducerPriorityList || !g_pfnRenderBrokerFrame || !g_pfnGetBrokerState || !g_pfnGetBrokerFrameValue) {
        return;
    }

    DWORD pids[5] = {0};
    g_pfnSetCompositingMode(false);
    g_pfnUpdateProducerPriorityList(pids, 5);
    g_pfnRenderBrokerFrame();
    const BrokerState brokerState = g_pfnGetBrokerState();
    const UINT64 brokerFrameValue = g_pfnGetBrokerFrameValue();
    VirtuaCamLog::LogLine(std::format(
        L"Forced default broker frame: reason={} brokerState={} frameValue={}",
        reason ? reason : L"",
        static_cast<int>(brokerState),
        brokerFrameValue));
    TrySendBrokerFrameToDriver(true, brokerState, brokerFrameValue);
}

void InformBroker() {
    if (!g_discovery || !g_pfnUpdateProducerPriorityList || !g_pfnSetCompositingMode) return;

    g_discovery->DiscoverStreams();
    g_pfnSetCompositingMode(false);

    DWORD pids[5] = {0};
    pids[0] = g_mainSourceState.pid;
    pids[1] = g_pip_tl_state.pid;
    pids[2] = g_pip_tr_state.pid;
    pids[3] = g_pip_bl_state.pid;
    pids[4] = g_pip_br_state.pid;
    g_pfnUpdateProducerPriorityList(pids, 5);
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
    g_pfnGetBrokerFrameValue = (PFN_GetBrokerFrameValue)GetProcAddress(g_hBrokerDll, "GetBrokerFrameValue");
    g_pfnUpdateProducerPriorityList = (PFN_UpdateProducerPriorityList)GetProcAddress(g_hBrokerDll, "UpdateProducerPriorityList");
    g_pfnRegisterExpectedProducer = (PFN_RegisterExpectedProducer)GetProcAddress(g_hBrokerDll, "RegisterExpectedProducer");
    g_pfnSetCompositingMode = (PFN_SetCompositingMode)GetProcAddress(g_hBrokerDll, "SetCompositingMode");
    if (!g_pfnInitializeBroker || !g_pfnShutdownBroker || !g_pfnRenderBrokerFrame || !g_pfnGetSharedTexture || !g_pfnGetBrokerState || !g_pfnGetBrokerFrameValue || !g_pfnUpdateProducerPriorityList || !g_pfnRegisterExpectedProducer || !g_pfnSetCompositingMode) {
        VirtuaCamLog::LogLine(L"DirectPortBroker.dll missing expected exports");
        return E_FAIL;
    }
    g_pfnInitializeBroker();
    VirtuaCamLog::LogLine(L"DirectPortBroker initialized");
    return S_OK;
}

void ShutdownSystem() {
    RequestDriverDisconnect();

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

void RequestDriverDisconnect()
{
    if (g_disconnectAttempted) {
        return;
    }
    g_disconnectAttempted = true;

    if (!g_driverBridge || !g_driverBridge->IsActive()) {
        return;
    }

    HRESULT hr = g_driverBridge->Disconnect();
    if (FAILED(hr)) {
        VirtuaCamLog::LogHr(L"DriverBridge::Disconnect failed", hr);
    } else if (hr == S_FALSE) {
        VirtuaCamLog::LogLine(L"DriverBridge::Disconnect skipped (unsupported by current driver)");
    } else {
        VirtuaCamLog::LogLine(L"DriverBridge::Disconnect succeeded");
    }
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
    (void)VirtuaCamConfig::DeleteLegacySettingsFile();
    const VirtuaCamConfig::AppSettings settings = VirtuaCamConfig::LoadSettings();
    g_showPipTL = settings.showPipTopLeft;
    g_showPipTR = settings.showPipTopRight;
    g_showPipBL = settings.showPipBottomLeft;
    g_startDebugMode = settings.startDebugMode;
    g_aspectRatioMode = settings.aspectRatio;
    g_audioRoutingMode = settings.audioRoutingMode;
    g_audioCaptureDeviceName = settings.audioCaptureDeviceName;

    VirtuaCamLog::LogLine(std::format(
        L"Settings loaded: registry={} debug={} aspect={} audioMode={} audio={}",
        VirtuaCamConfig::GetSettingsRegistryPath(),
        g_startDebugMode ? L"on" : L"off",
        VirtuaCamConfig::AspectRatioName(g_aspectRatioMode),
        VirtuaCamConfig::AudioRoutingModeName(g_audioRoutingMode),
        g_audioCaptureDeviceName.empty() ? L"None" : g_audioCaptureDeviceName));
}

void SaveSettings() {
    const VirtuaCamConfig::AppSettings existing = VirtuaCamConfig::LoadSettings();
    VirtuaCamConfig::AppSettings settings = {};
    settings.showPipTopLeft = g_showPipTL;
    settings.showPipTopRight = g_showPipTR;
    settings.showPipBottomLeft = g_showPipBL;
    settings.startDebugMode = existing.startDebugMode;
    settings.aspectRatio = g_aspectRatioMode;
    settings.audioRoutingMode = g_audioRoutingMode;
    settings.audioCaptureDeviceName = g_audioCaptureDeviceName;
    (void)VirtuaCamConfig::SaveSettings(settings);
}

bool TryGetArgU64(const std::wstring& cmdLine, const wchar_t* arg, UINT64& outValue)
{
    outValue = 0;

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(cmdLine.c_str(), &argc);
    if (!argv) {
        return false;
    }

    bool found = false;
    for (int i = 1; i < argc; ++i) {
        if (!argv[i] || _wcsicmp(argv[i], arg) != 0 || (i + 1) >= argc || !argv[i + 1]) {
            continue;
        }

        wchar_t* end = nullptr;
        const UINT64 parsed = wcstoull(argv[i + 1], &end, 10);
        if (end && end != argv[i + 1]) {
            outValue = parsed;
            found = true;
        }
        break;
    }

    LocalFree(argv);
    return found;
}

bool HasArg(const std::wstring& cmdLine, const wchar_t* arg)
{
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(cmdLine.c_str(), &argc);
    if (!argv) {
        return false;
    }

    bool found = false;
    for (int i = 1; i < argc; ++i) {
        if (argv[i] && _wcsicmp(argv[i], arg) == 0) {
            found = true;
            break;
        }
    }

    LocalFree(argv);
    return found;
}

std::wstring JsonEscape(const std::wstring& value)
{
    std::wstring out;
    out.reserve(value.size() + 8);
    for (wchar_t ch : value) {
        switch (ch) {
        case L'\\': out += L"\\\\"; break;
        case L'"': out += L"\\\""; break;
        case L'\b': out += L"\\b"; break;
        case L'\f': out += L"\\f"; break;
        case L'\n': out += L"\\n"; break;
        case L'\r': out += L"\\r"; break;
        case L'\t': out += L"\\t"; break;
        default:
            if (ch < 0x20) {
                wchar_t escaped[7] = {};
                swprintf_s(escaped, L"\\u%04x", static_cast<unsigned int>(ch));
                out += escaped;
            } else {
                out += ch;
            }
            break;
        }
    }
    return out;
}

bool WriteStdoutText(const std::wstring& text)
{
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (!output || output == INVALID_HANDLE_VALUE) {
        AttachConsole(ATTACH_PARENT_PROCESS);
        output = GetStdHandle(STD_OUTPUT_HANDLE);
    }
    if (!output || output == INVALID_HANDLE_VALUE) {
        return false;
    }

    DWORD mode = 0;
    if (GetConsoleMode(output, &mode)) {
        DWORD written = 0;
        return WriteConsoleW(output, text.c_str(), static_cast<DWORD>(text.size()), &written, nullptr) != FALSE;
    }

    const int bytesNeeded = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (bytesNeeded <= 0) {
        return false;
    }

    std::string utf8(static_cast<size_t>(bytesNeeded), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), utf8.data(), bytesNeeded, nullptr, nullptr);
    DWORD written = 0;
    return WriteFile(output, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr) != FALSE;
}

int PrintCapturableWindowsJson()
{
    const auto windows = EnumerateWindows();
    std::wstring json = L"[\r\n";
    for (size_t i = 0; i < windows.size(); ++i) {
        DWORD pid = 0;
        GetWindowThreadProcessId(windows[i].hwnd, &pid);
        json += L"  {\"hwnd\":";
        json += std::to_wstring(static_cast<UINT64>(reinterpret_cast<UINT_PTR>(windows[i].hwnd)));
        json += L",\"pid\":";
        json += std::to_wstring(pid);
        json += L",\"title\":\"";
        json += JsonEscape(windows[i].title);
        json += L"\"}";
        if (i + 1 < windows.size()) {
            json += L",";
        }
        json += L"\r\n";
    }
    json += L"]\r\n";
    return WriteStdoutText(json) ? 0 : 1;
}
