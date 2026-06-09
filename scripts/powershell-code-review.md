# VirtuaCam PowerShell Scripts — Code Review

## Current Fix Status

- VM readiness now needs the shared Probe-VMState state machine in `hyperv-common.ps1`, including heartbeat, PowerShell Direct, `LogonUI`, `userinit`, `explorer`, and `ReadyToConnect` state.
- UI proof flows should wait for `ReadyToConnect`; service-only and HLK flows should log connection state and wait for PowerShell Direct plus heartbeat.
- vHLK runners should keep the stale-poll warning, redirected-output guard, active queue cancellation, and full failed-name export.
- Driver-test DirectShow validation should use `scripts/test-driver-dshow-probe.ps1` so probe output is written on the host and aborted guest logging cannot stall the run.

**Scope:** All scripts under `VirtuaCam/scripts/`  
**Focus:** Code quality · logical-flow stability · counter / state-tracking accuracy  
**Rating scale:** 🔴 High · 🟡 Medium · 🟢 Low / Info

---

## 1. Global Patterns — Strengths

| Pattern | Where | Notes |
|---------|-------|-------|
| `Set-StrictMode -Version Latest` + `$ErrorActionPreference = "Stop"` | Every entry-point script | Correctly stops accidental undefined-variable usage and un-caught native errors |
| `try/finally` for PSSession cleanup | All scripts that open sessions | Sessions always released even on throw |
| `[string]::IsNullOrWhiteSpace()` for param guards | Consistent | More robust than `-eq ""` |
| `$null = New-Item -ItemType Directory -Force` | Universal | Idempotent dir creation without noise |
| `-LiteralPath` everywhere | Universal | Correct; avoids wildcard expansion on paths with brackets |
| Structured return objects (`[pscustomobject]@{…}`) | All callers | Machine-readable, good for piping to JSON |
| `Write-HvLog` abstraction (`hyperv-common.ps1`) | All Hyper-V scripts | Centralised timestamping, file persistence, levels |

---

## 2. Script-by-Script Findings

### 2.1 `hyperv-common.ps1` (shared foundation)

**Strengths:** `Wait-HvPowerShellDirect` polls with deadline + sleep; `Invoke-HvGuestCommand` wraps errors with context. `Get-HvGuestCredential` resolves credential three ways (object → plaintext → interactive).

🟡 **`Resolve-HvPath` silently falls back to `$PWD`** when called with a relative path and no repo root is found. If called from an unexpected CWD (e.g., scheduled task), all artifact paths silently land in wrong location. Suggest: emit a `Write-HvLog` WARN when falling back.

🟢 `Get-HvArtifactDirectory` uses `Get-HvTimestamp` which formats with `yyyyMMdd-HHmmss`. No conflict guard if two runs start in the same second (rare but possible in CI loops). Appending PID would make it collision-safe.

---

### 2.2 `build-all.ps1`

🟢 **`vcpkg integrate install` called unconditionally** (line ~87). On machines where vcpkg is already integrated this is a no-op but adds ~2 s. Guard with a capability check or `-Triplet` check could skip it.

🟢 **Artifact verification uses `Test-Path` only** — doesn't verify file size > 0. A zero-byte `avshws.cat` from a failed signing step would pass the check and proceed to staging.  
Suggest: add `(Get-Item $path).Length -gt 0` assertion for critical signed artifacts.

🟢 Driver signing calls `signtool.exe` but doesn't capture or log its stdout/stderr on success — only on failure via `$LASTEXITCODE`. Any warnings from signtool are silently swallowed.

---

### 2.3 Legacy install script

Resolved: install automation now uses `VirtuaCamSetup.exe --install --json`; the old PowerShell install entrypoint was removed.

🟡 **`Protect-VirtuaCamRegistryKey` sets ACLs but no rollback on failure.** If the `SetAccessControl` call throws mid-application, the key may end up in a partially-tightened ACL state that blocks subsequent installs. Wrap in `try/catch` with a restore of the original SDDL.

🟢 `Remove-VirtuaCamDriver` calls `pnputil /delete-driver` but only checks `$LASTEXITCODE -eq 0`. pnputil exit 2 means "driver removed but reboot required" — this is treated as an error when it should be a handled state.

---

### 2.4 `hyperv-driver-loop.ps1`

🟢 **Attempt counter is implicit** — loop index `$i` drives the attempt ID but is never surfaced in log output. After a failure you can see "Attempt 3 failed" but not which attempt IDs (UUIDs) map to which loop iteration. Log `$i` alongside the attempt ID.

