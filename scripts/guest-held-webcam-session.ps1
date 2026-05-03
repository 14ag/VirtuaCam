[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Join-TextOutput {
    param([object[]]$InputObject)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }
        $lines.Add([string]$item.ToString())
    }

    return [string]::Join([System.Environment]::NewLine, $lines.ToArray())
}

function Get-BrowserPath {
    param([string]$RequestedBrowser)

    $chrome = Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"
    $edge = Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"
    if ($RequestedBrowser -eq "Chrome" -and (Test-Path -LiteralPath $chrome)) {
        return $chrome
    }
    if ($RequestedBrowser -eq "Edge" -and (Test-Path -LiteralPath $edge)) {
        return $edge
    }
    if (Test-Path -LiteralPath $chrome) {
        return $chrome
    }
    return $edge
}

function Invoke-WithAttemptEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptValue,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [hashtable]$AdditionalEnvironment = @{}
    )

    $oldAttempt = $env:VIRTUACAM_ATTEMPT_ID
    $hadAttempt = Test-Path Env:VIRTUACAM_ATTEMPT_ID
    $savedEnvironment = @{}

    foreach ($entry in $AdditionalEnvironment.GetEnumerator()) {
        $name = [string]$entry.Key
        $envPath = "Env:$name"
        $savedEnvironment[$name] = [pscustomobject]@{
            HadValue = (Test-Path $envPath)
            Value = if (Test-Path $envPath) { (Get-Item $envPath).Value } else { "" }
        }
        Set-Item -Path $envPath -Value ([string]$entry.Value)
    }

    $env:VIRTUACAM_ATTEMPT_ID = $AttemptValue
    try {
        & $Action
    }
    finally {
        foreach ($entry in $savedEnvironment.GetEnumerator()) {
            $name = [string]$entry.Key
            $envPath = "Env:$name"
            if ($entry.Value.HadValue) {
                Set-Item -Path $envPath -Value ([string]$entry.Value.Value)
            }
            else {
                Remove-Item $envPath -ErrorAction SilentlyContinue
            }
        }

        if ($hadAttempt) {
            $env:VIRTUACAM_ATTEMPT_ID = $oldAttempt
        }
        else {
            Remove-Item Env:VIRTUACAM_ATTEMPT_ID -ErrorAction SilentlyContinue
        }
    }
}

