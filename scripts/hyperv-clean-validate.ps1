[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [switch]$RequireHlkClient,
    [string]$ArtifactRoot = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { Get-HvArtifactDirectory -ArtifactRoot "output\hyperv-clean-validate" } else { Resolve-HvPath -Path $ArtifactRoot }
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-clean-validate.log"
}

function Restore-HvCheckpointForValidation {
    param(
        [Parameter(Mandatory = $true)][string]$TargetVm,
        [Parameter(Mandatory = $true)][string]$TargetCheckpoint,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    Write-HvLog -Message ("Restoring checkpoint '{0}' before validation." -f $TargetCheckpoint) -LogPath $LogFile -Level STEP
    $checkpoint = Get-VMSnapshot -VMName $TargetVm -Name $TargetCheckpoint -ErrorAction SilentlyContinue
    if (-not $checkpoint) {
        Fail-Hv -Message ("Checkpoint '{0}' was not found." -f $TargetCheckpoint) -LogPath $LogFile
    }

    try {
        $vmState = (Get-VM -Name $TargetVm -ErrorAction Stop).State
        if ($vmState -ne "Off") {
            Stop-VM -Name $TargetVm -TurnOff -Force -Confirm:$false | Out-Null
        }
    }
    catch {
        Write-HvLog -Message ("VM stop before restore skipped: {0}" -f $_.Exception.Message) -LogPath $LogFile -Level WARN
    }

    Restore-VMCheckpoint -VMName $TargetVm -Name $TargetCheckpoint -Confirm:$false | Out-Null
}

function Assert-PoshSshAvailable {
    param([Parameter(Mandatory = $true)][string]$LogFile)

    $module = Get-Module -ListAvailable Posh-SSH | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        Fail-Hv -Message "Posh-SSH module is required for clean bench validation." -LogPath $LogFile
    }

    Import-Module $module.Path -Force
    return $module
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
Restore-HvCheckpointForValidation -TargetVm $VmName -TargetCheckpoint $CheckpointName -LogFile $LogPath

$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
$sshSession = $null

try {
    $guestState = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($CheckForHlk)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        function Get-DriverResidue {
            $enum = pnputil /enum-drivers 2>&1 | Out-String
            $device = pnputil /enum-devices /instanceid ROOT\AVSHWS\0000 2>&1 | Out-String
            [pscustomobject]@{
                DriverStoreHit = [bool](
                    $enum -match '(?im)^\s*Original Name:\s*avshws\.inf\s*$' -or
                    $enum -match '(?im)^\s*Provider Name:\s*VirtualCameraDriver\s*$'
                )
                DeviceHit = [bool]($device -notmatch '(?i)no devices were found')
                DriverEnum = $enum
                DeviceEnum = $device
            }
        }

        function Get-HlkArpEntries {
            $roots = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )

            foreach ($root in $roots) {
                Get-ItemProperty $root -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.PSObject.Properties["DisplayName"] -and
                        $_.DisplayName -match 'Hardware Lab Kit Client|HLK Client|Windows Driver Testing Framework|Windows Performance Toolkit|Application Verifier'
                    } |
                    Select-Object DisplayName, DisplayVersion, Publisher
            }
        }

        $listener = @(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
        $guestIp = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
            Sort-Object InterfaceMetric |
            Select-Object -First 1 -ExpandProperty IPAddress)

        $hlkServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match 'HLK|WTT' -or
            ($_.PSObject.Properties["DisplayName"] -and $_.DisplayName -match 'Hardware Lab Kit|Windows Driver Testing')
        } | Select-Object Name, DisplayName, Status, StartType)

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            GuestIp = $guestIp
            SshListenerCount = $listener.Count
            DriverResidue = Get-DriverResidue
            HlkInstalledEntries = @(Get-HlkArpEntries)
            HlkServices = $hlkServices
            RequireHlkClient = [bool]$CheckForHlk
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    } -ArgumentList ([bool]$RequireHlkClient)

    $guestState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "guest-clean-validation.json") -Encoding UTF8

    if ($guestState.DriverResidue.DriverStoreHit -or $guestState.DriverResidue.DeviceHit) {
        Fail-Hv -Message "Restored clean checkpoint still contains avshws residue." -LogPath $LogPath
    }

    if ($guestState.SshListenerCount -lt 1) {
        Fail-Hv -Message "Guest sshd is not listening on port 22 after clean restore." -LogPath $LogPath
    }

    if ([string]::IsNullOrWhiteSpace($guestState.GuestIp)) {
        Fail-Hv -Message "Guest did not report a usable IPv4 address for SSH validation." -LogPath $LogPath
    }

    if ($RequireHlkClient) {
        if (@($guestState.HlkInstalledEntries).Count -lt 1) {
            Fail-Hv -Message "Required HLK client packages are not installed in restored clean checkpoint." -LogPath $LogPath
        }

        $runningHlkService = @($guestState.HlkServices | Where-Object {
            ([string]$_.Name) -ieq "HLKsvc" -and ([string]$_.Status) -ieq "Running"
        })
        if ($runningHlkService.Count -lt 1) {
            Fail-Hv -Message "HLKSvc is not running in restored clean checkpoint." -LogPath $LogPath
        }
    }

    $poshSshModule = Assert-PoshSshAvailable -LogFile $LogPath
    Write-HvLog -Message ("Using Posh-SSH {0} from {1}" -f $poshSshModule.Version, $poshSshModule.ModuleBase) -LogPath $LogPath -Level STEP

    $portReachable = Test-NetConnection -ComputerName $guestState.GuestIp -Port 22 -InformationLevel Quiet
    $portProbe = [pscustomobject]@{
        ComputerName = $guestState.GuestIp
        Port = 22
        Reachable = [bool]$portReachable
        CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    $portProbe | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifactDir "host-port22-probe.json") -Encoding UTF8

    if (-not $portReachable) {
        Fail-Hv -Message ("Host could not reach {0}:22 after clean restore." -f $guestState.GuestIp) -LogPath $LogPath
    }

    Write-HvLog -Message ("Opening SSH session to {0}" -f $guestState.GuestIp) -LogPath $LogPath -Level STEP
    $sshSession = New-SSHSession -ComputerName $guestState.GuestIp -Credential $guestCred -AcceptKey -ConnectionTimeout 30
    $sshResult = Invoke-SSHCommand -SSHSession $sshSession -Command 'cmd /c "hostname & whoami"'
    $sshState = [pscustomobject]@{
        Host = $guestState.GuestIp
        ExitStatus = $sshResult.ExitStatus
        Output = [string]::Join([Environment]::NewLine, @($sshResult.Output))
        Error = $sshResult.Error
        CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    $sshState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifactDir "host-ssh-validation.json") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $artifactDir "host-ssh-validation.txt") -Value $sshState.Output

    if ($sshState.ExitStatus -ne 0) {
        Fail-Hv -Message ("Posh-SSH login failed with exit status {0}." -f $sshState.ExitStatus) -LogPath $LogPath
    }

    [pscustomobject]@{
        VmName = $VmName
        CheckpointName = $CheckpointName
        GuestIp = $guestState.GuestIp
        RequireHlkClient = [bool]$RequireHlkClient
        ArtifactDir = $artifactDir
        HlkReady = if ($RequireHlkClient) { $true } else { $null }
    }
}
finally {
    if ($sshSession) {
        Remove-SSHSession -SSHSession $sshSession | Out-Null
    }

    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
