# Task List: Route Frames Directly to Kernel Driver (avshws)

Goal: VirtuaCam always pushes frames to the `avshws` kernel driver via
`DriverBridge` + `IKsPropertySet`. MF virtual camera path completely removed.
The Broker/compositing stack stays — it still produces the composited texture
that `DriverBridge::SendFrame()` consumes.

> [!IMPORTANT]
> Scope: this file covers the **direct-driver frame path only**.
> DirectShow (v1 IPC filter) details → `driver-frame-path-update-1.md`
> MediaFoundation virtual camera details → `driver-frame-path-update-2.md`

---

## Key Invariants (do not break)

| Component                 | Keep?           | Reason                                                                 |
| ------------------------- | --------------- | ---------------------------------------------------------------------- |
| DirectPortBroker.dll      | YES             | Composites producer textures → shared texture consumed by DriverBridge |
| DirectPortClient.dll      | YES             | Producer registration (COM)                                            |
| DirectPortConsumer.dll    | YES             | Consumer source mode                                                   |
| VirtuaCamProcess.exe      | YES             | Launched per source (camera/window capture)                            |
| DriverBridge.cpp          | YES             | Core of this feature                                                   |
| avshws kernel driver      | YES             | Frame sink                                                             |
| MFActivate/Source/Stream  | REMOVE          | Only serve IMFVirtualCamera path                                       |
| IMFVirtualCamera (g_vcam) | REMOVE          | Replaced unconditionally by DriverBridge                               |
| MFStartup/MFShutdown      | REMOVE (verify) | Not needed without g_vcam                                              |

---

## Phase 1 — Understand & Audit (no code changes)

- [ ] 1.1 Confirm avshws driver is installed and `PROPSETID_VIDCAP_CUSTOMCONTROL`
      device appears under CLSID_VideoInputDeviceCategory.
      Run DriverBridge::FindDriverFilter logic manually or add a test
      diagnostic log at startup.

- [ ] 1.2 Confirm `DriverBridge::SendFrame()` reaches `IKsPropertySet::Set()`
      and that `hwsim.cpp CHardwareSimulation::SetData()` receives data.
      Add a volatile frame counter or `OutputDebugString` in `SetData`,
      trigger one manual frame, check DbgView.

- [ ] 1.3 Audit which source files include `mfvirtualcamera.h` or MF-only APIs
      (`IMFVirtualCamera`, `MFCreateVirtualCamera`, etc.) — these are the
      only ones that need to change: - App.cpp ← primary target - MFActivate.cpp/h ← will be removed - MFSource.cpp/h ← will be removed - MFStream.cpp/h ← will be removed - MFClient.cpp ← lives in DirectPortClient DLL, leave alone - mfvirtualcamera.h stub — keep until all callers gone

- [ ] 1.4 Check whether `winrt::init_apartment` is required outside of MF path
      (search for winrt:: usages outside MFSource/MFStream/MFActivate).

- [ ] 1.5 Check whether `MFStartup` / `MFShutdown` are needed by any remaining
      component (Broker, Consumer, WASAPI, etc.).

- [ ] 1.6 Verify format contract between DriverBridge and avshws: - avshws expects RGB24, 1280×720, row-major, no padding
      (`kDriverWidth/Height/BytesPerPixel` constants in DriverBridge.cpp) - Broker composites at 1920×1080 BGRA (`Multiplexer.cpp` line 72-73) - DriverBridge scales 1920×1080→1280×720 via D3D blit then
      swizzles BGRA→BGR. Confirm no channel-swap needed. - Check `image.cpp` (CImageSynthesizer) byte-order expectation.

- [ ] 1.7 Verify driver is loaded and device enumerated:
      `cmd
         pnputil /enum-drivers | findstr avshws
         pnputil /enum-devices /class Camera
         powershell "Get-PnpDevice -Class Camera"
         `
      Device must appear as `ROOT\AVSHWS\0000` before any frame-send work.

