#pragma once

#include <filesystem>
#include <string>
#include "VirtuaCamDriverAbi.h"

enum class AspectRatioMode
{
    R16_9 = 0,
    R9_16,
    R4_3,
    R3_4
};

#define ASPECT_RATIO_MASK_16_9          VIRTUACAM_ASPECT_MASK_16_9
#define ASPECT_RATIO_MASK_9_16          VIRTUACAM_ASPECT_MASK_9_16
#define ASPECT_RATIO_MASK_4_3           VIRTUACAM_ASPECT_MASK_4_3
#define ASPECT_RATIO_MASK_3_4           VIRTUACAM_ASPECT_MASK_3_4
#define ASPECT_RATIO_MASK_ALL           VIRTUACAM_ASPECT_MASK_ALL

namespace VirtuaCamConfig
{
    struct AppSettings
    {
        bool showPipTopLeft = false;
        bool showPipTopRight = false;
        bool showPipBottomLeft = false;
        AspectRatioMode aspectRatio = AspectRatioMode::R16_9;
    };

    std::filesystem::path GetConfigPath();
    AppSettings LoadSettings();
    bool SaveSettings(const AppSettings& settings);

    AspectRatioMode ParseAspectRatio(const std::wstring& value);
    const wchar_t* AspectRatioName(AspectRatioMode mode);
    const wchar_t* AspectRatioConfigValue(AspectRatioMode mode);
    float AspectRatioValue(AspectRatioMode mode);
}
