#include "pch.h"
#include "Process.h"
#include "DriverBridge.h"
#include "Resource.h"
#include "Config.h"
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
#include <vector>
#include <wtsapi32.h>
#include <userenv.h>
#include <d3dcompiler.h>
#include <algorithm>
#include <cmath>
#include <cwctype>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.foundation.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "runtimeobject.lib")
#pragma comment(lib, "wtsapi32.lib")
#pragma comment(lib, "userenv.lib")
#pragma comment(lib, "d3dcompiler.lib")

using Microsoft::WRL::ComPtr;

// Globals (outside anonymous namespace) so wWinMain can reference service entrypoints.
constexpr wchar_t kWatcherServiceName[] = L"VirtuaCamWatcher";
void WINAPI WatcherServiceMain(DWORD, LPWSTR*);

namespace
{
    constexpr wchar_t kClientRequestEventName[] = L"VirtuaCamClientRequest";
    constexpr wchar_t kGlobalClientRequestEventName[] = L"Global\\VirtuaCamClientRequest";
    constexpr DWORD kWatcherOpenRetryMs = 1000;
    constexpr DWORD kProducerFrameIntervalMs = 33;
    constexpr DWORD kProducerIdleBackoffMaxMs = 250;

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

    std::wstring ToLowerInvariant(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
            return static_cast<wchar_t>(std::towlower(ch));
        });
        return value;
    }

    std::wstring NormalizeCameraDeviceLink(std::wstring value)
    {
        value = ToLowerInvariant(value);
        constexpr wchar_t pnpPrefix[] = L"@device:pnp:";
        if (value.rfind(pnpPrefix, 0) == 0) {
            value.erase(0, ARRAYSIZE(pnpPrefix) - 1);
        }

        const size_t devicePathStart = value.find(L"\\\\?\\");
        if (devicePathStart != std::wstring::npos) {
            value.erase(0, devicePathStart);
        }

        const size_t interfaceGuidStart = value.find(L"#{");
        if (interfaceGuidStart != std::wstring::npos) {
            value.erase(interfaceGuidStart);
        }

        return value;
    }

    bool CameraDeviceLinksMatch(const std::wstring& lhs, const std::wstring& rhs)
    {
        if (_wcsicmp(lhs.c_str(), rhs.c_str()) == 0) {
            return true;
        }

        const std::wstring normalizedLhs = NormalizeCameraDeviceLink(lhs);
        const std::wstring normalizedRhs = NormalizeCameraDeviceLink(rhs);
        return !normalizedLhs.empty() &&
            !normalizedRhs.empty() &&
            normalizedLhs == normalizedRhs;
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

    constexpr UINT kProducerCanvasWidth = 1920;
    constexpr UINT kProducerCanvasHeight = 1080;

    struct CanvasBlitConstants
    {
        float uvScaleX;
        float uvScaleY;
        float uvOffsetX;
        float uvOffsetY;
    };

    const char* kCanvasBlitVertexShader = R"(
struct VS_OUTPUT { float4 Pos : SV_POSITION; float2 Tex : TEXCOORD; };
VS_OUTPUT main(uint id : SV_VertexID) {
    VS_OUTPUT output;
    output.Tex = float2((id << 1) & 2, id & 2);
    output.Pos = float4(output.Tex.x * 2.0 - 1.0, 1.0 - output.Tex.y * 2.0, 0.0, 1.0);
    return output;
})";

