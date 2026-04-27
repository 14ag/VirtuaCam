[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [string]$GuestPackageRoot = "C:\Temp\VirtuaCamHyperV\current\output",
    [string]$ArtifactRoot = "",
    [string]$HostDebuggerLogPath = "",
    [int]$EventHoursBack = 4,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { Get-HvArtifactDirectory } else { Resolve-HvPath -Path $ArtifactRoot }
$null = New-Item -ItemType Directory -Force -Path $artifactDir

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "hyperv-collect.log"
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath

$guestRunRoot = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
    param($HoursBack, $PackageRoot)

    function Save-Text {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Text
        )

        $dir = Split-Path -Parent $Path
        if ($dir) {
            $null = New-Item -ItemType Directory -Force -Path $dir
        }
        Set-Content -LiteralPath $Path -Value $Text
    }

    function Get-SetupApiSlice {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [string[]]$Patterns = @("avshws.inf", "ROOT\AVSHWS"),
            [int]$ContextLines = 20
        )

        if (-not (Test-Path -LiteralPath $Path)) {
            return "setupapi.dev.log missing: $Path"
        }

        $lines = Get-Content -LiteralPath $Path
        $hits = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($pattern in $Patterns) {
                if ($lines[$i] -match [Regex]::Escape($pattern)) {
                    $hits.Add($i)
                    break
                }
            }
        }

        if ($hits.Count -eq 0) {
            return "No avshws references found in setupapi.dev.log"
        }

        $ranges = New-Object System.Collections.Generic.List[object]
        foreach ($hit in $hits) {
            $start = [Math]::Max(0, $hit - $ContextLines)
            $end = [Math]::Min($lines.Count - 1, $hit + $ContextLines)
            $ranges.Add([pscustomobject]@{ Start = $start; End = $end })
        }

        $merged = New-Object System.Collections.Generic.List[object]
        foreach ($range in $ranges | Sort-Object Start, End) {
            if ($merged.Count -eq 0) {
                $merged.Add($range)
                continue
            }

            $last = $merged[$merged.Count - 1]
            if ($range.Start -le ($last.End + 1)) {
                $last.End = [Math]::Max($last.End, $range.End)
            } else {
                $merged.Add($range)
            }
        }

        $sb = New-Object System.Text.StringBuilder
        foreach ($range in $merged) {
            [void]$sb.AppendLine(("===== setupapi lines {0}-{1} =====" -f ($range.Start + 1), ($range.End + 1)))
            for ($i = $range.Start; $i -le $range.End; $i++) {
                [void]$sb.AppendLine($lines[$i])
            }
            [void]$sb.AppendLine()
        }
        return $sb.ToString()
    }

    $collectRoot = Join-Path $env:TEMP ("VirtuaCamHyperVCollect-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $null = New-Item -ItemType Directory -Force -Path $collectRoot
    $guestOut = Join-Path $collectRoot "guest"
    $null = New-Item -ItemType Directory -Force -Path $guestOut

    Save-Text -Path (Join-Path $guestOut "computer.txt") -Text ((hostname) | Out-String)
    Save-Text -Path (Join-Path $guestOut "bcdedit.txt") -Text ((& "$env:WINDIR\System32\bcdedit.exe" /enum 2>&1 | Out-String))
    Save-Text -Path (Join-Path $guestOut "verifier.txt") -Text ((verifier /querysettings 2>&1 | Out-String))
    Save-Text -Path (Join-Path $guestOut "pnputil-camera.txt") -Text ((& "$env:WINDIR\System32\pnputil.exe" /enum-devices /class Camera 2>&1 | Out-String))
    Save-Text -Path (Join-Path $guestOut "pnputil-drivers.txt") -Text ((& "$env:WINDIR\System32\pnputil.exe" /enum-drivers 2>&1 | Out-String))

    $crashControl = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" |
        Select-Object CrashDumpEnabled, MinidumpDir, DumpFile, AlwaysKeepMemoryDump
    $crashControl | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $guestOut "crashcontrol.json")

    $signedDriver = Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceID -like "ROOT\AVSHWS\*" } |
        Select-Object DeviceName, DeviceID, DriverVersion, DriverDate, InfName, Manufacturer, IsSigned
    $signedDriver | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $guestOut "avshws-signed-driver.json")

    $cameraDevices = Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.PNPDeviceID -like "ROOT\AVSHWS\*" } |
        Select-Object Name, DeviceID, Status, ConfigManagerErrorCode, PNPDeviceID
    $cameraDevices | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $guestOut "avshws-devices.json")

    $recentSystem = Get-WinEvent -FilterHashtable @{ LogName = "System"; StartTime = (Get-Date).AddHours(-1 * $HoursBack) } |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
    $recentSystem | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $guestOut "system-events.json")

    $systemEvtx = Join-Path $guestOut "system.evtx"
    & wevtutil.exe epl System $systemEvtx | Out-Null

    $setupApiSlice = Get-SetupApiSlice -Path "C:\Windows\INF\setupapi.dev.log"
    Save-Text -Path (Join-Path $guestOut "setupapi-avshws.txt") -Text $setupApiSlice

    $miniDir = "C:\Windows\Minidump"
    if (Test-Path -LiteralPath $miniDir) {
        $dumpOut = Join-Path $guestOut "minidump"
        $null = New-Item -ItemType Directory -Force -Path $dumpOut
        Get-ChildItem -LiteralPath $miniDir -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5 |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dumpOut $_.Name) -Force
            }
    }

    if (Test-Path -LiteralPath $PackageRoot) {
        $pkgOut = Join-Path $guestOut "package-output"
        $null = New-Item -ItemType Directory -Force -Path $pkgOut
        foreach ($name in @("logs", "VirtuaCam.exe", "VirtuaCamProcess.exe", "avshws.inf", "avshws.sys", "avshws.cat")) {
            $src = Join-Path $PackageRoot $name
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $pkgOut $name) -Recurse -Force
            }
        }
    }

    return $collectRoot
} -ArgumentList $EventHoursBack, $GuestPackageRoot

