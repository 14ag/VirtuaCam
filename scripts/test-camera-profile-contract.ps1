[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$filterPath = Join-Path $repoRoot "driver-project\filter.cpp"
$devicePath = Join-Path $repoRoot "driver-project\device.cpp"
$infPath = Join-Path $repoRoot "driver-project\avshws.inf"

if (-not (Test-Path -LiteralPath $filterPath)) { throw "Missing filter.cpp" }
if (-not (Test-Path -LiteralPath $devicePath)) { throw "Missing device.cpp" }
if (-not (Test-Path -LiteralPath $infPath)) { throw "Missing avshws.inf" }

$filter = Get-Content -LiteralPath $filterPath -Raw
$device = Get-Content -LiteralPath $devicePath -Raw
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

function Get-InfProfileV2Entries {
    param([string]$Text)

    $entries = @{}
    $pattern = 'HKR,"Profiles\\(?<profile>[^"]+)","(?<name>Constraint|BlockedControls|MTF\d+)",0,"(?<value>[^"]*)"'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $profile = $match.Groups["profile"].Value
        $name = $match.Groups["name"].Value
        if (-not $entries.ContainsKey($profile)) {
            $entries[$profile] = @{}
        }
        $entries[$profile][$name] = $match.Groups["value"].Value
    }
    return $entries
}

$infCounts = Get-InfMediaCounts -Text $inf
$infEntries = Get-InfMediaEntries -Text $inf
$infProfileV2 = Get-InfProfileV2Entries -Text $inf
$requiredProfiles = @(
    "KSCAMERAPROFILE_VideoRecording",
    "KSCAMERAPROFILE_VideoConferencing",
    "KSCAMERAPROFILE_HighQualityPhoto",
    "KSCAMERAPROFILE_BalancedVideoAndPhoto"
)
$requiredProfileV2 = @("KSCAMERAPROFILE_Legacy") + $requiredProfiles
$requiredPins = @("PINNAME_VIDEO_PREVIEW", "PINNAME_VIDEO_CAPTURE", "PINNAME_VIDEO_STILL")
$customProfileGuidPattern = '\{0BB8A130-17C4-40A4-A17A-7CB4437F90E2\}'

Assert-Match -Text $inf -Pattern 'HKR,,"OEMCameraProfileVersion",%REG_DWORD%,2' -Message "INF must enable Camera Profile V2."
Assert-NotContains -Text $inf -Pattern 'OEMCameraProfiles' -Message "INF must not publish legacy Camera Profile 1507 OEMCameraProfiles when Camera Profile V2 is enabled."
Assert-NotContains -Text $inf -Pattern 'HKR,"KSCAMERAPROFILE_[^"]+\\PINNAME_VIDEO_' -Message "INF must not publish legacy Camera Profile 1507 per-pin media keys when Camera Profile V2 is enabled."

foreach ($profile in $requiredProfileV2) {
    $profileV2 = "$profile,0"
    if (-not $infProfileV2.ContainsKey($profileV2)) {
        throw "INF missing Camera Profile V2 key: Profiles\$profileV2"
    }
    if ($infProfileV2[$profileV2]["BlockedControls"] -ne "PHSEQ") {
        throw "INF Camera Profile V2 must block photo sequence for $profileV2."
    }
    foreach ($name in @("MTF0", "MTF1", "MTF2")) {
        if (-not $infProfileV2[$profileV2].ContainsKey($name)) {
            throw "INF Camera Profile V2 missing $name for $profileV2."
        }
    }
    if ($infProfileV2[$profileV2]["MTF0"] -notmatch '^Pin0:') {
        throw "INF Camera Profile V2 MTF0 must describe preview Pin0 for $profileV2."
    }
    if ($infProfileV2[$profileV2]["MTF1"] -notmatch '^Pin1:') {
        throw "INF Camera Profile V2 MTF1 must describe capture Pin1 for $profileV2."
    }
    if ($infProfileV2[$profileV2]["MTF2"] -notmatch '^Pin2:') {
        throw "INF Camera Profile V2 MTF2 must describe still Pin2 for $profileV2."
    }
}

