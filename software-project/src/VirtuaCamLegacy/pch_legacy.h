#pragma once

// Legacy MF virtual-camera + C++/WinRT precompiled header.
// Kept out of src/VirtuaCam so default tree has zero winrt:: / <winrt/> refs.

#include "../VirtuaCam/pch.h"

#include "mfvirtualcamera.h"

#include "winrt/base.h"
#include "winrt/Windows.ApplicationModel.h"
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

namespace winrt
{
    template<> inline bool is_guid_of<IMFMediaSourceEx>(guid const& id) noexcept
    {
        return is_guid_of<IMFMediaSourceEx, IMFMediaSource, IMFMediaEventGenerator>(id);
    }
    template<> inline bool is_guid_of<IMFMediaSource2>(guid const& id) noexcept
    {
        return is_guid_of<IMFMediaSource2, IMFMediaSourceEx, IMFMediaSource, IMFMediaEventGenerator>(id);
    }
    template<> inline bool is_guid_of<IMFMediaStream2>(guid const& id) noexcept
    {
        return is_guid_of<IMFMediaStream2, IMFMediaStream, IMFMediaEventGenerator>(id);
    }
    template<> inline bool is_guid_of<IMFActivate>(guid const& id) noexcept
    {
        return is_guid_of<IMFActivate, IMFAttributes>(id);
    }
}

