/**************************************************************************

    AVStream Simulated Hardware Sample

    Copyright (c) 2001, Microsoft Corporation.

    File:

        filter.cpp

    Abstract:

        This file contains the filter level implementation for the 
        capture filter.

    History:

        created 3/12/2001

**************************************************************************/

#include "avshws.h"

/**************************************************************************

    PAGEABLE CODE

**************************************************************************/

#ifdef ALLOC_PRAGMA
#pragma code_seg("PAGE")
#endif // ALLOC_PRAGMA

namespace
{
    const GUID VirtuaCamFilterReferenceGuid =
        { 0x6b2f0f9a, 0x4fcb, 0x4c93, { 0x95, 0x80, 0x21, 0x52, 0xa7, 0x6e, 0x2d, 0x44 } };

    const GUID VirtuaCamCustomProfileGuid =
        { 0x0bb8a130, 0x17c4, 0x40a4, { 0xa1, 0x7a, 0x7c, 0xb4, 0x43, 0x7f, 0x90, 0xe2 } };

    const KSCAMERA_PROFILE_MEDIAINFO CameraProfileMediaInfos[] = {
        { { 1920, 1080 }, { 30, 1 }, 0, 0, 0, 0, 0 },
        { { 640, 480 }, { 30, 1 }, 0, 0, 0, 0, 0 },
        { { 1080, 1920 }, { 30, 1 }, 0, 0, 0, 0, 0 },
        { { 480, 640 }, { 30, 1 }, 0, 0, 0, 0, 0 }
    };

    KSCAMERA_PROFILE_PININFO CameraProfilePins[] = {
        {
            STATICGUIDOF(PINNAME_VIDEO_PREVIEW),
            { 0, KSCameraProfileSensorType_RGB },
            SIZEOF_ARRAY(CameraProfileMediaInfos),
            const_cast<PKSCAMERA_PROFILE_MEDIAINFO>(CameraProfileMediaInfos)
        },
        {
            STATICGUIDOF(PINNAME_VIDEO_CAPTURE),
            { 1, KSCameraProfileSensorType_RGB },
            SIZEOF_ARRAY(CameraProfileMediaInfos),
            const_cast<PKSCAMERA_PROFILE_MEDIAINFO>(CameraProfileMediaInfos)
        },
        {
            STATICGUIDOF(PINNAME_VIDEO_STILL),
            { 2, KSCameraProfileSensorType_RGB },
            SIZEOF_ARRAY(CameraProfileMediaInfos),
            const_cast<PKSCAMERA_PROFILE_MEDIAINFO>(CameraProfileMediaInfos)
        }
    };

    const GUID CameraProfileIds[] = {
        STATICGUIDOF(KSCAMERAPROFILE_VideoConferencing),
        STATICGUIDOF(KSCAMERAPROFILE_VideoRecording),
        STATICGUIDOF(KSCAMERAPROFILE_HighQualityPhoto),
        STATICGUIDOF(KSCAMERAPROFILE_BalancedVideoAndPhoto),
        VirtuaCamCustomProfileGuid
    };

    KSCAMERA_EXTENDEDPROP_PROFILE CurrentCameraProfile = {
        STATICGUIDOF(KSCAMERAPROFILE_Legacy),
        0,
        0
    };

    ULONG GetPropertyDataLength(_In_ PIRP Irp)
    {
        PIO_STACK_LOCATION irpStack = IoGetCurrentIrpStackLocation(Irp);
        return irpStack->Parameters.DeviceIoControl.OutputBufferLength;
    }

    NTSTATUS ValidatePrivatePropertyAccess(_In_ PIRP Irp, _In_ ACCESS_MASK desiredAccess)
    {
        return IoValidateDeviceIoControlAccess(Irp, desiredAccess);
    }

    bool ShouldProbePropertyData(_In_ PIRP Irp, _In_opt_ PVOID Data)
    {
        return Irp->RequestorMode != KernelMode && Data == Irp->UserBuffer;
    }

    NTSTATUS CopyPropertyDataFromCaller(
        _In_ PIRP Irp,
        _In_reads_bytes_(length) PVOID Data,
        _In_ ULONG length,
        _Out_writes_bytes_(length) PVOID destination,
        _In_ ULONG alignment
        )
    {
        if (!Data || !destination || length == 0) {
            return STATUS_INVALID_PARAMETER;
        }

        __try {
            if (ShouldProbePropertyData(Irp, Data)) {
                ProbeForRead(Data, length, alignment);
            }
            RtlCopyMemory(destination, Data, length);
        }
        __except (EXCEPTION_EXECUTE_HANDLER) {
            return GetExceptionCode();
        }

        return STATUS_SUCCESS;
    }

