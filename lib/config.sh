#!/usr/bin/env bash
# =============================================================================
# lib/config.sh - Configuration & Validation Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: load_config, validate_config, create_default_config, config_doctor
# =============================================================================

[[ -n "${_LIB_CONFIG_SH:-}" ]] && return 0
readonly _LIB_CONFIG_SH=1

# ---------------------------------------------------------------------------
# Default-Werte (werden durch .patchrc überschrieben)
# ---------------------------------------------------------------------------
_set_defaults() {
  # Pfade
  PATCH_BASE_DIR_BASE="${PATCH_BASE_DIR_BASE:-/work/dba/patching}"
  ORACLE_BASE="${ORACLE_BASE:-/oracle}"
  CURRENT_ORACLE_HOME="${CURRENT_ORACLE_HOME:-/oracle/19}"
  LOGDIR="${LOGDIR:-/work/dba/patching/logs}"
  USE_HOSTNAME_DIR="${USE_HOSTNAME_DIR:-false}"

  # Inventory (auto-detect via /etc/oraInst.loc)
  local _auto_inv=""
  if [[ -f /etc/oraInst.loc ]]; then
    _auto_inv=$(awk -F'=' '/inventory_loc/{print $2}' /etc/oraInst.loc 2>/dev/null | tr -d ' ')
  fi
  INVENTORY_LOC="${INVENTORY_LOC:-${_auto_inv:-/oracle/oraInventory}}"

  # Betrieb
  REQUIRED_USER="${REQUIRED_USER:-ora19}"
  DRY_RUN="${DRY_RUN:-false}"
  UNATTENDED_MODE="${UNATTENDED_MODE:-false}"
  DEFAULT_MODE="${DEFAULT_MODE:-interactive}"
  LOG_LEVEL="${LOG_LEVEL:-INFO}"

  # Cleanup-Policy
  AUTO_CLEANUP_DAYS="${AUTO_CLEANUP_DAYS:-30}"
  KEEP_HOMES="${KEEP_HOMES:-2}"
  ALLOW_AUTO_CLEANUP="${ALLOW_AUTO_CLEANUP:-false}"
  ENABLE_INVENTORY_REMOVE="${ENABLE_INVENTORY_REMOVE:-false}"

  # Performance
  MAX_PARALLEL_DATAPATCH="${MAX_PARALLEL_DATAPATCH:-1}"
  DATAPATCH_TIMEOUT="${DATAPATCH_TIMEOUT:-7200}"
  SPACE_BUFFER_FACTOR="${SPACE_BUFFER_FACTOR:-1.5}"
  CLONE_TOLERANCE_PCT="${CLONE_TOLERANCE_PCT:-5}"

  # Limits
  MIN_OPEN_FILES="${MIN_OPEN_FILES:-4096}"
  MIN_CLEANUP_DAYS="${MIN_CLEANUP_DAYS:-7}"

  # Reporting
  JSON_REPORT="${JSON_REPORT:-true}"
  COLOR_OUTPUT="${COLOR_OUTPUT:-true}"
  NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
}

# ---------------------------------------------------------------------------
# load_config: Lädt .patchrc wenn vorhanden, nach Syntax-Check
# ---------------------------------------------------------------------------
load_config() {
  _set_defaults

  local patchrc="${PATCHRC:-${HOME}/.patchrc}"

  if [[ -f "${patchrc}" ]]; then
    log_info "Lade Konfiguration aus: ${patchrc}"

    # Syntax-Check vor dem Sourcen
    if ! bash -n "${patchrc}" 2>/dev/null; then
      die "Konfigurationsdatei hat Syntaxfehler: ${patchrc}"
    fi

    # shellcheck source=/dev/null
    source "${patchrc}"
    log_debug "Konfiguration geladen: ${patchrc}"
  else
    log_info "Keine Konfigurationsdatei gefunden (${patchrc}) - verwende Defaults"
    log_info "Tipp: ${SCRIPT_NAME:-oop_patch.sh} --create-config"
  fi

  # Patch-Basisverzeichnis nach Hostname anpassen falls gewünscht
  if [[ "${USE_HOSTNAME_DIR}" == "true" ]]; then
    PATCH_BASE_DIR="${PATCH_BASE_DIR_BASE}/$(hostname -s)"
  else
    PATCH_BASE_DIR="${PATCH_BASE_DIR_BASE}"
  fi

  # Timestamp & Logfile
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  LOGFILE="${LOGDIR}/oop_patching_${TIMESTAMP}.log"

  validate_config
}

