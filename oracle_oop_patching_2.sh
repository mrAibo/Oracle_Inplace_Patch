#!/usr/bin/env bash
# =============================================================================
# Oracle 19c Out-of-Place Patching Framework
# Version: 2.1.0
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================

readonly SCRIPT_VERSION="2.1.0"
SCRIPT_NAME=$(basename -- "$0")
readonly SCRIPT_NAME
readonly MIN_OPEN_FILES=4096
readonly MIN_CLEANUP_DAYS=7
readonly CLONE_TOLERANCE_PCT=5
readonly SPACE_BUFFER_FACTOR=1.5
readonly MAX_PARALLEL_DATAPATCH=4

# =============================================================================
# SECURE TEMPORARY FILES & LOCKING
# =============================================================================

# Set umask FIRST before any file creation
umask 077

LOCK_DIR="${LOCK_DIR:-}"
LOCK_PID_FILE=""
CLEANUP_TMPFILE=""
LOCK_ACQUIRED=false
LOCK_OWNER_BASHPID=""

# =============================================================================
# ERROR HANDLING
# =============================================================================

declare -a ERRORS=()

add_error() {
    ERRORS+=("$1")
}

check_errors() {
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        log_error "=== FEHLER ZUSAMMENFASSUNG ==="
        for err in "${ERRORS[@]}"; do
            log_error "  - ${err}"
        done
        return 1
    fi
    return 0
}

# =============================================================================
# CLEANUP & TRAP HANDLING
# =============================================================================

cleanup() {
    local exit_code=$?
    
    # Remove temp file
    [[ -n "${CLEANUP_TMPFILE:-}" && -f "${CLEANUP_TMPFILE}" ]] && rm -f "${CLEANUP_TMPFILE}"
    
    # Only the process that acquired the lock may release it.
    if [[ "${LOCK_ACQUIRED}" == "true" && "${BASHPID}" == "${LOCK_OWNER_BASHPID}" && -d "${LOCK_DIR}" ]]; then
        [[ -f "${LOCK_PID_FILE}" ]] && rm -f "${LOCK_PID_FILE}"
        rmdir "${LOCK_DIR}" 2>/dev/null || true
    fi
    
    if [[ ${exit_code} -ne 0 && ${exit_code} -ne 130 ]]; then
        log_error "Skript wurde mit Fehler beendet (Exit Code: ${exit_code})"
        check_errors
    fi
}

trap cleanup EXIT
trap 'log_warn "Abbruch durch Benutzer"; exit 130' INT TERM

# =============================================================================
# AUTO-DETECT ORACLE INVENTORY
# =============================================================================

detect_oracle_inventory() {
    local inventory_loc=""
    if [[ -f /etc/oraInst.loc ]]; then
        inventory_loc=$(awk -F'=' '/inventory_loc/{print $2}' /etc/oraInst.loc | tr -d ' ')
    fi
    echo "${inventory_loc}"
}

AUTO_INVENTORY_LOC=$(detect_oracle_inventory)

# =============================================================================
# CONFIGURATION - DEFAULTS
# =============================================================================

PATCHRC="${HOME}/.patchrc"

# Basis-Verzeichnisse
PATCH_BASE_DIR_BASE="${PATCH_BASE_DIR_BASE:-/work/dba/patching}"
USE_HOSTNAME_DIR="${USE_HOSTNAME_DIR:-false}"
ORACLE_BASE="${ORACLE_BASE:-/oracle}"
CURRENT_ORACLE_HOME="${CURRENT_ORACLE_HOME:-/oracle/19}"
INVENTORY_LOC="${INVENTORY_LOC:-${AUTO_INVENTORY_LOC:-/oracle/oraInventory}}"
LOGDIR="${LOGDIR:-/work/dba/patching/logs}"
PATCH_BASE_DIR="${PATCH_BASE_DIR_BASE}"

# Auto-Cleanup
AUTO_CLEANUP_DAYS="${AUTO_CLEANUP_DAYS:-30}"
KEEP_HOMES="${KEEP_HOMES:-2}"

# Modes
DEFAULT_MODE="${DEFAULT_MODE:-interactive}"
UNATTENDED_MODE="${UNATTENDED_MODE:-false}"

# User
REQUIRED_USER="${REQUIRED_USER:-ora19}"

# Timestamp & Logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGFILE=""
STATE_FILE=""
DRY_RUN="${DRY_RUN:-false}"
DATAPATCH_TIMEOUT="${DATAPATCH_TIMEOUT:-7200}"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Log levels: DEBUG=0, INFO=1, WARN=2, ERROR=3
LOG_LEVEL="${LOG_LEVEL:-1}"

log_level_num() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;
    esac
}

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Level filter
    if [[ $(log_level_num "${level}") -lt $(log_level_num "${LOG_LEVEL}") ]]; then
        return 0
    fi

    if [[ -z "${LOGFILE:-}" ]]; then
        echo -e "${timestamp} [${level}] ${message}"
        return 0
    fi
    
    # Ensure log directory exists
    if [[ ! -d "${LOGDIR}" ]]; then
        mkdir -p "${LOGDIR}" 2>/dev/null || {
            echo -e "${timestamp} [${level}] ${message}"
            return 0
        }
    fi
    
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOGFILE}"
    
    # Secure log file
    [[ -f "${LOGFILE}" ]] && chmod 640 "${LOGFILE}" 2>/dev/null || true
}

