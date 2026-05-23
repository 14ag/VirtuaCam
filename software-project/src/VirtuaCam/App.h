#pragma once

#include "Formats.h"
#include "Config.h"
#include <string>

#define WM_APP_TRAY_MSG (WM_APP + 1)
#define WM_APP_MENU_COMMAND (WM_APP + 2)
#define ID_TRAY_PREVIEW_WINDOW  5001
#define ID_TRAY_ABOUT           5002
#define ID_TRAY_EXIT            5003
#define IDC_TELEMETRY_LABEL     5004
#define ID_AUDIO_DEVICE_NONE    6000
#define ID_AUDIO_DEVICE_AUTO    6001
#define ID_AUDIO_CAPTURE_FIRST  7001

#define ID_SOURCE_OFF                   8000
#define ID_SOURCE_CAMERA_FIRST          8100
#define ID_SOURCE_DISPLAY_FIRST         8500
#define ID_SOURCE_WINDOW_FIRST          9000
#define ID_SOURCE_DISCOVERED_FIRST      9500
#define ID_SOURCE_IMAGE_FILE            9600
#define ID_SOURCE_VIDEO_FILE            9601

#define ID_PIP_TL_OFF                   10000
#define ID_PIP_TL_CAMERA_FIRST          10100
#define ID_PIP_TL_WINDOW_FIRST          11000
#define ID_PIP_TL_DISCOVERED_FIRST      11500

#define ID_PIP_TR_OFF                   12000
#define ID_PIP_TR_CAMERA_FIRST          12100
#define ID_PIP_TR_WINDOW_FIRST          13000
#define ID_PIP_TR_DISCOVERED_FIRST      13500

#define ID_PIP_BL_OFF                   14000
#define ID_PIP_BL_CAMERA_FIRST          14100
#define ID_PIP_BL_WINDOW_FIRST          15000
#define ID_PIP_BL_DISCOVERED_FIRST      15500

#define ID_PIP_OFF                      16000
#define ID_PIP_CAMERA_FIRST             16100
#define ID_PIP_WINDOW_FIRST             17000
#define ID_PIP_DISCOVERED_FIRST         17500

#define ID_SETTINGS_PIP_TL              18001
#define ID_SETTINGS_PIP_TR              18002
#define ID_SETTINGS_PIP_BL              18003
#define ID_ASPECT_RATIO_16_9            18100
#define ID_ASPECT_RATIO_9_16            18101
#define ID_ASPECT_RATIO_4_3             18102
#define ID_ASPECT_RATIO_3_4             18103
#define ID_ADV_OPEN_LOG_DIR             18200
#define ID_ADV_RUN_HOST_PROOF           18201
#define ID_ADV_RUN_SETUP_VERIFY         18202
#define ID_ADV_RUN_VM_VERIFIER_PROOF    18203

enum class BrokerState { Searching, Connected, Failed };
enum class VCamCommand { None = 0 };
enum class SourceMode { Off, Camera, Discovered, Window, Display, Image, Video };
enum class PipPosition { TL, TR, BL, BR };

struct SourceState {
    SourceMode mode = SourceMode::Off;
    DWORD pid = 0;
    HWND hwnd = nullptr;
    int cameraIndex = -1;
    int displayIndex = -1;
    std::wstring filePath;
};
