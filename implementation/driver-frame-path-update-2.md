# MediaFoundation Virtual Camera — Implementation Reference

Source: `docs/kernel-driver/design.md`, `docs/kernel-driver/requirements.md`,
`docs/kernel-driver/tasks.md`, `docs/project-proposal.md`,
`docs/misc/Task5_Implementation_Summary.md`, `docs/misc/FIXES_SUMMARY.md`,
`docs/misc/CRITICAL_BSOD_FIXES_SUMMARY.md`, `docs/misc/PERFORMANCE_AUDIT_REPORT.md`,
`docs/misc/TASK4_COMPLETION_REPORT.md`, `docs/misc/FINAL_DRIVER_TEST_INSTRUCTIONS.md`,
`docs/misc/DRIVER_INSTALLATION_INSTRUCTIONS.md`

This file captures all MediaFoundation / AVStream kernel-driver knowledge from
the v1 iteration. This is **reference material** — the v2 project uses the
avshws kernel driver as the primary output path. The MF virtual camera
(`MFCreateVirtualCamera`) is the Win11-only alternative that makes a camera
visible to DirectShow, MF, and WinRT simultaneously without a kernel driver.
The AVStream driver path achieves the same breadth of compatibility while
targeting Win10+.

---

## Background: Why AVStream Instead of MFCreateVirtualCamera

| Feature | MFCreateVirtualCamera | AVStream Driver |
|---------|----------------------|-----------------|
| OS support | Win11 only | Win10 build 17763+ |
| Visible to DirectShow | YES (via Frame Server) | YES |
| Visible to Media Foundation | YES | YES |
| Visible to WinRT | YES | YES |
| Appears in Device Manager | NO | YES |
| Driver signing required | NO | YES (test-signing or WHQL) |
| Complexity | Medium | High |

**Decision (from docs/project-proposal.md):**
- Win10 target → DirectShow DLL baseline
- Win11 exclusive → `MFCreateVirtualCamera`
- Broad coverage (Win10+) → AVStream kernel driver (`VirtuaCam.sys` / `avshws.sys`)

---

## AVStream Driver Architecture

### System Diagram

```
User Mode
├── Capture Application
│   └── CaptureEngine (WGC / PrintWindow / BitBlt)
│       └── IpcSender
│           ├── SharedMemory → DirectShow Filter (vcam_filter.dll)
│           └── KS Property → AVStream Driver (VirtuaCam.sys)
└── Camera Applications
    ├── DirectShow app → vcam_filter.dll
    ├── Media Foundation app → Frame Server → AVStream Driver
    └── WinRT app → Frame Server → AVStream Driver

Kernel Mode
└── AVStream Driver (VirtuaCam.sys)
    ├── KSFILTER
    └── KSPIN (capture, output)
        └── Frame Buffer (thread-safe)

Windows Subsystems
├── Frame Server (Win11 MF integration)
└── Device Manager (camera enumeration)
```

### Driver Component Map

```
VirtuaCam.sys (AVStream Kernel Driver)
├── driver_entry.cpp     — DriverEntry, KsInitializeDriver, filter factory
├── filter.cpp           — KSFILTER descriptor, dispatch table, creation/destruction
├── pin_simple.cpp       — KSPIN descriptor, process dispatch, state transitions
├── property.cpp         — Frame injection KS property handler
├── logging.cpp          — DbgPrint macros (ERROR / INFO / DEBUG levels)
└── VirtuaCam.inf        — INF file for device class registration
```

---

## Custom KS Property for Frame Injection

### Property Set GUID

```cpp
// {CB043957-7B35-456E-9B61-5513930F4D8E}
DEFINE_KSPROPSETID_VirtuaCam_Control =
  {0xCB043957, 0x7B35, 0x456E, {0x9B, 0x61, 0x55, 0x13, 0x93, 0x0F, 0x4D, 0x8E}};

#define KSPROPERTY_VirtuaCam_FRAME_INJECT  0
```

### Frame Data Structure

