# Phase 3 Plan: Clean Up MF-Only Source Files

Context: phase 2 removed the app-level `IMFVirtualCamera` startup path, but the
software build still carries Media Foundation and C++/WinRT dependencies that
were introduced for multiple different purposes. Phase 3 is therefore a build
cleanup phase, not a blanket delete-everything phase: we should remove only the
MF-source pieces that are now dead for the direct-driver path, while keeping
the producer modules and COM client pieces that are still exercised by the
current runtime.

## Findings That Shape This Phase

- `software-project/src/CMakeLists.txt` already does not compile
  `VirtuaCam/MFActivate.cpp`, `VirtuaCam/MFSource.cpp`, or
  `VirtuaCam/MFStream.cpp`. Task 3.1 is effectively already satisfied and only
  needs to be recorded/validated.
- `software-project/src/VirtuaCam/Process.cpp` still loads
  `DirectPortMFCamera.dll` for `--type camera` and
  `DirectPortMFGraphicsCapture.dll` for `--type capture`, so task 3.2 cannot
  remove those targets yet without breaking source capture.
- `VCAM_MF_LIBS` is currently linked through `VirtuaCamCommon`, which forces MF
  link libraries onto every target even though only some targets use them.
  This is the main cleanup we can safely land now.
- `cppwinrt` cannot be removed yet because `DirectPortClient` and
  `DirectPortMFGraphicsCapture` still compile C++/WinRT code through
  `MFClient.cpp`, `MFGraphicsCapture.cpp`, and `pch.h`.

## Scope

- Record the current state of task 3.1 as verified.
- Narrow Media Foundation link dependencies to only the targets that still call
  MF APIs.
- Explicitly defer removal of producer targets and `cppwinrt` until their
  surviving runtime callers are redesigned or deleted.
- Validate the resulting build.

## Tasks

- [x] Verify task 3.1 is already true:
      `MFActivate.cpp`, `MFSource.cpp`, and `MFStream.cpp` are not listed in
      any active target in `software-project/src/CMakeLists.txt`.
- [ ] Keep task 3.2 deferred:
      `DirectPortMFCamera` and `DirectPortMFGraphicsCapture` are still runtime
      dependencies of `VirtuaCamProcess.exe` and cannot be removed in this
      phase without replacing the producer path.
- [x] Implement task 3.3 as a link-scope cleanup:
      remove `VCAM_MF_LIBS` from `VirtuaCamCommon` and link it only to the
      targets that still use MF APIs (`DirectPortClient`, `DirectPortMFCamera`,
      and `VirtuaCam`).
- [ ] Keep task 3.4 deferred:
      `find_package(cppwinrt ...)` and the `cppwinrt` vcpkg dependency remain
      necessary while `MFClient.cpp` and `MFGraphicsCapture.cpp` still use
      `winrt::implements`, WinRT activation, and WinRT capture APIs.

## Validation

- Reconfigure and build the software project after the CMake changes.
- Confirm `DirectPortBroker`, `DirectPortConsumer`, and `VirtuaCamProcess` no
  longer inherit MF link libraries through `VirtuaCamCommon`.
- Confirm the producer DLL targets remain buildable and staged because
  `VirtuaCamProcess` still loads them dynamically.

## Deferred Follow-Up

- Replace or remove the `camera` and `capture` producer modules before deleting
  `DirectPortMFCamera` and `DirectPortMFGraphicsCapture`.
- Remove `mfvirtualcamera.h` from the shared precompiled header after the
  remaining MF/WinRT cleanup stops depending on those shared declarations.
- Revisit `cppwinrt` removal only after `MFClient` and `MFGraphicsCapture` are
  retired or rewritten.
