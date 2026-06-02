[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SkipRuntime,
    [int]$RuntimeSeconds = 3,
    [string]$ArtifactRoot = "",
    [string]$FrameTracePath = "",
    [string]$ReferencePpmPath = "",
    [string]$CapturedPpmPath = "",
    [double]$MaxFreezeEventRate = -1.0,
    [double]$MaxFreezeTimeRatio = -1.0,
    [double]$MaxP95LatencyMs = -1.0,
    [double]$MinPsnrDb = -1.0,
    [double]$MinSsimY = -1.0,
    [switch]$FailOnLimitedColorRange
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))
$SourceRoot = Join-Path $RepoRoot "software-project\src"

if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $RepoRoot ("test-reports\performance-audit\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
} elseif (-not [System.IO.Path]::IsPathRooted($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $RepoRoot $ArtifactRoot
}
New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null

function Read-Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $text = Read-Text -Path $Path
    if ($text -notmatch $Pattern) {
        throw "[FAIL] $Message"
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $text = Read-Text -Path $Path
    if ($text -match $Pattern) {
        throw "[FAIL] $Message"
    }
}

function Get-PpmDumpList {
    $logsDir = Join-Path $RepoRoot "logs"
    if (-not (Test-Path -LiteralPath $logsDir)) {
        return @()
    }
    return @(
        Get-ChildItem -LiteralPath $logsDir -Filter "driverbridge-frame-*.ppm" -File -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    )
}

function Measure-FrameFreezeMetrics {
    param(
        [Parameter(Mandatory = $true)][UInt64[]]$FrameValues,
        [double]$FrameIntervalMs = 33.0
    )

    $duplicateCount = 0
    $freezeEventCount = 0
    $inFreeze = $false
    for ($i = 1; $i -lt $FrameValues.Count; $i++) {
        if ($FrameValues[$i] -eq $FrameValues[$i - 1]) {
            $duplicateCount++
            if (-not $inFreeze) {
                $freezeEventCount++
                $inFreeze = $true
            }
        } else {
            $inFreeze = $false
        }
    }

    $comparisons = [Math]::Max(0, $FrameValues.Count - 1)
    $durationMs = [Math]::Max($FrameIntervalMs, $comparisons * $FrameIntervalMs)
    $freezeMs = $duplicateCount * $FrameIntervalMs
    return [ordered]@{
        sampleCount = $FrameValues.Count
        duplicateFrameCount = $duplicateCount
        freezeEventCount = $freezeEventCount
        freezeEventRate = if ($comparisons -gt 0) { $freezeEventCount / $comparisons } else { 0.0 }
        freezeTimeRatio = if ($durationMs -gt 0) { $freezeMs / $durationMs } else { 0.0 }
    }
}

function Measure-NumericSummary {
    param([Parameter(Mandatory = $true)][double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return [ordered]@{
            average = $null
            p95 = $null
            max = $null
        }
    }

    $sorted = @($Values | Sort-Object)
    $sum = 0.0
    foreach ($value in $Values) { $sum += $value }
    $p95Index = [Math]::Min($sorted.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($sorted.Count * 0.95) - 1))
    return [ordered]@{
        average = $sum / $Values.Count
        p95 = [double]$sorted[$p95Index]
        max = [double]$sorted[-1]
    }
}

function Read-FrameTraceValues {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = New-Object System.Collections.Generic.List[UInt64]
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
        $first = ($trimmed -split ",")[0].Trim()
        [UInt64]$parsed = 0
        if ([UInt64]::TryParse($first, [ref]$parsed)) {
            $values.Add($parsed)
        }
    }
    return [UInt64[]]$values.ToArray()
}

function Read-FrameTraceNumberColumn {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ColumnIndex
    )

    $values = New-Object System.Collections.Generic.List[double]
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed -split ","
        if ($parts.Count -le $ColumnIndex) { continue }
        $parsed = 0.0
        if ([double]::TryParse($parts[$ColumnIndex].Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            $values.Add($parsed)
        }
    }
    return [double[]]$values.ToArray()
}

function Measure-Intervals {
    param([Parameter(Mandatory = $true)][double[]]$TimestampsMs)

    $intervals = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $TimestampsMs.Count; $i++) {
        if ($TimestampsMs[$i] -ge $TimestampsMs[$i - 1]) {
            $intervals.Add($TimestampsMs[$i] - $TimestampsMs[$i - 1])
        }
    }
    return Measure-NumericSummary -Values ([double[]]$intervals.ToArray())
}

function Read-PpmToken {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][ref]$Offset
    )

    while ($Offset.Value -lt $Bytes.Count) {
        $b = $Bytes[$Offset.Value]
        if ($b -eq 35) {
            while ($Offset.Value -lt $Bytes.Count -and $Bytes[$Offset.Value] -notin 10, 13) { $Offset.Value++ }
            continue
        }
        if ($b -notin 9, 10, 13, 32) { break }
        $Offset.Value++
    }

    $start = $Offset.Value
    while ($Offset.Value -lt $Bytes.Count -and $Bytes[$Offset.Value] -notin 9, 10, 13, 32) {
        $Offset.Value++
    }
    if ($Offset.Value -le $start) { return "" }
    return [Text.Encoding]::ASCII.GetString($Bytes, $start, $Offset.Value - $start)
}