try {
    Copy-HvFromGuest -Session $session -GuestPath $guestRunRoot -LocalPath (Join-Path $artifactDir "guest-collect") -Recurse -LogPath $LogPath
}
finally {
    try {
        Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
            param($PathToDelete)
            if (Test-Path -LiteralPath $PathToDelete) {
                Remove-Item -LiteralPath $PathToDelete -Recurse -Force
            }
        } -ArgumentList $guestRunRoot | Out-Null
    }
    catch {
        Write-HvLog -Message ("Guest cleanup skipped: {0}" -f $_.Exception.Message) -LogPath $LogPath -Level WARN
    }

    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
}

if (-not [string]::IsNullOrWhiteSpace($HostDebuggerLogPath)) {
    $resolvedDebuggerLog = Resolve-HvPath -Path $HostDebuggerLogPath
    $targetDebuggerLog = Join-Path $artifactDir (Split-Path -Leaf $resolvedDebuggerLog)
    if (Test-Path -LiteralPath $resolvedDebuggerLog) {
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($resolvedDebuggerLog, $targetDebuggerLog)) {
            Write-HvLog -Message ("Host debugger log already in artifact dir: {0}" -f $resolvedDebuggerLog) -LogPath $LogPath
        } else {
            Copy-Item -LiteralPath $resolvedDebuggerLog -Destination $targetDebuggerLog -Force
        }
    } else {
        Write-HvLog -Message ("Host debugger log missing: {0}" -f $resolvedDebuggerLog) -LogPath $LogPath -Level WARN
    }
}

[pscustomobject]@{
    VmName      = $VmName
    ArtifactDir = $artifactDir
    GuestPath   = $GuestPackageRoot
}
