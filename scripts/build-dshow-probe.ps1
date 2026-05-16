[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Error $Message
    exit 1
}

function Get-VsWherePath {
    $path = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $path) {
        return $path
    }
    return $null
}

function Get-VsDevCmdPath {
    $vswhere = Get-VsWherePath
    if (-not $vswhere) {
        return $null
    }

    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) {
        return $null
    }

    $candidate = Join-Path $installationPath "Common7\Tools\VsDevCmd.bat"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return $null
}

function Quote-CmdPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return '"' + $Path.Replace('"', '\"') + '"'
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
$sourcePath = Join-Path $repoRoot "tools\dshow-probe\dshow_probe.cpp"
$buildDir = Join-Path $repoRoot "tools\dshow-probe\build"
$exePath = Join-Path $buildDir "dshow_probe.exe"
$objPath = Join-Path $buildDir "dshow_probe.obj"

if (-not (Test-Path -LiteralPath $sourcePath)) {
    Fail "Missing DirectShow probe source: $sourcePath"
}

$null = New-Item -ItemType Directory -Force -Path $buildDir

if ((-not $Force) -and (Test-Path -LiteralPath $exePath)) {
    $sourceItem = Get-Item -LiteralPath $sourcePath
    $exeItem = Get-Item -LiteralPath $exePath
    if ($exeItem.LastWriteTimeUtc -ge $sourceItem.LastWriteTimeUtc) {
        Write-Host ("DirectShow probe up to date: {0}" -f $exePath)
        exit 0
    }
}

$vsDevCmd = Get-VsDevCmdPath
if (-not $vsDevCmd) {
    Fail "VsDevCmd.bat not found. Install Visual Studio Build Tools with VC x64 tools."
}

$cmd = @(
    (Quote-CmdPath -Path $vsDevCmd),
    "-arch=x64",
    "-host_arch=x64",
    ">nul",
    "&&",
    "cl.exe",
    "/nologo",
    "/EHsc",
    "/std:c++17",
    "/W4",
    "/O2",
    "/MT",
    ("/Fo" + (Quote-CmdPath -Path $objPath)),
    ("/Fe" + (Quote-CmdPath -Path $exePath)),
    (Quote-CmdPath -Path $sourcePath),
    "strmiids.lib",
    "ole32.lib",
    "oleaut32.lib"
) -join " "

Write-Host ("Building DirectShow probe: {0}" -f $exePath)
& $env:ComSpec /d /c $cmd
if ($LASTEXITCODE -ne 0) {
    Fail "cl.exe failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $exePath)) {
    Fail "DirectShow probe build did not produce: $exePath"
}

Write-Host ("DirectShow probe built: {0}" -f $exePath)
