#!/usr/bin/env bash
# =============================================================================
# Oracle 19c Out-of-Place Patching Framework
# Version: 2.0.0
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME=$(basename "$0")
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

LOCK_DIR="/tmp/oracle_patching.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
CLEANUP_TMPFILE=$(mktemp -t cleanup_candidates.XXXXXX)

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
    [[ -n "${CLEANUP_TMPFILE}" && -f "${CLEANUP_TMPFILE}" ]] && rm -f "${CLEANUP_TMPFILE}"
    
    # Remove lock directory
    if [[ -d "${LOCK_DIR}" ]]; then
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
LOGFILE="${LOGDIR}/oop_patching_${TIMESTAMP}.log"
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
# COMMAND EXECUTION WRAPPER
# =============================================================================

execute_cmd() {
    local description="$1"
    shift
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] ${description}"
        log_debug "[DRY-RUN] Command: $*"
        return 0
    fi
    
    log_info "${description}"
    "$@"
}

# =============================================================================
# CONFIG-FILE HANDLING
# =============================================================================

validate_config() {
    local errors=0
    
    [[ -z "${ORACLE_BASE}" ]] && { log_error "ORACLE_BASE nicht konfiguriert"; ((errors++)); }
    [[ -z "${CURRENT_ORACLE_HOME}" ]] && { log_error "CURRENT_ORACLE_HOME nicht konfiguriert"; ((errors++)); }
    [[ ! -d "${ORACLE_BASE}" ]] && { log_error "ORACLE_BASE existiert nicht: ${ORACLE_BASE}"; ((errors++)); }
    [[ ! -d "${CURRENT_ORACLE_HOME}" ]] && { log_error "CURRENT_ORACLE_HOME existiert nicht: ${CURRENT_ORACLE_HOME}"; ((errors++)); }
    
    if [[ ${AUTO_CLEANUP_DAYS} -lt ${MIN_CLEANUP_DAYS} ]]; then
        log_warn "AUTO_CLEANUP_DAYS < ${MIN_CLEANUP_DAYS} ist riskant (aktuell: ${AUTO_CLEANUP_DAYS})"
    fi
    
    [[ ${errors} -gt 0 ]] && return 1
    return 0
}

load_config() {
    if [[ -f "${PATCHRC}" ]]; then
        log_info "Loading configuration from ${PATCHRC}"
        
        # Syntax check before loading
        if ! bash -n "${PATCHRC}" 2>/dev/null; then
            die "Konfigurationsdatei ${PATCHRC} hat Syntaxfehler!"
        fi
        
        # shellcheck source=/dev/null
        source "${PATCHRC}"

        if [[ -z "${INVENTORY_LOC}" ]] && [[ -n "${AUTO_INVENTORY_LOC}" ]]; then
            INVENTORY_LOC="${AUTO_INVENTORY_LOC}"
        fi
    else
        log_info "No config file found, using defaults"
    fi
    
    # Validate after loading
    validate_config || die "Konfigurationsvalidierung fehlgeschlagen"
}

create_default_config() {
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

# Nach wie vielen Tagen werden alte Homes automatisch aufgeräumt?
AUTO_CLEANUP_DAYS=30

# Wie viele Homes parallel behalten (aktuell + Rollback)?
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

# ============================================================================
# SYSTEM
# ============================================================================

# Oracle User (Owner der Oracle Software)
REQUIRED_USER="ora19"

# Datapatch Timeout in Sekunden
DATAPATCH_TIMEOUT=7200

# ============================================================================
# BENACHRICHTIGUNGEN (optional)
# ============================================================================

# E-Mail für Notifications nach Abschluss (leer = keine Mails)
NOTIFY_EMAIL=""

EOF

    log_success "Default config created: ${PATCHRC}"
    exit 0
}

# =============================================================================
# LOCKING
# =============================================================================

