#!/usr/bin/env bash
# =============================================================================
# lib/switch.sh - Oracle Home Switch Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: run_switch
# Phasenablauf: listener_stop -> db_stop (alle DBs) -> oratab_update
#               -> listener_start (neues Home) -> db_start -> verify
# Depends on: log.sh, config.sh, oracle.sh
# =============================================================================

[[ -n "${_LIB_SWITCH_SH:-}" ]] && return 0
readonly _LIB_SWITCH_SH=1

# ---------------------------------------------------------------------------
# run_switch
# Führt den vollständigen DB-Switch vom alten auf das neue Oracle Home durch.
# Setzt globale Variable SWITCH_DONE=true bei Erfolg.
# ---------------------------------------------------------------------------
run_switch() {
  local old_home="${CURRENT_ORACLE_HOME:?run_switch: CURRENT_ORACLE_HOME nicht gesetzt}"
  local new_home="${NEW_ORACLE_HOME:?run_switch: NEW_ORACLE_HOME nicht gesetzt}"

  log_section "Oracle Home Switch"
  log_info "Alt:  ${old_home}"
  log_info "Neu:  ${new_home}"

  SWITCH_DONE=false

  # Sicherheitsprüfungen vor Downtime
  _switch_prechecks "${new_home}" || return 1

  # Bestätigung bei interaktivem Betrieb
  _switch_confirm "${old_home}" "${new_home}" || return 1

  # --- Downtime beginnt hier ---
  local downtime_start
  downtime_start=$(date +%s)

  # 1. Listener stoppen
  _switch_stop_listener "${old_home}"

  # 2. Alle DBs stoppen
  get_active_dbs "${old_home}"
  local -a dbs_to_switch=("${ACTIVE_DBS[@]}")

  if [[ ${#dbs_to_switch[@]} -eq 0 ]]; then
    log_warn "Keine Datenbanken für Home ${old_home} in oratab gefunden"
  fi

  local failed_stops=0
  for sid in "${dbs_to_switch[@]}"; do
    db_stop "${sid}" "${old_home}" || {
      log_error "DB-Stop fehlgeschlagen: ${sid}"
      ((failed_stops++))
    }
  done

  if [[ ${failed_stops} -gt 0 ]]; then
    log_error "${failed_stops} DB(s) konnten nicht gestoppt werden"
    if [[ "${UNATTENDED_MODE:-false}" != "true" ]]; then
      read -r -p "Trotzdem fortfahren? (yes/no): " confirm
      [[ "${confirm}" != "yes" ]] && {
        log_warn "Switch abgebrochen — kein oratab-Update durchgeführt"
        _switch_start_listener "${old_home}"
        return 1
      }
    fi
  fi

  # 3. oratab für alle DBs aktualisieren
  local failed_updates=0
  for sid in "${dbs_to_switch[@]}"; do
    oratab_update_home "${sid}" "${new_home}" || {
      log_error "oratab-Update fehlgeschlagen: ${sid}"
      ((failed_updates++))
    }
  done

  if [[ ${failed_updates} -gt 0 ]]; then
    die "oratab-Update für ${failed_updates} DB(s) fehlgeschlagen — Rollback erforderlich"
  fi

  # CURRENT_ORACLE_HOME aktualisieren
  OLD_ORACLE_HOME="${old_home}"
  CURRENT_ORACLE_HOME="${new_home}"
  export ORACLE_HOME="${new_home}"
  export PATH="${new_home}/bin:${PATH}"

  # 4. Listener im neuen Home starten
  _switch_start_listener "${new_home}"

  # 5. Alle DBs im neuen Home starten
  local failed_starts=0
  for sid in "${dbs_to_switch[@]}"; do
    db_start "${sid}" "${new_home}" "open" || {
      log_error "DB-Start fehlgeschlagen: ${sid}"
      ((failed_starts++))
    }
  done

  local downtime_end
  downtime_end=$(date +%s)
  local downtime=$(( downtime_end - downtime_start ))

  # 6. Verifikation
  local failed_verifies=0
  for sid in "${dbs_to_switch[@]}"; do
    verify_db_open "${sid}" "${new_home}" || ((failed_verifies++))
  done

  # Ergebnis
  if [[ ${failed_starts} -gt 0 ]] || [[ ${failed_verifies} -gt 0 ]]; then
    log_error "Switch abgeschlossen mit Fehlern:"
    log_error "  DB-Starts fehlgeschlagen:  ${failed_starts}"
    log_error "  Verifikationen fehlgeschlagen: ${failed_verifies}"
    log_error "Downtime: ${downtime}s"
    log_error "Rollback prüfen: $(basename "${BASH_SOURCE[0]%.*}") --rollback"
    return 1
  fi

  SWITCH_DONE=true
  log_success "Switch abgeschlossen in ${downtime}s"
  log_success "Aktives Oracle Home: ${new_home}"
  return 0
}

# ---------------------------------------------------------------------------
# Interne Hilfsfunktionen
# ---------------------------------------------------------------------------

_switch_prechecks() {
  local new_home="$1"
  local errors=0

  [[ ! -d "${new_home}" ]] && {
    log_error "Neues Oracle Home existiert nicht: ${new_home}"
    ((errors++))
  }

  [[ ! -x "${new_home}/bin/oracle" ]] && {
    log_error "Oracle Binary fehlt im neuen Home: ${new_home}/bin/oracle"
    ((errors++))
  }

  [[ ! -x "${new_home}/bin/sqlplus" ]] && {
    log_error "sqlplus fehlt im neuen Home: ${new_home}/bin/sqlplus"
    ((errors++))
  }

  [[ ! -x "${new_home}/OPatch/opatch" ]] && {
    log_error "OPatch fehlt im neuen Home: ${new_home}/OPatch/opatch"
    ((errors++))
  }

  [[ ${errors} -gt 0 ]] && return 1
  log_debug "Switch Prechecks: OK"
  return 0
}

_switch_confirm() {
  local old_home="$1"
  local new_home="$2"

  [[ "${DRY_RUN:-false}" == "true" ]] && {
    log_info "[DRY-RUN] Switch-Bestätigung übersprungen"
    return 0
  }

  [[ "${UNATTENDED_MODE:-false}" == "true" ]] && return 0

  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │           ACHTUNG: Datenbankdowntime beginnt        │"
  echo "  ├─────────────────────────────────────────────────────┤"
  printf "  │  Alt:  %-44s│\n" "${old_home}"
  printf "  │  Neu:  %-44s│\n" "${new_home}"
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""
  read -r -p "  Switch jetzt durchführen? (yes/no): " confirm
  echo ""

  if [[ "${confirm}" != "yes" ]]; then
    log_info "Switch abgebrochen durch Benutzer"
    return 1
  fi
  return 0
}

_switch_stop_listener() {
  local oh="$1"
  # Listener-Name aus listener.ora ermitteln oder Default verwenden
  local lsnr_name="LISTENER"
  local listener_ora="${oh}/network/admin/listener.ora"
  if [[ -f "${listener_ora}" ]]; then
    local detected
    detected=$(awk '/^[A-Z_]+ *=/{print $1; exit}' "${listener_ora}" 2>/dev/null | \
      tr -d ' =()')
    [[ -n "${detected}" ]] && lsnr_name="${detected}"
  fi
  listener_stop "${lsnr_name}" || log_warn "Listener-Stop fehlgeschlagen (nicht kritisch)"
}

_switch_start_listener() {
  local oh="$1"
  local lsnr_name="LISTENER"
  local listener_ora="${oh}/network/admin/listener.ora"
  if [[ -f "${listener_ora}" ]]; then
    local detected
    detected=$(awk '/^[A-Z_]+ *=/{print $1; exit}' "${listener_ora}" 2>/dev/null | \
      tr -d ' =()')
    [[ -n "${detected}" ]] && lsnr_name="${detected}"
  fi
  listener_start "${lsnr_name}" "${oh}" || log_warn "Listener-Start fehlgeschlagen"
}
