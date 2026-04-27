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
        $ArtifactRoot = Resolve-HvPath -Path "output\hyperv-runs"
    } else {
        $ArtifactRoot = Resolve-HvPath -Path $ArtifactRoot
    }

    $runDir = Join-Path $ArtifactRoot (Get-HvTimestamp)
    $null = New-Item -ItemType Directory -Force -Path $runDir
    return $runDir
}

function Get-HvGuestCredential {
    param(
        [System.Management.Automation.PSCredential]$GuestCredential,
        [string]$GuestUser = "Administrator",
        [string]$GuestPasswordPlaintext = ""
    )

    if ($GuestCredential) {
        return $GuestCredential
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
        [int]$RetryDelaySeconds = 5,
        [string]$LogPath = ""
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            Ensure-HvVmRunning -VmName $VmName -LogPath $LogPath
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
