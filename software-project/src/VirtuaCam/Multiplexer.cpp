#include "pch.h"
#include "Multiplexer.h"
#include "RuntimeLog.h"
#include <d3dcompiler.h>
#include <cmath>
#include <algorithm>

#pragma comment(lib, "d3dcompiler.lib")

const char* g_BlitVertexShader = R"(
struct VS_OUTPUT { float4 Pos : SV_POSITION; float2 Tex : TEXCOORD; };
VS_OUTPUT main(uint id : SV_VertexID) {
    VS_OUTPUT output;
    output.Tex = float2((id << 1) & 2, id & 2);
    output.Pos = float4(output.Tex.x * 2.0 - 1.0, 1.0 - output.Tex.y * 2.0, 0, 1);
    return output;
})";

const char* g_BlitPixelShader = R"(
Texture2D    g_texture : register(t0);
SamplerState g_sampler : register(s0);
float4 main(float4 pos : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET {
    return g_texture.Sample(g_sampler, uv);
})";

Multiplexer::Multiplexer() {}
Multiplexer::~Multiplexer() {}

HRESULT Multiplexer::Initialize(Microsoft::WRL::ComPtr<ID3D11Device> device)
{
    m_device = device;
    m_device->GetImmediateContext(&m_context);
    m_context.As(&m_context4);
    RETURN_IF_FAILED(CreateResources());
    RETURN_IF_FAILED(m_offModeShader.Initialize(m_device));
    return S_OK;
}

void Multiplexer::Shutdown()
{
    m_offModeShader.Shutdown();
    m_device.Reset();
    m_context.Reset();
    m_context4.Reset();
    m_compositeTexture.Reset();
    m_compositeRTV.Reset();
    m_outputTexture.Reset();
    m_outputFence.Reset();
    m_blitVS.Reset();
    m_blitPS.Reset();
    m_blitSampler.Reset();
    m_producerResources.clear();
}

ID3D11Texture2D* Multiplexer::GetOutputTexture()
{
    return m_outputTexture.Get();
}

ID3D11Fence* Multiplexer::GetOutputFence()
{
    return m_outputFence.Get();
}

UINT64 Multiplexer::GetOutputFrameValue()
{
    return m_outputFrameValue;
}

HRESULT Multiplexer::CreateResources()
{
    D3D11_TEXTURE2D_DESC compositeDesc = {};
    compositeDesc.Width = 1920;
    compositeDesc.Height = 1080;
    compositeDesc.MipLevels = 1;
    compositeDesc.ArraySize = 1;
    compositeDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    compositeDesc.SampleDesc.Count = 1;
    compositeDesc.Usage = D3D11_USAGE_DEFAULT;
    compositeDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    RETURN_IF_FAILED(m_device->CreateTexture2D(&compositeDesc, nullptr, &m_compositeTexture));
    RETURN_IF_FAILED(m_device->CreateRenderTargetView(m_compositeTexture.Get(), nullptr, &m_compositeRTV));

    D3D11_TEXTURE2D_DESC outputDesc = compositeDesc;
    outputDesc.MiscFlags = 0;
    RETURN_IF_FAILED(m_device->CreateTexture2D(&outputDesc, nullptr, &m_outputTexture));
    
    Microsoft::WRL::ComPtr<ID3D11Device5> device5;
    m_device.As(&device5);
    RETURN_IF_FAILED(device5->CreateFence(0, D3D11_FENCE_FLAG_NONE, IID_PPV_ARGS(&m_outputFence)));

    Microsoft::WRL::ComPtr<ID3DBlob> vsBlob, psBlob;
    RETURN_IF_FAILED(D3DCompile(g_BlitVertexShader, strlen(g_BlitVertexShader), nullptr, nullptr, nullptr, "main", "vs_5_0", 0, 0, &vsBlob, nullptr));
    RETURN_IF_FAILED(D3DCompile(g_BlitPixelShader, strlen(g_BlitPixelShader), nullptr, nullptr, nullptr, "main", "ps_5_0", 0, 0, &psBlob, nullptr));

    RETURN_IF_FAILED(m_device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &m_blitVS));
    RETURN_IF_FAILED(m_device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &m_blitPS));
    
    D3D11_SAMPLER_DESC sampDesc = {};
    sampDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sampDesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampDesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampDesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampDesc.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sampDesc.MinLOD = 0;
    sampDesc.MaxLOD = D3D11_FLOAT32_MAX;
    RETURN_IF_FAILED(m_device->CreateSamplerState(&sampDesc, &m_blitSampler));

    return S_OK;
}

