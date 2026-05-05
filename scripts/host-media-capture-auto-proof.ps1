[CmdletBinding()]
param(
    [string]$ArtifactRoot = "test-reports\host-media-capture-auto",
    [ValidateSet("auto", "printwindow", "wgc", "bitblt")][string]$CaptureBackend = "wgc",
    [string]$DeviceNamePattern = "Virtual Camera",
    [int]$TimeoutSeconds = 25,
    [switch]$IncludeAutoSurfaceProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-RunDirectory {
    param([Parameter(Mandatory = $true)][string]$Root)
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    $fullRoot = if ([System.IO.Path]::IsPathRooted($Root)) { $Root } else { Join-Path $repoRoot $Root }
    $runDir = Join-Path $fullRoot (Get-Date -Format "yyyyMMdd-HHmmss")
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    return $runDir
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )
    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Await-AsyncOperation {
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][type]$ResultType
    )
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "AsTask" -and
            $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } |
        Select-Object -First 1
    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Await-AsyncAction {
    param([Parameter(Mandatory = $true)]$Action)
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "AsTask" -and
            -not $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
        } |
        Select-Object -First 1
    $task = $method.Invoke($null, @($Action))
    $task.Wait()
}

function Convert-SoftwareBitmapToBgra8 {
    param([Parameter(Mandatory = $true)]$Bitmap)
    $formatType = [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    $alphaType = [Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    if ($Bitmap.BitmapPixelFormat -eq $formatType::Bgra8 -and $Bitmap.BitmapAlphaMode -eq $alphaType::Premultiplied) {
        return $Bitmap
    }
    return [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]::Convert(
        $Bitmap,
        $formatType::Bgra8,
        $alphaType::Premultiplied)
}

function Get-BitmapStats {
    param([Parameter(Mandatory = $true)]$Bitmap)

    $bgra = Convert-SoftwareBitmapToBgra8 -Bitmap $Bitmap
    $width = [int]$bgra.PixelWidth
    $height = [int]$bgra.PixelHeight
    $buffer = [Windows.Storage.Streams.Buffer, Windows.Storage.Streams, ContentType=WindowsRuntime]::new([uint32]($width * $height * 4))
    $bgra.CopyToBuffer($buffer)
    $bytes = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::ToArray($buffer)

    $nonBlack = 0
    [int64]$sumB = 0
    [int64]$sumG = 0
    [int64]$sumR = 0
    $center = (($height / 2) -as [int]) * $width * 4 + (($width / 2) -as [int]) * 4
    for ($i = 0; $i -lt $bytes.Length; $i += 4) {
        $b = [int]$bytes[$i]
        $g = [int]$bytes[$i + 1]
        $r = [int]$bytes[$i + 2]
        if ($b -gt 6 -or $g -gt 6 -or $r -gt 6) {
            $nonBlack++
        }
        $sumB += $b
        $sumG += $g
        $sumR += $r
    }

    $pixels = $width * $height
    return [pscustomobject]@{
        Width = $width
        Height = $height
        PixelFormat = [string]$bgra.BitmapPixelFormat
        AlphaMode = [string]$bgra.BitmapAlphaMode
        NonBlackPixels = $nonBlack
        PixelCount = $pixels
        NonBlackRatio = if ($pixels -gt 0) { [Math]::Round($nonBlack / $pixels, 6) } else { 0 }
        AverageBgr = @(
            [Math]::Round($sumB / [Math]::Max(1, $pixels), 2),
            [Math]::Round($sumG / [Math]::Max(1, $pixels), 2),
            [Math]::Round($sumR / [Math]::Max(1, $pixels), 2)
        )
        CenterBgr = @([int]$bytes[$center], [int]$bytes[$center + 1], [int]$bytes[$center + 2])
    }
}

function Export-EventLogSafe {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][string]$OutPath
    )
    try {
        & wevtutil.exe epl $LogName $OutPath 2>$null
    }
    catch {
        Set-Content -LiteralPath ($OutPath + ".error.txt") -Encoding UTF8 -Value $_.Exception.Message
    }
}

