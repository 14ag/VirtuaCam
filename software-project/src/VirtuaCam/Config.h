#pragma once

#include <string>
#include "VirtuaCamDriverAbi.h"

enum class AspectRatioMode
{
    R16_9 = 0,
    R9_16,
    R4_3,
    R3_4
};

enum class AudioRoutingMode
{
    Auto = 0,
    Manual
};

#define ASPECT_RATIO_MASK_16_9          VIRTUACAM_ASPECT_MASK_16_9
#define ASPECT_RATIO_MASK_9_16          VIRTUACAM_ASPECT_MASK_9_16
#define ASPECT_RATIO_MASK_4_3           VIRTUACAM_ASPECT_MASK_4_3
#define ASPECT_RATIO_MASK_3_4           VIRTUACAM_ASPECT_MASK_3_4
#define ASPECT_RATIO_MASK_ALL           VIRTUACAM_ASPECT_MASK_ALL

namespace VirtuaCamConfig
{
    constexpr const wchar_t* kSettingsRegistryPath = L"HKCU\\Software\\VirtuaCam\\Settings";

    struct AppSettings
    {
        bool showPipTopLeft = false;
        bool showPipTopRight = false;
        bool showPipBottomLeft = false;
        bool startDebugMode = false;
        AspectRatioMode aspectRatio = AspectRatioMode::R16_9;
        AudioRoutingMode audioRoutingMode = AudioRoutingMode::Auto;
        std::wstring audioCaptureDeviceName = L"Stereo Mix";
    };

    const wchar_t* GetSettingsRegistryPath();
    AppSettings LoadSettings();
    bool SaveSettings(const AppSettings& settings);
    bool DeleteLegacySettingsFile();

    AspectRatioMode ParseAspectRatio(const std::wstring& value);
    const wchar_t* AspectRatioName(AspectRatioMode mode);
    const wchar_t* AspectRatioConfigValue(AspectRatioMode mode);
    float AspectRatioValue(AspectRatioMode mode);
    AudioRoutingMode ParseAudioRoutingMode(const std::wstring& value);
    const wchar_t* AudioRoutingModeName(AudioRoutingMode mode);
    const wchar_t* AudioRoutingModeConfigValue(AudioRoutingMode mode);
}
