# VirtuaCam — Driver/Software Coupling Workflow

> **Audience:** Coding agent with access to the full VirtuaCam repository.  
> **Goal:** Couple `avshws` (kernel driver) to `VirtuaCam.exe` (tray app) so that:
> - The driver outputs a default blue frame when no software client is connected.
> - `VirtuaCam.exe` auto-starts on login.
> - Opening the camera in any app (Teams, Zoom, OBS) auto-launches `VirtuaCam.exe` if not running.
> - Clean disconnect on software exit reverts the driver to the default frame without leaving a broken feed.

---

## Architecture Recap (as-is)

```
[Producer]
   └─> Shared D3D11 Texture + Fence
         └─> DirectPortBroker.dll   (composites on GPU)
               └─> DriverBridge.cpp  (IKsPropertySet wrapper)
                     └─> avshws.sys  (AVStream kernel driver)
                           └─> OS camera device (Teams, OBS, etc.)
```

**VirtuaCamProcess.exe** hosts the built-in producers (screen capture, camera passthrough) and feeds the shared D3D11 texture.  
**VirtuaCam.exe** is the tray controller that manages sources, layout, and preview.  
**DriverBridge.cpp** is the sole bridge between user-mode and the kernel driver, using `IKsPropertySet` on GUID `{CB043957-7B35-456E-9B61-5513930F4D8E}`, property ID `0`.

---

## What Needs to Change

| Layer | File(s) | Change |
|---|---|---|
| Kernel | `avshws` driver source | Default frame buffer, `ClientConnected` flag, new property IDs, named event, heartbeat timer |
| User-mode bridge | `DriverBridge.cpp` | `Connect()` and `Disconnect()` exports wrapping new property IDs |
| Tray app | `VirtuaCam.exe` startup/shutdown | Call `Connect` on init, `Disconnect` on exit |
| Process host | `VirtuaCamProcess.exe` | Expand into watcher role: monitor named event, launch `VirtuaCam.exe` on demand |
| Installation | `install-all.ps1` | Register `VirtuaCamProcess.exe` as auto-start service or Run-key entry |

---

## Phase 1 — Extend the `avshws` Driver

### 1.1 — Extend the Property Set

The existing property set uses GUID `{CB043957-7B35-456E-9B61-5513930F4D8E}` with one property (ID `0`) for frame push. Add two more IDs:

```c
// Property IDs — add alongside the existing VIRTUACAM_PROP_FRAME (0)
#define VIRTUACAM_PROP_FRAME       0   // existing: push RGB24 frame buffer
#define VIRTUACAM_PROP_CONNECT     1   // new: user-mode client taking over
#define VIRTUACAM_PROP_DISCONNECT  2   // new: user-mode client releasing
```

Register handlers for IDs `1` and `2` in the same `KSPROPERTY_SET` table that already handles ID `0`. Both are `Set`-direction only; no `Get` handler required.

### 1.2 — Driver Context: New Fields

In the filter or stream context struct (wherever the current frame buffer pointer lives):

```c
BOOLEAN      ClientConnected;       // TRUE when VirtuaCam.exe has called Connect
PUCHAR       DefaultFrameBuffer;    // Blue RGB24 frame, allocated at init
SIZE_T       DefaultFrameSize;      // 1280 * 720 * 3 = 2,764,800 bytes
PUCHAR       LastClientFrame;       // Existing frame buffer from DriverBridge pushes
KSPIN_LOCK   FrameLock;
HANDLE       hClientRequestEvent;   // Named event: signals "app opened camera, no client present"
KTIMER       HeartbeatTimer;
KDPC         HeartbeatDpc;
LARGE_INTEGER LastFrameTime;        // Timestamp of last DriverBridge_PushFrame call
```

### 1.3 — Default Blue Frame Initialization

In `DriverEntry` or the AVStream filter factory creation callback:

```c
context->DefaultFrameSize = 1280 * 720 * 3;
context->DefaultFrameBuffer = ExAllocatePoolWithTag(
    NonPagedPoolNx, context->DefaultFrameSize, 'maCv');

// RGB24 in AVStream = packed BGR bytes per pixel
// Blue pixel: B=0xFF, G=0x00, R=0x00
RtlFillMemory(context->DefaultFrameBuffer, context->DefaultFrameSize, 0x00);
for (SIZE_T i = 0; i < context->DefaultFrameSize; i += 3) {
    context->DefaultFrameBuffer[i] = 0xFF; // B channel
}

context->ClientConnected = FALSE;
```

