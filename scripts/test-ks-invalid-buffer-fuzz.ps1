[CmdletBinding()]
param(
    [string]$VmName = "driver-test",
    [string]$GuestUser = "Administrator",
    [System.Management.Automation.PSCredential]$GuestCredential,
    [string]$GuestPasswordPlaintext = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "hyperv-common.ps1")

Assert-HvAdministrator

$artifactDir = Get-HvArtifactDirectory -ArtifactRoot "test-reports\ks-invalid-buffer-fuzz"
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $artifactDir "ks-invalid-buffer-fuzz.log"
}

$guestCred = Get-HvGuestCredential -GuestCredential $GuestCredential -GuestUser $GuestUser -GuestPasswordPlaintext $GuestPasswordPlaintext
$session = Wait-HvPowerShellDirect -VmName $VmName -Credential $guestCred -LogPath $LogPath

try {
    $result = Invoke-HvGuestCommand -Session $session -LogPath $LogPath -ScriptBlock {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"

        $source = @"
using System;
using System.Runtime.InteropServices;

public static class VirtuaCamKsFuzz
{
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint DIGCF_PRESENT = 0x00000002;
    private const uint DIGCF_DEVICEINTERFACE = 0x00000010;
    private const uint IOCTL_KS_PROPERTY = 0x002F0003;
    private const uint KSPROPERTY_TYPE_SET = 0x00000001;
    private const uint KSPROPERTY_TYPE_GET = 0x00000002;
    private static readonly Guid PropSet = new Guid("CB043957-7B35-456E-9B61-5513930F4D8E");
    private static readonly Guid VideoCameraCategory = new Guid("E5323777-F976-4F5B-9B55-B94699C46E44");
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    private struct KSPROPERTY
    {
        public Guid Set;
        public uint Id;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(
        ref Guid classGuid,
        IntPtr enumerator,
        IntPtr hwndParent,
        uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr deviceInfoSet,
        IntPtr deviceInfoData,
        ref Guid interfaceClassGuid,
        uint memberIndex,
        ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr deviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData,
        IntPtr deviceInterfaceDetailData,
        int deviceInterfaceDetailDataSize,
        out int requiredSize,
        IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        IntPtr handle,
        uint dwIoControlCode,
        IntPtr inBuffer,
        uint nInBufferSize,
        IntPtr outBuffer,
        uint nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string Run()
    {
        string path = FindVirtuaCamPath();
        if (String.IsNullOrEmpty(path)) {
            return "SKIP: VirtuaCam KS camera interface not found";
        }

        IntPtr handle = CreateFile(
            path,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            0,
            IntPtr.Zero);
        if (handle == IntPtr.Zero || handle == INVALID_HANDLE_VALUE) {
            return "SKIP: CreateFile failed gle=" + Marshal.GetLastWin32Error();
        }

        try {
            int failuresSeen = 0;
            failuresSeen += ExpectFailure(handle, 5, KSPROPERTY_TYPE_SET, IntPtr.Zero, 4, "null scalar");

            IntPtr shortBuffer = Marshal.AllocHGlobal(1);
            try {
                failuresSeen += ExpectFailure(handle, 5, KSPROPERTY_TYPE_SET, shortBuffer, 1, "short scalar");
            }
            finally {
                Marshal.FreeHGlobal(shortBuffer);
            }

            IntPtr misalignedBase = Marshal.AllocHGlobal(8);
            try {
                failuresSeen += ExpectFailure(handle, 5, KSPROPERTY_TYPE_SET, IntPtr.Add(misalignedBase, 1), 4, "misaligned scalar");
            }
            finally {
                Marshal.FreeHGlobal(misalignedBase);
            }

            failuresSeen += ExpectFailure(handle, 6, KSPROPERTY_TYPE_SET, new IntPtr(0x1234), 4, "invalid scalar pointer");
            failuresSeen += ExpectFailure(handle, 3, KSPROPERTY_TYPE_GET, IntPtr.Zero, 112, "null status output");

            if (failuresSeen != 5) {
                throw new InvalidOperationException("Expected five rejected fuzz calls, saw " + failuresSeen);
            }
            return "PASS: KS invalid-buffer fuzz calls rejected";
        }
        finally {
            CloseHandle(handle);
        }
    }

    private static int ExpectFailure(IntPtr handle, uint propertyId, uint flags, IntPtr data, uint dataLength, string name)
    {
        KSPROPERTY property = new KSPROPERTY { Set = PropSet, Id = propertyId, Flags = flags };
        int propertySize = Marshal.SizeOf<KSPROPERTY>();
        IntPtr propertyPtr = Marshal.AllocHGlobal(propertySize);
        try {
            Marshal.StructureToPtr(property, propertyPtr, false);
            uint returned;
            bool ok = DeviceIoControl(handle, IOCTL_KS_PROPERTY, propertyPtr, (uint)propertySize, data, dataLength, out returned, IntPtr.Zero);
            if (ok) {
                throw new InvalidOperationException(name + " unexpectedly succeeded");
            }
            return 1;
        }
        finally {
            Marshal.FreeHGlobal(propertyPtr);
        }
    }

    private static string FindVirtuaCamPath()
    {
        Guid category = VideoCameraCategory;
        IntPtr set = SetupDiGetClassDevs(ref category, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == INVALID_HANDLE_VALUE) {
            return null;
        }

        try {
            for (uint index = 0; ; index++) {
                SP_DEVICE_INTERFACE_DATA data = new SP_DEVICE_INTERFACE_DATA();
                data.cbSize = Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>();
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref category, index, ref data)) {
                    return null;
                }

                int required;
                SetupDiGetDeviceInterfaceDetail(set, ref data, IntPtr.Zero, 0, out required, IntPtr.Zero);
                if (required <= 0) {
                    continue;
                }

                IntPtr detail = Marshal.AllocHGlobal(required);
                try {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref data, detail, required, out required, IntPtr.Zero)) {
                        continue;
                    }

                    string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                    if (!String.IsNullOrEmpty(path) &&
                        path.IndexOf("avshws", StringComparison.OrdinalIgnoreCase) >= 0) {
                        return path;
                    }
                }
                finally {
                    Marshal.FreeHGlobal(detail);
                }
            }
        }
        finally {
            SetupDiDestroyDeviceInfoList(set);
        }
    }
}
"@

        Add-Type -TypeDefinition $source -Language CSharp
        [VirtuaCamKsFuzz]::Run()
    }

    Set-Content -LiteralPath (Join-Path $artifactDir "ks-invalid-buffer-fuzz.txt") -Value $result
    Write-Host $result
}
finally {
    if ($session) {
        Remove-PSSession $session
    }
}
