#include "definitions.h"
#include "VirtuaCamMicBridge.h"
#include "..\..\..\shared\VirtuaCamAudioAbi.h"
#include <wdmsec.h>

#define VIRTUACAM_MIC_BRIDGE_POOLTAG 'cMvV'

typedef struct _VIRTUACAM_MIC_BRIDGE_STATE {
    PDEVICE_OBJECT ControlDevice;
    BOOLEAN SymbolicLinkCreated;
    PUCHAR Buffer;
    SIZE_T Capacity;
    SIZE_T ReadOffset;
    SIZE_T WriteOffset;
    SIZE_T Queued;
    uint64_t Packets;
    uint64_t Frames;
    uint64_t Underruns;
    uint64_t Drops;
    KSPIN_LOCK Lock;
} VIRTUACAM_MIC_BRIDGE_STATE;

static VIRTUACAM_MIC_BRIDGE_STATE g_MicBridge = {};
static const GUID GUID_VIRTUACAM_MIC_BRIDGE =
{ 0x9b965f90, 0x856b, 0x4f08, { 0xa8, 0x61, 0x5c, 0x2e, 0x3a, 0xc8, 0xf1, 0x17 } };

static
VOID
VirtuaCamMicBridgeResetLocked()
{
    g_MicBridge.ReadOffset = 0;
    g_MicBridge.WriteOffset = 0;
    g_MicBridge.Queued = 0;
}

static
VOID
VirtuaCamMicBridgeWritePacketLocked(
    _In_reads_bytes_(ByteCount) const UCHAR* Data,
    _In_ SIZE_T ByteCount,
    _In_ uint32_t FrameCount
)
{
    if (!g_MicBridge.Buffer || g_MicBridge.Capacity == 0 || !Data || ByteCount == 0)
    {
        return;
    }

    const UCHAR* source = Data;
    SIZE_T remaining = ByteCount;
    if (remaining > g_MicBridge.Capacity)
    {
        source += remaining - g_MicBridge.Capacity;
        remaining = g_MicBridge.Capacity;
        g_MicBridge.Drops++;
        VirtuaCamMicBridgeResetLocked();
    }

    SIZE_T freeBytes = g_MicBridge.Capacity - g_MicBridge.Queued;
    if (remaining > freeBytes)
    {
        SIZE_T dropBytes = remaining - freeBytes;
        g_MicBridge.ReadOffset = (g_MicBridge.ReadOffset + dropBytes) % g_MicBridge.Capacity;
        g_MicBridge.Queued -= dropBytes;
        g_MicBridge.Drops++;
    }

    SIZE_T copied = 0;
    while (copied < remaining)
    {
        SIZE_T run = min(remaining - copied, g_MicBridge.Capacity - g_MicBridge.WriteOffset);
        RtlCopyMemory(g_MicBridge.Buffer + g_MicBridge.WriteOffset, source + copied, run);
        g_MicBridge.WriteOffset = (g_MicBridge.WriteOffset + run) % g_MicBridge.Capacity;
        g_MicBridge.Queued += run;
        copied += run;
    }

    g_MicBridge.Packets++;
    g_MicBridge.Frames += FrameCount;
}

VOID
VirtuaCamMicBridgeReadAudio(
    _Out_writes_bytes_(ByteCount) PUCHAR Buffer,
    _In_ SIZE_T ByteCount
)
{
    if (!Buffer || ByteCount == 0)
    {
        return;
    }

    KIRQL oldIrql;
    SIZE_T copied = 0;

    KeAcquireSpinLock(&g_MicBridge.Lock, &oldIrql);
    while (copied < ByteCount && g_MicBridge.Queued > 0 && g_MicBridge.Buffer)
    {
        SIZE_T run = min(ByteCount - copied, g_MicBridge.Capacity - g_MicBridge.ReadOffset);
        run = min(run, g_MicBridge.Queued);
        RtlCopyMemory(Buffer + copied, g_MicBridge.Buffer + g_MicBridge.ReadOffset, run);
        g_MicBridge.ReadOffset = (g_MicBridge.ReadOffset + run) % g_MicBridge.Capacity;
        g_MicBridge.Queued -= run;
        copied += run;
    }

    if (copied < ByteCount)
    {
        RtlZeroMemory(Buffer + copied, ByteCount - copied);
        g_MicBridge.Underruns++;
    }
    KeReleaseSpinLock(&g_MicBridge.Lock, oldIrql);
}

