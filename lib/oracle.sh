#!/usr/bin/env bash
# =============================================================================
# lib/oracle.sh - Oracle Environment & DB Operations Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: get_oracle_homes, get_active_dbs, db_stop, db_start,
#           listener_stop, listener_start, oratab_backup,
#           oratab_update_home, inventory_register_home,
#           inventory_remove_home, get_patch_level
# =============================================================================

[[ -n "${_LIB_ORACLE_SH:-}" ]] && return 0
readonly _LIB_ORACLE_SH=1

# ---------------------------------------------------------------------------
# get_oracle_homes
# Liest alle Oracle Homes aus oratab (Zeilen mit ORACLE_HOME-Pfad)
# Gibt Array ORACLE_HOMES[] zurück
# ---------------------------------------------------------------------------
get_oracle_homes() {
  ORACLE_HOMES=()
  local oratab="/etc/oratab"

  [[ ! -f "${oratab}" ]] && { log_warn "oratab nicht gefunden: ${oratab}"; return 0; }

  while IFS=: read -r sid home auto _rest; do
    [[ "${sid}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${sid}" || -z "${home}" ]] && continue
    [[ "${sid}" == "+" ]] && continue  # ASM ignorieren
    [[ -d "${home}" ]] && ORACLE_HOMES+=("${home}")
  done < "${oratab}"

  # Deduplizieren
  local -A seen
  local unique=()
  for h in "${ORACLE_HOMES[@]}"; do
    [[ -z "${seen[$h]:-}" ]] && unique+=("$h") && seen[$h]=1
  done
  ORACLE_HOMES=("${unique[@]}")

  log_debug "Oracle Homes aus oratab: ${#ORACLE_HOMES[@]}"
}

# ---------------------------------------------------------------------------
# get_active_dbs [oracle_home]
# Liest alle SIDs aus oratab die dem angegebenen Home zugeordnet sind.
# Wenn kein Home angegeben: aktuelles CURRENT_ORACLE_HOME
# Berücksichtigt TARGET_DBS-Filter (--db Flag)
# Gibt Array ACTIVE_DBS[] zurück
# ---------------------------------------------------------------------------
get_active_dbs() {
  local target_home="${1:-${CURRENT_ORACLE_HOME}}"
  ACTIVE_DBS=()
  local oratab="/etc/oratab"

  [[ ! -f "${oratab}" ]] && { log_warn "oratab nicht gefunden: ${oratab}"; return 0; }

  while IFS=: read -r sid home auto _rest; do
    [[ "${sid}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${sid}" || -z "${home}" ]] && continue
    [[ "${sid}" == "+" ]] && continue
    [[ "${home}" != "${target_home}" ]] && continue

    # TARGET_DBS-Filter anwenden
    if [[ -n "${TARGET_DBS:-}" ]]; then
      local match=false
      IFS=',' read -ra filter_list <<< "${TARGET_DBS}"
      for f in "${filter_list[@]}"; do
        [[ "${f}" == "${sid}" ]] && match=true && break
      done
      [[ "${match}" == "false" ]] && continue
    fi

    ACTIVE_DBS+=("${sid}")
  done < "${oratab}"

  log_info "Datenbanken für Home ${target_home}: ${ACTIVE_DBS[*]:-keine}"
}

# ---------------------------------------------------------------------------
# db_stop <sid> <oracle_home>
# Stoppt eine DB-Instanz via sqlplus immediate
# ---------------------------------------------------------------------------
db_stop() {
  local sid="${1:?db_stop: SID fehlt}"
  local oh="${2:?db_stop: ORACLE_HOME fehlt}"

  log_info "Stoppe Datenbank: ${sid}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] ORACLE_SID=${sid} sqlplus / as sysdba -> shutdown immediate"
    return 0
  fi

  local output
  output=$(ORACLE_HOME="${oh}" ORACLE_SID="${sid}" \
    "${oh}/bin/sqlplus" -s "/ as sysdba" <<-'SQLEOF' 2>&1
      whenever sqlerror exit 1
      shutdown immediate;
      exit;
SQLEOF
  )
  local rc=$?

  log_debug "sqlplus shutdown output: ${output}"

  if [[ ${rc} -ne 0 ]]; then
    # Prüfe ob DB bereits gestoppt
    if echo "${output}" | grep -qi "ORA-01034\|not mounted\|already stopped\|idle instance"; then
      log_warn "DB ${sid} war bereits gestoppt"
      return 0
    fi
    log_error "DB-Stop fehlgeschlagen (RC=${rc}): ${sid}"
    log_error "Output: ${output}"
    return 1
  fi

  log_success "DB gestoppt: ${sid}"
  return 0
}

