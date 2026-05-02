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

namespace
{
    NTSTATUS ProbePropertyReadBuffer(
        _In_ PIRP Irp,
        _In_reads_bytes_(Length) const void* Buffer,
        _In_ SIZE_T Length)
    {
        if (Length == 0) {
            return STATUS_SUCCESS;
        }

        if (!Buffer) {
            return STATUS_INVALID_PARAMETER;
        }

        if (Irp->RequestorMode == KernelMode) {
            return STATUS_SUCCESS;
        }

        __try {
            ProbeForRead(const_cast<PVOID>(Buffer), Length, sizeof(UCHAR));
        }
        __except (EXCEPTION_EXECUTE_HANDLER) {
            return GetExceptionCode();
        }

        return STATUS_SUCCESS;
    }

    NTSTATUS ProbePropertyWriteBuffer(
        _In_ PIRP Irp,
        _Out_writes_bytes_(Length) void* Buffer,
        _In_ SIZE_T Length)
    {
        if (Length == 0) {
            return STATUS_SUCCESS;
        }

        if (!Buffer) {
            return STATUS_INVALID_PARAMETER;
        }

        if (Irp->RequestorMode == KernelMode) {
            return STATUS_SUCCESS;
        }

        __try {
            ProbeForWrite(Buffer, Length, sizeof(UCHAR));
        }
        __except (EXCEPTION_EXECUTE_HANDLER) {
            return GetExceptionCode();
        }

        return STATUS_SUCCESS;
    }
}

/**************************************************************************

    PAGEABLE CODE

**************************************************************************/

