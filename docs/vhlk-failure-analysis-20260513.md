# vHLK Failure Analysis - 2026-05-13

Latest saved run: `test-reports\vhlk-oneclick-20260513-021033`.

That run saved aggregate status only: `113` total, `26` passed, `77` failed, `7` not run, `2` queued, and `1` running when the controller session broke. It preserved only five failure names in `latest-status.json`, so `test-reports\vhlk-oneclick-20260512-202918\failed-test-names.txt` remains the complete local failed-name baseline.

## Failure Groups

- Photo/multistream/profile failures dominate the baseline. Fix target: expose a real still-image KS pin and publish still stream profile metadata.
- Preview/record failures overlap format negotiation and concurrent stream open. Fix target: allow compatible preview/capture/still pins to share the simulated source instead of rejecting the second pin with `STATUS_SHARING_VIOLATION`.
- DirectShow/IAMStreamConfig failures map to data-range intersection and set-format behavior. Current code already accepts the second pre-run set-format and keeps VideoInfo/VideoInfo2 ranges visible.
- DF InfVerif/Reinstall/PnP failures map to package validation plus fresh install/reinstall behavior. `InfVerif.exe` is not installed in the local WDK image, so local `/h` validation is blocked until that tool is installed.

## References Read Before Driver Edits

- Local PDF TOC/first pages read from `pdfs\mslearn-vhlk-fixes\capture-preview-still-category.pdf`, `camera-profiles.pdf`, `data-range-intersections-in-avstream.pdf`, `ks-data-formats-and-data-ranges.pdf`, `selecting-a-stream-format.pdf`, `iamstreamconfig.pdf`, and `infverif-h.pdf`.
- Microsoft Learn: Capture, Preview, and Still Category; Camera Profiles/KsPublishDeviceProfile; Data Range Intersections in AVStream; InfVerif `/h`.

## Applied Code Rationale

- `PINNAME_VIDEO_STILL` is valid for still-image streams, and Microsoft describes capture, preview, and still stream categories as nearly identical for data formats. The driver now exposes a still pin using existing uncompressed YUY2/NV12/RGB32 ranges.
- Camera profiles must be associated with the `KSCATEGORY_VIDEO_CAMERA` interface and published per supported profile. The driver already sets `KSFILTER_FLAG_PRIORITIZE_REFERENCEGUID`; profile pin tables and INF profile registry now include still stream media.
- AVStream may call set-format again before run with actual surface parameters; compatible multistream opens should not fail solely because one peer pin already acquired the simulated source.
