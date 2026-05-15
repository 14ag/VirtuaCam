[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $fullPath = Join-Path $repoRoot $Path
    $text = Get-Content -LiteralPath $fullPath -Raw
    if ($text -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $fullPath = Join-Path $repoRoot $Path
    $text = Get-Content -LiteralPath $fullPath -Raw
    if ($text -match $Pattern) {
        throw $Message
    }
}

Assert-Contains `
    -Path "driver-project\device.h" `
    -Pattern "LONG\s+m_PinsWithResources;" `
    -Message "Device must track acquired stream resources."

Assert-Contains `
    -Path "driver-project\device.h" `
    -Pattern "LONG\s+m_RemovePending;[\s\S]*SetRemovePending[\s\S]*IsRemovePending" `
    -Message "Device must track remove-pending state after query-remove."

Assert-Contains `
    -Path "driver-project\device.h" `
    -Pattern "PKSFILTERFACTORY\s+m_FilterFactory;[\s\S]*SetFilterFactoryDeviceClassesState" `
    -Message "Device must track its AVStream filter factory so PnP can disable and re-enable device classes."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpQueryRemove[\s\S]*SetRemovePending\(TRUE\)[\s\S]*return STATUS_SUCCESS;" `
    -Message "PnpQueryRemove must enter remove-pending state and allow Device Fundamentals remove/restart."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpStart[\s\S]*m_FilterFactory\s*=\s*filterFactory[\s\S]*SetFilterFactoryDeviceClassesState\(TRUE,\s*""PnpStart""\)" `
    -Message "PnpStart must store and enable the AVStream filter factory device classes."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpQueryRemove[\s\S]*SetFilterFactoryDeviceClassesState\(FALSE,\s*""PnpQueryRemove""\)" `
    -Message "PnpQueryRemove must disable AVStream device classes before remove/restart."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpQueryRemove[\s\S]*NotifyCameraState\(FALSE\)[\s\S]*m_HardwareSimulation\s*->\s*Stop\s*\(" `
    -Message "PnpQueryRemove must quiesce active streaming hardware before remove/restart."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpCancelRemove[\s\S]*SetRemovePending\(FALSE\)[\s\S]*Start\s*\([\s\S]*NotifyCameraState\(TRUE\)" `
    -Message "PnpCancelRemove must restart active streaming hardware after a canceled remove."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpCancelRemove[\s\S]*SetFilterFactoryDeviceClassesState\(TRUE,\s*""PnpCancelRemove""\)" `
    -Message "PnpCancelRemove must re-enable AVStream device classes after a canceled remove."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpRemove[\s\S]*SetFilterFactoryDeviceClassesState\(FALSE,\s*""PnpRemove""\)[\s\S]*m_FilterFactory\s*=\s*NULL" `
    -Message "PnpRemove must disable AVStream device classes and clear the filter factory pointer."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpSurpriseRemoval[\s\S]*SetFilterFactoryDeviceClassesState\(FALSE,\s*""PnpSurpriseRemoval""\)[\s\S]*m_FilterFactory\s*=\s*NULL" `
    -Message "PnpSurpriseRemoval must disable AVStream device classes and clear the filter factory pointer."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "QueryCapabilities[\s\S]*Removable\s*=\s*TRUE[\s\S]*SurpriseRemovalOK\s*=\s*TRUE" `
    -Message "Device capabilities must mark this root virtual camera as removable and surprise-removal safe."

Assert-Contains `
    -Path "driver-project\avshws.inf" `
    -Pattern "\[avshws\.NTx86\.HW\][\s\S]*AddReg=avshws\.DeviceRemovalPolicy\.AddReg[\s\S]*\[avshws\.NTamd64\.HW\][\s\S]*AddReg=avshws\.DeviceRemovalPolicy\.AddReg[\s\S]*\[avshws\.NTarm\.HW\][\s\S]*AddReg=avshws\.DeviceRemovalPolicy\.AddReg[\s\S]*\[avshws\.NTarm64\.HW\][\s\S]*AddReg=avshws\.DeviceRemovalPolicy\.AddReg" `
    -Message "INF must set removal policy override from every architecture-specific hardware section."

Assert-Contains `
    -Path "driver-project\avshws.inf" `
    -Pattern "\[avshws\.DeviceRemovalPolicy\.AddReg\][\s\S]*HKR,,RemovalPolicy,%REG_DWORD%,3" `
    -Message "INF must set CM_REMOVAL_POLICY_EXPECT_SURPRISE_REMOVAL through the hardware key removal policy override."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "CaptureDeviceDispatch[\s\S]*DispatchPnpQueryCapabilities" `
    -Message "Device dispatch table must provide a query-capabilities callback."

Assert-Contains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpCancelRemove[\s\S]*SetRemovePending\(FALSE\)" `
    -Message "PnpCancelRemove must reopen creates after a canceled remove."

Assert-NotContains `
    -Path "driver-project\device.cpp" `
    -Pattern "PnpQueryRemove[\s\S]*STATUS_DEVICE_BUSY" `
    -Message "PnpQueryRemove must not create PNP_VetoDevice during HLK remove/restart."

Assert-Contains `
    -Path "driver-project\filter.cpp" `
    -Pattern "DispatchCreate[\s\S]*IsRemovePending\(\)[\s\S]*STATUS_DELETE_PENDING" `
    -Message "Filter create must fail while the device is remove-pending."

Assert-NotContains `
    -Path "driver-project\filter.cpp" `
    -Pattern "AddOpenFilter|RemoveOpenFilter|m_OpenFilterCounted" `
    -Message "Filter lifetime must not drive PnP query-remove veto state."

Assert-Contains `
    -Path "driver-project\filter.cpp" `
    -Pattern "DispatchClose[\s\S]*return STATUS_SUCCESS" `
    -Message "Filter close dispatch must complete successfully."

Assert-Contains `
    -Path "driver-project\filter.cpp" `
    -Pattern "CaptureFilterDispatch[\s\S]*CCaptureFilter::DispatchClose" `
    -Message "Filter dispatch table must provide a close callback."

Assert-Contains `
    -Path "driver-project\capture.cpp" `
    -Pattern "DispatchClose[\s\S]*SetState\(KSSTATE_STOP,\s*KSSTATE_RUN\)" `
    -Message "Pin close must force stop cleanup for Device Fundamentals PnP cycles."

Assert-Contains `
    -Path "driver-project\capture.cpp" `
    -Pattern "DispatchCreate[\s\S]*IsRemovePending\s*\(\s*\)[\s\S]*STATUS_DELETE_PENDING" `
    -Message "Pin create must fail while the device is remove-pending."

Assert-Contains `
    -Path "driver-project\capture.cpp" `
    -Pattern "KSSTATE_ACQUIRE[\s\S]*IsRemovePending\s*\(\s*\)[\s\S]*STATUS_DELETE_PENDING" `
    -Message "Pin acquire must fail while the device is remove-pending."

Assert-Contains `
    -Path "driver-project\capture.cpp" `
    -Pattern "KSSTATE_RUN[\s\S]*IsRemovePending\s*\(\s*\)[\s\S]*STATUS_DELETE_PENDING" `
    -Message "Pin run must fail while the device is remove-pending."

Assert-Contains `
    -Path "driver-project\capture.cpp" `
    -Pattern "CapturePinDispatch[\s\S]*CCapturePin::DispatchClose" `
    -Message "Pin dispatch table must provide a close callback."

$inputPath = Join-Path $env:TEMP ("vhlk-filter-input-{0}.txt" -f ([guid]::NewGuid()))
$skipPath = Join-Path $env:TEMP ("vhlk-filter-skip-{0}.txt" -f ([guid]::NewGuid()))
$outputPath = Join-Path $env:TEMP ("vhlk-filter-output-{0}.txt" -f ([guid]::NewGuid()))

try {
    @("A", "B", "C") | Set-Content -LiteralPath $inputPath -Encoding UTF8
    @("b") | Set-Content -LiteralPath $skipPath -Encoding UTF8
    $json = & (Join-Path $repoRoot "scripts\filter-vhlk-test-list.ps1") -InputPath $inputPath -SkipPath $skipPath -OutputPath $outputPath
    $result = $json | ConvertFrom-Json
    $names = @(Get-Content -LiteralPath $outputPath)
    if ($result.OutputCount -ne 2 -or ($names -join ",") -ne "A,C") {
        throw "filter-vhlk-test-list.ps1 did not remove skipped tests case-insensitively."
    }
}
finally {
    Remove-Item -LiteralPath $inputPath, $skipPath, $outputPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Driver PnP contract checks passed."
