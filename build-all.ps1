[CmdletBinding()]
param(
    [switch]$Clean,
    [string]$BuildConfig = "Release",
    [switch]$SkipSoftware,
    [switch]$SkipDriver,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "`n" -NoNewline; Write-Host "--- [STEP] $Message ---" -ForegroundColor Yellow }
function Write-Success { param([string]$Message) Write-Host "  - SUCCESS:" -ForegroundColor Green -NoNewline; Write-Host " $Message" }
function Write-Info { param([string]$Message) Write-Host "  - INFO:" -ForegroundColor Cyan -NoNewline; Write-Host " $Message" }
function Fail { param([string]$Message) Write-Host $Message -ForegroundColor Red; exit 1 }

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $scriptDir "output" }

$softwareBin = Join-Path $OutputRoot "software\\bin"
$driverBuild = Join-Path $OutputRoot "driver\\build"
$driverPkg = Join-Path $OutputRoot "driver\\package"
$logsDir = Join-Path $OutputRoot "logs"

Write-Host "============================================================" -ForegroundColor Green
Write-Host " Build All"
Write-Host "============================================================" -ForegroundColor Green

Write-Step "Prepare output layout"
if ($Clean -and (Test-Path -LiteralPath $OutputRoot)) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Force -Path $softwareBin, $driverBuild, $driverPkg, $logsDir
Write-Info "OutputRoot: $OutputRoot"

if (-not $SkipSoftware) {
    Write-Step "Build software"
    $swBuild = Join-Path $scriptDir "software-project\\build.ps1"
    if (-not (Test-Path -LiteralPath $swBuild)) { Fail "Missing: $swBuild" }
    & $swBuild -BuildConfig $BuildConfig -Clean:$Clean.IsPresent -OutputRoot $OutputRoot
    if ($LASTEXITCODE -ne 0) { Fail "Software build failed (exit $LASTEXITCODE)." }
    Write-Success "Software staged -> $softwareBin"
} else {
    Write-Info "Skip software"
}

if (-not $SkipDriver) {
    Write-Step "Build driver"
    $drvBuild = Join-Path $scriptDir "driver-project\\build-driver.ps1"
    if (-not (Test-Path -LiteralPath $drvBuild)) { Fail "Missing: $drvBuild" }
    & $drvBuild -BuildConfig $BuildConfig -Platform "x64" -Clean:$Clean.IsPresent -OutputRoot $OutputRoot
    if ($LASTEXITCODE -ne 0) { Fail "Driver build failed (exit $LASTEXITCODE)." }
    Write-Success "Driver staged -> $driverPkg"
} else {
    Write-Info "Skip driver"
}

Write-Step "Validate required artifacts"
$requiredSoftware = @(
    (Join-Path $softwareBin "VirtuaCam.exe"),
    (Join-Path $softwareBin "VirtuaCamProcess.exe"),
    (Join-Path $softwareBin "DirectPortBroker.dll")
)
$requiredDriver = @(
    (Join-Path $driverPkg "avshws.sys"),
    (Join-Path $driverPkg "avshws.inf"),
    (Join-Path $driverPkg "avshws.cat"),
    (Join-Path $driverPkg "VirtualCameraDriver-TestSign.cer")
)

foreach ($p in $requiredSoftware) {
    if (-not $SkipSoftware -and -not (Test-Path -LiteralPath $p)) { Fail "Missing software artifact: $p" }
}
foreach ($p in $requiredDriver) {
    if (-not $SkipDriver -and -not (Test-Path -LiteralPath $p)) { Fail "Missing driver artifact: $p" }
}
Write-Success "Artifacts present"

Write-Step "Artifact inventory"
Write-Host ""
Write-Host "Software: $softwareBin"
Get-ChildItem -LiteralPath $softwareBin -File | Sort-Object Name | ForEach-Object { Write-Host ("  - {0} ({1:n0} bytes)" -f $_.Name, $_.Length) }
Write-Host ""
Write-Host "Driver package: $driverPkg"
Get-ChildItem -LiteralPath $driverPkg -File | Sort-Object Name | ForEach-Object { Write-Host ("  - {0} ({1:n0} bytes)" -f $_.Name, $_.Length) }
Write-Host ""

Write-Host "============================================================" -ForegroundColor Green
Write-Host " BUILD-ALL SUCCEEDED"
Write-Host "============================================================" -ForegroundColor Green

