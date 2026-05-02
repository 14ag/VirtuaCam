#include "DriverBridge.h"

#include <dshow.h>
#include <dvdmedia.h>
#include <d3dcompiler.h>
#include <algorithm>
#include <cstdio>
#include <cwctype>
#include <winioctl.h>
#include "RuntimeLog.h"

#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "ksproxy.lib")

namespace
{
    constexpr UINT kDriverWidth = 1280;
    constexpr UINT kDriverHeight = 720;
    constexpr UINT kDriverBytesPerPixel = 3;
    constexpr UINT kDriverFrameSize = kDriverWidth * kDriverHeight * kDriverBytesPerPixel;

    const GUID kDriverPropertySet = { 0xcb043957, 0x7b35, 0x456e, { 0x9b, 0x61, 0x55, 0x13, 0x93, 0x0f, 0x4d, 0x8e } };
    constexpr ULONG kDriverPropertyIdFrame = 0;
    constexpr ULONG kDriverPropertyIdConnect = 1;
    constexpr ULONG kDriverPropertyIdDisconnect = 2;
    constexpr ULONG kDriverPropertyIdStatus = 3;
    constexpr ULONG kDriverPropertyIdRegisterEvent = 4;
    constexpr ULONG kDriverHardwareStateRunning = 2;
    constexpr ULONG kDriverSetDataRejectNotRunning = 1;
    constexpr ULONG kDriverSetDataRejectNotConnected = 3;
    const GUID kVideoCameraCategory = { 0xe5323777, 0xf976, 0x4f5b, { 0x9b, 0x55, 0xb9, 0x46, 0x99, 0xc4, 0x6e, 0x44 } };
    const GUID kCaptureCategory = { 0x65e8773d, 0x8f56, 0x11d0, { 0xa3, 0xb9, 0x00, 0xa0, 0xc9, 0x22, 0x31, 0x96 } };
    constexpr const wchar_t* kVideoCameraCategoryGuid = L"{e5323777-f976-4f5b-9b55-b94699c46e44}";
    constexpr const wchar_t* kCaptureCategoryGuid = L"{65e8773d-8f56-11d0-a3b9-00a0c9223196}";
    constexpr ULONG kIoctlKsProperty = CTL_CODE(FILE_DEVICE_KS, 0x000, METHOD_NEITHER, FILE_ANY_ACCESS);

    extern "C" HRESULT WINAPI KsOpenDefaultDevice(
        _In_ REFGUID Category,
        _In_ ACCESS_MASK Access,
        _Out_ PHANDLE DeviceHandle);

    extern "C" HRESULT WINAPI KsSynchronousDeviceControl(
        _In_ HANDLE Handle,
        _In_ ULONG IoControl,
        _In_reads_bytes_opt_(InLength) PVOID InBuffer,
        _In_ ULONG InLength,
        _Out_writes_bytes_opt_(OutLength) PVOID OutBuffer,
        _In_ ULONG OutLength,
        _Inout_opt_ PULONG BytesReturned);

    struct DriverStatusSnapshot
    {
        ULONG Size = sizeof(DriverStatusSnapshot);
        ULONG Version = 0;
        ULONG HardwareState = 0;
        ULONG ClientConnected = 0;
        ULONG Width = 0;
        ULONG Height = 0;
        ULONG ImageSize = 0;
        ULONG ScatterGatherMappingsQueued = 0;
        ULONG ScatterGatherBytesQueued = 0;
        ULONG NumMappingsCompleted = 0;
        ULONG NumFramesSkipped = 0;
        ULONG InterruptTime = 0;
        ULONG LastFillStatus = 0;
        ULONG LastFillStride = 0;
        ULONG LastFillWidthBytes = 0;
        ULONG LastFillRequiredBytes = 0;
        ULONG LastFillByteCount = 0;
        ULONG LastFillBufferRemaining = 0;
        ULONG LastCompletedDelta = 0;
        ULONG LastSetDataLength = 0;
        ULONG SetDataAcceptedCount = 0;
        ULONG SetDataRejectedCount = 0;
        ULONG LastSetDataReason = 0;
        ULONGLONG CompletedFrameCount = 0;
        ULONGLONG LastFrameTime100ns = 0;
    };

    bool IsWarmupRejectStatus(const DriverStatusSnapshot& status)
    {
        if (status.SetDataAcceptedCount != 0) {
            return false;
        }

        if (status.HardwareState != kDriverHardwareStateRunning) {
            return true;
        }

        return status.LastSetDataReason == kDriverSetDataRejectNotRunning ||
            status.LastSetDataReason == kDriverSetDataRejectNotConnected;
    }

