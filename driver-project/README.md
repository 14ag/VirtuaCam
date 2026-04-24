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
Use `build-driver.ps1` (requires WDK + VS 2022).
Artifacts land in `v2/output/driver/package`.

## Installation
1. Enable testsigning: `bcdedit.exe -set TESTSIGNING ON` (requires reboot).
2. Install certificate: Import `VirtualCameraDriver-TestSign.cer` to Trusted Root Certification Authorities.
3. Install driver:
   - Command: `pnputil /add-driver avshws.inf /install`
   - UI: `hdwwiz.exe` (Add legacy hardware).


## UserMode Software
Main suite in `software-project/`.
- `VirtuaCam.exe`: Primary UI.
- `DriverBridge.cpp`: Library for direct driver frame push.