if ($infProfileV2["KSCAMERAPROFILE_Legacy,0"]["MTF0"] -notmatch 'RES==;FRT==;SUT==ALL') {
    throw "INF Camera Profile V2 legacy profile must allow all preview media."
}
if ($infProfileV2["KSCAMERAPROFILE_Legacy,0"]["MTF1"] -notmatch 'RES==;FRT<=30,1;SUT==ALL') {
    throw "INF Camera Profile V2 legacy profile must allow all capture media."
}
if ($infProfileV2["KSCAMERAPROFILE_Legacy,0"]["MTF2"] -notmatch 'RES==;FRT==;SUT==ALL') {
    throw "INF Camera Profile V2 legacy profile must allow all still media."
}

if ($infProfileV2["KSCAMERAPROFILE_VideoRecording,0"]["MTF0"] -notmatch 'RES==;FRT==;SUT==ALL') {
    throw "VideoRecording MTF0 must use valid broad Camera Profile V2 sample syntax."
}
if ($infProfileV2["KSCAMERAPROFILE_VideoRecording,0"]["MTF1"] -notmatch 'RES==;FRT<=30,1;SUT==ALL') {
    throw "VideoRecording MTF1 must use valid broad Camera Profile V2 sample syntax."
}
if ($infProfileV2["KSCAMERAPROFILE_VideoRecording,0"]["MTF2"] -notmatch 'RES==;FRT==;SUT==ALL') {
    throw "VideoRecording MTF2 must use valid broad Camera Profile V2 sample syntax."
}

