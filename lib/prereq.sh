#!/usr/bin/env bash
# =============================================================================
# lib/prereq.sh - Prerequisite Checks Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: run_prechecks
# Exit-Code: 2 wenn Vorabprüfung fehlschlägt
# =============================================================================

[[ -n "${_LIB_PREREQ_SH:-}" ]] && return 0
readonly _LIB_PREREQ_SH=1

# ---------------------------------------------------------------------------
# run_prechecks
# Prüft alle Voraussetzungen vor dem Start des Patchings.
# Unterscheidet zwischen FATAL (exit 2) und WARNING (weiter).
# ---------------------------------------------------------------------------
run_prechecks() {
  log_section "Vorabprüfungen (Prerequisites)"
  CURRENT_PHASE="PRECHECK"

  local errors=0

  # --- 1. Benutzer ---
  _check_user || ((errors++))

  # --- 2. Oracle Home Struktur ---
  _check_oracle_home || ((errors++))

  # --- 3. Speicherplatz ---
  _check_disk_space || ((errors++))

  # --- 4. Pflicht-Tools ---
  _check_required_tools || ((errors++))

  # --- 5. ulimit ---
  _check_ulimits

  # --- 6. Laufende Patch-Prozesse ---
  _check_running_patch_processes

  # --- 7. Aktive DB-Instanzen (Info) ---
  _check_active_instances

  # --- 8. OPatch-Version ---
  _check_opatch_version || ((errors++))

  # --- 9. Patch-Verzeichnis ---
  _check_patch_directory || ((errors++))

  if [[ ${errors} -gt 0 ]]; then
    log_error "Vorabprüfung fehlgeschlagen: ${errors} kritische Fehler"
    exit 2
  fi

  log_success "Alle Vorabprüfungen bestanden"
  CURRENT_PHASE=""
}

# ---------------------------------------------------------------------------
# Interne Prüffunktionen
# ---------------------------------------------------------------------------

_check_user() {
  local current_user
  current_user=$(whoami)
  if [[ "${current_user}" != "${REQUIRED_USER}" ]]; then
    log_error "Falscher Benutzer: '${current_user}' (erwartet: '${REQUIRED_USER}')"
    log_error "Wechsel mit: sudo su - ${REQUIRED_USER}"
    return 1
  fi
  log_debug "Benutzer: ${current_user} [OK]"
  return 0
}

_check_oracle_home() {
  local errors=0

  if [[ ! -d "${CURRENT_ORACLE_HOME}" ]]; then
    log_error "CURRENT_ORACLE_HOME existiert nicht: ${CURRENT_ORACLE_HOME}"
    ((errors++))
  fi

  if [[ ! -x "${CURRENT_ORACLE_HOME}/bin/sqlplus" ]]; then
    log_error "sqlplus nicht gefunden: ${CURRENT_ORACLE_HOME}/bin/sqlplus"
    ((errors++))
  fi

  if [[ ! -x "${CURRENT_ORACLE_HOME}/OPatch/opatch" ]]; then
    log_error "OPatch nicht gefunden: ${CURRENT_ORACLE_HOME}/OPatch/opatch"
    ((errors++))
  fi

  if [[ ! -f "${CURRENT_ORACLE_HOME}/bin/oracle" ]]; then
    log_error "Oracle Binary nicht gefunden: ${CURRENT_ORACLE_HOME}/bin/oracle"
    ((errors++))
  fi

  [[ ${errors} -gt 0 ]] && return 1
  log_debug "Oracle Home Struktur: ${CURRENT_ORACLE_HOME} [OK]"
  return 0
}

_check_disk_space() {
  local required_mb available_mb

  required_mb=$(du -sb "${CURRENT_ORACLE_HOME}" 2>/dev/null | \
    awk -v factor="${SPACE_BUFFER_FACTOR:-1.5}" '{printf "%d", int($1 * factor / 1024 / 1024)}')

  available_mb=$(df -m "${ORACLE_BASE}" 2>/dev/null | tail -1 | awk '{print $4}')

  log_info "Speicherplatz: benötigt ~${required_mb} MB, verfügbar ${available_mb} MB (in ${ORACLE_BASE})"

  if [[ -z "${available_mb}" ]] || [[ ${available_mb} -lt ${required_mb} ]]; then
    log_error "Zu wenig Speicherplatz: benötigt ${required_mb} MB, verfügbar ${available_mb:-0} MB"
    log_error "Freigeben oder SPACE_BUFFER_FACTOR reduzieren (aktuell: ${SPACE_BUFFER_FACTOR:-1.5})"
    return 1
  fi

  log_debug "Speicherplatz ausreichend [OK]"
  return 0
}