    const char* kVertexShaderSource = R"(
struct VS_OUTPUT { float4 Pos : SV_POSITION; float2 Tex : TEXCOORD; };
VS_OUTPUT main(uint id : SV_VertexID) {
    VS_OUTPUT output;
    output.Tex = float2((id << 1) & 2, id & 2);
    output.Pos = float4(output.Tex.x * 2.0 - 1.0, 1.0 - output.Tex.y * 2.0, 0.0, 1.0);
    return output;
})";

    const char* kPixelShaderSource = R"(
Texture2D inputTexture : register(t0);
SamplerState inputSampler : register(s0);
float4 main(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    return inputTexture.Sample(inputSampler, uv);
})";

    void DumpBgr24FrameAsPpm(
        const wchar_t* path,
        const BYTE* bgrBuffer,
        size_t bufferSize,
        UINT width,
        UINT height)
    {
        if (!path || !bgrBuffer || width == 0 || height == 0) {
            return;
        }

        const size_t requiredSize = static_cast<size_t>(width) * static_cast<size_t>(height) * 3ull;
        if (bufferSize < requiredSize) {
            return;
        }

        FILE* file = nullptr;
        if (_wfopen_s(&file, path, L"wb") != 0 || !file) {
            return;
        }

        std::fprintf(file, "P6\n%u %u\n255\n", width, height);
        for (UINT y = 0; y < height; ++y) {
            const BYTE* row = bgrBuffer + (static_cast<size_t>(y) * width * 3ull);
            for (UINT x = 0; x < width; ++x) {
                const BYTE* pixel = row + (static_cast<size_t>(x) * 3ull);
                std::fputc(pixel[2], file);
                std::fputc(pixel[1], file);
                std::fputc(pixel[0], file);
            }
        }

        std::fclose(file);
    }

    std::wstring GetMonikerStringProperty(IMoniker* moniker, const wchar_t* propertyName)
    {
        if (!moniker || !propertyName || !*propertyName) {
            return {};
        }

        wil::com_ptr_nothrow<IPropertyBag> propertyBag;
        if (FAILED(moniker->BindToStorage(nullptr, nullptr, IID_PPV_ARGS(propertyBag.put()))) || !propertyBag) {
            return {};
        }

        VARIANT value;
        VariantInit(&value);
        std::wstring result;
        if (SUCCEEDED(propertyBag->Read(propertyName, &value, nullptr)) &&
            value.vt == VT_BSTR &&
            value.bstrVal) {
            result = value.bstrVal;
        }
        VariantClear(&value);
        return result;
    }

    bool ContainsInsensitive(std::wstring_view haystack, std::wstring_view needle)
    {
        if (needle.empty() || haystack.size() < needle.size()) {
            return false;
        }

        auto it = std::search(
            haystack.begin(),
            haystack.end(),
            needle.begin(),
            needle.end(),
            [](wchar_t left, wchar_t right) {
                return std::towlower(left) == std::towlower(right);
            });
        return it != haystack.end();
    }

    int ScoreDriverDevicePath(std::wstring_view devicePath)
    {
        if (ContainsInsensitive(devicePath, kVideoCameraCategoryGuid)) {
            return 200;
        }
        if (ContainsInsensitive(devicePath, kCaptureCategoryGuid)) {
            return 100;
        }
        return 0;
    }

    HRESULT OpenDriverCategoryHandle(const GUID& category, const wchar_t* categoryName, wil::unique_hfile& handle)
    {
        HANDLE rawHandle = INVALID_HANDLE_VALUE;
        const HRESULT hr = KsOpenDefaultDevice(category, GENERIC_READ | GENERIC_WRITE, &rawHandle);
        if (FAILED(hr)) {
            return hr;
        }
        if (!rawHandle || rawHandle == INVALID_HANDLE_VALUE) {
            return HRESULT_FROM_WIN32(ERROR_INVALID_HANDLE);
        }

        handle.reset(rawHandle);
        VirtuaCamLog::LogLine(std::format(
            L"[1.1] Opened KS handle for category {}",
            categoryName ? categoryName : L"<unknown>"));
        return S_OK;
    }
}

DriverBridge::DriverBridge()
{
    m_rgbBuffer.resize(kDriverFrameSize);
}
DriverBridge::~DriverBridge()
{
    Shutdown();
}

