[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$ArtifactRoot = "",
    [bool]$RevertAfterRun = $true,
    [string[]]$Modes = @("list", "yuy2", "nv12", "rgb32", "video2")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
. (Join-Path $scriptDir "hyperv-common.ps1")

Assert-HvAdministrator

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing .env file: $Path"
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') {
            continue
        }

        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $map[$parts[0].Trim()] = $parts[1].Trim().Trim('"')
        }
    }

    return $map
}

function New-CredentialFromEnv {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EnvMap,
        [Parameter(Mandatory = $true)][string]$UserKey,
        [Parameter(Mandatory = $true)][string]$PasswordKey
    )

    $user = [string]$EnvMap[$UserKey]
    $password = [string]$EnvMap[$PasswordKey]
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password)) {
        throw "Missing $UserKey or $PasswordKey in .env"
    }

    $secure = New-HvSecureString -PlainText $password
    return [System.Management.Automation.PSCredential]::new($user, $secure)
}

$repoRoot = Get-HvRepoRoot
$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path $repoRoot ("test-reports\driver-test-dshow-{0}" -f (Get-HvTimestamp))
} else {
    Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot
}
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "driver-test-dshow.log"

$envMap = Read-DotEnv -Path (Join-Path $repoRoot ".env")
$guestCred = New-CredentialFromEnv -EnvMap $envMap -UserKey "DRIVER_TEST_VM_USERNAME" -PasswordKey "DRIVER_TEST_VM_PASSWORD"

$probeBuildScript = Join-Path $scriptDir "build-dshow-probe.ps1"
if (-not (Test-Path -LiteralPath $probeBuildScript)) {
    throw "Missing DirectShow probe build script: $probeBuildScript"
}
& powershell.exe -ExecutionPolicy Bypass -File $probeBuildScript
if ($LASTEXITCODE -ne 0) {
    throw "DirectShow probe build failed with exit code $LASTEXITCODE."
}

$session = $null
$guestRoot = "C:\Temp\VirtuaCamDshowGate"
$guestScriptsRoot = Join-Path $guestRoot "scripts"
$guestScriptToolsRoot = Join-Path $guestScriptsRoot "tools"
$guestProbeToolsRoot = Join-Path $guestRoot "probe-tools"
$guestPackageRoot = Join-Path $guestRoot "output"
$guestSetupExe = Join-Path $guestPackageRoot "VirtuaCamSetup.exe"
$guestInstallJson = Join-Path $guestRoot "setup-install.json"
$guestProbeExe = Join-Path $guestProbeToolsRoot "dshow_probe.exe"

