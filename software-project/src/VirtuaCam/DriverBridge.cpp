#include "DriverBridge.h"

#include <dshow.h>
#include <dvdmedia.h>
#include <d3dcompiler.h>
#include <cstdio>
#include "RuntimeLog.h"

#pragma comment(lib, "d3dcompiler.lib")

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
    RETURN_IF_FAILED(EnsurePropertySetReady());
    m_active = true;
    VirtuaCamLog::LogLine(L"DriverBridge initialized");
    return S_OK;
}

void DriverBridge::Shutdown()
{
    m_active = false;
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

        VirtuaCamLog::LogLine(std::format(L"[1.1] Found avshws filter supporting kDriverPropertySet, supportFlags=0x{:08X}", supportFlags));

        m_filter = filter;
        (void)filter->QueryInterface(IID_PPV_ARGS(m_ksControl.put()));
        m_propertySet = propertySet;
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
        SetLastError(std::format(L"Driver property set failed: 0x{:08X}", static_cast<unsigned>(hr)));
        LogDriverStatusSnapshot(L"Driver status after send failure", n);
    } else if (n <= 3 || n % 60 == 0) {
        LogDriverStatusSnapshot(L"Driver status", n);
    }
    return hr;
}

void DriverBridge::LogDriverStatusSnapshot(const wchar_t* prefix, long frameSequence)
{
    if (!m_propertySet) {
        return;
    }

    DWORD supportFlags = 0;
    if (FAILED(m_propertySet->QuerySupported(kDriverPropertySet, kDriverPropertyIdStatus, &supportFlags)) ||
        (supportFlags & KSPROPERTY_SUPPORT_GET) != KSPROPERTY_SUPPORT_GET) {
        return;
    }

    DriverStatusSnapshot status = {};
    DWORD returned = 0;
    const HRESULT hr = GetDriverProperty(
        kDriverPropertyIdStatus,
        &status,
        static_cast<DWORD>(sizeof(status)),
        &returned);

    if (FAILED(hr)) {
        VirtuaCamLog::LogLine(std::format(
            L"{} frame={} query failed hr=0x{:08X}",
            prefix ? prefix : L"Driver status",
            frameSequence,
            static_cast<unsigned>(hr)));
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
    if (m_propertySet) {
        return S_OK;
    }
    return FindDriverFilter();
}

HRESULT DriverBridge::SetDriverProperty(ULONG propertyId, void* data, ULONG dataLength, ULONG* bytesReturned)
{
    RETURN_IF_FAILED(EnsurePropertySetReady());

    if (m_ksControl) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_SET;
        ULONG localBytesReturned = 0;
        return m_ksControl->KsProperty(
            &property,
            static_cast<ULONG>(sizeof(property)),
            data,
            dataLength,
            bytesReturned ? bytesReturned : &localBytesReturned);
    }

    return m_propertySet->Set(kDriverPropertySet, propertyId, nullptr, 0, data, dataLength);
}

HRESULT DriverBridge::GetDriverProperty(ULONG propertyId, void* data, ULONG dataLength, ULONG* bytesReturned)
{
    RETURN_IF_FAILED(EnsurePropertySetReady());

    if (m_ksControl) {
        KSPROPERTY property = {};
        property.Set = kDriverPropertySet;
        property.Id = propertyId;
        property.Flags = KSPROPERTY_TYPE_GET;
        ULONG localBytesReturned = 0;
        return m_ksControl->KsProperty(
            &property,
            static_cast<ULONG>(sizeof(property)),
            data,
            dataLength,
            bytesReturned ? bytesReturned : &localBytesReturned);
    }

    return m_propertySet->Get(kDriverPropertySet, propertyId, nullptr, 0, data, dataLength, bytesReturned);
}

bool DriverBridge::IsPropertySetSupported(ULONG propertyId, DWORD* supportFlags)
{
    if (supportFlags) {
        *supportFlags = 0;
    }

    if (!m_propertySet) {
        return false;
    }

    DWORD flags = 0;
    if (FAILED(m_propertySet->QuerySupported(kDriverPropertySet, propertyId, &flags))) {
        return false;
    }
    if (supportFlags) {
        *supportFlags = flags;
    }
    return (flags & KSPROPERTY_SUPPORT_SET) == KSPROPERTY_SUPPORT_SET;
}

HRESULT DriverBridge::Connect()
{
    DWORD supportFlags = 0;
    if (!IsPropertySetSupported(kDriverPropertyIdConnect, &supportFlags)) {
        VirtuaCamLog::LogLine(std::format(
            L"DriverBridge::Connect unsupported by driver (property {} support=0x{:08X}); continuing",
            kDriverPropertyIdConnect,
            supportFlags));
        return S_FALSE;
    }

    HRESULT hr = SetDriverProperty(kDriverPropertyIdConnect, nullptr, 0);
    if (FAILED(hr)) {
        SetLastError(std::format(L"Driver connect failed: 0x{:08X}", static_cast<unsigned>(hr)));
    }
    return hr;
}

HRESULT DriverBridge::Disconnect()
{
    DWORD supportFlags = 0;
    if (!IsPropertySetSupported(kDriverPropertyIdDisconnect, &supportFlags)) {
        VirtuaCamLog::LogLine(std::format(
            L"DriverBridge::Disconnect unsupported by driver (property {} support=0x{:08X}); continuing",
            kDriverPropertyIdDisconnect,
            supportFlags));
        return S_FALSE;
    }

    HRESULT hr = SetDriverProperty(kDriverPropertyIdDisconnect, nullptr, 0);
    if (FAILED(hr)) {
        SetLastError(std::format(L"Driver disconnect failed: 0x{:08X}", static_cast<unsigned>(hr)));
    }
    return hr;
}

HRESULT DriverBridge::ReinitializeAfterFailure(HRESULT failureHr)
{
    VirtuaCamLog::LogLine(std::format(
        L"DriverBridge recoverable send failure HRESULT=0x{:08X}; reinitializing",
        static_cast<unsigned>(failureHr)));

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
