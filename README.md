# Virtual Webcam v2

Windows virtual camera stack for Windows built from:

- `driver-project/`: AVStream kernel camera driver (`avshws`)
- `software-project/`: tray app, broker, producer host, and user-mode driver bridge

Repository goal: build and install a virtual camera that appears to Windows camera clients, while feeding frames through a direct user-mode-to-driver path.

## What is here

- `build-all.ps1`: builds software and driver, then stages artifacts into `output/`
- `install-all.ps1`: installs staged driver package, registers `DirectPortClient.dll`, and configures startup
- `software-project/`: CMake-based user-mode code
- `driver-project/`: Visual Studio / WDK driver code
- `implementation/`: plans, audits, workflow notes, and execution logs
- `wiki/`: source-of-truth long-form project documentation

## Quick start

Requirements:

1. Windows 10 or Windows 11
2. Visual Studio 2022 with MSBuild and C++ workloads
3. Windows SDK and WDK
4. CMake 3.20 or newer
5. Git

Build:

```powershell
.\build-all.ps1
```

Install from elevated PowerShell:

```powershell
.\install-all.ps1
```

If installer reports `TESTSIGNING is OFF`, enable it and reboot:

```powershell
bcdedit /set testsigning on
```

Run:

1. Start `output\VirtuaCam.exe`
2. Pick a source from tray menu
3. Select the virtual camera in your target app

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

## Documentation

Long-form docs live in wiki repo pages, not duplicated under `docs/`:

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
- [Repository Metadata Draft](REPOSITORY_METADATA.md)
- [Repository Writing Checklist](REPOSITORY_WRITING_CHECKLIST.md)

## License

Root repository is MIT-licensed. See [LICENSE](LICENSE).

Subproject license files are preserved in:

- `software-project/LICENSE`
- `driver-project/LICENSE`
