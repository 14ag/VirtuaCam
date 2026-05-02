[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [string]$HostPublicKeyPath = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Resolve-HvPath -Path "output\hyperv-enable-ssh.log"
}

if ([string]::IsNullOrWhiteSpace($HostPublicKeyPath)) {
    $HostPublicKeyPath = Join-Path $env:USERPROFILE ".ssh\driver-test-ed25519.pub"
}

if (-not (Test-Path -LiteralPath $HostPublicKeyPath)) {
    Fail-Hv -Message "Host public key missing: $HostPublicKeyPath" -LogPath $LogPath
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$publicKey = (Get-Content -LiteralPath $HostPublicKeyPath -Raw).Trim()

Write-HvLog -Message ("Configuring OpenSSH in guest '{0}'" -f $VmName) -LogPath $LogPath -Level STEP
$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath

try {
    $result = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        param($KeyText)

        function Get-OpenSshCapability {
            $capability = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
            if (-not $capability) {
                throw "OpenSSH.Server capability not found."
            }
            return $capability
        }

        function Ensure-OpenSshCapabilityInstalled {
            $capability = Get-OpenSshCapability
            if ($capability.State -ne "Installed") {
                Add-WindowsCapability -Online -Name $capability.Name | Out-Null
                $capability = Get-OpenSshCapability
            }
            return $capability
        }

        function Test-SshdListenerReady {
            return (@(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue).Count -gt 0)
        }

        function Get-SystemOpenSshDir {
            return (Join-Path $env:WINDIR "System32\OpenSSH")
        }

        function Get-SystemInstallSshdScript {
            return (Join-Path (Get-SystemOpenSshDir) "install-sshd.ps1")
        }

        function Get-SystemHostKeyGen {
            return (Join-Path (Get-SystemOpenSshDir) "ssh-keygen.exe")
        }

        function Get-SshdImagePath {
            $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\sshd"
            if (-not (Test-Path -LiteralPath $serviceKey)) {
                return ""
            }
            return [string](Get-ItemProperty -LiteralPath $serviceKey -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
        }

        function Repair-SshdServiceRegistration {
            $installSshd = Get-SystemInstallSshdScript
            $systemSshdExe = Join-Path (Get-SystemOpenSshDir) "sshd.exe"
            if (-not (Test-Path -LiteralPath $systemSshdExe)) {
                throw "System OpenSSH sshd.exe missing: $systemSshdExe"
            }

            Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
            if (Get-Service -Name ssh-agent -ErrorAction SilentlyContinue) {
                Stop-Service -Name ssh-agent -Force -ErrorAction SilentlyContinue
            }
            Get-Process sshd, ssh-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

            if (Test-Path -LiteralPath $installSshd) {
                & sc.exe delete sshd | Out-Null
                if (Get-Service -Name ssh-agent -ErrorAction SilentlyContinue) {
                    & sc.exe delete ssh-agent | Out-Null
                }
                Start-Sleep -Seconds 2
                & powershell.exe -ExecutionPolicy Bypass -File $installSshd | Out-Null
                return
            }

            if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
                & sc.exe create sshd binPath= "`"$systemSshdExe`"" start= auto DisplayName= "OpenSSH SSH Server" obj= LocalSystem | Out-Null
            }
            else {
                & sc.exe config sshd binPath= "`"$systemSshdExe`"" start= auto obj= LocalSystem | Out-Null
            }
        }

        function Set-SshdDirective {
            param(
                [Parameter(Mandatory = $true)][ref]$LinesRef,
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)][string]$Value
            )

            $pattern = '^(?i)\s*#?\s*' + [regex]::Escape($Name) + '\b.*$'
            $replacement = "$Name $Value"
            $found = $false
            $updated = New-Object System.Collections.Generic.List[string]

            foreach ($line in @($LinesRef.Value)) {
                if ($line -match $pattern) {
                    if (-not $found) {
                        $updated.Add($replacement)
                        $found = $true
                    }
                    continue
                }
                $updated.Add($line)
            }

            if (-not $found) {
                $updated.Add($replacement)
            }

            $LinesRef.Value = $updated.ToArray()
        }

        function Write-PermissiveSshdConfig {
            param([Parameter(Mandatory = $true)][string]$ConfigPath)

            $lines = if (Test-Path -LiteralPath $ConfigPath) {
                @(Get-Content -LiteralPath $ConfigPath -ErrorAction SilentlyContinue)
            }
            else {
                @()
            }

            Set-SshdDirective -LinesRef ([ref]$lines) -Name "SyslogFacility" -Value "LOCAL0"
            Set-SshdDirective -LinesRef ([ref]$lines) -Name "LogLevel" -Value "VERBOSE"
            Set-SshdDirective -LinesRef ([ref]$lines) -Name "StrictModes" -Value "no"
            Set-SshdDirective -LinesRef ([ref]$lines) -Name "PubkeyAuthentication" -Value "yes"
            Set-SshdDirective -LinesRef ([ref]$lines) -Name "AuthorizedKeysFile" -Value ".ssh/authorized_keys"
            Set-SshdDirective -LinesRef ([ref]$lines) -Name "PasswordAuthentication" -Value "yes"
            Set-SshdDirective -LinesRef ([ref]$lines) -Name "PermitEmptyPasswords" -Value "no"

            Set-Content -LiteralPath $ConfigPath -Encoding Ascii -Value $lines
        }

        function Ensure-SshdInstalledFiles {
            $openSshDir = Get-SystemOpenSshDir
            $installSshd = Get-SystemInstallSshdScript
            $hostKeyGen = Get-SystemHostKeyGen
            if (Test-Path -LiteralPath $hostKeyGen) {
                & $hostKeyGen -A | Out-Null
            }

            if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath $installSshd) {
                    & powershell.exe -ExecutionPolicy Bypass -File $installSshd | Out-Null
                }
            }

            if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
                $winget = (Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
                if ($winget) {
                    & $winget install --id Microsoft.OpenSSH.Preview --exact --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
                    $previewRoots = @(
                        "C:\Program Files\OpenSSH",
                        "C:\Program Files\OpenSSH-Win64"
                    )

                    foreach ($previewRoot in $previewRoots) {
                        $previewInstall = Join-Path $previewRoot "install-sshd.ps1"
                        if (Test-Path -LiteralPath $previewInstall) {
                            & powershell.exe -ExecutionPolicy Bypass -File $previewInstall | Out-Null
                            break
                        }
                    }
                }
            }

            if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
                throw "OpenSSH capability present but sshd service still missing."
            }

            $expectedBinary = Join-Path $openSshDir "sshd.exe"
            $imagePath = Get-SshdImagePath
            if ([string]::IsNullOrWhiteSpace($imagePath) -or
                $imagePath.IndexOf($expectedBinary, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                Repair-SshdServiceRegistration
                $imagePath = Get-SshdImagePath
            }

            if ([string]::IsNullOrWhiteSpace($imagePath) -or
                $imagePath.IndexOf($expectedBinary, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw "sshd service image path is not using system OpenSSH binary: $imagePath"
            }
        }

        function Repair-OpenSshServerCapability {
            $capability = Get-OpenSshCapability
            if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
                Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
            }
            Remove-WindowsCapability -Online -Name $capability.Name | Out-Null
            $capability = Ensure-OpenSshCapabilityInstalled
            Ensure-SshdInstalledFiles
        }

        $capability = Ensure-OpenSshCapabilityInstalled

        Ensure-SshdInstalledFiles

        $sshdConfig = "C:\ProgramData\ssh\sshd_config"
        $adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
        $sshDir = Split-Path -Parent $adminKeys

        $null = New-Item -ItemType Directory -Force -Path $sshDir
        [System.IO.File]::WriteAllText($adminKeys, $KeyText + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
        Write-PermissiveSshdConfig -ConfigPath $sshdConfig

        & icacls.exe $adminKeys /inheritance:r | Out-Null
        & icacls.exe $adminKeys /grant "Administrators:F" "SYSTEM:F" | Out-Null

        Set-Service -Name sshd -StartupType Automatic
        Start-Service -Name sshd
        Start-Sleep -Seconds 2

        $repairApplied = $false
        if (-not (Test-SshdListenerReady)) {
            $repairApplied = $true
            Repair-OpenSshServerCapability
            Write-PermissiveSshdConfig -ConfigPath $sshdConfig
            Set-Service -Name sshd -StartupType Automatic
            Start-Service -Name sshd
            Start-Sleep -Seconds 2
        }

        if (Get-Service -Name ssh-agent -ErrorAction SilentlyContinue) {
            Set-Service -Name ssh-agent -StartupType Manual
            Start-Service -Name ssh-agent
        }

        $fw = Get-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" -ErrorAction SilentlyContinue
        if (-not $fw) {
            New-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 | Out-Null
        } else {
            Enable-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" | Out-Null
        }

        New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -PropertyType String -Value "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Force | Out-Null

        if (-not (Test-SshdListenerReady)) {
            throw "sshd service is running but port 22 is not listening after repair."
        }

        $guestIp = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
            Sort-Object InterfaceMetric |
            Select-Object -First 1 -ExpandProperty IPAddress)

        [pscustomobject]@{
            CapabilityState = (Get-OpenSshCapability | Select-Object -ExpandProperty State)
            SshdStatus = (Get-Service sshd | Select-Object Status, StartType)
            ListenerCount = @(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue).Count
            RepairApplied = $repairApplied
            GuestIp = $guestIp
            SshdConfigPath = $sshdConfig
            AdminKeysPath = $adminKeys
        }
    } -ArgumentList $publicKey

    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Resolve-HvPath -Path "output\hyperv-enable-ssh.json") -Encoding UTF8
    $result
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
