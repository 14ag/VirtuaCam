# WDK Driver Development Reference Report
## For VirtuaCam Coding Agent

---

## 1 TOOLCHAIN AND ENVIRONMENT

### 1a Current WDK Versions

The active production WDK as of April 2026 is **10.0.26100.6584**, released September 23 2025,
targeting Windows 11 version 25H2. It supports KMDF 1.33 and requires Visual Studio 2022. A
preview WDK with Visual Studio 2026 support exists for Insiders only and must not be used in
production.

| WDK Version | Target OS | Status |
|---|---|---|
| 10.0.26100.6584 | Win 11 25H2 | Current production |
| 10.0.26100.1 (26H1) | Specific silicon only | Restricted use |
| 10.0.22621 and earlier | Win 10 x86/ARM32 | Legacy only |

The WDK is now distributed as a **NuGet package** in addition to the traditional MSI installer,
enabling CI/CD pipelines to consume headers, libraries, DLLs, tools, and metadata directly via
nuget.org inside Visual Studio. The EWDK (Enterprise WDK) is a standalone ISO containing Visual
Studio 2022 Build Tools 17.11.4 with MSVC toolset v14.41 for environments that cannot run a full
Visual Studio install.

**Installation order is mandatory:**
1. Visual Studio 2022 with the C++ workload
2. Windows SDK (must match WDK build number exactly)
3. WDK MSI or NuGet package
4. WDK VSIX (now a Visual Studio individual component since VS 17.11)

### 1b Driver Models

Three production driver models exist. Choose in this priority order:

**UMDF 2 (User-Mode Driver Framework)**
Run in user space, preventing a faulty driver from crashing the kernel. Use UMDF 2 when the
device does not require kernel-only resources such as DMA, direct hardware interrupts, or
non-paged pool memory that must be accessed at DISPATCH_LEVEL. UMDF 2 version 2.33 ships
with Windows 11 21H2 and later. Communication with kernel is routed through a reflector
component via RPC through a driver host process managed by the UMDF driver manager.

**KMDF (Kernel-Mode Driver Framework)**
The preferred kernel-mode model for all standard devices. KMDF wraps most PnP, power
management, and IRP boilerplate in an event-driven object model, exposing drivers, devices,
queues, and hardware resource objects with well-defined callbacks. KMDF 1.33 ships with the
current WDK. OSR explicitly recommends KMDF over WDM for all new drivers.

**WDM (Windows Driver Model)**
Required only for: miniport drivers, minifilter file system drivers, AVStream minidrivers,
and any driver requiring custom IRP handling that KMDF does not expose. VirtuaCam uses WDM
through AVStream (KS), which is the correct and required model for video capture. No migration
to KMDF is applicable here.

**AVStream (KS / ks.sys)**
AVStream is the Microsoft-provided multimedia class driver in ks.sys. Vendors write a minidriver
that registers with and runs under ks.sys. AVStream supersedes the legacy stream.sys (Stream
class), which Microsoft has discontinued. All new video capture drivers must use AVStream. The
three multimedia class drivers are: portcls.sys (audio), stream.sys (legacy video, deprecated),
and ks.sys (AVStream, current). The USB Video Class (UVC) driver is a fourth option for USB
cameras and handles compliance internally.

---

## 2 MEMORY MANAGEMENT

### 2a The Deprecated Pool API Family

`ExAllocatePoolWithTag`, `ExAllocatePool`, `ExAllocatePoolWithQuotaTag`, and `ExFreePool`
were **formally deprecated in Windows 10 version 2004 (build 19041)** and removed from
ntoskrnl.exe exports in **Windows 11 24H2 (build 26100)**. Any driver binary that imports
these symbols will fail to load on 24H2 with `STATUS_DRIVER_ENTRYPOINT_NOT_FOUND` (Code 39).
This is the root cause of the VirtuaCam driver failure.

### 2b Replacement APIs

**ExAllocatePool2** (introduced Windows 10 2004, required on 24H2+)

