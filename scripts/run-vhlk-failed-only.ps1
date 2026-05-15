[CmdletBinding()]
param(
    [string]$TestNameListPath = "",
    [int]$ResearchGateFailureCount = 2,
    [int]$StopOnFailureCount = 10,
    [int]$MaxControllerReconnectFailures = 5,
    [int]$PendingStartTimeoutSeconds = 300,
    [int]$TimeoutMinutes = 60,
    [switch]$SkipDutInstall,
    [switch]$NoExport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))

if ([string]::IsNullOrWhiteSpace($TestNameListPath)) {
    if ($NoExport) {
        throw "TestNameListPath is required when -NoExport is used."
    }

    $exportRoot = Join-Path $repoRoot ("test-reports\vhlk-failed-export-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    & (Join-Path $scriptDir "export-vhlk-failed-tests.ps1") -ArtifactRoot $exportRoot
    $TestNameListPath = Join-Path $exportRoot "failed-test-names.txt"
}

$resolvedTestNameListPath = Resolve-Path -LiteralPath $TestNameListPath -ErrorAction Stop
$failedNames = @(Get-Content -LiteralPath $resolvedTestNameListPath |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim() })
if ($failedNames.Count -lt 1) {
    Write-Host ("No failed vHLK tests to run. Failed-name list is empty: {0}" -f $resolvedTestNameListPath)
    exit 0
}

if (-not $SkipDutInstall) {
    & (Join-Path $scriptDir "install-driver-for-vhlk.ps1")
}

& (Join-Path $scriptDir "run-vhlk-tests.ps1") `
    -TestNameListPath $TestNameListPath `
    -PendingStartTimeoutSeconds $PendingStartTimeoutSeconds `
    -TimeoutMinutes $TimeoutMinutes `
    -ResearchGateFailureCount $ResearchGateFailureCount `
    -StopOnFailureCount $StopOnFailureCount `
    -MaxControllerReconnectFailures $MaxControllerReconnectFailures

exit $LASTEXITCODE
