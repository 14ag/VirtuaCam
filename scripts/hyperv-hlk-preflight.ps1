[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [string]$ControllerName = "",
    [string]$ControllerSharePath = "",
    [string]$ControllerUser = "",
    [string]$ControllerPasswordPlaintext = "",
    [string]$ArtifactRoot = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { Get-HvArtifactDirectory -ArtifactRoot "output\hyperv-hlk-preflight" } else { Resolve-HvPath -Path $ArtifactRoot }
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-hlk-preflight.log"
}

if ([string]::IsNullOrWhiteSpace($ControllerSharePath)) {
    if ([string]::IsNullOrWhiteSpace($ControllerName)) {
        Fail-Hv -Message "Provide -ControllerName or -ControllerSharePath." -LogPath $LogPath
    }

    $ControllerSharePath = "\\{0}\HLKInstall\Client\Setup.cmd" -f $ControllerName
}

$controllerHost = if (-not [string]::IsNullOrWhiteSpace($ControllerName)) {
    $ControllerName
} elseif ($ControllerSharePath -match '^\\\\([^\\]+)\\') {
    $matches[1]
} else {
    ""
}

function Add-HostControllerCredential {
    param(
        [Parameter(Mandatory = $true)][string]$ControllerHostName,
        [string]$UserName = "",
        [string]$Password = ""
    )

    if ([string]::IsNullOrWhiteSpace($ControllerHostName) -or
        [string]::IsNullOrWhiteSpace($UserName) -or
        [string]::IsNullOrWhiteSpace($Password)) {
        return
    }

    cmd.exe /c ("cmdkey /add:{0} /user:{1} /pass:{2}" -f $ControllerHostName, $UserName, $Password) | Out-Null
}

function Restore-HvCheckpointForPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$TargetVm,
        [Parameter(Mandatory = $true)][string]$TargetCheckpoint,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    Write-HvLog -Message ("Restoring checkpoint '{0}' before HLK preflight." -f $TargetCheckpoint) -LogPath $LogFile -Level STEP
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

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
Restore-HvCheckpointForPreflight -TargetVm $VmName -TargetCheckpoint $CheckpointName -LogFile $LogPath

Write-HvLog -Message ("Checking controller share from host: {0}" -f $ControllerSharePath) -LogPath $LogPath -Level STEP
Add-HostControllerCredential -ControllerHostName $controllerHost -UserName $ControllerUser -Password $ControllerPasswordPlaintext
$hostShareReachable = Test-Path -LiteralPath $ControllerSharePath
$hostShareState = [pscustomobject]@{
    SharePath = $ControllerSharePath
    Reachable = [bool]$hostShareReachable
    CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$hostShareState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifactDir "host-share-check.json") -Encoding UTF8

if (-not $hostShareReachable) {
    Fail-Hv -Message ("Host cannot reach controller share path: {0}" -f $ControllerSharePath) -LogPath $LogPath
}

$hostDirOutput = cmd.exe /c ('dir "{0}"' -f $ControllerSharePath) 2>&1 | Out-String
Set-Content -LiteralPath (Join-Path $artifactDir "host-share-check.txt") -Value $hostDirOutput

$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
try {
    $guestState = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param(
            $SharePath,
            $ControllerHost,
            $ControllerUserName,
            $ControllerPassword
        )

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

        if (-not [string]::IsNullOrWhiteSpace($ControllerHost) -and
            -not [string]::IsNullOrWhiteSpace($ControllerUserName) -and
            -not [string]::IsNullOrWhiteSpace($ControllerPassword)) {
            cmd.exe /c ("cmdkey /add:{0} /user:{1} /pass:{2}" -f $ControllerHost, $ControllerUserName, $ControllerPassword) | Out-Null
        }

        $hlkServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match 'HLK|WTT' -or
            ($_.PSObject.Properties["DisplayName"] -and $_.DisplayName -match 'Hardware Lab Kit|Windows Driver Testing')
        } | Select-Object Name, DisplayName, Status, StartType)

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            SharePath = $SharePath
            ShareReachable = [bool](Test-Path -LiteralPath $SharePath)
            DriverResidue = Get-DriverResidue
            HlkInstalledEntries = @(Get-HlkArpEntries)
            HlkServices = $hlkServices
            GuestIp = (Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
                Sort-Object InterfaceMetric |
                Select-Object -First 1 -ExpandProperty IPAddress)
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    } -ArgumentList $ControllerSharePath, $controllerHost, $ControllerUser, $ControllerPasswordPlaintext

    $guestState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "guest-hlk-preflight.json") -Encoding UTF8

    if ($guestState.DriverResidue.DriverStoreHit -or $guestState.DriverResidue.DeviceHit) {
        Fail-Hv -Message "Restored clean checkpoint still contains avshws residue during HLK preflight." -LogPath $LogPath
    }

    if (-not $guestState.ShareReachable) {
        Fail-Hv -Message ("Guest cannot reach controller share path: {0}" -f $ControllerSharePath) -LogPath $LogPath
    }

    if (@($guestState.HlkInstalledEntries).Count -lt 1) {
        Fail-Hv -Message "HLK client packages are not installed on guest." -LogPath $LogPath
    }

    $runningHlkService = @($guestState.HlkServices | Where-Object {
        ([string]$_.Name) -ieq "HLKsvc" -and ([string]$_.Status) -ieq "Running"
    })
    if ($runningHlkService.Count -lt 1) {
        Fail-Hv -Message "HLKSvc is not running on guest." -LogPath $LogPath
    }

    [pscustomobject]@{
        VmName = $VmName
        CheckpointName = $CheckpointName
        ControllerSharePath = $ControllerSharePath
        GuestIp = $guestState.GuestIp
        ArtifactDir = $artifactDir
    }
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
