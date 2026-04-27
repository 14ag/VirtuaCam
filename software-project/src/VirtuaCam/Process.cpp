#include "pch.h"
#include "Process.h"
#include "Resource.h"
#include "RuntimeLog.h"
#include "Tools.h"
#include <string>
#include <sstream>
#include <map>
#include <roapi.h>
#include <winstring.h>
#include <wrl.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <sddl.h>
#include <atomic>
#include <tlhelp32.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.foundation.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "runtimeobject.lib")

using Microsoft::WRL::ComPtr;

namespace
{
    constexpr wchar_t kClientRequestEventName[] = L"VirtuaCamClientRequest";
    constexpr DWORD kWatcherOpenRetryMs = 1000;
    constexpr DWORD kProducerIdleWaitMs = 1;

    struct HString
    {
        HSTRING value = nullptr;
        HString() = default;
        ~HString() { if (value) { WindowsDeleteString(value); } }
        HString(HString const&) = delete;
        HString& operator=(HString const&) = delete;
        HString(HString&& other) noexcept { value = other.value; other.value = nullptr; }
        HString& operator=(HString&& other) noexcept
        {
            if (this != &other) {
                if (value) WindowsDeleteString(value);
                value = other.value;
                other.value = nullptr;
            }
            return *this;
        }
    };

    HRESULT MakeHString(const wchar_t* str, HString& out)
    {
        if (!str) {
            return E_INVALIDARG;
        }
        return WindowsCreateString(str, static_cast<UINT32>(wcslen(str)), &out.value);
    }

    std::vector<std::wstring> SplitArgs(const std::wstring& args)
    {
        // CommandLineToArgvW expects a full command line including a program name.
        std::wstring cmdLine = L"VirtuaCamProcess.exe ";
        cmdLine += args;

        int argc = 0;
        LPWSTR* argv = CommandLineToArgvW(cmdLine.c_str(), &argc);
        if (!argv || argc <= 1) {
            if (argv) LocalFree(argv);
            return {};
        }

        std::vector<std::wstring> tokens;
        for (int i = 1; i < argc; ++i) {
            if (argv[i]) tokens.emplace_back(argv[i]);
        }
        LocalFree(argv);
        return tokens;
    }

    bool TryGetArgValue(const std::wstring& args, const wchar_t* key, std::wstring& outValue)
    {
        outValue.clear();
        auto tokens = SplitArgs(args);
        for (size_t i = 0; i < tokens.size(); ++i) {
            if (tokens[i] == key && (i + 1) < tokens.size()) {
                outValue = tokens[i + 1];
                return true;
            }
        }
        return false;
    }

    bool TryGetArgU64(const std::wstring& args, const wchar_t* key, UINT64& outValue)
    {
        outValue = 0;
        std::wstring s;
        if (!TryGetArgValue(args, key, s)) return false;
        wchar_t* end = nullptr;
        outValue = wcstoull(s.c_str(), &end, 10);
        return end && end != s.c_str();
    }

    bool TryGetArgI32(const std::wstring& args, const wchar_t* key, int& outValue)
    {
        outValue = 0;
        std::wstring s;
        if (!TryGetArgValue(args, key, s)) return false;
        wchar_t* end = nullptr;
        long v = wcstol(s.c_str(), &end, 10);
        if (!(end && end != s.c_str())) return false;
        outValue = static_cast<int>(v);
        return true;
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
}

    bool ParseCommandLine(const WCHAR* cmdLine, std::wstring& type, std::wstring& args)
{
    UNREFERENCED_PARAMETER(cmdLine);

    type.clear();
    args.clear();

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc <= 1) {
        if (argv) LocalFree(argv);
        return false;
    }

    // argv[0] is the executable path.
    for (int i = 1; i < argc; ++i) {
        if (!argv[i]) continue;
        std::wstring token = argv[i];
        if (token == L"--type" && (i + 1) < argc && argv[i + 1]) {
            type = argv[++i];
            continue;
        }

        if (!args.empty()) args += L" ";
        const bool needsQuotes = (token.find_first_of(L" \t\"") != std::wstring::npos);
        if (needsQuotes) {
            std::wstring escaped = token;
            size_t pos = 0;
            while ((pos = escaped.find(L"\"", pos)) != std::wstring::npos) {
                escaped.insert(pos, L"\\");
                pos += 2;
            }
            args += L"\"";
            args += escaped;
            args += L"\"";
        } else {
            args += token;
        }
    }