```cpp
typedef struct {
    ULONG Width;
    ULONG Height;
    ULONG Format;    // PixelFormat enum: 0=RGB24, 1=YUY2
    ULONG Stride;
    ULONG DataSize;
    UCHAR Data[1];   // variable-length frame data
} VirtuaCam_FRAME_DATA, *PVirtuaCam_FRAME_DATA;
```

### Frame Injection from User-Mode (IpcSender)

```cpp
bool IpcSender::SendFrameToDriver(const uint8_t* data, size_t dataSize) {
    size_t totalSize = sizeof(VirtuaCam_FRAME_DATA) + dataSize;
    PVirtuaCam_FRAME_DATA frameData = (PVirtuaCam_FRAME_DATA)m_sendBuffer.data();
    // ↑ Pre-allocated in constructor — never malloc per-frame!

    frameData->Width    = m_width;
    frameData->Height   = m_height;
    frameData->Format   = static_cast<ULONG>(m_format);
    frameData->Stride   = CalculateStride(m_width, m_format);
    frameData->DataSize = static_cast<ULONG>(dataSize);
    memcpy(frameData->Data, data, dataSize);

    KSPROPERTY property = {};
    property.Set   = KSPROPSETID_VirtuaCam_Control;
    property.Id    = KSPROPERTY_VirtuaCam_FRAME_INJECT;
    property.Flags = KSPROPERTY_TYPE_SET;

    DWORD bytesReturned;
    return DeviceIoControl(
        m_driverHandle,
        IOCTL_KS_PROPERTY,
        &property, sizeof(property),
        frameData, static_cast<DWORD>(totalSize),
        &bytesReturned, NULL
    ) != FALSE;
}
```

### Device Handle Acquisition

```cpp
bool IpcSender::InitializeDriverInterface() {
    HDEVINFO deviceInfoSet = SetupDiGetClassDevs(
        &KSCATEGORY_VIDEO_CAMERA, NULL, NULL,
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE
    );
    // Enumerate, match friendly name, open with:
    m_driverHandle = CreateFile(
        devicePath,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL
    );
    // If driver not found: set m_driverAvailable = false
    // Fall back to shared-memory-only path (DirectShow filter still works)
}
```

---

## Kernel-Mode Frame Handler

### Frame Injection Property Handler

```cpp
NTSTATUS VirtuaCamFrameInjectHandler(
    _In_ PIRP Irp,
    _In_ PKSPROPERTY Property,
    _Inout_ PVOID Data
) {
    if (Property->Flags & KSPROPERTY_TYPE_SET) {
        PVirtuaCam_FRAME_DATA frameData = (PVirtuaCam_FRAME_DATA)Data;
        if (!ValidateFrameData(frameData))
            return STATUS_INVALID_PARAMETER;

        // *** PRE-ALLOCATE outside spinlock (BSOD fix) ***
        PVOID tempBuffer = ExAllocatePoolWithTag(
            NonPagedPoolNx, frameData->DataSize, 'maCi'
        );
        if (!tempBuffer) return STATUS_INSUFFICIENT_RESOURCES;

        RtlCopyMemory(tempBuffer, frameData->Data, frameData->DataSize);

        KIRQL oldIrql;
        KeAcquireSpinLock(&filterContext->FrameBufferLock, &oldIrql);
        PVOID oldBuffer = filterContext->FrameBuffer;
        filterContext->FrameBuffer = tempBuffer;
        filterContext->FrameSize   = frameData->DataSize;
        KeReleaseSpinLock(&filterContext->FrameBufferLock, oldIrql);

        if (oldBuffer) ExFreePoolWithTag(oldBuffer, 'maCi');

        KeSetEvent(&filterContext->FrameAvailableEvent, 0, FALSE);
    }
    return STATUS_SUCCESS;
}
```

