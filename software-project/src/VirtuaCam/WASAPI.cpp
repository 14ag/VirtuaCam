#include "pch.h"
#include "WASAPI.h"
#include "App.h"
#include "RuntimeLog.h"
#include <propkey.h>
#include <functiondiscoverykeys_devpkey.h>
#include <avrt.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#pragma comment(lib, "avrt.lib")

WASAPICapture::WASAPICapture() {
    m_hShutdownEvent.reset(CreateEvent(NULL, TRUE, FALSE, NULL));
}

WASAPICapture::~WASAPICapture() {
    StopCapture();
}

// Enumerates active audio output (render) devices.
HRESULT WASAPICapture::EnumerateRenderDevices() {
    m_renderDevices.clear();
    m_renderDeviceNames.clear();

    wil::com_ptr_nothrow<IMMDeviceEnumerator> enumerator;
    RETURN_IF_FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)));

    wil::com_ptr_nothrow<IMMDeviceCollection> collection;
    RETURN_IF_FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection));

    UINT count = 0;
    RETURN_IF_FAILED(collection->GetCount(&count));

    for (UINT i = 0; i < count; i++) {
        wil::com_ptr_nothrow<IMMDevice> device;
        if (SUCCEEDED(collection->Item(i, &device))) {
            wil::com_ptr_nothrow<IPropertyStore> props;
            if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
                PROPVARIANT varName;
                PropVariantInit(&varName);
                if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &varName))) {
                    m_renderDevices.push_back(device);
                    m_renderDeviceNames.push_back(varName.pwszVal);
                    PropVariantClear(&varName);
                }
            }
        }
    }
    return S_OK;
}

// Enumerates active audio input (capture) devices.
HRESULT WASAPICapture::EnumerateCaptureDevices() {
    m_captureDevices.clear();
    m_captureDeviceNames.clear();

    wil::com_ptr_nothrow<IMMDeviceEnumerator> enumerator;
    RETURN_IF_FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)));

    wil::com_ptr_nothrow<IMMDeviceCollection> collection;
    RETURN_IF_FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection));

    UINT count = 0;
    RETURN_IF_FAILED(collection->GetCount(&count));

    for (UINT i = 0; i < count; i++) {
        wil::com_ptr_nothrow<IMMDevice> device;
        if (SUCCEEDED(collection->Item(i, &device))) {
            wil::com_ptr_nothrow<IPropertyStore> props;
            if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
                PROPVARIANT varName;
                PropVariantInit(&varName);
                if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &varName))) {
                    m_captureDevices.push_back(device);
                    m_captureDeviceNames.push_back(varName.pwszVal);
                    PropVariantClear(&varName);
                }
            }
        }
    }
    return S_OK;
}

