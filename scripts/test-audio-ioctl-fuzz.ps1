[CmdletBinding()]
param(
    [string]$DevicePath = "\\.\VirtuaCamMicBridge",
    [switch]$AllowMissingBridge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$source = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class VirtuaCamMicIoctlProbe {
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    private const uint FILE_DEVICE_VIRTUACAM_MIC = 0x8337;
    private const uint FILE_READ_DATA = 0x0001;
    private const uint FILE_WRITE_DATA = 0x0002;
    private const uint METHOD_BUFFERED = 0;
    public const int HeaderSize = 16;
    public const int PacketBytes = 1920;
    public static readonly uint WritePacket = CtlCode(FILE_DEVICE_VIRTUACAM_MIC, 0x800, METHOD_BUFFERED, FILE_WRITE_DATA);
    public static readonly uint GetStatus = CtlCode(FILE_DEVICE_VIRTUACAM_MIC, 0x801, METHOD_BUFFERED, FILE_READ_DATA);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr device, uint code, byte[] inBuffer, int inSize, byte[] outBuffer, int outSize, out int bytesReturned, IntPtr overlapped);

    private static uint CtlCode(uint deviceType, uint function, uint method, uint access) {
        return (deviceType << 16) | (access << 14) | (function << 2) | method;
    }

    public static IntPtr Open(string path) {
        IntPtr handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle == INVALID_HANDLE_VALUE) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Open VirtuaCam mic bridge failed.");
        }
        return handle;
    }

    public static void Close(IntPtr handle) {
        if (handle != IntPtr.Zero && handle != INVALID_HANDLE_VALUE) {
            CloseHandle(handle);
        }
    }

    public static bool Ioctl(IntPtr handle, uint code, byte[] input, byte[] output, out int lastError, out int returned) {
        returned = 0;
        bool ok = DeviceIoControl(handle, code, input, input == null ? 0 : input.Length, output, output == null ? 0 : output.Length, out returned, IntPtr.Zero);
        lastError = ok ? 0 : Marshal.GetLastWin32Error();
        return ok;
    }
}
"@

if (-not ([System.Management.Automation.PSTypeName]'VirtuaCamMicIoctlProbe').Type) {
    Add-Type -TypeDefinition $source
}

function Assert-False([bool]$Value, [string]$Name) {
    if ($Value) { throw "$Name unexpectedly succeeded" }
}

function Assert-True([bool]$Value, [string]$Name, [int]$LastError) {
    if (-not $Value) { throw "$Name failed: Win32=$LastError" }
}

$handle = $null
try {
    $handle = [VirtuaCamMicIoctlProbe]::Open($DevicePath)
}
catch {
    if (-not $AllowMissingBridge) {
        throw
    }

    $mic = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like "ROOT\VIRTUACAMMIC\*" })
    $bad = @($mic | Where-Object { $_.Status -and $_.Status -ne "OK" })
    if ($mic.Count -eq 0 -or $bad.Count -gt 0) {
        throw "VirtuaCam microphone endpoint is missing or not OK while bridge is unavailable."
    }

    Write-Host "PASS VirtuaCam microphone endpoint OK; user-mode feed bridge unavailable"
    exit 0
}
try {
    [int]$err = 0
    [int]$returned = 0

    $short = New-Object byte[] ([VirtuaCamMicIoctlProbe]::HeaderSize)
    Assert-False ([VirtuaCamMicIoctlProbe]::Ioctl($handle, [VirtuaCamMicIoctlProbe]::WritePacket, $short, $null, [ref]$err, [ref]$returned)) "short write packet"

    $bad = New-Object byte[] ([VirtuaCamMicIoctlProbe]::HeaderSize + [VirtuaCamMicIoctlProbe]::PacketBytes)
    [BitConverter]::GetBytes([uint32]4).CopyTo($bad, 0)
    [BitConverter]::GetBytes([uint32]1).CopyTo($bad, 4)
    Assert-False ([VirtuaCamMicIoctlProbe]::Ioctl($handle, [VirtuaCamMicIoctlProbe]::WritePacket, $bad, $null, [ref]$err, [ref]$returned)) "bad packet header"

    $packet = New-Object byte[] ([VirtuaCamMicIoctlProbe]::HeaderSize + [VirtuaCamMicIoctlProbe]::PacketBytes)
    [BitConverter]::GetBytes([uint32][VirtuaCamMicIoctlProbe]::PacketBytes).CopyTo($packet, 0)
    [BitConverter]::GetBytes([uint32]480).CopyTo($packet, 4)
    [BitConverter]::GetBytes([uint64]1).CopyTo($packet, 8)
    Assert-True ([VirtuaCamMicIoctlProbe]::Ioctl($handle, [VirtuaCamMicIoctlProbe]::WritePacket, $packet, $null, [ref]$err, [ref]$returned)) "valid packet write" $err

    $tinyStatus = New-Object byte[] 4
    Assert-False ([VirtuaCamMicIoctlProbe]::Ioctl($handle, [VirtuaCamMicIoctlProbe]::GetStatus, $null, $tinyStatus, [ref]$err, [ref]$returned)) "short status output"

    $status = New-Object byte[] 40
    Assert-True ([VirtuaCamMicIoctlProbe]::Ioctl($handle, [VirtuaCamMicIoctlProbe]::GetStatus, $null, $status, [ref]$err, [ref]$returned)) "status query" $err
    if ($returned -lt 40) {
        throw "status query returned too few bytes: $returned"
    }
    $packets = [BitConverter]::ToUInt64($status, 0)
    if ($packets -lt 1) {
        throw "status packets counter did not advance"
    }

    Write-Host "PASS VirtuaCam microphone IOCTL fuzz"
}
finally {
    [VirtuaCamMicIoctlProbe]::Close($handle)
}

