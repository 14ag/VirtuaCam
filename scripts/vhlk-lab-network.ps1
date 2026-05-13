Set-StrictMode -Version Latest

function Set-VhlkHostsEntryText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Address
    )

    $lines = @()
    foreach ($line in @($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $lines += $line
            continue
        }
        if ($line.TrimStart().StartsWith("#")) {
            $lines += $line
            continue
        }
        $parts = @($line -split "\s+" | Where-Object { $_ })
        if ($parts.Count -ge 2 -and ($parts[1..($parts.Count - 1)] -contains $Name)) {
            continue
        }
        $lines += $line
    }

    $lines += ("{0} {1}" -f $Address, $Name)
    return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

function Ensure-VhlkLabHostNetwork {
    param(
        [Parameter(Mandatory = $true)][string]$VhlkVmName,
        [Parameter(Mandatory = $true)][string]$DutVmName,
        [Parameter(Mandatory = $true)][string]$SwitchName,
        [Parameter(Mandatory = $true)][string]$HostAddress,
        [Parameter(Mandatory = $true)][int]$PrefixLength
    )

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    $createdSwitch = $false
    if (-not $switch) {
        $switch = New-VMSwitch -Name $SwitchName -SwitchType Internal -ErrorAction Stop
        $createdSwitch = $true
    }

    $connected = @()
    foreach ($vmName in @($VhlkVmName, $DutVmName)) {
        $adapter = Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Select-Object -First 1
        if (-not $adapter) {
            throw "VM '$vmName' has no network adapter."
        }
        if ([string]$adapter.SwitchName -ne $SwitchName) {
            Connect-VMNetworkAdapter -VMName $vmName -Name $adapter.Name -SwitchName $SwitchName -ErrorAction Stop
        }
        $connected += [pscustomobject]@{
            VmName = $vmName
            AdapterName = [string]$adapter.Name
            SwitchNameBefore = [string]$adapter.SwitchName
            SwitchNameAfter = $SwitchName
        }
    }

    $hostAdapterName = "vEthernet ($SwitchName)"
    $hostAdapter = Get-NetAdapter -Name $hostAdapterName -ErrorAction Stop
    $existingIp = @(Get-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $HostAddress })
    $addedHostIp = $false
    if ($existingIp.Count -lt 1) {
        New-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -IPAddress $HostAddress -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
        $addedHostIp = $true
    }

    [pscustomobject]@{
        SwitchName = $SwitchName
        SwitchCreated = $createdSwitch
        HostAdapter = $hostAdapterName
        HostAddress = $HostAddress
        HostAddressAdded = $addedHostIp
        ConnectedAdapters = $connected
    }
}

function Set-VhlkGuestLabNetwork {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$PrefixLength,
        [Parameter(Mandatory = $true)][hashtable]$Hosts,
        [string[]]$ServicesToRestart = @("HLKSvc")
    )

    Invoke-Command -Session $Session -ArgumentList @($Address, $PrefixLength, $Hosts, $ServicesToRestart) -ScriptBlock {
        param($Address, $PrefixLength, $Hosts, $ServicesToRestart)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        function Set-HostsEntry {
            param(
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)][string]$IpAddress
            )

            $path = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
            $text = ""
            if (Test-Path -LiteralPath $path) {
                $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            }

            $lines = @()
            foreach ($line in @($text -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    $lines += $line
                    continue
                }
                if ($line.TrimStart().StartsWith("#")) {
                    $lines += $line
                    continue
                }
                $parts = @($line -split "\s+" | Where-Object { $_ })
                if ($parts.Count -ge 2 -and ($parts[1..($parts.Count - 1)] -contains $Name)) {
                    continue
                }
                $lines += $line
            }

            $lines += ("{0} {1}" -f $IpAddress, $Name)
            Set-Content -LiteralPath $path -Value (($lines -join "`r`n").TrimEnd() + "`r`n") -Encoding ASCII -Force
        }

        $adapter = @(Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Loopback" } |
            Sort-Object -Property ifIndex |
            Select-Object -First 1)
        if ($adapter.Count -lt 1) {
            throw "No active guest network adapter found."
        }

        $idx = [int]$adapter[0].ifIndex
        $beforeIp = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty IPAddress)

        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue

        foreach ($old in @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne $Address })) {
            try {
                Remove-NetIPAddress -InterfaceIndex $idx -IPAddress $old.IPAddress -Confirm:$false -ErrorAction Stop
            }
            catch {
            }
        }

        $existing = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $Address })
        $added = $false
        if ($existing.Count -lt 1) {
            New-NetIPAddress -InterfaceIndex $idx -IPAddress $Address -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
            $added = $true
        }

        try {
            Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Private -ErrorAction Stop
        }
        catch {
        }

        foreach ($key in @($Hosts.Keys)) {
            Set-HostsEntry -Name ([string]$key) -IpAddress ([string]$Hosts[$key])
        }

        $serviceStates = @()
        foreach ($name in @($ServicesToRestart)) {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $svc) {
                $serviceStates += [pscustomobject]@{ Name = $name; Status = "Missing"; Restarted = $false }
                continue
            }
            $restarted = $false
            try {
                if ($svc.Status -eq "Running") {
                    Restart-Service -Name $name -Force -ErrorAction Stop
                    $restarted = $true
                }
                else {
                    Start-Service -Name $name -ErrorAction Stop
                }
                Start-Sleep -Seconds 2
            }
            catch {
            }
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            $serviceStates += [pscustomobject]@{
                Name = $name
                Status = if ($svc) { [string]$svc.Status } else { "Missing" }
                Restarted = $restarted
            }
        }

        $afterIp = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty IPAddress)

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            AdapterName = [string]$adapter[0].Name
            InterfaceIndex = $idx
            Address = $Address
            AddressAdded = $added
            IPv4Before = $beforeIp
            IPv4After = $afterIp
            Services = $serviceStates
        }
    }
}