function Read-PpmP6 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    [int]$offset = 0
    $magic = Read-PpmToken -Bytes $bytes -Offset ([ref]$offset)
    if ($magic -ne "P6") { throw "[FAIL] Unsupported PPM format in $Path. Expected P6." }
    $width = [int](Read-PpmToken -Bytes $bytes -Offset ([ref]$offset))
    $height = [int](Read-PpmToken -Bytes $bytes -Offset ([ref]$offset))
    $max = [int](Read-PpmToken -Bytes $bytes -Offset ([ref]$offset))
    if ($width -le 0 -or $height -le 0 -or $max -ne 255) {
        throw "[FAIL] Invalid PPM header in $Path."
    }
    if ($offset -lt $bytes.Count -and $bytes[$offset] -in 9, 10, 13, 32) {
        $offset++
    }
    $required = $width * $height * 3
    if (($bytes.Count - $offset) -lt $required) {
        throw "[FAIL] Short PPM payload in $Path."
    }

    $payload = New-Object byte[] $required
    [Array]::Copy($bytes, $offset, $payload, 0, $required)
    return [ordered]@{
        width = $width
        height = $height
        data = $payload
    }
}

function Measure-PpmPsnr {
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$CapturedPath
    )

    $reference = Read-PpmP6 -Path $ReferencePath
    $captured = Read-PpmP6 -Path $CapturedPath
    if ($reference.width -ne $captured.width -or $reference.height -ne $captured.height) {
        throw "[FAIL] PPM dimensions differ: $ReferencePath vs $CapturedPath"
    }

    $sumSquaredError = 0.0
    for ($i = 0; $i -lt $reference.data.Count; $i++) {
        $delta = [double]$reference.data[$i] - [double]$captured.data[$i]
        $sumSquaredError += $delta * $delta
    }

    $mse = $sumSquaredError / $reference.data.Count
    $psnr = if ($mse -le 0.0) { 99.0 } else { 10.0 * [Math]::Log10((255.0 * 255.0) / $mse) }
    return [ordered]@{
        width = $reference.width
        height = $reference.height
        comparedChannelCount = $reference.data.Count
        meanSquaredError = $mse
        psnrDb = $psnr
    }
}

function Measure-PpmSsimY {
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$CapturedPath
    )

    $reference = Read-PpmP6 -Path $ReferencePath
    $captured = Read-PpmP6 -Path $CapturedPath
    if ($reference.width -ne $captured.width -or $reference.height -ne $captured.height) {
        throw "[FAIL] PPM dimensions differ: $ReferencePath vs $CapturedPath"
    }

    $count = [int]($reference.data.Count / 3)
    if ($count -le 0) { throw "[FAIL] Empty PPM payload in $ReferencePath." }

    $sumX = 0.0
    $sumY = 0.0
    $sumX2 = 0.0
    $sumY2 = 0.0
    $sumXY = 0.0
    for ($i = 0; $i -lt $reference.data.Count; $i += 3) {
        $x = (0.2126 * [double]$reference.data[$i]) + (0.7152 * [double]$reference.data[$i + 1]) + (0.0722 * [double]$reference.data[$i + 2])
        $y = (0.2126 * [double]$captured.data[$i]) + (0.7152 * [double]$captured.data[$i + 1]) + (0.0722 * [double]$captured.data[$i + 2])
        $sumX += $x
        $sumY += $y
        $sumX2 += $x * $x
        $sumY2 += $y * $y
        $sumXY += $x * $y
    }

    $meanX = $sumX / $count
    $meanY = $sumY / $count
    $varianceX = [Math]::Max(0.0, ($sumX2 / $count) - ($meanX * $meanX))
    $varianceY = [Math]::Max(0.0, ($sumY2 / $count) - ($meanY * $meanY))
    $covariance = ($sumXY / $count) - ($meanX * $meanY)
    $c1 = [Math]::Pow(0.01 * 255.0, 2.0)
    $c2 = [Math]::Pow(0.03 * 255.0, 2.0)
    $denominator = (($meanX * $meanX) + ($meanY * $meanY) + $c1) * ($varianceX + $varianceY + $c2)
    $ssim = if ($denominator -le 0.0) { 1.0 } else { (((2.0 * $meanX * $meanY) + $c1) * ((2.0 * $covariance) + $c2)) / $denominator }

    return [ordered]@{
        width = $reference.width
        height = $reference.height
        comparedPixelCount = $count
        ssimY = $ssim
    }
}

function Measure-PpmColorRange {
    param([Parameter(Mandatory = $true)][string]$Path)

    $ppm = Read-PpmP6 -Path $Path
    $minR = 255; $minG = 255; $minB = 255
    $maxR = 0; $maxG = 0; $maxB = 0
    for ($i = 0; $i -lt $ppm.data.Count; $i += 3) {
        $r = [int]$ppm.data[$i]
        $g = [int]$ppm.data[$i + 1]
        $b = [int]$ppm.data[$i + 2]
        if ($r -lt $minR) { $minR = $r }
        if ($g -lt $minG) { $minG = $g }
        if ($b -lt $minB) { $minB = $b }
        if ($r -gt $maxR) { $maxR = $r }
        if ($g -gt $maxG) { $maxG = $g }
        if ($b -gt $maxB) { $maxB = $b }
    }

    $rangeR = $maxR - $minR
    $rangeG = $maxG - $minG
    $rangeB = $maxB - $minB
    return [ordered]@{
        width = $ppm.width
        height = $ppm.height
        minR = $minR
        maxR = $maxR
        rangeR = $rangeR
        minG = $minG
        maxG = $maxG
        rangeG = $rangeG
        minB = $minB
        maxB = $maxB
        rangeB = $rangeB
        limitedRangeLikely = ($minR -ge 16 -and $minG -ge 16 -and $minB -ge 16 -and $maxR -le 235 -and $maxG -le 235 -and $maxB -le 235)
    }
}