- [ ] 1.8 Verify TESTSIGNING boot option is active (required for test-signed .sys):
      `cmd
         bcdedit /enum | findstr /i testsigning
         `
      Expected: `testsigning    Yes`

---

## Phase 2 — Make DriverBridge Unconditional in App.cpp

- [ ] 2.1 Remove `RegisterVirtualCamera()` call from `wWinMain`.
      Delete the function body and its declaration.

- [ ] 2.2 Remove `g_vcam` (IMFVirtualCamera) global and all code that touches it: - `wil::com_ptr_nothrow<IMFVirtualCamera> g_vcam` - `g_vcam->Start()` - `g_vcam->Remove()` in ShutdownSystem()

- [ ] 2.3 Replace the conditional DriverBridge init block with unconditional init:
      ```cpp
      // BEFORE (fallback only):
      HRESULT hrVcam = RegisterVirtualCamera();
      if (FAILED(hrVcam)) {
      g_driverBridge = std::make_unique<DriverBridge>();
      HRESULT hrDriver = g_driverBridge->Initialize();
      if (FAILED(hrDriver)) { ... g_driverBridge.reset(); }
      }

           // AFTER (always):
           g_driverBridge = std::make_unique<DriverBridge>();
           HRESULT hrDriver = g_driverBridge->Initialize();
           if (FAILED(hrDriver)) {
               VirtuaCamLog::ShowAndLogError(g_hMainWnd,
                   L"DriverBridge failed to connect to avshws kernel driver.\n"
                   L"Make sure driver-project is installed.", L"Error", hrDriver);
               // Do NOT reset — allow app to continue without frame output
               // so UI and broker still work. Or hard-fail: your call.
           }
           ```

- [ ] 2.4 Remove `MFStartup(MF_VERSION)` and `MFShutdown()` calls from
      `wWinMain` and `ShutdownSystem()` unless audit (1.5) shows they're
      still needed by another component.

- [ ] 2.5 Remove `winrt::init_apartment(...)` call unless audit (1.4) shows
      it has surviving callers.

- [ ] 2.6 Remove `#include <mfvirtualcamera.h>` from pch.h / App.cpp once
      all uses of `IMFVirtualCamera`, `MFVirtualCameraType`, etc. are gone.

---

## Phase 3 — Clean Up MF-Only Source Files

These files implement the MF software camera source (IMFMediaSource / IMFMediaStream).
They are no longer needed in the direct-driver path.

- [ ] 3.1 Remove from CMakeLists.txt `VirtuaCamCommon` (and any other target): - `VirtuaCam/MFActivate.cpp` - `VirtuaCam/MFSource.cpp` - `VirtuaCam/MFStream.cpp`
      (headers stay on disk but are no longer compiled; delete later.)

- [ ] 3.2 Remove from CMakeLists.txt the `DirectPortMFCamera` shared library
      target (`VirtuaCam/MFCamera.cpp`) unless it is used for something
      other than the MF virtual camera source.
      Same for `DirectPortMFGraphicsCapture` (`VirtuaCam/MFGraphicsCapture.cpp`)
      if it only serves the MF path.
      **Verify first**: check if VirtuaCamProcess.exe loads either DLL.

- [ ] 3.3 Remove `VCAM_MF_LIBS` (`mfplat mfuuid mfreadwrite mf`) from
      `target_link_libraries(VirtuaCamCommon ...)` in CMakeLists.txt,
      UNLESS audit shows Broker, WASAPI, or Consumer still link MF APIs.

- [ ] 3.4 Remove `cppwinrt` vcpkg dependency and `find_package(cppwinrt ...)`
      from CMakeLists.txt if winrt:: is fully removed.

---

## Phase 4 — DriverBridge Hardening

- [ ] 4.1 Fix operator-precedence bug in `Device.cpp` line 35:
      `cpp
         // WRONG (& binds tighter than !=):
         if (supportFlags & KSPROPERTY_SUPPORT_SET != KSPROPERTY_SUPPORT_SET)
         // RIGHT:
         if ((supportFlags & KSPROPERTY_SUPPORT_SET) != KSPROPERTY_SUPPORT_SET)
         `
      This is in `driver-project/UserLand/DriverInterface/Device.cpp`.
      The same check in `DriverBridge.cpp` line 102 is already correct.

