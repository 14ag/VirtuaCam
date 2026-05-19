# VirtuaCam Test Instructions

Read this before running, changing, or reporting tests in this repository.

## Agent Defaults

- Use the `caveman` skill in replies.
- Automate viable steps with PowerShell or batch scripts.
- Ask only yes/no clarification questions when intent is uncertain.
- Keep output quiet: relevant execution results and error summaries only.
- If a command or dependency is missing, verify it with `powershell Get-Command <tool> -ErrorAction SilentlyContinue` or `powershell where.exe <tool>`.
- If the same error happens twice, search the internet for fixes before more patching.
- Preserve existing user changes. Do not revert unrelated edits.

## Source Priority

Use these files before scanning the repository for test order:

1. `skills/run-tests/SKILL.md`
2. `scripts/RUN-TESTS.md`
3. `wiki/Testing.md`
4. `wiki/vHLK-Fix-Workflow.md`
5. `wiki/Home.md`

`scripts/RUN-TESTS.md` is the canonical command list. Wiki pages document current roles, gates, artifact paths, and vHLK behavior. If a test, run, or vHLK fact is missing from the wiki and must be found by repo search, update the wiki with `technical-writer2`.

## Driver Rules

- Driver tests run only in the `driver-test` VM.
- VM credentials come from `.env`.
- HLK controller work uses the `vhlk` VM.
- Before changing anything under `driver-project`, read the relevant PDF table of contents under `pdfs/`, then read the relevant section.
- Record the PDF section used in the work log or final summary.
- After a vHLK failure that needs a driver change, repeat PDF research before patching.
- Do not run full vHLK during fix batches. Use failed-only vHLK after local and `driver-test` gates pass.

## Required Preflight

Run from repository root in elevated PowerShell.

```powershell
git status --short
Get-Command powershell.exe -ErrorAction SilentlyContinue
Get-Command cmake.exe -ErrorAction SilentlyContinue
Get-Command node.exe -ErrorAction SilentlyContinue
Get-Command npm.cmd -ErrorAction SilentlyContinue
Get-Command pnputil.exe -ErrorAction SilentlyContinue
```

## Run Order

Stop at the first failed stage. Patch, then restart at Stage 1. After a vHLK playlist patch, rerun Stage 1 and Stage 2, then resume Stage 4 with the current failed or remaining playlist. Do not restart completed playlist tests or queue the full project unless Stage 5 is reached.

1. Stage 1: local gate.
2. Stage 2: `driver-test` gate.
3. Stage 3: vHLK failed-name export and failed-only prep.
4. Stage 4: failed-only vHLK.
5. Stage 5: final full vHLK sanity.
6. Stage 6: post-vHLK documentation assertion.

## Iteration Loop

Use this loop until every required test passes.

1. Run local regression tests in `driver-test`.
2. When local and `driver-test` gates pass, run vHLK.
3. If two vHLK tests fail in one iteration, stop the vHLK run, export failed names/status, collect failure artifacts, research the failed tests, and patch the failures.
4. After the patch, rerun local regression tests in `driver-test`.
5. Retest the two failed vHLK tests first.
6. If the two failed tests still fail, return to step 3.
7. If the two failed tests pass, resume vHLK with tests after the failed pair plus any current non-passed tests. Do not rerun vHLK tests already marked `Passed`.
8. After the last queued vHLK test passes, run the final full vHLK sanity from the start, then run all required local and `driver-test` gates again.
9. When all tests pass in the final verification pass, update documentation and report the final artifact paths.

## Stage 1 - Local Gate

Parse changed or key PowerShell files first. Then run:

```powershell
.\scripts\test-vhlk-runner-flow.ps1
.\scripts\test-setup-registry-debug-mic.ps1
.\scripts\test-code-review-20260511.ps1
.\scripts\test-frame-ex-abi.ps1
.\scripts\test-camera-profile-contract.ps1
.\scripts\test-driver-pnp-contract.ps1
.\scripts\test-ai-window-cli.ps1
.\scripts\build-all.ps1 -Clean
```