# ---------------------------------------------------------------------------
# validate_config: Prüft Pflichtfelder und Plausibilität
# ---------------------------------------------------------------------------
validate_config() {
  local errors=0

  # Pflichtfelder
  [[ -z "${ORACLE_BASE}"          ]] && { log_error "ORACLE_BASE nicht gesetzt";          ((errors++)); }
  [[ -z "${CURRENT_ORACLE_HOME}"  ]] && { log_error "CURRENT_ORACLE_HOME nicht gesetzt";  ((errors++)); }
  [[ -z "${INVENTORY_LOC}"        ]] && { log_error "INVENTORY_LOC nicht gesetzt";        ((errors++)); }
  [[ -z "${REQUIRED_USER}"        ]] && { log_error "REQUIRED_USER nicht gesetzt";        ((errors++)); }
  [[ -z "${PATCH_BASE_DIR_BASE}"  ]] && { log_error "PATCH_BASE_DIR_BASE nicht gesetzt"; ((errors++)); }

  # Verzeichnisse (nur wenn Werte gesetzt)
  [[ -n "${ORACLE_BASE}"         && ! -d "${ORACLE_BASE}"         ]] && { log_error "ORACLE_BASE existiert nicht: ${ORACLE_BASE}";                 ((errors++)); }
  [[ -n "${CURRENT_ORACLE_HOME}" && ! -d "${CURRENT_ORACLE_HOME}" ]] && { log_error "CURRENT_ORACLE_HOME existiert nicht: ${CURRENT_ORACLE_HOME}"; ((errors++)); }

  # Plausibilität
  if [[ -n "${AUTO_CLEANUP_DAYS}" ]] && [[ ${AUTO_CLEANUP_DAYS} -lt ${MIN_CLEANUP_DAYS:-7} ]]; then
    log_warn "AUTO_CLEANUP_DAYS=${AUTO_CLEANUP_DAYS} ist sehr niedrig (Minimum empfohlen: ${MIN_CLEANUP_DAYS})"
  fi

  if [[ -n "${MAX_PARALLEL_DATAPATCH}" ]] && [[ ${MAX_PARALLEL_DATAPATCH} -gt 4 ]]; then
    log_warn "MAX_PARALLEL_DATAPATCH=${MAX_PARALLEL_DATAPATCH} ist hoch - kann die DB belasten"
  fi

  [[ ${errors} -gt 0 ]] && die "Konfigurationsvalidierung fehlgeschlagen (${errors} Fehler)"

  log_debug "Konfigurationsvalidierung erfolgreich"
  return 0
}

# ---------------------------------------------------------------------------
# config_doctor: Zeigt vollständige Konfiguration mit Status an
# ---------------------------------------------------------------------------
config_doctor() {
  log_section "Konfigurationsdiagnose"

  local patchrc="${PATCHRC:-${HOME}/.patchrc}"

  printf "  %-30s %s\n" "Config-Datei:"         "${patchrc}"
  printf "  %-30s %s\n" "Config existiert:"      "$([[ -f ${patchrc} ]] && echo 'ja' || echo 'NEIN - erstellen mit --create-config')"
  echo ""
  printf "  %-30s %s\n" "ORACLE_BASE:"           "${ORACLE_BASE:-NICHT GESETZT}"
  printf "  %-30s %s\n" "CURRENT_ORACLE_HOME:"   "${CURRENT_ORACLE_HOME:-NICHT GESETZT}"
  printf "  %-30s %s\n" "INVENTORY_LOC:"         "${INVENTORY_LOC:-NICHT GESETZT}"
  printf "  %-30s %s\n" "PATCH_BASE_DIR:"        "${PATCH_BASE_DIR:-NICHT GESETZT}"
  printf "  %-30s %s\n" "LOGDIR:"               "${LOGDIR:-NICHT GESETZT}"
  printf "  %-30s %s\n" "REQUIRED_USER:"         "${REQUIRED_USER:-NICHT GESETZT}"
  echo ""
  printf "  %-30s %s\n" "DRY_RUN:"              "${DRY_RUN:-false}"
  printf "  %-30s %s\n" "UNATTENDED_MODE:"       "${UNATTENDED_MODE:-false}"
  printf "  %-30s %s\n" "MAX_PARALLEL_DATAPATCH:" "${MAX_PARALLEL_DATAPATCH:-1}"
  printf "  %-30s %s\n" "DATAPATCH_TIMEOUT:"     "${DATAPATCH_TIMEOUT:-7200}s"
  printf "  %-30s %s\n" "AUTO_CLEANUP_DAYS:"     "${AUTO_CLEANUP_DAYS:-30}"
  printf "  %-30s %s\n" "ALLOW_AUTO_CLEANUP:"    "${ALLOW_AUTO_CLEANUP:-false}"
  printf "  %-30s %s\n" "ENABLE_INVENTORY_REMOVE:" "${ENABLE_INVENTORY_REMOVE:-false}"
  echo ""

  # Verzeichnisstatus
  local -a check_dirs=(
    "${ORACLE_BASE}"
    "${CURRENT_ORACLE_HOME}"
    "${INVENTORY_LOC}"
    "${PATCH_BASE_DIR:-${PATCH_BASE_DIR_BASE}}"
    "${LOGDIR}"
  )
  for d in "${check_dirs[@]}"; do
    [[ -z "${d}" ]] && continue
    if [[ -d "${d}" ]]; then
      printf "  %-30s %s\n" "[OK] Verzeichnis:" "${d}"
    else
      printf "  %-30s %s\n" "[FEHLT] Verzeichnis:" "${d}"
    fi
  done
}