acquire_lock() {
    if [[ -d "${LOCK_DIR}" ]]; then
        if [[ -f "${LOCK_PID_FILE}" ]]; then
            local locked_pid
            locked_pid=$(cat "${LOCK_PID_FILE}" 2>/dev/null || echo "")
            
            if [[ -n "${locked_pid}" ]] && kill -0 "${locked_pid}" 2>/dev/null; then
                log_error "Skript läuft bereits (PID: ${locked_pid})"
                exit 1
            else
                log_warn "Entferne verwaistes Lock (PID ${locked_pid} nicht mehr aktiv)"
                rm -rf "${LOCK_DIR}"
            fi
        fi
    fi
    
    mkdir "${LOCK_DIR}" 2>/dev/null || die "Konnte Lock-Verzeichnis nicht erstellen: ${LOCK_DIR}"
    echo $$ > "${LOCK_PID_FILE}"
    
    log_debug "Lock acquired (PID: $$)"
}

# =============================================================================
# DATABASE HELPER FUNCTIONS
# =============================================================================

# Read databases as array from oratab
read_databases_from_oratab() {
    local oracle_home="$1"
    local -n result_array=$2
    
    mapfile -t result_array < <(
        grep -E "^[^#].*:${oracle_home}:" /etc/oratab 2>/dev/null | cut -d':' -f1 || true
    )
}

