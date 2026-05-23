param()

$ErrorActionPreference = "Stop"

function Assert-Contains {
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

$root = Split-Path -Parent $PSScriptRoot
$driverBridgePath = Join-Path $root "software-project\src\VirtuaCam\DriverBridge.cpp"
$processPath = Join-Path $root "software-project\src\VirtuaCam\Process.cpp"
$configHeaderPath = Join-Path $root "software-project\src\VirtuaCam\Config.h"
$configSourcePath = Join-Path $root "software-project\src\VirtuaCam\Config.cpp"
$uiPath = Join-Path $root "software-project\src\VirtuaCam\UI.cpp"
$abiPath = Join-Path $root "shared\VirtuaCamDriverAbi.h"

$driverBridge = Get-Content -LiteralPath $driverBridgePath -Raw
$process = Get-Content -LiteralPath $processPath -Raw
$configHeader = Get-Content -LiteralPath $configHeaderPath -Raw
$configSource = Get-Content -LiteralPath $configSourcePath -Raw
$ui = Get-Content -LiteralPath $uiPath -Raw
$abi = Get-Content -LiteralPath $abiPath -Raw

$aspectRatios = @(
    [pscustomobject]@{
        Name = "16:9"; Enum = "R16_9"; DriverValue = 0; Mask = "16_9"; Width = 1920; Height = 1080; RatioW = 16.0; RatioH = 9.0
    },
    [pscustomobject]@{
        Name = "9:16"; Enum = "R9_16"; DriverValue = 1; Mask = "9_16"; Width = 1080; Height = 1920; RatioW = 9.0; RatioH = 16.0
    },
    [pscustomobject]@{
        Name = "4:3"; Enum = "R4_3"; DriverValue = 2; Mask = "4_3"; Width = 1440; Height = 1080; RatioW = 4.0; RatioH = 3.0
    },
    [pscustomobject]@{
        Name = "3:4"; Enum = "R3_4"; DriverValue = 3; Mask = "3_4"; Width = 1080; Height = 1440; RatioW = 3.0; RatioH = 4.0
    }
)

foreach ($aspect in $aspectRatios) {
    $escapedName = [regex]::Escape($aspect.Name)
    Assert-Contains -Text $configHeader -Pattern "AspectRatioMode[\s\S]*$($aspect.Enum)" -Message "$($aspect.Name) must exist in AspectRatioMode."
    if ($aspect.Enum -eq "R16_9") {
        Assert-Contains -Text $configSource -Pattern "return\s+AspectRatioMode::R16_9;" -Message "16:9 must be settings parse fallback."
    } else {
        Assert-Contains -Text $configSource -Pattern "if\s*\(value\s*==\s*L`"$escapedName`"\)\s*return\s*AspectRatioMode::$($aspect.Enum)" -Message "$($aspect.Name) must parse from settings."
    }
    if ($aspect.Enum -eq "R16_9") {
        Assert-Contains -Text $configSource -Pattern "default:\s*return\s+L`"16:9`"" -Message "16:9 must serialize as default menu/settings name."
    } else {
        Assert-Contains -Text $configSource -Pattern "case\s+AspectRatioMode::$($aspect.Enum):\s*return\s+L`"$escapedName`"" -Message "$($aspect.Name) must serialize to menu/settings name."
    }
    if ($aspect.Enum -eq "R16_9") {
        Assert-Contains -Text $configSource -Pattern "default:\s*return\s+16\.0f\s*/\s*9\.0f" -Message "16:9 numeric aspect value must be default."
    } else {
        Assert-Contains -Text $configSource -Pattern "case\s+AspectRatioMode::$($aspect.Enum):\s*return\s+$($aspect.RatioW.ToString("0.0"))f\s*/\s*$($aspect.RatioH.ToString("0.0"))f" -Message "$($aspect.Name) numeric aspect value must match."
    }
    Assert-Contains -Text $abi -Pattern "VIRTUACAM_ASPECT_$($aspect.Mask)\s+$($aspect.DriverValue)u" -Message "$($aspect.Name) ABI driver value must match app enum order."
    Assert-Contains -Text $abi -Pattern "VIRTUACAM_ASPECT_MASK_$($aspect.Mask)\s+\(1u\s*<<\s*VIRTUACAM_ASPECT_$($aspect.Mask)\)" -Message "$($aspect.Name) ABI mask must exist."
    Assert-Contains -Text $ui -Pattern "AddNativeMenuItem\(aspectMenuTop,\s*L`"$escapedName`",\s*ID_ASPECT_RATIO_$($aspect.Mask)" -Message "$($aspect.Name) must be present in top-level aspect menu."
    if ($aspect.Enum -eq "R16_9") {
        Assert-Contains -Text $driverBridge -Pattern "default:\s*return\s+0;" -Message "16:9 DriverBridge property value must be ABI default."
    } else {
        Assert-Contains -Text $driverBridge -Pattern "case\s+AspectRatioMode::$($aspect.Enum):\s*return\s+$($aspect.DriverValue);" -Message "$($aspect.Name) DriverBridge property value must match ABI."
    }
}

Assert-Contains -Text $driverBridge -Pattern "case\s+AspectRatioMode::R9_16:[\s\S]*?width\s*=\s*1080;\s*height\s*=\s*1920;" -Message "9:16 driver output must be 1080x1920."
Assert-Contains -Text $driverBridge -Pattern "case\s+AspectRatioMode::R4_3:[\s\S]*?width\s*=\s*1440;\s*height\s*=\s*1080;" -Message "4:3 driver output must be 1440x1080."
Assert-Contains -Text $driverBridge -Pattern "case\s+AspectRatioMode::R3_4:[\s\S]*?width\s*=\s*1080;\s*height\s*=\s*1440;" -Message "3:4 driver output must be 1080x1440."
Assert-Contains -Text $driverBridge -Pattern "width\s*=\s*kDriverWidth;\s*height\s*=\s*kDriverHeight;" -Message "16:9 driver output must use 1920x1080 base geometry."

Assert-Contains -Text $driverBridge -Pattern "GetAspectCanvasUvConstants" -Message "DriverBridge must crop the fixed producer canvas to the selected aspect rectangle."
Assert-Contains -Text $driverBridge -Pattern "ClearRenderTargetView\(m_scaledRtv\.get\(\),\s*clearColor\)" -Message "DriverBridge must clear letterbox padding before drawing fitted source."
Assert-Contains -Text $driverBridge -Pattern "33\.0f\s*/\s*255\.0f" -Message "DriverBridge letterbox padding must use #212121."
Assert-Contains -Text $driverBridge -Pattern "uvScaleX\s*=\s*outputAspect\s*/\s*sourceAspect" -Message "DriverBridge must extract the selected aspect region from the fixed producer canvas."
Assert-Contains -Text $driverBridge -Pattern "uvScaleY\s*=\s*sourceAspect\s*/\s*outputAspect" -Message "DriverBridge must extract the selected aspect region from the fixed producer canvas."
Assert-NotContains -Text $driverBridge -Pattern "GetOutputContainViewport" -Message "DriverBridge must not contain the already-letterboxed producer canvas again."
Assert-NotContains -Text $driverBridge -Pattern "GetFullSourceUvConstants" -Message "DriverBridge must not pass the whole fixed producer canvas to non-16:9 camera outputs."

Assert-Contains -Text $process -Pattern "GetContainCanvasViewport" -Message "Producer canvas must keep contain scaling."
Assert-Contains -Text $process -Pattern "33\.0f\s*/\s*255\.0f" -Message "Producer canvas padding must use #212121."

function Get-LetterboxBounds {
    param(
        [double]$SourceWidth,
        [double]$SourceHeight,
        [double]$OutputWidth,
        [double]$OutputHeight,
        [double]$CanvasWidth = 1920,
        [double]$CanvasHeight = 1080
    )

    $targetAspect = $OutputWidth / $OutputHeight
    $targetWidth = $CanvasWidth
    $targetHeight = $CanvasHeight
    if (($CanvasWidth / $CanvasHeight) -gt $targetAspect) {
        $targetWidth = $targetHeight * $targetAspect
    } else {
        $targetHeight = $targetWidth / $targetAspect
    }

    $targetX = ($CanvasWidth - $targetWidth) * 0.5
    $targetY = ($CanvasHeight - $targetHeight) * 0.5
    $scale = [Math]::Min($targetWidth / $SourceWidth, $targetHeight / $SourceHeight)
    $contentWidth = $SourceWidth * $scale
    $contentHeight = $SourceHeight * $scale
    $contentX = $targetX + (($targetWidth - $contentWidth) * 0.5)
    $contentY = $targetY + (($targetHeight - $contentHeight) * 0.5)

    $cropAspect = $targetAspect
    $cropWidth = $CanvasWidth
    $cropHeight = $CanvasHeight
    if (($CanvasWidth / $CanvasHeight) -gt $cropAspect) {
        $cropWidth = $cropHeight * $cropAspect
    } else {
        $cropHeight = $cropWidth / $cropAspect
    }
    $cropX = ($CanvasWidth - $cropWidth) * 0.5
    $cropY = ($CanvasHeight - $cropHeight) * 0.5

    [pscustomobject]@{
        Left = (($contentX - $cropX) / $cropWidth) * $OutputWidth
        Top = (($contentY - $cropY) / $cropHeight) * $OutputHeight
        Right = (($contentX + $contentWidth - $cropX) / $cropWidth) * $OutputWidth
        Bottom = (($contentY + $contentHeight - $cropY) / $cropHeight) * $OutputHeight
    }
}

function Assert-Near {
    param([double]$Actual, [double]$Expected, [double]$Tolerance, [string]$Message)
    if ([Math]::Abs($Actual - $Expected) -gt $Tolerance) {
        throw "$Message Actual=$Actual Expected=$Expected"
    }
}

function Assert-ContainGeometry {
    param(
        [string]$CaseName,
        [double]$SourceWidth,
        [double]$SourceHeight,
        [double]$OutputWidth,
        [double]$OutputHeight
    )

    $bounds = Get-LetterboxBounds -SourceWidth $SourceWidth -SourceHeight $SourceHeight -OutputWidth $OutputWidth -OutputHeight $OutputHeight
    $contentWidth = $bounds.Right - $bounds.Left
    $contentHeight = $bounds.Bottom - $bounds.Top
    $sourceAspect = $SourceWidth / $SourceHeight
    $contentAspect = $contentWidth / $contentHeight

    if ($bounds.Left -lt -1 -or $bounds.Top -lt -1 -or $bounds.Right -gt ($OutputWidth + 1) -or $bounds.Bottom -gt ($OutputHeight + 1)) {
        throw "$CaseName content escapes selected output canvas. Bounds=$($bounds | ConvertTo-Json -Compress)"
    }

    Assert-Near -Actual $contentAspect -Expected $sourceAspect -Tolerance 0.002 -Message "$CaseName must preserve source aspect."

    $touchLeft = [Math]::Abs($bounds.Left) -le 1
    $touchRight = [Math]::Abs($bounds.Right - $OutputWidth) -le 1
    $touchTop = [Math]::Abs($bounds.Top) -le 1
    $touchBottom = [Math]::Abs($bounds.Bottom - $OutputHeight) -le 1
    $fillsWidth = $touchLeft -and $touchRight
    $fillsHeight = $touchTop -and $touchBottom

    if (-not ($fillsWidth -or $fillsHeight)) {
        throw "$CaseName must expand until width or height is full; got windowbox. Bounds=$($bounds | ConvertTo-Json -Compress)"
    }

    if ($fillsWidth -and $fillsHeight) {
        return
    }

    if ($fillsWidth -and ($bounds.Top -lt -1 -or $bounds.Bottom -gt ($OutputHeight + 1))) {
        throw "$CaseName width-filled letterbox has invalid vertical bars."
    }
    if ($fillsHeight -and ($bounds.Left -lt -1 -or $bounds.Right -gt ($OutputWidth + 1))) {
        throw "$CaseName height-filled pillarbox has invalid side bars."
    }
}

$sourceCases = @(
    [pscustomobject]@{ Name = "source-16:9"; Width = 1920; Height = 1080 },
    [pscustomobject]@{ Name = "source-9:16"; Width = 1080; Height = 1920 },
    [pscustomobject]@{ Name = "source-4:3"; Width = 1440; Height = 1080 },
    [pscustomobject]@{ Name = "source-3:4"; Width = 1080; Height = 1440 },
    [pscustomobject]@{ Name = "source-1:1"; Width = 1200; Height = 1200 },
    [pscustomobject]@{ Name = "source-21:9"; Width = 2560; Height = 1080 }
)

foreach ($target in $aspectRatios) {
    Assert-Near -Actual ($target.Width / $target.Height) -Expected ($target.RatioW / $target.RatioH) -Tolerance 0.002 -Message "$($target.Name) output size must match declared aspect."
    foreach ($source in $sourceCases) {
        Assert-ContainGeometry `
            -CaseName "$($source.Name) into $($target.Name)" `
            -SourceWidth $source.Width `
            -SourceHeight $source.Height `
            -OutputWidth $target.Width `
            -OutputHeight $target.Height
    }

    Assert-ContainGeometry `
        -CaseName "$($target.Name) exact aspect source fills $($target.Name)" `
        -SourceWidth $target.Width `
        -SourceHeight $target.Height `
        -OutputWidth $target.Width `
        -OutputHeight $target.Height
}

[pscustomobject]@{
    Success = $true
    AspectRatiosChecked = @($aspectRatios.Name)
    GeometryCasesChecked = $aspectRatios.Count * ($sourceCases.Count + 1)
    CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Depth 3
