Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Read-Text([string]$RelativePath) {
    Get-Content -LiteralPath (Join-Path $repoRoot $RelativePath) -Raw
}

function Assert-Contains([string]$Name, [string]$Text, [string]$Needle) {
    if ($Text -notlike "*$Needle*") {
        throw "$Name missing: $Needle"
    }
}

function Assert-NotContains([string]$Name, [string]$Text, [string]$Needle) {
    if ($Text -like "*$Needle*") {
        throw "$Name should not contain: $Needle"
    }
}

$appH = Read-Text "software-project\src\VirtuaCam\App.h"
$appCpp = Read-Text "software-project\src\VirtuaCam\App.cpp"
$uiCpp = Read-Text "software-project\src\VirtuaCam\UI.cpp"
$processCpp = Read-Text "software-project\src\VirtuaCam\Process.cpp"

Assert-Contains "App source modes" $appH "Display, Image, Video"
Assert-Contains "Display source launch" $appCpp "--type capture --monitor"
Assert-Contains "Media source launch" $appCpp "--type media --media-kind"

Assert-Contains "Video Source menu" $uiCpp "BuildMainVideoSourceSubMenu"
Assert-Contains "Source Off menu" $uiCpp "ID_SOURCE_OFF"
Assert-Contains "Display enumeration" $uiCpp "EnumDisplayMonitors"
Assert-Contains "MF video capture enumeration" $uiCpp "MFEnumDeviceSources"
Assert-Contains "Image file picker" $uiCpp "ID_SOURCE_IMAGE_FILE"
Assert-Contains "Video file picker" $uiCpp "ID_SOURCE_VIDEO_FILE"
Assert-NotContains "Removed discovery grid command" $appH "ID_SOURCE_CONSUMER"
Assert-NotContains "Removed consumer source mode" $appH "Consumer"
Assert-NotContains "Removed consumer process loader" $processCpp "DirectPortConsumer.dll"

$menuStart = $uiCpp.IndexOf("HMENU BuildMainVideoSourceSubMenu")
$menuEnd = $uiCpp.IndexOf("HMENU BuildSourceSubMenu")
if ($menuStart -lt 0 -or $menuEnd -le $menuStart) {
    throw "Main video source menu builder missing."
}
$menuBody = $uiCpp.Substring($menuStart, $menuEnd - $menuStart)

$offPos = $menuBody.IndexOf("ID_SOURCE_OFF")
$windowPos = $menuBody.IndexOf("ID_SOURCE_WINDOW_FIRST")
$displayPos = $menuBody.IndexOf("ID_SOURCE_DISPLAY_FIRST")
$cameraPos = $menuBody.IndexOf("ID_SOURCE_CAMERA_FIRST")
$imagePos = $menuBody.IndexOf("ID_SOURCE_IMAGE_FILE")
if ($offPos -lt 0 -or $windowPos -lt 0 -or $displayPos -lt 0 -or $cameraPos -lt 0 -or $imagePos -lt 0) {
    throw "Source menu sections missing."
}
if (-not ($offPos -lt $windowPos -and $windowPos -lt $displayPos -and $displayPos -lt $cameraPos -and $cameraPos -lt $imagePos)) {
    throw "Source menu order is not off, window, display, camera, file."
}

Assert-Contains "WGC monitor capture" $processCpp "CreateForMonitor"
Assert-Contains "WGC default before PrintWindow" $processCpp "InitWgc failed; falling through to PrintWindow"
Assert-Contains "Media producer" $processCpp "InitializeFileProducer"
Assert-Contains "Media module route" $processCpp "type == L`"media`""

[pscustomobject]@{
    Success = $true
    CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json
