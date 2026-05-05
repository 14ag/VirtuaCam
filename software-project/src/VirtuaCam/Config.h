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
