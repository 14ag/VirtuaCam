# Continuation Prompt

Use caveman mode in user-facing replies.

You are resuming work in repo:
`C:\Users\philip\sauce\virtual-webcam\v2`

## Mission
Keep the project on the **kernel-driver-only AVStream** path, preserve the now-working proof harness, and move from proof to HLK/WHQL readiness without regressing the real guest-window camera proof.

## Real success criteria
There are now two separate success bars:

1. Functional proof:
   - Chrome inside `driver-test` opens the virtual camera.
   - The webcam feed shows a **real guest app window**.
   - Placeholder blue frames or synthetic filler do **not** count.
2. Compliance path:
   - HLK controller/client wiring works.
   - `driver-test` can be exercised from clean state through HLK without breaking the working proof path.

## What is already true now
### Proof path is real and green
- The trustworthy Hyper-V proof harness is already implemented.
- Real-window source mode is enforced through guest Notepad, not the old synthetic proof panel default.
- The AVStream path was repaired enough to deliver frames to Chrome.
- Latest known good proof from this repo state was attempt `61`.
- Key proof artifacts:
  - `output\playwright\vm-webcam-proof.json`
  - `output\playwright\vm-session-status.json`
  - `output\playwright\vm-webcam-proof.png`

### Build/install path is now unified
Public repo entrypoints were collapsed to:

- one build script: `build-all.ps1`
- one install script: `install-all.ps1`
- one staged package path: `output\`

Deleted old split entrypoints:

- `software-project\build.ps1`
- `driver-project\build-driver.ps1`
- `driver-project\Driver\avshws\install-driver.ps1`

Current packaging/source-of-truth helper:

- `tools\artifact-manifest.ps1`

### Build script is confirmed working
- Full root build was run successfully.
- A real bug in VC runtime staging was fixed in `build-all.ps1`.
- Problem was bad runtime-redist directory selection under Visual Studio Build Tools.
- `build-all.ps1` now finds the correct `VC\Redist\MSVC\<version>\x64\Microsoft.VC143.CRT` directory.

### Install script is confirmed working
- `install-all.ps1` was exercised inside `driver-test` guest from a clean restore path.
- It successfully:
  - verified staged artifacts
  - imported cert
  - installed driver
  - created `ROOT\AVSHWS` if missing
  - restarted device node
  - registered `DirectPortClient.dll`
  - configured startup entries
- Proof artifact for that install:
  - `output\hyperv-runs\20260502-165126\guest-driver-install.txt`

### HLK controller/client wiring now works
- `vhlk` is installed and exposes working controller shares.
- Verified controller share path:
  - `\\192.168.100.115\HLKInstall\Client\Setup.cmd`
- Verified shares on controller:
  - `HLKInstall`
  - `HLKLogs`
  - `HLKTools`
  - `Tests`
  - `TestPackages`
  - `TestRuntimes`
  - `TaefBinaries`
- `driver-test` HLK client install succeeded from clean state.
- Artifact:
  - `output\hyperv-hlk-client\20260502-170705\guest-hlk-client.json`
  - `output\hyperv-hlk-client\20260502-170705\guest-hlk-client-output.txt`
- Confirmed installed on `driver-test`:
  - `Windows Hardware Lab Kit Client`
  - `Windows Driver Testing Framework (WDTF) Runtime Libraries`
  - `Application Verifier x64 External Package`
- Confirmed running service on guest:
  - `HLKSvc` / `HLK Communication Service`

## Current architecture constraints from user
- Must stay **kernel driver only**.
- Do **not** pivot to Media Foundation virtual camera.
- Keep AVStream as the shipping path.
- If auditing is needed again, inspect AVStream/WDK compliance against local PDFs first.

## Mandatory workflow rules
1. Use caveman style in replies.
2. If a Windows-specific issue appears, read local PDFs first.
3. When reading PDFs, use TOC first for navigation.
4. If the same error happens twice, stop blind reruns.
5. Use SSH as a supplement where it works, but do not assume `clean` is ssh-ready.
6. Do not claim success from placeholder-frame screenshots.

## Research order and sources
### Local PDFs first
1. `C:\Users\philip\sauce\virtual-webcam\v2\pdfs\Windows_Internals_Including_Windows_Server_2008.pdf`
   - useful areas already referenced:
     - Chapter 4 `Services`
     - Chapter 6 `Security`
     - Chapter 7 `I/O System`
     - Chapter 12 `Networking`
2. `C:\Users\philip\sauce\virtual-webcam\v2\pdfs\Programming the Microsoft Windows Driver Model (2nd Edition).pdf`
   - useful areas already referenced:
     - user-pointer handling
     - spinlocks / waits / IRQL rules
     - PnP state transitions
     - METHOD_NEITHER / safe IOCTL design

### After PDFs
- Official Microsoft Learn / WDK docs
- `https://osronline.com/`
- public support references only when needed

