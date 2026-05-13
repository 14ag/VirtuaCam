Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-HvScriptRoot {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }

    return Split-Path -Parent $MyInvocation.MyCommand.Definition
}

function Get-HvRepoRoot {
    return [System.IO.Path]::GetFullPath((Join-Path (Get-HvScriptRoot) ".."))
}

function Resolve-HvPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BasePath = (Get-HvRepoRoot)
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-HvTimestamp {
    return Get-Date -Format "yyyyMMdd-HHmmss"
}

function Write-HvLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$LogPath = "",
        [ValidateSet("INFO", "WARN", "ERROR", "STEP")][string]$Level = "INFO"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff zzz"
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "STEP"  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $dir = Split-Path -Parent $LogPath
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            $null = New-Item -ItemType Directory -Force -Path $dir
        }
        Add-Content -LiteralPath $LogPath -Value $line
    }
}

function Fail-Hv {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$LogPath = ""
    )

    Write-HvLog -Message $Message -LogPath $LogPath -Level ERROR
    throw $Message
}

function Assert-HvAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script in elevated PowerShell (Run as Administrator)."
    }
}

function Get-HvArtifactDirectory {
    param(
        [string]$ArtifactRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
        $ArtifactRoot = Resolve-HvPath -Path "test-reports\hyperv-runs"
    } else {
        $ArtifactRoot = Resolve-HvPath -Path $ArtifactRoot
    }

    $runDir = Join-Path $ArtifactRoot (Get-HvTimestamp)
    $null = New-Item -ItemType Directory -Force -Path $runDir
    return $runDir
}

function Read-HvDotEnv {
    param(
        [string]$Path = (Resolve-HvPath -Path ".env")
    )

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }

        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $values[$name] = $value
        }
    }

    return $values
}

function Get-HvGuestCredential {
    param(
        [System.Management.Automation.PSCredential]$GuestCredential,
        [string]$GuestUser = "Administrator",
        [string]$GuestPasswordPlaintext = "",
        [string]$EnvUserKey = "",
        [string]$EnvPasswordKey = ""
    )

    if ($GuestCredential) {
        return $GuestCredential
    }

    if ([string]::IsNullOrWhiteSpace($GuestPasswordPlaintext) -and -not [string]::IsNullOrWhiteSpace($EnvPasswordKey)) {
        $envValues = Read-HvDotEnv
        if ($envValues.ContainsKey($EnvUserKey) -and -not [string]::IsNullOrWhiteSpace([string]$envValues[$EnvUserKey]) -and $GuestUser -eq "Administrator") {
            $GuestUser = [string]$envValues[$EnvUserKey]
        }
        if ($envValues.ContainsKey($EnvPasswordKey) -and -not [string]::IsNullOrWhiteSpace([string]$envValues[$EnvPasswordKey])) {
            $GuestPasswordPlaintext = [string]$envValues[$EnvPasswordKey]
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($GuestPasswordPlaintext)) {
        $secure = ConvertTo-SecureString $GuestPasswordPlaintext -AsPlainText -Force
        return [System.Management.Automation.PSCredential]::new($GuestUser, $secure)
    }

    return Get-Credential -UserName $GuestUser -Message "Enter Hyper-V guest credential"
}

function Get-HvRecoveryMessage {
    param([string]$VmName)

    return @"
PowerShell Direct recovery for '$VmName':
1. Open VM console: vmconnect.exe localhost $VmName
2. Log in inside guest.
3. In elevated PowerShell inside guest: Restart-Service vmicvmsession
4. Retry Hyper-V harness.
"@
}

function Ensure-HvVmRunning {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [int]$TimeoutSeconds = 120,
        [string]$LogPath = ""
    )

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.State -eq "Running") {
        return
    }

    Write-HvLog -Message ("VM '{0}' is {1}. Starting it." -f $VmName, $vm.State) -LogPath $LogPath -Level WARN
    Start-VM -Name $VmName | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ($vm.State -eq "Running") {
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for VM '$VmName' to enter Running state."
}

