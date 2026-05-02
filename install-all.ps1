[CmdletBinding()]
param(
    [string]$OutputRoot = "",
    [switch]$SkipDriverInstall,
    [switch]$SkipDllRegister,
    [switch]$ForceDriverRebind,
    [switch]$SkipCertificateImport,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-InstallLog {
    param([string]$Message)

    if (-not $script:logPath) {
        return
    }

    $logDir = Split-Path -Parent $script:logPath
    if ($logDir) {
        $null = New-Item -ItemType Directory -Force -Path $logDir
    }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff zzz"
    Add-Content -LiteralPath $script:logPath -Value ("[{0}] {1}" -f $ts, $Message)
}

function Write-Step { param([string]$Message) Write-Host "`n" -NoNewline; Write-Host "--- [STEP] $Message ---" -ForegroundColor Yellow; Write-InstallLog "--- [STEP] $Message ---" }
function Write-Success { param([string]$Message) Write-Host "  - SUCCESS:" -ForegroundColor Green -NoNewline; Write-Host " $Message"; Write-InstallLog "SUCCESS: $Message" }
function Write-Info { param([string]$Message) Write-Host "  - INFO:" -ForegroundColor Cyan -NoNewline; Write-Host " $Message"; Write-InstallLog "INFO: $Message" }
function Fail {
    param([string]$Message)
    Write-Host "`n==================== FATAL INSTALL ERROR ====================" -ForegroundColor Red
    Write-Host "  $Message" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-InstallLog "FATAL: $Message"
    exit 1
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    $commandLine = "> $FilePath $($Arguments -join ' ')"
    Write-Host $commandLine
    Write-InstallLog $commandLine
    $output = & $FilePath @Arguments 2>&1
    if ($null -ne $output) {
        $output | ForEach-Object {
            Write-Host $_
            Write-InstallLog "$_"
        }
    }

    if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
        Fail "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail "Run this script in an elevated PowerShell window (Run as Administrator)."
    }
}

function Import-TestCertificateIfPresent {
    param([string]$Path)

    if ($SkipCertificateImport) {
        Write-Info "Skip test certificate import"
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "Certificate missing ($Path). Continuing without import."
        return
    }

    $tempCert = Join-Path $env:TEMP ("avshws-cert-{0}.cer" -f [Guid]::NewGuid().ToString("N"))
    Copy-Item -LiteralPath $Path -Destination $tempCert -Force
    try {
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\certutil.exe" -Arguments @("-f", "-addstore", "Root", $tempCert)
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\certutil.exe" -Arguments @("-f", "-addstore", "TrustedPublisher", $tempCert)
    }
    finally {
        Remove-Item -LiteralPath $tempCert -ErrorAction SilentlyContinue
    }
}

function Get-AvshwsDevices {
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.PNPDeviceID -like "ROOT\AVSHWS\*" }
}

function Remove-ExistingDriverPackageIfRequested {
    if (-not $ForceDriverRebind) {
        return
    }

    $signedDrivers = Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceID -like "ROOT\AVSHWS\*" -and $_.InfName }

    $infNames = @($signedDrivers | Select-Object -ExpandProperty InfName -Unique)
    if ($infNames.Count -eq 0) {
        Write-Info "No bound OEM INF found for ROOT\AVSHWS"
        return
    }

    foreach ($inf in $infNames) {
        if ($inf -match '^oem\d+\.inf$') {
            Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/delete-driver", $inf, "/uninstall", "/force") -AllowedExitCodes @(0, 259, 3010)
        }
    }
}

