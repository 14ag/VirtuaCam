# VirtuaCam Kernel Driver

Windows virtual camera driver using the AVStream `avshws` minidriver. It is the camera-device frame sink for **VirtuaCam v2**.

## Architecture
- **Type**: Kernel-mode driver (AVStream).
- **Path**: Direct driver communication (bypasses Media Foundation).
- **Communication**: Custom `IKsPropertySet` on AVStream filter.
- **Buffer**: RGB24, 1280x720, 30fps.
- **Device class**: `Camera`.
- **Hardware ID**: `AVSHWS`.
- **Service name**: `avshws`.

## Interface
- **GUID**: `{CB043957-7B35-456E-9B61-5513930F4D8E}`
- **Property IDs**:
  - `0`: frame upload
  - `1`: connect
  - `2`: disconnect
  - `3`: status
  - `4`: register event
- **Logic**: user-mode app connects, pushes packed BGR24 frame buffers with `Set`, polls status as needed, and disconnects on shutdown.
- **Client-request event**: driver signals `VirtuaCamClientRequest` when camera capture starts without a connected user-mode client.
- **Fallback**: driver can serve a default blue BGR24 frame until live user-mode frames arrive.

## Build
Use the repository root build script:

```powershell
.\scripts\build-all.ps1
```

For driver-only iteration, still use the same script:

```powershell
.\scripts\build-all.ps1 -SkipSoftware
```

Staged artifacts land in `output/`.

## Installation
Use the repository root install script:

```powershell
.\scripts\install-all.ps1
```

If needed first:

```powershell
bcdedit.exe /set testsigning on
```


## UserMode Software
Main suite in `software-project/`.
- `VirtuaCam.exe`: Primary UI.
- `DriverBridge.cpp`: user-mode bridge for direct frame push and driver status.
- `VirtuaCamProcess.exe --service`: watcher service entrypoint installed as `VirtuaCamWatcher`.
