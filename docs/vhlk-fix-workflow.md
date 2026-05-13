# vHLK Fix Workflow

This checklist tracks the `vhlk-fixes` branch. Run stages in order. Do not run full vHLK during fix batches. After driver-test gates pass, run failed-only vHLK with a test-name list.

## Current Baseline

- Latest saved vHLK run: `test-reports/vhlk-oneclick-20260513-021033`.
- Saved result: `113` total, `26` passed, `77` failed, `7` not run, `2` queued, and `1` running when the controller/session broke.
- Complete local failed-name fallback: `test-reports/vhlk-oneclick-20260512-202918/failed-test-names.txt` with `106` names.
- Use controller export first when available. Use the fallback list only if controller export is unavailable.

## Stage 0 - Rules And Inputs

- [x] Stay on branch `vhlk-fixes`.
- [x] Do not resume aborted vHLK from this chat.
- [x] Preserve existing user changes: `Probe-VMState.ps1` is user-created, and `next task2.txt` was already deleted before this pass.
- [x] Keep vHLK out of fix-batch validation.
- [x] Use PowerShell automation and `.env` VM credentials.
- [x] Use PDF TOC/first pages before citing PDFs for driver changes. No new driver-side PDF-backed change was made in this pass.

Checkpoint: proceed only when repo state and rules are understood.

## Stage 1 - Local Whitebox Gate

Run:

```powershell
.\scripts\test-vhlk-runner-flow.ps1
.\scripts\test-code-review-20260511.ps1
.\scripts\test-frame-ex-abi.ps1
.\scripts\test-ai-window-cli.ps1
.\scripts\build-all.ps1 -Clean
```

Checklist:

- [x] Parsed changed/key PowerShell scripts: `hyperv-common.ps1`, `run-vhlk-tests.ps1`, `run-vhlk-smoke-3tests.ps1`, `test-driver-dshow-probe.ps1`, `hyperv-proof-windows-camera.ps1`, `hyperv-proof-chrome.ps1`, `build-all.ps1`, and `install-all.ps1`.
- [x] `test-vhlk-runner-flow.ps1` passed.
- [x] `test-code-review-20260511.ps1` passed after adding Chrome proof `.env` coverage.
- [x] `test-frame-ex-abi.ps1` passed.
- [x] `test-ai-window-cli.ps1` added for `VirtuaCam.exe --windows`.
- [x] `build-all.ps1 -Clean` passed and staged `output/` artifacts.

Checkpoint: fix local script/code failures before any VM gate.

## Stage 2 - Driver-Test Gate

Run:

```powershell
.\scripts\test-driver-dshow-probe.ps1 -Modes list,yuy2,nv12,rgb32,video2
.\scripts\hyperv-proof-windows-camera.ps1 -VmName driver-test -CheckpointName clean -CaptureBackend wgc
.\scripts\hyperv-proof-chrome.ps1 -VmName driver-test -CheckpointName clean -ArtifactRoot test-reports\playwright\browser-proof-<timestamp> -SourceWindowMode Notepad -CaptureBackend printwindow
```

Checklist:

- [x] DirectShow probe passed `list`, `yuy2`, `nv12`, `rgb32`, and `video2`.
  Artifact: `test-reports/driver-test-dshow-20260513-064330/summary.json`.
- [x] Windows Camera proof passed with WGC source.
  Artifact: `test-reports/windows-camera/20260513-064935/windows-camera-proof.json`.
- [x] Browser proof passed at `1920x1080`.
  Artifact: `test-reports/playwright/browser-proof-20260513-074810/vm-webcam-proof.json`.
- [x] Browser proof harness fixed to use `.env` credentials noninteractively.
- [x] Browser proof harness fixed to wait for settled post-reboot interactive readiness.
- [x] Browser/hold readiness windows increased from `90` seconds to `240` seconds so scheduled task start delay does not consume the proof window.

Checkpoint: do not export/run vHLK until all three driver-test gates pass.

## Stage 3 - Failed-Only vHLK Prep

Checklist:

- [x] Export current failed vHLK test names from the controller if possible.
  Artifact: `test-reports/vhlk-failed-export-20260513-075545/failed-test-names.txt`.
- [x] If controller export is unavailable, use fallback list `test-reports/vhlk-oneclick-20260512-202918/failed-test-names.txt`.
  Status: controller export succeeded, so fallback was not used.
