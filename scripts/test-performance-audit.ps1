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
$processCpp = Join-Path $SourceRoot "VirtuaCam\Process.cpp"
$cmakeLists = Join-Path $SourceRoot "CMakeLists.txt"

Assert-Contains -Path $appCpp -Pattern "kAppFrameIntervalMs\s*=\s*33" -Message "App frame scheduler must target 30 fps."
Assert-Contains -Path $appCpp -Pattern "GetBrokerFrameValue" -Message "App must query broker frame value."
Assert-Contains -Path $appCpp -Pattern "brokerFrameValue\s*==\s*s_lastSentFrameValue" -Message "App must skip unchanged broker frames."
Assert-Contains -Path $brokerCpp -Pattern "kDiscoveryIntervalMs\s*=\s*1000" -Message "Broker discovery must be throttled."
Assert-Contains -Path $brokerCpp -Pattern "GetBrokerFrameValue" -Message "Broker frame-value export missing."
Assert-Contains -Path $cmakeLists -Pattern "GetBrokerFrameValue" -Message "Broker .def export missing from CMake."
Assert-Contains -Path $multiplexerCpp -Pattern "manifestView" -Message "Multiplexer must cache mapped producer manifests."
Assert-Contains -Path $multiplexerCpp -Pattern "if \(!forceComposite && !inputFrameChanged\)" -Message "Multiplexer must skip unchanged composites."
Assert-Contains -Path $processCpp -Pattern "kProducerFrameIntervalMs\s*=\s*33" -Message "Producer loop must use frame cadence."
Assert-Contains -Path $processCpp -Pattern "kProducerIdleBackoffMaxMs\s*=\s*250" -Message "Producer loop must have adaptive idle backoff."
Assert-Contains -Path $processCpp -Pattern "producedFrame\s*= module\.Process\(\)" -Message "Producer loop must use frame production result."
Assert-NotContains -Path $processCpp -Pattern "kProducerIdleWaitMs" -Message "Producer 1 ms polling constant must be removed."
Assert-Contains -Path $processCpp -Pattern "struct GdiCaptureCache" -Message "GDI fallback must cache capture objects."
Assert-NotContains -Path $processCpp -Pattern "g_gdiFrame" -Message "GDI fallback must avoid extra frame-copy buffer."
Assert-Contains -Path $processCpp -Pattern "UpdateSubresource\(g_sourceD3D11Texture\.Get\(\), 0, nullptr, g_gdiCache\.bits" -Message "GDI fallback must upload DIB bits directly."
Assert-Contains -Path $driverBridgeCpp -Pattern "DriverFrameDumpEnabled\(\) && \(n == 1 \|\| n == 90\)" -Message "DriverBridge PPM dumps must be debug-gated."

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