HRESULT DriverBridge::Initialize()
{
    m_lastError.clear();
    m_connected = false;
    RETURN_IF_FAILED(EnsurePropertySetReady());
    m_active = true;
    VirtuaCamLog::LogLine(L"DriverBridge initialized");
    return S_OK;
}

void DriverBridge::Shutdown()
{
    if (m_connected && (m_driverHandle || m_ksControl || m_propertySet)) {
        const HRESULT hrDisconnect = Disconnect();
        if (FAILED(hrDisconnect) && hrDisconnect != S_FALSE) {
            VirtuaCamLog::LogHr(L"DriverBridge::Disconnect during shutdown failed", hrDisconnect);
        }
    }

    m_active = false;
    m_connected = false;
    m_selectedDevicePath.clear();
    m_selectedFriendlyName.clear();
    m_driverHandle.reset();
    m_sourceSrv.reset();
    m_sourceTexture.reset();
    m_samplerState.reset();
    m_pixelShader.reset();
    m_vertexShader.reset();
    m_stagingTexture.reset();
    m_scaledRtv.reset();
    m_scaledTexture.reset();
    m_context.reset();
    m_device.reset();
    m_ksControl.reset();
    m_propertySet.reset();
    m_filter.reset();
}

bool DriverBridge::IsRecoverableSendFailure(HRESULT hr)
{
    return hr == HRESULT_FROM_WIN32(ERROR_BAD_COMMAND) ||
        hr == HRESULT_FROM_WIN32(ERROR_GEN_FAILURE) ||
        hr == HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED) ||
        hr == HRESULT_FROM_WIN32(ERROR_NOT_READY) ||
        hr == HRESULT_FROM_WIN32(ERROR_INVALID_HANDLE);
}