    NTSTATUS CopyPropertyDataToCaller(
        _In_ PIRP Irp,
        _Out_writes_bytes_(length) PVOID Data,
        _In_reads_bytes_(length) const void* source,
        _In_ ULONG length,
        _In_ ULONG alignment
        )
    {
        if (!Data || !source || length == 0) {
            return STATUS_INVALID_PARAMETER;
        }

        __try {
            if (ShouldProbePropertyData(Irp, Data)) {
                ProbeForWrite(Data, length, alignment);
            }
            RtlCopyMemory(Data, source, length);
        }
        __except (EXCEPTION_EXECUTE_HANDLER) {
            return GetExceptionCode();
        }

        return STATUS_SUCCESS;
    }

    NTSTATUS CapturePropertyDataToPool(
        _In_ PIRP Irp,
        _In_reads_bytes_(length) PVOID Data,
        _In_ ULONG length,
        _Outptr_result_bytebuffer_(length) PUCHAR* capturedData
        )
    {
        if (!capturedData) {
            return STATUS_INVALID_PARAMETER;
        }
        *capturedData = NULL;

        if (!Data || length == 0) {
            return STATUS_INVALID_PARAMETER;
        }

        PUCHAR buffer = reinterpret_cast<PUCHAR>(
            ExAllocatePool2(
                POOL_FLAG_NON_PAGED,
                length,
                AVSHWS_POOLTAG));
        if (!buffer) {
            return STATUS_INSUFFICIENT_RESOURCES;
        }

        NTSTATUS status = CopyPropertyDataFromCaller(Irp, Data, length, buffer, 1);
        if (!NT_SUCCESS(status)) {
            ExFreePoolWithTag(buffer, AVSHWS_POOLTAG);
            return status;
        }

        *capturedData = buffer;
        return STATUS_SUCCESS;
    }

    NTSTATUS ReadPropertyUlong(_In_ PIRP Irp, _Inout_ PVOID Data, _Out_ PULONG value)
    {
        if (GetPropertyDataLength(Irp) != sizeof(ULONG)) {
            return STATUS_INVALID_BUFFER_SIZE;
        }
        return CopyPropertyDataFromCaller(Irp, Data, sizeof(ULONG), value, __alignof(ULONG));
    }

    NTSTATUS ReadPropertyHandle(_In_ PIRP Irp, _Inout_ PVOID Data, _Out_ PHANDLE value)
    {
        if (GetPropertyDataLength(Irp) != sizeof(HANDLE)) {
            return STATUS_INVALID_BUFFER_SIZE;
        }
        return CopyPropertyDataFromCaller(Irp, Data, sizeof(HANDLE), value, __alignof(HANDLE));
    }

    bool IsPublishedCameraProfile(_In_ const GUID& ProfileId)
    {
        if (IsEqualGUID(ProfileId, KSCAMERAPROFILE_Legacy)) {
            return true;
        }

        for (ULONG i = 0; i < SIZEOF_ARRAY(CameraProfileIds); ++i) {
            if (IsEqualGUID(ProfileId, CameraProfileIds[i])) {
                return true;
            }
        }
        return false;
    }

    void WriteCameraProfilePayload(
        _Out_ PKSCAMERA_EXTENDEDPROP_HEADER Header,
        _In_ const KSCAMERA_EXTENDEDPROP_PROFILE& Profile
        )
    {
        RtlZeroMemory(
            Header,
            sizeof(KSCAMERA_EXTENDEDPROP_HEADER) +
            sizeof(KSCAMERA_EXTENDEDPROP_PROFILE));
        Header->Version = 1;
        Header->PinId = KSCAMERA_EXTENDEDPROP_FILTERSCOPE;
        Header->Size =
            sizeof(KSCAMERA_EXTENDEDPROP_HEADER) +
            sizeof(KSCAMERA_EXTENDEDPROP_PROFILE);
        Header->Result = 0;
        Header->Flags = 0;
        Header->Capability = KSCAMERA_EXTENDEDPROP_CAPS_ASYNCCONTROL;

        PKSCAMERA_EXTENDEDPROP_PROFILE Payload =
            reinterpret_cast<PKSCAMERA_EXTENDEDPROP_PROFILE>(Header + 1);
        *Payload = Profile;
    }
}


NTSTATUS
CCaptureFilter::
DispatchCreate (
    IN PKSFILTER Filter,
    IN PIRP Irp
    )

/*++

Routine Description:

    This is the creation dispatch for the capture filter.  It creates
    the CCaptureFilter object, associates it with the AVStream filter
    object, and bag the CCaptureFilter for later cleanup.

Arguments:

    Filter -
        The AVStream filter being created

    Irp -
        The creation Irp

Return Value:
    
    Success / failure

--*/

{

    PAGED_CODE();

    NTSTATUS Status = STATUS_SUCCESS;

    CCaptureFilter *CapFilter = new (NonPagedPoolNx, 'liFC') CCaptureFilter (Filter);

    if (!CapFilter) {
        //
        // Return failure if we couldn't create the filter.
        //
        Status = STATUS_INSUFFICIENT_RESOURCES;

    } else {
        //
        // Add the item to the object bag if we we were successful. 
        // Whenever the filter closes, the bag is cleaned up and we will be
        // freed.
        //
        Status = KsAddItemToObjectBag (
            Filter -> Bag,
            reinterpret_cast <PVOID> (CapFilter),
            reinterpret_cast <PFNKSFREE> (CCaptureFilter::Cleanup)
            );

        if (!NT_SUCCESS (Status)) {
            delete CapFilter;
        } else {
            Filter -> Context = reinterpret_cast <PVOID> (CapFilter);
        }

    }

    return Status;

}

