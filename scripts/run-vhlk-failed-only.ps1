[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string]$DutVmName = "driver-test",
    [string]$DutCheckpointName = "clean",
    [string]$ProjectName = "VirtuaCam",
    [string]$TestNameListPath = "",
    [string]$BlockedTestNameListPath = "",
    [string]$ArtifactRoot = "",
    [int]$ResearchGateFailureCount = 2,
    [int]$StopOnFailureCount = 10,
    [int]$MaxControllerReconnectFailures = 5,
    [int]$PendingStartTimeoutSeconds = 300,
    [int]$TimeoutMinutes = 60,
    [switch]$SkipDutInstall,
    [switch]$SkipFreshStart,
    [switch]$SkipBlockerFilter,
    [switch]$NoExport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path $repoRoot ("test-reports\vhlk-failed-only-{0}" -f (Get-HvTimestamp))
} else {
    Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot
}
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "run-vhlk-failed-only.log"

function Read-FailedTestNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Failed-name list not found: $Path"
    }

    return @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique
    )
}

try {
    if ($MaxControllerReconnectFailures -lt 1) {
        throw "MaxControllerReconnectFailures must be at least 1."
    }

    $envMap = Read-HvDotEnv
    $vhlkUser = [string]$envMap["vhlk_VM_USERNAME"]
    $vhlkPassword = [string]$envMap["vhlk_VM_PASSWORD"]
    $dutUser = [string]$envMap["DRIVER_TEST_VM_USERNAME"]
    $dutPassword = [string]$envMap["DRIVER_TEST_VM_PASSWORD"]
    if ([string]::IsNullOrWhiteSpace($vhlkUser) -or [string]::IsNullOrWhiteSpace($vhlkPassword)) {
        throw "Missing vhlk_VM_USERNAME or vhlk_VM_PASSWORD in .env"
    }
    if ([string]::IsNullOrWhiteSpace($dutUser) -or [string]::IsNullOrWhiteSpace($dutPassword)) {
        throw "Missing DRIVER_TEST_VM_USERNAME or DRIVER_TEST_VM_PASSWORD in .env"
    }

    $vhlkCred = [pscredential]::new($vhlkUser, (ConvertTo-SecureString $vhlkPassword -AsPlainText -Force))
    $dutCred = [pscredential]::new($dutUser, (ConvertTo-SecureString $dutPassword -AsPlainText -Force))

    if (-not $SkipFreshStart) {
        Write-Host "[1/5] Fresh-start vHLK controller and DUT" -ForegroundColor Cyan
        $freshStart = Initialize-HvVhlkRunVms `
            -VhlkVmName $VhlkVmName `
            -DutVmName $DutVmName `
            -DutCheckpointName $DutCheckpointName `
            -VhlkCredential $vhlkCred `
            -DutCredential $dutCred `
            -RequireDutInteractiveSession `
            -LogPath $logPath
        $freshStart | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-fresh-start.json") -Encoding UTF8
    } else {
        Write-Host "[1/5] Fresh-start skipped by parameter" -ForegroundColor Yellow
    }

    if ([string]::IsNullOrWhiteSpace($TestNameListPath)) {
        if ($NoExport) {
            throw "TestNameListPath is required when -NoExport is used."
        }

        Write-Host "[2/5] Export failed vHLK names" -ForegroundColor Cyan
        $exportRoot = Join-Path $artifactDir "export"
        & (Join-Path $scriptDir "export-vhlk-failed-tests.ps1") `
            -VhlkVmName $VhlkVmName `
            -ProjectName $ProjectName `
            -ArtifactRoot $exportRoot `
            -SkipFreshStart
        if (-not $?) {
            throw "Failed-name export failed. See $exportRoot"
        }
        $TestNameListPath = Join-Path $exportRoot "failed-test-names.txt"
    } else {
        Write-Host "[2/5] Use provided failed-name list" -ForegroundColor Cyan
        $TestNameListPath = Resolve-HvPath -Path $TestNameListPath -BasePath $repoRoot
    }

    $failedNames = @(Read-FailedTestNames -Path $TestNameListPath)
    if ($failedNames.Count -lt 1) {
        Write-Host ("No failed vHLK tests to run. Failed-name list is empty: {0}" -f $TestNameListPath)
        exit 0
    }

    if (-not $SkipBlockerFilter) {
        if ([string]::IsNullOrWhiteSpace($BlockedTestNameListPath)) {
            $defaultBlockerPath = Join-Path $repoRoot "docs\vhlk-blocked-test-names.txt"
            if (Test-Path -LiteralPath $defaultBlockerPath) {
                $BlockedTestNameListPath = $defaultBlockerPath
            }
        } else {
            $BlockedTestNameListPath = Resolve-HvPath -Path $BlockedTestNameListPath -BasePath $repoRoot
        }

        if (-not [string]::IsNullOrWhiteSpace($BlockedTestNameListPath) -and (Test-Path -LiteralPath $BlockedTestNameListPath)) {
            Write-Host "[3/5] Filter documented blocked tests" -ForegroundColor Cyan
            $filteredPath = Join-Path $artifactDir "failed-test-names.filtered.txt"
            $filterOutput = & (Join-Path $scriptDir "filter-vhlk-test-list.ps1") `
                -InputPath $TestNameListPath `
                -SkipPath $BlockedTestNameListPath `
                -OutputPath $filteredPath
            $filterOutput | Set-Content -LiteralPath (Join-Path $artifactDir "filter-result.json") -Encoding UTF8
            $TestNameListPath = $filteredPath
            $failedNames = @(Read-FailedTestNames -Path $TestNameListPath)
            if ($failedNames.Count -lt 1) {
                Write-Host ("All failed vHLK tests are documented blockers. Filtered list is empty: {0}" -f $TestNameListPath)
                exit 0
            }
        } else {
            Write-Host "[3/5] No blocked-test list found" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[3/5] Blocker filter skipped by parameter" -ForegroundColor Yellow
    }

    if (-not $SkipDutInstall) {
        Write-Host "[4/5] Install staged DUT driver" -ForegroundColor Cyan
        $dutInstallArtifact = Join-Path $artifactDir "dut-install"
        & (Join-Path $scriptDir "install-driver-for-vhlk.ps1") `
            -VmName $DutVmName `
            -CheckpointName $DutCheckpointName `
            -ArtifactRoot $dutInstallArtifact `
            -SkipFreshStart
        if (-not $?) {
            throw "DUT vHLK install failed. See $dutInstallArtifact"
        }
    } else {
        Write-Host "[4/5] DUT install skipped by parameter" -ForegroundColor Yellow
    }

    Write-Host "[5/5] Run failed-only vHLK list" -ForegroundColor Cyan
    & (Join-Path $scriptDir "run-vhlk-tests.ps1") `
        -VhlkVmName $VhlkVmName `
        -DutVmName $DutVmName `
        -DutCheckpointName $DutCheckpointName `
        -ProjectName $ProjectName `
        -TestNameListPath $TestNameListPath `
        -PendingStartTimeoutSeconds $PendingStartTimeoutSeconds `
        -TimeoutMinutes $TimeoutMinutes `
        -ResearchGateFailureCount $ResearchGateFailureCount `
        -StopOnFailureCount $StopOnFailureCount `
        -MaxControllerReconnectFailures $MaxControllerReconnectFailures `
        -SkipFreshStart `
        -SkipDutInstall
    $runExitCode = $LASTEXITCODE

    [pscustomobject]@{
        ArtifactDir = $artifactDir
        TestNameListPath = $TestNameListPath
        SelectedCount = $failedNames.Count
        ResearchGateFailureCount = $ResearchGateFailureCount
        StopOnFailureCount = $StopOnFailureCount
        MaxControllerReconnectFailures = $MaxControllerReconnectFailures
        RunExitCode = $runExitCode
        CompletedAt = (Get-Date).ToString("s")
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "failed-only-summary.json") -Encoding UTF8

    exit $runExitCode
}
catch {
    $errorPath = Join-Path $artifactDir "error.txt"
    $_ | Out-String | Set-Content -LiteralPath $errorPath -Encoding UTF8
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Artifacts: {0}" -f $artifactDir) -ForegroundColor Yellow
    exit 1
}
