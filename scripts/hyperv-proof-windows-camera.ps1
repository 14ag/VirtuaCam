[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [string]$GuestPasswordPlaintext = "",
    [string]$ArtifactRoot = "test-reports\windows-camera",
    [ValidateSet("Chrome", "Edge")][string]$Browser = "Chrome",
    [ValidateSet("auto", "printwindow", "wgc", "bitblt")][string]$CaptureBackend = "wgc",
    [bool]$RevertAfterRun = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )
    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Restore-ProofCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$TargetVm,
        [Parameter(Mandatory = $true)][string]$TargetCheckpoint,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    Write-HvLog -Message ("Restoring checkpoint '{0}'." -f $TargetCheckpoint) -LogPath $LogFile -Level STEP
    $checkpoint = Get-VMSnapshot -VMName $TargetVm -Name $TargetCheckpoint -ErrorAction SilentlyContinue
    if (-not $checkpoint) {
        Fail-Hv -Message ("Checkpoint '{0}' was not found." -f $TargetCheckpoint) -LogPath $LogFile
    }
    Stop-HvVmForRestore -VmName $TargetVm -LogPath $LogFile
    Restore-VMSnapshot -VMName $TargetVm -Name $TargetCheckpoint -Confirm:$false | Out-Null
}

$repoRoot = Get-HvRepoRoot
$runDir = Join-Path (Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot) (Get-HvTimestamp)
$null = New-Item -ItemType Directory -Force -Path $runDir
$logPath = Join-Path $runDir "hyperv-proof-windows-camera.log"
$statusPath = Join-Path $runDir "vm-session-status.json"
$stopSignalPath = Join-Path $runDir "vm-session-stop.signal"
$holdLogPath = Join-Path $runDir "vm-session-host.log"
$holdStdoutPath = Join-Path $runDir "vm-session-host.stdout.txt"
$holdStderrPath = Join-Path $runDir "vm-session-host.stderr.txt"
$cameraResultPath = Join-Path $runDir "windows-camera-proof.json"
$hostScreenshotPath = Join-Path $runDir "windows-camera-proof.png"

$envValues = Read-HvDotEnv
if ([string]::IsNullOrWhiteSpace($GuestPasswordPlaintext) -and $envValues.ContainsKey("DRIVER_TEST_VM_PASSWORD")) {
    if ($GuestUser -eq "Administrator" -and $envValues.ContainsKey("DRIVER_TEST_VM_USERNAME") -and -not [string]::IsNullOrWhiteSpace([string]$envValues["DRIVER_TEST_VM_USERNAME"])) {
        $GuestUser = [string]$envValues["DRIVER_TEST_VM_USERNAME"]
    }
    $GuestPasswordPlaintext = [string]$envValues["DRIVER_TEST_VM_PASSWORD"]
}

$guestCred = Get-HvGuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext -EnvUserKey "DRIVER_TEST_VM_USERNAME" -EnvPasswordKey "DRIVER_TEST_VM_PASSWORD"
$session = $null
$holdProc = $null
$guestRoot = "C:\Temp\VirtuaCamHyperV\camera-proof"
$guestPackageRoot = Join-Path $guestRoot "output"
$guestScriptsRoot = Join-Path $guestRoot "scripts"
$guestToolsRoot = Join-Path $guestScriptsRoot "tools"
$guestInstallAll = Join-Path $guestScriptsRoot "install-all.ps1"
$guestWebcamHtml = Join-Path $guestRoot "webcam.html"
$guestScreenshotPath = Join-Path $guestRoot "windows-camera-proof.png"