🟢 **`Restore-VMCheckpoint` called without verifying the VM is Off first** in the fast-path where a prior run left the VM in a Saved state. Most callers force-stop first, but this one does not — rely on Hyper-V to reject the call. Should mirror the `Stop-VM -TurnOff` pattern used in `hyperv-hlk-client.ps1`.

---

### 2.5 `run-vhlk-tests.ps1`

**Counters audit:**

```
$passCount  ← set from $remoteStatus.Passed  (remote JSON field)
$failCount  ← set from $remoteStatus.Failed
$totalCount ← set from $remoteStatus.Total
```

🔴 **Counter stale-read risk:** `$remoteStatus` is fetched inside `Invoke-Vhlk` which calls `Invoke-Command`. If the controller is under load and the command times out, `$remoteStatus` stays `$null` and the loop re-uses last iteration's values without any log message. The `while` loop exits on `$totalCount -ge $expectedTotal` — with stale `$totalCount` this may never trigger, causing the loop to run until the outer deadline rather than the test completion.

**Fix:** explicitly check for `$null -ne $remoteStatus` before updating counters and emit a WARN log on each stale poll:
```powershell
if ($null -ne $remoteStatus) {
    $passCount  = $remoteStatus.Passed
    $failCount  = $remoteStatus.Failed
    $totalCount = $remoteStatus.Total
} else {
    Write-HvLog -Message "Remote status poll returned null; using last known counts." -LogPath $LogPath -Level WARN
}
```

🟡 **Heartbeat timeout check** compares `$lastHeartbeat` to `(Get-Date)` but `$lastHeartbeat` is only updated when `$remoteStatus` is non-null (correct). However the timeout threshold is a bare literal (`300` seconds in most places). If this constant ever diverges between `run-vhlk-tests.ps1` and `run-vhlk-smoke-3tests.ps1` (they are separate copies), bugs appear silently. Extract to a named param or shared constant.

🟡 **`Write-LiveLine` spinner** writes to the same console line via `\r`. On non-interactive (redirected) stdout this produces garbled output in captured logs. Guard: detect `[Console]::IsOutputRedirected` and fall back to plain `Write-Host`.

🟢 `$expectedTotal` is read from the HLK project's test list at startup. If the HLK controller re-evaluates and adds/removes tests (e.g., on DUT reconnect), `$expectedTotal` becomes wrong and the completion check either fires early or never fires.

---

### 2.6 `run-vhlk-smoke-3tests.ps1`

All findings from 2.5 apply. Additional:

🟡 **Hardcoded test count `3`** baked into the script name and completion check (`$totalCount -ge 3`). If a test is removed from the HLK project the loop exits correctly but silently. If a test is added it runs forever. Derive expected count from the controller query same as the full runner, or assert exact equality.

🟢 Exit-code mapping at bottom (`exit 0 / exit 1 / exit 2`) is correct, but the comment says "exit 2 = partial" — the consuming orchestrator (`hyperv-driver-loop.ps1`) treats any non-zero as failure. If partial-pass ever needs special handling, the caller must be updated too.

---

### 2.7 `hyperv-proof-chrome.ps1`

**Counter / state tracking — `Update-AttemptState`:**

```
attempt       ← incremented on each call
repeat_count  ← incremented when same ErrorSignature repeats
researched    ← set true once repeat_count hits threshold
```

🟡 **`$attemptChange` variable set before the `try` block, but `Update-AttemptState -Success:$true` and `Update-AttemptState -Success:$false` both pass `$attemptChange`.** If `$attemptChange` is ever stale (e.g., JSON file write failed), the state file records a wrong diff. The JSON write in `Update-AttemptState` should be wrapped in its own `try/catch` to surface this.

🟡 **`$runSucceeded` flag** is set to `$true` only on the success path (line 907). In the `finally` block it's used to decide whether to re-throw checkpoint restore failures. However `$runSucceeded` is initialized at the top of the outer scope — if the script body throws before reaching the flag assignment, `$runSucceeded` is `$false` (correct). But if `$runSucceeded` is never declared (e.g., strict mode + different call path), this would cause a terminating error in `finally`. Verify the variable is always initialized at script top.

🟢 **`$driverPackageStage` cleanup in `finally`** calls `Remove-Item -Recurse -Force` on `$driverPackageStage.StageParent`. If `StageParent` somehow equals repo root (path resolution bug), this would silently delete the working tree. The `clean-output.ps1` pattern of checking `StartsWith(repoRoot)` before deleting should be applied here too.

