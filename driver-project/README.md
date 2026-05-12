# VirtuaCam Kernel Driver

Windows virtual camera driver using the AVStream `avshws` minidriver. It is the camera-device frame sink for **VirtuaCam v2**.

## Architecture
- **Type**: Kernel-mode driver (AVStream).
- **Path**: Direct driver communication (bypasses Media Foundation).
- **Communication**: Custom `IKsPropertySet` on AVStream filter.
- **Buffer**: legacy BGR24 input side channel sized to the active capture format, plus FrameEx uploads for BGRA32/RGB32/NV12 when negotiated. Default is 1280x720 at 30fps; the KS capture pin also advertises 640x480, 720x1280, and 480x640 formats for HLK and portrait clients.
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
  - `5`: preferred aspect
  - `6`: allowed aspect mask
  - `7`: FrameEx upload (`VIRTUACAM_FRAME_EX_HEADER`)
- **Logic**: user-mode app connects, queries driver status, pushes FrameEx BGRA32/NV12 buffers when supported, falls back to packed BGR24 buffers matching the active stream geometry, polls status as needed, and disconnects on shutdown.
- **Shared ABI**: user-mode and driver constants live in `shared/VirtuaCamDriverAbi.h`; the v1 status prefix remains fixed while v2 adds output format, stride, upload-format mask, and last upload format fields.
- **Client-request event**: driver signals `VirtuaCamClientRequest` when camera capture starts without a connected user-mode client.
- **Fallback**: driver can serve a default blue BGR24 frame until live user-mode frames arrive.
- **Aspect policy**: preferred aspect and allowed aspect mask reorder the static capture data ranges for the next stream open while keeping unsupported masks from disabling all formats.

## Build
Use the repository root build script:

```powershell
.\scripts\build-all.ps1
```

The script runs a clean build by default and stages the full package in `output/`.

The staged INF uses `PnpLockdown=1`, DIRID `13`, and `ServiceBinary=%13%\avshws.sys` for current package-isolation validation.

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