$freezeSelfTest = Measure-FrameFreezeMetrics -FrameValues ([UInt64[]]@(1, 2, 2, 2, 3, 4, 4)) -FrameIntervalMs 33
if ($freezeSelfTest.duplicateFrameCount -ne 3 -or $freezeSelfTest.freezeEventCount -ne 2) {
    throw "[FAIL] freeze metric self-test failed."
}
$summarySelfTest = Measure-NumericSummary -Values ([double[]]@(10, 20, 30, 40))
if ($summarySelfTest.average -ne 25 -or $summarySelfTest.max -ne 40) {
    throw "[FAIL] numeric summary self-test failed."
}
$ppmSelfTestDir = Join-Path $ArtifactRoot "_metric-selftest"
New-Item -ItemType Directory -Path $ppmSelfTestDir -Force | Out-Null
$ppmSelfTestPath = Join-Path $ppmSelfTestDir "bars.ppm"
$ppmHeader = [Text.Encoding]::ASCII.GetBytes("P6`n2 1`n255`n")
$ppmPixels = [byte[]]@(255, 0, 0, 0, 255, 0)
$ppmBytes = New-Object byte[] ($ppmHeader.Count + $ppmPixels.Count)
[Buffer]::BlockCopy($ppmHeader, 0, $ppmBytes, 0, $ppmHeader.Count)
[Buffer]::BlockCopy($ppmPixels, 0, $ppmBytes, $ppmHeader.Count, $ppmPixels.Count)
[IO.File]::WriteAllBytes($ppmSelfTestPath, $ppmBytes)
$ssimSelfTest = Measure-PpmSsimY -ReferencePath $ppmSelfTestPath -CapturedPath $ppmSelfTestPath
if ([Math]::Abs($ssimSelfTest.ssimY - 1.0) -gt 0.0000001) {
    throw "[FAIL] SSIM-Y metric self-test failed."
}
$colorRangeSelfTest = Measure-PpmColorRange -Path $ppmSelfTestPath
if ($colorRangeSelfTest.maxR -ne 255 -or $colorRangeSelfTest.maxG -ne 255 -or $colorRangeSelfTest.maxB -ne 0) {
    throw "[FAIL] color-range metric self-test failed."
}
Remove-Item -LiteralPath $ppmSelfTestDir -Recurse -Force

$appCpp = Join-Path $SourceRoot "VirtuaCam\App.cpp"
$brokerCpp = Join-Path $SourceRoot "VirtuaCam\Broker.cpp"
$driverBridgeCpp = Join-Path $SourceRoot "VirtuaCam\DriverBridge.cpp"
$multiplexerCpp = Join-Path $SourceRoot "VirtuaCam\Multiplexer.cpp"
$multiplexerH = Join-Path $SourceRoot "VirtuaCam\Multiplexer.h"
$processCpp = Join-Path $SourceRoot "VirtuaCam\Process.cpp"
$toolsH = Join-Path $SourceRoot "VirtuaCam\Tools.h"
$toolsCpp = Join-Path $SourceRoot "VirtuaCam\Tools.cpp"
$discoveryH = Join-Path $SourceRoot "VirtuaCam\Discovery.h"
$discoveryCpp = Join-Path $SourceRoot "VirtuaCam\Discovery.cpp"
$cmakeLists = Join-Path $SourceRoot "CMakeLists.txt"
$auditMetrics = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    targetFrameIntervalMs = 33
    targetFps = 30
    buildSkipped = [bool]$SkipBuild
    runtimeSkipped = [bool]$SkipRuntime
    runtimeSeconds = [int]$RuntimeSeconds
    noDebugPpmDumpCount = $null
    noDebugPpmDumpPass = $null
    thresholds = [ordered]@{
        maxFreezeEventRate = $MaxFreezeEventRate
        maxFreezeTimeRatio = $MaxFreezeTimeRatio
        maxP95LatencyMs = $MaxP95LatencyMs
        minPsnrDb = $MinPsnrDb
        minSsimY = $MinSsimY
        failOnLimitedColorRange = [bool]$FailOnLimitedColorRange
    }
    producer = [ordered]@{
        hasLatestFrameHandoff = $false
        hasDroppedSampleCounter = $false
        hasDuplicateCounter = $false
        hasStaleCounter = $false
        validatesRgb32 = $false
        rejectsShortRgb32Buffers = $false
    }
    broker = [ordered]@{
        skipsUnchangedFrames = $false
        dropsStaleProducerWhenFreshExists = $false
        avoidsPerFrameDiscovery = $false
    }
    driverBridge = [ordered]@{
        hasReadbackPool = $false
        usesNonBlockingMap = $false
        hasReadbackNotReadyCounter = $false
        logsReadbackNotReady = $false
        legacyFallbackPreserved = $false
    }
    freeze = [ordered]@{
        duplicateFrameCounterPresent = $false
        staleFrameCounterPresent = $false
        freezeEventRateMeasured = $false
        freezeEventRate = $null
        freezeTimeRatioMeasured = $false
        freezeTimeRatio = $null
        sampleCount = 0
        duplicateFrameCount = 0
        freezeEventCount = 0
        note = "Runtime frame-freeze rate needs a consumer frame-id trace; static contracts are validated here."
    }
    cadence = [ordered]@{
        measured = $false
        averageIntervalMs = $null
        p95IntervalMs = $null
        maxIntervalMs = $null
    }
    latency = [ordered]@{
        measured = $false
        averageMs = $null
        p95Ms = $null
        maxMs = $null
    }
    quality = [ordered]@{
        ssimYMeasured = $false
        ssimY = $null
        psnrMeasured = $false
        psnrDb = $null
        meanSquaredError = $null
        comparedChannelCount = 0
        colorRangeMeasured = $false
        capturedMinR = $null
        capturedMaxR = $null
        capturedMinG = $null
        capturedMaxG = $null
        capturedMinB = $null
        capturedMaxB = $null
        capturedLimitedRangeLikely = $null
        note = "Matched-frame SSIM/PSNR hooks require reference and captured frame pairs; cadence/freeze metrics are available from frame traces."
    }
}