try {
    Restore-ProofCheckpoint -TargetVm $VmName -TargetCheckpoint $CheckpointName -LogFile $logPath
    Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath | Out-Null
    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $logPath

    Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($Root, $ScriptsRoot, $ToolsRoot)
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Force -Path $Root, $ScriptsRoot, $ToolsRoot
    } -ArgumentList $guestRoot, $guestScriptsRoot, $guestToolsRoot | Out-Null

    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "output") -GuestPath $guestRoot -Recurse -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "scripts\install-all.ps1") -GuestPath $guestScriptsRoot -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "scripts\tools\artifact-manifest.ps1") -GuestPath $guestToolsRoot -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "software-project\webcam.html") -GuestPath $guestRoot -LogPath $logPath

    Write-HvLog -Message "Installing staged package inside guest." -LogPath $logPath -Level STEP
    $install = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($InstallScript)
        $lines = & powershell.exe -ExecutionPolicy Bypass -File $InstallScript 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]::Join([Environment]::NewLine, @($lines | ForEach-Object { [string]$_ }))
        }
    } -ArgumentList $guestInstallAll
    Set-Content -LiteralPath (Join-Path $runDir "guest-driver-install.txt") -Value $install.Output
    if ($install.ExitCode -ne 0) {
        throw "driver.InstallFailed"
    }
    if ($install.Output -match '(?i)reboot is needed|reboot is required|pending system reboot|a reboot is required') {
        Write-HvLog -Message "Driver install requested reboot; restarting guest before Windows Camera proof." -LogPath $logPath -Level STEP
        Restart-HvGuest -Session $session -LogPath $logPath
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
        Wait-HvVmRebootTransition -VmName $VmName -Credential $guestCred -TimeoutSeconds 90 -PollIntervalSeconds 3 -LogPath $logPath | Out-Null
        Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds 300 -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath | Out-Null
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 300 -LogPath $logPath
    }

    Remove-Item -LiteralPath $statusPath, $stopSignalPath -Force -ErrorAction SilentlyContinue
    $holdArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "hyperv-hold-webcam-session.ps1"),
        "-VmName", $VmName,
        "-GuestUser", $GuestUser,
        "-GuestPasswordPlaintext", $GuestPasswordPlaintext,
        "-GuestPackageRoot", $guestPackageRoot,
        "-GuestWebcamHtml", $guestWebcamHtml,
        "-Browser", $Browser,
        "-SourceWindowMode", "ProofPanel",
        "-CaptureBackend", $CaptureBackend,
        "-SkipBrowser",
        "-AttemptId", "camera-proof",
        "-ServeHttp",
        "-HttpPort", "8000",
        "-HostStatusPath", $statusPath,
        "-HostStopSignalPath", $stopSignalPath,
        "-LogPath", $holdLogPath
    )

    Write-HvLog -Message "Launching held source session." -LogPath $logPath -Level STEP
    $holdProc = Start-Process -FilePath "powershell.exe" -ArgumentList $holdArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $holdStdoutPath -RedirectStandardError $holdStderrPath

    $status = $null
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $statusPath) {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            if ($status.Ready) { break }
            if ($status.LaunchError) { throw [string]$status.LaunchError }
        }
        if ($holdProc.HasExited) {
            $stdout = if (Test-Path -LiteralPath $holdStdoutPath) { Get-Content -LiteralPath $holdStdoutPath -Raw } else { "" }
            $stderr = if (Test-Path -LiteralPath $holdStderrPath) { Get-Content -LiteralPath $holdStderrPath -Raw } else { "" }
            throw ("Held session exited before ready. ExitCode={0}`nSTDOUT={1}`nSTDERR={2}" -f $holdProc.ExitCode, $stdout.Trim(), $stderr.Trim())
        }
        Start-Sleep -Seconds 2
    }
    if (-not $status -or -not $status.Ready) {
        throw "Timed out waiting for held source session."
    }

    Write-HvLog -Message "Launching Windows Camera app and taking desktop screenshot." -LogPath $logPath -Level STEP
    $camera = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($Root, $ScreenshotPath, $TaskUser, $TaskPassword)

        $scriptPath = Join-Path $Root "windows-camera-shot.ps1"
        $launcherPath = Join-Path $Root "windows-camera-shot-launch.ps1"
        $resultPath = Join-Path $Root "windows-camera-shot.json"
        $stdoutPath = Join-Path $Root "windows-camera-shot.stdout.txt"
        $stderrPath = Join-Path $Root "windows-camera-shot.stderr.txt"
        $taskName = "VirtuaCamWindowsCameraProof"
        Remove-Item -LiteralPath $ScreenshotPath, $resultPath, $stdoutPath, $stderrPath, $launcherPath -Force -ErrorAction SilentlyContinue

        @'
