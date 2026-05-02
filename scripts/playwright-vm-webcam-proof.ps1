[CmdletBinding()]
param(
    [string]$StatusPath = "output\playwright\vm-session-status.json",
    [string]$ArtifactRoot = "output\playwright",
    [int]$TimeoutSeconds = 90,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

function Write-ProofLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "STEP", "WARN", "ERROR")][string]$Level = "INFO"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff zzz"
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $line
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$artifactDir = Resolve-HvPath -Path $ArtifactRoot
$statusPathResolved = Resolve-HvPath -Path $StatusPath
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "playwright-vm-webcam-proof.log"
}

$resultPath = Join-Path $artifactDir "vm-webcam-proof.json"
$screenshotPath = Join-Path $artifactDir "vm-webcam-proof.png"
$consolePath = Join-Path $artifactDir "vm-webcam-console.log"
$runnerDir = Join-Path $artifactDir ".playwright-proof-runner"
$runnerScriptPath = Join-Path $runnerDir "vm-webcam-proof.cjs"

if (-not (Test-Path -LiteralPath $statusPathResolved)) {
    throw "Status file not found: $statusPathResolved"
}

$status = Read-JsonFile -Path $statusPathResolved
if (-not $status.GuestIp) {
    throw "GuestIp missing in status file: $statusPathResolved"
}

$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $nodeCommand) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $nodeCommand) {
    throw "node is required for Playwright proof runner."
}

$npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npmCommand) {
    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
}
if (-not $npmCommand) {
    throw "npm is required for Playwright proof runner."
}

$null = New-Item -ItemType Directory -Force -Path $runnerDir

