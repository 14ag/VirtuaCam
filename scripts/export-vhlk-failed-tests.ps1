[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string]$ProjectName = "VirtuaCam",
    [string]$ArtifactRoot = "",
    [string]$ShortExportRoot = "C:\VhlkExport",
    [switch]$NoOpenController,
    [switch]$SkipFreshStart,
    [switch]$ExportFailedResultDetails
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path $repoRoot ("test-reports\vhlk-failed-export-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
} else {
    Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot
}
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "export.log"

$session = $null

try {
    $envMap = Read-HvDotEnv
    $user = [string]$envMap["vhlk_VM_USERNAME"]
    $password = [string]$envMap["vhlk_VM_PASSWORD"]
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password)) {
        throw "Missing vhlk_VM_USERNAME or vhlk_VM_PASSWORD in .env"
    }
    $cred = [pscredential]::new($user, (ConvertTo-SecureString $password -AsPlainText -Force))

    if (-not $SkipFreshStart) {
        Write-HvLog -Message ("Fresh-starting vHLK controller '{0}' before failed-name export." -f $VhlkVmName) -LogPath $logPath -Level STEP
        $freshStart = Start-HvFreshControllerVm -VmName $VhlkVmName -Credential $cred -ReadyTimeoutSeconds 300 -LogPath $logPath
        $freshStart | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-fresh-start.json") -Encoding UTF8
    }

    $session = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 180 -LogPath $logPath 6>$null
    $status = Invoke-Command -Session $session -ScriptBlock {
        param($ProjectName, $ExportFailedResultDetails, $ShortExportRoot)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        $root = "C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Controller"
        $stdioRoot = [string]$env:WTTSTDIO
        if ([string]::IsNullOrWhiteSpace($stdioRoot)) {
            $stdioRoot = $root
        }

        $resolveHandler = [System.ResolveEventHandler]{
            param($sender, $resolveArgs)

            $assemblyName = [System.Reflection.AssemblyName]::new($resolveArgs.Name).Name
            $candidate = [System.IO.Path]::Combine($stdioRoot, ($assemblyName + ".dll"))
            if ([System.IO.File]::Exists($candidate)) {
                return [System.Reflection.Assembly]::LoadFrom($candidate)
            }
            return $null
        }
        [System.AppDomain]::CurrentDomain.add_AssemblyResolve($resolveHandler)

        $assemblies = @(
            "microsoft.windows.kits.hardware.sqmwrapper.dll",
            "microsoft.windows.kits.hardware.logging.dll",
            "microsoft.windows.kits.hardware.objectmodel.dll",
            "microsoft.windows.kits.hardware.objectmodel.dbconnection.dll",
            "microsoft.windows.kits.hardware.objectmodel.submission.dll",
            "microsoft.windows.kits.hardware.objectmodel.export.dll",
            "microsoft.windows.kits.hardware.diagnosticsummary.dll"
        )
        foreach ($assembly in $assemblies) {
            $assemblyPath = Join-Path $stdioRoot $assembly
            if (Test-Path -LiteralPath $assemblyPath) {
                [void][System.Reflection.Assembly]::LoadFrom($assemblyPath)
            }
        }

        $pm = [Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager]::new($env:COMPUTERNAME)
        $project = $pm.GetProject($ProjectName)
        if (-not $project) {
            throw "HLK project not found: $ProjectName"
        }

        $tests = @($project.GetTests())
        $failures = @($tests | Where-Object { [string]$_.Status -eq "Failed" } | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                Status = [string]$_.Status
                ExecutionState = [string]$_.ExecutionState
            }
        } | Sort-Object Name)

        $detailRoot = ""
        $detailManifest = @()
        $detailErrors = @()
        if ($ExportFailedResultDetails) {
            if ([string]::IsNullOrWhiteSpace($ShortExportRoot)) {
                $ShortExportRoot = "C:\VhlkExport"
            }
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $detailRoot = Join-Path $ShortExportRoot ("VirtuaCamFailedLogs-{0}" -f $stamp)
            if (Test-Path -LiteralPath $detailRoot) {
                Remove-Item -LiteralPath $detailRoot -Recurse -Force
            }
            $null = New-Item -ItemType Directory -Force -Path $detailRoot

            $testIndex = 0
            foreach ($test in @($tests | Where-Object { [string]$_.Status -eq "Failed" } | Sort-Object Name)) {
                $testIndex++
                $testDir = Join-Path $detailRoot ("test-{0:00}" -f $testIndex)
                $null = New-Item -ItemType Directory -Force -Path $testDir
                $index = 0
                foreach ($result in @($test.GetTestResults() | Where-Object { [string]$_.Status -eq "Failed" })) {
                    $index++
                    $outDir = Join-Path $testDir ("result-{0}" -f $index)
                    $null = New-Item -ItemType Directory -Force -Path $outDir
                    $errorPath = Join-Path $testDir ("result-{0}-export-error.txt" -f $index)
                    try {
                        $exportable = $result -as [Microsoft.Windows.Kits.Hardware.ObjectModel.IRunExport]
                        if (-not $exportable) {
                            throw "Result does not implement IRunExport."
                        }
                        if (-not $exportable.CanExport) {
                            throw "Result CanExport is false."
                        }
                        $exportable.Export($outDir)
                    }
                    catch {
                        $errorText = $_ | Out-String
                        $errorText | Set-Content -LiteralPath $errorPath -Encoding UTF8
                        $detailErrors += [pscustomobject]@{
                            Name = [string]$test.Name
                            ResultIndex = $index
                            ErrorPath = $errorPath
                            Error = $errorText.Trim()
                        }
                    }
                    $detailManifest += [pscustomobject]@{
                        Name = [string]$test.Name
                        ResultIndex = $index
                        ExportPath = $outDir
                        ErrorPath = if (Test-Path -LiteralPath $errorPath) { $errorPath } else { "" }
                    }
                }
            }
        }

        try {
            [pscustomobject]@{
                CheckedAt = (Get-Date).ToString("s")
                Controller = $env:COMPUTERNAME
                Project = $ProjectName
                Total = $tests.Count
                Passed = @($tests | Where-Object { [string]$_.Status -eq "Passed" }).Count
                Failed = $failures.Count
                NotRun = @($tests | Where-Object { [string]$_.Status -eq "NotRun" }).Count
                Failures = $failures
                FailedTestNames = @($failures | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
                FailedResultDetailsGuestRoot = $detailRoot
                FailedResultDetails = $detailManifest
                ExportIncomplete = ($detailErrors.Count -gt 0)
                DetailExportErrors = $detailErrors
            }
        }
        finally {
            [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($resolveHandler)
        }
    } -ArgumentList $ProjectName, ([bool]$ExportFailedResultDetails), $ShortExportRoot

    $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "latest-status.json") -Encoding UTF8
    @($status.FailedTestNames) | Set-Content -LiteralPath (Join-Path $artifactDir "failed-test-names.txt") -Encoding UTF8
    if ($ExportFailedResultDetails -and -not [string]::IsNullOrWhiteSpace([string]$status.FailedResultDetailsGuestRoot)) {
        $detailHostRoot = Join-Path $artifactDir "failed-result-details"
        Copy-HvFromGuest -Session $session -GuestPath ([string]$status.FailedResultDetailsGuestRoot) -LocalPath $detailHostRoot -Recurse -LogPath $logPath
    }
    if ($ExportFailedResultDetails -and
        $status.PSObject.Properties.Match("ExportIncomplete").Count -gt 0 -and
        [bool]$status.ExportIncomplete) {
        [pscustomobject]@{
            Completed = $false
            Error = "One or more failed-result detail exports were incomplete."
            CheckedAt = (Get-Date).ToString("s")
            ArtifactDir = $artifactDir
            DetailExportErrors = $status.DetailExportErrors
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "export-incomplete.json") -Encoding UTF8
        Write-Warning "Failed-result detail export incomplete. See export-incomplete.json."
    }
    Write-Host ("Exported {0} failed names from {1} tests." -f $status.Failed, $status.Total)
    Write-Host ("Artifacts: {0}" -f $artifactDir)
    exit 0
}
catch {
    [pscustomobject]@{
        Completed = $false
        Error = $_.Exception.Message
        CheckedAt = (Get-Date).ToString("s")
        ArtifactDir = $artifactDir
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactDir "export-incomplete.json") -Encoding UTF8
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Artifacts: {0}" -f $artifactDir) -ForegroundColor Yellow
    exit 1
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
