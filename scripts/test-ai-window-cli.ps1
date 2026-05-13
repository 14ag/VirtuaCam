[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$appCpp = Join-Path $repoRoot "software-project\src\VirtuaCam\App.cpp"
$uiHeader = Join-Path $repoRoot "software-project\src\VirtuaCam\UI.h"

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing file: $Path"
    }
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -notmatch $Pattern) {
        throw $Message
    }
}

Assert-Contains -Path $appCpp -Pattern 'HasArg\(cmdLine,\s*L"--windows"\)' -Message "VirtuaCam.exe must expose --windows."
Assert-Contains -Path $appCpp -Pattern 'PrintCapturableWindowsJson' -Message "--windows must use headless JSON output."
Assert-Contains -Path $appCpp -Pattern 'WriteStdoutText' -Message "--windows must write to stdout for automation."
Assert-Contains -Path $appCpp -Pattern 'GetWindowThreadProcessId' -Message "--windows output must include PID for AI tooling."
Assert-Contains -Path $appCpp -Pattern 'JsonEscape' -Message "--windows output must escape JSON titles."
Assert-Contains -Path $uiHeader -Pattern 'std::vector<CapturableWindow>\s+EnumerateWindows\(\)' -Message "Capturable window enumeration must be reusable outside the tray menu."

$exePath = Join-Path $repoRoot "output\VirtuaCam.exe"
if (Test-Path -LiteralPath $exePath) {
    $stdoutPath = Join-Path $env:TEMP "virtuacam-ai-windows-stdout.json"
    $stderrPath = Join-Path $env:TEMP "virtuacam-ai-windows-stderr.txt"
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $exePath -ArgumentList "--windows" -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0) {
        throw "VirtuaCam.exe --windows failed with exit code $($proc.ExitCode)."
    }
    $jsonText = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        throw "VirtuaCam.exe --windows produced no stdout."
    }
    $json = $jsonText | ConvertFrom-Json
    foreach ($item in @($json)) {
        if ($null -eq $item.hwnd -or $null -eq $item.pid -or $null -eq $item.title) {
            throw "VirtuaCam.exe --windows returned an item without hwnd, pid, and title."
        }
    }
}

Write-Host "AI window CLI whitebox checks passed."
