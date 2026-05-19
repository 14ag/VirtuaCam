#pragma once

#define VIRTUACAM_MIC_ENABLE_USERMODE_FEED 0

NTSTATUS VirtuaCamMicBridgeInitialize(_In_ PDRIVER_OBJECT DriverObject);
VOID VirtuaCamMicBridgeShutdown();
VOID VirtuaCamMicBridgeReadAudio(_Out_writes_bytes_(ByteCount) PUCHAR Buffer, _In_ SIZE_T ByteCount);
DRIVER_DISPATCH VirtuaCamMicBridgeDispatchCreateClose;
DRIVER_DISPATCH VirtuaCamMicBridgeDispatchDeviceControl;