HRESULT DriverBridge::FindDriverFilter()
{
    wil::com_ptr_nothrow<ICreateDevEnum> devEnum;
    RETURN_IF_FAILED(CoCreateInstance(CLSID_SystemDeviceEnum, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(devEnum.put())));

    wil::com_ptr_nothrow<IEnumMoniker> enumMoniker;
    HRESULT hr = devEnum->CreateClassEnumerator(CLSID_VideoInputDeviceCategory, enumMoniker.put(), 0);
    if (hr == S_FALSE) {
        SetLastError(L"No video capture devices found.");
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }
    RETURN_IF_FAILED(hr);

    wil::com_ptr_nothrow<IBaseFilter> bestFilter;
    wil::com_ptr_nothrow<IKsPropertySet> bestPropertySet;
    wil::com_ptr_nothrow<IKsControl> bestKsControl;
    std::wstring bestDevicePath;
    std::wstring bestFriendlyName;
    DWORD bestSupportFlags = 0;
    int bestScore = -1;

    while (true) {
        wil::com_ptr_nothrow<IMoniker> moniker;
        ULONG fetched = 0;
        if (enumMoniker->Next(1, moniker.put(), &fetched) != S_OK) {
            break;
        }

        wil::com_ptr_nothrow<IBaseFilter> filter;
        if (FAILED(moniker->BindToObject(nullptr, nullptr, IID_PPV_ARGS(filter.put()))) || !filter) {
            continue;
        }

        wil::com_ptr_nothrow<IKsPropertySet> propertySet;
        if (FAILED(filter->QueryInterface(IID_PPV_ARGS(propertySet.put()))) || !propertySet) {
            continue;
        }

        DWORD supportFlags = 0;
        if (FAILED(propertySet->QuerySupported(kDriverPropertySet, kDriverPropertyIdFrame, &supportFlags))) {
            continue;
        }

        if ((supportFlags & KSPROPERTY_SUPPORT_SET) != KSPROPERTY_SUPPORT_SET) {
            continue;
        }

        const std::wstring devicePath = GetMonikerStringProperty(moniker.get(), L"DevicePath");
        const std::wstring friendlyName = GetMonikerStringProperty(moniker.get(), L"FriendlyName");
        const int score = ScoreDriverDevicePath(devicePath);

        VirtuaCamLog::LogLine(std::format(
            L"[1.1] Candidate avshws filter supportFlags=0x{:08X} score={} friendly='{}' devicePath='{}'",
            supportFlags,
            score,
            friendlyName.empty() ? L"<unknown>" : friendlyName,
            devicePath.empty() ? L"<unknown>" : devicePath));

        if (score > bestScore) {
            bestScore = score;
            bestSupportFlags = supportFlags;
            bestFriendlyName = friendlyName;
            bestDevicePath = devicePath;
            bestFilter = filter;
            bestPropertySet = propertySet;
            bestKsControl.reset();
            (void)filter->QueryInterface(IID_PPV_ARGS(bestKsControl.put()));
        }
    }

    if (bestFilter && bestPropertySet) {
        m_filter = bestFilter;
        m_propertySet = bestPropertySet;
        m_ksControl = bestKsControl;
        m_selectedDevicePath = bestDevicePath;
        m_selectedFriendlyName = bestFriendlyName;
        VirtuaCamLog::LogLine(std::format(
            L"[1.1] Selected avshws filter supportFlags=0x{:08X} friendly='{}' devicePath='{}'",
            bestSupportFlags,
            m_selectedFriendlyName.empty() ? L"<unknown>" : m_selectedFriendlyName,
            m_selectedDevicePath.empty() ? L"<unknown>" : m_selectedDevicePath));

        HRESULT handleHr = OpenDriverCategoryHandle(kVideoCameraCategory, L"KSCATEGORY_VIDEO_CAMERA", m_driverHandle);
        if (FAILED(handleHr)) {
            VirtuaCamLog::LogLine(std::format(
                L"[1.1] Failed to open KS handle for KSCATEGORY_VIDEO_CAMERA hr=0x{:08X}; trying KSCATEGORY_CAPTURE",
                static_cast<unsigned>(handleHr)));
            handleHr = OpenDriverCategoryHandle(kCaptureCategory, L"KSCATEGORY_CAPTURE", m_driverHandle);
            if (FAILED(handleHr)) {
                VirtuaCamLog::LogLine(std::format(
                    L"[1.1] Failed to open KS handle for KSCATEGORY_CAPTURE hr=0x{:08X}; falling back to moniker property-set path",
                    static_cast<unsigned>(handleHr)));
            }
        }
        return S_OK;
    }

    VirtuaCamLog::LogLine(L"[1.1] avshws device NOT found in VideoInputDeviceCategory");
    SetLastError(L"Virtual Camera Driver device not found. Install driver-project camera first.");
    return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

HRESULT DriverBridge::CreateShaders()
{
    wil::com_ptr_nothrow<ID3DBlob> vsBlob;
    wil::com_ptr_nothrow<ID3DBlob> psBlob;
    RETURN_IF_FAILED(D3DCompile(kVertexShaderSource, strlen(kVertexShaderSource), nullptr, nullptr, nullptr, "main", "vs_5_0", 0, 0, &vsBlob, nullptr));
    RETURN_IF_FAILED(D3DCompile(kPixelShaderSource, strlen(kPixelShaderSource), nullptr, nullptr, nullptr, "main", "ps_5_0", 0, 0, &psBlob, nullptr));
    RETURN_IF_FAILED(m_device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &m_vertexShader));
    RETURN_IF_FAILED(m_device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &m_pixelShader));

    D3D11_SAMPLER_DESC samplerDesc = {};
    samplerDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    samplerDesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.MinLOD = 0;
    samplerDesc.MaxLOD = D3D11_FLOAT32_MAX;
    RETURN_IF_FAILED(m_device->CreateSamplerState(&samplerDesc, &m_samplerState));
    return S_OK;
}

HRESULT DriverBridge::EnsureGpuResources(ID3D11Texture2D* sourceTexture)
{
    RETURN_HR_IF_NULL(E_POINTER, sourceTexture);

    if (!m_device) {
        sourceTexture->GetDevice(m_device.put());
        RETURN_HR_IF_NULL(E_FAIL, m_device.get());
        m_device->GetImmediateContext(m_context.put());
        RETURN_IF_FAILED(CreateShaders());
    }

    if (!m_scaledTexture || !m_stagingTexture) {
        D3D11_TEXTURE2D_DESC scaledDesc = {};
        scaledDesc.Width = kDriverWidth;
        scaledDesc.Height = kDriverHeight;
        scaledDesc.MipLevels = 1;
        scaledDesc.ArraySize = 1;
        scaledDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        scaledDesc.SampleDesc.Count = 1;
        scaledDesc.Usage = D3D11_USAGE_DEFAULT;
        scaledDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        RETURN_IF_FAILED(m_device->CreateTexture2D(&scaledDesc, nullptr, m_scaledTexture.put()));
        RETURN_IF_FAILED(m_device->CreateRenderTargetView(m_scaledTexture.get(), nullptr, m_scaledRtv.put()));

        D3D11_TEXTURE2D_DESC stagingDesc = scaledDesc;
        stagingDesc.Usage = D3D11_USAGE_STAGING;
        stagingDesc.BindFlags = 0;
        stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        RETURN_IF_FAILED(m_device->CreateTexture2D(&stagingDesc, nullptr, m_stagingTexture.put()));
    }

    return S_OK;
}

