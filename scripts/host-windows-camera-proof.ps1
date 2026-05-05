[CmdletBinding()]
param(
    [string]$ArtifactRoot = "test-reports\host-windows-camera",
    [ValidateSet("auto", "printwindow", "wgc", "bitblt")][string]$CaptureBackend = "wgc",
    [int]$WarmupSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )
    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Stop-ProofProcesses {
    Get-Process -Name "VirtuaCam", "VirtuaCamProcess", "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*show-proof-panel.ps1*" -or $_.CommandLine -like "*serve-webcam.ps1*" } |
        Invoke-CimMethod -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
}

function Export-EventLogSafe {
    param([string]$LogName, [string]$OutPath)
    try { & wevtutil.exe epl $LogName $OutPath 2>$null } catch {}
}

function Enable-EventLogSafe {
    param([string]$LogName)
    try { & wevtutil.exe sl $LogName /e:true /q:true 2>$null } catch {}
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$fullRoot = if ([System.IO.Path]::IsPathRooted($ArtifactRoot)) { $ArtifactRoot } else { Join-Path $repoRoot $ArtifactRoot }
$runDir = Join-Path $fullRoot (Get-Date -Format "yyyyMMdd-HHmmss")
$packageRoot = Join-Path $runDir "package"
$htmlPath = Join-Path $runDir "webcam.html"
$statusPath = Join-Path $runDir "held-status.json"
$configPath = Join-Path $runDir "held-config.json"
$screenshotPath = Join-Path $runDir "host-camera.png"
$summaryPath = Join-Path $runDir "host-camera-proof.json"

New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
Copy-Item -Path (Join-Path $repoRoot "output\*") -Destination $packageRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "software-project\webcam.html") -Destination $htmlPath -Force

