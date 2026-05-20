[CmdletBinding()]
param(
    [string]$VhlkVmName = "vhlk",
    [string[]]$Needles = @(
        "Camera Driver Profiles Interface APIs (Device Test)",
        "CCameraProfileTests",
        "InitializeWithSymbolicName",
        "0x80070057"
    ),
    [string]$ArtifactRoot = "",
    [int]$SinceHours = 24,
    [int]$ContextLines = 35,
    [int]$MaxFiles = 200,
    [switch]$FreshStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
. (Join-Path $scriptDir "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    Join-Path $repoRoot ("test-reports\vhlk-controller-log-scan-{0}" -f (Get-HvTimestamp))
} else {
    Resolve-HvPath -Path $ArtifactRoot -BasePath $repoRoot
}
$null = New-Item -ItemType Directory -Force -Path $artifactDir
$logPath = Join-Path $artifactDir "controller-log-scan.log"
$session = $null

function New-SafeSnippetName {
    param(
        [int]$Index,
        [string]$Path
    )

    $name = Split-Path -Leaf $Path
    $safe = $name -replace '[\\/:*?"<>|]', '_'
    if ($safe.Length -gt 60) {
        $safe = $safe.Substring(0, 60)
    }
    return ("match-{0:00}-{1}.txt" -f $Index, $safe)
}

try {
    if ($SinceHours -lt 1) {
        throw "SinceHours must be at least 1."
    }
    if ($ContextLines -lt 0) {
        throw "ContextLines must be 0 or greater."
    }
    if ($MaxFiles -lt 1) {
        throw "MaxFiles must be at least 1."
    }
    $Needles = @($Needles | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Needles.Count -lt 1) {
        throw "At least one search needle is required."
    }

    $envMap = Read-HvDotEnv
    $user = [string]$envMap["vhlk_VM_USERNAME"]
    $password = [string]$envMap["vhlk_VM_PASSWORD"]
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password)) {
        throw "Missing vhlk_VM_USERNAME or vhlk_VM_PASSWORD in .env"
    }
    $cred = [pscredential]::new($user, (New-HvSecureString -PlainText $password))

    if ($FreshStart) {
        $freshStart = Start-HvFreshControllerVm -VmName $VhlkVmName -Credential $cred -ReadyTimeoutSeconds 300 -LogPath $logPath
        $freshStart | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactDir "vm-fresh-start.json") -Encoding UTF8
    } else {
        Wait-HvVmReady -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 180 -PollIntervalSeconds 3 -RequirePowerShellDirect -LogPath $logPath | Out-Null
    }

    $session = Wait-HvPowerShellDirect -VmName $VhlkVmName -Credential $cred -TimeoutSeconds 180 -LogPath $logPath 6>$null
    $needlesJson = ConvertTo-Json -InputObject @($Needles) -Depth 3 -Compress
    $scan = Invoke-Command -Session $session -ScriptBlock {
        param(
            [string]$NeedlesJson,
            [int]$SinceHours,
            [int]$ContextLines,
            [int]$MaxFiles
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        $root = "C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Controller\WTTSystemLogs"
        if (-not (Test-Path -LiteralPath $root)) {
            throw "HLK controller log root not found: $root"
        }

        $decodedNeedles = ConvertFrom-Json -InputObject $NeedlesJson
        $Needles = @($decodedNeedles | ForEach-Object {
            $needle = ([string]$_).Trim()
            if (-not [string]::IsNullOrWhiteSpace($needle)) {
                $needle
            }
        })

        $cutoff = (Get-Date).AddHours(-1 * $SinceHours)
        $extensions = @(".wtl", ".log", ".txt", ".xml")
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $cutoff -and $extensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First $MaxFiles)

        $matches = @()
        $snippets = @()
        foreach ($file in $files) {
            $hits = @()
            try {
                $hits = @(Select-String -LiteralPath $file.FullName -Pattern $Needles -SimpleMatch -Context $ContextLines, $ContextLines -ErrorAction Stop)
            }
            catch {
                continue
            }

            foreach ($hit in $hits) {
                $line = [string]$hit.Line
                $lineLower = $line.ToLowerInvariant()
                $matchedNeedles = @(
                    foreach ($needleRaw in $Needles) {
                        $needle = [string]$needleRaw
                        if ($lineLower.Contains($needle.ToLowerInvariant())) {
                            $needle
                        }
                    }
                )

                $snippetLines = @()
                $pre = @($hit.Context.PreContext)
                for ($j = 0; $j -lt $pre.Count; $j++) {
                    $lineNumber = [Math]::Max(1, [int]$hit.LineNumber - $pre.Count + $j)
                    $snippetLines += ("{0}: {1}" -f $lineNumber, [string]$pre[$j])
                }
                $snippetLines += ("{0}: {1}" -f ([int]$hit.LineNumber), $line)
                $post = @($hit.Context.PostContext)
                for ($j = 0; $j -lt $post.Count; $j++) {
                    $lineNumber = [int]$hit.LineNumber + $j + 1
                    $snippetLines += ("{0}: {1}" -f $lineNumber, [string]$post[$j])
                }

                $match = [pscustomobject]@{
                    Path = [string]$file.FullName
                    LineNumber = [int]$hit.LineNumber
                    Needles = @($matchedNeedles)
                    Line = $line
                    LastWriteTime = $file.LastWriteTime.ToString("s")
                }
                $matches += $match
                $snippets += [pscustomobject]@{
                    Match = $match
                    Text = [string]::Join([Environment]::NewLine, @($snippetLines))
                }
            }
        }

        [pscustomobject]@{
            Root = $root
            SinceHours = $SinceHours
            ContextLines = $ContextLines
            MaxFiles = $MaxFiles
            ScannedFiles = $files.Count
            Needles = @($Needles)
            Matches = @($matches)
            Snippets = @($snippets)
            CheckedAt = (Get-Date).ToString("s")
        }
    } -ArgumentList $needlesJson, $SinceHours, $ContextLines, $MaxFiles

    $scan | Select-Object -Property * -ExcludeProperty Snippets |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $artifactDir "controller-log-scan.json") -Encoding UTF8

    $index = 0
    foreach ($snippet in @($scan.Snippets)) {
        $index++
        $path = Join-Path $artifactDir (New-SafeSnippetName -Index $index -Path ([string]$snippet.Match.Path))
        @(
            "Path: $($snippet.Match.Path)"
            "Line: $($snippet.Match.LineNumber)"
            "Needles: $([string]::Join(', ', @($snippet.Match.Needles)))"
            ""
            [string]$snippet.Text
        ) | Set-Content -LiteralPath $path -Encoding UTF8
    }

    Write-Host ("Scanned {0} files; found {1} matching lines." -f $scan.ScannedFiles, @($scan.Matches).Count)
    Write-Host ("Artifacts: {0}" -f $artifactDir)
    if (@($scan.Matches).Count -lt 1) {
        exit 2
    }
    exit 0
}
catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $artifactDir "error.txt") -Encoding UTF8
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Artifacts: {0}" -f $artifactDir) -ForegroundColor Yellow
    exit 1
}
finally {
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