param(
    [Parameter(Mandatory=$true)][string]$ScreenshotPath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CameraProofWindowOps {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@
foreach ($capability in @("microphone", "webcam")) {
    $consentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capability\Microsoft.WindowsCamera_8wekyb3d8bbwe"
    New-Item -Path $consentPath -Force | Out-Null
    Set-ItemProperty -Path $consentPath -Name Value -Value Allow
}
Start-Process "microsoft.windows.camera:" | Out-Null
$cameraProcesses = @()
$cameraWindow = $null
$deadline = (Get-Date).AddSeconds(20)
do {
    Start-Sleep -Milliseconds 500
    $cameraProcesses = @(Get-Process -Name "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue)
    foreach ($proc in $cameraProcesses) {
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne 0) {
            $cameraWindow = $proc
            break
        }
    }
} while (-not $cameraWindow -and (Get-Date) -lt $deadline)
if ($cameraWindow) {
    [void][CameraProofWindowOps]::ShowWindowAsync($cameraWindow.MainWindowHandle, 3)
    Start-Sleep -Milliseconds 500
    [void][CameraProofWindowOps]::SetForegroundWindow($cameraWindow.MainWindowHandle)
    Start-Sleep -Seconds 2
    [CameraProofWindowOps]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [CameraProofWindowOps]::keybd_event(0x59, 0, 0, [UIntPtr]::Zero)
    [CameraProofWindowOps]::keybd_event(0x59, 0, 0x0002, [UIntPtr]::Zero)
    [CameraProofWindowOps]::keybd_event(0x12, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Seconds 3
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $changeCameraX = [Math]::Max(1, $bounds.Width - 46)
    $changeCameraY = [Math]::Max(1, [int]($bounds.Height * 0.30))
    [void][CameraProofWindowOps]::SetCursorPos($changeCameraX, $changeCameraY)
    [CameraProofWindowOps]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [CameraProofWindowOps]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Seconds 8
    $cameraWindow.Refresh()
    [void][CameraProofWindowOps]::ShowWindowAsync($cameraWindow.MainWindowHandle, 3)
    [void][CameraProofWindowOps]::SetForegroundWindow($cameraWindow.MainWindowHandle)
    Start-Sleep -Seconds 2
}
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($bounds.Width -le 0 -or $bounds.Height -le 0) {
    throw "Primary screen bounds invalid: $($bounds.Width)x$($bounds.Height)"
}
$bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($ScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}
[pscustomobject]@{
    CameraProcessCount = $cameraProcesses.Count
    CameraWindowTitle = if ($cameraWindow) { [string]$cameraWindow.MainWindowTitle } else { "" }
    CameraWindowHandle = if ($cameraWindow) { ($cameraWindow.MainWindowHandle.ToInt64()).ToString() } else { "" }
    ScreenshotPath = $ScreenshotPath
    CapturedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@ | Set-Content -LiteralPath $scriptPath -Encoding ASCII

        $pwsh = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        $schtasks = Join-Path $env:WINDIR "System32\schtasks.exe"
        $escapedScriptPath = $scriptPath -replace "'", "''"
        $escapedScreenshotPath = $ScreenshotPath -replace "'", "''"
        $escapedResultPath = $resultPath -replace "'", "''"
        $escapedStdoutPath = $stdoutPath -replace "'", "''"
        $escapedStderrPath = $stderrPath -replace "'", "''"
        "& '$escapedScriptPath' -ScreenshotPath '$escapedScreenshotPath' -ResultPath '$escapedResultPath' > '$escapedStdoutPath' 2> '$escapedStderrPath'" |
            Set-Content -LiteralPath $launcherPath -Encoding ASCII
        & $schtasks /delete /tn $taskName /f 2>$null | Out-Null
        $taskStartAt = (Get-Date).AddMinutes(10)
        $startTime = $taskStartAt.ToString("HH:mm")
        $startDate = $taskStartAt.ToString((Get-Culture).DateTimeFormat.ShortDatePattern)
        $taskCommand = '"' + $pwsh + '" -NoProfile -ExecutionPolicy Bypass -STA -File "' + $launcherPath + '"'
        $createOutput = & $schtasks /create /tn $taskName /sc once /sd $startDate /st $startTime /tr $taskCommand /ru $TaskUser /rp $TaskPassword /rl HIGHEST /it /f 2>&1 | Out-String
        $runOutput = & $schtasks /run /tn $taskName 2>&1 | Out-String

        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $resultPath) {
                return Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            }
            if (Test-Path -LiteralPath $stderrPath) {
                $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                    throw ("Camera screenshot task failed: " + $stderr.Trim())
                }
            }
            Start-Sleep -Seconds 2
        }

        $endOutput = & $schtasks /end /tn $taskName 2>&1 | Out-String
        $queryOutput = & $schtasks /query /tn $taskName /v /fo list 2>&1 | Out-String
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }
        throw ("Timed out waiting for Camera screenshot task. Create={0}`nRun={1}`nEnd={2}`nQuery={3}`nSTDOUT={4}`nSTDERR={5}" -f $createOutput.Trim(), $runOutput.Trim(), $endOutput.Trim(), $queryOutput.Trim(), $stdout.Trim(), $stderr.Trim())
    } -ArgumentList $guestRoot, $guestScreenshotPath, $GuestUser, $GuestPasswordPlaintext

    Copy-HvFromGuest -Session $session -GuestPath $guestScreenshotPath -LocalPath $hostScreenshotPath -LogPath $logPath
    $summary = [pscustomobject]@{
        Success = (Test-Path -LiteralPath $hostScreenshotPath)
        RunDir = $runDir
        ScreenshotPath = $hostScreenshotPath
        HeldSessionStatus = $status
        Camera = $camera
        CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    Write-JsonFile -Path $cameraResultPath -Data $summary
    $summary
}
finally {
    if (-not (Test-Path -LiteralPath $stopSignalPath)) {
        New-Item -ItemType File -Force -Path $stopSignalPath | Out-Null
    }
    if ($holdProc) {
        Wait-Process -Id $holdProc.Id -Timeout 20 -ErrorAction SilentlyContinue
        if (-not $holdProc.HasExited) {
            Stop-Process -Id $holdProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
    if ($RevertAfterRun) {
        Restore-ProofCheckpoint -TargetVm $VmName -TargetCheckpoint $CheckpointName -LogFile $logPath
    }
}
