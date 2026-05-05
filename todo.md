# TODO

Last audited: 2026-05-05

Source checked: `next task.txt`

## Remaining Checklist

- [ ] Make Windows Camera show live VirtuaCam footage.
  - Latest host Camera proof still failed: `test-reports/host-windows-camera/20260505-130049`.
  - Result: `Success=false`, `DriverVer=05/05/2026,6.0.5600.44`, `NonDarkRatio=0`.
  - Driver counters prove Windows Camera opens and streams the device: `hw=2`, `lastFill=0`, completed frames rising. YUY2-only and RGB32-only experiments both still showed a blank Camera preview, so the failed format narrowing was reverted and full YUY2/NV12/RGB32 support restored.
  - Research note saved: `implementation/camera-driver-ecosystem-check-20260505-130756.md`.
  - Next path: compare VirtuaCam against Microsoft `AvsCamera` for INF metadata, DeviceMFT behavior, allocator framing, sample timing, `KS_FRAME_INFO`, and stream pointer lifecycle. Avoid more format-only toggles unless probe logs prove negotiation mismatch.

- [ ] Verify user-run HTML smoke after latest default-feed/grid/preview fixes.
  - User will run this manually.
  - Expected: when `VirtuaCam.exe` is closed and `VirtuaCamWatcher` is running, opening webcam in browser should cause `VirtuaCam.exe /startup` to appear and frames to flow.

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
- [x] Retired flaky Auto/D3D surface-copy branch from default `scripts/host-media-capture-auto-proof.ps1` run; use `-IncludeAutoSurfaceProbe` only for optional diagnostics.
- [x] Investigated repeated `DriverBridge::SendFrame requested retry after reinitialize`; it was expected pre-stream warm-up (`hw=0 client=1 reason=1`) with misleading/noisy app logging. Log now says waiting for driver stream and throttles to first/every 120 retries.
- [x] Re-ran host Windows Camera proof after YUY2-only and RGB32-only driver format experiments; both still blank. Reverted format narrowing, kept reports under `test-reports`, and preserved full advertised format support.
- [x] Latest MediaCapture smoke passed after final restore: `test-reports/host-media-capture-auto/20260505-130135`.

## Source Mode Notes

- `Source: Off`: renders only the generated no-signal/off feed. It does not discover producers or draw tiles.
- `Source: Auto-Discovery Grid`: keeps scanning for DirectPort producers and draws all discovered feeds into a grid. If none exist, the driver now gets the same generated Off feed as its default frame.