//  Get VIRTUACAM_PROP_FRAME.
NTSTATUS
CCaptureFilter::
GetData(
	_In_ PIRP Irp,
	_In_ PKSIDENTIFIER Request,
	_Inout_ PVOID Data
)
{
	PAGED_CODE();

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_READ_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

	ULONG bufferLength = GetPropertyDataLength(Irp);
	if (!Data || bufferLength < sizeof(DWORD)) {
		return STATUS_BUFFER_TOO_SMALL;
	}

    DWORD value = 0xAA77AA77;
    status = CopyPropertyDataToCaller(Irp, Data, &value, sizeof(value), __alignof(DWORD));
    if (!NT_SUCCESS(status)) {
        return status;
    }

	Irp->IoStatus.Information = sizeof(DWORD);

	return STATUS_SUCCESS;
}

//  Set VIRTUACAM_PROP_FRAME.
NTSTATUS
CCaptureFilter::
SetData(
	_In_ PIRP Irp,
	_In_ PKSIDENTIFIER Request,
	_Inout_ PVOID Data
)
{
	PAGED_CODE();

	CCaptureFilter* filter = reinterpret_cast<CCaptureFilter*>(KsGetFilterFromIrp(Irp)->Context);

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_WRITE_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

	ULONG bufferLength = GetPropertyDataLength(Irp);

	if (bufferLength == 0 || Data == NULL) {
		return STATUS_INVALID_PARAMETER;
	}

	CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
	VIRTUACAM_DRIVER_STATUS driverStatus = {};
	driverStatus.Size = sizeof(driverStatus);
	device->QueryStatus(&driverStatus);

    ULONG dataLength = bufferLength;
    if (driverStatus.Width != 0 && driverStatus.Height != 0) {
        const ULONGLONG requiredLength =
            static_cast<ULONGLONG>(driverStatus.Width) *
            static_cast<ULONGLONG>(driverStatus.Height) *
            VIRTUACAM_FRAME_BYTES_PER_PIXEL;
        if (requiredLength > MAXULONG) {
            return STATUS_INVALID_PARAMETER;
        }

        dataLength = static_cast<ULONG>(requiredLength);
        if (bufferLength < dataLength) {
            return STATUS_BUFFER_TOO_SMALL;
        }
    }

    if (bufferLength != dataLength) {
        return STATUS_INVALID_BUFFER_SIZE;
    }

    PUCHAR frameCopy = NULL;
    status = CapturePropertyDataToPool(Irp, Data, dataLength, &frameCopy);
    if (!NT_SUCCESS(status)) {
        return status;
    }

	static volatile LONG s_driverFrameCount = 0;
	LONG n = _InterlockedIncrement(&s_driverFrameCount);
	if (n <= 3 || n % 30 == 0) {
		DbgPrint("[avshws] SetData frame=%ld len=%lu rawLen=%lu width=%lu height=%lu irql=%lu\n", n, dataLength, bufferLength, driverStatus.Width, driverStatus.Height, (ULONG)KeGetCurrentIrql());
	}

    status = device->SetData(frameCopy, dataLength);
    ExFreePoolWithTag(frameCopy, AVSHWS_POOLTAG);

	return status;
}

//  Set VIRTUACAM_PROP_FRAME_EX.
NTSTATUS
CCaptureFilter::
SetFrameEx(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    PAGED_CODE();

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_WRITE_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    ULONG bufferLength = GetPropertyDataLength(Irp);

    if (bufferLength < sizeof(VIRTUACAM_FRAME_EX_HEADER) || Data == NULL) {
        return STATUS_INVALID_PARAMETER;
    }

    VIRTUACAM_FRAME_EX_HEADER header = {};
    status = CopyPropertyDataFromCaller(Irp, Data, sizeof(header), &header, __alignof(VIRTUACAM_FRAME_EX_HEADER));
    if (!NT_SUCCESS(status)) {
        return status;
    }

    if (header.Size != sizeof(VIRTUACAM_FRAME_EX_HEADER) ||
        header.Version != VIRTUACAM_FRAME_EX_VERSION ||
        header.PayloadOffset < sizeof(VIRTUACAM_FRAME_EX_HEADER) ||
        header.PayloadLength == 0 ||
        header.Width == 0 ||
        header.Height == 0) {
        return STATUS_INVALID_PARAMETER;
    }

    const ULONGLONG copyLength64 =
        static_cast<ULONGLONG>(header.PayloadOffset) +
        static_cast<ULONGLONG>(header.PayloadLength);
    if (copyLength64 > MAXULONG || copyLength64 != bufferLength) {
        return STATUS_INVALID_BUFFER_SIZE;
    }

    const ULONG copyLength = static_cast<ULONG>(copyLength64);
    PUCHAR frameCopy = NULL;
    status = CapturePropertyDataToPool(Irp, Data, copyLength, &frameCopy);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    CCaptureFilter* filter = reinterpret_cast<CCaptureFilter*>(KsGetFilterFromIrp(Irp)->Context);
    CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
    status = device->SetFrameEx(frameCopy, copyLength);
    ExFreePoolWithTag(frameCopy, AVSHWS_POOLTAG);

    return status;
}