function Stop-HvVmForRestore {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [int]$TimeoutSeconds = 180,
        [string]$LogPath = ""
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stopRequested = $false
    do {
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ([string]$vm.State -eq "Off") {
            return
        }

        if (-not $stopRequested -and [string]$vm.State -ne "Stopping") {
            Write-HvLog -Message ("Stopping VM '{0}' from state {1} before checkpoint restore." -f $VmName, $vm.State) -LogPath $LogPath -Level WARN
            Stop-VM -Name $VmName -TurnOff -Force -Confirm:$false | Out-Null
            $stopRequested = $true
        }

        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for VM '$VmName' to stop before checkpoint restore."
}

function Restore-HvCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$CheckpointName,
        [string]$LogPath = ""
    )

    $checkpoint = Get-VMSnapshot -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue
    if (-not $checkpoint) {
        Fail-Hv -Message ("Checkpoint '{0}' was not found for VM '{1}'." -f $CheckpointName, $VmName) -LogPath $LogPath
    }

    Write-HvLog -Message ("Restoring checkpoint '{0}' on VM '{1}'." -f $CheckpointName, $VmName) -LogPath $LogPath
    Restore-VMSnapshot -VMName $VmName -Name $CheckpointName -Confirm:$false | Out-Null
}

function Test-HvVmConnectionStateAtLeast {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$MinimumState
    )

    $rank = @{
        NotFound = 0
        Off = 1
        Saved = 1
        Paused = 1
        Stopping = 2
        Booting = 3
        WindowsLoading = 4
        AwaitingLogin = 5
        LoggingIn = 6
        LoggedIn = 7
        ReadyToConnect = 8
        Unknown = 0
    }

    if (-not $rank.ContainsKey($State)) {
        return $false
    }
    if (-not $rank.ContainsKey($MinimumState)) {
        return $false
    }

    return [int]$rank[$State] -ge [int]$rank[$MinimumState]
}