log_debug() { log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$*${NC}"; }

die() {
    log_error "$@"
    add_error "$*"
    exit 1
}

# =============================================================================
# CONFIG-FILE HANDLING
# =============================================================================

validate_config() {
    local errors=0

    [[ -z "${ORACLE_BASE}" ]] && { log_error "ORACLE_BASE nicht konfiguriert"; errors=$((errors + 1)); }
    [[ -z "${CURRENT_ORACLE_HOME}" ]] && { log_error "CURRENT_ORACLE_HOME nicht konfiguriert"; errors=$((errors + 1)); }
    [[ ! -d "${ORACLE_BASE}" ]] && { log_error "ORACLE_BASE existiert nicht: ${ORACLE_BASE}"; errors=$((errors + 1)); }
    [[ ! -d "${CURRENT_ORACLE_HOME}" ]] && { log_error "CURRENT_ORACLE_HOME existiert nicht: ${CURRENT_ORACLE_HOME}"; errors=$((errors + 1)); }

    [[ ! "${AUTO_CLEANUP_DAYS}" =~ ^[0-9]+$ ]] && { log_error "AUTO_CLEANUP_DAYS muss eine ganze Zahl sein"; errors=$((errors + 1)); }
    [[ ! "${KEEP_HOMES}" =~ ^[0-9]+$ || "${KEEP_HOMES}" -lt 1 ]] && { log_error "KEEP_HOMES muss mindestens 1 sein"; errors=$((errors + 1)); }
    [[ ! "${DATAPATCH_TIMEOUT}" =~ ^[0-9]+$ || "${DATAPATCH_TIMEOUT}" -lt 1 ]] && { log_error "DATAPATCH_TIMEOUT muss mindestens 1 sein"; errors=$((errors + 1)); }
    [[ ! "${DRY_RUN}" =~ ^(true|false)$ ]] && { log_error "DRY_RUN muss true oder false sein"; errors=$((errors + 1)); }
    [[ ! "${UNATTENDED_MODE}" =~ ^(true|false)$ ]] && { log_error "UNATTENDED_MODE muss true oder false sein"; errors=$((errors + 1)); }
    [[ ! "${DEFAULT_MODE}" =~ ^(interactive|test|prod)$ ]] && { log_error "DEFAULT_MODE muss interactive, test oder prod sein"; errors=$((errors + 1)); }

    if [[ "${AUTO_CLEANUP_DAYS}" =~ ^[0-9]+$ && ${AUTO_CLEANUP_DAYS} -lt ${MIN_CLEANUP_DAYS} ]]; then
        log_error "AUTO_CLEANUP_DAYS muss mindestens ${MIN_CLEANUP_DAYS} sein"
        errors=$((errors + 1))
    fi

    [[ ${errors} -gt 0 ]] && return 1
    return 0
}

load_config() {
    if [[ -f "${PATCHRC}" ]]; then
        [[ -O "${PATCHRC}" && ! -L "${PATCHRC}" ]] || die "Config must be an owned regular file, not a symlink: ${PATCHRC}"
        local config_mode
        config_mode=$(stat -c '%a' "${PATCHRC}") || die "Could not inspect config permissions: ${PATCHRC}"
        if (( (8#${config_mode} & 8#22) != 0 )); then
            die "Config must not be writable by group or others: ${PATCHRC}"
        fi

        # Syntax check before loading
        if ! bash -n "${PATCHRC}" 2>/dev/null; then
            die "Konfigurationsdatei ${PATCHRC} hat Syntaxfehler!"
        fi

        # shellcheck source=/dev/null
        source "${PATCHRC}"

        if [[ -z "${INVENTORY_LOC}" ]] && [[ -n "${AUTO_INVENTORY_LOC}" ]]; then
            INVENTORY_LOC="${AUTO_INVENTORY_LOC}"
        fi
    fi
}

create_default_config() {
    [[ ! -e "${PATCHRC}" ]] || die "Config already exists and will not be overwritten: ${PATCHRC}"

    local detected_inv=""
    if [[ -f /etc/oraInst.loc ]]; then
        detected_inv=$(awk -F'=' '/inventory_loc/{print $2}' /etc/oraInst.loc | tr -d ' ')
    fi

    cat > "${PATCHRC}" <<EOF
# Oracle Out-of-Place Patching Configuration
# Erstellt am: $(date)
# Version: ${SCRIPT_VERSION}

# ============================================================================
# PATCH VERZEICHNISSE
# ============================================================================

# Basis-Verzeichnis für Patches
PATCH_BASE_DIR_BASE="/work/dba/patching"

# Hostname-basierte Unterverzeichnisse verwenden?
# true  = /work/dba/patching/\$(hostname -s)  <- empfohlen für zentrale Shares
# false = /work/dba/patching
USE_HOSTNAME_DIR="true"

# ============================================================================
# ORACLE UMGEBUNG
# ============================================================================

ORACLE_BASE="/oracle"
CURRENT_ORACLE_HOME="/oracle/19"

# Oracle Inventory (auto-detected: ${detected_inv:-not found})
INVENTORY_LOC="${detected_inv:-/oracle/oraInventory}"

# ============================================================================
# LOGGING
# ============================================================================

LOGDIR="/work/dba/patching/logs"
# LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR

# ============================================================================
# AUTO-CLEANUP EINSTELLUNGEN
# ============================================================================

# Altersgrenze für expliziten Cleanup (--cleanup); nie während --prod automatisch
AUTO_CLEANUP_DAYS=30

# Anzahl der neuesten Homes, die Cleanup immer behält (aktuell + Rollback)
KEEP_HOMES=2

# ============================================================================
# BETRIEBSMODI
# ============================================================================

# Default Mode wenn Skript ohne Parameter aufgerufen wird
# Optionen: interactive, test, prod
DEFAULT_MODE="interactive"

# Unattended Mode (keine Bestätigungen erforderlich)
# true  = Keine Benutzerinteraktion, direkt durchlaufen
# false = Bestätigungen erforderlich (empfohlen für manuelle Ausführung)
UNATTENDED_MODE="false"

# Nur validieren und geplante Aktionen anzeigen; keine Änderungen
DRY_RUN="false"

# ============================================================================
# SYSTEM
# ============================================================================

# Oracle User (Owner der Oracle Software)
REQUIRED_USER="ora19"

# Datapatch Timeout in Sekunden
DATAPATCH_TIMEOUT=7200

EOF

    log_success "Default config created: ${PATCHRC}"
    exit 0
}

# =============================================================================
# LOCKING
# =============================================================================

acquire_lock() {
    if [[ -d "${LOCK_DIR}" ]]; then
        [[ -O "${LOCK_DIR}" && ! -L "${LOCK_DIR}" ]] || die "Lock-Verzeichnis ist nicht sicher/eigen: ${LOCK_DIR}"
        local locked_pid=""
        if [[ -f "${LOCK_PID_FILE}" ]]; then
            [[ -O "${LOCK_PID_FILE}" && ! -L "${LOCK_PID_FILE}" ]] || die "Lock-PID-Datei ist nicht sicher/eigen: ${LOCK_PID_FILE}"
            locked_pid=$(cat "${LOCK_PID_FILE}" 2>/dev/null || echo "")
        fi

        if [[ "${locked_pid}" =~ ^[0-9]+$ ]] && kill -0 "${locked_pid}" 2>/dev/null; then
            die "Skript läuft bereits (PID: ${locked_pid})"
        fi

        log_warn "Entferne verwaistes Lock${locked_pid:+ (PID: ${locked_pid})}"
        rm -f -- "${LOCK_PID_FILE}"
        rmdir -- "${LOCK_DIR}" 2>/dev/null || die "Lock-Verzeichnis ist nicht leer oder nicht entfernbar: ${LOCK_DIR}"
    fi

    mkdir "${LOCK_DIR}" 2>/dev/null || die "Konnte Lock-Verzeichnis nicht erstellen: ${LOCK_DIR}"
    if ! chmod 700 "${LOCK_DIR}" || ! printf '%s\n' "$$" > "${LOCK_PID_FILE}"; then
        rm -f -- "${LOCK_PID_FILE}"
        rmdir -- "${LOCK_DIR}" 2>/dev/null || true
        die "Konnte Lock nicht sicher initialisieren: ${LOCK_DIR}"
    fi
    LOCK_ACQUIRED=true
    LOCK_OWNER_BASHPID="${BASHPID}"

    log_debug "Lock acquired (PID: $$)"
}

# =============================================================================
# DATABASE HELPER FUNCTIONS
# =============================================================================

# Read databases as array from oratab
read_databases_from_oratab() {
    local oracle_home="$1"
    local -n result_array=$2
    local oratab_file="${3:-/etc/oratab}"
    
    # shellcheck disable=SC2034 # populated through the nameref output parameter
    mapfile -t result_array < <(
        awk -F: -v home="${oracle_home}" 'NF >= 2 && $1 !~ /^[[:space:]]*#/ && $1 ~ /^[[:alnum:]_$#]+$/ && $1 != "*" && $2 == home { print $1 }' "${oratab_file}" 2>/dev/null || true
    )
}

# Get Oracle Home version (multiple fallback methods)
get_home_version() {
    local oracle_home="$1"
    local version=""
    
    # Method 1: sqlplus -V (most reliable, no DB connection needed)
    if [[ -x "${oracle_home}/bin/sqlplus" ]]; then
        version=$("${oracle_home}/bin/sqlplus" -V 2>/dev/null | awk '/^Version/{print $2}' || true)
        if [[ -n "${version}" ]]; then
            echo "${version}"
            return 0
        fi
    fi
    
    # Method 2: opatch lspatches (extract from RU patch description)
    if [[ -x "${oracle_home}/OPatch/opatch" ]]; then
        version=$("${oracle_home}/OPatch/opatch" lspatches 2>/dev/null | \
                  grep -oE "19\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)
        if [[ -n "${version}" ]]; then
            echo "${version}"
            return 0
        fi
    fi
    
    # Method 3: Fallback to "Unknown"
    echo "Unknown"
}

# Get database status
get_db_status() {
    local db_home="$1"
    local db_sid="$2"
    
    export ORACLE_HOME="${db_home}"
    export ORACLE_SID="${db_sid}"
    
    "${db_home}/bin/sqlplus" -s / as sysdba 2>/dev/null <<'EOF'
whenever sqlerror exit failure
set heading off feedback off pagesize 0
SELECT status FROM v$instance;
EXIT;
EOF
}

# Get database version (requires running DB)
get_db_version() {
    local db_home="$1"
    local db_sid="$2"
    
    export ORACLE_HOME="${db_home}"
    export ORACLE_SID="${db_sid}"
    
    "${db_home}/bin/sqlplus" -s / as sysdba 2>/dev/null <<'EOF'
whenever sqlerror exit failure
set heading off feedback off pagesize 0
SELECT version_full FROM v$instance;
EXIT;
EOF
}

# Get invalid object count
get_invalid_count() {
    local db_home="$1"
    local db_sid="$2"
    
    export ORACLE_HOME="${db_home}"
    export ORACLE_SID="${db_sid}"
    
    "${db_home}/bin/sqlplus" -s / as sysdba 2>/dev/null <<'EOF'
whenever sqlerror exit failure
set heading off feedback off pagesize 0
SELECT COUNT(*) FROM dba_objects WHERE status='INVALID';
EXIT;
EOF
}

# Get OPatch version
get_opatch_version() {
    local oracle_home="$1"
    
    if [[ -x "${oracle_home}/OPatch/opatch" ]]; then
        "${oracle_home}/OPatch/opatch" version 2>/dev/null | \
            awk '/OPatch Version/{print $3}' || echo "Unknown"
    else
        echo "Not installed"
    fi
}

# Get home size
get_home_size() {
    local oracle_home="$1"
    du -sh "${oracle_home}" 2>/dev/null | cut -f1 || echo "Unknown"
}

# Get home age in days
get_home_age_days() {
    local oracle_home="$1"
    local mtime
    mtime=$(stat -c %Y "${oracle_home}" 2>/dev/null || echo "0")
    echo $(( ( $(date +%s) - mtime ) / 86400 ))
}

# =============================================================================
# INITIALIZATION
# =============================================================================

INITIALIZED=false

initialize() {
    [[ "${INITIALIZED}" == "true" ]] && return 0

    load_config

    if [[ "${USE_HOSTNAME_DIR}" == "true" ]]; then
        PATCH_BASE_DIR="${PATCH_BASE_DIR_BASE}/$(hostname -s)"
    else
        PATCH_BASE_DIR="${PATCH_BASE_DIR_BASE}"
    fi

    LOGFILE="${LOGDIR}/oop_patching_${TIMESTAMP}.log"
    STATE_FILE="${LOGDIR}/oop_patching_state"
    LOCK_DIR="${LOCK_DIR:-${ORACLE_BASE}/.oracle_patching.lock}"
    LOCK_PID_FILE="${LOCK_DIR}/pid"
    if ! mkdir -p "${LOGDIR}" 2>/dev/null || [[ ! -w "${LOGDIR}" ]]; then
        printf 'Log directory is not writable: %s\n' "${LOGDIR}" >&2
        exit 1
    fi
    if ! CLEANUP_TMPFILE=$(mktemp -t cleanup_candidates.XXXXXX); then
        printf 'Could not create cleanup temporary file\n' >&2
        exit 1
    fi
    if ! touch "${LOGFILE}"; then
        printf 'Could not create log file: %s\n' "${LOGFILE}" >&2
        exit 1
    fi

    validate_config || die "Konfigurationsvalidierung fehlgeschlagen"
    INITIALIZED=true
    log_info "Configuration loaded${PATCHRC:+ (${PATCHRC})}"
}

# Declare global arrays
declare -a DATABASES=()
declare -a DATAPATCH_PIDS=()

# Global patch variables
NEW_ORACLE_HOME=""
OLD_ORACLE_HOME=""
ORATAB_BACKUP=""
PATCH_PHASE="PREPARE"
RU_PATCH_DIR=""
RU_PATCH_NUM=""
NEW_PATCH_VERSION=""
OPATCH_ZIP=""
OJVM_PATCH_DIR=""
OJVM_PATCH_NUM=""

# =============================================================================
# STATUS OVERVIEW
# =============================================================================
show_status() {
    log_info "=== Oracle Patching Status Overview ==="
    echo ""

    # System Info
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}SYSTEM INFORMATION${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Hostname: $(hostname)"
    echo -e "  Oracle User: ${REQUIRED_USER}"
    echo -e "  Oracle Inventory: ${INVENTORY_LOC}"
    echo -e "  Patch Directory: ${PATCH_BASE_DIR}"
    echo ""

    # Oracle Homes
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}INSTALLED ORACLE HOMES${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ -f "${INVENTORY_LOC}/ContentsXML/inventory.xml" ]]; then
        local homes
        homes=$(grep -oP '(?<=LOC=")[^"]+' "${INVENTORY_LOC}/ContentsXML/inventory.xml" 2>/dev/null || echo "")

        if [[ -n "${homes}" ]]; then
            while IFS= read -r home; do
#                if [[ -d "${home}" ]] && [[ -f "${home}/bin/oracle" ]]; then
#                    # Get version
#                    local version
#                    version=$(grep "oracle.installer.version=" "${home}/install/version.properties" 2>/dev/null | \
#                              cut -d'=' -f2 || echo "Unknown")
                if [[ -d "${home}" ]] && [[ -f "${home}/bin/oracle" ]]; then
                    # Get version
                    local version
                    version=$(get_home_version "${home}")

                    local size
                    size=$(get_home_size "${home}")
                    
                    local age_days
                    age_days=$(get_home_age_days "${home}")
                    
                    local is_current=""
                    if [[ "${home}" == "${CURRENT_ORACLE_HOME}" ]] || \
                       grep -q "${home}" /etc/oratab 2>/dev/null; then
                        is_current=" ${GREEN}[ACTIVE]${NC}"
                    else
                        is_current=" ${YELLOW}[INACTIVE - ${age_days} days old]${NC}"
                    fi

                    echo -e "  [>>] ${home}${is_current}"
                    echo -e "     Version: ${version}"
                    echo -e "     Size: ${size}"

                    local opatch_ver
                    opatch_ver=$(get_opatch_version "${home}")
                    echo -e "     OPatch: ${opatch_ver}"

                    if [[ -x "${home}/OPatch/opatch" ]]; then
                        echo -e "     Patches:"
                        "${home}/OPatch/opatch" lspatches 2>/dev/null | head -3 | grep -v '^$' | while IFS= read -r line; do
                            echo -e "       • ${line}"
                        done
                    fi
                    echo ""
                fi
            done <<< "${homes}"
        else
            echo "  No Oracle Homes found in inventory"
        fi
    else
        log_warn "Inventory not found at ${INVENTORY_LOC}"
        echo ""
    fi

    # Active Databases
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}ACTIVE DATABASES${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local -a active_dbs=()
    mapfile -t active_dbs < <(awk -F: 'NF>=3 && !/^#/{print $1}' /etc/oratab 2>/dev/null || true)

    if [[ ${#active_dbs[@]} -gt 0 ]]; then
        for db in "${active_dbs[@]}"; do
            local db_home
            db_home=$(grep "^${db}:" /etc/oratab 2>/dev/null | cut -d':' -f2 || echo "")

            echo -e "  [#]  Database: ${GREEN}${db}${NC}"
            echo -e "     Home: ${db_home}"

            if [[ -n "${db_home}" ]] && [[ -x "${db_home}/bin/sqlplus" ]]; then
                local db_status
                db_status=$(get_db_status "${db_home}" "${db}")
                echo -e "     Status: ${db_status}"

                if [[ "${db_status}" == *"OPEN"* ]]; then
                    local db_version
                    db_version=$(get_db_version "${db_home}" "${db}")
                    echo -e "     Version: ${db_version}"

                    echo -e "     SQL Patches:"
                    export ORACLE_SID="${db}"
                    export ORACLE_HOME="${db_home}"
                    "${db_home}/bin/sqlplus" -s / as sysdba 2>/dev/null <<'EOSQL'
set pagesize 100 linesize 150
col description format a60
col action_time format a20
SELECT TO_CHAR(action_time, 'YYYY-MM-DD HH24:MI') as action_time,
       patch_id,
       description
FROM dba_registry_sqlpatch
ORDER BY action_time DESC
FETCH FIRST 3 ROWS ONLY;
EXIT;
EOSQL
                fi
            fi
            echo ""
        done
    else
        echo "  No active databases found in /etc/oratab"
        echo ""
    fi

    # Available Patches
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}AVAILABLE PATCHES${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ -d "${PATCH_BASE_DIR}" ]]; then
        local -a patch_dirs=()
        mapfile -t patch_dirs < <(find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | sort -V || true)

        if [[ ${#patch_dirs[@]} -gt 0 ]]; then
            for patch_dir in "${patch_dirs[@]}"; do
                local patch_num
                patch_num=$(basename "${patch_dir}")
                local readme="${patch_dir}/README.txt"

                echo -e "  [*] Patch ${patch_num}"

                if [[ -f "${readme}" ]]; then
                    local patch_desc
                    patch_desc=$(grep -E "^(Patch|Release Update)" "${readme}" 2>/dev/null | head -1 || echo "")
                    [[ -n "${patch_desc}" ]] && echo -e "     ${patch_desc}"
                fi
            done
        else
            echo "  No patches found in ${PATCH_BASE_DIR}"
        fi

        local -a opatch_zips=()
        mapfile -t opatch_zips < <(find "${PATCH_BASE_DIR}" -maxdepth 1 -name "p6880880*.zip" 2>/dev/null || true)
        
        if [[ ${#opatch_zips[@]} -gt 0 ]]; then
            echo ""
            echo -e "  OPatch Updates available:"
            for zip in "${opatch_zips[@]}"; do
                echo -e "    • $(basename "${zip}")"
            done
        fi
    else
        log_warn "Patch directory not found: ${PATCH_BASE_DIR}"
    fi

    # Cleanup Candidates
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}CLEANUP CANDIDATES (older than ${AUTO_CLEANUP_DAYS} days)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    find_old_homes

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# =============================================================================
# AUTO-CLEANUP FUNCTIONS
# =============================================================================

find_old_homes() {
    if [[ ! -f "${INVENTORY_LOC}/ContentsXML/inventory.xml" ]]; then
        return 0
    fi

    : > "${CLEANUP_TMPFILE}"

    local homes
    homes=$(awk '
        {
            line = $0
            while (match(line, /LOC="[^"]+"/)) {
                print substr(line, RSTART + 5, RLENGTH - 6)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "${INVENTORY_LOC}/ContentsXML/inventory.xml" 2>/dev/null || true)

    if [[ -z "${homes}" ]]; then
        echo -e "  ${GREEN}✓ No cleanup candidates found${NC}"
        return 0
    fi

    local -a sorted_homes=()
    local canonical_base
    canonical_base=$(realpath -e -- "${ORACLE_BASE}" 2>/dev/null) || return 0
    mapfile -t sorted_homes < <(
        while IFS= read -r home; do
            home=$(realpath -e -- "${home}" 2>/dev/null || true)
            [[ -n "${home}" && "${home}" == "${canonical_base}/"* ]] || continue
            [[ -f "${home}/bin/oracle" ]] || continue
            printf '%s\t%s\n' "$(stat -c %Y "${home}" 2>/dev/null || echo 0)" "${home}"
        done <<< "${homes}" | sort -u -k2,2 | sort -rn -k1,1 | cut -f2-
    )

    local found_candidates=false
    local position=0
    local home
    for home in "${sorted_homes[@]}"; do
        position=$((position + 1))

        # Always retain the newest configured number of homes.
        if [[ ${position} -le ${KEEP_HOMES} ]]; then
            continue
        fi

        # Never offer a home still referenced by oratab.
        if awk -F: -v candidate="${home}" 'NF >= 2 && $1 !~ /^#/ && $2 == candidate { found=1 } END { exit !found }' /etc/oratab 2>/dev/null; then
            continue
        fi

        local age_days
        age_days=$(get_home_age_days "${home}")

        if [[ ${age_days} -ge ${AUTO_CLEANUP_DAYS} ]]; then
            local size
            size=$(get_home_size "${home}")
            echo -e "  [!]  ${home}"
            echo -e "     Age: ${age_days} days, Size: ${size}"
            echo "${home}" >> "${CLEANUP_TMPFILE}"
            found_candidates=true
        fi
    done

    if [[ "${found_candidates}" == "false" ]]; then
        echo -e "  ${GREEN}✓ No cleanup candidates found${NC}"
    fi
}

auto_cleanup() {
    acquire_lock
    log_info "=== Auto-Cleanup of Old Homes ==="

    if [[ ! -s "${CLEANUP_TMPFILE}" ]]; then
        find_old_homes > /dev/null
    fi

    if [[ ! -s "${CLEANUP_TMPFILE}" ]]; then
        log_success "No homes to cleanup"
        return 0
    fi

    local -a candidates=()
    mapfile -t candidates < "${CLEANUP_TMPFILE}"
    
    # Reset temp file after reading
    : > "${CLEANUP_TMPFILE}"

    if [[ ${#candidates[@]} -eq 0 ]]; then
        log_success "No homes to cleanup"
        return 0
    fi

    local cleanup_failures=0
    for old_home in "${candidates[@]}"; do
        log_info "Cleaning up: ${old_home}"
        if ! cleanup_single_home "${old_home}" --auto; then
            cleanup_failures=$((cleanup_failures + 1))
            log_warn "Cleanup skipped after safety check failure: ${old_home}"
        fi
    done

    if [[ ${cleanup_failures} -gt 0 ]]; then
        die "Cleanup completed with ${cleanup_failures} safety-check failure(s)"
    fi
}

cleanup_single_home() {
    local old_home="$1"
    local auto_mode="${2:-}"
    local canonical_home canonical_base

    [[ -z "${old_home}" ]] && die "Kein Home angegeben"
    command -v realpath >/dev/null 2>&1 || die "Required tool 'realpath' is not installed"
    canonical_home=$(realpath -e -- "${old_home}" 2>/dev/null) || { log_error "Home existiert nicht: ${old_home}"; return 1; }
    canonical_base=$(realpath -e -- "${ORACLE_BASE}" 2>/dev/null) || die "ORACLE_BASE ist ungültig: ${ORACLE_BASE}"
    old_home="${canonical_home}"

    [[ "${old_home}" == "${canonical_base}" ]] && die "ORACLE_BASE selbst darf nicht gelöscht werden"
    [[ "${old_home}" == "${canonical_base}/"* ]] || die "Cleanup ist nur innerhalb von ORACLE_BASE erlaubt: ${canonical_base}"
    [[ "${old_home}" == "$(realpath -e -- "${CURRENT_ORACLE_HOME}" 2>/dev/null || true)" ]] && die "Aktuelles Oracle Home darf nicht gelöscht werden"
    [[ ! -f "${old_home}/bin/oracle" ]] && { log_error "Kein gültiges Oracle Home: ${old_home}"; return 1; }

    if awk -F: -v candidate="${old_home}" 'NF >= 2 && $1 !~ /^#/ && $2 == candidate { found=1 } END { exit !found }' /etc/oratab 2>/dev/null; then
        log_error "Oracle Home wird noch in /etc/oratab verwendet: ${old_home}"
        return 1
    fi

    local proc pid executable
    for proc in /proc/[0-9]*; do
        pid=${proc##*/}
        executable=$(readlink -f "${proc}/exe" 2>/dev/null || true)
        if [[ "${executable}" == "${old_home}/"* ]]; then
            log_error "Ein laufender Prozess verwendet noch ${old_home} (PID: ${pid}, executable: ${executable})"
            return 1
        fi
    done

    local home_age_days
    home_age_days=$(get_home_age_days "${old_home}")

    if [[ "${auto_mode}" == "--auto" && ${home_age_days} -lt ${AUTO_CLEANUP_DAYS} ]]; then
        log_error "Home ist erst ${home_age_days} Tage alt; Minimum: ${AUTO_CLEANUP_DAYS}"
        return 1
    fi

    log_warn "Home: ${old_home}"
    log_warn "Age: ${home_age_days} days"
    local confirm
    read -r -p "Delete this home? Type yes to continue: " confirm

    if [[ "${confirm}" != "yes" ]]; then
        log_info "Cleanup skipped"
        return 0
    fi

    log_info "Starting cleanup of ${old_home}..."

    local inventory_xml="${INVENTORY_LOC}/ContentsXML/inventory.xml"
    if [[ -f "${inventory_xml}" ]] && grep -Fq "LOC=\"${old_home}\"" "${inventory_xml}"; then
        [[ -x "${old_home}/oui/bin/runInstaller" ]] || {
            log_error "runInstaller fehlt; Inventory wird nicht manuell verändert"
            return 1
        }

        log_info "Detaching Oracle Home from inventory..."
        local inventory_backup
        if ! inventory_backup=$(mktemp "${LOGDIR}/inventory.xml.bak.XXXXXX"); then
            log_error "Could not allocate Oracle Inventory backup; cleanup aborted"
            return 1
        fi
        if ! cp --preserve=mode,timestamps -- "${inventory_xml}" "${inventory_backup}"; then
            rm -f -- "${inventory_backup}"
            log_error "Could not back up Oracle Inventory; cleanup aborted"
            return 1
        fi
        log_info "Inventory backup: ${inventory_backup}"
        if ! "${old_home}/oui/bin/runInstaller" -silent -detachHome ORACLE_HOME="${old_home}" 2>&1 | tee -a "${LOGFILE}"; then
            log_error "Inventory detach failed; directory is preserved"
            return 1
        fi

        if grep -Fq "LOC=\"${old_home}\"" "${inventory_xml}"; then
            log_error "Oracle Home is still present in inventory; directory is preserved"
            return 1
        fi
    fi

    log_info "Removing directory ${old_home}..."
    rm -rf -- "${old_home}"

    log_success "Cleanup completed: ${old_home}"
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_prerequisites() {
    log_info "=== Prerequisite Checks ==="

    if [[ "$(whoami)" != "${REQUIRED_USER}" ]]; then
        die "Script must be run as user '${REQUIRED_USER}', current user: $(whoami)"
    fi

    if [[ ! -d "${CURRENT_ORACLE_HOME}" ]]; then
        die "Current Oracle Home not found: ${CURRENT_ORACLE_HOME}"
    fi

    if [[ ! -x "${CURRENT_ORACLE_HOME}/OPatch/opatch" ]]; then
        die "OPatch not found in ${CURRENT_ORACLE_HOME}/OPatch"
    fi

    # Disk Space with buffer
    local required_space available_space
    if ! required_space=$(du -sb "${CURRENT_ORACLE_HOME}" 2>/dev/null | \
        awk -v factor="${SPACE_BUFFER_FACTOR}" '{print int($1 * factor / 1024 / 1024)}') ||
       ! [[ "${required_space}" =~ ^[0-9]+$ ]]; then
        die "Could not calculate required disk space"
    fi
    if ! available_space=$(df -Pm "${ORACLE_BASE}" 2>/dev/null | awk 'NR == 2 {print $4}') ||
       ! [[ "${available_space}" =~ ^[0-9]+$ ]]; then
        die "Could not determine available disk space in ${ORACLE_BASE}"
    fi
    
    log_info "Required space: ~${required_space} MB, Available: ${available_space} MB"
    
    if [[ ${available_space} -lt ${required_space} ]]; then
        die "Insufficient disk space in ${ORACLE_BASE} (need ${required_space} MB, have ${available_space} MB)"
    fi

    # ulimit Check
    local open_files
    open_files=$(ulimit -n)
    if [[ ${open_files} -lt ${MIN_OPEN_FILES} ]]; then
        log_warn "Limit für offene Dateien ist niedrig: ${open_files} (empfohlen: ${MIN_OPEN_FILES})"
    fi

    # Check required tools
    local required_tools=("rsync" "unzip" "realpath" "timeout" "stdbuf")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            die "Required tool '${tool}' is not installed"
        fi
    done

    # Check for running patch processes
    if pgrep -f "opatch|datapatch" 2>/dev/null | grep -vFx -- "$$" > /dev/null; then
        log_warn "Other OPatch/Datapatch processes are running on this host"
    fi

    # Active Sessions Check (info only)
    local session_count
    session_count=$(pgrep -u "${REQUIRED_USER}" -c ora_pmon 2>/dev/null || echo "0")
    if [[ ${session_count} -gt 0 ]]; then
        log_warn "Aktive Oracle Instanzen (${session_count}) auf diesem Host erkannt."
    fi

    log_success "All prerequisites met"
}

check_supported_topology() {
    local crs_home=""
    if [[ -r /etc/oracle/olr.loc ]]; then
        crs_home=$(awk -F= '$1 == "crs_home" { print $2; exit }' /etc/oracle/olr.loc | tr -d '[:space:]')
    fi
    if [[ -n "${crs_home}" && -x "${crs_home}/bin/crsctl" ]]; then
        die "Oracle Grid Infrastructure/Restart detected (${crs_home}); use an srvctl-aware patching workflow"
    fi

    local -a topology_databases=()
    local db topology role standby_destinations
    read_databases_from_oratab "${CURRENT_ORACLE_HOME}" topology_databases
    [[ ${#topology_databases[@]} -gt 0 ]] || die "No databases found for topology validation"

    for db in "${topology_databases[@]}"; do
        export ORACLE_HOME="${CURRENT_ORACLE_HOME}"
        export ORACLE_SID="${db}"
        if ! topology=$("${CURRENT_ORACLE_HOME}/bin/sqlplus" -s / as sysdba 2>/dev/null <<'EOF'
whenever sqlerror exit failure
set heading off feedback off pagesize 0
SELECT database_role || ':' ||
       (SELECT COUNT(*) FROM v$archive_dest
        WHERE target = 'STANDBY')
FROM v$database;
exit;
EOF
        ); then
            die "Could not validate database topology for ${db}"
        fi

        topology=$(tr -d '[:space:]' <<< "${topology}")
        role=${topology%%:*}
        standby_destinations=${topology#*:}
        if [[ "${role}" != "PRIMARY" || ! "${standby_destinations}" =~ ^[0-9]+$ ]]; then
            die "Unsupported or indeterminate database role for ${db}: ${topology:-empty}"
        fi
        if [[ ${standby_destinations} -gt 0 ]]; then
            die "Data Guard configuration detected for ${db}; coordinated standby patching is required"
        fi
    done

    log_success "Supported standalone single-instance topology confirmed"
}

# =============================================================================
# CLONE VALIDATION
# =============================================================================

validate_clone() {
    log_info "=== Validating Cloned Oracle Home ==="
    
    # 1. File Count Check
    local src_count dst_count diff_pct
    src_count=$(find "${CURRENT_ORACLE_HOME}" -type f 2>/dev/null | wc -l)
    dst_count=$(find "${NEW_ORACLE_HOME}" -type f 2>/dev/null | wc -l)
    
    if [[ ${src_count} -gt 0 ]]; then
        diff_pct=$(( (src_count - dst_count) * 100 / src_count ))
        log_info "Source files: ${src_count}, Target files: ${dst_count} (Diff: ${diff_pct#-}%)"
        
        if [[ ${diff_pct#-} -gt ${CLONE_TOLERANCE_PCT} ]]; then
            log_warn "File count difference is high (${diff_pct#-}%)"
        fi
    fi
    
    # 2. Critical Files Check
    local critical_files=("bin/oracle" "bin/sqlplus" "OPatch/opatch" "lib/libclntsh.so")
    for file in "${critical_files[@]}"; do
        if [[ ! -f "${NEW_ORACLE_HOME}/${file}" ]]; then
            die "Missing critical file in clone: ${file}"
        fi
    done
    
    # 3. Registry Check
    if [[ "${DRY_RUN}" != "true" ]]; then
        "${NEW_ORACLE_HOME}/OPatch/opatch" version &> /dev/null || \
            die "OPatch binary in new home is not functional"
    fi
    
    log_success "Clone validation successful"
}

# =============================================================================
# PATCH DETECTION & SELECTION
# =============================================================================

select_patch() {
    log_info "=== Detecting Patches ==="

    local -a patch_options=()
    local -a ojvm_candidates=()
    local -A patch_versions=()
    local patch_dir patch_readme patch_id patch_version opt

    while IFS= read -r patch_dir; do
        patch_readme="${patch_dir}/README.txt"
        [[ -f "${patch_readme}" ]] || continue

        if grep -Eqi 'OJVM|Oracle JavaVM' "${patch_readme}"; then
            ojvm_candidates+=("${patch_dir}")
        elif grep -Eqi 'Oracle Database Release Update|Database Release Update|Release Update.*19c' "${patch_readme}"; then
            patch_id=$(basename "${patch_dir}")
            patch_version=$(grep -oE "19\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "${patch_readme}" 2>/dev/null | sort -V | tail -1 || true)
            if [[ -n "${patch_version}" ]]; then
                patch_options+=("${patch_id}")
                patch_versions["${patch_id}"]="${patch_version}"
            else
                log_warn "Ignoring RU candidate without a 19c target version: ${patch_dir}"
            fi
        fi
    done < <(find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | sort -V || true)

    if [[ ${#patch_options[@]} -eq 0 ]]; then
        die "No verified Database Release Update patches found in ${PATCH_BASE_DIR}"
    fi

    if [[ "${UNATTENDED_MODE:-false}" == "true" ]]; then
        patch_id=$(
            for patch_id in "${patch_options[@]}"; do
                printf '%s\t%s\n' "${patch_versions[${patch_id}]}" "${patch_id}"
            done | sort -V -k1,1 | tail -1 | cut -f2
        )
        RU_PATCH_DIR="${PATCH_BASE_DIR}/${patch_id}"
    else
        echo ""
        echo "Available Database Release Updates in ${PATCH_BASE_DIR}:"
        local -a patch_labels=()
        for patch_id in "${patch_options[@]}"; do
            patch_labels+=("${patch_id} (${patch_versions[${patch_id}]})")
        done
        select opt in "${patch_labels[@]}" "Abbruch"; do
            if [[ "${opt}" == "Abbruch" ]]; then
                exit 0
            fi
            if [[ -z "${opt}" ]]; then
                echo "Ungültige Auswahl"
                continue
            fi
            patch_id=${patch_options[REPLY-1]}
            RU_PATCH_DIR="${PATCH_BASE_DIR}/${patch_id}"
            break
        done
    fi

    RU_PATCH_NUM=$(basename "${RU_PATCH_DIR}")
    NEW_PATCH_VERSION="${patch_versions[${RU_PATCH_NUM}]}"
    log_info "Selected RU Patch: ${RU_PATCH_NUM}"
    log_info "Target Version: ${NEW_PATCH_VERSION}"

    OPATCH_ZIP=$(find "${PATCH_BASE_DIR}" -maxdepth 1 -type f -name "p6880880*.zip" 2>/dev/null | sort -V | tail -1 || true)
    [[ -n "${OPATCH_ZIP}" ]] && log_info "Found OPatch Update: $(basename "${OPATCH_ZIP}")"

    OJVM_PATCH_DIR=""
    OJVM_PATCH_NUM=""
    for patch_dir in "${ojvm_candidates[@]}"; do
        patch_readme="${patch_dir}/README.txt"
        if grep -Fq "${NEW_PATCH_VERSION}" "${patch_readme}"; then
            OJVM_PATCH_DIR="${patch_dir}"
            OJVM_PATCH_NUM=$(basename "${patch_dir}")
        fi
    done

    if [[ -n "${OJVM_PATCH_DIR}" ]]; then
        log_info "Detected matching OJVM Patch: ${OJVM_PATCH_NUM}"
    elif [[ ${#ojvm_candidates[@]} -gt 0 ]]; then
        log_warn "OJVM patches exist, but none matches RU version ${NEW_PATCH_VERSION}; skipping OJVM"
    fi
}

# =============================================================================
# ORACLE HOME CLONE
# =============================================================================

clone_oracle_home() {
    log_info "=== Cloning Oracle Home ==="

    NEW_ORACLE_HOME="${ORACLE_BASE}/19_${NEW_PATCH_VERSION}_${TIMESTAMP}"

    log_info "Source: ${CURRENT_ORACLE_HOME}"
    log_info "Target: ${NEW_ORACLE_HOME}"

    local required_space available_space
    if ! required_space=$(du -sb "${CURRENT_ORACLE_HOME}" 2>/dev/null | \
        awk -v factor="${SPACE_BUFFER_FACTOR}" '{print int($1 * factor / 1024 / 1024)}') ||
       ! [[ "${required_space}" =~ ^[0-9]+$ ]]; then
        die "Could not calculate clone size"
    fi
    if ! available_space=$(df -Pm "${ORACLE_BASE}" 2>/dev/null | awk 'NR == 2 {print $4}') ||
       ! [[ "${available_space}" =~ ^[0-9]+$ ]]; then
        die "Could not determine available disk space in ${ORACLE_BASE}"
    fi

    log_info "Required: ${required_space} MB, Available: ${available_space} MB"
    [[ ${available_space} -ge ${required_space} ]] || die "Insufficient disk space before clone"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would clone to: ${NEW_ORACLE_HOME}"
        return 0
    fi

    # Create target directory
    mkdir -p "${NEW_ORACLE_HOME}"

    # rsync with progress
    log_info "Starting clone operation..."
    
    if ! rsync -a \
        --exclude='rdbms/audit' \
        --exclude='rdbms/log' \
        --exclude='admin' \
        --exclude='*.log' --exclude='*.trc' --exclude='*.trm' \
        --info=progress2 \
        "${CURRENT_ORACLE_HOME}/" "${NEW_ORACLE_HOME}/" 2>&1 | \
        stdbuf -oL tr '\r' '\n' | \
        while IFS= read -r line; do
            if [[ "$line" =~ [0-9]+% ]]; then
                printf "\rCloning: %-20s" "$line" >&2
            fi
        done; then
        echo ""
        die "Clone operation failed"
    fi
    
    echo ""
    log_info "Clone operation completed"

    validate_clone

    log_success "Oracle Home cloned successfully"

    log_info "Updating Oracle Inventory..."

    if ! "${NEW_ORACLE_HOME}/oui/bin/runInstaller" -silent -clone \
        -ignorePrereq \
        ORACLE_HOME="${NEW_ORACLE_HOME}" \
        ORACLE_HOME_NAME="OraDB19_${NEW_PATCH_VERSION}_${TIMESTAMP}" \
        ORACLE_BASE="${ORACLE_BASE}" 2>&1 | tee -a "${LOGFILE}"; then
        die "Clone registration in inventory failed"
    fi

    log_success "Inventory updated"
}

# =============================================================================
# OPATCH UPDATE
# =============================================================================

update_opatch() {
    if [[ -z "${OPATCH_ZIP:-}" ]]; then
        log_info "Skipping OPatch update (no new version provided)"
        return 0
    fi

    log_info "=== Updating OPatch ==="

    local current_version new_version
    current_version=$(get_opatch_version "${NEW_ORACLE_HOME}")
    log_info "Current OPatch version: ${current_version}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would extract: ${OPATCH_ZIP}"
        return 0
    fi

    mv "${NEW_ORACLE_HOME}/OPatch" "${NEW_ORACLE_HOME}/OPatch.bak_${TIMESTAMP}"
    
    if ! unzip -q -d "${NEW_ORACLE_HOME}" "${OPATCH_ZIP}" 2>&1 | tee -a "${LOGFILE}"; then
        log_error "Failed to extract OPatch, restoring backup"
        rm -rf -- "${NEW_ORACLE_HOME}/OPatch"
        mv -- "${NEW_ORACLE_HOME}/OPatch.bak_${TIMESTAMP}" "${NEW_ORACLE_HOME}/OPatch"
        return 1
    fi

    new_version=$(get_opatch_version "${NEW_ORACLE_HOME}")
    if [[ ! "${new_version}" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
        log_error "Extracted OPatch is not executable or has an invalid version: ${new_version:-empty}"
        rm -rf -- "${NEW_ORACLE_HOME}/OPatch"
        mv -- "${NEW_ORACLE_HOME}/OPatch.bak_${TIMESTAMP}" "${NEW_ORACLE_HOME}/OPatch"
        return 1
    fi

    log_success "OPatch updated: ${current_version} -> ${new_version}"
}

# =============================================================================
# PATCH INSTALLATION
# =============================================================================

apply_patches() {
    log_info "=== Applying Patches to New Home ==="

    local original_dir="${PWD}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would run conflict analysis and apply RU ${RU_PATCH_NUM}${OJVM_PATCH_NUM:+ and OJVM ${OJVM_PATCH_NUM}}"
        return 0
    fi

    export ORACLE_HOME="${NEW_ORACLE_HOME}"
    export PATH="${NEW_ORACLE_HOME}/OPatch:${PATH}"

    log_info "Running conflict analysis..."

    cd -- "${RU_PATCH_DIR}" || die "Could not enter RU patch directory: ${RU_PATCH_DIR}"

    if ! "${NEW_ORACLE_HOME}/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph ./ 2>&1 | tee -a "${LOGFILE}"; then
        die "Conflict check failed"
    fi

    log_info "Applying Release Update ${RU_PATCH_NUM}..."

    if ! "${NEW_ORACLE_HOME}/OPatch/opatch" apply -silent 2>&1 | tee -a "${LOGFILE}"; then
        die "RU Patch application failed"
    fi

    log_success "RU Patch ${RU_PATCH_NUM} applied successfully"

    if [[ -n "${OJVM_PATCH_DIR:-}" ]]; then
        log_info "Applying OJVM Patch ${OJVM_PATCH_NUM}..."

        cd -- "${OJVM_PATCH_DIR}" || die "Could not enter OJVM patch directory: ${OJVM_PATCH_DIR}"
        
        if ! "${NEW_ORACLE_HOME}/OPatch/opatch" apply -silent 2>&1 | tee -a "${LOGFILE}"; then
            die "OJVM Patch application failed"
        else
            log_success "OJVM Patch ${OJVM_PATCH_NUM} applied successfully"
        fi
    fi

    log_info "Verifying installed patches..."
    local installed_patches
    if ! installed_patches=$("${NEW_ORACLE_HOME}/OPatch/opatch" lspatches 2>&1); then
        printf '%s\n' "${installed_patches}" | tee -a "${LOGFILE}"
        die "Could not verify installed patches"
    fi
    printf '%s\n' "${installed_patches}" | tee -a "${LOGFILE}"

    if ! grep -Eq "^${RU_PATCH_NUM};" <<< "${installed_patches}"; then
        die "Applied RU ${RU_PATCH_NUM} is missing from OPatch inventory"
    fi
    if [[ -n "${OJVM_PATCH_NUM:-}" ]] && ! grep -Eq "^${OJVM_PATCH_NUM};" <<< "${installed_patches}"; then
        die "Applied OJVM ${OJVM_PATCH_NUM} is missing from OPatch inventory"
    fi

    cd -- "${original_dir}" || die "Could not restore working directory: ${original_dir}"
}

# =============================================================================
# DATABASE SWITCH (DOWNTIME PHASE)
# =============================================================================

save_switch_state() {
    local state_tmp
    state_tmp=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || return 1
    if ! {
        printf 'OLD_HOME\t%s\n' "${CURRENT_ORACLE_HOME}"
        printf 'NEW_HOME\t%s\n' "${NEW_ORACLE_HOME}"
        printf 'ORATAB_BACKUP\t%s\n' "${ORATAB_BACKUP}"
        printf 'PHASE\t%s\n' "${PATCH_PHASE}"
        local db
        for db in "${DATABASES[@]}"; do
            printf 'DATABASE\t%s\n' "${db}"
        done
    } > "${state_tmp}"; then
        rm -f -- "${state_tmp}"
        return 1
    fi
    mv -- "${state_tmp}" "${STATE_FILE}" || { rm -f -- "${state_tmp}"; return 1; }
}

load_switch_state() {
    [[ -f "${STATE_FILE}" && -O "${STATE_FILE}" ]] || die "Owned rollback state not found: ${STATE_FILE}"

    OLD_ORACLE_HOME=""
    NEW_ORACLE_HOME=""
    ORATAB_BACKUP=""
    PATCH_PHASE=""
    DATABASES=()

    local key value
    while IFS=$'\t' read -r key value; do
        case "${key}" in
            OLD_HOME) OLD_ORACLE_HOME="${value}" ;;
            NEW_HOME) NEW_ORACLE_HOME="${value}" ;;
            ORATAB_BACKUP) ORATAB_BACKUP="${value}" ;;
            PHASE) PATCH_PHASE="${value}" ;;
            DATABASE) DATABASES+=("${value}") ;;
        esac
    done < "${STATE_FILE}"

    [[ -n "${OLD_ORACLE_HOME}" && -d "${OLD_ORACLE_HOME}" ]] || die "Old Oracle Home from state is missing"
    [[ -n "${NEW_ORACLE_HOME}" && -d "${NEW_ORACLE_HOME}" ]] || die "New Oracle Home from state is missing"
    [[ -n "${ORATAB_BACKUP}" && -f "${ORATAB_BACKUP}" ]] || die "oratab backup from state is missing"
    [[ "${PATCH_PHASE}" =~ ^(SWITCHING|SWITCHED|DATAPATCH_STARTED|COMPLETE)$ ]] || die "Invalid patch phase in rollback state"
    [[ ${#DATABASES[@]} -gt 0 ]] || die "No databases recorded in rollback state"
}

update_oratab_home() {
    local source_file="$1"
    local old_home="$2"
    local new_home="$3"
    local target_file="$4"

    awk -F: -v OFS=: -v old="${old_home}" -v new="${new_home}" '$1 !~ /^[[:space:]]*#/ && $2 == old { $2 = new } { print }' "${source_file}" > "${target_file}"
}

rollback_databases() {
    local db db_status failed=0

    for db in "${DATABASES[@]}"; do
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${NEW_ORACLE_HOME}"
        db_status=$(get_db_status "${NEW_ORACLE_HOME}" "${db}" || true)

        if [[ "${db_status}" == *"OPEN"* || "${db_status}" == *"MOUNTED"* || "${db_status}" == *"STARTED"* ]]; then
            log_info "Stopping ${db} before rollback..."
            if ! "${NEW_ORACLE_HOME}/bin/sqlplus" -s / as sysdba <<'EOF' 2>&1 | tee -a "${LOGFILE}"
whenever sqlerror exit failure
shutdown immediate;
exit;
EOF
            then
                log_error "Immediate shutdown failed for ${db}; attempting abort"
                if ! "${NEW_ORACLE_HOME}/bin/sqlplus" -s / as sysdba <<'EOF' 2>&1 | tee -a "${LOGFILE}"
whenever sqlerror exit failure
shutdown abort;
exit;
EOF
                then
                    log_error "Failed to stop ${db}; rollback aborted before oratab restore"
                    return 1
                fi
            fi
        else
            log_info "${db} is not running; continuing rollback"
        fi
    done

    if ! cat -- "${ORATAB_BACKUP}" > /etc/oratab; then
        log_error "Could not restore ${ORATAB_BACKUP}"
        return 1
    fi
    log_info "Restored oratab from ${ORATAB_BACKUP}"

    for db in "${DATABASES[@]}"; do
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${OLD_ORACLE_HOME}"
        log_info "Starting ${db} from old home (${OLD_ORACLE_HOME})..."

        if ! "${OLD_ORACLE_HOME}/bin/sqlplus" -s / as sysdba <<'EOF' 2>&1 | tee -a "${LOGFILE}"
whenever sqlerror exit failure
startup;
exit;
EOF
        then
            log_error "Failed to start ${db} from old home"
            failed=1
        else
            log_success "Database ${db} rolled back"
        fi
    done

    if [[ ${failed} -ne 0 ]]; then
        return 1
    fi

    rm -f -- "${STATE_FILE}"
    log_warn "Listener processes were not restarted automatically; verify listeners separately"
    log_success "Rollback completed - databases running from ${OLD_ORACLE_HOME}"
}

handle_switch_failure() {
    local reason="$1"
    log_error "${reason}; initiating automatic rollback"
    if rollback_databases; then
        die "${reason}; automatic rollback completed"
    fi
    die "${reason}; automatic rollback incomplete, state preserved at ${STATE_FILE}"
}

switch_database() {
    log_info "=== Switching Database to New Home ==="
    log_warn "[!]  DOWNTIME STARTS NOW [!]"

    local downtime_start
    local db
    downtime_start=$(date +%s)

    read_databases_from_oratab "${CURRENT_ORACLE_HOME}" DATABASES
    if [[ ${#DATABASES[@]} -eq 0 ]]; then
        die "No databases found in /etc/oratab for home ${CURRENT_ORACLE_HOME}"
    fi

    log_info "Databases to switch: ${DATABASES[*]}"

    ORATAB_BACKUP="${LOGDIR}/oratab_${TIMESTAMP}.bak"
    cp --preserve=mode,timestamps -- /etc/oratab "${ORATAB_BACKUP}" || die "Could not back up /etc/oratab"
    OLD_ORACLE_HOME="${CURRENT_ORACLE_HOME}"
    PATCH_PHASE="SWITCHING"
    save_switch_state || die "Could not persist rollback state"

    for db in "${DATABASES[@]}"; do
        log_info "Stopping database ${db}..."
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${CURRENT_ORACLE_HOME}"

        if ! "${CURRENT_ORACLE_HOME}/bin/sqlplus" -s / as sysdba <<'EOF' 2>&1 | tee -a "${LOGFILE}"
whenever sqlerror exit failure
shutdown immediate;
exit;
EOF
        then
            log_error "Failed to shutdown ${db}, attempting abort..."
            if ! "${CURRENT_ORACLE_HOME}/bin/sqlplus" -s / as sysdba <<'EOF' 2>&1 | tee -a "${LOGFILE}"
whenever sqlerror exit failure
shutdown abort;
exit;
EOF
            then
                handle_switch_failure "Failed to stop ${db}"
            fi
        fi

        log_success "Database ${db} stopped"
    done

    log_info "Updating /etc/oratab..."
    local oratab_tmp
    if ! oratab_tmp=$(mktemp "${LOGDIR}/oratab.new.XXXXXX"); then
        handle_switch_failure "Could not create temporary oratab"
    fi
    if ! update_oratab_home /etc/oratab "${CURRENT_ORACLE_HOME}" "${NEW_ORACLE_HOME}" "${oratab_tmp}"; then
        rm -f -- "${oratab_tmp}"
        handle_switch_failure "Could not generate updated oratab"
    fi
    # Write through the existing inode so root/group ownership and mode stay intact.
    if ! cat -- "${oratab_tmp}" > /etc/oratab; then
        rm -f -- "${oratab_tmp}"
        handle_switch_failure "Could not install updated oratab"
    fi
    rm -f -- "${oratab_tmp}"

    local -a switched_databases=()
    local -A switched_set=()
    read_databases_from_oratab "${NEW_ORACLE_HOME}" switched_databases
    for db in "${switched_databases[@]}"; do
        switched_set["${db}"]=1
    done
    if [[ ${#switched_databases[@]} -ne ${#DATABASES[@]} ]]; then
        handle_switch_failure "oratab update validation failed"
    fi
    for db in "${DATABASES[@]}"; do
        if [[ -z "${switched_set[${db}]+present}" ]]; then
            handle_switch_failure "oratab update validation failed for ${db}"
        fi
    done

    for db in "${DATABASES[@]}"; do
        log_info "Starting database ${db} from new home..."
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${NEW_ORACLE_HOME}"

        if ! "${NEW_ORACLE_HOME}/bin/sqlplus" -s / as sysdba <<'EOF' 2>&1 | tee -a "${LOGFILE}"
whenever sqlerror exit failure
startup;
exit;
EOF
        then
            handle_switch_failure "Failed to start ${db} from new home"
        fi

        log_success "Database ${db} started from new home"
    done

    PATCH_PHASE="SWITCHED"
    save_switch_state || handle_switch_failure "Could not persist switched state"
    log_warn "Listener processes are not restarted automatically; verify listener ownership and registration separately"

    local downtime_end downtime_duration
    downtime_end=$(date +%s)
    downtime_duration=$((downtime_end - downtime_start))

    log_success "[!]  DOWNTIME ENDED - Duration: ${downtime_duration} seconds [!]"
}

# =============================================================================
# DATAPATCH
# =============================================================================

run_datapatch_single() {
    local db="$1"

    export ORACLE_SID="${db}"
    export ORACLE_HOME="${NEW_ORACLE_HOME}"

    local dplock="${LOGDIR}/datapatch_${db}.lock"
    if [[ -f "${dplock}" ]]; then
        local lock_pid
        lock_pid=$(cat "${dplock}" 2>/dev/null || echo "")
        if [[ "${lock_pid}" =~ ^[0-9]+$ ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_error "Datapatch for ${db} bereits aktiv (PID: ${lock_pid})"
            return 1
        fi
    fi

    echo "${BASHPID}" > "${dplock}"
    log_info "Running datapatch for ${db}..."

    if timeout --foreground --kill-after=60s "${DATAPATCH_TIMEOUT}" "${NEW_ORACLE_HOME}/OPatch/datapatch" -verbose 2>&1 | \
       tee "${LOGDIR}/datapatch_${db}_${TIMESTAMP}.log"; then
        log_success "Datapatch completed for ${db}"
        rm -f "${dplock}"
        return 0
    else
        log_error "Datapatch failed or timed out for ${db}"
        rm -f "${dplock}"
        return 1
    fi
}

wait_datapatch_batch() {
    local failed=0
    local pid
    for pid in "$@"; do
        if ! wait "${pid}"; then
            failed=1
        fi
    done
    [[ ${failed} -eq 0 ]]
}

run_datapatch() {
    log_info "=== Running Datapatch (up to ${MAX_PARALLEL_DATAPATCH} in parallel) ==="

    DATAPATCH_PIDS=()
    local -a batch_pids=()
    local failed=0
    local db pid

    for db in "${DATABASES[@]}"; do
        log_info "Starting datapatch for ${db}..."
        run_datapatch_single "${db}" &
        pid=$!
        DATAPATCH_PIDS+=("${pid}")
        batch_pids+=("${pid}")

        if [[ ${#batch_pids[@]} -ge ${MAX_PARALLEL_DATAPATCH} ]]; then
            if ! wait_datapatch_batch "${batch_pids[@]}"; then
                failed=1
            fi
            batch_pids=()
        fi
    done

    if [[ ${#batch_pids[@]} -gt 0 ]] && ! wait_datapatch_batch "${batch_pids[@]}"; then
        failed=1
    fi

    if [[ ${failed} -ne 0 ]]; then
        add_error "One or more datapatch runs failed"
        return 1
    fi

    log_success "All datapatch processes completed successfully"
}

# =============================================================================
# HEALTH CHECKS
# =============================================================================

database_health_check() {
    local phase="$1"
    local health_home="$2"
    local db outfile failed=0
    log_info "=== Database Health Check (${phase}) ==="

    for db in "${DATABASES[@]}"; do
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${health_home}"
        outfile="${LOGDIR}/health_${db}_${phase}_${TIMESTAMP}.log"

        if ! "${ORACLE_HOME}/bin/sqlplus" -s / as sysdba > "${outfile}" 2>&1 <<'EOF'
whenever sqlerror exit failure
set pagesize 1000 linesize 200 heading on feedback off
col tablespace_name format a30
col owner format a20
col object_type format a20

PROMPT --- Tablespace Usage (>80%) ---
SELECT tablespace_name, ROUND(used_percent, 2) as used_pct
FROM dba_tablespace_usage_metrics
WHERE used_percent > 80;

PROMPT --- Invalid Objects ---
SELECT owner, object_type, COUNT(*)
FROM dba_objects
WHERE status = 'INVALID'
GROUP BY owner, object_type;

PROMPT --- Recent Alerts (last 1 hour) ---
SELECT message_text
FROM (
    SELECT message_text, originating_timestamp
    FROM v$diag_alert_ext
    WHERE originating_timestamp > SYSDATE - 1/24
    ORDER BY originating_timestamp DESC
)
WHERE ROWNUM <= 10;

EXIT;
EOF
        then
            log_error "Health check failed for ${db}; see ${outfile}"
            add_error "Health check failed for ${db} (${phase})"
            failed=1
        else
            log_info "Health check for ${db} saved to: ${outfile}"
        fi
    done
    [[ ${failed} -eq 0 ]]
}

validate_patch_contents() {
    log_info "=== Validating Patch Contents ==="
    [[ -f "${RU_PATCH_DIR}/README.txt" ]] || die "README.txt is missing in ${RU_PATCH_DIR}"
    [[ -d "${RU_PATCH_DIR}/etc/config" ]] || die "RU patch metadata is missing: ${RU_PATCH_DIR}/etc/config"
    if [[ -n "${OJVM_PATCH_DIR:-}" ]]; then
        [[ -f "${OJVM_PATCH_DIR}/README.txt" ]] || die "README.txt is missing in ${OJVM_PATCH_DIR}"
        [[ -d "${OJVM_PATCH_DIR}/etc/config" ]] || die "OJVM patch metadata is missing: ${OJVM_PATCH_DIR}/etc/config"
    fi
    if [[ -n "${OPATCH_ZIP:-}" ]] && ! unzip -tq "${OPATCH_ZIP}" >/dev/null 2>&1; then
        die "OPatch archive is corrupt or unreadable: ${OPATCH_ZIP}"
    fi
    log_success "Patch content validation complete"
}

# =============================================================================
# REPORTING
# =============================================================================

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "${value}"
}

generate_final_report() {
    local report_file="${LOGDIR}/patch_report_${TIMESTAMP}.json"
    log_info "=== Generating Final Report ==="

    local dbs_json=""
    local db
    for db in "${DATABASES[@]}"; do
        if [[ -n "${dbs_json}" ]]; then
            dbs_json+=", "
        fi
        dbs_json+="\"$(json_escape "${db}")\""
    done

    local host_json patch_json version_json old_home_json new_home_json ojvm_json
    host_json=$(json_escape "$(hostname)")
    patch_json=$(json_escape "${RU_PATCH_NUM}")
    version_json=$(json_escape "${NEW_PATCH_VERSION}")
    old_home_json=$(json_escape "${CURRENT_ORACLE_HOME}")
    new_home_json=$(json_escape "${NEW_ORACLE_HOME}")
    ojvm_json=$(json_escape "${OJVM_PATCH_NUM:-N/A}")

    cat > "${report_file}" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "host": "${host_json}",
  "status": "SUCCESS",
  "patch": "${patch_json}",
  "version": "${version_json}",
  "old_home": "${old_home_json}",
  "new_home": "${new_home_json}",
  "ojvm_patch": "${ojvm_json}",
  "databases": [ ${dbs_json} ]
}
EOF
    log_info "JSON Report generated: ${report_file}"
}

# =============================================================================
# POST-PATCH VALIDATION
# =============================================================================

post_patch_checks() {
    log_info "=== Post-Patch Validation ==="

    export ORACLE_HOME="${NEW_ORACLE_HOME}"

    for db in "${DATABASES[@]}"; do
        export ORACLE_SID="${db}"

        log_info "Validating database ${db}..."

        local db_status
        if ! db_status=$(get_db_status "${NEW_ORACLE_HOME}" "${db}"); then
            log_error "Could not query database status for ${db}"
            add_error "Database status query failed for ${db}"
            continue
        fi

        if [[ "${db_status}" != *"OPEN"* ]]; then
            log_error "Database ${db} is not OPEN: ${db_status}"
            add_error "Database ${db} not OPEN"
            continue
        fi

        log_success "Database ${db} is OPEN"

        if ! "${NEW_ORACLE_HOME}/bin/sqlplus" -s / as sysdba 2>&1 <<'EOF' | tee -a "${LOGFILE}"
whenever sqlerror exit failure
set pagesize 100 linesize 200
col action_time format a30
col action format a20
col version format a15
col description format a50

SELECT action_time, action, version, description
FROM dba_registry_sqlpatch
ORDER BY action_time DESC
FETCH FIRST 5 ROWS ONLY;
exit;
EOF
        then
            log_error "Could not query SQL patch registry for ${db}"
            add_error "SQL patch registry query failed for ${db}"
        fi

        local invalid_count
        if ! invalid_count=$(get_invalid_count "${NEW_ORACLE_HOME}" "${db}" | tr -d '[:space:]'); then
            log_error "Invalid object query failed for ${db}"
            add_error "Invalid object query failed for ${db}"
            continue
        fi
        if [[ ! "${invalid_count}" =~ ^[0-9]+$ ]]; then
            log_error "Could not determine invalid object count for ${db}: ${invalid_count}"
            add_error "Invalid object query failed for ${db}"
            continue
        fi

        log_info "Invalid objects in ${db}: ${invalid_count}"
        if [[ ${invalid_count} -gt 0 ]]; then
            log_warn "Invalid objects detected in ${db} - consider running utlrp.sql"
        fi
    done
}

# =============================================================================
# ROLLBACK FUNCTION
# =============================================================================

rollback() {
    acquire_lock
    load_switch_state
    if [[ "${PATCH_PHASE}" == "DATAPATCH_STARTED" || "${PATCH_PHASE}" == "COMPLETE" ]]; then
        die "Automatic Home rollback is blocked after datapatch began; perform a coordinated SQL patch rollback using Oracle's documented procedure"
    fi
    [[ -w /etc/oratab ]] || die "/etc/oratab is not writable; rollback was not started"
    [[ -x "${OLD_ORACLE_HOME}/bin/sqlplus" && -x "${NEW_ORACLE_HOME}/bin/sqlplus" ]] || die "Required sqlplus binary is missing; rollback was not started"
    log_warn "=== INITIATING ROLLBACK ==="
    log_warn "New home: ${NEW_ORACLE_HOME}"
    log_warn "Old home: ${OLD_ORACLE_HOME}"
    log_warn "Databases: ${DATABASES[*]}"

    if [[ "${UNATTENDED_MODE}" != "true" ]]; then
        local confirmation
        read -r -p "Type ROLLBACK to continue: " confirmation
        [[ "${confirmation}" == "ROLLBACK" ]] || { log_info "Rollback cancelled"; return 0; }
    fi

    if ! rollback_databases; then
        die "Rollback incomplete; state file preserved at ${STATE_FILE}"
    fi
}

# =============================================================================
# MODE FUNCTIONS
# =============================================================================

test_mode() {
    acquire_lock
    log_info "=== TEST MODE - No Database Switch ==="

    check_prerequisites
    check_supported_topology
    select_patch
    validate_patch_contents

    if [[ "${DRY_RUN}" == "true" ]]; then
        NEW_ORACLE_HOME="${ORACLE_BASE}/19_${NEW_PATCH_VERSION}_${TIMESTAMP}"
        log_success "[DRY-RUN] Validation completed; no files, inventory, databases, or oratab were changed"
        log_info "[DRY-RUN] Planned Oracle Home: ${NEW_ORACLE_HOME}"
        return 0
    fi

    clone_oracle_home
    update_opatch
    apply_patches

    log_success "========================================="
    log_success "TEST MODE COMPLETED SUCCESSFULLY"
    log_success "New Oracle Home: ${NEW_ORACLE_HOME}"
    log_success "========================================="
    log_info "Next steps:"
    log_info "1. Verify patches: ${NEW_ORACLE_HOME}/OPatch/opatch lspatches"
    log_info "2. Run in PROD mode: ${SCRIPT_NAME} --prod"
    log_info "3. To remove the test home safely: ${SCRIPT_NAME} --cleanup ${NEW_ORACLE_HOME}"
    
    generate_final_report
}

production_mode() {
    acquire_lock
    local force_mode="${1:-}"

    log_info "=== PRODUCTION MODE - Full Patching with Database Switch ==="

    local skip_confirmations=false

    if [[ "${DRY_RUN}" == "true" ]]; then
        skip_confirmations=true
        log_info "Running in DRY-RUN mode"
    elif [[ "${force_mode}" == "--force" ]]; then
        skip_confirmations=true
        log_warn "Running in FORCE mode - skipping all confirmations"
    elif [[ "${UNATTENDED_MODE:-false}" == "true" ]]; then
        skip_confirmations=true
        log_warn "Running in UNATTENDED mode (from config) - skipping confirmations"
    fi

    if [[ "${skip_confirmations}" == "false" ]]; then
        echo ""
        echo -e "${YELLOW}[!]  WARNING: This will cause DATABASE DOWNTIME [!]${NC}"
        echo ""
        echo "This script will:"
        echo "  1. Clone current Oracle Home"
        echo "  2. Apply patches to new home"
        echo "  3. Switch databases to new home (downtime duration depends on the environment)"
        echo "  4. Run and verify datapatch (parallel, up to ${MAX_PARALLEL_DATAPATCH})"
        echo "  5. Preserve the previous Oracle Home for rollback"
        echo ""
        read -r -p "Do you want to continue? (yes/no): " confirm

        if [[ "${confirm}" != "yes" ]]; then
            log_info "Operation cancelled by user"
            exit 0
        fi
    else
        log_info "Skipping initial confirmation (unattended mode)"
    fi

    check_prerequisites
    [[ -r /etc/oratab && -w /etc/oratab ]] || die "/etc/oratab must be readable and writable by ${REQUIRED_USER}"
    check_supported_topology
    select_patch
    validate_patch_contents

    echo ""
    log_info "=== Patch Summary ==="
    log_info "Release Update: ${RU_PATCH_NUM}"
    log_info "Target Version: ${NEW_PATCH_VERSION}"
    [[ -n "${OJVM_PATCH_NUM:-}" ]] && log_info "OJVM Patch: ${OJVM_PATCH_NUM}"
    [[ -n "${OPATCH_ZIP:-}" ]] && log_info "OPatch Update: $(basename "${OPATCH_ZIP}")"
    echo ""

    if [[ "${DRY_RUN}" == "true" ]]; then
        NEW_ORACLE_HOME="${ORACLE_BASE}/19_${NEW_PATCH_VERSION}_${TIMESTAMP}"
        log_success "[DRY-RUN] Production plan validated; no files, inventory, databases, or oratab were changed"
        log_info "[DRY-RUN] Planned Oracle Home: ${NEW_ORACLE_HOME}"
        return 0
    fi

    log_info "=== PHASE 1: PREPARATION (No Downtime) ==="
    log_info "Current databases will continue running during this phase"
    echo ""

    clone_oracle_home
    update_opatch
    apply_patches

    log_success "=== PHASE 1 COMPLETED ==="
    log_success "New Oracle Home prepared: ${NEW_ORACLE_HOME}"
    log_success "All patches applied successfully"
    echo ""

    # Read databases for health check
    read_databases_from_oratab "${CURRENT_ORACLE_HOME}" DATABASES
    if ! database_health_check "pre-patch" "${CURRENT_ORACLE_HOME}"; then
        die "Pre-patch health validation failed; database switch was not started"
    fi

    if [[ "${skip_confirmations}" == "false" ]]; then
        log_info "Preparation complete. Ready for database switch."
        echo ""
        echo -e "${YELLOW}[!]  DOWNTIME PHASE: Database switch will happen now [!]${NC}"
        echo ""
        echo "Affected databases:"
        for db in "${DATABASES[@]}"; do
            echo "  - ${db}"
        done
        echo ""
        echo "Expected downtime: environment-dependent; verify on test first"
        echo ""
        read -r -p "Start DOWNTIME phase now? (yes/no): " confirm_downtime

        if [[ "${confirm_downtime}" != "yes" ]]; then
            log_info "Database switch cancelled; no database or oratab changes were made"
            log_info "Prepared home remains registered at: ${NEW_ORACLE_HOME}"
            log_info "To abandon it safely, run: ${SCRIPT_NAME} --cleanup ${NEW_ORACLE_HOME}"
            exit 0
        fi
    else
        log_info "FORCE/UNATTENDED mode - proceeding with database switch automatically"
        log_info "Affected databases: ${DATABASES[*]}"
    fi

    echo ""
    log_info "=== PHASE 2: DATABASE SWITCH (DOWNTIME) ==="

    switch_database

    log_success "=== PHASE 2 COMPLETED ==="
    log_success "All databases switched to new home successfully"
    echo ""

    log_info "=== PHASE 3: DATAPATCH ==="
    log_info "Databases are OPEN; waiting for all datapatch runs to finish"
    echo ""

    PATCH_PHASE="DATAPATCH_STARTED"
    save_switch_state || handle_switch_failure "Could not persist datapatch phase"
    if ! run_datapatch; then
        die "Datapatch failed or timed out; do not switch Homes blindly—follow Oracle's documented SQL patch recovery/rollback procedure"
    fi
    PATCH_PHASE="COMPLETE"
    if ! save_switch_state; then
        log_warn "Could not mark state COMPLETE; conservative rollback guard remains in effect"
    fi

    log_success "=== PHASE 3 COMPLETED ==="
    echo ""

    log_info "=== PHASE 4: POST-PATCH VALIDATION ==="

    post_patch_checks
    check_errors || die "Post-patch validation failed"

    log_success "=== PHASE 4 COMPLETED ==="
    echo ""

    log_info "=== PHASE 5: ROLLBACK PRESERVATION ==="
    log_success "Previous Oracle Home preserved: ${CURRENT_ORACLE_HOME}"
    log_info "Cleanup is intentionally manual: ${SCRIPT_NAME} --cleanup"
    echo ""

    if ! database_health_check "post-patch" "${NEW_ORACLE_HOME}"; then
        die "Final database health check failed"
    fi
    check_errors || die "Final health validation failed"
    generate_final_report

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}PATCHING COMPLETED SUCCESSFULLY${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_success "New Oracle Home: ${NEW_ORACLE_HOME}"
    log_success "Old Oracle Home: ${CURRENT_ORACLE_HOME}"
    log_success "Patch Version: ${NEW_PATCH_VERSION}"
    echo ""
    log_info "Datapatch Status:"
    log_info "  - Completed successfully for: ${DATABASES[*]}"
    log_info "  - Log files: ${LOGDIR}/datapatch_*_${TIMESTAMP}.log"
    echo ""
    log_info "Next Steps:"
    log_info "  1. Verify listener ownership and registration"
    log_info "  2. Check invalid objects and application connectivity"
    log_info "  3. Run full application smoke tests"
    echo ""
    log_info "Post-datapatch rollback:"
    log_info "  Automatic Home rollback is intentionally blocked after datapatch starts"
    log_info "  Use Oracle's documented coordinated SQL patch rollback procedure"
    log_info "  Old home and state metadata are preserved until explicit cleanup"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Write summary file
    local summary_file="${ORACLE_BASE}/autopatchinstall.log"
    cat > "${summary_file}" <<EOF
Oracle Database Patching Summary
=================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Status: SUCCESS

Environment:
  Hostname: $(hostname)
  User: $(whoami)

Patch Details:
  Release Update: ${RU_PATCH_NUM}
  Target Version: ${NEW_PATCH_VERSION}
  OJVM Patch: ${OJVM_PATCH_NUM:-N/A}

Oracle Homes:
  Old Home: ${CURRENT_ORACLE_HOME}
  New Home: ${NEW_ORACLE_HOME}

Databases Patched:
$(for db in "${DATABASES[@]}"; do echo "  - ${db}"; done)

Datapatch:
  Status: COMPLETED
  Log Directory: ${LOGDIR}

Detailed Log: ${LOGFILE}

Next Steps:
  - Verify listener ownership and registration
  - Verify invalid objects
  - Run application smoke tests
  - Keep old home until rollback window is explicitly closed
EOF

    log_info "Summary written to: ${summary_file}"
}

interactive_mode() {
    show_status

    echo ""
    echo -e "${BLUE}What would you like to do?${NC}"
    echo "  1) Test patching (no database switch)"
    echo "  2) Production patching (with downtime)"
    echo "  3) Show status only (refresh)"
    echo "  4) Cleanup old homes"
    echo "  5) Exit"
    echo ""
    read -r -p "Choose option [1-5]: " choice

    case ${choice} in
        1) test_mode ;;
        2) production_mode ;;
        3) show_status ;;
        4) auto_cleanup ;;
        5) exit 0 ;;
        *) log_error "Invalid option"; exit 1 ;;
    esac
}

# =============================================================================
# USAGE / HELP
# =============================================================================

usage() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Oracle 19c Out-of-Place Patching Framework v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}USAGE:${NC}"
    echo "    ${SCRIPT_NAME} [OPTIONS]"
    echo ""
    echo -e "${GREEN}OPTIONS:${NC}"
    echo "    --status            Show detailed status overview"
    echo "    --test              Prepare and patch a new Home; no DB switch"
    echo "    --prod              Production mode (database downtime, no automatic cleanup)"
    echo "    --prod --force      Production mode unattended (no confirmations)"
    echo "    --cleanup           Find and confirm eligible old Homes"
    echo "    --cleanup HOME      Detach and remove a specific eligible Oracle Home"
    echo "    --rollback          Roll back a saved switch only before datapatch starts"
    echo "    --create-config     Create default .patchrc configuration"
    echo "    -h, -?, --help      Show this help message"
    echo ""
    echo -e "${GREEN}INTERACTIVE MODE:${NC}"
    echo "    Run without options for interactive menu"
    echo ""
    echo -e "${GREEN}EXAMPLES:${NC}"
    echo -e "    ${YELLOW}# First time setup${NC}"
    echo "    ${SCRIPT_NAME} --create-config"
    echo "    vi ~/.patchrc"
    echo ""
    echo -e "    ${YELLOW}# Check current status${NC}"
    echo "    ${SCRIPT_NAME} --status"
    echo ""
    echo -e "    ${YELLOW}# Test on non-production${NC}"
    echo "    ${SCRIPT_NAME} --test"
    echo ""
    echo -e "    ${YELLOW}# Production patching (interactive)${NC}"
    echo "    ${SCRIPT_NAME} --prod"
    echo ""
    echo -e "    ${YELLOW}# Production patching (unattended)${NC}"
    echo "    ${SCRIPT_NAME} --prod --force"
    echo ""
    echo -e "    ${YELLOW}# Interactive mode${NC}"
    echo "    ${SCRIPT_NAME}"
    echo ""
    echo -e "${GREEN}CONFIGURATION:${NC}"
    echo "    Config file: ${PATCHRC}"
    echo -e "    Oracle Inventory: ${INVENTORY_LOC} ${GREEN}(auto-detected)${NC}"
    echo "    Patch directory: ${PATCH_BASE_DIR}"
    echo "    Log directory: ${LOGDIR}"
    echo "    Oracle User: ${REQUIRED_USER}"
    echo ""
    echo -e "${GREEN}FEATURES:${NC}"
    echo "    ✓ Out-of-Place patching with measured downtime"
    echo "    ✓ Automatic RU/OJVM classification"
    echo "    ✓ Auto-detected Oracle Inventory"
    echo "    ✓ Hostname-based patch directories"
    echo "    ✓ Test mode without database switch"
    echo "    ✓ Dry-run and unattended modes"
    echo "    ✓ Multi-database support"
    echo "    ✓ Guarded, explicit old-Home cleanup"
    echo "    ✓ Parallel datapatch with result verification"
    echo "    ✓ Persistent and automatic rollback capability"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        initialize
        case "${DEFAULT_MODE}" in
            interactive) interactive_mode ;;
            test) test_mode ;;
            prod) production_mode ;;
        esac
        return
    fi

    case "$1" in
        --status)
            [[ $# -eq 1 ]] || { echo "Unexpected arguments for --status" >&2; return 2; }
            initialize
            show_status
            ;;
        --test)
            [[ $# -eq 1 ]] || { echo "Unexpected arguments for --test" >&2; return 2; }
            initialize
            test_mode
            ;;
        --prod)
            [[ $# -le 2 ]] || { echo "Unexpected arguments for --prod" >&2; return 2; }
            if [[ $# -eq 2 && "$2" != "--force" ]]; then
                echo "Unknown option for --prod: $2" >&2
                return 2
            fi
            initialize
            if [[ "${2:-}" == "--force" ]]; then
                production_mode --force
            else
                production_mode
            fi
            ;;
        --cleanup)
            [[ $# -le 2 ]] || { echo "Unexpected arguments for --cleanup" >&2; return 2; }
            initialize
            if [[ -n "${2:-}" ]]; then
                acquire_lock
                cleanup_single_home "$2"
            else
                auto_cleanup
            fi
            ;;
        --rollback)
            [[ $# -eq 1 ]] || { echo "Unexpected arguments for --rollback" >&2; return 2; }
            initialize
            rollback
            ;;
        --create-config)
            [[ $# -eq 1 ]] || { echo "Unexpected arguments for --create-config" >&2; return 2; }
            create_default_config
            ;;
        -h|-\?|--help)
            [[ $# -eq 1 ]] || { echo "Unexpected arguments for --help" >&2; return 2; }
            usage
            ;;
        interactive)
            [[ $# -eq 1 ]] || { echo "Unexpected arguments for interactive mode" >&2; return 2; }
            initialize
            interactive_mode
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            echo "" >&2
            usage >&2
            return 2
            ;;
    esac
}

# Run main only when executed, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
