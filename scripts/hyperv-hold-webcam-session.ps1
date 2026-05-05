[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$GuestUser = "Administrator",
    [string]$GuestPasswordPlaintext = "",
    [string]$GuestPackageRoot = "C:\Temp\VirtuaCamHyperV\manual\package-repro",
    [string]$GuestWebcamHtml = "C:\Temp\VirtuaCamHyperV\manual\webcam.html",
    [ValidateSet("Chrome", "Edge")][string]$Browser = "Chrome",
    [ValidateSet("Notepad", "Settings", "Explorer", "ProofPanel")][string]$SourceWindowMode = "Notepad",
    [ValidateSet("auto", "printwindow", "wgc", "bitblt")][string]$CaptureBackend = "auto",
    [string[]]$BrowserExtraArgs = @(),
    [switch]$SkipBrowser,
    [string]$AttemptId = "manual",
    [switch]$ServeHttp,
    [int]$HttpPort = 8000,
    [string]$HostStatusPath = "",
    [string]$HostStopSignalPath = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-StatusFile {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$StatusObject
    )

    $StatusObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $HostStatusPath -Encoding UTF8
}

function Join-TextOutput {
    param([object[]]$InputObject)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }
        $lines.Add([string]$item.ToString())
    }

    return [string]::Join([System.Environment]::NewLine, $lines.ToArray())
}

if ([string]::IsNullOrWhiteSpace($HostStatusPath)) {
    $HostStatusPath = Resolve-HvPath -Path "test-reports\playwright\vm-session-status.json"
}
if ([string]::IsNullOrWhiteSpace($HostStopSignalPath)) {
    $HostStopSignalPath = Resolve-HvPath -Path "test-reports\playwright\vm-session-stop.signal"
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Resolve-HvPath -Path "test-reports\playwright\vm-session-host.log"
}

$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HostStatusPath), (Split-Path -Parent $HostStopSignalPath), (Split-Path -Parent $LogPath)
Remove-Item -LiteralPath $HostStatusPath, $HostStopSignalPath -Force -ErrorAction SilentlyContinue

$guestRunnerLocalPath = Resolve-HvPath -Path "scripts\guest-held-webcam-session.ps1"
if (-not (Test-Path -LiteralPath $guestRunnerLocalPath)) {
    throw "Guest held-session runner not found: $guestRunnerLocalPath"
}
$guestHelperLocalPaths = @(
    $guestRunnerLocalPath,
    (Resolve-HvPath -Path "scripts\show-proof-panel.ps1"),
    (Resolve-HvPath -Path "scripts\serve-webcam.ps1")
)
foreach ($helperPath in $guestHelperLocalPaths) {
    if (-not (Test-Path -LiteralPath $helperPath)) {
        throw "Guest helper script not found: $helperPath"
    }
}

$guestCred = Get-HvGuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$session = $null

