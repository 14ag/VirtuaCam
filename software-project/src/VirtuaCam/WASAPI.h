#pragma once
#include <windows.h>
#include <vector>
#include <string>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <wil/com.h>
#include <wil/resource.h>
#include "VirtuaCamAudioAbi.h"

class WASAPICapture {
public:
    WASAPICapture();
    ~WASAPICapture();

    // Enumerate render devices (speakers, headphones) for loopback capture.
    HRESULT EnumerateRenderDevices();
    // Enumerate capture devices (microphones).
    HRESULT EnumerateCaptureDevices();

    // Getters for the device name lists.
    const std::vector<std::wstring>& GetRenderDeviceNames() const { return m_renderDeviceNames; }
    const std::vector<std::wstring>& GetCaptureDeviceNames() const { return m_captureDeviceNames; }

    // Start capturing from a device. isLoopback determines whether to use the render or capture list.
    HRESULT StartCapture(int deviceIndex, bool isLoopback);
    void StopCapture();

private:
    static DWORD WINAPI CaptureThread(LPVOID context);
    void CaptureThreadImpl();
    void CopySourceFormat(const WAVEFORMATEX* format);
    void PublishAudioToBridge(const BYTE* data, UINT32 frameCount, DWORD flags);
    void SendMicPacket(const int16_t* frames, size_t frameCount);
    float ReadSourceSampleAsFloat(const BYTE* data, UINT32 frameIndex, WORD channel) const;
    static int16_t FloatToPcm16(float value);

    // Separate lists for render and capture devices.
    std::vector<wil::com_ptr_nothrow<IMMDevice>> m_renderDevices;
    std::vector<std::wstring> m_renderDeviceNames;
    std::vector<wil::com_ptr_nothrow<IMMDevice>> m_captureDevices;
    std::vector<std::wstring> m_captureDeviceNames;
    
    wil::com_ptr_nothrow<IAudioClient> m_audioClient;
    wil::com_ptr_nothrow<IAudioCaptureClient> m_captureClient;

    wil::unique_handle m_hCaptureThread;
    wil::unique_handle m_hShutdownEvent;
    wil::unique_handle m_hAudioEvent;
    wil::unique_handle m_hMicBridge;
    WAVEFORMATEXTENSIBLE m_sourceFormat = {};
    WORD m_sourceFormatTag = WAVE_FORMAT_PCM;
    GUID m_sourceSubFormat = KSDATAFORMAT_SUBTYPE_PCM;
    UINT32 m_sourceSampleRate = VIRTUACAM_MIC_SAMPLE_RATE;
    WORD m_sourceChannels = VIRTUACAM_MIC_CHANNELS;
    WORD m_sourceBitsPerSample = VIRTUACAM_MIC_BITS_PER_SAMPLE;
    WORD m_sourceBlockAlign = VIRTUACAM_MIC_FRAME_BYTES;
    uint64_t m_packetSequence = 0;
    std::vector<int16_t> m_bridgeFrameBuffer;
    bool m_isCapturing = false;
    bool m_loggedFirstPacket = false;
    bool m_loggedBridgeError = false;
};
