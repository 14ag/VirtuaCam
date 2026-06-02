[CmdletBinding()]
param(
    [string]$ArtifactRoot = "test-reports\host-windows-camera-aspect-hot-change",
    [int]$DisplayIndex = 0,
    [ValidateSet("16:9", "9:16", "4:3", "3:4")]
    [string]$InitialAspectRatio = "16:9",
    [ValidateSet("16:9", "9:16", "4:3", "3:4")]
    [string]$TargetAspectRatio = "9:16",
    [int]$WarmupSeconds = 8,
    [int]$AfterChangeWaitSeconds = 10,
    [int]$CaptureWaitSeconds = 25,
    [switch]$RestartCameraAfterChange,
    [switch]$CloseAndReopenCameraAfterChange
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

function Get-NewCameraPhoto {
    param([DateTime]$Since)
    foreach ($root in Get-CameraRollCandidates) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Include "*.jpg", "*.jpeg", "*.png" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Since } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
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

function Get-AspectCommandId {
    param([Parameter(Mandatory = $true)][string]$AspectRatio)
    switch ($AspectRatio) {
        "9:16" { return 18101 }
        "4:3" { return 18102 }
        "3:4" { return 18103 }
        default { return 18100 }
    }
}

function Get-ImageSize {
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new($Path)
    try {
        return @($bitmap.Width, $bitmap.Height)
    }
    finally {
        $bitmap.Dispose()
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

function Wait-NewCameraPhoto {
    param(
        [Parameter(Mandatory = $true)][DateTime]$Since,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $saved = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $saved = @(Get-NewCameraPhoto -Since $Since | Select-Object -First 1)
    } while (-not $saved -and (Get-Date) -lt $deadline)
    if (-not $saved) { return $null }
    return $saved[0]
}

if (-not ("HotChangeCameraOps" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class HotChangeCameraOps {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
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
    $swpShowWindow = 0x0040
    [void][HotChangeCameraOps]::ShowWindowAsync($WindowHandle, 9)
    Start-Sleep -Milliseconds 200
    [void][HotChangeCameraOps]::SetWindowPos($WindowHandle, $hwndTopMost, $X, $Y, $Width, $Height, $swpShowWindow)
    Start-Sleep -Milliseconds 200
    [void][HotChangeCameraOps]::SetForegroundWindow($WindowHandle)
    Start-Sleep -Milliseconds 200
    [void][HotChangeCameraOps]::SetWindowPos($WindowHandle, $hwndNoTopMost, $X, $Y, $Width, $Height, $swpShowWindow)
}

function Close-CameraWindow {
    param([Parameter(Mandatory = $true)][IntPtr]$WindowHandle)

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
    if ($root) {
        $pattern = $null
        if ($root.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pattern)) {
            $pattern.Close()
            return $true
        }
    }

    return [HotChangeCameraOps]::PostMessage($WindowHandle, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
}

function Wait-CameraWindow {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        foreach ($proc in @(Get-Process -Name "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue)) {
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne 0) {
                return $proc
            }
        }
    } while ((Get-Date) -lt $deadline)

    return $null
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$fullRoot = if ([System.IO.Path]::IsPathRooted($ArtifactRoot)) { $ArtifactRoot } else { Join-Path $repoRoot $ArtifactRoot }
$runDir = Join-Path $fullRoot (Get-Date -Format "yyyyMMdd-HHmmss")
$packageRoot = Join-Path $runDir "package"
$beforeChangeScreenshot = Join-Path $runDir "screen-before-change.png"
$afterChangeScreenshot = Join-Path $runDir "screen-after-change.png"
$afterTargetClickScreenshot = Join-Path $runDir "screen-after-target-click.png"
$summaryPath = Join-Path $runDir "summary.json"

New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
Copy-Item -Path (Join-Path $repoRoot "output\*") -Destination $packageRoot -Recurse -Force
$packageLogs = Join-Path $packageRoot "logs"
if (Test-Path -LiteralPath $packageLogs) {
    Remove-Item -LiteralPath $packageLogs -Recurse -Force
}

$summary = [ordered]@{
    Success = $false
    RunDir = $runDir
    DisplayIndex = $DisplayIndex
    InitialAspectRatio = $InitialAspectRatio
    TargetAspectRatio = $TargetAspectRatio
    InitialExpectedSize = @(Get-ExpectedCaptureSize -AspectRatio $InitialAspectRatio)
    TargetExpectedSize = @(Get-ExpectedCaptureSize -AspectRatio $TargetAspectRatio)
    BeforeChangeScreenshot = $beforeChangeScreenshot
    AfterChangeScreenshot = $afterChangeScreenshot
    AfterTargetClickScreenshot = $afterTargetClickScreenshot
    InitialCapture = ""
    InitialCaptureSize = @()
    TargetCapture = ""
    TargetCaptureSize = @()
    TargetSizeMatches = $false
    RestartMode = if ($CloseAndReopenCameraAfterChange) { "CloseAndReopen" } elseif ($RestartCameraAfterChange) { "ForceKillAndReopen" } else { "None" }
    RuntimeLogTail = ""
    Error = ""
    CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
}

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
    Set-ItemProperty -Path $settingsPath -Name AspectRatio -Value $InitialAspectRatio
    $runtime = Start-Process -FilePath (Join-Path $packageRoot "VirtuaCam.exe") -ArgumentList @(
        "-debug",
        "--source-display-index",
        ([string]$DisplayIndex)
    ) -WorkingDirectory $packageRoot -PassThru -WindowStyle Hidden

    Start-Sleep -Seconds $WarmupSeconds
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
    if (-not $cameraWindow) { throw "Windows Camera window not found." }

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $cameraW = [Math]::Min(760, [Math]::Max(520, [int]($bounds.Width * 0.38)))
    $cameraH = [Math]::Min(620, [Math]::Max(420, [int]($bounds.Height * 0.58)))
    $cameraX = [Math]::Max(0, $bounds.Width - $cameraW - 20)
    $cameraY = 40
    Set-CameraWindowForeground -WindowHandle $cameraWindow.MainWindowHandle -X $cameraX -Y $cameraY -Width $cameraW -Height $cameraH
    [void][HotChangeCameraOps]::MoveWindow($cameraWindow.MainWindowHandle, $cameraX, $cameraY, $cameraW, $cameraH, $true)
    Start-Sleep -Seconds 3
    Save-ScreenPng -Path $beforeChangeScreenshot

    $since = (Get-Date).AddSeconds(-2)
    if (-not (Invoke-CameraTakePhotoButton -WindowHandle $cameraWindow.MainWindowHandle)) {
        throw "Initial Take photo button not found."
    }
    $initialSaved = Wait-NewCameraPhoto -Since $since -TimeoutSeconds $CaptureWaitSeconds
    if (-not $initialSaved) { throw "No initial Windows Camera photo appeared in Camera Roll." }
    $summary.InitialCapture = $initialSaved.FullName
    $summary.InitialCaptureSize = @(Get-ImageSize -Path $initialSaved.FullName)

    $virtuaCamHwnd = [HotChangeCameraOps]::FindWindowEx([IntPtr]::new(-3), [IntPtr]::Zero, "VIRTUACAM", "VirtuaCam Message Window")
    if ($virtuaCamHwnd -eq [IntPtr]::Zero) { throw "VirtuaCam message window not found." }
    $targetCommand = Get-AspectCommandId -AspectRatio $TargetAspectRatio
    $targetWParam = [UIntPtr]::new([uint64]$targetCommand)
    if (-not [HotChangeCameraOps]::PostMessage($virtuaCamHwnd, 0x8002, $targetWParam, [IntPtr]::Zero)) {
        throw "PostMessage aspect change failed."
    }

    Start-Sleep -Seconds $AfterChangeWaitSeconds
    if ($RestartCameraAfterChange -or $CloseAndReopenCameraAfterChange) {
        if ($CloseAndReopenCameraAfterChange) {
            if (-not (Close-CameraWindow -WindowHandle $cameraWindow.MainWindowHandle)) {
                throw "Windows Camera close request failed."
            }
            Start-Sleep -Seconds 3
        } else {
            Get-Process -Name "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        Start-Process "microsoft.windows.camera:" | Out-Null
        $cameraWindow = Wait-CameraWindow -TimeoutSeconds 25
        if (-not $cameraWindow) { throw "Windows Camera window not found after restart." }
        Start-Sleep -Seconds 3
    }
    Set-CameraWindowForeground -WindowHandle $cameraWindow.MainWindowHandle -X $cameraX -Y $cameraY -Width $cameraW -Height $cameraH
    Save-ScreenPng -Path $afterChangeScreenshot

    $since = (Get-Date).AddSeconds(-2)
    if (-not (Invoke-CameraTakePhotoButton -WindowHandle $cameraWindow.MainWindowHandle)) {
        throw "Target Take photo button not found."
    }
    Start-Sleep -Seconds 2
    Save-ScreenPng -Path $afterTargetClickScreenshot
    $targetSaved = Wait-NewCameraPhoto -Since $since -TimeoutSeconds $CaptureWaitSeconds
    if (-not $targetSaved) { throw "No target Windows Camera photo appeared in Camera Roll." }
    $summary.TargetCapture = $targetSaved.FullName
    $summary.TargetCaptureSize = @(Get-ImageSize -Path $targetSaved.FullName)
    $summary.TargetSizeMatches = (
        $summary.TargetCaptureSize[0] -eq $summary.TargetExpectedSize[0] -and
        $summary.TargetCaptureSize[1] -eq $summary.TargetExpectedSize[1])
    $summary.Success = $summary.TargetSizeMatches
    if (-not $summary.Success) {
        $summary.Error = "Camera stayed on old stream size after VirtuaCam aspect change."
    }
}
catch {
    $summary.Error = $_.Exception.Message
}
finally {
    $runtimeLog = Join-Path $packageRoot "logs\virtuacam-runtime.log"
    if (Test-Path -LiteralPath $runtimeLog) {
        $summary.RuntimeLogTail = [string]::Join([Environment]::NewLine, @(Get-Content -LiteralPath $runtimeLog -Encoding Unicode -Tail 160))
    }
    Stop-ProofProcesses
    if ($runtime -and -not $runtime.HasExited) {
        Stop-Process -Id $runtime.Id -Force -ErrorAction SilentlyContinue
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