try {
    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath

    $guestLaunch = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($PackageRoot, $AttemptValue)

        $root = Split-Path -Parent $PackageRoot
        $scriptsRoot = Join-Path $root "scripts"
        $statusPath = Join-Path $root "guest-session-status.json"
        $configPath = Join-Path $root "guest-held-webcam-session.json"
        $launcherPath = Join-Path $scriptsRoot "launch-held-webcam-session.ps1"
        $runnerPath = Join-Path $scriptsRoot "guest-held-webcam-session.ps1"
        $taskName = "VirtuaCamHeldSession-" + (($AttemptValue -replace '[^A-Za-z0-9._-]', '-') -replace '^-+', '')

        $null = New-Item -ItemType Directory -Force -Path $root, $scriptsRoot
        Remove-Item -LiteralPath $statusPath, $configPath, $launcherPath -Force -ErrorAction SilentlyContinue

        [pscustomobject]@{
            Root = $root
            ScriptsRoot = $scriptsRoot
            StatusPath = $statusPath
            ConfigPath = $configPath
            LauncherPath = $launcherPath
            RunnerPath = $runnerPath
            TaskName = $taskName
        }
    } -ArgumentList $GuestPackageRoot, $AttemptId

    foreach ($helperPath in $guestHelperLocalPaths) {
        Copy-HvToGuest -Session $session -LocalPath $helperPath -GuestPath $guestLaunch.ScriptsRoot -LogPath $LogPath
    }

    $launchResult = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param(
            $ConfigPath,
            $LauncherPath,
            $RunnerPath,
            $TaskName,
            $PackageRoot,
            $HtmlPath,
            $BrowserName,
            $RequestedSourceWindowMode,
            $RequestedCaptureBackend,
            $ShouldServeHttp,
            $RequestedHttpPort,
            $RequestedBrowserExtraArgs,
            $RequestedSkipBrowser,
            $RequestedAttemptId,
            $RequestedGuestStatusPath,
            $TaskUser,
            $TaskPassword
        )

        function Join-GuestTextOutput {
            param([object[]]$InputObject)

            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($item in @($InputObject)) {
                if ($null -eq $item) {
                    continue
                }
                $lines.Add([string]$item.ToString())
            }

            return [string]::Join([System.Environment]::NewLine, $lines.ToArray())
        }

        $config = [ordered]@{
            PackageRoot = $PackageRoot
            HtmlPath = $HtmlPath
            Browser = $BrowserName
            SourceWindowMode = $RequestedSourceWindowMode
            CaptureBackend = $RequestedCaptureBackend
            ServeHttp = [bool]$ShouldServeHttp
            HttpPort = [int]$RequestedHttpPort
            BrowserExtraArgs = @($RequestedBrowserExtraArgs)
            LaunchBrowser = -not [bool]$RequestedSkipBrowser
            AttemptId = $RequestedAttemptId
            GuestStatusPath = $RequestedGuestStatusPath
        }
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

        $escapedRunnerPath = $RunnerPath -replace "'", "''"
        $escapedConfigPath = $ConfigPath -replace "'", "''"
        $launcherText = "& '$escapedRunnerPath' -ConfigPath '$escapedConfigPath'"
        Set-Content -LiteralPath $LauncherPath -Encoding ASCII -Value $launcherText

        schtasks /delete /tn $TaskName /f 2>$null | Out-Null
        $startTime = (Get-Date).AddMinutes(1).ToString("HH:mm")
        $taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $LauncherPath + '"'
        $createOutput = Join-GuestTextOutput @(schtasks /create /tn $TaskName /sc once /st $startTime /tr $taskCommand /ru $TaskUser /rp $TaskPassword /rl HIGHEST /it /f 2>&1)
        $runOutput = Join-GuestTextOutput @(schtasks /run /tn $TaskName 2>&1)

        [pscustomobject]@{
            TaskName = $TaskName
            TaskCommand = $taskCommand
            CreateOutput = $createOutput
            RunOutput = $runOutput
        }
    } -ArgumentList `
        $guestLaunch.ConfigPath,
        $guestLaunch.LauncherPath,
        $guestLaunch.RunnerPath,
        $guestLaunch.TaskName,
        $GuestPackageRoot,
        $GuestWebcamHtml,
        $Browser,
        $SourceWindowMode,
        $CaptureBackend,
        $ServeHttp,
        $HttpPort,
        $BrowserExtraArgs,
        $SkipBrowser,
        $AttemptId,
        $guestLaunch.StatusPath,
        $GuestUser,
        $GuestPasswordPlaintext

    $guestState = $null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        $guestState = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            param($GuestStatusPath)
            if (-not (Test-Path -LiteralPath $GuestStatusPath)) {
                return $null
            }

            Get-Content -LiteralPath $GuestStatusPath -Raw | ConvertFrom-Json
        } -ArgumentList $guestLaunch.StatusPath

        if ($guestState) {
            if ($guestState.Ready) {
                break
            }
            if ($guestState.LaunchError) {
                throw [string]$guestState.LaunchError
            }
        }

        Start-Sleep -Seconds 2
    }

    if (-not $guestState -or -not $guestState.Ready) {
        $taskQuery = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            param($TaskName)

            function Join-GuestTextOutput {
                param([object[]]$InputObject)

                $lines = New-Object System.Collections.Generic.List[string]
                foreach ($item in @($InputObject)) {
                    if ($null -eq $item) {
                        continue
                    }
                    $lines.Add([string]$item.ToString())
                }

                return [string]::Join([System.Environment]::NewLine, $lines.ToArray())
            }

            Join-GuestTextOutput @(schtasks /query /tn $TaskName /v /fo list 2>&1)
        } -ArgumentList $guestLaunch.TaskName
        throw ("Timed out waiting for held guest session status. Task={0}`nCreate={1}`nRun={2}`nQuery={3}" -f $launchResult.TaskName, $launchResult.CreateOutput.Trim(), $launchResult.RunOutput.Trim(), $taskQuery.Trim())
    }

    $hostState = [ordered]@{}
    foreach ($property in $guestState.PSObject.Properties) {
        $hostState[$property.Name] = $property.Value
    }
    $hostState.HostHoldPid = $PID
    $hostState.HostHeartbeatUtc = [DateTime]::UtcNow.ToString("o")
    $hostState.GuestHeartbeatUtc = $hostState.GuestSessionTimestampUtc
    $hostState.GuestLivenessError = ""
    Write-StatusFile -StatusObject ([pscustomobject]$hostState)

    Write-HvLog -Message ("Guest session held. Status file: {0}" -f $HostStatusPath) -LogPath $LogPath -Level STEP

    $lastProbe = Get-Date
    while (-not (Test-Path -LiteralPath $HostStopSignalPath)) {
        $hostState.HostHeartbeatUtc = [DateTime]::UtcNow.ToString("o")

        if (((Get-Date) - $lastProbe).TotalSeconds -ge 5) {
            try {
                $probe = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
                    param($RequestedBrowser)
                    $browserProcessName = if ($RequestedBrowser -eq "Edge") { "msedge" } else { "chrome" }
                    [pscustomobject]@{
                        Utc = [DateTime]::UtcNow.ToString("o")
                        BrowserAlive = [bool](Get-Process -Name $browserProcessName -ErrorAction SilentlyContinue)
                        VirtuaCamAlive = [bool](Get-Process -Name "VirtuaCam" -ErrorAction SilentlyContinue)
                        VirtuaCamProcessAlive = [bool](Get-Process -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue)
                    }
                } -ArgumentList $Browser
                $hostState.GuestSessionAlive = $true
                $hostState.GuestHeartbeatUtc = $probe.Utc
                $hostState.BrowserAlive = $probe.BrowserAlive
                $hostState.VirtuaCamAlive = $probe.VirtuaCamAlive
                $hostState.VirtuaCamProcessAlive = $probe.VirtuaCamProcessAlive
                $hostState.GuestLivenessError = ""
            }
            catch {
                $hostState.GuestSessionAlive = $false
                $hostState.GuestLivenessError = $_.Exception.Message
                Write-StatusFile -StatusObject ([pscustomobject]$hostState)
                throw
            }
            $lastProbe = Get-Date
        }

        Write-StatusFile -StatusObject ([pscustomobject]$hostState)
        Start-Sleep -Seconds 1
    }
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
