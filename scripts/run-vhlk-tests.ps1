[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string]$ProjectName = "VirtuaCam",
    [string]$PlaylistPath = "C:\Users\Administrator\Desktop\Compat Playlists\HLK Version 2004 CompatPlaylist x86 x64 ARM64.xml",
    [int]$MonitorIntervalSeconds = 15,
    [int]$NoStartTimeoutMinutes = 20,
    [int]$TimeoutMinutes = 0,
    [switch]$NoCleanResults,
    [switch]$NoReloadPlaylist,
    [switch]$StopOnFirstFailure,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")

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
        (ConvertTo-SecureString $password -AsPlainText -Force))
}

function Write-LiveLine {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )

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

Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
try {
    $envMap = Read-DotEnv -Path (Join-Path $repoRoot ".env")
    $cred = New-CredentialFromEnv -EnvMap $envMap -UserKey "vhlk_VM_USERNAME" -PasswordKey "vhlk_VM_PASSWORD"

    Write-LiveLine "[0/?] - connecting to vHLK controller VM '$VhlkVmName'"
    $session = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 180 -LogPath $logPath 6>$null

    $remoteInit = {
        param($ProjectName, $PlaylistPath, $ReloadPlaylist, $CleanResults, $DryRun)

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

        $tests = @($project.GetTests())
        $cancelled = 0
        $deleted = 0
        $deleteErrors = @()

        if ($CleanResults -and -not $DryRun) {
            foreach ($test in $tests) {
                foreach ($result in @($test.GetTestResults())) {
                    try {
                        if ("Running", "InQueue" -contains ([string]$result.Status)) {
                            $result.Cancel()
                            $cancelled++
                        }
                    }
                    catch {
                        $deleteErrors += "Cancel failed: $($test.Name): $($_.Exception.Message)"
                    }

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
        if (-not $DryRun) {
            $queuedResults = @($project.QueueTest())
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
            CancelledResults = $cancelled
            DeletedResults   = $deleted
            DeleteErrors     = $deleteErrors
            DryRun           = [bool]$DryRun
            QueuedResults    = $queuedResults.Count
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
        [bool]$DryRun)

    $init | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "queue-result.json") -Encoding UTF8

    if ($DryRun) {
        Write-DoneLine
        Write-Host ("Dry run OK. Tests available: {0}. ArtifactDir: {1}" -f $init.Tests, $artifactDir) -ForegroundColor Green
        exit 0
    }

    $remoteStatus = {
        param($ProjectName)

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
        $failures = @($tests | Where-Object { [string]$_.Status -eq "Failed" } | Select-Object -First 5 | ForEach-Object {
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
            Total           = $tests.Count
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
            Machines        = $machines
        }
    }

    $history = New-Object System.Collections.Generic.List[object]
    $start = Get-Date
    $lastAnyStarted = $null
    $lastStatus = $null

    while ($true) {
        $status = Invoke-Vhlk -Session $session -ScriptBlock $remoteStatus -ArgumentList @($ProjectName)
        $history.Add($status) | Out-Null
        $lastStatus = $status

        $currentIndex = if ($status.RunningCount -gt 0) { [Math]::Min($status.Total, $status.Completed + 1) } else { $status.Completed }
        $label = if ($status.RunningCount -gt 0) {
            "{0} running" -f $status.CurrentName
        } elseif ($status.InQueue -gt 0) {
            "waiting for scheduler ({0} queued)" -f $status.InQueue
        } else {
            "no test running"
        }
        $line = "[{0}/{1}] - {2} | pass={3} fail={4} queue={5}" -f $currentIndex, $status.Total, $label, $status.Passed, $status.Failed, $status.InQueue
        $color = if ($status.Failed -gt 0) { [ConsoleColor]::Red } elseif ($status.RunningCount -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-LiveLine $line $color

        if ($status.RunningCount -gt 0 -or $status.Passed -gt 0 -or $status.Failed -gt 0) {
            if (-not $lastAnyStarted) {
                $lastAnyStarted = Get-Date
            }
        }

        $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "latest-status.json") -Encoding UTF8

        if ($StopOnFirstFailure -and $status.Failed -gt 0) {
            Write-DoneLine
            Write-Host "First failure detected. Monitoring stopped; HLK queue may still be running." -ForegroundColor Red
            break
        }

        if ($status.Total -gt 0 -and $status.Completed -ge $status.Total) {
            Write-DoneLine
            if ($status.Failed -eq 0) {
                Write-Host "All vHLK tests completed without failed status." -ForegroundColor Green
            } else {
                Write-Host ("vHLK completed with {0} failed tests." -f $status.Failed) -ForegroundColor Red
            }
            break
        }

        if ($NoStartTimeoutMinutes -gt 0 -and -not $lastAnyStarted -and ((Get-Date) - $start).TotalMinutes -ge $NoStartTimeoutMinutes) {
            Write-DoneLine
            Write-Host ("No vHLK test started within {0} minutes. Check machine pool, HLKSvc, and controller scheduler." -f $NoStartTimeoutMinutes) -ForegroundColor Red
            break
        }

        if ($TimeoutMinutes -gt 0 -and ((Get-Date) - $start).TotalMinutes -ge $TimeoutMinutes) {
            Write-DoneLine
            Write-Host ("Monitor timeout reached after {0} minutes." -f $TimeoutMinutes) -ForegroundColor Yellow
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
        History = $history
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "monitor-summary.json") -Encoding UTF8

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
    Stop-Transcript | Out-Null
    Write-Host ("Artifacts: {0}" -f $artifactDir)
}
