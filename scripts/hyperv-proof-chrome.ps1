[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [string]$GuestPasswordPlaintext = "",
    [string]$DriverPackageRoot = "output",
    [string]$ArtifactRoot = "output\playwright",
    [ValidateSet("Chrome", "Edge")][string]$Browser = "Chrome",
    [string[]]$BrowserExtraArgs = @(),
    [switch]$EnableVerifier,
    [bool]$RevertAfterRun = $true,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-ResearchNote {
    param(
        [Parameter(Mandatory = $true)][string]$ErrorClass,
        [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
        [Parameter(Mandatory = $true)][string]$ErrorSignature
    )

    $safeName = ($ErrorClass -replace '[^A-Za-z0-9._-]', '-')
    $path = Join-Path $ArtifactDirectory ("research-note-{0}.md" -f $safeName)

    $lines = switch ($ErrorClass) {
        "chrome.NotSupportedError" {
            @(
                "# Research Note: chrome.NotSupportedError",
                "",
                "Repeated signature: $ErrorSignature",
                "",
                "Findings:",
                "- `getUserMedia()` requires secure context; `http://127.0.0.1` and `http://localhost` qualify.",
                "- Chromium still exposes `--force-directshow` on Windows.",
                "- Chromium capture defaults on Windows can differ by backend, so Media Foundation vs DirectShow matters during device negotiation.",
                "",
                "Next change:",
                "- Ensure guest Chrome launch keeps `--force-directshow` in proof path.",
                "- Compare browser result with runtime logs and driver frame logs before next rerun.",
                "",
                "Sources:",
                "- https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia",
                "- https://chromium.googlesource.com/chromium/src/media/%2B/142dece531032e4a6f8e8cb14f447c6972d150ab/base/media_switches.cc",
                "- https://chromium.googlesource.com/chromium/src/%2B/b21f99fbd0b44c68eb9471ecf503b7c329af316f/media/base/media_switches.cc"
            )
        }
        "vm.BSOD" {
            @(
                "# Research Note: vm.BSOD",
                "",
                "Repeated signature: $ErrorSignature",
                "",
                "Findings:",
                "- Treat unexpected guest logout, PowerShell Direct loss, or restart during driver exercise as crash path until dump says otherwise.",
                "- Use `!analyze -v` on newest dump, then map verifier bugchecks and params before rerun.",
                "",
                "Next change:",
                "- Collect latest dump and system/setupapi logs before next attempt.",
                "- If verifier involved, map bugcheck to exact rule before more stress.",
                "",
                "Sources:",
                "- https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/handling-a-bug-check-when-driver-verifier-is-enabled",
                "- https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/verifier-command-line"
            )
        }
        "driver.InstallFailed" {
            @(
                "# Research Note: driver.InstallFailed",
                "",
                "Repeated signature: $ErrorSignature",
                "",
                "Findings:",
                "- x64 kernel driver install path expects signed or test-signed package.",
                "- Automated guest install should verify `TESTSIGNING` and trust chain before `pnputil /add-driver /install`.",
                "",
                "Next change:",
                "- Recheck guest `TESTSIGNING`, cert import, and setupapi slice before next install.",
                "",
                "Sources:",
                "- https://learn.microsoft.com/en-us/windows-hardware/drivers/install/test-signing"
            )
        }
        "driver.VerifierBugcheck" {
            @(
                "# Research Note: driver.VerifierBugcheck",
                "",
                "Repeated signature: $ErrorSignature",
                "",
                "Findings:",
                "- Driver Verifier rule and bugcheck params must drive next step.",
                "- DDI compliance / SDV follow-up fits repeated IRQL, lock, or API misuse signals.",
                "",
                "Next change:",
                "- Map verifier rule from dump before rerun.",
                "- Queue SDV/DDI pass if bugcheck points to rule-based misuse.",
                "",
                "Sources:",
                "- https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/verifier-command-line",
                "- https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/ddi-compliance-checking",
                "- https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/static-driver-verifier"
            )
        }
        default {
            @(
                "# Research Note: $ErrorClass",
                "",
                "Repeated signature: $ErrorSignature",
                "",
                "Observation:",
                "- Same failure hit twice. Stop blind reruns.",
                "",
                "Next change:",
                "- Inspect latest status, logs, and dump artifacts before next attempt."
            )
        }
    }

    Set-Content -LiteralPath $path -Encoding UTF8 -Value ($lines -join [Environment]::NewLine)
    return $path
}

function Update-AttemptState {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [bool]$Success,
        [string]$ErrorClass = "",
        [string]$ErrorSignature = "",
        [string]$LastChange = ""
    )

    $previous = Read-JsonFile -Path $StatePath
    $attempt = if ($previous) { [int]$previous.attempt + 1 } else { 1 }
    $repeatCount = 0
    $researchNote = ""
    $researched = $false

    if (-not $Success) {
        if ($previous -and $previous.error_signature -eq $ErrorSignature) {
            $repeatCount = [int]$previous.repeat_count + 1
        }
        else {
            $repeatCount = 1
        }

        if ($repeatCount -ge 2) {
            $researchNote = New-ResearchNote -ErrorClass $ErrorClass -ArtifactDirectory (Split-Path -Parent $StatePath) -ErrorSignature $ErrorSignature
            $researched = $true
        }
    }

    $state = [pscustomobject]@{
        attempt = $attempt
        status = if ($Success) { "success" } else { "failed" }
        error_class = $ErrorClass
        error_signature = $ErrorSignature
        repeat_count = $repeatCount
        last_change = $LastChange
        researched = $researched
        research_note = $researchNote
        updated_at = [DateTime]::UtcNow.ToString("o")
    }

    Write-JsonFile -Path $StatePath -Data $state
    return $state
}

function Wait-ForGuestRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        $vmState = (Get-VM -Name $VmName -ErrorAction Stop).State.ToString()
        Write-HvLog -Message ("PowerShell Direct reconnect attempt {0}; VM state={1}" -f $attempt, $vmState) -LogPath $LogFile
        try {
            return Wait-HvPowerShellDirect -VmName $VmName -Credential $Credential -TimeoutSeconds 20 -LogPath $LogFile
        }
        catch {
            Write-HvLog -Message ("Reconnect attempt {0} failed: {1}" -f $attempt, $_.Exception.Message) -LogPath $LogFile -Level WARN
            Start-Sleep -Seconds 5
        }
    }

    return $null
}

