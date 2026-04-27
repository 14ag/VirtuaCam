[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$PipeName = "",
    [ValidateSet("kd", "windbg")][string]$Debugger = "kd",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [int]$BaudRate = 115200,
    [switch]$SkipDebuggerLaunch,
    [switch]$RebootGuest,
    [string]$ArtifactRoot = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { Get-HvArtifactDirectory } else { Resolve-HvPath -Path $ArtifactRoot }
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-kd.log"
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$pipePath = Get-HvNamedPipePath -VmName $VmName -PipeName $PipeName
$debuggerLog = Join-Path $artifactDir "kernel-debugger.log"

Write-HvLog -Message ("Preparing kernel debug for VM '{0}' via {1}" -f $VmName, $pipePath) -LogPath $LogPath -Level STEP

$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.Generation -eq 2) {
    Write-HvLog -Message "Generation 2 VM detected. Disabling Secure Boot for serial kernel debug." -LogPath $LogPath
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
}

Set-VMComPort -VMName $VmName -Number 1 -Path $pipePath -DebuggerMode On | Out-Null

$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath
try {
    $guestDebugState = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($GuestBaudRate)

        $null = & "$env:WINDIR\System32\bcdedit.exe" /debug on
        $null = & "$env:WINDIR\System32\bcdedit.exe" /dbgsettings serial debugport:1 baudrate:$GuestBaudRate
        & "$env:WINDIR\System32\bcdedit.exe" /enum "{current}" 2>&1 | Out-String
    } -ArgumentList $BaudRate

    Set-Content -LiteralPath (Join-Path $artifactDir "guest-bcdedit-debug.txt") -Value $guestDebugState
}
finally {
    if ($RebootGuest) {
        Restart-HvGuest -Session $session -LogPath $LogPath
    } else {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

if (-not $SkipDebuggerLaunch) {
    $debuggerExe = Resolve-HvDebuggerExe -Debugger $Debugger
    $argumentList = @(
        "-k",
        "com:pipe,port=$pipePath,resets=0,reconnect",
        "-logou",
        $debuggerLog
    )

    Write-HvLog -Message ("Launching debugger: {0} {1}" -f $debuggerExe, ($argumentList -join ' ')) -LogPath $LogPath
    Start-Process -FilePath $debuggerExe -ArgumentList $argumentList -Verb RunAs | Out-Null
}

[pscustomobject]@{
    VmName           = $VmName
    PipePath         = $pipePath
    Debugger         = $Debugger
    DebuggerLogPath  = $debuggerLog
    ArtifactDir      = $artifactDir
    KernelDebugReady = $true
}
