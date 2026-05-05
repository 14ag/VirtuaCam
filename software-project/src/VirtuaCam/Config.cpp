#include "pch.h"
#include "Config.h"
#include "RuntimeLog.h"

namespace
{
    constexpr wchar_t kConfigDirName[] = L"VirtuaCam";
    constexpr wchar_t kConfigFileName[] = L"settings.ini";
    constexpr wchar_t kSectionName[] = L"VirtuaCam";

    std::filesystem::path ResolveLocalAppDataPath()
    {
        wchar_t buffer[MAX_PATH] = {};
        DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, ARRAYSIZE(buffer));
        if (len > 0 && len < ARRAYSIZE(buffer)) {
            return std::filesystem::path(buffer) / kConfigDirName;
        }

        wchar_t fallback[MAX_PATH] = {};
        len = GetEnvironmentVariableW(L"APPDATA", fallback, ARRAYSIZE(fallback));
        if (len > 0 && len < ARRAYSIZE(fallback)) {
            return std::filesystem::path(fallback) / kConfigDirName;
        }

        return std::filesystem::current_path();
    }
}

namespace VirtuaCamConfig
{
    std::filesystem::path GetConfigPath()
    {
        return ResolveLocalAppDataPath() / kConfigFileName;
    }

    AspectRatioMode ParseAspectRatio(const std::wstring& value)
    {
        if (value == L"9:16") return AspectRatioMode::R9_16;
        if (value == L"4:3") return AspectRatioMode::R4_3;
        if (value == L"3:4") return AspectRatioMode::R3_4;
        return AspectRatioMode::R16_9;
    }

    const wchar_t* AspectRatioName(AspectRatioMode mode)
    {
        switch (mode) {
        case AspectRatioMode::R9_16: return L"9:16";
        case AspectRatioMode::R4_3: return L"4:3";
        case AspectRatioMode::R3_4: return L"3:4";
        case AspectRatioMode::R16_9:
        default: return L"16:9";
        }
    }

    const wchar_t* AspectRatioConfigValue(AspectRatioMode mode)
    {
        return AspectRatioName(mode);
    }

    float AspectRatioValue(AspectRatioMode mode)
    {
        switch (mode) {
        case AspectRatioMode::R9_16: return 9.0f / 16.0f;
        case AspectRatioMode::R4_3: return 4.0f / 3.0f;
        case AspectRatioMode::R3_4: return 3.0f / 4.0f;
        case AspectRatioMode::R16_9:
        default: return 16.0f / 9.0f;
        }
    }

    AppSettings LoadSettings()
    {
        AppSettings settings;
        const auto path = GetConfigPath();

        settings.showPipTopLeft =
            GetPrivateProfileIntW(kSectionName, L"ShowPipTopLeft", 0, path.c_str()) != 0;
        settings.showPipTopRight =
            GetPrivateProfileIntW(kSectionName, L"ShowPipTopRight", 0, path.c_str()) != 0;
        settings.showPipBottomLeft =
            GetPrivateProfileIntW(kSectionName, L"ShowPipBottomLeft", 0, path.c_str()) != 0;

        wchar_t aspectRatio[32] = {};
        GetPrivateProfileStringW(
            kSectionName,
            L"AspectRatio",
            L"16:9",
            aspectRatio,
            ARRAYSIZE(aspectRatio),
            path.c_str());
        settings.aspectRatio = ParseAspectRatio(aspectRatio);

        if (!std::filesystem::exists(path)) {
            (void)SaveSettings(settings);
        }

        return settings;
    }

    bool SaveSettings(const AppSettings& settings)
    {
        const auto path = GetConfigPath();
        std::error_code ec;
        std::filesystem::create_directories(path.parent_path(), ec);
        if (ec) {
            VirtuaCamLog::LogLine(std::format(
                L"Create config directory failed: {} error={}",
                path.parent_path().wstring(),
                ec.value()));
            return false;
        }

        const bool ok =
            WritePrivateProfileStringW(kSectionName, L"ShowPipTopLeft", settings.showPipTopLeft ? L"1" : L"0", path.c_str()) &&
            WritePrivateProfileStringW(kSectionName, L"ShowPipTopRight", settings.showPipTopRight ? L"1" : L"0", path.c_str()) &&
            WritePrivateProfileStringW(kSectionName, L"ShowPipBottomLeft", settings.showPipBottomLeft ? L"1" : L"0", path.c_str()) &&
            WritePrivateProfileStringW(kSectionName, L"AspectRatio", AspectRatioConfigValue(settings.aspectRatio), path.c_str());

        if (!ok) {
            VirtuaCamLog::LogWin32(std::format(L"Write config failed: {}", path.wstring()), GetLastError());
        }
        return ok;
    }
}