#ifdef ALLOC_PRAGMA
#pragma code_seg("PAGE")
#endif // ALLOC_PRAGMA


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

	PIO_STACK_LOCATION pIrpStack = IoGetCurrentIrpStackLocation(Irp);
	ULONG bufferLength = pIrpStack->Parameters.DeviceIoControl.OutputBufferLength;
	if (!Data || bufferLength < sizeof(DWORD)) {
		return STATUS_BUFFER_TOO_SMALL;
	}

    NTSTATUS probeStatus = ProbePropertyWriteBuffer(Irp, Data, sizeof(DWORD));
    if (!NT_SUCCESS(probeStatus)) {
        return probeStatus;
    }

    DWORD value = 0xAA77AA77;
    __try {
        RtlCopyMemory(Data, &value, sizeof(value));
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        return GetExceptionCode();
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

	PIO_STACK_LOCATION pIrpStack = IoGetCurrentIrpStackLocation(Irp);
	ULONG bufferLength = pIrpStack->Parameters.DeviceIoControl.OutputBufferLength;

	if (bufferLength == 0 || Data == NULL) {
		return STATUS_INVALID_PARAMETER;
	}

	ULONG dataLength = VIRTUACAM_FRAME_BUFFER_SIZE;
    if (bufferLength < dataLength) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    NTSTATUS probeStatus = ProbePropertyReadBuffer(Irp, Data, dataLength);
    if (!NT_SUCCESS(probeStatus)) {
        return probeStatus;
    }

	CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
	VIRTUACAM_DRIVER_STATUS driverStatus = {};
	driverStatus.Size = sizeof(driverStatus);
	device->QueryStatus(&driverStatus);

    PUCHAR frameCopy = reinterpret_cast<PUCHAR>(
        ExAllocatePool2(
            POOL_FLAG_NON_PAGED,
            dataLength,
            AVSHWS_POOLTAG));
    if (!frameCopy) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    __try {
        RtlCopyMemory(frameCopy, Data, dataLength);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        ExFreePoolWithTag(frameCopy, AVSHWS_POOLTAG);
        return GetExceptionCode();
    }

	static volatile LONG s_driverFrameCount = 0;
	LONG n = _InterlockedIncrement(&s_driverFrameCount);
	if (n <= 3 || n % 30 == 0) {
		DbgPrint("[avshws] SetData frame=%ld len=%lu rawLen=%lu width=%lu height=%lu irql=%lu\n", n, dataLength, bufferLength, driverStatus.Width, driverStatus.Height, (ULONG)KeGetCurrentIrql());
	}

	device->SetData(frameCopy, dataLength);
    ExFreePoolWithTag(frameCopy, AVSHWS_POOLTAG);

	return STATUS_SUCCESS;
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
GetStatus(
    _In_ PIRP Irp,
    _In_ PKSIDENTIFIER Request,
    _Inout_ PVOID Data
)
{
    UNREFERENCED_PARAMETER(Request);
    PAGED_CODE();

    PIO_STACK_LOCATION pIrpStack = IoGetCurrentIrpStackLocation(Irp);
    ULONG bufferLength = pIrpStack->Parameters.DeviceIoControl.OutputBufferLength;
    if (!Data || bufferLength < sizeof(VIRTUACAM_DRIVER_STATUS)) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    NTSTATUS probeStatus = ProbePropertyWriteBuffer(Irp, Data, sizeof(VIRTUACAM_DRIVER_STATUS));
    if (!NT_SUCCESS(probeStatus)) {
        return probeStatus;
    }

    CCaptureFilter* filter = reinterpret_cast<CCaptureFilter*>(KsGetFilterFromIrp(Irp)->Context);
    CCaptureDevice* device = CCaptureDevice::Recast(KsFilterGetDevice(filter->m_Filter));
    VIRTUACAM_DRIVER_STATUS status = {};
    device->QueryStatus(&status);

    __try {
        RtlCopyMemory(Data, &status, sizeof(status));
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        return GetExceptionCode();
    }

    Irp->IoStatus.Information = sizeof(status);
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
		(ULONG)VIRTUACAM_FRAME_BUFFER_SIZE,		//MinData
		(PFNKSHANDLER)&CCaptureFilter::SetData,		//SetPropertyHandler
		(PKSPROPERTY_VALUES)NULL,					//Values
		0,											//RelationsCount
		(PKSPROPERTY)NULL,							//Relations
		(PFNKSHANDLER)NULL,							//SupportHandler
		(ULONG)0									//SerializedSize
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
        (ULONG)sizeof(VIRTUACAM_DRIVER_STATUS),        //MinData
        (PFNKSHANDLER)NULL,                            //SetPropertyHandler
        (PKSPROPERTY_VALUES)NULL,                      //Values
        0,                                             //RelationsCount
        (PKSPROPERTY)NULL,                             //Relations
        (PFNKSHANDLER)NULL,                            //SupportHandler
        (ULONG)0                                       //SerializedSize
    }
};

DEFINE_KSPROPERTY_SET_TABLE(PropertySetTable)
{
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

GUID g_PINNAME_VIDEO_CAPTURE = {STATIC_PINNAME_VIDEO_CAPTURE};

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
    // Video Capture Pin
    //
    {
        &CapturePinDispatch,
        NULL,             
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
        KSPIN_FLAG_PROCESS_IN_RUN_STATE_ONLY,// Pin Flags
        1,                                  // Instances Possible
        1,                                  // Instances Necessary
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
// since there's only one pin on the filter.  Realistically, there would
// be some topological relationships here because there would be input 
// pins from crossbars and the like.
//
const 
KSFILTER_DESCRIPTOR 
CaptureFilterDescriptor = {
    &CaptureFilterDispatch,                 // Dispatch Table
    &AvsFilterAutomationTable,              // Automation Table
    KSFILTER_DESCRIPTOR_VERSION,            // Version
    0,                                      // Flags
    &KSNAME_Filter,                         // Reference GUID
    DEFINE_KSFILTER_PIN_DESCRIPTORS (CaptureFilterPinDescriptors),
    DEFINE_KSFILTER_CATEGORIES (CaptureFilterCategories),
    0,
    sizeof (KSNODE_DESCRIPTOR),
    NULL,
    0,
    NULL,
    NULL                                    // Component ID
};
