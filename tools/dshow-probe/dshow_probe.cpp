#include <windows.h>
#include <dshow.h>
#include <dvdmedia.h>
#include <string>
#include <vector>
#include <iostream>
#include <iomanip>
#include <sstream>

#pragma comment(lib, "strmiids.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

static const GUID kMediaSubtypeI420 =
{ 0x30323449, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 } };
static const GUID kClsidNullRenderer =
{ 0xC1F400A4, 0x3F08, 0x11d3, { 0x9F, 0x0B, 0x00, 0x60, 0x08, 0x03, 0x9E, 0x37 } };

template <typename T>
void SafeRelease(T** value) {
    if (value && *value) {
        (*value)->Release();
        *value = nullptr;
    }
}

struct ScopedCoInit {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~ScopedCoInit() {
        if (SUCCEEDED(hr)) {
            CoUninitialize();
        }
    }
};

static std::wstring GuidToString(REFGUID guid) {
    LPOLESTR text = nullptr;
    if (FAILED(StringFromCLSID(guid, &text))) {
        return L"{guid}";
    }
    std::wstring value(text);
    CoTaskMemFree(text);
    return value;
}

static std::wstring MediaSubtypeToString(const GUID& guid) {
    if (guid == MEDIASUBTYPE_RGB24) return L"MEDIASUBTYPE_RGB24";
    if (guid == MEDIASUBTYPE_YUY2) return L"MEDIASUBTYPE_YUY2";
    if (guid == MEDIASUBTYPE_UYVY) return L"MEDIASUBTYPE_UYVY";
    if (guid == MEDIASUBTYPE_NV12) return L"MEDIASUBTYPE_NV12";
    if (guid == kMediaSubtypeI420) return L"MEDIASUBTYPE_I420";
    return GuidToString(guid);
}

static std::wstring FourCcToString(DWORD fourcc) {
    wchar_t text[5] = {};
    text[0] = static_cast<wchar_t>(fourcc & 0xFF);
    text[1] = static_cast<wchar_t>((fourcc >> 8) & 0xFF);
    text[2] = static_cast<wchar_t>((fourcc >> 16) & 0xFF);
    text[3] = static_cast<wchar_t>((fourcc >> 24) & 0xFF);
    for (int i = 0; i < 4; ++i) {
        if (text[i] == 0) {
            text[i] = L' ';
        }
    }
    return std::wstring(text, 4);
}

static void FreeMediaType(AM_MEDIA_TYPE& mt) {
    if (mt.cbFormat != 0) {
        CoTaskMemFree(mt.pbFormat);
        mt.cbFormat = 0;
        mt.pbFormat = nullptr;
    }
    if (mt.pUnk != nullptr) {
        mt.pUnk->Release();
        mt.pUnk = nullptr;
    }
}

static std::wstring GetFriendlyName(IMoniker* moniker) {
    IPropertyBag* bag = nullptr;
    VARIANT value;
    VariantInit(&value);
    std::wstring name;

    if (SUCCEEDED(moniker->BindToStorage(nullptr, nullptr, IID_IPropertyBag, reinterpret_cast<void**>(&bag)))) {
        if (SUCCEEDED(bag->Read(L"FriendlyName", &value, nullptr)) && value.vt == VT_BSTR) {
            name = value.bstrVal;
        }
    }

    VariantClear(&value);
    SafeRelease(&bag);
    return name;
}

static HRESULT FindSourceFilter(const std::wstring& friendlyName, IBaseFilter** filterOut, std::wstring* resolvedName) {
    if (!filterOut) {
        return E_POINTER;
    }
    *filterOut = nullptr;

    ICreateDevEnum* devEnum = nullptr;
    IEnumMoniker* enumMoniker = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_SystemDeviceEnum, nullptr, CLSCTX_INPROC_SERVER,
        IID_ICreateDevEnum, reinterpret_cast<void**>(&devEnum));
    if (FAILED(hr)) {
        return hr;
    }

    hr = devEnum->CreateClassEnumerator(CLSID_VideoInputDeviceCategory, &enumMoniker, 0);
    if (hr != S_OK) {
        SafeRelease(&devEnum);
        return hr == S_FALSE ? HRESULT_FROM_WIN32(ERROR_NOT_FOUND) : hr;
    }

    IMoniker* moniker = nullptr;
    while (enumMoniker->Next(1, &moniker, nullptr) == S_OK) {
        std::wstring name = GetFriendlyName(moniker);
        if (_wcsicmp(name.c_str(), friendlyName.c_str()) == 0) {
            hr = moniker->BindToObject(nullptr, nullptr, IID_IBaseFilter, reinterpret_cast<void**>(filterOut));
            if (SUCCEEDED(hr) && resolvedName) {
                *resolvedName = name;
            }
            moniker->Release();
            break;
        }
        moniker->Release();
        moniker = nullptr;
    }

    SafeRelease(&enumMoniker);
    SafeRelease(&devEnum);
    return *filterOut ? S_OK : HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

