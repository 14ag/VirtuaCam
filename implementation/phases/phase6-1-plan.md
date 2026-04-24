# Phase 6.1 Plan: Remove Producer DLL Runtime Dependencies (Finish 6.3 + scheduled.md)

Goal: Make `implementation/driver-frame-path.md` Phase 6.3 true for real by
removing runtime + packaging dependency on:

- `DirectPortMFCamera.dll`
- `DirectPortMFGraphicsCapture.dll`

We do that by moving the `camera` + `capture` producers into
`VirtuaCamProcess.exe` as built-in producers. We keep `DirectPortConsumer.dll`
as the only dynamically loaded producer module. In the same pass, we complete
all items in `implementation/scheduled.md` by removing the `mfvirtualcamera.h`
PCH dependency and making `cppwinrt` optional/off-by-default via a CMake option.

## Checklist

### A) Built-in producers in VirtuaCamProcess

- [x] Refactor `software-project/src/VirtuaCam/Process.cpp` to dispatch producer
      type to either:
      - built-in `camera` producer
      - built-in `capture` producer (Windows Graphics Capture)
      - dynamic module load for `consumer` only
- [x] Ensure built-in producers expose the same function pointer surface as the
      legacy DLL exports:
      - `HRESULT InitializeProducer(const wchar_t*)`
      - `void ProcessFrame()`
      - `void ShutdownProducer()`

### B) Camera selection correctness

- [x] Extend camera enumeration in `software-project/src/VirtuaCam/UI.cpp` to
      also capture a stable `DevicePath` (from DirectShow moniker
      `IPropertyBag`, when available).
- [x] Add UI API to fetch cached device path by index:
      `const wchar_t* UI_GetCameraDevicePath(int index);`
      (returns null if unavailable / out of range)
- [x] Update `software-project/src/VirtuaCam/App.cpp` to launch camera producer
      with `--device-path "<path>"` instead of `--device <index>`.
- [x] Update built-in camera producer to select MF device by matching
      `MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK` to the provided
      `--device-path`, and fail gracefully if not found.
- [x] Call `MFStartup`/`MFShutdown` inside the built-in camera producer lifetime
      only (so non-camera modes do not require MF init).

### C) Remove legacy producer DLLs from default build + staging

- [x] Add CMake option `VCAM_ENABLE_LEGACY_MF_COMPONENTS` (default OFF).
- [x] When OFF: do not build `DirectPortMFCamera` or `DirectPortMFGraphicsCapture`.
- [x] Update `software-project/build.ps1` staging step to copy an explicit
      allowlist of binaries:
      - `VirtuaCam.exe`
      - `VirtuaCamProcess.exe`
      - `DirectPortBroker.dll`
      - `DirectPortClient.dll`
      - `DirectPortConsumer.dll`
      and remove any legacy producer DLLs from `output/software/bin` if present.

### D) Make cppwinrt optional + finish scheduled.md

- [x] Replace the existing WGC producer implementationâ€™s `winrt::...` usage with
      WinRT ABI calls (no `cppwinrt` dependency) inside `VirtuaCamProcess.exe`.
- [x] Wrap `find_package(cppwinrt ...)` and any `#include <winrt/...>` usage
      behind `VCAM_ENABLE_LEGACY_MF_COMPONENTS`.
- [x] Remove unused `mfvirtualcamera.h` include from
      `software-project/src/VirtuaCam/pch.h` (keep it only under legacy option).
- [x] Remove MF-virtual-camera-only GUID name mappings from
      `software-project/src/VirtuaCam/Tools.cpp` so the default build does not
      require `mfvirtualcamera.h`.

### E) DirectPortClient.dll default behavior

- [x] For legacy option ON: keep the existing MF/WinRT COM implementation.
- [x] For legacy option OFF: build `DirectPortClient.dll` as a minimal COM
      registerable stub that exports `DllRegisterServer`, `DllUnregisterServer`,
      `DllGetClassObject`, `DllCanUnloadNow` (returns success / no class objects).

## Acceptance Criteria

- Build: `powershell -ExecutionPolicy Bypass -File .\\software-project\\build.ps1`
  succeeds with default config (`VCAM_ENABLE_LEGACY_MF_COMPONENTS=OFF`).
- `output/software/bin` contains only:
  - `VirtuaCam.exe`
  - `VirtuaCamProcess.exe`
  - `DirectPortBroker.dll`
  - `DirectPortClient.dll`
  - `DirectPortConsumer.dll`
  and does NOT contain `DirectPortMFCamera.dll` / `DirectPortMFGraphicsCapture.dll`.
- Static search: `rg -n \"winrt::|<winrt/\" .\\software-project\\src\\VirtuaCam`
  yields no hits in the default build paths.
- `implementation/scheduled.md` items are all checked as done.
- `implementation/done.txt` has new timestamped completion lines appended (do
  not edit prior entries).

## Validation Commands

```powershell
powershell -ExecutionPolicy Bypass -File .\\software-project\\build.ps1
Get-ChildItem .\\output\\software\\bin -File | Sort-Object Name | Select-Object Name
rg -n \"winrt::|<winrt/\" .\\software-project\\src\\VirtuaCam
```