static
NTSTATUS
VirtuaCamMicBridgeGetStatusLocked(
    _Out_ VIRTUACAM_MIC_STATUS* Status
)
{
    if (!Status)
    {
        return STATUS_INVALID_PARAMETER;
    }

    Status->packets = g_MicBridge.Packets;
    Status->frames = g_MicBridge.Frames;
    Status->underruns = g_MicBridge.Underruns;
    Status->drops = g_MicBridge.Drops;
    Status->queuedBytes = (uint32_t)min(g_MicBridge.Queued, (SIZE_T)UINT32_MAX);

    return STATUS_SUCCESS;
}

_Dispatch_type_(IRP_MJ_CREATE)
_Dispatch_type_(IRP_MJ_CLOSE)
_Dispatch_type_(IRP_MJ_CLEANUP)
NTSTATUS
VirtuaCamMicBridgeDispatchCreateClose(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
)
{
    if (DeviceObject != g_MicBridge.ControlDevice)
    {
        return PcDispatchIrp(DeviceObject, Irp);
    }

    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

_Dispatch_type_(IRP_MJ_DEVICE_CONTROL)
NTSTATUS
VirtuaCamMicBridgeDispatchDeviceControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
)
{
    if (DeviceObject != g_MicBridge.ControlDevice)
    {
        return PcDispatchIrp(DeviceObject, Irp);
    }

    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    const ULONG ioControlCode = stack->Parameters.DeviceIoControl.IoControlCode;
    const ULONG inputLength = stack->Parameters.DeviceIoControl.InputBufferLength;
    const ULONG outputLength = stack->Parameters.DeviceIoControl.OutputBufferLength;
    PVOID systemBuffer = Irp->AssociatedIrp.SystemBuffer;
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    ULONG_PTR information = 0;

    switch (ioControlCode)
    {
    case IOCTL_VIRTUACAM_MIC_WRITE_PACKET:
    {
        const ULONG expectedLength = sizeof(VIRTUACAM_MIC_PACKET_HEADER) + VIRTUACAM_MIC_PACKET_BYTES;
        if (inputLength != expectedLength || systemBuffer == NULL)
        {
            status = STATUS_INVALID_BUFFER_SIZE;
            break;
        }

        const auto header = static_cast<const VIRTUACAM_MIC_PACKET_HEADER*>(systemBuffer);
        if (header->size != VIRTUACAM_MIC_PACKET_BYTES ||
            header->frameCount != VIRTUACAM_MIC_PACKET_FRAMES)
        {
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        KIRQL oldIrql;
        KeAcquireSpinLock(&g_MicBridge.Lock, &oldIrql);
        VirtuaCamMicBridgeWritePacketLocked(
            reinterpret_cast<const UCHAR*>(header + 1),
            header->size,
            header->frameCount);
        KeReleaseSpinLock(&g_MicBridge.Lock, oldIrql);
        status = STATUS_SUCCESS;
        break;
    }
    case IOCTL_VIRTUACAM_MIC_GET_STATUS:
    {
        if (outputLength < sizeof(VIRTUACAM_MIC_STATUS) || systemBuffer == NULL)
        {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        auto statusBuffer = static_cast<VIRTUACAM_MIC_STATUS*>(systemBuffer);
        KIRQL oldIrql;
        KeAcquireSpinLock(&g_MicBridge.Lock, &oldIrql);
        status = VirtuaCamMicBridgeGetStatusLocked(statusBuffer);
        KeReleaseSpinLock(&g_MicBridge.Lock, oldIrql);
        if (NT_SUCCESS(status))
        {
            information = sizeof(VIRTUACAM_MIC_STATUS);
        }
        break;
    }
    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    Irp->IoStatus.Status = status;
    Irp->IoStatus.Information = information;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

NTSTATUS
VirtuaCamMicBridgeInitialize(
    _In_ PDRIVER_OBJECT DriverObject
)
{
#if VIRTUACAM_MIC_ENABLE_USERMODE_FEED
    if (!DriverObject)
    {
        return STATUS_INVALID_PARAMETER;
    }
#else
    UNREFERENCED_PARAMETER(DriverObject);
#endif

    KeInitializeSpinLock(&g_MicBridge.Lock);
    g_MicBridge.Capacity = VIRTUACAM_MIC_BYTES_PER_SECOND * 2u;
    g_MicBridge.Buffer = static_cast<PUCHAR>(
        ExAllocatePool2(POOL_FLAG_NON_PAGED, g_MicBridge.Capacity, VIRTUACAM_MIC_BRIDGE_POOLTAG));
    if (!g_MicBridge.Buffer)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(g_MicBridge.Buffer, g_MicBridge.Capacity);

#if VIRTUACAM_MIC_ENABLE_USERMODE_FEED
    UNICODE_STRING deviceName = RTL_CONSTANT_STRING(VIRTUACAM_MIC_NT_DEVICE_NAME);
    UNICODE_STRING sddl = RTL_CONSTANT_STRING(L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)");
    NTSTATUS status = IoCreateDeviceSecure(
        DriverObject,
        0,
        &deviceName,
        FILE_DEVICE_VIRTUACAM_MIC,
        FILE_DEVICE_SECURE_OPEN,
        FALSE,
        &sddl,
        &GUID_VIRTUACAM_MIC_BRIDGE,
        &g_MicBridge.ControlDevice);
    if (!NT_SUCCESS(status))
    {
        VirtuaCamMicBridgeShutdown();
        return status;
    }

    g_MicBridge.ControlDevice->Flags |= DO_BUFFERED_IO;

    UNICODE_STRING symbolicLink = RTL_CONSTANT_STRING(VIRTUACAM_MIC_DOS_DEVICE_NAME);
    status = IoCreateSymbolicLink(&symbolicLink, &deviceName);
    if (!NT_SUCCESS(status))
    {
        VirtuaCamMicBridgeShutdown();
        return status;
    }
    g_MicBridge.SymbolicLinkCreated = TRUE;

    g_MicBridge.ControlDevice->Flags &= ~DO_DEVICE_INITIALIZING;
#endif
    return STATUS_SUCCESS;
}

VOID
VirtuaCamMicBridgeShutdown()
{
    if (g_MicBridge.SymbolicLinkCreated)
    {
        UNICODE_STRING symbolicLink = RTL_CONSTANT_STRING(VIRTUACAM_MIC_DOS_DEVICE_NAME);
        IoDeleteSymbolicLink(&symbolicLink);
        g_MicBridge.SymbolicLinkCreated = FALSE;
    }

    if (g_MicBridge.ControlDevice)
    {
        IoDeleteDevice(g_MicBridge.ControlDevice);
        g_MicBridge.ControlDevice = NULL;
    }

    if (g_MicBridge.Buffer)
    {
        ExFreePoolWithTag(g_MicBridge.Buffer, VIRTUACAM_MIC_BRIDGE_POOLTAG);
        g_MicBridge.Buffer = NULL;
    }

    g_MicBridge.Capacity = 0;
    g_MicBridge.ReadOffset = 0;
    g_MicBridge.WriteOffset = 0;
    g_MicBridge.Queued = 0;
}