const char* kCanvasBlitPixelShader = R"(
Texture2D inputTexture : register(t0);
SamplerState inputSampler : register(s0);
cbuffer CanvasBlitConstants : register(b0) {
    float2 uvScale;
    float2 uvOffset;
};
float4 main(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    return inputTexture.Sample(inputSampler, uv * uvScale + uvOffset);
})";

    HRESULT CreateCanvasBlitResources(
        ID3D11Device* device,
        ID3D11VertexShader** vertexShader,
        ID3D11PixelShader** pixelShader,
        ID3D11SamplerState** samplerState,
        ID3D11Buffer** constantBuffer)
    {
        RETURN_HR_IF_NULL(E_POINTER, device);
        RETURN_HR_IF_NULL(E_POINTER, vertexShader);
        RETURN_HR_IF_NULL(E_POINTER, pixelShader);
        RETURN_HR_IF_NULL(E_POINTER, samplerState);
        RETURN_HR_IF_NULL(E_POINTER, constantBuffer);

        ComPtr<ID3DBlob> vsBlob;
        ComPtr<ID3DBlob> psBlob;
        RETURN_IF_FAILED(D3DCompile(
            kCanvasBlitVertexShader,
            strlen(kCanvasBlitVertexShader),
            nullptr,
            nullptr,
            nullptr,
            "main",
            "vs_5_0",
            0,
            0,
            &vsBlob,
            nullptr));
        RETURN_IF_FAILED(D3DCompile(
            kCanvasBlitPixelShader,
            strlen(kCanvasBlitPixelShader),
            nullptr,
            nullptr,
            nullptr,
            "main",
            "ps_5_0",
            0,
            0,
            &psBlob,
            nullptr));
        RETURN_IF_FAILED(device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, vertexShader));
        RETURN_IF_FAILED(device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, pixelShader));

        D3D11_SAMPLER_DESC samplerDesc = {};
        samplerDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        samplerDesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
        samplerDesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
        samplerDesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        samplerDesc.ComparisonFunc = D3D11_COMPARISON_NEVER;
        samplerDesc.MinLOD = 0;
        samplerDesc.MaxLOD = D3D11_FLOAT32_MAX;
        RETURN_IF_FAILED(device->CreateSamplerState(&samplerDesc, samplerState));

        D3D11_BUFFER_DESC constantDesc = {};
        constantDesc.ByteWidth = sizeof(CanvasBlitConstants);
        constantDesc.Usage = D3D11_USAGE_DEFAULT;
        constantDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        RETURN_IF_FAILED(device->CreateBuffer(&constantDesc, nullptr, constantBuffer));
        return S_OK;
    }

    CanvasBlitConstants GetFullSourceUvConstants()
    {
        CanvasBlitConstants constants = {};
        constants.uvScaleX = 1.0f;
        constants.uvScaleY = 1.0f;
        constants.uvOffsetX = 0.0f;
        constants.uvOffsetY = 0.0f;
        return constants;
    }

    AspectRatioMode GetProducerAspectRatioMode()
    {
        static AspectRatioMode cached = VirtuaCamConfig::LoadSettings().aspectRatio;
        static ULONGLONG lastReloadTick = 0;

        const ULONGLONG now = GetTickCount64();
        if (now - lastReloadTick > 500) {
            cached = VirtuaCamConfig::LoadSettings().aspectRatio;
            lastReloadTick = now;
        }
        return cached;
    }

    D3D11_VIEWPORT GetContainCanvasViewport(UINT sourceWidth, UINT sourceHeight)
    {
        const float sourceW = static_cast<float>(std::max<UINT>(1, sourceWidth));
        const float sourceH = static_cast<float>(std::max<UINT>(1, sourceHeight));
        const float canvasW = static_cast<float>(kProducerCanvasWidth);
        const float canvasH = static_cast<float>(kProducerCanvasHeight);

        const float targetAspect = VirtuaCamConfig::AspectRatioValue(GetProducerAspectRatioMode());
        float targetW = canvasW;
        float targetH = canvasH;
        if ((canvasW / canvasH) > targetAspect) {
            targetW = targetH * targetAspect;
        } else {
            targetH = targetW / targetAspect;
        }

        const float scale = (std::min)(targetW / sourceW, targetH / sourceH);
        const float fittedW = sourceW * scale;
        const float fittedH = sourceH * scale;

        D3D11_VIEWPORT viewport = {};
        viewport.TopLeftX = (canvasW - targetW) * 0.5f + (targetW - fittedW) * 0.5f;
        viewport.TopLeftY = (canvasH - targetH) * 0.5f + (targetH - fittedH) * 0.5f;
        viewport.Width = fittedW;
        viewport.Height = fittedH;
        viewport.MinDepth = 0.0f;
        viewport.MaxDepth = 1.0f;
        return viewport;
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
    enum class CaptureBackend
    {
        None,
        Wgc,
        PrintWindow,
        BitBlt
    };

    static ComPtr<ID3D11Device> g_d3d11Device;
    static ComPtr<ID3D11Device5> g_d3d11Device5;
    static ComPtr<ID3D11DeviceContext> g_d3d11Context;
    static ComPtr<ID3D11DeviceContext4> g_d3d11Context4;

    static ComPtr<ID3D11Texture2D> g_sharedD3D11Texture;
    static ComPtr<ID3D11Fence> g_sharedD3D11Fence;
    static ComPtr<ID3D11RenderTargetView> g_canvasRTV;
    static ComPtr<ID3D11Texture2D> g_sourceD3D11Texture;
    static ComPtr<ID3D11ShaderResourceView> g_sourceSRV;
    static ComPtr<ID3D11VertexShader> g_canvasVS;
    static ComPtr<ID3D11PixelShader> g_canvasPS;
    static ComPtr<ID3D11SamplerState> g_canvasSampler;
    static ComPtr<ID3D11Buffer> g_canvasConstants;
    static HANDLE g_hSharedTextureHandle = nullptr;
    static HANDLE g_hSharedFenceHandle = nullptr;
    static HANDLE g_hManifest = nullptr;
    static BroadcastManifest* g_pManifestView = nullptr;
    static std::atomic<UINT64> g_fenceValue = 0;
    static UINT64 g_brokerNonce = 0;

    static ComPtr<ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice> g_winrtD3dDevice;
    static ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem> g_captureItem;
    static ComPtr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool> g_framePool;
    static ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession> g_session;
    static std::atomic<bool> g_isCapturing = false;
    static bool g_loggedFirstFrame = false;
    static HWND g_captureTargetHwnd = nullptr;
    static HMONITOR g_captureTargetMonitor = nullptr;
    static CaptureBackend g_captureBackend = CaptureBackend::None;
    static UINT g_captureWidth = 0;
    static UINT g_captureHeight = 0;
    static bool g_roInitialized = false;

    struct GdiCaptureCache
    {
        HWND hwnd = nullptr;
        UINT width = 0;
        UINT height = 0;
        HDC windowDc = nullptr;
        HDC memoryDc = nullptr;
        HBITMAP dib = nullptr;
        HGDIOBJ oldBitmap = nullptr;
        void* bits = nullptr;

        void Reset()
        {
            if (memoryDc && oldBitmap && oldBitmap != HGDI_ERROR) {
                SelectObject(memoryDc, oldBitmap);
            }
            if (dib) {
                DeleteObject(dib);
            }
            if (memoryDc) {
                DeleteDC(memoryDc);
            }
            if (windowDc && hwnd) {
                ReleaseDC(hwnd, windowDc);
            }

            hwnd = nullptr;
            width = 0;
            height = 0;
            windowDc = nullptr;
            memoryDc = nullptr;
            dib = nullptr;
            oldBitmap = nullptr;
            bits = nullptr;
        }

        HRESULT Ensure(HWND targetHwnd, UINT targetWidth, UINT targetHeight)
        {
            RETURN_HR_IF_NULL(E_HANDLE, targetHwnd);
            RETURN_HR_IF(E_INVALIDARG, targetWidth == 0 || targetHeight == 0);

            if (hwnd == targetHwnd &&
                width == targetWidth &&
                height == targetHeight &&
                windowDc &&
                memoryDc &&
                dib &&
                bits) {
                return S_OK;
            }

            Reset();
            hwnd = targetHwnd;
            width = targetWidth;
            height = targetHeight;

            windowDc = GetDC(hwnd);
            if (!windowDc) {
                const DWORD err = GetLastError();
                Reset();
                return HRESULT_FROM_WIN32(err ? err : ERROR_GEN_FAILURE);
            }

            memoryDc = CreateCompatibleDC(windowDc);
            if (!memoryDc) {
                const DWORD err = GetLastError();
                Reset();
                return HRESULT_FROM_WIN32(err ? err : ERROR_GEN_FAILURE);
            }

            BITMAPINFO bmi{};
            bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            bmi.bmiHeader.biWidth = static_cast<LONG>(width);
            bmi.bmiHeader.biHeight = -static_cast<LONG>(height);
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB;

            dib = CreateDIBSection(windowDc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
            if (!dib || !bits) {
                const DWORD err = GetLastError();
                Reset();
                return HRESULT_FROM_WIN32(err ? err : ERROR_GEN_FAILURE);
            }

            oldBitmap = SelectObject(memoryDc, dib);
            if (!oldBitmap || oldBitmap == HGDI_ERROR) {
                const DWORD err = GetLastError();
                Reset();
                return HRESULT_FROM_WIN32(err ? err : ERROR_GEN_FAILURE);
            }

            return S_OK;
        }
    };

    static GdiCaptureCache g_gdiCache;

    constexpr UINT kPrintWindowFlagsClientOnly = 0x00000001;
    constexpr UINT kPrintWindowFlagsRenderFullContent = 0x00000002; // PW_RENDERFULLCONTENT (Win8.1+)
    constexpr UINT kPrintWindowFlagsClientFullContent = kPrintWindowFlagsClientOnly | kPrintWindowFlagsRenderFullContent; // 0x3

    static std::wstring GetWindowClassName(HWND hwnd)
    {
        wchar_t cls[256] = {};
        if (!hwnd) return {};
        if (!GetClassNameW(hwnd, cls, ARRAYSIZE(cls))) return {};
        return cls;
    }

    static HWND FindDescendantWindowByClass(HWND root, const wchar_t* className)
    {
        if (!root || !className || !*className) return nullptr;

        struct FindData
        {
            const wchar_t* className = nullptr;
            HWND found = nullptr;
        } data;
        data.className = className;

        EnumChildWindows(
            root,
            [](HWND hwnd, LPARAM lParam) -> BOOL {
                auto* d = reinterpret_cast<FindData*>(lParam);
                if (!d || d->found) return FALSE;

                wchar_t cls[256] = {};
                if (GetClassNameW(hwnd, cls, ARRAYSIZE(cls)) && _wcsicmp(cls, d->className) == 0) {
                    d->found = hwnd;
                    return FALSE;
                }
                return TRUE;
            },
            reinterpret_cast<LPARAM>(&data));

        return data.found;
    }

    static HWND GetWgcTargetHwnd(HWND selectedHwnd)
    {
        // WGC CreateForWindow expects the target HWND; for UWP/ApplicationFrameWindow
        // the top-level frame is the stable capture target. Child CoreWindow can fail E_INVALIDARG.
        return selectedHwnd;
    }

    struct MonitorLookup
    {
        int targetIndex = -1;
        int currentIndex = 0;
        HMONITOR monitor = nullptr;
    };

    static BOOL CALLBACK FindMonitorByIndexProc(HMONITOR monitor, HDC, LPRECT, LPARAM lParam)
    {
        auto* lookup = reinterpret_cast<MonitorLookup*>(lParam);
        if (!lookup) {
            return FALSE;
        }
        if (lookup->currentIndex == lookup->targetIndex) {
            lookup->monitor = monitor;
            return FALSE;
        }
        ++lookup->currentIndex;
        return TRUE;
    }

    static HMONITOR FindMonitorByIndex(int index)
    {
        if (index < 0) {
            return nullptr;
        }
        MonitorLookup lookup{};
        lookup.targetIndex = index;
        EnumDisplayMonitors(nullptr, nullptr, FindMonitorByIndexProc, reinterpret_cast<LPARAM>(&lookup));
        return lookup.monitor;
    }

    static bool IsProbablyAllBlackBgrx(const BYTE* bits, UINT width, UINT height)
    {
        if (!bits || width == 0 || height == 0) {
            return true;
        }

        constexpr UINT kGrid = 8;
        const size_t stride = static_cast<size_t>(width) * 4;

        for (UINT gy = 0; gy < kGrid; ++gy) {
            const UINT y = (height == 1) ? 0 : (gy * (height - 1)) / (kGrid - 1);
            const BYTE* row = bits + static_cast<size_t>(y) * stride;
            for (UINT gx = 0; gx < kGrid; ++gx) {
                const UINT x = (width == 1) ? 0 : (gx * (width - 1)) / (kGrid - 1);
                const BYTE* p = row + static_cast<size_t>(x) * 4;
                if ((p[0] | p[1] | p[2]) != 0) {
                    return false;
                }
            }
        }
        return true;
    }

    static void ResetSharedOutputs()
    {
        if (g_pManifestView) UnmapViewOfFile(g_pManifestView);
        if (g_hManifest) CloseHandle(g_hManifest);
        g_pManifestView = nullptr;
        g_hManifest = nullptr;

        if (g_hSharedTextureHandle) CloseHandle(g_hSharedTextureHandle);
        if (g_hSharedFenceHandle) CloseHandle(g_hSharedFenceHandle);
        g_hSharedTextureHandle = nullptr;
        g_hSharedFenceHandle = nullptr;
        g_brokerNonce = 0;

        g_sharedD3D11Fence.Reset();
        g_sharedD3D11Texture.Reset();
        g_canvasRTV.Reset();
        g_sourceSRV.Reset();
        g_sourceD3D11Texture.Reset();
        g_canvasVS.Reset();
        g_canvasPS.Reset();
        g_canvasSampler.Reset();
        g_canvasConstants.Reset();
        g_canvasRTV.Reset();
        g_sourceSRV.Reset();
        g_sourceD3D11Texture.Reset();
        g_canvasVS.Reset();
        g_canvasPS.Reset();
        g_canvasSampler.Reset();
        g_canvasConstants.Reset();
        g_captureWidth = 0;
        g_captureHeight = 0;
        g_gdiCache.Reset();
    }

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

    static HRESULT EnsureCaptureSourceTexture(UINT width, UINT height)
    {
        RETURN_HR_IF(E_INVALIDARG, width == 0 || height == 0);

        D3D11_TEXTURE2D_DESC currentDesc = {};
        if (g_sourceD3D11Texture) {
            g_sourceD3D11Texture->GetDesc(&currentDesc);
        }
        if (g_sourceD3D11Texture && g_sourceSRV && currentDesc.Width == width && currentDesc.Height == height) {
            return S_OK;
        }

        g_sourceSRV.Reset();
        g_sourceD3D11Texture.Reset();

        D3D11_TEXTURE2D_DESC td{};
        td.Width = width;
        td.Height = height;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        RETURN_IF_FAILED(g_d3d11Device->CreateTexture2D(&td, nullptr, &g_sourceD3D11Texture));
        RETURN_IF_FAILED(g_d3d11Device->CreateShaderResourceView(g_sourceD3D11Texture.Get(), nullptr, &g_sourceSRV));
        return S_OK;
    }

    static HRESULT RenderTextureToCanvas(ID3D11Texture2D* sourceTexture, UINT sourceWidth, UINT sourceHeight)
    {
        RETURN_HR_IF_NULL(E_POINTER, sourceTexture);
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasRTV.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasVS.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasPS.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasSampler.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasConstants.Get());

        ComPtr<ID3D11ShaderResourceView> sourceSRV;
        if (sourceTexture == g_sourceD3D11Texture.Get() && g_sourceSRV) {
            sourceSRV = g_sourceSRV;
        } else {
            RETURN_IF_FAILED(g_d3d11Device->CreateShaderResourceView(sourceTexture, nullptr, &sourceSRV));
        }

        const float clearColor[] = { 33.0f / 255.0f, 33.0f / 255.0f, 33.0f / 255.0f, 1.0f };
        const CanvasBlitConstants constants = GetFullSourceUvConstants();
        D3D11_VIEWPORT viewport = GetContainCanvasViewport(sourceWidth, sourceHeight);
        ID3D11RenderTargetView* rtvs[] = { g_canvasRTV.Get() };
        ID3D11ShaderResourceView* srvs[] = { sourceSRV.Get() };
        ID3D11SamplerState* samplers[] = { g_canvasSampler.Get() };
        ID3D11Buffer* constantBuffers[] = { g_canvasConstants.Get() };

        g_d3d11Context->OMSetRenderTargets(1, rtvs, nullptr);
        g_d3d11Context->ClearRenderTargetView(g_canvasRTV.Get(), clearColor);
        g_d3d11Context->UpdateSubresource(g_canvasConstants.Get(), 0, nullptr, &constants, 0, 0);
        g_d3d11Context->RSSetViewports(1, &viewport);
        g_d3d11Context->VSSetShader(g_canvasVS.Get(), nullptr, 0);
        g_d3d11Context->PSSetShader(g_canvasPS.Get(), nullptr, 0);
        g_d3d11Context->PSSetConstantBuffers(0, 1, constantBuffers);
        g_d3d11Context->PSSetShaderResources(0, 1, srvs);
        g_d3d11Context->PSSetSamplers(0, 1, samplers);
        g_d3d11Context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        g_d3d11Context->Draw(3, 0);

        ID3D11ShaderResourceView* nullSrv[] = { nullptr };
        g_d3d11Context->PSSetShaderResources(0, 1, nullSrv);
        return S_OK;
    }

    static HRESULT InitWgc(HWND hwndToCapture)
    {
        HRESULT hrInit = RoInitialize(RO_INIT_MULTITHREADED);
        if (FAILED(hrInit) && hrInit != RPC_E_CHANGED_MODE) {
            return hrInit;
        }
        if (SUCCEEDED(hrInit)) {
            g_roInitialized = true;
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

    static HRESULT InitWgcMonitor(HMONITOR monitorToCapture)
    {
        RETURN_HR_IF_NULL(E_INVALIDARG, monitorToCapture);

        HRESULT hrInit = RoInitialize(RO_INIT_MULTITHREADED);
        if (FAILED(hrInit) && hrInit != RPC_E_CHANGED_MODE) {
            return hrInit;
        }
        if (SUCCEEDED(hrInit)) {
            g_roInitialized = true;
        }

        HString itemClass;
        RETURN_IF_FAILED(MakeHString(L"Windows.Graphics.Capture.GraphicsCaptureItem", itemClass));

        ComPtr<IActivationFactory> itemFactory;
        RETURN_IF_FAILED(RoGetActivationFactory(itemClass.value, IID_PPV_ARGS(&itemFactory)));

        ComPtr<IGraphicsCaptureItemInterop> interop;
        RETURN_IF_FAILED(itemFactory.As(&interop));

        RETURN_IF_FAILED(interop->CreateForMonitor(
            monitorToCapture,
            __uuidof(ABI::Windows::Graphics::Capture::IGraphicsCaptureItem),
            (void**)g_captureItem.ReleaseAndGetAddressOf()));
        RETURN_HR_IF_NULL(E_FAIL, g_captureItem.Get());

        ComPtr<IDXGIDevice> dxgiDevice;
        RETURN_IF_FAILED(g_d3d11Device.As(&dxgiDevice));

        ComPtr<IInspectable> inspectableDevice;
        RETURN_IF_FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.Get(), inspectableDevice.ReleaseAndGetAddressOf()));
        RETURN_IF_FAILED(inspectableDevice.As(&g_winrtD3dDevice));

        HString framePoolClass;
        RETURN_IF_FAILED(MakeHString(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool", framePoolClass));

        ComPtr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePoolStatics> framePoolStatics;
        RETURN_IF_FAILED(RoGetActivationFactory(framePoolClass.value, IID_PPV_ARGS(&framePoolStatics)));

        ABI::Windows::Graphics::SizeInt32 size{};
        RETURN_IF_FAILED(g_captureItem->get_Size(&size));

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

    static HRESULT InitSharedOutputs(UINT width, UINT height);

    static HRESULT InitPrintWindowCapture(HWND hwndToCapture)
    {
        RECT rc{};
        if (!GetClientRect(hwndToCapture, &rc)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }

        const LONG width = rc.right - rc.left;
        const LONG height = rc.bottom - rc.top;
        RETURN_HR_IF(E_INVALIDARG, width <= 0 || height <= 0);

        RETURN_IF_FAILED(InitSharedOutputs(kProducerCanvasWidth, kProducerCanvasHeight));
        g_captureWidth = static_cast<UINT>(width);
        g_captureHeight = static_cast<UINT>(height);
        RETURN_IF_FAILED(EnsureCaptureSourceTexture(g_captureWidth, g_captureHeight));
        RETURN_IF_FAILED(g_gdiCache.Ensure(hwndToCapture, g_captureWidth, g_captureHeight));
        return S_OK;
    }

    static HRESULT InitBitBltCapture(HWND hwndToCapture)
    {
        // Keep size consistent with PrintWindow path: client area.
        return InitPrintWindowCapture(hwndToCapture);
    }

    static CaptureBackend GetCaptureBackendOverride()
    {
        wchar_t value[64] = {};
        const DWORD len = GetEnvironmentVariableW(L"VIRTUACAM_CAPTURE_BACKEND", value, ARRAYSIZE(value));
        if (len == 0 || len >= ARRAYSIZE(value) || _wcsicmp(value, L"auto") == 0) {
            return CaptureBackend::None;
        }
        if (_wcsicmp(value, L"printwindow") == 0) {
            return CaptureBackend::PrintWindow;
        }
        if (_wcsicmp(value, L"wgc") == 0) {
            return CaptureBackend::Wgc;
        }
        if (_wcsicmp(value, L"bitblt") == 0) {
            return CaptureBackend::BitBlt;
        }

        VirtuaCamLog::LogLine(std::format(L"Ignoring unknown VIRTUACAM_CAPTURE_BACKEND={}", value));
        return CaptureBackend::None;
    }

    static HRESULT InitSharedOutputs(UINT width, UINT height)
    {
        width = kProducerCanvasWidth;
        height = kProducerCanvasHeight;

        D3D11_TEXTURE2D_DESC td{};
        td.Width = width;
        td.Height = height;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        td.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
        RETURN_IF_FAILED(g_d3d11Device->CreateTexture2D(&td, nullptr, &g_sharedD3D11Texture));
        RETURN_IF_FAILED(g_d3d11Device->CreateRenderTargetView(g_sharedD3D11Texture.Get(), nullptr, &g_canvasRTV));
        RETURN_IF_FAILED(CreateCanvasBlitResources(
            g_d3d11Device.Get(),
            g_canvasVS.ReleaseAndGetAddressOf(),
            g_canvasPS.ReleaseAndGetAddressOf(),
            g_canvasSampler.ReleaseAndGetAddressOf(),
            g_canvasConstants.ReleaseAndGetAddressOf()));
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

        ComPtr<IDXGIDevice> dxgi;
        g_d3d11Device.As(&dxgi);
        ComPtr<IDXGIAdapter> adapter;
        dxgi->GetAdapter(&adapter);
        DXGI_ADAPTER_DESC desc{};
        adapter->GetDesc(&desc);
        RETURN_HR_IF(E_FAIL, !InitializeBroadcastManifest(
            g_pManifestView,
            pid,
            g_brokerNonce,
            width,
            height,
            DXGI_FORMAT_B8G8R8A8_UNORM,
            desc.AdapterLuid,
            texName,
            fenceName));

        ComPtr<IDXGIResource1> r1;
        g_sharedD3D11Texture.As(&r1);
        RETURN_IF_FAILED(r1->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, texName.c_str(), &g_hSharedTextureHandle));
        RETURN_IF_FAILED(g_sharedD3D11Fence->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, fenceName.c_str(), &g_hSharedFenceHandle));
        g_pManifestView->sharedFenceHandleValue = static_cast<UINT64>(
            reinterpret_cast<UINT_PTR>(g_hSharedFenceHandle));

        return S_OK;
    }

    static HRESULT CapturePrintWindowFrame()
    {
        RETURN_HR_IF_NULL(E_HANDLE, g_captureTargetHwnd);

        RECT rc{};
        if (!GetClientRect(g_captureTargetHwnd, &rc)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }

        const UINT width = static_cast<UINT>(rc.right - rc.left);
        const UINT height = static_cast<UINT>(rc.bottom - rc.top);
        RETURN_HR_IF(E_INVALIDARG, width == 0 || height == 0);
        if (width != g_captureWidth || height != g_captureHeight) {
            g_captureWidth = width;
            g_captureHeight = height;
            RETURN_IF_FAILED(EnsureCaptureSourceTexture(width, height));
            VirtuaCamLog::LogLine(std::format(L"PrintWindow source resized: {}x{}", width, height));
        }

        RETURN_IF_FAILED(g_gdiCache.Ensure(g_captureTargetHwnd, width, height));

        BOOL copied = PrintWindow(g_captureTargetHwnd, g_gdiCache.memoryDc, kPrintWindowFlagsClientFullContent);

        HRESULT hr = S_OK;
        if (!copied) {
            const DWORD err = GetLastError();
            hr = HRESULT_FROM_WIN32(err ? err : ERROR_GEN_FAILURE);
        } else if (IsProbablyAllBlackBgrx(reinterpret_cast<const BYTE*>(g_gdiCache.bits), width, height)) {
            hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        } else {
            RETURN_IF_FAILED(EnsureCaptureSourceTexture(width, height));
            g_d3d11Context->UpdateSubresource(g_sourceD3D11Texture.Get(), 0, nullptr, g_gdiCache.bits, width * 4, 0);
            hr = RenderTextureToCanvas(g_sourceD3D11Texture.Get(), width, height);
        }

        return hr;
    }

    static HRESULT CaptureBitBltFrame()
    {
        RETURN_HR_IF_NULL(E_HANDLE, g_captureTargetHwnd);

        RECT rc{};
        if (!GetClientRect(g_captureTargetHwnd, &rc)) {
            return HRESULT_FROM_WIN32(GetLastError());
        }

        const UINT width = static_cast<UINT>(rc.right - rc.left);
        const UINT height = static_cast<UINT>(rc.bottom - rc.top);
        RETURN_HR_IF(E_INVALIDARG, width == 0 || height == 0);
        if (width != g_captureWidth || height != g_captureHeight) {
            g_captureWidth = width;
            g_captureHeight = height;
            RETURN_IF_FAILED(EnsureCaptureSourceTexture(width, height));
            VirtuaCamLog::LogLine(std::format(L"BitBlt source resized: {}x{}", width, height));
        }

        RETURN_IF_FAILED(g_gdiCache.Ensure(g_captureTargetHwnd, width, height));

        const BOOL copied = BitBlt(
            g_gdiCache.memoryDc,
            0,
            0,
            static_cast<int>(width),
            static_cast<int>(height),
            g_gdiCache.windowDc,
            0,
            0,
            SRCCOPY | CAPTUREBLT);

        HRESULT hr = S_OK;
        if (!copied) {
            const DWORD err = GetLastError();
            hr = HRESULT_FROM_WIN32(err ? err : ERROR_GEN_FAILURE);
        } else {
            RETURN_IF_FAILED(EnsureCaptureSourceTexture(width, height));
            g_d3d11Context->UpdateSubresource(g_sourceD3D11Texture.Get(), 0, nullptr, g_gdiCache.bits, width * 4, 0);
            hr = RenderTextureToCanvas(g_sourceD3D11Texture.Get(), width, height);
        }

        return hr;
    }

    HRESULT InitializeProducer(const wchar_t* args)
    {
        UINT64 hwndVal = 0;
        int monitorIndex = -1;
        std::wstring argsStr = args ? args : L"";
        UINT64 brokerNonceValue = 0;
        g_brokerNonce = 0;
        if (TryGetArgU64(argsStr, L"--broker-nonce", brokerNonceValue)) {
            g_brokerNonce = brokerNonceValue;
        }
        const bool hasMonitor = TryGetArgI32(argsStr, L"--monitor", monitorIndex);
        const bool hasWindow = TryGetArgU64(argsStr, L"--hwnd", hwndVal);
        RETURN_HR_IF(E_INVALIDARG, !hasMonitor && !hasWindow);
        HWND hwndToCapture = reinterpret_cast<HWND>(hwndVal);
        if (!hasMonitor) {
            RETURN_HR_IF_NULL(E_INVALIDARG, hwndToCapture);
        }
        g_captureTargetHwnd = hwndToCapture;
        g_captureTargetMonitor = nullptr;
        g_captureBackend = CaptureBackend::None;
        g_captureWidth = 0;
        g_captureHeight = 0;
        g_roInitialized = false;

        RETURN_IF_FAILED(InitD3D11());

        const CaptureBackend backendOverride = GetCaptureBackendOverride();
        HRESULT hr = S_OK;

        if (hasMonitor) {
            HMONITOR monitor = FindMonitorByIndex(monitorIndex);
            RETURN_HR_IF_NULL(HRESULT_FROM_WIN32(ERROR_NOT_FOUND), monitor);
            g_captureTargetMonitor = monitor;
            RETURN_IF_FAILED(InitWgcMonitor(monitor));
            ABI::Windows::Graphics::SizeInt32 size{};
            RETURN_IF_FAILED(g_captureItem->get_Size(&size));
            RETURN_IF_FAILED(InitSharedOutputs(kProducerCanvasWidth, kProducerCanvasHeight));
            g_captureWidth = static_cast<UINT>(size.Width);
            g_captureHeight = static_cast<UINT>(size.Height);
            g_captureBackend = CaptureBackend::Wgc;
            g_isCapturing = true;
            g_loggedFirstFrame = false;
            VirtuaCamLog::LogLine(std::format(
                L"Capture init: using WGC display monitor={} size={}x{}",
                monitorIndex,
                g_captureWidth,
                g_captureHeight));
            return S_OK;
        }

        if (backendOverride == CaptureBackend::PrintWindow) {
            RETURN_IF_FAILED(InitPrintWindowCapture(hwndToCapture));
            RETURN_IF_FAILED(CapturePrintWindowFrame());
            VirtuaCamLog::LogLine(L"Capture init: using PrintWindow(PW_RENDERFULLCONTENT|PW_CLIENTONLY) forced by VIRTUACAM_CAPTURE_BACKEND");
            g_captureBackend = CaptureBackend::PrintWindow;
        } else if (backendOverride == CaptureBackend::Wgc) {
            const HWND wgcHwnd = GetWgcTargetHwnd(hwndToCapture);
            RETURN_IF_FAILED(InitWgc(wgcHwnd));
            ABI::Windows::Graphics::SizeInt32 size{};
            RETURN_IF_FAILED(g_captureItem->get_Size(&size));
            RETURN_IF_FAILED(InitSharedOutputs(kProducerCanvasWidth, kProducerCanvasHeight));
            g_captureWidth = static_cast<UINT>(size.Width);
            g_captureHeight = static_cast<UINT>(size.Height);
            VirtuaCamLog::LogLine(std::format(
                L"Capture init: using WGC forced by VIRTUACAM_CAPTURE_BACKEND hwnd={} (selected hwnd={}) size={}x{}",
                static_cast<UINT64>(reinterpret_cast<UINT_PTR>(wgcHwnd)),
                static_cast<UINT64>(reinterpret_cast<UINT_PTR>(hwndToCapture)),
                g_captureWidth,
                g_captureHeight));
            g_captureBackend = CaptureBackend::Wgc;
        } else if (backendOverride == CaptureBackend::BitBlt) {
            RETURN_IF_FAILED(InitBitBltCapture(hwndToCapture));
            VirtuaCamLog::LogLine(L"Capture init: using BitBlt forced by VIRTUACAM_CAPTURE_BACKEND");
            g_captureBackend = CaptureBackend::BitBlt;
        }

        if (g_captureBackend == CaptureBackend::None) {
            const HWND wgcHwnd = GetWgcTargetHwnd(hwndToCapture);
            hr = InitWgc(wgcHwnd);
            if (SUCCEEDED(hr)) {
                ABI::Windows::Graphics::SizeInt32 size{};
                RETURN_IF_FAILED(g_captureItem->get_Size(&size));
                RETURN_IF_FAILED(InitSharedOutputs(kProducerCanvasWidth, kProducerCanvasHeight));
                g_captureWidth = static_cast<UINT>(size.Width);
                g_captureHeight = static_cast<UINT>(size.Height);
                VirtuaCamLog::LogLine(std::format(
                    L"Capture init: using WGC hwnd={} (selected hwnd={}) size={}x{}",
                    static_cast<UINT64>(reinterpret_cast<UINT_PTR>(wgcHwnd)),
                    static_cast<UINT64>(reinterpret_cast<UINT_PTR>(hwndToCapture)),
                    g_captureWidth,
                    g_captureHeight));
                g_captureBackend = CaptureBackend::Wgc;
            } else {
                VirtuaCamLog::LogHr(L"InitWgc failed; falling through to PrintWindow", hr);
                ResetSharedOutputs();
            }
        }

        if (g_captureBackend == CaptureBackend::None) {
            hr = InitPrintWindowCapture(hwndToCapture);
            if (SUCCEEDED(hr)) {
                const HRESULT testHr = CapturePrintWindowFrame();
                if (SUCCEEDED(testHr)) {
                    VirtuaCamLog::LogLine(L"Capture init: using PrintWindow(PW_RENDERFULLCONTENT|PW_CLIENTONLY)");
                    g_captureBackend = CaptureBackend::PrintWindow;
                } else {
                    VirtuaCamLog::LogHr(L"PrintWindow test frame black/failed; falling through to BitBlt", testHr);
                    ResetSharedOutputs();
                }
            } else {
                VirtuaCamLog::LogHr(L"InitPrintWindowCapture failed; falling through to BitBlt", hr);
                ResetSharedOutputs();
            }
        }

        if (g_captureBackend == CaptureBackend::None) {
            // Method 1: BitBlt last resort (classic Win32 only).
            RETURN_IF_FAILED(InitBitBltCapture(hwndToCapture));
            VirtuaCamLog::LogLine(L"Capture init: using BitBlt fallback");
            g_captureBackend = CaptureBackend::BitBlt;
        }

        g_isCapturing = true;
        g_loggedFirstFrame = false;
        return S_OK;
    }

    bool ProcessFrame()
    {
        if (!g_isCapturing) return false;

        if (g_captureBackend == CaptureBackend::PrintWindow) {
            if (FAILED(CapturePrintWindowFrame())) return false;
        } else if (g_captureBackend == CaptureBackend::BitBlt) {
            if (FAILED(CaptureBitBltFrame())) return false;
        } else {
            // WGC path
            if (!g_framePool) return false;

            ComPtr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame> frame;
            if (FAILED(g_framePool->TryGetNextFrame(frame.ReleaseAndGetAddressOf())) || !frame) {
                return false;
            }

            ComPtr<ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface> surface;
            if (FAILED(frame->get_Surface(surface.ReleaseAndGetAddressOf())) || !surface) {
                return false;
            }

            ComPtr<IDirect3DDxgiInterfaceAccess> surfaceAccess;
            if (FAILED(surface.As(&surfaceAccess)) || !surfaceAccess) {
                return false;
            }

            ComPtr<ID3D11Texture2D> frameTexture;
            if (FAILED(surfaceAccess->GetInterface(IID_PPV_ARGS(&frameTexture))) || !frameTexture) {
                return false;
            }

            D3D11_TEXTURE2D_DESC frameDesc = {};
            frameTexture->GetDesc(&frameDesc);
            if (frameDesc.Width != g_captureWidth || frameDesc.Height != g_captureHeight) {
                g_captureWidth = frameDesc.Width;
                g_captureHeight = frameDesc.Height;
                VirtuaCamLog::LogLine(std::format(L"WGC source resized: {}x{}", g_captureWidth, g_captureHeight));
            }
            if (FAILED(RenderTextureToCanvas(frameTexture.Get(), frameDesc.Width, frameDesc.Height))) {
                return false;
            }
        }

        UINT64 newFenceValue = g_fenceValue.fetch_add(1) + 1;
        g_d3d11Context4->Signal(g_sharedD3D11Fence.Get(), newFenceValue);
        g_d3d11Context->Flush();

        if (g_pManifestView) {
            InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&g_pManifestView->frameValue), newFenceValue);
        }

        if (!g_loggedFirstFrame) {
            VirtuaCamLog::LogLine(std::format(
                L"First producer frame: type=capture backend={} hwnd={} size={}x{} frameValue={}",
                (g_captureBackend == CaptureBackend::Wgc) ? L"wgc" : (g_captureBackend == CaptureBackend::PrintWindow) ? L"printwindow" : L"bitblt",
                static_cast<UINT64>(reinterpret_cast<UINT_PTR>(g_captureTargetHwnd)),
                g_captureWidth,
                g_captureHeight,
                newFenceValue));
            g_loggedFirstFrame = true;
        }
        return true;
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
        ResetSharedOutputs();
        g_captureTargetHwnd = nullptr;
        g_captureTargetMonitor = nullptr;
        g_captureBackend = CaptureBackend::None;

        if (g_d3d11Context) g_d3d11Context->ClearState();
        g_d3d11Context4.Reset();
        g_d3d11Context.Reset();
        g_d3d11Device5.Reset();
        g_d3d11Device.Reset();

        if (g_roInitialized) {
            RoUninitialize();
            g_roInitialized = false;
        }
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

    bool LaunchVirtuaCamStartupInActiveSession(const std::wstring& exePath, const std::wstring& startupArgs)
    {
        const DWORD sessionId = WTSGetActiveConsoleSessionId();
        if (sessionId == 0xFFFFFFFF) {
            VirtuaCamLog::LogLine(L"Watcher: no active console session for CreateProcessAsUser");
            return false;
        }

        wil::unique_handle userToken;
        if (!WTSQueryUserToken(sessionId, userToken.put())) {
            VirtuaCamLog::LogWin32(L"WTSQueryUserToken failed", GetLastError());
            return false;
        }

        wil::unique_handle primaryToken;
        if (!DuplicateTokenEx(
                userToken.get(),
                TOKEN_ALL_ACCESS,
                nullptr,
                SecurityIdentification,
                TokenPrimary,
                primaryToken.put())) {
            VirtuaCamLog::LogWin32(L"DuplicateTokenEx failed", GetLastError());
            return false;
        }

        LPVOID envBlock = nullptr;
        if (!CreateEnvironmentBlock(&envBlock, primaryToken.get(), FALSE)) {
            VirtuaCamLog::LogWin32(L"CreateEnvironmentBlock failed", GetLastError());
            envBlock = nullptr;
        }

        STARTUPINFOW si{};
        si.cb = sizeof(si);
        si.lpDesktop = (LPWSTR)L"winsta0\\default";

        PROCESS_INFORMATION pi{};
        const std::wstring cmdLine = std::format(L"\"{}\" {}", exePath, startupArgs);
        std::vector<wchar_t> cmdLineMutable(cmdLine.begin(), cmdLine.end());
        cmdLineMutable.push_back(L'\0');

        const DWORD createFlags = CREATE_UNICODE_ENVIRONMENT;
        const BOOL ok = CreateProcessAsUserW(
            primaryToken.get(),
            exePath.c_str(),
            cmdLineMutable.data(),
            nullptr,
            nullptr,
            FALSE,
            createFlags,
            envBlock,
            nullptr,
            &si,
            &pi);

        if (envBlock) {
            DestroyEnvironmentBlock(envBlock);
        }

        if (!ok) {
            VirtuaCamLog::LogWin32(std::format(L"CreateProcessAsUserW failed: {}", exePath), GetLastError());
            return false;
        }

        if (pi.hThread) CloseHandle(pi.hThread);
        if (pi.hProcess) CloseHandle(pi.hProcess);
        return true;
    }

    bool LaunchVirtuaCamStartup()
    {
        std::wstring exePath = GetVirtuaCamExePathFromRegistryOrDefault();
        const std::wstring cmdLine = GetCommandLineW() ? GetCommandLineW() : L"";
        const bool enableDebugLogging = HasArg(cmdLine, L"-debug");
        std::wstring startupArgs = enableDebugLogging ? L"/startup -debug" : L"/startup";

        wchar_t extraArgs[1024] = {};
        const DWORD extraArgsLength = GetEnvironmentVariableW(
            L"VIRTUACAM_STARTUP_ARGS",
            extraArgs,
            ARRAYSIZE(extraArgs));
        if (extraArgsLength > 0 && extraArgsLength < ARRAYSIZE(extraArgs)) {
            startupArgs += L" ";
            startupArgs += extraArgs;
        }

        // Prefer ShellExecuteExW for normal user-session watcher; fall back to CreateProcessAsUser for service/session-0.
        SHELLEXECUTEINFOW sei = {};
        sei.cbSize = sizeof(sei);
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        sei.lpFile = exePath.c_str();
        sei.lpParameters = startupArgs.c_str();
        sei.nShow = SW_HIDE;
        if (ShellExecuteExW(&sei)) {
            if (sei.hProcess) {
                CloseHandle(sei.hProcess);
            }
            return true;
        }

        const DWORD err = GetLastError();
        VirtuaCamLog::LogWin32(std::format(L"ShellExecuteExW failed for {}; falling back to CreateProcessAsUser", exePath), err);
        return LaunchVirtuaCamStartupInActiveSession(exePath, startupArgs);
    }

    HANDLE OpenClientRequestEventHandle()
    {
        HANDLE eventHandle = OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE, kGlobalClientRequestEventName);
        if (eventHandle) {
            return eventHandle;
        }

        return OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE, FALSE, kClientRequestEventName);
    }

    HANDLE CreateRegisteredClientRequestEventHandle()
    {
        HANDLE eventHandle = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!eventHandle) {
            VirtuaCamLog::LogWin32(L"CreateEventW failed for watcher request event", GetLastError());
            return nullptr;
        }

        DriverBridge driverBridge;
        HRESULT hr = driverBridge.Initialize();
        if (FAILED(hr)) {
            VirtuaCamLog::LogHr(L"Watcher DriverBridge::Initialize failed", hr);
            CloseHandle(eventHandle);
            return nullptr;
        }

        hr = driverBridge.RegisterClientRequestEvent(eventHandle);
        if (FAILED(hr)) {
            VirtuaCamLog::LogHr(L"Watcher DriverBridge::RegisterClientRequestEvent failed", hr);
            CloseHandle(eventHandle);
            return nullptr;
        }

        VirtuaCamLog::LogLine(std::format(
            L"Watcher registered session-local client request event handle=0x{:X}",
            static_cast<unsigned long long>(reinterpret_cast<UINT_PTR>(eventHandle))));
        return eventHandle;
    }

    DWORD RunWatcherLoop(HANDLE stopEvent)
    {
        int launchFailCount = 0;
        while (true) {
            if (stopEvent && WaitForSingleObject(stopEvent, 0) == WAIT_OBJECT_0) {
                return 0;
            }

            HANDLE requestEvent = CreateRegisteredClientRequestEventHandle();
            if (!requestEvent) {
                Sleep(kWatcherOpenRetryMs);
                continue;
            }

            while (true) {
                DWORD waitResult = WAIT_FAILED;
                if (stopEvent) {
                    HANDLE handles[2] = { stopEvent, requestEvent };
                    waitResult = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
                    if (waitResult == WAIT_OBJECT_0) {
                        CloseHandle(requestEvent);
                        return 0;
                    }
                    if (waitResult != (WAIT_OBJECT_0 + 1)) {
                        break;
                    }
                } else {
                    waitResult = WaitForSingleObject(requestEvent, INFINITE);
                    if (waitResult != WAIT_OBJECT_0) {
                        break;
                    }
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

    DWORD WINAPI WatcherThreadProc(LPVOID)
    {
        return RunWatcherLoop(nullptr);
    }

}

static SERVICE_STATUS_HANDLE g_serviceStatusHandle = nullptr;
static SERVICE_STATUS g_serviceStatus = {};
static HANDLE g_serviceStopEvent = nullptr;
static HANDLE g_serviceWorkerThread = nullptr;

static bool IsProcessRunningForService(const wchar_t* processName)
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

static bool ReadVirtuaCamRegistryString(const wchar_t* valueName, std::wstring& value)
{
    DWORD valueType = 0;
    DWORD valueSize = 0;
    const wchar_t keyPath[] = L"SOFTWARE\\VirtuaCam";

    LSTATUS status = RegGetValueW(
        HKEY_LOCAL_MACHINE,
        keyPath,
        valueName,
        RRF_RT_REG_SZ,
        &valueType,
        nullptr,
        &valueSize);
    if (status != ERROR_SUCCESS || valueSize < sizeof(wchar_t)) {
        return false;
    }

    std::vector<wchar_t> buffer((valueSize / sizeof(wchar_t)) + 1);
    status = RegGetValueW(
        HKEY_LOCAL_MACHINE,
        keyPath,
        valueName,
        RRF_RT_REG_SZ,
        &valueType,
        buffer.data(),
        &valueSize);
    if (status != ERROR_SUCCESS || buffer.empty() || buffer[0] == L'\0') {
        return false;
    }

    value.assign(buffer.data());
    return !value.empty();
}

static bool CanonicalizePathForService(const std::wstring& path, std::wstring& canonical)
{
    canonical.clear();
    if (path.empty()) {
        return false;
    }

    DWORD needed = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
    if (needed == 0) {
        return false;
    }

    std::vector<wchar_t> buffer(needed + 1);
    DWORD written = GetFullPathNameW(path.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
    if (written == 0 || written >= buffer.size()) {
        return false;
    }

    canonical.assign(buffer.data(), written);
    std::replace(canonical.begin(), canonical.end(), L'/', L'\\');
    return true;
}

static std::wstring ToLowerForService(std::wstring value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
        return static_cast<wchar_t>(towlower(ch));
    });
    return value;
}

static bool IsPathUnderDirectoryForService(const std::wstring& path, const std::wstring& directory)
{
    std::wstring pathLower = ToLowerForService(path);
    std::wstring directoryLower = ToLowerForService(directory);
    while (!directoryLower.empty() &&
           (directoryLower.back() == L'\\' || directoryLower.back() == L'/')) {
        directoryLower.pop_back();
    }
    directoryLower.push_back(L'\\');
    return pathLower.rfind(directoryLower, 0) == 0;
}

static bool ComputeFileSha256HexForService(const std::wstring& path, std::wstring& hashHex)
{
    hashHex.clear();

    wil::unique_hfile file(CreateFileW(
        path.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr));
    if (!file) {
        return false;
    }

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD objectLength = 0;
    DWORD hashLength = 0;
    DWORD bytesReturned = 0;
    std::vector<BYTE> hashObject;
    std::vector<BYTE> digest;
    BYTE buffer[64 * 1024] = {};
    bool ok = false;

    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0))) {
        goto Cleanup;
    }
    if (!BCRYPT_SUCCESS(BCryptGetProperty(
            algorithm,
            BCRYPT_OBJECT_LENGTH,
            reinterpret_cast<PUCHAR>(&objectLength),
            sizeof(objectLength),
            &bytesReturned,
            0)) ||
        !BCRYPT_SUCCESS(BCryptGetProperty(
            algorithm,
            BCRYPT_HASH_LENGTH,
            reinterpret_cast<PUCHAR>(&hashLength),
            sizeof(hashLength),
            &bytesReturned,
            0)) ||
        objectLength == 0 ||
        hashLength == 0) {
        goto Cleanup;
    }

    hashObject.resize(objectLength);
    digest.resize(hashLength);
    if (!BCRYPT_SUCCESS(BCryptCreateHash(
            algorithm,
            &hash,
            hashObject.data(),
            static_cast<ULONG>(hashObject.size()),
            nullptr,
            0,
            0))) {
        goto Cleanup;
    }

    for (;;) {
        DWORD bytesRead = 0;
        if (!ReadFile(file.get(), buffer, sizeof(buffer), &bytesRead, nullptr)) {
            goto Cleanup;
        }
        if (bytesRead == 0) {
            break;
        }
        if (!BCRYPT_SUCCESS(BCryptHashData(hash, buffer, bytesRead, 0))) {
            goto Cleanup;
        }
    }

    if (!BCRYPT_SUCCESS(BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0))) {
        goto Cleanup;
    }

    hashHex.reserve(digest.size() * 2);
    for (BYTE byte : digest) {
        wchar_t hex[3] = {};
        if (FAILED(StringCchPrintfW(hex, ARRAYSIZE(hex), L"%02X", byte))) {
            goto Cleanup;
        }
        hashHex.append(hex);
    }
    ok = true;

