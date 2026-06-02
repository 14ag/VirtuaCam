# VirtuaCam

Windows virtual camera stack for Windows built from:

- `driver-project/`: AVStream kernel camera driver (`avshws`)
- `software-project/`: tray app, broker, producer host, and user-mode driver bridge

Repository goal: build and install a virtual camera that appears to Windows camera clients, while feeding frames through a direct user-mode-to-driver path.

## What is here

- `scripts\build-all.ps1`: single build entrypoint; builds software and driver and stages everything into `output/`
- `output\VirtuaCamSetup.exe`: single install entrypoint; installs only from `output/`, registers `DirectPortClient.dll`, and configures startup
- `scripts\clean-output.ps1`: removes `output/` so the next build recreates a fresh staged package
- `scripts\test-code-review-20260511.ps1`: whitebox checks for the 2026-05-11 code-review fixes
- `scripts\test-performance-audit.ps1`: whitebox/runtime checks for the 2026-05-11 performance-audit fixes
- `scripts\test-capture-source-menu-contract.ps1`: whitebox check for the tray capture-source menu contract
- `scripts\run-vhlk-tests.ps1`: vHLK queue/monitor helper that reads controller credentials from `.env`
- `scripts\run-vhlk-failed-only.ps1`: one-call failed-only vHLK entry point; exports failed names, filters documented blockers, fresh-starts VMs, installs the DUT driver, runs selected tests, and writes status artifacts
- `shared\`: driver/user-mode ABI constants and structures shared by both projects
- `software-project/`: CMake-based user-mode code
- `driver-project/`: Visual Studio / WDK driver code
- `implementation/`: retained WDK and AVStream audit references
- `wiki/`: optional local checkout of the GitHub wiki; ignored by this repository

## Clone to first camera session

1. Clone the repository and enter it:

```powershell
git clone https://github.com/14ag/VirtuaCam.git
cd VirtuaCam
```

2. Check prerequisites.

Requirements:

1. Windows 10 or Windows 11
2. Visual Studio 2022 with MSBuild and C++ workloads
3. Windows SDK and WDK
4. CMake 3.20 or newer
5. Git

## Build

Build the full staged package with the single build script:

```powershell
.\scripts\build-all.ps1
```

This script is the only build entrypoint. It always stages the installable package into `.\output`.

Useful variants stay on the same script:

```powershell
.\scripts\build-all.ps1
```

Clean is the default behavior. The script always builds and stages the full package.
During driver signing the build creates `.driver-package-work` as a temporary INF/catalog workspace. The final installable files are copied to `.\output`; installers should not read from `.driver-package-work`.

## Install

If the installer later reports `TESTSIGNING is OFF`, enable it once and reboot:

```powershell
bcdedit /set testsigning on
```

Open an elevated PowerShell window in the repo root and install from the setup wizard:

```powershell
.\output\VirtuaCamSetup.exe --install --quiet --json .\output\logs\wizard\install.json
```

The setup wizard is the only install entrypoint. It always installs from its own package directory.

## Run

Launch the tray app:

```powershell
.\output\VirtuaCam.exe
```

Use the tray icon to choose a video source, audio source, and aspect ratio.

Open the target app and select `VirtuaCam` or `Virtual Camera Driver` as the camera.

Staged artifact names are centralized in `scripts/tools/artifact-manifest.ps1`, which is shared by the build and install scripts.

## Tray settings

The tray menu has two source modes that can look similar when no producers are active:

- `Video Source > Off`: deliberately sends the generated off/default feed and ignores discovered producer streams.
- `Video Source > Auto-Discovery Grid`: scans for available DirectPort producer streams and tiles them into a grid. If no producers are found, it falls back to the generated off/default feed.

Normal tray launch exposes Show Preview, Video Source, Audio Source, Aspect Ratio, About, and Exit. Launch with `-debug` to expose PIP, aspect-ratio masks, diagnostics, logs, and proof tool launchers under `Advanced`.

The `Video Source` menu is grouped in this order:

```text
windows and games
displays
video capture devices
Image
Video
```

Aspect ratio is controlled from:

```text
Aspect Ratio > 16:9 | 9:16 | 4:3 | 3:4
```

VirtuaCam stores these settings in:

```text
HKCU\Software\VirtuaCam\Settings
```

The registry settings include `AudioCaptureDeviceName`. The tray menu exposes `Audio Source`, with `None` and active WASAPI capture devices. Startup falls back to `Stereo Mix` when present, and camera passthrough keeps the existing matching-microphone selection behavior.

The driver defaults to `1920x1080`. The tray aspect setting is sent to the driver as the preferred capture format for the next camera stream open:

| Aspect ratio | Preferred output |
| --- | --- |
| `16:9` | `1920x1080` |
| `9:16` | `1080x1920` |
| `4:3` | `1440x1080` |
| `3:4` | `1080x1440` |

The driver keeps `640x480` and `480x640` compatibility ranges. Camera passthrough can restrict the allowed driver aspect mask to formats supported by the physical camera. Sources are scaled as large as possible while preserving source proportions. Empty canvas space uses `#212121` padding.

## Validation

Repository whitebox checks:

```powershell
.\scripts\test-code-review-20260511.ps1
.\scripts\test-frame-ex-abi.ps1
.\scripts\test-performance-audit.ps1 -SkipBuild -SkipRuntime
```

`test-performance-audit.ps1` can also build `VirtuaCam`, `DirectPortBroker`, and `VirtuaCamProcess` and briefly launch `VirtuaCam.exe` when run without skip switches.