Assert-Contains -Path $appCpp -Pattern "kAppFrameIntervalMs\s*=\s*33" -Message "App frame scheduler must target 30 fps."
Assert-Contains -Path $appCpp -Pattern "GetBrokerFrameValue" -Message "App must query broker frame value."
Assert-Contains -Path $appCpp -Pattern "brokerFrameValue\s*==\s*s_lastSentFrameValue" -Message "App must skip unchanged broker frames."
$auditMetrics.broker.skipsUnchangedFrames = $true
Assert-Contains -Path $brokerCpp -Pattern "kDiscoveryIntervalMs\s*=\s*1000" -Message "Broker discovery must be throttled."
Assert-Contains -Path $brokerCpp -Pattern "GetBrokerFrameValue" -Message "Broker frame-value export missing."
Assert-Contains -Path $cmakeLists -Pattern "GetBrokerFrameValue" -Message "Broker .def export missing from CMake."
Assert-Contains -Path $multiplexerH -Pattern "SetOutputTexture" -Message "Multiplexer must accept broker-owned output texture."
Assert-Contains -Path $brokerCpp -Pattern "SetOutputTexture\(g_sharedTex_Out\.Get\(\)\)" -Message "Broker must wire shared output texture into multiplexer."
Assert-NotContains -Path $brokerCpp -Pattern "CopyResource\(g_sharedTex_Out\.Get\(\), g_multiplexer->GetOutputTexture\(\)\)" -Message "Broker must not copy multiplexer output into shared texture per frame."
Assert-Contains -Path $multiplexerCpp -Pattern "m_outputTexture\.Get\(\) != m_compositeTexture\.Get\(\)" -Message "Multiplexer must skip output copy when rendering directly to shared output."
Assert-Contains -Path $multiplexerCpp -Pattern "manifestView" -Message "Multiplexer must cache mapped producer manifests."
Assert-Contains -Path $multiplexerCpp -Pattern "if \(!forceComposite && !inputFrameChanged\)" -Message "Multiplexer must skip unchanged composites."
Assert-Contains -Path $toolsH -Pattern "struct DirectPortStatusV1" -Message "DirectPort sidecar status ABI missing."
Assert-Contains -Path $toolsH -Pattern "VIRTUACAM_DIRECTPORT_STATUS_VERSION\s*=\s*1u" -Message "DirectPort status version must be v1."
Assert-Contains -Path $toolsH -Pattern "volatile LONGLONG publishSequence" -Message "DirectPort status must use odd/even publish sequence."
Assert-Contains -Path $toolsH -Pattern "sampleAgeQpcDelta" -Message "DirectPort status must expose callback-to-publish sample age telemetry."
Assert-Contains -Path $toolsH -Pattern "droppedCallbackSampleCount" -Message "DirectPort status must expose dropped callback sample telemetry separately from stale frames."
Assert-Contains -Path $toolsH -Pattern "GetProducerStatusName" -Message "DirectPort status mapping name helper missing."
Assert-Contains -Path $toolsCpp -Pattern "InitializeDirectPortStatus" -Message "DirectPort status initializer missing."
Assert-Contains -Path $toolsCpp -Pattern "PublishDirectPortStatus" -Message "DirectPort status publisher missing."
Assert-Contains -Path $toolsCpp -Pattern "ReadDirectPortStatusStable" -Message "DirectPort stable status reader missing."
Assert-Contains -Path $toolsCpp -Pattern "beginSequence == endSequence" -Message "DirectPort reader must reject partial status updates."
Assert-Contains -Path $toolsCpp -Pattern "beginWriteSequence" -Message "DirectPort publisher must mark odd write sequence before field updates."
Assert-Contains -Path $toolsCpp -Pattern "status->sampleAgeQpcDelta = sampleAgeQpcDelta" -Message "DirectPort publisher must write sample age telemetry inside stable publish sequence."
Assert-Contains -Path $toolsCpp -Pattern "status->droppedCallbackSampleCount = droppedCallbackSampleCount" -Message "DirectPort publisher must write dropped callback count inside stable publish sequence."
Assert-Contains -Path $processCpp -Pattern "DirectPortStatusMapping" -Message "Producer status mapping wrapper missing."
Assert-Contains -Path $processCpp -Pattern "InitializeDirectPortStatusMapping" -Message "Producer must initialize DirectPort status sidecar."
Assert-Contains -Path $processCpp -Pattern "PublishDirectPortProducerStatus" -Message "Producer must publish DirectPort status."
Assert-Contains -Path $processCpp -Pattern "GetProducerStatusName" -Message "Producer status sidecar must use named mapping."
Assert-Contains -Path $processCpp -Pattern "class AsyncSourceReaderCallback final : public IMFSourceReaderCallback" -Message "Camera/file producers must use async Source Reader callback mode."
Assert-Contains -Path $processCpp -Pattern "MF_SOURCE_READER_ASYNC_CALLBACK" -Message "Source Reader callback must be configured before reader creation."
Assert-Contains -Path $processCpp -Pattern "TryTakeLatest" -Message "Async Source Reader path must expose a latest-sample handoff."
$auditMetrics.producer.hasLatestFrameHandoff = $true
Assert-Contains -Path $processCpp -Pattern "m_droppedSamples" -Message "Async Source Reader callback must overwrite stale samples instead of queuing unbounded frames."
$auditMetrics.producer.hasDroppedSampleCounter = $true
Assert-Contains -Path $processCpp -Pattern "DroppedSamples\(\)" -Message "Async Source Reader dropped-sample count must be observable."
Assert-Contains -Path $processCpp -Pattern "g_sourceReaderCallback->DroppedSamples\(\)" -Message "Producer status must publish async dropped-sample count."
Assert-Contains -Path $processCpp -Pattern "m_latestCallbackQpc" -Message "Async Source Reader callback must capture producer-side QPC for sample age telemetry."
Assert-Contains -Path $processCpp -Pattern "sampleAgeQpcDelta" -Message "Producer status must compute callback-to-publish sample age."
Assert-Contains -Path $processCpp -Pattern "SelectRgb32MediaType" -Message "Camera/file producers must validate RGB32 media type before BGRA upload."
$auditMetrics.producer.validatesRgb32 = $true
Assert-Contains -Path $processCpp -Pattern "subtype != MFVideoFormat_RGB32" -Message "Camera/file producers must reject non-RGB32 current media types."
Assert-Contains -Path $processCpp -Pattern "length\) < requiredBytes" -Message "Camera/file producers must reject short RGB32 sample buffers."
$auditMetrics.producer.rejectsShortRgb32Buffers = $true
Assert-NotContains -Path $processCpp -Pattern "ReadSample\([^\r\n]*&streamFlags" -Message "Camera/file hot path must not use blocking Source Reader ReadSample output parameters."
Assert-Contains -Path $discoveryH -Pattern "DiscoverStreams\(const std::map<DWORD, UINT64>& expectedProducers\)" -Message "Discovery must support expected-producer fast path."
Assert-Contains -Path $discoveryCpp -Pattern "TryAddStreamForPid" -Message "Discovery must use PID-targeted manifest probing."
Assert-Contains -Path $discoveryCpp -Pattern "ReadDirectPortStatusStable" -Message "Discovery must read stable producer status when present."
Assert-Contains -Path $brokerCpp -Pattern "DiscoverStreams\(expectedProducers\)" -Message "Broker must pass expected producers into discovery."
Assert-Contains -Path $multiplexerH -Pattern "DirectPortStatusV1\* statusView" -Message "Multiplexer must cache mapped producer status sidecar."
Assert-Contains -Path $multiplexerH -Pattern "copyCount" -Message "Multiplexer must track producer copy count."
Assert-Contains -Path $multiplexerCpp -Pattern "IsProducerStatusStale" -Message "Multiplexer stale producer policy missing."
Assert-Contains -Path $multiplexerCpp -Pattern "hasFreshStatusProducer && res\.staleByStatus" -Message "Multiplexer must drop stale producer when fresher status exists."
$auditMetrics.broker.dropsStaleProducerWhenFreshExists = $true
Assert-Contains -Path $multiplexerCpp -Pattern "\+\+res\.copyCount" -Message "Multiplexer must count producer shared-texture copies."
Assert-Contains -Path $processCpp -Pattern "kProducerFrameIntervalMs\s*=\s*33" -Message "Producer loop must use frame cadence."
Assert-Contains -Path $processCpp -Pattern "kProducerIdleBackoffMaxMs\s*=\s*250" -Message "Producer loop must have adaptive idle backoff."
Assert-Contains -Path $processCpp -Pattern "producedFrame\s*= module\.Process\(\)" -Message "Producer loop must use frame production result."
Assert-NotContains -Path $processCpp -Pattern "kProducerIdleWaitMs" -Message "Producer 1 ms polling constant must be removed."
Assert-Contains -Path $processCpp -Pattern "struct GdiCaptureCache" -Message "GDI fallback must cache capture objects."
Assert-NotContains -Path $processCpp -Pattern "g_gdiFrame" -Message "GDI fallback must avoid extra frame-copy buffer."
Assert-Contains -Path $processCpp -Pattern "UpdateSubresource\(g_sourceD3D11Texture\.Get\(\), 0, nullptr, g_gdiCache\.bits" -Message "GDI fallback must upload DIB bits directly."
Assert-Contains -Path $driverBridgeCpp -Pattern "DriverFrameDumpEnabled\(\) && \(n == 1 \|\| n == 90\)" -Message "DriverBridge PPM dumps must be debug-gated."
Assert-Contains -Path $driverBridgeCpp -Pattern "kDriverReadbackPoolSize\s*=\s*3" -Message "DriverBridge must keep a three-slot readback pool."
$auditMetrics.driverBridge.hasReadbackPool = $true
Assert-Contains -Path $driverBridgeCpp -Pattern "QueueReadbackAndMapReady" -Message "DriverBridge must queue GPU readbacks through the staging pool."
Assert-Contains -Path $driverBridgeCpp -Pattern "D3D11_MAP_FLAG_DO_NOT_WAIT" -Message "DriverBridge readback pool must avoid blocking Map when possible."
$auditMetrics.driverBridge.usesNonBlockingMap = $true
Assert-Contains -Path $driverBridgeCpp -Pattern "return DXGI_ERROR_WAS_STILL_DRAWING" -Message "DriverBridge must report readback-not-ready distinctly from driver warmup retry."
Assert-Contains -Path $driverBridgeCpp -Pattern "m_readbackNotReadyCount" -Message "DriverBridge must count readback-not-ready events separately."
$auditMetrics.driverBridge.hasReadbackNotReadyCounter = $true
Assert-Contains -Path $driverBridgeCpp -Pattern "readbackNotReady=" -Message "DriverBridge status logs must expose readback-not-ready count."
Assert-Contains -Path (Join-Path $RepoRoot "software-project\src\VirtuaCam\App.cpp") -Pattern "readback not ready" -Message "App must log readback-not-ready separately from driver warmup."
$auditMetrics.driverBridge.logsReadbackNotReady = $true
Assert-NotContains -Path $driverBridgeCpp -Pattern "Map\(m_stagingTexture\.get\(\), 0, D3D11_MAP_READ, 0" -Message "DriverBridge must not use single blocking BGRA staging maps."
Assert-NotContains -Path $driverBridgeCpp -Pattern "Map\(m_nv12StagingTexture\.get\(\), 0, D3D11_MAP_READ, 0" -Message "DriverBridge must not use single blocking NV12 staging maps."