> [!CAUTION]
> **BSOD FIX**: Never call `ExAllocatePoolWithTag` while holding a spinlock.
> At DISPATCH_LEVEL, paged operations cause `IRQL_NOT_LESS_OR_EQUAL`.
> Pre-allocate the buffer BEFORE acquiring the spinlock, then swap pointers
> inside the lock. This was the primary BSOD root cause in v1.

### Pin Process Dispatch

```cpp
NTSTATUS VirtuaCamPinProcess(_In_ PKSPIN Pin) {
    PKSSTREAM_POINTER sp = KsPinGetLeadingEdgeStreamPointer(
        Pin, KSSTREAM_POINTER_STATE_LOCKED
    );
    if (!sp) return STATUS_DEVICE_NOT_READY;

    PUCHAR outputBuffer = (PUCHAR)sp->StreamHeader->Data;

    // *** IRQL-SAFE buffer validation (BSOD fix) ***
    // ProbeForWrite requires PASSIVE_LEVEL — NEVER call at DISPATCH_LEVEL
    // Use MmIsAddressValid() instead:
    if (!MmIsAddressValid(outputBuffer)) {
        KsStreamPointerAdvanceOffsetsAndUnlock(sp, 0, 0, TRUE);
        return STATUS_INVALID_ADDRESS;
    }

    __try {
        if (IsFrameAvailable(pinContext)) {
            CopyFrameData(pinContext, outputBuffer, frameSize);
            sp->StreamHeader->DataUsed = frameSize;
            sp->StreamHeader->PresentationTime.Time = GetCurrentFrameTime();
        } else {
            GenerateNoSignalFrame(sp, pinContext);
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        // Safe cleanup even in exception path
        KsStreamPointerAdvanceOffsetsAndUnlock(sp, 0, 0, TRUE);
        return GetExceptionCode();
    }

    KsStreamPointerAdvanceOffsetsAndUnlock(
        sp, 0, sp->StreamHeader->DataUsed, TRUE
    );
    return STATUS_SUCCESS;
}
```

> [!CAUTION]
> **BSOD FIX**: `ProbeForWrite()` called at `DISPATCH_LEVEL` IRQL causes
> `IRQL_NOT_LESS_OR_EQUAL`. Replace with `MmIsAddressValid()` which is
> safe at any IRQL. Wrap all memory ops in `__try/__except`.

---

## State Machine

```
KSSTATE_STOP
    → KSSTATE_ACQUIRE  (allocate frame buffer via ExAllocatePoolWithTag NonPagedPoolNx)
    → KSSTATE_PAUSE    (buffers ready, not running)
    → KSSTATE_RUN      (set IsRunning=TRUE, start delivering frames)
    ← KSSTATE_PAUSE    (set IsRunning=FALSE)
    ← KSSTATE_ACQUIRE  (keep buffers)
    ← KSSTATE_STOP     (free frame buffer, clear event)
```

```cpp
NTSTATUS VirtuaCamPinSetState(PKSPIN Pin, KSSTATE ToState, KSSTATE FromState) {
    switch (ToState) {
    case KSSTATE_STOP:
        pinContext->IsRunning = FALSE;
        KeClearEvent(&pinContext->FrameAvailableEvent);
        if (pinContext->FrameBuffer) {
            ExFreePoolWithTag(pinContext->FrameBuffer, 'maCi');
            pinContext->FrameBuffer = NULL;
        }
        break;
    case KSSTATE_ACQUIRE:
        return InitializeFrameBuffer(pinContext);
    case KSSTATE_PAUSE:
        pinContext->IsRunning = FALSE;
        break;
    case KSSTATE_RUN:
        pinContext->IsRunning = TRUE;
        break;
    }
    return STATUS_SUCCESS;
}
```

---

## Media Types Advertised

| Format | Resolutions | FPS |
|--------|-------------|-----|
| YUY2   | 640×480, 1280×720, 1920×1080 | 15, 30, 60 |
| RGB24  | 640×480, 1280×720, 1920×1080 | 15, 30, 60 |

`KSDATARANGE_VIDEO` entries for each combination.

---

## INF File

