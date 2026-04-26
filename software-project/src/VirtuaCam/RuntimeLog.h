#pragma once

#include "pch.h"

#include <string>

namespace VirtuaCamLog
{
    struct InitOptions
    {
        PCWSTR logFileName = L"virtuacam-runtime.log";
        bool attachConsole = true;
        bool allocConsoleIfMissing = false;
        bool enabled = false;
    };

    void Init(const InitOptions& options);
    void Shutdown();

    void LogLine(const std::wstring& message);
    void LogHr(const std::wstring& context, HRESULT hr);
    void LogWin32(const std::wstring& context, DWORD error);

    void ConfigureDllSearchPaths();

    std::wstring GetExePath();
    std::wstring GetExeDir();
    std::wstring GetCurrentDir();
    std::wstring GetLogPath();

    void ShowAndLogError(HWND hwnd, PCWSTR message, PCWSTR title, HRESULT hr);
}
