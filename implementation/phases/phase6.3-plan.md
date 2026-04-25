# Phase 6.1 Plan: Remove Producer DLL Runtime Dependencies (Finish 6.3 + scheduled.md)

## Summary
We make Phase 6.3 true “for real” by removing the runtime requirement (and default packaging) of `DirectPortMFCamera.dll` and `DirectPortMFGraphicsCapture.dll`. We do that by moving the `camera` + `capture` producer implementations into `VirtuaCamProcess.exe` (built-in producers), while keeping `DirectPortConsumer.dll` as the only dynamically loaded producer module. In the same pass, we complete `implementation/scheduled.md` by removing the `mfvirtualcamera.h` PCH dependency and making `cppwinrt` optional/off-by-default (legacy MF/WinRT components behind a CMake option).

## Key Implementation Changes
- Create `implementation/phases/phase6-1-plan.md` first with the exact checklist below (mirrors this plan, plus acceptance criteria and commands).
- **Built-in producers in `VirtuaCamProcess.exe`**
  - Refactor `software-project/src/VirtuaCam/Process.cpp` so `LoadProducerModule()` returns function pointers for:
    - `--type camera` → built-in camera producer (reusing logic from `MFCamera.cpp`)
    - `--type capture` → built-in window-capture producer (reusing logic from `MFGraphicsCapture.cpp`, rewritten to *WinRT ABI* so we don’t need `cppwinrt`)
    - `--type consumer` → keep dynamic load of `DirectPortConsumer.dll` as today
  - Ensure built-in producers implement the same `InitializeProducer/ProcessFrame/ShutdownProducer` signatures as the old DLL exports.
- **Fix camera selection correctness (important)**
  - UI camera listing is now DirectShow-based, but the old camera producer selected devices by *MF index*; indexes can differ.
  - Update `software-project/src/VirtuaCam/UI.cpp` camera enumeration to also capture a stable device identifier (prefer `DevicePath` from `IPropertyBag`).
  - Add a small UI API in `software-project/src/VirtuaCam/UI.h` to fetch the cached camera `DevicePath` by camera index.
  - Update `software-project/src/VirtuaCam/App.cpp` to launch camera producers with `--device-path "<path>"` (not `--device <index>`).
  - Update the built-in camera producer to select the MF device whose `MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK` matches the passed `--device-path`. If not found, log and fail gracefully.
  - Add `MFStartup/MFShutdown` inside the camera producer lifetime (only when `--type camera` is used).
- **Remove `DirectPortMFCamera.dll` and `DirectPortMFGraphicsCapture.dll` from default build + staging**
  - In `software-project/src/CMakeLists.txt`:
    - Add option like `VCAM_ENABLE_LEGACY_MF_COMPONENTS` (default `OFF`).
    - When `OFF`: do **not** build `DirectPortMFCamera` and `DirectPortMFGraphicsCapture` targets.
    - When `ON`: keep building them (unchanged) for fallback builds.
  - In `software-project/build.ps1`:
    - Stage an explicit allowlist (copy only `VirtuaCam.exe`, `VirtuaCamProcess.exe`, `DirectPortBroker.dll`, `DirectPortClient.dll`, `DirectPortConsumer.dll` (+ optional `.pdb` if desired)).
    - Remove any previously-staged legacy producer DLLs from `output/software/bin` during staging to keep the folder clean.
- **Make `cppwinrt` optional + complete `scheduled.md`**
  - Replace the current `MFGraphicsCapture.cpp` WGC usage (`winrt::...`) with WinRT ABI calls using SDK headers like `windows.graphics.capture.h` + `windows.graphics.capture.interop.h` and `RoGetActivationFactory` / `IGraphicsCaptureItemInterop` / `IDirect3D11CaptureFramePoolStatics`.
  - Remove `find_package(cppwinrt CONFIG REQUIRED)` from default configuration; wrap it in the `VCAM_ENABLE_LEGACY_MF_COMPONENTS` option.
  - Remove WinRT (`#include <winrt/...>`) from `software-project/src/VirtuaCam/pch.h` unless legacy option is enabled.
- **Remove `mfvirtualcamera.h` dependency cleanly**
  - In `software-project/src/VirtuaCam/Tools.cpp`, remove the `IFGUID(MF_VIRTUALCAMERA_...)` cases and any other MF-virtual-camera-specific GUID-to-string mappings that are no longer used in the direct-driver build.
  - Then remove `#include "mfvirtualcamera.h"` from `software-project/src/VirtuaCam/pch.h`.
  - Keep the file in-tree behind the legacy option if you want, but it should not be included or referenced in the default build.
- **DirectPortClient.dll strategy (per your choice)**
  - Keep legacy MF virtual-camera COM server behind `VCAM_ENABLE_LEGACY_MF_COMPONENTS=ON`.
  - For default `OFF`, build `DirectPortClient.dll` as a minimal COM-registerable DLL (implement `DllRegisterServer/DllUnregisterServer/DllGetClassObject/DllCanUnloadNow` as simple stubs that make `regsvr32` succeed, but do not expose MF virtual camera classes).
  - Keep `install-all.ps1` behavior intact (still registers `DirectPortClient.dll`) unless you want a separate follow-up to remove registration entirely.
- **Docs/Tracking**
  - Update `implementation/scheduled.md` checkboxes to `[x]` for all items it currently lists.
  - Append timestamped “done” lines to `implementation/done.txt` for every completed item in this subproject; do not modify prior lines.
  - (Optional but recommended) Add one short note to `implementation/driver-frame-path.md` Phase 6.3 section clarifying that camera/window producers are now built into `VirtuaCamProcess.exe` and the two legacy producer DLLs are disabled by default.

## Test / Validation Plan
- Build: run `powershell -ExecutionPolicy Bypass -File .\\software-project\\build.ps1` and ensure it succeeds with `VCAM_ENABLE_LEGACY_MF_COMPONENTS=OFF`.
- Output check: verify `output/software/bin` contains only:
  - `VirtuaCam.exe`
  - `VirtuaCamProcess.exe`
  - `DirectPortBroker.dll`
  - `DirectPortClient.dll`
  - `DirectPortConsumer.dll`
  - and does **not** contain `DirectPortMFCamera.dll` / `DirectPortMFGraphicsCapture.dll`.
- Static search: `rg -n "winrt::|<winrt/" software-project\\src\\VirtuaCam` should be empty when legacy option is OFF.
- Runtime smoke:
  - Start `VirtuaCam.exe`, pick `Source -> [Webcam]` and confirm `VirtuaCamProcess.exe --type camera --device-path ...` launches and produces a stream.
  - Pick `Source -> [Window]` and confirm `--type capture --hwnd ...` produces frames.
- Error handling rule: if you hit the same build/link/runtime error more than twice, do a targeted web search for that exact error text + “Windows Graphics Capture ABI” / “RoGetActivationFactory Direct3D11CaptureFramePool” and retry with the discovered fix.

## Assumptions / Defaults
- Default build disables legacy MF virtual camera + producer DLLs: `VCAM_ENABLE_LEGACY_MF_COMPONENTS=OFF`.
- We preserve window capture quality by keeping Windows Graphics Capture, but implemented via WinRT ABI (no `cppwinrt` dependency).
- We keep `DirectPortClient.dll` registerable by `regsvr32` in the default build to avoid breaking existing install scripts, even though it no longer provides an MF virtual camera in the default configuration.
