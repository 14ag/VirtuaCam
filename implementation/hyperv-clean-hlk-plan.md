# Hyper-V Clean Loop And HLK Plan

## Clean bench workflow

Goal:
- keep one named Hyper-V checkpoint, `clean`
- `clean` must contain no installed `avshws` device instance and no `avshws.inf` package in the guest driver store
- every driver test run starts by restoring `clean`
- every result pass/fail ends with artifact collection and a report-driven next action

Scripts:
- create or refresh the bench:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-clean-checkpoint.ps1 -GuestPasswordPlaintext x -ForceRefresh`
- run one driver test cycle from `clean`:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-driver-loop.ps1 -GuestPasswordPlaintext x -CheckpointName clean`
- install or remove HLK client from the guest once a controller share exists:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-hlk-client.ps1 -Action Install -RestoreCleanFirst -RefreshCleanCheckpoint -GuestPasswordPlaintext x -ControllerName <ControllerName>`
  - `powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-hlk-client.ps1 -Action Uninstall -RestoreCleanFirst -GuestPasswordPlaintext x -ControllerName <ControllerName>`
- create controller VM shell from Server ISO:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-hlk-controller-vm.ps1 -IsoPath '<server-iso-path>' -VmName hlk-controller -StartVm`

What `hyperv-clean-checkpoint.ps1` does:
- connects to the guest with PowerShell Direct
- stops `VirtuaCam`, `VirtuaCamProcess`, Chrome, Edge, and Camera app
- removes `C:\Temp\VirtuaCamHyperV`
- clears guest crash dumps
- removes `ROOT\AVSHWS\0000` if present
- deletes matching `avshws.inf` driver packages from the guest driver store
- reboots and retries cleanup if the guest reports reboot-needed cleanup state
- powers off the VM
- creates a standard Hyper-V checkpoint named `clean`

