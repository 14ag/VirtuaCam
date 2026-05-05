# Changelog

All notable changes to this project should be documented in this file.

Format follows Keep a Changelog and this repository currently tracks changes from this point forward.

## [Unreleased]

### Added

- tray aspect-ratio setting with `16:9`, `9:16`, `4:3`, and `3:4`
- `%LOCALAPPDATA%\VirtuaCam\settings.ini` persistence for aspect ratio and PIP toggles
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