// Set VIRTUACAM_PROP_CONNECT.
NTSTATUS
CCaptureFilter::
SetConnect(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    UNREFERENCED_PARAMETER(Data);
    PAGED_CODE();

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_WRITE_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    CCaptureFilter* filter = reinterpret_cast<CCaptureFilter*>(KsGetFilterFromIrp(Irp)->Context);
    CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
    static volatile LONG s_connectSequence = 0;
    LONG seq = _InterlockedIncrement(&s_connectSequence);
    DbgPrint("[avshws] SetConnect seq=%ld irql=%lu\n", seq, (ULONG)KeGetCurrentIrql());
    device->ConnectClient();
    return STATUS_SUCCESS;
}

// Set VIRTUACAM_PROP_DISCONNECT.
NTSTATUS
CCaptureFilter::
SetDisconnect(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    UNREFERENCED_PARAMETER(Data);
    PAGED_CODE();

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_WRITE_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    CCaptureFilter* filter = reinterpret_cast<CCaptureFilter*>(KsGetFilterFromIrp(Irp)->Context);
    CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
    static volatile LONG s_disconnectSequence = 0;
    LONG seq = _InterlockedIncrement(&s_disconnectSequence);
    DbgPrint("[avshws] SetDisconnect seq=%ld irql=%lu\n", seq, (ULONG)KeGetCurrentIrql());
    device->DisconnectClient();
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
SetRegisterEvent(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    PAGED_CODE();

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_WRITE_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    HANDLE eventHandle = NULL;
    status = ReadPropertyHandle(Irp, Data, &eventHandle);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    if (!eventHandle) {
        return STATUS_INVALID_HANDLE;
    }

    CCaptureFilter* filter = reinterpret_cast<CCaptureFilter*>(KsGetFilterFromIrp(Irp)->Context);
    CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
    return device->RegisterClientRequestEvent(eventHandle, Irp->RequestorMode);
}

NTSTATUS
CCaptureFilter::
SetPreferredAspect(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    PAGED_CODE();

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_WRITE_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    ULONG aspectMode = 0;
    status = ReadPropertyUlong(Irp, Data, &aspectMode);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    if (aspectMode > VIRTUACAM_ASPECT_3_4) {
        return STATUS_INVALID_PARAMETER;
    }

    VirtuaCamSetPreferredAspect(aspectMode);
    Irp->IoStatus.Information = sizeof(ULONG);
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
SetAllowedAspects(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    PAGED_CODE();

    NTSTATUS status = ValidatePrivatePropertyAccess(Irp, FILE_WRITE_DATA);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    ULONG allowedMask = 0;
    status = ReadPropertyUlong(Irp, Data, &allowedMask);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    allowedMask &= VIRTUACAM_ASPECT_MASK_ALL;
    if (allowedMask == 0) {
        allowedMask = VIRTUACAM_ASPECT_MASK_ALL;
    }

    VirtuaCamSetAspectPolicy(MAXULONG, allowedMask);
    Irp->IoStatus.Information = sizeof(ULONG);
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
GetStatus(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    PAGED_CODE();

    NTSTATUS copyStatus = ValidatePrivatePropertyAccess(Irp, FILE_READ_DATA);
    if (!NT_SUCCESS(copyStatus)) {
        return copyStatus;
    }

    ULONG bufferLength = GetPropertyDataLength(Irp);
    if (!Data || bufferLength < VIRTUACAM_DRIVER_STATUS_V1_SIZE) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    CCaptureFilter* filter = reinterpret_cast<CCaptureFilter*>(KsGetFilterFromIrp(Irp)->Context);
    CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
    VIRTUACAM_DRIVER_STATUS status = {};
    device->QueryStatus(&status);

    ULONG bytesToCopy = sizeof(status);
    if (bufferLength < bytesToCopy) {
        bytesToCopy = bufferLength;
    }

    copyStatus = CopyPropertyDataToCaller(Irp, Data, &status, bytesToCopy, __alignof(VIRTUACAM_DRIVER_STATUS));
    if (!NT_SUCCESS(copyStatus)) {
        return copyStatus;
    }

    Irp->IoStatus.Information = bytesToCopy;
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
GetVideoControlMode(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    PAGED_CODE();
    UNREFERENCED_PARAMETER(Request);

    PIO_STACK_LOCATION irpStack = IoGetCurrentIrpStackLocation(Irp);
    ULONG bufferLength = irpStack->Parameters.DeviceIoControl.OutputBufferLength;
    if (!Data || bufferLength < sizeof(KSPROPERTY_VIDEOCONTROL_MODE_S)) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    PKSPROPERTY_VIDEOCONTROL_MODE_S mode =
        reinterpret_cast<PKSPROPERTY_VIDEOCONTROL_MODE_S>(Data);
    mode->Mode = 0;

    Irp->IoStatus.Information = sizeof(*mode);
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
SetVideoControlMode(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    PAGED_CODE();
    UNREFERENCED_PARAMETER(Request);

    PIO_STACK_LOCATION irpStack = IoGetCurrentIrpStackLocation(Irp);
    ULONG bufferLength = irpStack->Parameters.DeviceIoControl.OutputBufferLength;
    if (!Data || bufferLength < sizeof(KSPROPERTY_VIDEOCONTROL_MODE_S)) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    PKSPROPERTY_VIDEOCONTROL_MODE_S mode =
        reinterpret_cast<PKSPROPERTY_VIDEOCONTROL_MODE_S>(Data);
    if (mode->StreamIndex >= CAPTURE_FILTER_PIN_COUNT) {
        return STATUS_INVALID_PARAMETER;
    }

    Irp->IoStatus.Information = sizeof(*mode);
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
GetVideoControlCaps(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    PAGED_CODE();
    UNREFERENCED_PARAMETER(Request);

    PIO_STACK_LOCATION irpStack = IoGetCurrentIrpStackLocation(Irp);
    ULONG bufferLength = irpStack->Parameters.DeviceIoControl.OutputBufferLength;
    if (!Data || bufferLength < sizeof(KSPROPERTY_VIDEOCONTROL_CAPS_S)) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    PKSPROPERTY_VIDEOCONTROL_CAPS_S caps =
        reinterpret_cast<PKSPROPERTY_VIDEOCONTROL_CAPS_S>(Data);
    if (caps->StreamIndex >= CAPTURE_FILTER_PIN_COUNT) {
        return STATUS_INVALID_PARAMETER;
    }

    caps->VideoControlCaps = 0;
    Irp->IoStatus.Information = sizeof(*caps);
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
GetCameraProfile(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    PAGED_CODE();
    UNREFERENCED_PARAMETER(Request);

    const ULONG payloadSize =
        sizeof(KSCAMERA_EXTENDEDPROP_HEADER) +
        sizeof(KSCAMERA_EXTENDEDPROP_PROFILE);

    if (!Data || GetPropertyDataLength(Irp) < payloadSize) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    WriteCameraProfilePayload(
        reinterpret_cast<PKSCAMERA_EXTENDEDPROP_HEADER>(Data),
        CurrentCameraProfile);

    Irp->IoStatus.Information = payloadSize;
    return STATUS_SUCCESS;
}

NTSTATUS
CCaptureFilter::
SetCameraProfile(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    PAGED_CODE();
    UNREFERENCED_PARAMETER(Request);

    const ULONG payloadSize =
        sizeof(KSCAMERA_EXTENDEDPROP_HEADER) +
        sizeof(KSCAMERA_EXTENDEDPROP_PROFILE);

    if (!Data || GetPropertyDataLength(Irp) < payloadSize) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    PKSCAMERA_EXTENDEDPROP_HEADER Header =
        reinterpret_cast<PKSCAMERA_EXTENDEDPROP_HEADER>(Data);
    PKSCAMERA_EXTENDEDPROP_PROFILE Payload =
        reinterpret_cast<PKSCAMERA_EXTENDEDPROP_PROFILE>(Header + 1);

    if (Header->PinId != KSCAMERA_EXTENDEDPROP_FILTERSCOPE ||
        Header->Size != payloadSize ||
        Header->Flags != 0 ||
        Payload->Index != 0 ||
        Payload->Reserved != 0 ||
        !IsPublishedCameraProfile(Payload->ProfileId)) {
        Header->Result = static_cast<ULONG>(STATUS_INVALID_PARAMETER);
        Irp->IoStatus.Information = payloadSize;
        return STATUS_INVALID_PARAMETER;
    }

    CurrentCameraProfile = *Payload;
    WriteCameraProfilePayload(Header, CurrentCameraProfile);

    Irp->IoStatus.Information = payloadSize;
    return STATUS_SUCCESS;
}

/**************************************************************************

	PROPERTY TABLE STUFF

**************************************************************************/

DEFINE_KSPROPERTY_TABLE(CustomPropertyTable)
{
	{
		VIRTUACAM_PROP_FRAME,                       //PropertyId
		(PFNKSHANDLER)&CCaptureFilter::GetData,		//GetPropertyHandler
		(ULONG)sizeof(KSPROPERTY),					//MinProperty
		(ULONG)0,								//MinData
		(PFNKSHANDLER)&CCaptureFilter::SetData,		//SetPropertyHandler
		(PKSPROPERTY_VALUES)NULL,					//Values
		0,											//RelationsCount
		(PKSPROPERTY)NULL,							//Relations
		(PFNKSHANDLER)NULL,							//SupportHandler
		(ULONG)0									//SerializedSize
	},
    {
        VIRTUACAM_PROP_FRAME_EX,                    //PropertyId
        (PFNKSHANDLER)NULL,                         //GetPropertyHandler
        (ULONG)sizeof(KSPROPERTY),                  //MinProperty
        (ULONG)sizeof(VIRTUACAM_FRAME_EX_HEADER),   //MinData
        (PFNKSHANDLER)&CCaptureFilter::SetFrameEx,  //SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                   //Values
        0,                                          //RelationsCount
        (PKSPROPERTY)NULL,                          //Relations
        (PFNKSHANDLER)NULL,                         //SupportHandler
        (ULONG)0                                    //SerializedSize
    },
    {
        VIRTUACAM_PROP_CONNECT,                     //PropertyId
        (PFNKSHANDLER)NULL,                         //GetPropertyHandler
        (ULONG)sizeof(KSPROPERTY),                  //MinProperty
        (ULONG)0,                                   //MinData
        (PFNKSHANDLER)&CCaptureFilter::SetConnect,  //SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                   //Values
        0,                                          //RelationsCount
        (PKSPROPERTY)NULL,                          //Relations
        (PFNKSHANDLER)NULL,                         //SupportHandler
        (ULONG)0                                    //SerializedSize
    },
    {
        VIRTUACAM_PROP_DISCONNECT,                     //PropertyId
        (PFNKSHANDLER)NULL,                            //GetPropertyHandler
        (ULONG)sizeof(KSPROPERTY),                     //MinProperty
        (ULONG)0,                                      //MinData
        (PFNKSHANDLER)&CCaptureFilter::SetDisconnect,  //SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                      //Values
        0,                                             //RelationsCount
        (PKSPROPERTY)NULL,                             //Relations
        (PFNKSHANDLER)NULL,                            //SupportHandler
        (ULONG)0                                       //SerializedSize
    },
    {
        VIRTUACAM_PROP_STATUS,                         //PropertyId
        (PFNKSHANDLER)&CCaptureFilter::GetStatus,      //GetPropertyHandler
        (ULONG)sizeof(KSPROPERTY),                     //MinProperty
        (ULONG)VIRTUACAM_DRIVER_STATUS_V1_SIZE,        //MinData
        (PFNKSHANDLER)NULL,                            //SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                      //Values
        0,                                             //RelationsCount
        (PKSPROPERTY)NULL,                             //Relations
        (PFNKSHANDLER)NULL,                            //SupportHandler
        (ULONG)0                                       //SerializedSize
    },
    {
        VIRTUACAM_PROP_REGISTER_EVENT,                    //PropertyId
        (PFNKSHANDLER)NULL,                               //GetPropertyHandler
        (ULONG)sizeof(KSPROPERTY),                        //MinProperty
        (ULONG)sizeof(HANDLE),                            //MinData
        (PFNKSHANDLER)&CCaptureFilter::SetRegisterEvent,  //SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                         //Values
        0,                                                //RelationsCount
        (PKSPROPERTY)NULL,                                //Relations
        (PFNKSHANDLER)NULL,                               //SupportHandler
        (ULONG)0                                          //SerializedSize
    },
    {
        VIRTUACAM_PROP_PREFERRED_ASPECT,                  //PropertyId
        (PFNKSHANDLER)NULL,                               //GetPropertyHandler
        (ULONG)sizeof(KSPROPERTY),                        //MinProperty
        (ULONG)sizeof(ULONG),                             //MinData
        (PFNKSHANDLER)&CCaptureFilter::SetPreferredAspect,//SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                         //Values
        0,                                                //RelationsCount
        (PKSPROPERTY)NULL,                                //Relations
        (PFNKSHANDLER)NULL,                               //SupportHandler
        (ULONG)0                                          //SerializedSize
    },
    {
        VIRTUACAM_PROP_ALLOWED_ASPECTS,                   //PropertyId
        (PFNKSHANDLER)NULL,                               //GetPropertyHandler
        (ULONG)sizeof(KSPROPERTY),                        //MinProperty
        (ULONG)sizeof(ULONG),                             //MinData
        (PFNKSHANDLER)&CCaptureFilter::SetAllowedAspects, //SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                         //Values
        0,                                                //RelationsCount
        (PKSPROPERTY)NULL,                                //Relations
        (PFNKSHANDLER)NULL,                               //SupportHandler
        (ULONG)0                                          //SerializedSize
    }
};

DEFINE_KSPROPERTY_TABLE(FilterVidcapPropertyTable)
{
    DEFINE_KSPROPERTY_ITEM(
        KSPROPERTY_VIDEOCONTROL_MODE,
        CCaptureFilter::GetVideoControlMode,
        sizeof(KSPROPERTY),
        sizeof(KSPROPERTY_VIDEOCONTROL_MODE_S),
        CCaptureFilter::SetVideoControlMode,
        NULL,
        0,
        NULL,
        NULL,
        0
    ),
    DEFINE_KSPROPERTY_ITEM(
        KSPROPERTY_VIDEOCONTROL_CAPS,
        CCaptureFilter::GetVideoControlCaps,
        sizeof(KSPROPERTY),
        sizeof(KSPROPERTY_VIDEOCONTROL_CAPS_S),
        NULL,
        NULL,
        0,
        NULL,
        NULL,
        0
    )
};

DEFINE_KSPROPERTY_TABLE(ExtendedCameraControlPropertyTable)
{
    DEFINE_KSPROPERTY_ITEM(
        KSPROPERTY_CAMERACONTROL_EXTENDED_PROFILE,
        CCaptureFilter::GetCameraProfile,
        sizeof(KSPROPERTY),
        sizeof(KSCAMERA_EXTENDEDPROP_HEADER) + sizeof(KSCAMERA_EXTENDEDPROP_PROFILE),
        CCaptureFilter::SetCameraProfile,
        NULL,
        0,
        NULL,
        NULL,
        0
    )
};

DEFINE_KSPROPERTY_SET_TABLE(PropertySetTable)
{
    DEFINE_STD_PROPERTY_SET(PROPSETID_VIDCAP_VIDEOCONTROL, FilterVidcapPropertyTable),
    DEFINE_STD_PROPERTY_SET(KSPROPERTYSETID_ExtendedCameraControl, ExtendedCameraControlPropertyTable),
	DEFINE_STD_PROPERTY_SET(PROPSETID_VIDCAP_CUSTOMCONTROL, CustomPropertyTable)
};


DEFINE_KSAUTOMATION_TABLE(AvsFilterAutomationTable)
{
	DEFINE_KSAUTOMATION_PROPERTIES(PropertySetTable),
	DEFINE_KSAUTOMATION_METHODS_NULL,
	DEFINE_KSAUTOMATION_EVENTS_NULL
};

/**************************************************************************

    DESCRIPTOR AND DISPATCH LAYOUT

**************************************************************************/

GUID g_PINNAME_VIDEO_PREVIEW = {STATIC_PINNAME_VIDEO_PREVIEW};
GUID g_PINNAME_VIDEO_CAPTURE = {STATIC_PINNAME_VIDEO_CAPTURE};
GUID g_PINNAME_VIDEO_STILL = {STATIC_PINNAME_VIDEO_STILL};

NTSTATUS
VirtuaCamPublishCameraProfiles (
    _In_ PKSFILTERFACTORY FilterFactory
    )
{
    PAGED_CODE();

    if (!FilterFactory) {
        return STATUS_INVALID_PARAMETER;
    }

    NTSTATUS Status = KsInitializeDeviceProfile(FilterFactory);
    if (!NT_SUCCESS(Status)) {
        DbgPrint("[avshws] KsInitializeDeviceProfile failed status=0x%08X\n", Status);
        return Status;
    }

    for (ULONG i = 0; i < SIZEOF_ARRAY(CameraProfileIds); ++i) {
        KSDEVICE_PROFILE_INFO ProfileInfo = {};
        ProfileInfo.Type = KSDEVICE_PROFILE_TYPE_CAMERA;
        ProfileInfo.Size = sizeof(ProfileInfo);
        ProfileInfo.Camera.Info.ProfileId = CameraProfileIds[i];
        ProfileInfo.Camera.Info.Index = 0;
        ProfileInfo.Camera.Info.PinCount = SIZEOF_ARRAY(CameraProfilePins);
        ProfileInfo.Camera.Info.Pins = CameraProfilePins;
        ProfileInfo.Camera.Reserved = 0;
        ProfileInfo.Camera.ConcurrencyCount = 0;
        ProfileInfo.Camera.Concurrency = NULL;

        Status = KsPublishDeviceProfile(FilterFactory, &ProfileInfo);
        if (!NT_SUCCESS(Status)) {
            DbgPrint("[avshws] KsPublishDeviceProfile index=%lu status=0x%08X\n", i, Status);
            return Status;
        }
    }

    Status = KsPersistDeviceProfile(FilterFactory);
    if (!NT_SUCCESS(Status)) {
        DbgPrint("[avshws] KsPersistDeviceProfile failed status=0x%08X\n", Status);
    }

    return Status;
}

//
// CaptureFilterCategories:
//
// The list of category GUIDs for the capture filter.
//
const
GUID
CaptureFilterCategories [CAPTURE_FILTER_CATEGORIES_COUNT] = {
    STATICGUIDOF (KSCATEGORY_VIDEO),
    STATICGUIDOF (KSCATEGORY_CAPTURE),
    STATICGUIDOF (KSCATEGORY_VIDEO_CAMERA)
};

//
// CaptureFilterPinDescriptors:
//
// The list of pin descriptors on the capture filter.  
//
const 
KSPIN_DESCRIPTOR_EX
CaptureFilterPinDescriptors [CAPTURE_FILTER_PIN_COUNT] = {
    //
    // Video Preview Pin. Keep this first because Windows camera clients prefer
    // a VideoPreview color stream before falling back to VideoRecord/Capture.
    //
    {
        &CapturePinDispatch,
        &CapturePinAutomationTable,
        {
            0,                              // Interfaces (NULL, 0 == default)
            NULL,
            0,                              // Mediums (NULL, 0 == default)
            NULL,
            SIZEOF_ARRAY(CapturePinDataRanges),// Range Count
            CapturePinDataRanges,           // Ranges
            KSPIN_DATAFLOW_OUT,             // Dataflow
            KSPIN_COMMUNICATION_BOTH,       // Communication
            &PIN_CATEGORY_PREVIEW,          // Category
            &g_PINNAME_VIDEO_PREVIEW,       // Name
            0                               // Reserved
        },
        KSPIN_FLAG_PROCESS_IN_RUN_STATE_ONLY |
            KSPIN_FLAG_DO_NOT_INITIATE_PROCESSING,// Pin Flags
        1,                                  // Instances Possible
        0,                                  // Instances Necessary
        &CapturePinAllocatorFraming,        // Allocator Framing
        reinterpret_cast <PFNKSINTERSECTHANDLEREX>
            (CCapturePin::IntersectHandler)
    },
    //
    // Video Capture Pin
    //
    {
        &CapturePinDispatch,
        &CapturePinAutomationTable,
        {
            0,                              // Interfaces (NULL, 0 == default)
            NULL,
            0,                              // Mediums (NULL, 0 == default)
            NULL,
            SIZEOF_ARRAY(CapturePinDataRanges),// Range Count
            CapturePinDataRanges,           // Ranges
            KSPIN_DATAFLOW_OUT,             // Dataflow
            KSPIN_COMMUNICATION_BOTH,       // Communication
            &PIN_CATEGORY_CAPTURE,          // Category
            &g_PINNAME_VIDEO_CAPTURE,       // Name
            0                               // Reserved
        },
        KSPIN_FLAG_PROCESS_IN_RUN_STATE_ONLY |
            KSPIN_FLAG_DO_NOT_INITIATE_PROCESSING,// Pin Flags
        1,                                  // Instances Possible
        0,                                  // Instances Necessary
        &CapturePinAllocatorFraming,        // Allocator Framing
        reinterpret_cast <PFNKSINTERSECTHANDLEREX> 
            (CCapturePin::IntersectHandler)
    },
    //
    // Still image pin. Media Foundation can encode JPEG/PNG/JPEG-XR from
    // these uncompressed ranges, so do not claim kernel JPEG/H264 output.
    //
    {
        &CapturePinDispatch,
        &CapturePinAutomationTable,
        {
            0,                              // Interfaces (NULL, 0 == default)
            NULL,
            0,                              // Mediums (NULL, 0 == default)
            NULL,
            SIZEOF_ARRAY(CapturePinDataRanges),// Range Count
            CapturePinDataRanges,           // Ranges
            KSPIN_DATAFLOW_OUT,             // Dataflow
            KSPIN_COMMUNICATION_BOTH,       // Communication
            &PIN_CATEGORY_STILL,            // Category
            &g_PINNAME_VIDEO_STILL,         // Name
            0                               // Reserved
        },
        KSPIN_FLAG_PROCESS_IN_RUN_STATE_ONLY |
            KSPIN_FLAG_DO_NOT_INITIATE_PROCESSING,// Pin Flags
        1,                                  // Instances Possible
        0,                                  // Instances Necessary
        &CapturePinAllocatorFraming,        // Allocator Framing
        reinterpret_cast <PFNKSINTERSECTHANDLEREX>
            (CCapturePin::IntersectHandler)
    }
};

//
// CaptureFilterDispatch:
//
// This is the dispatch table for the capture filter.  It provides notification
// of creation, closure, processing (for filter-centrics, not for the capture
// filter), and resets (for filter-centrics, not for the capture filter).
//
const 
KSFILTER_DISPATCH
CaptureFilterDispatch = {
    CCaptureFilter::DispatchCreate,         // Filter Create
    NULL,                                   // Filter Close
    NULL,                                   // Filter Process
    NULL                                    // Filter Reset
};


//
// CaptureFilterDescription:
//
// The descriptor for the capture filter.  We don't specify any topology
// since this virtual camera has simple peer output pins.  Realistically, there would
// be some topological relationships here because there would be input 
// pins from crossbars and the like.
//
const 
KSFILTER_DESCRIPTOR 
CaptureFilterDescriptor = {
    &CaptureFilterDispatch,                 // Dispatch Table
    &AvsFilterAutomationTable,              // Automation Table
    KSFILTER_DESCRIPTOR_VERSION,            // Version
    KSFILTER_FLAG_PRIORITIZE_REFERENCEGUID, // Flags
    &VirtuaCamFilterReferenceGuid,          // Reference GUID
    DEFINE_KSFILTER_PIN_DESCRIPTORS (CaptureFilterPinDescriptors),
    DEFINE_KSFILTER_CATEGORIES (CaptureFilterCategories),
    0,
    sizeof (KSNODE_DESCRIPTOR),
    NULL,
    0,
    NULL,
    NULL                                    // Component ID
};
