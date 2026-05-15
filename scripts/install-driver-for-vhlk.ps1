[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$ArtifactRoot = "",
    [string]$GuestRoot = "",
    [switch]$SkipFreshStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path $repoRoot ("test-reports\vhlk-dut-install-{0}" -f (Get-HvTimestamp))
} else {
    Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot
}
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "install-driver-for-vhlk.log"
if ([string]::IsNullOrWhiteSpace($GuestRoot)) {
    $GuestRoot = "C:\Temp\VirtuaCamVhlkInstall-{0}" -f (Get-HvTimestamp)
}

$envMap = Read-HvDotEnv
$guestCred = Get-HvGuestCredential `
    -GuestUser "Administrator" `
    -EnvUserKey "DRIVER_TEST_VM_USERNAME" `
    -EnvPasswordKey "DRIVER_TEST_VM_PASSWORD"

$session = $null
$guestScriptsRoot = Join-Path $GuestRoot "scripts"
$guestToolsRoot = Join-Path $guestScriptsRoot "tools"
$guestInstallAll = Join-Path $guestScriptsRoot "install-all.ps1"

function Set-VhlkCameraDirectMode {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$GuestSession,
        [Parameter(Mandatory = $true)][string]$OutputName
    )

    $state = Invoke-HvGuestCommand -Session $GuestSession -LogPath $logPath -ScriptBlock {
        $registrySpecs = @(
            [pscustomobject]@{
                Path = "HKLM:\SOFTWARE\Microsoft\Windows Media Foundation\Platform"
                View = [Microsoft.Win32.RegistryView]::Registry64
                SubKey = "SOFTWARE\Microsoft\Windows Media Foundation\Platform"
            },
            [pscustomobject]@{
                Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Media Foundation\Platform"
                View = [Microsoft.Win32.RegistryView]::Registry32
                SubKey = "SOFTWARE\Microsoft\Windows Media Foundation\Platform"
            }
        )

        $registryState = foreach ($spec in $registrySpecs) {
            $baseKey = $null
            $key = $null
            try {
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $spec.View)
                $key = $baseKey.CreateSubKey($spec.SubKey, $true)
                if (-not $key) {
                    throw "Failed to open registry subkey: $($spec.Path)"
                }
                $key.SetValue("EnableFrameServerMode", 0, [Microsoft.Win32.RegistryValueKind]::DWord)
                $value = $key.GetValue("EnableFrameServerMode", $null)
                [pscustomobject]@{
                    Path = $spec.Path
                    RegistryView = [string]$spec.View
                    EnableFrameServerMode = [int]$value
                }
            }
            finally {
                if ($key) {
                    $key.Close()
                }
                if ($baseKey) {
                    $baseKey.Close()
                }
            }
        }

        $serviceState = foreach ($service in @(Get-Service -Name "FrameServer", "CaptureService_*" -ErrorAction SilentlyContinue)) {
            if ($service.Status -ne "Stopped") {
                try {
                    Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
                    $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10))
                }
                catch {
                }
            }
            $current = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Name = $service.Name
                DisplayName = $service.DisplayName
                Status = if ($current) { [string]$current.Status } else { "Missing" }
                StartType = if ($current) { [string]$current.StartType } else { "" }
            }
        }

        [pscustomobject]@{
            Registry = @($registryState)
            Services = @($serviceState)
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    }

    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir $OutputName) -Encoding UTF8
    return $state
}

try {
    if (-not $SkipFreshStart) {
        Write-HvLog -Message ("Fresh-starting DUT '{0}' from checkpoint '{1}' before vHLK install." -f $VmName, $CheckpointName) -LogPath $logPath -Level STEP
        $freshStart = Start-HvFreshCheckpointVm `
            -VmName $VmName `
            -CheckpointName $CheckpointName `
            -Credential $guestCred `
            -RequireInteractiveSession `
            -ReadyTimeoutSeconds 420 `
            -LogPath $logPath
        $freshStart | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-fresh-start.json") -Encoding UTF8
    }

    Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds 300 -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath | Out-Null
    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 180 -LogPath $logPath

    Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($Root, $ScriptsRoot, $ToolsRoot)
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Force -Path $Root, $ScriptsRoot, $ToolsRoot
    } -ArgumentList $GuestRoot, $guestScriptsRoot, $guestToolsRoot | Out-Null

    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "output") -GuestPath $GuestRoot -Recurse -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "scripts\install-all.ps1") -GuestPath $guestScriptsRoot -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "scripts\tools\artifact-manifest.ps1") -GuestPath $guestToolsRoot -LogPath $logPath

    Write-HvLog -Message "Configuring Media Foundation camera direct mode for vHLK." -LogPath $logPath -Level STEP
    Set-VhlkCameraDirectMode -GuestSession $session -OutputName "camera-frame-server-mode-before-install.json" | Out-Null

    Write-HvLog -Message "Installing staged package in DUT for vHLK." -LogPath $logPath -Level STEP
    $install = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($InstallScript)
        $lines = & powershell.exe -ExecutionPolicy Bypass -File $InstallScript -SkipWatcherService 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]::Join([Environment]::NewLine, @($lines | ForEach-Object { [string]$_ }))
        }
    } -ArgumentList $guestInstallAll
    $install.Output | Set-Content -LiteralPath (Join-Path $artifactDir "guest-driver-install.txt") -Encoding UTF8
    if ($install.ExitCode -ne 0) {
        throw "install-all failed in guest: $($install.ExitCode)"
    }

    if ($install.Output -match '(?i)reboot is needed|reboot is required|pending system reboot|a reboot is required') {
        Write-HvLog -Message "Driver install requested reboot; restarting DUT before vHLK." -LogPath $logPath -Level STEP
        Restart-HvGuest -Session $session -LogPath $logPath
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
        Wait-HvVmRebootTransition -VmName $VmName -Credential $guestCred -TimeoutSeconds 120 -PollIntervalSeconds 3 -LogPath $logPath | Out-Null
        Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds 360 -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath | Out-Null
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 180 -LogPath $logPath
    } else {
        Write-HvLog -Message "Restarting DUT to apply vHLK camera direct mode." -LogPath $logPath -Level STEP
        Restart-HvGuest -Session $session -LogPath $logPath
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
        Wait-HvVmRebootTransition -VmName $VmName -Credential $guestCred -TimeoutSeconds 120 -PollIntervalSeconds 3 -LogPath $logPath | Out-Null
        Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds 360 -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath | Out-Null
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 180 -LogPath $logPath
    }

    Set-VhlkCameraDirectMode -GuestSession $session -OutputName "camera-frame-server-mode.json" | Out-Null

    $state = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        $devices = @(pnputil /enum-devices /instanceid ROOT\AVSHWS\0000 2>&1 | ForEach-Object { [string]$_ })
        $drivers = @(pnputil /enum-drivers 2>&1 | Where-Object { $_ -match 'avshws|Virtual Camera' } | ForEach-Object { [string]$_ })
        [pscustomobject]@{
            Devices = $devices
            Drivers = $drivers
            DevicePresent = [bool]($devices -match 'ROOT\\AVSHWS\\0000')
            DriverPackagePresent = [bool]($drivers -match 'avshws')
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactDir "dut-driver-state.json") -Encoding UTF8
    if (-not $state.DevicePresent -or -not $state.DriverPackagePresent) {
        throw "DUT driver install verification failed. See $artifactDir"
    }

    Write-Host ("DUT driver installed for vHLK. Artifacts: {0}" -f $artifactDir)
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
