cmake_minimum_required(VERSION 3.20)
set(CMAKE_SYSTEM_VERSION "10.0.22621.0")
project(VirtuaCamSetup LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "$<IF:$<CONFIG:Debug>,MultiThreadedDebugDLL,MultiThreadedDLL>")

add_executable(VirtuaCamSetup WIN32
    src/VirtuaCamSetup.cpp
    src/VirtuaCamSetup.rc
)

target_compile_definitions(VirtuaCamSetup PRIVATE UNICODE _UNICODE NOMINMAX)
target_link_libraries(VirtuaCamSetup PRIVATE
    advapi32
    comctl32
    d3d11
    d3dcompiler
    dwmapi
    dxgi
    mf
    mfplat
    mfreadwrite
    mfuuid
    ole32
    propsys
    newdev
    setupapi
    shell32
    user32
    uxtheme
)
