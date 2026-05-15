# vHLK Lab Blockers 2026-05-15

## Blocked Tests

- `Camera Driver Test - Photo Capture - Capture an NV12 photo from each format exposed on the preferred stream for video preview`

## Current Status

- Artifact: `test-reports/vhlk-oneclick-20260515-031300`
- Export: `test-reports/vhlk-failed-export-20260515-060000`
- Failure task: `HLK Config Library Tasks Per Test - Native`
- Failed setup command: `Configure Crash dump event log setting`
- Missing parameter: `WTT\VirtualAsset`
- Result code: `0x8201acad`

## Evidence

- `failed-result-details/Camera_Driver_Test_-_Photo_Capture_-_Capture_an_NV12_photo_from_each_format_exposed_on_the_preferred_stream_for_video_preview/result-1-log-30.wtl`
- Lines in that log show `CKeyEvaluator::ExpandString : Parameter [WTT\VirtualAsset] not Found` and `Configure Crash dump event log setting` failure.
- The camera I/O task body did not run.

## Skip File

Machine-readable skip list:

```powershell
.\docs\vhlk-blocked-test-names.txt
```

Failed-only runner behavior:

```powershell
.\scripts\run-vhlk-failed-only.ps1
```

The runner filters `docs\vhlk-blocked-test-names.txt` unless `-SkipBlockerFilter` is used.
