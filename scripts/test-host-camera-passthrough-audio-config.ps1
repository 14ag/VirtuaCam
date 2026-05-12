[CmdletBinding()]
param(
    [string]$ArtifactRoot = "test-reports\host-camera-passthrough",
    [string]$VirtualDevicePattern = "Virtual Camera",
    [int]$CameraIndex = 0,
    [int]$TimeoutSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runDir = Join-Path (Join-Path $repoRoot $ArtifactRoot) (Get-Date -Format "yyyyMMdd-HHmmss")
$outputDir = Join-Path $repoRoot "output"
$logDir = Join-Path $outputDir "logs"
$runtimeLog = Join-Path $logDir "virtuacam-runtime.log"
$processLog = Join-Path $logDir "virtuacam-process.log"
$summaryPath = Join-Path $runDir "host-camera-passthrough.json"
$settingsRegPath = "HKCU:\Software\VirtuaCam\Settings"
$legacyConfigPath = Join-Path $env:LOCALAPPDATA "VirtuaCam\settings.ini"

New-Item -ItemType Directory -Force -Path $runDir, $logDir | Out-Null

function Read-TextFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    try { return [string](Get-Content -LiteralPath $Path -Raw -Encoding Unicode) }
    catch { return [string](Get-Content -LiteralPath $Path -Raw) }
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
    $center = ([int]($height / 2) * $width * 4) + ([int]($width / 2) * 4)
    for ($i = 0; $i -lt $bytes.Length; $i += 4) {
        $b = [int]$bytes[$i]
        $g = [int]$bytes[$i + 1]
        $r = [int]$bytes[$i + 2]
        if ($b -gt 6 -or $g -gt 6 -or $r -gt 6) { $nonBlack++ }
        $sumB += $b
        $sumG += $g
        $sumR += $r
    }

    $pixels = [Math]::Max(1, $width * $height)
    [pscustomobject]@{
        Width = $width
        Height = $height
        NonBlackPixels = $nonBlack
        PixelCount = $width * $height
        NonBlackRatio = [Math]::Round($nonBlack / $pixels, 6)
        AverageBgr = @(
            [Math]::Round($sumB / $pixels, 2),
            [Math]::Round($sumG / $pixels, 2),
            [Math]::Round($sumR / $pixels, 2)
        )
        CenterBgr = @([int]$bytes[$center], [int]$bytes[$center + 1], [int]$bytes[$center + 2])
    }
}