Use Hyper-V guest `driver-test` for crash repro, verifier, dump collection, browser proof, and Windows Camera proof. Test artifacts are written under `test-reports\`; `output\` is reserved for staged build/install components.

```powershell
.\scripts\hyperv-clean-checkpoint.ps1 -GuestPasswordPlaintext <password> -ForceRefresh -EnableSsh
.\scripts\hyperv-clean-validate.ps1 -GuestPasswordPlaintext <password>
.\scripts\hyperv-proof-chrome.ps1 -GuestPasswordPlaintext <password>
.\scripts\hyperv-proof-windows-camera.ps1 -GuestPasswordPlaintext <password>
```

Helper entry points:

- `.\scripts\hyperv-driver-loop.ps1`
- `.\scripts\hyperv-kd.ps1`
- `.\scripts\hyperv-collect.ps1`
- `.\scripts\hyperv-enable-ssh.ps1`
- `.\scripts\hyperv-clean-validate.ps1`

HLK client helper:

- `.\scripts\hyperv-hlk-client.ps1`
- `.\scripts\hyperv-hlk-preflight.ps1`
- `.\scripts\run-vhlk-tests.ps1`

Host-side proof helpers:

```powershell
.\scripts\host-preview-menu-proof.ps1
.\scripts\host-windows-camera-proof.ps1
.\scripts\host-windows-camera-display-capture-proof.ps1 -AspectRatio '4:3'
.\scripts\host-windows-camera-aspect-hot-change-proof.ps1 -InitialAspectRatio '9:16' -TargetAspectRatio '4:3'
.\scripts\host-media-capture-auto-proof.ps1
.\scripts\host-media-capture-auto-proof.ps1 -IncludeAutoSurfaceProbe
.\scripts\test-host-camera-passthrough-audio-config.ps1
.\scripts\test-setup-registry-debug.ps1
```

`host-media-capture-auto-proof.ps1` runs the CPU-backed frame-reader path by default. Use `-IncludeAutoSurfaceProbe` when you also want to probe the WinRT `Auto` memory preference path.

AI window enumeration:

```powershell
.\output\VirtuaCam.exe --windows
```

The command writes JSON for windows that can be captured and exits without starting the tray app.

VM-only driver fuzz:

```powershell
.\scripts\test-ks-invalid-buffer-fuzz.ps1 -VmName driver-test
```

The latest failed-only vHLK artifact is `test-reports\vhlk-oneclick-20260516-014142`. It selected 2 tests, completed 2 tests, passed `Camera Driver System Test - MediaCapture - TestEnumerateMediaFrameSourceGroupById`, and failed `Camera Driver Profiles Interface APIs (Device Test)`.

Failed-only vHLK:

```powershell
.\scripts\run-vhlk-failed-only.ps1
```

Full vHLK sanity:

```powershell
.\scripts\run-vhlk-tests.ps1 -PendingStartTimeoutSeconds 300 -TimeoutMinutes 480 -ResearchGateFailureCount 2 -StopOnFailureCount 10 -MaxControllerReconnectFailures 5
```

Suggested bench order:

1. refresh `clean` with `-EnableSsh`
2. validate `clean` with `hyperv-clean-validate.ps1`
3. rerun real proof with `hyperv-proof-chrome.ps1`
4. run Windows Camera proof with `hyperv-proof-windows-camera.ps1`
5. install or confirm HLK client
6. rerun `hyperv-clean-validate.ps1 -RequireHlkClient`
7. run `hyperv-hlk-preflight.ps1`
8. move `driver-test` into HLK Studio pool and start small batches first

## Runtime shape

```text
Producer
  -> shared texture + fence
  -> DirectPortBroker.dll
  -> VirtuaCam.exe / DriverBridge
  -> IKsPropertySet(Set), preferring FrameEx BGRA32/NV12 when supported
  -> avshws.sys
  -> Windows camera client
```

Current staged runtime binaries:

- `VirtuaCam.exe`
- `VirtuaCamProcess.exe`
- `DirectPortBroker.dll`
- `DirectPortClient.dll`
- `DirectPortConsumer.dll`
- `avshws.sys`
- `avshws.inf`
- `avshws.cat`
- `VirtualCameraDriver-TestSign.cer`
- `msvcp140.dll`
- `vcruntime140.dll`
- `vcruntime140_1.dll`

Default packaging does not stage legacy Media Foundation producer DLLs. Camera and window producers are built into `VirtuaCamProcess.exe`; `DirectPortConsumer.dll` is the dynamic producer module kept in the default package.

## Documentation

Long-form current docs live in the separate GitHub wiki repo, not duplicated under `docs/`. When `wiki/` exists locally, it is an ignored wiki checkout.

- [Wiki Home](https://github.com/14ag/VirtuaCam/wiki)
- [Getting Started](https://github.com/14ag/VirtuaCam/wiki/Getting-Started)
- [Architecture](https://github.com/14ag/VirtuaCam/wiki/Architecture)
- [Development Guide](https://github.com/14ag/VirtuaCam/wiki/Development-Guide)
- [Troubleshooting](https://github.com/14ag/VirtuaCam/wiki/Troubleshooting)

## Contributing and project policies

- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Changelog](CHANGELOG.md)

## Cleanup

Generated build artifacts collect under `output/`.
Test reports and proof artifacts collect under `test-reports/`.

For a full reset:

```powershell
.\scripts\clean-output.ps1
```

Root build and install scripts recreate the required package layout on the next run.

## License

Root repository is MIT-licensed. See [LICENSE](LICENSE).

Subproject license files are preserved in:

- `software-project/LICENSE`
- `driver-project/LICENSE`