if (-not (Test-Path -LiteralPath (Join-Path $runnerDir "node_modules\playwright-core\package.json"))) {
    Write-ProofLog -Message "Bootstrapping playwright-core in runner dir." -Level STEP
    Push-Location $runnerDir
    try {
        $installOutput = & $npmCommand.Source install --no-save playwright-core@latest 2>&1
        $installOutput |
            Where-Object { $_ -ne $null -and "$_".Length -gt 0 } |
            ForEach-Object { Write-ProofLog -Message "$_" }
        if ($LASTEXITCODE -ne 0) {
            throw "npm install playwright-core failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

$runnerScript = @'
const fs = require('fs');
const { chromium } = require('playwright-core');

function readJson(file) {
  const raw = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
  return JSON.parse(raw);
}

function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function appendConsoleLine(lines, line) {
  lines.push(line);
  if (lines.length > 500) {
    lines.shift();
  }
}

function mergeConsoleLines(consoleLines, statusLogs) {
  const merged = [];
  const seen = new Set();
  for (const line of [...statusLogs, ...consoleLines]) {
    if (!line || seen.has(line)) {
      continue;
    }
    seen.add(line);
    merged.push(line);
  }
  return merged;
}

(async () => {
  const statusPath = process.env.STATUS_PATH;
  const resultPath = process.env.RESULT_PATH;
  const screenshotPath = process.env.SCREENSHOT_PATH;
  const consolePath = process.env.CONSOLE_PATH;
  const timeoutMs = parseInt(process.env.TIMEOUT_MS || '90000', 10);
  const status = readJson(statusPath);
  const consoleLines = [];
  const attachBase = `http://${status.GuestIp}:9223`;
  const sourceWindow = {
    SourceWindowMode: status.SourceWindowMode || '',
    SourceWindowProcess: status.SourceWindowProcess || '',
    SourceWindowTitle: status.SourceWindowTitle || '',
    SourceWindowPid: status.SourceWindowPid || '',
    SourceWindowHwnd: status.SourceWindowHwnd || '',
    SourceMarker: status.SourceMarker || ''
  };

  let browser;
  let page;
  let lastState = null;

  function buildResult(data) {
    return Object.assign({
      attachBase,
      browserUrl: status.BrowserUrl,
      guestIp: status.GuestIp
    }, sourceWindow, data);
  }

  function pickPage(pages) {
    const targetUrl = (status.BrowserUrl || '').toLowerCase();
    return pages.find((candidate) => {
      const url = (candidate.url() || '').toLowerCase();
      return (targetUrl && url === targetUrl) || url.includes('webcam.html');
    }) || pages[0] || null;
  }

  async function snapshotState(currentPage) {
    return currentPage.evaluate(() => {
      const video = document.getElementById('webcam');
      const status = window.__webcamStatus || {};
      const logs = Array.isArray(window.__webcamLogs) ? window.__webcamLogs.slice(-200) : [];
      return {
        phase: status.phase || '',
        enumerateCount: status.enumerateCount || 0,
        selectedDeviceLabel: status.selectedDeviceLabel || '',
        selectedDeviceId: status.selectedDeviceId || '',
        trackLabel: status.trackLabel || '',
        trackState: status.trackState || '',
        videoWidth: status.videoWidth || (video ? video.videoWidth : 0) || 0,
        videoHeight: status.videoHeight || (video ? video.videoHeight : 0) || 0,
        errorName: status.errorName || '',
        errorMessage: status.errorMessage || '',
        updatedAt: status.updatedAt || '',
        readyState: video ? video.readyState : -1,
        pageUrl: location.href,
        pageTitle: document.title,
        logs
      };
    });
  }

  try {
    if (!sourceWindow.SourceWindowMode || sourceWindow.SourceWindowMode === 'ProofPanel') {
      const errorMessage = !sourceWindow.SourceWindowMode
        ? 'SourceWindowMode missing from held guest status.'
        : 'ProofPanel source is synthetic and does not qualify as real-window proof.';
      fs.writeFileSync(consolePath, '', 'utf8');
      writeJson(resultPath, buildResult({
        success: false,
        errorClass: 'proof.InvalidSourceWindowMode',
        errorMessage,
        state: lastState,
        consoleLineCount: 0,
        capturedAt: new Date().toISOString()
      }));
      process.exit(1);
    }

    browser = await chromium.connectOverCDP(attachBase);
    const contexts = browser.contexts();
    if (!contexts.length) {
      throw new Error('No Chrome contexts exposed by CDP.');
    }

    const pages = contexts.flatMap((context) => context.pages());
    page = pickPage(pages);
    if (!page) {
      page = await contexts[0].newPage();
    }

    page.on('console', (msg) => appendConsoleLine(consoleLines, `[${msg.type()}] ${msg.text()}`));
    page.on('pageerror', (err) => appendConsoleLine(consoleLines, `[pageerror] ${err.message}`));
    await page.bringToFront();
    await page.goto(status.BrowserUrl, { waitUntil: 'load', timeout: 30000 });
    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(1500);

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      lastState = await snapshotState(page);
      if (lastState.phase === 'live' && lastState.videoWidth > 0 && lastState.videoHeight > 0) {
        await page.screenshot({ path: screenshotPath });
        const mergedLogs = mergeConsoleLines(consoleLines, lastState.logs || []);
        fs.writeFileSync(consolePath, mergedLogs.join('\n'), 'utf8');
        writeJson(resultPath, buildResult({
          success: true,
          errorClass: '',
          screenshotPath,
          state: lastState,
          consoleLineCount: mergedLogs.length,
          capturedAt: new Date().toISOString()
        }));
        await browser.close();
        process.exit(0);
      }
      if (lastState.phase === 'error') {
        break;
      }
      await page.waitForTimeout(1000);
    }

    const mergedLogs = mergeConsoleLines(consoleLines, (lastState && lastState.logs) ? lastState.logs : []);
    fs.writeFileSync(consolePath, mergedLogs.join('\n'), 'utf8');
    const errorClass = lastState && lastState.errorName
      ? `chrome.${lastState.errorName}`
      : 'chrome.NoLiveFrame';
    writeJson(resultPath, buildResult({
      success: false,
      errorClass,
      state: lastState,
      consoleLineCount: mergedLogs.length,
      capturedAt: new Date().toISOString()
    }));
    await browser.close();
    process.exit(1);
  } catch (error) {
    fs.writeFileSync(consolePath, consoleLines.join('\n'), 'utf8');
    writeJson(resultPath, buildResult({
      success: false,
      errorClass: 'playwright.CDPAttachFailed',
      errorMessage: error && error.message ? error.message : String(error),
      state: lastState,
      consoleLineCount: consoleLines.length,
      capturedAt: new Date().toISOString()
    }));
    if (browser) {
      try {
        await browser.close();
      } catch {
      }
    }
    process.exit(2);
  }
})();
'@

$runnerScript | Set-Content -LiteralPath $runnerScriptPath -Encoding ASCII

$oldStatusPath = $env:STATUS_PATH
$oldResultPath = $env:RESULT_PATH
$oldScreenshotPath = $env:SCREENSHOT_PATH
$oldConsolePath = $env:CONSOLE_PATH
$oldTimeoutMs = $env:TIMEOUT_MS
$oldNodePath = $env:NODE_PATH
$env:STATUS_PATH = $statusPathResolved
$env:RESULT_PATH = $resultPath
$env:SCREENSHOT_PATH = $screenshotPath
$env:CONSOLE_PATH = $consolePath
$env:TIMEOUT_MS = [string]($TimeoutSeconds * 1000)
$env:NODE_PATH = Join-Path $runnerDir "node_modules"

try {
    Write-ProofLog -Message ("Attaching to guest Chrome at {0}:9223" -f $status.GuestIp) -Level STEP
    Push-Location $runnerDir
    try {
        & $nodeCommand.Source $runnerScriptPath
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
finally {
    $env:STATUS_PATH = $oldStatusPath
    $env:RESULT_PATH = $oldResultPath
    $env:SCREENSHOT_PATH = $oldScreenshotPath
    $env:CONSOLE_PATH = $oldConsolePath
    $env:TIMEOUT_MS = $oldTimeoutMs
    $env:NODE_PATH = $oldNodePath
}

if (-not (Test-Path -LiteralPath $resultPath)) {
    throw "Proof result file missing: $resultPath"
}

$result = Read-JsonFile -Path $resultPath
$resultSuccessProp = $result.PSObject.Properties["success"]
$resultErrorMessageProp = $result.PSObject.Properties["errorMessage"]
$resultErrorClassProp = $result.PSObject.Properties["errorClass"]
if ($exitCode -ne 0 -or -not ($resultSuccessProp -and $resultSuccessProp.Value)) {
    $message = if ($resultErrorMessageProp -and $resultErrorMessageProp.Value) {
        [string]$resultErrorMessageProp.Value
    } elseif ($resultErrorClassProp -and $resultErrorClassProp.Value) {
        [string]$resultErrorClassProp.Value
    } else {
        "proof failed"
    }
    throw "Playwright proof failed: $message"
}

Write-ProofLog -Message ("Proof screenshot saved: {0}" -f $screenshotPath) -Level STEP
$result
