#pragma once

#include <d2d1_1.h>
#include <ks.h>
#include <cassert>

std::string to_string(const std::wstring& ws);
std::wstring to_wstring(const std::string& s);
const std::wstring GUID_ToStringW(const GUID& guid, bool resolve = true);
const std::string GUID_ToStringA(const GUID& guid, bool resolve = true);
const std::wstring PROPVARIANT_ToString(const PROPVARIANT& pv);
void CenterWindow(HWND hwnd, bool useCursorPos);
D2D_COLOR_F HSL2RGB(const float h, const float s, const float l);
const std::wstring GetProcessName(DWORD pid);
const LSTATUS RegWriteKey(HKEY key, PCWSTR path, HKEY* outKey);
const LSTATUS RegWriteValue(HKEY key, PCWSTR name, const std::wstring& value);
const LSTATUS RegWriteValue(HKEY key, PCWSTR name, DWORD value);
HRESULT RGB32ToNV12(BYTE* input, ULONG inputSize, LONG inputStride, UINT width, UINT height, BYTE* output, ULONG ouputSize, LONG outputStride);
HANDLE GetHandleFromName(const WCHAR* name, DWORD desiredAccess = GENERIC_READ | GENERIC_WRITE);
HRESULT CreateCurrentUserOnlySecurityAttributes(wil::unique_hlocal_security_descriptor& descriptor, SECURITY_ATTRIBUTES& sa);
std::wstring GetProducerManifestName(DWORD pid);
std::wstring GetProducerTextureName(DWORD pid);
std::wstring GetProducerFenceName(DWORD pid);
std::wstring GetProducerStatusName(DWORD pid);
std::wstring GetBrokerManifestName();
std::wstring GetBrokerTextureName();
std::wstring GetBrokerFenceName();

enum class VCamCommand;

inline constexpr UINT32 VIRTUACAM_MANIFEST_MAGIC = 0x324D4356u; // VCM2
inline constexpr UINT32 VIRTUACAM_MANIFEST_VERSION = 2u;
inline constexpr UINT32 VIRTUACAM_MANIFEST_NAME_CAPACITY = 256u;

struct BroadcastManifest {
    UINT32 magic;
    UINT32 version;
    UINT32 size;
    DWORD ownerPid;
    UINT64 brokerNonce;
    UINT64 frameValue;
    UINT width;
    UINT height;
    DXGI_FORMAT format;
    LUID adapterLuid;
    UINT32 textureNameLength;
    UINT32 fenceNameLength;
    WCHAR textureName[VIRTUACAM_MANIFEST_NAME_CAPACITY];
    WCHAR fenceName[VIRTUACAM_MANIFEST_NAME_CAPACITY];
    UINT64 sharedFenceHandleValue;
    volatile VCamCommand command;
};

inline constexpr UINT32 VIRTUACAM_DIRECTPORT_STATUS_MAGIC = 0x31534356u; // VCS1
inline constexpr UINT32 VIRTUACAM_DIRECTPORT_STATUS_VERSION = 1u;

struct DirectPortStatusV1 {
    UINT32 magic;
    UINT32 version;
    UINT32 size;
    DWORD ownerPid;
    volatile LONGLONG publishSequence;
    UINT64 qpcFrequency;
    UINT64 producerFrameQpc;
    UINT64 lastPublishedFenceValue;
    UINT64 frameCount;
    UINT64 duplicateCount;
    UINT64 staleCount;
    HRESULT lastHRESULT;
    ULONG reserved0;
    UINT64 reserved[8];
};

bool InitializeBroadcastManifest(
    BroadcastManifest* manifest,
    DWORD ownerPid,
    UINT64 brokerNonce,
    UINT width,
    UINT height,
    DXGI_FORMAT format,
    const LUID& adapterLuid,
    const std::wstring& textureName,
    const std::wstring& fenceName);
bool ValidateBroadcastManifest(
    const BroadcastManifest* manifest,
    DWORD expectedOwnerPid,
    UINT64 expectedBrokerNonce,
    const LUID* expectedAdapterLuid,
    std::wstring& textureName,
    std::wstring& fenceName);
bool InitializeDirectPortStatus(
    DirectPortStatusV1* status,
    DWORD ownerPid,
    UINT64 qpcFrequency);
void PublishDirectPortStatus(
    DirectPortStatusV1* status,
    UINT64 producerFrameQpc,
    UINT64 lastPublishedFenceValue,
    UINT64 frameCount,
    UINT64 duplicateCount,
    UINT64 staleCount,
    HRESULT lastHRESULT);
bool ReadDirectPortStatusStable(
    const DirectPortStatusV1* status,
    DWORD expectedOwnerPid,
    DirectPortStatusV1& snapshot);

void TraceMFAttributes(IUnknown* unknown, PCWSTR prefix);
std::wstring PKSIDENTIFIER_ToString(PKSIDENTIFIER id, ULONG length);

_Ret_range_(== , _expr)
inline bool assert_true(bool _expr)
{
    assert(_expr);
    return _expr;
}

namespace wil
{
    template<typename T>
    wil::unique_cotaskmem_array_ptr<T> make_unique_cotaskmem_array(size_t numOfElements)
    {
        wil::unique_cotaskmem_array_ptr<T> arr;
        auto cb = sizeof(wil::details::element_traits<T>::type) * numOfElements;
        void* ptr = ::CoTaskMemAlloc(cb);
        if (ptr != nullptr)
        {
            ZeroMemory(ptr, cb);
            arr.reset(reinterpret_cast<typename wil::details::element_traits<T>::type*>(ptr), numOfElements);
        }
        return arr;
    }
}

struct registry_traits
{
    using type = HKEY;
    static void close(type value) noexcept
    {
        (void)RegCloseKey(value);
    }
    static constexpr type invalid() noexcept
    {
        return nullptr;
    }
};