$muxText = Read-Text -Path $multiplexerCpp
if ($muxText -match "for \(auto& res : m_producerResources\)[\s\S]{0,260}OpenFileMappingW") {
    throw "[FAIL] Multiplexer still opens producer manifests inside per-frame resource loop."
}
$auditMetrics.broker.avoidsPerFrameDiscovery = $true

$toolsText = Read-Text -Path $toolsH
$auditMetrics.producer.hasDuplicateCounter = ($toolsText -match "duplicateCount")
$auditMetrics.producer.hasStaleCounter = ($toolsText -match "staleCount")
$auditMetrics.freeze.duplicateFrameCounterPresent = $auditMetrics.producer.hasDuplicateCounter
$auditMetrics.freeze.staleFrameCounterPresent = $auditMetrics.producer.hasStaleCounter

$driverText = Read-Text -Path $driverBridgeCpp
$auditMetrics.driverBridge.legacyFallbackPreserved = ($driverText -match "UploadMappedFrame\(mapped\)")

if (-not [string]::IsNullOrWhiteSpace($FrameTracePath)) {
    if (-not [System.IO.Path]::IsPathRooted($FrameTracePath)) {
        $FrameTracePath = Join-Path $RepoRoot $FrameTracePath
    }
    if (-not (Test-Path -LiteralPath $FrameTracePath)) {
        throw "[FAIL] Frame trace not found: $FrameTracePath"
    }
    $frameValues = Read-FrameTraceValues -Path $FrameTracePath
    $freezeMetrics = Measure-FrameFreezeMetrics -FrameValues $frameValues -FrameIntervalMs $auditMetrics.targetFrameIntervalMs
    $auditMetrics.freeze.freezeEventRateMeasured = $true
    $auditMetrics.freeze.freezeEventRate = $freezeMetrics.freezeEventRate
    $auditMetrics.freeze.freezeTimeRatioMeasured = $true
    $auditMetrics.freeze.freezeTimeRatio = $freezeMetrics.freezeTimeRatio
    $auditMetrics.freeze.sampleCount = $freezeMetrics.sampleCount
    $auditMetrics.freeze.duplicateFrameCount = $freezeMetrics.duplicateFrameCount
    $auditMetrics.freeze.freezeEventCount = $freezeMetrics.freezeEventCount
    $auditMetrics.freeze.note = "Freeze metrics measured from frame trace: $FrameTracePath"

    $timestampsMs = Read-FrameTraceNumberColumn -Path $FrameTracePath -ColumnIndex 1
    if ($timestampsMs.Count -gt 1) {
        $cadence = Measure-Intervals -TimestampsMs $timestampsMs
        $auditMetrics.cadence.measured = $true
        $auditMetrics.cadence.averageIntervalMs = $cadence.average
        $auditMetrics.cadence.p95IntervalMs = $cadence.p95
        $auditMetrics.cadence.maxIntervalMs = $cadence.max
    }

    $latencyMs = Read-FrameTraceNumberColumn -Path $FrameTracePath -ColumnIndex 2
    if ($latencyMs.Count -gt 0) {
        $latency = Measure-NumericSummary -Values $latencyMs
        $auditMetrics.latency.measured = $true
        $auditMetrics.latency.averageMs = $latency.average
        $auditMetrics.latency.p95Ms = $latency.p95
        $auditMetrics.latency.maxMs = $latency.max
    }
}

