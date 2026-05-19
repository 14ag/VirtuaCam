[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string]$DutVmName = "driver-test",
    [string]$DutCheckpointName = "clean",
    [string]$ProjectName = "VirtuaCam",
    [string]$PlaylistPath = "C:\Users\Administrator\Desktop\Compat Playlists\HLK Version 2004 CompatPlaylist x86 x64 ARM64.xml",
    [int]$MonitorIntervalSeconds = 15,
    [int]$NoStartTimeoutMinutes = 3,
    [int]$PendingStartTimeoutSeconds = 90,
    [int]$TimeoutMinutes = 0,
    [int]$MaxHeartbeatAgeMinutes = 10,
    [int]$MaxControllerReconnectFailures = 5,
    [int]$ResearchGateFailureCount = 0,
    [int]$StopOnFailureCount = 0,
    [string]$TestNameListPath = "",
    [string]$LabSwitchName = "hlk-lab",
    [string]$LabHostIp = "192.168.240.1",
    [string]$LabControllerIp = "192.168.240.10",
    [string]$LabDutIp = "192.168.240.20",
    [switch]$NoCleanResults,
    [switch]$NoReloadPlaylist,
    [switch]$NoSetDutReady,
    [switch]$SkipLabNetworkRepair,
    [switch]$SkipFreshStart,
    [switch]$SkipDutInstall,
    [switch]$StopOnFirstFailure,
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

    return [System.Management.Automation.PSCredential]::new(
        $user,
        (New-HvSecureString -PlainText $password))
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

    $padded = $Message.PadRight($width)
    Write-Host ("`r{0}" -f $padded) -NoNewline -ForegroundColor $Color
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

