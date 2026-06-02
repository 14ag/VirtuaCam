#pragma once

#include <windows.h>
#include <d3d11_4.h>
#include <wrl/client.h>
#include <string>
#include <vector>
#include <memory>
#include <map>
#include "Tools.h"

struct ID3D11Device;

namespace VirtuaCam {

    struct DiscoveredSharedStream {
        DWORD processId;
        std::wstring processName;
        std::wstring producerType;
        std::wstring manifestName;
        std::wstring textureName;
        std::wstring fenceName;
        std::wstring statusName;
        UINT64 sharedFenceHandleValue = 0;
        UINT64 brokerNonce = 0;
        DWORD ownerPid = 0;
        LUID adapterLuid;
        bool hasStatus = false;
        DirectPortStatusV1 status = {};
    };

    class Discovery {
    public:
        Discovery();
        ~Discovery();

        HRESULT Initialize(ID3D11Device* device);
        void Teardown();

        void DiscoverStreams();
        void DiscoverStreams(const std::map<DWORD, UINT64>& expectedProducers);
        
        const std::vector<DiscoveredSharedStream>& GetDiscoveredStreams() const;

    private:
        struct Impl;
        std::unique_ptr<Impl> pImpl;
    };

}
