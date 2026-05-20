[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))

function Fail([string]$Message) {
    throw $Message
}

function Assert-Contains([string]$Path, [string]$Pattern, [string]$Message) {
    $matches = @(Select-String -Path (Join-Path $repoRoot $Path) -Pattern $Pattern -SimpleMatch -ErrorAction Stop)
    if ($matches.Count -eq 0) { Fail $Message }
}

function Assert-NotContains([string[]]$Paths, [string]$Pattern, [string]$Message) {
    $matches = @(Select-String -Path $Paths -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue)
    if ($matches.Count -gt 0) {
        Fail ("{0}: {1}" -f $Message, (($matches | Select-Object -First 4 | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join ", "))
    }
}

$appSources = @(Get-ChildItem -Path (Join-Path $repoRoot "software-project\src\VirtuaCam") -Include *.cpp,*.h -Recurse | Select-Object -ExpandProperty FullName)

Assert-NotContains -Paths $appSources -Pattern "GetPrivateProfile" -Message "INI read API still present"
Assert-NotContains -Paths $appSources -Pattern "WritePrivateProfile" -Message "INI write API still present"
Assert-Contains "software-project\src\VirtuaCam\Config.cpp" "Software\\VirtuaCam\\Settings" "HKCU settings registry path missing"
Assert-Contains "software-project\src\VirtuaCam\Config.cpp" "DeleteLegacySettingsFile" "Legacy settings cleanup missing"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "UI_SetDebugMode" "Debug mode UI gate missing"
Assert-Contains "software-project\src\VirtuaCam\App.cpp" 'L"-debug"' "App -debug argument gate missing"
Assert-Contains "shared\VirtuaCamAudioAbi.h" "IOCTL_VIRTUACAM_MIC_WRITE_PACKET" "Audio write IOCTL ABI missing"
Assert-Contains "shared\VirtuaCamAudioAbi.h" "VIRTUACAM_MIC_PACKET_BYTES" "Fixed 10 ms packet ABI missing"
Assert-Contains "audio-driver-project\Source\Main\VirtuaCamMicBridge.cpp" "IoCreateDeviceSecure" "Secured audio bridge device missing"
Assert-Contains "audio-driver-project\Source\Main\VirtuaCamMicBridge.cpp" "PcDispatchIrp" "Audio bridge does not forward non-bridge IRPs to PortCls"
Assert-Contains "audio-driver-project\Source\Main\VirtuaCamMicBridge.cpp" "STATUS_INVALID_BUFFER_SIZE" "Audio IOCTL length validation missing"
Assert-Contains "audio-driver-project\Source\Main\VirtuaCamMicBridge.cpp" "g_MicBridge.Underruns++" "Audio underrun counter missing"
Assert-NotContains -Paths @((Join-Path $repoRoot "audio-driver-project\Source\Main\adapter.cpp")) -Pattern "RtlAppendUnicodeToString(&g_RegistryPath" -Message "Driver registry path copy must be length-bounded"
Assert-NotContains -Paths @((Join-Path $repoRoot "audio-driver-project\Source\Main\adapter.cpp")) -Pattern "WdfDriverCreate" -Message "Virtual mic DriverEntry must stay PortCls-only"
Assert-Contains "audio-driver-project\Source\Main\adapter.cpp" "IoOpenDriverRegistryKey failed, using defaults" "Missing audio Parameters key must not fail DriverEntry"
Assert-Contains "audio-driver-project\Source\Main\common.cpp" "#define VIRTUACAM_MIC_ENABLE_WDF_MINIPORT 0" "Virtual mic must not create unused WDF miniport object"
Assert-Contains "audio-driver-project\Source\Main\common.cpp" "m_pPhysicalDeviceObject, // PDO" "WdfDeviceMiniportCreate must receive the PortCls PDO"
Assert-Contains "audio-driver-project\Source\Main\minwavertstream.cpp" "VirtuaCamMicBridgeReadAudio" "WaveRT capture path does not read bridge audio"
Assert-NotContains -Paths @((Join-Path $repoRoot "audio-driver-project\Source\Main\minwavertstream.cpp")) -Pattern "GenerateSine" -Message "Capture path still generates tone instead of pass-through audio"
Assert-NotContains -Paths @((Join-Path $repoRoot "audio-driver-project\Source\Utilities\Utilities.vcxproj")) -Pattern "tonegenerator.cpp" -Message "Tone generator is still built into audio pass-through driver"
Assert-Contains "audio-driver-project\Source\Filters\minipairs.h" "#define g_cRenderEndpoints  0" "Audio driver still exposes render endpoints"
Assert-Contains "audio-driver-project\Source\Filters\micarraywavtable.h" "48 KHz 16-bit stereo PCM" "Audio format is not fixed 48 kHz 16-bit stereo"
Assert-Contains "audio-driver-project\virtuacam-mic.inf" "VirtuaCam Microphone" "Audio INF endpoint name missing"
Assert-NotContains -Paths @((Join-Path $repoRoot "audio-driver-project\virtuacam-mic.inf")) -Pattern "KSCATEGORY_RENDER" -Message "Audio INF still registers a render endpoint"
Assert-NotContains -Paths @((Join-Path $repoRoot "audio-driver-project\virtuacam-mic.inf")) -Pattern "KmdfLibraryVersion" -Message "Audio INF still declares unused KMDF service"
Assert-Contains "audio-driver-project\virtuacam-mic.inf" "PnpLockdown = 1" "Audio INF PnpLockdown missing"
Assert-Contains "scripts\build-all.ps1" "virtuacam-mic.inf" "Build does not stage audio INF"
Assert-Contains "scripts\install-all.ps1" "ROOT\VIRTUACAMMIC" "Install does not create mic devnode"
Assert-Contains "software-project\src\VirtuaCam\WASAPI.cpp" "DeviceIoControl" "WASAPI bridge does not write IOCTL packets"
Assert-Contains "software-project\src\VirtuaCam\WASAPI.cpp" "VIRTUACAM_MIC_SAMPLE_RATE" "WASAPI bridge does not resample to audio ABI"

Write-Host "PASS setup/registry/debug/audio whitebox checks"
