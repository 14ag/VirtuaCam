[CmdletBinding()]
param(
    [string]$ArtifactRoot = "test-reports\host-windows-camera-display-capture",
    [int]$DisplayIndex = 0,
    [ValidateSet("16:9", "9:16", "4:3", "3:4")]
    [string]$AspectRatio = "16:9",
    [int]$WarmupSeconds = 8,
    [int]$CaptureWaitSeconds = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )
    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Stop-ProofProcesses {
    Get-Service -Name "VirtuaCamWatcher" -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne "Stopped" } |
        Stop-Service -Force -ErrorAction SilentlyContinue
    Get-Process -Name "VirtuaCam", "VirtuaCamProcess", "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-CameraRollCandidates {
    $paths = New-Object System.Collections.Generic.List[string]
    $pictures = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
    if ($pictures) { $paths.Add((Join-Path $pictures "Camera Roll")) }
    if ($env:OneDrive) { $paths.Add((Join-Path $env:OneDrive "Pictures\Camera Roll")) }
    $paths.Add((Join-Path $env:USERPROFILE "Pictures\Camera Roll"))
    return @($paths | Select-Object -Unique)
}

function Get-NewCameraFiles {
    param([DateTime]$Since)
    $patterns = @("*.jpg", "*.jpeg", "*.png", "*.mp4")
    foreach ($root in Get-CameraRollCandidates) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($pattern in $patterns) {
            Get-ChildItem -LiteralPath $root -Filter $pattern -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $Since } |
                Sort-Object LastWriteTime -Descending
        }
    }
}

function Save-ScreenPng {
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-ExpectedCaptureSize {
    param([Parameter(Mandatory = $true)][string]$AspectRatio)
    switch ($AspectRatio) {
        "9:16" { return @(1080, 1920) }
        "4:3" { return @(1440, 1080) }
        "3:4" { return @(1080, 1440) }
        default { return @(1920, 1080) }
    }
}

function Invoke-CameraTakePhotoButton {
    param([Parameter(Mandatory = $true)][IntPtr]$WindowHandle)

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
    if (-not $root) { return $false }

    $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    foreach ($button in $buttons) {
        $name = [string]$button.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::NameProperty)
        if ($name -notmatch "Take photo|Capture|Shutter") { continue }

        $pattern = $null
        if ($button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            $pattern.Invoke()
            return $true
        }
    }

    return $false
}

function Invoke-FallbackMouseClick {
    param(
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y
    )

    [void][HostCameraDisplayOps]::SetCursorPos($X, $Y)
    [HostCameraDisplayOps]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [HostCameraDisplayOps]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Get-ImageCompareStats {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$ActualPath
    )
    Add-Type -AssemblyName System.Drawing
    $expected = [System.Drawing.Bitmap]::new($ExpectedPath)
    $actual = [System.Drawing.Bitmap]::new($ActualPath)
    $resized = $null
    try {
        $resized = [System.Drawing.Bitmap]::new($actual.Width, $actual.Height)
        $g = [System.Drawing.Graphics]::FromImage($resized)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($expected, 0, 0, $actual.Width, $actual.Height)
        }
        finally {
            $g.Dispose()
        }

        [int64]$sumAbs = 0
        [int64]$sumActualB = 0
        [int64]$sumActualG = 0
        [int64]$sumActualR = 0
        [int64]$yellow = 0
        [int64]$samples = 0
        $stepX = [Math]::Max(1, [int]($actual.Width / 320))
        $stepY = [Math]::Max(1, [int]($actual.Height / 180))
        for ($y = 0; $y -lt $actual.Height; $y += $stepY) {
            for ($x = 0; $x -lt $actual.Width; $x += $stepX) {
                $a = $actual.GetPixel($x, $y)
                $e = $resized.GetPixel($x, $y)
                $sumAbs += [Math]::Abs([int]$a.R - [int]$e.R)
                $sumAbs += [Math]::Abs([int]$a.G - [int]$e.G)
                $sumAbs += [Math]::Abs([int]$a.B - [int]$e.B)
                $sumActualB += $a.B
                $sumActualG += $a.G
                $sumActualR += $a.R
                if ($a.R -gt 130 -and $a.G -gt 90 -and $a.B -lt 80 -and $a.R -gt ($a.B + 60) -and $a.G -gt ($a.B + 40)) {
                    ++$yellow
                }
                ++$samples
            }
        }
        $centerActual = $actual.GetPixel([int]($actual.Width / 2), [int]($actual.Height / 2))
        $centerExpected = $resized.GetPixel([int]($actual.Width / 2), [int]($actual.Height / 2))
        return [pscustomobject]@{
            Expected = $ExpectedPath
            Actual = $ActualPath
            ExpectedSize = @($expected.Width, $expected.Height)
            ActualSize = @($actual.Width, $actual.Height)
            Samples = $samples
            MeanAbsRgbDiff = if ($samples -gt 0) { [Math]::Round($sumAbs / ($samples * 3.0), 3) } else { 0 }
            ActualAvgBgr = @(
                [Math]::Round($sumActualB / [Math]::Max(1, $samples), 2),
                [Math]::Round($sumActualG / [Math]::Max(1, $samples), 2),
                [Math]::Round($sumActualR / [Math]::Max(1, $samples), 2)
            )
            ActualCenterBgr = @($centerActual.B, $centerActual.G, $centerActual.R)
            ExpectedCenterBgr = @($centerExpected.B, $centerExpected.G, $centerExpected.R)
            YellowRatio = if ($samples -gt 0) { [Math]::Round($yellow / $samples, 6) } else { 0 }
        }
    }
    finally {
        if ($resized) { $resized.Dispose() }
        $actual.Dispose()
        $expected.Dispose()
    }
}

