# build.ps1 (Version 10 - Incremental Builds & Registration)
# Supports incremental builds by default. Use -Clean for a full rebuild.
# Supports COM registration via -Register and -Unregister flags.

# --- PARAMETERS ---
param(
    [string]$VcpkgRoot = "",
    [string]$OutputRoot = "",
    [string]$BuildConfig = "Release",
    [switch]$Clean,
    [switch]$Register,
    [switch]$Unregister
)

# --- SCRIPT START ---
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Helper Functions ---
function Write-Step { param([string]$Message) Write-Host "`n" -NoNewline; Write-Host "--- [STEP] $Message ---" -ForegroundColor Yellow }
function Write-Success { param([string]$Message) Write-Host "  - SUCCESS:" -ForegroundColor Green -NoNewline; Write-Host " $Message" }
function Write-Info { param([string]$Message) Write-Host "  - INFO:" -ForegroundColor Cyan -NoNewline; Write-Host " $Message" }
function Exit-WithError {
    param([string]$Message)
    Write-Host "`n"; Write-Host "==================== FATAL BUILD ERROR ====================" -ForegroundColor Red
    Write-Host "  $Message" -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
    exit 1
}
function Execute-Process {
    param([string]$File, [array]$Arguments)
    Write-Host "  - Executing: $File $($Arguments -join ' ')"
    & $File $Arguments
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "An external process ($File) failed with exit code $LASTEXITCODE."
    }
}
function Get-X64CompilerPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        return $null
    }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) {
        return $null
    }

    $msvcRoot = Join-Path $installationPath "VC\Tools\MSVC"
    if (-not (Test-Path $msvcRoot)) {
        return $null
    }

    $toolsetDir = Get-ChildItem -Path $msvcRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $toolsetDir) {
        return $null
    }

    $compilerPath = Join-Path $toolsetDir.FullName "bin\Hostx64\x64\cl.exe"
    if (Test-Path $compilerPath) {
        return $compilerPath
    }

    return $null
}

# --- Main Script Body ---
Write-Host "============================================================" -ForegroundColor Green
Write-Host " DirectPort Build Script (v10 - Incremental)"
Write-Host "============================================================"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$BuildDir = Join-Path $scriptDir "build"
$SourceDir = Join-Path $scriptDir "src"

function Get-OutputBinDir {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return (Join-Path $scriptDir "..\\output\\software\\bin")
    }

    $looksLikeBinDir = $Root -match '(?i)(^|[\\/])(software[\\/]+bin|bin)$'
    if ($looksLikeBinDir) {
        return $Root
    }

    return (Join-Path $Root "software\\bin")
}

$OutputBinDir = Get-OutputBinDir -Root $OutputRoot

# --- PRE-FLIGHT CHECKS ---
Write-Step "Performing Pre-flight Sanity Checks"
if (-not (Test-Path (Join-Path $SourceDir "CMakeLists.txt"))) { Exit-WithError "'CMakeLists.txt' not found in '$SourceDir'." }
Write-Success "Found 'src/CMakeLists.txt'."
if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
    if ($env:VCPKG_ROOT -and (Test-Path $env:VCPKG_ROOT)) {
        $VcpkgRoot = $env:VCPKG_ROOT
    } elseif (Test-Path "C:\vcpkg") {
        $VcpkgRoot = "C:\vcpkg"
    } else {
        $VcpkgRoot = Join-Path $PSScriptRoot "vcpkg"
    }
}

if (-not (Test-Path $VcpkgRoot)) {
    Write-Host "  - vcpkg directory not found at '$VcpkgRoot'. Automatically cloning..." -ForegroundColor Yellow
    Execute-Process "git" @("clone", "https://github.com/microsoft/vcpkg.git", $VcpkgRoot)
    
    Write-Host "  - Bootstrapping vcpkg..." -ForegroundColor Yellow
    $bootstrap = Join-Path $VcpkgRoot "bootstrap-vcpkg.bat"
    Execute-Process "cmd.exe" @("/c", $bootstrap, "-disableMetrics")
    
    Write-Success "vcpkg auto-installed successfully."
} else {
    Write-Success "Found vcpkg directory at '$VcpkgRoot'."
}

$ToolchainFile = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"
if (-not (Test-Path $ToolchainFile)) { Exit-WithError "vcpkg toolchain file not found at '$ToolchainFile'." }
Write-Success "Found vcpkg toolchain file."

# --- Kill any running instances of VirtuaCam.exe ---
Write-Step "Checking for running VirtuaCam instances"
Get-Process -Name "VirtuaCam" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
Write-Success "Terminated any running VirtuaCam instances."

