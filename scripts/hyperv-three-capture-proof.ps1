[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [string]$GuestPasswordPlaintext = "",
    [string]$ArtifactRoot = "test-reports\playwright\three-capture-proof",
    [ValidateSet("Chrome", "Edge")][string]$Browser = "Chrome",
    [string[]]$BrowserExtraArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$root = Resolve-HvPath -Path $ArtifactRoot
$runDir = Join-Path $root (Get-HvTimestamp)
$null = New-Item -ItemType Directory -Force -Path $runDir

$cases = @(
    [pscustomobject]@{ Name = "01-printwindow-notepad"; SourceWindowMode = "Notepad";  CaptureBackend = "printwindow" },
    [pscustomobject]@{ Name = "02-wgc-settings";       SourceWindowMode = "Settings"; CaptureBackend = "wgc" },
    [pscustomobject]@{ Name = "03-bitblt-explorer";    SourceWindowMode = "Explorer"; CaptureBackend = "bitblt" }
)

$results = @()
foreach ($case in $cases) {
    $caseRoot = Join-Path $runDir $case.Name
    $null = New-Item -ItemType Directory -Force -Path $caseRoot

    $proof = & (Join-Path $PSScriptRoot "hyperv-proof-chrome.ps1") `
        -VmName $VmName `
        -CheckpointName $CheckpointName `
        -GuestUser $GuestUser `
        -GuestPasswordPlaintext $GuestPasswordPlaintext `
        -ArtifactRoot $caseRoot `
        -Browser $Browser `
        -SourceWindowMode $case.SourceWindowMode `
        -CaptureBackend $case.CaptureBackend `
        -BrowserExtraArgs $BrowserExtraArgs `
        -RevertAfterRun:$true

    $proofResultPath = Join-Path $caseRoot "vm-webcam-proof.json"
    $proofResult = if (Test-Path -LiteralPath $proofResultPath) {
        Get-Content -LiteralPath $proofResultPath -Raw | ConvertFrom-Json
    } else {
        $proof
    }

    $results += [pscustomobject]@{
        Name = $case.Name
        SourceWindowMode = $case.SourceWindowMode
        CaptureBackend = $case.CaptureBackend
        Success = [bool]$proofResult.success
        SourceWindowTitle = [string]$proofResult.SourceWindowTitle
        SourceWindowHwnd = [string]$proofResult.SourceWindowHwnd
        VideoWidth = [int]$proofResult.state.videoWidth
        VideoHeight = [int]$proofResult.state.videoHeight
        ArtifactRoot = $caseRoot
        ScreenshotPath = Join-Path $caseRoot "vm-webcam-proof.png"
    }
}

$summary = [pscustomobject]@{
    Success = @($results | Where-Object { -not $_.Success }).Count -eq 0
    RunDir = $runDir
    Cases = $results
    CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir "three-capture-proof-summary.json") -Encoding UTF8
$summary
