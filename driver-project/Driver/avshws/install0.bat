@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-driver.ps1" %*
pause