[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string]$DutVmName = "driver-test",
    [string]$ProjectName = "VirtuaCam",
    [string]$PlaylistPath = "C:\Users\Administrator\Desktop\Compat Playlists\HLK Version 2004 CompatPlaylist x86 x64 ARM64.xml",
    [int]$TestLimit = 3,
    [int]$TimeoutMinutes = 5,
    [int]$MonitorIntervalSeconds = 5,
    [int]$PendingStartTimeoutSeconds = 90,
    [string]$TestNamePattern = "",
    [int]$MaxHeartbeatAgeMinutes = 10,
    [string]$LabSwitchName = "hlk-lab",
    [string]$LabHostIp = "192.168.240.1",
    [string]$LabControllerIp = "192.168.240.10",
    [string]$LabDutIp = "192.168.240.20",
    [switch]$NoReloadPlaylist,
    [switch]$NoCleanResults,
    [switch]$NoSetDutReady,
    [switch]$AllowStaleDutHeartbeat,
    [switch]$SkipLabNetworkRepair,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")
. (Join-Path $scriptDir "vhlk-lab-network.ps1")

Assert-HvAdministrator

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing .env file: $Path"
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') {
            continue
        }

        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $map[$parts[0].Trim()] = $parts[1].Trim()
        }
    }

    return $map
}

function New-CredentialFromEnv {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EnvMap,
        [Parameter(Mandatory = $true)][string]$UserKey,
        [Parameter(Mandatory = $true)][string]$PasswordKey
    )

    $user = [string]$EnvMap[$UserKey]
    $password = [string]$EnvMap[$PasswordKey]
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password)) {
        throw "Missing $UserKey or $PasswordKey in .env"
    }

    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    return [System.Management.Automation.PSCredential]::new($user, $secure)
}

function Write-LiveLine {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )

    $isRedirected = $false
    try {
        $isRedirected = [Console]::IsOutputRedirected
    }
    catch {
        $isRedirected = $true
    }

    if ($isRedirected) {
        Write-Host $Message -ForegroundColor $Color
        return
    }

    try {
        $width = [Math]::Max(40, [Console]::BufferWidth - 1)
    }
    catch {
        $width = 120
    }

    if ($Message.Length -gt $width) {
        $Message = $Message.Substring(0, $width - 3) + "..."
    }

    Write-Host ("`r{0}" -f $Message.PadRight($width)) -NoNewline -ForegroundColor $Color
}

function Write-DoneLine {
    Write-Host ""
}

function Invoke-Vhlk {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
}