# ---------------------------------------------------------------------------
# db_start <sid> <oracle_home> [open|mount|nomount]
# ---------------------------------------------------------------------------
db_start() {
  local sid="${1:?db_start: SID fehlt}"
  local oh="${2:?db_start: ORACLE_HOME fehlt}"
  local startup_mode="${3:-open}"

  log_info "Starte Datenbank: ${sid} (Mode: ${startup_mode})"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] ORACLE_SID=${sid} sqlplus / as sysdba -> startup ${startup_mode}"
    return 0
  fi

  local output
  output=$(ORACLE_HOME="${oh}" ORACLE_SID="${sid}" \
    "${oh}/bin/sqlplus" -s "/ as sysdba" <<-SQLEOF 2>&1
      whenever sqlerror exit 1
      startup ${startup_mode};
      exit;
SQLEOF
  )
  local rc=$?

  log_debug "sqlplus startup output: ${output}"

  if [[ ${rc} -ne 0 ]]; then
    if echo "${output}" | grep -qi "ORA-01081\|already started"; then
      log_warn "DB ${sid} war bereits gestartet"
      return 0
    fi
    log_error "DB-Start fehlgeschlagen (RC=${rc}): ${sid}"
    log_error "Output: ${output}"
    return 1
  fi

  log_success "DB gestartet: ${sid} (Mode: ${startup_mode})"
  return 0
}

# ---------------------------------------------------------------------------
# listener_stop [listener_name]
# ---------------------------------------------------------------------------
listener_stop() {
  local lsnr="${1:-LISTENER}"
  local lsnrctl="${CURRENT_ORACLE_HOME}/bin/lsnrctl"

  [[ ! -x "${lsnrctl}" ]] && { log_warn "lsnrctl nicht gefunden: ${lsnrctl}"; return 0; }

  log_info "Stoppe Listener: ${lsnr}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] lsnrctl stop ${lsnr}"
    return 0
  fi

  ORACLE_HOME="${CURRENT_ORACLE_HOME}" "${lsnrctl}" stop "${lsnr}" 2>&1 | \
    while IFS= read -r line; do log_debug "lsnrctl: ${line}"; done

  log_success "Listener gestoppt: ${lsnr}"
}

# ---------------------------------------------------------------------------
# listener_start [listener_name] [oracle_home]
# ---------------------------------------------------------------------------
listener_start() {
  local lsnr="${1:-LISTENER}"
  local oh="${2:-${NEW_ORACLE_HOME:-${CURRENT_ORACLE_HOME}}}"
  local lsnrctl="${oh}/bin/lsnrctl"

  [[ ! -x "${lsnrctl}" ]] && { log_warn "lsnrctl nicht gefunden: ${lsnrctl}"; return 0; }

  log_info "Starte Listener: ${lsnr} (Home: ${oh})"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] lsnrctl start ${lsnr}"
    return 0
  fi

  ORACLE_HOME="${oh}" "${lsnrctl}" start "${lsnr}" 2>&1 | \
    while IFS= read -r line; do log_debug "lsnrctl: ${line}"; done

  log_success "Listener gestartet: ${lsnr}"
}

# ---------------------------------------------------------------------------
# oratab_backup
# Erstellt ein zeitgestempeltes Backup von /etc/oratab
# ---------------------------------------------------------------------------
oratab_backup() {
  local oratab="/etc/oratab"
  local backup="${oratab}.bak_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] cp ${oratab} ${backup}"
    return 0
  fi

  cp "${oratab}" "${backup}" || { log_error "Backup von oratab fehlgeschlagen"; return 1; }
  chmod 644 "${backup}"
  log_info "oratab Backup: ${backup}"
}

# ---------------------------------------------------------------------------
# oratab_update_home <sid> <new_home>
# Ändert den Oracle-Home-Eintrag einer SID in /etc/oratab (atomisch via tmp)
# ---------------------------------------------------------------------------
oratab_update_home() {
  local sid="${1:?oratab_update_home: SID fehlt}"
  local new_home="${2:?oratab_update_home: new_home fehlt}"
  local oratab="/etc/oratab"
  local tmp_oratab="${oratab}.tmp_$$"

  [[ ! -f "${oratab}" ]] && die "oratab nicht gefunden: ${oratab}"
  [[ ! -d "${new_home}" ]]  && die "Neues Oracle Home existiert nicht: ${new_home}"

  # Prüfe ob SID überhaupt in oratab vorhanden
  if ! grep -q "^${sid}:" "${oratab}" 2>/dev/null; then
    log_error "SID '${sid}' nicht in oratab gefunden"
    return 1
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] oratab: ${sid} -> ${new_home}"
    return 0
  fi

  # Backup vor jeder Änderung
  oratab_backup

  # Atomische Änderung via tmp-Datei
  awk -v sid="${sid}" -v newhome="${new_home}" \
    'BEGIN{FS=OFS=":"} /^[^#]/ && $1==sid { $2=newhome } { print }' \
    "${oratab}" > "${tmp_oratab}" || { rm -f "${tmp_oratab}"; die "oratab awk-Verarbeitung fehlgeschlagen"; }

  mv "${tmp_oratab}" "${oratab}" || { rm -f "${tmp_oratab}"; die "oratab-Update fehlgeschlagen (mv)"; }
  chmod 644 "${oratab}"

  log_success "oratab aktualisiert: ${sid} -> ${new_home}"
}