function Get-HvVmConnectionState {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$ReadyThresholdSeconds = 30
    )

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        return [pscustomobject]@{
            State = "NotFound"
            Detail = "No VM named '$VmName' found on this host."
            LogonUIRunning = $false
            UserinitRunning = $false
            ExplorerRunning = $false
            ExplorerAgeSeconds = $null
            PowerShellDirectReady = $false
            LastError = ""
        }
    }

    switch ([string]$vm.State) {
        "Off" { return [pscustomobject]@{ State = "Off"; Detail = "VM is powered off."; LogonUIRunning = $false; UserinitRunning = $false; ExplorerRunning = $false; ExplorerAgeSeconds = $null; PowerShellDirectReady = $false; LastError = "" } }
        "Saved" { return [pscustomobject]@{ State = "Saved"; Detail = "VM state is saved to disk."; LogonUIRunning = $false; UserinitRunning = $false; ExplorerRunning = $false; ExplorerAgeSeconds = $null; PowerShellDirectReady = $false; LastError = "" } }
        "Paused" { return [pscustomobject]@{ State = "Paused"; Detail = "VM is paused."; LogonUIRunning = $false; UserinitRunning = $false; ExplorerRunning = $false; ExplorerAgeSeconds = $null; PowerShellDirectReady = $false; LastError = "" } }
        "Stopping" { return [pscustomobject]@{ State = "Stopping"; Detail = "VM is stopping; wait before start/connect."; LogonUIRunning = $false; UserinitRunning = $false; ExplorerRunning = $false; ExplorerAgeSeconds = $null; PowerShellDirectReady = $false; LastError = "" } }
        "Starting" { return [pscustomobject]@{ State = "Booting"; Detail = "VM is starting at hypervisor level."; LogonUIRunning = $false; UserinitRunning = $false; ExplorerRunning = $false; ExplorerAgeSeconds = $null; PowerShellDirectReady = $false; LastError = "" } }
    }

    if ([string]$vm.State -ne "Running") {
        return [pscustomobject]@{
            State = "Booting"
            Detail = "VM state is '$($vm.State)'."
            LogonUIRunning = $false
            UserinitRunning = $false
            ExplorerRunning = $false
            ExplorerAgeSeconds = $null
            PowerShellDirectReady = $false
            LastError = ""
        }
    }

    $heartbeat = $vm | Get-VMIntegrationService -Name "Heartbeat" -ErrorAction SilentlyContinue
    $heartbeatOK = $heartbeat -and ([string]$heartbeat.PrimaryStatusDescription -eq "OK")
    if (-not $heartbeatOK) {
        $heartbeatText = if ($heartbeat) { [string]$heartbeat.PrimaryStatusDescription } else { "Missing" }
        return [pscustomobject]@{
            State = "Booting"
            Detail = "VM is running but heartbeat is '$heartbeatText'."
            LogonUIRunning = $false
            UserinitRunning = $false
            ExplorerRunning = $false
            ExplorerAgeSeconds = $null
            PowerShellDirectReady = $false
            LastError = ""
        }
    }

    if (-not $Credential) {
        return [pscustomobject]@{
            State = "WindowsLoading"
            Detail = "Heartbeat OK; credential not provided for PowerShell Direct state probe."
            LogonUIRunning = $false
            UserinitRunning = $false
            ExplorerRunning = $false
            ExplorerAgeSeconds = $null
            PowerShellDirectReady = $false
            LastError = ""
        }
    }

    $probe = $null
    try {
        $probe = Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
            $logonUI = Get-Process -Name "LogonUI" -ErrorAction SilentlyContinue
            $userinit = Get-Process -Name "userinit" -ErrorAction SilentlyContinue
            $explorer = Get-Process -Name "explorer" -ErrorAction SilentlyContinue

            $explorerAgeSeconds = $null
            if ($explorer) {
                $oldest = $explorer | Sort-Object StartTime | Select-Object -First 1
                $explorerAgeSeconds = [int]((Get-Date) - $oldest.StartTime).TotalSeconds
            }

            $svc = Get-Service -Name "vmicvmsession" -ErrorAction SilentlyContinue
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                VmicVmSessionStatus = if ($svc) { [string]$svc.Status } else { "Missing" }
                LogonUIRunning = [bool]$logonUI
                UserinitRunning = [bool]$userinit
                ExplorerRunning = [bool]$explorer
                ExplorerAgeSeconds = $explorerAgeSeconds
            }
        }
    }
    catch {
        return [pscustomobject]@{
            State = "WindowsLoading"
            Detail = "Heartbeat OK but PowerShell Direct refused: $($_.Exception.Message)"
            LogonUIRunning = $false
            UserinitRunning = $false
            ExplorerRunning = $false
            ExplorerAgeSeconds = $null
            PowerShellDirectReady = $false
            LastError = $_.Exception.Message
        }
    }

    if ($probe.LogonUIRunning -and -not $probe.ExplorerRunning) {
        return [pscustomobject]@{
            State = "AwaitingLogin"
            Detail = "LogonUI.exe is running; login screen is displayed."
            LogonUIRunning = $true
            UserinitRunning = [bool]$probe.UserinitRunning
            ExplorerRunning = $false
            ExplorerAgeSeconds = $null
            PowerShellDirectReady = $true
            LastError = ""
            GuestComputerName = [string]$probe.ComputerName
            VmicVmSessionStatus = [string]$probe.VmicVmSessionStatus
        }
    }

    if (-not $probe.LogonUIRunning -and -not $probe.ExplorerRunning) {
        if ($probe.UserinitRunning) {
            return [pscustomobject]@{
                State = "LoggingIn"
                Detail = "userinit.exe is active; user profile is loading."
                LogonUIRunning = $false
                UserinitRunning = $true
                ExplorerRunning = $false
                ExplorerAgeSeconds = $null
                PowerShellDirectReady = $true
                LastError = ""
                GuestComputerName = [string]$probe.ComputerName
                VmicVmSessionStatus = [string]$probe.VmicVmSessionStatus
            }
        }

        return [pscustomobject]@{
            State = "WindowsLoading"
            Detail = "PowerShell Direct connected but explorer.exe has not started."
            LogonUIRunning = $false
            UserinitRunning = $false
            ExplorerRunning = $false
            ExplorerAgeSeconds = $null
            PowerShellDirectReady = $true
            LastError = ""
            GuestComputerName = [string]$probe.ComputerName
            VmicVmSessionStatus = [string]$probe.VmicVmSessionStatus
        }
    }

    if ($probe.ExplorerRunning) {
        $age = $probe.ExplorerAgeSeconds
        if ($null -ne $age -and [int]$age -ge $ReadyThresholdSeconds) {
            return [pscustomobject]@{
                State = "ReadyToConnect"
                Detail = "explorer.exe has been running for ${age}s; session is settled."
                LogonUIRunning = [bool]$probe.LogonUIRunning
                UserinitRunning = [bool]$probe.UserinitRunning
                ExplorerRunning = $true
                ExplorerAgeSeconds = $age
                PowerShellDirectReady = $true
                LastError = ""
                GuestComputerName = [string]$probe.ComputerName
                VmicVmSessionStatus = [string]$probe.VmicVmSessionStatus
            }
        }

        return [pscustomobject]@{
            State = "LoggedIn"
            Detail = "explorer.exe started ${age}s ago; session still settling."
            LogonUIRunning = [bool]$probe.LogonUIRunning
            UserinitRunning = [bool]$probe.UserinitRunning
            ExplorerRunning = $true
            ExplorerAgeSeconds = $age
            PowerShellDirectReady = $true
            LastError = ""
            GuestComputerName = [string]$probe.ComputerName
            VmicVmSessionStatus = [string]$probe.VmicVmSessionStatus
        }
    }

    return [pscustomobject]@{
        State = "Unknown"
        Detail = "Could not determine state from process snapshot."
        LogonUIRunning = [bool]$probe.LogonUIRunning
        UserinitRunning = [bool]$probe.UserinitRunning
        ExplorerRunning = [bool]$probe.ExplorerRunning
        ExplorerAgeSeconds = $probe.ExplorerAgeSeconds
        PowerShellDirectReady = $true
        LastError = ""
        GuestComputerName = [string]$probe.ComputerName
        VmicVmSessionStatus = [string]$probe.VmicVmSessionStatus
    }
}