if (-not ("HostCameraDisplayOps" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class HostCameraDisplayOps {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
"@
}

function Set-CameraWindowForeground {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$WindowHandle,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    $hwndTopMost = [IntPtr]::new(-1)
    $hwndNoTopMost = [IntPtr]::new(-2)
    $showNormal = 1
    $showRestore = 9
    $swpShowWindow = 0x0040
    [void][HostCameraDisplayOps]::ShowWindowAsync($WindowHandle, $showRestore)
    Start-Sleep -Milliseconds 200
    [void][HostCameraDisplayOps]::SetWindowPos($WindowHandle, $hwndTopMost, $X, $Y, $Width, $Height, $swpShowWindow)
    Start-Sleep -Milliseconds 200
    [void][HostCameraDisplayOps]::SetForegroundWindow($WindowHandle)
    Start-Sleep -Milliseconds 200
    [void][HostCameraDisplayOps]::SetWindowPos($WindowHandle, $hwndNoTopMost, $X, $Y, $Width, $Height, $swpShowWindow)
    [void][HostCameraDisplayOps]::ShowWindowAsync($WindowHandle, $showNormal)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$fullRoot = if ([System.IO.Path]::IsPathRooted($ArtifactRoot)) { $ArtifactRoot } else { Join-Path $repoRoot $ArtifactRoot }
$runDir = Join-Path $fullRoot (Get-Date -Format "yyyyMMdd-HHmmss")
$packageRoot = Join-Path $runDir "package"
$beforeScreenshotPath = Join-Path $runDir "screen-before-camera.png"
$captureScreenshotPath = Join-Path $runDir "screen-at-capture.png"
$summaryPath = Join-Path $runDir "summary.json"

New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
Copy-Item -Path (Join-Path $repoRoot "output\*") -Destination $packageRoot -Recurse -Force

$summary = [ordered]@{
    Success = $false
    RunDir = $runDir
    DisplayIndex = $DisplayIndex
    AspectRatio = $AspectRatio
    ExpectedCaptureSize = @(Get-ExpectedCaptureSize -AspectRatio $AspectRatio)
    AspectSizeMatches = $false
    CameraRollCandidates = @(Get-CameraRollCandidates)
    BeforeScreenshot = $beforeScreenshotPath
    CaptureScreenshot = $captureScreenshotPath
    SavedCapture = ""
    Compare = $null
    RuntimeLogTail = ""
    ProcessLogTail = ""
    Error = ""
    CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
}

$oldDump = $env:VIRTUACAM_DRIVER_FRAME_DUMP
$hadDump = Test-Path Env:VIRTUACAM_DRIVER_FRAME_DUMP
$watcherService = Get-Service -Name "VirtuaCamWatcher" -ErrorAction SilentlyContinue
$watcherWasRunning = $watcherService -and $watcherService.Status -ne "Stopped"
$settingsPath = "HKCU:\Software\VirtuaCam\Settings"
$hadAspectSetting = $false
$oldAspectSetting = $null
if (Test-Path -LiteralPath $settingsPath) {
    $existingSettings = Get-ItemProperty -LiteralPath $settingsPath -ErrorAction SilentlyContinue
    if ($existingSettings -and ($existingSettings.PSObject.Properties.Name -contains "AspectRatio")) {
        $hadAspectSetting = $true
        $oldAspectSetting = $existingSettings.AspectRatio
    }
}
$runtime = $null
try {
    Stop-ProofProcesses
    New-Item -Path $settingsPath -Force | Out-Null
    Set-ItemProperty -Path $settingsPath -Name AspectRatio -Value $AspectRatio
    $env:VIRTUACAM_DRIVER_FRAME_DUMP = "1"
    $runtime = Start-Process -FilePath (Join-Path $packageRoot "VirtuaCam.exe") -ArgumentList @(
        "/startup",
        "-debug",
        "--source-display-index",
        ([string]$DisplayIndex)
    ) -WorkingDirectory $packageRoot -PassThru -WindowStyle Hidden

    Start-Sleep -Seconds $WarmupSeconds
    Save-ScreenPng -Path $beforeScreenshotPath

    foreach ($capability in @("microphone", "webcam")) {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capability\Microsoft.WindowsCamera_8wekyb3d8bbwe"
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name Value -Value Allow
    }

    $since = (Get-Date).AddSeconds(-2)
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
    if (-not $cameraWindow) { throw "Windows Camera window not found." }

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $cameraW = [Math]::Min(760, [Math]::Max(520, [int]($bounds.Width * 0.38)))
    $cameraH = [Math]::Min(620, [Math]::Max(420, [int]($bounds.Height * 0.58)))
    $cameraX = [Math]::Max(0, $bounds.Width - $cameraW - 20)
    $cameraY = 40
    Set-CameraWindowForeground -WindowHandle $cameraWindow.MainWindowHandle -X $cameraX -Y $cameraY -Width $cameraW -Height $cameraH
    [void][HostCameraDisplayOps]::MoveWindow($cameraWindow.MainWindowHandle, $cameraX, $cameraY, $cameraW, $cameraH, $true)
    Start-Sleep -Seconds 2
    Set-CameraWindowForeground -WindowHandle $cameraWindow.MainWindowHandle -X $cameraX -Y $cameraY -Width $cameraW -Height $cameraH
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait("%y")
    Start-Sleep -Seconds 2

    Set-CameraWindowForeground -WindowHandle $cameraWindow.MainWindowHandle -X $cameraX -Y $cameraY -Width $cameraW -Height $cameraH
    Save-ScreenPng -Path $captureScreenshotPath

    $buttonX = $cameraX + $cameraW - 68
    $buttonY = $cameraY + [int]($cameraH / 2)
    if (-not (Invoke-CameraTakePhotoButton -WindowHandle $cameraWindow.MainWindowHandle)) {
        Set-CameraWindowForeground -WindowHandle $cameraWindow.MainWindowHandle -X $cameraX -Y $cameraY -Width $cameraW -Height $cameraH
        Invoke-FallbackMouseClick -X $buttonX -Y $buttonY
    }

    $saved = $null
    $deadline = (Get-Date).AddSeconds($CaptureWaitSeconds)
    do {
        Start-Sleep -Seconds 1
        $saved = @(Get-NewCameraFiles -Since $since | Where-Object { $_.Extension -match '\.jpe?g|\.png' } | Select-Object -First 1)
    } while (-not $saved -and (Get-Date) -lt $deadline)
    if (-not $saved) { throw "No new Windows Camera photo appeared in Camera Roll." }

    $summary.SavedCapture = $saved[0].FullName
    $summary.Compare = Get-ImageCompareStats -ExpectedPath $captureScreenshotPath -ActualPath $saved[0].FullName
    $summary.AspectSizeMatches = (
        $summary.Compare.ActualSize[0] -eq $summary.ExpectedCaptureSize[0] -and
        $summary.Compare.ActualSize[1] -eq $summary.ExpectedCaptureSize[1])
    $summary.Success = (
        $summary.Compare.YellowRatio -lt 0.20 -and
        $summary.Compare.MeanAbsRgbDiff -lt 95 -and
        $summary.AspectSizeMatches)
    if (-not $summary.Success) {
        $summary.Error = "Windows Camera saved image differs from display screenshot, is yellow-tinted, or has wrong aspect size."
    }
}
catch {
    $summary.Error = $_.Exception.Message
}
finally {
    $runtimeLog = Join-Path $packageRoot "logs\virtuacam-runtime.log"
    $processLog = Join-Path $packageRoot "logs\virtuacam-process.log"
    if (Test-Path -LiteralPath $runtimeLog) {
        $summary.RuntimeLogTail = [string]::Join([Environment]::NewLine, @(Get-Content -LiteralPath $runtimeLog -Encoding Unicode -Tail 120))
    }
    if (Test-Path -LiteralPath $processLog) {
        $summary.ProcessLogTail = [string]::Join([Environment]::NewLine, @(Get-Content -LiteralPath $processLog -Encoding Unicode -Tail 120))
    }
    Stop-ProofProcesses
    if ($runtime -and -not $runtime.HasExited) {
        Stop-Process -Id $runtime.Id -Force -ErrorAction SilentlyContinue
    }
    if ($hadDump) {
        $env:VIRTUACAM_DRIVER_FRAME_DUMP = $oldDump
    } else {
        Remove-Item Env:VIRTUACAM_DRIVER_FRAME_DUMP -ErrorAction SilentlyContinue
    }
    if ($hadAspectSetting) {
        Set-ItemProperty -Path $settingsPath -Name AspectRatio -Value $oldAspectSetting -ErrorAction SilentlyContinue
    } else {
        Remove-ItemProperty -Path $settingsPath -Name AspectRatio -ErrorAction SilentlyContinue
    }
    if ($watcherWasRunning) {
        Start-Service -Name "VirtuaCamWatcher" -ErrorAction SilentlyContinue
    }
    Write-JsonFile -Path $summaryPath -Data ([pscustomobject]$summary)
}

Get-Content -LiteralPath $summaryPath -Raw