Pass criteria:

- All scripts exit `0`.
- Build ends with `BUILD-ALL SUCCEEDED`.
- `output\` contains staged camera driver, virtual microphone driver, software, catalog, and test certificate artifacts.
- `test-driver-pnp-contract.ps1` confirms PnP query-remove handling, close callbacks, device capabilities, INF hardware removal-policy override, and vHLK blocker filtering.
- `test-setup-registry-debug-mic.ps1` confirms registry settings, debug gating, virtual microphone ABI, capture-only INF registration, PortCls-only DriverEntry, and the compile-time user-mode feed bridge state.

## Stage 2 - Driver-Test Gate

Run:

```powershell
.\scripts\test-driver-dshow-probe.ps1 -Modes list,yuy2,nv12,rgb32,video2
.\scripts\hyperv-proof-windows-camera.ps1
```

Pass criteria:

- DirectShow modes `list`, `yuy2`, `nv12`, `rgb32`, and `video2` pass.
- Windows Camera proof reports `Success: True`.
- Windows Camera screenshot shows nonblack capture of the selected source window.
- Windows Camera proof writes `audio-ioctl-fuzz.txt`. With the user-mode feed bridge disabled, the expected pass line is `PASS VirtuaCam microphone endpoint OK; user-mode feed bridge unavailable`.
- Do not run Chrome or browser proof as part of the default local or driver-test gate.

## Stage 3 - vHLK Prep

Preferred command:

```powershell
.\scripts\run-vhlk-failed-only.ps1 `
  -PendingStartTimeoutSeconds 300 `
  -TimeoutMinutes 180 `
  -ResearchGateFailureCount 2 `
  -StopOnFailureCount 10 `
  -MaxControllerReconnectFailures 5
```

Direct export command:

```powershell
.\scripts\export-vhlk-failed-tests.ps1
```

Use a fallback failed-name list only when controller export is unavailable, then pass `-TestNameListPath <path> -NoExport` to `run-vhlk-failed-only.ps1`.

## Stage 4 - Failed-Only vHLK

Run the same failed-only command from Stage 3. The runner fresh-starts VMs, restores `driver-test` checkpoint `clean`, exports failed names, filters `docs\vhlk-blocked-test-names.txt`, installs staged `output\`, queues selected tests, monitors counters, and writes artifacts.

Stop rules:

- Stop at `2` vHLK failures. Export failed names/status, search the internet for the failed tests plus driver/API terms, then patch.
- After fixing the `2`-failure set, rerun local and `driver-test` gates, then resume the failed or remaining playlist. Do not start the playlist over.
- Stop at `10` vHLK failures immediately.
- Stop after `5` consecutive controller reconnect failures. Report `controller-reconnect-limit.json`.
- If vHLK fails and driver work is needed, read PDF table of contents and relevant section before patching.

## Stage 5 - Final vHLK Sanity

Run only after failed-only vHLK, local gate, and `driver-test` gate pass.

```powershell
.\scripts\run-vhlk-tests.ps1 `
  -PendingStartTimeoutSeconds 300 `
  -TimeoutMinutes 480 `
  -ResearchGateFailureCount 2 `
  -StopOnFailureCount 10 `
  -MaxControllerReconnectFailures 5
```

Pass criteria:

- Full vHLK run completes without failed status.
- Impossible lab or tool blockers are documented under `docs\` before any skip is used in a later failed-only run.

## Stage 6 - Documentation Assertion

Read current docs before asserting project state:

```powershell
Get-Content .\wiki\Home.md -TotalCount 80
Get-Content .\wiki\Testing.md -TotalCount 160
Get-Content .\wiki\vHLK-Fix-Workflow.md -TotalCount 160
Get-Content .\README.md -TotalCount 120
```

Final response must include:

- Exact stages passed.
- Commands run.
- Latest artifact directories.
- Failed tests or blockers.
- Next stage.

Assert all features are working only when local, `driver-test`, failed-only vHLK, final full vHLK, and documentation assertion all pass. Do not say ready to ship until every gate is green.