$artifactDir = Join-Path $repoRoot ("test-reports\vhlk-oneclick-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "hyperv.log"
$transcriptPath = Join-Path $artifactDir "runner-transcript.log"
$session = $null
$dutSession = $null

Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
try {
    $envMap = Read-DotEnv -Path (Join-Path $repoRoot ".env")
    $cred = New-CredentialFromEnv -EnvMap $envMap -UserKey "vhlk_VM_USERNAME" -PasswordKey "vhlk_VM_PASSWORD"
    $dutCred = New-CredentialFromEnv -EnvMap $envMap -UserKey "DRIVER_TEST_VM_USERNAME" -PasswordKey "DRIVER_TEST_VM_PASSWORD"

    if ($MaxHeartbeatAgeMinutes -lt 1) {
        throw "MaxHeartbeatAgeMinutes must be at least 1."
    }
    if ($ResearchGateFailureCount -lt 0) {
        throw "ResearchGateFailureCount must be 0 or greater."
    }
    if ($StopOnFailureCount -lt 0) {
        throw "StopOnFailureCount must be 0 or greater."
    }

    $selectedTestNames = @()
    if (-not [string]::IsNullOrWhiteSpace($TestNameListPath)) {
        $resolvedTestNameListPath = Resolve-HvPath -Path $TestNameListPath -BasePath $repoRoot
        if (-not (Test-Path -LiteralPath $resolvedTestNameListPath)) {
            throw "Test name list not found: $resolvedTestNameListPath"
        }
        $selectedTestNames = @(Get-Content -LiteralPath $resolvedTestNameListPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique)
        if ($selectedTestNames.Count -lt 1) {
            throw "Test name list is empty: $resolvedTestNameListPath"
        }
    }

    if (-not $SkipFreshStart) {
        Write-LiveLine "[0/?] - fresh-starting vHLK controller and DUT VMs"
        $freshStart = Initialize-HvVhlkRunVms `
            -VhlkVmName $VhlkVmName `
            -DutVmName $DutVmName `
            -DutCheckpointName $DutCheckpointName `
            -VhlkCredential $cred `
            -DutCredential $dutCred `
            -RequireDutInteractiveSession `
            -LogPath $logPath
        $freshStart | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-fresh-start.json") -Encoding UTF8
    }

    if (-not $SkipDutInstall) {
        Write-LiveLine "[0/?] - installing staged driver into DUT"
        $dutInstallArtifact = Join-Path $artifactDir "dut-install"
        & (Join-Path $scriptDir "install-driver-for-vhlk.ps1") `
            -VmName $DutVmName `
            -CheckpointName $DutCheckpointName `
            -ArtifactRoot $dutInstallArtifact `
            -SkipFreshStart
        $installExitCode = $LASTEXITCODE
        if ($installExitCode -ne 0) {
            throw "DUT vHLK install failed with exit code $installExitCode. See $dutInstallArtifact"
        }
    }

    Write-LiveLine "[0/?] - connecting to vHLK controller VM '$VhlkVmName'"
    $session = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 180 -LogPath $logPath 6>$null

    Write-LiveLine "[0/?] - checking DUT VM '$DutVmName'"
    Wait-HvVmReady -VmName $DutVmName -Credential $dutCred -TimeoutSeconds 180 -PollIntervalSeconds 3 -RequirePowerShellDirect -LogPath $logPath | Out-Null
    $dutSession = Wait-HvPowerShellDirect -VmName $DutVmName -Credential $dutCred -TimeoutSeconds 180 -LogPath $logPath 6>$null
    $dutState = Invoke-Command -Session $dutSession -ScriptBlock {
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

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            HlkSvcFound = [bool]$service
            HlkSvcStatus = if ($service) { [string]$service.Status } else { "" }
            HlkSvcStartAttempted = $startAttempted
            IPv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
                Select-Object -ExpandProperty IPAddress)
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

    if (-not $SkipLabNetworkRepair) {
        Write-LiveLine "[0/?] - repairing vHLK lab network"
        $labNetwork = Repair-VhlkLabNetwork `
            -VhlkVmName $VhlkVmName `
            -DutVmName $DutVmName `
            -VhlkSession $session `
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
    }

    $dutState = Invoke-Command -Session $dutSession -ScriptBlock {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            IPv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
                Select-Object -ExpandProperty IPAddress)
        }
    }
    if (@($dutState.IPv4).Count -lt 1) {
        throw "DUT has no non-link-local IPv4 address. HLK controller cannot heartbeat it."
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

        function Get-AllMachineObjects {
            param($Pool)
            $items = @()
            foreach ($m in @($Pool.GetMachines())) { $items += $m }
            foreach ($child in @($Pool.GetChildPools())) {
                foreach ($item in @(Get-AllMachineObjects -Pool $child)) { $items += $item }
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
                PoolName = [string]$Machine.Pool.Name
                Pool = [string]$Machine.Pool.Path
                IsRootOrDefaultPool = [bool]($Machine.Pool.Equals($Machine.Pool.RootPool) -or $Machine.Pool.Equals($Machine.Pool.DefaultPool))
                LastHeartbeat = if ($heartbeat) { $heartbeat.ToString("s") } else { "" }
                HeartbeatAgeMinutes = $ageMinutes
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
        $machines = @(Get-AllMachineObjects -Pool ($pm.GetRootMachinePool()))
        $matches = @($machines | Where-Object {
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
        $before = Convert-MachineInfo -Machine $dut
        $setReadyResult = $null
        $setReadyAttempts = 0
        if ($SetDutReady -and -not $before.IsRootOrDefaultPool) {
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
        } elseif ($SetDutReady) {
            $setReadyResult = "SKIP: DUT is in root/default pool"
        }

        $afterMachine = @(Get-AllMachineObjects -Pool ($pm.GetRootMachinePool()) | Where-Object { ([string]$_.Name) -eq ([string]$dut.Name) } | Select-Object -First 1)
        [pscustomobject]@{
            Controller = $env:COMPUTERNAME
            Project = $ProjectName
            DutComputerName = $DutComputerName
            ControllerServices = $services
            BadControllerServices = $badServices
            DutMachineBefore = $before
            SetReadyAttempted = [bool]$SetDutReady
            SetReadyAttempts = $setReadyAttempts
            SetReadyResult = $setReadyResult
            DutMachineAfter = if ($afterMachine.Count -gt 0) { Convert-MachineInfo -Machine $afterMachine[0] } else { $null }
            TestCount = @($project.GetTests()).Count
            CheckedAt = (Get-Date).ToString("s")
        }
    }

    $readinessDeadline = (Get-Date).AddMinutes(15)
    $readiness = $null
    $machine = $null
    do {
        Write-LiveLine "[0/?] - checking controller services + DUT readiness"
        $readiness = Invoke-Vhlk -Session $session -ScriptBlock $remoteReadiness -ArgumentList @(
            $ProjectName,
            [string]$dutState.ComputerName,
            (-not [bool]$NoSetDutReady))
        $readiness | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "readiness.json") -Encoding UTF8

        if (@($readiness.BadControllerServices).Count -gt 0) {
            throw "One or more controller services are not Running. See readiness.json."
        }
        if ($readiness.TestCount -lt 1) {
            throw "HLK project has no tests."
        }
        $machine = if ($readiness.DutMachineAfter) { $readiness.DutMachineAfter } else { $readiness.DutMachineBefore }
        if ($machine.IsRootOrDefaultPool) {
            throw ("DUT machine is in root/default pool ({0}). Move it to a non-default child pool before scheduling tests." -f $machine.PoolName)
        }
        if ($readiness.SetReadyAttempted -and ([string]$readiness.SetReadyResult).StartsWith("ERROR:")) {
            throw ("DUT machine could not be set Ready on controller: {0}" -f $readiness.SetReadyResult)
        }

        $heartbeatFresh = $true
        if ($null -ne $machine.HeartbeatAgeMinutes -and [double]$machine.HeartbeatAgeMinutes -gt $MaxHeartbeatAgeMinutes) {
            $heartbeatFresh = $false
        }
        if ([string]$machine.Status -in @("Ready", "Running") -and $heartbeatFresh) {
            break
        }

        if ((Get-Date) -ge $readinessDeadline) {
            if (-not $heartbeatFresh) {
                throw ("DUT HLK heartbeat is stale: {0} minutes old. Controller is not seeing current HLKSvc heartbeat." -f $machine.HeartbeatAgeMinutes)
            }
            throw ("DUT machine is not schedulable. Status={0}. See readiness.json." -f $machine.Status)
        }

        Write-Host ("[WARN] DUT machine status={0}; waiting for HLK client to become Ready/Running." -f $machine.Status) -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    } while ($true)

    $remoteInit = {
        param($ProjectName, $PlaylistPath, $ReloadPlaylist, $CleanResults, $DryRun, $DutComputerName, [string[]]$SelectedTestNames)

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

        $tests = @($project.GetTests())
        $testsToQueue = @($tests)
        $missingSelectedTests = @()
        if ($SelectedTestNames -and $SelectedTestNames.Count -gt 0) {
            $byName = @{}
            foreach ($test in $tests) {
                $byName[[string]$test.Name] = $test
            }
            $testsToQueue = @()
            foreach ($name in $SelectedTestNames) {
                if ($byName.ContainsKey($name)) {
                    $testsToQueue += $byName[$name]
                } else {
                    $missingSelectedTests += $name
                }
            }
            if ($testsToQueue.Count -lt 1) {
                throw "No selected tests exist in HLK project."
            }
        }

        $testsToManage = if ($SelectedTestNames -and $SelectedTestNames.Count -gt 0) { @($testsToQueue) } else { @($tests) }
        $activeCancelled = 0
        $activeCancelErrors = @()
        if (-not $DryRun) {
            foreach ($test in $testsToManage) {
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
            foreach ($test in $testsToManage) {
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

        $queuedResults = @()
        $queueErrors = @()
        if (-not $DryRun) {
            $machineList = New-Object 'System.Collections.Generic.List[Microsoft.Windows.Kits.Hardware.ObjectModel.Machine]'
            $machineList.Add($dutMachine) | Out-Null
            if ($SelectedTestNames -and $SelectedTestNames.Count -gt 0) {
                foreach ($test in $testsToQueue) {
                    try {
                        $queuedResults += @($test.QueueTest($machineList))
                    }
                    catch {
                        $queueErrors += "Queue failed: $($test.Name): $($_.Exception.Message)"
                    }
                }
            } else {
                $queuedResults = @($project.QueueTest($machineList))
            }
        }

        $testsAfter = @($project.GetTests())
        [pscustomobject]@{
            Controller       = $env:COMPUTERNAME
            Project          = $ProjectName
            Playlist         = $PlaylistPath
            ReloadPlaylist   = [bool]$ReloadPlaylist
            LoadedPlaylistIds = $loadedPlaylistIds.Count
            Tests            = $testsAfter.Count
            CleanResults     = [bool]$CleanResults
            ActiveCancelledResults = $activeCancelled
            ActiveCancelErrors = $activeCancelErrors
            CancelledResults = $cancelled
            DeletedResults   = $deleted
            DeleteErrors     = $deleteErrors
            DryRun           = [bool]$DryRun
            DutComputerName  = $DutComputerName
            QueueMode        = "DirectToDutMachine"
            ManagedTests     = @($testsToManage | ForEach-Object { [string]$_.Name })
            SelectedTestNames = @($testsToQueue | ForEach-Object { [string]$_.Name })
            MissingSelectedTests = $missingSelectedTests
            QueuedResults    = $queuedResults.Count
            QueueErrors      = $queueErrors
            StartedAt        = (Get-Date).ToString("s")
        }
    }

    $reloadPlaylist = -not [bool]$NoReloadPlaylist
    $cleanResults = -not [bool]$NoCleanResults
    Write-LiveLine "[0/?] - loading playlist, cleaning old results, queueing tests"
    $init = Invoke-Vhlk -Session $session -ScriptBlock $remoteInit -ArgumentList @(
        $ProjectName,
        $PlaylistPath,
        $reloadPlaylist,
        $cleanResults,
        [bool]$DryRun,
        $dutComputerName,
        $selectedTestNames)

    $init | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "queue-result.json") -Encoding UTF8

    if (@($init.QueueErrors).Count -gt 0) {
        throw "At least one selected test failed to queue. See queue-result.json."
    }
    $fatalActiveCancelErrors = @($init.ActiveCancelErrors | Where-Object {
        [string]$_ -notmatch "Job cannot be cancelled in\s+'PD'\s+pipeline"
    })
    if ($fatalActiveCancelErrors.Count -gt 0) {
        throw "At least one active queued/running result failed to cancel. See queue-result.json."
    }
    if (@($init.ActiveCancelErrors).Count -gt 0) {
        Write-Host "[WARN] HLK refused to cancel a result already in the PD pipeline; selected tests were still queued and monitoring will continue." -ForegroundColor Yellow
    }
    if (@($init.MissingSelectedTests).Count -gt 0) {
        throw "Some selected tests were not found in the HLK project. See queue-result.json."
    }

    if ($DryRun) {
        Write-DoneLine
        Write-Host ("Dry run OK. Tests available: {0}. ArtifactDir: {1}" -f $init.Tests, $artifactDir) -ForegroundColor Green
        exit 0
    }

    $selectedTestNamesJson = ConvertTo-Json -InputObject @($selectedTestNames) -Depth 3 -Compress

    $remoteStatus = {
        param(
            $ProjectName,
            [string]$SelectedTestNamesJson
        )

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

        $tests = @($project.GetTests())
        $selectedNames = @()
        if (-not [string]::IsNullOrWhiteSpace($SelectedTestNamesJson)) {
            $decodedSelectedNames = ConvertFrom-Json -InputObject $SelectedTestNamesJson
            $selectedNames = @($decodedSelectedNames | ForEach-Object {
                $name = ([string]$_).Trim()
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $name
                }
            } | Sort-Object -Unique)
        }

        $selectedNameSet = @{}
        foreach ($name in $selectedNames) {
            $selectedNameSet[$name] = $true
        }

        $projectNameSet = @{}
        foreach ($test in $tests) {
            $projectNameSet[[string]$test.Name] = $true
        }

        $monitoringSelectedTests = $selectedNameSet.Count -gt 0
        $monitoredTests = @()
        if ($monitoringSelectedTests) {
            $monitoredTests = @($tests | Where-Object { $selectedNameSet.ContainsKey([string]$_.Name) })
        } else {
            $monitoredTests = @($tests)
        }
        $missingSelectedTests = @($selectedNames | Where-Object { -not $projectNameSet.ContainsKey($_) })
        $selectedTotal = if ($monitoringSelectedTests) { $selectedNames.Count } else { $monitoredTests.Count }

        $groups = @($monitoredTests | Group-Object { "{0},{1}" -f $_.Status, $_.ExecutionState } | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Count = $_.Count }
        })

        $passed = @($monitoredTests | Where-Object { [string]$_.Status -eq "Passed" }).Count
        $failed = @($monitoredTests | Where-Object { [string]$_.Status -eq "Failed" }).Count
        $running = @($monitoredTests | Where-Object { [string]$_.ExecutionState -eq "Running" })
        $inQueue = @($monitoredTests | Where-Object { [string]$_.ExecutionState -eq "InQueue" }).Count
        $notRun = @($monitoredTests | Where-Object { [string]$_.Status -eq "NotRun" }).Count
        $completed = @($monitoredTests | Where-Object {
            [string]$_.Status -in @("Passed", "Failed", "Canceled", "Cancelled", "Blocked", "NotApplicable")
        }).Count

        $current = $null
        if ($running.Count -gt 0) {
            $current = $running[0]
        }
        $failures = @($monitoredTests | Where-Object { [string]$_.Status -eq "Failed" } | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Status = [string]$_.Status
                ExecutionState = [string]$_.ExecutionState
            }
        })

        $machines = @()
        function Add-PoolMachines {
            param($Pool)
            foreach ($m in @($Pool.GetMachines())) {
                $script:machines += [pscustomobject]@{
                    Name = $m.Name
                    Status = [string]$m.Status
                    LastHeartbeat = $m.LastHeartbeat
                    Pool = $m.Pool.Path
                }
            }
            foreach ($child in @($Pool.GetChildPools())) {
                Add-PoolMachines -Pool $child
            }
        }
        Add-PoolMachines -Pool ($pm.GetRootMachinePool())

        [pscustomobject]@{
            CheckedAt       = (Get-Date).ToString("s")
            Total           = $selectedTotal
            MatchedTotal    = $monitoredTests.Count
            ProjectTotal    = $tests.Count
            MonitoringSelectedTests = $monitoringSelectedTests
            SelectedTestNames = $selectedNames
            MissingSelectedTests = $missingSelectedTests
            Completed       = $completed
            Passed          = $passed
            Failed          = $failed
            InQueue         = $inQueue
            NotRun          = $notRun
            RunningCount    = $running.Count
            CurrentName     = if ($current) { $current.Name } else { "" }
            CurrentStatus   = if ($current) { [string]$current.Status } else { "" }
            CurrentState    = if ($current) { [string]$current.ExecutionState } else { "" }
            Groups          = $groups
            Failures        = $failures
            FailedTestNames  = @($failures | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
            Machines        = $machines
        }
    }

    $remoteCancelQueuedOrRunning = {
        param(
            $ProjectName,
            [string]$SelectedTestNamesJson
        )
        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Continue"
        $root = "C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Controller"
        Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dll")
        Add-Type -Path (Join-Path $root "microsoft.windows.kits.hardware.objectmodel.dbconnection.dll")
        $pm = [Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager]::new($env:COMPUTERNAME)
        $project = $pm.GetProject($ProjectName)
        $tests = @($project.GetTests())
        $selectedNames = @()
        if (-not [string]::IsNullOrWhiteSpace($SelectedTestNamesJson)) {
            $decodedSelectedNames = ConvertFrom-Json -InputObject $SelectedTestNamesJson
            $selectedNames = @($decodedSelectedNames | ForEach-Object {
                $name = ([string]$_).Trim()
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $name
                }
            } | Sort-Object -Unique)
        }
        $selectedNameSet = @{}
        foreach ($name in $selectedNames) {
            $selectedNameSet[$name] = $true
        }
        $testsToCancel = if ($selectedNameSet.Count -gt 0) {
            @($tests | Where-Object { $selectedNameSet.ContainsKey([string]$_.Name) })
        } else {
            @($tests)
        }
        $cancelled = 0
        $errors = @()
        foreach ($test in $testsToCancel) {
            foreach ($result in @($test.GetTestResults())) {
                if ([string]$result.Status -in @("InQueue", "Running")) {
                    try {
                        $result.Cancel()
                        $cancelled++
                    }
                    catch {
                        $errors += "Cancel failed: $($test.Name): $($_.Exception.Message)"
                    }
                }
            }
        }
        [pscustomobject]@{
            Cancelled = $cancelled
            Errors = $errors
            ProjectTotal = $tests.Count
            ManagedTests = @($testsToCancel | ForEach-Object { [string]$_.Name })
        }
    }

    $history = New-Object System.Collections.Generic.List[object]
    $start = Get-Date
    $lastAnyStarted = $null
    $lastStatus = $null
    $stopReason = ""
    $tick = 0
    $controllerReconnectFailures = 0
    $spinner = @("|", "/", "-", "\")

    while ($true) {
        $tick++
        $status = $null
        $statusFresh = $true
        $statusPollError = ""
        try {
            $status = Invoke-Vhlk -Session $session -ScriptBlock $remoteStatus -ArgumentList @($ProjectName, $selectedTestNamesJson)
        }
        catch {
            $statusFresh = $false
            $statusPollError = $_.Exception.Message
            Write-DoneLine
            Write-HvLog -Message ("Remote status poll failed; using last known status. {0}" -f $statusPollError) -LogPath $logPath -Level WARN
            try {
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
                $session = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 60 -LogPath $logPath 6>$null
                $controllerReconnectFailures = 0
            }
            catch {
                $controllerReconnectFailures++
                Write-HvLog -Message ("Controller session reopen failed ({0}/{1}); will retry. {2}" -f $controllerReconnectFailures, $MaxControllerReconnectFailures, $_.Exception.Message) -LogPath $logPath -Level WARN
                if ($controllerReconnectFailures -ge $MaxControllerReconnectFailures) {
                    Write-DoneLine
                    Write-Host ("Controller connection failed {0} times. Monitoring stopped." -f $MaxControllerReconnectFailures) -ForegroundColor Red
                    $connectionGate = [pscustomobject]@{
                        Trigger = "MaxControllerReconnectFailures"
                        Threshold = $MaxControllerReconnectFailures
                        ConsecutiveFailures = $controllerReconnectFailures
                        LastError = $_.Exception.Message
                        LastStatus = $lastStatus
                        CheckedAt = (Get-Date).ToString("s")
                    }
                    $connectionGate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "controller-reconnect-limit.json") -Encoding UTF8
                    $stopReason = "MaxControllerReconnectFailures"
                    break
                }
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

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $remaining = if ($TimeoutMinutes -gt 0) { [Math]::Max(0, [int]($start.AddMinutes($TimeoutMinutes) - (Get-Date)).TotalSeconds) } else { 0 }
        $glyph = $spinner[$tick % $spinner.Count]
        $groupText = [string]::Join("; ", @($status.Groups | ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }))
        $currentIndex = if ($status.Total -gt 0 -and $status.Completed -ge $status.Total) {
            $status.Total
        } elseif ($status.RunningCount -gt 0) {
            [Math]::Min($status.Total, $status.Completed + 1)
        } else {
            $status.Completed
        }
        $label = if ($status.Total -gt 0 -and $status.Completed -ge $status.Total) {
            "completed"
        } elseif ($status.RunningCount -gt 0) {
            "{0} running" -f $status.CurrentName
        } elseif ($status.InQueue -gt 0) {
            "waiting for scheduler ({0} queued)" -f $status.InQueue
        } else {
            "no test running"
        }
        $timePart = if ($TimeoutMinutes -gt 0) { "t+{0}s rem={1}s" -f $elapsed, $remaining } else { "t+{0}s" -f $elapsed }
        $line = "{0} {1} [{2}/{3}] - {4} | pass={5} fail={6} queue={7} groups={8}" -f $glyph, $timePart, $currentIndex, $status.Total, $label, $status.Passed, $status.Failed, $status.InQueue, $groupText
        $color = if ($status.Failed -gt 0) { [ConsoleColor]::Red } elseif ($status.RunningCount -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-LiveLine $line $color

        if (($tick % 6) -eq 0) {
            Write-DoneLine
            Write-Host ("    alive tick={0}; latest={1}" -f $tick, $status.CheckedAt) -ForegroundColor DarkCyan
        }

        if ($status.RunningCount -gt 0 -or $status.Passed -gt 0 -or $status.Failed -gt 0) {
            if (-not $lastAnyStarted) {
                $lastAnyStarted = Get-Date
            }
        }

        $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "latest-status.json") -Encoding UTF8
        if ($status.FailedTestNames) {
            @($status.FailedTestNames) | Set-Content -LiteralPath (Join-Path $artifactDir "failed-test-names.txt") -Encoding UTF8
        }

        if ($StopOnFirstFailure -and $status.Failed -gt 0) {
            Write-DoneLine
            Write-Host "First failure detected. Monitoring stopped; HLK queue may still be running." -ForegroundColor Red
            $stopReason = "StopOnFirstFailure"
            break
        }

        if ($ResearchGateFailureCount -gt 0 -and $status.Failed -ge $ResearchGateFailureCount) {
            Write-DoneLine
            Write-Host ("Research gate reached at {0} failed tests. Cancelling queued/running results." -f $ResearchGateFailureCount) -ForegroundColor Red
            $cancel = Invoke-Vhlk -Session $session -ScriptBlock $remoteCancelQueuedOrRunning -ArgumentList @($ProjectName, $selectedTestNamesJson)
            $researchGate = [pscustomobject]@{
                Trigger = "ResearchGateFailureCount"
                Threshold = $ResearchGateFailureCount
                Failed = $status.Failed
                FailedTestNames = @($status.FailedTestNames)
                Cancel = $cancel
                CheckedAt = (Get-Date).ToString("s")
            }
            $researchGate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "research-gate.json") -Encoding UTF8
            $stopReason = "ResearchGateFailureCount"
            break
        }

        if ($StopOnFailureCount -gt 0 -and $status.Failed -ge $StopOnFailureCount) {
            Write-DoneLine
            Write-Host ("Failure stop reached at {0} failed tests. Cancelling queued/running results." -f $StopOnFailureCount) -ForegroundColor Red
            $cancel = Invoke-Vhlk -Session $session -ScriptBlock $remoteCancelQueuedOrRunning -ArgumentList @($ProjectName, $selectedTestNamesJson)
            $failureGate = [pscustomobject]@{
                Trigger = "StopOnFailureCount"
                Threshold = $StopOnFailureCount
                Failed = $status.Failed
                FailedTestNames = @($status.FailedTestNames)
                Cancel = $cancel
                CheckedAt = (Get-Date).ToString("s")
            }
            $failureGate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "failure-stop.json") -Encoding UTF8
            $stopReason = "StopOnFailureCount"
            break
        }

        if ($status.Total -gt 0 -and $status.Completed -ge $status.Total) {
            Write-DoneLine
            if ($status.Failed -eq 0) {
                Write-Host "All vHLK tests completed without failed status." -ForegroundColor Green
            } else {
                Write-Host ("vHLK completed with {0} failed tests." -f $status.Failed) -ForegroundColor Red
            }
            $stopReason = "Completed"
            break
        }

        if ($NoStartTimeoutMinutes -gt 0 -and -not $lastAnyStarted -and ((Get-Date) - $start).TotalMinutes -ge $NoStartTimeoutMinutes) {
            Write-DoneLine
            Write-Host ("No vHLK test started within {0} minutes. Cancelling queued results." -f $NoStartTimeoutMinutes) -ForegroundColor Red
            Invoke-Vhlk -Session $session -ScriptBlock $remoteCancelQueuedOrRunning -ArgumentList @($ProjectName, $selectedTestNamesJson) | Out-Null
            $stopReason = "NoStartTimeout"
            break
        }

        if ($PendingStartTimeoutSeconds -gt 0 -and -not $lastAnyStarted -and $status.InQueue -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $PendingStartTimeoutSeconds) {
            Write-DoneLine
            Write-Host ("vHLK tests stayed pending for {0} seconds. Cancelling queued results." -f $PendingStartTimeoutSeconds) -ForegroundColor Red
            Invoke-Vhlk -Session $session -ScriptBlock $remoteCancelQueuedOrRunning -ArgumentList @($ProjectName, $selectedTestNamesJson) | Out-Null
            $stopReason = "PendingStartTimeout"
            break
        }

        if ($TimeoutMinutes -gt 0 -and ((Get-Date) - $start).TotalMinutes -ge $TimeoutMinutes) {
            Write-DoneLine
            Write-Host ("Monitor timeout reached after {0} minutes." -f $TimeoutMinutes) -ForegroundColor Yellow
            $stopReason = "Timeout"
            break
        }

        Start-Sleep -Seconds ([Math]::Max(1, $MonitorIntervalSeconds))
    }

    $summary = [pscustomobject]@{
        ArtifactDir = $artifactDir
        StartedAt = $start.ToString("s")
        CompletedAt = (Get-Date).ToString("s")
        InitialQueue = $init
        FinalStatus = $lastStatus
        StopReason = $stopReason
        History = $history
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "monitor-summary.json") -Encoding UTF8

    if ($stopReason -eq "MaxControllerReconnectFailures") {
        exit 1
    }
    if ($lastStatus -and $lastStatus.Failed -gt 0) {
        exit 2
    }
    if ($lastStatus -and $lastStatus.Total -gt 0 -and $lastStatus.Completed -ge $lastStatus.Total) {
        exit 0
    }
    exit 1
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
    if ($dutSession) {
        Remove-PSSession -Session $dutSession -ErrorAction SilentlyContinue
    }
    Stop-Transcript | Out-Null
    Write-Host ("Artifacts: {0}" -f $artifactDir)
}