## VM inventory and credentials
### `driver-test`
- OS: Windows 10 Pro 19045
- Current hostname: `WIN-KQ09DIBH3C6`
- IP seen after latest clean restore: `192.168.100.91`
- Username: `Administrator`
- Password: `x`

### `vhlk`
- OS: Windows Server 2019 Standard 17763
- Current hostname: `WIN-GPO7F54QE38`
- Current verified IP: `192.168.100.115`
- Username: `administrator`
- Password: `xxxxxx.1`

Note: guest IPs do drift. Re-check before using SSH or SMB paths.

## SSH state
### What is working
- `vhlk` share access from host is working over SMB.
- SSH was previously verified on both VMs when not using the old clean snapshot.
- Host-side preferred SSH path is still `Posh-SSH` with password auth.

Module path:
- `C:\Users\philip\Documents\WindowsPowerShell\Modules\Posh-SSH\3.2.7\Posh-SSH.psd1`

### Important nuance
- The current `clean` checkpoint on `driver-test` is still **not ssh-ready**.
- After restoring `clean`, `driver-test` answered on Hyper-V/PowerShell Direct eventually, but SSH on `192.168.100.91:22` timed out.
- So do **not** assume SSH works immediately after restoring `clean`.
- If future work needs SSH-first clean runs, refresh `clean` after re-enabling ssh inside that restored guest.

## Checkpoint state
There is a Hyper-V checkpoint on `driver-test` named `clean`.

What is true about `clean` now:
- it is still suitable for clean driver-free restore
- it was good enough for:
  - clean driver install test via `install-all.ps1`
  - clean HLK client install
- it is **not** yet ssh-ready

What `clean` should become next:
1. restore `clean`
2. verify no `avshws` in driver store
3. verify no `ROOT\AVSHWS` device
4. re-enable/fix guest OpenSSH if needed
5. create refreshed `clean` again

That gives a bench that is:
- driver-free
- HLK-client-ready if desired
- ssh-ready

## Key code and script changes already made
### AVStream/driver side
High-value driver fixes were already made in the AVStream stack, including:
- repaired sample-delivery behavior so Chrome can open the device
- event/object lifetime fixes
- PnP/power cleanup hardening
- stream pointer cleanup
- frame timing/metadata fixes
- stop/remove race fixes
- pause/resume monotonicity fixes

Do not assume those areas are perfect, but do assume the current repo state is the one that produced the real green proof.

### Hyper-V proof harness
The proof harness was upgraded to:
- restore `clean` before each proof run
- verify clean preinstall state
- use real Notepad window source by default
- capture richer session metadata
- reject synthetic proof mode in the real proof path
- revert to `clean` after run

Relevant scripts:
- `scripts\hyperv-proof-chrome.ps1`
- `scripts\hyperv-hold-webcam-session.ps1`
- `scripts\guest-held-webcam-session.ps1`
- `scripts\playwright-vm-webcam-proof.ps1`

### Unified build/install scripts
Relevant files:
- `build-all.ps1`
- `install-all.ps1`
- `clean-output.ps1`
- `tools\artifact-manifest.ps1`

### Hyper-V HLK helper fix
`scripts\hyperv-hlk-client.ps1` had a strict-mode/property-access bug on `DisplayName`.
That was fixed by guarding property access before matching it.

## Current file/worktree situation
There are active repo changes related to:
- unified build/install flow
- HLK client helper
- continuation docs
- subproject docs

Files known changed in the current worktree include:
- `build-all.ps1`
- `install-all.ps1`
- `clean-output.ps1`
- `scripts\hyperv-driver-loop.ps1`
- `scripts\hyperv-proof-chrome.ps1`
- `scripts\hyperv-hlk-client.ps1`
- `tools\artifact-manifest.ps1`
- `README.md`
- `CONTRIBUTING.md`
- `software-project\README.md`
- `driver-project\README.md`
- `implementation\continuation-prompt.md`
- `implementation\driver-frame-path.md`

Deleted old scripts:
- `software-project\build.ps1`
- `driver-project\build-driver.ps1`
- `driver-project\Driver\avshws\install-driver.ps1`