🟢 The `$holdProc` wait timeout is 20 seconds (`Wait-Process -Timeout 20`). For heavy VMs this may be insufficient; the `Stop-Process` fallback handles it, but leaves no log entry explaining why the graceful wait failed.

---

### 2.8 `hyperv-hold-webcam-session.ps1`

🟡 **90-second ready-wait loop** (line 206) polls every 2 seconds. Total polls = 45. If the scheduler task fires but the guest script crashes before writing status, the loop times out and throws a generic "timed out" error. The thrown error message includes `schtasks /query` output for diagnostics — good.

🟡 **`Join-GuestTextOutput` defined twice** — once inside the launch scriptblock (lines 140-152) and again inside the timeout diagnostic block (lines 233-245). Should be defined once at the top of the remote block or passed as a ScriptBlock argument. Duplication risk: if one copy diverges.

🟢 **`$HostHeartbeatUtc` updated every loop iteration** but `$HostStopSignalPath` check is the only exit condition. If the stop signal file is written while a 5-second probe is in-flight, the loop may run one extra probe cycle. Not a bug, but the probe could throw and propagate before the stop signal is honored. Consider checking stop signal inside the probe catch block.

---

### 2.9 `hyperv-proof-windows-camera.ps1`

🟡 **Inline script string** (lines 157-235) is embedded as a here-string and written to a `.ps1` file inside the guest via `Set-Content`. This makes the inner script invisible to static analysis, linters, and diff tools. Consider storing it as a real file under `scripts/` and copying it to the guest via `Copy-HvToGuest`, consistent with how `guest-held-webcam-session.ps1` is deployed.

🟡 **`$deadline` variable** (line 252, inside the remote scriptblock) shadows the outer host-side `$deadline` (line 127). In strict mode they're in different scopes so it's harmless, but it's confusing during debugging. Rename inner to `$taskDeadline`.

🟢 **Camera window detection** iterates `WindowsCamera` and `ApplicationFrameHost` processes. If the Camera app is already running (from a previous failed attempt), `$cameraWindow` may pick up a stale window. The `Restore-ProofCheckpoint` at the end resets, so this is only a risk if `-RevertAfterRun:$false` is used.

---

### 2.10 `hyperv-clean-checkpoint.ps1`

🟢 **Multi-pass driver removal** correctly loops with `$remainingPasses`. Counter decrements properly. No issue with counter stale reads here.

🟢 `pnputil /delete-driver` exit code 2 ("reboot required") not handled (same as 2.3). Should set a `$rebootRequired` flag rather than treating as error.

---

### 2.11 `hyperv-clean-validate.ps1`

🟢 Validation script reports `Pass/Fail` booleans for each check but doesn't surface an aggregate exit code or `throw` on failure — callers must inspect the return object. If called standalone and failures are present, the script exits 0. Add a top-level check:
```powershell
if (-not $result.AllPassed) { exit 1 }
```

---

### 2.12 `hyperv-collect.ps1`

🟢 **`Get-SetupApiSlice` range-merge algorithm** is correct — intervals sorted by `Start`, merged greedily. No off-by-one: uses `$hit + $ContextLines` inclusive, and `AppendLine` adds newline after each. ✅

🟢 `Invoke-HvGuestCommand` return value `$guestRunRoot` is the temp dir path on the guest. If the scriptblock throws, `$guestRunRoot` may be `$null`. The `finally` block correctly guards with `if (Test-Path -LiteralPath $PathToDelete)` — safe. ✅

---

### 2.13 `hyperv-enable-ssh.ps1`

🟡 **`Set-SshdDirective` modifies lines by ref** (`[ref]$LinesRef`). The pattern removes all matching lines and appends one replacement. If `sshd_config` has a `Match` block that legitimately repeats a directive in a different context, all copies are collapsed into one at the file root — may break the config. This is unlikely in practice but worth noting.

🟡 **`Test-SshdImageHealthy`** calls `& $exe -T *> $null` which suppresses stderr. On some OpenSSH builds, `-T` returns exit 1 for a valid config (version-dependent). The function returns `$false` → triggers unnecessary `Repair-SshdServiceRegistration`. Add version detection or use `Get-Process sshd` after start as secondary health check.

🟢 **`$repairApplied` flag** set correctly to `$true` on repair path, `$false` on clean path. Correctly reported in return object. ✅

