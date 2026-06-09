[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $fullPath = Join-Path $repoRoot $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Missing file: $Path"
    }

    $text = Get-Content -LiteralPath $fullPath -Raw
    if ($text -notmatch $Pattern) {
        throw $Message
    }
}

Assert-Contains -Path "shared\VirtuaCamDriverAbi.h" -Pattern "VIRTUACAM_PROP_FRAME_EX\s+7u" -Message "FrameEx property id must stay 7."
Assert-Contains -Path "shared\VirtuaCamDriverAbi.h" -Pattern "VIRTUACAM_DRIVER_STATUS_V1_SIZE\s+112u" -Message "Driver status v1 prefix size must stay 112."
Assert-Contains -Path "shared\VirtuaCamDriverAbi.h" -Pattern "VIRTUACAM_DRIVER_STATUS_VERSION\s+3u" -Message "Driver status version must reflect append-only telemetry fields."
Assert-Contains -Path "driver-project\avshws.h" -Pattern "ReservedStatus\[3\];[\s\S]*StaleUploadRejectedCount[\s\S]*BusyUploadRejectedCount[\s\S]*LastAcceptedFrameId[\s\S]*LastAcceptedPerformanceCounter[\s\S]*LastAcceptedSystemTime100ns" -Message "Driver status telemetry must append after the v1-compatible prefix."
Assert-Contains -Path "driver-project\avshws.h" -Pattern "FIELD_OFFSET\(VIRTUACAM_DRIVER_STATUS, StaleUploadRejectedCount\) > VIRTUACAM_DRIVER_STATUS_V1_SIZE" -Message "Driver status append-only fields must be guarded by a static assert."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "VIRTUACAM_PROP_FRAME_EX" -Message "Driver property table must expose FrameEx."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "VIRTUACAM_DRIVER_STATUS_V1_SIZE" -Message "Status MinData must keep v1 compatibility."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "bufferLength < sizeof\(VIRTUACAM_FRAME_EX_HEADER\)" -Message "FrameEx filter path must reject short headers."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "header\.Version != VIRTUACAM_FRAME_EX_VERSION" -Message "FrameEx filter path must reject bad versions."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "copyLength64 != bufferLength" -Message "FrameEx filter path must reject mismatched payload lengths."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "IsFrameExUploadSupported" -Message "Driver must gate FrameEx by negotiated output format."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "dataLength < sizeof\(VIRTUACAM_FRAME_EX_HEADER\)" -Message "FrameEx hardware path must reject short headers."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "header->Version != VIRTUACAM_FRAME_EX_VERSION" -Message "FrameEx hardware path must reject bad versions."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "header->PayloadOffset < sizeof\(VIRTUACAM_FRAME_EX_HEADER\)" -Message "FrameEx hardware path must reject bad payload offsets."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "header->PayloadLength > dataLength - header->PayloadOffset" -Message "FrameEx hardware path must reject short payloads."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "expectedPayloadLength != header->PayloadLength" -Message "FrameEx hardware path must reject mismatched payload sizes."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "header->Stride0 <= 0" -Message "FrameEx hardware path must reject bad stride values."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "header->Width == 0[\s\S]*header->Height == 0" -Message "FrameEx hardware path must reject bad dimensions."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "kSetDataRejectUnsupportedFormat" -Message "FrameEx hardware path must reject unsupported upload formats."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "m_BusyUploadRejectedCount\+\+" -Message "Driver status must count busy upload rejections."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "m_LastAcceptedFrameId\s*=\s*header->FrameId" -Message "Driver FrameEx status must record the last accepted FrameId."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "KeQueryPerformanceCounter\(NULL\)" -Message "Driver status must record an accepted-frame performance counter timestamp."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "UploadMappedFrameExBgra" -Message "App RGB32/BGRA FrameEx path missing."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "UploadMappedFrameExNv12" -Message "App NV12 FrameEx path missing."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "UploadMappedFrame\(mapped\)" -Message "Legacy BGR24 fallback missing."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "StaleUploadRejectedCount" -Message "App driver status snapshot must tolerate appended telemetry."
Assert-Contains -Path "tools\dshow-probe\dshow_probe.cpp" -Pattern "mode == L`"nv12`"" -Message "dshow probe must support nv12 mode."
Assert-Contains -Path "tools\dshow-probe\dshow_probe.cpp" -Pattern "mode == L`"rgb32`"" -Message "dshow probe must support rgb32 mode."

Write-Host "FrameEx ABI whitebox checks passed."
