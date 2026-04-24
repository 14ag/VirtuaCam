# Implementation Plan (tracking)

Source: `PLAN.md` (Unify Build, Output, Logging, Driver Install)

- [ ] 1. Implementation tracking
- [x] 1.1 Add `implementation/plan.md` + `implementation/done.txt`
  - `implementation/plan.md` contains checklist
  - `implementation/done.txt` gets timestamped lines per completion

- [x] 2. Output layout (single root)
- [x] 2.1 Define folders under `output/`
  - `output/software/bin`
  - `output/driver/build`
  - `output/driver/package`
  - `output/logs`
- [x] 2.2 Stage only into `output/` (no repo-root copies)

- [x] 3. Unified build entrypoints
- [x] 3.1 Add top-level orchestrator `build-all.ps1`
  - Params: `-Clean`, `-BuildConfig`, `-SkipSoftware`, `-SkipDriver`, `-OutputRoot`
  - Runs software build then driver build, validates required artifacts, prints inventory
- [x] 3.2 Refactor `software-project/build.ps1`
  - Add `-OutputRoot`
  - Stop copying artifacts to `software-project` root
  - Copy EXE/DLL/PDB into `output/software/bin`
- [x] 3.3 Add driver wrapper `driver-project/build-driver.ps1`
  - Build `Driver/avshws/avshws.sln` (`Release|x64`)
  - Copy artifacts to `output/driver/build` + `output/driver/package`

- [x] 4. Driver build/install reliability
- [x] 4.1 Add readiness checks (build + install)
  - Elevated token (install)
  - Tooling present (vswhere/msbuild for build; pnputil/certutil for install)
  - Package files exist (`.inf/.sys/.cat`, test cert)
  - `TESTSIGNING` readable; if OFF, fail with `bcdedit /set testsigning on` + reboot guidance
- [x] 4.2 Update `Driver/avshws/install-driver.ps1`
  - Use package from `output/driver/package` via `-PackageRoot`
  - Log to `output/logs/driver-install.log`
  - Non-interactive; machine-readable exit codes
  - Success criteria: package added, root device exists, device enumerates (`ROOT\\AVSHWS\\...`)

- [ ] 5. Runtime console logging (VirtuaCam)
- [x] 5.1 Allocate/attach console on startup (debug-friendly)
- [x] 5.2 Mirror GUI MessageBox errors to stderr + `output/logs/virtuacam-runtime.log`
- [x] 5.3 Log exact DLL load failures (incl. HRESULT `0x8007047E` context)

- [ ] 6. Software artifact discovery from `output`
- [x] 6.1 Ensure `VirtuaCam.exe` resolves sibling DLLs from `output/software/bin`
- [x] 6.2 Ensure helper scripts use staged binaries (not repo root)

- [x] 7. Top-level install/clean flow
- [x] 7.1 Add `install-all.ps1`
  - Verify artifacts exist
  - Install driver from `output/driver/package`
  - Optional DLL registration if still needed
  - Emit pass/fail summary
- [x] 7.2 Add `clean-output.ps1` (remove only `output/` + logs)

- [ ] 8. Validation pass
- [ ] 8.1 `build-all.ps1` stages software + driver under `output/`
- [ ] 8.2 `install-all.ps1` installs driver from `output/`
- [ ] 8.3 Launch `output/software/bin/VirtuaCam.exe`, confirm console + log file