function Wait-ForProcessMainWindow {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$TitleLike = "",
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($proc) {
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne 0) {
                $title = [string]$proc.MainWindowTitle
                if ([string]::IsNullOrWhiteSpace($TitleLike) -or $title -like ("*{0}*" -f $TitleLike)) {
                    return [pscustomobject]@{
                        Hwnd = ($proc.MainWindowHandle.ToInt64()).ToString()
                        ProcessId = $proc.Id.ToString()
                        ProcessName = [string]$proc.ProcessName
                        WindowTitle = $title
                    }
                }
            }
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Wait-ForProcessNameWindow {
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [string]$TitleLike = "",
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $candidates = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        foreach ($candidate in $candidates) {
            $candidate.Refresh()
            if ($candidate.MainWindowHandle -eq 0) {
                continue
            }

            $title = [string]$candidate.MainWindowTitle
            if ([string]::IsNullOrWhiteSpace($TitleLike) -or $title -like ("*{0}*" -f $TitleLike)) {
                return [pscustomobject]@{
                    Hwnd = ($candidate.MainWindowHandle.ToInt64()).ToString()
                    ProcessId = $candidate.Id.ToString()
                    ProcessName = [string]$candidate.ProcessName
                    WindowTitle = $title
                }
            }
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    return $null
}

if (-not ("NativeWindowOps" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeWindowOps {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
"@
}

$consoleHwnd = [NativeWindowOps]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
    [void][NativeWindowOps]::ShowWindowAsync($consoleHwnd, 2)
}

$config = Read-JsonFile -Path $ConfigPath
$packageRoot = [string]$config.PackageRoot
$htmlPath = [string]$config.HtmlPath
$browser = [string]$config.Browser
$attemptId = [string]$config.AttemptId
$requestedSourceWindowMode = [string]$config.SourceWindowMode
$captureBackend = if ($config.PSObject.Properties["CaptureBackend"] -and $config.CaptureBackend) { [string]$config.CaptureBackend } else { "auto" }
$httpPort = [int]$config.HttpPort
$guestStatusPath = [string]$config.GuestStatusPath
$serveHttp = [bool]$config.ServeHttp
$browserExtraArgs = @()
if ($config.PSObject.Properties["BrowserExtraArgs"] -and $null -ne $config.BrowserExtraArgs) {
    if ($config.BrowserExtraArgs -is [System.Array]) {
        $browserExtraArgs = @($config.BrowserExtraArgs | ForEach-Object { [string]$_ })
    }
    else {
        $browserExtraArgs = @([string]$config.BrowserExtraArgs)
    }
}

$root = Split-Path -Parent $packageRoot
$sourceHwndFile = Join-Path $root "source-window.hwnd.txt"
$sourcePidFile = Join-Path $root "source-window.pid.txt"
$panelScript = Join-Path $root "show-proof-panel.ps1"
$panelStdOut = Join-Path $root "show-proof-panel.stdout.log"
$panelStdErr = Join-Path $root "show-proof-panel.stderr.log"
$serverScript = Join-Path $root "serve-webcam.ps1"
$browserDebugLog = Join-Path $root ("chrome_debug_{0}.log" -f $attemptId)
$browserProfile = Join-Path $root (($browser.ToLowerInvariant()) + "-profile-" + $attemptId)
$runtimeLog = Join-Path $packageRoot "logs\virtuacam-runtime.log"
$processLog = Join-Path $packageRoot "logs\virtuacam-process.log"
$processExe = Join-Path $packageRoot "VirtuaCamProcess.exe"
$runtimeExe = Join-Path $packageRoot "VirtuaCam.exe"
$browserExe = Get-BrowserPath -RequestedBrowser $browser
$sourceWindowMode = $requestedSourceWindowMode
$sourceTimestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$sourceStem = ("proof-{0}-{1}-{2}" -f $attemptId, $sourceTimestamp, $env:COMPUTERNAME) -replace '[^A-Za-z0-9._-]', '-'
$sourceMarker = "VIRTUACAM REAL WINDOW PROOF | attempt=$attemptId | utc=$sourceTimestamp | host=$env:COMPUTERNAME"
$sourceTextPath = Join-Path $root ("notepad-{0}.txt" -f $sourceStem)
$sourceExplorerDir = Join-Path $root ("explorer-{0}" -f $sourceStem)
$sourceLaunchProc = $null
$sourceWindowInfo = $null
$sourceWindowTitleHint = ""
$sourceWindowHwndText = ""
$sourceWindowPidText = ""
$sourceWindowProcess = ""
$sourceWindowTitle = ""
$virtuaCamProcess = $null
$virtuaCamRuntime = $null
$browserProc = $null
$browserUrl = "file:///" + ($htmlPath -replace "\\", "/")
$guestIp = ""
$browserReady = $false
$browserCommandLine = ""
$browserReadyProbe = [ordered]@{
    JsonVersionUrl = "http://127.0.0.1:9222/json/version"
    StatusCode = 0
    WebSocketDebuggerUrl = ""
    Body = ""
    Error = ""
}

function Get-TextTail {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$EncodingName = "",
        [int]$Tail = 80
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($EncodingName)) {
        return Join-TextOutput @(Get-Content -LiteralPath $Path -Tail $Tail)
    }

    return Join-TextOutput @(Get-Content -LiteralPath $Path -Encoding $EncodingName -Tail $Tail)
}

function Write-GuestState {
    param(
        [bool]$Ready,
        [string]$LaunchError = "",
        [string]$LaunchErrorClass = "",
        [bool]$GuestSessionAlive = $true
    )

    $state = [ordered]@{
        Ready = $Ready
        AttemptId = $attemptId
        GuestIp = $guestIp
        Browser = $browser
        SourceWindowMode = $sourceWindowMode
        CaptureBackend = $captureBackend
        SourceWindowProcess = $sourceWindowProcess
        SourceWindowTitle = $sourceWindowTitle
        SourceWindowPid = $sourceWindowPidText
        SourceWindowHwnd = $sourceWindowHwndText
        SourceMarker = $sourceMarker
        BrowserExe = $browserExe
        BrowserUrl = $browserUrl
        BrowserReady = $browserReady
        BrowserReadyProbe = $browserReadyProbe
        BrowserCommandLine = $browserCommandLine
        BrowserProfilePath = $browserProfile
        BrowserDebugLogPath = $browserDebugLog
        BrowserDebugLogTail = Get-TextTail -Path $browserDebugLog -Tail 80
        GuestSessionAlive = $GuestSessionAlive
        GuestSessionTimestampUtc = [DateTime]::UtcNow.ToString("o")
        ControlPanelHwnd = if ($sourceWindowMode -eq "ProofPanel") { $sourceWindowHwndText } else { "" }
        ControlPanelPid = if ($sourceWindowMode -eq "ProofPanel") { $sourceWindowPidText } else { "" }
        PanelProcessId = if ($sourceWindowMode -eq "ProofPanel" -and $sourceLaunchProc) { $sourceLaunchProc.Id } else { 0 }
        VirtuaCamPid = if ($virtuaCamRuntime) { $virtuaCamRuntime.Id } else { 0 }
        VirtuaCamProcessPid = if ($virtuaCamProcess) { $virtuaCamProcess.Id } else { 0 }
        RuntimeLogPath = $runtimeLog
        ProcessLogPath = $processLog
        RuntimeLogTail = Get-TextTail -Path $runtimeLog -EncodingName Unicode -Tail 60
        ProcessLogTail = Get-TextTail -Path $processLog -EncodingName Unicode -Tail 60
        LaunchError = $LaunchError
        LaunchErrorClass = $LaunchErrorClass
    }

    Write-JsonFile -Path $guestStatusPath -Data ([pscustomobject]$state)
    return [pscustomobject]$state
}

$panelScriptText = @"
param(
    [Parameter(Mandatory=`$true)][string]`$HwndPath,
    [Parameter(Mandatory=`$true)][string]`$PidPath,
    [string]`$AttemptId = "",
    [string]`$MarkerText = ""
)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
`$attemptText = if (`$AttemptId) { `$AttemptId } else { 'n/a' }
`$markerText = if (`$MarkerText) { `$MarkerText } else { 'marker-missing' }
`$form = New-Object System.Windows.Forms.Form
`$form.Text = 'Proof Window'
`$form.StartPosition = 'CenterScreen'
`$form.Size = New-Object System.Drawing.Size(900, 620)
`$form.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 34)
`$header = New-Object System.Windows.Forms.Label
`$header.Text = 'Virtual Camera Proof Window'
`$header.ForeColor = [System.Drawing.Color]::White
`$header.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
`$header.AutoSize = `$true
`$header.Location = New-Object System.Drawing.Point(24, 20)
`$form.Controls.Add(`$header)
`$group = New-Object System.Windows.Forms.GroupBox
`$group.Text = 'Feed'
`$group.ForeColor = [System.Drawing.Color]::White
`$group.Size = New-Object System.Drawing.Size(840, 500)
`$group.Location = New-Object System.Drawing.Point(24, 70)
`$form.Controls.Add(`$group)
`$preview = New-Object System.Windows.Forms.Panel
`$preview.BackColor = [System.Drawing.Color]::White
`$preview.Size = New-Object System.Drawing.Size(520, 360)
`$preview.Location = New-Object System.Drawing.Point(24, 40)
`$group.Controls.Add(`$preview)
`$pc = New-Object System.Windows.Forms.Label
`$pc.Text = "SYNTHETIC DEBUG WINDOW`r`n`r`nAttempt: `$attemptText`r`n`r`nMarker:`r`n`$markerText"
`$pc.ForeColor = [System.Drawing.Color]::Black
`$pc.Font = New-Object System.Drawing.Font('Consolas', 16, [System.Drawing.FontStyle]::Bold)
`$pc.AutoSize = `$true
`$pc.BackColor = [System.Drawing.Color]::Transparent
`$pc.Location = New-Object System.Drawing.Point(28, 46)
`$preview.Controls.Add(`$pc)
`$btn = New-Object System.Windows.Forms.Button
`$btn.Text = 'Synthetic Debug Mode'
`$btn.Size = New-Object System.Drawing.Size(180, 36)
`$btn.Location = New-Object System.Drawing.Point(580, 60)
`$group.Controls.Add(`$btn)
`$list = New-Object System.Windows.Forms.ListBox
`$list.Size = New-Object System.Drawing.Size(220, 160)
`$list.Location = New-Object System.Drawing.Point(580, 120)
`$list.Items.AddRange(@('Synthetic only', 'Do not count as proof', 'Use Notepad or Explorer instead'))
`$group.Controls.Add(`$list)
`$status = New-Object System.Windows.Forms.Label
`$status.Text = 'Status: Synthetic debug source'
`$status.ForeColor = [System.Drawing.Color]::White
`$status.AutoSize = `$true
`$status.Location = New-Object System.Drawing.Point(580, 310)
`$group.Controls.Add(`$status)
`$form.Add_Shown({
    param(`$sender, `$eventArgs)
    [System.IO.File]::WriteAllText(`$HwndPath, (`$sender.Handle.ToInt64()).ToString())
    [System.IO.File]::WriteAllText(`$PidPath, `$PID.ToString())
})
[System.Windows.Forms.Application]::Run(`$form)
"@

$serverScriptText = @"
param(
    [Parameter(Mandatory=`$true)][string]`$Root,
    [int]`$Port = 8000
)
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web
`$listener = [System.Net.HttpListener]::new()
`$listener.Prefixes.Add("http://127.0.0.1:`$Port/")
`$listener.Start()
try {
    while (`$listener.IsListening) {
        `$ctx = `$listener.GetContext()
        try {
            `$reqPath = [System.Web.HttpUtility]::UrlDecode(`$ctx.Request.Url.AbsolutePath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace(`$reqPath)) {
                `$reqPath = 'webcam.html'
            }
            `$filePath = Join-Path `$Root `$reqPath
            if ((Test-Path -LiteralPath `$filePath) -and -not (Get-Item -LiteralPath `$filePath).PSIsContainer) {
                `$ext = [System.IO.Path]::GetExtension(`$filePath).ToLowerInvariant()
                `$contentType = switch (`$ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.png'  { 'image/png' }
                    '.jpg'  { 'image/jpeg' }
                    '.jpeg' { 'image/jpeg' }
                    default { 'application/octet-stream' }
                }
                `$bytes = [System.IO.File]::ReadAllBytes(`$filePath)
                `$ctx.Response.StatusCode = 200
                `$ctx.Response.ContentType = `$contentType
                `$ctx.Response.OutputStream.Write(`$bytes, 0, `$bytes.Length)
            }
            else {
                `$ctx.Response.StatusCode = 404
            }
        }
        finally {
            `$ctx.Response.OutputStream.Close()
        }
    }
}
finally {
    `$listener.Stop()
    `$listener.Close()
}
"@

try {
    $null = New-Item -ItemType Directory -Force -Path $root, (Join-Path $packageRoot "logs")
    $panelScriptText | Set-Content -LiteralPath $panelScript -Encoding ASCII
    $serverScriptText | Set-Content -LiteralPath $serverScript -Encoding ASCII

    $cleanupNames = @("chrome", "msedge", "VirtuaCam", "VirtuaCamProcess")
    if ($sourceWindowMode -eq "Notepad") {
        $cleanupNames += "notepad"
    }
    if ($sourceWindowMode -eq "Settings") {
        $cleanupNames += "SystemSettings"
    }
    Get-Process -Name $cleanupNames -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($procName in $cleanupNames) {
        for ($wait = 0; $wait -lt 30; $wait++) {
            if (-not (Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
                break
            }
            Start-Sleep -Milliseconds 200
        }
    }

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*serve-webcam.ps1*" -or $_.CommandLine -like "*show-proof-panel.ps1*" } |
        Invoke-CimMethod -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null

    Remove-Item -LiteralPath $sourceHwndFile, $sourcePidFile, $browserDebugLog, $guestStatusPath, $panelStdOut, $panelStdErr -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $browserProfile -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sourceTextPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sourceExplorerDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $browserProfile | Out-Null

    switch ($sourceWindowMode) {
        "Notepad" {
            $sourceLines = @(
                "VIRTUAL CAMERA REAL WINDOW PROOF",
                "",
                "Marker: $sourceMarker",
                "SourceMode: $sourceWindowMode",
                "AttemptId: $attemptId",
                "UtcTimestamp: $sourceTimestamp",
                "ComputerName: $env:COMPUTERNAME",
                ""
            ) + (1..10 | ForEach-Object { "ProofLine $($_): $sourceMarker" })
            Set-Content -LiteralPath $sourceTextPath -Encoding ASCII -Value $sourceLines
            $sourceLaunchProc = Start-Process -FilePath "notepad.exe" -ArgumentList @($sourceTextPath) -PassThru
            $sourceWindowTitleHint = [System.IO.Path]::GetFileName($sourceTextPath)
            $sourceWindowInfo = Wait-ForProcessMainWindow -ProcessId $sourceLaunchProc.Id -TitleLike $sourceWindowTitleHint -TimeoutSeconds 20
            if (-not $sourceWindowInfo) {
                throw "Timed out waiting for Notepad source window."
            }
        }
        "Settings" {
            Get-Process -Name SystemSettings -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Start-Process "ms-settings:" | Out-Null
            $sourceWindowTitleHint = "Settings"
            $sourceWindowInfo = Wait-ForProcessNameWindow -ProcessName "ApplicationFrameHost" -TitleLike $sourceWindowTitleHint -TimeoutSeconds 30
            if (-not $sourceWindowInfo) {
                throw "Timed out waiting for Settings source window."
            }
        }
        "Explorer" {
            New-Item -ItemType Directory -Force -Path $sourceExplorerDir | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceExplorerDir "README.txt") -Encoding ASCII -Value @(
                "VIRTUAL CAMERA REAL WINDOW PROOF",
                "",
                "Marker: $sourceMarker",
                "SourceMode: $sourceWindowMode",
                "AttemptId: $attemptId",
                "UtcTimestamp: $sourceTimestamp",
                "ComputerName: $env:COMPUTERNAME"
            )
            $sourceWindowTitleHint = Split-Path -Path $sourceExplorerDir -Leaf
            $sourceLaunchProc = Start-Process -FilePath "explorer.exe" -ArgumentList @($sourceExplorerDir) -PassThru
            $sourceWindowInfo = Wait-ForProcessNameWindow -ProcessName "explorer" -TitleLike $sourceWindowTitleHint -TimeoutSeconds 20
            if (-not $sourceWindowInfo) {
                throw "Timed out waiting for Explorer source window."
            }
        }
        "ProofPanel" {
            $panel = Start-Process powershell.exe -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-STA",
                "-File", $panelScript,
                "-HwndPath", $sourceHwndFile,
                "-PidPath", $sourcePidFile,
                "-AttemptId", $attemptId,
                "-MarkerText", $sourceMarker
            ) -RedirectStandardOutput $panelStdOut -RedirectStandardError $panelStdErr -PassThru

            $deadline = (Get-Date).AddSeconds(20)
            do {
                Start-Sleep -Milliseconds 250
                if (Test-Path -LiteralPath $sourceHwndFile) {
                    break
                }
            } while ((Get-Date) -lt $deadline)

            if (-not (Test-Path -LiteralPath $sourceHwndFile)) {
                if (Test-Path -LiteralPath $panelStdErr) {
                    $stderrText = (Get-Content -LiteralPath $panelStdErr -Raw -ErrorAction SilentlyContinue)
                    if ($stderrText) {
                        throw ("Timed out waiting for proof-panel hwnd file. stderr: " + $stderrText.Trim())
                    }
                }
                throw "Timed out waiting for proof-panel hwnd file."
            }

            $sourceWindowHwndText = (Get-Content -LiteralPath $sourceHwndFile -Raw).Trim()
            $sourceWindowPidText = if (Test-Path -LiteralPath $sourcePidFile) { (Get-Content -LiteralPath $sourcePidFile -Raw).Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($sourceWindowPidText)) {
                $sourceWindowPidText = if ($panel) { $panel.Id.ToString() } else { "" }
            }
            $sourceWindowInfo = [pscustomobject]@{
                Hwnd = $sourceWindowHwndText
                ProcessId = $sourceWindowPidText
                ProcessName = "powershell"
                WindowTitle = "Proof Window"
            }
            if ([uint64]$sourceWindowInfo.Hwnd -eq 0) {
                throw "Proof-panel hwnd is 0."
            }
            $sourceLaunchProc = $panel
        }
        default {
            throw "Unsupported source window mode: $sourceWindowMode"
        }
    }

    if (-not $sourceWindowInfo) {
        throw "Source window info missing after launch."
    }

    $sourceWindowHwndText = [string]$sourceWindowInfo.Hwnd
    $sourceWindowPidText = [string]$sourceWindowInfo.ProcessId
    $sourceWindowProcess = [string]$sourceWindowInfo.ProcessName
    $sourceWindowTitle = [string]$sourceWindowInfo.WindowTitle
    $hwnd = [uint64]$sourceWindowHwndText

    if ($hwnd -ne 0) {
        [void][NativeWindowOps]::ShowWindowAsync(([IntPtr][int64]$hwnd), 3)
        Start-Sleep -Milliseconds 250
        [void][NativeWindowOps]::SetForegroundWindow(([IntPtr][int64]$hwnd))
    }

    netsh advfirewall firewall add rule name='VirtuaCam Browser CDP 9222' dir=in action=allow protocol=TCP localport=9222 | Out-Null
    netsh advfirewall firewall add rule name='VirtuaCam Browser CDP 9223' dir=in action=allow protocol=TCP localport=9223 | Out-Null
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=9223 | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=9223 connectaddress=127.0.0.1 connectport=9222 | Out-Null

    if (Test-Path -LiteralPath $processExe) {
        $virtuaCamProcess = Invoke-WithAttemptEnvironment -AttemptValue $attemptId -Action {
            Start-Process -FilePath $processExe -WorkingDirectory $packageRoot -ArgumentList @("-debug") -WindowStyle Hidden -PassThru
        } -AdditionalEnvironment @{
            VIRTUACAM_STARTUP_ARGS = ("--source-window-hwnd {0}" -f $sourceWindowHwndText)
            VIRTUACAM_CAPTURE_BACKEND = $captureBackend
        }
    }

    if (-not (Test-Path -LiteralPath $runtimeExe)) {
        throw "VirtuaCam.exe missing: $runtimeExe"
    }

    if ($serveHttp) {
        Start-Process powershell.exe -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $serverScript,
            "-Root", (Split-Path -Parent $htmlPath),
            "-Port", "$httpPort"
        ) -WindowStyle Hidden | Out-Null
        $browserUrl = "http://127.0.0.1:$httpPort/" + [System.IO.Path]::GetFileName($htmlPath)
    }

    $defaultBrowserArgs = @(
        "--user-data-dir=$browserProfile",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-sync",
        "--disable-background-networking",
        "--disable-component-update",
        "--remote-debugging-address=0.0.0.0",
        "--remote-debugging-port=9222",
        "--use-fake-ui-for-media-stream",
        "--enable-logging",
        "--v=1",
        "--log-file=$browserDebugLog",
        "--force-directshow",
        "--new-window"
    )
    if ($browserExtraArgs) {
        $defaultBrowserArgs += $browserExtraArgs
    }
    $defaultBrowserArgs += $browserUrl

    $browserProc = Invoke-WithAttemptEnvironment -AttemptValue $attemptId -Action {
        Start-Process -FilePath $browserExe -ArgumentList $defaultBrowserArgs -PassThru
    }

    $browserWindow = Wait-ForProcessMainWindow -ProcessId $browserProc.Id -TimeoutSeconds 20
    if ($browserWindow -and $browserWindow.Hwnd) {
        [void][NativeWindowOps]::ShowWindowAsync(([IntPtr][int64]$browserWindow.Hwnd), 3)
        Start-Sleep -Milliseconds 250
        [void][NativeWindowOps]::SetForegroundWindow(([IntPtr][int64]$browserWindow.Hwnd))
    }

    $runtimeDeadline = (Get-Date).AddSeconds(15)
    do {
        $runtimeCandidates = @(Get-Process -Name "VirtuaCam" -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending)
        if ($runtimeCandidates.Count -gt 0) {
            $virtuaCamRuntime = $runtimeCandidates[0]
            break
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $runtimeDeadline)

    Start-Sleep -Seconds 6

    $guestIp = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1 -ExpandProperty IPAddress)

    try {
        $versionResponse = Invoke-WebRequest -UseBasicParsing -Uri $browserReadyProbe.JsonVersionUrl -TimeoutSec 5
        $browserReadyProbe.StatusCode = [int]$versionResponse.StatusCode
        $browserReadyProbe.Body = $versionResponse.Content
        $versionJson = $versionResponse.Content | ConvertFrom-Json
        if ($versionJson.webSocketDebuggerUrl) {
            $browserReadyProbe.WebSocketDebuggerUrl = [string]$versionJson.webSocketDebuggerUrl
        }
        $browserReady = ($versionResponse.StatusCode -eq 200)
    }
    catch {
        $browserReadyProbe.Error = $_.Exception.Message
    }

    if ($browserProc) {
        $browserInfo = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $browserProc.Id) -ErrorAction SilentlyContinue
        if ($browserInfo) {
            $browserCommandLine = [string]$browserInfo.CommandLine
        }
    }

    Write-GuestState -Ready $true | Out-Null
}
catch {
    Write-GuestState -Ready $false -LaunchError $_.Exception.Message -LaunchErrorClass "guest.HoldLaunchFailed" -GuestSessionAlive $false | Out-Null
    throw
}
