# Virtual Webcam

Windows virtual camera stack for Windows built from:

- `driver-project/`: AVStream kernel camera driver (`avshws`)
- `software-project/`: tray app, broker, producer host, and user-mode driver bridge

Repository goal: build and install a virtual camera that appears to Windows camera clients, while feeding frames through a direct user-mode-to-driver path.

## What is here

- `scripts\build-all.ps1`: single build entrypoint; builds software and driver and stages everything into `output/`
- `scripts\install-all.ps1`: single install entrypoint; installs only from `output/`, registers `DirectPortClient.dll`, and configures startup
- `scripts\clean-output.ps1`: removes `output/` so the next build recreates a fresh staged package
- `software-project/`: CMake-based user-mode code
- `driver-project/`: Visual Studio / WDK driver code
- `implementation/`: retained WDK and AVStream audit references
- `wiki/`: current source-of-truth long-form project documentation

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

3. Build the full staged package with the single build script:

```powershell
.\scripts\build-all.ps1
```

This script is the only build entrypoint. It always stages the installable package into `.\output`.

Useful variants stay on the same script:

```powershell
.\scripts\build-all.ps1 -Clean
.\scripts\build-all.ps1 -SkipDriver
.\scripts\build-all.ps1 -SkipSoftware
```

4. If the installer later reports `TESTSIGNING is OFF`, enable it once and reboot:

```powershell
bcdedit /set testsigning on
```

5. Open an elevated PowerShell window in the repo root and install from the single install script:

```powershell
.\scripts\install-all.ps1
```

This script is the only install entrypoint. It always installs from `.\output`.

6. Launch the tray app:

```powershell
.\output\VirtuaCam.exe
```

7. Use the tray icon to choose a source.

8. Open the target app and select `VirtuaCam` or `Virtual Camera Driver` as the camera.

Staged artifact names are centralized in `scripts/tools/artifact-manifest.ps1`, which is shared by the build and install scripts.

## Validation

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
  -> IKsPropertySet(Set)
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

Long-form current docs live in wiki repo pages, not duplicated under `docs/`:

- [Wiki Home](wiki/Home.md)
- [Getting Started](wiki/Getting-Started.md)
- [Architecture](wiki/Architecture.md)
- [Development Guide](wiki/Development-Guide.md)
- [Troubleshooting](wiki/Troubleshooting.md)

If published on GitHub, wiki URL is:

- `https://github.com/14ag/VirtuaCam/wiki`

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