function Invoke-CollectArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)][string]$GuestUser,
        [Parameter(Mandatory = $true)][string]$GuestPasswordPlaintext,
        [Parameter(Mandatory = $true)][string]$GuestPackageRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    $recoverySession = Wait-ForGuestRecovery -VmName $VmName -Credential $Credential -LogFile $LogFile -TimeoutSeconds 300
    if ($recoverySession) {
        Remove-PSSession -Session $recoverySession -ErrorAction SilentlyContinue
    }
    else {
        Write-HvLog -Message "Guest did not recover for artifact collection window." -LogPath $LogFile -Level WARN
        return
    }

    & (Join-Path $PSScriptRoot "hyperv-collect.ps1") `
        -VmName $VmName `
        -GuestUser $GuestUser `
        -GuestPasswordPlaintext $GuestPasswordPlaintext `
        -GuestPackageRoot $GuestPackageRoot `
        -ArtifactRoot $ArtifactDirectory `
        -LogPath (Join-Path $ArtifactDirectory "hyperv-collect.log") | Out-Null
}

function Restore-ProofCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$CheckpointName,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    Write-HvLog -Message ("Restoring checkpoint '{0}'." -f $CheckpointName) -LogPath $LogFile -Level STEP
    $checkpoint = Get-VMSnapshot -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue
    if (-not $checkpoint) {
        Fail-Hv -Message ("Checkpoint '{0}' was not found. Create or refresh the clean bench first." -f $CheckpointName) -LogPath $LogFile
    }

    try {
        $vmState = (Get-VM -Name $VmName -ErrorAction Stop).State
        if ($vmState -ne "Off") {
            Stop-VM -Name $VmName -TurnOff -Force -Confirm:$false | Out-Null
        }
    }
    catch {
        Write-HvLog -Message ("Pre-restore VM stop skipped: {0}" -f $_.Exception.Message) -LogPath $LogFile -Level WARN
    }

    Restore-VMSnapshot -VMName $VmName -Name $CheckpointName -Confirm:$false | Out-Null
}