---

### 2.14 `vhlk-lab-network.ps1`

🟢 **`Set-VhlkHostsEntryText` pure function** — doesn't write to disk, returns new text. Called from host-side code only. Makes unit-testing easy.

🟡 **`Set-VhlkGuestLabNetwork` silently swallows errors** in two `catch {}` blocks (lines 151-153 and 165-167) — one for `Remove-NetIPAddress`, one for `Set-NetConnectionProfile`. These empty catches hide real failures. At minimum add `Write-Warning $_.Exception.Message`.

🟢 **`$serviceStates` array** built correctly in loop; `$restarted` flag correctly set only when service was Running before restart. Counter logic is sound. ✅

🟢 **`Test-VhlkGuestTcp`** returns a result object but doesn't throw on failure — caller (`Repair-VhlkLabNetwork`) includes connectivity in the return object but doesn't assert connectivity succeeded. The orchestrating caller must check `Connectivity.TcpTestSucceeded`. Document this contract.

---

### 2.15 `hyperv-hlk-client.ps1`

🟡 **`cmdkey` password passed as plaintext in process command line** (line 128):
```
cmd.exe /c "cmdkey /add:HOST /user:USER /pass:PLAINTEXT"
```
This is visible in process listings (`tasklist`, Process Monitor) on the guest during execution. Consider: write a temp script to the guest and invoke it, or use `net use` with stored credentials instead.

🟢 **Driver residue check before and after** the HLK setup action — both `$beforeResidue` and `$afterResidue` correctly compared. Return object includes both snapshots for diff. ✅

---

### 2.16 `hyperv-hlk-preflight.ps1`

🟢 **Code duplication** — `Get-DriverResidue` and `Get-HlkArpEntries` are defined verbatim in both `hyperv-hlk-client.ps1` and `hyperv-hlk-preflight.ps1`. Should be extracted into `hyperv-common.ps1` or a dedicated `hyperv-hlk-common.ps1`.

🟢 `$controllerHost` extraction via regex (line 40) uses `$matches[1]` — correct in PowerShell but `$matches` is a special automatic variable that can be clobbered by any subsequent regex operation before `$controllerHost` is evaluated. Assign immediately: `$controllerHost = $matches[1]` (already done). ✅

---

### 2.17 `hyperv-hlk-controller-vm.ps1`

🟢 Clean, minimal, correct. `$ForceRecreate` guard before VHD delete is safe. Boot order set only when both DVD and HDD drives exist.

🟢 `Set-VMFirmware -EnableSecureBoot On` called unconditionally — HLK controller VMs don't always require Secure Boot and the ISO may be unsigned. Suggest: make `$SecureBoot` a parameter defaulting to `$true`.

---

### 2.18 `test-ks-invalid-buffer-fuzz.ps1`

🟢 **`failuresSeen` counter** tracked correctly in C# — incremented by `ExpectFailure` return value (always 1 on success), total asserted at end (`!= 5`). If any call unexpectedly succeeds, the method throws immediately rather than silently passing. ✅

🟢 **`try/finally` for all `AllocHGlobal`/`FreeHGlobal` pairs** — no memory leak paths. `SetupDiDestroyDeviceInfoList` in outer `finally`. ✅

🟢 **SKIP path** (device not found) returns a string, not throws — caller writes it to artifact and `Write-Host`s. Script exits 0 even on skip. If this is run in CI, a skip is indistinguishable from a pass at the exit-code level. Add: check if result starts with "SKIP" and `exit 2` to signal skip distinctly.

---

### 2.19 `test-performance-audit.ps1`

🟢 `Assert-Contains` / `Assert-NotContains` / `Assert-Order` pattern is clean whitebox test style. All throw on failure — correct.

🟡 **`$before`/`$after` PPM dump comparison** (lines 105-122): `$before` is a plain `@(…)` array of full paths. `$after -notcontains $_` does string comparison. If paths have inconsistent trailing slashes or case differences (Windows is case-insensitive), `notcontains` may miss a match. Use `[System.StringComparer]::OrdinalIgnoreCase` comparison or normalize paths first.

🟢 Build step uses `& $cmake.Path` with `$LASTEXITCODE` check — correct. Runtime test correctly uses `Start-Process -PassThru` + `Stop-Process` in `finally`. ✅

---

### 2.20 `playwright-vm-webcam-proof.ps1`

🟢 **Environment variable backup/restore pattern** (lines 282-313) — saves old values, restores in `finally`. Correct even if node fails. ✅

