#include "pch.h"
#include "Discovery.h"
#include "Tools.h"
#include <d3d11_1.h>
#include <d3d12.h>
#include <tlhelp32.h>
#include <memory>
#include <algorithm>

#pragma comment(lib, "d3d12.lib")

namespace VirtuaCam {

struct Discovery::Impl {
    Microsoft::WRL::ComPtr<ID3D11Device> m_device;
    LUID m_adapterLuid = {};
    std::vector<DiscoveredSharedStream> m_discoveredStreams;

    bool TryAddStreamForPid(DWORD pid, const std::wstring& processName, UINT64 expectedBrokerNonce)
    {
        if (pid == 0 ||
            std::any_of(
                m_discoveredStreams.begin(),
                m_discoveredStreams.end(),
                [pid](const auto& stream) { return stream.processId == pid; })) {
            return false;
        }

        const std::wstring manifestName = GetProducerManifestName(pid);
        HANDLE hManifest = OpenFileMappingW(FILE_MAP_READ, FALSE, manifestName.c_str());
        if (!hManifest) {
            return false;
        }

        bool added = false;
        BroadcastManifest* pView = static_cast<BroadcastManifest*>(
            MapViewOfFile(hManifest, FILE_MAP_READ, 0, 0, sizeof(BroadcastManifest)));
        if (pView) {
            std::wstring textureName;
            std::wstring fenceName;
            if (ValidateBroadcastManifest(
                    pView,
                    pid,
                    expectedBrokerNonce,
                    &m_adapterLuid,
                    textureName,
                    fenceName)) {
                DiscoveredSharedStream stream;
                stream.processId = pid;
                stream.processName = processName;
                stream.producerType = L"DirectPort";
                stream.manifestName = manifestName;
                stream.textureName = textureName;
                stream.fenceName = fenceName;
                stream.statusName = GetProducerStatusName(pid);
                stream.sharedFenceHandleValue = pView->sharedFenceHandleValue;
                stream.brokerNonce = pView->brokerNonce;
                stream.ownerPid = pView->ownerPid;
                stream.adapterLuid = pView->adapterLuid;

                HANDLE hStatus = OpenFileMappingW(FILE_MAP_READ, FALSE, stream.statusName.c_str());
                if (hStatus) {
                    DirectPortStatusV1* statusView = static_cast<DirectPortStatusV1*>(
                        MapViewOfFile(hStatus, FILE_MAP_READ, 0, 0, sizeof(DirectPortStatusV1)));
                    if (statusView) {
                        stream.hasStatus = ReadDirectPortStatusStable(
                            statusView,
                            pid,
                            stream.status);
                        UnmapViewOfFile(statusView);
                    }
                    CloseHandle(hStatus);
                }

                m_discoveredStreams.push_back(std::move(stream));
                added = true;
            }
            UnmapViewOfFile(pView);
        }

        CloseHandle(hManifest);
        return added;
    }
};

Discovery::Discovery() : pImpl(std::make_unique<Impl>()) {}
Discovery::~Discovery() { Teardown(); }

HRESULT Discovery::Initialize(ID3D11Device* device) {
    pImpl->m_device = device;
    Microsoft::WRL::ComPtr<IDXGIDevice> dxgiDevice;
    pImpl->m_device.As(&dxgiDevice);
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    dxgiDevice->GetAdapter(&adapter);
    DXGI_ADAPTER_DESC desc;
    adapter->GetDesc(&desc);
    pImpl->m_adapterLuid = desc.AdapterLuid;
    return S_OK;
}

void Discovery::Teardown() {
    pImpl->m_device.Reset();
}

void Discovery::DiscoverStreams() {
    static const std::map<DWORD, UINT64> emptyExpectedProducers;
    DiscoverStreams(emptyExpectedProducers);
}

void Discovery::DiscoverStreams(const std::map<DWORD, UINT64>& expectedProducers) {
    pImpl->m_discoveredStreams.clear();

    for (const auto& [pid, nonce] : expectedProducers) {
        pImpl->TryAddStreamForPid(pid, GetProcessName(pid), nonce);
    }

    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnapshot == INVALID_HANDLE_VALUE) return;

    PROCESSENTRY32W pe32 = {};
    pe32.dwSize = sizeof(PROCESSENTRY32W);
    
    if (Process32FirstW(hSnapshot, &pe32)) {
        do {
            pImpl->TryAddStreamForPid(pe32.th32ProcessID, pe32.szExeFile, 0);
        } while (Process32NextW(hSnapshot, &pe32));
    }
    CloseHandle(hSnapshot);
}

const std::vector<DiscoveredSharedStream>& Discovery::GetDiscoveredStreams() const { 
    return pImpl->m_discoveredStreams; 
}

}