if (-not ([System.Management.Automation.PSTypeName]'AvshwsInstallerNative').Type) {
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class AvshwsInstallerNative {
    private const int DICD_GENERATE_ID = 0x00000001;
    private const int SPDRP_HARDWAREID = 0x00000001;
    private const int DIF_REGISTERDEVICE = 0x00000019;
    private const uint INSTALLFLAG_FORCE = 0x00000001;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);
    private const int ERROR_NO_SUCH_DEVINST = unchecked((int)0xE000020B);

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA {
        public int cbSize;
        public Guid ClassGuid;
        public int DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiCreateDeviceInfo(
        IntPtr DeviceInfoSet,
        string DeviceName,
        ref Guid ClassGuid,
        string DeviceDescription,
        IntPtr hwndParent,
        int CreationFlags,
        ref SP_DEVINFO_DATA DeviceInfoData
    );

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryProperty(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData,
        int Property,
        byte[] PropertyBuffer,
        int PropertyBufferSize
    );

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiCallClassInstaller(
        int InstallFunction,
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData
    );

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateDriverForPlugAndPlayDevices(
        IntPtr hwndParent,
        string HardwareId,
        string FullInfPath,
        uint InstallFlags,
        [MarshalAs(UnmanagedType.Bool)] out bool rebootRequired
    );

    public static void CreateRootDevice(string hardwareId, string className, string deviceDescription, Guid classGuid) {
        IntPtr infoSet = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (infoSet == INVALID_HANDLE_VALUE) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed.");
        }

        try {
            SP_DEVINFO_DATA infoData = new SP_DEVINFO_DATA();
            infoData.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

            if (!SetupDiCreateDeviceInfo(infoSet, className, ref classGuid, deviceDescription, IntPtr.Zero, DICD_GENERATE_ID, ref infoData)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfo failed.");
            }

            byte[] hardwareIdMultiSz = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(infoSet, ref infoData, SPDRP_HARDWAREID, hardwareIdMultiSz, hardwareIdMultiSz.Length)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiSetDeviceRegistryProperty failed.");
            }

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, infoSet, ref infoData)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCallClassInstaller failed.");
            }
        }
        finally {
            SetupDiDestroyDeviceInfoList(infoSet);
        }
    }

    public static bool TryBindDriver(string hardwareId, string infPath, bool forceRebind, out bool rebootRequired, out int lastError) {
        uint flags = forceRebind ? INSTALLFLAG_FORCE : 0;
        bool ok = UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hardwareId, infPath, flags, out rebootRequired);
        if (ok) {
            lastError = 0;
            return true;
        }

        lastError = Marshal.GetLastWin32Error();
        if (lastError == ERROR_NO_SUCH_DEVINST) {
            lastError = 0;
            return false;
        }
        return false;
    }
}
"@
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath($scriptDir)
. (Join-Path $repoRoot "tools\artifact-manifest.ps1")
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $repoRoot "output" }
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$runKeyPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$virtuaCamRegPath = "HKLM:\SOFTWARE\VirtuaCam"
$logsDir = Join-Path $OutputRoot "logs"
$logPath = Join-Path $logsDir "driver-install.log"

$installDir = $OutputRoot
$expectedArtifacts = Get-VirtuaCamInstallArtifacts

$virtuaCamExe = Join-Path $installDir "VirtuaCam.exe"
$processExe = Join-Path $installDir "VirtuaCamProcess.exe"
$driverInf = Join-Path $OutputRoot "avshws.inf"
$driverSys = Join-Path $OutputRoot "avshws.sys"
$driverCat = Join-Path $OutputRoot "avshws.cat"
$driverCer = Join-Path $OutputRoot "VirtualCameraDriver-TestSign.cer"
$clientDll = Join-Path $OutputRoot "DirectPortClient.dll"

Write-Host "============================================================" -ForegroundColor Green
Write-Host " Install All"
Write-Host "============================================================" -ForegroundColor Green
Write-Info "OutputRoot: $OutputRoot"

if ($Uninstall) {
    Write-Step "Uninstall startup and VirtuaCam registry entries"
    Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCam" -ErrorAction SilentlyContinue
    Remove-Item -Path $virtuaCamRegPath -Recurse -ErrorAction SilentlyContinue
    Write-Success "Uninstall cleanup complete"
    exit 0
}