```ini
[Version]
Signature="$WINDOWS NT$"
Class=Camera
ClassGuid={ca3e7ab9-b4c3-4ae6-8251-579ef933890f}
Provider=%ManufacturerName%
CatalogFile=VirtuaCam.cat

[Manufacturer]
%ManufacturerName%=Standard,NTamd64.10.0...17763

[Standard.NTamd64.10.0...17763]
%VirtuaCam.DeviceDesc%=VirtuaCam_Device, root\VirtuaCamVirtualCamera

[VirtuaCam_Device.NT.Services]
AddService = VirtuaCamDriver,%SPSVCINST_ASSOCSERVICE%, VirtuaCam_Service_Inst

[VirtuaCam_Service_Inst]
ServiceType  = 1   ; SERVICE_KERNEL_DRIVER
StartType    = 3   ; SERVICE_DEMAND_START
ErrorControl = 1   ; SERVICE_ERROR_NORMAL

[VirtuaCam_Device.NT.Interfaces]
AddInterface = %KSCATEGORY_VIDEO_CAMERA%, %KSNAME_Filter%, VirtuaCam.Interface

[VirtuaCam.Interface.AddReg]
HKR,,CLSID,,%ProxyVCap.CLSID%
HKR,,FriendlyName,,%VirtuaCam.FriendlyName%

[Strings]
KSCATEGORY_VIDEO_CAMERA="{E5323777-F976-4f5b-9B55-B94699C46E44}"
ProxyVCap.CLSID="{17CCA71B-ECD7-11D0-B908-00A0C9223196}"
```

---

## Installation

### Prerequisites

- WDK 10.0.22621+ (or 10.0.17763+ minimum)
- Visual Studio 2022 with C++ Desktop + WDK extension
- TESTSIGNING enabled (required for self-signed .sys):
  ```cmd
  bcdedit /set testsigning on
  # restart required
  ```
- Secure Boot **disabled** in BIOS/UEFI (required for test-signed drivers)

### Install

```cmd
# As Administrator:
pnputil /add-driver "build\driver_package\VirtuaCam.inf" /install
```

### Verify

```cmd
pnputil /enum-drivers | findstr VirtuaCam
pnputil /enum-devices /class Camera
powershell "Get-PnpDevice -Class Camera"
devmgmt.msc  # look under Cameras > VirtuaCam Virtual Camera
```

### Uninstall

```cmd
pnputil /delete-driver VirtuaCam.inf /uninstall /force
```

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `0xC0000263` STATUS_DRIVER_ENTRYPOINT_NOT_FOUND | Wrong toolset / missing WDK lib | Retarget .vcxproj to `WindowsKernelModeDriver10.0`, link `ks.lib ksguid.lib` |
| "Test signing is not enabled" | TESTSIGNING off | `bcdedit /set testsigning on` + restart |
| "Access denied" during install | Not admin | Run as Administrator |
| Driver with yellow bang in Device Manager | Code 52 / unsigned driver | Must sign with `signtool`; verify test cert imported |
| Camera doesn't appear in apps | Driver stopped | Check service: `sc query VirtuaCamDriver` |
| BSOD `IRQL_NOT_LESS_OR_EQUAL` | ProbeForWrite at DISPATCH_LEVEL | Use MmIsAddressValid; pre-alloc outside spinlock |
| BSOD unpaged area | `ExAllocatePool2` deprecated | Use `ExAllocatePoolWithTag(NonPagedPoolNx, ...)` |

---

## Build System (CMake + WDK)