Cleanup:
    if (hash) {
        BCryptDestroyHash(hash);
    }
    if (algorithm) {
        BCryptCloseAlgorithmProvider(algorithm, 0);
    }
    if (!ok) {
        hashHex.clear();
    }
    return ok;
}

static std::wstring GetTrustedVirtuaCamExePathForService()
{
    std::wstring installDir;
    std::wstring exePath;
    std::wstring expectedHash;
    if (!ReadVirtuaCamRegistryString(L"InstallDir", installDir) ||
        !ReadVirtuaCamRegistryString(L"VirtuaCamExe", exePath) ||
        !ReadVirtuaCamRegistryString(L"VirtuaCamExeSha256", expectedHash)) {
        VirtuaCamLog::LogLine(L"Watcher service: trusted VirtuaCam registry config missing");
        return L"";
    }

    std::wstring canonicalInstallDir;
    std::wstring canonicalExePath;
    if (!CanonicalizePathForService(installDir, canonicalInstallDir) ||
        !CanonicalizePathForService(exePath, canonicalExePath) ||
        !IsPathUnderDirectoryForService(canonicalExePath, canonicalInstallDir)) {
        VirtuaCamLog::LogLine(L"Watcher service: VirtuaCamExe failed install-dir trust check");
        return L"";
    }

    DWORD attrs = GetFileAttributesW(canonicalExePath.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        VirtuaCamLog::LogLine(L"Watcher service: VirtuaCamExe missing or directory");
        return L"";
    }

    std::wstring actualHash;
    if (!ComputeFileSha256HexForService(canonicalExePath, actualHash) ||
        _wcsicmp(actualHash.c_str(), expectedHash.c_str()) != 0) {
        VirtuaCamLog::LogLine(L"Watcher service: VirtuaCamExe SHA-256 trust check failed");
        return L"";
    }

    return canonicalExePath;
}

