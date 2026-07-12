#!/usr/bin/env bash
set -euo pipefail

SCRIPT=$(realpath "${1:-./oracle_oop_patching_2.sh}")
TMP=$(mktemp -d)
trap 'rm -R -- "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

if ! env -i HOME="${TMP}" PATH="${PATH}" TERM=dumb bash "${SCRIPT}" --help >"${TMP}/help.out" 2>"${TMP}/help.err"; then
    fail "--help must work before Oracle configuration exists"
fi
if grep -q '^Unknown$\|No config file\|Konfigurationsvalidierung' "${TMP}/help.out"; then
    fail "--help must not initialize Oracle or emit stray version output"
fi
pass "help is side-effect free"

if env -i HOME="${TMP}" PATH="${PATH}" TERM=dumb bash "${SCRIPT}" --bogus >"${TMP}/bogus.out" 2>"${TMP}/bogus.err"; then
    fail "unknown options must return non-zero"
fi
pass "unknown option is rejected"

if env -i HOME="${TMP}" PATH="${PATH}" TERM=dumb bash "${SCRIPT}" --status extra >"${TMP}/extra.out" 2>"${TMP}/extra.err"; then
    fail "unexpected positional arguments must return non-zero"
fi
pass "unexpected arguments are rejected"

config_home="${TMP}/config-home"
mkdir -p "${config_home}"
env -i HOME="${config_home}" PATH="${PATH}" TERM=dumb bash "${SCRIPT}" --create-config >/dev/null
cp "${config_home}/.patchrc" "${TMP}/patchrc.original"
if env -i HOME="${config_home}" PATH="${PATH}" TERM=dumb bash "${SCRIPT}" --create-config >"${TMP}/overwrite.out" 2>&1; then
    fail "--create-config must refuse to overwrite an existing config"
fi
cmp -s "${config_home}/.patchrc" "${TMP}/patchrc.original" || fail "existing config was modified"
pass "existing config is preserved"

chmod 666 "${config_home}/.patchrc"
if env -i HOME="${config_home}" PATH="${PATH}" TERM=dumb bash "${SCRIPT}" --status >"${TMP}/unsafe-config.out" 2>&1; then
    fail "group/other-writable config was accepted"
fi
grep -Fq 'must not be writable by group or others' "${TMP}/unsafe-config.out" || fail "unsafe config rejection was unclear"
pass "unsafe config permissions are rejected"
