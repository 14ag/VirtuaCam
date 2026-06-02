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
Assert-Contains -Path "scripts\hyperv-proof-chrome.ps1" -Pattern 'EnvUserKey\s+"DRIVER_TEST_VM_USERNAME"' -Message "Chrome VM proof must use .env guest username in noninteractive runs."
Assert-Contains -Path "scripts\hyperv-proof-chrome.ps1" -Pattern 'EnvPasswordKey\s+"DRIVER_TEST_VM_PASSWORD"' -Message "Chrome VM proof must use .env guest password in noninteractive runs."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern '\[ValidateRange\(1,\s*10\)\]\[int\]\$CdpConnectAttempts\s*=\s*3' -Message "Playwright proof must retry transient CDP attach failures by default."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern 'connectOverCDP\(attachBase,\s*\{\s*timeout:\s*connectTimeoutMs\s*\}\)' -Message "Playwright proof must pass an explicit CDP connect timeout."
Assert-Contains -Path "scripts\playwright-vm-webcam-proof.ps1" -Pattern 'cdp-probe-attempt-\$\{attempt\}\.json' -Message "Playwright proof must write CDP probe artifacts for failed attach triage."

Write-Host "Code review 20260511 whitebox checks passed."