Write-Step "Verify artifacts in output"
foreach ($name in $expectedArtifacts) {
    $path = Join-Path $OutputRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "Missing staged artifact in output: $path"
    }
}
Write-Success ("Artifacts present ({0})" -f ($expectedArtifacts -join ", "))

Assert-Administrator
$null = New-Item -ItemType Directory -Force -Path $logsDir

if (-not $SkipDriverInstall) {
    Write-Step "Install driver from output"

    $bcdOut = & "$env:WINDIR\System32\bcdedit.exe" /enum "{current}" 2>&1
    $testLine = $bcdOut | Where-Object { $_ -match '^\s*testsigning\s+' } | Select-Object -First 1
    $isTestSigningOn = $false
    if ($testLine) {
        $isTestSigningOn = $testLine -match '(?i)\bYes\b'
    }
    if (-not $isTestSigningOn) {
        Fail "TESTSIGNING is OFF. Enable then reboot: bcdedit /set testsigning on"
    }

    Import-TestCertificateIfPresent -Path $driverCer
    Remove-ExistingDriverPackageIfRequested

    Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/add-driver", $driverInf, "/install") -AllowedExitCodes @(0, 259)

    $existingDevices = @(Get-AvshwsDevices)
    if ($existingDevices.Count -eq 0) {
        $cameraClassGuid = [Guid]::Parse("{ca3e7ab9-b4c3-4ae6-8251-579ef933890f}")
        [AvshwsInstallerNative]::CreateRootDevice("AVSHWS", "AVSHWS", "Virtual Camera Driver", $cameraClassGuid)
    }

    $rebootRequired = $false
    [int]$lastError = 0
    $bindOutcome = [AvshwsInstallerNative]::TryBindDriver("AVSHWS", $driverInf, $ForceDriverRebind.IsPresent, [ref]$rebootRequired, [ref]$lastError)
    if (-not $bindOutcome -and $lastError -ne 0) {
        $hexError = ("0x{0:X8}" -f ([uint32]$lastError))
        Fail "UpdateDriverForPlugAndPlayDevices failed with $hexError."
    }

    Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/scan-devices")

    $finalDevices = @(Get-AvshwsDevices)
    if ($finalDevices.Count -eq 0) {
        Fail "Install finished but no ROOT\AVSHWS device was found."
    }

    $bad = @($finalDevices | Where-Object { $_.Status -and $_.Status -ne "OK" })
    if ($bad.Count -gt 0) {
        Fail "Installed device present but not OK status."
    }

    if ($rebootRequired) {
        Write-Info "Reboot required to finalize driver bind"
    }

    Write-Success "Driver install OK from $OutputRoot"
} else {
    Write-Info "Skip driver install"
}

if (-not $SkipDllRegister) {
    Write-Step "Register software components from output"
    Invoke-NativeProcess -FilePath "$env:WINDIR\System32\regsvr32.exe" -Arguments @("/s", $clientDll)
    Write-Success "Registered: $clientDll"
} else {
    Write-Info "Skip DLL register"
}

Write-Step "Configure registry and startup from output"
New-Item -Path $virtuaCamRegPath -Force | Out-Null
Set-ItemProperty -Path $virtuaCamRegPath -Name "InstallDir" -Value $installDir
Set-ItemProperty -Path $virtuaCamRegPath -Name "VirtuaCamExe" -Value $virtuaCamExe
Set-ItemProperty -Path $virtuaCamRegPath -Name "ProcessExe" -Value $processExe
Set-ItemProperty -Path $runKeyPath -Name "VirtuaCamProcess" -Value "`"$processExe`""
Set-ItemProperty -Path $runKeyPath -Name "VirtuaCam" -Value "`"$virtuaCamExe`" /startup"
Write-Success "Configured HKLM\SOFTWARE\VirtuaCam and HKCU Run keys"

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " INSTALL-ALL SUCCEEDED"
Write-Host "============================================================" -ForegroundColor Green
