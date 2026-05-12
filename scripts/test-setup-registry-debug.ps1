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
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "Run VM Verifier Proof" "Verifier proof launcher missing from debug advanced UI"
Assert-Contains "software-project\src\VirtuaCam\UI.cpp" "-EnableVerifier" "Verifier proof launcher does not enable verifier"
Assert-Contains "scripts\build-all.ps1" "Build setup wizard" "Build does not include setup wizard"
Assert-Contains "scripts\install-all.ps1" "Remove-LegacyUserSettingsFile" "Installer does not clean legacy settings"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "HKCU settings registry" "Wizard registry check missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Mic enumeration" "Wizard generic mic check missing"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "MF_SOURCE_READER_ASYNC_CALLBACK" "Wizard final test frame does not use source reader callback"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "ReadSample" "Wizard final test frame does not read a frame sample"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "SERVICE_RUNNING" "Wizard service check must require running service"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Virtual Camera Source" "Wizard camera match must use exact VirtuaCam source name"
Assert-Contains "wizard-project\src\VirtuaCamSetup.cpp" "Status:                     Started" "Wizard PnP check must accept started devices"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "--install" -Message "Wizard install flag must not be present"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "--repair" -Message "Wizard repair flag must not be present"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "--uninstall" -Message "Wizard uninstall flag must not be present"
Assert-NotContains -Paths @((Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp")) -Pattern "RunScriptAction" -Message "Wizard must not shell out to install script"

Write-Host "PASS setup/registry/debug whitebox checks"
