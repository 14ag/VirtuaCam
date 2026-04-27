# Contributing

Thanks for contributing to Virtual Webcam v2.

## Before you start

Read:

- `README.md`
- `wiki/Getting-Started.md`
- `wiki/Architecture.md`
- `wiki/Development-Guide.md`

Use `implementation/` notes when you work on startup flow, producer flow, packaging, or AVStream behavior. That folder contains project rationale not fully captured in code comments.

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
.\build-all.ps1
.\software-project\build.ps1
.\driver-project\build-driver.ps1
```

Installer command:

```powershell
.\install-all.ps1
```

## Development expectations

- keep changes grounded in current repo architecture
- update docs in same change when behavior changes
- do not remove or rewrite implementation notes unless change makes them obsolete
- preserve user changes outside your task scope
- test manually when you touch build, install, startup, producer selection, or driver bridge behavior

## Validation expectations

No automated test suite is checked in today. For changes that affect behavior, manual validation is expected:

1. build affected component or full repo
2. install if driver or packaging changed
3. launch `VirtuaCam.exe`
4. select a source
5. verify target app can open camera

Good issue or PR notes include what you tested and what you did not test.

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
- `wiki/` pages for long-form behavior
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

- use existing wiki pages first
- use public issues for non-sensitive questions
- use `SECURITY.md` path for vulnerabilities or sensitive findings
