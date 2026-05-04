[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [switch]$ForceRefresh,
    [switch]$EnableSsh,
    [ValidateSet("Password", "PasswordAndKey")][string]$SshAuthMode = "Password",
    [string]$SshHostPublicKeyPath = "",
    [switch]$StartVmAfterCreate,
    [string]$ArtifactRoot = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { Get-HvArtifactDirectory -ArtifactRoot "output\hyperv-clean" } else { Resolve-HvPath -Path $ArtifactRoot }
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-clean-checkpoint.log"
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext

function Invoke-CleanBenchPass {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$RunLabel,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    Write-HvLog -Message ("Guest cleanup pass: {0}" -f $RunLabel) -LogPath $LogFile -Level STEP

    return Invoke-HvGuestCommand -Session $Session -LogPath $LogFile -ScriptBlock {
        param($PassLabel)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        function Get-DriverPackagesToRemove {
            $enum = pnputil /enum-drivers 2>&1 | Out-String
            $blocks = $enum -split "(?ms)\r?\n\r?\n"
            $packages = New-Object System.Collections.Generic.List[string]
            foreach ($block in $blocks) {
                if ($block -match '(?im)^\s*Original Name:\s*avshws\.inf\s*$' -or
                    $block -match '(?im)^\s*Provider Name:\s*VirtualCameraDriver\s*$') {
                    if ($block -match '(?im)^\s*Published Name:\s*(oem\d+\.inf)\s*$') {
                        $packages.Add($matches[1].ToLowerInvariant())
                    }
                }
            }
            return $packages | Select-Object -Unique
        }

        function Test-DriverStillPresent {
            $enum = pnputil /enum-drivers 2>&1 | Out-String
            return ($enum -match '(?im)^\s*Original Name:\s*avshws\.inf\s*$') -or
                   ($enum -match '(?im)^\s*Provider Name:\s*VirtualCameraDriver\s*$')
        }

        function Get-DeviceStatusText {
            return pnputil /enum-devices /instanceid ROOT\AVSHWS\0000 2>&1 | Out-String
        }

        Get-Process -Name "VirtuaCam", "VirtuaCamProcess", "chrome", "msedge", "WindowsCamera" -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

        $benchRoots = @(
            "C:\Temp\VirtuaCamHyperV",
            "C:\Temp\VirtuaCamChat",
            "C:\Temp\VirtuaCamServiceMenu"
        )
        foreach ($benchRoot in $benchRoots) {
            if (Test-Path -LiteralPath $benchRoot) {
                Remove-Item -LiteralPath $benchRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $tempOpenSshArtifacts = @(
            "C:\Temp\OpenSSH-Win64.zip",
            "C:\Temp\OpenSSH-Win64-extract"
        )
        foreach ($tempArtifact in $tempOpenSshArtifacts) {
            if (Test-Path -LiteralPath $tempArtifact) {
                Remove-Item -LiteralPath $tempArtifact -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $minidumpDir = Join-Path $env:SystemRoot "Minidump"
        if (Test-Path -LiteralPath $minidumpDir) {
            Remove-Item -LiteralPath (Join-Path $minidumpDir "*.dmp") -Force -ErrorAction SilentlyContinue
        }
        $memoryDump = Join-Path $env:SystemRoot "MEMORY.DMP"
        if (Test-Path -LiteralPath $memoryDump) {
            Remove-Item -LiteralPath $memoryDump -Force -ErrorAction SilentlyContinue
        }

        $deviceBefore = Get-DeviceStatusText
        $removeDeviceOutput = ""
        if ($deviceBefore -notmatch '(?i)no devices were found') {
            $removeDeviceOutput = pnputil /remove-device ROOT\AVSHWS\0000 2>&1 | Out-String
        }

        $deleteResults = @()
        $needsReboot = $false
        foreach ($pkg in (Get-DriverPackagesToRemove)) {
            $out = pnputil /delete-driver $pkg /uninstall /force 2>&1 | Out-String
            if ($out -match '(?i)reboot') {
                $needsReboot = $true
            }
            $deleteResults += [pscustomobject]@{
                Package = $pkg
                Output  = $out
            }
        }

        $scanOutput = pnputil /scan-devices 2>&1 | Out-String
        $deviceAfter = Get-DeviceStatusText
        $driverStillPresent = Test-DriverStillPresent
        $deviceStillPresent = $deviceAfter -notmatch '(?i)no devices were found'

        $bcd = & "$env:WINDIR\System32\bcdedit.exe" /enum "{current}" 2>&1 | Out-String
        $testSigningOn = $bcd -match '(?im)^\s*testsigning\s+Yes\b'
        $chrome = Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"

        [pscustomobject]@{
            PassLabel           = $PassLabel
            TestSigning         = $testSigningOn
            ChromePresent       = [bool](Test-Path -LiteralPath $chrome)
            DeviceBefore        = $deviceBefore
            RemoveDeviceOutput  = $removeDeviceOutput
            DeletedPackages     = $deleteResults
            ScanOutput          = $scanOutput
            DeviceAfter         = $deviceAfter
            DriverStillPresent  = $driverStillPresent
            DeviceStillPresent  = $deviceStillPresent
            NeedsReboot         = $needsReboot
            CheckedAtUtc        = [DateTime]::UtcNow.ToString("o")
        }
    } -ArgumentList $RunLabel
}

function Stop-VmForCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$TargetVm,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    try {
        Stop-VM -Name $TargetVm -Force -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        Write-HvLog -Message ("Graceful stop failed, forcing power off: {0}" -f $_.Exception.Message) -LogPath $LogFile -Level WARN
        Stop-VM -Name $TargetVm -TurnOff -Force -Confirm:$false | Out-Null
    }

    $deadline = (Get-Date).AddSeconds(120)
    do {
        $vm = Get-VM -Name $TargetVm -ErrorAction Stop
        if ($vm.State -eq "Off") {
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for VM '$TargetVm' to power off."
}

Write-HvLog -Message ("Preparing clean checkpoint '{0}' for '{1}'" -f $CheckpointName, $VmName) -LogPath $LogPath -Level STEP

$existingCheckpoint = Get-VMSnapshot -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue
if ($existingCheckpoint -and -not $ForceRefresh) {
    Fail-Hv -Message ("Checkpoint '{0}' already exists. Use -ForceRefresh to rebuild it." -f $CheckpointName) -LogPath $LogPath
}

if ($existingCheckpoint -and $ForceRefresh) {
    Write-HvLog -Message ("Removing existing checkpoint '{0}'" -f $CheckpointName) -LogPath $LogPath -Level STEP
    Remove-VMSnapshot -VMName $VmName -Name $CheckpointName -Confirm:$false | Out-Null
}

$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
try {
    $pass1 = Invoke-CleanBenchPass -Session $session -RunLabel "pass1" -LogFile $LogPath
    $pass1 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "guest-clean-pass1.json")

    if ($pass1.NeedsReboot -or $pass1.DriverStillPresent -or $pass1.DeviceStillPresent) {
        Write-HvLog -Message "Guest cleanup requested reboot or still sees driver state; restarting for second pass." -LogPath $LogPath -Level STEP
        Restart-HvGuest -Session $session -LogPath $LogPath
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 300 -LogPath $LogPath

        $pass2 = Invoke-CleanBenchPass -Session $session -RunLabel "pass2" -LogFile $LogPath
        $pass2 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "guest-clean-pass2.json")

        if ($pass2.DriverStillPresent -or $pass2.DeviceStillPresent) {
            Fail-Hv -Message "Guest cleanup did not remove avshws from the device/driver store. Refusing to create clean checkpoint." -LogPath $LogPath
        }
    }

    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
    }

    if ($EnableSsh) {
        Write-HvLog -Message ("Preparing SSH state in guest before checkpoint create (auth mode: {0})" -f $SshAuthMode) -LogPath $LogPath -Level STEP
        $sshResult = & (Join-Path $PSScriptRoot "hyperv-enable-ssh.ps1") `
            -VmName $VmName `
            -GuestCredential $guestCred `
            -AuthMode $SshAuthMode `
            -HostPublicKeyPath $SshHostPublicKeyPath `
            -LogPath (Join-Path $artifactDir "hyperv-enable-ssh.log") `
            -ResultPath (Join-Path $artifactDir "guest-ssh-ready.json")

        if (-not $sshResult -or -not $sshResult.GuestIp) {
            Fail-Hv -Message "SSH preparation completed without guest IP result. Refusing to create checkpoint." -LogPath $LogPath
        }
    }

    Stop-VmForCheckpoint -TargetVm $VmName -LogFile $LogPath
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

Write-HvLog -Message "Configuring VM to use standard checkpoints for repeatable test resets." -LogPath $LogPath -Level STEP
Set-VM -Name $VmName -CheckpointType Standard | Out-Null

Write-HvLog -Message ("Creating checkpoint '{0}'" -f $CheckpointName) -LogPath $LogPath -Level STEP
$checkpoint = Checkpoint-VM -Name $VmName -SnapshotName $CheckpointName -Passthru -ErrorAction Stop

if ($StartVmAfterCreate) {
    Start-VM -Name $VmName | Out-Null
}

[pscustomobject]@{
    VmName            = $VmName
    CheckpointName    = $CheckpointName
    ArtifactDir       = $artifactDir
    StartVmAfterCreate = [bool]$StartVmAfterCreate
    CheckpointId      = $checkpoint.Id.Guid
}
