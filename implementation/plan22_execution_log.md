# Plan22 Execution Log (Step 2 onward)

Date: 2026-04-25

## Step 2 - Driver model and architecture
- Verified AVStream/WDM path remains active:
  - `KsInitializeDriver` in `device.cpp`
  - KS categories and interfaces in `avshws.inf`
- Pin-centric processing (`CCapturePin::Process`) unchanged and in place.

## Step 3 - Memory management modernization
- Replaced deprecated pool APIs:
  - `ExAllocatePoolWithTag` -> `ExAllocatePool2`
  - `ExFreePool` -> `ExFreePoolWithTag`
- Removed redundant `RtlZeroMemory` after pool allocations now using `ExAllocatePool2`.
- Updated lookaside list usage:
  - `ExInitializeNPagedLookasideList` -> `ExInitializeLookasideListEx`
  - `ExAllocateFromNPagedLookasideList` -> `ExAllocateFromLookasideListEx`
  - `ExFreeToNPagedLookasideList` -> `ExFreeToLookasideListEx`
  - `ExDeleteNPagedLookasideList` -> `ExDeleteLookasideListEx`

## Step 4 - IRQL and synchronization discipline
- Kept allocations in DISPATCH paths as non-paged (`POOL_FLAG_NON_PAGED`).
- Added safe fallback path if lookaside init is unavailable (non-paged pool alloc/free with tag).
- Preserved existing spinlock and DPC discipline.

## Step 5 - AVStream-specific implementation
- Verified INF has:
  - `KSCATEGORY_VIDEO`
  - `KSCATEGORY_CAPTURE`
  - `KSCATEGORY_VIDEO_CAMERA`
- Verified `Proxy.CLSID` registration remains present.
- Property handler buffer validation in `filter.cpp` remains intact.

## Step 6 - Driver signing and certification (dev path)
- Updated build pipeline to always generate fresh signed package artifacts:
  - Fresh `avshws.sys` from build output
  - Fresh `avshws.inf` copy
  - Fresh `avshws.cat` via `Inf2Cat`
  - Test cert generation/export (`VirtualCameraDriver-TestSign.cer`)
  - Catalog signing via `signtool`
- Updated `DriverVer` in INF to `04/25/2026,6.0.5600.1`.

## Step 7 - Debugging and validation
- Added/used installer flow that:
  - supports benign pnputil exit code `259`
  - supports force rebind by removing existing OEM package when requested
- Performed install validation:
  - `pnputil` camera device status changed from `Problem Code 39` to `Started`
  - final CIM check: `ConfigManagerErrorCode = 0`, `Status = OK`

## Step 8 - Coding rules and patterns
- Kept kernel C++ operator new/delete overloads but modernized internals.
- Kept AVStream object-lifetime model and existing cleanup callbacks.

## Step 9 - Static analysis and testing
- Completed build and binary import validation.
- Confirmed built package sys imports modern APIs (`ExAllocatePool2`, `ExFreePoolWithTag`, `ExInitializeLookasideListEx`).

## Step 10 - Documentation and reference
- Added this execution log with concrete implementation and validation outcomes.

## Step 11 - Common pitfall audits
- Deprecated pool APIs eliminated from driver source.
- Old package staging issue fixed (stale sys no longer copied to output package).
- Installer now handles rebind/reinstall path for stale driver-store package scenarios.

## Step 1 (toolchain setup) necessity check
- Not required to execute now: existing environment already has VS Build Tools + WDK and successfully builds/signs/installs.
