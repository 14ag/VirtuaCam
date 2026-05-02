[CmdletBinding()]
param(
    [switch]$Clean,
    [string]$BuildConfig = "Release",
    [switch]$SkipSoftware,
    [switch]$SkipDriver,
    [string]$VcpkgRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "`n" -NoNewline; Write-Host "--- [STEP] $Message ---" -ForegroundColor Yellow }
function Write-Success { param([string]$Message) Write-Host "  - SUCCESS:" -ForegroundColor Green -NoNewline; Write-Host " $Message" }
function Write-Info { param([string]$Message) Write-Host "  - INFO:" -ForegroundColor Cyan -NoNewline; Write-Host " $Message" }
function Fail {
    param([string]$Message)
    Write-Host "`n==================== FATAL BUILD ERROR ====================" -ForegroundColor Red
    Write-Host "  $Message" -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
    exit 1
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Get-VsWherePath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) { return $vswhere }
    return $null
}

function Get-MSBuildPath {
    $vswhere = Get-VsWherePath
    if (-not $vswhere) { return $null }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) { return $null }

    foreach ($candidate in @(
        (Join-Path $installationPath "MSBuild\Current\Bin\MSBuild.exe"),
        (Join-Path $installationPath "MSBuild\17.0\Bin\MSBuild.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return $null
}

function Get-X64CompilerPath {
    $vswhere = Get-VsWherePath
    if (-not $vswhere) { return $null }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) { return $null }

    $msvcRoot = Join-Path $installationPath "VC\Tools\MSVC"
    if (-not (Test-Path -LiteralPath $msvcRoot)) { return $null }

    $toolsetDir = Get-ChildItem -Path $msvcRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $toolsetDir) { return $null }

    $compilerPath = Join-Path $toolsetDir.FullName "bin\Hostx64\x64\cl.exe"
    if (Test-Path -LiteralPath $compilerPath) { return $compilerPath }
    return $null
}

function Get-VcRedistX64Dir {
    $vswhere = Get-VsWherePath
    if (-not $vswhere) { return $null }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Redist.14.Latest -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) { return $null }

    $redistRoot = Join-Path $installationPath "VC\Redist\MSVC"
    if (-not (Test-Path -LiteralPath $redistRoot)) { return $null }

    $redistDir = Get-ChildItem -Path $redistRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $redistDir) { return $null }

    $crtDir = Join-Path $redistDir.FullName "x64\Microsoft.VC143.CRT"
    if (Test-Path -LiteralPath $crtDir) { return $crtDir }

    return $null
}

function Get-WdkRoot {
    try {
        $roots = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots" -ErrorAction Stop
        if ($roots.KitsRoot10 -and (Test-Path -LiteralPath $roots.KitsRoot10)) { return $roots.KitsRoot10 }
    } catch {
        return $null
    }
    return $null
}

function Assert-WdkPresent {
    $wdkRoot = Get-WdkRoot
    if (-not $wdkRoot) {
        Fail "Windows Kits root not found. Install Windows SDK + WDK."
    }

    $includeRoot = Join-Path $wdkRoot "Include"
    if (-not (Test-Path -LiteralPath $includeRoot)) {
        Fail "Windows Kits include dir missing: $includeRoot"
    }

    $verDir = Get-ChildItem -Path $includeRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $verDir) {
        Fail "No versioned include folders under: $includeRoot"
    }

    $wdfDir = Join-Path $verDir.FullName "wdf"
    if (-not (Test-Path -LiteralPath $wdfDir)) {
        $wdfDir = Join-Path $includeRoot "wdf"
    }
    if (-not (Test-Path -LiteralPath $wdfDir)) {
        Fail "WDK headers not found. Install WDK."
    }

    Write-Success "WDK detected at: $wdkRoot"
}

function Get-SdkToolPath {
    param(
        [Parameter(Mandatory = $true)][string]$ToolName,
        [Parameter(Mandatory = $true)][string]$Architecture
    )

    $wdkRoot = Get-WdkRoot
    if (-not $wdkRoot) { return $null }

    $binRoot = Join-Path $wdkRoot "bin"
    if (-not (Test-Path -LiteralPath $binRoot)) { return $null }

    $versioned = Get-ChildItem -Path $binRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object Name -Descending

    foreach ($v in $versioned) {
        $candidate = Join-Path $v.FullName ("{0}\{1}" -f $Architecture, $ToolName)
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $fallback = Join-Path (Join-Path $binRoot $Architecture) $ToolName
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    return $null
}

function Get-OrCreateTestCodeSigningCertificate {
    param([string]$SubjectCommonName)

    $subject = "CN=$SubjectCommonName"
    $cert = Get-ChildItem -Path Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if (-not $cert) {
        $cert = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $subject `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -HashAlgorithm SHA256 `
            -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears(5)
    }

    if (-not $cert) {
        Fail "Unable to create or locate test signing certificate '$subject'."
    }

    return $cert
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath($scriptDir)
. (Join-Path $repoRoot "tools\artifact-manifest.ps1")
$softwareDir = Join-Path $repoRoot "software-project"
$softwareSrcDir = Join-Path $softwareDir "src"
$softwareBuildDir = Join-Path $softwareDir "build"
$driverRoot = Join-Path $repoRoot "driver-project\Driver\avshws"
$driverSolutionPath = Join-Path $driverRoot "avshws.sln"
$OutputRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "output"))
$logsDir = Join-Path $OutputRoot "logs"
$driverPackageTmp = Join-Path $repoRoot ".driver-package-work"