static bool LaunchVirtuaCamStartupFromService()
{
    std::wstring exePath = GetTrustedVirtuaCamExePathForService();
    if (exePath.empty()) {
        return false;
    }
    std::wstring startupArgs = L"/startup";

    const DWORD sessionId = WTSGetActiveConsoleSessionId();
    if (sessionId == 0xFFFFFFFF) {
        VirtuaCamLog::LogLine(L"Watcher service: no active console session for CreateProcessAsUser");
        return false;
    }

    wil::unique_handle userToken;
    if (!WTSQueryUserToken(sessionId, userToken.put())) {
        VirtuaCamLog::LogWin32(L"Watcher service: WTSQueryUserToken failed", GetLastError());
        return false;
    }

    wil::unique_handle primaryToken;
    if (!DuplicateTokenEx(
            userToken.get(),
            TOKEN_ALL_ACCESS,
            nullptr,
            SecurityIdentification,
            TokenPrimary,
            primaryToken.put())) {
        VirtuaCamLog::LogWin32(L"Watcher service: DuplicateTokenEx failed", GetLastError());
        return false;
    }

    LPVOID envBlock = nullptr;
    if (!CreateEnvironmentBlock(&envBlock, primaryToken.get(), FALSE)) {
        VirtuaCamLog::LogWin32(L"Watcher service: CreateEnvironmentBlock failed", GetLastError());
        envBlock = nullptr;
    }

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.lpDesktop = (LPWSTR)L"winsta0\\default";

    PROCESS_INFORMATION pi{};
    const std::wstring cmdLine = std::format(L"\"{}\" {}", exePath, startupArgs);
    std::vector<wchar_t> cmdLineMutable(cmdLine.begin(), cmdLine.end());
    cmdLineMutable.push_back(L'\0');

    const DWORD createFlags = CREATE_UNICODE_ENVIRONMENT;
    const BOOL ok = CreateProcessAsUserW(
        primaryToken.get(),
        exePath.c_str(),
        cmdLineMutable.data(),
        nullptr,
        nullptr,
        FALSE,
        createFlags,
        envBlock,
        nullptr,
        &si,
        &pi);

    if (envBlock) {
        DestroyEnvironmentBlock(envBlock);
    }

    if (!ok) {
        VirtuaCamLog::LogWin32(std::format(L"Watcher service: CreateProcessAsUserW failed: {}", exePath), GetLastError());
        return false;
    }

    if (pi.hThread) CloseHandle(pi.hThread);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    return true;
}