function Capture-VirtualCameraFrame {
    param(
        [Parameter(Mandatory = $true)][string]$DevicePattern,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
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

    $selector = $mediaDeviceType::GetVideoCaptureSelector()
    $devices = Await-AsyncOperation -Operation ($deviceInfoType::FindAllAsync($selector)) -ResultType ([Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType=WindowsRuntime])
    $device = $devices | Where-Object { $_.Name -like "*$DevicePattern*" } | Select-Object -First 1
    if (-not $device) { throw "No video capture device matched '$DevicePattern'." }

    $settings = $settingsType::new()
    $settings.VideoDeviceId = $device.Id
    $settings.StreamingCaptureMode = $modeType::Video
    $settings.SharingMode = $sharingType::SharedReadOnly
    $settings.MemoryPreference = $memoryType::Cpu

    $capture = $captureType::new()
    $reader = $null
    try {
        Await-AsyncAction -Action ($capture.InitializeAsync($settings))
        $sources = @($capture.FrameSources | ForEach-Object { $_.Value } | Where-Object { $_.Info.SourceKind -eq $kindType::Color })
        $source = $sources | Where-Object { $_.Info.MediaStreamType -eq $streamType::VideoPreview } | Select-Object -First 1
        if (-not $source) { throw "No color VideoPreview frame source." }

        $reader = Await-AsyncOperation -Operation ($capture.CreateFrameReaderAsync($source)) -ResultType ([Windows.Media.Capture.Frames.MediaFrameReader, Windows.Media.Capture, ContentType=WindowsRuntime])
        $startStatus = Await-AsyncOperation -Operation ($reader.StartAsync()) -ResultType $readerStatusType
        if ([string]$startStatus -ne "Success") { throw "FrameReader start failed: $startStatus" }

        $deadline = (Get-Date).AddSeconds($Timeout)
        while ((Get-Date) -lt $deadline) {
            $frame = $reader.TryAcquireLatestFrame()
            if ($frame -and $frame.VideoMediaFrame -and $frame.VideoMediaFrame.SoftwareBitmap) {
                $stats = Get-BitmapStats -Bitmap $frame.VideoMediaFrame.SoftwareBitmap
                return [pscustomobject]@{
                    DeviceName = $device.Name
                    ReaderStartStatus = [string]$startStatus
                    Stats = $stats
                    Passed = ($stats.NonBlackRatio -gt 0.05)
                }
            }
            Start-Sleep -Milliseconds 200
        }
        throw "No frame arrived within $Timeout seconds."
    }
    finally {
        if ($reader) { Await-AsyncAction -Action ($reader.StopAsync()) }
        if ($capture -is [IDisposable]) { $capture.Dispose() }
    }
}

$app = $null
try {
    Get-Process -Name VirtuaCam,VirtuaCamProcess -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Remove-Item -LiteralPath $runtimeLog, $processLog -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $settingsRegPath) {
        Remove-ItemProperty -LiteralPath $settingsRegPath -Name AudioCaptureDeviceName -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $legacyConfigPath -Force -ErrorAction SilentlyContinue

    $env:VIRTUACAM_ATTEMPT_ID = "host-camera-passthrough"
    $app = Start-Process -FilePath (Join-Path $outputDir "VirtuaCam.exe") `
        -ArgumentList @("-debug", "--source-camera-index", "$CameraIndex") `
        -WorkingDirectory $outputDir `
        -PassThru `
        -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $runtime = ""
    $process = ""
    do {
        Start-Sleep -Milliseconds 500
        $runtime = Read-TextFile -Path $runtimeLog
        $process = Read-TextFile -Path $processLog
    } while ((Get-Date) -lt $deadline -and
        ($runtime -notmatch 'Broker state -> Connected' -or
         $process -notmatch 'First producer frame: type=camera' -or
         $runtime -notmatch 'Audio source selected: Microphone .*Camera .* reason=camera passthrough' -or
         $runtime -notmatch 'Audio capture started: device=Microphone .*Camera .* loopback=0'))

    $frame = Capture-VirtualCameraFrame -DevicePattern $VirtualDevicePattern -Timeout $TimeoutSeconds
    $settings = if (Test-Path -LiteralPath $settingsRegPath) { Get-ItemProperty -LiteralPath $settingsRegPath } else { $null }
    $registryAudioName = if ($settings -and $settings.PSObject.Properties.Name -contains "AudioCaptureDeviceName") {
        [string]$settings.AudioCaptureDeviceName
    } else {
        ""
    }

    $summary = [ordered]@{
        Success = $true
        RunDir = $runDir
        AppPid = $app.Id
        SettingsRegistryPath = $settingsRegPath
        LegacyConfigPath = $legacyConfigPath
        LegacyConfigExists = (Test-Path -LiteralPath $legacyConfigPath)
        SawStereoMixDefault = ($runtime -match 'Audio source selected: Stereo Mix .* reason=startup default')
        SawWebcamMicSelected = ($runtime -match 'Audio source selected: Microphone .*Camera .* reason=camera passthrough')
        WebcamMicCaptureStarted = ($runtime -match 'Audio capture started: device=Microphone .*Camera .* loopback=0')
        AudioPacketSeen = ($runtime -match 'Audio capture packet: frames=')
        RegistryAudioCaptureDeviceName = $registryAudioName
        RegistryHasWebcamMic = ($registryAudioName -match 'Microphone .*Camera')
        CameraProducerStarted = ($process -match 'InitializeProducer success: type=camera')
        CameraProducerFrame = ($process -match 'First producer frame: type=camera')
        BrokerConnected = ($runtime -match 'Broker state -> Connected')
        FrameProof = $frame
        CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    if (-not $summary.SawStereoMixDefault -or
        -not $summary.SawWebcamMicSelected -or
        -not $summary.WebcamMicCaptureStarted -or
        -not $summary.RegistryHasWebcamMic -or
        $summary.LegacyConfigExists -or
        -not $summary.CameraProducerStarted -or
        -not $summary.CameraProducerFrame -or
        -not $summary.BrokerConnected -or
        -not $summary.FrameProof.Passed) {
        $summary.Success = $false
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Copy-Item -LiteralPath $runtimeLog -Destination (Join-Path $runDir "virtuacam-runtime.log") -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $processLog -Destination (Join-Path $runDir "virtuacam-process.log") -Force -ErrorAction SilentlyContinue

    if (-not $summary.Success) {
        throw "Host camera passthrough proof failed. See $summaryPath"
    }

    $summary | ConvertTo-Json -Depth 8
}
finally {
    if ($app -and -not $app.HasExited) {
        Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name VirtuaCamProcess -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