> Optional: bake a pre-rasterized white-text bitmap ("VirtuaCam — Start the app") and `RtlCopyMemory` it centered into `DefaultFrameBuffer` over the blue fill.

### 1.4 — Frame Provision Callback

In the callback where the driver currently copies a user-mode buffer to the AVStream output pin mapping (this is likely the `CStream::FillPacket`, `Process`, or `CompleteMapping` routine depending on how `avshws` was structured):

```c
KeAcquireSpinLock(&context->FrameLock, &irql);

PUCHAR source = context->ClientConnected
    ? context->LastClientFrame
    : context->DefaultFrameBuffer;

RtlCopyMemory(destBuffer, source, context->DefaultFrameSize);

KeReleaseSpinLock(&context->FrameLock, irql);
```

### 1.5 — Named Event: Notify User-Mode When Camera is Opened

Create the event at filter init:

```c
UNICODE_STRING evtName;
RtlInitUnicodeString(&evtName, L"\\BaseNamedObjects\\VirtuaCamClientRequest");

OBJECT_ATTRIBUTES oa;
InitializeObjectAttributes(&oa, &evtName, OBJ_KERNEL_HANDLE | OBJ_OPENIF, NULL, NULL);

ZwCreateEvent(&context->hClientRequestEvent, EVENT_ALL_ACCESS, &oa,
              NotificationEvent, FALSE);
```

In the AVStream pin's **state-change handler** (the callback that fires when the pin transitions between `KSSTATE_*` values — in AVStream this is typically the `SetDeviceState` dispatch or the equivalent automation table entry):

```c
if (toState == KSSTATE_RUN && !context->ClientConnected) {
    // An app opened the camera but VirtuaCam.exe is not connected.
    // Signal VirtuaCamProcess.exe to launch VirtuaCam.exe.
    ZwSetEvent(context->hClientRequestEvent, NULL);
}
if (toState == KSSTATE_STOP) {
    ZwResetEvent(context->hClientRequestEvent, NULL);
}
```

### 1.6 — Property Handlers for CONNECT / DISCONNECT

**CONNECT handler:**
```c
static NTSTATUS VirtuaCamConnect_Handler(
    PIRP Irp, PKSPROPERTY Property, PVOID Data)
{
    PSTREAM_CONTEXT ctx = GetStreamContext(Irp);
    KeAcquireSpinLock(&ctx->FrameLock, &irql);
    ctx->ClientConnected = TRUE;
    KeQuerySystemTime(&ctx->LastFrameTime);
    KeReleaseSpinLock(&ctx->FrameLock, irql);

    // Re-arm the event in case an app is already streaming
    ZwResetEvent(ctx->hClientRequestEvent, NULL);
    return STATUS_SUCCESS;
}
```

**DISCONNECT handler:**
```c
static NTSTATUS VirtuaCamDisconnect_Handler(
    PIRP Irp, PKSPROPERTY Property, PVOID Data)
{
    PSTREAM_CONTEXT ctx = GetStreamContext(Irp);
    KeAcquireSpinLock(&ctx->FrameLock, &irql);
    ctx->ClientConnected = FALSE;
    KeReleaseSpinLock(&ctx->FrameLock, irql);
    return STATUS_SUCCESS;
}
```

### 1.7 — Heartbeat Watchdog (Crash-Safety)

If `VirtuaCam.exe` crashes without calling `Disconnect`, `ClientConnected` stays `TRUE` and the driver stalls on a dead frame. Use a `KTIMER`/`KDPC` to detect silence:

