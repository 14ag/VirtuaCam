[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Get-RepoText {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = Join-Path $repoRoot $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Missing file: $Path"
    }
    Get-Content -LiteralPath $fullPath -Raw
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ((Get-RepoText -Path $Path) -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ((Get-RepoText -Path $Path) -match $Pattern) {
        throw $Message
    }
}

$json = ConvertTo-Json -InputObject @("DF - PNP Remove Device Test (Reliability)", "DF - Reinstall with IO Before and After (Reliability)") -Depth 3 -Compress
$decodedSelectedNames = ConvertFrom-Json -InputObject $json
$roundTripNames = @($decodedSelectedNames | ForEach-Object { ([string]$_).Trim() })
if ($roundTripNames.Count -ne 2) {
    throw "PowerShell 5 JSON array parsing must preserve two selected vHLK test names."
}

$vhlkScripts = @("scripts\run-vhlk-tests.ps1", "scripts\run-vhlk-smoke-3tests.ps1")
foreach ($path in $vhlkScripts) {
    Assert-Contains -Path $path -Pattern "\[Console\]::IsOutputRedirected" -Message "$path must avoid carriage-return live lines when stdout is redirected."
    Assert-Contains -Path $path -Pattern "Wait-HvVmReady" -Message "$path must use shared VM readiness gate before PowerShell Direct work."
    Assert-Contains -Path $path -Pattern "ActiveCancelledResults" -Message "$path must cancel active queued/running results before queueing."
    Assert-Contains -Path $path -Pattern "FailedTestNames" -Message "$path must export full failed test names."
    Assert-Contains -Path $path -Pattern "failed-test-names\.txt" -Message "$path must persist failed test names for failed-only reruns."
    Assert-Contains -Path $path -Pattern "StatusFresh" -Message "$path must mark stale reused status after poll failures."
    Assert-Contains -Path $path -Pattern "StatusPollError" -Message "$path must persist poll error text when status is stale."
    Assert-Contains -Path $path -Pattern "Remote status poll failed; using last known status" -Message "$path must warn on stale status polls."
    Assert-Contains -Path $path -Pattern "MaxControllerReconnectFailures\s*=\s*5" -Message "$path must cap controller reconnect failures at five by default."
    Assert-Contains -Path $path -Pattern "controller-reconnect-limit\.json" -Message "$path must persist controller reconnect stop metadata."
    Assert-NotContains -Path $path -Pattern "Select-Object\s+-First\s+5\s+\|\s+ForEach-Object\s*\{" -Message "$path must not truncate failed-name export to five failures."
}

Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Get-HvVmConnectionState" -Message "hyperv-common must expose Probe-VMState connection states."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Get-HvVmReadiness" -Message "hyperv-common must expose VM readiness inspection."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Wait-HvVmReady" -Message "hyperv-common must expose VM readiness polling."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Stop-HvVmForRestore" -Message "hyperv-common must stop VMs safely before checkpoint restore."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Start-HvFreshCheckpointVm" -Message "hyperv-common must restore checkpoint, force off, start, and wait for DUT fresh starts."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Start-HvFreshControllerVm" -Message "hyperv-common must power-cycle the vHLK controller before vHLK runs."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Initialize-HvVhlkRunVms" -Message "hyperv-common must expose one helper for vHLK VM fresh starts."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "Test-HvTransientPowerShellDirectError" -Message "known boot-time PowerShell Direct errors must be treated as transient readiness states."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "PollIntervalSeconds\s*=\s*3" -Message "VM readiness polling must default to 3 seconds."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "vmicvmsession" -Message "VM readiness must report vmicvmsession status."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "ReadyToConnect" -Message "VM readiness must support ReadyToConnect state."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "LogonUI" -Message "VM readiness must report login-screen state."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "userinit" -Message "VM readiness must report profile-loading state."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "explorer" -Message "VM readiness must report shell-settled state."
Assert-Contains -Path "scripts\hyperv-driver-loop.ps1" -Pattern 'ReadyCheckpointName\s*=\s*"clean-ready"' -Message "driver-test loop must prefer clean-ready checkpoint when present."
Assert-Contains -Path "scripts\hyperv-driver-loop.ps1" -Pattern "DisableReadyCheckpointPreference" -Message "driver-test loop must allow disabling ready checkpoint preference."
Assert-Contains -Path "scripts\hyperv-driver-loop.ps1" -Pattern "RequireInteractiveSession" -Message "driver loop must wait for interactive readiness before UI repro."
Assert-Contains -Path "scripts\hyperv-proof-windows-camera.ps1" -Pattern "RequireInteractiveSession" -Message "Windows Camera proof must wait for interactive readiness."
Assert-Contains -Path "scripts\test-driver-dshow-probe.ps1" -Pattern "DirectShow probe gate" -Message "driver-test DirectShow gate script must exist."
Assert-Contains -Path "scripts\test-driver-dshow-probe.ps1" -Pattern 'Set-Content -LiteralPath \$localLog' -Message "DirectShow gate must write probe logs on host side."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "ResearchGateFailureCount" -Message "failed-only vHLK must stop at the research failure threshold."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "StopOnFailureCount" -Message "failed-only vHLK must support a hard failure threshold."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "research-gate\.json" -Message "research gate must persist failure metadata."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "MonitoringSelectedTests" -Message "failed-only monitor must count selected tests instead of whole project."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "ProjectTotal" -Message "failed-only monitor must preserve whole-project total separately."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "MatchedTotal" -Message "failed-only monitor must report matched selected tests separately from selected total."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern 'Total\s*=\s*\$selectedTotal' -Message "failed-only monitor Total must equal selected list count."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern 'completed' -Message "vHLK monitor must label fully completed selected runs as completed."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern '\$status\.Completed\s+-ge\s+\$status\.Total' -Message "vHLK monitor must exit when completed count reaches selected total."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "vm-fresh-start\.json" -Message "main vHLK runner must write fresh-start metadata."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "SkipFreshStart" -Message "main vHLK runner must support wrapper-owned fresh starts."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "SkipDutInstall" -Message "main vHLK runner must support wrapper-owned DUT install."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "SelectedTestNamesJson" -Message "failed-only monitor must pass selected test names into remote status polling."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern 'decodedSelectedNames\s*=\s*ConvertFrom-Json -InputObject \$SelectedTestNamesJson' -Message "failed-only monitor must parse JSON arrays before enumeration on PowerShell 5."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern '\$monitoredTests\s*=\s*@\(\)' -Message "failed-only monitor must preserve array semantics for one selected test."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "testsToManage" -Message "failed-only clean/cancel must be scoped to selected tests."
Assert-Contains -Path "scripts\run-vhlk-tests.ps1" -Pattern "ManagedTests" -Message "failed-only clean/cancel scope must be persisted in queue/cancel metadata."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "ResearchGateFailureCount\s*=\s*2" -Message "failed-only wrapper must default to 2-failure research gate."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "MaxControllerReconnectFailures\s*=\s*5" -Message "failed-only wrapper must default to five controller reconnect failures."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "install-driver-for-vhlk\.ps1" -Message "failed-only wrapper must install staged driver into DUT before vHLK."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "export-vhlk-failed-tests\.ps1" -Message "failed-only wrapper must export controller failed names itself."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "filter-vhlk-test-list\.ps1" -Message "failed-only wrapper must filter documented blockers itself."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "vm-fresh-start\.json" -Message "failed-only wrapper must write fresh-start metadata."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "failed-only-summary\.json" -Message "failed-only wrapper must write one-call run summary."
Assert-Contains -Path "scripts\run-vhlk-failed-only.ps1" -Pattern "No failed vHLK tests to run" -Message "failed-only wrapper must exit cleanly when controller export has no failures."
Assert-Contains -Path "scripts\export-vhlk-failed-tests.ps1" -Pattern "failed-test-names\.txt" -Message "failed-name export script must write failed-test-names.txt."
Assert-Contains -Path "scripts\export-vhlk-failed-tests.ps1" -Pattern "export-incomplete\.json" -Message "failed-name export script must write incomplete export metadata on failure."
Assert-Contains -Path "scripts\export-vhlk-failed-tests.ps1" -Pattern "ShortExportRoot" -Message "failed-result detail export must use a short guest root."
Assert-Contains -Path "scripts\run-vhlk-smoke-3tests.ps1" -Pattern 'Total\s*=\s*\$selectedTotal' -Message "smoke monitor Total must equal selected smoke list count."
Assert-Contains -Path "scripts\run-vhlk-smoke-3tests.ps1" -Pattern "vm-fresh-start\.json" -Message "smoke runner must write fresh-start metadata."
Assert-Contains -Path "docs\vhlk-blocked-test-names.txt" -Pattern "Camera Driver Test - Photo Capture - Capture an NV12 photo" -Message "documented vHLK blockers must have a machine-readable skip list."
Assert-Contains -Path "scripts\install-all.ps1" -Pattern "function Stop-VirtuaCamRuntime" -Message "installer must stop runtime processes before driver install."
Assert-Contains -Path "scripts\install-all.ps1" -Pattern "SkipWatcherService" -Message "installer must support vHLK installs without watcher service."
Assert-Contains -Path "scripts\install-driver-for-vhlk.ps1" -Pattern "-SkipWatcherService" -Message "vHLK DUT install must not enable watcher service during HLK reliability tests."
Assert-Contains -Path "scripts\install-driver-for-vhlk.ps1" -Pattern "SkipFreshStart" -Message "vHLK DUT install must support wrapper-owned fresh starts."
Assert-Contains -Path "batch-scripts\vhlk-tasklist.bat" -Pattern '\$ErrorActionPreference=''Stop''' -Message "batch local gate must stop on first failed PowerShell gate."
Assert-Contains -Path "batch-scripts\vhlk-tasklist.bat" -Pattern "test-ai-window-cli\.ps1" -Message "batch local gate must include the AI window CLI whitebox test."
Assert-Contains -Path "batch-scripts\binaries\selector.bat" -Pattern "GTR 9" -Message "selector must fail clearly when options exceed choice key range."

Write-Host "vHLK runner flow whitebox checks passed."
