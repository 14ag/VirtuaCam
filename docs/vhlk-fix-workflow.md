# vHLK Fix Workflow

This checklist tracks the `vhlk-fixes` branch. Cross off an item only after the linked artifact shows the fix is built, installed in `driver-test`, and the related driver-test gate passes. Do not run vHLK during fix batches.

## Current Baseline

- Baseline full run: `test-reports/vhlk-oneclick-20260512-202918/latest-status.json`
- Result: 113 completed, 7 passed, 106 failed.
- Scheduler/lab status is no longer the blocker. Final readiness proof is in `test-reports/vhlk-oneclick-20260512-202918/final-lab-check.json`.
- Representative failure proof is in `test-reports/vhlk-oneclick-20260512-202918/failure-diagnostics/failure-root-cause-summary.json`.

## References

Downloaded copies live in `pdfs/mslearn-vhlk-fixes/`.

- Camera profiles: `camera-profiles.pdf`
- Camera controls and profile control: `camera-driver-controls.pdf`, `ksproperty-cameracontrol-extended-profile.pdf`
- Camera profile functions and structures: `camera-driver-functions.pdf`, `camera-driver-structures.pdf`
- AVStream formats and negotiation: `ks-data-formats-and-data-ranges.pdf`, `data-range-intersections-in-avstream.pdf`, `selecting-a-stream-format.pdf`, `tagks-datarange-video.pdf`
- Capture/preview categories: `capture-preview-still-category.pdf`
- DirectShow `IAMStreamConfig`: `iamstreamconfig.pdf`, `iamstreamconfig-setformat.pdf`
- INF validation and driver isolation: `validating-windows-drivers.pdf`, `porting-inf-to-windows-driver.pdf`, `infverif-h.pdf`, `dch-principles-best-practices.pdf`
- Local background references: `Programming the Microsoft Windows Driver Model (2nd Edition).pdf`, especially INF and PnP TOC sections; `Windows_Internals_Including_Windows_Server_2008.pdf`, especially PnP and driver installation TOC sections.

## Checklist

| Status | Batch | Evidence to collect | Smoke gate |
| --- | --- | --- | --- |
| [ ] | InfVerif/package truth: verify the DUT installed INF is the repo `avshws.inf`, remove stale `oem*.inf`/device state if needed, and run `infverif /h /v` when available. | `test-reports/vhlk-fixes/infverif-*` | Driver-test install/reinstall proof |
| [ ] | IAMStreamConfig and format negotiation: make AVStream intersection and `DispatchSetFormat` accept valid client-proposed `VIDEOINFOHEADER` formats without advertising unsupported ranges. | `test-reports/vhlk-fixes/streamconfig-*` | DirectShow probe modes |
| [ ] | MediaCapture preview: keep preview/capture pins usable through Media Foundation after the format negotiation changes. | `test-reports/vhlk-fixes/mediacapture-preview-*` | Windows Camera proof |
| [ ] | VideoInfoHeader2: add or prove support for the HLK `VideoInfoHeader2 Data` expectation using AVStream docs. | `test-reports/vhlk-fixes/vih2-*` | DirectShow `video2` probe |
| [ ] | Camera profiles: add the required camera profile metadata/control surface or document why the selected Microsoft-supported path is INF-only. | `test-reports/vhlk-fixes/profiles-*` | Profile install/probe proof |
| [ ] | Final failed-only vHLK: export full failed-name list, then run only failed test names. Stop and patch when 10 failures appear. | `test-reports/vhlk-oneclick-*` | Failed-only vHLK |

## Batch Rules

1. Read and cite the relevant downloaded reference before each driver change.
2. Build with `.\scripts\build-all.ps1 -Clean`.
3. Install and test only in `driver-test`.
4. Do not run vHLK after each batch; use driver-test gates only.
5. Cross off the batch only after the driver-test artifact shows the target behavior works.
6. Run failed-only vHLK after all driver-test gates pass; stop after 10 failures and patch again.
