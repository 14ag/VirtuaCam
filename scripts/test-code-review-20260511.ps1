[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoText {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = Join-Path $repoRoot $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Missing file: $Path"
    }
    return Get-Content -LiteralPath $fullPath -Raw
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ((Get-RepoText -Path $Path) -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ((Get-RepoText -Path $Path) -match $Pattern) {
        throw $Message
    }
}

function Assert-Order {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $text = Get-RepoText -Path $Path
    $firstIndex = $text.IndexOf($First, [StringComparison]::Ordinal)
    $secondIndex = $text.IndexOf($Second, [StringComparison]::Ordinal)
    if ($firstIndex -lt 0 -or $secondIndex -lt 0 -or $firstIndex -gt $secondIndex) {
        throw $Message
    }
}

Assert-Contains -Path "driver-project\avshws.inf" -Pattern "(?m)^PnpLockdown=1$" -Message "INF must enable PnpLockdown."
Assert-Contains -Path "driver-project\avshws.inf" -Pattern "(?m)^DefaultDestDir=13$" -Message "INF DefaultDestDir must use DIRID 13."
Assert-Contains -Path "driver-project\avshws.inf" -Pattern "(?m)^avshws\.CopyFiles=13$" -Message "INF CopyFiles must use DIRID 13."
Assert-Contains -Path "driver-project\avshws.inf" -Pattern "(?m)^ServiceBinary=%13%\\avshws\.sys$" -Message "INF ServiceBinary must use DIRID 13."

Assert-Contains -Path "software-project\src\VirtuaCam\pch.h" -Pattern "#include <mfreadwrite\.h>" -Message "pch.h must include mfreadwrite.h."
Assert-Contains -Path "shared\VirtuaCamDriverAbi.h" -Pattern "VIRTUACAM_ASPECT_MASK_ALL" -Message "Shared ABI must own aspect masks."
Assert-Contains -Path "software-project\src\VirtuaCam\Config.h" -Pattern "ASPECT_RATIO_MASK_ALL\s+VIRTUACAM_ASPECT_MASK_ALL" -Message "User aspect masks must map to shared ABI."

Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "IOCTL_KS_PROPERTY" -Message "DriverBridge must use SDK IOCTL_KS_PROPERTY."
Assert-NotContains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "CTL_CODE\(FILE_DEVICE_KS,\s*0x000,\s*METHOD_NEITHER,\s*FILE_ANY_ACCESS\)" -Message "DriverBridge must not hand-roll FILE_ANY_ACCESS KS IOCTL."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "IoValidateDeviceIoControlAccess" -Message "KS handlers must perform dynamic access checks."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "ProbeForRead" -Message "KS set handlers must probe user input."
Assert-Contains -Path "driver-project\filter.cpp" -Pattern "ProbeForWrite" -Message "KS get handlers must probe user output."
Assert-NotContains -Path "driver-project\filter.cpp" -Pattern "OutputBufferLength\s*>\s*bufferLength" -Message "Scalar setters must not accept max(input, output) length."

Assert-Contains -Path "software-project\src\VirtuaCam\Tools.h" -Pattern "VIRTUACAM_MANIFEST_VERSION\s*=\s*2u" -Message "Manifest must be versioned."
Assert-Contains -Path "software-project\src\VirtuaCam\Tools.cpp" -Pattern "wcsnlen_s" -Message "Manifest strings must be bounded."
Assert-Contains -Path "software-project\src\VirtuaCam\Broker.cpp" -Pattern "RegisterExpectedProducer" -Message "Broker must expose expected producer registration."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "--broker-nonce" -Message "Producer launch must include broker nonce."
Assert-NotContains -Path "software-project\src\VirtuaCam\Multiplexer.cpp" -Pattern "reinterpret_cast<HANDLE>\(static_cast<UINT_PTR>\(streamInfo\.sharedFenceHandleValue\)\)" -Message "Multiplexer must not own untrusted raw handle values."

Assert-Order -Path "software-project\src\VirtuaCam\Broker.cpp" -First "context4->Signal" -Second "context->Flush();" -Message "Broker publish must flush after signal."
Assert-Order -Path "software-project\src\VirtuaCam\Process.cpp" -First "g_d3d11Context4->Signal" -Second "g_d3d11Context->Flush();" -Message "Producer publish must flush after signal."
Assert-Order -Path "software-project\src\VirtuaCam\Multiplexer.cpp" -First "m_context4->Signal" -Second "m_context->Flush();" -Message "Multiplexer publish must flush after signal."
Assert-Contains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern "VirtuaCamExeSha256" -Message "Service mode must verify installed executable hash."
Assert-NotContains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern "VIRTUACAM_STARTUP_ARGS[\s\S]{0,600}Watcher service" -Message "Service launch must ignore VIRTUACAM_STARTUP_ARGS."
$oldTrayFlag = "/" + "startup"
$oldStartupMode = "Startup " + "mode"
$processText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\Process.cpp") -Raw
if ($processText -notlike '*launchArgs = enableDebugLogging ? L"--driver -debug" : L"--driver"*') {
    throw "Watcher launch must use --driver only."
}
if ($processText -notlike '*launchArgs = L"--driver"*') {
    throw "Service launch must use --driver only."
}
Assert-NotContains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern ([regex]::Escape("$oldTrayFlag --driver")) -Message "Watcher/service must not combine old tray flag with --driver."
Assert-NotContains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "g_silentStart|$([regex]::Escape($oldTrayFlag))|-startup|$oldStartupMode" -Message "Redundant tray-silent mode must stay removed."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "g_driverStart = HasArg\(cmdLine, L`"--driver`"\)" -Message "App must auto-exit only for --driver launches."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "5ull \* 1000ull" -Message "--driver inactive timeout must be 5 seconds."
$appText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\App.cpp") -Raw
if ($appText -notmatch "else if \(g_driverStart\)[\s\S]{0,500}driver inactive for 5 seconds") {
    throw "--driver branch must own inactive auto-exit behavior."
}
$driverBridgeText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\DriverBridge.cpp") -Raw
if ($driverBridgeText -match "HRESULT DriverBridge::Initialize\(\)[\s\S]{0,260}EnsurePropertySetReady") {
    throw "DriverBridge init must not probe the AVStream driver during app startup."
}
if ($appText -match "DriverBridge failed to connect to the avshws kernel driver") {
    throw "App startup must not show the old DriverBridge modal when driver is absent."
}
if ($appText -notmatch "Virtual Camera Driver is not installed or not available[\s\S]{0,420}ShowAndLogError") {
    throw "App startup must show an explicit actionable driver-missing indicator."
}
if ($driverBridgeText -notmatch "HRESULT DriverBridge::SendFrame\([^\)]*\)[\s\S]{0,260}EnsurePropertySetReady\(\)[\s\S]{0,260}ApplyPendingAspectPolicyIfIdle\(\)[\s\S]{0,260}Connect\(\)") {
    throw "DriverBridge SendFrame must probe/defer policy before connecting."
}
if ($driverBridgeText -notmatch "HRESULT DriverBridge::SetAspectPolicy\([^\)]*\)[\s\S]{0,520}m_hasPendingAspectPolicy = true;[\s\S]{0,520}EnsurePropertySetReady\(\)[\s\S]{0,520}return S_OK;") {
    throw "DriverBridge aspect policy must be staged and deferred when the driver is unavailable."
}
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.h" -Pattern "bool IsConnected\(\) const" -Message "DriverBridge must expose connected state for --driver auto-exit."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.h" -Pattern "bool IsDriverInUse\(\)" -Message "DriverBridge must expose real driver-use state for --driver auto-exit."
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "kDriverProbeRetryMs" -Message "DriverBridge must back off missing-driver probes."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "g_driverBridge->IsDriverInUse\(\)" -Message "--driver auto-exit must track real driver use, not lazy bridge init."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "waiting for driver availability" -Message "Driver availability wait must be quiet/throttled, not modal."
$runtimeLogText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\RuntimeLog.cpp") -Raw
if ($runtimeLogText -notmatch "EnsureConsole\(options\.attachConsole \|\| allocConsole, allocConsole\)[\s\S]{0,180}if \(!options\.enabled\)") {
    throw "RuntimeLog must attach parent console before no-debug file logging gate."
}
if ($runtimeLogText -match "void LogHr\([^\)]*\)[\s\S]{0,220}LogLine\(") {
    throw "RuntimeLog HRESULT errors must go through stderr-visible error logging, not debug-only LogLine."
}
if ($runtimeLogText -match "void LogWin32\([^\)]*\)[\s\S]{0,220}LogLine\(") {
    throw "RuntimeLog Win32 errors must go through stderr-visible error logging, not debug-only LogLine."
}
Assert-Contains -Path "software-project\src\VirtuaCam\RuntimeLog.cpp" -Pattern "WriteStdHandleLineLocked\(STD_OUTPUT_HANDLE, line\)" -Message "Runtime messages must mirror to stdout for console/redirected test runs."
Assert-Contains -Path "software-project\src\VirtuaCam\RuntimeLog.cpp" -Pattern "WriteStdHandleLineLocked\(STD_ERROR_HANDLE, line\)" -Message "Runtime messages must mirror to stderr for console/redirected test runs."
Assert-Contains -Path "software-project\src\VirtuaCam\RuntimeLog.cpp" -Pattern "LogConsoleVisibleLine" -Message "RuntimeLog must keep all messages visible when normal logging is disabled."
$driverBridgeText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\DriverBridge.cpp") -Raw
if ($driverBridgeText -match "return\s+m_connected\s*\|\|\s*IsDriverClientActive\(\)") {
    throw "Driver-start auto-exit must not treat app-side upload connection as active driver use."
}
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "return IsDriverClientActive\(\);" -Message "Driver-start auto-exit must use actual driver capture activity."
$setupText = Get-Content -LiteralPath (Join-Path $repoRoot "wizard-project\src\VirtuaCamSetup.cpp") -Raw
if ($setupText -match "if \(!mode\.empty\(\)\)[\s\S]{0,900}MessageBoxW") {
    throw "Setup headless mode must not show popups."
}
if ($setupText -match "succeeded\\n\\nReport|succeeded[\s\S]{0,180}result\.jsonPath") {
    throw "Setup headless success summary must not reference a local report path."
}
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "WriteStdHandleLine\(STD_OUTPUT_HANDLE, line\)" -Message "Setup headless output must mirror to stdout."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "WriteStdHandleLine\(STD_ERROR_HANDLE, line\)" -Message "Setup headless output must mirror to stderr."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "WriteHeadlessSummary\(result\)" -Message "Setup headless mode must print console summary."
Assert-NotContains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "--quiet|/quiet" -Message "Setup must not expose a quiet flag; any flag means headless."
Assert-NotContains -Path "README.md" -Pattern "--quiet" -Message "README must not document a setup quiet flag."
Assert-NotContains -Path "CONTRIBUTING.md" -Pattern "--quiet" -Message "CONTRIBUTING must not document a setup quiet flag."
Assert-Contains -Path "scripts\hyperv-proof-chrome.ps1" -Pattern 'EnvUserKey\s+"DRIVER_TEST_VM_USERNAME"' -Message "Chrome VM proof must use .env guest username in noninteractive runs."
Assert-Contains -Path "scripts\hyperv-proof-chrome.ps1" -Pattern 'EnvPasswordKey\s+"DRIVER_TEST_VM_PASSWORD"' -Message "Chrome VM proof must use .env guest password in noninteractive runs."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern '\[ValidateRange\(1,\s*10\)\]\[int\]\$CdpConnectAttempts\s*=\s*3' -Message "Playwright proof must retry transient CDP attach failures by default."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern 'connectOverCDP\(attachBase,\s*\{\s*timeout:\s*connectTimeoutMs\s*\}\)' -Message "Playwright proof must pass an explicit CDP connect timeout."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern 'cdp-probe-attempt-\$\{attempt\}\.json' -Message "Playwright proof must write CDP probe artifacts for failed attach triage."

Write-Host "Code review 20260511 whitebox checks passed."
