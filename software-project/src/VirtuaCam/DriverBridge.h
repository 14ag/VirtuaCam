#pragma once

#include "pch.h"
#include "Config.h"
#include "VirtuaCamDriverAbi.h"
#include <dshow.h>
#include <dmksctrl.h>
#include <vector>

class DriverBridge
{
public:
    DriverBridge();
    ~DriverBridge();

    HRESULT Initialize();
    void Shutdown();
    bool IsActive() const { return m_active; }
    bool IsConnected() const { return m_connected; }
    bool IsDriverInUse();
    const std::wstring& GetLastError() const { return m_lastError; }

    HRESULT RegisterClientRequestEvent(HANDLE eventHandle);
    HRESULT CheckDriverAvailability();
    HRESULT Connect();
    HRESULT Disconnect();
    HRESULT SetPreferredAspectRatio(AspectRatioMode mode);
    HRESULT SetAspectPolicy(AspectRatioMode preferredMode, ULONG allowedMask);
    HRESULT SendFrame(ID3D11Texture2D* sourceTexture);

private:
    struct ReadbackSlot
    {
        wil::com_ptr_nothrow<ID3D11Texture2D> texture;
        bool hasCopy = false;
        UINT64 sequence = 0;
    };

    static bool IsRecoverableSendFailure(HRESULT hr);
    HRESULT EnsurePropertySetReady();
    bool IsPropertySetSupported(ULONG propertyId, DWORD* supportFlags = nullptr);
    HRESULT FindDriverFilter();
    HRESULT ReinitializeAfterFailure(HRESULT failureHr);
    HRESULT SetDriverProperty(ULONG propertyId, void* data, ULONG dataLength, ULONG* bytesReturned = nullptr);
    HRESULT GetDriverProperty(ULONG propertyId, void* data, ULONG dataLength, ULONG* bytesReturned = nullptr);
    HRESULT EnsureGpuResources(ID3D11Texture2D* sourceTexture);
    HRESULT EnsureSourceTextureView(ID3D11Texture2D* sourceTexture);
    HRESULT RefreshDriverGeometry();
    bool IsDriverClientActive();
    HRESULT ApplyDriverAspectProperties(AspectRatioMode preferredMode, ULONG allowedMask);
    HRESULT ApplyAspectPolicyNow(AspectRatioMode preferredMode, ULONG allowedMask);
    HRESULT ApplyPendingAspectPolicyIfIdle();
    HRESULT EnsureNv12Resources();
    HRESULT CreateShaders();
    HRESULT UploadMappedFrame(const D3D11_MAPPED_SUBRESOURCE& mapped);
    HRESULT UploadMappedFrameExBgra(const D3D11_MAPPED_SUBRESOURCE& mapped);
    HRESULT UploadMappedFrameExNv12(const D3D11_MAPPED_SUBRESOURCE& mapped);
    HRESULT TrySendFrameEx(const VIRTUACAM_FRAME_EX_HEADER& header);
    bool CanUseFrameEx(ULONG uploadFormat) const;
    bool IsFrameExSupported();
    HRESULT EnsureReadbackPool(
        std::vector<ReadbackSlot>& slots,
        DXGI_FORMAT format,
        UINT width,
        UINT height,
        wil::com_ptr_nothrow<ID3D11Texture2D>* firstSlotAlias = nullptr);
    HRESULT QueueReadbackAndMapReady(
        std::vector<ReadbackSlot>& slots,
        size_t& writeIndex,
        ID3D11Texture2D* sourceTexture,
        D3D11_MAPPED_SUBRESOURCE& mapped,
        ID3D11Texture2D** mappedTexture);
    void ResetReadbackPools();
    void ResetFrameExResources();
    void LogDriverStatusSnapshot(const wchar_t* prefix, long frameSequence);
    void SetLastError(const std::wstring& message) { m_lastError = message; }

    bool m_active = false;
    bool m_connected = false;
    std::wstring m_lastError;
    std::wstring m_selectedDevicePath;
    std::wstring m_selectedFriendlyName;
    wil::unique_hfile m_driverHandle;

    wil::com_ptr_nothrow<IBaseFilter> m_filter;
    wil::com_ptr_nothrow<IKsControl> m_ksControl;
    wil::com_ptr_nothrow<IKsPropertySet> m_propertySet;

    wil::com_ptr_nothrow<ID3D11Device> m_device;
    wil::com_ptr_nothrow<ID3D11DeviceContext> m_context;
    wil::com_ptr_nothrow<ID3D11Texture2D> m_scaledTexture;
    wil::com_ptr_nothrow<ID3D11RenderTargetView> m_scaledRtv;
    wil::com_ptr_nothrow<ID3D11Texture2D> m_stagingTexture;
    wil::com_ptr_nothrow<ID3D11Texture2D> m_nv12Texture;
    wil::com_ptr_nothrow<ID3D11Texture2D> m_nv12StagingTexture;
    wil::com_ptr_nothrow<ID3D11VideoDevice> m_videoDevice;
    wil::com_ptr_nothrow<ID3D11VideoContext> m_videoContext;
    wil::com_ptr_nothrow<ID3D11VideoProcessorEnumerator> m_videoProcessorEnumerator;
    wil::com_ptr_nothrow<ID3D11VideoProcessor> m_videoProcessor;
    wil::com_ptr_nothrow<ID3D11VideoProcessorInputView> m_videoInputView;
    wil::com_ptr_nothrow<ID3D11VideoProcessorOutputView> m_videoOutputView;
    wil::com_ptr_nothrow<ID3D11Texture2D> m_sourceTexture;
    wil::com_ptr_nothrow<ID3D11ShaderResourceView> m_sourceSrv;
    wil::com_ptr_nothrow<ID3D11VertexShader> m_vertexShader;
    wil::com_ptr_nothrow<ID3D11PixelShader> m_pixelShader;
    wil::com_ptr_nothrow<ID3D11SamplerState> m_samplerState;
    wil::com_ptr_nothrow<ID3D11Buffer> m_blitConstants;

    std::vector<BYTE> m_rgbBuffer;
    std::vector<BYTE> m_frameExBuffer;
    std::vector<ReadbackSlot> m_bgraReadbackSlots;
    std::vector<ReadbackSlot> m_nv12ReadbackSlots;
    size_t m_bgraReadbackWriteIndex = 0;
    size_t m_nv12ReadbackWriteIndex = 0;
    UINT64 m_readbackSequence = 0;
    UINT64 m_readbackNotReadyCount = 0;
    UINT64 m_frameExBgraUploadCount = 0;
    UINT64 m_frameExNv12UploadCount = 0;
    UINT64 m_legacyBgr24UploadCount = 0;
    UINT64 m_frameExFallbackToBgr24Count = 0;
    ULONGLONG m_nextDriverProbeTick = 0;
    UINT m_outputWidth = 1920;
    UINT m_outputHeight = 1080;
    ULONG m_outputFormat = 0;
    ULONG m_uploadFormatMask = 0;
    AspectRatioMode m_pendingPreferredMode = AspectRatioMode::R16_9;
    ULONG m_pendingAllowedMask = ASPECT_RATIO_MASK_ALL;
    bool m_hasPendingAspectPolicy = false;
    bool m_frameExSupportKnown = false;
    bool m_frameExSupported = false;
    bool m_frameExFallbackLogged = false;
    UINT64 m_frameId = 0;
};
