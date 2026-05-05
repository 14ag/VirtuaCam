# TODO

Last audited: 2026-05-05

Source checked: `next task.txt`

## Remaining Checklist

- [ ] Make Windows Camera show live VirtuaCam footage.
  - Latest host Camera proof still failed: `test-reports/host-windows-camera/20260505-082513`.
  - Result: `Success=false`, `DriverVer=05/05/2026,6.0.5600.44`, `NonDarkRatio=0`.
  - Driver counters rose, so Camera opens device but preview surface still does not show footage.

- [ ] Verify user-run HTML smoke after latest default-feed/grid/preview fixes.
  - User will run this manually.
  - Expected: when `VirtuaCam.exe` is closed and `VirtuaCamWatcher` is running, opening webcam in browser should cause `VirtuaCam.exe /startup` to appear and frames to flow.

- [ ] Investigate repeated `DriverBridge::SendFrame requested retry after reinitialize`.
  - MediaCapture eventually passes, but warm-up retries are noisy and may hide timing faults.
  - Latest passing run: `test-reports/host-media-capture-auto/20260505-085045`.

- [ ] Fix or retire Auto/D3D surface-copy branch in `scripts/host-media-capture-auto-proof.ps1`.
  - CPU modes pass.
  - Auto modes still fail with COM `IDirect3DSurface` conversion error.

- [ ] Run VM smoke after host Windows Camera proof passes.
  - Required VM: `driver-test`.
  - Keep verifier/crash dumps/logs under `test-reports`.

- [ ] Run vHLK only after smoke passes.
  - Target: `Virtual Camera Driver`, `ROOT\AVSHWS\0000`, class `Camera`.
  - Select appropriate playlist XML from vHLK VM Desktop.

## Completed Checklist

- [x] Fixed producer canvas path to stable `1920x1080` canvas with cover/crop scaling.
- [x] Set default startup source to auto-discovery grid / `SourceMode::Consumer`.
- [x] Implemented native tray menu path using `TrackPopupMenuEx`.
- [x] Fixed tray Preview command dispatch ordering.
- [x] Made Preview window taskbar-visible and restored/foregrounded when reopened.
- [x] Added D3D hardware-to-WARP fallback for Preview window.
- [x] Fixed Preview shared texture open path to use `OpenSharedResourceByName`.
- [x] Implemented actual auto-discovery grid compositing in `Multiplexer.cpp`.
- [x] Changed no-source/default broker frame upload so driver receives the same generated Off feed instead of waiting forever for `Connected`.
- [x] Verified watcher service auto-start path exists: `VirtuaCamWatcher` registers driver client-request event and launches `VirtuaCam.exe /startup` when `VirtuaCam.exe` is absent.
- [x] Restarted `VirtuaCamWatcher`; service is currently `Running` and `Automatic`.
- [x] Scripts are under `scripts/`; audit found zero repo `.ps1` files outside `scripts` except excluded dependencies/git.
- [x] Test reports/log roots use `test-reports`; stale `.github` `output\logs` mention was corrected.
- [x] `output` currently contains staged build/install components only.
- [x] Build passed: `scripts/build-all.ps1`.
- [x] Install/rebind passed: `scripts/install-all.ps1 -ForceDriverRebind -SkipDllRegister`.
- [x] Preview menu proof passed: `test-reports/host-preview-menu/20260505-085040`.
- [x] MediaCapture proof passed CPU live-frame path: `test-reports/host-media-capture-auto/20260505-085045`.

## Source Mode Notes

- `Source: Off`: renders only the generated no-signal/off feed. It does not discover producers or draw tiles.
- `Source: Auto-Discovery Grid`: keeps scanning for DirectPort producers and draws all discovered feeds into a grid. If none exist, the driver now gets the same generated Off feed as its default frame.