Write-Host "============================================================" -ForegroundColor Green
Write-Host " Build All"
Write-Host "============================================================" -ForegroundColor Green

Write-Step "Pre-flight checks"
$msbuild = Get-MSBuildPath
if (-not $msbuild) { Fail "MSBuild not found. Install Visual Studio Build Tools 2022." }
Write-Success "MSBuild: $msbuild"
Assert-WdkPresent

if (-not (Test-Path -LiteralPath (Join-Path $softwareSrcDir "CMakeLists.txt"))) {
    Fail "Software CMakeLists.txt missing: $softwareSrcDir"
}
if (-not (Test-Path -LiteralPath $driverSolutionPath)) {
    Fail "Driver solution missing: $driverSolutionPath"
}

if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
    if ($env:VCPKG_ROOT -and (Test-Path -LiteralPath $env:VCPKG_ROOT)) {
        $VcpkgRoot = $env:VCPKG_ROOT
    } elseif (Test-Path -LiteralPath "C:\vcpkg") {
        $VcpkgRoot = "C:\vcpkg"
    } else {
        $VcpkgRoot = Join-Path $softwareDir "vcpkg"
    }
}
$VcpkgRoot = [System.IO.Path]::GetFullPath($VcpkgRoot)
$toolchainFile = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"

Write-Step "Prepare output layout"
if ($Clean -and (Test-Path -LiteralPath $OutputRoot)) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Force -Path $OutputRoot, $logsDir, $driverPackageTmp
Write-Info "OutputRoot: $OutputRoot"

foreach ($legacyDir in @(
    (Join-Path $OutputRoot "software"),
    (Join-Path $OutputRoot "driver")
)) {
    if (Test-Path -LiteralPath $legacyDir) {
        Remove-Item -LiteralPath $legacyDir -Recurse -Force
    }
}

