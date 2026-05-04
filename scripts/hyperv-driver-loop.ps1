[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [switch]$EnableVerifier,
    [switch]$EnableKernelDebug,
    [ValidateSet("None", "VirtuaCam", "CameraApp", "WebcamHtml")][string]$ReproMode = "CameraApp",
    [ValidateSet("Chrome", "Edge")][string]$Browser = "Chrome",
    [string]$ArtifactRoot = "",
    [string]$PipeName = "",
    [ValidateSet("kd", "windbg")][string]$Debugger = "kd",
    [switch]$SkipDebuggerLaunch,
    [int]$ReproWaitSeconds = 45,
    [bool]$RevertAfterRun = $true,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

if (-not $PSBoundParameters.ContainsKey("EnableVerifier")) {
    $EnableVerifier = $false
}
if (-not $PSBoundParameters.ContainsKey("EnableKernelDebug")) {
    $EnableKernelDebug = $false
}

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { Get-HvArtifactDirectory } else { Resolve-HvPath -Path $ArtifactRoot }
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-driver-loop.log"
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$repoRoot = Get-HvRepoRoot
$driverPackageRootPath = Resolve-HvPath -Path "output" -BasePath $repoRoot
$installAllScript = Resolve-HvPath -Path "scripts\install-all.ps1" -BasePath $repoRoot
$artifactManifestScript = Resolve-HvPath -Path "scripts\tools\artifact-manifest.ps1" -BasePath $repoRoot
$webcamHtml = Resolve-HvPath -Path "software-project\webcam.html" -BasePath $repoRoot
$runId = Get-HvTimestamp
$guestRoot = "C:\Temp\VirtuaCamHyperV\run-$runId"
$guestPackageRoot = Join-Path $guestRoot (Split-Path -Path $driverPackageRootPath -Leaf)
$guestScriptsRoot = Join-Path $guestRoot "scripts"
$guestToolsRoot = Join-Path $guestScriptsRoot "tools"
$guestInstallAll = Join-Path $guestScriptsRoot "install-all.ps1"
$guestWebcamHtml = Join-Path $guestRoot "webcam.html"
$debuggerLogPath = ""
$reproFailureMessage = ""

Write-HvLog -Message ("Hyper-V driver loop start for '{0}'" -f $VmName) -LogPath $LogPath -Level STEP
Write-HvLog -Message ("ArtifactDir: {0}" -f $artifactDir) -LogPath $LogPath
Write-HvLog -Message ("PackageRoot: {0}" -f $driverPackageRootPath) -LogPath $LogPath
Write-HvLog -Message ("CheckpointName: {0}" -f $CheckpointName) -LogPath $LogPath

if (-not (Test-Path -LiteralPath $driverPackageRootPath)) {
    Fail-Hv -Message "Driver package root not found: $driverPackageRootPath" -LogPath $LogPath
}

if (-not (Test-Path -LiteralPath (Join-Path $driverPackageRootPath "avshws.inf"))) {
    Fail-Hv -Message "Missing avshws.inf in package root: $driverPackageRootPath" -LogPath $LogPath
}

try {
    Write-HvLog -Message ("Restoring clean checkpoint '{0}' before run" -f $CheckpointName) -LogPath $LogPath -Level STEP
    $existingCheckpoint = Get-VMSnapshot -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue
    if (-not $existingCheckpoint) {
        Fail-Hv -Message ("Checkpoint '{0}' was not found. Create the clean bench first." -f $CheckpointName) -LogPath $LogPath
    }

    try {
        $vmState = (Get-VM -Name $VmName -ErrorAction Stop).State
        if ($vmState -ne "Off") {
            Stop-VM -Name $VmName -TurnOff -Force -Confirm:$false | Out-Null
        }
    }
    catch {
        Write-HvLog -Message ("Pre-restore VM stop skipped: {0}" -f $_.Exception.Message) -LogPath $LogPath -Level WARN
    }

    Restore-VMCheckpoint -VMName $VmName -Name $CheckpointName -Confirm:$false | Out-Null

    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
    try {
        Write-HvLog -Message "Guest baseline checks." -LogPath $LogPath -Level STEP
        $baseline = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            $bcd = & "$env:WINDIR\System32\bcdedit.exe" /enum "{current}" 2>&1 | Out-String
            $testSigningOn = $bcd -match '(?im)^\s*testsigning\s+Yes\b'
            if (-not $testSigningOn) {
                throw "TESTSIGNING is OFF inside guest."
            }

            $crashKey = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
            $props = Get-ItemProperty $crashKey
            if ($props.CrashDumpEnabled -notin @(2, 3)) {
                Set-ItemProperty -Path $crashKey -Name CrashDumpEnabled -Value 3
            }

            $miniDir = $props.MinidumpDir
            if ([string]::IsNullOrWhiteSpace($miniDir)) {
                $miniDir = "%SystemRoot%\Minidump"
                Set-ItemProperty -Path $crashKey -Name MinidumpDir -Value $miniDir
            }

            $miniPath = [Environment]::ExpandEnvironmentVariables($miniDir)
            $null = New-Item -ItemType Directory -Force -Path $miniPath

            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                TestSigning  = $true
                CrashDump    = (Get-ItemProperty $crashKey).CrashDumpEnabled
                MinidumpDir  = (Get-ItemProperty $crashKey).MinidumpDir
            }
        }

        $baseline | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifactDir "guest-baseline.json")

        Write-HvLog -Message "Preparing guest staging folders." -LogPath $LogPath -Level STEP
        Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            param($Root, $ScriptsRoot, $ToolsRoot)
            if (Test-Path -LiteralPath $Root) {
                Remove-Item -LiteralPath $Root -Recurse -Force
            }
            $null = New-Item -ItemType Directory -Force -Path $Root, $ScriptsRoot, $ToolsRoot
            $outputRoot = Join-Path $Root "output"
            if (Test-Path -LiteralPath $outputRoot) {
                Remove-Item -LiteralPath $outputRoot -Recurse -Force
            }
            $null = New-Item -ItemType Directory -Force -Path $outputRoot
        } -ArgumentList $guestRoot, $guestScriptsRoot, $guestToolsRoot | Out-Null

        Copy-HvToGuest -Session $session -LocalPath $driverPackageRootPath -GuestPath $guestRoot -Recurse -LogPath $LogPath
        Copy-HvToGuest -Session $session -LocalPath $installAllScript -GuestPath $guestScriptsRoot -LogPath $LogPath
        Copy-HvToGuest -Session $session -LocalPath $artifactManifestScript -GuestPath $guestToolsRoot -LogPath $LogPath
        if (Test-Path -LiteralPath $webcamHtml) {
            Copy-HvToGuest -Session $session -LocalPath $webcamHtml -GuestPath $guestRoot -LogPath $LogPath
        }

        Write-HvLog -Message "Installing/rebinding driver inside guest." -LogPath $LogPath -Level STEP
        $installResult = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            param($InstallScript)
            $output = & powershell.exe -ExecutionPolicy Bypass -File $InstallScript 2>&1 | Out-String
            [pscustomobject]@{
                Output   = $output
                ExitCode = $LASTEXITCODE
            }
        } -ArgumentList $guestInstallAll
        Set-Content -LiteralPath (Join-Path $artifactDir "guest-driver-install.txt") -Value $installResult.Output
        if ($installResult.ExitCode -ne 0) {
            Fail-Hv -Message ("Guest driver install failed with exit code {0}. See {1}" -f $installResult.ExitCode, (Join-Path $artifactDir "guest-driver-install.txt")) -LogPath $LogPath
        }

        $installNeedsReboot = $installResult.Output -match '(?i)reboot is needed|reboot is required|pending system reboot'
        if ($installNeedsReboot) {
            Write-HvLog -Message "Driver install requested reboot; restarting guest before repro." -LogPath $LogPath -Level STEP
            Restart-HvGuest -Session $session -LogPath $LogPath
            $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -LogPath $LogPath
        }

        if ($EnableVerifier) {
            Write-HvLog -Message "Enabling Driver Verifier for avshws.sys and ks.sys." -LogPath $LogPath -Level STEP
            $verifierPre = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
                verifier /reset 2>&1 | Out-Null
                verifier /standard /driver avshws.sys ks.sys 2>&1 | Out-String
            }
            Set-Content -LiteralPath (Join-Path $artifactDir "verifier-enable.txt") -Value $verifierPre
        }

        if ($EnableKernelDebug) {
            Write-HvLog -Message "Configuring Hyper-V kernel debugger." -LogPath $LogPath -Level STEP
            $kdResult = & (Join-Path $PSScriptRoot "hyperv-kd.ps1") `
                -VmName $VmName `
                -PipeName $PipeName `
                -Debugger $Debugger `
                -GuestCredential $guestCred `
                -SkipDebuggerLaunch:$SkipDebuggerLaunch `
                -ArtifactRoot $artifactDir `
                -LogPath (Join-Path $artifactDir "hyperv-kd.log")

            if (-not $SkipDebuggerLaunch) {
                $debuggerLogPath = $kdResult.DebuggerLogPath
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
        }

        Restart-HvGuest -Session $session -LogPath $LogPath
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -LogPath $LogPath

        $postBootVerifier = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            verifier /querysettings 2>&1 | Out-String
        }
        Set-Content -LiteralPath (Join-Path $artifactDir "verifier-postboot.txt") -Value $postBootVerifier

        Write-HvLog -Message ("Launching guest repro mode: {0}" -f $ReproMode) -LogPath $LogPath -Level STEP
        try {
            $reproInfo = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
                param($PackageRoot, $Mode, $WaitSeconds, $HtmlPath, $Browser)

                $exe = Join-Path $PackageRoot "VirtuaCam.exe"
                $proc = Join-Path $PackageRoot "VirtuaCamProcess.exe"
                $chrome = Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"
                $edge = Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"
                $browserExe = if ($Browser -eq "Chrome" -and (Test-Path -LiteralPath $chrome)) { $chrome } elseif (Test-Path -LiteralPath $edge) { $edge } else { $chrome }

                Get-Process -Name "VirtuaCam", "VirtuaCamProcess", "WindowsCamera", "chrome", "msedge" -ErrorAction SilentlyContinue |
                    Stop-Process -Force -ErrorAction SilentlyContinue

                if (Test-Path -LiteralPath $proc) {
                    Start-Process -FilePath $proc -ArgumentList "-debug" -WindowStyle Hidden | Out-Null
                }

                if (Test-Path -LiteralPath $exe) {
                    Start-Process -FilePath $exe -ArgumentList "/startup -debug" | Out-Null
                }

                switch ($Mode) {
                    "CameraApp" {
                        Start-Process "microsoft.windows.camera:" | Out-Null
                    }
                    "WebcamHtml" {
                        if (Test-Path -LiteralPath $browserExe) {
                            Start-Process -FilePath $browserExe -ArgumentList @("--new-window", $HtmlPath) | Out-Null
                        } elseif (Test-Path -LiteralPath $HtmlPath) {
                            Start-Process -FilePath $HtmlPath | Out-Null
                        }
                    }
                    "VirtuaCam" {
                    }
                    "None" {
                    }
                }

                Start-Sleep -Seconds $WaitSeconds

                [pscustomobject]@{
                    Mode           = $Mode
                    Browser        = $Browser
                    VirtuaCamAlive = [bool](Get-Process -Name "VirtuaCam" -ErrorAction SilentlyContinue)
                    ProcessAlive   = [bool](Get-Process -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue)
                }
            } -ArgumentList $guestPackageRoot, $ReproMode, $ReproWaitSeconds, $guestWebcamHtml, $Browser
            $reproInfo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $artifactDir "repro-result.json")
        }
        catch {
            $reproFailureMessage = $_.Exception.Message
            Set-Content -LiteralPath (Join-Path $artifactDir "repro-error.txt") -Value $reproFailureMessage
            Write-HvLog -Message ("Guest repro interrupted: {0}" -f $reproFailureMessage) -LogPath $LogPath -Level WARN
        }

        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
    }
    finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }

    Write-HvLog -Message "Collecting guest artifacts back to host." -LogPath $LogPath -Level STEP
    & (Join-Path $PSScriptRoot "hyperv-collect.ps1") `
        -VmName $VmName `
        -GuestCredential $guestCred `
        -GuestPackageRoot $guestPackageRoot `
        -ArtifactRoot $artifactDir `
        -HostDebuggerLogPath $debuggerLogPath `
        -LogPath (Join-Path $artifactDir "hyperv-collect.log") | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($reproFailureMessage)) {
        Fail-Hv -Message ("Guest repro failed or guest restarted unexpectedly. Artifacts: {0}. Error: {1}" -f $artifactDir, $reproFailureMessage) -LogPath $LogPath
    }
}
finally {
    if ($RevertAfterRun) {
        Write-HvLog -Message ("Restoring checkpoint '{0}'" -f $CheckpointName) -LogPath $LogPath -Level STEP
        try {
            $vmState = (Get-VM -Name $VmName -ErrorAction Stop).State
            if ($vmState -ne "Off") {
                Stop-VM -Name $VmName -TurnOff -Force -Confirm:$false | Out-Null
            }
        }
        catch {
            Write-HvLog -Message ("Pre-restore VM stop skipped: {0}" -f $_.Exception.Message) -LogPath $LogPath -Level WARN
        }

        Restore-VMCheckpoint -VMName $VmName -Name $CheckpointName -Confirm:$false | Out-Null
    }
}

[pscustomobject]@{
    VmName          = $VmName
    CheckpointName  = $CheckpointName
    ArtifactDir     = $artifactDir
    ReproMode       = $ReproMode
    VerifierEnabled = [bool]$EnableVerifier
    KernelDebug     = [bool]$EnableKernelDebug
}