HRESULT DriverBridge::EnsureSourceTextureView(ID3D11Texture2D* sourceTexture)
{
    RETURN_HR_IF_NULL(E_POINTER, sourceTexture);

    if (m_sourceTexture.get() == sourceTexture && m_sourceSrv) {
        return S_OK;
    }

    m_sourceSrv.reset();
    m_sourceTexture = sourceTexture;
    RETURN_IF_FAILED(m_device->CreateShaderResourceView(sourceTexture, nullptr, m_sourceSrv.put()));
    return S_OK;
}

HRESULT DriverBridge::UploadMappedFrame(const D3D11_MAPPED_SUBRESOURCE& mapped)
{
    static volatile LONG s_driverFrameCount = 0;
    LONG n = _InterlockedIncrement(&s_driverFrameCount);
    if (n % 30 == 0) {
        VirtuaCamLog::LogLine(std::format(L"[1.2] SendFrame #{} calling IKsPropertySet::Set()", n));
    }

    for (UINT y = 0; y < kDriverHeight; ++y) {
        const BYTE* src = static_cast<const BYTE*>(mapped.pData) + (mapped.RowPitch * y);
        BYTE* dst = m_rgbBuffer.data() + (kDriverWidth * kDriverBytesPerPixel * y);

        for (UINT x = 0; x < kDriverWidth; ++x) {
            const BYTE* srcPixel = src + (x * 4);
            BYTE* dstPixel = dst + (x * 3);

            // Broker texture is BGRA8. Driver sink expects packed BGR24.
            // Copy B,G,R bytes directly; no extra channel swap needed.
            dstPixel[0] = srcPixel[0];
            dstPixel[1] = srcPixel[1];
            dstPixel[2] = srcPixel[2];
        }
    }

    if (n == 1 && !m_rgbBuffer.empty()) {
        const BYTE* topLeft = m_rgbBuffer.data();
        const size_t centerOffset =
            ((static_cast<size_t>(kDriverHeight / 2) * kDriverWidth) + (kDriverWidth / 2)) * kDriverBytesPerPixel;
        const BYTE* center = (centerOffset + 2 < m_rgbBuffer.size()) ? (m_rgbBuffer.data() + centerOffset) : topLeft;
        CreateDirectoryW(L"logs", nullptr);
        DumpBgr24FrameAsPpm(
            L"logs\\driverbridge-first-frame.ppm",
            m_rgbBuffer.data(),
            m_rgbBuffer.size(),
            kDriverWidth,
            kDriverHeight);
        VirtuaCamLog::LogLine(std::format(
            L"DriverBridge first frame: rowPitch={} bytes={} topLeftBgr={},{},{} centerBgr={},{},{}",
            mapped.RowPitch,
            m_rgbBuffer.size(),
            static_cast<unsigned>(topLeft[0]),
            static_cast<unsigned>(topLeft[1]),
            static_cast<unsigned>(topLeft[2]),
            static_cast<unsigned>(center[0]),
            static_cast<unsigned>(center[1]),
            static_cast<unsigned>(center[2])));
    }

    RETURN_IF_FAILED(EnsurePropertySetReady());
    RETURN_HR_IF(E_UNEXPECTED, m_rgbBuffer.size() != kDriverFrameSize);

    HRESULT hr = SetDriverProperty(kDriverPropertyIdFrame, m_rgbBuffer.data(), static_cast<ULONG>(m_rgbBuffer.size()));
    if (FAILED(hr)) {
        DriverStatusSnapshot status = {};
        DWORD returned = 0;
        if (SUCCEEDED(GetDriverProperty(
                kDriverPropertyIdStatus,
                &status,
                static_cast<DWORD>(sizeof(status)),
                &returned)) &&
            returned >= sizeof(ULONG) * 4) {
            if (status.LastSetDataReason == kDriverSetDataRejectNotConnected) {
                m_connected = false;
            }
            if (IsWarmupRejectStatus(status)) {
                if (n <= 5 || n % 30 == 0) {
                    VirtuaCamLog::LogLine(std::format(
                        L"Driver warm-up reject: frame={} hw={} client={} setOk={} setReject={} reason={}",
                        n,
                        status.HardwareState,
                        status.ClientConnected,
                        status.SetDataAcceptedCount,
                        status.SetDataRejectedCount,
                        status.LastSetDataReason));
                }
                return HRESULT_FROM_WIN32(ERROR_RETRY);
            }
        }
        SetLastError(std::format(L"Driver property set failed: 0x{:08X}", static_cast<unsigned>(hr)));
        LogDriverStatusSnapshot(L"Driver status after send failure", n);
    } else if (n <= 3 || n % 60 == 0) {
        LogDriverStatusSnapshot(L"Driver status", n);
    }
    return hr;
}