if (-not $SkipSoftware) {
    Write-Step "Build software"

    if (-not (Test-Path -LiteralPath $VcpkgRoot)) {
        Write-Info "Cloning vcpkg into $VcpkgRoot"
        Invoke-NativeProcess -FilePath "git" -Arguments @("clone", "https://github.com/microsoft/vcpkg.git", $VcpkgRoot)
        Invoke-NativeProcess -FilePath "cmd.exe" -Arguments @("/c", (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat"), "-disableMetrics")
    }
    if (-not (Test-Path -LiteralPath $toolchainFile)) {
        Fail "vcpkg toolchain file missing: $toolchainFile"
    }

    Get-Process -Name "VirtuaCam" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }

    if ($Clean -and (Test-Path -LiteralPath $softwareBuildDir)) {
        Remove-Item -LiteralPath $softwareBuildDir -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Force -Path $softwareBuildDir

    $cmakeConfigArgs = @(
        "-S", $softwareSrcDir,
        "-B", $softwareBuildDir,
        "-G", "Visual Studio 17 2022",
        "-A", "x64",
        "-T", "host=x64",
        "-DVCPKG_TARGET_TRIPLET=x64-windows",
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile"
    )

    $x64Compiler = Get-X64CompilerPath
    if ($x64Compiler) {
        $cmakeConfigArgs += "-DCMAKE_CXX_COMPILER=$x64Compiler"
    }

    Invoke-NativeProcess -FilePath "cmake" -Arguments $cmakeConfigArgs
    Invoke-NativeProcess -FilePath "cmake" -Arguments @("--build", $softwareBuildDir, "--config", $BuildConfig)

    $softwareArtifactDir = Join-Path $softwareBuildDir $BuildConfig
    if (-not (Test-Path -LiteralPath $softwareArtifactDir)) {
        Fail "Software build artifact dir missing: $softwareArtifactDir"
    }

    foreach ($legacy in @("DirectPortMFCamera.dll", "DirectPortMFGraphicsCapture.dll")) {
        $legacyPath = Join-Path $OutputRoot $legacy
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force
        }
    }

    $softwareArtifacts = Get-VirtuaCamSoftwareArtifacts
    $vcRuntimeArtifacts = Get-VirtuaCamRuntimeArtifacts

    foreach ($name in $softwareArtifacts) {
        $src = Join-Path $softwareArtifactDir $name
        if (-not (Test-Path -LiteralPath $src)) {
            Fail "Missing software artifact: $src"
        }
        Copy-Item -LiteralPath $src -Destination $OutputRoot -Force
        $pdb = [System.IO.Path]::ChangeExtension($src, ".pdb")
        if (Test-Path -LiteralPath $pdb) {
            Copy-Item -LiteralPath $pdb -Destination $OutputRoot -Force
        }
    }

    $vcRedistDir = Get-VcRedistX64Dir
    if (-not $vcRedistDir) {
        Fail "Visual C++ x64 runtime redist folder not found."
    }

    foreach ($name in $vcRuntimeArtifacts) {
        $src = Join-Path $vcRedistDir $name
        if (-not (Test-Path -LiteralPath $src)) {
            Fail "Missing VC runtime artifact: $src"
        }
        Copy-Item -LiteralPath $src -Destination $OutputRoot -Force
    }

    Write-Success "Software staged -> $OutputRoot"
} else {
    Write-Info "Skip software"
}

if (-not $SkipDriver) {
    Write-Step "Build driver"

    $targets = if ($Clean) { "Clean;Build" } else { "Build" }
    Invoke-NativeProcess -FilePath $msbuild -Arguments @(
        $driverSolutionPath,
        "/m",
        "/t:$targets",
        "/p:Configuration=$BuildConfig",
        "/p:Platform=x64",
        "/nologo",
        "/v:m"
    )

    $driverBuildDir = Join-Path $driverRoot ("build\x64\{0}" -f $BuildConfig)
    $driverSys = Join-Path $driverBuildDir "avshws.sys"
    $driverPdb = Join-Path $driverBuildDir "avshws.pdb"
    $driverInf = Join-Path $driverRoot "avshws.inf"
    if (-not (Test-Path -LiteralPath $driverSys)) { Fail "Fresh driver sys missing: $driverSys" }
    if (-not (Test-Path -LiteralPath $driverInf)) { Fail "Driver INF missing: $driverInf" }

    if (Test-Path -LiteralPath $driverPackageTmp) {
        Get-ChildItem -LiteralPath $driverPackageTmp -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Copy-Item -LiteralPath $driverSys -Destination (Join-Path $driverPackageTmp "avshws.sys") -Force
    Copy-Item -LiteralPath $driverInf -Destination (Join-Path $driverPackageTmp "avshws.inf") -Force

    $inf2cat = Get-SdkToolPath -ToolName "Inf2Cat.exe" -Architecture "x86"
    $signtool = Get-SdkToolPath -ToolName "signtool.exe" -Architecture "x64"
    if (-not $inf2cat) { Fail "Inf2Cat.exe not found in Windows Kits bin." }
    if (-not $signtool) { Fail "signtool.exe not found in Windows Kits bin." }

    Invoke-NativeProcess -FilePath $inf2cat -Arguments @("/driver:$driverPackageTmp", "/os:10_X64")

    $catPath = Join-Path $driverPackageTmp "avshws.cat"
    if (-not (Test-Path -LiteralPath $catPath)) {
        Fail "Catalog generation failed: $catPath not found."
    }

    $cert = Get-OrCreateTestCodeSigningCertificate -SubjectCommonName "VirtualCameraDriver-TestSign"
    $cerPath = Join-Path $driverPackageTmp "VirtualCameraDriver-TestSign.cer"
    Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null

    Invoke-NativeProcess -FilePath $signtool -Arguments @(
        "sign",
        "/v",
        "/fd", "SHA256",
        "/sha1", $cert.Thumbprint,
        "/s", "My",
        $catPath
    )

    foreach ($artifact in @((Get-VirtuaCamDriverArtifacts) + "avshws.pdb")) {
        $dst = Join-Path $OutputRoot $artifact
        if (Test-Path -LiteralPath $dst) {
            Remove-Item -LiteralPath $dst -Force
        }
    }

    foreach ($artifact in (Get-VirtuaCamDriverArtifacts)) {
        Copy-Item -LiteralPath (Join-Path $driverPackageTmp $artifact) -Destination (Join-Path $OutputRoot $artifact) -Force
    }
    if (Test-Path -LiteralPath $driverPdb) {
        Copy-Item -LiteralPath $driverPdb -Destination (Join-Path $OutputRoot "avshws.pdb") -Force
    }

    Write-Success "Driver staged -> $OutputRoot"
} else {
    Write-Info "Skip driver"
}

Write-Step "Validate required artifacts"
$requiredSoftware = @((Get-VirtuaCamSoftwareArtifacts) + (Get-VirtuaCamRuntimeArtifacts))
$requiredDriver = Get-VirtuaCamDriverArtifacts

foreach ($name in $requiredSoftware) {
    if (-not $SkipSoftware -and -not (Test-Path -LiteralPath (Join-Path $OutputRoot $name))) {
        Fail "Missing software artifact in output: $name"
    }
}
foreach ($name in $requiredDriver) {
    if (-not $SkipDriver -and -not (Test-Path -LiteralPath (Join-Path $OutputRoot $name))) {
        Fail "Missing driver artifact in output: $name"
    }
}
Write-Success "Artifacts present in output"

Write-Step "Artifact inventory"
Get-ChildItem -LiteralPath $OutputRoot -File | Sort-Object Name | ForEach-Object {
    Write-Host ("  - {0} ({1:n0} bytes)" -f $_.Name, $_.Length)
}

if (Test-Path -LiteralPath $driverPackageTmp) {
    Remove-Item -LiteralPath $driverPackageTmp -Recurse -Force
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " BUILD-ALL SUCCEEDED"
Write-Host "============================================================" -ForegroundColor Green
