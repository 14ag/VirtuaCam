# VirtuaCam Run Tests Guide

Use this file when the user says `run tests`, `run VirtuaCam tests`, or `run vHLK gates`.

Run stages in order. Stop at the first failed stage. Do not start vHLK until local and `driver-test` gates pass.

## Stage 0 - Before Running

Run from repository root in elevated PowerShell.

```powershell
git status --short
Get-Command powershell.exe -ErrorAction SilentlyContinue
Get-Command cmake.exe -ErrorAction SilentlyContinue
Get-Command node.exe -ErrorAction SilentlyContinue
Get-Command npm.cmd -ErrorAction SilentlyContinue
Get-Command pnputil.exe -ErrorAction SilentlyContinue
```

Rules:

- Preserve existing user changes.
- Use `.env` credentials for VM automation.
- Use `driver-test` for driver and camera-client proof.
- Use `vhlk` for HLK controller work.
- Do not run full vHLK during fix batches.
- Before driver code changes, read relevant PDF table of contents or first pages, read relevant section, and record the PDF section used.
- After each vHLK failure that needs a driver change, do PDF research before patching.
- After 2 vHLK failures in one iteration, do web research before patching.
- At 10 vHLK failures, stop immediately.
- After fixing a 2-failure vHLK set, rerun local and `driver-test` gates, retest the failed set, then resume after the failed set with only non-passed tests.
- After the last queued vHLK test passes, run final full vHLK sanity from the start, then run all local and `driver-test` gates again.

## Stage 1 - Local Gate

Parse changed PowerShell first:

```powershell
$paths = @(
  '.\scripts\run-vhlk-tests.ps1',
  '.\scripts\run-vhlk-smoke-3tests.ps1',
  '.\scripts\run-vhlk-failed-only.ps1',
  '.\scripts\export-vhlk-failed-tests.ps1',
  '.\scripts\export-vhlk-remaining-tests.ps1',
  '.\scripts\export-vhlk-all-tests.ps1',
  '.\scripts\filter-vhlk-test-list.ps1',
  '.\scripts\test-vhlk-runner-flow.ps1',
  '.\scripts\test-setup-registry-debug-mic.ps1',
  '.\scripts\test-audio-ioctl-fuzz.ps1',
  '.\scripts\test-capture-source-menu-contract.ps1',
  '.\scripts\host-windows-camera-display-capture-proof.ps1',
  '.\scripts\host-windows-camera-aspect-hot-change-proof.ps1',
  '.\scripts\hyperv-common.ps1',
  '.\scripts\hyperv-proof-windows-camera.ps1',
  '.\scripts\build-all.ps1',
  '.\scripts\install-driver-for-vhlk.ps1'
)
foreach ($path in $paths) {
  $tokens = $null
  $parseErrors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $path),
    [ref]$tokens,
    [ref]$parseErrors
  )
  if ($parseErrors.Count) {
    throw "Parse failed: $path`n$($parseErrors | Out-String)"
  }
}
```

Run local checks:

```powershell
.\scripts\test-vhlk-runner-flow.ps1
.\scripts\test-setup-registry-debug-mic.ps1
.\scripts\test-code-review-20260511.ps1
.\scripts\test-frame-ex-abi.ps1
.\scripts\test-camera-profile-contract.ps1
.\scripts\test-driver-pnp-contract.ps1
.\scripts\test-ai-window-cli.ps1
.\scripts\test-capture-source-menu-contract.ps1
.\scripts\build-all.ps1 -Clean
```

Pass criteria:

- All scripts exit `0`.
- Build ends with `BUILD-ALL SUCCEEDED`.
- `output\` contains staged camera driver, virtual microphone driver, software, catalog, and test certificate artifacts.
- `test-driver-pnp-contract.ps1` confirms PnP query-remove handling, close callbacks, device capabilities, INF hardware removal-policy override, and vHLK blocker filtering.
- `test-setup-registry-debug-mic.ps1` confirms registry settings, debug gating, virtual microphone ABI, capture-only INF registration, PortCls-only DriverEntry, and the compile-time user-mode feed bridge state.
- `test-capture-source-menu-contract.ps1` confirms the normal tray source menu order: windows/games, displays, video capture devices, image, and video.

## Stage 2 - Driver-Test Gate

Run DirectShow probe:

```powershell
.\scripts\test-driver-dshow-probe.ps1 -Modes list,yuy2,nv12,rgb32,video2
```

Run Windows Camera proof:

```powershell
.\scripts\hyperv-proof-windows-camera.ps1
```

Pass criteria:

- DirectShow modes `list`, `yuy2`, `nv12`, `rgb32`, and `video2` pass.
- Windows Camera proof reports `Success: True`.
- Windows Camera screenshot shows a nonblack capture of the selected source window.
- Windows Camera proof writes `audio-ioctl-fuzz.txt`. With the user-mode feed bridge disabled, the expected pass line is `PASS VirtuaCam microphone endpoint OK; user-mode feed bridge unavailable`.
- Chrome or browser proof is not part of the default local or driver-test gate.

## Stage 3 - vHLK Prep

Use the one-call failed-only runner. It exports controller failed names when `-TestNameListPath` is not provided, filters documented blockers from `docs\vhlk-blocked-test-names.txt`, fresh-starts VMs, installs the staged DUT driver, queues selected tests, monitors counters, and writes artifacts.

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

Direct export behavior:

- Fresh-starts `vhlk` by default, then exports project status.
- Writes `latest-status.json` and `failed-test-names.txt`.
- Writes `export-incomplete.json` when export fails before completion.
- Reads controller credentials inside its protected block so credential failures write `export-incomplete.json`.
- Use `-SkipFreshStart` only when another wrapper already fresh-started the controller.

Fallback list:

```powershell
$failedList = '.\test-reports\vhlk-oneclick-20260512-202918\failed-test-names.txt'
```

Use fallback only when controller export is unavailable, then pass `-TestNameListPath $failedList -NoExport` to `run-vhlk-failed-only.ps1`.

## Stage 4 - Failed-Only vHLK

Normal command:

```powershell
.\scripts\run-vhlk-failed-only.ps1 `
  -PendingStartTimeoutSeconds 300 `
  -TimeoutMinutes 180 `
  -ResearchGateFailureCount 2 `
  -StopOnFailureCount 10 `
  -MaxControllerReconnectFailures 5
```

