# VirtuaCam

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Platform: Windows 10+ / 11](https://img.shields.io/badge/Platform-Windows_10%2B_/_11-blue.svg) ![Language: C++20](https://img.shields.io/badge/Language-C++20-orange.svg)

VirtuaCam is a modern, high-performance virtual camera system for Windows. It enables low-latency, zero-copy video injection from external DirectX applications, games, or other video sources directly into a kernel-mode driver path. This exposes them as a standard webcam for use in applications like Zoom, Microsoft Teams, OBS, and Discord.

## Architecture: Direct-to-Driver Path

VirtuaCam uses a decoupled architecture to achieve maximum performance and stability:

`[Producer (Built-in or External)]` ---> `[Shared D3D11 Texture & Fence]` ---> `[VirtuaCam Broker]` ---> `[DriverBridge]` ---> `[avshws Kernel Driver]`

This design avoids the overhead of the Media Foundation virtual camera pipeline by pushing raw frames directly from the user-mode broker to a kernel-mode AVStream minidriver.

## Key Components

1.  **VirtuaCam Broker (`DirectPortBroker.dll`):** Composites video feeds from multiple sources on the GPU.
2.  **VirtuaCam Process (`VirtuaCamProcess.exe`):** A lightweight host for built-in producers (Camera and Screen Capture).
3.  **Driver Bridge:** A user-mode interface that handles communication with the kernel driver.
4.  **avshws Driver:** The kernel-mode component that presents the video feed as a hardware camera device to the system.

## Features

*   **Zero-Copy GPU Path:** Frames stay on the GPU from capture to driver submission.
*   **Built-in Producers:** High-performance screen capture and physical camera passthrough are built directly into the process host.
*   **Kernel-Mode Output:** Appears as a real hardware device, bypassing virtual camera detection in many apps.
*   **Tray Controller:** Manage sources, layouts (Grid/PIP), and preview from a professional tray interface.

## Build and Run

Use the repository root scripts. This subproject does not have a separate public build or install path.

1. From the repo root, run `.\build-all.ps1`.
2. From an elevated PowerShell window in the repo root, run `.\install-all.ps1`.
3. Launch `.\output\VirtuaCam.exe`.
4. Select a source from the tray icon menu.
5. Open the target app and select `VirtuaCam` or `Virtual Camera Driver` as the camera.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