void DriverBridge::LogDriverStatusSnapshot(const wchar_t* prefix, long frameSequence)
{
    if (!m_driverHandle && !m_ksControl && !m_propertySet) {
        return;
    }

    DWORD supportFlags = 0;
    const bool supportKnown = IsPropertySetSupported(kDriverPropertyIdStatus, &supportFlags);

    DriverStatusSnapshot status = {};
    DWORD returned = 0;
    const HRESULT hr = GetDriverProperty(
        kDriverPropertyIdStatus,
        &status,
        static_cast<DWORD>(sizeof(status)),
        &returned);

    if (FAILED(hr)) {
        VirtuaCamLog::LogLine(std::format(
            L"{} frame={} query failed hr=0x{:08X} supportKnown={} supportFlags=0x{:08X}",
            prefix ? prefix : L"Driver status",
            frameSequence,
            static_cast<unsigned>(hr),
            supportKnown ? 1 : 0,
            supportFlags));
        return;
    }

    VirtuaCamLog::LogLine(std::format(
        L"{} frame={} hw={} client={} queuedMappings={} queuedBytes={} completed={} completedFrames={} skipped={} lastFill=0x{:08X} stride={} widthBytes={} required={} byteCount={} remaining={} lastSetLen={} setOk={} setReject={} rejectReason={} returned={}",
        prefix ? prefix : L"Driver status",
        frameSequence,
        status.HardwareState,
        status.ClientConnected,
        status.ScatterGatherMappingsQueued,
        status.ScatterGatherBytesQueued,
        status.NumMappingsCompleted,
        status.CompletedFrameCount,
        status.NumFramesSkipped,
        status.LastFillStatus,
        status.LastFillStride,
        status.LastFillWidthBytes,
        status.LastFillRequiredBytes,
        status.LastFillByteCount,
        status.LastFillBufferRemaining,
        status.LastSetDataLength,
        status.SetDataAcceptedCount,
        status.SetDataRejectedCount,
        status.LastSetDataReason,
        returned));
}

HRESULT DriverBridge::EnsurePropertySetReady()
{
    if (m_driverHandle || m_propertySet) {
        return S_OK;
    }
    return FindDriverFilter();
}

HRESULT DriverBridge::SetDriverProperty(ULONG propertyId, void* data, ULONG dataLength, ULONG* bytesReturned)
{
    RETURN_IF_FAILED(EnsurePropertySetReady());

    HRESULT lastHr = E_NOINTERFACE;
    bool attempted = false;

    if (m_driverHandle) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_SET;
        ULONG localBytesReturned = 0;
        const HRESULT hr = KsSynchronousDeviceControl(
            m_driverHandle.get(),
            kIoctlKsProperty,
            &property,
            static_cast<ULONG>(sizeof(property)),
            data,
            dataLength,
            bytesReturned ? bytesReturned : &localBytesReturned);
        if (SUCCEEDED(hr)) {
            return hr;
        }
        lastHr = hr;
        attempted = true;
    }

    if (m_ksControl) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_SET;
        ULONG localBytesReturned = 0;
        const HRESULT hr = m_ksControl->KsProperty(
            &property,
            static_cast<ULONG>(sizeof(property)),
            data,
            dataLength,
            bytesReturned ? bytesReturned : &localBytesReturned);
        if (SUCCEEDED(hr)) {
            return hr;
        }
        if (!attempted) {
            lastHr = hr;
            attempted = true;
        }
    }

    if (m_propertySet) {
        const HRESULT hr = m_propertySet->Set(kDriverPropertySet, propertyId, nullptr, 0, data, dataLength);
        if (SUCCEEDED(hr)) {
            return hr;
        }
        if (!attempted) {
            lastHr = hr;
            attempted = true;
        }
    }

    return attempted ? lastHr : E_NOINTERFACE;
}