```c
// At init: set up a recurring timer, period = 500ms
LARGE_INTEGER period;
period.QuadPart = -5000000LL; // 500ms in 100ns units (negative = relative)
KeSetTimerEx(&context->HeartbeatTimer, period, 500, &context->HeartbeatDpc);

// DPC routine:
VOID HeartbeatDpc_Routine(PKDPC Dpc, PVOID Ctx, PVOID A, PVOID B) {
    PSTREAM_CONTEXT ctx = (PSTREAM_CONTEXT)Ctx;
    LARGE_INTEGER now;
    KeQuerySystemTime(&now);

    KeAcquireSpinLock(&ctx->FrameLock, &irql);
    if (ctx->ClientConnected) {
        LONGLONG gap = now.QuadPart - ctx->LastFrameTime.QuadPart;
        if (gap > 20000000LL) { // 2 seconds in 100ns units
            ctx->ClientConnected = FALSE; // auto-disconnect stale client
        }
    }
    KeReleaseSpinLock(&ctx->FrameLock, irql);
}
```

Also update `LastFrameTime` in the existing property ID `0` (`VIRTUACAM_PROP_FRAME`) Set handler each time a frame is pushed.

---

## Phase 2 — Extend `DriverBridge.cpp`

`DriverBridge.cpp` currently wraps property ID `0` (frame push). Add two exported functions:

```cpp
// DriverBridge.h additions
HRESULT DriverBridge_Connect();
HRESULT DriverBridge_Disconnect();
// existing:
HRESULT DriverBridge_PushFrame(const BYTE* rgb24, UINT32 size);
```

`DriverBridge_Connect` and `DriverBridge_Disconnect` follow the same pattern as the existing `PushFrame` — open the device via its interface GUID, QI for `IKsPropertySet` (already done for frame push), and call `Set` with the new property IDs.

```cpp
HRESULT DriverBridge_Connect() {
    // Reuse or re-acquire the IKsPropertySet handle used for frame push
    return g_pKsPropertySet->Set(
        KSPROPSETID_VirtuaCam,   // {CB043957-7B35-456E-9B61-5513930F4D8E}
        VIRTUACAM_PROP_CONNECT,  // ID 1
        nullptr, 0,
        nullptr, 0);
}

HRESULT DriverBridge_Disconnect() {
    return g_pKsPropertySet->Set(
        KSPROPSETID_VirtuaCam,
        VIRTUACAM_PROP_DISCONNECT, // ID 2
        nullptr, 0,
        nullptr, 0);
}
```

Both functions must be safe to call before any frame has been pushed (i.e., the device open and QI that currently happens lazily on first `PushFrame` must be factored out into a shared `EnsureConnected()` helper callable by all three exports).

---

## Phase 3 — Changes to `VirtuaCam.exe`

### 3.1 — On Startup

After the tray icon is created and before any producer is activated, call:

```cpp
HRESULT hr = DriverBridge_Connect();
if (FAILED(hr)) {
    // Log and show tray notification: "Could not connect to VirtuaCam driver"
    // Continue running — user can retry, but don't crash
}
```

At this point, even with no source selected, `VirtuaCam.exe` should begin pushing the blue default frame **from user mode** through `DriverBridge_PushFrame` at 30fps. This keeps the frame path identical whether the frame is "real" or default, and removes the need for the driver to implement a frame timer of its own (the heartbeat watchdog above only serves as crash safety, not normal operation).

Maintain a `bool g_NoSource = true` flag. When no source is selected, a dedicated producer thread in `VirtuaCam.exe` pushes the pre-filled blue buffer at 30fps via `DriverBridge_PushFrame`. When the user selects a source, `g_NoSource = false` and `DirectPortBroker.dll` takes over.

### 3.2 — On Shutdown (Tray Exit or System Logoff)

Register a `WM_ENDSESSION` / `WM_QUERYENDSESSION` handler and the tray icon exit action to both call:

```cpp
DriverBridge_Disconnect();
// then proceed with normal teardown
```

This must fire before `CoUninitialize` or any COM/DX teardown, since `DriverBridge_Disconnect` uses the `IKsPropertySet` interface.

### 3.3 — Command-Line Flag for Silent Start

```cpp
// In WinMain / entry point
bool silentStart = HasArg(lpCmdLine, L"/startup");
if (silentStart) {
    // Do not show splash, do not foreground any window
    // Go directly to tray icon + DriverBridge_Connect()
}
```

---

## Phase 4 — Expand `VirtuaCamProcess.exe` into the Watcher Role