void Multiplexer::PruneConnections(const std::vector<VirtuaCam::DiscoveredSharedStream>& currentProducers)
{
    m_producerResources.erase(std::remove_if(m_producerResources.begin(), m_producerResources.end(),
        [&](const ProducerGpuResources& res) {
            auto it = std::find_if(currentProducers.begin(), currentProducers.end(), 
                [&](const auto& p){ return p.processId == res.pid; });
            return it == currentProducers.end();
        }), m_producerResources.end());
}

HRESULT Multiplexer::UpdateProducerConnection(const VirtuaCam::DiscoveredSharedStream& streamInfo)
{
    for(auto& res : m_producerResources)
    {
        if(res.pid == streamInfo.processId)
        {
            return S_OK; 
        }
    }

    ProducerGpuResources newRes;
    newRes.pid = streamInfo.processId;

    Microsoft::WRL::ComPtr<ID3D11Device1> device1;
    m_device.As(&device1);
    Microsoft::WRL::ComPtr<ID3D11Device5> device5;
    m_device.As(&device5);

    const HRESULT hrTexture = device1->OpenSharedResourceByName(
        streamInfo.textureName.c_str(),
        DXGI_SHARED_RESOURCE_READ,
        __uuidof(ID3D11Texture2D),
        reinterpret_cast<void**>(newRes.sharedTexture.GetAddressOf()));
    if (FAILED(hrTexture) || !newRes.sharedTexture) {
        VirtuaCamLog::LogLine(std::format(
            L"UpdateProducerConnection failed to open shared texture: pid={} name='{}' hr=0x{:08X}",
            streamInfo.processId,
            streamInfo.textureName,
            static_cast<unsigned>(hrTexture)));
        return FAILED(hrTexture) ? hrTexture : E_FAIL;
    }

    if (streamInfo.sharedFenceHandleValue == 0) {
        VirtuaCamLog::LogLine(std::format(
            L"UpdateProducerConnection missing duplicated shared fence handle: pid={} name='{}'",
            streamInfo.processId,
            streamInfo.fenceName));
        return E_FAIL;
    }

    newRes.importedFenceHandle.reset(reinterpret_cast<HANDLE>(static_cast<UINT_PTR>(streamInfo.sharedFenceHandleValue)));
    const HRESULT hrFence = device5->OpenSharedFence(newRes.importedFenceHandle.get(), IID_PPV_ARGS(&newRes.sharedFence));
    if (FAILED(hrFence) || !newRes.sharedFence) {
        VirtuaCamLog::LogLine(std::format(
            L"UpdateProducerConnection failed to open shared fence: pid={} name='{}' handle=0x{:X} hr=0x{:08X}",
            streamInfo.processId,
            streamInfo.fenceName,
            static_cast<unsigned long long>(streamInfo.sharedFenceHandleValue),
            static_cast<unsigned>(hrFence)));
        return FAILED(hrFence) ? hrFence : E_FAIL;
    }
    
    D3D11_TEXTURE2D_DESC sharedDesc;
    newRes.sharedTexture->GetDesc(&sharedDesc);
    sharedDesc.MiscFlags = 0;
    sharedDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    sharedDesc.Usage = D3D11_USAGE_DEFAULT;
    
    RETURN_IF_FAILED(m_device->CreateTexture2D(&sharedDesc, nullptr, &newRes.privateTexture));
    RETURN_IF_FAILED(m_device->CreateShaderResourceView(newRes.privateTexture.Get(), nullptr, &newRes.privateSRV));

    newRes.connected = true;
    m_producerResources.push_back(std::move(newRes));
    VirtuaCamLog::LogLine(std::format(
        L"UpdateProducerConnection connected pid={} texture='{}' fence='{}' handle=0x{:X}",
        streamInfo.processId,
        streamInfo.textureName,
        streamInfo.fenceName,
        static_cast<unsigned long long>(streamInfo.sharedFenceHandleValue)));

    return S_OK;
}

