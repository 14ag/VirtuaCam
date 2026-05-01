[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$GuestUser = "Administrator",
    [string]$GuestPasswordPlaintext = "",
    [string]$GuestPackageRoot = "C:\Temp\VirtuaCamHyperV\manual\package-repro",
    [string]$GuestWebcamHtml = "C:\Temp\VirtuaCamHyperV\manual\webcam.html",
    [ValidateSet("Chrome", "Edge")][string]$Browser = "Chrome",
    [string[]]$BrowserExtraArgs = @(),
    [string]$AttemptId = "manual",
    [switch]$ServeHttp,
    [int]$HttpPort = 8000,
    [string]$HostStatusPath = "",
    [string]$HostStopSignalPath = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

if ([string]::IsNullOrWhiteSpace($HostStatusPath)) {
    $HostStatusPath = Resolve-HvPath -Path "output\playwright\vm-session-status.json"
}
if ([string]::IsNullOrWhiteSpace($HostStopSignalPath)) {
    $HostStopSignalPath = Resolve-HvPath -Path "output\playwright\vm-session-stop.signal"
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Resolve-HvPath -Path "output\playwright\vm-session-host.log"
}

$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HostStatusPath), (Split-Path -Parent $HostStopSignalPath), (Split-Path -Parent $LogPath)
Remove-Item -LiteralPath $HostStatusPath, $HostStopSignalPath -Force -ErrorAction SilentlyContinue

$guestCred = Get-HvGuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$session = $null

function Write-StatusFile {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$StatusObject
    )

    $StatusObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $HostStatusPath -Encoding UTF8
}

try {
    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath

    $guestState = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($PackageRoot, $HtmlPath, $Browser, $ServeHttp, $HttpPort, $BrowserExtraArgs, $AttemptId)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

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
                [Parameter(Mandatory = $true)][scriptblock]$Action
            )

            $oldAttempt = $env:VIRTUACAM_ATTEMPT_ID
            $hadAttempt = Test-Path Env:VIRTUACAM_ATTEMPT_ID
            $env:VIRTUACAM_ATTEMPT_ID = $AttemptValue
            try {
                & $Action
            }
            finally {
                if ($hadAttempt) {
                    $env:VIRTUACAM_ATTEMPT_ID = $oldAttempt
                }
                else {
                    Remove-Item Env:VIRTUACAM_ATTEMPT_ID -ErrorAction SilentlyContinue
                }
            }
        }

        $root = Split-Path -Parent $PackageRoot
        $hwndFile = Join-Path $root "control-panel.hwnd.txt"
        $pidFile = Join-Path $root "control-panel.pid.txt"
        $panelScript = Join-Path $root "show-control-panel.ps1"
        $panelStdOut = Join-Path $root "show-control-panel.stdout.log"
        $panelStdErr = Join-Path $root "show-control-panel.stderr.log"
        $serverScript = Join-Path $root "serve-webcam.ps1"
        $browserDebugLog = Join-Path $root ("chrome_debug_{0}.log" -f $AttemptId)
        $guestStatusPath = Join-Path $root "guest-session-status.json"
        $browserProfile = Join-Path $root (($Browser.ToLowerInvariant()) + "-profile-" + $AttemptId)
        $runtimeLog = Join-Path $PackageRoot "logs\virtuacam-runtime.log"
        $processLog = Join-Path $PackageRoot "logs\virtuacam-process.log"
        $processExe = Join-Path $PackageRoot "VirtuaCamProcess.exe"
        $runtimeExe = Join-Path $PackageRoot "VirtuaCam.exe"
        $browserExe = Get-BrowserPath -RequestedBrowser $Browser
        $browserProcessName = if ($Browser -eq "Edge") { "msedge" } else { "chrome" }

