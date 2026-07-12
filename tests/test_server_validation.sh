#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
VALIDATOR="${ROOT}/oracle_server_validation.sh"
TMP=$(mktemp -d)
trap 'rm -R -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

[[ -x "${VALIDATOR}" ]] || fail "server validator is missing or not executable"

"${VALIDATOR}" --report-dir "${TMP}/help-reports" --help >"${TMP}/help.out"
[[ ! -e "${TMP}/help-reports" ]] || fail "help created a report directory"
grep -Fq 'default: read-only Oracle preflight' "${TMP}/help.out" || fail "help does not describe the safe default"
grep -Fq -- '--prepare' "${TMP}/help.out" || fail "help does not describe preparation mode"
pass "server validator help is side-effect free"

if "${VALIDATOR}" --bogus >"${TMP}/bogus.out" 2>&1; then
    fail "unknown server validator option was accepted"
fi
pass "server validator rejects unknown options"

CALL_LOG="${TMP}/calls.log"
export CALL_LOG
cat >"${TMP}/fake_patch.sh" <<'FAKE'
#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
if [[ "${1:-}" == "--test" ]]; then
    printf '%s\n' execute-test >>"${CALL_LOG}"
    exit 0
fi
initialize() { printf '%s\n' initialize >>"${CALL_LOG}"; }
check_prerequisites() { printf '%s\n' prerequisites >>"${CALL_LOG}"; }
check_supported_topology() { printf '%s\n' topology >>"${CALL_LOG}"; [[ "${FAIL_STAGE:-}" != topology ]]; }
select_patch() { printf '%s\n' patch-selection >>"${CALL_LOG}"; }
validate_patch_contents() { printf '%s\n' patch-validation >>"${CALL_LOG}"; }
read_databases_from_oratab() { local -n out=$2; out=(DB1); printf '%s\n' database-discovery >>"${CALL_LOG}"; }
database_health_check() { printf '%s\n' health-check >>"${CALL_LOG}"; }
check_errors() { printf '%s\n' error-summary >>"${CALL_LOG}"; }
CURRENT_ORACLE_HOME=/fake/oracle/19
UNATTENDED_MODE=false
DATABASES=()
FAKE
chmod 755 "${TMP}/fake_patch.sh"

"${VALIDATOR}" --script "${TMP}/fake_patch.sh" --report-dir "${TMP}/reports" >"${TMP}/preflight.out"
expected=$'initialize\nprerequisites\ntopology\npatch-selection\npatch-validation\ndatabase-discovery\nhealth-check\nerror-summary'
[[ "$(cat "${CALL_LOG}")" == "${expected}" ]] || fail "preflight call sequence was incomplete"
! grep -Fq 'execute-test' "${CALL_LOG}" || fail "default preflight invoked mutation mode"
grep -Fq 'PRECHECK PASSED' "${TMP}/preflight.out" || fail "preflight success was not reported"
compgen -G "${TMP}/reports/oracle_validation_*.log" >/dev/null || fail "validation report was not created"
pass "default server preflight is non-mutating"

: >"${CALL_LOG}"
if FAIL_STAGE=topology "${VALIDATOR}" --script "${TMP}/fake_patch.sh" --report-dir "${TMP}/reports" >"${TMP}/failed-preflight.out" 2>&1; then
    fail "failed Oracle preflight returned success"
fi
! grep -Fq 'PRECHECK PASSED' "${TMP}/failed-preflight.out" || fail "failed Oracle preflight printed a success marker"
pass "server preflight propagates failures"

: >"${CALL_LOG}"
printf 'no\n' | "${VALIDATOR}" --prepare --script "${TMP}/fake_patch.sh" --report-dir "${TMP}/reports" >"${TMP}/cancel.out"
! grep -Fq 'execute-test' "${CALL_LOG}" || fail "cancelled preparation invoked --test"
pass "server preparation requires exact confirmation"

: >"${CALL_LOG}"
printf 'PREPARE\n' | "${VALIDATOR}" --prepare --script "${TMP}/fake_patch.sh" --report-dir "${TMP}/reports" >"${TMP}/prepare.out"
grep -Fxq 'execute-test' "${CALL_LOG}" || fail "confirmed preparation did not invoke --test"
grep -Fq 'PREPARATION TEST PASSED' "${TMP}/prepare.out" || fail "preparation success was not reported"
pass "confirmed server preparation invokes main test mode"