function Get-HvVmReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$CheckPowerShellDirect,
        [int]$ReadyThresholdSeconds = 30
    )

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $integration = @(Get-VMIntegrationService -VMName $VmName -ErrorAction SilentlyContinue)
    $heartbeat = @($integration | Where-Object { [string]$_.Name -eq "Heartbeat" } | Select-Object -First 1)
    $psDirect = @($integration | Where-Object { [string]$_.Name -like "*PowerShell Direct*" } | Select-Object -First 1)
    $connection = Get-HvVmConnectionState -VmName $VmName -Credential $Credential -ReadyThresholdSeconds $ReadyThresholdSeconds
    $psReady = [bool]$connection.PowerShellDirectReady
    $guestComputerName = if ($connection.PSObject.Properties.Name -contains "GuestComputerName") { [string]$connection.GuestComputerName } else { "" }
    $vmicStatus = if ($connection.PSObject.Properties.Name -contains "VmicVmSessionStatus") { [string]$connection.VmicVmSessionStatus } else { "" }
    $lastError = [string]$connection.LastError

    [pscustomobject]@{
        VmName = $VmName
        State = [string]$vm.State
        Status = [string]$vm.Status
        Uptime = [string]$vm.Uptime
        Heartbeat = if ($heartbeat.Count -gt 0) { [string]$heartbeat[0].PrimaryStatusDescription } else { "" }
        HeartbeatSecondary = if ($heartbeat.Count -gt 0) { [string]::Join(",", @($heartbeat[0].SecondaryOperationalStatus)) } else { "" }
        PowerShellDirect = if ($psDirect.Count -gt 0) { [string]$psDirect[0].PrimaryStatusDescription } else { "" }
        PowerShellDirectSecondary = if ($psDirect.Count -gt 0) { [string]::Join(",", @($psDirect[0].SecondaryOperationalStatus)) } else { "" }
        PowerShellDirectReady = $psReady
        GuestComputerName = $guestComputerName
        VmicVmSessionStatus = $vmicStatus
        ConnectionState = [string]$connection.State
        ConnectionDetail = [string]$connection.Detail
        LogonUIRunning = [bool]$connection.LogonUIRunning
        UserinitRunning = [bool]$connection.UserinitRunning
        ExplorerRunning = [bool]$connection.ExplorerRunning
        ExplorerAgeSeconds = $connection.ExplorerAgeSeconds
        LastError = $lastError
        CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
}

