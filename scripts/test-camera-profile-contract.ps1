[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$filterPath = Join-Path $repoRoot "driver-project\filter.cpp"
$infPath = Join-Path $repoRoot "driver-project\avshws.inf"

if (-not (Test-Path -LiteralPath $filterPath)) { throw "Missing filter.cpp" }
if (-not (Test-Path -LiteralPath $infPath)) { throw "Missing avshws.inf" }

$filter = Get-Content -LiteralPath $filterPath -Raw
$inf = Get-Content -LiteralPath $infPath -Raw

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Get-InfMediaCounts {
    param([string]$Text)

    $counts = @{}
    $pattern = 'HKR,"(?<profile>[^"\\]+(?:\}|\w)),0\\(?<pin>PINNAME_VIDEO_[^"]+)","MediaCount",%REG_DWORD%,(?<count>\d+)'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $profile = $match.Groups["profile"].Value
        $pin = $match.Groups["pin"].Value
        if (-not $counts.ContainsKey($profile)) {
            $counts[$profile] = @{}
        }
        $counts[$profile][$pin] = [int]$match.Groups["count"].Value
    }
    return $counts
}

$infCounts = Get-InfMediaCounts -Text $inf
$requiredProfiles = @(
    "KSCAMERAPROFILE_VideoRecording",
    "KSCAMERAPROFILE_VideoConferencing",
    "KSCAMERAPROFILE_HighQualityPhoto",
    "KSCAMERAPROFILE_BalancedVideoAndPhoto",
    "{0BB8A130-17C4-40A4-A17A-7CB4437F90E2}"
)
$requiredPins = @("PINNAME_VIDEO_PREVIEW", "PINNAME_VIDEO_CAPTURE", "PINNAME_VIDEO_STILL")

foreach ($profile in $requiredProfiles) {
    if (-not $infCounts.ContainsKey($profile)) {
        throw "INF missing profile media counts: $profile"
    }
    foreach ($pin in $requiredPins) {
        if (-not $infCounts[$profile].ContainsKey($pin)) {
            throw "INF missing media count for $profile $pin"
        }
    }
}

foreach ($pin in $requiredPins) {
    if ($infCounts["KSCAMERAPROFILE_VideoRecording"][$pin] -ne 4) {
        throw "VideoRecording $pin must keep 4 INF media entries."
    }
}

foreach ($profile in @("KSCAMERAPROFILE_VideoConferencing", "KSCAMERAPROFILE_HighQualityPhoto", "KSCAMERAPROFILE_BalancedVideoAndPhoto", "{0BB8A130-17C4-40A4-A17A-7CB4437F90E2}")) {
    foreach ($pin in $requiredPins) {
        if ($infCounts[$profile][$pin] -ne 2) {
            throw "$profile $pin must keep 2 INF media entries."
        }
    }
}

Assert-Match -Text $filter -Pattern 'CameraProfileFullMediaInfos[\s\S]*\{\s*\{\s*1080,\s*1920\s*\}' -Message "Runtime full profile media must include portrait entry."
Assert-Match -Text $filter -Pattern 'CameraProfileStandardMediaInfos[\s\S]*\{\s*\{\s*640,\s*480\s*\}' -Message "Runtime standard profile media must include 640x480 fallback."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_VideoRecording[\s\S]{0,220}CameraProfileFullPins' -Message "Runtime VideoRecording profile must use full media pins."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_BalancedVideoAndPhoto[\s\S]{0,220}CameraProfileStandardPins' -Message "Runtime BalancedVideoAndPhoto profile must use standard media pins."
Assert-Match -Text $filter -Pattern 'IsEqualGUID\(ProfileId,\s*GUID_NULL\)' -Message "Profile control must accept GUID_NULL profile selection."
Assert-Match -Text $filter -Pattern 'Header->Version\s*!=\s*1' -Message "Profile control must validate header Version."
Assert-Match -Text $filter -Pattern 'Header->Capability\s*!=\s*KSCAMERA_EXTENDEDPROP_CAPS_ASYNCCONTROL' -Message "Profile control must validate async capability."

Write-Host "Camera profile contract whitebox checks passed."
