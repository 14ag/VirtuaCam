# Contributing

Thanks for contributing to Virtual Webcam v2.

## Before you start

Read:

- `README.md`
- `https://github.com/14ag/VirtuaCam/wiki/Getting-Started`
- `https://github.com/14ag/VirtuaCam/wiki/Architecture`
- `https://github.com/14ag/VirtuaCam/wiki/Development-Guide`

Use current docs and source first when you work on startup flow, producer flow, packaging, or AVStream behavior. `implementation/` is reserved for retained WDK and AVStream audit references.

## Ways to contribute

- report a bug
- propose a feature
- improve documentation
- test installation or runtime behavior on new Windows setups
- fix software or driver issues

## Reporting bugs

Use GitHub bug report template and include:

1. Windows version
2. whether `TESTSIGNING` is enabled
3. exact command you ran
4. whether failure is in build, install, startup, source selection, or target app preview
5. logs or screenshots when available

If bug is security-sensitive, do not open a public issue. Follow `SECURITY.md`.

## Suggesting features

Use GitHub feature request template and explain:

1. problem you are trying to solve
2. current workaround
3. expected behavior
4. constraints around Windows version, driver model, or target app compatibility

## Local development setup

Prerequisites:

1. Windows 10 or Windows 11
2. Visual Studio 2022 with MSBuild and C++ workloads
3. Windows SDK and WDK
4. CMake 3.20 or newer
5. Git

Common commands:

```powershell
.\scripts\build-all.ps1
.\scripts\build-all.ps1 -Clean
.\scripts\build-all.ps1 -SkipDriver
.\scripts\build-all.ps1 -SkipSoftware
```

Installer command:

```powershell
.\scripts\install-all.ps1
```

There is one build script, one install script, and one staged package path:

- `scripts\build-all.ps1`
- `scripts\install-all.ps1`
- `output/`

If you add, remove, or rename staged binaries, update `scripts/tools/artifact-manifest.ps1` so build and install stay aligned.

## Development expectations

- keep changes grounded in current repo architecture
- update docs in same change when behavior changes
- keep retained implementation references aligned with driver work
- preserve user changes outside your task scope
- test manually when you touch build, install, startup, producer selection, or driver bridge behavior
- before changing anything under `driver-project`, check the relevant local PDF table of contents, read the relevant section, and cite the section in your work notes or PR summary
- keep current docs in `README.md`, `software-project/README.md`, `driver-project/README.md`, and the separate GitHub wiki; do not treat implementation scratch notes as user-facing project docs

## Validation expectations

No automated test suite is checked in today. For changes that affect behavior, manual validation is expected:

1. build affected component or full repo
2. install if driver or packaging changed
3. launch `VirtuaCam.exe`
4. select a source
5. verify target app can open camera

Good issue or PR notes include what you tested and what you did not test.

For build, install, or driver/runtime integration changes, include whether you ran:

```powershell
.\scripts\hyperv-clean-validate.ps1 -GuestPasswordPlaintext <password>
.\scripts\hyperv-proof-chrome.ps1 -GuestPasswordPlaintext <password>
```

For Hyper-V bench or HLK workflow changes, also include whether you ran:

```powershell
.\scripts\hyperv-clean-checkpoint.ps1 -GuestPasswordPlaintext <password> -ForceRefresh -EnableSsh
.\scripts\hyperv-clean-validate.ps1 -GuestPasswordPlaintext <password> -RequireHlkClient
.\scripts\hyperv-hlk-preflight.ps1 -GuestPasswordPlaintext <password> -ControllerName <controller>
```

## Pull requests

Keep pull requests focused.

PRs should include:

1. summary of change
2. why change was needed
3. affected area
4. manual testing performed
5. screenshots or logs when UI or install flow changed

If change updates public behavior, also update:

- `README.md` for quick-start impact
- GitHub wiki pages for long-form behavior
- `CHANGELOG.md` when user-visible

## Commit messages

Use Conventional Commits where practical:

- `feat`
- `fix`
- `docs`
- `build`
- `refactor`
- `test`
- `chore`

Examples:

- `docs: add repo community health files`
- `fix(driver): retry property-set bridge after reconnect`
- `build: stage signed driver package from root script`

## Questions and support

- use existing GitHub wiki pages first
- use public issues for non-sensitive questions
- use `SECURITY.md` path for vulnerabilities or sensitive findings