```c
PVOID ExAllocatePool2(
    POOL_FLAGS Flags,       // ULONG64 flags not POOL_TYPE
    SIZE_T     NumberOfBytes,
    ULONG      Tag          // must be non-zero
);
```

Key behavioral differences from ExAllocatePoolWithTag:
- Memory is **zero-initialized by default** - remove all RtlZeroMemory calls that follow allocation
- Returns NULL on failure by default (raises exception only if POOL_FLAG_RAISE_ON_FAILURE set)
- Tag value of 0 is invalid and will be rejected
- Takes POOL_FLAGS (ULONG64) not POOL_TYPE

POOL_FLAGS mapping from legacy POOL_TYPE values:

| Old POOL_TYPE | New POOL_FLAGS |
|---|---|
| NonPagedPoolNx | POOL_FLAG_NON_PAGED |
| NonPagedPool (deprecated) | POOL_FLAG_NON_PAGED |
| PagedPool | POOL_FLAG_PAGED |
| NonPagedPoolExecute | POOL_FLAG_NON_PAGED_EXECUTABLE |

**ExAllocatePool3** also exists for advanced scenarios (custom extended parameters).

**ExFreePoolWithTag** replaces ExFreePool. The tag parameter must match the tag used at
allocation. Passing 0 as the tag is accepted as a wildcard and is the safest migration path
when the original tag is not tracked through the free path.

```c
void ExFreePoolWithTag(PVOID P, ULONG Tag);
```

### 2c IRQL Constraints on Pool Operations

These rules are hard; violating them causes an immediate BSOD:

- `ExAllocatePool2` with `POOL_FLAG_NON_PAGED`: callable at IRQL <= DISPATCH_LEVEL
- `ExAllocatePool2` with `POOL_FLAG_PAGED`: callable at IRQL <= APC_LEVEL only
- `ExFreePoolWithTag`: callable at IRQL <= DISPATCH_LEVEL

Code that runs in an ISR or DPC (which execute at DISPATCH_LEVEL) must use non-paged pool.
Code in PAGED_CODE sections is callable only at PASSIVE_LEVEL and APC_LEVEL.

### 2d Lookaside Lists

For frequent fixed-size allocations (such as per-frame buffers in a streaming driver),
lookaside lists eliminate per-call pool overhead:

```c
// ExInitializeLookasideListEx replaces ExInitializeNPagedLookasideList
ExInitializeLookasideListEx(
    &list, NULL, NULL,
    NonPagedPoolNx, 0,
    sizeof(MY_STRUCT), 'gaTL', 0
);

PVOID p = ExAllocateFromLookasideListEx(&list);
ExFreeToLookasideListEx(&list, p);
ExDeleteLookasideListEx(&list);
```

---

## 3 IRQL AND SYNCHRONIZATION

### 3a IRQL Levels

Windows kernels prioritize code execution via Interrupt Request Levels (IRQLs). Each CPU
has a current IRQL. Code at a lower IRQL cannot preempt code at a higher IRQL.

| IRQL | Name | Where used |
|---|---|---|
| 0 | PASSIVE_LEVEL | User mode, most driver routines |
| 1 | APC_LEVEL | APC delivery, pageable driver code |
| 2 | DISPATCH_LEVEL | Scheduler, DPCs, spinlock holders |
| 3-26 | DIRQL | Hardware interrupt service routines |
| 27 | PROFILE_LEVEL | Profile timer |
| 28 | CLOCK2_LEVEL | Clock interrupt |
| 31 | HIGH_LEVEL | Machine check, NMI |

**PAGED_CODE()** macro asserts that the current IRQL is <= APC_LEVEL at runtime. Place it at
the top of every function in a PAGE segment. Missing PAGED_CODE on a pageable routine that
gets called at elevated IRQL is a common source of random BSODs in production.

### 3b Spinlocks

Spinlocks are the only synchronization primitive safe at DISPATCH_LEVEL and above.
Acquiring a spinlock raises the CPU IRQL to DISPATCH_LEVEL. Holding a spinlock while
calling any function that lowers IRQL is a bug.