if (-not [string]::IsNullOrWhiteSpace($ReferencePpmPath) -or -not [string]::IsNullOrWhiteSpace($CapturedPpmPath)) {
    if ([string]::IsNullOrWhiteSpace($ReferencePpmPath) -or [string]::IsNullOrWhiteSpace($CapturedPpmPath)) {
        throw "[FAIL] Provide both -ReferencePpmPath and -CapturedPpmPath."
    }
    if (-not [System.IO.Path]::IsPathRooted($ReferencePpmPath)) {
        $ReferencePpmPath = Join-Path $RepoRoot $ReferencePpmPath
    }
    if (-not [System.IO.Path]::IsPathRooted($CapturedPpmPath)) {
        $CapturedPpmPath = Join-Path $RepoRoot $CapturedPpmPath
    }
    if (-not (Test-Path -LiteralPath $ReferencePpmPath)) { throw "[FAIL] Reference PPM not found: $ReferencePpmPath" }
    if (-not (Test-Path -LiteralPath $CapturedPpmPath)) { throw "[FAIL] Captured PPM not found: $CapturedPpmPath" }

    $psnr = Measure-PpmPsnr -ReferencePath $ReferencePpmPath -CapturedPath $CapturedPpmPath
    $ssim = Measure-PpmSsimY -ReferencePath $ReferencePpmPath -CapturedPath $CapturedPpmPath
    $colorRange = Measure-PpmColorRange -Path $CapturedPpmPath
    $auditMetrics.quality.psnrMeasured = $true
    $auditMetrics.quality.psnrDb = $psnr.psnrDb
    $auditMetrics.quality.meanSquaredError = $psnr.meanSquaredError
    $auditMetrics.quality.comparedChannelCount = $psnr.comparedChannelCount
    $auditMetrics.quality.ssimYMeasured = $true
    $auditMetrics.quality.ssimY = $ssim.ssimY
    $auditMetrics.quality.colorRangeMeasured = $true
    $auditMetrics.quality.capturedMinR = $colorRange.minR
    $auditMetrics.quality.capturedMaxR = $colorRange.maxR
    $auditMetrics.quality.capturedMinG = $colorRange.minG
    $auditMetrics.quality.capturedMaxG = $colorRange.maxG
    $auditMetrics.quality.capturedMinB = $colorRange.minB
    $auditMetrics.quality.capturedMaxB = $colorRange.maxB
    $auditMetrics.quality.capturedLimitedRangeLikely = $colorRange.limitedRangeLikely
    $auditMetrics.quality.note = "PSNR, SSIM-Y, and captured color range measured from P6 PPM pair."
}

