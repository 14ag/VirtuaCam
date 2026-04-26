# VirtuaCam BSOD Fix Plan
## Error: IRQL_NOT_LESS_OR_EQUAL on camera start

---

## Root Cause Summary

IRQL_NOT_LESS_OR_EQUAL means paged (or invalid) memory was accessed at DISPATCH_LEVEL.
The DPC timer fires `FakeHardware` at DISPATCH_LEVEL. It reaches `FillScatterGatherBuffers`
which touches the actual frame buffer data (`SGEntry->Virtual`). If those buffers are in
paged pool the CPU takes a page fault at DISPATCH_LEVEL and Windows bugchecks.

---

## Bug 1 — PRIMARY BSOD CAUSE
**File:** `capture.cpp`
**Location:** `DECLARE_SIMPLE_FRAMING_EX(CapturePinAllocatorFraming, ...)`

The framing includes `KSALLOCATOR_REQUIREMENTF_PREFERENCES_ONLY`.
This downgrades the `KSMEMORY_TYPE_KERNEL_NONPAGED` requirement to a *hint*.
The OS or a downstream filter is free to allocate frame buffers in paged pool.
`FillScatterGatherBuffers` then writes into those paged buffers from the DPC
at DISPATCH_LEVEL — instant BSOD.

**Fix:** Remove `KSALLOCATOR_REQUIREMENTF_PREFERENCES_ONLY` from the flags.

```
// BEFORE
KSALLOCATOR_REQUIREMENTF_SYSTEM_MEMORY |
    KSALLOCATOR_REQUIREMENTF_PREFERENCES_ONLY,

// AFTER
KSALLOCATOR_REQUIREMENTF_SYSTEM_MEMORY,
```

---

## Bug 2 — DATA RACE (corruption / potential fault)
**File:** `hwsim.cpp`
**Functions:** `SetData` vs `FakeHardware`

`SetData` writes rows into `m_TemporaryBuffer` at PASSIVE_LEVEL.
`FakeHardware` reads the entire buffer via `RtlCopyMemory` at DISPATCH_LEVEL.
There is no spinlock guarding the *content* of the buffer — only `m_ClientConnected`
is spinlock-protected. The DPC can preempt `SetData` mid-write and read a half-written frame.
This will not BSOD on its own but produces torn frames and can trigger downstream issues.

**Fix:** Protect the `m_TemporaryBuffer` content copy with `m_FrameLock`.

In `SetData`, hold `m_FrameLock` across the `RtlCopyMemory` loop:
```cpp
// acquire spinlock before loop - write is now atomic wrt the DPC
KeAcquireSpinLock(&m_FrameLock, &irql);
for (ULONG y = 0; y < m_Height; y++) {
    PUCHAR buffer   = m_TemporaryBuffer + ((m_Width * 3) * (m_Height - 1 - y));
    PUCHAR dataLine = (PUCHAR)(data)    + ((m_Width * 3) * y);
    RtlCopyMemory(buffer, dataLine, m_Width * 3);
}
m_LastFrameTime = now;   // move the timestamp update inside the same lock
KeReleaseSpinLock(&m_FrameLock, irql);
```

In `FakeHardware`, the existing spinlock around `m_ClientConnected` must be
extended to also cover the `RtlCopyMemory` of `m_TemporaryBuffer`:
```cpp
KeAcquireSpinLockAtDpcLevel(&m_FrameLock);
clientConnected = m_ClientConnected;
lastFrameTime   = m_LastFrameTime;
// copy while holding lock so SetData cannot write concurrently
const PUCHAR sourceFrame = (clientConnected && m_TemporaryBuffer)
    ? m_TemporaryBuffer
    : (m_DefaultFrameBuffer ? m_DefaultFrameBuffer : m_TemporaryBuffer);
if (sourceFrame) {
    RtlCopyMemory(m_SynthesisBuffer, sourceFrame, m_ImageSize);
} else {
    RtlZeroMemory(m_SynthesisBuffer, m_ImageSize);
}
KeReleaseSpinLockFromDpcLevel(&m_FrameLock);
```

Note: `m_SynthesisBuffer` and `m_TemporaryBuffer` are both NonPagedPool so
`RtlCopyMemory` under a spinlock at DISPATCH_LEVEL is legal.

---

## Bug 3 — IRQL ANNOTATION MISMATCH
**File:** `hwsim.cpp`
**Function:** `CHardwareSimulation::Stop()`

`Stop()` is placed in the locked (non-paged) code segment after `#pragma code_seg()`,
yet it calls `KeWaitForSingleObject` which requires IRQL <= APC_LEVEL.
It is currently always reached via `CCaptureDevice::Stop()` which has `PAGED_CODE()`,
so it does not BSOD today. However the placement is wrong: if the call path ever
changes, or if the code analyser (Driver Verifier / SAL) checks it, it will flag or crash.

**Fix:** Move `Stop()` above the `#pragma code_seg()` boundary (into the
pageable segment, alongside `Pause()`) and add `PAGED_CODE()` at the top of
the function body.

---

## Fix Order for Coding Agent

1. `capture.cpp` — remove `KSALLOCATOR_REQUIREMENTF_PREFERENCES_ONLY` (Bug 1)
2. `hwsim.cpp` `SetData` — extend spinlock scope to cover the copy loop (Bug 2)
3. `hwsim.cpp` `FakeHardware` — extend spinlock scope to cover the `RtlCopyMemory` into `m_SynthesisBuffer` (Bug 2)
4. `hwsim.cpp` `Stop()` — move into pageable segment and add `PAGED_CODE()` (Bug 3)
