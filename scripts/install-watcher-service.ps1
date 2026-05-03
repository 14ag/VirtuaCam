#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$serviceName = "VirtuaCamWatcher"
$regPath = "HKLM:\SOFTWARE\VirtuaCam"

function Get-ProcessExeFromRegistry {
    if (-not (Test-Path -LiteralPath $regPath)) { return $null }
    try {
        $v = (Get-ItemProperty -LiteralPath $regPath -Name "ProcessExe" -ErrorAction Stop).ProcessExe
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        return [string]$v
    } catch {
        return $null
    }
}

$processExe = Get-ProcessExeFromRegistry
if (-not $processExe) {
    throw "Missing HKLM\\SOFTWARE\\VirtuaCam\\ProcessExe. Run install-all.ps1 first or set it manually."
}
if (-not (Test-Path -LiteralPath $processExe)) {
    throw "Process exe not found: $processExe"
}

$binPath = "`"$processExe`" --service"

& sc.exe query $serviceName *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Service exists: $serviceName. Updating config..."
    & sc.exe config $serviceName binPath= $binPath start= auto | Out-Host
} else {
    Write-Host "Creating service: $serviceName"
    & sc.exe create $serviceName binPath= $binPath start= auto DisplayName= "VirtuaCam Watcher" | Out-Host
}

& sc.exe description $serviceName "Starts VirtuaCam UI on first virtual camera access." | Out-Host
& sc.exe start $serviceName | Out-Host

Write-Host "OK. Optional: remove HKCU Run keys VirtuaCam/VirtuaCamProcess if you no longer want login startup."