# ---------------------------------------------------------------------------
# create_default_config: Erstellt .patchrc mit dokumentierten Defaults
# ---------------------------------------------------------------------------
create_default_config() {
  local patchrc="${PATCHRC:-${HOME}/.patchrc}"

  if [[ -f "${patchrc}" ]]; then
    log_warn "Konfigurationsdatei existiert bereits: ${patchrc}"
    read -r -p "Überschreiben? (yes/no): " confirm
    [[ "${confirm}" != "yes" ]] && { log_info "Abgebrochen"; return 0; }
    cp "${patchrc}" "${patchrc}.bak_$(date +%Y%m%d_%H%M%S)"
    log_info "Backup erstellt: ${patchrc}.bak_*"
  fi

  # Auto-detect Inventory
  local detected_inv=""
  if [[ -f /etc/oraInst.loc ]]; then
    detected_inv=$(awk -F'=' '/inventory_loc/{print $2}' /etc/oraInst.loc 2>/dev/null | tr -d ' ')
  fi
  local inv_val="${detected_inv:-/oracle/oraInventory}"

  cat > "${patchrc}" <<EOF
# =============================================================================
# Oracle 19c OOP Patching Framework v3.0 - Konfiguration
# Erstellt: $(date '+%Y-%m-%d %H:%M:%S') auf $(hostname)
# =============================================================================

# --- Verzeichnisse ---
PATCH_BASE_DIR_BASE=/work/dba/patching   # Basis-Verzeichnis für Patches
ORACLE_BASE=/oracle                       # Oracle Base
CURRENT_ORACLE_HOME=/oracle/19            # Aktuelles Oracle Home
LOGDIR=/work/dba/patching/logs           # Log-Verzeichnis
INVENTORY_LOC=${inv_val}                  # Oracle Inventory (auto-erkannt)

# USE_HOSTNAME_DIR=true                   # Patch-Dir: PATCH_BASE_DIR/hostname/

# --- Benutzer ---
REQUIRED_USER=ora19                       # Oracle Software Owner

# --- Betriebsmodi ---
# DEFAULT_MODE=interactive                # interactive | test | prod
# UNATTENDED_MODE=false                   # true = keine Bestätigungen
# DRY_RUN=false                           # true = keine realen Änderungen

# --- Logging ---
# LOG_LEVEL=INFO                          # DEBUG | INFO | WARN | ERROR
# JSON_REPORT=true                        # JSON-Abschlussbericht erzeugen

# --- Cleanup-Policy ---
AUTO_CLEANUP_DAYS=30                      # Homes älter als N Tage bereinigen
KEEP_HOMES=2                             # Mindestanzahl beizubehaltender Homes
ALLOW_AUTO_CLEANUP=false                  # Automatischen Cleanup erlauben
ENABLE_INVENTORY_REMOVE=false             # Inventory-Eintrag beim Cleanup entfernen

# --- Performance ---
MAX_PARALLEL_DATAPATCH=1                  # Parallele Datapatch-Prozesse (1 = seriell)
DATAPATCH_TIMEOUT=7200                    # Timeout Datapatch in Sekunden
SPACE_BUFFER_FACTOR=1.5                   # Speicher-Puffer-Faktor beim Clone

# --- Benachrichtigung ---
# NOTIFY_EMAIL=dba@example.com            # E-Mail nach Abschluss (leer = keine)
EOF

  chmod 600 "${patchrc}"
  log_success "Konfigurationsdatei erstellt: ${patchrc}"
  log_info "Bitte anpassen: vi ${patchrc}"
  log_info "Konfiguration prüfen: ${SCRIPT_NAME:-oop_patch.sh} --config-doctor"
}
