#!/usr/bin/env bash
# =============================================================================
# lib/lock.sh - Process Locking Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: acquire_lock, release_lock
# Depends on: log.sh
# =============================================================================

[[ -n "${_LIB_LOCK_SH:-}" ]] && return 0
readonly _LIB_LOCK_SH=1

readonly LOCK_DIR="/tmp/oracle_oop_patching.lock"
readonly LOCK_PID_FILE="${LOCK_DIR}/pid"
readonly LOCK_INFO_FILE="${LOCK_DIR}/info"

# ---------------------------------------------------------------------------
# acquire_lock
# Creates lock directory atomically (mkdir is atomic on most filesystems).
# If lock exists, checks if owning PID is still alive.
# ---------------------------------------------------------------------------
acquire_lock() {
  if [[ -d "${LOCK_DIR}" ]]; then
    local locked_pid=""
    [[ -f "${LOCK_PID_FILE}" ]] && locked_pid=$(cat "${LOCK_PID_FILE}" 2>/dev/null || echo "")

    if [[ -n "${locked_pid}" ]] && kill -0 "${locked_pid}" 2>/dev/null; then
      local lock_info=""
      [[ -f "${LOCK_INFO_FILE}" ]] && lock_info=$(cat "${LOCK_INFO_FILE}" 2>/dev/null || echo "")
      log_error "Skript läuft bereits (PID: ${locked_pid})"
      [[ -n "${lock_info}" ]] && log_error "Lock-Info: ${lock_info}"
      log_error "Falls der Prozess nicht mehr aktiv ist: rm -rf ${LOCK_DIR}"
      exit 1
    else
      log_warn "Verwaistes Lock gefunden (PID ${locked_pid} nicht mehr aktiv) - wird entfernt"
      rm -rf "${LOCK_DIR}"
    fi
  fi

  mkdir "${LOCK_DIR}" 2>/dev/null || die "Konnte Lock-Verzeichnis nicht erstellen: ${LOCK_DIR}"
  echo "$$" > "${LOCK_PID_FILE}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | User: $(whoami) | Mode: ${MODE:-unknown} | Host: $(hostname)" > "${LOCK_INFO_FILE}"

  log_debug "Lock gesetzt (PID: $$, Dir: ${LOCK_DIR})"
}

# ---------------------------------------------------------------------------
# release_lock
# Wird normalerweise über den EXIT-Trap in main.sh aufgerufen.
# ---------------------------------------------------------------------------
release_lock() {
  if [[ -d "${LOCK_DIR}" ]]; then
    local pid_in_lock
    pid_in_lock=$(cat "${LOCK_PID_FILE}" 2>/dev/null || echo "")
    if [[ "${pid_in_lock}" == "$$" ]]; then
      rm -f "${LOCK_PID_FILE}" "${LOCK_INFO_FILE}"
      rmdir "${LOCK_DIR}" 2>/dev/null || true
      log_debug "Lock freigegeben (PID: $$)"
    fi
  fi
}