static HANDLE CreateRegisteredClientRequestEventHandleForService()
{
    HANDLE eventHandle = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!eventHandle) {
        VirtuaCamLog::LogWin32(L"Watcher service: CreateEventW failed", GetLastError());
        return nullptr;
    }

    DriverBridge driverBridge;
    HRESULT hr = driverBridge.Initialize();
    if (FAILED(hr)) {
        VirtuaCamLog::LogHr(L"Watcher service: DriverBridge::Initialize failed", hr);
        CloseHandle(eventHandle);
        return nullptr;
    }

    hr = driverBridge.RegisterClientRequestEvent(eventHandle);
    if (FAILED(hr)) {
        VirtuaCamLog::LogHr(L"Watcher service: DriverBridge::RegisterClientRequestEvent failed", hr);
        CloseHandle(eventHandle);
        return nullptr;
    }

    VirtuaCamLog::LogLine(std::format(
        L"Watcher service: registered client request event handle=0x{:X}",
        static_cast<unsigned long long>(reinterpret_cast<UINT_PTR>(eventHandle))));
    return eventHandle;
}

static DWORD RunWatcherLoopForService(HANDLE stopEvent)
{
    int launchFailCount = 0;
    while (true) {
        if (stopEvent && WaitForSingleObject(stopEvent, 0) == WAIT_OBJECT_0) {
            return 0;
        }

        HANDLE requestEvent = CreateRegisteredClientRequestEventHandleForService();
        if (!requestEvent) {
            Sleep(1000);
            continue;
        }

        while (true) {
            HANDLE handles[2] = { stopEvent, requestEvent };
            const DWORD waitResult = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
            if (waitResult == WAIT_OBJECT_0) {
                CloseHandle(requestEvent);
                return 0;
            }
            if (waitResult != (WAIT_OBJECT_0 + 1)) {
                break;
            }

            if (!IsProcessRunningForService(L"VirtuaCam.exe")) {
                if (launchFailCount < 3) {
                    if (LaunchVirtuaCamStartupFromService()) {
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

static void SetWatcherServiceStatus(DWORD state, DWORD win32ExitCode = NO_ERROR, DWORD waitHintMs = 0)
{
    if (!g_serviceStatusHandle) return;

    g_serviceStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_serviceStatus.dwCurrentState = state;
    g_serviceStatus.dwWin32ExitCode = win32ExitCode;
    g_serviceStatus.dwWaitHint = waitHintMs;

    if (state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING) {
        g_serviceStatus.dwControlsAccepted = 0;
        g_serviceStatus.dwCheckPoint++;
    } else {
        g_serviceStatus.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
        g_serviceStatus.dwCheckPoint = 0;
    }

    (void)SetServiceStatus(g_serviceStatusHandle, &g_serviceStatus);
}

static void WINAPI WatcherServiceCtrlHandler(DWORD control)
{
    switch (control) {
        case SERVICE_CONTROL_STOP:
        case SERVICE_CONTROL_SHUTDOWN:
            SetWatcherServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 2000);
            if (g_serviceStopEvent) {
                SetEvent(g_serviceStopEvent);
            }
            break;
        default:
            break;
    }
}

static DWORD WINAPI WatcherServiceWorkerThreadProc(LPVOID)
{
    const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        VirtuaCamLog::LogHr(L"Watcher service CoInitializeEx failed", hr);
        return 1;
    }
    const DWORD exitCode = RunWatcherLoopForService(g_serviceStopEvent);
    CoUninitialize();
    return exitCode;
}

void WINAPI WatcherServiceMain(DWORD, LPWSTR*)
{
    g_serviceStatusHandle = RegisterServiceCtrlHandlerW(kWatcherServiceName, WatcherServiceCtrlHandler);
    if (!g_serviceStatusHandle) {
        return;
    }

    g_serviceStatus.dwCheckPoint = 1;
    SetWatcherServiceStatus(SERVICE_START_PENDING, NO_ERROR, 5000);

    g_serviceStopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_serviceStopEvent) {
        SetWatcherServiceStatus(SERVICE_STOPPED, GetLastError(), 0);
        return;
    }

    g_serviceWorkerThread = CreateThread(nullptr, 0, WatcherServiceWorkerThreadProc, nullptr, 0, nullptr);
    if (!g_serviceWorkerThread) {
        const DWORD err = GetLastError();
        CloseHandle(g_serviceStopEvent);
        g_serviceStopEvent = nullptr;
        SetWatcherServiceStatus(SERVICE_STOPPED, err, 0);
        return;
    }

    SetWatcherServiceStatus(SERVICE_RUNNING, NO_ERROR, 0);
    WaitForSingleObject(g_serviceWorkerThread, INFINITE);

    CloseHandle(g_serviceWorkerThread);
    g_serviceWorkerThread = nullptr;
    CloseHandle(g_serviceStopEvent);
    g_serviceStopEvent = nullptr;

    SetWatcherServiceStatus(SERVICE_STOPPED, NO_ERROR, 0);
}

namespace BuiltInCameraProducer
{
    static ComPtr<ID3D11Device> g_d3d11Device;
    static ComPtr<ID3D11Device5> g_d3d11Device5;
    static ComPtr<ID3D11DeviceContext> g_d3d11Context;
    static ComPtr<ID3D11DeviceContext4> g_d3d11Context4;
    static ComPtr<ID3D11Texture2D> g_sharedD3D11Texture;
    static ComPtr<ID3D11Fence> g_sharedD3D11Fence;
    static ComPtr<ID3D11RenderTargetView> g_canvasRTV;
    static ComPtr<ID3D11Texture2D> g_sourceD3D11Texture;
    static ComPtr<ID3D11ShaderResourceView> g_sourceSRV;
    static ComPtr<ID3D11VertexShader> g_canvasVS;
    static ComPtr<ID3D11PixelShader> g_canvasPS;
    static ComPtr<ID3D11SamplerState> g_canvasSampler;
    static ComPtr<ID3D11Buffer> g_canvasConstants;
    static HANDLE g_hSharedTextureHandle = nullptr;
    static HANDLE g_hSharedFenceHandle = nullptr;
    static HANDLE g_hManifest = nullptr;
    static BroadcastManifest* g_pManifestView = nullptr;
    static std::atomic<UINT64> g_fenceValue = 0;
    static UINT64 g_brokerNonce = 0;

    static ComPtr<IMFSourceReader> g_sourceReader;
    static long g_videoWidth = 0;
    static long g_videoHeight = 0;
    static std::atomic<bool> g_isCapturing = false;
    static bool g_mfStarted = false;
    static bool g_loggedFirstFrame = false;
    static bool g_staticImageMode = false;

    static HRESULT InitD3D11()
    {
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        RETURN_IF_FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION, &g_d3d11Device, nullptr, &g_d3d11Context));
        RETURN_IF_FAILED(g_d3d11Device.As(&g_d3d11Device5));
        RETURN_IF_FAILED(g_d3d11Context.As(&g_d3d11Context4));
        return S_OK;
    }

    static HRESULT EnsureCameraSourceTexture(UINT width, UINT height)
    {
        RETURN_HR_IF(E_INVALIDARG, width == 0 || height == 0);

        D3D11_TEXTURE2D_DESC currentDesc = {};
        if (g_sourceD3D11Texture) {
            g_sourceD3D11Texture->GetDesc(&currentDesc);
        }
        if (g_sourceD3D11Texture && g_sourceSRV && currentDesc.Width == width && currentDesc.Height == height) {
            return S_OK;
        }

        g_sourceSRV.Reset();
        g_sourceD3D11Texture.Reset();

        D3D11_TEXTURE2D_DESC td{};
        td.Width = width;
        td.Height = height;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        RETURN_IF_FAILED(g_d3d11Device->CreateTexture2D(&td, nullptr, &g_sourceD3D11Texture));
        RETURN_IF_FAILED(g_d3d11Device->CreateShaderResourceView(g_sourceD3D11Texture.Get(), nullptr, &g_sourceSRV));
        return S_OK;
    }

    static HRESULT RenderCameraTextureToCanvas(ID3D11Texture2D* sourceTexture, UINT sourceWidth, UINT sourceHeight)
    {
        RETURN_HR_IF_NULL(E_POINTER, sourceTexture);
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasRTV.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasVS.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasPS.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasSampler.Get());
        RETURN_HR_IF_NULL(E_UNEXPECTED, g_canvasConstants.Get());

        ComPtr<ID3D11ShaderResourceView> sourceSRV;
        if (sourceTexture == g_sourceD3D11Texture.Get() && g_sourceSRV) {
            sourceSRV = g_sourceSRV;
        } else {
            RETURN_IF_FAILED(g_d3d11Device->CreateShaderResourceView(sourceTexture, nullptr, &sourceSRV));
        }

        const float clearColor[] = { 33.0f / 255.0f, 33.0f / 255.0f, 33.0f / 255.0f, 1.0f };
        const CanvasBlitConstants constants = GetFullSourceUvConstants();
        D3D11_VIEWPORT viewport = GetContainCanvasViewport(sourceWidth, sourceHeight);
        ID3D11RenderTargetView* rtvs[] = { g_canvasRTV.Get() };
        ID3D11ShaderResourceView* srvs[] = { sourceSRV.Get() };
        ID3D11SamplerState* samplers[] = { g_canvasSampler.Get() };
        ID3D11Buffer* constantBuffers[] = { g_canvasConstants.Get() };

        g_d3d11Context->OMSetRenderTargets(1, rtvs, nullptr);
        g_d3d11Context->ClearRenderTargetView(g_canvasRTV.Get(), clearColor);
        g_d3d11Context->UpdateSubresource(g_canvasConstants.Get(), 0, nullptr, &constants, 0, 0);
        g_d3d11Context->RSSetViewports(1, &viewport);
        g_d3d11Context->VSSetShader(g_canvasVS.Get(), nullptr, 0);
        g_d3d11Context->PSSetShader(g_canvasPS.Get(), nullptr, 0);
        g_d3d11Context->PSSetConstantBuffers(0, 1, constantBuffers);
        g_d3d11Context->PSSetShaderResources(0, 1, srvs);
        g_d3d11Context->PSSetSamplers(0, 1, samplers);
        g_d3d11Context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        g_d3d11Context->Draw(3, 0);

        ID3D11ShaderResourceView* nullSrv[] = { nullptr };
        g_d3d11Context->PSSetShaderResources(0, 1, nullSrv);
        return S_OK;
    }

    static HRESULT InitSharedOutputs(UINT width, UINT height)
    {
        width = kProducerCanvasWidth;
        height = kProducerCanvasHeight;

        D3D11_TEXTURE2D_DESC td{};
        td.Width = width;
        td.Height = height;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        td.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
        RETURN_IF_FAILED(g_d3d11Device->CreateTexture2D(&td, nullptr, &g_sharedD3D11Texture));
        RETURN_IF_FAILED(g_d3d11Device->CreateRenderTargetView(g_sharedD3D11Texture.Get(), nullptr, &g_canvasRTV));
        RETURN_IF_FAILED(CreateCanvasBlitResources(
            g_d3d11Device.Get(),
            g_canvasVS.ReleaseAndGetAddressOf(),
            g_canvasPS.ReleaseAndGetAddressOf(),
            g_canvasSampler.ReleaseAndGetAddressOf(),
            g_canvasConstants.ReleaseAndGetAddressOf()));
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

        ComPtr<IDXGIDevice> dxgi;
        g_d3d11Device.As(&dxgi);
        ComPtr<IDXGIAdapter> adapter;
        dxgi->GetAdapter(&adapter);
        DXGI_ADAPTER_DESC desc{};
        adapter->GetDesc(&desc);
        RETURN_HR_IF(E_FAIL, !InitializeBroadcastManifest(
            g_pManifestView,
            pid,
            g_brokerNonce,
            width,
            height,
            DXGI_FORMAT_B8G8R8A8_UNORM,
            desc.AdapterLuid,
            texName,
            fenceName));

        ComPtr<IDXGIResource1> r1;
        g_sharedD3D11Texture.As(&r1);
        RETURN_IF_FAILED(r1->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, texName.c_str(), &g_hSharedTextureHandle));
        RETURN_IF_FAILED(g_sharedD3D11Fence->CreateSharedHandle(&sa, GENERIC_READ | GENERIC_WRITE, fenceName.c_str(), &g_hSharedFenceHandle));
        g_pManifestView->sharedFenceHandleValue = static_cast<UINT64>(
            reinterpret_cast<UINT_PTR>(g_hSharedFenceHandle));

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
                    CameraDeviceLinksMatch(symbolicLink.get(), devicePath)) {
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
        UINT64 brokerNonceValue = 0;
        g_brokerNonce = 0;
        if (TryGetArgU64(argsStr, L"--broker-nonce", brokerNonceValue)) {
            g_brokerNonce = brokerNonceValue;
        }

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

        RETURN_IF_FAILED(InitSharedOutputs(kProducerCanvasWidth, kProducerCanvasHeight));
        RETURN_IF_FAILED(EnsureCameraSourceTexture(static_cast<UINT>(g_videoWidth), static_cast<UINT>(g_videoHeight)));

        g_isCapturing = true;
        g_loggedFirstFrame = false;
        return S_OK;
    }

    HRESULT InitializeFileProducer(const wchar_t* args)
    {
        std::wstring argsStr = args ? args : L"";
        UINT64 brokerNonceValue = 0;
        g_brokerNonce = 0;
        if (TryGetArgU64(argsStr, L"--broker-nonce", brokerNonceValue)) {
            g_brokerNonce = brokerNonceValue;
        }

        std::wstring filePath;
        RETURN_HR_IF(E_INVALIDARG, !TryGetArgValue(argsStr, L"--file", filePath) || filePath.empty());
        std::wstring mediaKind;
        (void)TryGetArgValue(argsStr, L"--media-kind", mediaKind);

        if (_wcsicmp(mediaKind.c_str(), L"image") == 0) {
            RETURN_IF_FAILED(InitD3D11());

            ComPtr<IWICImagingFactory> wicFactory;
            RETURN_IF_FAILED(CoCreateInstance(
                CLSID_WICImagingFactory,
                nullptr,
                CLSCTX_INPROC_SERVER,
                IID_PPV_ARGS(&wicFactory)));

            ComPtr<IWICBitmapDecoder> decoder;
            RETURN_IF_FAILED(wicFactory->CreateDecoderFromFilename(
                filePath.c_str(),
                nullptr,
                GENERIC_READ,
                WICDecodeMetadataCacheOnLoad,
                &decoder));

            ComPtr<IWICBitmapFrameDecode> frame;
            RETURN_IF_FAILED(decoder->GetFrame(0, &frame));

            UINT width = 0;
            UINT height = 0;
            RETURN_IF_FAILED(frame->GetSize(&width, &height));
            RETURN_HR_IF(E_FAIL, width == 0 || height == 0);

            ComPtr<IWICFormatConverter> converter;
            RETURN_IF_FAILED(wicFactory->CreateFormatConverter(&converter));
            RETURN_IF_FAILED(converter->Initialize(
                frame.Get(),
                GUID_WICPixelFormat32bppBGRA,
                WICBitmapDitherTypeNone,
                nullptr,
                0.0,
                WICBitmapPaletteTypeCustom));

            std::vector<BYTE> pixels(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
            RETURN_IF_FAILED(converter->CopyPixels(
                nullptr,
                width * 4,
                static_cast<UINT>(pixels.size()),
                pixels.data()));

            g_videoWidth = static_cast<long>(width);
            g_videoHeight = static_cast<long>(height);
            RETURN_IF_FAILED(InitSharedOutputs(kProducerCanvasWidth, kProducerCanvasHeight));
            RETURN_IF_FAILED(EnsureCameraSourceTexture(width, height));
            g_d3d11Context->UpdateSubresource(g_sourceD3D11Texture.Get(), 0, NULL, pixels.data(), width * 4, 0);
            RETURN_IF_FAILED(RenderCameraTextureToCanvas(g_sourceD3D11Texture.Get(), width, height));

            g_staticImageMode = true;
            g_isCapturing = true;
            g_loggedFirstFrame = false;
            VirtuaCamLog::LogLine(std::format(L"BuiltInMediaProducer: image={} size={}x{}", filePath, g_videoWidth, g_videoHeight));
            return S_OK;
        }

        if (!g_mfStarted) {
            RETURN_IF_FAILED(MFStartup(MF_VERSION));
            g_mfStarted = true;
        }
        g_staticImageMode = false;

        RETURN_IF_FAILED(InitD3D11());

        ComPtr<IMFAttributes> readerAttributes;
        RETURN_IF_FAILED(MFCreateAttributes(&readerAttributes, 2));
        RETURN_IF_FAILED(readerAttributes->SetUINT32(MF_READWRITE_DISABLE_CONVERTERS, FALSE));
        RETURN_IF_FAILED(readerAttributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE));

        RETURN_IF_FAILED(MFCreateSourceReaderFromURL(filePath.c_str(), readerAttributes.Get(), &g_sourceReader));

        ComPtr<IMFMediaType> outputType;
        RETURN_IF_FAILED(MFCreateMediaType(&outputType));
        RETURN_IF_FAILED(outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
        RETURN_IF_FAILED(outputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32));

        for (DWORD i = 0;; ++i) {
            ComPtr<IMFMediaType> nativeType;
            HRESULT hr = g_sourceReader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &nativeType);
            if (hr == MF_E_NO_MORE_TYPES) break;
            RETURN_IF_FAILED(hr);

            if (SUCCEEDED(g_sourceReader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, nativeType.Get())) &&
                SUCCEEDED(g_sourceReader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, outputType.Get()))) {
                break;
            }
        }

        ComPtr<IMFMediaType> currentType;
        RETURN_IF_FAILED(g_sourceReader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &currentType));
        MFGetAttributeSize(currentType.Get(), MF_MT_FRAME_SIZE, (UINT32*)&g_videoWidth, (UINT32*)&g_videoHeight);
        RETURN_HR_IF(E_FAIL, g_videoWidth <= 0 || g_videoHeight <= 0);

        RETURN_IF_FAILED(InitSharedOutputs(kProducerCanvasWidth, kProducerCanvasHeight));
        RETURN_IF_FAILED(EnsureCameraSourceTexture(static_cast<UINT>(g_videoWidth), static_cast<UINT>(g_videoHeight)));

        g_isCapturing = true;
        g_loggedFirstFrame = false;
        VirtuaCamLog::LogLine(std::format(L"BuiltInMediaProducer: file={} size={}x{}", filePath, g_videoWidth, g_videoHeight));
        return S_OK;
    }

    bool ProcessFrame()
    {
        if (!g_isCapturing) return false;

        if (g_staticImageMode) {
            UINT64 newFenceValue = g_fenceValue.fetch_add(1) + 1;
            g_d3d11Context4->Signal(g_sharedD3D11Fence.Get(), newFenceValue);
            g_d3d11Context->Flush();
            if (g_pManifestView) {
                InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&g_pManifestView->frameValue), newFenceValue);
            }
            if (!g_loggedFirstFrame) {
                VirtuaCamLog::LogLine(std::format(
                    L"First producer frame: type=image size={}x{} frameValue={}",
                    g_videoWidth,
                    g_videoHeight,
                    newFenceValue));
                g_loggedFirstFrame = true;
            }
            return true;
        }

        if (!g_sourceReader) return false;

        ComPtr<IMFSample> sample;
        DWORD streamFlags = 0;
        LONGLONG timestamp = 0;
        HRESULT hr = g_sourceReader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, NULL, &streamFlags, &timestamp, &sample);
        if (FAILED(hr)) return false;
        if ((streamFlags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
            PROPVARIANT pos{};
            PropVariantInit(&pos);
            pos.vt = VT_I8;
            pos.hVal.QuadPart = 0;
            (void)g_sourceReader->SetCurrentPosition(GUID_NULL, pos);
            PropVariantClear(&pos);
            return false;
        }
        if (!sample) return false;

        ComPtr<IMFMediaBuffer> buffer;
        if (FAILED(sample->ConvertToContiguousBuffer(&buffer)) || !buffer) return false;

        BYTE* data = nullptr;
        DWORD length = 0;
        if (FAILED(buffer->Lock(&data, NULL, &length)) || !data) return false;
        if (FAILED(EnsureCameraSourceTexture(static_cast<UINT>(g_videoWidth), static_cast<UINT>(g_videoHeight)))) {
            (void)buffer->Unlock();
            return false;
        }
        g_d3d11Context->UpdateSubresource(g_sourceD3D11Texture.Get(), 0, NULL, data, g_videoWidth * 4, 0);
        (void)buffer->Unlock();
        if (FAILED(RenderCameraTextureToCanvas(
                g_sourceD3D11Texture.Get(),
                static_cast<UINT>(g_videoWidth),
                static_cast<UINT>(g_videoHeight)))) {
            return false;
        }

        UINT64 newFenceValue = g_fenceValue.fetch_add(1) + 1;
        g_d3d11Context4->Signal(g_sharedD3D11Fence.Get(), newFenceValue);
        g_d3d11Context->Flush();
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
        return true;
    }

    void ShutdownProducer()
    {
        if (!g_isCapturing.exchange(false)) return;
        g_staticImageMode = false;

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
        g_brokerNonce = 0;

        g_sharedD3D11Fence.Reset();
        g_sharedD3D11Texture.Reset();
        g_canvasRTV.Reset();
        g_sourceSRV.Reset();
        g_sourceD3D11Texture.Reset();
        g_canvasVS.Reset();
        g_canvasPS.Reset();
        g_canvasSampler.Reset();
        g_canvasConstants.Reset();

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
    if (type == L"media") {
        module.hModule = nullptr;
        module.Initialize = &BuiltInCameraProducer::InitializeFileProducer;
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

    if (HasArg(cmdLine, L"--service")) {
        VirtuaCamLog::LogLine(L"Starting watcher service mode (--service)");
        SERVICE_TABLE_ENTRYW serviceTable[] = {
            { (LPWSTR)kWatcherServiceName, WatcherServiceMain },
            { nullptr, nullptr }
        };
        if (!StartServiceCtrlDispatcherW(serviceTable)) {
            VirtuaCamLog::LogWin32(L"StartServiceCtrlDispatcherW failed", GetLastError());
            return 20;
        }
        return 0;
    }

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

    const HRESULT initHr = module.Initialize(producerArgs.c_str());
    if (FAILED(initHr))
    {
        VirtuaCamLog::LogHr(std::format(L"InitializeProducer HRESULT: type={} args={}", producerType, producerArgs), initHr);
        VirtuaCamLog::LogLine(std::format(L"InitializeProducer failed: type={} args={}", producerType, producerArgs));
        module.Shutdown();
        if (module.hModule) FreeLibrary(module.hModule);
        return 3;
    }
    VirtuaCamLog::LogLine(std::format(L"InitializeProducer success: type={} args={}", producerType, producerArgs));
    
    MSG msg = {};
    ULONGLONG nextProcessTick = GetTickCount64();
    DWORD processIntervalMs = kProducerFrameIntervalMs;
    while (msg.message != WM_QUIT)
    {
        if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        else
        {
            const ULONGLONG now = GetTickCount64();
            const DWORD waitMs = (now >= nextProcessTick)
                ? 0
                : static_cast<DWORD>(std::min<ULONGLONG>(
                    nextProcessTick - now,
                    processIntervalMs));
            DWORD waitResult = MsgWaitForMultipleObjectsEx(
                0,
                nullptr,
                waitMs,
                QS_ALLINPUT,
                MWMO_INPUTAVAILABLE);
            if (waitResult == WAIT_TIMEOUT) {
                const ULONGLONG processNow = GetTickCount64();
                if (processNow < nextProcessTick) {
                    continue;
                }
                const bool producedFrame = module.Process();
                processIntervalMs = producedFrame
                    ? kProducerFrameIntervalMs
                    : std::min<DWORD>(kProducerIdleBackoffMaxMs, std::max<DWORD>(kProducerFrameIntervalMs, processIntervalMs * 2));
                nextProcessTick = processNow + processIntervalMs;
            }
        }
    }

    module.Shutdown();
    if (module.hModule) FreeLibrary(module.hModule);
    CoUninitialize();
    return 0;
}
