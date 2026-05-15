[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$SkipPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Read-TestNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "List not found: $Path"
    }

    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    )
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))

$resolvedInput = Resolve-RepoPath -Path $InputPath -BasePath $repoRoot
$resolvedSkip = Resolve-RepoPath -Path $SkipPath -BasePath $repoRoot
$resolvedOutput = Resolve-RepoPath -Path $OutputPath -BasePath $repoRoot

$inputNames = @(Read-TestNames -Path $resolvedInput)
$skipNames = @(Read-TestNames -Path $resolvedSkip)
$skipSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $skipNames) {
    [void]$skipSet.Add($name)
}

$filtered = @($inputNames | Where-Object { -not $skipSet.Contains($_) })
$outputDir = Split-Path -Parent $resolvedOutput
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$filtered | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8

[pscustomobject]@{
    InputPath = $resolvedInput
    SkipPath = $resolvedSkip
    OutputPath = $resolvedOutput
    InputCount = $inputNames.Count
    SkipCount = $skipNames.Count
    OutputCount = $filtered.Count
    Skipped = @($inputNames | Where-Object { $skipSet.Contains($_) })
} | ConvertTo-Json -Depth 4
