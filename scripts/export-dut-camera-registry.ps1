[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$ArtifactRoot = "",
    [int]$TimeoutSeconds = 300,
    [switch]$FreshStart,
    [string]$CheckpointName = "clean"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path $repoRoot ("test-reports\dut-camera-registry-{0}" -f (Get-HvTimestamp))
} else {
    Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot
}
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "export-dut-camera-registry.log"
$exitCode = 1
$session = $null

try {
    $guestCred = Get-HvGuestCredential `
        -GuestUser "Administrator" `
        -EnvUserKey "DRIVER_TEST_VM_USERNAME" `
        -EnvPasswordKey "DRIVER_TEST_VM_PASSWORD"

    if ($FreshStart) {
        Write-HvLog -Message ("Fresh-starting DUT '{0}' from checkpoint '{1}' before registry export." -f $VmName, $CheckpointName) -LogPath $logPath -Level STEP
        $freshStart = Start-HvFreshCheckpointVm `
            -VmName $VmName `
            -CheckpointName $CheckpointName `
            -Credential $guestCred `
            -RequireInteractiveSession `
            -ReadyTimeoutSeconds $TimeoutSeconds `
            -LogPath $logPath
        $freshStart | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-fresh-start.json") -Encoding UTF8
    } else {
        Wait-HvVmReady -VmName $VmName -Credential $guestCred -TimeoutSeconds $TimeoutSeconds -PollIntervalSeconds 3 -RequireInteractiveSession -ReadyThresholdSeconds 30 -LogPath $logPath | Out-Null
    }

    $session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -TimeoutSeconds $TimeoutSeconds -LogPath $logPath

    $state = Invoke-HvGuestCommand -Session $session -LogPath $logPath -ScriptBlock {
        function Convert-RegistryKeyToObject {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [int]$Depth = 4
            )

            if (-not (Test-Path -LiteralPath $Path)) {
                return [pscustomobject]@{
                    Path = $Path
                    Exists = $false
                    Values = @()
                    Children = @()
                }
            }

            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            $valueEntries = @()
            foreach ($name in $item.GetValueNames()) {
                $rawValue = $item.GetValue($name)
                $valueEntries += [pscustomobject]@{
                    Name = if ([string]::IsNullOrEmpty($name)) { "(Default)" } else { $name }
                    Kind = [string]$item.GetValueKind($name)
                    Value = if ($null -eq $rawValue) { $null } else { [string]$rawValue }
                }
            }

            $childEntries = @()
            if ($Depth -gt 0) {
                foreach ($child in @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue | Sort-Object PSChildName)) {
                    $childEntries += Convert-RegistryKeyToObject -Path $child.PSPath -Depth ($Depth - 1)
                }
            }

            [pscustomobject]@{
                Path = $Path
                Name = $item.PSChildName
                Exists = $true
                Values = @($valueEntries)
                Children = @($childEntries)
            }
        }

        function Get-DeviceClassKey {
            param([Parameter(Mandatory = $true)][string]$ClassGuid)
            $path = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceClasses\$ClassGuid"
            Convert-RegistryKeyToObject -Path $path -Depth 7
        }

        $videoCameraClass = "{E5323777-F976-4F5B-9B55-B94699C46E44}"
        $captureClass = "{65E8773D-8F56-11D0-A3B9-00A0C9223196}"
        $deviceInstance = "ROOT\AVSHWS\0000"
        $driverStoreMatches = @()
        $driverStoreRoot = Join-Path $env:SystemRoot "System32\DriverStore\FileRepository"
        if (Test-Path -LiteralPath $driverStoreRoot) {
            $driverStoreMatches = @(Get-ChildItem -LiteralPath $driverStoreRoot -Directory -Filter "avshws.inf_*" -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    FullName = $_.FullName
                    InfPath = Join-Path $_.FullName "avshws.inf"
                    HasInf = Test-Path -LiteralPath (Join-Path $_.FullName "avshws.inf")
                    LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString("o")
                }
            })
        }

        $deviceKeyPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\ROOT\AVSHWS\0000"
        $softwareKeyPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Media Foundation\Platform"
        $wowSoftwareKeyPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows Media Foundation\Platform"

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
            DeviceInstance = $deviceInstance
            PnpDevice = @(pnputil /enum-devices /instanceid $deviceInstance 2>&1 | ForEach-Object { [string]$_ })
            PnpDrivers = @(pnputil /enum-drivers 2>&1 | Where-Object { $_ -match "avshws|Virtual Camera" } | ForEach-Object { [string]$_ })
            DriverStoreMatches = @($driverStoreMatches)
            DeviceEnumKey = Convert-RegistryKeyToObject -Path $deviceKeyPath -Depth 5
            VideoCameraDeviceClass = Get-DeviceClassKey -ClassGuid $videoCameraClass
            CaptureDeviceClass = Get-DeviceClassKey -ClassGuid $captureClass
            MediaFoundationPlatform = Convert-RegistryKeyToObject -Path $softwareKeyPath -Depth 1
            MediaFoundationPlatformWow6432 = Convert-RegistryKeyToObject -Path $wowSoftwareKeyPath -Depth 1
        }
    }

    $jsonPath = Join-Path $artifactDir "dut-camera-registry.json"
    $state | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Host ("DUT camera registry exported. Artifact: {0}" -f $jsonPath)
    $exitCode = 0
}
catch {
    $errorPath = Join-Path $artifactDir "error.txt"
    $_ | Out-String | Set-Content -LiteralPath $errorPath -Encoding UTF8
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Artifacts: {0}" -f $artifactDir) -ForegroundColor Yellow
    $exitCode = 1
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

exit $exitCode