if ($MaxFreezeEventRate -ge 0.0) {
    if (-not $auditMetrics.freeze.freezeEventRateMeasured) {
        throw "[FAIL] -MaxFreezeEventRate requires -FrameTracePath."
    }
    if ($auditMetrics.freeze.freezeEventRate -gt $MaxFreezeEventRate) {
        throw "[FAIL] Freeze event rate $($auditMetrics.freeze.freezeEventRate) exceeds max $MaxFreezeEventRate."
    }
}

if ($MaxFreezeTimeRatio -ge 0.0) {
    if (-not $auditMetrics.freeze.freezeTimeRatioMeasured) {
        throw "[FAIL] -MaxFreezeTimeRatio requires -FrameTracePath."
    }
    if ($auditMetrics.freeze.freezeTimeRatio -gt $MaxFreezeTimeRatio) {
        throw "[FAIL] Freeze time ratio $($auditMetrics.freeze.freezeTimeRatio) exceeds max $MaxFreezeTimeRatio."
    }
}

if ($MaxP95LatencyMs -ge 0.0) {
    if (-not $auditMetrics.latency.measured) {
        throw "[FAIL] -MaxP95LatencyMs requires latency column in -FrameTracePath."
    }
    if ($auditMetrics.latency.p95Ms -gt $MaxP95LatencyMs) {
        throw "[FAIL] P95 latency $($auditMetrics.latency.p95Ms) ms exceeds max $MaxP95LatencyMs ms."
    }
}

if ($MinPsnrDb -ge 0.0) {
    if (-not $auditMetrics.quality.psnrMeasured) {
        throw "[FAIL] -MinPsnrDb requires -ReferencePpmPath and -CapturedPpmPath."
    }
    if ($auditMetrics.quality.psnrDb -lt $MinPsnrDb) {
        throw "[FAIL] PSNR $($auditMetrics.quality.psnrDb) dB is below min $MinPsnrDb dB."
    }
}

if ($MinSsimY -ge 0.0) {
    if (-not $auditMetrics.quality.ssimYMeasured) {
        throw "[FAIL] -MinSsimY requires -ReferencePpmPath and -CapturedPpmPath."
    }
    if ($auditMetrics.quality.ssimY -lt $MinSsimY) {
        throw "[FAIL] SSIM-Y $($auditMetrics.quality.ssimY) is below min $MinSsimY."
    }
}

