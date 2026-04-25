# VirtuaCam WDK Driver Development: Comprehensive Action Plan

## 1. Toolchain and Environment Setup
- Install Visual Studio 2022 with C++ workload
- Install Windows SDK matching WDK build number (10.0.26100.6584)
- Install WDK 10.0.26100.6584 (MSI or NuGet)
- Install WDK VSIX component in Visual Studio
- Use EWDK ISO for build environments without full Visual Studio

## 2. Driver Model and Architecture
- Confirm AVStream (WDM/KS) is used for VirtuaCam (required for video capture)
- Document why AVStream is chosen over KMDF/UMDF
- Ensure minidriver registration via KsInitializeDriver and correct descriptor setup
- Use pin-centric processing (CCapturePin::Process)

## 3. Memory Management Modernization
- Replace all ExAllocatePoolWithTag/ExAllocatePool calls with ExAllocatePool2
  - Use correct POOL_FLAGS (POOL_FLAG_NON_PAGED, etc.)
  - Remove RtlZeroMemory after allocation (ExAllocatePool2 zeroes by default)
  - Check for NULL after every allocation
  - Use unique, valid 4-char pool tags (no 0 bytes)
- Replace ExFreePool with ExFreePoolWithTag (tag=0 if not tracked)
- Update lookaside list usage to ExInitializeLookasideListEx

## 4. IRQL and Synchronization Discipline
- Audit all allocations for IRQL correctness (see table)
- Ensure all DISPATCH_LEVEL code uses non-paged pool only
- Place PAGED_CODE() at top of every function in PAGE segment
- Ensure no pageable code is called from DPC/ISR/locked code
- Use spinlocks correctly (KeAcquireSpinLock, KeReleaseSpinLock)
- Use KeAcquireSpinLockAtDpcLevel/KeReleaseSpinLockFromDpcLevel when already at DISPATCH_LEVEL

## 5. AVStream-Specific Implementation
- Register device under KSCATEGORY_VIDEO, KSCATEGORY_CAPTURE, KSCATEGORY_VIDEO_CAMERA in INF
- Use DEFINE_KSPROPERTY_TABLE and DEFINE_KSPROPERTY_SET_TABLE for custom properties
- Implement property handlers with buffer length checks
- Use KsAddItemToObjectBag for all allocations needing cleanup
- Use KsEdit for runtime descriptor modification, check NT_SUCCESS
- Handle scatter-gather and stream pointer logic as described
- Ensure correct use of KSSTREAM_HEADER and KS_FRAME_INFO

## 6. Driver Signing and Certification
- Use test signing for development (bcdedit /set testsigning on)
- Plan for attestation signing for production (submit to Partner Center)
- For WHQL/WHCP, prepare for HLK test suite and DVL generation
- Ensure no legacy cross-signed drivers are used (April 2026 enforcement)
- Integrate CodeQL and SDV in CI/CD
- Avoid POOL_FLAG_NON_PAGED_EXECUTABLE for HVCI compatibility

## 7. Debugging and Validation
- Use WinDbg for kernel debugging (setup KDNET, USB, or serial transport)
- Enable Driver Verifier for avshws.sys and ks.sys
- Use KsStudio.exe and GraphEdt.exe for AVStream validation
- Enable KASAN in project properties for runtime memory checks
- Use !analyze -v, !pool, !poolused, !irp, !ks.graph, !ks.allStreams in WinDbg

## 8. Coding Rules and Patterns
- Overload operator new/delete for kernel pool allocations
- Use role-type SAL annotations on all dispatch routines
- Avoid exceptions, STL, RTTI in kernel code
- Ensure _purecall is defined
- Use C++ compiler for all code (even C)
- Use unique pool tags and track with WinDbg

## 9. Static Analysis and Testing
- Integrate Static Driver Verifier (SDV) and CodeQL in build pipeline
- Enable KASAN for memory error detection
- Review and address all SDV/CodeQL findings before release

## 10. Documentation and Reference
- Maintain up-to-date documentation on:
  - Toolchain versions and setup
  - Driver model rationale
  - Memory management patterns
  - IRQL and synchronization rules
  - AVStream architecture and property sets
  - Signing and certification process
  - Debugging and validation workflow
  - Coding standards and patterns
- Reference and review:
  - Windows Kernel Programming (Yosifovich)
  - Windows Internals (Russinovich et al)
  - Microsoft Learn and Windows-driver-samples
  - OSR NT Insider and best practices

## 11. Common Pitfall Audits
- Check all IOCTL/property handlers for buffer length validation
- Ensure no deprecated pool APIs remain
- Audit all DPC/ISR/locked code for pageable calls
- Check KsEdit failure handling
- Validate stream pointer advancement logic
- Ensure descriptor constness is respected and KsEdit is used for runtime changes

---

**Next Steps:**
1. Review and assign owners for each actionable.
2. Sequence implementation and audits according to project phase.
3. Track progress and update plan as new WDK/OS changes are released.
