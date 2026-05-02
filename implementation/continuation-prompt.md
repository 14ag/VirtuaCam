# Continuation Prompt

Use caveman mode in user-facing replies.

You are resuming work in repo:
`C:\Users\philip\sauce\virtual-webcam\v2`

## Mission
Get the virtual webcam driver stable enough to prove end-to-end success inside Hyper-V.

### Real success criterion
Capture a screenshot of **Chrome inside the VM** running `webcam.html`, where the webcam feed is a **real guest window** such as `explorer.exe`, Notepad, or any other visible app window. A blue placeholder frame or synthetic filler image does **not** count.

## Mandatory workflow
1. Keep a Hyper-V checkpoint named `clean` as the ready driver bench.
2. `clean` must be driver-free: no `avshws` package in driver store and no `ROOT\AVSHWS` device present.
3. For each driver test loop:
   - restore `clean`
   - stage fresh files from repo/output
   - install driver
   - repro
   - collect logs/dumps/diagnostics
   - decide next call to action
   - patch project
   - restore `clean`
   - retest
4. If the same error class happens twice, stop blind reruns. Research first, then change one variable.
5. If a Windows-related error happens, use local PDFs first. Look at the TOC first, then pull only the relevant sections, then use official Microsoft docs if needed.

## Research order and sources
### Local PDFs first
1. `C:\Users\philip\sauce\virtual-webcam\v2\pdfs\Windows_Internals_Including_Windows_Server_2008.pdf`
   - TOC pointers already used:
     - Chapter 4 `Services` around p281-317
     - Chapter 6 `Security` around p451-535
     - Chapter 7 `I/O System` around p537-644
     - Chapter 12 `Networking` around p1020+
2. `C:\Users\philip\sauce\virtual-webcam\v2\pdfs\Programming the Microsoft Windows Driver Model (2nd Edition).pdf`
   - useful sections already used:
     - p72 user-pointer handling basics
     - p107-111 spinlocks / waits / IRQL rules
     - p181-191 PnP state transitions
     - p279-280 METHOD_NEITHER / safe IOCTL design

### After PDFs
- Official Microsoft Learn / WDK docs
- `https://osronline.com/`
- Public precedent only as support: GitHub, OSR, Stack Overflow, Reddit, Chromium issues

## VM inventory and credentials
### `driver-test`
- OS: Windows 10 Pro 19045
- Current hostname: `WIN-KQ09DIBH3C6`
- Current IP during last check: `192.168.100.112`
- Username: `Administrator`
- Password: `x`

### `vhlk`
- OS: Windows Server 2019 Standard 17763
- Current hostname: `WIN-GPO7F54QE38`
- Current IP during last check: `192.168.100.113`
- Username: `administrator`
- Password: `xxxxxx.1`

Note: IPs can change on Hyper-V default switch. Rediscover with PowerShell Direct if needed.

## SSH state
### What is working now
Both VMs now have permissive `sshd` configs and are listening on port 22.

Config lines currently set on both VMs:
- `SyslogFacility LOCAL0`
- `LogLevel VERBOSE`
- `StrictModes no`
- `PubkeyAuthentication yes`
- `AuthorizedKeysFile .ssh/authorized_keys`
- `PasswordAuthentication yes`
- `PermitEmptyPasswords no`

### Important detail
- `driver-test` OpenSSH Server was broken before: service was crash-looping with repeated SCM 7031 entries.
- It was fixed by removing and reinstalling `OpenSSH.Server~~~~0.0.1.0`, then rewriting a permissive `sshd_config`.
- `vhlk` already had working sshd after install and was reconfigured to the same permissive policy.

### Host-side command path that works now
Do **not** rely on Windows `ssh.exe` key auth right now. It behaved badly even when the server accepted the key.
Use `Posh-SSH` with password auth from host PowerShell.

Module path:
- `C:\Users\philip\Documents\WindowsPowerShell\Modules\Posh-SSH\3.2.7\Posh-SSH.psd1`

