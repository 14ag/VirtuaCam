#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$serviceName = "VirtuaCamWatcher"

& sc.exe query $serviceName *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Service not found: $serviceName"
    exit 0
}

& sc.exe stop $serviceName | Out-Host
Start-Sleep -Seconds 1
& sc.exe delete $serviceName | Out-Host

Write-Host "OK"

