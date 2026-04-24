# Phase 1: Understand & Audit

Goal: Confirm the avshws driver is functional and audit the codebase for MediaFoundation (MF) dependencies.

- [ ] 1.1 Confirm avshws driver is installed and `PROPSETID_VIDCAP_CUSTOMCONTROL` device appears under `CLSID_VideoInputDeviceCategory`
- [ ] 1.2 Confirm `DriverBridge::SendFrame()` reaches `IKsPropertySet::Set()` and `CHardwareSimulation::SetData()`
- [ ] 1.3 Audit files including `mfvirtualcamera.h` or MF-only APIs (`IMFVirtualCamera`, `MFCreateVirtualCamera`, etc.)
- [ ] 1.4 Check whether `winrt::init_apartment` is required outside of MF path
- [ ] 1.5 Check whether `MFStartup` / `MFShutdown` are needed by remaining components
