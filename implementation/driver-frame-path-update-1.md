# DirectShow Virtual Camera Filter — Implementation Reference

Source: Previous iteration (`docs/implementation_plan.md`, `docs/tasks.md`,
`docs/requirements.md`, `docs/project-proposal.md`, `docs/tasks_done.txt`)

This file captures all DirectShow-specific knowledge from the v1 iteration.
It is **reference material** for the current v2 project, not an active task list.
The current frame path (v2) bypasses this layer — frames go directly to the
avshws kernel driver via `DriverBridge`. However, v1's DirectShow filter
(`vcam_filter.dll`) is a useful fallback for Win10 apps that cannot use the
kernel driver.

---

## Architecture

DirectShow virtual camera = COM DLL registered under `CLSID_VideoInputCategory`.
Frame transport = shared memory (`CreateFileMapping(INVALID_HANDLE_VALUE, ...)`) +
named Event (`VirtuaCam_FrameEvent_0`) for notification.

```
Capture Engine
    → IpcSender::SendFrame()
        → writes to named shared mem (VirtuaCam_SharedMem_0)
        → SetEvent(VirtuaCam_FrameEvent_0)
            → IpcReceiver::WaitForFrame() [in DirectShow filter thread]
                → copies frame into IMediaSample buffer
                → returns from FillBuffer()
                    → DirectShow graph delivers frame to consumer
```

### Shared Memory Layout

```
[0  – 63 bytes]  Header struct:
                   DWORD magic       (validation)
                   DWORD version
                   DWORD width
                   DWORD height
                   DWORD pixelFormat (PixelFormat enum)
                   DWORD stride
                   DWORD frameCounter
                   DWORD dataOffset  (= 64)
[64 – MAX_FRAME]  Raw pixel data
```

Named objects:
- Mapping: `VirtuaCam_SharedMem_0`
- Event:   `VirtuaCam_FrameEvent_0`
- Multiple instances: suffix `_1`, `_2`, etc.

---

## IPC Layer

### IpcSender

```cpp
class IpcSender {
public:
    bool Create(int width, int height, PixelFormat format);
    bool SendFrame(const uint8_t* data, size_t dataSize);
    void Destroy();
private:
    HANDLE m_sharedMemHandle;
    HANDLE m_frameEventHandle;
    SharedMemHeader* m_sharedMemPtr;
};
```

- `Create()`: `CreateFileMapping(INVALID_HANDLE_VALUE, ...)` + `MapViewOfFile`
- `SendFrame()`: copy data, increment `frameCounter`, `SetEvent`
- Thread-safe: protect with `CRITICAL_SECTION` or `std::mutex`
- `Destroy()`: `UnmapViewOfFile` then `CloseHandle` (order matters)

### IpcReceiver

```cpp
class IpcReceiver {
public:
    bool Open();
    bool WaitForFrame(DWORD timeoutMs);
    FrameData GetFrameData();
    void Close();
};
```

- `Open()`: `OpenFileMapping(FILE_MAP_READ, FALSE, ...)` + `OpenEvent`
- `WaitForFrame()`: `WaitForSingleObject(event, timeout)` → `WAIT_OBJECT_0`
- Disconnect detection: if `OpenFileMapping` fails with `ERROR_FILE_NOT_FOUND`,
  sender has exited — show "No Signal" frame

---

## DirectShow Filter

### Classes

| Class | Base | File |
|-------|------|------|
| `CVCamFilter` | `CSource` | `src/filter/vcam_filter.cpp` |
| `CVCamStream` | `CSourceStream` | `src/filter/vcam_stream.cpp` |

### CVCamFilter

```cpp
class CVCamFilter : public CSource {
public:
    static CUnknown* WINAPI CreateInstance(LPUNKNOWN, HRESULT*);
    CVCamFilter(LPUNKNOWN punk, HRESULT* phr);
};
```

- Registers under `CLSID_VideoInputCategory`
- Sets `FriendlyName` = `"VirtuaCam"` via `IPropertyBag`
- Merit: `MERIT_DO_NOT_USE + 1`
- Filter category: `CLSID_VideoInputCategory`

### CVCamStream::GetMediaType()

Advertise at minimum:

| Format | Resolutions | FPS options |
|--------|-------------|-------------|
| YUY2   | 640×480, 1280×720, 1920×1080 | 15, 30, 60 |
| RGB24  | 640×480, 1280×720, 1920×1080 | 15, 30, 60 |

`AvgTimePerFrame` in `VIDEOINFOHEADER` = `10000000 / fps`
(units: 100-nanosecond intervals)

### CVCamStream::FillBuffer()

```cpp
HRESULT CVCamStream::FillBuffer(IMediaSample* pSample) {
    // 1. Open IpcReceiver if not already open
    // 2. WaitForFrame(timeout)  ← blocks here until frame or timeout
    // 3. Copy frame data to pSample buffer
    // 4. Set timestamps:
    REFERENCE_TIME rtStart = m_frameIndex * m_avgTimePerFrame;
    REFERENCE_TIME rtEnd   = rtStart + m_avgTimePerFrame;
    pSample->SetTime(&rtStart, &rtEnd);
    m_frameIndex++;
    // 5. Return S_OK
}
```

**Critical rules (learned from v1 bugs):**
- **Never self-time inside FillBuffer** (no `Sleep`, no spin). Timestamps on
  media samples control frame rate. The renderer drives timing.
