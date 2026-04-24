# Phase 5 Plan: OnIdle Frame-Push Timing

Context: after phase 4, `DriverBridge` is unconditional and resilient to
recoverable send failures. Phase 5 is about making the idle-loop contract
explicit so we always render the broker frame before attempting to push to the
driver, and so we never send a stale/null texture when the broker exports are
missing or not ready.

## Findings That Shape This Phase

- `software-project/src/VirtuaCam/App.cpp` already calls
  `g_pfnRenderBrokerFrame()` before `DriverBridge::SendFrame()`, but the
  sequencing is implicit inside one `OnIdle()` block rather than expressed as a
  guarded frame-push step.
- Current send guard is close to correct (`g_driverBridge`,
  `g_driverBridge->IsActive()`, `g_pfnGetSharedTexture`, non-null texture), but
  it does not explicitly tie the send attempt to a successful broker render
  callback being available on that idle tick.
- `RenderBrokerFrame()` updates broker state and shared texture even when no
  producer stream is currently connected. That means phase 5 should preserve
  "render first, then optionally push" regardless of broker telemetry state.
- The optional dedicated frame-push thread in task 5.3 would add concurrency,
  timer lifetime, and shutdown complexity. It is better deferred until the
  single-threaded path is locked down and revalidated.

## Scope

- Refactor `OnIdle()` so the broker-render -> telemetry -> driver-send order is
  explicit and easy to validate.
- Gate `SendFrame()` on both a render callback being present for the tick and a
  non-null shared texture from the broker.
- Keep the current idle-thread execution model for now; do not introduce a
  waitable-timer worker in this phase.

## Tasks

- [ ] 5.1 Make `OnIdle()` explicitly render the broker frame before any
      driver-send attempt, independent of broker state.
- [ ] 5.2 Route driver sends through a helper/guard that only runs when:
      broker render export exists for the tick, `DriverBridge` is active,
      `GetSharedTexture` export exists, and the returned shared texture is
      non-null.
- [ ] 5.3 Defer the optional dedicated frame-push thread until after build/link
      validation in phase 6.

## Validation

- Rebuild `VirtuaCam` after the idle-loop refactor.
- Confirm `OnIdle()` still updates telemetry every tick and only pushes frames
  after broker render for that tick.
- Confirm null shared-texture cases are skipped safely without dereferencing.

## Deferred Follow-Up

- If idle-loop cadence proves unstable under load, reuse this explicit helper
  boundary for a later `SetWaitableTimer`-driven sender thread.
