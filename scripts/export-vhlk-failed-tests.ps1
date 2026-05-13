[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string]$ProjectName = "VirtuaCam",
    [string]$ArtifactRoot = "",
    [switch]$NoOpenController
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

$envMap = Read-HvDotEnv
$user = [string]$envMap["vhlk_VM_USERNAME"]
$password = [string]$envMap["vhlk_VM_PASSWORD"]
if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password)) {
    throw "Missing vhlk_VM_USERNAME or vhlk_VM_PASSWORD in .env"
}
$cred = [pscredential]::new($user, (ConvertTo-SecureString $password -AsPlainText -Force))
$session = $null

try {
    $session = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 180 -LogPath $logPath 6>$null
    $status = Invoke-Command -Session $session -ScriptBlock {
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
        $failures = @($tests | Where-Object { [string]$_.Status -eq "Failed" } | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                Status = [string]$_.Status
                ExecutionState = [string]$_.ExecutionState
            }
        } | Sort-Object Name)

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
        }
    } -ArgumentList $ProjectName

    $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "latest-status.json") -Encoding UTF8
    @($status.FailedTestNames) | Set-Content -LiteralPath (Join-Path $artifactDir "failed-test-names.txt") -Encoding UTF8
    Write-Host ("Exported {0} failed names from {1} tests." -f $status.Failed, $status.Total)
    Write-Host ("Artifacts: {0}" -f $artifactDir)
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