- **Never connect a Null Renderer** in the DirectShow graph. Doing so causes
  a single-frame freeze bug (OBS GitHub #8057).
- If sender disconnects: deliver a branded "No Signal" slate frame, keep
  returning `S_OK` — do not return an error code.

### Registration

```cpp
// vcam_register.cpp
STDAPI DllRegisterServer()   { return AMovieDllRegisterServer2(TRUE); }
STDAPI DllUnregisterServer() { return AMovieDllRegisterServer2(FALSE); }
STDAPI DllGetClassObject(...)
STDAPI DllCanUnloadNow()
```

DEF file exports:
```
EXPORTS
    DllGetClassObject   PRIVATE
    DllCanUnloadNow     PRIVATE
    DllRegisterServer   PRIVATE
    DllUnregisterServer PRIVATE
```

Registration command:
```cmd
regsvr32 /s VirtuaCam_x64.dll
regsvr32 /s VirtuaCam_x86.dll
```

Unregistration:
```cmd
regsvr32 /u /s VirtuaCam_x64.dll
regsvr32 /u /s VirtuaCam_x86.dll
```

---

## Build Configuration (CMake)

```cmake
# Filter DLL target
add_library(VirtuaCam_x64 SHARED
    src/filter/vcam_filter.cpp
    src/filter/vcam_stream.cpp
    src/filter/vcam_register.cpp
    src/filter/vcam_filter.def   # <- required for clean COM exports
)
target_link_libraries(VirtuaCam_x64
    baseclasses           # vendored DirectShow BaseClasses
    VirtuaCam_common      # IPC layer
    strmiids.lib winmm.lib ole32.lib oleaut32.lib uuid.lib
)
# Build both x64 AND Win32 (separate CMake configure passes)
```

**Vendored BaseClasses**: download from
[Windows-classic-samples](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/Win7Samples/multimedia/directshow/baseclasses).
Build as a static library. Required for `CSource`, `CSourceStream`, `CBasePin`.

---

## Pixel Format Gotchas

| Situation | Issue | Fix |
|-----------|-------|-----|
| OpenCV DirectShow backend | Fails silently on NV12 | Advertise YUY2 + RGB24 only |
| Single-frame freeze | Null Renderer connected | Remove Null Renderer from graph |
| FillBuffer jitter | Self-timing inside FillBuffer | Timestamp samples, don't sleep |
| 32-bit apps can't see camera | Only x64 DLL registered | Register both x64 + x86 DLL |
| Camera shows as CLSID in UI | FriendlyName not set | Set via `IPropertyBag` |
| WPF transparent window → black | PrintWindow limitation | No GDI fix; use WGC fallback |

---

## Capture Engine (v1 — IPC-based)

Source lives in `src/capture/`. Fallback chain per frame:

```
PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT | PW_CLIENTONLY)  [flags = 0x3]
    if non-black → use it
    if black     → fall through
Windows Graphics Capture (WGC) via Direct3D11CaptureFramePool::CreateFreeThreaded
    OS build >= 17763 required
    Win11: call item.IsBorderRequired(false) to suppress yellow border
    /DELAYLOAD:CoreMessaging.dll required for safe load on Win10
    if failure → fall through
BitBlt (GetDC + BitBlt) — last resort for classic Win32 windows
```

**Chromium / Electron capture**: call `PrintWindow(topLevelHwnd, hdc, 0x3)` on
the **top-level** HWND (not child GPU-process HWND). DWM composites everything.
WGC targeting top-level HWND is also reliable and faster.

**WPF `AllowsTransparency=True`**: PrintWindow returns black.
No pure-GDI fix. WGC handles this.

**WGC DispatcherQueue crash**: use `CreateFreeThreaded` variant of
`Direct3D11CaptureFramePool`. Never use `Create` on a non-UI thread.

---

## Performance Targets (v1)

| Metric | Target |
|--------|--------|
| Capture-to-display latency | ≤ 50ms @ 30fps |
| CPU usage | ≤ 5% @ 1080p30 |
| Memory | ≤ 100MB (app + capture) |
| Frame rate accuracy | ±2fps of target |

---

## Compatibility Matrix

| Application | Works with DS filter? | Notes |
|-------------|----------------------|-------|
| Zoom (64-bit) | YES | x64 DLL |
| Teams | YES | x64 DLL |
| Discord | YES | x64 DLL |
| OBS Studio | YES | x64 DLL |
| 32-bit Python OpenCV | YES | x86 DLL required |
| Google Meet (Chrome) | YES | x64 DLL |
| Media Foundation apps (some Teams) | NO on Win10 | Win11 MF path needed |

---

## Build Order

1. `external/baseclasses` (static lib)
2. `src/common` (IPC layer — static lib)
3. `src/capture` (capture engine — static lib)
4. `src/filter` (DirectShow DLL — x64 + x86)
5. `src/app` (control application)

---

## Testing Notes from v1

- IPC layer: test sender→receiver round-trip data integrity and event signaling
- Filter registration: enumerate `CLSID_VideoInputCategory` via `ICreateDevEnum`
  and confirm "VirtuaCam" appears
- Frame delivery: open Zoom, select VirtuaCam, verify continuous video (not frozen)
- Bitness: test x86 DLL with 32-bit Python `cv2.VideoCapture`
- Stress: run at 1080p60 for 10 minutes, check for memory leaks