function Test-VhlkGuestTcp {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [int]$Port = 1771
    )

    Invoke-Command -Session $Session -ArgumentList @($ComputerName, $Port) -ScriptBlock {
        param($ComputerName, $Port)
        $result = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue
        [pscustomobject]@{
            Source = $env:COMPUTERNAME
            Target = $ComputerName
            Port = $Port
            TcpTestSucceeded = [bool]$result.TcpTestSucceeded
            RemoteAddress = if ($result.RemoteAddress) { [string]$result.RemoteAddress } else { "" }
        }
    }
}

function Repair-VhlkLabNetwork {
    param(
        [Parameter(Mandatory = $true)][string]$VhlkVmName,
        [Parameter(Mandatory = $true)][string]$DutVmName,
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$VhlkSession,
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$DutSession,
        [Parameter(Mandatory = $true)][string]$DutComputerName,
        [string]$SwitchName = "hlk-lab",
        [string]$HostAddress = "192.168.240.1",
        [string]$ControllerAddress = "192.168.240.10",
        [string]$DutAddress = "192.168.240.20",
        [int]$PrefixLength = 24
    )

    $hostState = Ensure-VhlkLabHostNetwork -VhlkVmName $VhlkVmName -DutVmName $DutVmName -SwitchName $SwitchName -HostAddress $HostAddress -PrefixLength $PrefixLength

    $controllerName = Invoke-Command -Session $VhlkSession -ScriptBlock { $env:COMPUTERNAME }
    $controllerHosts = @{}
    $controllerHosts[$DutComputerName] = $DutAddress
    $dutHosts = @{}
    $dutHosts[[string]$controllerName] = $ControllerAddress

    $controller = Set-VhlkGuestLabNetwork -Session $VhlkSession -Address $ControllerAddress -PrefixLength $PrefixLength -Hosts $controllerHosts -ServicesToRestart @("HLKSvc", "WTTChangeScheduler", "WTTServer", "DTMSERVICE")
    $dut = Set-VhlkGuestLabNetwork -Session $DutSession -Address $DutAddress -PrefixLength $PrefixLength -Hosts $dutHosts -ServicesToRestart @("HLKSvc")

    Start-Sleep -Seconds 5

    $dutToController = Test-VhlkGuestTcp -Session $DutSession -ComputerName ([string]$controllerName) -Port 1771
    $controllerToDut = Test-VhlkGuestTcp -Session $VhlkSession -ComputerName $DutComputerName -Port 1771

    [pscustomobject]@{
        SwitchName = $SwitchName
        ControllerName = [string]$controllerName
        DutComputerName = $DutComputerName
        Host = $hostState
        Controller = $controller
        Dut = $dut
        Connectivity = @($dutToController, $controllerToDut)
        CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
}