- [ ] Record any impossible lab/tool blockers under `docs/` before skipping them.
  Status: no new vHLK blocker hit in this pass.

Checkpoint: review exported failed-name list before queuing failed-only vHLK.

## Stage 4 - Failed-Only vHLK Run

Run only after Stage 3:

```powershell
.\scripts\run-vhlk-tests.ps1 -TestNameListPath <failed-list>
```

Checklist:

- [x] Run failed-only vHLK, not full vHLK.
  Artifact: `test-reports/vhlk-oneclick-20260513-080058`.
- [x] Stop for research at 2 failures.
  Artifact: `test-reports/vhlk-oneclick-20260513-080058/latest-status.json`.
- [ ] Stop immediately when 10 tests fail in one run.
  Status: hard stop is automated with `-StopOnFailureCount 10`; latest run stopped at 2 failures first.
- [ ] Patch code, rerun Stage 1 and Stage 2, then re-enter failed-only vHLK loop.
  Status: pending next vHLK result.
- [x] Failed-only monitor counts only selected tests for `Total`, `Completed`, pass/fail, queue, and groups.
  Status: fixed after `test-reports/vhlk-oneclick-20260513-091740` showed `2` selected tests passed while the old monitor still waited on `111` unrelated project tests.
- [x] Failed-only clean/cancel is scoped to selected tests.
  Status: fixed so failed-only reruns do not wipe unrelated project results into `NotRun`.
- [x] Batch menu local gate stops on first failed PowerShell gate, and selector fails clearly above nine options.
- [x] Failed-only wrapper exits cleanly when the exported failed-name list is empty.

Checkpoint: no full vHLK until failed-only loop is clean or explicitly approved.

## Stage 5 - Research Gate

- [x] PDF research completed for the two current driver-profile failures.
  Artifact: `docs/vhlk-camera-profiles-research-20260513.md`.
- [x] Web research completed because the iteration reached 2 vHLK failures.
  Artifact: `docs/vhlk-camera-profiles-research-20260513.md`.
- [x] Camera profile runtime/control patch prepared.
- [x] Camera profile INF/runtime drift test added: `scripts/test-camera-profile-contract.ps1`.
- [x] Failed-only vHLK automation added:
  - `scripts/export-vhlk-failed-tests.ps1`
  - `scripts/install-driver-for-vhlk.ps1`
  - `scripts/run-vhlk-failed-only.ps1`
  - `scripts/run-vhlk-tests.ps1 -ResearchGateFailureCount 2 -StopOnFailureCount 10`
  - `batch-scripts/vhlk-tasklist.bat` using `[selector](../batch-scripts/binaries/selector.bat)`

## Stage 6 - DUT vHLK Install Gate

- [x] Confirmed `test-reports/vhlk-oneclick-20260513-090356` did not validate the patched package because `driver-test` had no `ROOT\AVSHWS` package after proof restore.
- [x] Added non-reverting install automation for failed-only vHLK: `scripts/install-driver-for-vhlk.ps1`.
- [x] Added selected-test monitoring so failed-only runs complete when the selected list completes; whole-project size is still stored as `ProjectTotal`.
- [ ] Rerun failed-only vHLK after wrapper installs staged package into DUT.
  Status: pending next run.

## References

Downloaded copies live in `pdfs/mslearn-vhlk-fixes/`.

- Camera profiles: `camera-profiles.pdf`
- Camera controls and profile control: `camera-driver-controls.pdf`, `ksproperty-cameracontrol-extended-profile.pdf`
- Camera profile functions and structures: `camera-driver-functions.pdf`, `camera-driver-structures.pdf`
- AVStream formats and negotiation: `ks-data-formats-and-data-ranges.pdf`, `data-range-intersections-in-avstream.pdf`, `selecting-a-stream-format.pdf`, `tagks-datarange-video.pdf`
- Capture/preview categories: `capture-preview-still-category.pdf`
- DirectShow `IAMStreamConfig`: `iamstreamconfig.pdf`, `iamstreamconfig-setformat.pdf`
- INF validation and driver isolation: `validating-windows-drivers.pdf`, `porting-inf-to-windows-driver.pdf`, `infverif-h.pdf`, `dch-principles-best-practices.pdf`