HRESULT DriverBridge::GetDriverProperty(ULONG propertyId, void* data, ULONG dataLength, ULONG* bytesReturned)
{
    RETURN_IF_FAILED(EnsurePropertySetReady());

    HRESULT lastHr = E_NOINTERFACE;
    bool attempted = false;

    if (m_driverHandle) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_GET;
        ULONG localBytesReturned = 0;
        const HRESULT hr = KsSynchronousDeviceControl(
            m_driverHandle.get(),
            kIoctlKsProperty,
            &property,
            static_cast<ULONG>(sizeof(property)),
            data,
            dataLength,
            bytesReturned ? bytesReturned : &localBytesReturned);
        if (SUCCEEDED(hr)) {
            return hr;
        }
        lastHr = hr;
        attempted = true;
    }

    if (m_ksControl) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_GET;
        ULONG localBytesReturned = 0;
        const HRESULT hr = m_ksControl->KsProperty(
            &property,
            static_cast<ULONG>(sizeof(property)),
            data,
            dataLength,
            bytesReturned ? bytesReturned : &localBytesReturned);
        if (SUCCEEDED(hr)) {
            return hr;
        }
        if (!attempted) {
            lastHr = hr;
            attempted = true;
        }
    }

    if (m_propertySet) {
        const HRESULT hr = m_propertySet->Get(kDriverPropertySet, propertyId, nullptr, 0, data, dataLength, bytesReturned);
        if (SUCCEEDED(hr)) {
            return hr;
        }
        if (!attempted) {
            lastHr = hr;
            attempted = true;
        }
    }

    return attempted ? lastHr : E_NOINTERFACE;
}

bool DriverBridge::IsPropertySetSupported(ULONG propertyId, DWORD* supportFlags)
{
    if (supportFlags) {
        *supportFlags = 0;
    }

    bool supportKnown = false;
    DWORD combinedFlags = 0;

    if (m_driverHandle) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_SETSUPPORT;

        DWORD flags = 0;
        ULONG returned = 0;
        if (SUCCEEDED(KsSynchronousDeviceControl(
                m_driverHandle.get(),
                kIoctlKsProperty,
                &property,
                static_cast<ULONG>(sizeof(property)),
                &flags,
                static_cast<ULONG>(sizeof(flags)),
                &returned)) &&
            returned >= sizeof(flags)) {
            combinedFlags |= flags;
            supportKnown = true;
        }
    }

    if (m_ksControl) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_SETSUPPORT;

        DWORD flags = 0;
        ULONG returned = 0;
        if (SUCCEEDED(m_ksControl->KsProperty(
                &property,
                static_cast<ULONG>(sizeof(property)),
                &flags,
                static_cast<ULONG>(sizeof(flags)),
                &returned)) &&
            returned >= sizeof(flags)) {
            combinedFlags |= flags;
            supportKnown = true;
        }
    }

    if (m_propertySet) {
        DWORD flags = 0;
        if (SUCCEEDED(m_propertySet->QuerySupported(kDriverPropertySet, propertyId, &flags))) {
            combinedFlags |= flags;
            supportKnown = true;
        }
    }

    if (supportFlags) {
        *supportFlags = combinedFlags;
    }
    return supportKnown;
}

HRESULT DriverBridge::Connect()
{
    if (m_connected) {
        return S_OK;
    }

    RETURN_IF_FAILED(EnsurePropertySetReady());
    HRESULT hr = SetDriverProperty(kDriverPropertyIdConnect, nullptr, 0);
    if (FAILED(hr)) {
        DWORD supportFlags = 0;
        const bool supportKnown = IsPropertySetSupported(kDriverPropertyIdConnect, &supportFlags);
        VirtuaCamLog::LogLine(std::format(
            L"DriverBridge::Connect property {} failed hr=0x{:08X} supportKnown={} supportFlags=0x{:08X}",
            kDriverPropertyIdConnect,
            static_cast<unsigned>(hr),
            supportKnown ? 1 : 0,
            supportFlags));
        SetLastError(std::format(L"Driver connect failed: 0x{:08X}", static_cast<unsigned>(hr)));
    } else {
        m_connected = true;
    }
    return hr;
}

HRESULT DriverBridge::RegisterClientRequestEvent(HANDLE eventHandle)
{
    RETURN_IF_FAILED(EnsurePropertySetReady());

    DWORD supportFlags = 0;
    const bool supportKnown = IsPropertySetSupported(kDriverPropertyIdRegisterEvent, &supportFlags);
    HRESULT hr = SetDriverProperty(kDriverPropertyIdRegisterEvent, &eventHandle, sizeof(eventHandle), nullptr);
    if (FAILED(hr)) {
        VirtuaCamLog::LogLine(std::format(
            L"DriverBridge::RegisterClientRequestEvent property {} failed hr=0x{:08X} supportKnown={} supportFlags=0x{:08X} handle=0x{:X}",
            kDriverPropertyIdRegisterEvent,
            static_cast<unsigned>(hr),
            supportKnown ? 1 : 0,
            supportFlags,
            static_cast<unsigned long long>(reinterpret_cast<UINT_PTR>(eventHandle))));
        return hr;
    }

    VirtuaCamLog::LogLine(std::format(
        L"DriverBridge::RegisterClientRequestEvent succeeded handle=0x{:X}",
        static_cast<unsigned long long>(reinterpret_cast<UINT_PTR>(eventHandle))));
    return hr;
}

