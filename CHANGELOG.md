# Changelog

All notable changes to this project should be documented in this file.

Format follows Keep a Changelog and this repository currently tracks changes from this point forward.

## [Unreleased]

### Added

- tray aspect-ratio setting with `16:9`, `9:16`, `4:3`, and `3:4`
- `%LOCALAPPDATA%\VirtuaCam\settings.ini` persistence for aspect ratio and PIP toggles
- `Audio Source` tray selection for active WASAPI capture devices, including persisted `AudioCaptureDeviceName`
- camera passthrough audio selection that tries to pair a USB camera with its matching microphone
- shared driver/user-mode ABI header with aspect masks, `VIRTUACAM_PROP_FRAME_EX`, `VIRTUACAM_FRAME_EX_HEADER`, and driver status v2 fields
- FrameEx driver upload support for BGRA32/RGB32/NV12 with legacy BGR24 fallback
- broker manifest magic/version/size/owner PID/nonce validation and bounded shared-object names
- vHLK queue/monitor helper in `scripts/run-vhlk-tests.ps1`
- whitebox validation scripts for the 2026-05-11 code review, FrameEx ABI, performance audit, invalid-buffer fuzzing, and camera-passthrough audio config
- root repository documentation and policy files
- GitHub wiki documentation references and ignored local `wiki/` checkout guidance
- issue templates and pull request template
- repository metadata and writing checklist artifacts
- current architecture, packaging, testing, and driver-interface details from implementation notes into project docs

### Changed

- driver frame presentation timestamps now use `KeQueryPerformanceCounter` when no stream clock is available, while preserving monotonic frame time
- driver warm-up retry logging now reports the first wait and then periodic waits instead of logging every retry
- MediaCapture proof defaults to the CPU frame-reader path; `-IncludeAutoSurfaceProbe` opt-in also checks the WinRT `Auto` memory preference path
- producer canvas fitting now respects selected aspect ratio and adds black padding instead of stretching
- app frame upload is paced, skips unchanged broker frame values, and separates default-feed refresh from live producer refresh
- broker discovery is throttled, producer manifests are cached after validation, and shared D3D publish paths flush before frame values are published
- producer processing uses frame cadence with adaptive idle backoff instead of 1 ms polling
- GDI fallback capture caches DC/DIB resources and uploads DIB bits directly while source size is unchanged
- driver package INF now uses `PnpLockdown=1`, DIRID `13`, and isolated `ServiceBinary=%13%\avshws.sys`
- watcher service launch path validates canonical install location and stored SHA-256 before starting `VirtuaCam.exe`
- driver property handlers copy/probe caller buffers through shared helpers and apply dynamic access checks