$config = [pscustomobject]@{
    PackageRoot = $packageRoot
    HtmlPath = $htmlPath
    Browser = "Chrome"
    AttemptId = "host-camera-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    SourceWindowMode = "ProofPanel"
    CaptureBackend = $CaptureBackend
    LaunchBrowser = $false
    HttpPort = 8000
    GuestStatusPath = $statusPath
    ServeHttp = $false
}
Write-JsonFile -Path $configPath -Data $config

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ("HostCameraProofOps" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class HostCameraProofOps {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
}

function Get-TextTail {
    param(
        [string]$Path,
        [string]$EncodingName = "",
        [int]$Tail = 80
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($EncodingName)) {
        return [string]::Join([Environment]::NewLine, @(Get-Content -LiteralPath $Path -Tail $Tail))
    }

    return [string]::Join([Environment]::NewLine, @(Get-Content -LiteralPath $Path -Encoding $EncodingName -Tail $Tail))
}

$held = $null
$summary = [ordered]@{
    Success = $false
    RunDir = $runDir
    Screenshot = $screenshotPath
    CaptureBackend = $CaptureBackend
    DriverVer = if (Test-Path (Join-Path $repoRoot "output\avshws.inf")) {
        (Select-String -Path (Join-Path $repoRoot "output\avshws.inf") -Pattern "^DriverVer").Line
    } else { "" }
    Error = ""
    Interaction = "layout source left/camera right, Alt+Y, switch-camera click"
    CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
}

try {
    Stop-ProofProcesses
    foreach ($logName in @(
        "MF_MediaFoundationFrameServer",
        "MF_MediaFoundationDeviceProxy",
        "MediaFoundationPipeline",
        "Microsoft-Windows-Runtime-Windows-Media/WinRTCaptureEngine",
        "Microsoft-Windows-MediaFoundation-MFCaptureEngine/MFCaptureEngine"
    )) {
        Enable-EventLogSafe -LogName $logName
    }

    $held = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "guest-held-webcam-session.ps1"),
        "-ConfigPath", $configPath
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runDir "held.stdout.txt") -RedirectStandardError (Join-Path $runDir "held.stderr.txt")

    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $statusPath) {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            if ($status.Ready) {
                $summary.HeldSession = $status
                break
            }
            if ($status.LaunchError) { throw $status.LaunchError }
        }
        if ($held.HasExited) { throw "Held source exited early." }
        Start-Sleep -Milliseconds 500
    }
    if (-not $summary.HeldSession) { throw "Timed out waiting for held source." }

    $screenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($summary.HeldSession.ControlPanelHwnd) {
        $sourceHwndValue = [Int64]::Parse([string]$summary.HeldSession.ControlPanelHwnd)
        if ($sourceHwndValue -ne 0) {
            [void][HostCameraProofOps]::ShowWindowAsync([IntPtr]::new($sourceHwndValue), 1)
            [void][HostCameraProofOps]::MoveWindow(
                [IntPtr]::new($sourceHwndValue),
                20,
                80,
                [Math]::Min(900, [Math]::Max(640, [int]($screenBounds.Width * 0.46))),
                [Math]::Min(620, [Math]::Max(480, $screenBounds.Height - 140)),
                $true)
        }
    }

    foreach ($capability in @("microphone", "webcam")) {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capability\Microsoft.WindowsCamera_8wekyb3d8bbwe"
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name Value -Value Allow
    }

    Start-Process "microsoft.windows.camera:" | Out-Null
    $cameraWindow = $null
    $deadline = (Get-Date).AddSeconds(25)
    do {
        Start-Sleep -Milliseconds 500
        foreach ($proc in @(Get-Process -Name "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue)) {
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne 0) {
                $cameraWindow = $proc
                break
            }
        }
    } while (-not $cameraWindow -and (Get-Date) -lt $deadline)

    if ($cameraWindow) {
        [void][HostCameraProofOps]::ShowWindowAsync($cameraWindow.MainWindowHandle, 1)
        $cameraX = [Math]::Max(980, [int]($screenBounds.Width * 0.52))
        $cameraY = 20
        $cameraW = [Math]::Max(760, $screenBounds.Width - $cameraX - 20)
        $cameraH = [Math]::Max(640, $screenBounds.Height - 80)
        [void][HostCameraProofOps]::MoveWindow($cameraWindow.MainWindowHandle, $cameraX, $cameraY, $cameraW, $cameraH, $true)
        Start-Sleep -Milliseconds 500
        [void][HostCameraProofOps]::SetForegroundWindow($cameraWindow.MainWindowHandle)
        Start-Sleep -Seconds 2
        [System.Windows.Forms.SendKeys]::SendWait("%y")
        Start-Sleep -Seconds 1

        [void][HostCameraProofOps]::SetCursorPos([int]($cameraX + ($cameraW / 2)), [int]($cameraY + ($cameraH / 2)))
        [HostCameraProofOps]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        [HostCameraProofOps]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Seconds 1

        $changeCameraX = [Math]::Max(1, $cameraX + $cameraW - 46)
        $changeCameraY = [Math]::Max(1, $cameraY + [int]($cameraH * 0.30))
        [void][HostCameraProofOps]::SetCursorPos($changeCameraX, $changeCameraY)
        [HostCameraProofOps]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        [HostCameraProofOps]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }

    Start-Sleep -Seconds $WarmupSeconds

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($screenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)

        $nonDark = 0
        $colorful = 0
        $bright = 0
        $edge = 0
        $count = 0
        [int64]$sumB = 0
        [int64]$sumG = 0
        [int64]$sumR = 0
        [double]$sumLum = 0
        [double]$sumLumSq = 0
        $sampleLeft = 80
        $sampleTop = 80
        $sampleRight = [Math]::Min($bounds.Width - 180, 1700)
        $sampleBottom = [Math]::Min($bounds.Height - 140, 900)
        if ($cameraWindow) {
            $rect = New-Object HostCameraProofOps+RECT
            if ([HostCameraProofOps]::GetWindowRect($cameraWindow.MainWindowHandle, [ref]$rect)) {
                $sampleLeft = [Math]::Max(0, $rect.Left + 24)
                $sampleTop = [Math]::Max(0, $rect.Top + 80)
                $sampleRight = [Math]::Min($bounds.Width, $rect.Right - 90)
                $sampleBottom = [Math]::Min($bounds.Height, $rect.Bottom - 120)
                $summary.CameraWindowRect = @($rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
            }
        }
        $summary.SampleRect = @($sampleLeft, $sampleTop, $sampleRight, $sampleBottom)
        for ($y = $sampleTop; $y -lt $sampleBottom; $y += 4) {
            for ($x = $sampleLeft; $x -lt $sampleRight; $x += 4) {
                $c = $bitmap.GetPixel($x, $y)
                $lum = 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B
                if ($c.R -gt 50 -or $c.G -gt 50 -or $c.B -gt 50) { $nonDark++ }
                if ([Math]::Abs($c.R - $c.G) -gt 12 -or [Math]::Abs($c.G - $c.B) -gt 12 -or [Math]::Abs($c.R - $c.B) -gt 12) { $colorful++ }
                if ($c.R -gt 220 -and $c.G -gt 220 -and $c.B -gt 220) { $bright++ }
                $count++
                $sumB += $c.B
                $sumG += $c.G
                $sumR += $c.R
                $sumLum += $lum
                $sumLumSq += $lum * $lum
                if ($x + 8 -lt $sampleRight) {
                    $c2 = $bitmap.GetPixel($x + 8, $y)
                    $lum2 = 0.2126 * $c2.R + 0.7152 * $c2.G + 0.0722 * $c2.B
                    if ([Math]::Abs($lum - $lum2) -gt 35) { $edge++ }
                }
            }
        }
        $center = $bitmap.GetPixel([int]($bounds.Width / 2), [int]($bounds.Height / 2))
        $lumVariance = if ($count -gt 0) { ($sumLumSq / $count) - (($sumLum / $count) * ($sumLum / $count)) } else { 0 }
        $lumStdDev = [Math]::Sqrt([Math]::Max([double]0, $lumVariance))
        $summary.CameraWindowTitle = if ($cameraWindow) { [string]$cameraWindow.MainWindowTitle } else { "" }
        $summary.NonDarkSamples = $nonDark
        $summary.ColorfulSamples = $colorful
        $summary.BrightSamples = $bright
        $summary.EdgeSamples = $edge
        $summary.SampleCount = $count
        $summary.NonDarkRatio = if ($count -gt 0) { [Math]::Round($nonDark / $count, 6) } else { 0 }
        $summary.ColorfulRatio = if ($count -gt 0) { [Math]::Round($colorful / $count, 6) } else { 0 }
        $summary.BrightRatio = if ($count -gt 0) { [Math]::Round($bright / $count, 6) } else { 0 }
        $summary.EdgeRatio = if ($count -gt 0) { [Math]::Round($edge / $count, 6) } else { 0 }
        $summary.LumaStdDev = [Math]::Round($lumStdDev, 2)
        $summary.AvgBgr = @(
            [Math]::Round($sumB / [Math]::Max(1, $count), 2),
            [Math]::Round($sumG / [Math]::Max(1, $count), 2),
            [Math]::Round($sumR / [Math]::Max(1, $count), 2)
        )
        $summary.CenterBgr = @($center.B, $center.G, $center.R)
        $summary.RuntimeLogTailAfterCamera = if ($summary.HeldSession -and $summary.HeldSession.RuntimeLogPath) {
            Get-TextTail -Path ([string]$summary.HeldSession.RuntimeLogPath) -EncodingName Unicode -Tail 100
        } else { "" }
        $summary.Success = (
            $summary.BrightRatio -gt 0.015 -and
            $summary.EdgeRatio -gt 0.01 -and
            $summary.LumaStdDev -gt 18
        )
        if (-not $summary.Success -and [string]::IsNullOrWhiteSpace($summary.Error)) {
            $summary.Error = "Camera app screenshot did not contain proof-window footage; likely placeholder or blank."
        }
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}
catch {
    $summary.Error = $_.Exception.Message
}
finally {
    foreach ($logName in @(
        "System",
        "Application",
        "MF_MediaFoundationFrameServer",
        "MF_MediaFoundationDeviceProxy",
        "MediaFoundationPipeline",
        "Microsoft-Windows-Runtime-Windows-Media/WinRTCaptureEngine",
        "Microsoft-Windows-MediaFoundation-MFCaptureEngine/MFCaptureEngine"
    )) {
        $safeName = ($logName -replace '[\\/]', '_')
        Export-EventLogSafe -LogName $logName -OutPath (Join-Path $runDir ($safeName + ".evtx"))
    }
    Stop-ProofProcesses
    if ($held -and -not $held.HasExited) {
        Stop-Process -Id $held.Id -Force -ErrorAction SilentlyContinue
    }
    Write-JsonFile -Path $summaryPath -Data ([pscustomobject]$summary)
}

Get-Content -LiteralPath $summaryPath -Raw
