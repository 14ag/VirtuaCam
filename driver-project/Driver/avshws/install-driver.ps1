[CmdletBinding()]
param(
    [string]$PackageRoot = "",
    [string]$InfPath = "",
    [string]$HardwareId = "AVSHWS",
    [string]$DeviceDescription = "Virtual Camera Driver",
    [switch]$SkipCertificateImport,
    [string]$CertificatePath = "",
    [switch]$ForceDriverRebind,
    [string]$LogPath = ""
)

# $PSScriptRoot is empty when the script is invoked without a fully qualified path.
# $MyInvocation.MyCommand.Definition is always populated.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$defaultPackageRoot = Join-Path $scriptDir "..\\..\\..\\output"
if (-not $PackageRoot) { $PackageRoot = $defaultPackageRoot }
if (-not $InfPath) { $InfPath = Join-Path $PackageRoot "avshws.inf" }
if (-not $CertificatePath) { $CertificatePath = Join-Path $PackageRoot "VirtualCameraDriver-TestSign.cer" }

$defaultLogPath = Join-Path $scriptDir "..\\..\\..\\output\\logs\\driver-install.log"
if (-not $LogPath) { $LogPath = $defaultLogPath }

# Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff zzz"
    $line = "[{0}] {1}" -f $ts, $Message
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $line
}

function Exit-WithCode {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-Log "ERROR: $Message"
    exit $Code
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Exit-WithCode -Code 2 -Message "Run this script in an elevated PowerShell window (Run as Administrator)."
    }
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    $all = @($Arguments)
    Write-Log ("> {0} {1}" -f $FilePath, ($all -join ' '))

    $output = & $FilePath @all 2>&1
    if ($null -ne $output) {
        $output | ForEach-Object { Write-Log $_ }
    }

    if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
        Exit-WithCode -Code 5 -Message ("{0} failed with exit code {1}." -f $FilePath, $LASTEXITCODE)
    }
}

function Import-TestCertificateIfPresent {
    param([string]$Path)

    if ($SkipCertificateImport) {
        Write-Log "Skipping test certificate import."
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Test certificate not found ($Path). Continuing without cert import (TESTSIGNING mode expected)."
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
    param([string]$Id)

    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.PNPDeviceID -like ("ROOT\{0}\*" -f $Id) }
}

function Remove-ExistingDriverPackageIfRequested {
    param([string]$Id)

    if (-not $ForceDriverRebind) {
        return
    }

    $signedDrivers = Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceID -like ("ROOT\{0}\*" -f $Id) -and $_.InfName }

    $infNames = @($signedDrivers | Select-Object -ExpandProperty InfName -Unique)
    if ($infNames.Count -eq 0) {
        Write-Log "ForceDriverRebind: no existing OEM INF bound to ROOT\\$Id."
        return
    }

    foreach ($inf in $infNames) {
        if ($inf -match '^oem\d+\.inf$') {
            Write-Log "ForceDriverRebind: removing existing package $inf"
            Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/delete-driver", $inf, "/uninstall", "/force") -AllowedExitCodes @(0,259,3010)
        } else {
            Write-Log "ForceDriverRebind: skipping non-OEM INF '$inf'"
        }
    }
}

function Assert-Prereqs {
    $logDir = Split-Path -Parent $LogPath
    $null = New-Item -ItemType Directory -Force -Path $logDir

    Write-Log "============================================================"
    Write-Log " Driver Install"
    Write-Log " PackageRoot: $PackageRoot"
    Write-Log " LogPath:     $LogPath"
    Write-Log "============================================================"

    Assert-Administrator

    $pnputil = Join-Path $env:WINDIR "System32\\pnputil.exe"
    $certutil = Join-Path $env:WINDIR "System32\\certutil.exe"
    $bcdedit = Join-Path $env:WINDIR "System32\\bcdedit.exe"

    foreach ($t in @($pnputil, $certutil, $bcdedit)) {
        if (-not (Test-Path -LiteralPath $t)) {
            Exit-WithCode -Code 3 -Message "Required tool missing: $t"
        }
    }

    if (-not (Test-Path -LiteralPath $PackageRoot)) {
        Exit-WithCode -Code 3 -Message "PackageRoot not found: $PackageRoot"
    }

    foreach ($f in @($InfPath, (Join-Path $PackageRoot "avshws.sys"))) {
        if (-not (Test-Path -LiteralPath $f)) {
            Exit-WithCode -Code 3 -Message "Required package file missing: $f"
        }
    }

    if (-not $SkipCertificateImport) {
        if (-not (Test-Path -LiteralPath $CertificatePath)) {
            Write-Log "Certificate missing ($CertificatePath). Continuing without cert import."
        }
    }

    $bcdOut = & $bcdedit /enum "{current}" 2>&1
    $testLine = $bcdOut | Where-Object { $_ -match '^\s*testsigning\s+' } | Select-Object -First 1
    
    $isTestSigningOn = $false
    if ($testLine) {
        $isTestSigningOn = $testLine -match '(?i)\bYes\b'
    }

    if (-not $isTestSigningOn) {
        Exit-WithCode -Code 4 -Message "TESTSIGNING is OFF. Enable then reboot: bcdedit /set testsigning on"
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
        [MarshalAs(UnmanagedType.Bool)] out bool bRebootRequired
    );

    public static void CreateRootDevice(string hardwareId, string className, string deviceDescription, Guid classGuid) {
        IntPtr infoSet = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (infoSet == INVALID_HANDLE_VALUE) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed.");
        }

        try {
            SP_DEVINFO_DATA infoData = new SP_DEVINFO_DATA();
            infoData.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

            if (!SetupDiCreateDeviceInfo(
                infoSet,
                className,
                ref classGuid,
                deviceDescription,
                IntPtr.Zero,
                DICD_GENERATE_ID,
                ref infoData))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfo failed.");
            }

            byte[] hardwareIdMultiSz = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(
                infoSet,
                ref infoData,
                SPDRP_HARDWAREID,
                hardwareIdMultiSz,
                hardwareIdMultiSz.Length))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiSetDeviceRegistryProperty(SPDRP_HARDWAREID) failed.");
            }

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, infoSet, ref infoData)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCallClassInstaller(DIF_REGISTERDEVICE) failed.");
            }
        }
        finally {
            SetupDiDestroyDeviceInfoList(infoSet);
        }
    }

    // FIX 3: When UpdateDriverForPlugAndPlayDevices fails with ERROR_NO_SUCH_DEVINST,
    // zero out lastError so the caller's (-not $bindOutcome -and $lastError -ne 0) check
    // does not incorrectly treat it as a fatal error.
    public static bool TryBindDriver(string hardwareId, string infPath, bool forceRebind, out bool rebootRequired, out int lastError) {
        uint flags = forceRebind ? INSTALLFLAG_FORCE : 0;
        bool ok = UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hardwareId, infPath, flags, out rebootRequired);
        if (ok) {
            lastError = 0;
            return true;
        }

        lastError = Marshal.GetLastWin32Error();
        if (lastError == ERROR_NO_SUCH_DEVINST) {
            lastError = 0;  // non-fatal: device node not yet visible to PnP
            return false;
        }
        return false;
    }
}
"@
} # end if type not loaded