There are also untracked local items that were not part of this work and should not be touched blindly:
- `build-all.bat`
- `install.bat`
- `output0\`

## Verified artifacts and evidence
### Functional proof artifacts
- `output\playwright\vm-webcam-proof.json`
- `output\playwright\vm-session-status.json`
- `output\playwright\vm-webcam-proof.png`

### Build/install confirmation artifacts
- `output\hyperv-runs\20260502-165126\guest-driver-install.txt`
- `output\hyperv-runs\20260502-165126\repro-result.json`

### HLK client confirmation artifacts
- `output\hyperv-hlk-client\20260502-170705\guest-hlk-client.json`
- `output\hyperv-hlk-client\20260502-170705\guest-hlk-client-output.txt`

### One non-blocking failure artifact
After the successful guest install test, host-side artifact collection hit:
- `output\hyperv-runs\20260502-165126\hyperv-collect.log`
- error text: `Class not registered`

That was a **post-install collection** problem, not an `install-all.ps1` failure.

## Current diagnosis
### What is no longer the main blocker
- AVStream startup timeout is no longer the main story; proof already went green.
- build/install fragmentation is no longer the main story; build/install is now unified and confirmed.
- HLK controller/client discovery is no longer the main story; controller share and client install are confirmed.

### What is the actual current blocker
The biggest remaining bench-quality gap is:
- `clean` is not yet ssh-ready

The biggest remaining project-quality gap is:
- move from proof-green to HLK execution and WHQL-style validation without regressing the proof path

## Useful commands
### Full build
```powershell
powershell -ExecutionPolicy Bypass -File .\build-all.ps1
```

### Driver-only iteration on the same build script
```powershell
powershell -ExecutionPolicy Bypass -File .\build-all.ps1 -SkipSoftware
```

### Install from staged output
```powershell
powershell -ExecutionPolicy Bypass -File .\install-all.ps1
```

### Real proof run
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-proof-chrome.ps1 -GuestPasswordPlaintext x
```

### HLK client install to `driver-test`
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\hyperv-hlk-client.ps1 `
  -VmName driver-test `
  -GuestPasswordPlaintext x `
  -ControllerSharePath "\\192.168.100.115\HLKInstall\Client\Setup.cmd" `
  -ControllerUser administrator `
  -ControllerPasswordPlaintext xxxxxx.1 `
  -RestoreCleanFirst
```

### Host-side share check for controller
```powershell
cmd.exe /c "net view \\192.168.100.115"
cmd.exe /c "dir \\192.168.100.115\HLKInstall\Client"
```

### Posh-SSH example
```powershell
$env:PSModulePath = "$HOME\Documents\WindowsPowerShell\Modules;$env:PSModulePath"
Import-Module Posh-SSH -Force
$cred = [pscredential]::new('Administrator',(ConvertTo-SecureString 'x' -AsPlainText -Force))
$s = New-SSHSession -ComputerName 192.168.100.91 -Credential $cred -AcceptKey -ConnectionTimeout 30
Invoke-SSHCommand -SSHSession $s -Command 'cmd /c "hostname & whoami"'
Remove-SSHSession -SSHSession $s
```

Only use that last command after re-validating that the restored guest is actually listening on port 22.

## What to do next
### Immediate next steps
1. Refresh the `clean` checkpoint so it is both:
   - driver-free
   - ssh-ready
2. Confirm `driver-test` can still run the real proof harness from that refreshed clean state.
3. Open HLK Studio on `vhlk`.
4. Confirm `driver-test` appears as enrolled client.
5. Create or verify the machine pool and move `driver-test` into it.
6. Start with the smallest safe HLK passes first:
   - device fundamentals
   - camera-related basics
   - verifier-backed reliability tests only after confirming the exact pool/job selection

### Good sequencing
Best order from here:
1. refresh `clean`
2. rerun proof once from refreshed `clean`
3. confirm proof still green
4. begin HLK jobs
5. only then chase HLK failures one by one

## If proof regresses
Inspect first:
- `output\playwright\vm-webcam-proof.json`
- `output\playwright\vm-webcam-console.log`
- `output\playwright\vm-session-status.json`
- `output\playwright\hyperv-proof-chrome.log`
- guest `virtuacam-runtime.log`
- guest `virtuacam-process.log`
- any dump / event log if VM crashes

If the same failure repeats twice:
1. stop rerunning
2. read local PDFs first
3. then use Microsoft docs / OSR
4. change one thing only

## If HLK path fails
Check in this order:
1. can `driver-test` reach `\\192.168.100.115\HLKInstall\Client\Setup.cmd`
2. is `HLKSvc` running on `driver-test`
3. does HLK Studio on `vhlk` show the client
4. did refreshing `clean` remove the client unexpectedly
5. are PowerShell Direct failures just guest service timing, not actual install failures

## Short operator summary
You are resuming from a state where:
- the AVStream virtual camera proof is already real and green
- build/install flow is unified and confirmed
- HLK controller share on `vhlk` is working
- HLK client install on `driver-test` already succeeded from clean
- the clean checkpoint still needs one important improvement: make it ssh-ready
- best next move is **refresh clean, rerun proof once, then start HLK jobs**
