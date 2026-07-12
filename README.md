# Oracle 19c Out-of-Place Patching

Safety-oriented Bash workflow for preparing a patched Oracle 19c Home, switching local single-instance databases, running `datapatch`, and retaining persistent recovery metadata.

> **Important:** despite the historical repository name, this is **out-of-place**, not in-place, patching. Validate it on a staging host before production use. The automated switch is intentionally limited to standalone, locally managed single-instance databases. Grid Infrastructure, Oracle Restart, RAC, and Data Guard require an `srvctl`/role-aware coordinated workflow and are rejected.

## Safety properties

- `--help` is side-effect free and works without Oracle configuration.
- RU and OJVM directories are classified from their README content; an OJVM from a different release is not selected.
- The cloned Home retains `.patch_storage`.
- `/etc/oratab` is backed up and updated by exact field matching while preserving its existing inode ownership and mode.
- Switch state persists the old Home, new Home, backup path, and database list.
- A failed database switch triggers automatic rollback. `--rollback` also works in a fresh process while the saved phase is `SWITCHING` or `SWITCHED`.
- Once `datapatch` starts, automatic Home-only rollback is blocked because SQL patch state must be rolled back with Oracle's documented coordinated procedure.
- `datapatch` is bounded by a timeout and must finish successfully before a success report is generated.
- Production patching never deletes the previous Home automatically.
- Cleanup canonicalizes and validates paths, rejects active/current Homes, checks running processes, detaches through Oracle Inventory, and requires confirmation.
- Lock and state files are private to the Oracle user.

## Requirements

- Bash 4.3 or newer
- Oracle Database 19c, standalone single-instance topology
- Script executed as the configured Oracle software owner
- Writable Oracle base, central inventory, log directory, and `/etc/oratab`
- Commands: `awk`, `find`, `grep`, `realpath`, `rsync`, `stdbuf`, `timeout`, `unzip`
- Sufficient disk space for a complete Oracle Home clone plus a safety margin

The script deliberately refuses Grid Infrastructure/Oracle Restart and active Data Guard configurations.

## Patch directory

Set `PATCH_BASE_DIR_BASE` in `~/.patchrc`. With `USE_HOSTNAME_DIR=true`, patches are read from a hostname subdirectory:

```text
/work/dba/patching/<hostname>/
├── 3XXXXXXXX/                  # Database RU; README identifies it as an RU
├── 3YYYYYYYY/                  # Optional matching OJVM patch
└── p6880880_190000_Linux-x86-64.zip   # Optional OPatch update
```

Do not place unrelated numeric directories in the patch directory.

## Setup

```bash
chmod 750 oracle_oop_patching_2.sh
./oracle_oop_patching_2.sh --create-config
chmod 600 ~/.patchrc
vi ~/.patchrc
./oracle_oop_patching_2.sh --status
```

`--create-config` refuses to overwrite an existing `~/.patchrc`.

Important configuration values:

```bash
PATCH_BASE_DIR_BASE="/work/dba/patching"
USE_HOSTNAME_DIR="true"
ORACLE_BASE="/oracle"
CURRENT_ORACLE_HOME="/oracle/19"
INVENTORY_LOC="/oracle/oraInventory"
LOGDIR="/work/dba/patching/logs"
REQUIRED_USER="ora19"
DATAPATCH_TIMEOUT=7200
AUTO_CLEANUP_DAYS=30
KEEP_HOMES=2
DRY_RUN="false"
UNATTENDED_MODE="false"
DEFAULT_MODE="interactive"
```

## Usage

```bash
# Read-only overview
./oracle_oop_patching_2.sh --status

# Validate the plan without changing files, inventory, databases, or oratab
# Set DRY_RUN="true" in ~/.patchrc first
./oracle_oop_patching_2.sh --prod

# Prepare, clone, register, and patch a new Home; databases are not switched
./oracle_oop_patching_2.sh --test

# Full production switch; interactive confirmation by default
./oracle_oop_patching_2.sh --prod

# Explicit pre-datapatch rollback using the persisted state file
./oracle_oop_patching_2.sh --rollback

# Review eligible old Homes, then confirm each cleanup
./oracle_oop_patching_2.sh --cleanup

# Detach and remove one specific eligible Home
./oracle_oop_patching_2.sh --cleanup /oracle/19_old_home
```

### Mode semantics

| Mode | Files/inventory changed | Databases switched | Old Home deleted |
|---|---:|---:|---:|
| `--status` | No | No | No |
| `DRY_RUN=true` | No | No | No |
| `--test` | Yes: new Home is cloned, registered, and patched | No | No |
| `--prod` | Yes | Yes | Never automatically |
| `--rollback` | Restores saved `oratab` state only before `datapatch` starts | Yes, back to old Home | No |
| `--cleanup` | Detaches and removes only after checks/confirmation | No | Yes |

Listener processes are not restarted automatically because listener names and ownership vary. Verify listener ownership, service registration, connectivity, and application smoke tests after a switch or pre-datapatch rollback. After `datapatch` starts, use the Oracle release-specific SQL patch rollback/recovery procedure rather than switching Homes blindly.

## Verification

The repository includes Oracle-independent regression tests for CLI behavior, lock ownership, exact `oratab` mutation, rollback-state persistence, cleanup retention/guards, datapatch error propagation, and JSON report escaping.

```bash
bash -n oracle_oop_patching_2.sh tests/test_cli.sh tests/test_logic.sh
shellcheck -x -S warning oracle_oop_patching_2.sh tests/test_cli.sh tests/test_logic.sh
bash tests/test_cli.sh
bash tests/test_logic.sh
```

These tests do not replace a staging run against a real Oracle Home and database. Before production, exercise `--test`, a controlled `--prod`, `datapatch` verification, application connectivity, automatic rollback from an induced pre-datapatch switch failure, and the Oracle-documented post-datapatch recovery procedure on a representative non-production host.