HRESULT DriverBridge::Disconnect()
{
    if (!m_connected) {
        return S_FALSE;
    }

    RETURN_IF_FAILED(EnsurePropertySetReady());
    HRESULT hr = SetDriverProperty(kDriverPropertyIdDisconnect, nullptr, 0);
    if (FAILED(hr)) {
        DWORD supportFlags = 0;
        const bool supportKnown = IsPropertySetSupported(kDriverPropertyIdDisconnect, &supportFlags);
        VirtuaCamLog::LogLine(std::format(
            L"DriverBridge::Disconnect property {} failed hr=0x{:08X} supportKnown={} supportFlags=0x{:08X}",
            kDriverPropertyIdDisconnect,
            static_cast<unsigned>(hr),
            supportKnown ? 1 : 0,
            supportFlags));
        SetLastError(std::format(L"Driver disconnect failed: 0x{:08X}", static_cast<unsigned>(hr)));
    } else {
        m_connected = false;
    }
    return hr;
}

HRESULT DriverBridge::ReinitializeAfterFailure(HRESULT failureHr)
{
    VirtuaCamLog::LogLine(std::format(
        L"DriverBridge recoverable send failure HRESULT=0x{:08X}; reinitializing",
        static_cast<unsigned>(failureHr)));

    if (m_connected && (m_driverHandle || m_ksControl || m_propertySet)) {
        const HRESULT hrDisconnect = Disconnect();
        if (FAILED(hrDisconnect) && hrDisconnect != S_FALSE) {
            VirtuaCamLog::LogHr(L"DriverBridge::Disconnect before reinitialize failed", hrDisconnect);
        }
    }

    Shutdown();
    HRESULT hr = Initialize();
    if (FAILED(hr)) {
        VirtuaCamLog::LogHr(L"DriverBridge reinitialize failed", hr);
    }
    return hr;
}

HRESULT DriverBridge::SendFrame(ID3D11Texture2D* sourceTexture)
{
    RETURN_HR_IF(E_UNEXPECTED, !m_active);
    RETURN_IF_FAILED(Connect());
    RETURN_IF_FAILED(EnsureGpuResources(sourceTexture));
    RETURN_IF_FAILED(EnsureSourceTextureView(sourceTexture));

    D3D11_VIEWPORT viewport = { 0.f, 0.f, static_cast<float>(kDriverWidth), static_cast<float>(kDriverHeight), 0.f, 1.f };
    ID3D11RenderTargetView* rtvs[] = { m_scaledRtv.get() };

    m_context->OMSetRenderTargets(1, rtvs, nullptr);
    m_context->RSSetViewports(1, &viewport);
    m_context->VSSetShader(m_vertexShader.get(), nullptr, 0);
    m_context->PSSetShader(m_pixelShader.get(), nullptr, 0);
    ID3D11SamplerState* samplers[] = { m_samplerState.get() };
    m_context->PSSetSamplers(0, 1, samplers);
    ID3D11ShaderResourceView* srvs[] = { m_sourceSrv.get() };
    m_context->PSSetShaderResources(0, 1, srvs);
    m_context->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    m_context->Draw(3, 0);

    ID3D11ShaderResourceView* nullSrv[] = { nullptr };
    m_context->PSSetShaderResources(0, 1, nullSrv);

    m_context->CopyResource(m_stagingTexture.get(), m_scaledTexture.get());

    D3D11_MAPPED_SUBRESOURCE mapped = {};
    RETURN_IF_FAILED(m_context->Map(m_stagingTexture.get(), 0, D3D11_MAP_READ, 0, &mapped));
    HRESULT hr = UploadMappedFrame(mapped);
    m_context->Unmap(m_stagingTexture.get(), 0);

    if (FAILED(hr) && IsRecoverableSendFailure(hr)) {
        HRESULT hrReinit = ReinitializeAfterFailure(hr);
        if (SUCCEEDED(hrReinit)) {
            return HRESULT_FROM_WIN32(ERROR_RETRY);
        }
        return hrReinit;
    }

    return hr;
}