What `hyperv-driver-loop.ps1` now does:
- restores checkpoint `clean` before the run
- boots guest and waits for PowerShell Direct
- stages current `output\` package plus install script and `webcam.html`
- installs the driver without forced rebind
- reboots if install logs say reboot is required
- optionally enables verifier / kernel debug
- runs the selected repro mode
- collects guest logs, dumps, and debugger logs
- restores `clean` again after the run when `-RevertAfterRun $true`

## Test loop

1. Build code and stage fresh `output\`.
2. Restore `clean`.
3. Copy fresh files into guest.
4. Install driver.
5. Reboot if install requires it.
6. Reproduce:
   - `CameraApp`
   - `WebcamHtml`
   - `VirtuaCam`
   - or no repro for install-only checks
7. Collect:
   - setup/install logs
   - runtime/process logs
   - event logs
   - minidumps / memory dumps
   - optional debugger logs
8. Write next action from evidence:
   - bug fix
   - instrumentation
   - verifier configuration change
   - format / media-type change
   - HLK-specific prep
9. Repeat from step 1.

## Reporting outputs

Every run should produce enough evidence to answer:
- did install succeed?
- did guest require reboot?
- did guest BSOD or unexpectedly restart?
- did the browser / app see frames?
- did the driver queue and complete frames?
- what exact log or dump points to the next change?

Minimum artifact set:
- `guest-driver-install.txt`
- `guest-baseline.json`
- collected guest logs
- collected event logs
- minidump or memory dump if crash happened
- browser proof logs / screenshot if browser path used

## HLK plan

## Current status

As of `2026-05-02`:
- host `UNIT` now has standalone HLK Studio bits installed from local media
- verified installed products:
  - `Windows Hardware Lab Kit - Windows 10 10.1.19041.5738`
  - `Windows Hardware Lab Kit Studio 10.1.19041.5738`
  - `Microsoft SQL Server Compact 4.0 SP1 x64 ENU 4.0.8876.1`
- verified bundle result:
  - root burn log ended `Apply complete, result: 0x0, restart: None`
- verified installed tree:
  - `C:\Program Files (x86)\Windows Kits\10\Hardware Lab Kit\Studio`
- not installed:
  - HLK Controller
  - HLK client on `driver-test`

Important limit:
- Microsoft docs support HLK Controller on a Windows Server test server or VHLK controller VM
- this Windows 10 host is good for standalone Studio, but it is not the controller target we should rely on for the clean test bench
- because of that, the next HLK blocker is not Studio, it is getting a controller share:
  - `\\<ControllerName>\HLKInstall\Client\Setup.cmd`

Use official guidance:
- Windows HLK overview: use the correct kit version for the target OS; VHLK is a preconfigured controller VM in Hyper-V.
- HLK prerequisites: controller and clients must be dedicated test machines; client machines should be clean before HLK client install; workgroup needs same workgroup and guest account enabled.
- VHLK get-started: VHLK runs as a Hyper-V VM, default credentials `HLKAdminUser / Testpassword,1`, recommended 4 GB+ RAM and 2+ vCPUs.

Reference links:
- HLK overview:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/
- HLK prerequisites:
  - https://learn.microsoft.com/en-gb/windows-hardware/test/hlk/getstarted/windows-hlk-prerequisites
- VHLK get started:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/getstarted/getstarted-vhlk
- Install controller and studio:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/getstarted/step-1-install-controller-and-studio-on-the-test-server
- Install client on test systems:
  - https://learn.microsoft.com/en-sg/windows-hardware/test/hlk/getstarted/step-2--install-client-on-the-test-system-s-
- Create machine pool:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/getstarted/step-3-create-a-machine-pool
- Create project:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/getstarted/step-4-create-a-project
- Select and run tests:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/getstarted/step-6-select-and-run-tests
- HLK Studio tests tab:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/user/hlk-studio---tests-tab
- Troubleshoot HLK client:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/user/troubleshooting-windows-hlk-client
- Device Fundamentals reliability prerequisites:
  - https://learn.microsoft.com/en-us/windows-hardware/test/hlk/testref/devicefundamentals-reliability-testing-prerequisites

Recommended plan for this repo:

### Phase 1: Controller choice

Option A, preferred:
- use VHLK as the controller VM if the downloaded ISO / VHDX matches the guest OS we care about
- this saves manual SQL/controller setup time

Option B:
- install full HLK Controller on a dedicated Windows Server VM from `HLKSetup.exe` if VHLK for the needed target version is unavailable

Do not use the current Windows 10 host as the long-term controller.

Controller VM prep script now exists:
- [hyperv-hlk-controller-vm.ps1](C:/Users/philip/sauce/virtual-webcam/v2/scripts/hyperv-hlk-controller-vm.ps1)
- it:
  - creates Generation 2 VM
  - creates/attaches VHDX
  - mounts downloaded Server ISO
  - sets DVD first boot
  - disables automatic checkpoints
  - leaves machine ready for manual Windows Server install

### Phase 2: DUT strategy

For the current `driver-test` VM:
- keep `clean` as the base checkpoint
- after HLK client install is working, refresh `clean` so it still has:
  - no `avshws` driver in the store
  - no `ROOT\AVSHWS\0000`
  - HLK client installed and ready
  - any required test-signing / dump / debugger settings already configured

This makes HLK and non-HLK loops both restore to a driver-free but test-ready state.

### Phase 3: Initial HLK bring-up

1. Bring up controller VM.
2. Install or confirm HLK Studio + Controller.
3. Install HLK Client on `driver-test`.
   - official silent path:
     - `\\<ControllerName>\HLKInstall\Client\Setup.cmd /qn ICFAGREE=Yes`
   - script wrapper:
     - `powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-hlk-client.ps1 -Action Install -RestoreCleanFirst -RefreshCleanCheckpoint -GuestPasswordPlaintext x -ControllerName <ControllerName>`
4. In HLK Studio:
   - move client from `Default Pool` to a working pool
   - set machine status to `Ready`
   - create a project for `avshws`
5. Confirm the DUT target appears on the Selection tab before scheduling tests.

### Phase 4: First HLK batches

Run small batches first:
- camera registration / metadata / dependency tests
- camera basic Media Foundation / AVStream interface tests
- Device Fundamentals bring-up checks

Then run larger batches:
- Device Fundamentals reliability tests
- camera functional tests
- camera stress / reliability tests

Keep manual tests separate from automated batches.

### Phase 5: How HLK fits our bug loop

Use HLK after each meaningful fix set, not after every tiny code edit:
- first pass: registration / discovery / basic capture
- second pass: functional camera scenarios
- third pass: reliability / stress

Platform note:
- for refreshed HLK releases starting with the October 2024 refresh for Windows 11 24H2 / Windows Server 2025, HLK Proxy Client is no longer supported, so use normal controller/client onboarding instead of planning around proxy-client mode

If HLK finds:
- unexpected reboot: pull dump, analyze, patch, restore `clean`, rerun
- device setup failure: inspect install/setup logs and target readiness
- media capture failure: compare HLK logs with our browser/runtime logs

### Phase 6: Suggested early HLK matrix

Batch A, install / registration:
- camera registration
- metadata / dependency
- target enumeration

Batch B, basic capture:
- preview / capture basic tests
- AVStream / MediaFoundation interface coverage

Batch C, reliability:
- Device Fundamentals reliability
- reboot / PnP / disable-enable style stress where applicable

Batch D, long-run:
- camera stress / long preview-record paths

## Notes

- Browser proof and HLK serve different purposes:
  - browser proof shows end-to-end real app behavior
  - HLK gives structured certification-style diagnostics
- today's installed Studio helps us inspect and connect later, but it does not remove the controller requirement for DUT onboarding
- do not snapshot a guest that already has a trial `avshws` package in its driver store if that snapshot is meant to be `clean`
- when HLK client gets added to the DUT, refresh `clean` again so the bench remains driver-free but HLK-ready

