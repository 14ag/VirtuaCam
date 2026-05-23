[CmdletBinding()]
param(
    [switch]$SkipDllRegister,
    [switch]$SkipCertificateImport,
    [switch]$SkipWatcherService,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FileSha256Hash {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $stream = [System.IO.File]::OpenRead($LiteralPath)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha256.ComputeHash($stream)
            return [BitConverter]::ToString($hash).Replace("-", "")
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

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
    try {
        return @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.PNPDeviceID -like "ROOT\AVSHWS\*" })
    }
    catch {
        Write-Info "CIM device query failed for ROOT\AVSHWS; falling back to pnputil."
    }

    $output = & "$env:WINDIR\System32\pnputil.exe" /enum-devices /instanceid "ROOT\AVSHWS\0000" 2>$null
    if ($LASTEXITCODE -eq 0 -and ($output -match 'Instance ID:\s+ROOT\\AVSHWS\\0000')) {
        return @([pscustomobject]@{ PNPDeviceID = "ROOT\AVSHWS\0000"; Status = "OK" })
    }
    return @()
}

function Get-VirtuaCamMicDevices {
    try {
        return @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.PNPDeviceID -like "ROOT\VIRTUACAMMIC\*" })
    }
    catch {
        Write-Info "CIM device query failed for ROOT\VIRTUACAMMIC; falling back to pnputil."
    }

    $output = & "$env:WINDIR\System32\pnputil.exe" /enum-devices /instanceid "ROOT\VIRTUACAMMIC\0000" 2>$null
    if ($LASTEXITCODE -eq 0 -and ($output -match 'Instance ID:\s+ROOT\\VIRTUACAMMIC\\0000')) {
        return @([pscustomobject]@{ PNPDeviceID = "ROOT\VIRTUACAMMIC\0000"; Status = "OK" })
    }
    return @()
}

function Get-DeviceInstanceIdForPattern {
    param([Parameter(Mandatory = $true)][string]$DeviceIdPattern)

    if ($DeviceIdPattern -like "ROOT\AVSHWS\*") {
        return "ROOT\AVSHWS\0000"
    }
    if ($DeviceIdPattern -like "ROOT\VIRTUACAMMIC\*") {
        return "ROOT\VIRTUACAMMIC\0000"
    }
    return $null
}

function Get-BoundDriverInfNames {
    param([Parameter(Mandatory = $true)][string]$DeviceIdPattern)

    try {
        $signedDrivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceID -like $DeviceIdPattern -and $_.InfName }
        return @($signedDrivers | Select-Object -ExpandProperty InfName -Unique)
    }
    catch {
        Write-Info "CIM driver query failed for $DeviceIdPattern; falling back to pnputil."
    }

    $instanceId = Get-DeviceInstanceIdForPattern -DeviceIdPattern $DeviceIdPattern
    if (-not $instanceId) {
        return @()
    }

    $output = & "$env:WINDIR\System32\pnputil.exe" /enum-devices /instanceid $instanceId /drivers 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @($output |
        Where-Object { $_ -match '^\s*Driver Name:\s*(oem\d+\.inf)\s*$' } |
        ForEach-Object { $Matches[1] } |
        Select-Object -Unique)
}

function Remove-DriverPackagesForDevicePattern {
    param([Parameter(Mandatory = $true)][string]$DeviceIdPattern)

    $infNames = @(Get-BoundDriverInfNames -DeviceIdPattern $DeviceIdPattern)
    foreach ($inf in $infNames) {
        if ($inf -match '^oem\d+\.inf$') {
            Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/delete-driver", $inf, "/uninstall", "/force") -AllowedExitCodes @(0, 2, 259, 3010, -536870340)
        }
    }
}