try {
    Assert-Prereqs
}
catch {
    Exit-WithCode -Code 1 -Message $_.Exception.Message
}

# FIX 2: Guard with Test-Path before Resolve-Path.
# With $ErrorActionPreference = "Stop", Resolve-Path throws on a missing path,
# making any Test-Path check placed after it unreachable.
if (-not (Test-Path -LiteralPath $InfPath)) {
    Exit-WithCode -Code 3 -Message "INF not found: $InfPath"
}
$resolvedInf = (Resolve-Path -LiteralPath $InfPath).Path

Import-TestCertificateIfPresent -Path $CertificatePath

Remove-ExistingDriverPackageIfRequested -Id $HardwareId

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/add-driver", $resolvedInf, "/install") -AllowedExitCodes @(0,259,3010)

$existingDevices = @(Get-AvshwsDevices -Id $HardwareId)
if ($existingDevices.Count -eq 0) {
    Write-Log "No ROOT\\$HardwareId device present. Creating it now..."
    $cameraClassGuid = [Guid]::Parse("{ca3e7ab9-b4c3-4ae6-8251-579ef933890f}")
    [AvshwsInstallerNative]::CreateRootDevice($HardwareId, $HardwareId, $DeviceDescription, $cameraClassGuid)
}
else {
    Write-Log "ROOT\\$HardwareId already exists. Reusing existing device node."
}

# FIX 1: Declare $lastError before use so [ref]$lastError is a valid reference.
# The original [ref]([int]$lastError = 0) inline form does not correctly wire the reference.
$rebootRequired = $false
[int]$lastError = 0
$bindOutcome = $false
$bindOutcome = [AvshwsInstallerNative]::TryBindDriver($HardwareId, $resolvedInf, $ForceDriverRebind.IsPresent, [ref]$rebootRequired, [ref]$lastError)
if (-not $bindOutcome -and $lastError -ne 0) {
    $hexError = ("0x{0:X8}" -f ([uint32]$lastError))
    Exit-WithCode -Code 5 -Message "UpdateDriverForPlugAndPlayDevices failed with $hexError."
}

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/scan-devices")

$cameraEnum = & "$env:WINDIR\System32\pnputil.exe" /enum-devices /class Camera 2>&1
Write-Log "--- pnputil /enum-devices /class Camera ---"
if ($null -ne $cameraEnum) { $cameraEnum | ForEach-Object { Write-Log $_ } }

$finalDevices = @(Get-AvshwsDevices -Id $HardwareId)
if ($finalDevices.Count -eq 0) {
    Exit-WithCode -Code 5 -Message "Install finished but no ROOT\\$HardwareId device was found."
}

Write-Log ""
Write-Log "Driver install complete."
$finalDevices | ForEach-Object {
    Write-Log ("InstanceId: {0}" -f $_.PNPDeviceID)
    Write-Log ("Name:       {0}" -f $_.Name)
    Write-Log ("Status:     {0}" -f $_.Status)
    Write-Log ""
}

$bad = @($finalDevices | Where-Object { $_.Status -and $_.Status -ne "OK" })
if ($bad.Count -gt 0) {
    Exit-WithCode -Code 5 -Message "Installed device present but not OK status."
}

if ($rebootRequired) {
    Write-Log "A reboot is required to finalize installation."
}
exit 0
