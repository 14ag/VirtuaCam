# VirtuaCam Kernel Driver

Windows virtual camera driver using AVStream minidriver (avshws). Frame sink for **VirtuaCam v2**.

## Architecture
- **Type**: Kernel-mode driver (AVStream).
- **Path**: Direct driver communication (bypasses Media Foundation).
- **Communication**: Custom `IKsPropertySet` on AVStream filter.
- **Buffer**: RGB24, 1280x720, 30fps.

## Interface
- **GUID**: `{CB043957-7B35-456E-9B61-5513930F4D8E}`
- **ID**: `0`
- **Logic**: User-mode app pushes frame buffer via `Set` property. Driver copies to output pin.

## Build
Use the repository root build script:

```powershell
.\build-all.ps1
```

For driver-only iteration, still use the same script:

```powershell
.\build-all.ps1 -SkipSoftware
```

Staged artifacts land in `v2/output/`.

## Installation
Use the repository root install script:

```powershell
.\install-all.ps1
```

If needed first:

```powershell
bcdedit.exe /set testsigning on
```


## UserMode Software
Main suite in `software-project/`.
- `VirtuaCam.exe`: Primary UI.
- `DriverBridge.cpp`: Library for direct driver frame push.
