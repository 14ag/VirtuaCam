[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail { param([string]$Message) Write-Host $Message -ForegroundColor Red; exit 1 }

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
$OutputRoot = Join-Path $repoRoot "output"

$resolvedRepoRoot = (Resolve-Path -LiteralPath $repoRoot).Path.TrimEnd("\\/")
$resolvedOutputRoot = $OutputRoot
if (Test-Path -LiteralPath $resolvedOutputRoot) {
    $resolvedOutputRoot = (Resolve-Path -LiteralPath $resolvedOutputRoot).Path
}

if (-not ($resolvedOutputRoot.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
    Fail "Refuse to delete OutputRoot outside repo. OutputRoot='$resolvedOutputRoot' RepoRoot='$resolvedRepoRoot'"
}

if (Test-Path -LiteralPath $OutputRoot) {
    if ($PSCmdlet.ShouldProcess($OutputRoot, "Remove output directory")) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}

Write-Host "Cleaned: $OutputRoot"
