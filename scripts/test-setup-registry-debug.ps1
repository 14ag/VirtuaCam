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
Assert-Contains "software-project\src\VirtuaCam\Config.cpp" "StartDebugMode" "Debug next-session registry setting missing"
Assert-Contains "software-project\src\VirtuaCam\App.cpp" "existing.startDebugMode" "App saves must preserve setup debug setting"
Assert-Contains "software-project\src\VirtuaCam\Config.cpp" "DeleteLegacySettingsFile" "Legacy settings cleanup missing"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "UI_SetDebugMode" "Debug mode UI gate missing"
Assert-Contains "software-project\src\VirtuaCam\App.cpp" 'L"-debug"' "App -debug argument gate missing"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "Run VM Verifier Proof" "Verifier proof launcher missing from debug advanced UI"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "-EnableVerifier" "Verifier proof launcher does not enable verifier"
Assert-Contains "scripts\build-all.ps1" "Build setup wizard" "Build does not include setup wizard"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "PackageRoot()" "Setup wizard must use package-local output root"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" 'PackageRoot() / L"logs"' "Setup wizard logs must stay beside package"
Assert-Contains "software-project\src\VirtuaCam\Config.cpp" "DeleteLegacySettingsFile" "App does not clean legacy settings"
Assert-Contains "scripts\build-all.ps1" "function Stop-VirtuaCamBuildRuntime" "Build must stop running VirtuaCam before cleaning output"
Assert-Contains "scripts\build-all.ps1" "Stop-VirtuaCamBuildRuntime -PackageRoot `$OutputRoot" "Build must stop runtime before removing output"
Assert-Contains "scripts\build-all.ps1" "function Remove-PathWithRetry" "Build cleanup must retry locked output removal"
Assert-Contains "scripts\build-all.ps1" "Remove-PathWithRetry -Path `$OutputRoot -PackageRoot `$OutputRoot" "Build output cleanup must use retry helper"
Assert-Contains "scripts\build-all.ps1" "VirtuaCamSetup" "Build cleanup must stop setup preview window"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "HKCU settings registry" "Wizard registry check missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Mic enumeration" "Wizard generic mic check missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "MF_SOURCE_READER_ASYNC_CALLBACK" "Wizard final test frame does not use source reader callback"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "ReadSample" "Wizard final test frame does not read a frame sample"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "ResetForRead" "Wizard final test frame must retry null async samples"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "kReadAttempts" "Wizard final test frame retry budget missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "SERVICE_RUNNING" "Wizard service check must require running service"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Virtual Camera Source" "Wizard camera match must use exact VirtuaCam source name"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Status:                     Started" "Wizard PnP check must accept started devices"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--install" "Setup headless install flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--uninstall" "Setup headless uninstall flag missing"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "--verify-only" -Message "Setup verify mode must be removed"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "/verify" -Message "Setup verify mode must be removed"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--skip-dll-register" "Setup headless skip DLL flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--skip-certificate-import" "Setup headless skip certificate flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--skip-watcher-service" "Setup headless skip watcher flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--install-watcher-service" "Setup headless watcher install flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--uninstall-watcher-service" "Setup headless watcher uninstall flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "OpenSharedResourceByName" "Setup preview does not render broker shared texture"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "SetLogMode" "Setup must switch preview area to inline log display"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "LogDir() / L`"wizard`"" "Setup JSON logs must stay beside setup"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" 'PackageRoot() / L"logs"' "Setup logs must stay at artifact-root logs"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "RunNativeInstall" "Setup install logic must be native, not script-backed"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "UpdateDriverForPlugAndPlayDevicesW" "Setup must bind drivers natively"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "SetupDiCreateDeviceInfoW" "Setup must create root devices natively"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "/remove-device" "Setup uninstall must remove root device shells"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "CheckPnpDeviceRemoved" "Setup uninstall must verify unbound devices as removed"
Assert-Contains "software-project\src\VirtuaCam\RuntimeLog.cpp" 'exeDir / L"logs"' "Runtime logs must stay at artifact-root logs"
Assert-Contains "software-project\src\VirtuaCam\RuntimeLog.h" "GetLogDir" "Runtime log directory API missing"
Assert-Contains "software-project\src\VirtuaCam\DriverBridge.cpp" "VirtuaCamLog::GetLogDir()" "Driver frame dumps must use runtime log directory"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern ("install-all" + ".ps1") -Message "Setup still depends on legacy install script"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "FindRepoRoot" -Message "Setup still probes outside its package root"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "test-reports" -Message "Setup still writes reports outside package logs"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_INSTALL" "Setup install button missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_UNINSTALL" "Setup uninstall button missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_LAUNCH" "Setup launch button missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_OK" "Setup inline OK button missing"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "IDC_VERIFY" -Message "Setup verify button must be removed"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_DEBUG" "Setup debug checkbox missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Debug next session" "Setup debug checkbox label missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "StartDebugMode" "Setup debug checkbox must save VirtuaCam setting"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "BS_OWNERDRAW" "Setup debug checkbox must owner-draw text color"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "WM_DRAWITEM" "Setup debug checkbox must draw white label itself"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "g_debugChecked = !g_debugChecked" "Owner-drawn debug checkbox must toggle state"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "WM_CTLCOLORBTN" "Setup debug checkbox text color must be customized"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "SetTextColor(dc, RGB(242, 242, 242))" "Setup debug checkbox text must be white on dark background"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "ShowWindow(g_preview, g_logMode ? SW_HIDE : SW_SHOW)" "Setup preview must hide while showing inline logs"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "ShowWindow(g_ok, showOkOnly ? SW_SHOW : SW_HIDE)" "Setup must show OK during operation/result state"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern 'Successfully installed drivers", L"VirtuaCam Setup", MB_OK' -Message "Setup install confirmation must be inline, not popup"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "BeginOperationLog" "Setup operation log buffer missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "FlushOperationLog" "Setup must flush operation logs on failure"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "DiscardOperationLog" "Setup must discard operation logs on success"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "RemoveRunJson(result.jsonPath)" "Setup must remove success JSON logs for install/uninstall"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" 'RunFirstRunChecks(L"install-verify", {}, false)' "Install post-checks must not write success logs"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "FOLDERID_LocalAppData" -Message "Setup must not use LocalAppData for legacy cleanup or logs"
$scriptPaths = @(Get-ChildItem -Path (Join-Path $repoRoot "scripts") -Filter *.ps1 -File | Where-Object { $_.Name -ne "test-setup-registry-debug.ps1" } | Select-Object -ExpandProperty FullName)
Assert-NotContains -Paths $scriptPaths -Pattern ("install-all" + ".ps1") -Message "Automation must use setup wizard, not legacy install script"
if (Test-Path -LiteralPath (Join-Path $repoRoot "scripts\install-watcher-service.ps1")) { Fail "Watcher service install script must be migrated into setup wizard" }
if (Test-Path -LiteralPath (Join-Path $repoRoot "scripts\uninstall-watcher-service.ps1")) { Fail "Watcher service uninstall script must be migrated into setup wizard" }
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "DeleteLegacySettings" -Message "Setup legacy settings cleanup is redundant"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "Elevated install window opened" -Message "Setup must not show elevated install opened status"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "INSTALL-ALL SUCCEEDED" -Message "Setup must not write success operation logs"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "VirtuaCamSetup.exe" "Show Preview does not launch setup exe"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "ShellExecuteW" "Show Preview does not open setup exe"

Write-Host "PASS setup/registry/debug whitebox checks"
