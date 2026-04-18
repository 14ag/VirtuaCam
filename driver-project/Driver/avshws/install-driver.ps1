[CmdletBinding()]
param(
    [string]$InfPath = "",
    [string]$HardwareId = "AVSHWS",
    [string]$DeviceDescription = "Virtual Camera Driver",
    [switch]$SkipCertificateImport,
    [string]$CertificatePath = "",
    [switch]$ForceDriverRebind
)

# $PSScriptRoot is empty when the script is invoked without a fully qualified path.
# $MyInvocation.MyCommand.Definition is always populated.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $InfPath)         { $InfPath         = Join-Path $scriptDir "avshws.inf" }
if (-not $CertificatePath) { $CertificatePath = Join-Path $scriptDir "VirtualCameraDriver-TestSign.cer" }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script in an elevated PowerShell window (Run as Administrator)."
    }
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $all = @($Arguments)
    Write-Host "> $FilePath $($all -join ' ')"

    $output = & $FilePath @all 2>&1
    if ($null -ne $output) {
        $output | ForEach-Object { Write-Host $_ }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Import-TestCertificateIfPresent {
    param([string]$Path)

    if ($SkipCertificateImport) {
        Write-Host "Skipping test certificate import."
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "No test certificate found at '$Path'. Skipping certificate import."
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

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryProperty(
        IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData,
        int Property,
        byte[] PropertyBuffer,
        int PropertyBufferSize
    );

    [DllImport("setupapi.dll", SetLastError = true)]
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

Assert-Administrator

# FIX 2: Guard with Test-Path before Resolve-Path.
# With $ErrorActionPreference = "Stop", Resolve-Path throws on a missing path,
# making any Test-Path check placed after it unreachable.
if (-not (Test-Path -LiteralPath $InfPath)) {
    throw "INF not found: $InfPath"
}
$resolvedInf = (Resolve-Path -LiteralPath $InfPath).Path

Import-TestCertificateIfPresent -Path $CertificatePath

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/add-driver", $resolvedInf, "/install")

$existingDevices = @(Get-AvshwsDevices -Id $HardwareId)
if ($existingDevices.Count -eq 0) {
    Write-Host "No ROOT\\$HardwareId device present. Creating it now..."
    $cameraClassGuid = [Guid]::Parse("{ca3e7ab9-b4c3-4ae6-8251-579ef933890f}")
    [AvshwsInstallerNative]::CreateRootDevice($HardwareId, "Camera", $DeviceDescription, $cameraClassGuid)
}
else {
    Write-Host "ROOT\\$HardwareId already exists. Reusing existing device node."
}

# FIX 1: Declare $lastError before use so [ref]$lastError is a valid reference.
# The original [ref]([int]$lastError = 0) inline form does not correctly wire the reference.
$rebootRequired = $false
[int]$lastError = 0
$bindOutcome = [AvshwsInstallerNative]::TryBindDriver($HardwareId, $resolvedInf, $ForceDriverRebind.IsPresent, [ref]$rebootRequired, [ref]$lastError)
if (-not $bindOutcome -and $lastError -ne 0) {
    $hexError = ("0x{0:X8}" -f ([uint32]$lastError))
    throw "UpdateDriverForPlugAndPlayDevices failed with $hexError."
}

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/scan-devices")

$finalDevices = @(Get-AvshwsDevices -Id $HardwareId)
if ($finalDevices.Count -eq 0) {
    throw "Install finished but no ROOT\\$HardwareId device was found."
}

Write-Host ""
Write-Host "Driver install complete."
$finalDevices | ForEach-Object {
    Write-Host ("InstanceId: {0}" -f $_.PNPDeviceID)
    Write-Host ("Name:       {0}" -f $_.Name)
    Write-Host ("Status:     {0}" -f $_.Status)
    Write-Host ""
}

if ($rebootRequired) {
    Write-Host "A reboot is required to finalize installation."
}
Read-Host -Prompt "Press Enter to continue"