🟡 **`$env:NODE_PATH` set to runner's `node_modules`** but the embedded CJS script uses `require('playwright-core')` which Node resolves via `node_modules` relative to script location, not `NODE_PATH`. The `NODE_PATH` env var is redundant here (Node finds the module via standard lookup since script is in `$runnerDir`). Remove to avoid confusing future readers.

🟢 **`pickPage` function** in the embedded JS: falls back to `pages[0]` if URL match fails. If the browser has multiple tabs, this may pick the wrong one. The fallback is fine for the current single-tab use case.

🟢 **BOM strip** in `readJson` (`replace(/^\uFEFF/, '')`) — correct; `Set-Content -Encoding UTF8` in PS5 adds BOM. ✅

---

### 2.21 `hyperv-kd.ps1`

🟡 **`Set-VMFirmware -EnableSecureBoot Off` applied unconditionally for Gen2 VMs** (line 39) before checking if Secure Boot is already off. Not harmful but causes unnecessary VM config change log noise. Check current state first.

🟢 **`-RebootGuest` flag**: if true, `Restart-HvGuest` is called inside `finally` instead of `Remove-PSSession`. If `Restart-HvGuest` throws in `finally`, session is never removed. Add `Remove-PSSession` in a nested `try/catch` after `Restart-HvGuest`.

---

### 2.22 `host-media-capture-auto-proof.ps1`

🟡 **`$summary.Results += …` in a loop** — PowerShell array `+=` creates a new array each iteration. For 2×2=4 iterations this is fine, but the pattern should use `[System.Collections.Generic.List[object]]` for correctness.

🟡 **`$summary.Success = (@($summary.Results | Where-Object { $_.Passed }).Count -gt 0)`** — correct logic, but `$summary` is a `[ordered]@{}` hashtable, so `$summary.Success` assignment works via hashtable key access. No type enforcement. If a result object has no `Passed` property due to a partial failure, `Where-Object` silently excludes it. The `Errors` array captures these, but `Success` may be `$false` when errors were the only outcome — the caller gets no distinction between "nothing passed" and "everything errored". Document or split into `PartialSuccess`.

🟢 **`Await-AsyncOperation` / `Await-AsyncAction`** WinRT reflection helpers: method discovery via `GetMethods()` + `Where-Object` is expensive (called per frame reader probe). Cache the `MethodInfo` objects at script scope.

🟢 **`$center` pixel index calculation** (line 91): `($height / 2 -as [int]) * $width * 4 + ($width / 2 -as [int]) * 4`. Correct for BGRA center pixel. ✅

---

### 2.23 `clean-output.ps1`

🟢 **Path containment guard** before delete — mirrors best practice. `StartsWith(repoRoot, OrdinalIgnoreCase)` correct. ✅

🟢 Uses `SupportsShouldProcess` + `$PSCmdlet.ShouldProcess` — supports `-WhatIf`. ✅

🟢 `$resolvedOutputRoot` only resolved if path exists (else uses raw path) — safe against deleting non-existent dirs. ✅

---

### 2.24 `test-code-review-20260511.ps1`

🟢 Whitebox regression guard. `Assert-Order` using `IndexOf` is correct — verifies relative ordering of two patterns in source text.

🟡 **`Get-RepoText` assumes `$repoRoot = Split-Path -Parent $PSScriptRoot`** — two levels up from `scripts/`. Works only when invoked from `scripts/`. If invoked from repo root directly, `Split-Path -Parent $PSScriptRoot` gives the wrong directory. Use `[IO.Path]::GetFullPath(Join-Path $PSScriptRoot "..")` consistently.

---

## 3. Counter / State Tracking Summary

