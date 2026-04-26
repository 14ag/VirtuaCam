# VirtuaCam Driver WDK Compliance Audit Workflow
**Target WDK Version:** 10.0.19041.1  
**Driver Type:** AVStream virtual camera (non-filter)  
**Repository:** https://github.com/14ag/VirtuaCam

---

## Phase 1: Core Driver Structure Compliance

### 1.1 Driver Entry and Initialization (Ch 2.4)
**Files:** `device.cpp`, `hwsim.cpp`

- [ ] Verify DriverEntry sets all required MajorFunction pointers
- [ ] Check DriverObject->DriverUnload properly registered
- [ ] Validate driver extension initialization
- [ ] Confirm proper use of NonPagedPoolNx (not NonPagedPool)

**Required Pages if missing:** 27-29, 42-43

### 1.2 AddDevice Routine (Ch 2.5)
**Files:** `device.cpp`

- [ ] Verify CCaptureDevice::DispatchCreate follows proper AddDevice pattern
- [ ] Check device object creation uses correct flags (DO_POWER_PAGABLE, DO_BUFFERED_IO)
- [ ] Validate device object attachment to stack
- [ ] Verify proper symbolic link creation for device interfaces
- [ ] Check device extension initialization

**Required Pages if missing:** 29-43

### 1.3 Device Object Management (Ch 2.3.2)
**Files:** `device.cpp`, `device.h`

- [ ] Validate device extension structure alignment
- [ ] Check proper use of KsAddItemToObjectBag for cleanup
- [ ] Verify device object flags set correctly
- [ ] Confirm device characteristics match AVStream requirements

**Required Pages if missing:** 25-27

---

## Phase 2: Memory Management and Synchronization

### 2.1 Memory Allocation (Ch 3.3.2)
**Files:** `device.cpp`, `capture.cpp`, `hwsim.cpp`, `image.cpp`

- [ ] Verify all ExAllocatePool2 calls use proper flags
- [ ] Check NonPagedPoolNx used instead of NonPagedPool (security requirement)
- [ ] Validate pool tags are 4 characters and unique
- [ ] Confirm all allocations have matching frees
- [ ] Check for proper sized delete operators

**Current Observation:** Custom new/delete operators use ExAllocatePool2 - verify all paths

**Required Pages if missing:** 60-64

### 2.2 Synchronization Primitives (Ch 4)
**Files:** All .cpp files

- [ ] Audit spin lock usage - verify KeAcquireSpinLock paired with KeReleaseSpinLock
- [ ] Check IRQL management - no blocking at DISPATCH_LEVEL
- [ ] Validate event/mutex usage follows dispatcher object rules
- [ ] Verify interlocked operations used for simple counters
- [ ] Check no unsafe operations in ISR/DPC context

**Specific Check:** Examine `s_driverFrameCount` usage with InterlockedIncrement

**Required Pages if missing:** 83-110

### 2.3 IRQL and Paging (Ch 4.2)
**Files:** All .cpp files

- [ ] Verify PAGED_CODE() macro in pageable functions
- [ ] Check non-paged code sections properly marked
- [ ] Validate no paged memory access at DISPATCH_LEVEL
- [ ] Confirm ISR/DPC code in non-paged pool

**Required Pages if missing:** 85-88

---

## Phase 3: IRP Processing and I/O Control

### 3.1 IRP Handling (Ch 5)
**Files:** `filter.cpp`, `device.cpp`, `capture.cpp`

- [ ] Verify proper IRP completion (IoCompleteRequest)
- [ ] Check IoStatus.Status and IoStatus.Information set correctly
- [ ] Validate IRP forwarding uses IoCallDriver (not direct call)
- [ ] Confirm completion routines return correct status
- [ ] Check proper IRP cancellation handling

**Required Pages if missing:** 111-162

### 3.2 Custom Property Handling (Ch 9)
**Files:** `filter.cpp`, `customprops.h`

- [ ] Verify IOCTL code definitions follow CTL_CODE macro pattern
- [ ] Check buffering methods (METHOD_BUFFERED, METHOD_NEITHER) correct
- [ ] Validate input/output buffer size checks
- [ ] Confirm UserBuffer and SystemBuffer accessed correctly
- [ ] Verify VIRTUACAM_PROP_* implementation secure

**Current IOCTLs:**
- VIRTUACAM_PROP_FRAME
- VIRTUACAM_PROP_CONNECT  
- VIRTUACAM_PROP_DISCONNECT

**Required Pages if missing:** 255-269

### 3.3 IRP Cancellation (Ch 5.5)
**Files:** Examine all pending IRP scenarios

- [ ] Check cancel-safe queue usage if IRPs pended
- [ ] Verify cancel routine registration if needed
- [ ] Validate synchronization between cancel and completion
- [ ] Confirm IRP_MJ_CLEANUP handling

**Required Pages if missing:** 140-153

---

## Phase 4: Plug and Play Compliance

