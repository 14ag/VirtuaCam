# VirtuaCam Research Implementation Log

## Baseline

- Date: 2026-06-01
- Workspace root: `C:\Users\philip\sauce\virtual-webcam`
- Code root: `C:\Users\philip\sauce\virtual-webcam\VirtuaCam`
- Git HEAD: `c70c78f`
- Search note: `rg` was not available in this shell; PowerShell `Select-String` was used after verifying `powershell Get-Command rg -ErrorAction SilentlyContinue`.

Dirty worktree before implementation edits:

```text
 M scripts/build-all.ps1
 M scripts/test-setup-registry-debug.ps1
 M software-project/src/VirtuaCam/DriverBridge.cpp
 M software-project/src/VirtuaCam/RuntimeLog.cpp
 M software-project/src/VirtuaCam/RuntimeLog.h
 M wizard-project/src/VirtuaCamSetup.cpp
?? docs/research/
```

Existing dirty files above are preserved as user work. This implementation tranche avoids modifying those files unless explicitly required for the blueprint.

## Code Map

- Producer shared texture publication: `software-project\src\VirtuaCam\Process.cpp`
  - Capture producer `ProcessFrame`: around line 1236.
  - Camera/file producer `ProcessFrame`: around line 2466.
  - Producer shared manifest creation: around lines 994 and 2205.
  - Producer fence publish: around lines 1281, 1285, 2472, 2475, 2526, and 2529.
- Broker and compositor: `software-project\src\VirtuaCam\Broker.cpp`, `Discovery.cpp`, and `Multiplexer.cpp`
  - Broker shared output resources: `Broker.cpp` around line 110.
  - Broker render/export loop: `Broker.cpp` around line 225.
  - Process snapshot discovery: `Discovery.cpp` around line 38.
  - Multiplexer producer connection: `Multiplexer.cpp` around line 209.
  - Multiplexer per-frame copy on advanced fence: `Multiplexer.cpp` around lines 331-335.
  - Broker output copy still present: `Broker.cpp` around line 307.
- Driver upload path: `software-project\src\VirtuaCam\DriverBridge.cpp`
  - FrameEx send: around line 771.
  - BGRA FrameEx upload: around line 789.
  - NV12 FrameEx upload: around line 817.
  - Legacy BGR upload: around line 863.
  - GPU-to-CPU staging map in `SendFrame`: around lines 1459-1515.
- FrameEx ABI and driver handling:
  - `shared\VirtuaCamDriverAbi.h`: `VIRTUACAM_FRAME_EX_HEADER` around line 35; header size assertion around line 52.
  - `driver-project\filter.cpp`: FrameEx property handling around line 706.
  - `driver-project\hwsim.cpp`: `CHardwareSimulation::SetFrameEx` around line 2648.
- AVStream timing/framing:
  - `driver-project\capture.cpp`: allocator framing edit around lines 455-480.
  - `driver-project\capture.cpp`: `CapturePinAllocatorFraming` declaration around line 2300.

## Research Sources

- Local paper notes: `docs\research\papers\README.md`
- GPUSync: `docs\research\papers\gpusync-rtss13c.pdf`
- Globally scheduled GPUs: `docs\research\papers\globally-scheduled-real-time-multiprocessor-systems-with-gpus-rtns10.pdf`
- Elliott dissertation: `docs\research\papers\elliott-real-time-gpu-scheduling-dissertation-2015.pdf`
- Lock-free streaming overlays: `docs\research\papers\qos-monitoring-lock-free-streaming-overlays-2021.pdf`
- Multi-GPU configuration paper: `docs\research\papers\exploring-real-time-multi-gpu-configurations-rtss14c-long.pdf`

Applicability limit: GPU scheduling papers inform measurement, budgeting, stale-frame policy, and synchronized publication. Microsoft D3D11, Media Foundation, and AVStream documentation remain the source of truth for Windows API behavior.

## Initial Implementation Tranche

Goal: implement sidecar producer status and whitebox coverage without changing `BroadcastManifest`, FrameEx ABI, or driver media negotiation.

Tasks covered:

- 1.1 baseline code map and worktree state.
- 1.3 research appendix linkage.
- 2.1 sidecar status mapping ABI.
- 2.2 odd/even atomic publish/read protocol.
- 3.1 direct expected-producer discovery path before fallback snapshot scanning.
- 3.2 producer metadata validation whitebox hooks.
- 4.2 producer copy-count telemetry hook in multiplexer.
- 7.3 performance-audit assertions for sidecar status and existing no-debug checks.

Implemented changes:

- Added optional `DirectPortStatusV1` sidecar mapping named `Local\DirectPort_Producer_Status_<pid>`.
- Kept `BroadcastManifest` layout unchanged.
- Published producer status with odd/even sequence guards and stable broker reads.
- Added expected-PID discovery before process snapshot fallback.
- Rendered the multiplexer directly into the broker shared output texture to remove the broker output copy.
- Added status-aware stale producer filtering and producer copy-count tracking in the multiplexer.
- Extended performance-audit whitebox coverage for status ABI, publication, discovery, stale policy, and direct output rendering.

