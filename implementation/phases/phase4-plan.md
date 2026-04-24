# Phase 4 Plan: DriverBridge Hardening

Context: phase 2 made `DriverBridge` unconditional. Phase 4 now makes path
safer under real runtime conditions: fix known userland bug, make frame-send
path recover from transient driver failures, expose driver health in UI, and
lock in frame-buffer behavior so hot path stops reallocating.

## Findings That Shape This Phase

- `driver-project/UserLand/DriverInterface/Device.cpp` still has exact
  operator-precedence bug called out in task 4.1.
- `software-project/src/VirtuaCam/DriverBridge.cpp` already checks
  `KSPROPERTY_SUPPORT_SET` correctly, but `SendFrame()` still fails hard on
  property-set errors and does not try to re-enumerate device.
- `DriverBridge` currently resizes `m_rgbBuffer` in `Initialize()` and clears
  it in `Shutdown()`. That means hot path itself does not reallocate each
  frame, but phase intent is stronger: make max-frame buffer constructor-owned
  and persistent across reconnects.
- Driver-side property path is KS property automation table, not custom
  `CTL_CODE` IOCTL. `filter.cpp` handles `KSPROPERTY` set requests directly, so
  task 4.6 is verification/defer, not `METHOD_BUFFERED` to `METHOD_IN_DIRECT`
  code change in this phase.
- Driver-side `CHardwareSimulation::SetData()` copies incoming 24-bit rows into
  bottom-up RGB24 buffer. `DriverBridge::UploadMappedFrame()` copies broker
  BGRA bytes as `B,G,R` into 24-bit output, which matches driver RGB24/BGR byte
  order contract. No extra channel swap needed.

## Scope

- Fix precedence bug in legacy userland driver helper.
- Harden `DriverBridge` against recoverable `IKsPropertySet::Set()` failures.
- Expose driver health in preview telemetry and tray tooltip.
- Move send-buffer ownership to constructor lifetime.
- Record verified/deferred items for format contract and KS-property transport.

## Tasks

- [ ] 4.1 Fix precedence bug in
      `driver-project/UserLand/DriverInterface/Device.cpp`.
- [ ] 4.2 Add retry / re-init logic in
      `software-project/src/VirtuaCam/DriverBridge.cpp` for recoverable driver
      send failures.
- [ ] 4.3 Verify format contract:
      broker output `BGRA8` -> userland packed `BGR24` -> driver
      `CHardwareSimulation::SetData()` matches existing byte order. No channel
      swap required; document in code/comments and done log.
- [ ] 4.4 Add `GetDriverBridgeStatus()` free function in `App.cpp`, plumb it to
      UI, show driver state in preview telemetry and tray tooltip.
- [ ] 4.5 Pre-allocate `DriverBridge` send buffer in constructor and keep it
      across shutdown/re-init cycles.
- [ ] 4.6 Verify current avshws transport is KS property-set path, not custom
      IOCTL `METHOD_BUFFERED` vs `METHOD_IN_DIRECT` path. Defer transport-model
      redesign until property path replaced.

## Validation

- Build `software-project` after `DriverBridge` and UI changes.
- Build `driver-project/UserLand/VirtualCameraDriver.sln` after `Device.cpp`
  fix.
- Confirm telemetry text includes both broker and driver state.
- Confirm reconnect logic compiles cleanly and only retries on recoverable
  property-set failures.

## Deferred Follow-Up

- Task 4.6 redesign needs transport change deeper than current KS property-set
  contract. Not safe as incidental patch.
- If phase 5 later moves frame push off idle thread, reuse new driver-status
  reporting instead of inventing second status path.