### 4.1 PnP IRP Handling (Ch 6)
**Files:** `device.cpp`

- [ ] Verify IRP_MN_START_DEVICE implementation
- [ ] Check IRP_MN_STOP_DEVICE handling
- [ ] Validate IRP_MN_REMOVE_DEVICE cleanup
- [ ] Confirm IRP_MN_SURPRISE_REMOVAL support
- [ ] Verify state machine transitions correct

**Critical:** PnP IRPs must be passed down stack before/after processing

**Required Pages if missing:** 163-192

### 4.2 Resource Management (Ch 6.2, 7.1)
**Files:** `device.cpp::PnpStart`

- [ ] Verify TranslatedResourceList parsing
- [ ] Check hardware resource allocation
- [ ] Validate port/memory resource mapping
- [ ] Confirm proper resource release on STOP/REMOVE

**Note:** Virtual camera may have minimal resources

**Required Pages if missing:** 165-169, 193-195

### 4.3 Remove Lock Usage (Ch 6.3.6)
**Files:** Check if remove locks used

- [ ] Verify IoAllocateRemoveLock in AddDevice
- [ ] Check IoAcquireRemoveLock before I/O operations  
- [ ] Confirm IoReleaseRemoveLock pairs
- [ ] Validate IoReleaseRemoveLockAndWait in remove path

**Required Pages if missing:** 176-178

---

## Phase 5: Power Management

### 5.1 Power IRP Handling (Ch 8)
**Files:** Device power management code

- [ ] Verify IRP_MJ_POWER dispatch routine exists
- [ ] Check PoCallDriver used (not IoCallDriver)
- [ ] Validate system-to-device power mapping
- [ ] Confirm D0 entry/exit handling
- [ ] Check PoStartNextPowerIrp called correctly

**Required Pages if missing:** 227-254

### 5.2 Power Management Infrastructure (Ch 8.2.1)
**Files:** Power-related code

- [ ] Verify power state tracking
- [ ] Check device wake-up support if applicable
- [ ] Validate idle power-down logic
- [ ] Confirm DO_POWER_PAGABLE flag set correctly

**Required Pages if missing:** 232-244

---

## Phase 6: AVStream-Specific Compliance

### 6.1 Filter/Pin Architecture
**Files:** `filter.cpp`, `filter.h`, `capture.cpp`, `capture.h`

- [ ] Verify KSFILTER_DESCRIPTOR correct
- [ ] Check KSPIN_DESCRIPTOR_EX structures
- [ ] Validate KS property tables
- [ ] Confirm AVStream bag usage for cleanup

### 6.2 Hardware Simulation
**Files:** `hwsim.cpp`, `hwsim.h`

- [ ] Verify fake DMA implementation follows WDK patterns
- [ ] Check scatter/gather buffer handling
- [ ] Validate image synthesis thread management
- [ ] Confirm proper cleanup of hardware simulation

### 6.3 Capture Pin Implementation
**Files:** `capture.cpp`, `image.cpp`

- [ ] Verify stream state transitions
- [ ] Check buffer queue management
- [ ] Validate timestamp and frame metadata
- [ ] Confirm proper stream stop cleanup

---

## Phase 7: INF File Compliance (Ch 15)

### 7.1 INF Structure (Ch 15.2)
**File:** `avshws.inf`

- [ ] Verify [Version] section has all required directives
- [ ] Check Class and ClassGuid match Camera class
- [ ] Validate DriverVer format and date
- [ ] Confirm CatalogFile specified

**Current Issues Found:**
- ✓ Uses Camera class (correct for virtual camera)
- ✓ Multi-architecture support (x86, amd64, arm, arm64)

### 7.2 Installation Sections (Ch 15.2.1)
**File:** `avshws.inf`

- [ ] Verify platform decorations (.NTx86, .NTamd64, etc.)
- [ ] Check CopyFiles sections correct
- [ ] Validate service installation flags
- [ ] Confirm Needs/Include directives for KS components

**Required Pages if missing:** 386-388

### 7.3 AddReg and Registry Population (Ch 15.2.2)
**File:** `avshws.inf`

- [ ] Verify interface registration
- [ ] Check CLSID proxy registration
- [ ] Validate FriendlyName setting
- [ ] Confirm proper HKR usage

**Required Pages if missing:** 388-391

### 7.4 Device Interfaces (Ch 15.2)
**File:** `avshws.inf`

- [ ] Verify KSCATEGORY_CAPTURE interface
- [ ] Check KSCATEGORY_VIDEO interface
- [ ] Validate KSCATEGORY_VIDEO_CAMERA interface
- [ ] Confirm GUID values correct

### 7.5 Service Installation (Ch 15.2)
**File:** `avshws.inf`

- [ ] Verify ServiceType = SERVICE_KERNEL_DRIVER (1)
- [ ] Check StartType = SERVICE_DEMAND_START (3)
- [ ] Validate ErrorControl = SERVICE_ERROR_NORMAL (1)
- [ ] Confirm AddService flag 0x00000002 (SPSVCINST_ASSOCSERVICE)