# ---------------------------------------------------------------------------
# inventory_register_home <oracle_home>
# Registriert ein Oracle Home im zentralen Inventory
# ---------------------------------------------------------------------------
inventory_register_home() {
  local oh="${1:?inventory_register_home: oracle_home fehlt}"
  local inv_loc="${INVENTORY_LOC:-/oracle/oraInventory}"
  local oui="${oh}/oui/bin/attachHome.sh"

  log_info "Registriere Oracle Home im Inventory: ${oh}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] inventory_register_home ${oh}"
    return 0
  fi

  if [[ ! -x "${oui}" ]]; then
    log_warn "attachHome.sh nicht gefunden: ${oui} — überspringe Inventory-Registrierung"
    return 0
  fi

  "${oui}" \
    ORACLE_HOME="${oh}" \
    ORACLE_HOME_NAME="OraHome_$(basename "${oh}")" \
    -invPtrLoc /etc/oraInst.loc 2>&1 | \
    while IFS= read -r line; do log_debug "inventory: ${line}"; done

  log_success "Oracle Home im Inventory registriert: ${oh}"
}

# ---------------------------------------------------------------------------
# inventory_remove_home <oracle_home>
# Entfernt ein Oracle Home aus dem zentralen Inventory
# Nur ausführbar wenn ENABLE_INVENTORY_REMOVE=true
# ---------------------------------------------------------------------------
inventory_remove_home() {
  local oh="${1:?inventory_remove_home: oracle_home fehlt}"

  if [[ "${ENABLE_INVENTORY_REMOVE:-false}" != "true" ]]; then
    log_warn "ENABLE_INVENTORY_REMOVE=false — Inventory-Entfernung übersprungen für: ${oh}"
    return 0
  fi

  log_info "Entferne Oracle Home aus Inventory: ${oh}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] inventory_remove_home ${oh}"
    return 0
  fi

  local oui="${oh}/oui/bin/detachHome.sh"

  if [[ ! -x "${oui}" ]]; then
    log_warn "detachHome.sh nicht gefunden: ${oui} — überspringe Inventory-Entfernung"
    return 0
  fi

  "${oui}" ORACLE_HOME="${oh}" -invPtrLoc /etc/oraInst.loc 2>&1 | \
    while IFS= read -r line; do log_debug "inventory: ${line}"; done

  log_success "Oracle Home aus Inventory entfernt: ${oh}"
}

# ---------------------------------------------------------------------------
# get_patch_level <oracle_home>
# Gibt installierte Patches zurück via opatch lspatches
# ---------------------------------------------------------------------------
get_patch_level() {
  local oh="${1:-${CURRENT_ORACLE_HOME}}"
  local opatch="${oh}/OPatch/opatch"

  if [[ ! -x "${opatch}" ]]; then
    log_warn "OPatch nicht gefunden: ${opatch}"
    return 1
  fi

  log_info "Patch-Level für: ${oh}"
  ORACLE_HOME="${oh}" "${opatch}" lspatches 2>/dev/null | \
    grep -v "^$\|OPatch succeeded" | \
    while IFS= read -r line; do log_info "  ${line}"; done
}

# ---------------------------------------------------------------------------
# verify_db_open <sid> <oracle_home>
# Prüft ob DB im OPEN Status ist
# ---------------------------------------------------------------------------
verify_db_open() {
  local sid="${1:?verify_db_open: SID fehlt}"
  local oh="${2:?verify_db_open: ORACLE_HOME fehlt}"

  log_info "Prüfe DB-Status: ${sid}"

  local status
  status=$(ORACLE_HOME="${oh}" ORACLE_SID="${sid}" \
    "${oh}/bin/sqlplus" -s "/ as sysdba" <<-'SQLEOF' 2>/dev/null
      set heading off feedback off pagesize 0
      select status from v$instance;
      exit;
SQLEOF
  )
  status=$(echo "${status}" | tr -d '[:space:]')

  if [[ "${status}" == "OPEN" ]]; then
    log_success "DB ${sid} ist OPEN"
    return 0
  else
    log_error "DB ${sid} Status: '${status}' (erwartet: OPEN)"
    return 1
  fi
}