$artifactDir = Join-Path $repoRoot ("test-reports\vhlk-smoke-3tests-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "hyperv.log"
$transcriptPath = Join-Path $artifactDir "runner-transcript.log"
$vhlkSession = $null
$dutSession = $null
$exitCode = 1

Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
try {
    if ($TestLimit -lt 1) {
        throw "TestLimit must be at least 1."
    }
    if ($TimeoutMinutes -lt 1) {
        throw "TimeoutMinutes must be at least 1."
    }
    if ($MaxHeartbeatAgeMinutes -lt 1) {
        throw "MaxHeartbeatAgeMinutes must be at least 1."
    }

    $envMap = Read-DotEnv -Path (Join-Path $repoRoot ".env")
    $vhlkCred = New-CredentialFromEnv -EnvMap $envMap -UserKey "vhlk_VM_USERNAME" -PasswordKey "vhlk_VM_PASSWORD"
    $dutCred = New-CredentialFromEnv -EnvMap $envMap -UserKey "DRIVER_TEST_VM_USERNAME" -PasswordKey "DRIVER_TEST_VM_PASSWORD"

    Write-Host "[1/7] start/check VMs" -ForegroundColor Cyan
    Wait-HvVmReady -VmName $VhlkVmName -Credential $vhlkCred -TimeoutSeconds 240 -PollIntervalSeconds 3 -RequirePowerShellDirect -LogPath $logPath | Out-Null
    Wait-HvVmReady -VmName $DutVmName -Credential $dutCred -TimeoutSeconds 240 -PollIntervalSeconds 3 -RequirePowerShellDirect -LogPath $logPath | Out-Null

    Write-Host "[2/7] connect to controller + DUT" -ForegroundColor Cyan
    $vhlkSession = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $vhlkCred -TimeoutSeconds 240 -LogPath $logPath 6>$null
    $dutSession = Wait-HvPowerShellDirect -VmName $DutVmName -Credential $dutCred -TimeoutSeconds 240 -LogPath $logPath 6>$null

    Write-Host "[3/7] check DUT HLK client service" -ForegroundColor Cyan
    $dutState = Invoke-HvGuestCommand -Session $dutSession -LogPath $logPath -ScriptBlock {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        $service = Get-Service -Name "HLKSvc" -ErrorAction SilentlyContinue
        $startAttempted = $false
        if ($service -and $service.Status -ne "Running") {
            Start-Service -Name "HLKSvc"
            $startAttempted = $true
            Start-Sleep -Seconds 3
            $service = Get-Service -Name "HLKSvc" -ErrorAction SilentlyContinue
        }

        $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
            Select-Object -ExpandProperty IPAddress)

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            HlkSvcFound = [bool]$service
            HlkSvcStatus = if ($service) { [string]$service.Status } else { "" }
            HlkSvcStartAttempted = $startAttempted
            IPv4 = $ip
            CheckedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    }

    if (-not $dutState.HlkSvcFound) {
        throw "DUT HLKSvc not found. Install HLK client in VM '$DutVmName'."
    }
    if ([string]$dutState.HlkSvcStatus -ne "Running") {
        throw "DUT HLKSvc is not running after start attempt."
    }

    $dutComputerName = [string]$dutState.ComputerName
    Write-Host ("    DUT computer: {0}; HLKSvc={1}" -f $dutComputerName, $dutState.HlkSvcStatus) -ForegroundColor Green

    if (-not $SkipLabNetworkRepair) {
        Write-Host "[4/7] repair vHLK lab network" -ForegroundColor Cyan
        $labNetwork = Repair-VhlkLabNetwork `
            -VhlkVmName $VhlkVmName `
            -DutVmName $DutVmName `
            -VhlkSession $vhlkSession `
            -DutSession $dutSession `
            -DutComputerName $dutComputerName `
            -SwitchName $LabSwitchName `
            -HostAddress $LabHostIp `
            -ControllerAddress $LabControllerIp `
            -DutAddress $LabDutIp
        $labNetwork | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifactDir "lab-network.json") -Encoding UTF8
        $badLinks = @($labNetwork.Connectivity | Where-Object { -not $_.TcpTestSucceeded })
        if ($badLinks.Count -gt 0) {
            throw "vHLK lab network connectivity is not ready. See lab-network.json."
        }
        Write-Host ("    Lab IPs ready: controller={0}; DUT={1}" -f $LabControllerIp, $LabDutIp) -ForegroundColor Green
    }

    $remoteReadiness = {
        param($ProjectName, $DutComputerName, $SetDutReady)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        function Import-HlkObjectModel {
            $root = "C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Controller"
            Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dll")
            Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dbconnection.dll")
        }

        function Get-AllMachineObjects {
            param($Pool)

            $items = @()
            foreach ($m in @($Pool.GetMachines())) {
                $items += $m
            }

            foreach ($child in @($Pool.GetChildPools())) {
                foreach ($item in @(Get-AllMachineObjects -Pool $child)) {
                    $items += $item
                }
            }

            return @($items)
        }

        function Convert-MachineInfo {
            param($Machine)

            $heartbeat = $Machine.LastHeartbeat
            $ageMinutes = $null
            if ($heartbeat) {
                $ageMinutes = [Math]::Round(((Get-Date) - $heartbeat).TotalMinutes, 2)
            }

            [pscustomobject]@{
                Name = [string]$Machine.Name
                Status = [string]$Machine.Status
                Pool = [string]$Machine.Pool.Path
                LastHeartbeat = if ($heartbeat) { $heartbeat.ToString("s") } else { "" }
                HeartbeatAgeMinutes = $ageMinutes
            }
        }

        function Get-ServiceState {
            param([string[]]$Names)

            foreach ($name in $Names) {
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                if (-not $svc) {
                    [pscustomobject]@{ Name = $name; Status = "Missing"; StartAttempted = $false }
                    continue
                }

                $startAttempted = $false
                if ($svc.Status -ne "Running") {
                    try {
                        Start-Service -Name $name -ErrorAction Stop
                        $startAttempted = $true
                        Start-Sleep -Seconds 2
                        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                    }
                    catch {
                        [pscustomobject]@{ Name = $name; Status = "StartFailed: $($_.Exception.Message)"; StartAttempted = $true }
                        continue
                    }
                }

                [pscustomobject]@{ Name = $name; Status = [string]$svc.Status; StartAttempted = $startAttempted }
            }
        }

        Import-HlkObjectModel
        $pm = [Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager]::new($env:COMPUTERNAME)
        $project = $pm.GetProject($ProjectName)
        if (-not $project) {
            throw "HLK project not found: $ProjectName"
        }

        $services = @(Get-ServiceState -Names @("MSSQLSERVER", "WTTChangeScheduler", "WTTServer", "HLKSvc", "DTMSERVICE"))
        $badServices = @($services | Where-Object { [string]$_.Status -ne "Running" })
        $machineObjects = @(Get-AllMachineObjects -Pool ($pm.GetRootMachinePool()))
        $matches = @($machineObjects | Where-Object {
            ([string]$_.Name) -eq $DutComputerName -or ([string]$_.Name).StartsWith($DutComputerName + "#")
        } | Sort-Object LastHeartbeat -Descending)

        if ($matches.Count -lt 1) {
            throw "DUT '$DutComputerName' not found in HLK controller machine inventory."
        }

        $dut = @($matches | Where-Object { ([string]$_.Name) -eq $DutComputerName } | Select-Object -First 1)
        if ($dut.Count -lt 1) {
            $dut = @($matches | Select-Object -First 1)
        }
        $dut = $dut[0]
        $dutBefore = Convert-MachineInfo -Machine $dut
        $dutPoolIsRootOrDefault = $dut.Pool.Equals($dut.Pool.RootPool) -or $dut.Pool.Equals($dut.Pool.DefaultPool)

        $setReadyResult = $null
        $setReadyAttempts = 0
        if ($SetDutReady -and -not $dutPoolIsRootOrDefault) {
            $ready = [Microsoft.Windows.Kits.Hardware.ObjectModel.MachineStatus]::Ready
            $readyDeadline = (Get-Date).AddSeconds(120)
            do {
                $setReadyAttempts++
                try {
                    $setReadyResult = $dut.SetMachineStatus($ready, 600000)
                    if ($setReadyResult -eq $true -or [string]$setReadyResult -eq "True") {
                        break
                    }
                }
                catch {
                    $setReadyResult = "ERROR: $($_.Exception.Message)"
                }

                Start-Sleep -Seconds 5
                $refreshed = @(Get-AllMachineObjects -Pool ($pm.GetRootMachinePool()) | Where-Object {
                    ([string]$_.Name) -eq ([string]$dut.Name)
                } | Select-Object -First 1)
                if ($refreshed.Count -gt 0) {
                    $dut = $refreshed[0]
                }
            } while ((Get-Date) -lt $readyDeadline)
        }
        elseif ($SetDutReady) {
            $setReadyResult = "SKIP: DUT is in root/default pool"
        }

        $machineAfter = @(Get-AllMachineObjects -Pool ($pm.GetRootMachinePool()) | Where-Object {
            ([string]$_.Name) -eq ([string]$dut.Name)
        } | Select-Object -First 1)

        $tests = @($project.GetTests())
        [pscustomobject]@{
            Controller = $env:COMPUTERNAME
            Project = $ProjectName
            DutComputerName = $DutComputerName
            ControllerServices = $services
            BadControllerServices = $badServices
            DutMachineBefore = $dutBefore
            SetReadyAttempted = [bool]$SetDutReady
            SetReadyAttempts = $setReadyAttempts
            SetReadyResult = $setReadyResult
            DutPoolIsRootOrDefault = [bool]$dutPoolIsRootOrDefault
            DutMachineAfter = if ($machineAfter.Count -gt 0) {
                Convert-MachineInfo -Machine $machineAfter[0]
            } else { $null }
            MatchingMachines = @($matches | ForEach-Object {
                Convert-MachineInfo -Machine $_
            })
            TestCount = $tests.Count
            CheckedAt = (Get-Date).ToString("s")
        }
    }

    Write-Host "[5/7] check controller services + HLK machine state" -ForegroundColor Cyan
    $readiness = Invoke-Vhlk -Session $vhlkSession -ScriptBlock $remoteReadiness -ArgumentList @(
        $ProjectName,
        $dutComputerName,
        (-not [bool]$NoSetDutReady))
    $readiness | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "readiness.json") -Encoding UTF8

    if (@($readiness.BadControllerServices).Count -gt 0) {
        throw "One or more controller services are not Running. See readiness.json."
    }
    if ($readiness.TestCount -lt 1) {
        throw "HLK project has no tests."
    }
    if ($readiness.DutPoolIsRootOrDefault) {
        throw ("DUT machine is in root/default pool ({0}). Move it to a non-default child pool before scheduling tests." -f $readiness.DutMachineBefore.Pool)
    }
    if ($readiness.SetReadyAttempted -and ([string]$readiness.SetReadyResult).StartsWith("ERROR:")) {
        throw ("DUT machine could not be set Ready on controller: {0}" -f $readiness.SetReadyResult)
    }

    $machineStatus = if ($readiness.DutMachineAfter) { [string]$readiness.DutMachineAfter.Status } else { [string]$readiness.DutMachineBefore.Status }
    $machineHeartbeatAge = if ($readiness.DutMachineAfter) { $readiness.DutMachineAfter.HeartbeatAgeMinutes } else { $readiness.DutMachineBefore.HeartbeatAgeMinutes }
    if ($machineStatus -notin @("Ready", "Running")) {
        throw ("DUT machine is not schedulable. Status={0}. See readiness.json." -f $machineStatus)
    }
    if ((-not [bool]$AllowStaleDutHeartbeat) -and $null -ne $machineHeartbeatAge -and [double]$machineHeartbeatAge -gt $MaxHeartbeatAgeMinutes) {
        throw ("DUT HLK heartbeat is stale: {0} minutes old. Controller is not seeing current HLKSvc heartbeat." -f $machineHeartbeatAge)
    }
    Write-Host ("    Controller={0}; DUT machine status={1}; tests={2}" -f $readiness.Controller, $machineStatus, $readiness.TestCount) -ForegroundColor Green

    $remoteQueue = {
        param($ProjectName, $PlaylistPath, $ReloadPlaylist, $CleanResults, $DryRun, $TestLimit, $TestNamePattern, $DutComputerName)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        $root = "C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Controller"
        Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dll")
        Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dbconnection.dll")

        $pm = [Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager]::new($env:COMPUTERNAME)
        $project = $pm.GetProject($ProjectName)
        if (-not $project) {
            throw "HLK project not found: $ProjectName"
        }

        $loadedPlaylistIds = @()
        if ($ReloadPlaylist) {
            if (-not (Test-Path -LiteralPath $PlaylistPath)) {
                throw "Playlist not found on controller: $PlaylistPath"
            }

            $playlistManager = [Microsoft.Windows.Kits.Hardware.ObjectModel.PlaylistManager]::new($project)
            if ($playlistManager.IsPlaylistLoaded()) {
                $playlistManager.UnloadPlaylist()
            }
            $loadedPlaylistIds = @($playlistManager.LoadPlaylist($PlaylistPath))
        }

        function Get-HlkMachineByName {
            param($Pool, [string]$Name)
            foreach ($machine in @($Pool.GetMachines())) {
                if ([string]$machine.Name -eq $Name) {
                    return $machine
                }
            }
            foreach ($child in @($Pool.GetChildPools())) {
                $found = Get-HlkMachineByName -Pool $child -Name $Name
                if ($found) {
                    return $found
                }
            }
            return $null
        }

        $dutMachine = Get-HlkMachineByName -Pool ($pm.GetRootMachinePool()) -Name $DutComputerName
        if (-not $dutMachine) {
            throw "DUT '$DutComputerName' not found in controller machine inventory."
        }
        if ([string]$dutMachine.Status -notin @("Ready", "Running")) {
            throw "DUT '$DutComputerName' is not schedulable. Status=$($dutMachine.Status)."
        }

        $tests = @($project.GetTests() | Sort-Object Name)
        if (-not [string]::IsNullOrWhiteSpace($TestNamePattern)) {
            if ($TestNamePattern.IndexOfAny([char[]]"*?[]") -ge 0) {
                $tests = @($tests | Where-Object { [string]$_.Name -like $TestNamePattern })
            }
            else {
                $escapedPattern = [regex]::Escape($TestNamePattern)
                $tests = @($tests | Where-Object { [string]$_.Name -match $escapedPattern })
            }
        }
        $selected = @($tests | Select-Object -First $TestLimit)
        if ($selected.Count -lt 1) {
            throw "No tests selected for smoke run."
        }

        $activeCancelled = 0
        $activeCancelErrors = @()
        if (-not $DryRun) {
            foreach ($test in @($project.GetTests())) {
                foreach ($result in @($test.GetTestResults())) {
                    if ([string]$result.Status -in @("InQueue", "Running")) {
                        try {
                            $result.Cancel()
                            $activeCancelled++
                        }
                        catch {
                            $activeCancelErrors += "Cancel active failed: $($test.Name): $($_.Exception.Message)"
                        }
                    }
                }
            }
        }

        $cancelled = 0
        $deleted = 0
        $deleteErrors = @()
        if ($CleanResults -and -not $DryRun) {
            foreach ($test in @($project.GetTests())) {
                foreach ($result in @($test.GetTestResults())) {
                    try {
                        $test.DeleteTestResult($result)
                        $deleted++
                    }
                    catch {
                        $deleteErrors += "Delete failed: $($test.Name): $($_.Exception.Message)"
                    }
                }
            }
        }

        $queued = @()
        $queueErrors = @()
        if (-not $DryRun) {
            $machineList = New-Object 'System.Collections.Generic.List[Microsoft.Windows.Kits.Hardware.ObjectModel.Machine]'
            $machineList.Add($dutMachine) | Out-Null
            foreach ($test in $selected) {
                try {
                    $queued += @($test.QueueTest($machineList))
                }
                catch {
                    $queueErrors += "Queue failed: $($test.Name): $($_.Exception.Message)"
                }
            }
        }

        [pscustomobject]@{
            Controller = $env:COMPUTERNAME
            Project = $ProjectName
            Playlist = $PlaylistPath
            ReloadPlaylist = [bool]$ReloadPlaylist
            LoadedPlaylistIds = $loadedPlaylistIds.Count
            CleanResults = [bool]$CleanResults
            ActiveCancelledResults = $activeCancelled
            ActiveCancelErrors = $activeCancelErrors
            CancelledResults = $cancelled
            DeletedResults = $deleted
            DeleteErrors = $deleteErrors
            DryRun = [bool]$DryRun
            TestLimit = $TestLimit
            TestNamePattern = $TestNamePattern
            DutComputerName = $DutComputerName
            QueueMode = "DirectToDutMachine"
            SelectedTests = @($selected | ForEach-Object { [string]$_.Name })
            QueuedResults = $queued.Count
            QueueErrors = $queueErrors
            StartedAt = (Get-Date).ToString("s")
        }
    }

    Write-Host "[6/7] queue 3-test smoke set" -ForegroundColor Cyan
    $queue = Invoke-Vhlk -Session $vhlkSession -ScriptBlock $remoteQueue -ArgumentList @(
        $ProjectName,
        $PlaylistPath,
        (-not [bool]$NoReloadPlaylist),
        (-not [bool]$NoCleanResults),
        [bool]$DryRun,
        $TestLimit,
        $TestNamePattern,
        $dutComputerName)
    $queue | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "queue-result.json") -Encoding UTF8

    if (@($queue.QueueErrors).Count -gt 0) {
        throw "At least one smoke test failed to queue. See queue-result.json."
    }
    $fatalActiveCancelErrors = @($queue.ActiveCancelErrors | Where-Object {
        [string]$_ -notmatch "Job cannot be cancelled in\s+'PD'\s+pipeline"
    })
    if ($fatalActiveCancelErrors.Count -gt 0) {
        throw "At least one active queued/running result failed to cancel. See queue-result.json."
    }
    if (@($queue.ActiveCancelErrors).Count -gt 0) {
        Write-Host "[WARN] HLK refused to cancel a result already in the PD pipeline; selected smoke tests were still queued and monitoring will continue." -ForegroundColor Yellow
    }

    Write-Host "    Selected tests:" -ForegroundColor Green
    foreach ($name in @($queue.SelectedTests)) {
        Write-Host ("      - {0}" -f $name)
    }

    if ($DryRun) {
        Write-Host ("Dry run OK. ArtifactDir: {0}" -f $artifactDir) -ForegroundColor Green
        $exitCode = 0
        return
    }

    $remoteStatus = {
        param($ProjectName, $SelectedTests)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        $root = "C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Controller"
        Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dll")
        Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dbconnection.dll")

        $pm = [Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager]::new($env:COMPUTERNAME)
        $project = $pm.GetProject($ProjectName)
        if (-not $project) {
            throw "HLK project not found: $ProjectName"
        }

        $selectedNames = @($SelectedTests | ForEach-Object { [string]$_ })
        $tests = @($project.GetTests() | Where-Object { $selectedNames -contains ([string]$_.Name) })

        $groups = @($tests | Group-Object { "{0},{1}" -f $_.Status, $_.ExecutionState } | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Count = $_.Count }
        })

        $passed = @($tests | Where-Object { [string]$_.Status -eq "Passed" }).Count
        $failed = @($tests | Where-Object { [string]$_.Status -eq "Failed" }).Count
        $running = @($tests | Where-Object { [string]$_.ExecutionState -eq "Running" })
        $inQueue = @($tests | Where-Object { [string]$_.ExecutionState -eq "InQueue" }).Count
        $notRun = @($tests | Where-Object { [string]$_.Status -eq "NotRun" }).Count
        $completed = @($tests | Where-Object {
            [string]$_.Status -in @("Passed", "Failed", "Canceled", "Cancelled", "Blocked", "NotApplicable")
        }).Count

        $current = $running | Select-Object -First 1
        $details = @($tests | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                Status = [string]$_.Status
                ExecutionState = [string]$_.ExecutionState
            }
        })

        [pscustomobject]@{
            CheckedAt = (Get-Date).ToString("s")
            Total = $tests.Count
            Completed = $completed
            Passed = $passed
            Failed = $failed
            InQueue = $inQueue
            NotRun = $notRun
            RunningCount = $running.Count
            CurrentName = if ($current) { [string]$current.Name } else { "" }
            CurrentStatus = if ($current) { [string]$current.Status } else { "" }
            CurrentState = if ($current) { [string]$current.ExecutionState } else { "" }
            Groups = $groups
            Details = $details
            FailedTestNames = @($details | Where-Object { [string]$_.Status -eq "Failed" } | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
        }
    }

    Write-Host "[7/7] monitor smoke run for 5 minutes" -ForegroundColor Cyan
    $history = New-Object System.Collections.Generic.List[object]
    $start = Get-Date
    $deadline = $start.AddMinutes($TimeoutMinutes)
    $lastAnyStarted = $null
    $lastStatus = $null
    $tick = 0
    $spinner = @("|", "/", "-", "\")

    while ((Get-Date) -lt $deadline) {
        $tick++
        $status = $null
        $statusFresh = $true
        $statusPollError = ""
        try {
            $status = Invoke-Vhlk -Session $vhlkSession -ScriptBlock $remoteStatus -ArgumentList @($ProjectName, @($queue.SelectedTests))
        }
        catch {
            $statusFresh = $false
            $statusPollError = $_.Exception.Message
            Write-DoneLine
            Write-HvLog -Message ("Remote status poll failed; using last known status. {0}" -f $statusPollError) -LogPath $logPath -Level WARN
            try {
                if ($vhlkSession) {
                    Remove-PSSession -Session $vhlkSession -ErrorAction SilentlyContinue
                }
                $vhlkSession = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $vhlkCred -TimeoutSeconds 60 -LogPath $logPath 6>$null
            }
            catch {
                Write-HvLog -Message ("Controller session reopen failed; will retry. {0}" -f $_.Exception.Message) -LogPath $logPath -Level WARN
            }
        }

        if ($null -eq $status) {
            if ($lastStatus) {
                $status = $lastStatus
            } else {
                Start-Sleep -Seconds ([Math]::Max(1, $MonitorIntervalSeconds))
                continue
            }
        }
        Add-Member -InputObject $status -NotePropertyName StatusFresh -NotePropertyValue $statusFresh -Force
        Add-Member -InputObject $status -NotePropertyName StatusPollError -NotePropertyValue $statusPollError -Force
        $history.Add($status) | Out-Null
        $lastStatus = $status
        $status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "latest-status.json") -Encoding UTF8
        if ($status.FailedTestNames) {
            @($status.FailedTestNames) | Set-Content -LiteralPath (Join-Path $artifactDir "failed-test-names.txt") -Encoding UTF8
        }

        if ($status.RunningCount -gt 0 -or $status.Passed -gt 0 -or $status.Failed -gt 0) {
            if (-not $lastAnyStarted) {
                $lastAnyStarted = Get-Date
            }
        }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
        $glyph = $spinner[$tick % $spinner.Count]
        $currentIndex = if ($status.RunningCount -gt 0) { [Math]::Min($status.Total, $status.Completed + 1) } else { $status.Completed }
        $label = if ($status.RunningCount -gt 0) {
            "running: {0}" -f $status.CurrentName
        } elseif ($status.InQueue -gt 0) {
            "waiting scheduler ({0} queued)" -f $status.InQueue
        } else {
            "no active test"
        }
        $groupText = [string]::Join("; ", @($status.Groups | ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }))
        $line = "{0} t+{1}s rem={2}s [{3}/{4}] {5} pass={6} fail={7} notrun={8} groups={9}" -f $glyph, $elapsed, $remaining, $currentIndex, $status.Total, $label, $status.Passed, $status.Failed, $status.NotRun, $groupText
        $color = if ($status.Failed -gt 0) { [ConsoleColor]::Red } elseif ($status.RunningCount -gt 0 -or $status.Passed -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-LiveLine -Message $line -Color $color

        if (($tick % 6) -eq 0) {
            Write-DoneLine
            Write-Host ("    alive tick={0}; latest={1}" -f $tick, $status.CheckedAt) -ForegroundColor DarkCyan
        }

        if ($status.Total -gt 0 -and $status.Completed -ge $status.Total) {
            Write-DoneLine
            if ($status.Failed -eq 0) {
                Write-Host "[OK] Smoke tests completed without failed status." -ForegroundColor Green
                $exitCode = 0
            } else {
                Write-Host ("[FAIL] Smoke tests completed with {0} failed." -f $status.Failed) -ForegroundColor Red
                $exitCode = 2
            }
            break
        }

        if ($PendingStartTimeoutSeconds -gt 0 -and -not $lastAnyStarted -and $status.InQueue -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $PendingStartTimeoutSeconds) {
            Write-DoneLine
            Write-Host ("[TIMEOUT] Smoke tests stayed pending for {0} seconds. Cancelling queued results." -f $PendingStartTimeoutSeconds) -ForegroundColor Red
            Invoke-Vhlk -Session $vhlkSession -ScriptBlock {
                param($ProjectName, $SelectedTests)
                Set-StrictMode -Version Latest
                $ErrorActionPreference = "Continue"
                $root = "C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Controller"
                Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dll")
                Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dbconnection.dll")
                $pm = [Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager]::new($env:COMPUTERNAME)
                $project = $pm.GetProject($ProjectName)
                $selectedNames = @($SelectedTests | ForEach-Object { [string]$_ })
                foreach ($test in @($project.GetTests() | Where-Object { $selectedNames -contains ([string]$_.Name) })) {
                    foreach ($result in @($test.GetTestResults())) {
                        if ([string]$result.Status -in @("InQueue", "Running")) {
                            try { $result.Cancel() } catch {}
                        }
                    }
                }
            } -ArgumentList @($ProjectName, @($queue.SelectedTests)) | Out-Null
            $exitCode = 3
            break
        }

        Start-Sleep -Seconds ([Math]::Max(1, $MonitorIntervalSeconds))
    }

    if (-not $lastStatus) {
        throw "No status received from controller."
    }

    if ($exitCode -eq 1) {
        Write-DoneLine
        if (-not $lastAnyStarted) {
            Write-Host ("[TIMEOUT] No selected smoke test started within {0} minutes." -f $TimeoutMinutes) -ForegroundColor Red
        } else {
            Write-Host ("[TIMEOUT] Smoke monitor reached {0} minutes before completion." -f $TimeoutMinutes) -ForegroundColor Yellow
        }
    }

    $summary = [pscustomobject]@{
        ArtifactDir = $artifactDir
        StartedAt = $start.ToString("s")
        CompletedAt = (Get-Date).ToString("s")
        TimeoutMinutes = $TimeoutMinutes
        Readiness = $readiness
        InitialQueue = $queue
        FinalStatus = $lastStatus
        History = $history
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifactDir "monitor-summary.json") -Encoding UTF8
}
catch {
    Write-DoneLine
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    $errorPath = Join-Path $artifactDir "error.txt"
    Set-Content -LiteralPath $errorPath -Value ($_ | Out-String) -Encoding UTF8
    $exitCode = 1
}
finally {
    if ($vhlkSession) {
        Remove-PSSession -Session $vhlkSession -ErrorAction SilentlyContinue
    }
    if ($dutSession) {
        Remove-PSSession -Session $dutSession -ErrorAction SilentlyContinue
    }
    Stop-Transcript | Out-Null
    Write-Host ("Artifacts: {0}" -f $artifactDir)
}

exit $exitCode
