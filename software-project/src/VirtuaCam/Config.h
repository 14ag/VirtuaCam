#pragma once

#include <filesystem>
#include <string>

enum class AspectRatioMode
{
    R16_9 = 0,
    R9_16,
    R4_3,
    R3_4
};

#define ASPECT_RATIO_MASK_16_9          0x00000001u
#define ASPECT_RATIO_MASK_9_16          0x00000002u
#define ASPECT_RATIO_MASK_4_3           0x00000004u
#define ASPECT_RATIO_MASK_3_4           0x00000008u
#define ASPECT_RATIO_MASK_ALL           (ASPECT_RATIO_MASK_16_9 | ASPECT_RATIO_MASK_9_16 | ASPECT_RATIO_MASK_4_3 | ASPECT_RATIO_MASK_3_4)

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