function Wait-HvVmReady {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSeconds = 180,
        [int]$PollIntervalSeconds = 3,
        [switch]$RequirePowerShellDirect,
        [switch]$RequireInteractiveSession,
        [ValidateSet("", "Booting", "WindowsLoading", "AwaitingLogin", "LoggingIn", "LoggedIn", "ReadyToConnect")]
        [string]$UntilConnectionState = "",
        [int]$ReadyThresholdSeconds = 30,
        [string]$LogPath = ""
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSignature = ""
    $lastReady = $null

    if ($RequireInteractiveSession -and [string]::IsNullOrWhiteSpace($UntilConnectionState)) {
        $UntilConnectionState = "ReadyToConnect"
        $RequirePowerShellDirect = $true
    }

    do {
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ([string]$vm.State -eq "Off" -or [string]$vm.State -eq "Saved") {
            Write-HvLog -Message ("VM '{0}' is {1}. Starting it." -f $VmName, $vm.State) -LogPath $LogPath -Level WARN
            Start-VM -Name $VmName | Out-Null
        } elseif ([string]$vm.State -eq "Paused") {
            Write-HvLog -Message ("VM '{0}' is Paused. Resuming it." -f $VmName) -LogPath $LogPath -Level WARN
            Resume-VM -Name $VmName | Out-Null
        }

        $ready = Get-HvVmReadiness -VmName $VmName -Credential $Credential -CheckPowerShellDirect:$RequirePowerShellDirect -ReadyThresholdSeconds $ReadyThresholdSeconds
        $lastReady = $ready
        $signature = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f $ready.State, $ready.Status, $ready.Heartbeat, $ready.PowerShellDirectReady, $ready.ConnectionState, $ready.VmicVmSessionStatus, $ready.ExplorerAgeSeconds
        if ($signature -ne $lastSignature) {
            Write-HvLog -Message ("VM readiness {0}: state={1}; status={2}; heartbeat={3}; psdirect={4}; connection={5}; detail={6}; vmicvmsession={7}; logonui={8}; userinit={9}; explorer={10}; explorerAge={11}" -f $VmName, $ready.State, $ready.Status, $ready.Heartbeat, $ready.PowerShellDirectReady, $ready.ConnectionState, $ready.ConnectionDetail, $ready.VmicVmSessionStatus, $ready.LogonUIRunning, $ready.UserinitRunning, $ready.ExplorerRunning, $ready.ExplorerAgeSeconds) -LogPath $LogPath
            if (-not [string]::IsNullOrWhiteSpace($ready.LastError)) {
                Write-HvLog -Message ("VM readiness probe error {0}: {1}" -f $VmName, $ready.LastError) -LogPath $LogPath -Level WARN
            }
            $lastSignature = $signature
        }

        $stateReady = [string]$ready.State -eq "Running"
        $connectionReady = [string]::IsNullOrWhiteSpace($UntilConnectionState) -or (Test-HvVmConnectionStateAtLeast -State ([string]$ready.ConnectionState) -MinimumState $UntilConnectionState)
        if ($stateReady -and $connectionReady -and (-not $RequirePowerShellDirect -or $ready.PowerShellDirectReady)) {
            return $ready
        }

        Start-Sleep -Seconds ([Math]::Max(1, $PollIntervalSeconds))
    } while ((Get-Date) -lt $deadline)

    $msg = "Timed out waiting for VM '$VmName' readiness."
    if ($lastReady -and -not [string]::IsNullOrWhiteSpace($lastReady.LastError)) {
        $msg += " Last error: $($lastReady.LastError)"
    }
    Fail-Hv -Message $msg -LogPath $LogPath
}

function New-HvSession {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5,
        [string]$LogPath = ""
    )

    $lastError = $null

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $session = $null
        try {
            Write-HvLog -Message ("Opening PowerShell Direct session to {0} (attempt {1}/{2})" -f $VmName, $attempt, $RetryCount) -LogPath $LogPath
            $session = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
            $null = Invoke-Command -Session $session -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            return $session
        }
        catch {
            $lastError = $_
            if ($session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }

            Write-HvLog -Message $_.Exception.Message -LogPath $LogPath -Level WARN
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    $msg = @(
        "Failed to open PowerShell Direct session to '$VmName'.",
        $lastError.Exception.Message,
        (Get-HvRecoveryMessage -VmName $VmName)
    ) -join [Environment]::NewLine

    Fail-Hv -Message $msg -LogPath $LogPath
}

function Wait-HvPowerShellDirect {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSeconds = 180,
        [int]$RetryDelaySeconds = 3,
        [string]$LogPath = ""
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            Wait-HvVmReady -VmName $VmName -Credential $Credential -TimeoutSeconds ([Math]::Max(1, [int]($deadline - (Get-Date)).TotalSeconds)) -PollIntervalSeconds $RetryDelaySeconds -RequirePowerShellDirect -LogPath $LogPath | Out-Null
            return New-HvSession -VmName $VmName -Credential $Credential -RetryCount 1 -RetryDelaySeconds $RetryDelaySeconds -LogPath $LogPath
        }
        catch {
            $lastError = $_
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    $msg = "Timed out waiting for PowerShell Direct on '$VmName'."
    if ($lastError) {
        $msg += " Last error: $($lastError.Exception.Message)"
    }

    Fail-Hv -Message $msg -LogPath $LogPath
}