`VirtuaCamProcess.exe` is already described as a "lightweight host." It is the natural fit for the watcher role rather than introducing a fourth binary. Restructure it to serve two responsibilities:

1. **Existing:** Host built-in producers (screen capture, physical camera passthrough) and feed the shared D3D11 texture.
2. **New:** Watch the named event `VirtuaCamClientRequest` and launch `VirtuaCam.exe /startup` on demand.

### 4.1 — Watcher Thread in `VirtuaCamProcess.exe`

```cpp
DWORD WINAPI WatcherThread(LPVOID) {
    HANDLE hEvent = OpenEventW(SYNCHRONIZE | EVENT_MODIFY_STATE,
                               FALSE, L"VirtuaCamClientRequest");
    if (!hEvent) return 1; // driver not loaded

    int failCount = 0;
    while (true) {
        DWORD result = WaitForSingleObject(hEvent, INFINITE);
        if (result != WAIT_OBJECT_0) break;

        // Check if VirtuaCam.exe is already running
        if (!IsProcessRunning(L"VirtuaCam.exe")) {
            if (failCount < 3) {
                WCHAR exePath[MAX_PATH];
                GetVirtuaCamExePath(exePath); // reads from registry, see Phase 5
                SHELLEXECUTEINFOW sei = { sizeof(sei) };
                sei.lpFile = exePath;
                sei.lpParameters = L"/startup";
                sei.nShow = SW_HIDE;
                if (!ShellExecuteExW(&sei)) failCount++;
                else failCount = 0;
            }
        }
        ResetEvent(hEvent);
    }
    CloseHandle(hEvent);
    return 0;
}
```

`IsProcessRunning` uses `CreateToolhelp32Snapshot` + `Process32FirstW`/`Process32NextW` to check by process name.

Start `WatcherThread` from `VirtuaCamProcess.exe`'s `WinMain` immediately, on a background thread.

### 4.2 — Also Watch for Driver Device Removal

