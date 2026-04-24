# Phase 6 Plan: Build & Link Validation

Context: the direct-driver output path is already active, but the main
`VirtuaCam` executable still carries one leftover Media Foundation startup path
and link dependency that no longer belongs in the output side. Phase 6 removes
that remaining app-side dependency, rebuilds all targets, and validates the
staged binaries around the current source-producer architecture.

## Findings That Shape This Phase

- `software-project/src/VirtuaCam/App.cpp` still calls `MFStartup()` /
  `MFShutdown()`, even though the `IMFVirtualCamera` path is already gone.
- The surviving `VirtuaCam`-side MF use is `UI.cpp` camera enumeration via
  `MFCreateAttributes()` + `MFEnumDeviceSources()`. That can be replaced with
  DirectShow device enumeration, which the project already uses elsewhere
  (`DriverBridge::FindDriverFilter()`).
- `software-project/src/CMakeLists.txt` still links `VirtuaCam` against
  `VCAM_MF_LIBS`. Once UI camera enumeration stops using MF, the executable can
  drop those link libraries.
- `VirtuaCamProcess.exe` still dynamically loads `DirectPortMFCamera.dll` and
  `DirectPortMFGraphicsCapture.dll` for producer input modes. That means phase
  6 can validate and document the current runtime dependency, but cannot safely
  delete those producer DLLs without redesigning the source side.

## Scope

- Replace `VirtuaCam` camera enumeration with DirectShow enumeration.
- Remove `MFStartup()` / `MFShutdown()` from the main app and drop MF link libs
  from the `VirtuaCam` target.
- Rebuild all software targets and validate the staged binary layout.
- Explicitly record the remaining producer-DLL dependency as deferred, not
  silently ignored.

## Tasks

- [ ] 6.1 Replace `VirtuaCam` camera enumeration with DirectShow moniker
      enumeration so the app no longer needs `MFStartup()` / `MFShutdown()`.
- [ ] 6.1 Validate that active `VirtuaCam` sources no longer reference
      `IMFVirtualCamera`, `MFStartup`, or `MFCreateVirtualCamera`.
- [ ] 6.2 Remove `VCAM_MF_LIBS` from the `VirtuaCam` target in
      `software-project/src/CMakeLists.txt`, then rebuild all software targets
      and confirm no new linker errors.
- [ ] 6.3 Validate `output/software/bin` contains the required core binaries
      (`VirtuaCam.exe`, `VirtuaCamProcess.exe`, `DirectPortBroker.dll`,
      `DirectPortClient.dll`, `DirectPortConsumer.dll`) and record that
      `DirectPortMFCamera.dll` / `DirectPortMFGraphicsCapture.dll` are still
      shipped because `VirtuaCamProcess` currently loads them dynamically.

## Validation

- Run `software-project/build.ps1` after code and CMake changes.
- Search active `VirtuaCam` sources for `MFStartup`, `MFShutdown`,
  `IMFVirtualCamera`, and `MFCreateVirtualCamera`.
- Inspect `output/software/bin` after staging.

## Deferred Follow-Up

- Removing `DirectPortMFCamera.dll` and `DirectPortMFGraphicsCapture.dll` from
  runtime output requires replacing or inlining the current source producer
  modules in `VirtuaCamProcess`.
