#!/usr/bin/env bash
# shellcheck disable=SC2034 # globals are consumed by functions sourced below
set -euo pipefail

SCRIPT=$(realpath "${1:-./oracle_oop_patching_2.sh}")
TMP=$(mktemp -d)

# shellcheck source=/dev/null
source "${SCRIPT}"
trap 'rm -R -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# A losing process must never remove a lock owned by a running process.
foreign_lock="${TMP}/foreign.lock"
mkdir "${foreign_lock}"
sleep 30 &
holder_pid=$!
printf '%s\n' "${holder_pid}" > "${foreign_lock}/pid"
set +e
bash -c 'source "$1"; LOCK_DIR="$2"; LOCK_PID_FILE="${LOCK_DIR}/pid"; acquire_lock' _ "${SCRIPT}" "${foreign_lock}" >"${TMP}/lock.out" 2>&1
lock_rc=$?
set -e
kill "${holder_pid}" 2>/dev/null || true
wait "${holder_pid}" 2>/dev/null || true
[[ ${lock_rc} -ne 0 ]] || fail "second process unexpectedly acquired foreign lock"
[[ -d "${foreign_lock}" ]] || fail "second process removed foreign lock"
pass "foreign lock is preserved"

# oratab replacement must update field 2 exactly, not regex/substrings/comments.
cat > "${TMP}/oratab" <<'EOF'
DB1:/oracle/19.0:Y
DB2:/oracle/19x0:Y
# DB3:/oracle/19.0:Y
EOF
update_oratab_home "${TMP}/oratab" "/oracle/19.0" "/oracle/19.1" "${TMP}/oratab.new"
grep -Fxq 'DB1:/oracle/19.1:Y' "${TMP}/oratab.new" || fail "exact Oracle Home was not updated"
grep -Fxq 'DB2:/oracle/19x0:Y' "${TMP}/oratab.new" || fail "similar Oracle Home was changed"
grep -Fxq '# DB3:/oracle/19.0:Y' "${TMP}/oratab.new" || fail "comment was changed"
pass "oratab update is exact"

# Commented-out oratab entries must never be treated as active databases.
cat > "${TMP}/oratab.read" <<'EOF'
DB1:/oracle/19.0:Y
#DB2:/oracle/19.0:Y
# DB3:/oracle/19.0:Y
DB#4:/oracle/19.0:Y
DB5:/oracle/other:Y
*:/oracle/19.0:N
EOF
detected_databases=()
read_databases_from_oratab "/oracle/19.0" detected_databases "${TMP}/oratab.read"
[[ "${detected_databases[*]}" == "DB1 DB#4" ]] || fail "commented or unrelated oratab entries were included: ${detected_databases[*]}"
pass "commented oratab databases are ignored"

# Unattended patch selection must use the highest RU version, not the highest patch ID.
PATCH_BASE_DIR="${TMP}/patches"
mkdir -p "${PATCH_BASE_DIR}/99999999" "${PATCH_BASE_DIR}/11111111" "${PATCH_BASE_DIR}/22222222"
printf 'Oracle Database Release Update 19.20.0.0.0\n' > "${PATCH_BASE_DIR}/99999999/README.txt"
printf 'Oracle Database Release Update 19.25.0.0.0\n' > "${PATCH_BASE_DIR}/11111111/README.txt"
printf 'OJVM Release Update 19.25.0.0.0\n' > "${PATCH_BASE_DIR}/22222222/README.txt"
UNATTENDED_MODE=true
select_patch >/dev/null
[[ "${RU_PATCH_NUM}" == "11111111" && "${NEW_PATCH_VERSION}" == "19.25.0.0.0" ]] || fail "unattended mode selected the wrong RU"
[[ "${OJVM_PATCH_NUM}" == "22222222" ]] || fail "matching OJVM was not selected"
pass "patch selection is version-aware"

# Rollback state must survive a fresh process and restore every database.
mkdir -p "${TMP}/old" "${TMP}/new"
: > "${TMP}/oratab.backup"
STATE_FILE="${TMP}/state"
CURRENT_ORACLE_HOME="${TMP}/old"
NEW_ORACLE_HOME="${TMP}/new"
ORATAB_BACKUP="${TMP}/oratab.backup"
PATCH_PHASE="SWITCHING"
DATABASES=(DB1 DB2)
save_switch_state
OLD_ORACLE_HOME=""; NEW_ORACLE_HOME=""; ORATAB_BACKUP=""; PATCH_PHASE=""; DATABASES=()
load_switch_state
[[ "${OLD_ORACLE_HOME}" == "${TMP}/old" ]] || fail "old home was not restored from state"
[[ "${NEW_ORACLE_HOME}" == "${TMP}/new" ]] || fail "new home was not restored from state"
[[ "${DATABASES[*]}" == "DB1 DB2" ]] || fail "database list was not restored from state"
[[ "${PATCH_PHASE}" == "SWITCHING" ]] || fail "patch phase was not restored from state"
pass "rollback state round-trip"