Example commands:
```powershell
$env:PSModulePath = "$HOME\Documents\WindowsPowerShell\Modules;$env:PSModulePath"
Import-Module Posh-SSH -Force

$cred = [pscredential]::new('Administrator',(ConvertTo-SecureString 'x' -AsPlainText -Force))
$s = New-SSHSession -ComputerName 192.168.100.112 -Credential $cred -AcceptKey -ConnectionTimeout 30
Invoke-SSHCommand -SSHSession $s -Command 'cmd /c "hostname & whoami"'
Remove-SSHSession -SSHSession $s
```

```powershell
$env:PSModulePath = "$HOME\Documents\WindowsPowerShell\Modules;$env:PSModulePath"
Import-Module Posh-SSH -Force

$cred = [pscredential]::new('administrator',(ConvertTo-SecureString 'xxxxxx.1' -AsPlainText -Force))
$s = New-SSHSession -ComputerName 192.168.100.113 -Credential $cred -AcceptKey -ConnectionTimeout 30
Invoke-SSHCommand -SSHSession $s -Command 'cmd /c "hostname & whoami"'
Remove-SSHSession -SSHSession $s
```

These were verified.

## Checkpoint state
There is a Hyper-V checkpoint on `driver-test` named `clean`.

Important nuance:
- old `clean` snapshot exists and was created earlier as driver-free bench
- current running `driver-test` VM is **not clean** right now
- current running VM still shows `Virtual Camera Driver` / `ROOT\AVSHWS\0000`
- therefore **do not** assume current runtime matches the `clean` workflow
- also, the old `clean` snapshot predates the new SSH setup

### Recommended checkpoint action
Next operator should do this early:
1. restore old `clean`
2. verify `avshws` package/device absent
3. reapply the permissive SSH setup to `driver-test`
4. create a refreshed checkpoint also named `clean`

That gives a truly ready bench: driver-free and ssh-ready.

## Current code changes in worktree
Modified files:
- `driver-project/Driver/avshws/device.cpp`
- `driver-project/Driver/avshws/device.h`
- `driver-project/Driver/avshws/filter.cpp`
- `driver-project/Driver/avshws/hwsim.cpp`
- `driver-project/Driver/avshws/hwsim.h`

### High-value driver fixes already made
1. Split PnP paths in `device.cpp`
   - added more explicit stop/remove/surprise handling through `QuiesceHardware`, `PnpRemove`, `PnpSurpriseRemoval`
2. Hardened filter/property access in `filter.cpp`
   - size checks + guarded copies
   - removed bad `ProbeForRead/Write` experiment after AVStream docs showed KS handler `Data` is already marshaled/system-addressed for this path
3. Fixed frame upload teardown races in `hwsim.cpp`
   - introduced staging buffer handoff
   - stop path nulls/frees buffers safely
4. Fixed event and buffer lifetime issues around stop/data interaction
5. Reduced `kUserFrameStartupGraceInterrupts` from `1200` to `0`
   - this was a major practical fix because the driver was spending too long on placeholder/startup behavior before switching to uploaded real window frames

## Build state
Driver was rebuilt successfully after the recent driver changes and restaged into `output`.

Build command:
```powershell
powershell -ExecutionPolicy Bypass -File .\driver-project\build-driver.ps1
```

## Current diagnosis of the webcam failure path
### What already happened
The proof harness previously reached guest Chrome and `webcam.html`.
Browser enumerated the virtual camera, but one proof run failed with:
- `chrome.AbortError`
- page status: `AbortError - Timeout starting video source`

Artifacts were written under `output\playwright`.

### Very important nuance
There are older screenshot artifacts showing the driver's placeholder frame. Those do **not** satisfy the user. The feed must be a real guest app window.

### Strong current hypothesis
The old startup grace of `1200` interrupts likely delayed the transition from placeholder frames to real uploaded window frames for roughly tens of seconds, long enough for Chrome to time out. That constant was reduced to `0`, but the proof run after that change was interrupted before results were confirmed.

