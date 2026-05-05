# VirtuaCam

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Platform: Windows 10+ / 11](https://img.shields.io/badge/Platform-Windows_10%2B_/_11-blue.svg) ![Language: C++20](https://img.shields.io/badge/Language-C++20-orange.svg)

VirtuaCam is the user-mode side of Virtual Webcam v2. It runs the tray controller, producer host, GPU broker, and driver bridge that feed frames into the `avshws` AVStream camera driver.

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
* **Tray controller:** source selection, grid/PIP composition, aspect-ratio selection, and driver status telemetry.
* **Persisted settings:** PIP toggles and aspect ratio are saved in `%LOCALAPPDATA%\VirtuaCam\settings.ini`.
* **Driver geometry sync:** frames are scaled to the active driver format, including `1280x720`, `640x480`, `720x1280`, and `480x640`.

## Build and Run

Use the repository root scripts. This subproject does not have a separate public build or install path.

1. From the repo root, run `.\scripts\build-all.ps1`.
2. From an elevated PowerShell window in the repo root, run `.\scripts\install-all.ps1`.
3. Launch `.\output\VirtuaCam.exe`.
4. Select a source from the tray icon menu.
5. Open the target app and select `VirtuaCam` or `Virtual Camera Driver` as the camera.

Default staged user-mode artifacts are `VirtuaCam.exe`, `VirtuaCamProcess.exe`, `DirectPortBroker.dll`, `DirectPortClient.dll`, and `DirectPortConsumer.dll`.

Aspect ratio is available from `Settings > Aspect Ratio` with `16:9`, `9:16`, `4:3`, and `3:4`. The selected ratio changes how the producer fits content into the fixed driver frame; it preserves source shape and uses black padding instead of stretching.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