- [ ] 4.2 Add retry / re-init logic to DriverBridge::SendFrame():
      If `IKsPropertySet::Set()` returns a device-lost error
      (`HRESULT_FROM_WIN32(ERROR_BAD_COMMAND)` or similar), call
      `Shutdown()` then `Initialize()` to re-enumerate the filter.

- [ ] 4.3 Verify format contract (see 1.6 audit result). Confirm no
      channel-swap needed between BGRA broker output and BGR driver input.

- [ ] 4.4 Expose driver connection status in UI telemetry:
      Add a `GetDriverBridgeStatus()` free function in App.cpp (mirroring
      `GetBrokerState()`) and show `"Driver: OK / FAIL"` in the tray tooltip
      or the existing telemetry label.

- [ ] 4.5 **[From BSOD lessons]** Ensure user-mode DriverBridge pre-allocates
      its IOCTL send buffer in the constructor (max-frame-size), not per-frame.
      Per-frame malloc/free causes ~1000 CPU cycles of heap+syscall overhead
      and heap fragmentation at 30fps. Reuse a fixed buffer.
      `cpp
         // In DriverBridge constructor:
         m_sendBuffer.resize(sizeof(KSPROPERTY) + MAX_FRAME_BYTES);
         // In SendFrame(): fill m_sendBuffer in-place, call DeviceIoControl once
         `

- [ ] 4.6 **[From BSOD lessons]** Use `METHOD_IN_DIRECT` IOCTL instead of
      `METHOD_BUFFERED` if the avshws KS property path uses
      `METHOD_BUFFERED` for large frames. `METHOD_BUFFERED` causes a
      double-copy (8 MB/frame at 1920×1080 RGB24 = 16 MB bandwidth per frame).
      Verify the current IOCTL method in avshws property descriptor.

---

## Phase 5 — OnIdle Frame-Push Timing

- [ ] 5.1 Current OnIdle() order: 1. `g_pfnRenderBrokerFrame()` — composites into shared texture 2. `g_pfnGetBrokerState()` — telemetry 3. `g_driverBridge->SendFrame(sharedTexture)` — pushes to driver
      This is correct. Confirm `RenderBrokerFrame` is always called before
      `SendFrame` regardless of broker state.

- [ ] 5.2 Add a guard: only call `SendFrame` if broker returned a non-null
      texture AND the driver bridge is active. Current code already does
      this but double-check after removing the MF fallback guard.

- [ ] 5.3 (Optional performance) Move `SendFrame` to a dedicated thread at
      target frame rate (e.g. 30 fps timer) instead of running it on the
      message-loop idle tick, which is unbounded.
      Use `SetWaitableTimer` for precise 33.3ms intervals (not `Sleep`).
      Keep this optional until basic path works.

---

## Phase 6 — Build & Link Validation

- [ ] 6.1 Rebuild `VirtuaCam` target after Phase 2+3 changes.
      Expected: zero references to `IMFVirtualCamera`, `MFStartup`,
      `MFCreateVirtualCamera`.

- [ ] 6.2 Rebuild all targets. Confirm no linker errors from removed MF libs.

- [ ] 6.3 Confirm `output/software/bin/` contains: - `VirtuaCam.exe` - `VirtuaCamProcess.exe` - `DirectPortBroker.dll` - `DirectPortClient.dll` - `DirectPortConsumer.dll`
      and does NOT require `DirectPortMFCamera.dll` or
      `DirectPortMFGraphicsCapture.dll` at runtime.
      Note: `--type camera` and `--type capture` producers are built into
      `VirtuaCamProcess.exe`; the two MF producer DLLs are legacy/optional only.

---

## Phase 7 — End-to-End Smoke Test