Register for device interface change notifications (`RegisterDeviceNotification` with the driver's device interface GUID) so that if the driver is reinstalled or the device is re-enumerated, the watcher can re-open the named event handle without requiring a restart:

```cpp
DEV_BROADCAST_DEVICEINTERFACE filter = {};
filter.dbcc_size = sizeof(filter);
filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
filter.dbcc_classguid = KSPROPSETID_VirtuaCam; // {CB043957-7B35-456E-9B61-5513930F4D8E}

RegisterDeviceNotification(hwnd, &filter, DEVICE_NOTIFY_WINDOW_HANDLE);
// On DBT_DEVICEARRIVAL: re-open hEvent
```

---

## Phase 5 — Installation Changes (`install-all.ps1`)

### 5.1 — Write Install Path to Registry

After copying binaries to the install directory:

```powershell
$installDir = "$env:ProgramFiles\VirtuaCam"
New-Item -Path "HKLM:\SOFTWARE\VirtuaCam" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\VirtuaCam" `
    -Name "InstallDir" -Value $installDir
Set-ItemProperty -Path "HKLM:\SOFTWARE\VirtuaCam" `
    -Name "VirtuaCamExe" -Value (Join-Path $installDir "VirtuaCam.exe")
Set-ItemProperty -Path "HKLM:\SOFTWARE\VirtuaCam" `
    -Name "ProcessExe" -Value (Join-Path $installDir "VirtuaCamProcess.exe")
```

### 5.2 — Auto-Start `VirtuaCamProcess.exe` on Login

`VirtuaCamProcess.exe` (now the watcher + producer host) must start automatically so it is ready to receive the named event before any user manually opens `VirtuaCam.exe`.

```powershell
# Per-user: starts after login, no elevation needed
$processExe = Join-Path $installDir "VirtuaCamProcess.exe"
Set-ItemProperty `
    -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
    -Name "VirtuaCamProcess" `
    -Value "`"$processExe`""

# Also register VirtuaCam.exe for auto-start (for users who want it running always)
$virExe = Join-Path $installDir "VirtuaCam.exe"
Set-ItemProperty `
    -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
    -Name "VirtuaCam" `
    -Value "`"$virExe`" /startup"
```

> If all-users (HKLM) startup is preferred, `install-all.ps1` already runs as Administrator (it calls `bcdedit` and `pnputil`), so use `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` instead.

### 5.3 — Uninstall Cleanup

Add an uninstall path (or extend `install-all.ps1` with `-Uninstall` switch):

```powershell
Remove-ItemProperty -Path "HKCU:\...\Run" -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\...\Run" -Name "VirtuaCam" -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\SOFTWARE\VirtuaCam" -Recurse -ErrorAction SilentlyContinue
```

---

## Complete Coupled Flow (Target State)

```
[Login]
  └─> VirtuaCamProcess.exe starts (Run key)
        └─> WatcherThread: opens named event handle, waits
        └─> Watcher: checks if VirtuaCam.exe is in Run key → launches it /startup

[VirtuaCam.exe /startup]
  └─> DriverBridge_Connect() → IKsPropertySet Set(GUID, ID=1)
        └─> avshws: ClientConnected = TRUE
        └─> avshws: stops serving DefaultFrameBuffer
  └─> g_NoSource = true → blue-frame producer thread starts → DriverBridge_PushFrame() @ 30fps
  └─> Tray icon appears, no window shown

[User selects source in tray]
  └─> DirectPortBroker.dll composites Producer → D3D11 Texture → DriverBridge_PushFrame()
  └─> g_NoSource = false → blue-frame producer thread stops
  └─> Apps see live video

[User exits VirtuaCam.exe]
  └─> DriverBridge_Disconnect() → IKsPropertySet Set(GUID, ID=2)
        └─> avshws: ClientConnected = FALSE
        └─> avshws: resumes DefaultFrameBuffer → apps see blue frame, not black/broken
  └─> VirtuaCamProcess.exe (watcher) remains running

[App opens camera when VirtuaCam.exe is not running]
  └─> avshws pin → KSSTATE_RUN, ClientConnected = FALSE
        └─> ZwSetEvent(hClientRequestEvent)
  └─> VirtuaCamProcess.exe WatcherThread wakes
        └─> VirtuaCam.exe not running → ShellExecuteExW("VirtuaCam.exe /startup")
        └─> ResetEvent → watcher re-arms
  └─> VirtuaCam.exe calls DriverBridge_Connect() → live frames resume

[VirtuaCam.exe crashes without calling Disconnect]
  └─> avshws HeartbeatDpc fires every 500ms
        └─> gap between LastFrameTime and now > 2s → ClientConnected = FALSE
        └─> DefaultFrameBuffer served immediately — no black feed
  └─> Named event fires (KSSTATE_RUN still active) → watcher re-launches VirtuaCam.exe
```

---

## File Change Summary

| File | Change |
|---|---|
| `driver-project/src/avshws/*.c` | `DefaultFrameBuffer` alloc + fill; `ClientConnected` flag; property IDs 1 & 2 and their handlers; named event (`VirtuaCamClientRequest`) creation and set/reset in pin state-change handler; `KTIMER`/`KDPC` heartbeat; `LastFrameTime` update in frame-push handler |
| `driver-project/src/avshws/*.h` | New `#define`s for `VIRTUACAM_PROP_CONNECT` and `VIRTUACAM_PROP_DISCONNECT`; new context struct fields |
| `software-project/src/DriverBridge/DriverBridge.cpp` | Refactor device-open + IKsPropertySet QI into shared `EnsureConnected()`; add `DriverBridge_Connect()` and `DriverBridge_Disconnect()` |
| `software-project/src/DriverBridge/DriverBridge.h` | Export declarations for `Connect` and `Disconnect` |
| `software-project/src/VirtuaCam/Main.cpp` | Call `DriverBridge_Connect()` at startup; call `DriverBridge_Disconnect()` at exit; handle `/startup` flag; blue-frame push thread when `g_NoSource = true` |
| `software-project/src/VirtuaCamProcess/Main.cpp` | Add `WatcherThread`: open named event, wait, launch `VirtuaCam.exe /startup` on signal; add `RegisterDeviceNotification` for driver device re-enumeration |
| `install-all.ps1` | Write registry install paths; register `VirtuaCamProcess.exe` and `VirtuaCam.exe` in `Run` key; add uninstall path |