# --- 1. Clean and Prepare Build Directory (if -Clean is specified) ---
if ($Clean) {
    Write-Step "Cleaning Build Directory (-Clean specified)"
    if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
    Write-Success "Created fresh build directory."
} else {
    Write-Step "Incremental Build Mode (use -Clean for a full rebuild)"
    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
        Write-Success "Created new build directory."
    } else {
        Write-Success "Build directory already exists."
    }
}

# --- 2. Run CMake to Configure the Project (only if necessary) ---
# CMake is smart enough not to reconfigure if nothing has changed.
Write-Step "Configuring Project with CMake (if necessary)"
$cmake_config_args = @("-S", $SourceDir, "-B", $BuildDir, "-G", "Visual Studio 17 2022", "-A", "x64", "-T", "host=x64", "-DVCPKG_TARGET_TRIPLET=x64-windows", "-DCMAKE_TOOLCHAIN_FILE=$ToolchainFile")

$x64Compiler = Get-X64CompilerPath
if ($x64Compiler) {
    Write-Info "Forcing MSVC x64 compiler: $x64Compiler"
    $cmake_config_args += "-DCMAKE_CXX_COMPILER=$x64Compiler"
} else {
    Write-Host "  - WARNING: Could not locate MSVC x64 compiler with vswhere. Falling back to CMake auto-detection." -ForegroundColor Yellow
}

Execute-Process "cmake" $cmake_config_args
Write-Success "CMake configuration is up-to-date."

# --- 3. Run CMake to Build the Project ---
Write-Step "Building All Targets ($BuildConfig)"
Write-Host "  - INFO: Starting build. This will be fast if no files have changed." -ForegroundColor Cyan
$cmake_build_args = @("--build", $BuildDir, "--config", $BuildConfig)
Execute-Process "cmake" $cmake_build_args
Write-Success "Project build completed."

# --- 4. Register or Unregister the Virtual Camera DLL (Optional) ---
if ($Unregister) {
    Write-Step "Unregistering Virtual Camera DLL"
    $unregister_args = @("--build", $BuildDir, "--config", $BuildConfig, "--target", "unregister_vcam")
    Execute-Process "cmake" $unregister_args
    Write-Success "Unregistration command sent."
}
if ($Register) {
    Write-Step "Registering Virtual Camera DLL (requires Admin privileges)"
    $register_args = @("--build", $BuildDir, "--config", $BuildConfig, "--target", "register_vcam")
    Execute-Process "cmake" $register_args
    Write-Success "Registration command sent."
}

# --- 5. Stage Artifacts to Output Directory ---
Write-Step "Staging Build Artifacts to Output Directory"
$ArtifactSourceDir = Join-Path $BuildDir $BuildConfig
if (-not (Test-Path $ArtifactSourceDir)) { Exit-WithError "Build artifact directory not found at '$ArtifactSourceDir'." }

$null = New-Item -ItemType Directory -Force -Path $OutputBinDir
Write-Info "Output: $OutputBinDir"

$allowed = @(
    "VirtuaCam.exe",
    "VirtuaCamProcess.exe",
    "DirectPortBroker.dll",
    "DirectPortClient.dll",
    "DirectPortConsumer.dll"
)

# Clean out legacy producer DLLs if they were staged by older builds.
foreach ($legacy in @("DirectPortMFCamera.dll", "DirectPortMFGraphicsCapture.dll")) {
    $legacyPath = Join-Path $OutputBinDir $legacy
    if (Test-Path -LiteralPath $legacyPath) {
        Remove-Item -Force -LiteralPath $legacyPath
        Write-Info "Removed legacy staged DLL: $legacy"
    }
}

$copiedFiles = 0
foreach ($name in $allowed) {
    $src = Join-Path $ArtifactSourceDir $name
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $OutputBinDir -Force
        Write-Success "Staged: $name"
        $copiedFiles++

        $pdb = [System.IO.Path]::ChangeExtension($src, ".pdb")
        if (Test-Path -LiteralPath $pdb) {
            Copy-Item -LiteralPath $pdb -Destination $OutputBinDir -Force
            Write-Success "Staged: $([System.IO.Path]::GetFileName($pdb))"
        }
    } else {
        Write-Host "  - WARNING: Missing build artifact (not staged): $name" -ForegroundColor Yellow
    }
}

if ($copiedFiles -eq 0) {
    Write-Host "  - WARNING: No executables, modules, or DLLs were found in the build output." -ForegroundColor Yellow
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " BUILD SUCCEEDED"
Write-Host "============================================================"
