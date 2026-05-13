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
    Assert-NotContains -Path $path -Pattern "Select-Object\s+-First\s+5\s+\|\s+ForEach-Object\s*\{" -Message "$path must not truncate failed-name export to five failures."
}

Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Get-HvVmReadiness" -Message "hyperv-common must expose VM readiness inspection."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "function Wait-HvVmReady" -Message "hyperv-common must expose VM readiness polling."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "PollIntervalSeconds\s*=\s*3" -Message "VM readiness polling must default to 3 seconds."
Assert-Contains -Path "scripts\hyperv-common.ps1" -Pattern "vmicvmsession" -Message "VM readiness must report vmicvmsession status."
Assert-Contains -Path "scripts\hyperv-driver-loop.ps1" -Pattern 'ReadyCheckpointName\s*=\s*"clean-ready"' -Message "driver-test loop must prefer clean-ready checkpoint when present."
Assert-Contains -Path "scripts\hyperv-driver-loop.ps1" -Pattern "DisableReadyCheckpointPreference" -Message "driver-test loop must allow disabling ready checkpoint preference."

Write-Host "vHLK runner flow whitebox checks passed."