# Home-only rollback must be blocked once datapatch has started.
PATCH_PHASE="DATAPATCH_STARTED"
save_switch_state
set +e
bash -c 'source "$1"; STATE_FILE="$2"; LOCK_DIR="$3"; LOCK_PID_FILE="${LOCK_DIR}/pid"; UNATTENDED_MODE=true; rollback' \
    _ "${SCRIPT}" "${STATE_FILE}" "${TMP}/rollback.lock" >"${TMP}/post-datapatch-rollback.out" 2>&1
post_datapatch_rc=$?
set -e
[[ ${post_datapatch_rc} -ne 0 ]] || fail "post-datapatch Home-only rollback was accepted"
grep -Fq 'blocked after datapatch began' "${TMP}/post-datapatch-rollback.out" || fail "post-datapatch rollback rejection was unclear"
pass "post-datapatch Home rollback is blocked"

# KEEP_HOMES must preserve the newest homes and only nominate the old one.
INVENTORY_LOC="${TMP}/inventory"
ORACLE_BASE="${TMP}/homes"
mkdir -p "${INVENTORY_LOC}/ContentsXML" \
    "${TMP}/homes/new/bin" "${TMP}/homes/rollback/bin" "${TMP}/homes/old/bin"
: > "${TMP}/homes/new/bin/oracle"
: > "${TMP}/homes/rollback/bin/oracle"
: > "${TMP}/homes/old/bin/oracle"
touch -d '1 day ago' "${TMP}/homes/new"
touch -d '10 days ago' "${TMP}/homes/rollback"
touch -d '40 days ago' "${TMP}/homes/old"
cat > "${INVENTORY_LOC}/ContentsXML/inventory.xml" <<EOF
<HOME LOC="${TMP}/homes/new"/>
<HOME LOC="${TMP}/homes/rollback"/>
<HOME LOC="${TMP}/homes/old"/>
EOF
CLEANUP_TMPFILE="${TMP}/candidates"
KEEP_HOMES=2
AUTO_CLEANUP_DAYS=30
find_old_homes >/dev/null
[[ "$(cat "${CLEANUP_TMPFILE}")" == "${TMP}/homes/old" ]] || fail "cleanup retention selected the wrong homes"
pass "cleanup retention keeps newest homes"

# A datapatch child failure must fail the aggregate phase.
run_datapatch_single() { [[ "$1" != "FAILDB" ]]; }
DATABASES=(OKDB FAILDB)
if run_datapatch >/dev/null 2>&1; then
    fail "datapatch aggregate hid a child failure"
fi
pass "datapatch failure propagates"

# JSON reports must remain valid when paths or metadata contain JSON metacharacters.
LOGDIR="${TMP}/reports"
mkdir -p "${LOGDIR}"
TIMESTAMP="json_test"
CURRENT_ORACLE_HOME='old\\home"quoted'
NEW_ORACLE_HOME=$'new"home\nline'
RU_PATCH_NUM='ru"patch'
NEW_PATCH_VERSION='19.0\\test'
OJVM_PATCH_NUM='ojvm"patch'
DATABASES=('DB"1')
generate_final_report >/dev/null
python3 - "${LOGDIR}/patch_report_${TIMESTAMP}.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["new_home"] == 'new"home\nline'
assert report["databases"] == ['DB"1']
PY
pass "JSON report escapes dynamic values"

# Cleanup must refuse the configured current home before any deletion.
mkdir -p "${TMP}/base/current/bin"
: > "${TMP}/base/current/bin/oracle"
set +e
bash -c 'source "$1"; ORACLE_BASE="$2"; CURRENT_ORACLE_HOME="$2/current"; REQUIRED_USER="$(id -un)"; AUTO_CLEANUP_DAYS=7; cleanup_single_home "$2/current" --auto' _ "${SCRIPT}" "${TMP}/base" >"${TMP}/cleanup.out" 2>&1
cleanup_rc=$?
set -e
[[ ${cleanup_rc} -ne 0 ]] || fail "cleanup accepted CURRENT_ORACLE_HOME"
[[ -f "${TMP}/base/current/bin/oracle" ]] || fail "cleanup deleted CURRENT_ORACLE_HOME"
pass "current home cleanup is blocked"

# A rejected cleanup candidate must not prevent later candidates from being checked.
CLEANUP_TMPFILE="${TMP}/cleanup-batch"
printf '%s\n' "${TMP}/bad-home" "${TMP}/good-home" > "${CLEANUP_TMPFILE}"
: > "${TMP}/cleanup-calls"
acquire_lock() { :; }
cleanup_single_home() {
    printf '%s\n' "$1" >> "${TMP}/cleanup-calls"
    [[ "$1" != "${TMP}/bad-home" ]]
}
set +e
( auto_cleanup ) >"${TMP}/cleanup-batch.out" 2>&1
batch_rc=$?
set -e
[[ ${batch_rc} -ne 0 ]] || fail "cleanup batch hid a safety-check failure"
expected_cleanup_calls=$(printf '%s\n%s' "${TMP}/bad-home" "${TMP}/good-home")
[[ "$(cat "${TMP}/cleanup-calls")" == "${expected_cleanup_calls}" ]] || fail "cleanup batch stopped before checking all candidates"
pass "cleanup batch continues after guarded rejection"
