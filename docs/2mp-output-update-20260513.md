# VirtuaCam 2MP Output Update

Date: 2026-05-13

## Goal

Make the default VirtuaCam output 1920x1080 at 30 fps, while keeping explicit 640x480 fallback formats needed by HLK record scenarios.

## Source-backed implementation notes

- Windows KS video format ranges carry output width, height, frame rate, cropping, and sample size. The driver-side `KS_DATARANGE_VIDEO` and `KS_DATARANGE_VIDEO2` defaults now advertise 1920x1080 for 16:9 and 1080x1920 for 9:16. Source: Microsoft Learn, [Selecting a Stream Format](https://learn.microsoft.com/en-us/windows-hardware/drivers/stream/selecting-a-stream-format) and [`KS_DATARANGE_VIDEO`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-tagks_datarange_video).
- Camera profile media descriptions expose resolution and max frame rate per profile/pin. The in-driver profile media info and INF profile registry entries now advertise 1920x1080 first, with 640x480 retained. Source: Microsoft Learn, [`KSCAMERA_PROFILE_MEDIAINFO`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-_kscamera_profile_mediainfo).
- DirectShow clients request width/height through stream configuration, so the browser proof and user-mode defaults now request exact 1920x1080. Source: Microsoft Learn, [`IAMStreamConfig`](https://learn.microsoft.com/en-us/windows/win32/api/strmif/nn-strmif-iamstreamconfig).

## Small-screen behavior

The producer already renders into a fixed 1920x1080 canvas. `GetContainCanvasViewport` computes an aspect-preserving fit inside the selected target aspect, clears the canvas to black, and draws the source into that viewport. That means a source smaller than 1080p is upscaled and padded instead of being rejected or cropped. `DriverBridge` now crops that fixed producer canvas to the negotiated output aspect before scaling, so 9:16 and 4:3 outputs do not non-uniformly stretch the 16:9 canvas.

## Files changed for 2MP

- `driver-project/capture.cpp`: default 16:9 ranges moved from 1280x720 to 1920x1080; 9:16 moved from 720x1280 to 1080x1920.
- `driver-project/avshws.h`: legacy BGR24 side-channel buffer dimensions moved to 1920x1080.
- `driver-project/filter.cpp`: camera profile media info moved to 1920x1080 and 1080x1920.
- `driver-project/avshws.inf`: profile registry media entries moved to 1920x1080 and 1080x1920.
- `software-project/src/VirtuaCam/DriverBridge.*`: user-mode default output buffer moved to 1920x1080.
- `software-project/src/VirtuaCam/DriverBridge.*`: bridge blit samples the producer canvas through aspect-aware UV crop constants before scaling to the active driver format.
- `software-project/src/VirtuaCam/Formats.h`: 1920x1080 is first in the UI resolution list.
- `software-project/webcam.html`, `webcam.html`, and `scripts/host-webcam-html-proof.ps1`: browser proof expects exact 1920x1080.
- `README.md`, `driver-project/README.md`, and `software-project/README.md`: docs updated.

## Deferred

Full vHLK is intentionally not run in this update. Per instruction, vHLK testing continues in the next chat and must stop after 10 failures to patch again.
