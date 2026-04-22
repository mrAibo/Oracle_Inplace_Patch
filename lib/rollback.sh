#!/usr/bin/env bash
# =============================================================================
# lib/rollback.sh - Rollback Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: run_rollback
# Phasenablauf: listener_stop -> db_stop -> oratab_restore
#               -> listener_start (altes Home) -> db_start -> verify
# Depends on: log.sh, config.sh, oracle.sh
# =============================================================================

[[ -n "${_LIB_ROLLBACK_SH:-}" ]] && return 0
readonly _LIB_ROLLBACK_SH=1

# ---------------------------------------------------------------------------
# run_rollback
# Rollback vom neuen zurück zum alten Oracle Home.
# Ermittelt das alte Home aus oratab-Backup oder OLD_ORACLE_HOME.
# ---------------------------------------------------------------------------
run_rollback() {
  log_section "Rollback zum alten Oracle Home"

  # Altes Home ermitteln
  local old_home
  old_home=$(_rollback_find_old_home) || return 1

  local new_home="${CURRENT_ORACLE_HOME}"

  log_info "Aktuell (neu): ${new_home}"
  log_info "Rollback auf:  ${old_home}"

  # Prüfe ob altes Home noch existiert
  if [[ ! -d "${old_home}" ]]; then
    die "Altes Oracle Home existiert nicht mehr: ${old_home} — Rollback nicht möglich"
  fi

  if [[ ! -x "${old_home}/bin/oracle" ]]; then
    die "Oracle Binary fehlt im alten Home: ${old_home}/bin/oracle — Rollback nicht möglich"
  fi

  # Bestätigung
  _rollback_confirm "${new_home}" "${old_home}" || return 1

  local rollback_start
  rollback_start=$(date +%s)

  # 1. Listener stoppen
  _rollback_stop_listener "${new_home}"

  # 2. DBs stoppen (im neuen Home)
  get_active_dbs "${new_home}"
  local -a dbs=("${ACTIVE_DBS[@]}")

  # Falls keine DBs im neuen Home: alle aus oratab versuchen
  if [[ ${#dbs[@]} -eq 0 ]]; then
    log_warn "Keine DBs für ${new_home} in oratab — suche alle aktiven Instanzen"
    _rollback_get_running_sids
    dbs=("${RUNNING_SIDS[@]}")
  fi

  for sid in "${dbs[@]}"; do
    db_stop "${sid}" "${new_home}" || log_warn "DB-Stop fehlgeschlagen: ${sid} (wird ignoriert)"
  done

  # 3. oratab zurücksetzen
  local failed_updates=0
  for sid in "${dbs[@]}"; do
    oratab_update_home "${sid}" "${old_home}" || {
      log_error "oratab-Rollback fehlgeschlagen: ${sid}"
      ((failed_updates++))
    }
  done

  [[ ${failed_updates} -gt 0 ]] && log_error "${failed_updates} oratab-Einträge konnten nicht zurückgesetzt werden"

  # CURRENT_ORACLE_HOME zurücksetzen
  CURRENT_ORACLE_HOME="${old_home}"
  export ORACLE_HOME="${old_home}"
  export PATH="${old_home}/bin:${PATH}"

  # 4. Listener im alten Home starten
  _rollback_start_listener "${old_home}"

  # 5. DBs im alten Home starten
  local failed_starts=0
  for sid in "${dbs[@]}"; do
    db_start "${sid}" "${old_home}" "open" || {
      log_error "DB-Start fehlgeschlagen beim Rollback: ${sid}"
      ((failed_starts++))
    }
  done

  local rollback_end
  rollback_end=$(date +%s)
  local elapsed=$(( rollback_end - rollback_start ))

  # 6. Verifikation
  local failed_verifies=0
  for sid in "${dbs[@]}"; do
    verify_db_open "${sid}" "${old_home}" || ((failed_verifies++))
  done

  if [[ ${failed_starts} -gt 0 ]] || [[ ${failed_verifies} -gt 0 ]]; then
    log_error "Rollback abgeschlossen mit Fehlern (${elapsed}s)"
    log_error "  DB-Starts fehlgeschlagen:      ${failed_starts}"
    log_error "  Verifikationen fehlgeschlagen: ${failed_verifies}"
    log_error "Manuelle Prüfung erforderlich!"
    return 1
  fi

  log_success "Rollback erfolgreich abgeschlossen (${elapsed}s)"
  log_success "Aktives Oracle Home: ${old_home}"

  # Neues Home aufräumen (optional, nur auf Nachfrage)
  _rollback_offer_cleanup "${new_home}"

  return 0
}

# ---------------------------------------------------------------------------
# Interne Hilfsfunktionen
# ---------------------------------------------------------------------------

_rollback_find_old_home() {
  # Priorität 1: Explizit gesetzte Variable OLD_ORACLE_HOME
  if [[ -n "${OLD_ORACLE_HOME:-}" ]] && [[ -d "${OLD_ORACLE_HOME}" ]]; then
    echo "${OLD_ORACLE_HOME}"
    return 0
  fi

  # Priorität 2: Neuestes oratab-Backup auswerten
  local newest_backup
  newest_backup=$(ls -t /etc/oratab.bak_* 2>/dev/null | head -1)

  if [[ -n "${newest_backup}" ]] && [[ -f "${newest_backup}" ]]; then
    log_info "Verwende oratab-Backup: ${newest_backup}"
    # Home aus Backup für erste SID des aktuellen Homes ermitteln
    local current_sid
    current_sid=$(awk -F: -v oh="${CURRENT_ORACLE_HOME}" \
      '!/^#/ && $2==oh {print $1; exit}' /etc/oratab 2>/dev/null)

    if [[ -n "${current_sid}" ]]; then
      local old_home_from_backup
      old_home_from_backup=$(awk -F: -v sid="${current_sid}" \
        '!/^#/ && $1==sid {print $2}' "${newest_backup}" 2>/dev/null)
      if [[ -n "${old_home_from_backup}" ]] && \
         [[ "${old_home_from_backup}" != "${CURRENT_ORACLE_HOME}" ]]; then
        log_info "Altes Home aus Backup: ${old_home_from_backup}"
        echo "${old_home_from_backup}"
        return 0
      fi
    fi
  fi

  # Priorität 3: Oracle Homes aus Inventory durchsuchen
  log_warn "OLD_ORACLE_HOME nicht gesetzt und kein Backup gefunden"
  log_warn "Bekannte Oracle Homes:"
  get_oracle_homes
  for h in "${ORACLE_HOMES[@]}"; do
    [[ "${h}" != "${CURRENT_ORACLE_HOME}" ]] && log_warn "  -> ${h}"
  done

  log_error "Altes Oracle Home konnte nicht automatisch ermittelt werden"
  log_error "Bitte setzen: OLD_ORACLE_HOME=/oracle/19_alt ${SCRIPT_NAME:-oop_patch.sh} --rollback"
  return 1
}

_rollback_get_running_sids() {
  RUNNING_SIDS=()
  while IFS= read -r line; do
    local sid
    sid=$(echo "${line}" | awk '{print $NF}' | sed 's/ora_pmon_//')
    [[ -n "${sid}" ]] && RUNNING_SIDS+=("${sid}")
  done < <(pgrep -u "${REQUIRED_USER:-oracle}" -f "ora_pmon" -a 2>/dev/null || true)
  log_debug "Laufende Instanzen: ${RUNNING_SIDS[*]:-keine}"
}

_rollback_confirm() {
  local new_home="$1"
  local old_home="$2"

  [[ "${DRY_RUN:-false}" == "true" ]] && {
    log_info "[DRY-RUN] Rollback-Bestätigung übersprungen"
    return 0
  }
  [[ "${UNATTENDED_MODE:-false}" == "true" ]] && return 0

  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │            ACHTUNG: Rollback mit Downtime           │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  Von (neu):  %-39s│\n" "${new_home}"
  printf "  │  Auf (alt):  %-39s│\n" "${old_home}"
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""
  read -r -p "  Rollback jetzt durchführen? (yes/no): " confirm
  echo ""
  [[ "${confirm}" != "yes" ]] && { log_info "Rollback abgebrochen"; return 1; }
  return 0
}

_rollback_stop_listener() {
  local oh="$1"
  local lsnr="LISTENER"
  local lora="${oh}/network/admin/listener.ora"
  if [[ -f "${lora}" ]]; then
    local d
    d=$(awk '/^[A-Z_]+ *=/{print $1; exit}' "${lora}" 2>/dev/null | tr -d ' =()')
    [[ -n "${d}" ]] && lsnr="${d}"
  fi
  CURRENT_ORACLE_HOME="${oh}" listener_stop "${lsnr}" || \
    log_warn "Listener-Stop fehlgeschlagen (nicht kritisch)"
}

_rollback_start_listener() {
  local oh="$1"
  local lsnr="LISTENER"
  local lora="${oh}/network/admin/listener.ora"
  if [[ -f "${lora}" ]]; then
    local d
    d=$(awk '/^[A-Z_]+ *=/{print $1; exit}' "${lora}" 2>/dev/null | tr -d ' =()')
    [[ -n "${d}" ]] && lsnr="${d}"
  fi
  listener_start "${lsnr}" "${oh}" || log_warn "Listener-Start fehlgeschlagen"
}

_rollback_offer_cleanup() {
  local new_home="$1"

  [[ "${UNATTENDED_MODE:-false}" == "true" ]] && return 0
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0
  [[ ! -d "${new_home}" ]] && return 0

  echo ""
  read -r -p "  Neues Oracle Home löschen? ${new_home} (yes/no): " confirm
  if [[ "${confirm}" == "yes" ]]; then
    log_info "Lösche: ${new_home}"
    inventory_remove_home "${new_home}"
    rm -rf "${new_home}" && log_success "Gelöscht: ${new_home}" || \
      log_error "Löschen fehlgeschlagen: ${new_home}"
  else
    log_info "Neues Home behalten: ${new_home}"
  fi
}
