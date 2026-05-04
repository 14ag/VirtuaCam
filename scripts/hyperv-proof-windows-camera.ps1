[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$CheckpointName = "clean",
    [string]$GuestUser = "Administrator",
    [string]$GuestPasswordPlaintext = "",
    [string]$ArtifactRoot = "test-reports\windows-camera",
    [ValidateSet("Chrome", "Edge")][string]$Browser = "Chrome",
    [ValidateSet("auto", "printwindow", "wgc", "bitblt")][string]$CaptureBackend = "wgc",
    [bool]$RevertAfterRun = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )
    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Restore-ProofCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$TargetVm,
        [Parameter(Mandatory = $true)][string]$TargetCheckpoint,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    Write-HvLog -Message ("Restoring checkpoint '{0}'." -f $TargetCheckpoint) -LogPath $LogFile -Level STEP
    $checkpoint = Get-VMSnapshot -VMName $TargetVm -Name $TargetCheckpoint -ErrorAction SilentlyContinue
    if (-not $checkpoint) {
        Fail-Hv -Message ("Checkpoint '{0}' was not found." -f $TargetCheckpoint) -LogPath $LogFile
    }
    $vmState = (Get-VM -Name $TargetVm -ErrorAction Stop).State
    if ($vmState -ne "Off") {
        Stop-VM -Name $TargetVm -TurnOff -Force -Confirm:$false | Out-Null
    }
    Restore-VMSnapshot -VMName $TargetVm -Name $TargetCheckpoint -Confirm:$false | Out-Null
}

$repoRoot = Get-HvRepoRoot
$runDir = Join-Path (Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot) (Get-HvTimestamp)
$null = New-Item -ItemType Directory -Force -Path $runDir
$logPath = Join-Path $runDir "hyperv-proof-windows-camera.log"
$statusPath = Join-Path $runDir "vm-session-status.json"
$stopSignalPath = Join-Path $runDir "vm-session-stop.signal"
$holdLogPath = Join-Path $runDir "vm-session-host.log"
$cameraResultPath = Join-Path $runDir "windows-camera-proof.json"
$hostScreenshotPath = Join-Path $runDir "windows-camera-proof.png"

$guestCred = Get-HvGuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$session = $null
$holdProc = $null
$guestRoot = "C:\Temp\VirtuaCamHyperV\camera-proof"
$guestPackageRoot = Join-Path $guestRoot "output"
$guestScriptsRoot = Join-Path $guestRoot "scripts"
$guestToolsRoot = Join-Path $guestScriptsRoot "tools"
$guestInstallAll = Join-Path $guestScriptsRoot "install-all.ps1"
$guestWebcamHtml = Join-Path $guestRoot "webcam.html"
$guestScreenshotPath = Join-Path $guestRoot "windows-camera-proof.png"

try {
    Restore-ProofCheckpoint -TargetVm $VmName -TargetCheckpoint $CheckpointName -LogFile $logPath
    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $logPath

    Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($Root, $ScriptsRoot, $ToolsRoot)
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Force -Path $Root, $ScriptsRoot, $ToolsRoot
    } -ArgumentList $guestRoot, $guestScriptsRoot, $guestToolsRoot | Out-Null

    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "output") -GuestPath $guestRoot -Recurse -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "scripts\install-all.ps1") -GuestPath $guestScriptsRoot -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "scripts\tools\artifact-manifest.ps1") -GuestPath $guestToolsRoot -LogPath $logPath
    Copy-HvToGuest -Session $session -LocalPath (Join-Path $repoRoot "software-project\webcam.html") -GuestPath $guestRoot -LogPath $logPath

    Write-HvLog -Message "Installing staged package inside guest." -LogPath $logPath -Level STEP
    $install = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($InstallScript)
        $lines = & powershell.exe -ExecutionPolicy Bypass -File $InstallScript 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = [string]::Join([Environment]::NewLine, @($lines | ForEach-Object { [string]$_ }))
        }
    } -ArgumentList $guestInstallAll
    Set-Content -LiteralPath (Join-Path $runDir "guest-driver-install.txt") -Value $install.Output
    if ($install.ExitCode -ne 0) {
        throw "driver.InstallFailed"
    }

    Remove-Item -LiteralPath $statusPath, $stopSignalPath -Force -ErrorAction SilentlyContinue
    $holdArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "hyperv-hold-webcam-session.ps1"),
        "-VmName", $VmName,
        "-GuestUser", $GuestUser,
        "-GuestPasswordPlaintext", $GuestPasswordPlaintext,
        "-GuestPackageRoot", $guestPackageRoot,
        "-GuestWebcamHtml", $guestWebcamHtml,
        "-Browser", $Browser,
        "-SourceWindowMode", "ProofPanel",
        "-CaptureBackend", $CaptureBackend,
        "-AttemptId", "camera-proof",
        "-ServeHttp",
        "-HttpPort", "8000",
        "-HostStatusPath", $statusPath,
        "-HostStopSignalPath", $stopSignalPath,
        "-LogPath", $holdLogPath
    )

    Write-HvLog -Message "Launching held source session." -LogPath $logPath -Level STEP
    $holdProc = Start-Process -FilePath "powershell.exe" -ArgumentList $holdArgs -PassThru -WindowStyle Hidden

    $status = $null
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $statusPath) {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            if ($status.Ready) { break }
            if ($status.LaunchError) { throw [string]$status.LaunchError }
        }
        if ($holdProc.HasExited) { throw "Held session exited before ready." }
        Start-Sleep -Seconds 2
    }
    if (-not $status -or -not $status.Ready) {
        throw "Timed out waiting for held source session."
    }

    Write-HvLog -Message "Launching Windows Camera app and taking desktop screenshot." -LogPath $logPath -Level STEP
    $camera = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        param($ScreenshotPath)
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        Start-Process "microsoft.windows.camera:" | Out-Null
        Start-Sleep -Seconds 10
        $cameraProcesses = @(Get-Process -Name "WindowsCamera", "ApplicationFrameHost" -ErrorAction SilentlyContinue)
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($ScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        [pscustomobject]@{
            CameraProcessCount = $cameraProcesses.Count
            ScreenshotPath = $ScreenshotPath
            CapturedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    } -ArgumentList $guestScreenshotPath

    Copy-HvFromGuest -Session $session -GuestPath $guestScreenshotPath -LocalPath $hostScreenshotPath -LogPath $logPath
    $summary = [pscustomobject]@{
        Success = (Test-Path -LiteralPath $hostScreenshotPath)
        RunDir = $runDir
        ScreenshotPath = $hostScreenshotPath
        HeldSessionStatus = $status
        Camera = $camera
        CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    Write-JsonFile -Path $cameraResultPath -Data $summary
    $summary
}
finally {
    if (-not (Test-Path -LiteralPath $stopSignalPath)) {
        New-Item -ItemType File -Force -Path $stopSignalPath | Out-Null
    }
    if ($holdProc) {
        Wait-Process -Id $holdProc.Id -Timeout 20 -ErrorAction SilentlyContinue
        if (-not $holdProc.HasExited) {
            Stop-Process -Id $holdProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
    if ($RevertAfterRun) {
        Restore-ProofCheckpoint -TargetVm $VmName -TargetCheckpoint $CheckpointName -LogFile $logPath
    }
}