```cmake
find_path(WDK_ROOT NAMES "Include/wdf.h"
    PATHS "$ENV{WDK_DIR}" "$ENV{ProgramFiles(x86)}/Windows Kits/10")

if(NOT WDK_ROOT)
    message(WARNING "WDK not found. Driver target skipped.")
    return()
endif()

add_library(VirtuaCam_driver MODULE
    src/driver/driver_entry.cpp
    src/driver/filter.cpp
    src/driver/pin_simple.cpp
    src/driver/property.cpp
    src/driver/logging.cpp
)
set_target_properties(VirtuaCam_driver PROPERTIES
    SUFFIX ".sys"
    LINK_FLAGS "/DRIVER /SUBSYSTEM:NATIVE /ENTRY:DriverEntry"
)
target_include_directories(VirtuaCam_driver PRIVATE
    ${WDK_ROOT}/Include/10.0.17763.0/km
    ${WDK_ROOT}/Include/10.0.17763.0/shared
)
target_link_libraries(VirtuaCam_driver
    ${WDK_ROOT}/Lib/10.0.17763.0/km/x64/ks.lib
    ${WDK_ROOT}/Lib/10.0.17763.0/km/x64/ksguid.lib
    ${WDK_ROOT}/Lib/10.0.17763.0/km/x64/ntoskrnl.lib
)
```

### Signing (test cert)

```cmake
add_custom_command(TARGET VirtuaCam_driver POST_BUILD
    COMMAND makecert -r -pe -ss PrivateCertStore
            -n "CN=VirtuaCam Test Certificate" TestCert.cer
    COMMAND signtool sign /v /s PrivateCertStore
            /n "VirtuaCam Test Certificate" $<TARGET_FILE:VirtuaCam_driver>
)
```

---

## Logging Macros

```cpp
#define VirtuaCam_LOG_ERROR(fmt, ...) \
    DbgPrintEx(DPFLTR_IHVVIDEO_ID, DPFLTR_ERROR_LEVEL, \
               "[VirtuaCam] ERROR: " fmt "\n", __VA_ARGS__)

#define VirtuaCam_LOG_INFO(fmt, ...) \
    DbgPrintEx(DPFLTR_IHVVIDEO_ID, DPFLTR_INFO_LEVEL, \
               "[VirtuaCam] INFO: " fmt "\n", __VA_ARGS__)

#ifdef DBG
#define VirtuaCam_LOG_DEBUG(fmt, ...) \
    DbgPrintEx(DPFLTR_IHVVIDEO_ID, DPFLTR_TRACE_LEVEL, \
               "[VirtuaCam] DEBUG: " fmt "\n", __VA_ARGS__)
#else
#define VirtuaCam_LOG_DEBUG(fmt, ...)
#endif
```

Use WinDbg or DebugView (DbgView.exe) to see output.

---

## Security: Input Validation

```cpp
NTSTATUS ValidateFrameData(PVirtuaCam_FRAME_DATA frameData) {
    if (!frameData)                          return STATUS_INVALID_PARAMETER;
    if (frameData->Width  == 0 || frameData->Width  > 1920)
                                             return STATUS_INVALID_PARAMETER;
    if (frameData->Height == 0 || frameData->Height > 1080)
                                             return STATUS_INVALID_PARAMETER;
    if (frameData->Format != PIXEL_FORMAT_YUY2 &&
        frameData->Format != PIXEL_FORMAT_RGB24)
                                             return STATUS_INVALID_PARAMETER;
    ULONG expected = CalculateExpectedFrameSize(
        frameData->Width, frameData->Height, frameData->Format);
    if (frameData->DataSize != expected)     return STATUS_INVALID_PARAMETER;
    // MAX_FRAME_SIZE: 4MB cap (not 8MB!) to prevent non-paged pool exhaustion
    if (frameData->DataSize > 4 * 1024 * 1024)
                                             return STATUS_INVALID_PARAMETER;
    return STATUS_SUCCESS;
}
```

> [!WARNING]
> Do NOT use `MAX_FRAME_SIZE = 8MB`. A single malicious IOCTL at 8MB could
> exhaust non-paged pool. Cap at 4MB (covers 1920×1080 RGB24 ≈ 6MB, so cap
> should be at least 6MB for 1080p RGB24 — use progressive limits:
> 2MB for 720p, 6MB for 1080p, reject above).

---

## Performance Findings from v1 Audit

