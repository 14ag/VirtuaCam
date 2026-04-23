#include "DriverBridge.h"

#include <dshow.h>
#include <dvdmedia.h>
#include <d3dcompiler.h>
#include "RuntimeLog.h"

#pragma comment(lib, "d3dcompiler.lib")

namespace
{
    constexpr UINT kDriverWidth = 1280;
    constexpr UINT kDriverHeight = 720;
    constexpr UINT kDriverBytesPerPixel = 3;
    constexpr UINT kDriverFrameSize = kDriverWidth * kDriverHeight * kDriverBytesPerPixel;

    const GUID kDriverPropertySet = { 0xcb043957, 0x7b35, 0x456e, { 0x9b, 0x61, 0x55, 0x13, 0x93, 0x0f, 0x4d, 0x8e } };
    constexpr ULONG kDriverPropertyId = 0;

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
}

DriverBridge::DriverBridge() = default;
DriverBridge::~DriverBridge()
{
    Shutdown();
}

HRESULT DriverBridge::Initialize()
{
    m_lastError.clear();
    RETURN_IF_FAILED(FindDriverFilter());
    m_rgbBuffer.resize(kDriverFrameSize);
    m_active = true;
    return S_OK;
}

void DriverBridge::Shutdown()
{
    m_active = false;
    m_samplerState.reset();
    m_pixelShader.reset();
    m_vertexShader.reset();
    m_stagingTexture.reset();
    m_scaledRtv.reset();
    m_scaledTexture.reset();
    m_context.reset();
    m_device.reset();
    m_propertySet.reset();
    m_filter.reset();
    m_rgbBuffer.clear();
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
        if (FAILED(propertySet->QuerySupported(kDriverPropertySet, kDriverPropertyId, &supportFlags))) {
            continue;
        }

        if ((supportFlags & KSPROPERTY_SUPPORT_SET) != KSPROPERTY_SUPPORT_SET) {
            continue;
        }

        VirtuaCamLog::LogLine(std::format(L"[1.1] Found avshws filter supporting kDriverPropertySet, supportFlags=0x{:08X}", supportFlags));

        m_filter = filter;
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

            dstPixel[0] = srcPixel[0];
            dstPixel[1] = srcPixel[1];
            dstPixel[2] = srcPixel[2];
        }
    }

    RETURN_HR_IF_NULL(E_POINTER, m_propertySet.get());
    RETURN_HR_IF(E_UNEXPECTED, m_rgbBuffer.size() != kDriverFrameSize);

    HRESULT hr = m_propertySet->Set(kDriverPropertySet, kDriverPropertyId, nullptr, 0, m_rgbBuffer.data(), static_cast<ULONG>(m_rgbBuffer.size()));
    if (FAILED(hr)) {
        SetLastError(std::format(L"Driver property set failed: 0x{:08X}", static_cast<unsigned>(hr)));
    }
    return hr;
}

HRESULT DriverBridge::SendFrame(ID3D11Texture2D* sourceTexture)
{
    RETURN_HR_IF(E_UNEXPECTED, !m_active);
    RETURN_IF_FAILED(EnsureGpuResources(sourceTexture));

    wil::com_ptr_nothrow<ID3D11ShaderResourceView> sourceSrv;
    RETURN_IF_FAILED(m_device->CreateShaderResourceView(sourceTexture, nullptr, sourceSrv.put()));

    const float clearColor[] = { 0.f, 0.f, 0.f, 1.f };
    D3D11_VIEWPORT viewport = { 0.f, 0.f, static_cast<float>(kDriverWidth), static_cast<float>(kDriverHeight), 0.f, 1.f };
    ID3D11RenderTargetView* rtvs[] = { m_scaledRtv.get() };

    m_context->OMSetRenderTargets(1, rtvs, nullptr);
    m_context->ClearRenderTargetView(m_scaledRtv.get(), clearColor);
    m_context->RSSetViewports(1, &viewport);
    m_context->VSSetShader(m_vertexShader.get(), nullptr, 0);
    m_context->PSSetShader(m_pixelShader.get(), nullptr, 0);
    ID3D11SamplerState* samplers[] = { m_samplerState.get() };
    m_context->PSSetSamplers(0, 1, samplers);
    ID3D11ShaderResourceView* srvs[] = { sourceSrv.get() };
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
    return hr;
}
