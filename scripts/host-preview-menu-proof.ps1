param(
    [string]$ArtifactRoot = "test-reports\host-preview-menu",
    [int]$TimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runDir = Join-Path (Join-Path $repoRoot $ArtifactRoot) (Get-Date -Format "yyyyMMdd-HHmmss")
$packageDir = Join-Path $runDir "package"
$summaryPath = Join-Path $runDir "host-preview-menu-proof.json"
$null = New-Item -ItemType Directory -Force -Path $packageDir
Copy-Item -Path (Join-Path $repoRoot "output\*") -Destination $packageDir -Recurse -Force

$source = @"
using System;
using System.Runtime.InteropServices;

public static class VirtuaCamPreviewProofNative
{
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);

    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, UInt32 msg, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

if (-not ("VirtuaCamPreviewProofNative" -as [type])) {
    Add-Type -TypeDefinition $source
}

$summary = [ordered]@{
    Success = $false
    RunDir = $runDir
    MainHwnd = 0
    PreviewHwnd = 0
    PreviewVisible = $false
    Error = ""
    CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}

$app = $null
try {
    Get-Process -Name VirtuaCam,VirtuaCamProcess -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $exe = Join-Path $packageDir "VirtuaCam.exe"
    $app = Start-Process -FilePath $exe -ArgumentList @("-debug", "--source-consumer") -WorkingDirectory $packageDir -PassThru

    $hwndMessage = [IntPtr]::new(-3)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $mainHwnd = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline -and $mainHwnd -eq [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 200
        $mainHwnd = [VirtuaCamPreviewProofNative]::FindWindowEx($hwndMessage, [IntPtr]::Zero, "VIRTUACAM", "VirtuaCam Message Window")
        if ($mainHwnd -eq [IntPtr]::Zero) {
            $mainHwnd = [VirtuaCamPreviewProofNative]::FindWindowEx($hwndMessage, [IntPtr]::Zero, "VIRTUACAM", $null)
        }
    }
    if ($mainHwnd -eq [IntPtr]::Zero) {
        throw "VirtuaCam message window not found."
    }

    $summary.MainHwnd = $mainHwnd.ToInt64()
    $posted = [VirtuaCamPreviewProofNative]::PostMessage($mainHwnd, 0x8002, [UIntPtr]::new([uint32]5001), [IntPtr]::Zero)
    if (-not $posted) {
        throw "PostMessage(WM_APP_MENU_COMMAND, ID_TRAY_PREVIEW_WINDOW) failed."
    }

    $previewHwnd = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline -and $previewHwnd -eq [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 200
        $previewHwnd = [VirtuaCamPreviewProofNative]::FindWindow("VirtuaCamPreviewClass", "VirtuaCam Preview")
    }
    if ($previewHwnd -eq [IntPtr]::Zero) {
        throw "Preview window not created."
    }

    [void][VirtuaCamPreviewProofNative]::SetForegroundWindow($previewHwnd)
    Start-Sleep -Milliseconds 500
    $summary.PreviewHwnd = $previewHwnd.ToInt64()
    $summary.PreviewVisible = [VirtuaCamPreviewProofNative]::IsWindowVisible($previewHwnd)
    if (-not $summary.PreviewVisible) {
        throw "Preview window exists but is not visible."
    }

    $summary.Success = $true
}
catch {
    $summary.Error = $_.Exception.Message
}
finally {
    if ($app -and -not $app.HasExited) {
        Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name VirtuaCam,VirtuaCamProcess -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$packageDir*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $summary.CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
}

$summary | ConvertTo-Json -Depth 5
if (-not $summary.Success) {
    exit 1
}