## Useful existing scripts
Already present in repo:
- `scripts\hyperv-clean-checkpoint.ps1`
- `scripts\hyperv-driver-loop.ps1`
- `scripts\hyperv-proof-chrome.ps1`
- `scripts\playwright-vm-webcam-proof.ps1`
- `scripts\hyperv-hold-webcam-session.ps1`
- `scripts\hyperv-hlk-client.ps1`
- `scripts\hyperv-hlk-controller-vm.ps1`

### Key script intent
- `hyperv-proof-chrome.ps1`: stages build, starts source window + VirtuaCam + Chrome, runs Playwright capture, writes attempt-state and research notes
- `hyperv-driver-loop.ps1`: loop harness for install/repro/collect
- `hyperv-clean-checkpoint.ps1`: helps enforce driver-free bench

## Latest audit pressure still worth acting on
A later audit still flagged these classes of concern:
1. property-buffer safety in `filter.cpp`
2. too much work in DPC / `DISPATCH_LEVEL` paths in `hwsim.cpp`
3. stop/pause spin-drain behavior
4. upload buffer handoff correctness
5. PnP stop/remove/surprise semantics
6. capture sink / `KS_VIDEOINFOHEADER` lifetime

Some of these have been partially addressed, but they should be re-reviewed skeptically, not assumed fixed.

## HLK state and plan
- Host-side HLK Studio bits were installed earlier from local media.
- `vhlk` VM now exists as Windows Server 2019 controller candidate.
- Do not jump into HLK as the first debugger while the basic functional proof is still failing.
- Better order:
  1. refresh `clean`
  2. rerun functional proof on `driver-test`
  3. if screenshot proof exists, move into verifier/stress
  4. then wire HLK controller/client flow for reliability coverage

## Immediate call to action
1. Restore `driver-test` to old `clean`.
2. Reapply current permissive SSH config on `driver-test`.
3. Verify clean means:
   - no `avshws` in driver store
   - no `ROOT\AVSHWS` device
4. Recreate checkpoint `clean` so it is both driver-free and ssh-ready.
5. Rebuild driver if needed and confirm fresh `output` package.
6. Run `scripts\hyperv-proof-chrome.ps1 -GuestPasswordPlaintext x` with current build.
7. Use a simple real source window like `explorer.exe`.
8. Check whether the `kUserFrameStartupGraceInterrupts = 0` change now allows Chrome to receive a real app window feed before timeout.
9. If proof still fails, classify exact error and follow repeat-error rule.
10. If same browser/capture error repeats twice, read PDFs/official docs before next rerun.

## If proof still fails, inspect these artifacts first
- `output\playwright\vm-webcam-proof.json`
- `output\playwright\vm-webcam-console.log`
- `output\playwright\vm-session-status.json`
- `output\playwright\hyperv-proof-chrome.log`
- guest `virtuacam-runtime.log`
- guest `virtuacam-process.log`
- latest dump / event logs if VM crashes or PowerShell Direct dies

## If VM crashes again
Treat PowerShell Direct loss or sudden reboot as BSOD.
Then:
1. collect dump + event logs immediately
2. analyze exact bugcheck / faulting module
3. map to verifier rule if present
4. only then choose next code fix

## Background-agent permission
User granted permission to spawn background agents for bounded tasks.
Good uses:
- line-by-line audit against PDFs and OSR guidance
- narrow research on repeated error classes
- HLK matrix planning
Do not use agents for the critical-path action that is needed immediately.

## Constraints from user intent
- Use caveman style in replies.
- User wants action, not endless script-only work.
- The end goal is the real Chrome screenshot proof in VM.
- Do not claim success from placeholder frames.
- If a Windows-specific error appears, PDFs first, TOC first, then official docs.

## Short operator summary
You are resuming from a state where:
- SSH is now usable on both VMs via host `Posh-SSH` password sessions
- `driver-test` current runtime is dirty and still has the driver installed
- old `clean` checkpoint likely remains driver-free but predates SSH setup
- most recent important code fix is the startup-grace change from `1200` to `0`
- best next bet is to refresh `clean`, then rerun the proof harness and see whether real window frames finally reach Chrome in time