---

## Phase 8: Thread and Work Item Usage (Ch 14)

### 8.1 System Thread Usage (Ch 14.2)
**Files:** `hwsim.cpp`, search for PsCreateSystemThread

- [ ] Verify thread creation uses proper parameters
- [ ] Check thread priority set correctly
- [ ] Validate thread termination synchronization
- [ ] Confirm KeWaitForSingleObject used to wait for thread
- [ ] Check ObDereferenceObject called on thread handle

**Required Pages if missing:** 367-375

### 8.2 Work Items (Ch 14.3)
**Files:** Search for IoAllocateWorkItem, IoQueueWorkItem

- [ ] Verify work item allocation correct
- [ ] Check work item routine runs at PASSIVE_LEVEL
- [ ] Validate work item cleanup
- [ ] Confirm no blocking in work item callback

**Required Pages if missing:** 371-375

---

## Phase 9: Security and Robustness

### 9.1 Buffer Validation (Ch 9.3.3)
**Files:** `filter.cpp` property handlers

- [ ] Verify all buffer lengths validated before access
- [ ] Check for integer overflow in size calculations
- [ ] Validate ProbeForRead/ProbeForWrite if user buffers
- [ ] Confirm no trust of user-supplied pointers

**Current Observation:** SetData checks bufferLength but needs overflow validation

**Required Pages if missing:** 262

### 9.2 Error Handling (Ch 3.2)
**Files:** All .cpp files

- [ ] Verify NTSTATUS return codes used correctly
- [ ] Check NT_SUCCESS macro usage
- [ ] Validate cleanup on failure paths
- [ ] Confirm no resource leaks on errors

**Required Pages if missing:** 46-55

### 9.3 Safe String Handling (Ch 3.4)
**Files:** Any string operations

- [ ] Verify RtlInitUnicodeString usage
- [ ] Check RtlUnicodeStringCopy for safe copying
- [ ] Validate buffer size checks
- [ ] Confirm no unsafe strcpy/sprintf

**Required Pages if missing:** 69-71

---

## Phase 10: Code Quality and WDK 19041 Compliance

### 10.1 SAL Annotations
**Files:** All .cpp/.h files

- [ ] Verify _In_, _Out_, _Inout_ parameters annotated
- [ ] Check _Ret_maybenull_ on allocations
- [ ] Validate _When_ annotations on conditional code
- [ ] Confirm _IRQL_requires_ annotations where appropriate

### 10.2 Static Analysis Compliance
**Files:** All source files

- [ ] Run Driver Verifier enabled
- [ ] Check Code Analysis warnings (C28xxx)
- [ ] Validate no use of deprecated APIs
- [ ] Confirm compliance with banned APIs list

### 10.3 Pool Allocation Security (WDK 19041 Requirement)
**Files:** All memory allocation sites

- [ ] Verify ExAllocatePool2 used (not ExAllocatePoolWithTag)
- [ ] Check POOL_FLAG_NON_PAGED instead of NonPagedPool
- [ ] Validate POOL_FLAG_NON_PAGED_EXECUTE for executable pool
- [ ] Confirm no use of NonPagedPoolExecute type

**Current Status:** device.cpp implements pool conversion - verify all call sites

---

## Critical Issues Checklist

### Immediate Security Concerns
- [ ] Integer overflow in SetData: `bufferLength - sizeof(KSPROPERTY)` 
- [ ] Validate all user-supplied sizes before arithmetic
- [ ] Check all buffer accesses bounds-checked
- [ ] Verify no use of unsafe string functions

### Stability Concerns  
- [ ] Verify proper cleanup in all error paths
- [ ] Check all allocations have paired frees
- [ ] Validate thread termination synchronization
- [ ] Confirm no deadlocks in lock hierarchies

### WDK Version Compliance
- [ ] Confirm no deprecated API usage for 19041
- [ ] Check all pool allocations use ExAllocatePool2
- [ ] Validate NonPagedPoolNx used throughout
- [ ] Verify POOL_FLAGS used correctly

---

## Documentation Requirements

If information missing from available PDFs, request pages in format:
- **Chapter X pages needed:** [page ranges]

Example request:
```
5-111 to 5-120, 5-140 to 5-153, 6-163 to 6-178
```

---

## Testing Requirements

Post-audit validation:
1. Driver Verifier enabled testing
2. Static Driver Verifier (SDV) analysis
3. Code Analysis (/analyze) full run
4. PnP stress testing (surprise removal)
5. Power state transition testing
6. Memory leak detection
7. WHQL/HLK test suite for camera drivers

---

## Deliverables

1. **Issue Report:** Categorized findings (Critical/High/Medium/Low)
2. **Fix Implementation Plan:** Priority-ordered task list
3. **Compliance Matrix:** Per-requirement pass/fail status
4. **Code Recommendations:** Specific code changes needed
