- [x] Remove the unused mfvirtualcamera.h include from pch.h. Done: MF virtual-camera-only GUID mappings were removed from Tools.cpp and mfvirtualcamera.h is now included only for legacy builds.

- [x] Task 3.2 no longer deferred:
      `DirectPortMFCamera` and `DirectPortMFGraphicsCapture` are no longer runtime
      dependencies of `VirtuaCamProcess.exe` (camera/capture producers are built-in).

- [x] Task 3.4 no longer deferred:
      `cppwinrt` is optional and only required when enabling legacy MF/WinRT components.
