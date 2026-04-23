#include <windows.h>
#include <objbase.h>

// Minimal COM-registerable stub for the direct-driver build.
// This keeps `regsvr32 DirectPortClient.dll` working for existing scripts,
// but intentionally provides no class objects.

extern "C" HRESULT __stdcall DllCanUnloadNow()
{
    return S_OK;
}

extern "C" HRESULT __stdcall DllGetClassObject(_In_ REFCLSID, _In_ REFIID, _Outptr_ LPVOID* ppv)
{
    if (ppv) *ppv = nullptr;
    return CLASS_E_CLASSNOTAVAILABLE;
}

extern "C" HRESULT __stdcall DllRegisterServer()
{
    return S_OK;
}

extern "C" HRESULT __stdcall DllUnregisterServer()
{
    return S_OK;
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hModule);
    }
    return TRUE;
}