void Multiplexer::CompositeFrames(const std::vector<VirtuaCam::DiscoveredSharedStream>& producers, bool isGridMode)
{
    // 1. Update connections and sync GPU resources for all active producers
    std::vector<VirtuaCam::DiscoveredSharedStream> activeProducers;
    std::copy_if(producers.begin(), producers.end(), std::back_inserter(activeProducers),
        [](const auto& p) { return p.processId != 0; });

    PruneConnections(activeProducers);
    for (const auto& p : activeProducers) {
        const HRESULT hrConnection = UpdateProducerConnection(p);
        if (FAILED(hrConnection)) {
            VirtuaCamLog::LogLine(std::format(
                L"CompositeFrames skipping producer pid={} because connection failed hr=0x{:08X}",
                p.processId,
                static_cast<unsigned>(hrConnection)));
        }
    }

    for (auto& res : m_producerResources) {
        wil::unique_handle hManifest(OpenFileMappingW(FILE_MAP_READ, FALSE, GetProducerManifestName(res.pid).c_str()));
        if (!hManifest) continue;
        BroadcastManifest* pView = (BroadcastManifest*)MapViewOfFile(hManifest.get(), FILE_MAP_READ, 0, 0, sizeof(BroadcastManifest));
        if (!pView) continue;

        UINT64 latestFrame = pView->frameValue;
        if (latestFrame > res.lastSeenFrame) {
            m_context4->Wait(res.sharedFence.Get(), latestFrame);
            m_context->CopyResource(res.privateTexture.Get(), res.sharedTexture.Get());
            res.lastSeenFrame = latestFrame;
        }
        UnmapViewOfFile(pView);
    }

    // 2. Prepare for rendering
    m_context->OMSetRenderTargets(1, m_compositeRTV.GetAddressOf(), nullptr);
    const float clearColor[] = { 0.0f, 0.0f, 1.0f, 1.0f }; // Saturated blue
    m_context->ClearRenderTargetView(m_compositeRTV.Get(), clearColor);

    D3D11_TEXTURE2D_DESC compDesc;
    m_compositeTexture->GetDesc(&compDesc);
    UINT MUX_WIDTH = compDesc.Width;
    UINT MUX_HEIGHT = compDesc.Height;

    auto find_resource = [&](DWORD pid) -> ProducerGpuResources* {
        for (auto& res : m_producerResources) {
            if (res.pid == pid) return &res;
        }
        return nullptr;
    };

    // 3. Render Background (Either Primary Source or "No Signal" Shader)
    ProducerGpuResources* primarySourceRes = nullptr;
    if (!isGridMode && !producers.empty() && producers[0].processId != 0) {
        primarySourceRes = find_resource(producers[0].processId);
    }

    if (primarySourceRes && primarySourceRes->privateSRV) {
        D3D11_VIEWPORT vp = { 0.0f, 0.0f, (float)MUX_WIDTH, (float)MUX_HEIGHT, 0.0f, 1.0f };
        m_context->RSSetViewports(1, &vp);
        m_context->VSSetShader(m_blitVS.Get(), nullptr, 0);
        m_context->PSSetShader(m_blitPS.Get(), nullptr, 0);
        m_context->PSSetSamplers(0, 1, m_blitSampler.GetAddressOf());
        m_context->PSSetShaderResources(0, 1, primarySourceRes->privateSRV.GetAddressOf());
        m_context->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        m_context->Draw(3, 0);
    }
    else {
        m_offModeShader.Render(m_compositeRTV, MUX_WIDTH, MUX_HEIGHT);
    }

    // 4. Render Overlays (PiP sources or Grid)
    if (isGridMode) {
        std::vector<ProducerGpuResources*> gridResources;
        gridResources.reserve(activeProducers.size());
        for (const auto& producer : activeProducers) {
            if (ProducerGpuResources* res = find_resource(producer.processId); res && res->privateSRV) {
                gridResources.push_back(res);
            }
        }

        if (!gridResources.empty()) {
            m_context->VSSetShader(m_blitVS.Get(), nullptr, 0);
            m_context->PSSetShader(m_blitPS.Get(), nullptr, 0);
            m_context->PSSetSamplers(0, 1, m_blitSampler.GetAddressOf());
            m_context->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

            const UINT count = static_cast<UINT>(gridResources.size());
            const UINT columns = std::max<UINT>(1, static_cast<UINT>(std::ceil(std::sqrt(static_cast<float>(count)))));
            const UINT rows = std::max<UINT>(1, static_cast<UINT>(std::ceil(static_cast<float>(count) / static_cast<float>(columns))));
            const float tileW = static_cast<float>(MUX_WIDTH) / static_cast<float>(columns);
            const float tileH = static_cast<float>(MUX_HEIGHT) / static_cast<float>(rows);

            for (UINT i = 0; i < count; ++i) {
                const UINT col = i % columns;
                const UINT row = i / columns;
                D3D11_VIEWPORT tileVp = {
                    tileW * static_cast<float>(col),
                    tileH * static_cast<float>(row),
                    tileW,
                    tileH,
                    0.0f,
                    1.0f
                };
                m_context->RSSetViewports(1, &tileVp);
                m_context->PSSetShaderResources(0, 1, gridResources[i]->privateSRV.GetAddressOf());
                m_context->Draw(3, 0);
            }
        }
    }
    else {
        // --- START OF MODIFIED SECTION ---
        // Ensure blitting shaders are active before drawing overlays
        m_context->VSSetShader(m_blitVS.Get(), nullptr, 0);
        m_context->PSSetShader(m_blitPS.Get(), nullptr, 0);
        m_context->PSSetSamplers(0, 1, m_blitSampler.GetAddressOf());
        m_context->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        // Render PiP sources on top of the background.
        const float pip_w = MUX_WIDTH / 4.0f;
        const float pip_h = MUX_HEIGHT / 4.0f;
        const float margin = 10.0f;
        
        D3D11_VIEWPORT pip_vps[4] = {
            { margin, margin, pip_w, pip_h, 0.0f, 1.0f },
            { MUX_WIDTH - pip_w - margin, margin, pip_w, pip_h, 0.0f, 1.0f },
            { margin, MUX_HEIGHT - pip_h - margin, pip_w, pip_h, 0.0f, 1.0f },
            { MUX_WIDTH - pip_w - margin, MUX_HEIGHT - pip_h - margin, pip_w, pip_h, 0.0f, 1.0f }
        };
        
        // Start from index 1 for PiP sources
        for (size_t i = 1; i < producers.size() && i < 5; ++i) {
             if (producers[i].processId != 0) {
                 ProducerGpuResources* res = find_resource(producers[i].processId);
                 if (res && res->privateSRV) {
                     m_context->RSSetViewports(1, &pip_vps[i - 1]);
                     m_context->PSSetShaderResources(0, 1, res->privateSRV.GetAddressOf());
                     m_context->Draw(3, 0);
                 }
             }
        }
        // --- END OF MODIFIED SECTION ---
    }

    // 5. Finalize frame
    m_context->CopyResource(m_outputTexture.Get(), m_compositeTexture.Get());
    m_outputFrameValue++;
    m_context4->Signal(m_outputFence.Get(), m_outputFrameValue);
}
