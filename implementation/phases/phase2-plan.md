# Phase 2 Plan: DriverBridge Unconditional in VirtuaCam

Context: `software-project/src/VirtuaCam/App.cpp` still boots the deprecated
Media Foundation virtual camera path and only falls back to `DriverBridge`
when registration fails. Phase 2 makes the driver path the default while
preserving any remaining Media Foundation startup that is still needed by
other code in the `VirtuaCam.exe` process.

## Scope

- Remove the virtual-camera registration function and all `g_vcam` usage.
- Initialize `DriverBridge` unconditionally during app startup.
- Keep the app running if driver initialization fails, but log/show a clear
  error.
- Remove App-level WinRT / MF-virtual-camera dependencies that are no longer
  needed.
- Preserve `MFStartup` / `MFShutdown` for now because surviving MF callers
  remain in the app process (`UI.cpp` camera enumeration).

## Tasks

- [x] Delete `RegisterVirtualCamera()` declaration, definition, and startup
      call in `App.cpp`.
- [x] Remove the `g_vcam` global and shutdown cleanup in `App.cpp`.
- [x] Replace the fallback-only `DriverBridge` initialization with an
      unconditional startup path and clearer error handling.
- [x] Remove `winrt::init_apartment(...)` from `wWinMain`.
- [ ] Remove the unused `mfvirtualcamera.h` include from `pch.h`.
      Deferred: `Tools.cpp` still resolves MF virtual-camera GUID constants via
      the shared precompiled header, so this cleanup belongs with later MF-file
      cleanup rather than the App-only phase-2 patch.
- [x] Build the software target(s) needed to validate the phase-2 changes.

## Validation

- `VirtuaCam` compiles without references to `RegisterVirtualCamera` or
  `IMFVirtualCamera`.
- `App.cpp` no longer loads `mfsensorgroup.dll` or calls `MFCreateVirtualCamera`.
- Startup still initializes COM, Broker, UI, and `DriverBridge`.
- `MFStartup` remains only because other in-process MF code still exists.
