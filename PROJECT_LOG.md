# Project Log

## 2026-07-13 — Production-safety audit and hardening

### Task

Audit `oracle_oop_patching_2.sh` for Bash, workflow, production-safety, rollback, cleanup, and false-success defects; fix confirmed issues and add Oracle-independent regression coverage.

### Decisions

- Keep the previous Oracle Home until an explicit, separately confirmed cleanup.
- Persist rollback state instead of reconstructing it from timestamps or current process variables.
- Automatically roll back a partially failed database switch.
- Track `SWITCHING`, `SWITCHED`, `DATAPATCH_STARTED`, and `COMPLETE`; block unsafe Home-only rollback after SQL patching begins.
- Treat RU, OJVM, OPatch, database startup, health checks, and `datapatch` failures as blocking.
- Do not assume or restart a listener name automatically.
- Restrict automated switching to standalone single-instance databases; reject Grid Infrastructure/Restart and Data Guard.
- Make `--help` side-effect free and preserve explicit mode semantics.
- Continue checking all cleanup candidates after a guarded rejection, then return a non-zero aggregate result.
- Exclude commented-out `/etc/oratab` entries from every database walk; retain exact PID matching when excluding the current process.

### Files changed

- `oracle_oop_patching_2.sh` — production-safety and CLI fixes; version 2.1.0.
- `README.md` — scope, requirements, configuration, mode semantics, rollback, cleanup, and verification documentation.
- `tests/test_cli.sh` — side-effect-free CLI and config overwrite regressions.
- `tests/test_logic.sh` — lock, oratab, rollback state, cleanup, datapatch, and JSON regressions.

### Verification

- `bash -n oracle_oop_patching_2.sh tests/test_cli.sh tests/test_logic.sh`
- `shellcheck -x -S warning oracle_oop_patching_2.sh tests/test_cli.sh tests/test_logic.sh`
- `bash tests/test_cli.sh`
- `bash tests/test_logic.sh`
- `git diff --check`

All commands above passed locally. The regression scripts reported 16 successful scenarios.

### Open issue

A live Oracle integration test was not available in this development environment. Before production use, run the documented staging workflow against a representative Oracle 19c standalone database, including an induced pre-datapatch switch failure and the Oracle-documented post-datapatch recovery procedure.

### Next action

Exercise `--test`, controlled `--prod`, `datapatch` verification, connectivity checks, automatic pre-datapatch rollback, and release-specific SQL patch recovery in staging before adopting the script for production maintenance.

## 2026-07-13 — Oracle-server validation harness

### Task

Add a companion script that can validate the patching workflow on an Oracle server without mutating Oracle by default, while retaining an explicitly confirmed path to exercise the existing Home-preparation mode.

### Decisions

- Make the default `--preflight` mode read-only with respect to Oracle, inventory, `/etc/oratab`, and databases; only private reports and the main script's normal validation logs may be written.
- Reuse the main script's configuration, prerequisite, topology, patch-media, database-discovery, and SQL health-check functions so server validation exercises production code rather than a duplicate implementation.
- Require the exact confirmation `PREPARE` before invoking the mutating `--test` Home-preparation workflow.
- Preserve a private transcript and propagate every failed check as a non-zero process exit without printing a success marker.
- Accept only a non-symlink main script owned by root or the current user and not writable by group/others.

### Files changed

- `oracle_server_validation.sh` — Oracle-server preflight and explicitly confirmed preparation harness.
- `tests/test_server_validation.sh` — Oracle-independent CLI, non-mutation, failure-propagation, confirmation, and delegation regressions.
- `README.md` — server usage, safety boundary, report behavior, and verification commands.

### Verification

- `bash -n oracle_oop_patching_2.sh oracle_server_validation.sh tests/test_*.sh`
- `shellcheck -x -S warning oracle_oop_patching_2.sh oracle_server_validation.sh tests/test_*.sh`
- `bash tests/test_cli.sh`
- `bash tests/test_logic.sh`
- `bash tests/test_server_validation.sh`
- `git diff --check`

The Oracle-independent suites reported 22 successful scenarios. A real Oracle-server preflight and `--prepare` run remain staging activities because this development host has no Oracle installation.