function Invoke-HvGuestCommand {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [string]$LogPath = ""
    )

    try {
        return Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
    catch {
        Write-HvLog -Message $_.Exception.Message -LogPath $LogPath -Level ERROR
        throw
    }
}

function Copy-HvToGuest {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [switch]$Recurse,
        [string]$LogPath = ""
    )

    $resolvedLocal = Resolve-HvPath -Path $LocalPath
    Write-HvLog -Message ("Copy host -> guest: {0} => {1}" -f $resolvedLocal, $GuestPath) -LogPath $LogPath

    if ($Recurse) {
        Copy-Item -LiteralPath $resolvedLocal -Destination $GuestPath -ToSession $Session -Recurse -Force
    } else {
        Copy-Item -LiteralPath $resolvedLocal -Destination $GuestPath -ToSession $Session -Force
    }
}

function Copy-HvFromGuest {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [switch]$Recurse,
        [string]$LogPath = ""
    )

    $resolvedLocal = Resolve-HvPath -Path $LocalPath
    $dir = Split-Path -Parent $resolvedLocal
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir
    }

    Write-HvLog -Message ("Copy guest -> host: {0} => {1}" -f $GuestPath, $resolvedLocal) -LogPath $LogPath

    if ($Recurse) {
        Copy-Item -FromSession $Session -Path $GuestPath -Destination $resolvedLocal -Recurse -Force
    } else {
        Copy-Item -FromSession $Session -Path $GuestPath -Destination $resolvedLocal -Force
    }
}

function Resolve-HvDebuggerExe {
    param([ValidateSet("kd", "windbg")][string]$Debugger = "kd")

    $toolName = if ($Debugger -eq "windbg") { "windbg.exe" } else { "kd.exe" }
    $candidate = Join-Path "${env:ProgramFiles(x86)}" ("Windows Kits\10\Debuggers\x64\{0}" -f $toolName)
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    throw "Debugger not found: $candidate"
}

function Get-HvNamedPipePath {
    param(
        [string]$VmName,
        [string]$PipeName = ""
    )

    if ([string]::IsNullOrWhiteSpace($PipeName)) {
        $PipeName = ("{0}-kd" -f $VmName)
    }

    $PipeName = ($PipeName -replace '[^A-Za-z0-9._-]', '-')
    return "\\.\pipe\$PipeName"
}

function Restart-HvGuest {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$LogPath = ""
    )

    Write-HvLog -Message "Restarting guest OS." -LogPath $LogPath -Level STEP
    Invoke-Command -Session $Session -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue | Out-Null
    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
}

function Wait-HvVmRebootTransition {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSeconds = 90,
        [int]$PollIntervalSeconds = 3,
        [string]$LogPath = ""
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSummary = ""
    do {
        $ready = Get-HvVmReadiness -VmName $VmName -Credential $Credential -CheckPowerShellDirect -ReadyThresholdSeconds 30
        $summary = "state={0}; heartbeat={1}; psdirect={2}; connection={3}; detail={4}" -f $ready.State, $ready.Heartbeat, $ready.PowerShellDirect, $ready.ConnectionState, $ready.ConnectionDetail
        if ($summary -ne $lastSummary) {
            Write-HvLog -Message ("VM reboot transition {0}: {1}" -f $VmName, $summary) -LogPath $LogPath
            $lastSummary = $summary
        }

        $isTransition = ([string]$ready.State -in @("Off", "Saved", "Paused", "Stopping")) -or
            ([string]$ready.Heartbeat -ne "OK") -or
            (-not [bool]$ready.PowerShellDirect) -or
            (Test-HvVmConnectionStateAtLeast -State ([string]$ready.ConnectionState) -MinimumState "LoggedIn") -eq $false

        if ($isTransition) {
            return $ready
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    } while ((Get-Date) -lt $deadline)

    Write-HvLog -Message ("VM '{0}' did not show a reboot transition within {1}s; waiting for readiness anyway." -f $VmName, $TimeoutSeconds) -LogPath $LogPath -Level WARN
    return $ready
}
