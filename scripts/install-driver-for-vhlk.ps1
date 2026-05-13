[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$ArtifactRoot = "",
    [string]$GuestRoot = ""
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

try {
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

    Write-HvLog -Message "Installing staged package in DUT for vHLK." -LogPath $logPath -Level STEP
    $install = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($InstallScript)
        $lines = & powershell.exe -ExecutionPolicy Bypass -File $InstallScript 2>&1
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
    }

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
