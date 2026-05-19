[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string]$ProjectName = "VirtuaCam",
    [string]$ArtifactRoot = "",
    [switch]$SkipFreshStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path $repoRoot ("test-reports\vhlk-remaining-export-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
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
    $cred = [pscredential]::new($user, (New-HvSecureString -PlainText $password))

    if (-not $SkipFreshStart) {
        Write-HvLog -Message ("Fresh-starting vHLK controller '{0}' before remaining-name export." -f $VhlkVmName) -LogPath $logPath -Level STEP
        $freshStart = Start-HvFreshControllerVm -VmName $VhlkVmName -Credential $cred -ReadyTimeoutSeconds 300 -LogPath $logPath
        $freshStart | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-fresh-start.json") -Encoding UTF8
    }

    $session = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 180 -LogPath $logPath 6>$null
    $status = Invoke-Command -Session $session -ScriptBlock {
        param($ProjectName)

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

        try {
            $pm = [Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager]::new($env:COMPUTERNAME)
            $project = $pm.GetProject($ProjectName)
            if (-not $project) {
                throw "HLK project not found: $ProjectName"
            }

            $tests = @($project.GetTests())
            $testRows = @($tests | ForEach-Object {
                [pscustomobject]@{
                    Name = [string]$_.Name
                    Status = [string]$_.Status
                    ExecutionState = [string]$_.ExecutionState
                }
            } | Sort-Object Name)
            $remaining = @($testRows | Where-Object { [string]$_.Status -ne "Passed" })

            [pscustomobject]@{
                CheckedAt = (Get-Date).ToString("s")
                Controller = $env:COMPUTERNAME
                Project = $ProjectName
                Total = $tests.Count
                Passed = @($testRows | Where-Object { [string]$_.Status -eq "Passed" }).Count
                Failed = @($testRows | Where-Object { [string]$_.Status -eq "Failed" }).Count
                NotRun = @($testRows | Where-Object { [string]$_.Status -eq "NotRun" }).Count
                Running = @($testRows | Where-Object { [string]$_.ExecutionState -eq "Running" }).Count
                Remaining = $remaining.Count
                Tests = $testRows
                RemainingTests = $remaining
                RemainingTestNames = @($remaining | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
            }
        }
        finally {
            [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($resolveHandler)
        }
    } -ArgumentList $ProjectName

    $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "latest-status.json") -Encoding UTF8
    @($status.RemainingTestNames) | Set-Content -LiteralPath (Join-Path $artifactDir "remaining-test-names.txt") -Encoding UTF8
    Write-Host ("Exported {0} remaining names from {1} tests; passed={2}, failed={3}, notrun={4}, running={5}." -f $status.Remaining, $status.Total, $status.Passed, $status.Failed, $status.NotRun, $status.Running)
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
