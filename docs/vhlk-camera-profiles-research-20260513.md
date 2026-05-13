# vHLK Camera Profiles Research - 2026-05-13

## Trigger

Failed-only vHLK run `test-reports/vhlk-oneclick-20260513-080058` stopped with two `CAMERA_PROFILES` failures:

- `Camera Driver Controls Device Test - CAMERA_PROFILES - Log all profiles`
- `Camera Driver Controls Device Test - CAMERA_PROFILES - Verify KSCAMERAPROFILE_BalancedVideoAndPhoto enum all`

Because this fix changes driver profile publication and two vHLK failures were present, both gates were used:

- PDF gate: read local PDFs before driver changes.
- Web gate: checked current Microsoft Learn sources before patching.

## PDF References Read

- `pdfs/mslearn-vhlk-fixes/camera-profiles.pdf`
  - First pages / KS API Profile: `KsInitializeDeviceProfile` and `KsPublishDeviceProfile`.
  - Pages 4, 6, and 7: `KSCAMERA_PROFILE_INFO`, `KSCAMERA_PROFILE_PININFO`, and `KSCAMERA_PROFILE_MEDIAINFO`.
  - Pages 9 and 10: `KSPROPERTY_CAMERACONTROL_EXTENDED_PROFILE`.
  - Pages 11 through 14: `OEMCameraProfiles` INF profile registry format and profile media entries.
- `pdfs/mslearn-vhlk-fixes/ksproperty-cameracontrol-extended-profile.pdf`
  - Page 1: required `KSCAMERA_EXTENDEDPROP_HEADER` fields.
- `pdfs/mslearn-vhlk-fixes/camera-driver-controls.pdf`
  - First pages: universal camera driver control list includes `KSPROPERTY_CAMERACONTROL_EXTENDED_PROFILE`.

## Web References

- Microsoft Learn, Camera Profiles: https://learn.microsoft.com/en-us/windows-hardware/drivers/stream/camera-profiles
- Microsoft Learn, `KSPROPERTY_CAMERACONTROL_EXTENDED_PROFILE`: https://learn.microsoft.com/en-us/windows-hardware/drivers/stream/ksproperty-cameracontrol-extended-profile
- Microsoft Learn, `KSCAMERA_PROFILE_INFO`: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-_kscamera_profile_info
- Microsoft Learn, `KSCAMERA_PROFILE_MEDIAINFO`: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ksmedia/ns-ksmedia-_kscamera_profile_mediainfo

## Fix Rationale

- Camera profile publication must provide profile-specific pin arrays and media info counts. The runtime `KsPublishDeviceProfile` path used one shared four-entry media list for all profiles, while the INF registry used four media entries only for `VideoRecording` and two entries for the other profiles.
- `KSPROPERTY_CAMERACONTROL_EXTENDED_PROFILE` must validate documented header fields: `Version`, `PinId`, `Size`, `Capability`, and `Flags`.
- Profile control selection must accept `KSCAMERAPROFILE_Legacy` and `GUID_NULL` as valid non-published selections. Published profile data must not include the legacy profile.

## Current Patch Shape

- Runtime profile publication now uses a full media table for `KSCAMERAPROFILE_VideoRecording` and a standard media table for `VideoConferencing`, `HighQualityPhoto`, `BalancedVideoAndPhoto`, and the custom profile.
- Profile-control SET validation now checks `Version == 1` and `Capability == KSCAMERA_EXTENDEDPROP_CAPS_ASYNCCONTROL`, and accepts `GUID_NULL`.
- `scripts/test-camera-profile-contract.ps1` checks INF/runtime profile contract drift.

## 2026-05-13 Follow-Up

Failed-only vHLK run `test-reports/vhlk-oneclick-20260513-090356` still showed the same two failures. A read-only DUT check immediately after the run showed no `ROOT\AVSHWS` device and no `avshws` driver package installed. The failed-only runner had queued HLK after browser proof restored the `clean` checkpoint, so that run did not validate the patched driver package.

Automation fix:

- `scripts/install-driver-for-vhlk.ps1` installs staged `output/` artifacts into `driver-test`, leaves the driver installed, handles reboot-required install output, and verifies `ROOT\AVSHWS` plus the driver package before vHLK.
- `scripts/run-vhlk-failed-only.ps1` now runs that install step before queueing failed-only vHLK unless `-SkipDutInstall` is supplied.
- The install verifier checks the concrete instance `ROOT\AVSHWS\0000`; querying parent `ROOT\AVSHWS` is not sufficient for `pnputil /enum-devices /instanceid`.
- Each vHLK install uses a timestamped guest root so cleanup does not fail on DLLs still held by the watcher service from an earlier install root.