    LocalFree(argv);
    return !type.empty();
}

namespace BuiltInCaptureProducer
{
    static ComPtr<ID3D11Device> g_d3d11Device;
    static ComPtr<ID3D11Device5> g_d3d11Device5;
    static ComPtr<ID3D11DeviceContext> g_d3d11Context;
    static ComPtr<ID3D11DeviceContext4> g_d3d11Context4;

    static ComPtr<ID3D11Texture2D> g_sharedD3D11Texture;
    static ComPtr<ID3D11Fence> g_sharedD3D11Fence;
    static HANDLE g_hSharedTextureHandle = nullptr;
    static HANDLE g_hSharedFenceHandle = nullptr;
    static HANDLE g_hManifest = nullptr;
    static BroadcastManifest* g_pManifestView = nullptr;
    static std::atomic<UINT64> g_fenceValue = 0;

    static ComPtr<ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice> g_winrtD3dDevice;
    static ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem> g_captureItem;
    static ComPtr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool> g_framePool;
    static ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession> g_session;
    static std::atomic<bool> g_isCapturing = false;
    static bool g_loggedFirstFrame = false;
    static HWND g_captureTargetHwnd = nullptr;

    // Accessor to unwrap IDirect3DSurface -> underlying D3D11 texture.
    struct __declspec(uuid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1")) IDirect3DDxgiInterfaceAccess : public IUnknown
    {
        virtual HRESULT STDMETHODCALLTYPE GetInterface(REFIID riid, void** ppvObject) = 0;
    };

    static void CloseClosable(IInspectable* inspectable)
    {
        if (!inspectable) return;
        ComPtr<ABI::Windows::Foundation::IClosable> closable;
        if (SUCCEEDED(inspectable->QueryInterface(IID_PPV_ARGS(&closable))) && closable) {
            (void)closable->Close();
        }
    }

    static HRESULT InitD3D11()
    {
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        RETURN_IF_FAILED(D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            flags,
            nullptr,
            0,
            D3D11_SDK_VERSION,
            &g_d3d11Device,
            nullptr,
            &g_d3d11Context));
        RETURN_IF_FAILED(g_d3d11Device.As(&g_d3d11Device5));
        RETURN_IF_FAILED(g_d3d11Context.As(&g_d3d11Context4));
        return S_OK;
    }