static HRESULT FindCapturePin(IBaseFilter* filter, IPin** pinOut) {
    if (!filter || !pinOut) {
        return E_POINTER;
    }
    *pinOut = nullptr;

    IEnumPins* enumPins = nullptr;
    HRESULT hr = filter->EnumPins(&enumPins);
    if (FAILED(hr)) {
        return hr;
    }

    IPin* pin = nullptr;
    while (enumPins->Next(1, &pin, nullptr) == S_OK) {
        PIN_DIRECTION dir = PINDIR_INPUT;
        if (SUCCEEDED(pin->QueryDirection(&dir)) && dir == PINDIR_OUTPUT) {
            IKsPropertySet* ksProps = nullptr;
            GUID category = GUID_NULL;
            DWORD returned = 0;
            if (SUCCEEDED(pin->QueryInterface(IID_IKsPropertySet, reinterpret_cast<void**>(&ksProps)))) {
                if (SUCCEEDED(ksProps->Get(AMPROPSETID_Pin, AMPROPERTY_PIN_CATEGORY, nullptr, 0, &category, sizeof(category), &returned)) &&
                    category == PIN_CATEGORY_CAPTURE) {
                    *pinOut = pin;
                    SafeRelease(&ksProps);
                    break;
                }
                SafeRelease(&ksProps);
            }
        }
        pin->Release();
        pin = nullptr;
    }

    SafeRelease(&enumPins);
    return *pinOut ? S_OK : HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

struct CapabilityInfo {
    LONG width = 0;
    LONG height = 0;
    LONG bitCount = 0;
    DWORD compression = 0;
    REFERENCE_TIME avgTimePerFrame = 0;
    GUID subtype = GUID_NULL;
};

static bool ExtractCapability(const AM_MEDIA_TYPE& mt, CapabilityInfo* info) {
    if (!info) {
        return false;
    }
    if (mt.formattype != FORMAT_VideoInfo || !mt.pbFormat || mt.cbFormat < sizeof(VIDEOINFOHEADER)) {
        return false;
    }

    const auto* vih = reinterpret_cast<const VIDEOINFOHEADER*>(mt.pbFormat);
    info->width = vih->bmiHeader.biWidth;
    info->height = vih->bmiHeader.biHeight;
    info->bitCount = vih->bmiHeader.biBitCount;
    info->compression = vih->bmiHeader.biCompression;
    info->avgTimePerFrame = vih->AvgTimePerFrame;
    info->subtype = mt.subtype;
    return true;
}

static HRESULT EnumerateCapabilities(IPin* pin, std::vector<CapabilityInfo>* capsOut) {
    if (!pin || !capsOut) {
        return E_POINTER;
    }

    IAMStreamConfig* config = nullptr;
    HRESULT hr = pin->QueryInterface(IID_IAMStreamConfig, reinterpret_cast<void**>(&config));
    if (FAILED(hr)) {
        return hr;
    }

    int count = 0;
    int size = 0;
    hr = config->GetNumberOfCapabilities(&count, &size);
    if (FAILED(hr)) {
        SafeRelease(&config);
        return hr;
    }

    std::vector<BYTE> capBytes(static_cast<size_t>(size), 0);
    for (int index = 0; index < count; ++index) {
        AM_MEDIA_TYPE* mt = nullptr;
        hr = config->GetStreamCaps(index, &mt, capBytes.data());
        if (FAILED(hr) || !mt) {
            continue;
        }

        CapabilityInfo info = {};
        if (ExtractCapability(*mt, &info)) {
            capsOut->push_back(info);
        }

        FreeMediaType(*mt);
        CoTaskMemFree(mt);
    }

    SafeRelease(&config);
    return S_OK;
}

static HRESULT ApplyCapability(IPin* pin, const CapabilityInfo& requested) {
    IAMStreamConfig* config = nullptr;
    HRESULT hr = pin->QueryInterface(IID_IAMStreamConfig, reinterpret_cast<void**>(&config));
    if (FAILED(hr)) {
        return hr;
    }

    int count = 0;
    int size = 0;
    hr = config->GetNumberOfCapabilities(&count, &size);
    if (FAILED(hr)) {
        SafeRelease(&config);
        return hr;
    }

    std::vector<BYTE> capBytes(static_cast<size_t>(size), 0);
    HRESULT result = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    for (int index = 0; index < count; ++index) {
        AM_MEDIA_TYPE* mt = nullptr;
        hr = config->GetStreamCaps(index, &mt, capBytes.data());
        if (FAILED(hr) || !mt) {
            continue;
        }

        CapabilityInfo info = {};
        bool match = ExtractCapability(*mt, &info) &&
            info.width == requested.width &&
            info.height == requested.height &&
            info.bitCount == requested.bitCount &&
            info.compression == requested.compression &&
            info.subtype == requested.subtype;

        if (match) {
            result = config->SetFormat(mt);
            FreeMediaType(*mt);
            CoTaskMemFree(mt);
            break;
        }

        FreeMediaType(*mt);
        CoTaskMemFree(mt);
    }

    SafeRelease(&config);
    return result;
}

static void PrintCapabilities(const std::vector<CapabilityInfo>& caps) {
    std::wcout << L"CapabilityCount: " << caps.size() << std::endl;
    for (size_t i = 0; i < caps.size(); ++i) {
        const auto& cap = caps[i];
        double fps = cap.avgTimePerFrame > 0 ? (10000000.0 / static_cast<double>(cap.avgTimePerFrame)) : 0.0;
        std::wcout
            << L"  [" << i << L"] "
            << cap.width << L"x" << cap.height
            << L" subtype=" << MediaSubtypeToString(cap.subtype)
            << L" bitCount=" << cap.bitCount
            << L" compression=" << FourCcToString(cap.compression)
            << L" fps=" << std::fixed << std::setprecision(3) << fps
            << std::endl;
    }
}

static void DrainGraphEvents(IMediaEventEx* mediaEvent) {
    if (!mediaEvent) {
        return;
    }

    long code = 0;
    LONG_PTR p1 = 0;
    LONG_PTR p2 = 0;
    while (SUCCEEDED(mediaEvent->GetEvent(&code, &p1, &p2, 0))) {
        std::wcout << L"Event: code=" << code << L" p1=0x" << std::hex << p1 << L" p2=0x" << p2 << std::dec << std::endl;
        mediaEvent->FreeEventParams(code, p1, p2);
    }
}

static HRESULT RunGraphProbe(const std::wstring& friendlyName, const CapabilityInfo* requestedCap) {
    IBaseFilter* source = nullptr;
    std::wstring resolvedName;
    HRESULT hr = FindSourceFilter(friendlyName, &source, &resolvedName);
    if (FAILED(hr)) {
        std::wcout << L"FindSourceFilter failed hr=0x" << std::hex << hr << std::dec << std::endl;
        return hr;
    }

    IPin* capturePin = nullptr;
    hr = FindCapturePin(source, &capturePin);
    if (FAILED(hr)) {
        std::wcout << L"FindCapturePin failed hr=0x" << std::hex << hr << std::dec << std::endl;
        SafeRelease(&source);
        return hr;
    }

    std::vector<CapabilityInfo> caps;
    hr = EnumerateCapabilities(capturePin, &caps);
    std::wcout << L"FriendlyName: " << resolvedName << std::endl;
    std::wcout << L"EnumerateCapabilities hr=0x" << std::hex << hr << std::dec << std::endl;
    PrintCapabilities(caps);

    if (requestedCap) {
        hr = ApplyCapability(capturePin, *requestedCap);
        std::wcout << L"SetFormat hr=0x" << std::hex << hr << std::dec
            << L" for subtype=" << MediaSubtypeToString(requestedCap->subtype) << std::endl;
    }

    IGraphBuilder* graph = nullptr;
    ICaptureGraphBuilder2* graphBuilder = nullptr;
    IBaseFilter* nullRenderer = nullptr;
    IMediaControl* mediaControl = nullptr;
    IMediaEventEx* mediaEvent = nullptr;

    hr = CoCreateInstance(CLSID_FilterGraph, nullptr, CLSCTX_INPROC_SERVER,
        IID_IGraphBuilder, reinterpret_cast<void**>(&graph));
    if (FAILED(hr)) {
        std::wcout << L"CoCreateInstance(FilterGraph) failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = CoCreateInstance(CLSID_CaptureGraphBuilder2, nullptr, CLSCTX_INPROC_SERVER,
        IID_ICaptureGraphBuilder2, reinterpret_cast<void**>(&graphBuilder));
    if (FAILED(hr)) {
        std::wcout << L"CoCreateInstance(CaptureGraphBuilder2) failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = graphBuilder->SetFiltergraph(graph);
    if (FAILED(hr)) {
        std::wcout << L"SetFiltergraph failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = graph->AddFilter(source, L"VirtualCamSource");
    if (FAILED(hr)) {
        std::wcout << L"AddFilter(source) failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = CoCreateInstance(kClsidNullRenderer, nullptr, CLSCTX_INPROC_SERVER,
        IID_IBaseFilter, reinterpret_cast<void**>(&nullRenderer));
    if (FAILED(hr)) {
        std::wcout << L"CoCreateInstance(NullRenderer) failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = graph->AddFilter(nullRenderer, L"NullRenderer");
    if (FAILED(hr)) {
        std::wcout << L"AddFilter(nullRenderer) failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = graphBuilder->RenderStream(&PIN_CATEGORY_CAPTURE, &MEDIATYPE_Video, source, nullptr, nullRenderer);
    std::wcout << L"RenderStream hr=0x" << std::hex << hr << std::dec << std::endl;
    if (FAILED(hr)) {
        goto Exit;
    }

    hr = graph->QueryInterface(IID_IMediaControl, reinterpret_cast<void**>(&mediaControl));
    if (FAILED(hr)) {
        std::wcout << L"QueryInterface(IMediaControl) failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = graph->QueryInterface(IID_IMediaEventEx, reinterpret_cast<void**>(&mediaEvent));
    if (FAILED(hr)) {
        std::wcout << L"QueryInterface(IMediaEventEx) failed hr=0x" << std::hex << hr << std::dec << std::endl;
        goto Exit;
    }

    hr = mediaControl->Pause();
    std::wcout << L"Pause hr=0x" << std::hex << hr << std::dec << std::endl;
    DrainGraphEvents(mediaEvent);
    if (FAILED(hr)) {
        goto Exit;
    }

    hr = mediaControl->Run();
    std::wcout << L"Run hr=0x" << std::hex << hr << std::dec << std::endl;
    DrainGraphEvents(mediaEvent);
    if (SUCCEEDED(hr)) {
        OAFilterState state = State_Stopped;
        HRESULT stateHr = mediaControl->GetState(2000, &state);
        std::wcout << L"GetState hr=0x" << std::hex << stateHr << std::dec << L" state=" << state << std::endl;
        Sleep(1500);
        DrainGraphEvents(mediaEvent);
        HRESULT stopHr = mediaControl->Stop();
        std::wcout << L"Stop hr=0x" << std::hex << stopHr << std::dec << std::endl;
        DrainGraphEvents(mediaEvent);
    }

Exit:
    SafeRelease(&mediaEvent);
    SafeRelease(&mediaControl);
    if (graph) {
        graph->RemoveFilter(nullRenderer);
        graph->RemoveFilter(source);
    }
    SafeRelease(&nullRenderer);
    SafeRelease(&graphBuilder);
    SafeRelease(&graph);
    SafeRelease(&capturePin);
    SafeRelease(&source);
    return hr;
}

int wmain(int argc, wchar_t** argv) {
    std::wstring friendlyName = L"Virtual Camera Source";
    std::wstring mode = L"all";
    if (argc >= 2 && argv[1] && *argv[1]) {
        friendlyName = argv[1];
    }
    if (argc >= 3 && argv[2] && *argv[2]) {
        mode = argv[2];
    }

    ScopedCoInit coinit;
    if (FAILED(coinit.hr)) {
        std::wcerr << L"CoInitializeEx failed hr=0x" << std::hex << coinit.hr << std::dec << std::endl;
        return 1;
    }

    IBaseFilter* source = nullptr;
    std::wstring resolvedName;
    HRESULT hr = FindSourceFilter(friendlyName, &source, &resolvedName);
    if (FAILED(hr)) {
        std::wcerr << L"Could not find source filter '" << friendlyName << L"' hr=0x" << std::hex << hr << std::dec << std::endl;
        return 2;
    }

    IPin* pin = nullptr;
    hr = FindCapturePin(source, &pin);
    if (FAILED(hr)) {
        std::wcerr << L"Could not find capture pin hr=0x" << std::hex << hr << std::dec << std::endl;
        SafeRelease(&source);
        return 3;
    }

    std::vector<CapabilityInfo> caps;
    hr = EnumerateCapabilities(pin, &caps);
    std::wcout << L"FriendlyName: " << resolvedName << std::endl;
    std::wcout << L"EnumerateCapabilities hr=0x" << std::hex << hr << std::dec << std::endl;
    PrintCapabilities(caps);

    SafeRelease(&pin);
    SafeRelease(&source);

    if (mode == L"list") {
        return 0;
    }

    std::wcout << L"=== Probe: default graph ===" << std::endl;
    RunGraphProbe(friendlyName, nullptr);

    for (const auto& cap : caps) {
        if (mode == L"rgb24" && cap.subtype != MEDIASUBTYPE_RGB24) {
            continue;
        }
        if (mode == L"yuy2" && cap.subtype != MEDIASUBTYPE_YUY2) {
            continue;
        }
        std::wcout << L"=== Probe: explicit format " << MediaSubtypeToString(cap.subtype) << L" ===" << std::endl;
        RunGraphProbe(friendlyName, &cap);
    }

    return 0;
}
