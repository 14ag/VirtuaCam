param(
    [string]$ArtifactRoot = "test-reports\host-webcam-html",
    [int]$TimeoutSeconds = 60,
    [int]$Port = 8765
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runDir = Join-Path (Join-Path $repoRoot $ArtifactRoot) (Get-Date -Format "yyyyMMdd-HHmmss")
$packageDir = Join-Path $runDir "package"
$runnerDir = Join-Path $runDir ".playwright-html-runner"
$summaryPath = Join-Path $runDir "host-webcam-html-proof.json"
$screenshotPath = Join-Path $runDir "host-webcam-html.png"
$consolePath = Join-Path $runDir "host-webcam-html-console.log"
$nodeScriptPath = Join-Path $runnerDir "host-webcam-html-proof.cjs"
$hwndPath = Join-Path $runDir "source-window.hwnd.txt"
$pidPath = Join-Path $runDir "source-window.pid.txt"
$attemptId = "host-html-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$marker = "VIRTUACAM HTML SMOKE | attempt=$attemptId | utc=$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))"

$null = New-Item -ItemType Directory -Force -Path $packageDir, $runnerDir
Copy-Item -Path (Join-Path $repoRoot "output\*") -Destination $packageDir -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "software-project\webcam.html") -Destination (Join-Path $runDir "webcam.html") -Force

$summary = [ordered]@{
    Success = $false
    RunDir = $runDir
    Url = "http://127.0.0.1:$Port/webcam.html"
    CaptureBackend = "wgc"
    SourceHwnd = 0
    SourcePid = 0
    BrowserResult = $null
    Error = ""
    CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

$serverProc = $null
$panelProc = $null
$appProc = $null

try {
    Get-Process -Name VirtuaCam,VirtuaCamProcess,chrome,msedge -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$packageDir*" -or $_.ProcessName -in @("VirtuaCam","VirtuaCamProcess") } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $panelArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "show-proof-panel.ps1"),
        "-HwndPath", $hwndPath,
        "-PidPath", $pidPath,
        "-AttemptId", $attemptId,
        "-MarkerText", $marker
    )
    $panelProc = Start-Process -FilePath "powershell.exe" -ArgumentList $panelArgs -PassThru

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $hwndPath)) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $hwndPath)) {
        throw "Proof source window did not publish hwnd."
    }
    $sourceHwnd = [Int64](Get-Content -LiteralPath $hwndPath -Raw).Trim()
    $sourcePid = [Int32](Get-Content -LiteralPath $pidPath -Raw).Trim()
    $summary.SourceHwnd = $sourceHwnd
    $summary.SourcePid = $sourcePid

    $env:VIRTUACAM_CAPTURE_BACKEND = "wgc"
    $env:VIRTUACAM_ATTEMPT_ID = $attemptId
    $appProc = Start-Process -FilePath (Join-Path $packageDir "VirtuaCam.exe") `
        -ArgumentList @("-debug", "--source-window-hwnd", "$sourceHwnd") `
        -WorkingDirectory $packageDir `
        -PassThru `
        -WindowStyle Hidden
    Start-Sleep -Seconds 4

    $serverProc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "serve-webcam.ps1"), "-Root", $runDir, "-Port", "$Port") `
        -RedirectStandardOutput (Join-Path $runDir "serve-webcam.stdout.log") `
        -RedirectStandardError (Join-Path $runDir "serve-webcam.stderr.log") `
        -PassThru `
        -WindowStyle Hidden

    $serverReady = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and -not $serverReady) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri $summary.Url -TimeoutSec 2
            $serverReady = ($r.StatusCode -eq 200)
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    if (-not $serverReady) {
        throw "webcam.html server did not start on port $Port."
    }

    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npm) { throw "npm is required for host HTML proof." }

    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $node) { throw "node is required for host HTML proof." }

    if (-not (Test-Path -LiteralPath (Join-Path $runnerDir "node_modules\playwright-core\package.json"))) {
        Push-Location $runnerDir
        try {
            & $npm.Source install --no-save playwright-core@latest | Out-File -LiteralPath (Join-Path $runDir "npm-install.log") -Encoding UTF8
            if ($LASTEXITCODE -ne 0) {
                throw "npm install playwright-core failed with exit code $LASTEXITCODE"
            }
        }
        finally {
            Pop-Location
        }
    }

    $nodeScript = @'
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
  ].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate));
}

