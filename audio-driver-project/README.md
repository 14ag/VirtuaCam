# VirtuaCam Microphone Driver

This project builds the capture-only `VirtuaCam Microphone` endpoint.

It is a pass-through endpoint, not an audio mixer. The kernel driver exposes one WaveRT capture device and reads fixed `48 kHz / 16-bit / stereo PCM` packets from `\\.\VirtuaCamMicBridge`. The VirtuaCam app captures the selected Windows audio source through WASAPI and writes those packets to the driver.

Routing lives in user mode:

- `Audio Source > Auto` captures `Stereo Mix` when available.
- Camera passthrough in Auto mode switches to the matching plugged USB webcam microphone when one is detected.
- Manual audio selection keeps the selected capture device name in `HKCU\Software\VirtuaCam\Settings`.

The driver does not expose a render endpoint. If the app is not feeding packets, the endpoint emits silence and increments underrun counters exposed through `IOCTL_VIRTUACAM_MIC_GET_STATUS`.

This driver is derived from the Microsoft Simple Audio Sample Device Driver and keeps that sample's MS-PL license in `LICENSE-MS-PL.txt`.
