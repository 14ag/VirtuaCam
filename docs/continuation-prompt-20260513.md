# Continuation Prompt

You are continuing work in `C:\Users\philip\sauce\virtual-webcam\VirtuaCam` on branch `vhlk-fixes`.

Rules from user:
- Always use caveman skill.
- Do not run full vHLK during fix batches.
- After each fix batch, run only driver-test gates and whitebox/local checks.
- After all batch fixes pass, run all vHLK tests minus all that have passed or are blocked/unrun, using the latest failed-test-name list as filter.
- If 10 vHLK tests fail in a run, stop immediately and patch code before continuing.
- If a vHLK test is impossible due to lab/tool blocker, document it under `docs\` and skip it on the next failed-only run.
- Preserve existing user changes. Do not reset or revert.
- Use PowerShell/batch automation, not manual steps.
- If a PDF is used as reference, read its table of contents or first pages before citing sections.

Current high-level state:
- Branch: `vhlk-fixes`, tracking `github/vhlk-fixes`.
- Repo was renamed from stale `v2` to `VirtuaCam`; clean public refs only, leave raw historical logs alone.
- Latest full-ish saved vHLK result: `test-reports\vhlk-oneclick-20260513-021033`.
- That run reported 113 total, 26 passed, 77 failed, 7 not run, 2 queued, 1 running when controller/session broke.
- Latest complete failed-test-name fallback list is `test-reports\vhlk-oneclick-20260512-202918\failed-test-names.txt` with 106 names. Use controller export first if available; fallback only if export unavailable.
- Do not resume aborted vHLK from this chat.

2MP update done:
- Default driver/user-mode/browser proof output moved from 1280x720 to 1920x1080.
- Portrait 9:16 moved from 720x1280 to 1080x1920.
- 640x480 and 480x640 fallbacks retained for HLK/client compatibility.
- Small-source behavior: producer canvas is fixed 1920x1080; render path clears black and uses aspect-preserving contain viewport, so screens below 1080p are upscaled/padded, not cropped or rejected. Bridge blit now crops the fixed canvas to negotiated output aspect before scaling, avoiding non-uniform stretch for 9:16/4:3 outputs.
- Source notes saved in `docs\2mp-output-update-20260513.md`.

Earlier fix batches already applied before 2MP:
- Hyper-V readiness: `scripts\hyperv-common.ps1` has `Get-HvVmConnectionState`, extended `Wait-HvVmReady`, checkpoint restore helpers, reboot transition wait, `.env` credential fallback, and stale-session handling.
- vHLK runner robustness: `scripts\run-vhlk-tests.ps1` and smoke runner handle HLK PD-pipeline cancellation as warning and retry DUT `Initializing`.
- Driver-test gate: `scripts\test-driver-dshow-probe.ps1` logs install, rechecks/re-copies probe after reboot, parses current `dshow_probe.exe` output, and validates list/YUY2/NV12/RGB32/VIDEO2.
- App watcher: silent startup exits after 5 minutes of driver inactivity while watcher service stays alive.
- Build/install script reliability: artifact size checks, safer staging cleanup, `.driver-package-work` explanation, and `pnputil` exit code 2 treated as reboot-required.
- Driver vHLK fixes: still pin added (`PINNAME_VIDEO_STILL`), still/media profiles added, and capture device resource ownership supports compatible concurrent streams.

Known local/user-created/untracked context:
- `Probe-VMState.ps1` was user-created as a readiness prototype; use insights but do not blindly move/delete it.
- `next task2.txt` deletion existed before the latest 2MP work; do not restore unless user asks.
- `tools\dshow-probe\dshow_probe.cpp` had pre-existing changes before this 2MP task; inspect before staging/editing.

Required next test workflow:
1. Do not run vHLK first.
2. Run local parse/whitebox checks:
   - parse changed PowerShell scripts.
   - `.\scripts\test-vhlk-runner-flow.ps1`
   - `.\scripts\test-code-review-20260511.ps1`
   - `.\scripts\test-frame-ex-abi.ps1`
   - `.\scripts\build-all.ps1 -Clean`
3. Run driver-test gates only:
   - DirectShow probe: list, yuy2, nv12, rgb32, video2.
   - Windows Camera proof.
   - Browser proof now expects 1920x1080.
4. Only after driver-test gates pass, export full failed vHLK list from controller if possible.
5. Run `scripts\run-vhlk-tests.ps1 -TestNameListPath <failed-list>`, not full vHLK.
6. If 10 vHLK tests fail, stop immediately, patch, and re-enter driver-test gate loop.

Useful source refs already consulted:
- Microsoft Learn, "Selecting a Stream Format": https://learn.microsoft.com/en-us/windows-hardware/drivers/stream/selecting-a-stream-format
- Microsoft Learn, `KSCAMERA_PROFILE_MEDIAINFO`: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-_kscamera_profile_mediainfo
- Microsoft Learn, `IAMStreamConfig`: https://learn.microsoft.com/en-us/windows/win32/api/strmif/nn-strmif-iamstreamconfig
- Microsoft Learn, PowerShell Direct and Hyper-V heartbeat/vmicvmsession docs for readiness flow.