function Remove-ExistingDriverPackage {
    param([Parameter(Mandatory = $true)][string]$DeviceIdPattern)

    $infNames = @(Get-BoundDriverInfNames -DeviceIdPattern $DeviceIdPattern)
    if ($infNames.Count -eq 0) {
        Write-Info "No bound OEM INF found for $DeviceIdPattern"
        return
    }

    foreach ($inf in $infNames) {
        if ($inf -match '^oem\d+\.inf$') {
            Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/delete-driver", $inf, "/uninstall", "/force") -AllowedExitCodes @(0, 2, 259, 3010, -536870340)
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
$packageRoot = [System.IO.Path]::GetFullPath($scriptDir)
$manifestPath = Join-Path $packageRoot "scripts\tools\artifact-manifest.ps1"
if (Test-Path -LiteralPath $manifestPath) {
    . $manifestPath
}
else {
    function Get-VirtuaCamSoftwareArtifacts {
        @(
            "VirtuaCam.exe",
            "VirtuaCamProcess.exe",
            "DirectPortBroker.dll",
            "DirectPortClient.dll"
        )
    }

    function Get-VirtuaCamRuntimeArtifacts {
        @(
            "msvcp140.dll",
            "vcruntime140.dll",
            "vcruntime140_1.dll"
        )
    }

    function Get-VirtuaCamSetupArtifacts {
        @(
            "VirtuaCamSetup.exe"
        )
    }

    function Get-VirtuaCamCameraDriverArtifacts {
        @(
            "avshws.sys",
            "avshws.inf",
            "avshws.cat",
            "VirtualCameraDriver-TestSign.cer"
        )
    }

    function Get-VirtuaCamAudioDriverArtifacts {
        @(
            "virtuacam_mic.sys",
            "virtuacam-mic.inf",
            "virtuacam-mic.cat"
        )
    }

    function Get-VirtuaCamDriverArtifacts {
        @(
            (Get-VirtuaCamCameraDriverArtifacts) +
            (Get-VirtuaCamAudioDriverArtifacts)
        )
    }

    function Get-VirtuaCamInstallArtifacts {
        @(
            (Get-VirtuaCamSoftwareArtifacts) +
            (Get-VirtuaCamSetupArtifacts) +
            (Get-VirtuaCamRuntimeArtifacts) +
            (Get-VirtuaCamDriverArtifacts)
        )
    }
}
$OutputRoot = $packageRoot

$runKeyPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$virtuaCamRegPath = "HKLM:\SOFTWARE\VirtuaCam"
$watcherServiceName = "VirtuaCamWatcher"
$logsDir = Join-Path $packageRoot "logs"
$logPath = Join-Path $logsDir "driver-install.log"

$installDir = $OutputRoot
$expectedArtifacts = Get-VirtuaCamInstallArtifacts

$virtuaCamExe = Join-Path $installDir "VirtuaCam.exe"
$processExe = Join-Path $installDir "VirtuaCamProcess.exe"
$driverInf = Join-Path $OutputRoot "avshws.inf"
$driverSys = Join-Path $OutputRoot "avshws.sys"
$driverCat = Join-Path $OutputRoot "avshws.cat"
$audioDriverInf = Join-Path $OutputRoot "virtuacam-mic.inf"
$audioDriverSys = Join-Path $OutputRoot "virtuacam_mic.sys"
$audioDriverCat = Join-Path $OutputRoot "virtuacam-mic.cat"
$driverCer = Join-Path $OutputRoot "VirtualCameraDriver-TestSign.cer"
$clientDll = Join-Path $OutputRoot "DirectPortClient.dll"

function Remove-LegacyUserSettingsFile {
    $candidateRoots = @(
        [Environment]::GetFolderPath("LocalApplicationData"),
        [Environment]::GetFolderPath("ApplicationData")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($root in $candidateRoots) {
        $legacyPath = Join-Path $root "VirtuaCam\settings.ini"
        Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-WatcherService {
    param([Parameter(Mandatory = $true)][string]$ProcessPath)

    if (-not (Test-Path -LiteralPath $ProcessPath)) {
        Fail "Cannot install watcher service because ProcessExe is missing: $ProcessPath"
    }

    $binPath = "`"$ProcessPath`" --service"
    $service = Get-Service -Name $watcherServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-Info "Updating service: $watcherServiceName"
        if ($service.Status -ne "Stopped") {
            Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("stop", $watcherServiceName) -AllowedExitCodes @(0, 1062)
            try {
                $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
            } catch {
                $service.Refresh()
                if ($service.Status -ne "Stopped") {
                    Fail "Timed out stopping watcher service before update: $watcherServiceName"
                }
            }
        }
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("config", $watcherServiceName, "binPath=", $binPath, "start=", "auto")
    } else {
        Write-Info "Creating service: $watcherServiceName"
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("create", $watcherServiceName, "binPath=", $binPath, "start=", "auto", "DisplayName=", "VirtuaCam Watcher")
    }

    Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("description", $watcherServiceName, "Starts VirtuaCam when the virtual camera is accessed.")

    $service = Get-Service -Name $watcherServiceName -ErrorAction Stop
    if ($service.Status -ne "Running") {
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("start", $watcherServiceName) -AllowedExitCodes @(0, 1056)
    }

    Write-Success "Watcher service installed and running: $watcherServiceName"
}

function Protect-VirtuaCamRegistryKey {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $null = Get-Command Get-Acl -ErrorAction Stop
        $null = Get-Command Set-Acl -ErrorAction Stop
    }
    catch {
        Write-Info "Registry ACL hardening skipped; ACL cmdlets unavailable in this PowerShell host."
        return
    }

    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }

    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $rules = @(
        [System.Security.AccessControl.RegistryAccessRule]::new("SYSTEM", "FullControl", $inheritance, $propagation, "Allow"),
        [System.Security.AccessControl.RegistryAccessRule]::new("BUILTIN\Administrators", "FullControl", $inheritance, $propagation, "Allow"),
        [System.Security.AccessControl.RegistryAccessRule]::new("BUILTIN\Users", "ReadKey", $inheritance, $propagation, "Allow")
    )

    foreach ($rule in $rules) {
        $acl.AddAccessRule($rule)
    }

    Set-Acl -Path $Path -AclObject $acl
}

function Uninstall-WatcherService {
    $service = Get-Service -Name $watcherServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }

    if ($service.Status -ne "Stopped") {
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("stop", $watcherServiceName) -AllowedExitCodes @(0, 1062)
        try {
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
        } catch {
            $service.Refresh()
            if ($service.Status -ne "Stopped") {
                Fail "Timed out stopping watcher service before removal: $watcherServiceName"
            }
        }
    }
    Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("delete", $watcherServiceName)
    Write-Success "Watcher service removed: $watcherServiceName"
}

function Stop-VirtuaCamRuntime {
    $service = Get-Service -Name $watcherServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Stopped") {
        Write-Info "Stopping watcher service before driver install."
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\sc.exe" -Arguments @("stop", $watcherServiceName) -AllowedExitCodes @(0, 1062)
        try {
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
        } catch {
            $service.Refresh()
            if ($service.Status -ne "Stopped") {
                Fail "Timed out stopping watcher service before driver install: $watcherServiceName"
            }
        }
    }

    $processes = @(Get-Process -Name "VirtuaCam", "VirtuaCamProcess" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        Write-Info ("Stopping runtime process before driver install: {0} ({1})" -f $process.ProcessName, $process.Id)
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host " Install All"
Write-Host "============================================================" -ForegroundColor Green
Write-Info "OutputRoot: $OutputRoot"

if ($Uninstall) {
    Assert-Administrator
    Write-Step "Uninstall startup and VirtuaCam registry entries"
    Uninstall-WatcherService
    Remove-DriverPackagesForDevicePattern -DeviceIdPattern "ROOT\VIRTUACAMMIC\*"
    Remove-DriverPackagesForDevicePattern -DeviceIdPattern "ROOT\AVSHWS\*"
    Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCam" -ErrorAction SilentlyContinue
    Remove-Item -Path $virtuaCamRegPath -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\VirtuaCam\Settings" -Recurse -ErrorAction SilentlyContinue
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

Write-Step "Install driver from output"
Stop-VirtuaCamRuntime

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
Remove-ExistingDriverPackage -DeviceIdPattern "ROOT\AVSHWS\*"
Remove-ExistingDriverPackage -DeviceIdPattern "ROOT\VIRTUACAMMIC\*"

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/add-driver", $driverInf, "/install") -AllowedExitCodes @(0, 2, 259, 3010)

$existingDevices = @(Get-AvshwsDevices)
if ($existingDevices.Count -eq 0) {
    Write-Info "No ROOT\AVSHWS device present. Creating it now."
    $cameraClassGuid = [Guid]::Parse("{ca3e7ab9-b4c3-4ae6-8251-579ef933890f}")
    [AvshwsInstallerNative]::CreateRootDevice("AVSHWS", "AVSHWS", "Virtual Camera Driver", $cameraClassGuid)
}
else {
    Write-Info "ROOT\AVSHWS already exists. Reusing existing device node."
}

$rebootRequired = $false
[int]$lastError = 0
$bindOutcome = [AvshwsInstallerNative]::TryBindDriver("AVSHWS", $driverInf, $true, [ref]$rebootRequired, [ref]$lastError)
if (-not $bindOutcome -and $lastError -ne 0) {
    $hexError = ("0x{0:X8}" -f ([uint32]$lastError))
    Fail "UpdateDriverForPlugAndPlayDevices failed with $hexError."
}

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/scan-devices")

$finalDevices = @(Get-AvshwsDevices)
if ($finalDevices.Count -eq 0) {
    Fail "Install finished but no ROOT\AVSHWS device was found."
}

foreach ($device in $finalDevices) {
    if (-not [string]::IsNullOrWhiteSpace($device.PNPDeviceID)) {
        Write-Info ("Restarting device node: {0}" -f $device.PNPDeviceID)
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/restart-device", $device.PNPDeviceID) -AllowedExitCodes @(0, 2, 259, 3010)
    }
}

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/scan-devices")

$finalDevices = @(Get-AvshwsDevices)
if ($finalDevices.Count -eq 0) {
    Fail "Device node disappeared after restart."
}

$bad = @($finalDevices | Where-Object { $_.Status -and $_.Status -ne "OK" })
if ($bad.Count -gt 0) {
    Fail "Installed device present but not OK status."
}

if ($rebootRequired) {
    Write-Info "A reboot is required to finalize installation."
}

Write-Success "Fresh driver install OK from $OutputRoot"

Write-Step "Install virtual microphone driver from output"

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/add-driver", $audioDriverInf, "/install") -AllowedExitCodes @(0, 2, 259, 3010)

$audioHardwareId = "ROOT\VIRTUACAMMIC"
$existingMicDevices = @(Get-VirtuaCamMicDevices)
if ($existingMicDevices.Count -eq 0) {
    Write-Info "No ROOT\VIRTUACAMMIC device present. Creating it now."
    $mediaClassGuid = [Guid]::Parse("{4d36e96c-e325-11ce-bfc1-08002be10318}")
    [AvshwsInstallerNative]::CreateRootDevice($audioHardwareId, "VIRTUACAMMIC", "VirtuaCam Microphone", $mediaClassGuid)
}
else {
    Write-Info "ROOT\VIRTUACAMMIC already exists. Reusing existing device node."
}

$audioRebootRequired = $false
[int]$audioLastError = 0
$audioBindOutcome = [AvshwsInstallerNative]::TryBindDriver($audioHardwareId, $audioDriverInf, $true, [ref]$audioRebootRequired, [ref]$audioLastError)
if (-not $audioBindOutcome -and $audioLastError -ne 0) {
    $hexError = ("0x{0:X8}" -f ([uint32]$audioLastError))
    Fail "Audio UpdateDriverForPlugAndPlayDevices failed with $hexError."
}

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/scan-devices")

$finalMicDevices = @(Get-VirtuaCamMicDevices)
if ($finalMicDevices.Count -eq 0) {
    Fail "Install finished but no ROOT\VIRTUACAMMIC device was found."
}

foreach ($device in $finalMicDevices) {
    if (-not [string]::IsNullOrWhiteSpace($device.PNPDeviceID)) {
        Write-Info ("Restarting mic device node: {0}" -f $device.PNPDeviceID)
        Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/restart-device", $device.PNPDeviceID) -AllowedExitCodes @(0, 2, 259, 3010)
    }
}

Invoke-NativeProcess -FilePath "$env:WINDIR\System32\pnputil.exe" -Arguments @("/scan-devices")

$finalMicDevices = @(Get-VirtuaCamMicDevices)
$badMic = @($finalMicDevices | Where-Object { $_.Status -and $_.Status -ne "OK" })
if ($badMic.Count -gt 0) {
    foreach ($device in $badMic) {
        Write-Info ("Bad mic device: Name='{0}' PNPDeviceID='{1}' Status='{2}' ConfigManagerErrorCode='{3}'" -f $device.Name, $device.PNPDeviceID, $device.Status, $device.ConfigManagerErrorCode)
    }
    Fail "Installed VirtuaCam microphone device present but not OK status."
}

if ($audioRebootRequired) {
    Write-Info "A reboot is required to finalize microphone installation."
}

Write-Success "VirtuaCam Microphone driver install OK from $OutputRoot"

if (-not $SkipDllRegister) {
    Write-Step "Register software components from output"
    Invoke-NativeProcess -FilePath "$env:WINDIR\System32\regsvr32.exe" -Arguments @("/s", $clientDll)
    Write-Success "Registered: $clientDll"
} else {
    Write-Info "Skip DLL register"
}

Write-Step "Configure registry and startup from output"
Remove-LegacyUserSettingsFile
New-Item -Path $virtuaCamRegPath -Force | Out-Null
$installDirCanonical = [System.IO.Path]::GetFullPath($installDir)
$virtuaCamExeCanonical = [System.IO.Path]::GetFullPath($virtuaCamExe)
$processExeCanonical = [System.IO.Path]::GetFullPath($processExe)
$virtuaCamExeHash = Get-FileSha256Hash -LiteralPath $virtuaCamExeCanonical
$processExeHash = Get-FileSha256Hash -LiteralPath $processExeCanonical
Set-ItemProperty -Path $virtuaCamRegPath -Name "InstallDir" -Value $installDirCanonical
Set-ItemProperty -Path $virtuaCamRegPath -Name "VirtuaCamExe" -Value $virtuaCamExeCanonical
Set-ItemProperty -Path $virtuaCamRegPath -Name "ProcessExe" -Value $processExeCanonical
Set-ItemProperty -Path $virtuaCamRegPath -Name "VirtuaCamExeSha256" -Value $virtuaCamExeHash
Set-ItemProperty -Path $virtuaCamRegPath -Name "ProcessExeSha256" -Value $processExeHash
Protect-VirtuaCamRegistryKey -Path $virtuaCamRegPath
Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $runKeyPath -Name "VirtuaCam" -ErrorAction SilentlyContinue
if ($SkipWatcherService) {
    Uninstall-WatcherService
    Write-Info "Skip watcher service install."
    Write-Success "Configured HKLM\SOFTWARE\VirtuaCam without watcher service startup"
} else {
    Install-WatcherService -ProcessPath $processExeCanonical
    Write-Success "Configured HKLM\SOFTWARE\VirtuaCam and watcher service startup"
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " INSTALL-ALL SUCCEEDED"
Write-Host "============================================================" -ForegroundColor Green