function Invoke-FrameReaderProof {
    param(
        [Parameter(Mandatory = $true)][string]$MemoryPreference,
        [Parameter(Mandatory = $true)][string]$SharingMode,
        [Parameter(Mandatory = $true)][string]$DevicePattern,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $deviceInfoType = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $mediaDeviceType = [Windows.Media.Devices.MediaDevice, Windows.Media.Devices, ContentType=WindowsRuntime]
    $captureType = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType=WindowsRuntime]
    $settingsType = [Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
    $sharingType = [Windows.Media.Capture.MediaCaptureSharingMode, Windows.Media.Capture, ContentType=WindowsRuntime]
    $modeType = [Windows.Media.Capture.StreamingCaptureMode, Windows.Media.Capture, ContentType=WindowsRuntime]
    $memoryType = [Windows.Media.Capture.MediaCaptureMemoryPreference, Windows.Media.Capture, ContentType=WindowsRuntime]
    $kindType = [Windows.Media.Capture.Frames.MediaFrameSourceKind, Windows.Media.Capture, ContentType=WindowsRuntime]
    $streamType = [Windows.Media.Capture.MediaStreamType, Windows.Media.Capture, ContentType=WindowsRuntime]
    $readerStatusType = [Windows.Media.Capture.Frames.MediaFrameReaderStartStatus, Windows.Media.Capture, ContentType=WindowsRuntime]
    $softwareBitmapType = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    $directSurfaceType = [Windows.Graphics.DirectX.Direct3D11.IDirect3DSurface, Windows.Graphics.DirectX.Direct3D11, ContentType=WindowsRuntime]

    $selector = $mediaDeviceType::GetVideoCaptureSelector()
    $devices = Await-AsyncOperation -Operation ($deviceInfoType::FindAllAsync($selector)) -ResultType ([Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType=WindowsRuntime])
    $device = $devices | Where-Object { $_.Name -like "*$DevicePattern*" } | Select-Object -First 1
    if (-not $device) {
        throw "No video capture device matched '$DevicePattern'."
    }

    $settings = $settingsType::new()
    $settings.VideoDeviceId = $device.Id
    $settings.StreamingCaptureMode = $modeType::Video
    $settings.SharingMode = if ($SharingMode -eq "ExclusiveControl") { $sharingType::ExclusiveControl } else { $sharingType::SharedReadOnly }
    $settings.MemoryPreference = if ($MemoryPreference -eq "Cpu") { $memoryType::Cpu } else { $memoryType::Auto }

    $capture = $captureType::new()
    $reader = $null
    try {
        Await-AsyncAction -Action ($capture.InitializeAsync($settings))

        $sources = @($capture.FrameSources | ForEach-Object { $_.Value } | Where-Object { $_.Info.SourceKind -eq $kindType::Color })
        $source = $sources | Where-Object { $_.Info.MediaStreamType -eq $streamType::VideoPreview } | Select-Object -First 1
        if (-not $source) {
            $source = $sources | Where-Object { $_.Info.MediaStreamType -eq $streamType::VideoRecord } | Select-Object -First 1
        }
        if (-not $source) {
            throw "No color VideoPreview or VideoRecord frame source."
        }

        $reader = Await-AsyncOperation -Operation ($capture.CreateFrameReaderAsync($source)) -ResultType ([Windows.Media.Capture.Frames.MediaFrameReader, Windows.Media.Capture, ContentType=WindowsRuntime])
        $startStatus = Await-AsyncOperation -Operation ($reader.StartAsync()) -ResultType $readerStatusType

        $frame = $null
        $deadline = (Get-Date).AddSeconds($Timeout)
        while ((Get-Date) -lt $deadline) {
            $candidate = $reader.TryAcquireLatestFrame()
            if ($candidate -and $candidate.VideoMediaFrame) {
                $frame = $candidate
                break
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $frame) {
            throw "No frame arrived within $Timeout seconds."
        }

        $videoFrame = $frame.VideoMediaFrame
        $bitmap = $videoFrame.SoftwareBitmap
        $surfaceCopyError = ""
        $surfacePresent = $false
        if (-not $bitmap -and $videoFrame.Direct3DSurface) {
            $surfacePresent = $true
            try {
                $surface = [System.Management.Automation.LanguagePrimitives]::ConvertTo($videoFrame.Direct3DSurface, $directSurfaceType)
                $bitmap = Await-AsyncOperation -Operation ($softwareBitmapType::CreateCopyFromSurfaceAsync($surface)) -ResultType $softwareBitmapType
            }
            catch {
                $surfaceCopyError = $_.Exception.Message
            }
        }

        $stats = if ($bitmap) { Get-BitmapStats -Bitmap $bitmap } else { $null }
        return [pscustomobject]@{
            MemoryPreference = $MemoryPreference
            SharingMode = $SharingMode
            DeviceName = [string]$device.Name
            SourceStreamType = [string]$source.Info.MediaStreamType
            SourceKind = [string]$source.Info.SourceKind
            CurrentSubtype = [string]$source.CurrentFormat.Subtype
            CurrentWidth = [int]$source.CurrentFormat.VideoFormat.Width
            CurrentHeight = [int]$source.CurrentFormat.VideoFormat.Height
            ReaderStartStatus = [string]$startStatus
            SoftwareBitmapPresent = [bool]$videoFrame.SoftwareBitmap
            Direct3DSurfacePresent = [bool]$videoFrame.Direct3DSurface
            SurfaceCopyAttempted = $surfacePresent
            SurfaceCopyError = $surfaceCopyError
            Stats = $stats
            Passed = ($null -ne $stats -and $stats.NonBlackPixels -gt 1000)
        }
    }
    finally {
        if ($reader) {
            try { Await-AsyncAction -Action ($reader.StopAsync()) } catch {}
        }
        if ($capture) {
            $capture.Dispose()
        }
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$runDir = New-RunDirectory -Root $ArtifactRoot
$packageRoot = Join-Path $runDir "package"
$htmlPath = Join-Path $runDir "webcam.html"
$statusPath = Join-Path $runDir "held-session-status.json"
$configPath = Join-Path $runDir "held-session-config.json"
$stdoutPath = Join-Path $runDir "held-session.stdout.txt"
$stderrPath = Join-Path $runDir "held-session.stderr.txt"
$resultPath = Join-Path $runDir "media-capture-auto-proof.json"

Add-Type -AssemblyName System.Runtime.WindowsRuntime

New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
Copy-Item -Path (Join-Path $repoRoot "output\*") -Destination $packageRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "software-project\webcam.html") -Destination $htmlPath -Force

$config = [pscustomobject]@{
    PackageRoot = $packageRoot
    HtmlPath = $htmlPath
    Browser = "Chrome"
    AttemptId = "host-auto-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    SourceWindowMode = "ProofPanel"
    CaptureBackend = $CaptureBackend
    LaunchBrowser = $false
    HttpPort = 8000
    GuestStatusPath = $statusPath
    ServeHttp = $false
}
Write-JsonFile -Path $configPath -Data $config

$held = $null
$summary = [ordered]@{
    Success = $false
    RunDir = $runDir
    CaptureBackend = $CaptureBackend
    Results = @()
    Errors = @()
    CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
}

try {
    Get-Process -Name "VirtuaCam", "VirtuaCamProcess", "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $held = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "guest-held-webcam-session.ps1"),
        "-ConfigPath", $configPath
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $statusPath) {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            if ($status.Ready) {
                $summary.HeldSession = $status
                break
            }
            if ($status.LaunchError) {
                throw $status.LaunchError
            }
        }
        if ($held.HasExited) {
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
            throw "Held source exited early: $stderr"
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $summary.HeldSession) {
        throw "Timed out waiting for held VirtuaCam source."
    }

    $memoryPreferences = @("Cpu")
    if ($IncludeAutoSurfaceProbe.IsPresent) {
        $memoryPreferences = @("Auto", "Cpu")
    }

    foreach ($pref in $memoryPreferences) {
        foreach ($sharing in @("ExclusiveControl", "SharedReadOnly")) {
            try {
                $summary.Results += Invoke-FrameReaderProof -MemoryPreference $pref -SharingMode $sharing -DevicePattern $DeviceNamePattern -Timeout $TimeoutSeconds
            }
            catch {
                $summary.Errors += [pscustomobject]@{
                    MemoryPreference = $pref
                    SharingMode = $sharing
                    Error = $_.Exception.Message
                }
            }
        }
    }

    $summary.Success = (@($summary.Results | Where-Object { $_.Passed }).Count -gt 0)
}
finally {
    Export-EventLogSafe -LogName "System" -OutPath (Join-Path $runDir "system.evtx")
    Export-EventLogSafe -LogName "Application" -OutPath (Join-Path $runDir "application.evtx")
    Export-EventLogSafe -LogName "Microsoft-Windows-Kernel-PnP/Configuration" -OutPath (Join-Path $runDir "kernel-pnp-configuration.evtx")
    Get-Process -Name "VirtuaCam", "VirtuaCamProcess" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*show-proof-panel.ps1*" -or $_.CommandLine -like "*serve-webcam.ps1*" } |
        Invoke-CimMethod -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
    if ($held -and -not $held.HasExited) {
        Stop-Process -Id $held.Id -Force -ErrorAction SilentlyContinue
    }
    Write-JsonFile -Path $resultPath -Data ([pscustomobject]$summary)
}

Get-Content -LiteralPath $resultPath -Raw