try {
    Write-HvLog -Message ("Restoring checkpoint '{0}' for DirectShow probe gate." -f $CheckpointName) -LogPath $logPath -Level STEP
    Stop-HvVmForRestore -VmName $VmName -LogPath $logPath
    Restore-HvCheckpoint -VmName $VmName -CheckpointName $CheckpointName -LogPath $logPath

    $ready = Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds 300 -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath
    $ready | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-readiness.json") -Encoding UTF8
    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -LogPath $logPath

    Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($Root, $ScriptsRoot, $ScriptToolsRoot, $ProbeToolsRoot)

        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Force -Path $Root, $ScriptsRoot, $ScriptToolsRoot, $ProbeToolsRoot
    } -ArgumentList $guestRoot, $guestScriptsRoot, $guestScriptToolsRoot, $guestProbeToolsRoot | Out-Null

    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "output") -GuestPath $guestRoot -Recurse -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "tools\dshow-probe\build\dshow_probe.exe") -GuestPath $guestProbeToolsRoot -LogPath $logPath

    Write-HvLog -Message "Installing staged package with VirtuaCamSetup.exe before DirectShow probes." -LogPath $logPath -Level STEP
    $install = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($SetupExe, $JsonPath)

        $stdout = Join-Path $env:TEMP ("VirtuaCamSetup-{0}.out" -f [Guid]::NewGuid().ToString("N"))
        $stderr = Join-Path $env:TEMP ("VirtuaCamSetup-{0}.err" -f [Guid]::NewGuid().ToString("N"))
        $process = Start-Process -FilePath $SetupExe -ArgumentList @("--install", "--quiet", "--json", $JsonPath) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $lines = @()
        if (Test-Path -LiteralPath $stdout) { $lines += Get-Content -LiteralPath $stdout }
        if (Test-Path -LiteralPath $stderr) { $lines += Get-Content -LiteralPath $stderr }
        $json = if (Test-Path -LiteralPath $JsonPath) { Get-Content -LiteralPath $JsonPath -Raw } else { "" }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = [string]::Join([Environment]::NewLine, @($lines | ForEach-Object { [string]$_ }))
            Json = $json
        }
    } -ArgumentList $guestSetupExe, $guestInstallJson
    $install.Output | Set-Content -LiteralPath (Join-Path $artifactDir "guest-driver-install.txt") -Encoding UTF8
    $install.Json | Set-Content -LiteralPath (Join-Path $artifactDir "guest-driver-install.json") -Encoding UTF8
    if ($install.ExitCode -ne 0) {
        throw "VirtuaCamSetup.exe install failed in guest: $($install.ExitCode)"
    }

    if ($install.Output -match '(?i)reboot is needed|reboot is required|pending system reboot|a reboot is required') {
        Write-HvLog -Message "Driver install requested reboot; restarting guest before DirectShow probe." -LogPath $logPath -Level STEP
        Restart-HvGuest -Session $session -LogPath $logPath
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
        Wait-HvVmRebootTransition -VmName $VmName -Credential $guestCred -TimeoutSeconds 90 -PollIntervalSeconds 3 -LogPath $logPath | Out-Null
        Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds 360 -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath | Out-Null
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -LogPath $logPath

        $probePresent = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
            param($ProbeExe)
            Test-Path -LiteralPath $ProbeExe
        } -ArgumentList $guestProbeExe
        if (-not [bool]$probePresent) {
            Write-HvLog -Message "Probe executable missing after reboot; copying it again." -LogPath $logPath -Level WARN
            Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
                param($ProbeToolsRoot)
                $null = New-Item -ItemType Directory -Force -Path $ProbeToolsRoot
            } -ArgumentList $guestProbeToolsRoot | Out-Null
            Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "tools\dshow-probe\build\dshow_probe.exe") -GuestPath $guestProbeToolsRoot -LogPath $logPath
        }
    }

    $results = @()
    foreach ($mode in $Modes) {
        Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
            & "$env:WINDIR\System32\taskkill.exe" /IM VirtuaCam.exe /F 2>&1 | Out-Null
            foreach ($service in @(Get-Service -Name "FrameServer", "CaptureService_*" -ErrorAction SilentlyContinue)) {
                if ($service.Status -ne "Stopped") {
                    Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
                    try { $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10)) } catch {}
                }
            }
            Start-Sleep -Milliseconds 500
        } | Out-Null

        $probe = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
            param($ProbeExe, $Mode)

            $args = @("Virtual Camera Source")
            if ($Mode -ne "list") {
                $args += $Mode
            }

            $out = & $ProbeExe @args 2>&1
            [pscustomobject]@{
                Mode = $Mode
                ExitCode = $LASTEXITCODE
                Text = [string]::Join([Environment]::NewLine, @($out | ForEach-Object { [string]$_ }))
            }
        } -ArgumentList $guestProbeExe, $mode

        $localLog = Join-Path $artifactDir ("dshow-{0}.txt" -f $mode)
        $probe.Text | Set-Content -LiteralPath $localLog -Encoding UTF8
        $text = [string]$probe.Text
        $hasVideoInfo2 = [bool]($text -match '(?i)format=VideoInfo2')
        $hasNv12 = [bool]($text -match '(?i)subtype=MEDIASUBTYPE_NV12')
        $hasYuy2 = [bool]($text -match '(?i)subtype=MEDIASUBTYPE_YUY2')
        $hasRgb32 = [bool]($text -match '(?i)subtype=MEDIASUBTYPE_RGB32')
        $hasSetFormatSuccess = [bool]($text -match '(?i)SetFormat\s+hr=0x0')
        $hasRunSuccess = [bool]($text -match '(?i)Run\s+hr=0x0')
        $isLegacyReducedSet = $hasYuy2 -and $hasRgb32 -and (-not $hasNv12) -and (-not $hasVideoInfo2)
        $results += [pscustomobject]@{
            Mode = $mode
            ExitCode = [int]$probe.ExitCode
            CapabilityCount = [regex]::Matches($text, '(?m)^\s*\[\d+\]\s+').Count
            HasVideoInfo2 = $hasVideoInfo2
            HasNv12 = $hasNv12
            HasYuy2 = $hasYuy2
            HasRgb32 = $hasRgb32
            HasProfileAwareNoProfile = [bool]($text -match '(?i)SetProfileAwareNoProfile\((source|pin)\)\s+hr=0x0')
            HasLegacyReducedSet = $isLegacyReducedSet
            HasSetFormatSuccess = $hasSetFormatSuccess
            HasRunSuccess = $hasRunSuccess
            Log = $localLog
        }
    }

    $results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactDir "summary.json") -Encoding UTF8
    $bad = @($results | Where-Object {
        $expectedLegacyReduction = (
            ($_.Mode -eq "nv12" -or $_.Mode -eq "video2") -and
            $_.HasLegacyReducedSet -and
            $_.HasRunSuccess
        )
        $_.ExitCode -ne 0 -or
        $_.CapabilityCount -lt 1 -or
        ((-not $expectedLegacyReduction) -and (($_.Mode -ne "list") -and (-not $_.HasSetFormatSuccess -or -not $_.HasRunSuccess)))
    })
    if ($bad.Count -gt 0) {
        $bad | Format-List | Out-String | Set-Content -LiteralPath (Join-Path $artifactDir "failures.txt") -Encoding UTF8
        throw "DirectShow probe gate failed. See $artifactDir"
    }

    $results | Format-Table -AutoSize
    Write-Host ("Artifacts: {0}" -f $artifactDir)
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }

    if ($RevertAfterRun) {
        Stop-HvVmForRestore -VmName $VmName -LogPath $logPath
        Restore-HvCheckpoint -VmName $VmName -CheckpointName $CheckpointName -LogPath $logPath
    }
}
