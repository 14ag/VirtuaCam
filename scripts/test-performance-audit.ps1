[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SkipRuntime,
    [int]$RuntimeSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))
$SourceRoot = Join-Path $RepoRoot "software-project\src"

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

Assert-Contains -Path $appCpp -Pattern "kAppFrameIntervalMs\s*=\s*33" -Message "App frame scheduler must target 30 fps."
Assert-Contains -Path $appCpp -Pattern "GetBrokerFrameValue" -Message "App must query broker frame value."
Assert-Contains -Path $appCpp -Pattern "brokerFrameValue\s*==\s*s_lastSentFrameValue" -Message "App must skip unchanged broker frames."
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
Assert-Contains -Path $toolsH -Pattern "GetProducerStatusName" -Message "DirectPort status mapping name helper missing."
Assert-Contains -Path $toolsCpp -Pattern "InitializeDirectPortStatus" -Message "DirectPort status initializer missing."
Assert-Contains -Path $toolsCpp -Pattern "PublishDirectPortStatus" -Message "DirectPort status publisher missing."
Assert-Contains -Path $toolsCpp -Pattern "ReadDirectPortStatusStable" -Message "DirectPort stable status reader missing."
Assert-Contains -Path $toolsCpp -Pattern "beginSequence == endSequence" -Message "DirectPort reader must reject partial status updates."
Assert-Contains -Path $toolsCpp -Pattern "beginWriteSequence" -Message "DirectPort publisher must mark odd write sequence before field updates."
Assert-Contains -Path $processCpp -Pattern "DirectPortStatusMapping" -Message "Producer status mapping wrapper missing."
Assert-Contains -Path $processCpp -Pattern "InitializeDirectPortStatusMapping" -Message "Producer must initialize DirectPort status sidecar."
Assert-Contains -Path $processCpp -Pattern "PublishDirectPortProducerStatus" -Message "Producer must publish DirectPort status."
Assert-Contains -Path $processCpp -Pattern "GetProducerStatusName" -Message "Producer status sidecar must use named mapping."
Assert-Contains -Path $processCpp -Pattern "class AsyncSourceReaderCallback final : public IMFSourceReaderCallback" -Message "Camera/file producers must use async Source Reader callback mode."
Assert-Contains -Path $processCpp -Pattern "MF_SOURCE_READER_ASYNC_CALLBACK" -Message "Source Reader callback must be configured before reader creation."
Assert-Contains -Path $processCpp -Pattern "TryTakeLatest" -Message "Async Source Reader path must expose a latest-sample handoff."
Assert-Contains -Path $processCpp -Pattern "m_droppedSamples" -Message "Async Source Reader callback must overwrite stale samples instead of queuing unbounded frames."
Assert-Contains -Path $processCpp -Pattern "SelectRgb32MediaType" -Message "Camera/file producers must validate RGB32 media type before BGRA upload."
Assert-Contains -Path $processCpp -Pattern "subtype != MFVideoFormat_RGB32" -Message "Camera/file producers must reject non-RGB32 current media types."
Assert-Contains -Path $processCpp -Pattern "length\) < requiredBytes" -Message "Camera/file producers must reject short RGB32 sample buffers."
Assert-NotContains -Path $processCpp -Pattern "ReadSample\([^\r\n]*&streamFlags" -Message "Camera/file hot path must not use blocking Source Reader ReadSample output parameters."
Assert-Contains -Path $discoveryH -Pattern "DiscoverStreams\(const std::map<DWORD, UINT64>& expectedProducers\)" -Message "Discovery must support expected-producer fast path."
Assert-Contains -Path $discoveryCpp -Pattern "TryAddStreamForPid" -Message "Discovery must use PID-targeted manifest probing."
Assert-Contains -Path $discoveryCpp -Pattern "ReadDirectPortStatusStable" -Message "Discovery must read stable producer status when present."
Assert-Contains -Path $brokerCpp -Pattern "DiscoverStreams\(expectedProducers\)" -Message "Broker must pass expected producers into discovery."
Assert-Contains -Path $multiplexerH -Pattern "DirectPortStatusV1\* statusView" -Message "Multiplexer must cache mapped producer status sidecar."
Assert-Contains -Path $multiplexerH -Pattern "copyCount" -Message "Multiplexer must track producer copy count."
Assert-Contains -Path $multiplexerCpp -Pattern "IsProducerStatusStale" -Message "Multiplexer stale producer policy missing."
Assert-Contains -Path $multiplexerCpp -Pattern "hasFreshStatusProducer && res\.staleByStatus" -Message "Multiplexer must drop stale producer when fresher status exists."
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
Assert-Contains -Path $driverBridgeCpp -Pattern "QueueReadbackAndMapReady" -Message "DriverBridge must queue GPU readbacks through the staging pool."
Assert-Contains -Path $driverBridgeCpp -Pattern "D3D11_MAP_FLAG_DO_NOT_WAIT" -Message "DriverBridge readback pool must avoid blocking Map when possible."
Assert-Contains -Path $driverBridgeCpp -Pattern "return DXGI_ERROR_WAS_STILL_DRAWING" -Message "DriverBridge must report readback-not-ready distinctly from driver warmup retry."
Assert-Contains -Path $driverBridgeCpp -Pattern "m_readbackNotReadyCount" -Message "DriverBridge must count readback-not-ready events separately."
Assert-Contains -Path $driverBridgeCpp -Pattern "readbackNotReady=" -Message "DriverBridge status logs must expose readback-not-ready count."
Assert-Contains -Path (Join-Path $RepoRoot "software-project\src\VirtuaCam\App.cpp") -Pattern "readback not ready" -Message "App must log readback-not-ready separately from driver warmup."
Assert-NotContains -Path $driverBridgeCpp -Pattern "Map\(m_stagingTexture\.get\(\), 0, D3D11_MAP_READ, 0" -Message "DriverBridge must not use single blocking BGRA staging maps."
Assert-NotContains -Path $driverBridgeCpp -Pattern "Map\(m_nv12StagingTexture\.get\(\), 0, D3D11_MAP_READ, 0" -Message "DriverBridge must not use single blocking NV12 staging maps."

$muxText = Read-Text -Path $multiplexerCpp
if ($muxText -match "for \(auto& res : m_producerResources\)[\s\S]{0,260}OpenFileMappingW") {
    throw "[FAIL] Multiplexer still opens producer manifests inside per-frame resource loop."
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
        $proc = Start-Process -FilePath $exePath -ArgumentList "/startup" -WorkingDirectory (Split-Path -Parent $exePath) -WindowStyle Hidden -PassThru
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
    if ($newDumps.Count -gt 0) {
        throw "[FAIL] VirtuaCam without -debug created DriverBridge PPM dumps."
    }
}

Write-Output "[OK] performance audit checks passed"