// Starts the capture stream on a selected device.
HRESULT WASAPICapture::StartCapture(int deviceIndex, bool isLoopback) {
    StopCapture();

    wil::com_ptr_nothrow<IMMDevice> device;
    std::wstring deviceName;
    if (isLoopback) {
        if (deviceIndex < 0 || deviceIndex >= m_renderDevices.size()) return E_INVALIDARG;
        device = m_renderDevices[deviceIndex];
        deviceName = m_renderDeviceNames[deviceIndex];
    } else {
        if (deviceIndex < 0 || deviceIndex >= m_captureDevices.size()) return E_INVALIDARG;
        device = m_captureDevices[deviceIndex];
        deviceName = m_captureDeviceNames[deviceIndex];
    }

    RETURN_IF_FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void**)&m_audioClient));

    WAVEFORMATEX* rawFormat = NULL;
    RETURN_IF_FAILED(m_audioClient->GetMixFormat(&rawFormat));
    wil::unique_cotaskmem_ptr<WAVEFORMATEX> format(rawFormat);
    WAVEFORMATEX* pwfx = format.get();
    CopySourceFormat(pwfx);

    REFERENCE_TIME hnsRequestedDuration = 10000000; // 1 second buffer

    // Set AUDCLNT_STREAMFLAGS_LOOPBACK for capturing speaker output.
    DWORD streamFlags = isLoopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0;
    streamFlags |= AUDCLNT_STREAMFLAGS_EVENTCALLBACK;

    RETURN_IF_FAILED(m_audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, streamFlags, hnsRequestedDuration, 0, pwfx, NULL));

    m_hAudioEvent.reset(CreateEvent(NULL, FALSE, FALSE, NULL));
    RETURN_HR_IF_NULL(E_FAIL, m_hAudioEvent.get());
    RETURN_IF_FAILED(m_audioClient->SetEventHandle(m_hAudioEvent.get()));

    RETURN_IF_FAILED(m_audioClient->GetService(IID_PPV_ARGS(&m_captureClient)));

    m_hMicBridge.reset(CreateFileW(
        VIRTUACAM_MIC_WIN32_DEVICE_PATH,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr));
    if (!m_hMicBridge) {
        VirtuaCamLog::LogWin32(L"VirtuaCam microphone bridge open failed", GetLastError());
    }

    ResetEvent(m_hShutdownEvent.get());
    m_loggedFirstPacket = false;
    m_loggedBridgeError = false;
    m_packetSequence = 0;
    m_bridgeFrameBuffer.clear();
    m_hCaptureThread.reset(CreateThread(NULL, 0, CaptureThread, this, 0, NULL));
    RETURN_HR_IF_NULL(E_FAIL, m_hCaptureThread.get());

    m_isCapturing = true;
    HRESULT hrStart = m_audioClient->Start();
    if (FAILED(hrStart)) {
        StopCapture();
        return hrStart;
    }

    VirtuaCamLog::LogLine(std::format(
        L"Audio capture started: device={} loopback={}",
        deviceName,
        isLoopback ? 1 : 0));
    return S_OK;
}

// Stops any active capture stream and cleans up resources.
void WASAPICapture::StopCapture() {
    if (m_audioClient && m_isCapturing) {
        m_audioClient->Stop();
    }

    if (m_hShutdownEvent) {
        SetEvent(m_hShutdownEvent.get());
    }
    if (m_hCaptureThread) {
        WaitForSingleObject(m_hCaptureThread.get(), INFINITE);
        m_hCaptureThread.reset();
    }

    m_hAudioEvent.reset();
    m_hMicBridge.reset();
    m_bridgeFrameBuffer.clear();
    m_captureClient.reset();
    m_audioClient.reset();
    m_isCapturing = false;
}

// Static entry point for the capture thread.
DWORD WINAPI WASAPICapture::CaptureThread(LPVOID context) {
    WASAPICapture* pThis = static_cast<WASAPICapture*>(context);
    if (SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED))) {
        pThis->CaptureThreadImpl();
        CoUninitialize();
    }
    return 0;
}

// Main loop for the capture thread.
void WASAPICapture::CaptureThreadImpl() {
    DWORD taskIndex = 0;
    HANDLE hTask = AvSetMmThreadCharacteristics(L"Audio", &taskIndex);

    HANDLE waitHandles[] = { m_hShutdownEvent.get(), m_hAudioEvent.get() };
    for (;;) {
        DWORD wait = WaitForMultipleObjects(2, waitHandles, FALSE, 100);
        if (wait == WAIT_OBJECT_0) {
            break;
        }
        if (wait != WAIT_OBJECT_0 + 1 && wait != WAIT_TIMEOUT) {
            continue;
        }

        UINT32 nextPacketFrames = 0;
        while (m_captureClient && SUCCEEDED(m_captureClient->GetNextPacketSize(&nextPacketFrames)) && nextPacketFrames > 0) {
            BYTE* pData = nullptr;
            UINT32 numFramesAvailable = 0;
            DWORD flags = 0;

            HRESULT hr = m_captureClient->GetBuffer(&pData, &numFramesAvailable, &flags, NULL, NULL);
            if (FAILED(hr)) {
                break;
            }

            if (!m_loggedFirstPacket) {
                m_loggedFirstPacket = true;
                VirtuaCamLog::LogLine(std::format(
                    L"Audio capture packet: frames={} silent={} sourceRate={} sourceBits={} sourceChannels={}",
                    numFramesAvailable,
                    (flags & AUDCLNT_BUFFERFLAGS_SILENT) ? 1 : 0,
                    m_sourceSampleRate,
                    m_sourceBitsPerSample,
                    m_sourceChannels));
            }
            PublishAudioToBridge(pData, numFramesAvailable, flags);
            m_captureClient->ReleaseBuffer(numFramesAvailable);
        }
    }

    if (hTask) AvRevertMmThreadCharacteristics(hTask);
}

