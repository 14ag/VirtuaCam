[CmdletBinding()]
param(
    [string]$OutputRoot = "",
    [string]$BuildConfig = "Release",
    [switch]$SkipDriverInstall,
    [switch]$SkipDllRegister,
    [switch]$Uninstall
)

# Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "`n" -NoNewline; Write-Host "--- [STEP] $Message ---" -ForegroundColor Yellow }
function Write-Success { param([string]$Message) Write-Host "  - SUCCESS:" -ForegroundColor Green -NoNewline; Write-Host " $Message" }
function Write-Info { param([string]$Message) Write-Host "  - INFO:" -ForegroundColor Cyan -NoNewline; Write-Host " $Message" }
function Fail { param([string]$Message) Write-Host $Message -ForegroundColor Red; exit 1 }

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $scriptDir "output" }

$logsDir = Join-Path $OutputRoot "logs"
$null = New-Item -ItemType Directory -Force -Path $logsDir

Write-Host "============================================================" -ForegroundColor Green
Write-Host " Install All"
Write-Host "============================================================" -ForegroundColor Green
Write-Info "OutputRoot: $OutputRoot"

$runKeyPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$virtuaCamRegPath = "HKLM:\SOFTWARE\VirtuaCam"
$installDir = $OutputRoot
$processExe = Join-Path $installDir "VirtuaCamProcess.exe"
$virtuaCamExe = Join-Path $installDir "VirtuaCam.exe"

if ($Uninstall) {
    Write-Step "Uninstall startup and VirtuaCam registry entries"
    Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCam" -ErrorAction SilentlyContinue
    Remove-Item -Path $virtuaCamRegPath -Recurse -ErrorAction SilentlyContinue
    Write-Success "Uninstall cleanup complete"
    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host " INSTALL-ALL UNINSTALL COMPLETED"
    Write-Host "============================================================" -ForegroundColor Green
    exit 0
}

Write-Step "Verify artifacts"
foreach ($p in @(
    (Join-Path $OutputRoot "VirtuaCam.exe"),
    (Join-Path $OutputRoot "avshws.inf"),
    (Join-Path $OutputRoot "avshws.sys"),
    (Join-Path $OutputRoot "avshws.cat")
)) {
    if (-not (Test-Path -LiteralPath $p)) { Fail "Missing artifact: $p (run build-all.ps1 first)" }
}
Write-Success "Artifacts present"

if (-not $SkipDriverInstall) {
    Write-Step "Install driver"
    $drvInstall = Join-Path $scriptDir "driver-project\\Driver\\avshws\\install-driver.ps1"
    if (-not (Test-Path -LiteralPath $drvInstall)) { Fail "Missing: $drvInstall" }
    $logPath = Join-Path $logsDir "driver-install.log"
    & $drvInstall -PackageRoot $OutputRoot -LogPath $logPath
    if ($LASTEXITCODE -ne 0) { Fail "Driver install failed (exit $LASTEXITCODE). See: $logPath" }
    Write-Success "Driver install OK (log: $logPath)"
} else {
    Write-Info "Skip driver install"
}

if (-not $SkipDllRegister) {
    Write-Step "Register software components (optional)"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail "Run install-all.ps1 in elevated PowerShell for DLL registration (Run as Administrator)."
    }

    $regsvr32 = Join-Path $env:WINDIR "System32\\regsvr32.exe"
    $clientDll = Join-Path $OutputRoot "DirectPortClient.dll"
    if (-not (Test-Path -LiteralPath $regsvr32)) { Fail "Missing regsvr32: $regsvr32" }
    if (-not (Test-Path -LiteralPath $clientDll)) { Fail "Missing staged DLL for registration: $clientDll" }

    & $regsvr32 /s $clientDll
    if ($LASTEXITCODE -ne 0) { Fail "regsvr32 failed (exit $LASTEXITCODE) for: $clientDll" }
    Write-Success "Registered: $clientDll"
} else {
    Write-Info "Skip DLL register"
}

Write-Step "Configure VirtuaCam registry and startup"
New-Item -Path $virtuaCamRegPath -Force | Out-Null
Set-ItemProperty -Path $virtuaCamRegPath -Name "InstallDir" -Value $installDir
Set-ItemProperty -Path $virtuaCamRegPath -Name "VirtuaCamExe" -Value $virtuaCamExe
Set-ItemProperty -Path $virtuaCamRegPath -Name "ProcessExe" -Value $processExe

Set-ItemProperty -Path $runKeyPath -Name "VirtuaCamProcess" -Value "`"$processExe`""
Set-ItemProperty -Path $runKeyPath -Name "VirtuaCam" -Value "`"$virtuaCamExe`" /startup"
Write-Success "Configured HKLM\\SOFTWARE\\VirtuaCam and HKCU Run keys"

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " INSTALL-ALL SUCCEEDED"
Write-Host "============================================================" -ForegroundColor Green