    static HRESULT InitWgc(HWND hwndToCapture)
    {
        HRESULT hrInit = RoInitialize(RO_INIT_MULTITHREADED);
        if (FAILED(hrInit) && hrInit != RPC_E_CHANGED_MODE) {
            return hrInit;
        }

        // Create GraphicsCaptureItem for HWND.
        HString itemClass;
        RETURN_IF_FAILED(MakeHString(L"Windows.Graphics.Capture.GraphicsCaptureItem", itemClass));

        ComPtr<IActivationFactory> itemFactory;
        RETURN_IF_FAILED(RoGetActivationFactory(itemClass.value, IID_PPV_ARGS(&itemFactory)));

        ComPtr<IGraphicsCaptureItemInterop> interop;
        RETURN_IF_FAILED(itemFactory.As(&interop));

        RETURN_IF_FAILED(interop->CreateForWindow(hwndToCapture, __uuidof(ABI::Windows::Graphics::Capture::IGraphicsCaptureItem), (void**)g_captureItem.ReleaseAndGetAddressOf()));
        RETURN_HR_IF_NULL(E_FAIL, g_captureItem.Get());

        // Create WinRT IDirect3DDevice from our DXGI device.
        ComPtr<IDXGIDevice> dxgiDevice;
        RETURN_IF_FAILED(g_d3d11Device.As(&dxgiDevice));

        ComPtr<IInspectable> inspectableDevice;
        RETURN_IF_FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.Get(), inspectableDevice.ReleaseAndGetAddressOf()));
        RETURN_IF_FAILED(inspectableDevice.As(&g_winrtD3dDevice));

        // Create frame pool via activation factory statics.
        HString framePoolClass;
        RETURN_IF_FAILED(MakeHString(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool", framePoolClass));

        ComPtr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePoolStatics> framePoolStatics;
        RETURN_IF_FAILED(RoGetActivationFactory(framePoolClass.value, IID_PPV_ARGS(&framePoolStatics)));

        ABI::Windows::Graphics::SizeInt32 size{};
        RETURN_IF_FAILED(g_captureItem->get_Size(&size));

        // Prefer the free-threaded frame pool when available (avoids DispatcherQueue requirements).
#if defined(WINDOWS_FOUNDATION_UNIVERSALAPICONTRACT_VERSION) && WINDOWS_FOUNDATION_UNIVERSALAPICONTRACT_VERSION >= 0x70000
        ComPtr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePoolStatics2> framePoolStatics2;
        if (SUCCEEDED(framePoolStatics.As(&framePoolStatics2)) && framePoolStatics2) {
            RETURN_IF_FAILED(framePoolStatics2->CreateFreeThreaded(
                g_winrtD3dDevice.Get(),
                ABI::Windows::Graphics::DirectX::DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized,
                2,
                size,
                g_framePool.ReleaseAndGetAddressOf()));
        } else
#endif
        {
            RETURN_IF_FAILED(framePoolStatics->Create(
                g_winrtD3dDevice.Get(),
                ABI::Windows::Graphics::DirectX::DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized,
                2,
                size,
                g_framePool.ReleaseAndGetAddressOf()));
        }
        RETURN_HR_IF_NULL(E_FAIL, g_framePool.Get());

        RETURN_IF_FAILED(g_framePool->CreateCaptureSession(g_captureItem.Get(), g_session.ReleaseAndGetAddressOf()));
        RETURN_HR_IF_NULL(E_FAIL, g_session.Get());

        RETURN_IF_FAILED(g_session->StartCapture());
        return S_OK;
    }

    static HRESULT InitSharedOutputs(UINT width, UINT height)
    {
        D3D11_TEXTURE2D_DESC td{};
        td.Width = width;
        td.Height = height;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        td.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
        RETURN_IF_FAILED(g_d3d11Device->CreateTexture2D(&td, nullptr, &g_sharedD3D11Texture));
        RETURN_IF_FAILED(g_d3d11Device5->CreateFence(0, D3D11_FENCE_FLAG_SHARED, IID_PPV_ARGS(&g_sharedD3D11Fence)));

        DWORD pid = GetCurrentProcessId();
        std::wstring manifestName = GetProducerManifestName(pid);
        std::wstring texName = GetProducerTextureName(pid);
        std::wstring fenceName = GetProducerFenceName(pid);

        wil::unique_hlocal_security_descriptor sd;
        SECURITY_ATTRIBUTES sa = {};
        RETURN_IF_FAILED(CreateCurrentUserOnlySecurityAttributes(sd, sa));

        g_hManifest = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, sizeof(BroadcastManifest), manifestName.c_str());
        if (!g_hManifest) return HRESULT_FROM_WIN32(GetLastError());
        g_pManifestView = (BroadcastManifest*)MapViewOfFile(g_hManifest, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(BroadcastManifest));
        if (!g_pManifestView) return HRESULT_FROM_WIN32(GetLastError());

        ZeroMemory(g_pManifestView, sizeof(BroadcastManifest));
        g_pManifestView->width = width;
        g_pManifestView->height = height;
        g_pManifestView->format = DXGI_FORMAT_B8G8R8A8_UNORM;

        ComPtr<IDXGIDevice> dxgi;
        g_d3d11Device.As(&dxgi);
        ComPtr<IDXGIAdapter> adapter;
        dxgi->GetAdapter(&adapter);
        DXGI_ADAPTER_DESC desc{};
        adapter->GetDesc(&desc);
        g_pManifestView->adapterLuid = desc.AdapterLuid;

        wcscpy_s(g_pManifestView->textureName, texName.c_str());
        wcscpy_s(g_pManifestView->fenceName, fenceName.c_str());

        ComPtr<IDXGIResource1> r1;
        g_sharedD3D11Texture.As(&r1);
        RETURN_IF_FAILED(r1->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, texName.c_str(), &g_hSharedTextureHandle));
        RETURN_IF_FAILED(g_sharedD3D11Fence->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, fenceName.c_str(), &g_hSharedFenceHandle));

        return S_OK;
    }

    HRESULT InitializeProducer(const wchar_t* args)
    {
        UINT64 hwndVal = 0;
        std::wstring argsStr = args ? args : L"";
        RETURN_HR_IF(E_INVALIDARG, !TryGetArgU64(argsStr, L"--hwnd", hwndVal));
        HWND hwndToCapture = reinterpret_cast<HWND>(hwndVal);
        RETURN_HR_IF_NULL(E_INVALIDARG, hwndToCapture);
        g_captureTargetHwnd = hwndToCapture;

        RETURN_IF_FAILED(InitD3D11());
        RETURN_IF_FAILED(InitWgc(hwndToCapture));

        ABI::Windows::Graphics::SizeInt32 size{};
        RETURN_IF_FAILED(g_captureItem->get_Size(&size));
        RETURN_IF_FAILED(InitSharedOutputs(static_cast<UINT>(size.Width), static_cast<UINT>(size.Height)));

        g_isCapturing = true;
        g_loggedFirstFrame = false;
        return S_OK;
    }

    void ProcessFrame()
    {
        if (!g_isCapturing || !g_framePool) return;

        ComPtr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame> frame;
        if (FAILED(g_framePool->TryGetNextFrame(frame.ReleaseAndGetAddressOf())) || !frame) {
            return;
        }

        ComPtr<ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface> surface;
        if (FAILED(frame->get_Surface(surface.ReleaseAndGetAddressOf())) || !surface) {
            return;
        }

        ComPtr<IDirect3DDxgiInterfaceAccess> surfaceAccess;
        if (FAILED(surface.As(&surfaceAccess)) || !surfaceAccess) {
            return;
        }

        ComPtr<ID3D11Texture2D> frameTexture;
        if (FAILED(surfaceAccess->GetInterface(IID_PPV_ARGS(&frameTexture))) || !frameTexture) {
            return;
        }

        g_d3d11Context->CopyResource(g_sharedD3D11Texture.Get(), frameTexture.Get());

        UINT64 newFenceValue = g_fenceValue.fetch_add(1) + 1;
        g_d3d11Context4->Signal(g_sharedD3D11Fence.Get(), newFenceValue);

        if (g_pManifestView) {
            InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&g_pManifestView->frameValue), newFenceValue);
        }

        if (!g_loggedFirstFrame) {
            VirtuaCamLog::LogLine(std::format(
                L"First producer frame: type=capture hwnd={} frameValue={}",
                static_cast<UINT64>(reinterpret_cast<UINT_PTR>(g_captureTargetHwnd)),
                newFenceValue));
            g_loggedFirstFrame = true;
        }
    }

    void ShutdownProducer()
    {
        if (!g_isCapturing.exchange(false)) return;

        if (g_session) CloseClosable(g_session.Get());
        if (g_framePool) CloseClosable(g_framePool.Get());
        g_session.Reset();
        g_framePool.Reset();
        g_captureItem.Reset();
        g_winrtD3dDevice.Reset();

        if (g_pManifestView) UnmapViewOfFile(g_pManifestView);
        if (g_hManifest) CloseHandle(g_hManifest);
        g_pManifestView = nullptr;
        g_hManifest = nullptr;

        if (g_hSharedTextureHandle) CloseHandle(g_hSharedTextureHandle);
        if (g_hSharedFenceHandle) CloseHandle(g_hSharedFenceHandle);
        g_hSharedTextureHandle = nullptr;
        g_hSharedFenceHandle = nullptr;

        g_sharedD3D11Fence.Reset();
        g_sharedD3D11Texture.Reset();
        g_captureTargetHwnd = nullptr;

        if (g_d3d11Context) g_d3d11Context->ClearState();
        g_d3d11Context4.Reset();
        g_d3d11Context.Reset();
        g_d3d11Device5.Reset();
        g_d3d11Device.Reset();

        RoUninitialize();
    }

    bool IsProcessRunning(const wchar_t* processName)
    {
        if (!processName || !*processName) {
            return false;
        }

        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) {
            return false;
        }

        PROCESSENTRY32W pe = {};
        pe.dwSize = sizeof(pe);
        bool found = false;
        if (Process32FirstW(snap, &pe)) {
            do {
                if (_wcsicmp(pe.szExeFile, processName) == 0) {
                    found = true;
                    break;
                }
            } while (Process32NextW(snap, &pe));
        }
        CloseHandle(snap);
        return found;
    }

    std::wstring GetDefaultVirtuaCamExePath()
    {
        wchar_t modulePath[MAX_PATH] = {};
        if (!GetModuleFileNameW(nullptr, modulePath, ARRAYSIZE(modulePath))) {
            return L"VirtuaCam.exe";
        }

        std::wstring path = modulePath;
        size_t slash = path.find_last_of(L"\\/");
        if (slash != std::wstring::npos) {
            path.resize(slash + 1);
        }
        path += L"VirtuaCam.exe";
        return path;
    }

    std::wstring GetVirtuaCamExePathFromRegistryOrDefault()
    {
        HKEY hKey = nullptr;
        wchar_t value[MAX_PATH] = {};
        DWORD valueSize = sizeof(value);
        DWORD valueType = 0;

        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtuaCam", 0, KEY_READ, &hKey) == ERROR_SUCCESS) {
            const LSTATUS status = RegQueryValueExW(hKey, L"VirtuaCamExe", nullptr, &valueType, reinterpret_cast<LPBYTE>(value), &valueSize);
            RegCloseKey(hKey);
            if (status == ERROR_SUCCESS && valueType == REG_SZ && value[0] != L'\0') {
                return value;
            }
        }
        return GetDefaultVirtuaCamExePath();
    }

    bool LaunchVirtuaCamStartup()
    {
        std::wstring exePath = GetVirtuaCamExePathFromRegistryOrDefault();
        const std::wstring cmdLine = GetCommandLineW() ? GetCommandLineW() : L"";
        const bool enableDebugLogging = HasArg(cmdLine, L"-debug");

        SHELLEXECUTEINFOW sei = {};
        sei.cbSize = sizeof(sei);
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        sei.lpFile = exePath.c_str();
        sei.lpParameters = enableDebugLogging ? L"/startup -debug" : L"/startup";
        sei.nShow = SW_HIDE;
        if (!ShellExecuteExW(&sei)) {
            VirtuaCamLog::LogWin32(std::format(L"ShellExecuteExW failed for {}", exePath), GetLastError());
            return false;
        }

        if (sei.hProcess) {
            CloseHandle(sei.hProcess);
        }
        return true;
    }

    HANDLE OpenClientRequestEventHandle()
    {
        return OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE, kClientRequestEventName);
    }

    DWORD WINAPI WatcherThreadProc(LPVOID)
    {
        int launchFailCount = 0;
        while (true) {
            HANDLE requestEvent = OpenClientRequestEventHandle();
            if (!requestEvent) {
                Sleep(kWatcherOpenRetryMs);
                continue;
            }

            while (true) {
                DWORD waitResult = WaitForSingleObject(requestEvent, INFINITE);
                if (waitResult != WAIT_OBJECT_0) {
                    break;
                }

                if (!IsProcessRunning(L"VirtuaCam.exe")) {
                    if (launchFailCount < 3) {
                        if (LaunchVirtuaCamStartup()) {
                            launchFailCount = 0;
                        } else {
                            launchFailCount++;
                        }
                    }
                }
                ResetEvent(requestEvent);
            }

            CloseHandle(requestEvent);
        }
    }
}