void WASAPICapture::CopySourceFormat(const WAVEFORMATEX* format) {
    ZeroMemory(&m_sourceFormat, sizeof(m_sourceFormat));
    m_sourceSubFormat = KSDATAFORMAT_SUBTYPE_PCM;
    m_sourceFormatTag = format ? format->wFormatTag : WAVE_FORMAT_PCM;
    m_sourceSampleRate = format && format->nSamplesPerSec ? format->nSamplesPerSec : VIRTUACAM_MIC_SAMPLE_RATE;
    m_sourceChannels = format && format->nChannels ? format->nChannels : VIRTUACAM_MIC_CHANNELS;
    m_sourceBitsPerSample = format && format->wBitsPerSample ? format->wBitsPerSample : VIRTUACAM_MIC_BITS_PER_SAMPLE;
    m_sourceBlockAlign = format && format->nBlockAlign ? format->nBlockAlign : VIRTUACAM_MIC_FRAME_BYTES;

    if (format && format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        m_sourceFormat = *reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        m_sourceSubFormat = m_sourceFormat.SubFormat;
        if (m_sourceFormat.Samples.wValidBitsPerSample != 0) {
            m_sourceBitsPerSample = m_sourceFormat.Samples.wValidBitsPerSample;
        }
    } else if (format) {
        m_sourceFormat.Format = *format;
        m_sourceSubFormat = (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
            ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
            : KSDATAFORMAT_SUBTYPE_PCM;
    }
}

void WASAPICapture::PublishAudioToBridge(const BYTE* data, UINT32 frameCount, DWORD flags) {
    if (!m_hMicBridge || frameCount == 0 || m_sourceSampleRate == 0 || m_sourceBlockAlign == 0) {
        return;
    }

    const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || !data;
    const size_t outputFrames = std::max<size_t>(
        1,
        static_cast<size_t>(std::llround(
            static_cast<double>(frameCount) * VIRTUACAM_MIC_SAMPLE_RATE / m_sourceSampleRate)));

    std::vector<int16_t> converted(outputFrames * VIRTUACAM_MIC_CHANNELS);
    if (!silent) {
        for (size_t outFrame = 0; outFrame < outputFrames; ++outFrame) {
            UINT32 sourceFrame = static_cast<UINT32>(std::min<size_t>(
                frameCount - 1,
                static_cast<size_t>(
                    (static_cast<double>(outFrame) * m_sourceSampleRate) / VIRTUACAM_MIC_SAMPLE_RATE)));

            const float left = ReadSourceSampleAsFloat(data, sourceFrame, 0);
            const float right = ReadSourceSampleAsFloat(
                data,
                sourceFrame,
                m_sourceChannels > 1 ? 1 : 0);
            converted[(outFrame * 2) + 0] = FloatToPcm16(left);
            converted[(outFrame * 2) + 1] = FloatToPcm16(right);
        }
    }

    m_bridgeFrameBuffer.insert(m_bridgeFrameBuffer.end(), converted.begin(), converted.end());

    size_t offsetFrames = 0;
    while ((m_bridgeFrameBuffer.size() / VIRTUACAM_MIC_CHANNELS) - offsetFrames >= VIRTUACAM_MIC_PACKET_FRAMES) {
        SendMicPacket(
            m_bridgeFrameBuffer.data() + (offsetFrames * VIRTUACAM_MIC_CHANNELS),
            VIRTUACAM_MIC_PACKET_FRAMES);
        offsetFrames += VIRTUACAM_MIC_PACKET_FRAMES;
    }

    if (offsetFrames > 0) {
        m_bridgeFrameBuffer.erase(
            m_bridgeFrameBuffer.begin(),
            m_bridgeFrameBuffer.begin() + (offsetFrames * VIRTUACAM_MIC_CHANNELS));
    }
}

void WASAPICapture::SendMicPacket(const int16_t* frames, size_t frameCount) {
    std::vector<BYTE> packet(sizeof(VIRTUACAM_MIC_PACKET_HEADER) + VIRTUACAM_MIC_PACKET_BYTES);
    auto* header = reinterpret_cast<VIRTUACAM_MIC_PACKET_HEADER*>(packet.data());
    header->size = VIRTUACAM_MIC_PACKET_BYTES;
    header->frameCount = VIRTUACAM_MIC_PACKET_FRAMES;
    header->sequence = ++m_packetSequence;

    BYTE* payload = packet.data() + sizeof(VIRTUACAM_MIC_PACKET_HEADER);
    ZeroMemory(payload, VIRTUACAM_MIC_PACKET_BYTES);
    if (frames && frameCount > 0) {
        const size_t bytesToCopy = std::min<size_t>(
            frameCount * VIRTUACAM_MIC_FRAME_BYTES,
            VIRTUACAM_MIC_PACKET_BYTES);
        CopyMemory(payload, frames, bytesToCopy);
    }

    DWORD bytesReturned = 0;
    if (!DeviceIoControl(
            m_hMicBridge.get(),
            IOCTL_VIRTUACAM_MIC_WRITE_PACKET,
            packet.data(),
            static_cast<DWORD>(packet.size()),
            nullptr,
            0,
            &bytesReturned,
            nullptr) &&
        !m_loggedBridgeError) {
        m_loggedBridgeError = true;
        VirtuaCamLog::LogWin32(L"VirtuaCam microphone bridge write failed", GetLastError());
    }
}

float WASAPICapture::ReadSourceSampleAsFloat(const BYTE* data, UINT32 frameIndex, WORD channel) const {
    if (!data || m_sourceChannels == 0 || m_sourceBlockAlign == 0) {
        return 0.0f;
    }

    const WORD selectedChannel = std::min<WORD>(channel, static_cast<WORD>(m_sourceChannels - 1));
    const BYTE* frame = data + (static_cast<size_t>(frameIndex) * m_sourceBlockAlign);
    const WORD containerBytes = static_cast<WORD>(std::max<WORD>(1, m_sourceFormat.Format.wBitsPerSample / 8));
    const BYTE* sample = frame + (static_cast<size_t>(selectedChannel) * containerBytes);

    if (IsEqualGUID(m_sourceSubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) &&
        m_sourceFormat.Format.wBitsPerSample == 32) {
        float value = 0.0f;
        CopyMemory(&value, sample, sizeof(value));
        return value;
    }

    if (!IsEqualGUID(m_sourceSubFormat, KSDATAFORMAT_SUBTYPE_PCM) &&
        m_sourceFormatTag != WAVE_FORMAT_PCM) {
        return 0.0f;
    }

    switch (m_sourceFormat.Format.wBitsPerSample) {
    case 8:
        return (static_cast<int>(*sample) - 128) / 128.0f;
    case 16:
    {
        int16_t value = 0;
        CopyMemory(&value, sample, sizeof(value));
        return static_cast<float>(value) / 32768.0f;
    }
    case 24:
    {
        int32_t value = sample[0] | (sample[1] << 8) | (sample[2] << 16);
        if (value & 0x00800000) {
            value |= static_cast<int32_t>(0xFF000000);
        }
        return static_cast<float>(value) / 8388608.0f;
    }
    case 32:
    {
        int32_t value = 0;
        CopyMemory(&value, sample, sizeof(value));
        return static_cast<float>(value) / 2147483648.0f;
    }
    default:
        return 0.0f;
    }
}

int16_t WASAPICapture::FloatToPcm16(float value) {
    const float clipped = std::clamp(value, -1.0f, 1.0f);
    return static_cast<int16_t>(std::lrintf(clipped * 32767.0f));
}