Assert-NotContains -Text $inf -Pattern $customProfileGuidPattern -Message "INF profile declarations must not publish the optional custom profile during vHLK profile-interface validation."
Assert-NotContains -Text $device -Pattern 'VirtuaCamPublishCameraProfiles\(filterFactory\)' -Message "INF Camera Profile V2 must own profile store without duplicate runtime KS profile publication."
Assert-Match -Text $filter -Pattern 'CameraProfileVideoRecordingPreviewMediaInfos[\s\S]*\{\s*\{\s*1080,\s*1920\s*\},\s*\{\s*30,\s*1\s*\}' -Message "Runtime VideoRecording preview media must include portrait entry at 30/1."
Assert-Match -Text $filter -Pattern 'CameraProfileVideoRecordingStillMediaInfos[\s\S]*\{\s*\{\s*1080,\s*1920\s*\},\s*\{\s*0,\s*0\s*\}' -Message "Runtime VideoRecording still media must include portrait entry at 0/0."
Assert-Match -Text $filter -Pattern 'CameraProfileBalancedVideoAndPhotoStillMediaInfos[\s\S]*\{\s*\{\s*640,\s*480\s*\},\s*\{\s*0,\s*0\s*\}' -Message "Runtime BalancedVideoAndPhoto still media must keep 640x480 fallback at 0/0."
Assert-Match -Text $filter -Pattern 'GUID\s+g_PINNAME_IMAGE\s*=\s*\{STATIC_PINNAME_IMAGE\}' -Message "Still pin must use PINNAME_IMAGE for Media Foundation photo source classification."
Assert-Match -Text $filter -Pattern '&g_PINNAME_IMAGE,\s*// Category[\s\S]{0,120}&g_PINNAME_IMAGE,\s*// Name' -Message "Still pin descriptor must use PINNAME_IMAGE as the Media Foundation photo stream category and name."
Assert-NotContains -Text $filter -Pattern 'KSCameraProfileSensorType_RGB' -Message "Runtime KSCAMERA_PROFILE_PININFO Reserved field must remain 0."
Assert-NotContains -Text $filter -Pattern 'ProfileId\s*=\s*STATICGUIDOF\(KSCAMERAPROFILE_Legacy\)|STATICGUIDOF\(KSCAMERAPROFILE_Legacy\)[\s\S]{0,140}CameraProfile' -Message "Runtime KS profile publishing must not publish KSCAMERAPROFILE_Legacy."
Assert-NotContains -Text $filter -Pattern 'VirtuaCamCustomProfileGuid|CameraProfileCustom|0BB8A130' -Message "Runtime KS profile publishing must not publish the optional custom profile during vHLK profile-interface validation."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_VideoRecording[\s\S]{0,260}CameraProfileVideoRecordingPins' -Message "Runtime VideoRecording profile must use profile-specific pins."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_VideoConferencing[\s\S]{0,260}CameraProfileVideoConferencingPins' -Message "Runtime VideoConferencing profile must use profile-specific pins."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_HighQualityPhoto[\s\S]{0,260}CameraProfileHighQualityPhotoPins' -Message "Runtime HighQualityPhoto profile must use profile-specific pins."
Assert-Match -Text $filter -Pattern 'KSCAMERAPROFILE_BalancedVideoAndPhoto[\s\S]{0,260}CameraProfileBalancedVideoAndPhotoPins' -Message "Runtime BalancedVideoAndPhoto profile must use profile-specific pins."
Assert-NotContains -Text $filter -Pattern 'CameraProfileFullPins|CameraProfileStandardPins' -Message "Runtime profiles must not reuse shared profile pin tables."
Assert-Match -Text $filter -Pattern 'IsEqualGUID\(ProfileId,\s*GUID_NULL\)' -Message "Profile control must accept GUID_NULL profile selection."
Assert-Match -Text $filter -Pattern 'Header->Version\s*==\s*1' -Message "Profile control must validate header Version."
Assert-Match -Text $filter -Pattern 'Header->Capability\s*==\s*KSCAMERA_EXTENDEDPROP_CAPS_ASYNCCONTROL' -Message "Profile control must validate async capability."
Assert-Match -Text $filter -Pattern 'KSPROPERTY_TYPE_GETPAYLOADSIZE' -Message "Profile control must report extended profile payload size."
Assert-Match -Text $filter -Pattern 'STATUS_BUFFER_OVERFLOW' -Message "Profile GET must return required size for short buffers."
Assert-Match -Text $filter -Pattern 'CameraProfileBufferedHeaderOffset\s*=\s*16' -Message "Profile SET must tolerate the 16-byte framework header prefix."
Assert-Match -Text $filter -Pattern 'CCaptureFilter::GetCameraProfileSupport' -Message "Profile property item must expose a support handler."
Assert-Match -Text $filter -Pattern 'DEFINE_KSEVENT_TABLE\(ExtendedCameraControlEventTable\)' -Message "Profile control must expose an ExtendedCameraControl event table."
Assert-Match -Text $filter -Pattern 'DEFINE_KSEVENT_ITEM\(\s*KSPROPERTY_CAMERACONTROL_EXTENDED_PROFILE' -Message "Profile control must expose the async profile event."
Assert-Match -Text $filter -Pattern 'DEFINE_KSEVENT_SET\(\s*&KSEVENTSETID_ExtendedCameraControl' -Message "Profile control event set must use KSEVENTSETID_ExtendedCameraControl."
Assert-Match -Text $filter -Pattern 'DEFINE_KSAUTOMATION_EVENTS\(EventSetTable\)' -Message "Filter automation table must publish camera profile events."
Assert-Match -Text $filter -Pattern 'KsFilterGenerateEvents\(\s*filter,\s*&KSEVENTSETID_ExtendedCameraControl,\s*KSPROPERTY_CAMERACONTROL_EXTENDED_PROFILE' -Message "Profile SET must signal async profile completion events."
Assert-Match -Text $filter -Pattern 'StillVideoControlSupportedModes[\s\S]*KS_VideoControlFlag_Trigger[\s\S]*KS_VideoControlFlag_IndependentImagePin' -Message "Still pin must report programmatic trigger and independent image-pin video-control capabilities."
Assert-Match -Text $filter -Pattern 'KSPROPERTY_VIDEOCONTROL_MODE[\s\S]{0,220}sizeof\(KSPROPERTY_VIDEOCONTROL_MODE_S\)[\s\S]{0,120}sizeof\(KSPROPERTY_VIDEOCONTROL_MODE_S\)' -Message "Video-control mode property must use full MODE_S descriptor and value sizes."
Assert-Match -Text $filter -Pattern 'KSPROPERTY_VIDEOCONTROL_CAPS[\s\S]{0,220}sizeof\(KSPROPERTY_VIDEOCONTROL_CAPS_S\)[\s\S]{0,120}sizeof\(KSPROPERTY_VIDEOCONTROL_CAPS_S\)' -Message "Video-control caps property must use full CAPS_S descriptor and value sizes."
Assert-Match -Text $filter -Pattern 'PROPSETID_VIDCAP_CAMERACONTROL_IMAGE_PIN_CAPABILITY' -Message "Filter must expose image-pin capability property set."
Assert-Match -Text $filter -Pattern 'KSPROPERTY_CAMERACONTROL_IMAGE_PIN_CAPABILITY_S' -Message "Image-pin capability GET must return the documented capability structure."

Write-Host "Camera profile contract whitebox checks passed."
