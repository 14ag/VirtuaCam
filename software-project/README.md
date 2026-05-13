# VirtuaCam

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Platform: Windows 10+ / 11](https://img.shields.io/badge/Platform-Windows_10%2B_/_11-blue.svg) ![Language: C++20](https://img.shields.io/badge/Language-C++20-orange.svg)

VirtuaCam is the user-mode side of VirtuaCam. It runs the tray controller, producer host, GPU broker, and driver bridge that feed frames into the `avshws` AVStream camera driver.

## Architecture: Direct-to-Driver Path

VirtuaCam uses a direct-to-driver architecture:

`[Producer (Built-in or External)]` ---> `[Shared D3D11 Texture & Fence]` ---> `[VirtuaCam Broker]` ---> `[DriverBridge]` ---> `[avshws Kernel Driver]`

This design avoids the Media Foundation virtual camera output path. The broker composites producer frames on D3D11, then `DriverBridge` converts broker output to the driver frame contract and uploads through the custom KS property set.

## Key Components

1. **VirtuaCam (`VirtuaCam.exe`):** tray controller, source selection, broker lifecycle, and driver upload loop.
2. **VirtuaCam Process (`VirtuaCamProcess.exe`):** built-in camera producer, built-in window capture producer, `DirectPortConsumer.dll` host, and watcher/service mode.
3. **VirtuaCam Broker (`DirectPortBroker.dll`):** D3D11 composition and shared texture/fence publication.
4. **DirectPort Client (`DirectPortClient.dll`):** registerable compatibility DLL kept in the default install path.
5. **Driver Bridge:** user-mode bridge to `avshws.sys` through `IKsPropertySet`.

## Features

* **Direct AVStream output:** frames reach Windows camera clients through `avshws.sys`.
* **Built-in producers:** camera passthrough and window capture run inside `VirtuaCamProcess.exe`.
* **External producer support:** `DirectPortConsumer.dll` remains the default dynamic producer module.
* **Tray controller:** source selection, audio source selection, preview, about, and driver status telemetry.
* **Debug controls:** launching `VirtuaCam.exe -debug` exposes PIP, aspect-ratio masks, diagnostics, logs, and proof tool launchers under `Advanced`.
* **Audio source selection:** active WASAPI capture devices appear under `Audio Source`; camera passthrough keeps the existing matching-microphone selection behavior.
* **Persisted settings:** PIP toggles, aspect ratio, and selected audio capture device are saved in `HKCU\Software\VirtuaCam\Settings`.
* **Driver geometry sync:** frames are scaled to the active driver format, including `1920x1080`, `640x480`, `1080x1920`, and `480x640`.
* **FrameEx driver upload:** `DriverBridge` prefers the shared FrameEx ABI for BGRA32/NV12 uploads when the driver reports support, with legacy BGR24 fallback.

## Build and Run

Use the repository root scripts. This subproject does not have a separate public build or install path.

1. From the repo root, run `.\scripts\build-all.ps1`.
2. From an elevated PowerShell window in the repo root, run `.\scripts\install-all.ps1`.
3. Launch `.\output\VirtuaCam.exe`.
4. Select a source from the tray icon menu.
5. Open the target app and select `VirtuaCam` or `Virtual Camera Driver` as the camera.

Default staged user-mode artifacts are `VirtuaCam.exe`, `VirtuaCamProcess.exe`, `DirectPortBroker.dll`, `DirectPortClient.dll`, and `DirectPortConsumer.dll`.

Aspect ratio is available from `Advanced > Aspect Ratio` when launched with `-debug`, with `16:9`, `9:16`, `4:3`, and `3:4`. The selected ratio is sent to the driver as the preferred capture format for the next stream open (`1920x1080`, `1080x1920`, `640x480`, or `480x640`). The producer preserves source shape and uses black padding when content does not match the selected frame; sources smaller than 1080p are scaled into the 1920x1080 producer canvas.

Audio capture device selection is available from `Audio Source`. The app starts a WASAPI capture session for the selected input and persists the device name in the registry. Startup falls back to `Stereo Mix` when present.

The main frame loop is paced to the app frame interval, skips unchanged broker frame values, and keeps default/off-feed refresh separate from live producer refresh. The broker throttles process discovery, validates expected producer nonces, caches producer manifest mappings, and flushes shared D3D updates before publishing frame values.

Remaining performance boundary: `DriverBridge` still uses a D3D11 staging readback before uploading frames to the driver, and producer shared canvases remain fixed at 1920x1080. The FrameEx ABI reduces format conversion pressure for BGRA32/NV12, but a zero-readback driver/user-mode ABI path for BGRA/RGB32/NV12 upload and negotiated producer canvas sizing remain future work.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
