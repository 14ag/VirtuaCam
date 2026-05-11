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
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "VIRTUACAM_PROP_FRAME_EX" -Message "Driver property table must expose FrameEx."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "VIRTUACAM_DRIVER_STATUS_V1_SIZE" -Message "Status MinData must keep v1 compatibility."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "IsFrameExUploadSupported" -Message "Driver must gate FrameEx by negotiated output format."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "UploadMappedFrameExBgra" -Message "App RGB32/BGRA FrameEx path missing."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "UploadMappedFrameExNv12" -Message "App NV12 FrameEx path missing."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "UploadMappedFrame\(mapped\)" -Message "Legacy BGR24 fallback missing."
Assert-Contains -Path "tools\dshow-probe\dshow_probe.cpp" -Pattern "mode == L`"nv12`"" -Message "dshow probe must support nv12 mode."
Assert-Contains -Path "tools\dshow-probe\dshow_probe.cpp" -Pattern "mode == L`"rgb32`"" -Message "dshow probe must support rgb32 mode."

Write-Host "FrameEx ABI whitebox checks passed."
