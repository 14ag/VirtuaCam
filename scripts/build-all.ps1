[CmdletBinding()]
param(
    [string]$BuildConfig = "Release",
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

function Assert-FilePresentAndNotEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Fail "Required artifact missing: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) {
        Fail "Required artifact is empty: $Path"
    }
}

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $resolvedPath.StartsWith($resolvedRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "Refusing to modify path outside repository root: $resolvedPath"
    }
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

function Stop-VirtuaCamBuildRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $service = Get-Service -Name "VirtuaCamWatcher" -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Stopped") {
        Write-Info "Stopping VirtuaCamWatcher before cleaning output."
        try {
            Stop-Service -Name "VirtuaCamWatcher" -Force -ErrorAction Stop
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10))
        }
        catch {
            Write-Info "Could not stop VirtuaCamWatcher: $($_.Exception.Message)"
        }
    }

    $packageRootFull = [System.IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $processNames = @("VirtuaCam", "VirtuaCamProcess", "VirtuaCamSetup")
    $processes = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        $path = $null
        try {
            $path = [string]$process.MainModule.FileName
        }
        catch {
            try {
                $path = (Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction Stop).ExecutablePath
            }
            catch {
                $path = $null
            }
        }

        $isPackageProcess = $true
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $pathFull = [System.IO.Path]::GetFullPath($path)
            $isPackageProcess = $pathFull.StartsWith($packageRootFull + "\", [System.StringComparison]::OrdinalIgnoreCase)
        }

        if (-not $isPackageProcess) {
            Write-Info ("Leaving unrelated process running: {0} ({1})" -f $process.ProcessName, $process.Id)
            continue
        }

        Write-Info ("Stopping runtime process before cleaning output: {0} ({1})" -f $process.ProcessName, $process.Id)
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }

    foreach ($process in $processes) {
        Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 500
}

function Remove-PathWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [int]$Retries = 8,
        [int]$DelayMilliseconds = 750
    )

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }

        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $Retries) {
                Fail "Could not remove '$Path' after stopping VirtuaCam runtime. Last error: $($_.Exception.Message)"
            }

            Write-Info ("Output cleanup blocked; retry {0}/{1}: {2}" -f $attempt, $Retries, $_.Exception.Message)
            Stop-VirtuaCamBuildRuntime -PackageRoot $PackageRoot
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
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
    $candidateRoots = New-Object System.Collections.Generic.List[string]
    if ($vswhere) {
        foreach ($args in @(
            @("-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Redist.14.Latest", "-property", "installationPath"),
            @("-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath")
        )) {
            $installationPath = & $vswhere @args
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($installationPath)) {
                $candidateRoots.Add((Join-Path $installationPath "VC\Redist\MSVC"))
            }
        }
    }

    foreach ($redistRoot in ($candidateRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $redistRoot)) {
            continue
        }

        $versionedDirs = Get-ChildItem -Path $redistRoot -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } |
            Sort-Object Name -Descending

        foreach ($redistDir in $versionedDirs) {
            foreach ($crtDir in @(
                (Join-Path $redistDir.FullName "x64\Microsoft.VC143.CRT"),
                (Join-Path $redistDir.FullName "onecore\x64\Microsoft.VC143.CRT")
            )) {
                if (Test-Path -LiteralPath $crtDir) {
                    return $crtDir
                }
            }
        }
    }

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

