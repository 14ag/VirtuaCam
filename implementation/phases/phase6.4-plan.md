# Phase 6.4 Plan: Driver/App Coupling Completion (Phase 1 + 4 + 5)

## Summary
This phase documents coupling work added after Phase 2/3 bridge + tray lifecycle changes.  
Goal: make `avshws.sys`, `VirtuaCam.exe`, `VirtuaCamProcess.exe`, and installer cooperate for auto-recovery + auto-launch flow.

## Implemented Changes
- **Driver property surface extended**
  - Added property IDs in `driver-project/Driver/avshws/customprops.h`:
    - `VIRTUACAM_PROP_FRAME = 0`
    - `VIRTUACAM_PROP_CONNECT = 1`
    - `VIRTUACAM_PROP_DISCONNECT = 2`
  - Added handlers in `driver-project/Driver/avshws/filter.cpp`:
    - `SetConnect` -> marks client connected.
    - `SetDisconnect` -> marks client disconnected.
  - Property table now exposes all 3 IDs on existing custom prop set GUID.

- **Driver fallback + heartbeat behavior**
  - Added default blue BGR24 frame buffer in `driver-project/Driver/avshws/hwsim.cpp`.
  - Added client state fields/lock/event in `driver-project/Driver/avshws/hwsim.h`.
  - `FakeHardware()` now chooses frame source:
    - connected client frame when healthy.
    - default blue frame when disconnected/stale.
  - Added stale-client heartbeat timeout (`2s`) to auto-fallback.
  - Added named notification event support with `IoCreateNotificationEvent` using:
    - `\\BaseNamedObjects\\VirtuaCamClientRequest`
  - Added camera state notifications:
    - `RUN` + no client -> signal event.
    - `STOP` -> clear event.

- **Device + pin glue for new driver behavior**
  - Added passthrough methods in `driver-project/Driver/avshws/device.h/.cpp`:
    - `ConnectClient`
    - `DisconnectClient`
    - `NotifyCameraState`
  - Added pin state hooks in `driver-project/Driver/avshws/capture.cpp`:
    - notify stop in `KSSTATE_STOP`
    - notify run in `KSSTATE_RUN`

- **VirtuaCamProcess watcher mode**
  - Extended `software-project/src/VirtuaCam/Process.cpp`:
    - If no `--type`, run watcher mode.
    - Watcher opens `VirtuaCamClientRequest` event.
    - On signal, checks if `VirtuaCam.exe` running.
    - If not, launches `VirtuaCam.exe /startup`.
  - Exe path lookup order:
    - `HKLM\SOFTWARE\VirtuaCam\VirtuaCamExe`
    - fallback to sibling `VirtuaCam.exe`.

- **Installer registry/startup integration**
  - Updated `install-all.ps1`:
    - Adds `HKLM\SOFTWARE\VirtuaCam` values:
      - `InstallDir`
      - `VirtuaCamExe`
      - `ProcessExe`
    - Adds HKCU Run entries:
      - `VirtuaCamProcess`
      - `VirtuaCam` (`/startup`)
    - Adds `-Uninstall` switch to remove Run + VirtuaCam registry entries.

## Validation Run
- Driver build passed:
  - `driver-project/build-driver.ps1`
- Software build passed:
  - `software-project/build.ps1`
- `install-all.ps1` parameter surface verified includes `-Uninstall`.

## Notes / Boundaries
- This phase documents integration work only; no rollback of prior Phase 2/3 changes.
- Driver uses legacy AVStream sample architecture, so event signaling done with notification event object (`IoCreateNotificationEvent`) for WDK compatibility.
- Future runtime QA still needed for full end-to-end camera-open auto-launch behavior on real target machine.
