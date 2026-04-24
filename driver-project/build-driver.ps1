[CmdletBinding()]
param(
    [string]$BuildConfig = "Release",
    [string]$Platform = "x64",
    [switch]$Clean,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "`n" -NoNewline; Write-Host "--- [STEP] $Message ---" -ForegroundColor Yellow }
function Write-Success { param([string]$Message) Write-Host "  - SUCCESS:" -ForegroundColor Green -NoNewline; Write-Host " $Message" }
function Write-Info { param([string]$Message) Write-Host "  - INFO:" -ForegroundColor Cyan -NoNewline; Write-Host " $Message" }
function Fail {
    param([string]$Message)
    Write-Host "`n==================== FATAL DRIVER BUILD ERROR ====================" -ForegroundColor Red
    Write-Host "  $Message" -ForegroundColor Red
    Write-Host "===================================================================" -ForegroundColor Red
    exit 1
}

function Get-VsWherePath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\\Installer\\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) { return $vswhere }
    return $null
}

function Get-MSBuildPath {
    $vswhere = Get-VsWherePath
    if (-not $vswhere) { return $null }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) { return $null }

    $candidates = @(
        (Join-Path $installationPath "MSBuild\\Current\\Bin\\MSBuild.exe"),
        (Join-Path $installationPath "MSBuild\\17.0\\Bin\\MSBuild.exe")
    )

    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }

    return $null
}

function Get-WdkRoot {
    try {
        $roots = Get-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots" -ErrorAction Stop
        if ($roots.KitsRoot10 -and (Test-Path -LiteralPath $roots.KitsRoot10)) { return $roots.KitsRoot10 }
    } catch {
        return $null
    }
    return $null
}

function Assert-WdkPresent {
    $wdkRoot = Get-WdkRoot
    if (-not $wdkRoot) {
        Fail "Windows Kits root not found in registry. Install Windows 10/11 SDK + WDK (Visual Studio 'Windows Driver Kit')."
    }

    $includeRoot = Join-Path $wdkRoot "Include"
    if (-not (Test-Path -LiteralPath $includeRoot)) {
        Fail "Windows Kits include dir missing: $includeRoot. Install Windows 10/11 SDK + WDK."
    }

    $verDir = Get-ChildItem -Path $includeRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $verDir) {
        Fail "No versioned include folders under: $includeRoot. Install Windows 10/11 SDK + WDK."
    }

    $wdfDir = Join-Path $verDir.FullName "wdf"
    if (-not (Test-Path -LiteralPath $wdfDir)) {
        $wdfDir = Join-Path $includeRoot "wdf"
    }
    
    if (-not (Test-Path -LiteralPath $wdfDir)) {
        Fail "WDK headers not found (missing 'wdf'): looked in $($verDir.FullName)\wdf and $includeRoot\wdf. Install WDK (not just Windows SDK)."
    }

    Write-Success "WDK detected at: $wdkRoot"
}

function Get-OutputPaths {
    param([string]$Root)

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $defaultRoot = Join-Path $scriptDir "..\\output"

    $resolvedRoot = if ([string]::IsNullOrWhiteSpace($Root)) { $defaultRoot } else { $Root }

    return [pscustomobject]@{
        Root    = $resolvedRoot
        Build   = (Join-Path $resolvedRoot "driver\\build")
        Package = (Join-Path $resolvedRoot "driver\\package")
        Logs    = (Join-Path $resolvedRoot "logs")
    }
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $all = @($Arguments)
    Write-Host "> $FilePath $($all -join ' ')"
    & $FilePath @all
    if ($LASTEXITCODE -ne 0) {
        Fail "$FilePath failed with exit code $LASTEXITCODE."
    }
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$solutionPath = Join-Path $scriptDir "Driver\\avshws\\avshws.sln"
if (-not (Test-Path -LiteralPath $solutionPath)) { Fail "Driver solution not found: $solutionPath" }

Write-Host "============================================================" -ForegroundColor Green
Write-Host " Driver Build Wrapper"
Write-Host "============================================================" -ForegroundColor Green

Write-Step "Pre-flight checks"
$msbuild = Get-MSBuildPath
if (-not $msbuild) { Fail "MSBuild not found. Install Visual Studio Build Tools 2022 (MSBuild + C++ workload)." }
Write-Success "MSBuild: $msbuild"

Assert-WdkPresent

$out = Get-OutputPaths -Root $OutputRoot
$null = New-Item -ItemType Directory -Force -Path $out.Build, $out.Package, $out.Logs
Write-Info "OutputRoot: $($out.Root)"

Write-Step "Build (msbuild)"
$targets = if ($Clean) { "Clean;Build" } else { "Build" }
Invoke-NativeProcess -FilePath $msbuild -Arguments @(
    $solutionPath,
    "/m",
    "/t:$targets",
    "/p:Configuration=$BuildConfig",
    "/p:Platform=$Platform",
    "/nologo",
    "/v:m"
)
Write-Success "Driver build complete: $BuildConfig|$Platform"

Write-Step "Stage artifacts to output/"
$driverRoot = Join-Path $scriptDir "Driver\\avshws"
$srcBuildDir = Join-Path $driverRoot ("build\\{0}\\{1}" -f $Platform, $BuildConfig)
$srcPkgDir = Join-Path $driverRoot ("package\\{0}\\{1}" -f $Platform, $BuildConfig)

if (-not (Test-Path -LiteralPath $srcBuildDir)) { Fail "Driver build output dir missing: $srcBuildDir" }
if (-not (Test-Path -LiteralPath $srcPkgDir)) { Fail "Driver package dir missing: $srcPkgDir" }

Copy-Item -LiteralPath (Join-Path $srcBuildDir "*") -Destination $out.Build -Recurse -Force
Write-Success "Staged build outputs -> $($out.Build)"

$pkgFiles = @("avshws.sys", "avshws.inf", "avshws.cat", "VirtualCameraDriver-TestSign.cer")
foreach ($f in $pkgFiles) {
    $src = Join-Path $srcPkgDir $f
    if (-not (Test-Path -LiteralPath $src)) { Fail "Missing package file: $src" }
    Copy-Item -LiteralPath $src -Destination $out.Package -Force
}
Write-Success "Staged package -> $($out.Package)"

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " DRIVER BUILD SUCCEEDED"
Write-Host "============================================================" -ForegroundColor Green