| Finding | Severity | Fix |
|---------|----------|-----|
| `ExAllocatePool2` deprecated → BSOD on newer Windows | CRITICAL | `ExAllocatePoolWithTag(NonPagedPoolNx, ...)` |
| `ExAllocatePoolWithTag` inside spinlock | HIGH | Pre-allocate outside spinlock, swap pointers inside |
| Frame buffer realloc on every resolution change | HIGH | Lookaside list: `ExInitializeNPagedLookasideList` for 640p/720p/1080p sizes |
| Per-frame malloc/free in user-mode IpcSender | CRITICAL | Pre-alloc max-size buffer in constructor, reuse |
| Spinlock in hot path for read-only check | HIGH | `InterlockedCompareExchange` on `FrameAvailable` flag |
| malloc without free on all paths in device enum | MEDIUM | RAII wrapper or ensure `free(detailData)` on all exit paths |
| `METHOD_BUFFERED` for large frame IOCTL (double-copy) | HIGH | Switch to `METHOD_IN_DIRECT` to use MDL, eliminate kernel buffer copy |
| Test pattern frame regenerated every call | HIGH | Generate once at `KSSTATE_ACQUIRE`, cache in pin context |
| Sleep-based polling in capture thread | MEDIUM | `SetWaitableTimer` for precise frame intervals |
| Exception handler may not restore IRQL under spinlock | CRITICAL | `__try/__finally` to ensure IRQL restoration |

**Expected improvement after fixes:** 60–80% CPU reduction, 50% memory
bandwidth reduction, elimination of BSOD risk.

### Implementation Priority

1. **Immediate** (low risk, high impact): pool API modernization, buffer pre-alloc,
   malloc leak fix, window data leak fix
2. **Phase 1** (medium risk, high impact): IOCTL method change to IN_DIRECT,
   spinlock duration reduction
3. **Phase 2** (medium risk): lookaside lists, exception handling under spinlock
4. **Phase 3** (lower risk): frame availability check lock-free, test pattern caching,
   waitable timer, MAX_FRAME_SIZE cap

---

## MFCreateVirtualCamera (Win11-only path)

If targeting Windows 11 exclusively, `MFCreateVirtualCamera` is simpler than
an AVStream driver and achieves the same API-wide visibility via the Frame Server:

```cpp
// Win11 only (IsWindows11OrGreater())
IMFVirtualCamera* vcam;
MFCreateVirtualCamera(
    MFVirtualCameraType_SoftwareCameraSource,
    MFVirtualCameraLifetime_Session,
    MFVirtualCameraAccess_CurrentUser,
    L"VirtuaCam",
    nullptr, nullptr, 0,
    &vcam
);
vcam->AddMediaSource(myMediaSource, nullptr);
vcam->Start(nullptr);
```

The `myMediaSource` must implement `IMFMediaSource` + `IMFMediaSourceEx`.
Frames are pulled from this source by the Frame Server and distributed to all
consumers (DirectShow, MF, WinRT) simultaneously.

**Recommendation**: Implement DirectShow DLL for Win10 baseline.
On Win11 (`IsWindows11OrGreater()`), prefer AVStream driver or MFCreateVirtualCamera.
Current v2 uses AVStream driver (avshws) for Win10+ coverage.

---

## Coexistence: AVStream Driver + DirectShow Filter

When both are installed:
- Two separate camera devices appear in Device Manager / camera pickers
- `"VirtuaCam Virtual Camera"` → AVStream driver (all APIs)
- `"VirtuaCam"` → DirectShow filter (DS only)
- IpcSender sends frames to **both** simultaneously via dual-mode operation
- Graceful fallback: if driver absent, shared-memory path still feeds DS filter

```cpp
bool IpcSender::SendFrame(const uint8_t* data, size_t dataSize) {
    bool ok = SendFrameToSharedMemory(data, dataSize); // for DS filter
    if (m_driverAvailable)
        ok |= SendFrameToDriver(data, dataSize);       // for AVStream driver
    return ok;
}
```