$panelScriptText = @"
param(
    [Parameter(Mandatory=`$true)][string]`$HwndPath,
    [Parameter(Mandatory=`$true)][string]`$PidPath,
    [string]`$AttemptId = ""
)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
`$attemptText = if (`$AttemptId) { `$AttemptId } else { 'n/a' }
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
`$pc.Text = "VIRTUAL CAMERA PROOF`r`n`r`nAttempt: `$attemptText`r`n`r`nwebcam.html should show this text."
`$pc.ForeColor = [System.Drawing.Color]::Black
`$pc.Font = New-Object System.Drawing.Font('Consolas', 20, [System.Drawing.FontStyle]::Bold)
`$pc.AutoSize = `$true
`$pc.BackColor = [System.Drawing.Color]::Transparent
`$pc.Location = New-Object System.Drawing.Point(28, 46)
`$preview.Controls.Add(`$pc)
`$btn = New-Object System.Windows.Forms.Button
`$btn.Text = 'Driver Test Running'
`$btn.Size = New-Object System.Drawing.Size(180, 36)
`$btn.Location = New-Object System.Drawing.Point(580, 60)
`$group.Controls.Add(`$btn)
`$list = New-Object System.Windows.Forms.ListBox
`$list.Size = New-Object System.Drawing.Size(220, 160)
`$list.Location = New-Object System.Drawing.Point(580, 120)
`$list.Items.AddRange(@('Virtual Camera Source', 'Window Capture', 'Proof text window'))
`$group.Controls.Add(`$list)
`$status = New-Object System.Windows.Forms.Label
`$status.Text = 'Status: Ready'
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

        $null = New-Item -ItemType Directory -Force -Path $root, (Join-Path $PackageRoot "logs")
        $panelScriptText | Set-Content -LiteralPath $panelScript -Encoding ASCII
        $serverScriptText | Set-Content -LiteralPath $serverScript -Encoding ASCII

        Get-Process -Name chrome, msedge, VirtuaCam, VirtuaCamProcess -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        foreach ($procName in @("chrome", "msedge", "VirtuaCam", "VirtuaCamProcess")) {
            for ($wait = 0; $wait -lt 30; $wait++) {
                if (-not (Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
                    break
                }
                Start-Sleep -Milliseconds 200
            }
        }
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*serve-webcam.ps1*" } |
            Invoke-CimMethod -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null

        Remove-Item -LiteralPath $hwndFile, $pidFile, $browserDebugLog, $guestStatusPath, $panelStdOut, $panelStdErr -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $browserProfile -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $browserProfile | Out-Null

        $panel = Start-Process powershell.exe -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-STA",
            "-File", $panelScript,
            "-HwndPath", $hwndFile,
            "-PidPath", $pidFile,
            "-AttemptId", $AttemptId
        ) -RedirectStandardOutput $panelStdOut -RedirectStandardError $panelStdErr -PassThru

        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            if (Test-Path -LiteralPath $hwndFile) {
                break
            }
        } while ((Get-Date) -lt $deadline)

        if (-not (Test-Path -LiteralPath $hwndFile)) {
            if (Test-Path -LiteralPath $panelStdErr) {
                $stderrText = (Get-Content -LiteralPath $panelStdErr -Raw -ErrorAction SilentlyContinue)
                if ($stderrText) {
                    throw ("Timed out waiting for control-panel hwnd file. stderr: " + $stderrText.Trim())
                }
            }
            throw "Timed out waiting for control-panel hwnd file."
        }

        $hwndText = (Get-Content -LiteralPath $hwndFile -Raw).Trim()
        $panelPidText = if (Test-Path -LiteralPath $pidFile) { (Get-Content -LiteralPath $pidFile -Raw).Trim() } else { "" }
        $hwnd = [uint64]$hwndText
        if ($hwnd -eq 0) {
            throw "Control-panel hwnd is 0."
        }

        netsh advfirewall firewall add rule name='VirtuaCam Browser CDP 9222' dir=in action=allow protocol=TCP localport=9222 | Out-Null
        netsh advfirewall firewall add rule name='VirtuaCam Browser CDP 9223' dir=in action=allow protocol=TCP localport=9223 | Out-Null
        netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=9223 | Out-Null
        netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=9223 connectaddress=127.0.0.1 connectport=9222 | Out-Null

        $virtuaCamProcess = $null
        if (Test-Path -LiteralPath $processExe) {
            $virtuaCamProcess = Invoke-WithAttemptEnvironment -AttemptValue $AttemptId -Action {
                Start-Process -FilePath $processExe -WorkingDirectory $PackageRoot -ArgumentList @("-debug") -WindowStyle Hidden -PassThru
            }
        }

        $virtuaCamRuntime = $null
        if (Test-Path -LiteralPath $runtimeExe) {
            $virtuaCamRuntime = Invoke-WithAttemptEnvironment -AttemptValue $AttemptId -Action {
                Start-Process -FilePath $runtimeExe -WorkingDirectory $PackageRoot -ArgumentList @("/startup", "-debug", "--source-window-hwnd", "$hwnd") -PassThru
            }
        }
        else {
            throw "VirtuaCam.exe missing: $runtimeExe"
        }

        Start-Sleep -Seconds 4

        $browserUrl = "file:///" + ($HtmlPath -replace "\\", "/")
        if ($ServeHttp) {
            Start-Process powershell.exe -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $serverScript,
                "-Root", (Split-Path -Parent $HtmlPath),
                "-Port", "$HttpPort"
            ) -WindowStyle Hidden | Out-Null
            $browserUrl = "http://127.0.0.1:$HttpPort/" + [System.IO.Path]::GetFileName($HtmlPath)
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
        if ($BrowserExtraArgs) {
            $defaultBrowserArgs += $BrowserExtraArgs
        }
        $defaultBrowserArgs += $browserUrl

        $browserProc = $null
        $browserProc = Invoke-WithAttemptEnvironment -AttemptValue $AttemptId -Action {
            Start-Process -FilePath $browserExe -ArgumentList $defaultBrowserArgs -PassThru
        }

        Start-Sleep -Seconds 6

        $guestIp = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
            Sort-Object InterfaceMetric |
            Select-Object -First 1 -ExpandProperty IPAddress)

        $browserReady = $false
        $browserReadyProbe = [ordered]@{
            JsonVersionUrl = "http://127.0.0.1:9222/json/version"
            StatusCode = 0
            WebSocketDebuggerUrl = ""
            Body = ""
            Error = ""
        }
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

        $browserCommandLine = ""
        if ($browserProc) {
            $browserInfo = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $browserProc.Id) -ErrorAction SilentlyContinue
            if ($browserInfo) {
                $browserCommandLine = [string]$browserInfo.CommandLine
            }
        }

        $state = [pscustomobject]@{
            Ready = $true
            AttemptId = $AttemptId
            GuestIp = $guestIp
            Browser = $Browser
            BrowserExe = $browserExe
            BrowserUrl = $browserUrl
            BrowserReady = $browserReady
            BrowserReadyProbe = $browserReadyProbe
            BrowserCommandLine = $browserCommandLine
            BrowserProfilePath = $browserProfile
            BrowserDebugLogPath = $browserDebugLog
            BrowserDebugLogTail = if (Test-Path -LiteralPath $browserDebugLog) { Get-Content -LiteralPath $browserDebugLog -Tail 80 | Out-String } else { "" }
            GuestSessionAlive = $true
            GuestSessionTimestampUtc = [DateTime]::UtcNow.ToString("o")
            ControlPanelHwnd = $hwndText
            ControlPanelPid = $panelPidText
            PanelProcessId = if ($panel) { $panel.Id } else { 0 }
            VirtuaCamPid = if ($virtuaCamRuntime) { $virtuaCamRuntime.Id } else { 0 }
            VirtuaCamProcessPid = if ($virtuaCamProcess) { $virtuaCamProcess.Id } else { 0 }
            RuntimeLogPath = $runtimeLog
            ProcessLogPath = $processLog
            RuntimeLogTail = if (Test-Path -LiteralPath $runtimeLog) { Get-Content -LiteralPath $runtimeLog -Encoding Unicode -Tail 60 | Out-String } else { "" }
            ProcessLogTail = if (Test-Path -LiteralPath $processLog) { Get-Content -LiteralPath $processLog -Encoding Unicode -Tail 60 | Out-String } else { "" }
        }
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $guestStatusPath -Encoding UTF8
        $state
    } -ArgumentList $GuestPackageRoot, $GuestWebcamHtml, $Browser, $ServeHttp, $HttpPort, $BrowserExtraArgs, $AttemptId

    $hostState = [ordered]@{}
    foreach ($property in $guestState.PSObject.Properties) {
        $hostState[$property.Name] = $property.Value
    }
    $hostState.HostHoldPid = $PID
    $hostState.HostHeartbeatUtc = [DateTime]::UtcNow.ToString("o")
    $hostState.GuestHeartbeatUtc = $hostState.GuestSessionTimestampUtc
    $hostState.GuestLivenessError = ""
    Write-StatusFile -StatusObject ([pscustomobject]$hostState)

    Write-HvLog -Message ("Guest session held. Status file: {0}" -f $HostStatusPath) -LogPath $LogPath -Level STEP

    $lastProbe = Get-Date
    while (-not (Test-Path -LiteralPath $HostStopSignalPath)) {
        $hostState.HostHeartbeatUtc = [DateTime]::UtcNow.ToString("o")

        if (((Get-Date) - $lastProbe).TotalSeconds -ge 5) {
            try {
                $probe = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
                    param($RequestedBrowser)
                    $browserProcessName = if ($RequestedBrowser -eq "Edge") { "msedge" } else { "chrome" }
                    [pscustomobject]@{
                        Utc = [DateTime]::UtcNow.ToString("o")
                        BrowserAlive = [bool](Get-Process -Name $browserProcessName -ErrorAction SilentlyContinue)
                        VirtuaCamAlive = [bool](Get-Process -Name "VirtuaCam" -ErrorAction SilentlyContinue)
                        VirtuaCamProcessAlive = [bool](Get-Process -Name "VirtuaCamProcess" -ErrorAction SilentlyContinue)
                    }
                } -ArgumentList $Browser
                $hostState.GuestSessionAlive = $true
                $hostState.GuestHeartbeatUtc = $probe.Utc
                $hostState.BrowserAlive = $probe.BrowserAlive
                $hostState.VirtuaCamAlive = $probe.VirtuaCamAlive
                $hostState.VirtuaCamProcessAlive = $probe.VirtuaCamProcessAlive
                $hostState.GuestLivenessError = ""
            }
            catch {
                $hostState.GuestSessionAlive = $false
                $hostState.GuestLivenessError = $_.Exception.Message
                Write-StatusFile -StatusObject ([pscustomobject]$hostState)
                throw
            }
            $lastProbe = Get-Date
        }

        Write-StatusFile -StatusObject ([pscustomobject]$hostState)
        Start-Sleep -Seconds 1
    }
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
