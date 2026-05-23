#include "pch.h"
#include "Config.h"
#include "RuntimeLog.h"

#include <filesystem>
#include <wil/resource.h>

namespace
{
    constexpr wchar_t kSettingsSubkey[] = L"Software\\VirtuaCam\\Settings";
    constexpr wchar_t kLegacyConfigDirName[] = L"VirtuaCam";
    constexpr wchar_t kLegacyConfigFileName[] = L"settings.ini";

    wil::unique_hkey OpenSettingsKey(REGSAM access, bool create)
    {
        HKEY rawKey = nullptr;
        if (create) {
            DWORD disposition = 0;
            const LSTATUS status = RegCreateKeyExW(
                HKEY_CURRENT_USER,
                kSettingsSubkey,
                0,
                nullptr,
                REG_OPTION_NON_VOLATILE,
                access,
                nullptr,
                &rawKey,
                &disposition);
            if (status != ERROR_SUCCESS) {
                VirtuaCamLog::LogWin32(L"RegCreateKeyEx HKCU\\Software\\VirtuaCam\\Settings failed", status);
                return {};
            }
        } else {
            const LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, kSettingsSubkey, 0, access, &rawKey);
            if (status != ERROR_SUCCESS) {
                return {};
            }
        }
        return wil::unique_hkey(rawKey);
    }

    bool ReadDword(HKEY key, const wchar_t* name, DWORD& value)
    {
        DWORD type = 0;
        DWORD cb = sizeof(value);
        const LSTATUS status = RegGetValueW(key, nullptr, name, RRF_RT_REG_DWORD, &type, &value, &cb);
        return status == ERROR_SUCCESS && type == REG_DWORD && cb == sizeof(value);
    }

    bool WriteDword(HKEY key, const wchar_t* name, DWORD value)
    {
        return RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS;
    }

    bool ReadString(HKEY key, const wchar_t* name, std::wstring& value)
    {
        DWORD type = 0;
        DWORD cb = 0;
        LSTATUS status = RegQueryValueExW(key, name, nullptr, &type, nullptr, &cb);
        if (status != ERROR_SUCCESS || type != REG_SZ || cb < sizeof(wchar_t)) {
            return false;
        }

        std::wstring buffer((cb + sizeof(wchar_t) - 1) / sizeof(wchar_t), L'\0');
        type = 0;
        status = RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<LPBYTE>(buffer.data()), &cb);
        if (status != ERROR_SUCCESS || type != REG_SZ) {
            return false;
        }

        buffer.resize(cb / sizeof(wchar_t));
        while (!buffer.empty() && buffer.back() == L'\0') {
            buffer.pop_back();
        }
        value = buffer;
        return true;
    }

    bool WriteString(HKEY key, const wchar_t* name, const std::wstring& value)
    {
        const DWORD cb = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
        return RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()), cb) == ERROR_SUCCESS;
    }

    std::filesystem::path LegacySettingsPath()
    {
        wchar_t buffer[MAX_PATH] = {};
        DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, ARRAYSIZE(buffer));
        if (len == 0 || len >= ARRAYSIZE(buffer)) {
            len = GetEnvironmentVariableW(L"APPDATA", buffer, ARRAYSIZE(buffer));
        }
        if (len == 0 || len >= ARRAYSIZE(buffer)) {
            return {};
        }
        return std::filesystem::path(buffer) / kLegacyConfigDirName / kLegacyConfigFileName;
    }
}

namespace VirtuaCamConfig
{
    const wchar_t* GetSettingsRegistryPath()
    {
        return kSettingsRegistryPath;
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

    AudioRoutingMode ParseAudioRoutingMode(const std::wstring& value)
    {
        if (_wcsicmp(value.c_str(), L"Manual") == 0) return AudioRoutingMode::Manual;
        return AudioRoutingMode::Auto;
    }

    const wchar_t* AudioRoutingModeName(AudioRoutingMode mode)
    {
        switch (mode) {
        case AudioRoutingMode::Manual: return L"Manual";
        case AudioRoutingMode::Auto:
        default: return L"Auto";
        }
    }

    const wchar_t* AudioRoutingModeConfigValue(AudioRoutingMode mode)
    {
        return AudioRoutingModeName(mode);
    }

    AppSettings LoadSettings()
    {
        AppSettings settings;
        wil::unique_hkey key = OpenSettingsKey(KEY_READ | KEY_WRITE, true);
        if (!key) {
            return settings;
        }

        DWORD value = 0;
        if (ReadDword(key.get(), L"ShowPipTopLeft", value)) {
            settings.showPipTopLeft = value != 0;
        }
        if (ReadDword(key.get(), L"ShowPipTopRight", value)) {
            settings.showPipTopRight = value != 0;
        }
        if (ReadDword(key.get(), L"ShowPipBottomLeft", value)) {
            settings.showPipBottomLeft = value != 0;
        }

        std::wstring text;
        if (ReadString(key.get(), L"AspectRatio", text)) {
            settings.aspectRatio = ParseAspectRatio(text);
        }
        if (ReadString(key.get(), L"AudioRoutingMode", text)) {
            settings.audioRoutingMode = ParseAudioRoutingMode(text);
        }
        if (ReadString(key.get(), L"AudioCaptureDeviceName", text)) {
            settings.audioCaptureDeviceName = text;
        }

        (void)SaveSettings(settings);
        return settings;
    }

    bool SaveSettings(const AppSettings& settings)
    {
        wil::unique_hkey key = OpenSettingsKey(KEY_SET_VALUE, true);
        if (!key) {
            return false;
        }

        const bool ok =
            WriteDword(key.get(), L"ShowPipTopLeft", settings.showPipTopLeft ? 1u : 0u) &&
            WriteDword(key.get(), L"ShowPipTopRight", settings.showPipTopRight ? 1u : 0u) &&
            WriteDword(key.get(), L"ShowPipBottomLeft", settings.showPipBottomLeft ? 1u : 0u) &&
            WriteString(key.get(), L"AspectRatio", AspectRatioConfigValue(settings.aspectRatio)) &&
            WriteString(key.get(), L"AudioRoutingMode", AudioRoutingModeConfigValue(settings.audioRoutingMode)) &&
            WriteString(key.get(), L"AudioCaptureDeviceName", settings.audioCaptureDeviceName);

        if (!ok) {
            VirtuaCamLog::LogWin32(L"Write settings registry failed", GetLastError());
        }
        return ok;
    }

    bool DeleteLegacySettingsFile()
    {
        const std::filesystem::path legacyPath = LegacySettingsPath();
        if (legacyPath.empty()) {
            return true;
        }

        std::error_code ec;
        std::filesystem::remove(legacyPath, ec);
        if (ec) {
            VirtuaCamLog::LogLine(std::format(
                L"Legacy settings file delete failed: {} error={}",
                legacyPath.wstring(),
                ec.value()));
            return false;
        }
        return true;
    }
}