function Get-GuestDriverResidue {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    return Invoke-HvGuestCommand -Session $Session -LogPath $LogFile -ScriptBlock {
        $driverEnum = pnputil /enum-drivers 2>&1 | Out-String
        $deviceEnum = pnputil /enum-devices /instanceid ROOT\AVSHWS\0000 2>&1 | Out-String

        [pscustomobject]@{
            DriverStoreHit = [bool](
                $driverEnum -match '(?im)^\s*Original Name:\s*avshws\.inf\s*$' -or
                $driverEnum -match '(?im)^\s*Provider Name:\s*VirtualCameraDriver\s*$'
            )
            DeviceHit = [bool]($deviceEnum -notmatch '(?i)no devices were found')
            DriverEnum = $driverEnum
            DeviceEnum = $deviceEnum
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
}

function Test-InstallNeedsReboot {
    param([string]$Output)

    return [bool]($Output -match '(?i)reboot is needed|reboot is required|pending system reboot|pending system reboot to complete a previous operation|a reboot is required to finalize installation')
}

function Test-InstallCreatedFreshDevice {
    param([string]$Output)

    return [bool]($Output -match '(?i)No ROOT\\\\AVSHWS device present\.\s+Creating it now')
}

function Get-GuestConsoleState {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    return Invoke-HvGuestCommand -Session $Session -LogPath $LogFile -ScriptBlock {
        $quserText = (cmd.exe /c quser 2>&1 | Out-String)
        $consoleLine = ($quserText -split "`r?`n" | Where-Object { $_ -match '\bconsole\b' } | Select-Object -First 1)
        $consoleUser = ""
        if ($consoleLine) {
            $parts = ($consoleLine -replace '^>', '').Trim() -split '\s+'
            if ($parts.Count -gt 0) {
                $consoleUser = $parts[0]
            }
        }

        [pscustomobject]@{
            HasConsoleSession = [bool]$consoleLine
            ConsoleUser = $consoleUser
            Quser = $quserText
            ExplorerCount = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
}

function Test-GuestConsoleReady {
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$ExpectedUser = ""
    )

    if ($null -eq $State) {
        return $false
    }
    if (-not $State.HasConsoleSession) {
        return $false
    }
    if ([int]$State.ExplorerCount -lt 1) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedUser) -and
        -not [string]::IsNullOrWhiteSpace([string]$State.ConsoleUser) -and
        ([string]$State.ConsoleUser) -ine $ExpectedUser) {
        return $false
    }

    return $true
}

function Wait-ForGuestInteractiveDesktop {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [string]$ExpectedUser = "",
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = $null
    do {
        $lastState = Get-GuestConsoleState -Session $Session -LogFile $LogFile
        if (Test-GuestConsoleReady -State $lastState -ExpectedUser $ExpectedUser) {
            return $lastState
        }

        Write-HvLog -Message ("Waiting for guest interactive desktop. console={0}; user={1}; explorer={2}" -f $lastState.HasConsoleSession, $lastState.ConsoleUser, $lastState.ExplorerCount) -LogPath $LogFile
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    return $lastState
}

function Enable-GuestAutoLogon {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [Parameter(Mandatory = $true)][string]$GuestUser,
        [Parameter(Mandatory = $true)][string]$GuestPasswordPlaintext
    )

    return Invoke-HvGuestCommand -Session $Session -LogPath $LogFile -ScriptBlock {
        param($UserName, $PasswordText)

        $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value "1"
        Set-ItemProperty -Path $winlogon -Name ForceAutoLogon -Value "1"
        Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $UserName
        Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value $PasswordText
        Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME

        [pscustomobject]@{
            AutoAdminLogon = (Get-ItemProperty -Path $winlogon).AutoAdminLogon
            DefaultUserName = (Get-ItemProperty -Path $winlogon).DefaultUserName
            DefaultDomainName = (Get-ItemProperty -Path $winlogon).DefaultDomainName
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    } -ArgumentList $GuestUser, $GuestPasswordPlaintext
}

function Get-FailureInfo {
    param(
        [string]$ProofResultPath,
        [string]$StatusPath,
        [string]$VmName,
        [string]$FallbackMessage
    )

    $proof = Read-JsonFile -Path $ProofResultPath
    $proofErrorClassProp = $null
    $proofErrorMessageProp = $null
    if ($proof) {
        $proofErrorClassProp = $proof.PSObject.Properties["errorClass"]
        $proofErrorMessageProp = $proof.PSObject.Properties["errorMessage"]
    }
    if ($proofErrorClassProp -and $proofErrorClassProp.Value) {
        return [pscustomobject]@{
            ErrorClass = [string]$proofErrorClassProp.Value
            ErrorSignature = [string]$proofErrorClassProp.Value
            Message = if ($proofErrorMessageProp -and $proofErrorMessageProp.Value) { [string]$proofErrorMessageProp.Value } else { [string]$proofErrorClassProp.Value }
        }
    }

    $status = Read-JsonFile -Path $StatusPath
    $guestSessionAliveProp = $null
    $guestLivenessErrorProp = $null
    if ($status) {
        $guestSessionAliveProp = $status.PSObject.Properties["GuestSessionAlive"]
        $guestLivenessErrorProp = $status.PSObject.Properties["GuestLivenessError"]
    }
    if ($guestSessionAliveProp -and $guestSessionAliveProp.Value -eq $false) {
        return [pscustomobject]@{
            ErrorClass = "vm.BSOD"
            ErrorSignature = "vm.BSOD"
            Message = if ($guestLivenessErrorProp -and $guestLivenessErrorProp.Value) { [string]$guestLivenessErrorProp.Value } else { "Guest session ended unexpectedly." }
        }
    }

    $vmState = (Get-VM -Name $VmName -ErrorAction SilentlyContinue).State
    if ($vmState -and $vmState.ToString() -ne "Running") {
        return [pscustomobject]@{
            ErrorClass = "vm.BSOD"
            ErrorSignature = "vm.BSOD"
            Message = "VM state changed from Running: $vmState"
        }
    }

    return [pscustomobject]@{
        ErrorClass = "proof.Unknown"
        ErrorSignature = "proof.Unknown"
        Message = $FallbackMessage
    }
}

$repoRoot = Get-HvRepoRoot
$artifactDir = Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-proof-chrome.log"
}

$sessionStatusPath = Join-Path $artifactDir "vm-session-status.json"
$stopSignalPath = Join-Path $artifactDir "vm-session-stop.signal"
$holdLogPath = Join-Path $artifactDir "vm-session-host.log"
$playwrightLogPath = Join-Path $artifactDir "playwright-vm-webcam-proof.log"
$attemptStatePath = Join-Path $artifactDir "attempt-state.json"
$proofResultPath = Join-Path $artifactDir "vm-webcam-proof.json"
$preinstallCleanPath = Join-Path $artifactDir "guest-preinstall-clean.json"
$consoleStatePath = Join-Path $artifactDir "guest-console-state.json"
$priorAttemptState = Read-JsonFile -Path $attemptStatePath
$nextAttemptId = if ($priorAttemptState) { [int]$priorAttemptState.attempt + 1 } else { 1 }

$driverPackageRootPath = Resolve-HvPath -Path $DriverPackageRoot -BasePath $repoRoot
$installDriverScript = Resolve-HvPath -Path "driver-project\Driver\avshws\install-driver.ps1" -BasePath $repoRoot
$webcamHtml = Resolve-HvPath -Path "software-project\webcam.html" -BasePath $repoRoot
$holdScript = Resolve-HvPath -Path "scripts\hyperv-hold-webcam-session.ps1" -BasePath $repoRoot
$proofScript = Resolve-HvPath -Path "scripts\playwright-vm-webcam-proof.ps1" -BasePath $repoRoot
$guestRoot = "C:\Temp\VirtuaCamHyperV\proof-$nextAttemptId"
$guestPackageRoot = Join-Path $guestRoot (Split-Path -Path $driverPackageRootPath -Leaf)
$guestScriptsRoot = Join-Path $guestRoot "scripts"
$guestInstallDriver = Join-Path $guestScriptsRoot "install-driver.ps1"
$guestWebcamHtml = Join-Path $guestRoot "webcam.html"
$session = $null
$holdProc = $null
$runSucceeded = $false
$attemptChange = "browser=$Browser; verifier=$([bool]$EnableVerifier); source=Notepad; checkpoint=$CheckpointName; args=hold-defaults --force-directshow $($BrowserExtraArgs -join ' ')"
$guestCred = Get-HvGuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext

Write-HvLog -Message ("Hyper-V proof harness start for '{0}'" -f $VmName) -LogPath $LogPath -Level STEP
Write-HvLog -Message ("ArtifactDir: {0}" -f $artifactDir) -LogPath $LogPath
Write-HvLog -Message ("DriverPackageRoot: {0}" -f $driverPackageRootPath) -LogPath $LogPath
Write-HvLog -Message ("CheckpointName: {0}" -f $CheckpointName) -LogPath $LogPath
Write-HvLog -Message ("RevertAfterRun: {0}" -f $RevertAfterRun) -LogPath $LogPath
Remove-Item -LiteralPath $sessionStatusPath, $stopSignalPath, $proofResultPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $driverPackageRootPath)) {
    Fail-Hv -Message "Driver package root not found: $driverPackageRootPath" -LogPath $LogPath
}
if (-not (Test-Path -LiteralPath (Join-Path $driverPackageRootPath "avshws.inf"))) {
    Fail-Hv -Message "Missing avshws.inf in package root: $driverPackageRootPath" -LogPath $LogPath
}
if (-not (Test-Path -LiteralPath $webcamHtml)) {
    Fail-Hv -Message "Missing webcam.html: $webcamHtml" -LogPath $LogPath
}

