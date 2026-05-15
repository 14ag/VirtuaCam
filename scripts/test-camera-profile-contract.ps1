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

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Text -match $Pattern) {
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

function Get-InfMediaEntries {
    param([string]$Text)

    $entries = @()
    $pattern = 'HKR,"(?<profile>[^"\\]+(?:\}|\w)),0\\(?<pin>PINNAME_VIDEO_[^"]+)","(?<name>Media\d+)",0,"(?<media>[^"]+)"'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $parts = @($match.Groups["media"].Value.Split(",") | ForEach-Object { [int]($_.Trim()) })
        if ($parts.Count -ne 9) {
            throw "Invalid INF media entry: $($match.Value)"
        }
        $entries += [pscustomobject]@{
            Profile = $match.Groups["profile"].Value
            Pin = $match.Groups["pin"].Value
            Name = $match.Groups["name"].Value
            Media = $match.Groups["media"].Value
            Width = $parts[0]
            Height = $parts[1]
            FpsNumerator = $parts[2]
            FpsDenominator = $parts[3]
            Flags = $parts[4]
            Data0 = $parts[5]
            Data1 = $parts[6]
            Data2 = $parts[7]
            Data3 = $parts[8]
        }
    }
    return @($entries)
}

$infCounts = Get-InfMediaCounts -Text $inf
$infEntries = Get-InfMediaEntries -Text $inf
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

foreach ($entry in $infEntries) {
    if ($entry.Pin -eq "PINNAME_VIDEO_STILL") {
        if ($entry.FpsNumerator -ne 0 -or $entry.FpsDenominator -ne 0) {
            throw "Still profile media must advertise 0/0 framerate when photo sequence is unavailable: $($entry.Profile) $($entry.Name)"
        }
    } else {
        if ($entry.FpsNumerator -ne 30 -or $entry.FpsDenominator -ne 1) {
            throw "Preview/capture profile media must keep 30/1 framerate: $($entry.Profile) $($entry.Pin) $($entry.Name)"
        }
    }

    if ($entry.Flags -ne 0 -or $entry.Data0 -ne 0 -or $entry.Data1 -ne 0 -or $entry.Data2 -ne 0 -or $entry.Data3 -ne 0) {
        throw "Profile media flags/data fields must be zero: $($entry.Profile) $($entry.Pin) $($entry.Name)"
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

Assert-Match -Text $filter -Pattern 'CameraProfileVideoRecordingPreviewMediaInfos[\s\S]*\{\s*\{\s*1080,\s*1920\s*\},\s*\{\s*30,\s*1\s*\}' -Message "Runtime VideoRecording preview media must include portrait entry at 30/1."
Assert-Match -Text $filter -Pattern 'CameraProfileVideoRecordingStillMediaInfos[\s\S]*\{\s*\{\s*1080,\s*1920\s*\},\s*\{\s*0,\s*0\s*\}' -Message "Runtime VideoRecording still media must include portrait entry at 0/0."
Assert-Match -Text $filter -Pattern 'CameraProfileBalancedVideoAndPhotoStillMediaInfos[\s\S]*\{\s*\{\s*640,\s*480\s*\},\s*\{\s*0,\s*0\s*\}' -Message "Runtime BalancedVideoAndPhoto still media must keep 640x480 fallback at 0/0."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_VideoRecording[\s\S]{0,260}CameraProfileVideoRecordingPins' -Message "Runtime VideoRecording profile must use profile-specific pins."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_VideoConferencing[\s\S]{0,260}CameraProfileVideoConferencingPins' -Message "Runtime VideoConferencing profile must use profile-specific pins."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_HighQualityPhoto[\s\S]{0,260}CameraProfileHighQualityPhotoPins' -Message "Runtime HighQualityPhoto profile must use profile-specific pins."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_BalancedVideoAndPhoto[\s\S]{0,260}CameraProfileBalancedVideoAndPhotoPins' -Message "Runtime BalancedVideoAndPhoto profile must use profile-specific pins."
Assert-Match -Text $filter -Pattern 'VirtuaCamCustomProfileGuid[\s\S]{0,260}CameraProfileCustomPins' -Message "Runtime custom profile must use profile-specific pins."
Assert-NotContains -Text $filter -Pattern 'CameraProfileFullPins|CameraProfileStandardPins' -Message "Runtime profiles must not reuse shared profile pin tables."
Assert-Match -Text $filter -Pattern 'IsEqualGUID\(ProfileId,\s*GUID_NULL\)' -Message "Profile control must accept GUID_NULL profile selection."
Assert-Match -Text $filter -Pattern 'Header->Version\s*!=\s*1' -Message "Profile control must validate header Version."
Assert-Match -Text $filter -Pattern 'Header->Capability\s*!=\s*KSCAMERA_EXTENDEDPROP_CAPS_ASYNCCONTROL' -Message "Profile control must validate async capability."

Write-Host "Camera profile contract whitebox checks passed."