if ($FailOnLimitedColorRange) {
    if (-not $auditMetrics.quality.colorRangeMeasured) {
        throw "[FAIL] -FailOnLimitedColorRange requires -ReferencePpmPath and -CapturedPpmPath."
    }
    if ($auditMetrics.quality.capturedLimitedRangeLikely) {
        throw "[FAIL] Captured PPM appears limited-range; check NV12/BGRA color-range handling."
    }
}

if (-not $SkipBuild) {
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $cmake) {
        throw "[FAIL] cmake not found."
    }

    $buildDir = Join-Path $RepoRoot "software-project\build"
    & $cmake.Path --build $buildDir --config Release --target VirtuaCam DirectPortBroker VirtuaCamProcess
    if ($LASTEXITCODE -ne 0) {
        throw "[FAIL] software build failed."
    }
}

if (-not $SkipRuntime) {
    $exePath = Join-Path $RepoRoot "software-project\build\Release\VirtuaCam.exe"
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "[FAIL] VirtuaCam.exe missing. Run without -SkipBuild first."
    }

    $before = Get-PpmDumpList
    $proc = $null
    try {
        $proc = Start-Process -FilePath $exePath -WorkingDirectory (Split-Path -Parent $exePath) -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds $RuntimeSeconds
    }
    finally {
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $proc.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
    }

    $after = Get-PpmDumpList
    $newDumps = @($after | Where-Object { $before -notcontains $_ })
    $auditMetrics.noDebugPpmDumpCount = $newDumps.Count
    $auditMetrics.noDebugPpmDumpPass = ($newDumps.Count -eq 0)
    if ($newDumps.Count -gt 0) {
        throw "[FAIL] VirtuaCam without -debug created DriverBridge PPM dumps."
    }
}

$jsonPath = Join-Path $ArtifactRoot "performance-audit.json"
$mdPath = Join-Path $ArtifactRoot "performance-audit.md"
$auditMetrics | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$md = @(
    "# VirtuaCam Performance Audit",
    "",
    "- Generated UTC: $($auditMetrics.generatedAtUtc)",
    "- Target FPS: $($auditMetrics.targetFps)",
    "- Runtime seconds: $($auditMetrics.runtimeSeconds)",
    "- Max freeze event rate threshold: $($auditMetrics.thresholds.maxFreezeEventRate)",
    "- Max freeze time ratio threshold: $($auditMetrics.thresholds.maxFreezeTimeRatio)",
    "- Max P95 latency ms threshold: $($auditMetrics.thresholds.maxP95LatencyMs)",
    "- Min PSNR dB threshold: $($auditMetrics.thresholds.minPsnrDb)",
    "- Min SSIM-Y threshold: $($auditMetrics.thresholds.minSsimY)",
    "- Fail on limited color range: $($auditMetrics.thresholds.failOnLimitedColorRange)",
    "- No-debug PPM dump count: $($auditMetrics.noDebugPpmDumpCount)",
    "- Producer dropped-sample counter present: $($auditMetrics.producer.hasDroppedSampleCounter)",
    "- Duplicate counter present: $($auditMetrics.freeze.duplicateFrameCounterPresent)",
    "- Stale counter present: $($auditMetrics.freeze.staleFrameCounterPresent)",
    "- Readback-not-ready counter present: $($auditMetrics.driverBridge.hasReadbackNotReadyCounter)",
    "- Freeze event rate measured: $($auditMetrics.freeze.freezeEventRateMeasured)",
    "- Freeze event rate: $($auditMetrics.freeze.freezeEventRate)",
    "- Freeze time ratio measured: $($auditMetrics.freeze.freezeTimeRatioMeasured)",
    "- Freeze time ratio: $($auditMetrics.freeze.freezeTimeRatio)",
    "- Cadence measured: $($auditMetrics.cadence.measured)",
    "- Average interval ms: $($auditMetrics.cadence.averageIntervalMs)",
    "- P95 interval ms: $($auditMetrics.cadence.p95IntervalMs)",
    "- Max interval ms: $($auditMetrics.cadence.maxIntervalMs)",
    "- Latency measured: $($auditMetrics.latency.measured)",
    "- Average latency ms: $($auditMetrics.latency.averageMs)",
    "- P95 latency ms: $($auditMetrics.latency.p95Ms)",
    "- Max latency ms: $($auditMetrics.latency.maxMs)",
    "- SSIM-Y measured: $($auditMetrics.quality.ssimYMeasured)",
    "- SSIM-Y: $($auditMetrics.quality.ssimY)",
    "- PSNR measured: $($auditMetrics.quality.psnrMeasured)",
    "- PSNR dB: $($auditMetrics.quality.psnrDb)",
    "- MSE: $($auditMetrics.quality.meanSquaredError)",
    "- Color range measured: $($auditMetrics.quality.colorRangeMeasured)",
    "- Captured R range: $($auditMetrics.quality.capturedMinR)..$($auditMetrics.quality.capturedMaxR)",
    "- Captured G range: $($auditMetrics.quality.capturedMinG)..$($auditMetrics.quality.capturedMaxG)",
    "- Captured B range: $($auditMetrics.quality.capturedMinB)..$($auditMetrics.quality.capturedMaxB)",
    "- Captured limited range likely: $($auditMetrics.quality.capturedLimitedRangeLikely)",
    "",
    "Note: $($auditMetrics.freeze.note)"
)
$md | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Output "[OK] performance audit checks passed"
Write-Output "[OK] report: $jsonPath"