Runner behavior:

- Restores `driver-test` checkpoint `clean`, forces it off, starts it, and waits for readiness.
- Forces `vhlk` off, starts it, and waits for PowerShell Direct.
- Writes `vm-fresh-start.json`.
- Exports failed names unless `-TestNameListPath` and `-NoExport` are used.
- Filters `docs\vhlk-blocked-test-names.txt` unless `-SkipBlockerFilter` is used.
- Installs staged `output\` package into `driver-test` unless `-SkipDutInstall` is used.
- Keeps Media Foundation `EnableFrameServerMode` set to `1` for Camera Profile V2 profile discovery.
- Checks child script status with `$LASTEXITCODE`.
- Uses selected failed-test names as monitored total.
- Scopes cleanup and cancellation to selected tests.
- Stops at 2 failures for research.
- Stops at 10 failures as hard safety limit.
- Stops after 5 consecutive controller reconnect failures and writes `controller-reconnect-limit.json`.
- Writes `latest-status.json`, `failed-test-names.txt`, and `monitor-summary.json` under `test-reports\vhlk-oneclick-*`.

If vHLK fails:

1. Stop the loop.
2. Export failed names and latest status.
3. If driver change is needed, read PDF table of contents or first pages, then relevant PDF section.
4. If failure count reached 2, search web for each failed test plus driver/API terms.
5. Record sources and fix rationale under `implementation\` or `docs\` as appropriate.
6. Patch.
7. Return to Stage 1 and Stage 2.
8. Retest the failed vHLK set first.
9. If the failed set still fails, repeat this failure loop.
10. If the failed set passes, run `.\scripts\export-vhlk-remaining-tests.ps1`, then pass `remaining-test-names.txt` to `run-vhlk-tests.ps1 -TestNameListPath`. Do not restart completed playlist tests or queue the full project.

Resume command:

```powershell
.\scripts\export-vhlk-remaining-tests.ps1
.\scripts\run-vhlk-tests.ps1 `
  -TestNameListPath .\test-reports\vhlk-remaining-export-<timestamp>\remaining-test-names.txt `
  -PendingStartTimeoutSeconds 300 `
  -TimeoutMinutes 480 `
  -ResearchGateFailureCount 2 `
  -StopOnFailureCount 10 `
  -MaxControllerReconnectFailures 5
```

## Stage 5 - Final vHLK Sanity

After failed-only vHLK passes and all local/driver-test gates pass, run full vHLK sanity:

```powershell
.\scripts\run-vhlk-tests.ps1 `
  -PendingStartTimeoutSeconds 300 `
  -TimeoutMinutes 480 `
  -ResearchGateFailureCount 2 `
  -StopOnFailureCount 10 `
  -MaxControllerReconnectFailures 5
```

Pass criteria:

- `run-vhlk-tests.ps1` fresh-starts `vhlk` and `driver-test`, installs staged `output\` into DUT, then queues the full project.
- Final vHLK run completes without failed status.
- Any impossible lab/tool blocker is documented under `docs\` and skipped only on the next failed-only run.

For a full rerun that must skip documented blockers, export all project test names, filter `docs\vhlk-blocked-test-names.txt`, then pass the filtered list to `run-vhlk-tests.ps1`. Also pass the blocker list so stale queued/running blocked results are canceled and cleaned but not re-queued.

```powershell
.\scripts\export-vhlk-all-tests.ps1
.\scripts\filter-vhlk-test-list.ps1 `
  -InputPath .\test-reports\vhlk-all-export-<timestamp>\all-test-names.txt `
  -SkipPath .\docs\vhlk-blocked-test-names.txt `
  -OutputPath .\test-reports\vhlk-all-export-<timestamp>\all-test-names.filtered.txt
.\scripts\run-vhlk-tests.ps1 `
  -TestNameListPath .\test-reports\vhlk-all-export-<timestamp>\all-test-names.filtered.txt `
  -BlockedTestNameListPath .\docs\vhlk-blocked-test-names.txt `
  -PendingStartTimeoutSeconds 300 `
  -TimeoutMinutes 480 `
  -ResearchGateFailureCount 2 `
  -StopOnFailureCount 10 `
  -MaxControllerReconnectFailures 5
```

## Stage 6 - Post-vHLK Documentation Assertion

Read current docs before asserting project state:

```powershell
Get-Content .\wiki\Home.md -TotalCount 80
Get-Content .\wiki\Testing.md -TotalCount 160
Get-Content .\wiki\vHLK-Fix-Workflow.md -TotalCount 160
Get-Content .\README.md -TotalCount 120
```

Final response requirements:

- State exact stages that passed.
- State artifact paths for latest local, driver-test, and vHLK runs.
- Assert all features are working only when local, driver-test, failed-only vHLK, final full vHLK, and documentation assertion all pass.
- Do not say the project is ready to ship until every gate above is green.