try {
    Restore-ProofCheckpoint -VmName $VmName -CheckpointName $CheckpointName -LogFile $LogPath

    Write-HvLog -Message "Guest preflight checks." -LogPath $LogPath -Level STEP
    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
    $cleanState = Get-GuestDriverResidue -Session $session -LogFile $LogPath
    Write-JsonFile -Path $preinstallCleanPath -Data $cleanState
    if ($cleanState.DriverStoreHit -or $cleanState.DeviceHit) {
        throw "driver.CleanCheckpointDirty"
    }

    $consoleStateRecord = [ordered]@{
        Initial = $null
        AutoLogonConfigured = $false
        AutoLogon = $null
        Final = $null
    }
    $consoleStateRecord.Initial = Wait-ForGuestInteractiveDesktop -Session $session -LogFile $LogPath -ExpectedUser $GuestUser -TimeoutSeconds 30 -PollSeconds 5
    $consoleStateRecord.Final = $consoleStateRecord.Initial

    if (-not (Test-GuestConsoleReady -State $consoleStateRecord.Initial -ExpectedUser $GuestUser)) {
        if ([string]::IsNullOrWhiteSpace($GuestPasswordPlaintext)) {
            throw "guest.NoInteractiveDesktop"
        }

        Write-HvLog -Message ("Guest has no ready desktop after clean restore. Enabling autologon for {0}." -f $GuestUser) -LogPath $LogPath -Level STEP
        $consoleStateRecord.AutoLogonConfigured = $true
        $consoleStateRecord.AutoLogon = Enable-GuestAutoLogon -Session $session -LogFile $LogPath -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
        Restart-HvGuest -Session $session -LogPath $LogPath
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -LogPath $LogPath
        $consoleStateRecord.Final = Wait-ForGuestInteractiveDesktop -Session $session -LogFile $LogPath -ExpectedUser $GuestUser -TimeoutSeconds 120 -PollSeconds 5
    }

    Write-JsonFile -Path $consoleStatePath -Data ([pscustomobject]$consoleStateRecord)
    if (-not (Test-GuestConsoleReady -State $consoleStateRecord.Final -ExpectedUser $GuestUser)) {
        throw "guest.NoInteractiveDesktop"
    }

    $baseline = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($BrowserName)

        $bcd = & "$env:WINDIR\System32\bcdedit.exe" /enum "{current}" 2>&1 | Out-String
        $testSigningOn = $bcd -match '(?im)^\s*testsigning\s+Yes\b'
        if (-not $testSigningOn) {
            throw "TESTSIGNING is OFF inside guest."
        }

        $chrome = Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"
        $edge = Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"
        $browserExe = if ($BrowserName -eq "Chrome") { $chrome } else { $edge }
        if (-not (Test-Path -LiteralPath $browserExe)) {
            throw "Browser not found in guest: $browserExe"
        }

        $machinePrivacyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
        $userPrivacyPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
        $machineValue = if (Test-Path -LiteralPath $machinePrivacyPath) { (Get-ItemProperty -LiteralPath $machinePrivacyPath -ErrorAction SilentlyContinue).Value } else { "" }
        $userValue = if (Test-Path -LiteralPath $userPrivacyPath) { (Get-ItemProperty -LiteralPath $userPrivacyPath -ErrorAction SilentlyContinue).Value } else { "" }
        if ($machineValue -eq "Deny" -or $userValue -eq "Deny") {
            throw "Webcam privacy is Deny in guest."
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            TestSigning = $true
            Browser = $BrowserName
            BrowserExe = $browserExe
            MachineWebcamConsent = $machineValue
            UserWebcamConsent = $userValue
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    } -ArgumentList $Browser
    Write-JsonFile -Path (Join-Path $artifactDir "guest-baseline.json") -Data $baseline

    Write-HvLog -Message "Preparing guest staging folders." -LogPath $LogPath -Level STEP
    Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($Root, $ScriptsRoot)
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Force -Path $Root, $ScriptsRoot
    } -ArgumentList $guestRoot, $guestScriptsRoot | Out-Null

    Copy-HvToGuest -Session $session -LocalPath $driverPackageRootPath -GuestPath $guestRoot -Recurse -LogPath $LogPath
    Copy-HvToGuest -Session $session -LocalPath $installDriverScript -GuestPath $guestScriptsRoot -LogPath $LogPath
    Copy-HvToGuest -Session $session -LocalPath $webcamHtml -GuestPath $guestRoot -LogPath $LogPath

    Write-HvLog -Message "Importing driver signing certificate into guest trust stores." -LogPath $LogPath -Level STEP
    Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($CertPath)

        if (-not (Test-Path -LiteralPath $CertPath)) {
            throw "Guest cert file missing: $CertPath"
        }

        $certBytes = [System.IO.File]::ReadAllBytes($CertPath)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
        foreach ($storeName in @("Root", "TrustedPublisher")) {
            $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($storeName, "LocalMachine")
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            try {
                $existing = $store.Certificates.Find(
                    [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
                    $cert.Thumbprint,
                    $false)
                if ($existing.Count -eq 0) {
                    $store.Add($cert)
                }
            }
            finally {
                $store.Close()
            }
        }
    } -ArgumentList (Join-Path $guestPackageRoot "VirtualCameraDriver-TestSign.cer") | Out-Null

    Write-HvLog -Message "Installing driver inside guest." -LogPath $LogPath -Level STEP
    $installResult = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($InstallScript, $PackageRoot)
        $logFile = Join-Path $PackageRoot "logs\driver-install.log"
        $output = & powershell.exe -ExecutionPolicy Bypass -File $InstallScript -PackageRoot $PackageRoot -SkipCertificateImport -LogPath $logFile 2>&1 | Out-String
        [pscustomobject]@{
            Output = $output
            ExitCode = $LASTEXITCODE
        }
    } -ArgumentList $guestInstallDriver, $guestPackageRoot
    Set-Content -LiteralPath (Join-Path $artifactDir "guest-driver-install.txt") -Value $installResult.Output
    if ($installResult.ExitCode -ne 0) {
        throw "driver.InstallFailed"
    }
    if ($installResult.Output -match '(?i)already exists in the system|ROOT\\\\AVSHWS already exists') {
        throw "driver.InstallDirtyState"
    }

    $installNeedsReboot = Test-InstallNeedsReboot -Output $installResult.Output
    $installCreatedFreshDevice = Test-InstallCreatedFreshDevice -Output $installResult.Output
    if ($installNeedsReboot -or $installCreatedFreshDevice) {
        $rebootReason = if ($installNeedsReboot -and $installCreatedFreshDevice) {
            "Driver install requested reboot and created fresh ROOT\\AVSHWS device"
        }
        elseif ($installNeedsReboot) {
            "Driver install requested reboot"
        }
        else {
            "Driver install created fresh ROOT\\AVSHWS device"
        }

        Write-HvLog -Message ("{0}; restarting guest before proof." -f $rebootReason) -LogPath $LogPath -Level STEP
        Restart-HvGuest -Session $session -LogPath $LogPath
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -LogPath $LogPath
        $postInstallConsoleState = Wait-ForGuestInteractiveDesktop -Session $session -LogFile $LogPath -ExpectedUser $GuestUser -TimeoutSeconds 120 -PollSeconds 5
        if (-not (Test-GuestConsoleReady -State $postInstallConsoleState -ExpectedUser $GuestUser)) {
            throw "guest.NoInteractiveDesktop"
        }
    }

    if ($EnableVerifier) {
        Write-HvLog -Message "Enabling Driver Verifier for avshws.sys." -LogPath $LogPath -Level STEP
        $verifierOutput = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            verifier /reset 2>&1 | Out-Null
            verifier /standard /driver avshws.sys 2>&1 | Out-String
        }
        Set-Content -LiteralPath (Join-Path $artifactDir "verifier-enable.txt") -Value $verifierOutput
        Restart-HvGuest -Session $session -LogPath $LogPath
        $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds 240 -LogPath $LogPath
    }

    Remove-Item -LiteralPath $sessionStatusPath, $stopSignalPath, $proofResultPath -Force -ErrorAction SilentlyContinue

    $holdArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $holdScript,
        "-VmName", $VmName,
        "-GuestUser", $GuestUser,
        "-GuestPasswordPlaintext", $GuestPasswordPlaintext,
        "-GuestPackageRoot", $guestPackageRoot,
        "-GuestWebcamHtml", $guestWebcamHtml,
        "-Browser", $Browser,
        "-SourceWindowMode", "Notepad",
        "-AttemptId", "$nextAttemptId",
        "-ServeHttp",
        "-HttpPort", "8000",
        "-HostStatusPath", $sessionStatusPath,
        "-HostStopSignalPath", $stopSignalPath,
        "-LogPath", $holdLogPath
    )
    if ($BrowserExtraArgs.Count -gt 0) {
        $holdArgs += "-BrowserExtraArgs"
        $holdArgs += $BrowserExtraArgs
    }

    Write-HvLog -Message "Launching held guest webcam session." -LogPath $LogPath -Level STEP
    $holdProc = Start-Process -FilePath "powershell.exe" -ArgumentList $holdArgs -PassThru -WindowStyle Hidden

    $status = $null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $sessionStatusPath) {
            $status = Read-JsonFile -Path $sessionStatusPath
            if ($status -and $status.Ready) {
                break
            }
        }

        if ($holdProc.HasExited) {
            throw "Guest hold session exited before ready signal."
        }

        Start-Sleep -Seconds 2
    }

    if (-not $status -or -not $status.Ready) {
        throw "Timed out waiting for held guest session status."
    }

    if ($status.BrowserCommandLine) {
        Set-Content -LiteralPath (Join-Path $artifactDir "browser-commandline.txt") -Value $status.BrowserCommandLine
        Write-HvLog -Message ("Guest browser command line: {0}" -f $status.BrowserCommandLine) -LogPath $LogPath
    }
    if ($status.SourceWindowTitle) {
        Write-HvLog -Message ("Proof source window: mode={0} title={1}" -f $status.SourceWindowMode, $status.SourceWindowTitle) -LogPath $LogPath
    }

    Write-HvLog -Message "Running Playwright proof capture." -LogPath $LogPath -Level STEP
    $proof = & $proofScript -StatusPath $sessionStatusPath -ArtifactRoot $artifactDir -LogPath $playwrightLogPath

    $attemptState = Update-AttemptState -StatePath $attemptStatePath -Success:$true -LastChange $attemptChange
    $runSucceeded = $true
    Write-HvLog -Message ("Proof success. Screenshot: {0}" -f (Join-Path $artifactDir "vm-webcam-proof.png")) -LogPath $LogPath -Level STEP
    $proof
}
catch {
    $fallbackMessage = $_.Exception.Message
    $failureInfo = switch ($fallbackMessage) {
        "driver.CleanCheckpointDirty" {
            [pscustomobject]@{ ErrorClass = "driver.CleanCheckpointDirty"; ErrorSignature = "driver.CleanCheckpointDirty"; Message = "Restored checkpoint is not clean. avshws is still present before install." }
        }
        "driver.InstallFailed" {
            [pscustomobject]@{ ErrorClass = "driver.InstallFailed"; ErrorSignature = "driver.InstallFailed"; Message = "Guest driver install failed." }
        }
        "driver.InstallDirtyState" {
            [pscustomobject]@{ ErrorClass = "driver.InstallDirtyState"; ErrorSignature = "driver.InstallDirtyState"; Message = "Guest driver install reused existing avshws state after clean restore." }
        }
        "guest.NoInteractiveDesktop" {
            [pscustomobject]@{ ErrorClass = "guest.NoInteractiveDesktop"; ErrorSignature = "guest.NoInteractiveDesktop"; Message = "Guest never reached interactive desktop for real-window proof." }
        }
        default {
            Get-FailureInfo -ProofResultPath $proofResultPath -StatusPath $sessionStatusPath -VmName $VmName -FallbackMessage $fallbackMessage
        }
    }

    $attemptState = Update-AttemptState -StatePath $attemptStatePath -Success:$false -ErrorClass $failureInfo.ErrorClass -ErrorSignature $failureInfo.ErrorSignature -LastChange $attemptChange
    Write-HvLog -Message ("Proof failed: {0}" -f $failureInfo.Message) -LogPath $LogPath -Level ERROR
    if ($attemptState.researched) {
        Write-HvLog -Message ("Repeat failure reached research gate. Note: {0}" -f $attemptState.research_note) -LogPath $LogPath -Level WARN
    }

    try {
        Invoke-CollectArtifacts -VmName $VmName -Credential $guestCred -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext -GuestPackageRoot $guestPackageRoot -ArtifactDirectory $artifactDir -LogFile $LogPath
    }
    catch {
        Write-HvLog -Message ("Artifact collection failed: {0}" -f $_.Exception.Message) -LogPath $LogPath -Level WARN
    }

    throw
}
finally {
    if (-not (Test-Path -LiteralPath $stopSignalPath)) {
        New-Item -ItemType File -Force -Path $stopSignalPath | Out-Null
    }

    if ($holdProc) {
        try {
            Wait-Process -Id $holdProc.Id -Timeout 20 -ErrorAction SilentlyContinue
        }
        catch {
        }
        if (-not $holdProc.HasExited) {
            Stop-Process -Id $holdProc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }

    if ($RevertAfterRun) {
        try {
            Restore-ProofCheckpoint -VmName $VmName -CheckpointName $CheckpointName -LogFile $LogPath
        }
        catch {
            if ($runSucceeded) {
                throw
            }

            Write-HvLog -Message ("Post-run checkpoint restore failed: {0}" -f $_.Exception.Message) -LogPath $LogPath -Level WARN
        }
    }
}
