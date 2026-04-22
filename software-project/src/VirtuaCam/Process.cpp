#include "pch.h"
#include "Process.h"
#include "Resource.h"
#include "RuntimeLog.h"
#include <string>
#include <sstream>
#include <map>

bool ParseCommandLine(const WCHAR* cmdLine, std::wstring& type, std::wstring& args)
{
    std::wistringstream iss(cmdLine);
    std::wstring key;
    
    while (iss >> key)
    {
        if (key == L"--type")
        {
            iss >> type;
        }
        else
        {
            if (!args.empty()) args += L" ";
            args += key;
            
            std::wstring value;
            if (iss >> value)
            {
                args += L" ";
                args += value;
            }
        }
    }
    return !type.empty();
}

void LoadProducerModule(const std::wstring& type, ProducerModule& module)
{
    std::wstring dllName;
    if (type == L"camera") dllName = L"DirectPortMFCamera.dll";
    else if (type == L"capture") dllName = L"DirectPortMFGraphicsCapture.dll";
    else if (type == L"consumer") dllName = L"DirectPortConsumer.dll";
    else return;

    module.hModule = LoadLibraryExW(dllName.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (module.hModule)
    {
        module.Initialize = (PFN_InitializeProducer)GetProcAddress(module.hModule, "InitializeProducer");
        module.Process = (PFN_ProcessFrame)GetProcAddress(module.hModule, "ProcessFrame");
        module.Shutdown = (PFN_ShutdownProducer)GetProcAddress(module.hModule, "ShutdownProducer");
    }
    else
    {
        VirtuaCamLog::LogWin32(std::format(L"LoadLibraryExW failed: {}", dllName), GetLastError());
    }
}

int APIENTRY wWinMain(_In_ HINSTANCE hInstance, _In_opt_ HINSTANCE, _In_ LPWSTR lpCmdLine, _In_ int)
{
    VirtuaCamLog::InitOptions logOpts;
    logOpts.logFileName = L"virtuacam-process.log";
    logOpts.attachConsole = false;
    logOpts.allocConsoleIfMissing = false;
    VirtuaCamLog::Init(logOpts);

    RETURN_IF_FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));

    std::wstring producerType, producerArgs;
    if (!ParseCommandLine(lpCmdLine, producerType, producerArgs))
    {
        VirtuaCamLog::LogLine(L"ParseCommandLine failed");
        return 1;
    }

    ProducerModule module;
    LoadProducerModule(producerType, module);

    if (!module.hModule || !module.Initialize || !module.Process || !module.Shutdown)
    {
        VirtuaCamLog::LogLine(std::format(L"Producer module incomplete: type={}", producerType));
        return 2;
    }

    if (FAILED(module.Initialize(producerArgs.c_str())))
    {
        VirtuaCamLog::LogLine(std::format(L"InitializeProducer failed: type={} args={}", producerType, producerArgs));
        module.Shutdown();
        FreeLibrary(module.hModule);
        return 3;
    }
    
    MSG msg = {};
    while (msg.message != WM_QUIT)
    {
        if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        else
        {
            module.Process();
            Sleep(1); 
        }
    }

    module.Shutdown();
    FreeLibrary(module.hModule);
    CoUninitialize();
    return 0;
}
