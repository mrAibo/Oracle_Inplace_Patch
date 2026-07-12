#!/usr/bin/env bash
# Oracle-server validation harness for oracle_oop_patching_2.sh
set -euo pipefail
umask 077

SELF_NAME=$(basename -- "$0")
readonly SELF_NAME
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly SELF_DIR
PATCH_SCRIPT="${SELF_DIR}/oracle_oop_patching_2.sh"
REPORT_DIR="${PWD}/validation_reports"
MODE="preflight"

usage() {
    cat <<EOF
Usage: ${SELF_NAME} [OPTIONS]

Oracle-server companion test for oracle_oop_patching_2.sh.

Modes:
  --preflight          default: read-only Oracle preflight; writes logs only
  --prepare            run preflight, require PREPARE confirmation, then invoke --test

Options:
  --script PATH        patch script path (default: sibling oracle_oop_patching_2.sh)
  --report-dir DIR     validation transcript directory (default: ./validation_reports)
  -h, --help           show this help without creating files

The default mode does not clone a Home, change inventory/oratab, stop a database,
run datapatch, or perform cleanup. --prepare creates and patches a new Home through
the main script's --test mode, but it does not switch databases.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --preflight)
                MODE="preflight"
                shift
                ;;
            --prepare)
                MODE="prepare"
                shift
                ;;
            --script)
                [[ $# -ge 2 && -n "$2" ]] || { printf '%s\n' '--script requires PATH' >&2; return 2; }
                PATCH_SCRIPT="$2"
                shift 2
                ;;
            --report-dir)
                [[ $# -ge 2 && -n "$2" ]] || { printf '%s\n' '--report-dir requires DIR' >&2; return 2; }
                REPORT_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done
}

validate_script_file() {
    [[ ! -L "${PATCH_SCRIPT}" ]] || fail "Patch script must not be a symlink"
    PATCH_SCRIPT=$(realpath -e -- "${PATCH_SCRIPT}") || fail "Patch script not found: ${PATCH_SCRIPT}"
    [[ -f "${PATCH_SCRIPT}" && -r "${PATCH_SCRIPT}" ]] || fail "Patch script is not a readable regular file: ${PATCH_SCRIPT}"

    local mode script_uid current_uid
    mode=$(stat -c '%a' "${PATCH_SCRIPT}") || fail "Could not inspect patch script permissions"
    script_uid=$(stat -c '%u' "${PATCH_SCRIPT}") || fail "Could not inspect patch script owner"
    current_uid=$(id -u)
    [[ "${script_uid}" == "0" || "${script_uid}" == "${current_uid}" ]] || fail "Patch script must be owned by root or the current user"
    (( (8#${mode} & 8#22) == 0 )) || fail "Patch script must not be writable by group or others"

    bash -n "${PATCH_SCRIPT}" || fail "Patch script has Bash syntax errors"
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -x -S warning "${PATCH_SCRIPT}" || fail "Patch script failed ShellCheck"
    else
        printf 'WARN: shellcheck is not installed; static lint was skipped\n'
    fi
}

run_preflight() {
    printf '%s\n' '=== ORACLE PATCH SERVER PREFLIGHT ==='
    printf 'Host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'User: %s\n' "$(id -un)"
    printf 'Patch script: %s\n' "${PATCH_SCRIPT}"
    printf '%s\n' 'Scope: no clone, inventory/oratab mutation, database stop, datapatch, or cleanup'

    validate_script_file

    bash -c '
        set -euo pipefail
        source "$1"
        initialize
        UNATTENDED_MODE=true
        check_prerequisites
        check_supported_topology
        select_patch
        validate_patch_contents
        read_databases_from_oratab "${CURRENT_ORACLE_HOME}" DATABASES
        [[ ${#DATABASES[@]} -gt 0 ]] || die "No active databases found for ${CURRENT_ORACLE_HOME}"
        database_health_check "server-preflight" "${CURRENT_ORACLE_HOME}"
        check_errors
    ' _ "${PATCH_SCRIPT}" || fail "Oracle server preflight failed; inspect this report and the main script logs"

    printf '%s\n' 'PRECHECK PASSED'
}

run_prepare() {
    run_preflight
    printf '\n%s\n' 'Preparation mode will clone, register, and patch a new Oracle Home.'
    printf '%s\n' 'It will NOT switch databases or run datapatch.'
    printf '%s' 'Type PREPARE to continue: '

    local confirmation=""
    if ! IFS= read -r confirmation || [[ "${confirmation}" != "PREPARE" ]]; then
        printf '%s\n' 'Preparation cancelled; no --test invocation was made.'
        return 0
    fi

    printf '%s\n' '=== RUNNING MAIN SCRIPT --test ==='
    bash "${PATCH_SCRIPT}" --test || fail "Main script --test failed"
    printf '%s\n' 'PREPARATION TEST PASSED'
}

main() {
    parse_args "$@"

    mkdir -p -- "${REPORT_DIR}" || fail "Could not create report directory: ${REPORT_DIR}"
    REPORT_DIR=$(realpath -e -- "${REPORT_DIR}") || fail "Could not resolve report directory"
    local report_file report_prefix
    report_prefix="${REPORT_DIR}/oracle_validation_$(date +%Y%m%d_%H%M%S)_"
    report_file=$(mktemp "${report_prefix}XXXXXX.log") || fail "Could not create a private validation report in ${REPORT_DIR}"
    chmod 600 "${report_file}" || fail "Could not secure report: ${report_file}"

    local primary_rc
    set +e
    (
        set -e
        if [[ "${MODE}" == "prepare" ]]; then
            run_prepare
        else
            run_preflight
        fi
    ) >>"${report_file}" 2>&1
    primary_rc=$?
    set -e

    cat -- "${report_file}"
    printf 'Report: %s\n' "${report_file}"
    [[ ${primary_rc} -eq 0 ]] || return "${primary_rc}"
}

main "$@"