Corrective note:

- `driver-project\avshws.inf` is ignored by git but is the source INF consumed by local tests and packaging. The local copy was updated with Camera Profile V2 registry entries after `test-camera-profile-contract.ps1` exposed a missing-profile failure.

Validation completed:

```text
.\scripts\test-vhlk-runner-flow.ps1
.\scripts\test-setup-registry-debug-mic.ps1
.\scripts\test-code-review-20260511.ps1
.\scripts\test-frame-ex-abi.ps1
.\scripts\test-camera-profile-contract.ps1
.\scripts\test-driver-pnp-contract.ps1
.\scripts\test-ai-window-cli.ps1
.\scripts\test-capture-source-menu-contract.ps1
.\scripts\test-performance-audit.ps1 -SkipBuild
.\scripts\build-all.ps1 -Clean
```

Deferred after initial tranche:

- Baseline runtime latency report under `test-reports\performance-audit\<timestamp>\`.
- DriverBridge staging/readback pool.
- Media Foundation async Source Reader conversion.
- AVStream allocator framing tuning.
- FrameEx native fuzz/stress expansion.
- Driver-test, failed-only vHLK, and final full vHLK gates.

## Second Implementation Tranche

Goal: complete the highest-value runtime pipeline changes that can be validated locally without changing DirectShow names, FrameEx property IDs, or media negotiation.

Tasks covered:

- 4.3 DriverBridge staging/readback pool.
- 5.1 async Media Foundation Source Reader callback.
- 5.2 latest-sample-only producer handoff.
- 5.3 static image and capture mode preservation.
- 6.1 AVStream allocator framing review.
- 6.3 append-only driver timing/status counters.
- 7.1 expanded FrameEx malformed-payload whitebox coverage.

Implemented changes:

- Replaced single blocking DriverBridge BGRA/NV12 staging maps with a three-slot readback pool using `D3D11_MAP_FLAG_DO_NOT_WAIT`.
- Preserved FrameEx BGRA/NV12 upload order and legacy BGR24 fallback.
- Added `AsyncSourceReaderCallback` for camera/file producers and configured `MF_SOURCE_READER_ASYNC_CALLBACK` before reader creation.
- Replaced the camera/file producer blocking `ReadSample` hot path with a single-slot latest-sample handoff that overwrites stale samples.
- Preserved static image producer behavior and file end-of-stream looping.
- Raised capture allocator framing from 2 to 3 outstanding frames in both the edited runtime framing and `CapturePinAllocatorFraming`.
- Appended driver status fields for stale upload rejections, busy upload rejections, last accepted frame id, accepted-frame performance counter, and accepted-frame system time.
- Kept `VIRTUACAM_DRIVER_STATUS_V1_SIZE` at 112 and guarded append-only status fields with static asserts.
- Extended `test-frame-ex-abi.ps1` coverage for short headers, bad versions, bad payload offsets, short payloads, mismatched payload lengths, bad stride, bad dimensions, unsupported formats, and append-only status telemetry.

AVStream source notes:

- `pdfs\mslearn-vhlk-fixes\data-range-intersections-in-avstream.pdf`: no embedded PDF TOC; first page confirms minidrivers expose supported data ranges through `KSPIN_DESCRIPTOR` and may provide an intersection handler.
- `pdfs\mslearn-vhlk-fixes\ks-data-formats-and-data-ranges.pdf`: no embedded PDF TOC; first page distinguishes single `KSDATAFORMAT` values from broader `KSDATARANGE` descriptions.
- `pdfs\mslearn-vhlk-fixes\tagks-datarange-video.pdf`: no embedded PDF TOC; first page documents `KS_DATARANGE_VIDEO` fields and confirms unused stream-description fields remain zero.
- Microsoft allocator guidance recommends at least three outstanding frames for smoother AVStream dataflow. Applied only to allocator framing; media negotiation stayed unchanged.

Validation completed after tranche 2:

```text
.\scripts\test-frame-ex-abi.ps1
.\scripts\test-driver-pnp-contract.ps1
.\scripts\test-performance-audit.ps1 -SkipBuild -SkipRuntime
PowerShell parse check for changed/key scripts
cmake --build .\software-project\build --config Release --target VirtuaCam DirectPortBroker VirtuaCamProcess
MSBuild .\driver-project\avshws.vcxproj /p:Configuration=Release /p:Platform=x64 /m
.\scripts\test-vhlk-runner-flow.ps1
.\scripts\test-setup-registry-debug-mic.ps1
.\scripts\test-code-review-20260511.ps1
.\scripts\test-camera-profile-contract.ps1
.\scripts\test-ai-window-cli.ps1
.\scripts\test-capture-source-menu-contract.ps1
.\scripts\build-all.ps1 -Clean
.\scripts\test-performance-audit.ps1
```

Remaining gates not run:

- `.\scripts\test-driver-dshow-probe.ps1 -Modes list,yuy2,nv12,rgb32,video2`
- `.\scripts\hyperv-proof-windows-camera.ps1`
- failed-only vHLK
- final full vHLK
