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
Assert-Contains "scripts\install-all.ps1" '$OutputRoot = $packageRoot' "Installer must use package-local output root"
Assert-Contains "scripts\install-all.ps1" 'Join-Path $packageRoot "logs"' "Installer logs must stay beside package"
Assert-Contains "scripts\install-all.ps1" "Remove-LegacyUserSettingsFile" "Installer does not clean legacy settings"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "HKCU settings registry" "Wizard registry check missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Mic enumeration" "Wizard generic mic check missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "MF_SOURCE_READER_ASYNC_CALLBACK" "Wizard final test frame does not use source reader callback"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "ReadSample" "Wizard final test frame does not read a frame sample"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "SERVICE_RUNNING" "Wizard service check must require running service"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Virtual Camera Source" "Wizard camera match must use exact VirtuaCam source name"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Status:                     Started" "Wizard PnP check must accept started devices"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--install" "Setup headless install flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--uninstall" "Setup headless uninstall flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--skip-dll-register" "Setup headless skip DLL flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--skip-certificate-import" "Setup headless skip certificate flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "--skip-watcher-service" "Setup headless skip watcher flag missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "OpenSharedResourceByName" "Setup preview does not render broker shared texture"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "LogDir() / L`"wizard`"" "Setup JSON logs must stay beside setup"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "RunNativeInstall" "Setup install logic must be native, not script-backed"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "UpdateDriverForPlugAndPlayDevicesW" "Setup must bind drivers natively"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "SetupDiCreateDeviceInfoW" "Setup must create root devices natively"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "install-all.ps1" -Message "Setup still depends on install script"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "FindRepoRoot" -Message "Setup still probes outside its package root"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "test-reports" -Message "Setup still writes reports outside package logs"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_INSTALL" "Setup install button missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_UNINSTALL" "Setup uninstall button missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "IDC_DEBUG" "Setup debug checkbox missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Debug next session" "Setup debug checkbox label missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "StartDebugMode" "Setup debug checkbox must save VirtuaCam setting"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "VirtuaCamSetup.exe" "Show Preview does not launch setup exe"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "ShellExecuteW" "Show Preview does not open setup exe"

Write-Host "PASS setup/registry/debug whitebox checks"