function Get-WdkIncludeVersion {
    $wdkRoot = Get-WdkRoot
    if (-not $wdkRoot) { return $null }

    $includeRoot = Join-Path $wdkRoot "Include"
    if (-not (Test-Path -LiteralPath $includeRoot)) { return $null }

    $verDir = Get-ChildItem -Path $includeRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if ($verDir) { return $verDir.Name }
    return $null
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
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new("My", "CurrentUser")
    $cert = $null
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $cert = $store.Certificates |
            Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1
    }
    finally {
        $store.Close()
    }

    if (-not $cert) {
        Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
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
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $repoRoot "scripts\tools\artifact-manifest.ps1")
$softwareDir = Join-Path $repoRoot "software-project"
$softwareSrcDir = Join-Path $softwareDir "src"
$softwareBuildDir = Join-Path $softwareDir "build"
$wizardDir = Join-Path $repoRoot "wizard-project"
$wizardBuildDir = Join-Path $wizardDir "build"
$driverRoot = Join-Path $repoRoot "driver-project"
$driverSolutionPath = Join-Path $driverRoot "avshws.sln"
$audioDriverRoot = Join-Path $repoRoot "audio-driver-project"
$audioDriverProjects = @(
    (Join-Path $audioDriverRoot "Source\Filters\Filters.vcxproj"),
    (Join-Path $audioDriverRoot "Source\Utilities\Utilities.vcxproj"),
    (Join-Path $audioDriverRoot "Source\Main\Main.vcxproj")
)
$OutputRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "output"))
$driverPackageTmp = Join-Path $repoRoot ".driver-package-work"
$audioDriverPackageTmp = Join-Path $repoRoot ".audio-driver-package-work"
foreach ($pathToGuard in @($OutputRoot, $driverPackageTmp, $audioDriverPackageTmp, $softwareBuildDir, $wizardBuildDir)) {
    Assert-PathInsideRoot -Path $pathToGuard -Root $repoRoot
}

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
if (-not (Test-Path -LiteralPath (Join-Path $wizardDir "CMakeLists.txt"))) {
    Fail "Wizard CMakeLists.txt missing: $wizardDir"
}
if (-not (Test-Path -LiteralPath $driverSolutionPath)) {
    Fail "Driver solution missing: $driverSolutionPath"
}
foreach ($project in $audioDriverProjects) {
    if (-not (Test-Path -LiteralPath $project)) {
        Fail "Audio driver project missing: $project"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $audioDriverRoot "virtuacam-mic.inf"))) {
    Fail "Audio driver INF missing: $(Join-Path $audioDriverRoot "virtuacam-mic.inf")"
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
Stop-VirtuaCamBuildRuntime -PackageRoot $OutputRoot
if (Test-Path -LiteralPath $OutputRoot) {
    Remove-PathWithRetry -Path $OutputRoot -PackageRoot $OutputRoot
}
$null = New-Item -ItemType Directory -Force -Path $OutputRoot, $driverPackageTmp, $audioDriverPackageTmp
Write-Info "OutputRoot: $OutputRoot"
Write-Info ".driver-package-work is a temporary INF/catalog signing workspace; final install artifacts are staged in output."

foreach ($legacyDir in @(
    (Join-Path $OutputRoot "software"),
    (Join-Path $OutputRoot "driver")
)) {
    if (Test-Path -LiteralPath $legacyDir) {
        Remove-Item -LiteralPath $legacyDir -Recurse -Force
    }
}

Write-Step "Build software"

if (-not (Test-Path -LiteralPath $VcpkgRoot)) {
    Write-Info "Cloning vcpkg into $VcpkgRoot"
    Invoke-NativeProcess -FilePath "git" -Arguments @("clone", "https://github.com/microsoft/vcpkg.git", $VcpkgRoot)
    Invoke-NativeProcess -FilePath "cmd.exe" -Arguments @("/c", (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat"), "-disableMetrics")
}
if (-not (Test-Path -LiteralPath $toolchainFile)) {
    Fail "vcpkg toolchain file missing: $toolchainFile"
}

if (Test-Path -LiteralPath $softwareBuildDir) {
    Remove-Item -LiteralPath $softwareBuildDir -Recurse -Force
}
if (Test-Path -LiteralPath $wizardBuildDir) {
    Remove-Item -LiteralPath $wizardBuildDir -Recurse -Force
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

Write-Step "Build setup wizard"
$null = New-Item -ItemType Directory -Force -Path $wizardBuildDir
$wizardConfigArgs = @(
    "-S", $wizardDir,
    "-B", $wizardBuildDir,
    "-G", "Visual Studio 17 2022",
    "-A", "x64",
    "-T", "host=x64"
)
if ($x64Compiler) {
    $wizardConfigArgs += "-DCMAKE_CXX_COMPILER=$x64Compiler"
}
Invoke-NativeProcess -FilePath "cmake" -Arguments $wizardConfigArgs
Invoke-NativeProcess -FilePath "cmake" -Arguments @("--build", $wizardBuildDir, "--config", $BuildConfig)

$wizardArtifactDir = Join-Path $wizardBuildDir $BuildConfig
foreach ($name in (Get-VirtuaCamSetupArtifacts)) {
    $src = Join-Path $wizardArtifactDir $name
    if (-not (Test-Path -LiteralPath $src)) {
        Fail "Missing setup artifact: $src"
    }
    Copy-Item -LiteralPath $src -Destination $OutputRoot -Force
    $pdb = [System.IO.Path]::ChangeExtension($src, ".pdb")
    if (Test-Path -LiteralPath $pdb) {
        Copy-Item -LiteralPath $pdb -Destination $OutputRoot -Force
    }
}
Write-Success "Software staged -> $OutputRoot"

Write-Step "Build DirectShow probe"
$dshowProbeBuildScript = Join-Path $scriptDir "build-dshow-probe.ps1"
if (-not (Test-Path -LiteralPath $dshowProbeBuildScript)) {
    Fail "DirectShow probe build script missing: $dshowProbeBuildScript"
}
& powershell.exe -ExecutionPolicy Bypass -File $dshowProbeBuildScript -Force
if ($LASTEXITCODE -ne 0) {
    Fail "DirectShow probe build failed with exit code $LASTEXITCODE."
}

Write-Step "Build driver"

$targets = "Clean;Build"
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

foreach ($artifact in @((Get-VirtuaCamCameraDriverArtifacts) + "avshws.pdb")) {
    $dst = Join-Path $OutputRoot $artifact
    if (Test-Path -LiteralPath $dst) {
        Remove-Item -LiteralPath $dst -Force
    }
}

foreach ($artifact in (Get-VirtuaCamCameraDriverArtifacts)) {
    Copy-Item -LiteralPath (Join-Path $driverPackageTmp $artifact) -Destination (Join-Path $OutputRoot $artifact) -Force
}
if (Test-Path -LiteralPath $driverPdb) {
    Copy-Item -LiteralPath $driverPdb -Destination (Join-Path $OutputRoot "avshws.pdb") -Force
}

Write-Success "Driver staged -> $OutputRoot"

Write-Step "Build virtual microphone driver"

$wdkVersion = Get-WdkIncludeVersion
if (-not $wdkVersion) {
    Fail "Unable to determine WDK include version."
}

foreach ($project in $audioDriverProjects) {
    Invoke-NativeProcess -FilePath $msbuild -Arguments @(
        $project,
        "/t:$targets",
        "/p:Configuration=$BuildConfig",
        "/p:Platform=x64",
        "/p:WindowsTargetPlatformVersion=$wdkVersion",
        "/nologo",
        "/v:m"
    )
}

$audioBuildDir = Join-Path $audioDriverRoot ("Source\Main\Main\x64\{0}" -f $BuildConfig)
$audioSys = Join-Path $audioBuildDir "virtuacam_mic.sys"
$audioPdb = Join-Path $audioBuildDir "virtuacam_mic.pdb"
$audioInf = Join-Path $audioDriverRoot "virtuacam-mic.inf"
if (-not (Test-Path -LiteralPath $audioSys)) { Fail "Fresh audio driver sys missing: $audioSys" }
if (-not (Test-Path -LiteralPath $audioInf)) { Fail "Audio driver INF missing: $audioInf" }

if (Test-Path -LiteralPath $audioDriverPackageTmp) {
    Get-ChildItem -LiteralPath $audioDriverPackageTmp -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
$null = New-Item -ItemType Directory -Force -Path $audioDriverPackageTmp

Copy-Item -LiteralPath $audioSys -Destination (Join-Path $audioDriverPackageTmp "virtuacam_mic.sys") -Force
Copy-Item -LiteralPath $audioInf -Destination (Join-Path $audioDriverPackageTmp "virtuacam-mic.inf") -Force

Invoke-NativeProcess -FilePath $inf2cat -Arguments @("/driver:$audioDriverPackageTmp", "/os:10_X64")

$audioCatPath = Join-Path $audioDriverPackageTmp "virtuacam-mic.cat"
if (-not (Test-Path -LiteralPath $audioCatPath)) {
    Fail "Audio catalog generation failed: $audioCatPath not found."
}

Invoke-NativeProcess -FilePath $signtool -Arguments @(
    "sign",
    "/v",
    "/fd", "SHA256",
    "/sha1", $cert.Thumbprint,
    "/s", "My",
    $audioCatPath
)

foreach ($artifact in (Get-VirtuaCamAudioDriverArtifacts)) {
    $dst = Join-Path $OutputRoot $artifact
    if (Test-Path -LiteralPath $dst) {
        Remove-Item -LiteralPath $dst -Force
    }
    Copy-Item -LiteralPath (Join-Path $audioDriverPackageTmp $artifact) -Destination $dst -Force
}
if (Test-Path -LiteralPath $audioPdb) {
    Copy-Item -LiteralPath $audioPdb -Destination (Join-Path $OutputRoot "virtuacam_mic.pdb") -Force
}

Write-Success "Virtual microphone driver staged -> $OutputRoot"

Write-Step "Validate required artifacts"
$requiredSoftware = @((Get-VirtuaCamSoftwareArtifacts) + (Get-VirtuaCamSetupArtifacts) + (Get-VirtuaCamRuntimeArtifacts))
$requiredDriver = Get-VirtuaCamDriverArtifacts

foreach ($name in $requiredSoftware) {
    Assert-FilePresentAndNotEmpty -Path (Join-Path $OutputRoot $name)
}
foreach ($name in $requiredDriver) {
    Assert-FilePresentAndNotEmpty -Path (Join-Path $OutputRoot $name)
}
Write-Success "Artifacts present in output"

Write-Step "Artifact inventory"
Get-ChildItem -LiteralPath $OutputRoot -File | Sort-Object Name | ForEach-Object {
    Write-Host ("  - {0} ({1:n0} bytes)" -f $_.Name, $_.Length)
}

if (Test-Path -LiteralPath $driverPackageTmp) {
    Remove-Item -LiteralPath $driverPackageTmp -Recurse -Force
}
if (Test-Path -LiteralPath $audioDriverPackageTmp) {
    Remove-Item -LiteralPath $audioDriverPackageTmp -Recurse -Force
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " BUILD-ALL SUCCEEDED"
Write-Host "============================================================" -ForegroundColor Green