_check_required_tools() {
  local errors=0
  local required_tools=("rsync" "unzip" "awk" "sed" "du" "df" "stat")

  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Pflicht-Tool fehlt: ${tool}"
      ((errors++))
    else
      log_debug "Tool gefunden: ${tool} [OK]"
    fi
  done

  [[ ${errors} -gt 0 ]] && return 1
  return 0
}

_check_ulimits() {
  local open_files
  open_files=$(ulimit -n 2>/dev/null || echo "0")

  if [[ ${open_files} -lt ${MIN_OPEN_FILES:-4096} ]]; then
    log_warn "Limit für offene Dateien zu niedrig: ${open_files} (empfohlen: ${MIN_OPEN_FILES:-4096})"
    log_warn "Anpassen mit: ulimit -n ${MIN_OPEN_FILES:-4096}"
  else
    log_debug "ulimit -n: ${open_files} [OK]"
  fi
}

_check_running_patch_processes() {
  if pgrep -f "opatch|datapatch" 2>/dev/null | grep -v "^$$\$" >/dev/null; then
    log_warn "Andere OPatch/Datapatch-Prozesse laufen bereits auf diesem Host"
    log_warn "Bitte prüfen: pgrep -fl 'opatch|datapatch'"
  else
    log_debug "Keine laufenden Patch-Prozesse [OK]"
  fi
}

_check_active_instances() {
  local instance_count
  instance_count=$(pgrep -u "${REQUIRED_USER}" -f "ora_pmon" 2>/dev/null | wc -l || echo "0")

  if [[ ${instance_count} -gt 0 ]]; then
    log_info "Aktive Oracle-Instanzen auf diesem Host: ${instance_count}"
    pgrep -u "${REQUIRED_USER}" -f "ora_pmon" -a 2>/dev/null | while read -r line; do
      log_info "  -> ${line}"
    done
  else
    log_info "Keine aktiven Oracle-Instanzen gefunden"
  fi
}

_check_opatch_version() {
  local opatch_ver
  opatch_ver=$("${CURRENT_ORACLE_HOME}/OPatch/opatch" version 2>/dev/null | \
    awk '/OPatch Version/{print $3}' || echo "")

  if [[ -z "${opatch_ver}" ]]; then
    log_error "OPatch-Version konnte nicht ermittelt werden"
    return 1
  fi

  log_info "OPatch Version: ${opatch_ver}"

  # Mindestversion 12.2.0.1.x für Oracle 19c
  local major minor
  major=$(echo "${opatch_ver}" | cut -d'.' -f1)
  minor=$(echo "${opatch_ver}" | cut -d'.' -f2)

  if [[ ${major} -lt 12 ]] || ( [[ ${major} -eq 12 ]] && [[ ${minor} -lt 2 ]] ); then
    log_warn "OPatch-Version ${opatch_ver} ist möglicherweise zu alt für Oracle 19c (empfohlen: 12.2.x+)"
  fi

  return 0
}

_check_patch_directory() {
  if [[ ! -d "${PATCH_BASE_DIR}" ]]; then
    log_error "Patch-Verzeichnis nicht gefunden: ${PATCH_BASE_DIR}"
    log_error "Patches ablegen in: ${PATCH_BASE_DIR}/<PATCH_NUM>/"
    return 1
  fi

  # Prüfe ob überhaupt Patches vorhanden
  local patch_count
  patch_count=$(find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | wc -l)

  if [[ ${patch_count} -eq 0 ]]; then
    log_warn "Keine Patch-Verzeichnisse in ${PATCH_BASE_DIR} gefunden"
    log_warn "Erwartet: ${PATCH_BASE_DIR}/<numerische-Patch-ID>/"
  else
    log_info "Gefundene Patch-Verzeichnisse: ${patch_count} (in ${PATCH_BASE_DIR})"
  fi

  return 0
}