- [ ] 7.1 Install driver: run `install-all.ps1`.
      Confirm `ROOT\AVSHWS\0000` appears in Device Manager under Cameras.

- [ ] 7.2 Launch `VirtuaCam.exe` as admin. Confirm:
      a. No MF error dialog appears
      b. RuntimeLog shows `"DriverBridge initialized"` (add this log line)
      c. RuntimeLog does NOT show `"RegisterVirtualCamera"` attempts

- [ ] 7.3 Select a window/camera source in the VirtuaCam tray menu.
      Confirm Broker composites (telemetry shows "Connected").

- [ ] 7.4 Open `software-project\webcam.html`. Confirm live video feed appears.

- [ ] 7.5 Test graceful failure: uninstall driver, relaunch VirtuaCam.
      Confirm error is logged with exact HRESULT and app does not crash.
      Log format: `[VirtuaCam] ERROR: DriverBridge::Initialize failed HRESULT=0x...`

---

## Phase 8 — Cleanup & Documentation

- [ ] 8.1 Delete (or archive) source files no longer compiled: - `VirtuaCam/MFActivate.cpp` / `.h` - `VirtuaCam/MFSource.cpp` / `.h` - `VirtuaCam/MFStream.cpp` / `.h` - `VirtuaCam/MFCamera.cpp` (if target removed) - `VirtuaCam/MFGraphicsCapture.cpp` (if target removed) - `VirtuaCam/mfvirtualcamera.h` stub (if no remaining includes)

- [ ] 8.2 Update `implementation/plan.md`: mark old items done, add this file.

- [ ] 8.3 Update `implementation/done.txt` with timestamped completion lines.

- [ ] 8.4 Update top-level `README.md` to reflect that MF virtual camera is
      no longer used and the avshws kernel driver is the only output path.

---

## Lessons Learned from Previous Iteration

> These are hard-won insights from the v1 iteration that directly affect this
> phase. Ignore them at your peril.

### Driver Loading

- Error `0xC0000263` = STATUS_DRIVER_ENTRYPOINT_NOT_FOUND. Means the .sys was
  built without the correct WDK toolset (v143) or linked against wrong libs.
  Fix: retarget .vcxproj to `PlatformToolset=WindowsKernelModeDriver10.0`.
- Driver must be **cryptographically signed** before `pnputil` will install it
  on a system with SecureBoot or without TESTSIGNING enabled.
- `pnputil /add-driver avshws.inf /install` is the canonical install command.
  Verify with `pnputil /enum-devices /class Camera`.

### DriverBridge::SendFrame() Failures

- If `IKsPropertySet::Set()` fails with `ERROR_BAD_COMMAND`, the filter graph
  is not running. The avshws pin must be in `KSSTATE_RUN` before frames are accepted.
- Check that the avshws device is opened with `GENERIC_READ | GENERIC_WRITE`
  and `FILE_SHARE_READ | FILE_SHARE_WRITE`. Missing share flags → `ERROR_SHARING_VIOLATION`.

### HRESULT Logging

- Every `ShowAndLogError` must log to both console stderr AND
  `output\logs\virtuacam-runtime.log` with timestamp + HRESULT.
- For `0x8007047E` (module not found): log exact DLL path being loaded and
  the current executable directory.

### Build Output Layout

- All binaries must land in `v2\output\software\bin` (exe + DLLs).
- Driver package (`.sys`, `.inf`, `.cat`, `.cer`) must land in
  `v2\output\driver\package`.
- No artifacts should be copied to repo root.

### IOCTL Performance (cross-boundary)

- Each `DeviceIoControl` crossing ring 3→0 costs ~1000 cycles minimum.
- At 30fps, per-frame malloc+IOCTL+free = significant overhead.
- Pre-allocate send buffer once; reuse every frame (see Task 4.5).
- For frames > 1MB, switch from `METHOD_BUFFERED` to `METHOD_IN_DIRECT`
  to eliminate the kernel-side copy (see Task 4.6).
