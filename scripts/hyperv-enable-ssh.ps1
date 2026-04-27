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

        $capability = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
        if (-not $capability) {
            throw "OpenSSH.Server capability not found."
        }

        if ($capability.State -ne "Installed") {
            Add-WindowsCapability -Online -Name $capability.Name | Out-Null
        }

        $openSshDir = "C:\Windows\System32\OpenSSH"
        $installSshd = Join-Path $openSshDir "install-sshd.ps1"
        $hostKeyGen = Join-Path $openSshDir "ssh-keygen.exe"
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

        $sshdConfig = "C:\ProgramData\ssh\sshd_config"
        $adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
        $sshDir = Split-Path -Parent $adminKeys

        $null = New-Item -ItemType Directory -Force -Path $sshDir
        [System.IO.File]::WriteAllText($adminKeys, $KeyText + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

        & icacls.exe $adminKeys /inheritance:r | Out-Null
        & icacls.exe $adminKeys /grant "Administrators:F" "SYSTEM:F" | Out-Null

        Set-Service -Name sshd -StartupType Automatic
        Start-Service -Name sshd

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

        $guestIp = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
            Sort-Object InterfaceMetric |
            Select-Object -First 1 -ExpandProperty IPAddress)

        [pscustomobject]@{
            CapabilityState = (Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*" | Select-Object -ExpandProperty State)
            SshdStatus = (Get-Service sshd | Select-Object Status, StartType)
            GuestIp = $guestIp
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
