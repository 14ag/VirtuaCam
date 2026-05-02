[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall")][string]$Action = "Install",
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [switch]$RestoreCleanFirst,
    [switch]$RefreshCleanCheckpoint,
    [switch]$RefreshCleanEnableSsh,
    [ValidateSet("Password", "PasswordAndKey")][string]$RefreshCleanSshAuthMode = "Password",
    [string]$RefreshCleanSshHostPublicKeyPath = "",
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

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { Get-HvArtifactDirectory -ArtifactRoot "output\hyperv-hlk-client" } else { Resolve-HvPath -Path $ArtifactRoot }
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-hlk-client.log"
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext

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

Write-HvLog -Message ("HLK client action '{0}' for VM '{1}' using share '{2}'" -f $Action, $VmName, $ControllerSharePath) -LogPath $LogPath -Level STEP

if ($RestoreCleanFirst) {
    Write-HvLog -Message ("Restoring checkpoint '{0}' before HLK client action." -f $CheckpointName) -LogPath $LogPath -Level STEP
    $checkpoint = Get-VMSnapshot -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue
    if (-not $checkpoint) {
        Fail-Hv -Message ("Checkpoint '{0}' was not found." -f $CheckpointName) -LogPath $LogPath
    }

    try {
        $vmState = (Get-VM -Name $VmName -ErrorAction Stop).State
        if ($vmState -ne "Off") {
            Stop-VM -Name $VmName -TurnOff -Force -Confirm:$false | Out-Null
        }
    }
    catch {
        Write-HvLog -Message ("VM stop before restore skipped: {0}" -f $_.Exception.Message) -LogPath $LogPath -Level WARN
    }

    Restore-VMCheckpoint -VMName $VmName -Name $CheckpointName -Confirm:$false | Out-Null
}

$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
try {
    $shareProbe = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param(
            $SharePath,
            $ControllerHost,
            $ControllerUserName,
            $ControllerPassword,
            $RequestedAction
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

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

        $beforeResidue = Get-DriverResidue
        if ($beforeResidue.DriverStoreHit -or $beforeResidue.DeviceHit) {
            throw "Guest is not clean. avshws is still present before HLK client action."
        }

        if (-not [string]::IsNullOrWhiteSpace($ControllerHost) -and
            -not [string]::IsNullOrWhiteSpace($ControllerUserName) -and
            -not [string]::IsNullOrWhiteSpace($ControllerPassword)) {
            cmd.exe /c ("cmdkey /add:{0} /user:{1} /pass:{2}" -f $ControllerHost, $ControllerUserName, $ControllerPassword) | Out-Null
        }

        $shareExists = Test-Path -LiteralPath $SharePath
        if (-not $shareExists) {
            throw ("HLK client setup path not reachable from guest: {0}" -f $SharePath)
        }

        $quotedSetup = '"' + $SharePath + '"'
        $arguments = if ($RequestedAction -eq "Install") {
            "/qn ICFAGREE=Yes"
        } else {
            "/qn /uninstall"
        }

        $commandLine = "{0} {1}" -f $quotedSetup, $arguments
        $output = cmd.exe /c $commandLine 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $afterResidue = Get-DriverResidue

        [pscustomobject]@{
            Action          = $RequestedAction
            SharePath       = $SharePath
            ShareReachable  = $shareExists
            CommandLine     = $commandLine
            Output          = $output
            ExitCode        = $exitCode
            InstalledEntries = @(Get-HlkArpEntries)
            HlkServices     = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match 'HLK|WTT' -or
                ($_.PSObject.Properties["DisplayName"] -and $_.DisplayName -match 'Hardware Lab Kit|Windows Driver Testing')
            } | Select-Object Name, DisplayName, Status, StartType)
            DriverResidueBefore = $beforeResidue
            DriverResidueAfter  = $afterResidue
            CheckedAtUtc     = [DateTime]::UtcNow.ToString("o")
        }
    } -ArgumentList $ControllerSharePath, $controllerHost, $ControllerUser, $ControllerPasswordPlaintext, $Action

    $shareProbe | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "guest-hlk-client.json")
    Set-Content -LiteralPath (Join-Path $artifactDir "guest-hlk-client-output.txt") -Value $shareProbe.Output

    if ($shareProbe.ExitCode -ne 0) {
        Fail-Hv -Message ("HLK client action failed with exit code {0}. See {1}" -f $shareProbe.ExitCode, (Join-Path $artifactDir "guest-hlk-client-output.txt")) -LogPath $LogPath
    }
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

if ($RefreshCleanCheckpoint) {
    Write-HvLog -Message ("Refreshing checkpoint '{0}' after HLK client action." -f $CheckpointName) -LogPath $LogPath -Level STEP
    $refreshArgs = @{
        VmName = $VmName
        CheckpointName = $CheckpointName
        GuestCredential = $guestCred
        ForceRefresh = $true
        ArtifactRoot = (Join-Path $artifactDir "refresh-clean")
        LogPath = (Join-Path $artifactDir "refresh-clean.log")
    }

    if ($RefreshCleanEnableSsh) {
        $refreshArgs.EnableSsh = $true
        $refreshArgs.SshAuthMode = $RefreshCleanSshAuthMode
        if (-not [string]::IsNullOrWhiteSpace($RefreshCleanSshHostPublicKeyPath)) {
            $refreshArgs.SshHostPublicKeyPath = $RefreshCleanSshHostPublicKeyPath
        }
    }

    & (Join-Path $PSScriptRoot "hyperv-clean-checkpoint.ps1") @refreshArgs | Out-Null
}

[pscustomobject]@{
    VmName         = $VmName
    Action         = $Action
    ControllerPath = $ControllerSharePath
    ArtifactDir    = $artifactDir
    RefreshedClean = [bool]$RefreshCleanCheckpoint
}
