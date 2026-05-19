---
name: run-tests
description: Use when the user says "run tests", "run VirtuaCam tests", "run vHLK gates", or asks for the current VirtuaCam test workflow. Runs or explains the exact no-scan local, driver-test, failed-only vHLK, final vHLK, and documentation assertion sequence.
---

# VirtuaCam Run Tests

Use this skill when the user asks to run or plan tests for VirtuaCam.

## Entry Rules

- Read `scripts/RUN-TESTS.md` first.
- Use `wiki/Testing.md` for current test roles, pass gates, and artifact paths.
- Use `wiki/vHLK-Fix-Workflow.md` for current vHLK failed-only workflow.
- Do not scan the whole repository for test order unless these docs are missing or stale.
- If a required test fact is not documented in the wiki, update the wiki with `technical-writer2`.

## Default Workflow

Run these stages in order:

1. Local gate.
2. `driver-test` gate.
3. vHLK failed-name export.
4. Failed-only vHLK.
5. Final full vHLK sanity.
6. Post-vHLK documentation assertion.

Stop at the first failed stage. Patch, then restart at local gate. After a vHLK playlist patch, rerun local and `driver-test` gates, retest the failed vHLK set first, then resume the current failed or remaining playlist after the failed set passes. Do not restart completed playlist tests.

Default `driver-test` gate uses DirectShow probe and Windows Camera proof only. Do not run Chrome or browser proof unless the user explicitly asks for it.

Iteration loop:

1. Run local regression tests in `driver-test`.
2. Run vHLK only after local and `driver-test` gates pass.
3. If 2 vHLK tests fail in one iteration, stop, export status, collect artifacts, research, and patch.
4. Rerun local and `driver-test` gates.
5. Retest the failed vHLK set.
6. If the failed set still fails, repeat the failure loop.
7. If the failed set passes, continue vHLK with tests after the failed set plus any current non-passed tests.
8. After the last queued vHLK test passes, run final full vHLK from the start and rerun all local and `driver-test` gates.
9. Update docs only after final verification passes.

## Commands

The canonical command list is in:

- `scripts/RUN-TESTS.md`
- `skills/run-tests/references/test-workflow.md`

Reference docs:

- `wiki/Testing.md`
- `wiki/vHLK-Fix-Workflow.md`
- `wiki/Home.md`

Skill QA checklist:

- `skills/run-tests/QA.txt`

## vHLK Stop Rules

- Driver-change vHLK failure: read relevant PDF table of contents or first pages, then relevant section before patch.
- 2 vHLK failures in one iteration: stop, export failed names/status, do web research, then patch.
- 10 vHLK failures: stop immediately.
- 5 consecutive controller reconnect failures: stop, write `controller-reconnect-limit.json`, return control with artifact path.

## Output

When reporting test status, include:

- stages completed
- commands run
- latest artifact directories
- failed tests or blockers
- next stage

Only assert ready-to-ship when all local, `driver-test`, failed-only vHLK, final full vHLK, and post-vHLK documentation assertion gates pass.