```c
KSPIN_LOCK lock;
KIRQL oldIrql;
KeInitializeSpinLock(&lock);

KeAcquireSpinLock(&lock, &oldIrql);
// critical section - no pageable memory access
KeReleaseSpinLock(&lock, oldIrql);
```

Use `KeAcquireSpinLockAtDpcLevel` / `KeReleaseSpinLockFromDpcLevel` when already at
DISPATCH_LEVEL to avoid redundant IRQL transitions.

### 3c DPCs (Deferred Procedure Calls)

DPCs run at DISPATCH_LEVEL and are the correct place to complete interrupt-driven work
without holding the CPU at high IRQL. In AVStream/WDM drivers, fake ISR work (as in
VirtuaCam's hwsim.cpp) is a DPC-equivalent pattern: the hardware simulation calls
`Interrupt()` which runs at dispatch level and dispatches scatter-gather completion.

---

## 4 AVStream ARCHITECTURE

### 4a Filter and Pin Model

AVStream uses a filter-pin-topology model:

- **KSDEVICE**: the device object wrapper. Created by KsInitializeDriver
- **KSFILTER**: a processing unit with an associated KSFILTER_DESCRIPTOR and KSFILTER_DISPATCH
- **KSPIN**: a data connection point on a filter with a KSPIN_DESCRIPTOR_EX and KSPIN_DISPATCH
- **KSPROPERTY**: typed property sets exposed through an automation table (KSAUTOMATION_TABLE)

A minidriver registers via:
```c
KsInitializeDriver(DriverObject, RegistryPath, &CaptureDeviceDescriptor);
```

The device descriptor points to a KSDEVICE_DISPATCH containing PnP callbacks and a filter
descriptor table (DEFINE_KSFILTER_DESCRIPTOR_TABLE). KsCreateFilterFactory is called at
PnP start to instantiate the capture filter factory.

### 4b Pin-Centric vs Filter-Centric Processing

AVStream supports two processing modes:
- **Pin-centric**: each pin has its own process callback. Used in VirtuaCam (CCapturePin::Process)
- **Filter-centric**: the filter has a single process callback that sees all pins. Used for
  filters that need to coordinate multiple streams simultaneously

Pin-centric is correct for a single-output capture filter.

### 4c Scatter-Gather and Stream Pointers

The capture path uses scatter-gather DMA simulation:
1. `KsPinGetLeadingEdgeStreamPointer` locks the leading edge frame
2. `KsStreamPointerClone` creates a reference-counted clone for each in-flight frame
3. `ProgramScatterGatherMappings` hands virtual addresses to the hardware simulation
4. The fake ISR calls `CompleteMappings` via the ICaptureSink interface
5. `KsStreamPointerDelete` releases the clone when all mappings complete

The `KSSTREAM_HEADER` extended with `KS_FRAME_INFO` carries presentation timestamps,
frame number, and drop count per output buffer.

### 4d KS Property Sets

Custom properties are defined with `DEFINE_KSPROPERTY_TABLE` and aggregated into a
`DEFINE_KSPROPERTY_SET_TABLE` which is attached to the filter's automation table via
`DEFINE_KSAUTOMATION_TABLE`. VirtuaCam exposes three custom properties on
PROPSETID_VIDCAP_CUSTOMCONTROL:

- `VIRTUACAM_PROP_FRAME` (get/set): frame buffer data transfer from userland
- `VIRTUACAM_PROP_CONNECT` (set): signal client connection
- `VIRTUACAM_PROP_DISCONNECT` (set): signal client disconnection

Property handlers receive the IRP directly. The filter context is retrieved via
`KsGetFilterFromIrp(Irp)->Context` and the device via `KsFilterGetDevice`.

### 4e INF and Device Registration

AVStream capture filters register under three KSCATEGORY GUIDs:
- `KSCATEGORY_VIDEO` - enumerable as a video device
- `KSCATEGORY_CAPTURE` - enumerable as a capture device
- `KSCATEGORY_VIDEO_CAMERA` - enumerable as a camera (required for Windows Camera app)

The INF `[Interfaces]` section uses `AddInterface` for each category with `"GLOBAL"` as the
reference string, matching the string passed to `KsCreateFilterFactory`.

The `Proxy.CLSID` value `{17CCA71B-ECD7-11D0-B908-00A0C9223196}` registers the KS proxy,
enabling DirectShow and Media Foundation to enumerate the device.

---

## 5 DRIVER SIGNING AND CERTIFICATION

### 5a Current Signing Landscape (2025-2026)

This is the highest-impact area for VirtuaCam deployment:

**Test Signing (development only)**
Enable with `bcdedit /set testsigning on`. Allows loading drivers signed with any certificate.
Must never be used in production. Self-signed test certificates are created automatically by
the WDK build system.

**Attestation Signing (production, no HLK required)**
Submit the driver package to the Windows Hardware Developer Center (Partner Center). Microsoft
signs the driver with a production certificate after automated checks. Sufficient for drivers
that do not require WHQL logo certification. Fastest path to production signing.

**WHQL / WHCP Certification (full hardware compatibility program)**
Requires running the Hardware Lab Kit (HLK) test suite against the driver on target hardware.
The refreshed HLK for Windows 11 24H2 and Server 2025 was released in May 2025. WHQL-signed
drivers can be distributed via Windows Update. Process typically takes 4-8 weeks.

**Critical April 2026 Change**
Starting with the April 2026 Windows security update, Windows 11 24H2 / 25H2 / 26H1 and
Server 2025 **block legacy cross-signed kernel drivers by default**. The kernel enters an
evaluation mode first (requiring 100+ hours of runtime and multiple restarts before enforcement)
but the ultimate result is that only WHCP-signed drivers or explicit Microsoft allowlist entries
will load. Any driver signed with the old cross-signing program (pre-2021 program) is affected.
New driver submissions must use attestation or WHQL signing.

Device metadata and WMIS (Windows Metadata and Internet Services) have been deprecated. Hardware
vendors should migrate device information to Universal Windows Driver mechanisms.

### 5b Code Integrity Requirements

Windows 11 enforces Code Integrity (CI) for all kernel-mode code. Implications:
- 64-bit Windows does not load unsigned drivers under any circumstances unless test signing is on
- Secure Boot and HVCI (Hypervisor Protected Code Integrity) add a second enforcement layer
- HVCI-compatible drivers must not use executable non-paged pool (avoid POOL_FLAG_NON_PAGED_EXECUTABLE)
- Static Driver Verifier (SDV) and CodeQL analysis are required for DVL (Driver Verification Log)
  generation, which is a prerequisite for WHQL submission

---

## 6 DEBUGGING TOOLS

### 6a WinDbg

WinDbg is the primary kernel-mode debugger. Key commands for driver debugging:

```
!analyze -v          // automatic crash analysis
lm m avshws          // list module info
!pool <addr>         // inspect pool allocation at address
!poolused 4          // show pool usage by tag
!irp <addr>          // decode an IRP
!ks.graph <addr>     // dump AVStream filter graph (requires ks.dll extension)
!ks.allStreams        // enumerate all KS stream pointers
dt nt!_KSDEVICE      // dump KSDEVICE structure
```

Kernel debugging requires a debug transport: network (KDNET, fastest), USB 3.0, serial, or
FireWire. KDNET setup: `bcdedit /dbgsettings net hostip:<IP> port:<port>`.

### 6b Driver Verifier

Driver Verifier (`verifier.exe`) instruments a driver at load time to catch:
- Pool corruption (Special Pool option)
- IRQL violations
- Deadlock detection
- Force IRQL checks
- I/O verification (tracks IRP completion correctness)
- For AVStream drivers: also enable verification on ks.sys itself, not just the minidriver

Enable: `verifier /standard /driver avshws.sys`
OSR strongly recommends enabling Driver Verifier during all development and testing.

### 6c AVStream-Specific Tools

The WDK ships AVStream debugging tools in `%WDKInstallPath%\tools\avstream\`:

- **KsStudio.exe**: enumerates KS filters and pins, displays the filter graph, lets you
  query and set properties directly. Requires KsMon.sys in the same directory and elevated
  privileges. Indispensable for validating property set registration.

- **GraphEdt.exe**: DirectShow filter graph editor. Build a capture graph to your filter and
  verify it appears, connects, and streams correctly. Supersedes the removed AMCap2.exe.

- **USBView.exe**: USB device tree inspector, useful for USB-attached camera debugging.

### 6d Kernel Address Sanitizer (KASAN)

Available since WDK 10.0.26100 (November 2024). KASAN detects illegal memory access patterns
including out-of-bounds reads and writes. Enable in project properties as a build option.
Requires a supported OS build. Provides more granular detection than Special Pool for heap-like
corruption patterns.

---

## 7 ESSENTIAL REFERENCE BOOKS

### 7a Windows Kernel Programming (Yosifovich) - PRIMARY REFERENCE

**Title:** Windows Kernel Programming, Second Edition
**Author:** Pavel Yosifovich
**Published:** 2022/2023 (Leanpub, continuously updated)
**ISBN (print):** 9798379069513
**GitHub samples:** github.com/zodiacon/windowskernelprogrammingbook2e

This is the most current practical guide to WDK kernel driver development. Covers:
- WDM driver structure: DriverEntry, dispatch routines, unload
- Pool allocation (uses ExAllocatePool2 / modern APIs)
- IRQL, spinlocks, DPCs
- Filter drivers and callbacks
- Windows Filtering Platform
- Test signing and deployment
- WinDbg debugging workflow

Written against Visual Studio 2019/2022 and the Windows 11 WDK. All code compiles with the
current toolchain. This is the book to consult for WDM-level patterns that AVStream builds on.

### 7b Windows Internals (Russinovich et al) - ARCHITECTURE REFERENCE

**Title:** Windows Internals, Part 1 (7th Edition)
**Authors:** Pavel Yosifovich, Alex Ionescu, Mark Russinovich, David Solomon
**Publisher:** Microsoft Press
**ISBN Part 1:** 9780735684188

**Title:** Windows Internals, Part 2 (7th Edition)
**Authors:** Andrea Allievi, Mark Russinovich, Alex Ionescu, David Solomon
**Publisher:** Microsoft Press / Pearson Education (2022)
**ISBN Part 2:** 9780135462409

The definitive reference for Windows OS architecture. Topics directly relevant to driver
development:
- Part 1 Ch 1-3: Processes, virtual memory, system mechanisms (must read before writing any driver)
- Part 1 Ch 6: I/O system (IRP flow, device stacks, completion routines)
- Part 1 Ch 7: Memory manager (pool internals, page fault handling)
- Part 2: Boot process, storage internals, networking stack

OSR explicitly lists Chapters 1, 3, 6, and 7 of Part 1 as required reading before attempting
driver development. The book does not cover driver development directly but provides the
architectural understanding without which driver code becomes guesswork.

### 7c Programming the Windows Driver Model (Oney) - HISTORICAL WDM REFERENCE

**Title:** Programming the Microsoft Windows Driver Model (2nd Edition)
**Author:** Walter Oney
**Publisher:** Microsoft Press
**ISBN:** 9780735605886

The canonical WDM programming reference from the DDK era. Highly detailed on IRP handling,
power management, PnP, and hardware interaction. Now outdated with respect to API names
(uses the deprecated pool APIs throughout) and does not cover KMDF or modern signing. Useful
for understanding WDM concepts that underlie AVStream, but all code samples require API
modernization before use.

### 7d Developing Drivers with the Windows Driver Foundation (Orwick and Smith)

**Title:** Developing Drivers with the Windows Driver Foundation
**Authors:** Penny Orwick, Guy Smith
**Publisher:** Microsoft Press

The foundational book for KMDF and UMDF. Covers:
- WDF object model and lifetime management
- Queue framework and request processing
- Power management with WDF
- PnP callbacks and hardware resource management

Not directly applicable to AVStream (which does not use KMDF), but essential context for
understanding why KMDF exists and what WDM patterns it replaces.

### 7e Windows System Programming (Hart)

**Title:** Windows System Programming, 4th Edition
**Author:** Johnson M. Hart
**Publisher:** Addison-Wesley

OSR recommends this for developers coming from Unix or without Win32 experience. Covers
the Win32 API layer that drivers often interact with indirectly through IOCTLs and shared
memory patterns. Good background on handles, synchronization primitives, and file I/O
at the application layer.

---

## 8 ONLINE RESOURCES

### 8a Microsoft Learn (learn.microsoft.com/windows-hardware/drivers)

The authoritative and actively maintained documentation. Key sections:

- **DDI Reference** (learn.microsoft.com/windows-hardware/drivers/ddi/): every kernel API,
  struct, and macro with IRQL requirements, deprecation notices, and replacement guidance
- **WDK Release Notes**: changelog per WDK version, new APIs, deprecations
- **What's New in Driver Development**: per-OS-version feature additions
- **Updating deprecated ExAllocatePool calls**: step-by-step migration guide for the
  ExAllocatePoolWithTag -> ExAllocatePool2 transition
- **AVStream Overview**: filter-pin model, minidriver architecture, property sets
- **Kernel Streaming**: KS property/event/method sets, KS clocks, KS allocators
- **Video Capture Devices**: stream format negotiation, VIDEOINFOHEADER, format intersection

### 8b Microsoft Windows Driver Samples (github.com/microsoft/Windows-driver-samples)

The official sample repository, compiled against the current WDK. Relevant samples:

- `avstream/avshws/`: the base AVStream simulated hardware sample that VirtuaCam derives from
- `avstream/sampledevicemft/`: Device MFT (Media Foundation Transform) for camera post-processing
- `avstream/avscamera/`: AVStream camera driver with modern Media Foundation integration
- `avstream/filter/`: simple AVStream filter example

**Critical note from Microsoft:** Review "From Sample Code to Production Driver - What to Change
in the Samples" before releasing any driver based on sample code. Samples intentionally omit
production hardening.

### 8c OSR Online (osr.com and community.osr.com)

OSR (Open Systems Resources) is the leading independent authority on Windows driver development.
Resources:

- **NT Insider**: free journal covering driver development techniques, debugging, and architecture.
  Subscribe at osr.com. Articles are technically precise and current.
- **OSR Developer Community**: Q and A forum with expert responses. Search before posting -
  most common driver questions are already answered.
- **OSR Seminars**: instructor-led training on WDF, Internals/Software Drivers, Kernel Debugging,
  and File System Minifilters. Recommended by OSR themselves as the fastest path to competency.
- **Best Practices for Windows Driver Developers**: osr.com/nt-insider/2017-issue1/best-practices-
  for-windows-driver-developers/ - Essential reading. Key rules directly applicable to VirtuaCam:
  - Use the C++ compiler even for C code (strong type checking)
  - Enable Driver Verifier on both the driver and the framework/class driver (ks.sys)
  - Use role-type annotations (DRIVER_INITIALIZE, EVT_WDF_* etc)
  - Use the most modern driver model applicable to the project
  - Test on checked build OS images if available

### 8d Windows Driver Documentation GitHub (github.com/MicrosoftDocs/windows-driver-docs)

The source repository for all Microsoft driver documentation. Useful for:
- Checking documentation for recently changed APIs before the public page updates
- Filing issues on incorrect or unclear documentation
- Reading staging branch for unreleased documentation on upcoming WDK features

---

## 9 CODING RULES AND PATTERNS FOR AVSTREAM DRIVERS

### 9a Memory Allocation Pattern (current correct form)

```cpp
// operator new for kernel C++ objects - correct modern form
PVOID operator new(size_t iSize, POOL_TYPE /*poolType*/, ULONG tag)
{
    // ExAllocatePool2 zeroes automatically - NO RtlZeroMemory needed
    return ExAllocatePool2(POOL_FLAG_NON_PAGED, iSize, tag);
}

// operator delete - correct modern form
void __cdecl operator delete(PVOID pVoid, size_t /*size*/)
{
    if (pVoid) ExFreePoolWithTag(pVoid, 0);
}

// Use site remains unchanged - tag passed as second arg to placement new
CCaptureDevice *dev = new(NonPagedPoolNx, 'veDC') CCaptureDevice(Device);
```

### 9b PAGED_CODE Placement Rule

Every function in a PAGE code segment must start with PAGED_CODE():
```cpp
#ifdef ALLOC_PRAGMA
#pragma code_seg("PAGE")
#endif

NTSTATUS CCaptureDevice::PnpStart(...)
{
    PAGED_CODE();  // must be first executable statement
    // ...
}
```

Functions called at DISPATCH_LEVEL or from an ISR must be in locked (non-paged) segments and
must NOT contain PAGED_CODE. In VirtuaCam, Interrupt() and CompleteMappings() are in the
locked segment after `#pragma code_seg()` with no argument.

### 9c NULL Check After Every Allocation

`ExAllocatePool2` returns NULL on failure (unless POOL_FLAG_RAISE_ON_FAILURE is set). Every
allocation must be checked:
```cpp
m_ImageSynth = new(NonPagedPoolNx, 'YysI') CYUVSynthesizer;
if (!m_ImageSynth) {
    Status = STATUS_INSUFFICIENT_RESOURCES;
    // cleanup and return
}
```

### 9d KS Object Bagging

Use `KsAddItemToObjectBag` to register allocated objects with the device, filter, or pin bag.
When the parent object is destroyed, AVStream calls the registered cleanup callback for all
bagged items. This eliminates manual cleanup in most teardown paths:
```cpp
Status = KsAddItemToObjectBag(
    Device->Bag,
    reinterpret_cast<PVOID>(CapDevice),
    reinterpret_cast<PFNKSFREE>(CCaptureDevice::Cleanup)
);
```

### 9e Pool Tag Conventions

Each allocation site should use a unique, distinct 4-character tag. Tags are stored in reverse
byte order in memory by convention, so `'CRTV'` appears as VTRC in pool dumps. Use WinDbg's
`!poolused` or `!pool` to track allocations by tag during debugging. Tags containing 0 as
any byte are invalid with `ExAllocatePool2`.

### 9f C++ in Kernel Mode Rules

The WDK supports a limited subset of C++:
- Classes, inheritance, virtual functions: supported
- Exceptions (`throw`/`catch`): NOT supported - must be disabled (/EHs- /EHa-)
- Standard Template Library (STL): NOT available - no `std::vector`, no `std::string`
- RTTI (`dynamic_cast`, `typeid`): NOT available unless explicitly enabled (avoid it)
- Global constructors: supported but risky - prefer initialization in DriverEntry
- `_purecall` must be defined manually (VirtuaCam correctly provides purecall.c)
- `new`/`delete` must be overloaded for kernel pool (VirtuaCam does this in device.cpp)

### 9g Role-Type Annotations

Use SAL (Source Annotation Language) annotations on dispatch function signatures:

```cpp
extern "C" DRIVER_INITIALIZE DriverEntry;  // before definition
extern "C" NTSTATUS DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{ ... }
```

SAL annotations enable Static Driver Verifier to catch incorrect usage. The WDK headers
define macros like `DRIVER_INITIALIZE`, `DRIVER_UNLOAD`, `IO_COMPLETION_ROUTINE` that
encode the correct calling convention and SAL signature.

---

## 10 STATIC ANALYSIS AND TESTING

### 10a Static Driver Verifier (SDV)

SDV performs inter-procedural static analysis using model checking. It verifies:
- IRQL rules (no paged memory at DISPATCH_LEVEL)
- Spinlock discipline (no recursive acquisition, no acquiring with IRQL already raised)
- IRP completion rules (every IRP must be completed exactly once)
- Memory allocation checking (NULL dereference after failed allocation)

SDV is required to generate a Driver Verification Log (DVL) for WHQL submission.

### 10b CodeQL Analysis

Required for WHQL submission as of recent HLK versions. CodeQL queries detect:
- Buffer overflows
- Use-after-free patterns
- Integer overflow in size calculations
- Unsafe pointer arithmetic

Integrate in CI/CD with the WDK NuGet package and the CodeQL CLI.

### 10c KASAN (Kernel Address Sanitizer)

Available since WDK 10.0.26100. Detects out-of-bounds memory access at runtime.
Enable per-project in Visual Studio driver properties. More granular than Driver Verifier
Special Pool for catching overruns in small allocations.

---

## 11 COMMON PITFALLS IN AVSTREAM DRIVERS

### 11a Not Checking IOCTL Buffer Lengths in Property Handlers

SetData in filter.cpp correctly checks `bufferLength <= sizeof(KSPROPERTY)` before accessing
data beyond the property header. Omitting this check causes buffer overread when a malformed
IOCTL is sent, which Driver Verifier will catch under I/O Verification.

### 11b Using ExAllocatePoolWithTag on Windows 11 24H2

Confirmed root cause of VirtuaCam Code 39. Replace with ExAllocatePool2 throughout.
Remove all RtlZeroMemory calls that immediately follow ExAllocatePool2 allocations (redundant,
memory is already zeroed).

### 11c Calling Pageable Code from Locked Code

Any function called from the DPC / interrupt simulation path must be in a locked segment.
CompleteMappings, Interrupt, and ReadNumberOfMappingsCompleted all run at dispatch level in
VirtuaCam. None of these must call functions with PAGED_CODE or touch pageable memory.

### 11d KsEdit Failure Handling

`KsEdit` can fail if the system is low on pool. VirtuaCam's `CCapturePin::DispatchCreate`
correctly checks NT_SUCCESS on both KsEdit calls. Failing to check and proceeding causes
writes to read-only descriptor memory, producing hard-to-diagnose corruption.

### 11e DataUsed vs Remaining in Stream Pointer Advancement

In CompleteMappings, checking `Clone->StreamHeader->DataUsed >= Clone->OffsetOut.Remaining`
before deleting the clone is critical. Deleting a clone before all its mappings have been
marked complete leaves orphaned frames in the queue that are never released, causing hangs
when the graph is stopped.

### 11f Descriptor Constness and KsEdit

`KSFILTER_DESCRIPTOR`, `KSPIN_DESCRIPTOR_EX`, and `KSALLOCATOR_FRAMING_EX` are declared
`const`. To modify them at runtime (e.g. to update framing based on connected format),
use `KsEdit` to get a writable copy in pool, then cast away constness only after
`KsEdit` succeeds.

---

## 12 QUICK REFERENCE: API DEPRECATION TABLE

| Deprecated (pre-2004) | Replacement | Notes |
|---|---|---|
| ExAllocatePoolWithTag | ExAllocatePool2 | Zeroes memory automatically |
| ExAllocatePool | ExAllocatePool2 | Use POOL_FLAG_UNINITIALIZED to skip zeroing |
| ExAllocatePoolWithQuotaTag | ExAllocatePool2 with POOL_FLAG_USE_QUOTA | |
| ExFreePool | ExFreePoolWithTag | Pass tag or 0 |
| ExInitializeNPagedLookasideList | ExInitializeLookasideListEx | |
| ExInitializePagedLookasideList | ExInitializeLookasideListEx | |
| IoAllocateErrorLogEntry | (still valid) | |
| POOL_TYPE enum | POOL_FLAGS (ULONG64) | Different type entirely |
| NonPagedPool (POOL_TYPE) | POOL_FLAG_NON_PAGED | NX by default now |

---

*Report compiled from: Microsoft Learn WDK Documentation, WDK Release Notes, OSR NT Insider and*
*Best Practices guide, Windows Internals 7th Edition, Windows Kernel Programming 2nd Edition,*
*Microsoft Windows-driver-samples GitHub repository, and community driver development sources.*
*Current as of April 2026.*
