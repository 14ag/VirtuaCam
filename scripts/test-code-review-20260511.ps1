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
if ($processText -notmatch "serviceMode = HasArg\(cmdLine, L`"--service`"\)[\s\S]{0,180}enableDebugLogging = HasArg\(cmdLine, L`"-debug`"\) \|\| serviceMode") {
    throw "Watcher service mode must enable runtime logging by default."
}
Assert-NotContains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern ([regex]::Escape("$oldTrayFlag --driver")) -Message "Watcher/service must not combine old tray flag with --driver."
Assert-NotContains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "g_silentStart|$([regex]::Escape($oldTrayFlag))|-startup|$oldStartupMode" -Message "Redundant tray-silent mode must stay removed."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "g_driverStart = HasArg\(cmdLine, L`"--driver`"\)" -Message "App must auto-exit only for --driver launches."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "5ull \* 1000ull" -Message "--driver inactive timeout must be 5 seconds."
$appText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\App.cpp") -Raw
if ($appText -notmatch "else if \(g_driverStart\)[\s\S]{0,500}no active driver stream or producer for 5 seconds") {
    throw "--driver branch must own producer-aware inactive auto-exit behavior."
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
Assert-Contains -Path "software-project\src\VirtuaCam\Tools.cpp" -Pattern "ReadDirectPortStatusStable[\s\S]{0,900}__try" -Message "DirectPort status sidecar reads must be protected against stale mappings."
$driverBridgeText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\DriverBridge.cpp") -Raw
if ($driverBridgeText -match "return\s+m_connected\s*\|\|\s*IsDriverClientActive\(\)") {
    throw "Driver-start auto-exit must not treat app-side upload connection as active driver use."
}
Assert-Contains -Path "software-project\src\VirtuaCam\DriverBridge.cpp" -Pattern "status\.HardwareState != kDriverHardwareStateStopped" -Message "Driver-start auto-exit must treat paused/running camera pins as active."
Assert-Contains -Path "driver-project\hwsim.cpp" -Pattern "if \(isRunning\) \{[\s\S]{0,220}KeSetEvent\(registeredClientRequestEventObject[\s\S]{0,220}KeSetEvent\(namedClientRequestEventObject" -Message "Driver must signal watcher on every camera RUN transition, even after stale client state."
Assert-NotContains -Path "driver-project\hwsim.cpp" -Pattern "if \(!clientConnected \|\| acceptedFrameCount == 0\)" -Message "Driver watcher signal must not be suppressed by stale client/accepted-frame counters."
Assert-Contains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern "Watcher service: client request event signaled" -Message "Watcher service must log client request wakeups for blackbox diagnosis."
Assert-Contains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern "Watcher service: launched VirtuaCam\.exe pid=" -Message "Watcher service must log launch success for blackbox diagnosis."
$appText = Get-Content -LiteralPath (Join-Path $repoRoot "software-project\src\VirtuaCam\App.cpp") -Raw
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "sourceActive = brokerState == BrokerState::Connected \|\| HasLiveProducerProcess\(\)" -Message "Driver-start mode must stay alive while a producer source is connected or starting."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "keepAliveActive = driverActive \|\| sourceActive" -Message "Driver-start idle gate must use driver or producer activity."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "PostThreadMessageW\(pi\.dwThreadId, WM_QUIT" -Message "Producer shutdown must request graceful WM_QUIT before fallback termination."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "RefreshAudioDevicesIfChanged" -Message "Runtime must refresh audio capture device lists after startup."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "kAudioDeviceRefreshMs" -Message "Audio device refresh must be bounded by a cadence, not busy polling."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "Audio device list changed" -Message "Audio device hotplug must log list changes for support diagnosis."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "Selected audio source unavailable after device refresh" -Message "Missing selected audio source must be visible instead of silent stale routing."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "GetRuntimeDriverStatusText" -Message "Runtime must expose compact driver diagnostics to support UI."
Assert-Contains -Path "software-project\src\VirtuaCam\App.cpp" -Pattern "GetRuntimeAudioStatusText" -Message "Runtime must expose compact audio diagnostics to support UI."
Assert-Contains -Path "software-project\src\VirtuaCam\WASAPI.cpp" -Pattern "IsVirtuaCamAudioSource" -Message "Runtime audio source enumeration must filter VirtuaCam microphone to avoid self-loop selection."
Assert-Contains -Path "software-project\src\VirtuaCam\WASAPI.cpp" -Pattern "if \(!IsVirtuaCamAudioSource\(name\)\)" -Message "Runtime audio source list must skip VirtuaCam endpoints before assigning UI indices."
if ($appText -match "void TerminateProducer\([^\)]*\)[\s\S]{0,180}TerminateProcess") {
    throw "Source switching must not kill producers before graceful shutdown."
}
Assert-Order -Path "software-project\src\VirtuaCam\App.cpp" -First "StopProducerProcess(key, pi);" -Second "g_driverBridge->Shutdown();" -Message "Shutdown must stop producers before driver/broker teardown to release WGC capture cleanly."
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
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "failure[\s\S]{0,160}restart/1000/restart/5000" -Message "Setup must configure watcher service failure restart."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "failureflag[\s\S]{0,120}kWatcherServiceName" -Message "Setup must enable watcher service failure actions for non-crash exits."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "UiActionWorkerProc" -Message "Setup GUI install/uninstall/launch actions must run on a worker, not the UI thread."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "WM_APP_OPERATION_DONE" -Message "Setup GUI worker completion must return through the UI message pump."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "SetTimer\(g_hwnd, kOperationLogTimerId" -Message "Setup GUI must keep the canvas log updated while operations run."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "SetOperationUi\(true, false\)" -Message "Setup GUI operations must hide action buttons and show disabled OK while work is running."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "OperationCompleteText" -Message "Setup GUI must use operation-specific completion text instead of generic reports."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "OpenVirtualCameraSource\(source, name\)" -Message "Setup preview must read the installed driver camera, not the software broker texture."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "MF_SOURCE_READER_ASYNC_CALLBACK" -Message "Setup driver preview must use async Source Reader callback instead of blocking UI reads."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "Launch command returned but VirtuaCam\.exe was not observed running" -Message "Setup launch must fail honestly when the runtime does not start."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "for \(int id : \{ IDC_LAUNCH, IDC_INSTALL, IDC_UNINSTALL \}\)" -Message "Setup buttons must be ordered Launch, Install, Uninstall."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "ShowWindow\(g_status, SW_HIDE\)" -Message "Setup status messages must not appear outside the log box."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "Elevated setup started\. Press OK" -Message "Setup elevation handoff must be visible in the log box."
Assert-NotContains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "Preview waiting for VirtuaCam video|Preview ready|kBrokerTextureName|VirtuaCast_Broker_Texture|E&xit|--skip-watcher-service|/skip-watcher-service" -Message "Setup must not show preview overlay text, broker preview dependency, exit button, or watcher-service bypass."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "KEY_SET_VALUE \| KEY_QUERY_VALUE" -Message "Setup settings writes must open readback access for verification."
Assert-Contains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "verified == value" -Message "Setup settings writes must verify DWORD readback."
if ($setupText -match "void RunUiAction\([^\)]*\)[\s\S]{0,900}RunMode\(") {
    throw "Setup RunUiAction must not call RunMode directly on the UI thread."
}
Assert-NotContains -Path "wizard-project\src\VirtuaCamSetup.cpp" -Pattern "--quiet|/quiet" -Message "Setup must not expose a quiet flag; any flag means headless."
Assert-NotContains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "--quiet|/quiet|--verify-only|/verify" -Message "Runtime UI must not launch removed setup quiet/verify flags."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern 'AddNativeMenuItem\(menu, L"Open Logs", ID_TRAY_OPEN_LOGS\)' -Message "Open Logs must be available from the normal tray menu, not only debug menus."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "BuildSupportStatusText" -Message "About/status UI must show driver, broker, source, and log location."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "SourceSummaryText" -Message "Tray status must disclose source/default-feed state."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "default feed" -Message "Tray status must make default-feed fallback visible."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "GetRuntimeDriverStatusText" -Message "About/support UI must include runtime driver details and last error."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "GetRuntimeAudioStatusText" -Message "About/support UI must include runtime audio route details."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "IsVirtuaCamVideoSource" -Message "Runtime video source enumeration must filter the VirtuaCam virtual camera to avoid self-loop selection."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "ContainsNoCase\(link, L`"avshws`"\)" -Message "Runtime video source filter must reject the avshws symbolic link as well as friendly names."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern "lParam == WM_LBUTTONUP \|\| lParam == NIN_SELECT" -Message "Tray left-click/select must open the tray menu."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern 'Windows and Games' -Message "Source menus must group large source lists with readable headers."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern 'Video Capture Devices' -Message "Source menus must label camera/device sections."
Assert-Contains -Path "software-project\src\VirtuaCam\UI.cpp" -Pattern 'Driver: \{\}' -Message "Tray tooltip must include driver state."
Assert-Contains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern "RegisterClientRequestEvent\(eventHandle\)" -Message "Watcher must register the client-request event handle with the driver."
Assert-Contains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern "kGlobalClientRequestEventName" -Message "Watcher must use the global client-request event name expected by the driver."
Assert-Contains -Path "software-project\src\VirtuaCam\Process.cpp" -Pattern "falling back to session-local event" -Message "Watcher must log fallback when global event setup fails."
Assert-NotContains -Path "README.md" -Pattern "--quiet" -Message "README must not document a setup quiet flag."
Assert-NotContains -Path "CONTRIBUTING.md" -Pattern "--quiet" -Message "CONTRIBUTING must not document a setup quiet flag."
Assert-NotContains -Path "driver-project\README.md" -Pattern "--quiet" -Message "Driver README must not document a setup quiet flag."
Assert-NotContains -Path "software-project\README.md" -Pattern "--quiet" -Message "Software README must not document a setup quiet flag."
Assert-NotContains -Path "wiki\Getting-Started.md" -Pattern "--quiet" -Message "Getting Started wiki must not document a setup quiet flag."
Assert-NotContains -Path "wiki\Testing.md" -Pattern "--quiet" -Message "Testing wiki must not document a setup quiet flag."
Assert-Contains -Path "scripts\hyperv-proof-chrome.ps1" -Pattern 'EnvUserKey\s+"DRIVER_TEST_VM_USERNAME"' -Message "Chrome VM proof must use .env guest username in noninteractive runs."
Assert-Contains -Path "scripts\hyperv-proof-chrome.ps1" -Pattern 'EnvPasswordKey\s+"DRIVER_TEST_VM_PASSWORD"' -Message "Chrome VM proof must use .env guest password in noninteractive runs."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern '\[ValidateRange\(1,\s*10\)\]\[int\]\$CdpConnectAttempts\s*=\s*3' -Message "Playwright proof must retry transient CDP attach failures by default."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern 'connectOverCDP\(attachBase,\s*\{\s*timeout:\s*connectTimeoutMs\s*\}\)' -Message "Playwright proof must pass an explicit CDP connect timeout."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern 'cdp-probe-attempt-\$\{attempt\}\.json' -Message "Playwright proof must write CDP probe artifacts for failed attach triage."
Assert-Contains -Path "scripts\guest-held-webcam-session.ps1" -Pattern "Wait-ForLocalHttpUrl" -Message "Guest held-session proof must wait for the local webcam HTTP server before reporting ready."
Assert-Contains -Path "scripts\guest-held-webcam-session.ps1" -Pattern "HttpServerReadyProbe" -Message "Guest held-session status must include HTTP server readiness diagnostics."
Assert-Contains -Path "scripts\guest-held-webcam-session.ps1" -Pattern 'RedirectStandardError\s+\$serverStdErr' -Message "Guest held-session proof must capture HTTP server stderr for triage."
Assert-Contains -Path "scripts\hyperv-hold-webcam-session.ps1" -Pattern "FileShare\]::ReadWrite" -Message "Host held-session proof must tolerate concurrent guest status writes."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern "FileShare\]::ReadWrite" -Message "Playwright proof must tolerate concurrent VM status writes."
Assert-Contains -Path "scripts\hyperv-proof-chrome.ps1" -Pattern "FileShare\]::ReadWrite" -Message "Chrome proof wrapper must tolerate concurrent VM status writes."

Write-Host "Code review 20260511 whitebox checks passed."
