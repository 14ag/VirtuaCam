icacls "%~dp0DirectPortClient.dll" /grant "LOCAL SERVICE":(RX)
icacls "%~dp0DirectPortClient.dll" /grant "ALL APPLICATION PACKAGES":(RX)
regsvr32 "%~dp0DirectPortClient.dll"
pause