(async () => {
  const url = process.env.PROOF_URL;
  const resultPath = process.env.RESULT_PATH;
  const screenshotPath = process.env.SCREENSHOT_PATH;
  const consolePath = process.env.CONSOLE_PATH;
  const profileDir = process.env.PROFILE_DIR;
  const timeoutMs = parseInt(process.env.TIMEOUT_MS || '60000', 10);
  const chrome = findChrome();
  const consoleLines = [];
  let context;
  let result = {
    success: false,
    url,
    chrome,
    state: null,
    stats: null,
    error: ''
  };

  try {
    if (!chrome) {
      throw new Error('Chrome or Edge executable not found.');
    }

    context = await chromium.launchPersistentContext(profileDir, {
      executablePath: chrome,
      headless: false,
      viewport: { width: 1280, height: 900 },
      args: [
        '--use-fake-ui-for-media-stream',
        '--force-directshow',
        '--autoplay-policy=no-user-gesture-required',
        '--no-first-run',
        '--disable-features=HardwareMediaKeyHandling'
      ]
    });

    await context.grantPermissions(['camera'], { origin: new URL(url).origin });
    const page = await context.newPage();
    page.on('console', (msg) => consoleLines.push(`[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', (err) => consoleLines.push(`[pageerror] ${err.message}`));
    await page.goto(url, { waitUntil: 'load', timeout: 30000 });

    const deadline = Date.now() + timeoutMs;
    let state = null;
    while (Date.now() < deadline) {
      state = await page.evaluate(() => {
        const video = document.getElementById('webcam');
        const status = window.__webcamStatus || {};
        return {
          phase: status.phase || '',
          enumerateCount: status.enumerateCount || 0,
          selectedDeviceLabel: status.selectedDeviceLabel || '',
          selectedDeviceId: status.selectedDeviceId || '',
          trackLabel: status.trackLabel || '',
          trackState: status.trackState || '',
          videoWidth: status.videoWidth || (video ? video.videoWidth : 0) || 0,
          videoHeight: status.videoHeight || (video ? video.videoHeight : 0) || 0,
          readyState: video ? video.readyState : -1,
          errorName: status.errorName || '',
          errorMessage: status.errorMessage || '',
          logs: Array.isArray(window.__webcamLogs) ? window.__webcamLogs.slice(-80) : []
        };
      });
      if (state.phase === 'live' && state.videoWidth > 0 && state.videoHeight > 0) {
        break;
      }
      if (state.phase === 'error') {
        break;
      }
      await page.waitForTimeout(500);
    }

    await page.screenshot({ path: screenshotPath, fullPage: true });

    const stats = await page.evaluate(() => {
      const video = document.getElementById('webcam');
      if (!video || video.videoWidth <= 0 || video.videoHeight <= 0) {
        return null;
      }
      const w = 160;
      const h = 90;
      const canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(video, 0, 0, w, h);
      const data = ctx.getImageData(0, 0, w, h).data;
      let nonDark = 0;
      let bright = 0;
      for (let i = 0; i < data.length; i += 4) {
        const r = data[i];
        const g = data[i + 1];
        const b = data[i + 2];
        const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        if (luma > 24) nonDark++;
        if (luma > 120) bright++;
      }
      const pixels = w * h;
      return {
        width: video.videoWidth,
        height: video.videoHeight,
        nonDarkRatio: Number((nonDark / pixels).toFixed(6)),
        brightRatio: Number((bright / pixels).toFixed(6))
      };
    });

    const label = `${state ? state.trackLabel : ''} ${state ? state.selectedDeviceLabel : ''}`;
    const virtualLabel = /virtuacam|virtual camera|avshws/i.test(label);
    result.state = state;
    result.stats = stats;
    result.success = !!(
      state &&
      state.phase === 'live' &&
      state.trackState === 'live' &&
      state.videoWidth === 1280 &&
      state.videoHeight === 720 &&
      virtualLabel &&
      stats &&
      stats.nonDarkRatio > 0.05
    );
    if (!result.success) {
      result.error = `HTML smoke failed: phase=${state ? state.phase : ''}; track=${label}; dims=${state ? `${state.videoWidth}x${state.videoHeight}` : ''}; nonDark=${stats ? stats.nonDarkRatio : 'n/a'}`;
    }
  } catch (err) {
    result.error = err && err.message ? err.message : String(err);
  } finally {
    fs.writeFileSync(consolePath, consoleLines.join('\n'), 'utf8');
    writeJson(resultPath, result);
    if (context) {
      await context.close().catch(() => {});
    }
  }

  process.exit(result.success ? 0 : 1);
})();
'@
    Set-Content -LiteralPath $nodeScriptPath -Value $nodeScript -Encoding UTF8

    $env:PROOF_URL = $summary.Url
    $env:RESULT_PATH = Join-Path $runDir "browser-result.json"
    $env:SCREENSHOT_PATH = $screenshotPath
    $env:CONSOLE_PATH = $consolePath
    $env:PROFILE_DIR = Join-Path $runDir "chrome-profile"
    $env:TIMEOUT_MS = [string]($TimeoutSeconds * 1000)

    & $node.Source $nodeScriptPath
    $browserResult = Get-Content -LiteralPath $env:RESULT_PATH -Raw | ConvertFrom-Json
    $summary.BrowserResult = $browserResult
    $summary.Success = [bool]$browserResult.success
    if (-not $summary.Success) {
        $summary.Error = [string]$browserResult.error
    }
}
catch {
    $summary.Error = $_.Exception.Message
}
finally {
    if ($serverProc -and -not $serverProc.HasExited) { Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue }
    if ($appProc -and -not $appProc.HasExited) { Stop-Process -Id $appProc.Id -Force -ErrorAction SilentlyContinue }
    if ($panelProc -and -not $panelProc.HasExited) { Stop-Process -Id $panelProc.Id -Force -ErrorAction SilentlyContinue }
    Get-Process -Name VirtuaCam,VirtuaCamProcess -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$packageDir*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $summary.CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
}

$summary | ConvertTo-Json -Depth 20
if (-not $summary.Success) {
    exit 1
}