# Get Oracle Home version (multiple fallback methods)
get_home_version() {
    local oracle_home="$1"
    local version=""
    
    # Method 1: sqlplus -V (most reliable, no DB connection needed)
    if [[ -x "${oracle_home}/bin/sqlplus" ]]; then
        version=$("${oracle_home}/bin/sqlplus" -V 2>/dev/null | awk '/^Version/{print $2}')
        if [[ -n "${version}" ]]; then
            echo "${version}"
            return 0
        fi
    fi
    
    # Method 2: opatch lspatches (extract from RU patch description)
    if [[ -x "${oracle_home}/OPatch/opatch" ]]; then
        version=$("${oracle_home}/OPatch/opatch" lspatches 2>/dev/null | \
                  grep -oE "19\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
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

# Ensure log directory exists
mkdir -p "${LOGDIR}" 2>/dev/null || true

# Load config first
load_config

# Apply hostname-based directory if enabled
if [[ "${USE_HOSTNAME_DIR}" == "true" ]]; then
    PATCH_BASE_DIR="${PATCH_BASE_DIR_BASE}/$(hostname -s)"
else
    PATCH_BASE_DIR="${PATCH_BASE_DIR_BASE}"
fi

# Make critical variables readonly after initialization
readonly ORACLE_BASE CURRENT_ORACLE_HOME INVENTORY_LOC PATCH_BASE_DIR LOGDIR REQUIRED_USER

# Declare global arrays
declare -a DATABASES=()
declare -a DATAPATCH_PIDS=()

# Global patch variables
NEW_ORACLE_HOME=""
RU_PATCH_DIR=""
RU_PATCH_NUM=""
NEW_PATCH_VERSION=""
OPATCH_ZIP=""
OJVM_PATCH_DIR=""
OJVM_PATCH_NUM=""

# =============================================================================
# STATUS OVERVIEW
# =============================================================================
get_home_version "/oracle/19"
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

    # Reset temp file
    > "${CLEANUP_TMPFILE}"

    local homes
    homes=$(grep -oP '(?<=LOC=")[^"]+' "${INVENTORY_LOC}/ContentsXML/inventory.xml" 2>/dev/null || echo "")

    # Skip if no homes found
    if [[ -z "${homes}" ]]; then
        echo -e "  ${GREEN}✓ No cleanup candidates found${NC}" 
        return 0
    fi

    local found_candidates=false

    while IFS= read -r home; do
        [[ -z "${home}" ]] && continue

        # Check if home is in oratab (active)
        if grep -q "${home}" /etc/oratab 2>/dev/null; then
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
    done <<< "${homes}"

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
    > "${CLEANUP_TMPFILE}"

    if [[ ${#candidates[@]} -eq 0 ]]; then
        log_success "No homes to cleanup"
        return 0
    fi

    for old_home in "${candidates[@]}"; do
        log_info "Cleaning up: ${old_home}"
        cleanup_single_home "${old_home}" --auto
    done
}

cleanup_single_home() {
    local old_home="$1"
    local auto_mode="${2:-}"
    
    # Input validation
    [[ -z "${old_home}" ]] && die "Kein Home angegeben"
    [[ "${old_home}" == "/" ]] && die "Root-Pfad nicht erlaubt"
    [[ ! "${old_home}" =~ ^/oracle ]] && die "Nur /oracle-Pfade erlaubt für Cleanup"
    [[ ! -d "${old_home}" ]] && { log_error "Home existiert nicht: ${old_home}"; return 1; }
    [[ ! -f "${old_home}/bin/oracle" ]] && { log_error "Kein gültiges Oracle Home: ${old_home}"; return 1; }

    # Check for running databases
    local running_dbs
    running_dbs=$(pgrep -f "ora_pmon.*${old_home}" 2>/dev/null | wc -l || echo "0")

    if [[ ${running_dbs} -gt 0 ]]; then
        log_error "Databases still running from ${old_home}! Skipping cleanup."
        return 1
    fi

    local home_age_days
    home_age_days=$(get_home_age_days "${old_home}")

    if [[ "${auto_mode}" != "--auto" ]]; then
        log_warn "Home: ${old_home}"
        log_warn "Age: ${home_age_days} days"
        read -p "Delete this home? (yes/no): " confirm

        if [[ "${confirm}" != "yes" ]]; then
            log_info "Cleanup skipped"
            return 0
        fi
    fi

    log_info "Starting cleanup of ${old_home}..."

    if [[ -x "${old_home}/deinstall/deinstall" ]]; then
        log_info "Running deinstall..."
        export ORACLE_HOME="${old_home}"
        echo -e "yes\n" | "${old_home}/deinstall/deinstall" -silent 2>&1 | tee -a "${LOGFILE}" || true
    fi

    if grep -q "${old_home}" "${INVENTORY_LOC}/ContentsXML/inventory.xml" 2>/dev/null; then
        log_info "Removing from inventory..."
        cp "${INVENTORY_LOC}/ContentsXML/inventory.xml" \
           "${INVENTORY_LOC}/ContentsXML/inventory.xml.bak_${TIMESTAMP}"
        sed -i "\|${old_home}|d" "${INVENTORY_LOC}/ContentsXML/inventory.xml"
    fi

    log_info "Removing directory ${old_home}..."
    rm -rf "${old_home}"

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
    required_space=$(du -sb "${CURRENT_ORACLE_HOME}" 2>/dev/null | \
                     awk -v factor="${SPACE_BUFFER_FACTOR}" '{print int($1 * factor / 1024 / 1024)}')
    available_space=$(df -m "${ORACLE_BASE}" 2>/dev/null | tail -1 | awk '{print $4}')
    
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
    local required_tools=("rsync" "unzip")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            die "Required tool '${tool}' is not installed"
        fi
    done

    # Check for running patch processes
    if pgrep -f "opatch|datapatch" 2>/dev/null | grep -v $$ > /dev/null; then
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
    mapfile -t patch_options < <(
        find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" -printf "%f\n" 2>/dev/null | sort -V || true
    )

    if [[ ${#patch_options[@]} -eq 0 ]]; then
        die "No Release Update patches found in ${PATCH_BASE_DIR}"
    fi

    if [[ "${UNATTENDED_MODE:-false}" == "true" ]]; then
        # Select latest patch
        RU_PATCH_DIR="${PATCH_BASE_DIR}/${patch_options[-1]}"
    else
        echo ""
        echo "Available patches in ${PATCH_BASE_DIR}:"
        select opt in "${patch_options[@]}" "Abbruch"; do
            case $opt in
                "Abbruch") exit 0 ;;
                "") echo "Ungültige Auswahl" ;;
                *) RU_PATCH_DIR="${PATCH_BASE_DIR}/${opt}"; break ;;
            esac
        done
    fi

    RU_PATCH_NUM=$(basename "${RU_PATCH_DIR}")
    log_info "Selected RU Patch: ${RU_PATCH_NUM}"

    local readme="${RU_PATCH_DIR}/README.txt"
    if [[ -f "${readme}" ]]; then
        NEW_PATCH_VERSION=$(grep -oE "19\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "${readme}" 2>/dev/null | \
                           head -1 || echo "19.UNKNOWN")
    else
        NEW_PATCH_VERSION="19.UNKNOWN"
        log_warn "README.txt not found, using version: ${NEW_PATCH_VERSION}"
    fi

    log_info "Target Version: ${NEW_PATCH_VERSION}"

    # Find OPatch update
    OPATCH_ZIP=$(find "${PATCH_BASE_DIR}" -maxdepth 1 -type f -name "p6880880*.zip" 2>/dev/null | head -1 || true)
    [[ -n "${OPATCH_ZIP}" ]] && log_info "Found OPatch Update: $(basename "${OPATCH_ZIP}")"

    # Find OJVM patch
    OJVM_PATCH_DIR=""
    OJVM_PATCH_NUM=""
    
    local -a all_patch_dirs=()
    mapfile -t all_patch_dirs < <(find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null || true)
    
    for patch_dir in "${all_patch_dirs[@]}"; do
        local patch_readme="${patch_dir}/README.txt"
        if [[ -f "${patch_readme}" ]] && grep -q "OJVM" "${patch_readme}" 2>/dev/null; then
            OJVM_PATCH_DIR="${patch_dir}"
            OJVM_PATCH_NUM=$(basename "${patch_dir}")
            log_info "Detected OJVM Patch: ${OJVM_PATCH_NUM}"
            break
        fi
    done
}

detect_patches() {
    select_patch
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
    required_space=$(du -sb "${CURRENT_ORACLE_HOME}" 2>/dev/null | \
                     awk -v factor="${SPACE_BUFFER_FACTOR}" '{print int($1 * factor / 1024 / 1024)}')
    available_space=$(df -m "${ORACLE_BASE}" 2>/dev/null | tail -1 | awk '{print $4}')

    log_info "Required: ${required_space} MB, Available: ${available_space} MB"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would clone to: ${NEW_ORACLE_HOME}"
        return 0
    fi

    # Create target directory
    mkdir -p "${NEW_ORACLE_HOME}"

    # rsync with progress
    log_info "Starting clone operation..."
    
    if ! rsync -a \
        --exclude='.patch_storage' \
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
        rm -rf "${NEW_ORACLE_HOME}/OPatch"
        mv "${NEW_ORACLE_HOME}/OPatch.bak_${TIMESTAMP}" "${NEW_ORACLE_HOME}/OPatch"
        return 1
    fi

    new_version=$(get_opatch_version "${NEW_ORACLE_HOME}")
    log_success "OPatch updated: ${current_version} -> ${new_version}"
}

# =============================================================================
# PATCH INSTALLATION
# =============================================================================

apply_patches() {
    log_info "=== Applying Patches to New Home ==="

    export ORACLE_HOME="${NEW_ORACLE_HOME}"
    export PATH="${NEW_ORACLE_HOME}/OPatch:${PATH}"

    log_info "Running conflict analysis..."

    cd "${RU_PATCH_DIR}"

    if ! ${NEW_ORACLE_HOME}/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./ 2>&1 | tee -a "${LOGFILE}"; then
        die "Conflict check failed"
    fi

    log_info "Applying Release Update ${RU_PATCH_NUM}..."

    if ! ${NEW_ORACLE_HOME}/OPatch/opatch apply -silent 2>&1 | tee -a "${LOGFILE}"; then
        die "RU Patch application failed"
    fi

    log_success "RU Patch ${RU_PATCH_NUM} applied successfully"

    if [[ -n "${OJVM_PATCH_DIR:-}" ]]; then
        log_info "Applying OJVM Patch ${OJVM_PATCH_NUM}..."

        cd "${OJVM_PATCH_DIR}"
        
        if ! ${NEW_ORACLE_HOME}/OPatch/opatch apply -silent 2>&1 | tee -a "${LOGFILE}"; then
            log_warn "OJVM Patch application failed (non-critical)"
        else
            log_success "OJVM Patch ${OJVM_PATCH_NUM} applied successfully"
        fi
    fi

    log_info "Verifying installed patches..."
    ${NEW_ORACLE_HOME}/OPatch/opatch lspatches 2>&1 | tee -a "${LOGFILE}"
}

# =============================================================================
# DATABASE SWITCH (DOWNTIME PHASE)
# =============================================================================

switch_database() {
    log_info "=== Switching Database to New Home ==="
    log_warn "[!]  DOWNTIME STARTS NOW [!]"

    local downtime_start
    downtime_start=$(date +%s)

    # Read databases as array
    read_databases_from_oratab "${CURRENT_ORACLE_HOME}" DATABASES

    if [[ ${#DATABASES[@]} -eq 0 ]]; then
        die "No databases found in /etc/oratab for home ${CURRENT_ORACLE_HOME}"
    fi

    log_info "Databases to switch: ${DATABASES[*]}"

    for db in "${DATABASES[@]}"; do
        log_info "Stopping database ${db}..."

        export ORACLE_SID="${db}"
        export ORACLE_HOME="${CURRENT_ORACLE_HOME}"

        # Stop listener for this DB
        local listener_name
        listener_name=$(ps -ef 2>/dev/null | grep "[t]nslsnr.*${db}" | awk '{print $9}' | head -1 || true)
        
        if [[ -n "${listener_name}" ]]; then
            ${CURRENT_ORACLE_HOME}/bin/lsnrctl stop "${listener_name}" 2>&1 | tee -a "${LOGFILE}" || true
        fi

        # Shutdown database
        if ! ${CURRENT_ORACLE_HOME}/bin/sqlplus -s / as sysdba 2>&1 | tee -a "${LOGFILE}" <<'EOF'
whenever sqlerror exit failure
shutdown immediate;
exit;
EOF
        then
            log_error "Failed to shutdown ${db}, attempting abort..."
            ${CURRENT_ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'EOF'
shutdown abort;
exit;
EOF
        fi

        log_success "Database ${db} stopped"
    done

    log_info "Updating /etc/oratab..."

    cp /etc/oratab "/etc/oratab.bak_${TIMESTAMP}"
    sed -i "s|${CURRENT_ORACLE_HOME}|${NEW_ORACLE_HOME}|g" /etc/oratab

    for db in "${DATABASES[@]}"; do
        log_info "Starting database ${db} from new home..."

        export ORACLE_SID="${db}"
        export ORACLE_HOME="${NEW_ORACLE_HOME}"

        if ! ${NEW_ORACLE_HOME}/bin/sqlplus -s / as sysdba 2>&1 | tee -a "${LOGFILE}" <<'EOF'
whenever sqlerror exit failure
startup;
exit;
EOF
        then
            die "Failed to start ${db} from new home - ROLLBACK REQUIRED"
        fi

        log_success "Database ${db} started from new home"

        # Start listener
        ${NEW_ORACLE_HOME}/bin/lsnrctl start LISTENER 2>&1 | tee -a "${LOGFILE}" || true
    done

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
    
    local dplock="/tmp/datapatch_${db}.lock"
    
    if [[ -f "${dplock}" ]]; then
        local lock_pid
        lock_pid=$(cat "${dplock}" 2>/dev/null || echo "")
        if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_warn "Datapatch for ${db} bereits aktiv (PID: ${lock_pid})"
            return 0
        fi
    fi
    
    echo $$ > "${dplock}"
    
    log_info "Running datapatch for ${db}..."
    
    if ${NEW_ORACLE_HOME}/OPatch/datapatch -verbose 2>&1 | \
       tee "${LOGDIR}/datapatch_${db}_${TIMESTAMP}.log"; then
        log_success "Datapatch completed for ${db}"
        rm -f "${dplock}"
        return 0
    else
        log_error "Datapatch failed for ${db}"
        rm -f "${dplock}"
        return 1
    fi
}

run_datapatch() {
    log_info "=== Running Datapatch (Background) ==="

    DATAPATCH_PIDS=()
    local running=0

    for db in "${DATABASES[@]}"; do
        # Limit parallel processes
        if [[ ${running} -ge ${MAX_PARALLEL_DATAPATCH} ]]; then
            wait -n
            ((running--))
        fi
        
        log_info "Starting datapatch for ${db} in background..."
        
        run_datapatch_single "${db}" &
        DATAPATCH_PIDS+=($!)
        ((running++))
    done

    log_info "Datapatch running in background (PIDs: ${DATAPATCH_PIDS[*]})"
    log_info "Monitor progress: tail -f ${LOGDIR}/datapatch_*_${TIMESTAMP}.log"
}

wait_for_datapatch() {
    [[ ${#DATAPATCH_PIDS[@]} -eq 0 ]] && return 0

    log_info "=== Waiting for Datapatch Completion ==="
    
    local timeout="${DATAPATCH_TIMEOUT}"
    local elapsed=0
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        local running=0
        
        for pid in "${DATAPATCH_PIDS[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                ((running++))
            fi
        done
        
        if [[ ${running} -eq 0 ]]; then
            log_success "All datapatch processes completed"
            return 0
        fi
        
        sleep 60
        elapsed=$((elapsed + 60))
        log_info "Datapatch still running (${running} processes)... (${elapsed}s elapsed)"
    done
    
    log_warn "Datapatch timeout reached - check logs manually"
}

# =============================================================================
# HEALTH CHECKS
# =============================================================================

database_health_check() {
    local phase="$1"
    log_info "=== Database Health Check (${phase}) ==="
    
    for db in "${DATABASES[@]}"; do
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${NEW_ORACLE_HOME}"
        
        local outfile="${LOGDIR}/health_${db}_${phase}_${TIMESTAMP}.log"
        
        ${ORACLE_HOME}/bin/sqlplus -s / as sysdba > "${outfile}" 2>&1 <<'EOF'
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
FROM v$diag_alert_ext
WHERE originating_timestamp > SYSDATE - 1/24
AND ROWNUM <= 10
ORDER BY originating_timestamp DESC;

EXIT;
EOF
        log_info "Health check for ${db} saved to: ${outfile}"
    done
}

validate_patch_contents() {
    log_info "=== Validating Patch Contents ==="
    [[ ! -f "${RU_PATCH_DIR}/README.txt" ]] && log_warn "README.txt fehlt in ${RU_PATCH_DIR}"
    [[ ! -d "${RU_PATCH_DIR}/etc/config" ]] && log_warn "Patch-Metadaten (etc/config) fehlen in ${RU_PATCH_DIR}"
    log_success "Validation complete"
}

# =============================================================================
# REPORTING
# =============================================================================

generate_final_report() {
    local report_file="${LOGDIR}/patch_report_${TIMESTAMP}.json"
    log_info "=== Generating Final Report ==="
    
    # Build database array for JSON
    local dbs_json
    dbs_json=$(printf '"%s", ' "${DATABASES[@]}" | sed 's/, $//')
    
    cat > "${report_file}" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "host": "$(hostname)",
  "status": "SUCCESS",
  "patch": "${RU_PATCH_NUM}",
  "version": "${NEW_PATCH_VERSION}",
  "old_home": "${CURRENT_ORACLE_HOME}",
  "new_home": "${NEW_ORACLE_HOME}",
  "ojvm_patch": "${OJVM_PATCH_NUM:-N/A}",
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
        db_status=$(get_db_status "${NEW_ORACLE_HOME}" "${db}")

        if [[ "${db_status}" != *"OPEN"* ]]; then
            log_error "Database ${db} is not OPEN: ${db_status}"
            add_error "Database ${db} not OPEN"
            continue
        fi

        log_success "Database ${db} is OPEN"

        ${NEW_ORACLE_HOME}/bin/sqlplus -s / as sysdba <<EOF | tee -a "${LOGFILE}"
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

        local invalid_count
        invalid_count=$(get_invalid_count "${NEW_ORACLE_HOME}" "${db}")
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
    log_warn "=== INITIATING ROLLBACK ==="

    # Read databases from NEW home
    read_databases_from_oratab "${NEW_ORACLE_HOME}" DATABASES

    for db in "${DATABASES[@]}"; do
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${NEW_ORACLE_HOME}"

        log_info "Stopping ${db} from new home..."

        ${NEW_ORACLE_HOME}/bin/sqlplus -s / as sysdba <<'EOF'
shutdown immediate;
exit;
EOF
    done

    # Restore oratab
    if [[ -f "/etc/oratab.bak_${TIMESTAMP}" ]]; then
        cp "/etc/oratab.bak_${TIMESTAMP}" /etc/oratab
        log_info "Restored oratab from backup"
    else
        local latest_backup
        latest_backup=$(ls -t /etc/oratab.bak_* 2>/dev/null | head -1)
        if [[ -n "${latest_backup}" ]]; then
            cp "${latest_backup}" /etc/oratab
            log_info "Restored from ${latest_backup}"
        else
            log_error "No oratab backup found!"
        fi
    fi

    local old_home
    old_home=$(grep "^${DATABASES[0]}:" /etc/oratab 2>/dev/null | cut -d':' -f2 || echo "")

    if [[ -z "${old_home}" ]]; then
        die "Could not determine old Oracle Home from oratab"
    fi

    for db in "${DATABASES[@]}"; do
        export ORACLE_SID="${db}"
        export ORACLE_HOME="${old_home}"

        log_info "Starting ${db} from old home (${old_home})..."

        if ! ${old_home}/bin/sqlplus -s / as sysdba <<'EOF'; then
startup;
exit;
EOF
            log_error "Failed to start ${db} from old home"
        else
            log_success "Database ${db} rolled back"
        fi
    done

    log_success "Rollback completed - databases running from ${old_home}"
}

# =============================================================================
# MODE FUNCTIONS
# =============================================================================

test_mode() {
    acquire_lock
    log_info "=== TEST MODE - No Database Switch ==="

    check_prerequisites
    detect_patches
    validate_patch_contents
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
    log_info "3. In case of issues, simply delete: ${NEW_ORACLE_HOME}"
    
    generate_final_report
}

production_mode() {
    acquire_lock
    local force_mode="${1:-}"

    log_info "=== PRODUCTION MODE - Full Patching with Database Switch ==="

    local skip_confirmations=false

    if [[ "${force_mode}" == "--force" ]]; then
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
        echo "  3. Switch databases to new home (DOWNTIME: ~2-3 minutes)"
        echo "  4. Run datapatch in background"
        echo "  5. Auto-cleanup old homes (older than ${AUTO_CLEANUP_DAYS} days)"
        echo ""
        read -p "Do you want to continue? (yes/no): " confirm

        if [[ "${confirm}" != "yes" ]]; then
            log_info "Operation cancelled by user"
            exit 0
        fi
    else
        log_info "Skipping initial confirmation (unattended mode)"
    fi

    check_prerequisites
    detect_patches
    validate_patch_contents

    echo ""
    log_info "=== Patch Summary ==="
    log_info "Release Update: ${RU_PATCH_NUM}"
    log_info "Target Version: ${NEW_PATCH_VERSION}"
    [[ -n "${OJVM_PATCH_NUM:-}" ]] && log_info "OJVM Patch: ${OJVM_PATCH_NUM}"
    [[ -n "${OPATCH_ZIP:-}" ]] && log_info "OPatch Update: $(basename "${OPATCH_ZIP}")"
    echo ""

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
    database_health_check "pre-patch"

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
        echo "Expected downtime: 2-3 minutes"
        echo ""
        read -p "Start DOWNTIME phase now? (yes/no): " confirm_downtime

        if [[ "${confirm_downtime}" != "yes" ]]; then
            log_info "Database switch cancelled by user"
            log_info "New home is ready at: ${NEW_ORACLE_HOME}"
            log_info ""
            log_info "To complete patching later, you can:"
            log_info "  1. Manually update /etc/oratab to point to new home"
            log_info "  2. Shutdown databases and restart from new home"
            log_info "  3. Run datapatch manually"
            log_info ""
            log_info "Or delete the new home if you want to abort:"
            log_info "  rm -rf ${NEW_ORACLE_HOME}"
            exit 0
        fi
    else
        log_info "FORCE/UNATTENDED mode - proceeding with database switch automatically"
        read_databases_from_oratab "${CURRENT_ORACLE_HOME}" DATABASES
        log_info "Affected databases: ${DATABASES[*]}"
    fi

    echo ""
    log_info "=== PHASE 2: DATABASE SWITCH (DOWNTIME) ==="

    switch_database

    log_success "=== PHASE 2 COMPLETED ==="
    log_success "All databases switched to new home successfully"
    echo ""

    log_info "=== PHASE 3: DATAPATCH (Background) ==="
    log_info "Databases are now OPEN and available"
    log_info "Datapatch will run in background"
    echo ""

    run_datapatch

    log_success "=== PHASE 3 STARTED ==="
    log_info "Datapatch is running in background for all databases"
    log_info "Monitor progress: tail -f ${LOGDIR}/datapatch_*_${TIMESTAMP}.log"
    echo ""

    log_info "=== PHASE 4: POST-PATCH VALIDATION ==="

    post_patch_checks

    log_success "=== PHASE 4 COMPLETED ==="
    echo ""

    log_info "=== PHASE 5: AUTO-CLEANUP ==="
    log_info "Checking for old Oracle Homes to cleanup..."
    echo ""

    auto_cleanup

    log_success "=== PHASE 5 COMPLETED ==="
    echo ""

    database_health_check "post-patch"
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
    log_info "  - Running in background for: ${DATABASES[*]}"
    log_info "  - Log files: ${LOGDIR}/datapatch_*_${TIMESTAMP}.log"
    echo ""
    log_info "Next Steps:"
    log_info "  1. Monitor datapatch completion"
    log_info "  2. Check for invalid objects: SELECT COUNT(*) FROM dba_objects WHERE status='INVALID';"
    log_info "  3. Verify application connectivity"
    log_info "  4. Run full smoke tests"
    echo ""
    log_info "Rollback Option:"
    log_info "  If issues occur, you can rollback with: ${SCRIPT_NAME} --rollback"
    log_info "  Old home is preserved for ${AUTO_CLEANUP_DAYS} days"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Write summary file
    local summary_file="/oracle/autopatchinstall.log"
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
  Status: Running in background
  Log Directory: ${LOGDIR}

Detailed Log: ${LOGFILE}

Next Steps:
  - Monitor datapatch: tail -f ${LOGDIR}/datapatch_*_${TIMESTAMP}.log
  - Verify invalid objects
  - Run application smoke tests
  - Old home cleanup after ${AUTO_CLEANUP_DAYS} days
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
    read -p "Choose option [1-5]: " choice

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
    echo "    --test              Test mode (no DB switch, no downtime)"
    echo "    --prod              Production mode (with downtime + auto-cleanup)"
    echo "    --prod --force      Production mode unattended (no confirmations)"
    echo "    --cleanup           Auto-cleanup old homes (>${AUTO_CLEANUP_DAYS} days)"
    echo "    --cleanup HOME      Cleanup specific Oracle Home"
    echo "    --rollback          Rollback to previous Oracle Home"
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
    echo "    ✓ Out-of-Place patching (2-3 min downtime)"
    echo "    ✓ Automatic patch detection"
    echo "    ✓ Auto-detected Oracle Inventory"
    echo "    ✓ Hostname-based patch directories"
    echo "    ✓ Test mode for validation"
    echo "    ✓ Unattended/Force mode"
    echo "    ✓ Multi-database support"
    echo "    ✓ Auto-cleanup old homes"
    echo "    ✓ Parallel datapatch"
    echo "    ✓ Fast rollback capability"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    case "${1:-${DEFAULT_MODE}}" in
        --status)
            show_status
            ;;
        --test)
            test_mode
            ;;
        --prod)
            if [[ "${2:-}" == "--force" ]]; then
                production_mode --force
            else
                production_mode
            fi
            ;;
        --cleanup)
            if [[ -n "${2:-}" ]]; then
                cleanup_single_home "$2"
            else
                auto_cleanup
            fi
            ;;
        --rollback)
            rollback
            ;;
        --create-config)
            create_default_config
            ;;
        -h|-\?|--help)
            usage
            ;;
        interactive|"")
            interactive_mode
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo ""
            usage
            ;;
    esac
}

# Run main
main "$@"
