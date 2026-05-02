[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [string]$VmName = "hlk-controller",
    [string]$VmRoot = "C:\Hyper-V\HLK",
    [string]$VhdPath = "",
    [UInt64]$VhdSizeBytes = 137438953472,
    [string]$SwitchName = "",
    [int]$ProcessorCount = 4,
    [UInt64]$StartupMemoryBytes = 4294967296,
    [switch]$StartVm,
    [switch]$ForceRecreate,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$resolvedIso = Resolve-HvPath -Path $IsoPath
if (-not (Test-Path -LiteralPath $resolvedIso)) {
    Fail-Hv -Message ("ISO not found: {0}" -f $resolvedIso) -LogPath $LogPath
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path (Get-HvArtifactDirectory -ArtifactRoot "output\hyperv-hlk-controller") "hyperv-hlk-controller-vm.log"
}

if ([string]::IsNullOrWhiteSpace($SwitchName)) {
    $switch = Get-VMSwitch | Where-Object { $_.SwitchType -eq "External" } | Select-Object -First 1
    if (-not $switch) {
        $switch = Get-VMSwitch | Select-Object -First 1
    }
    if (-not $switch) {
        Fail-Hv -Message "No Hyper-V switch found." -LogPath $LogPath
    }
    $SwitchName = $switch.Name
}

$resolvedVmRoot = Resolve-HvPath -Path $VmRoot
$null = New-Item -ItemType Directory -Force -Path $resolvedVmRoot

if ([string]::IsNullOrWhiteSpace($VhdPath)) {
    $VhdPath = Join-Path $resolvedVmRoot ("{0}.vhdx" -f $VmName)
} else {
    $VhdPath = Resolve-HvPath -Path $VhdPath
}

Write-HvLog -Message ("Preparing HLK controller VM '{0}'" -f $VmName) -LogPath $LogPath -Level STEP
Write-HvLog -Message ("ISO: {0}" -f $resolvedIso) -LogPath $LogPath
Write-HvLog -Message ("Switch: {0}" -f $SwitchName) -LogPath $LogPath
Write-HvLog -Message ("VHD: {0}" -f $VhdPath) -LogPath $LogPath

$existingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($existingVm) {
    if (-not $ForceRecreate) {
        Fail-Hv -Message ("VM '{0}' already exists. Use -ForceRecreate to rebuild it." -f $VmName) -LogPath $LogPath
    }

    Write-HvLog -Message ("Removing existing VM '{0}'" -f $VmName) -LogPath $LogPath -Level STEP
    if ($existingVm.State -ne "Off") {
        Stop-VM -Name $VmName -TurnOff -Force -Confirm:$false | Out-Null
    }
    Remove-VM -Name $VmName -Force | Out-Null
}

if ($ForceRecreate -and (Test-Path -LiteralPath $VhdPath)) {
    Write-HvLog -Message ("Removing existing VHD '{0}'" -f $VhdPath) -LogPath $LogPath -Level STEP
    Remove-Item -LiteralPath $VhdPath -Force
}

if (-not (Test-Path -LiteralPath $VhdPath)) {
    Write-HvLog -Message "Creating controller VHDX." -LogPath $LogPath -Level STEP
    New-VHD -Path $VhdPath -SizeBytes $VhdSizeBytes -Dynamic | Out-Null
}

Write-HvLog -Message "Creating Generation 2 controller VM." -LogPath $LogPath -Level STEP
$vm = New-VM `
    -Name $VmName `
    -Generation 2 `
    -MemoryStartupBytes $StartupMemoryBytes `
    -VHDPath $VhdPath `
    -Path $resolvedVmRoot `
    -SwitchName $SwitchName

Set-VMProcessor -VMName $VmName -Count $ProcessorCount | Out-Null
Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false -CheckpointType Standard | Out-Null
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false | Out-Null

$dvd = Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue
if (-not $dvd) {
    Add-VMDvdDrive -VMName $VmName -Path $resolvedIso | Out-Null
} else {
    Set-VMDvdDrive -VMName $VmName -Path $resolvedIso | Out-Null
}

$dvdDrive = Get-VMDvdDrive -VMName $VmName | Select-Object -First 1
$hddDrive = Get-VMHardDiskDrive -VMName $VmName | Select-Object -First 1
Set-VMFirmware -VMName $VmName -EnableSecureBoot On | Out-Null
if ($dvdDrive -and $hddDrive) {
    Set-VMFirmware -VMName $VmName -FirstBootDevice $dvdDrive -BootOrder $dvdDrive, $hddDrive | Out-Null
}

if ($StartVm) {
    Write-HvLog -Message "Starting controller VM." -LogPath $LogPath -Level STEP
    Start-VM -Name $VmName | Out-Null
}

[pscustomobject]@{
    VmName             = $VmName
    IsoPath            = $resolvedIso
    VhdPath            = $VhdPath
    SwitchName         = $SwitchName
    ProcessorCount     = $ProcessorCount
    StartupMemoryBytes = $StartupMemoryBytes
    Started            = [bool]$StartVm
}
