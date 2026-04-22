#!/usr/bin/env bash
# =============================================================================
# lib/log.sh - Unified Logging Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: log_debug, log_info, log_warn, log_error, log_success, die
# Depends on: LOGDIR, LOGFILE, LOG_LEVEL (set in config.sh)
# =============================================================================

# Guard against double-sourcing
[[ -n "${_LIB_LOG_SH:-}" ]] && return 0
readonly _LIB_LOG_SH=1

# ---------------------------------------------------------------------------
# Color constants (no-op if stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  readonly _CLR_RED='\033[0;31m'
  readonly _CLR_GREEN='\033[0;32m'
  readonly _CLR_YELLOW='\033[0;33m'
  readonly _CLR_BLUE='\033[0;34m'
  readonly _CLR_CYAN='\033[0;36m'
  readonly _CLR_BOLD='\033[1m'
  readonly _CLR_NC='\033[0m'
else
  readonly _CLR_RED='' _CLR_GREEN='' _CLR_YELLOW=''
  readonly _CLR_BLUE='' _CLR_CYAN='' _CLR_BOLD='' _CLR_NC=''
fi

# ---------------------------------------------------------------------------
# Log level numeric mapping
# ---------------------------------------------------------------------------
_log_level_num() {
  case "${1:-INFO}" in
    DEBUG)   echo 0 ;;
    INFO)    echo 1 ;;
    WARN)    echo 2 ;;
    ERROR)   echo 3 ;;
    SUCCESS) echo 1 ;;
    *)       echo 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Core log function
# Format: YYYY-MM-DD HH:MM:SS [LEVEL] [PHASE] message
# ---------------------------------------------------------------------------
log() {
  local level="${1:-INFO}"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # Level filter
  local current_level
  current_level=$(_log_level_num "${LOG_LEVEL:-INFO}")
  local msg_level
  msg_level=$(_log_level_num "${level}")

  [[ ${msg_level} -lt ${current_level} ]] && return 0

  # Color by level
  local color="${_CLR_NC}"
  case "${level}" in
    WARN)    color="${_CLR_YELLOW}" ;;
    ERROR)   color="${_CLR_RED}" ;;
    SUCCESS) color="${_CLR_GREEN}" ;;
    DEBUG)   color="${_CLR_CYAN}" ;;
    INFO)    color="${_CLR_NC}" ;;
  esac

  # Phase tag (optional global CURRENT_PHASE)
  local phase_tag=""
  [[ -n "${CURRENT_PHASE:-}" ]] && phase_tag="[${CURRENT_PHASE}] "

  local formatted="${timestamp} [${level}] ${phase_tag}${message}"

  # Ensure log directory and file
  if [[ -n "${LOGDIR:-}" ]] && [[ ! -d "${LOGDIR}" ]]; then
    mkdir -p "${LOGDIR}" 2>/dev/null || true
  fi

  if [[ -n "${LOGFILE:-}" ]]; then
    # Write plain (no color) to log file
    echo "${timestamp} [${level}] ${phase_tag}${message}" >> "${LOGFILE}" 2>/dev/null || true
    chmod 640 "${LOGFILE}" 2>/dev/null || true
  fi

  # Write colored to stdout (errors to stderr)
  if [[ "${level}" == "ERROR" ]]; then
    echo -e "${color}${formatted}${_CLR_NC}" >&2
  else
    echo -e "${color}${formatted}${_CLR_NC}"
  fi
}

# ---------------------------------------------------------------------------
# Convenience wrappers
# ---------------------------------------------------------------------------
log_debug()   { log "DEBUG"   "$*"; }
log_info()    { log "INFO"    "$*"; }
log_warn()    { log "WARN"    "$*"; }
log_error()   { log "ERROR"   "$*"; }
log_success() { log "SUCCESS" "$*"; }

# ---------------------------------------------------------------------------
# Section header helper
# ---------------------------------------------------------------------------
log_section() {
  local title="$*"
  log "INFO" "${_CLR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}"
  log "INFO" "${_CLR_BOLD}${title}${_CLR_NC}"
  log "INFO" "${_CLR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}"
}

# ---------------------------------------------------------------------------
# Fatal error: log, register error, exit
# ---------------------------------------------------------------------------
die() {
  log_error "FATAL: $*"
  # Register in global error list if available
  if declare -f add_error &>/dev/null; then
    add_error "$*"
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# Preflight summary box
# ---------------------------------------------------------------------------
log_preflight_summary() {
  echo ""
  echo -e "${_CLR_CYAN}╔══════════════════════════════════════════════════════════════╗${_CLR_NC}"
  echo -e "${_CLR_CYAN}║${_CLR_NC}  ${_CLR_BOLD}Oracle 19c OOP Patching Framework v3.0 — Preflight${_CLR_NC}         ${_CLR_CYAN}║${_CLR_NC}"
  echo -e "${_CLR_CYAN}╠══════════════════════════════════════════════════════════════╣${_CLR_NC}"
  printf "  %-22s %s\n" "Host:"          "$(hostname)"
  printf "  %-22s %s\n" "User:"          "${REQUIRED_USER:-?}"
  printf "  %-22s %s\n" "Mode:"          "${MODE:-?}"
  printf "  %-22s %s\n" "Current Home:"  "${CURRENT_ORACLE_HOME:-?}"
  printf "  %-22s %s\n" "Oracle Base:"   "${ORACLE_BASE:-?}"
  printf "  %-22s %s\n" "Patch Dir:"     "${PATCH_BASE_DIR:-?}"
  printf "  %-22s %s\n" "Log Dir:"       "${LOGDIR:-?}"
  printf "  %-22s %s\n" "Dry-Run:"       "${DRY_RUN:-false}"
  echo -e "${_CLR_CYAN}╚══════════════════════════════════════════════════════════════╝${_CLR_NC}"
  echo ""
}
