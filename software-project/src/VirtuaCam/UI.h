#pragma once
#include <vector>
#include <string>
#include <functional>
#include <d3d11.h>

#define PREVIEW_WINDOW_CLASS L"VirtuaCamPreviewClass"

enum class BrokerState;

struct CapturableWindow {
    HWND hwnd;
    std::wstring title;
};

typedef ID3D11Texture2D* (*PFN_GetSharedTexture)();

void UI_Initialize(HINSTANCE instance, HWND& outMainWnd, PFN_GetSharedTexture pfnGetSharedTexture);
void UI_SetDebugMode(bool enabled);
void UI_RunMessageLoop(std::function<void()> onIdle);
void UI_Shutdown();
void UI_UpdateAudioDeviceLists(const std::vector<std::wstring>& captureDevices);
void UI_SetAudioSelectionCallback(std::function<void(int)> callback);
void UI_SetCurrentAudioDeviceId(int id);
int UI_GetCurrentAudioDeviceId();
std::vector<std::wstring> UI_RefreshCameraDeviceList();

// Returns a cached camera DevicePath for a given camera index (menu index),
// or nullptr if out of range / unknown. This is used to launch camera producers
// with a stable identifier rather than an API-specific device index.
const wchar_t* UI_GetCameraDevicePath(int index);
const wchar_t* UI_GetCameraDeviceName(int index);

void CreatePreviewWindow();
void UpdateTelemetry(BrokerState currentState, bool driverConnected);