| Script | Counter/State vars | Issues |
|--------|--------------------|--------|
| `run-vhlk-tests.ps1` | `$passCount`, `$failCount`, `$totalCount` | 🔴 Stale on null poll, no warn |
| `run-vhlk-smoke-3tests.ps1` | Same + hardcoded `3` | 🟡 Hardcoded completion threshold |
| `hyperv-proof-chrome.ps1` | `$attemptState` (JSON), `$runSucceeded` | 🟡 No write-fail guard on state JSON |
| `hyperv-driver-loop.ps1` | `$i` (implicit attempt counter) | 🟢 Not surfaced in logs |
| `hyperv-clean-checkpoint.ps1` | `$remainingPasses` | ✅ Correct |
| `test-ks-invalid-buffer-fuzz.ps1` | `failuresSeen` (C#) | ✅ Correct, exit-code skip issue |
| `vhlk-lab-network.ps1` | `$serviceStates`, `$added` | ✅ Correct |
| `hyperv-enable-ssh.ps1` | `$repairApplied`, `$keyInstalled` | ✅ Correct |
| `host-media-capture-auto-proof.ps1` | `$summary.Success`, `Results[]` | 🟡 Array += pattern |

---

## 4. Cross-Cutting Issues

### 4.1 Code Duplication
- `Get-DriverResidue` + `Get-HlkArpEntries` duplicated in `hyperv-hlk-client.ps1` and `hyperv-hlk-preflight.ps1`
- `Join-GuestTextOutput` duplicated across multiple guest scriptblocks in `hyperv-hold-webcam-session.ps1`
- `Restore-Checkpoint` pattern duplicated in `hyperv-hlk-client.ps1`, `hyperv-hlk-preflight.ps1`, `hyperv-proof-chrome.ps1`, `hyperv-proof-windows-camera.ps1`

**Recommendation:** consolidate into `hyperv-common.ps1` (or new `hyperv-hlk-common.ps1`).

### 4.2 pnputil Exit Code 2 Not Handled
Occurs in setup-driver install flows and `hyperv-clean-checkpoint.ps1`. Exit code 2 = reboot required (not an error). Treat as `$rebootRequired = $true` and continue.

### 4.3 Credential Exposure via cmdkey
`hyperv-hlk-client.ps1` and `hyperv-hlk-preflight.ps1` call `cmdkey` with plaintext password in a `cmd.exe` argument string. Visible in process listings. Mitigate: write a temp `.cmd` file, invoke, delete — or use `net use` with `PSCredential`.

### 4.4 Inline Script Strings
`hyperv-proof-windows-camera.ps1` embeds ~80 lines of PowerShell as a here-string written at runtime. Makes code invisible to static analysis. Extract to `scripts/windows-camera-shot.ps1` and deploy via `Copy-HvToGuest`.

### 4.5 Write-LiveLine on Redirected Stdout
Both VHLK runners use `\r` for in-place spinner. Redirected output (CI, log files) will contain carbled text. Guard with `[Console]::IsOutputRedirected`.

---

## 5. Priority Action List

| # | Finding | File(s) | Severity |
|---|---------|---------|----------|
| 1 | VHLK counter stale on null poll — add null guard + WARN log | `run-vhlk-tests.ps1`, `run-vhlk-smoke-3tests.ps1` | 🔴 |
| 2 | `Write-LiveLine` garbled on redirected stdout | `run-vhlk-tests.ps1`, `run-vhlk-smoke-3tests.ps1` | 🟡 |
| 3 | `cmdkey` plaintext visible in process list | `hyperv-hlk-client.ps1`, `hyperv-hlk-preflight.ps1` | 🟡 |
| 4 | Inline camera script string — extract to file | `hyperv-proof-windows-camera.ps1` | 🟡 |
| 5 | `$shadow` variable `$deadline` inside remote scriptblock | `hyperv-proof-windows-camera.ps1` | 🟡 |
| 6 | Extract `Get-DriverResidue` / `Get-HlkArpEntries` to shared module | `hlk-client` + `hlk-preflight` | 🟡 |
| 7 | pnputil exit 2 = reboot required, not error | setup wizard, `clean-checkpoint` | 🟡 |
| 8 | `Update-AttemptState` JSON write needs error guard | `hyperv-proof-chrome.ps1` | 🟡 |
| 9 | `$before`/`$after` path comparison case-sensitivity | `test-performance-audit.ps1` | 🟡 |
| 10 | `sshd -T` version-dependent exit code issue | `hyperv-enable-ssh.ps1` | 🟡 |
| 11 | `test-ks-invalid-buffer-fuzz.ps1` SKIP exits 0 | `test-ks-invalid-buffer-fuzz.ps1` | 🟢 |
| 12 | Artifact size not verified (zero-byte check) | `build-all.ps1` | 🟢 |
| 13 | `Get-HvArtifactDirectory` not collision-safe | `hyperv-common.ps1` | 🟢 |
| 14 | `$env:NODE_PATH` redundant in playwright proof | `playwright-vm-webcam-proof.ps1` | 🟢 |
| 15 | `hyperv-clean-validate.ps1` exits 0 on failure | `hyperv-clean-validate.ps1` | 🟢 |