namespace BuiltInCameraProducer
{
    static ComPtr<ID3D11Device> g_d3d11Device;
    static ComPtr<ID3D11Device5> g_d3d11Device5;
    static ComPtr<ID3D11DeviceContext> g_d3d11Context;
    static ComPtr<ID3D11DeviceContext4> g_d3d11Context4;
    static ComPtr<ID3D11Texture2D> g_sharedD3D11Texture;
    static ComPtr<ID3D11Fence> g_sharedD3D11Fence;
    static HANDLE g_hSharedTextureHandle = nullptr;
    static HANDLE g_hSharedFenceHandle = nullptr;
    static HANDLE g_hManifest = nullptr;
    static BroadcastManifest* g_pManifestView = nullptr;
    static std::atomic<UINT64> g_fenceValue = 0;

    static ComPtr<IMFSourceReader> g_sourceReader;
    static long g_videoWidth = 0;
    static long g_videoHeight = 0;
    static std::atomic<bool> g_isCapturing = false;
    static bool g_mfStarted = false;
    static bool g_loggedFirstFrame = false;

    static HRESULT InitD3D11()
    {
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        RETURN_IF_FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION, &g_d3d11Device, nullptr, &g_d3d11Context));
        RETURN_IF_FAILED(g_d3d11Device.As(&g_d3d11Device5));
        RETURN_IF_FAILED(g_d3d11Context.As(&g_d3d11Context4));
        return S_OK;
    }

    static HRESULT InitSharedOutputs(UINT width, UINT height)
    {
        D3D11_TEXTURE2D_DESC td{};
        td.Width = width;
        td.Height = height;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        td.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
        RETURN_IF_FAILED(g_d3d11Device->CreateTexture2D(&td, nullptr, &g_sharedD3D11Texture));
        RETURN_IF_FAILED(g_d3d11Device5->CreateFence(0, D3D11_FENCE_FLAG_SHARED, IID_PPV_ARGS(&g_sharedD3D11Fence)));

        DWORD pid = GetCurrentProcessId();
        std::wstring manifestName = GetProducerManifestName(pid);
        std::wstring texName = GetProducerTextureName(pid);
        std::wstring fenceName = GetProducerFenceName(pid);

        wil::unique_hlocal_security_descriptor sd;
        SECURITY_ATTRIBUTES sa = {};
        RETURN_IF_FAILED(CreateCurrentUserOnlySecurityAttributes(sd, sa));

        g_hManifest = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, sizeof(BroadcastManifest), manifestName.c_str());
        if (!g_hManifest) return HRESULT_FROM_WIN32(GetLastError());
        g_pManifestView = (BroadcastManifest*)MapViewOfFile(g_hManifest, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(BroadcastManifest));
        if (!g_pManifestView) return HRESULT_FROM_WIN32(GetLastError());

        ZeroMemory(g_pManifestView, sizeof(BroadcastManifest));
        g_pManifestView->width = width;
        g_pManifestView->height = height;
        g_pManifestView->format = DXGI_FORMAT_B8G8R8A8_UNORM;

        ComPtr<IDXGIDevice> dxgi;
        g_d3d11Device.As(&dxgi);
        ComPtr<IDXGIAdapter> adapter;
        dxgi->GetAdapter(&adapter);
        DXGI_ADAPTER_DESC desc{};
        adapter->GetDesc(&desc);
        g_pManifestView->adapterLuid = desc.AdapterLuid;

        wcscpy_s(g_pManifestView->textureName, texName.c_str());
        wcscpy_s(g_pManifestView->fenceName, fenceName.c_str());

        ComPtr<IDXGIResource1> r1;
        g_sharedD3D11Texture.As(&r1);
        RETURN_IF_FAILED(r1->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, texName.c_str(), &g_hSharedTextureHandle));
        RETURN_IF_FAILED(g_sharedD3D11Fence->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, fenceName.c_str(), &g_hSharedFenceHandle));

        return S_OK;
    }

    static HRESULT SelectMediaSource(const std::wstring& argsStr, ComPtr<IMFMediaSource>& outSource)
    {
        outSource.Reset();

        std::wstring devicePath;
        (void)TryGetArgValue(argsStr, L"--device-path", devicePath);

        int deviceIndex = 0;
        const bool hasIndex = TryGetArgI32(argsStr, L"--device", deviceIndex);

        ComPtr<IMFAttributes> attributes;
        RETURN_IF_FAILED(MFCreateAttributes(&attributes, 1));
        RETURN_IF_FAILED(attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID));

        UINT32 count = 0;
        IMFActivate** devices = nullptr;
        RETURN_IF_FAILED(MFEnumDeviceSources(attributes.Get(), &devices, &count));
        if (!devices || count == 0) {
            if (devices) CoTaskMemFree(devices);
            return E_FAIL;
        }

        int chosen = -1;
        if (!devicePath.empty()) {
            for (UINT32 i = 0; i < count; ++i) {
                wil::unique_cotaskmem_string symbolicLink;
                if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &symbolicLink, nullptr)) &&
                    symbolicLink.get() &&
                    _wcsicmp(symbolicLink.get(), devicePath.c_str()) == 0) {
                    chosen = static_cast<int>(i);
                    break;
                }
            }
        }

        if (chosen < 0 && hasIndex && deviceIndex >= 0 && static_cast<UINT32>(deviceIndex) < count) {
            chosen = deviceIndex;
        }

        HRESULT hr = E_FAIL;
        if (chosen >= 0) {
            hr = devices[chosen]->ActivateObject(IID_PPV_ARGS(&outSource));
        } else {
            VirtuaCamLog::LogLine(L"BuiltInCameraProducer: no matching camera for --device-path/--device");
            hr = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
        }

        for (UINT32 i = 0; i < count; ++i) {
            devices[i]->Release();
        }
        CoTaskMemFree(devices);
        return hr;
    }

    HRESULT InitializeProducer(const wchar_t* args)
    {
        std::wstring argsStr = args ? args : L"";

        if (!g_mfStarted) {
            RETURN_IF_FAILED(MFStartup(MF_VERSION));
            g_mfStarted = true;
        }

        RETURN_IF_FAILED(InitD3D11());

        ComPtr<IMFMediaSource> source;
        RETURN_IF_FAILED(SelectMediaSource(argsStr, source));

        ComPtr<IMFAttributes> readerAttributes;
        RETURN_IF_FAILED(MFCreateAttributes(&readerAttributes, 2));
        RETURN_IF_FAILED(readerAttributes->SetUINT32(MF_READWRITE_DISABLE_CONVERTERS, FALSE));
        RETURN_IF_FAILED(readerAttributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE));

        RETURN_IF_FAILED(MFCreateSourceReaderFromMediaSource(source.Get(), readerAttributes.Get(), &g_sourceReader));

        ComPtr<IMFMediaType> outputType;
        RETURN_IF_FAILED(MFCreateMediaType(&outputType));
        RETURN_IF_FAILED(outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
        RETURN_IF_FAILED(outputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32));

        // Pick a native type that the source reader can accept, then request RGB32.
        for (DWORD i = 0;; ++i) {
            ComPtr<IMFMediaType> nativeType;
            HRESULT hr = g_sourceReader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &nativeType);
            if (hr == MF_E_NO_MORE_TYPES) break;
            RETURN_IF_FAILED(hr);

            if (SUCCEEDED(g_sourceReader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, nativeType.Get()))) {
                if (SUCCEEDED(g_sourceReader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, outputType.Get()))) {
                    break;
                }
            }
        }

        ComPtr<IMFMediaType> currentType;
        RETURN_IF_FAILED(g_sourceReader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &currentType));
        MFGetAttributeSize(currentType.Get(), MF_MT_FRAME_SIZE, (UINT32*)&g_videoWidth, (UINT32*)&g_videoHeight);
        RETURN_HR_IF(E_FAIL, g_videoWidth <= 0 || g_videoHeight <= 0);

        RETURN_IF_FAILED(InitSharedOutputs(static_cast<UINT>(g_videoWidth), static_cast<UINT>(g_videoHeight)));

        g_isCapturing = true;
        g_loggedFirstFrame = false;
        return S_OK;
    }

    void ProcessFrame()
    {
        if (!g_isCapturing || !g_sourceReader) return;

        ComPtr<IMFSample> sample;
        DWORD streamFlags = 0;
        LONGLONG timestamp = 0;
        HRESULT hr = g_sourceReader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, NULL, &streamFlags, &timestamp, &sample);
        if (FAILED(hr) || !sample) return;

        ComPtr<IMFMediaBuffer> buffer;
        if (FAILED(sample->ConvertToContiguousBuffer(&buffer)) || !buffer) return;

        BYTE* data = nullptr;
        DWORD length = 0;
        if (FAILED(buffer->Lock(&data, NULL, &length)) || !data) return;
        g_d3d11Context->UpdateSubresource(g_sharedD3D11Texture.Get(), 0, NULL, data, g_videoWidth * 4, 0);
        (void)buffer->Unlock();

        UINT64 newFenceValue = g_fenceValue.fetch_add(1) + 1;
        g_d3d11Context4->Signal(g_sharedD3D11Fence.Get(), newFenceValue);
        if (g_pManifestView) {
            InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&g_pManifestView->frameValue), newFenceValue);
        }

        if (!g_loggedFirstFrame) {
            VirtuaCamLog::LogLine(std::format(
                L"First producer frame: type=camera size={}x{} frameValue={}",
                g_videoWidth,
                g_videoHeight,
                newFenceValue));
            g_loggedFirstFrame = true;
        }
    }

    void ShutdownProducer()
    {
        if (!g_isCapturing.exchange(false)) return;

        if (g_sourceReader) {
            (void)g_sourceReader->Flush(MF_SOURCE_READER_ALL_STREAMS);
        }
        g_sourceReader.Reset();

        if (g_pManifestView) UnmapViewOfFile(g_pManifestView);
        if (g_hManifest) CloseHandle(g_hManifest);
        g_pManifestView = nullptr;
        g_hManifest = nullptr;

        if (g_hSharedTextureHandle) CloseHandle(g_hSharedTextureHandle);
        if (g_hSharedFenceHandle) CloseHandle(g_hSharedFenceHandle);
        g_hSharedTextureHandle = nullptr;
        g_hSharedFenceHandle = nullptr;

        g_sharedD3D11Fence.Reset();
        g_sharedD3D11Texture.Reset();

        if (g_d3d11Context) g_d3d11Context->ClearState();
        g_d3d11Context.Reset();
        g_d3d11Context4.Reset();
        g_d3d11Device.Reset();
        g_d3d11Device5.Reset();

        if (g_mfStarted) {
            MFShutdown();
            g_mfStarted = false;
        }
    }
}

void LoadProducerModule(const std::wstring& type, ProducerModule& module)
{
    std::wstring dllName;
    if (type == L"camera") {
        module.hModule = nullptr;
        module.Initialize = &BuiltInCameraProducer::InitializeProducer;
        module.Process = &BuiltInCameraProducer::ProcessFrame;
        module.Shutdown = &BuiltInCameraProducer::ShutdownProducer;
        return;
    }
    if (type == L"capture") {
        module.hModule = nullptr;
        module.Initialize = &BuiltInCaptureProducer::InitializeProducer;
        module.Process = &BuiltInCaptureProducer::ProcessFrame;
        module.Shutdown = &BuiltInCaptureProducer::ShutdownProducer;
        return;
    }

    if (type == L"consumer") {
        dllName = L"DirectPortConsumer.dll";
    } else {
        return;
    }

    module.hModule = LoadLibraryExW(dllName.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (module.hModule)
    {
        module.Initialize = (PFN_InitializeProducer)GetProcAddress(module.hModule, "InitializeProducer");
        module.Process = (PFN_ProcessFrame)GetProcAddress(module.hModule, "ProcessFrame");
        module.Shutdown = (PFN_ShutdownProducer)GetProcAddress(module.hModule, "ShutdownProducer");
    }
    else
    {
        VirtuaCamLog::LogWin32(std::format(L"LoadLibraryExW failed: {}", dllName), GetLastError());
    }
}

int APIENTRY wWinMain(_In_ HINSTANCE hInstance, _In_opt_ HINSTANCE, _In_ LPWSTR lpCmdLine, _In_ int)
{
    const std::wstring cmdLine = GetCommandLineW() ? GetCommandLineW() : L"";
    const bool enableDebugLogging = HasArg(cmdLine, L"-debug");

    VirtuaCamLog::InitOptions logOpts;
    logOpts.logFileName = L"virtuacam-process.log";
    logOpts.attachConsole = false;
    logOpts.allocConsoleIfMissing = false;
    logOpts.enabled = enableDebugLogging;
    VirtuaCamLog::Init(logOpts);

    RETURN_IF_FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));

    std::wstring producerType, producerArgs;
    const bool hasProducerType = ParseCommandLine(lpCmdLine, producerType, producerArgs);

    if (!hasProducerType) {
        VirtuaCamLog::LogLine(L"No --type provided; running watcher mode");
        HANDLE watcherThread = CreateThread(nullptr, 0, BuiltInCaptureProducer::WatcherThreadProc, nullptr, 0, nullptr);
        if (!watcherThread) {
            VirtuaCamLog::LogWin32(L"CreateThread failed (watcher mode)", GetLastError());
            CoUninitialize();
            return 10;
        }
        WaitForSingleObject(watcherThread, INFINITE);
        CloseHandle(watcherThread);
        CoUninitialize();
        return 0;
    }

    ProducerModule module;
    LoadProducerModule(producerType, module);

    if (!module.Initialize || !module.Process || !module.Shutdown)
    {
        VirtuaCamLog::LogLine(std::format(L"Producer module incomplete: type={}", producerType));
        return 2;
    }

    if (FAILED(module.Initialize(producerArgs.c_str())))
    {
        VirtuaCamLog::LogLine(std::format(L"InitializeProducer failed: type={} args={}", producerType, producerArgs));
        module.Shutdown();
        if (module.hModule) FreeLibrary(module.hModule);
        return 3;
    }
    VirtuaCamLog::LogLine(std::format(L"InitializeProducer success: type={} args={}", producerType, producerArgs));
    
    MSG msg = {};
    while (msg.message != WM_QUIT)
    {
        if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        else
        {
            DWORD waitResult = MsgWaitForMultipleObjectsEx(
                0,
                nullptr,
                kProducerIdleWaitMs,
                QS_ALLINPUT,
                MWMO_INPUTAVAILABLE);
            if (waitResult == WAIT_TIMEOUT) {
                module.Process();
            }
        }
    }

    module.Shutdown();
    if (module.hModule) FreeLibrary(module.hModule);
    CoUninitialize();
    return 0;
}
