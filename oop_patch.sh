#!/usr/bin/env bash
# =============================================================================
# oop_patch.sh - Oracle 19c Out-of-Place Patching Framework v3.0
# =============================================================================
# Orchestrator: lädt alle Module und steuert den Patchingablauf
#
# Verwendung: ./oop_patch.sh --help
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Module laden (Reihenfolge ist wichtig)
# ---------------------------------------------------------------------------
_load_libs() {
  local libs=(
    "lib/log.sh"
    "lib/lock.sh"
    "lib/config.sh"
    "lib/cli.sh"
    "lib/prereq.sh"
    "lib/oracle.sh"
    "lib/patching.sh"
    "lib/switch.sh"
    "lib/rollback.sh"
    "lib/cleanup.sh"
    "lib/report.sh"
  )

  for lib in "${libs[@]}"; do
    local lib_path="${BASE_DIR}/${lib}"
    if [[ ! -f "${lib_path}" ]]; then
      echo "FATAL: Modul nicht gefunden: ${lib_path}" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    source "${lib_path}"
  done
}

# ---------------------------------------------------------------------------
# Traps & Exit-Handler
# ---------------------------------------------------------------------------
_setup_traps() {
  trap '_on_exit' EXIT
  trap '_on_interrupt' INT TERM
}

_on_exit() {
  local exit_code=$?
  release_lock 2>/dev/null || true

  if [[ ${exit_code} -ne 0 ]] && [[ -n "${REPORT_START_TIME:-}" ]]; then
    add_error "Skript beendet mit Exit-Code: ${exit_code}"
    report_finalize 2>/dev/null || true
  fi
}

_on_interrupt() {
  log_error "Unterbrochen (SIGINT/SIGTERM) — bitte Zustand manuell prüfen"
  log_error "Rollback: ${SCRIPT_NAME} --rollback"
  exit 130
}

# ---------------------------------------------------------------------------
# Sonderkommandos (vor Config/Lock)
# ---------------------------------------------------------------------------
_handle_special_commands() {
  case "${MODE:-}" in
    create-config)
      # Config-Modul nur für diesen Aufruf minimal initialisieren
      _set_defaults 2>/dev/null || true
      create_default_config
      exit 0
      ;;
    config-doctor)
      load_config
      config_doctor
      exit 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Ablauf: Status
# ---------------------------------------------------------------------------
run_status() {
  log_section "Oracle Home Status"
  CURRENT_PHASE="STATUS"

  log_preflight_summary

  echo ""
  log_info "=== Oracle Homes (oratab) ==="
  get_oracle_homes
  for h in "${ORACLE_HOMES[@]:-}"; do
    local is_current=""
    [[ "${h}" == "${CURRENT_ORACLE_HOME}" ]] && is_current=" [AKTUELL]"
    log_info "  ${h}${is_current}"
    get_patch_level "${h}" 2>/dev/null || true
    echo ""
  done

  log_info "=== Aktive Datenbankinstanzen ==="
  _check_active_instances

  log_info "=== OPatch Version ==="
  _check_opatch_version

  CURRENT_PHASE=""
}

# ---------------------------------------------------------------------------
# Ablauf: Test-Modus (Clone + Patch, kein Switch)
# ---------------------------------------------------------------------------
run_test_flow() {
  log_section "Test-Modus: Clone + OPatch (kein DB-Switch)"
  report_init

  run_prechecks

  clone_oracle_home
  report_add_db_result "ALL" "clone" "OK"

  apply_opatch
  log_preflight_summary

  log_success "Test-Modus abgeschlossen — kein DB-Switch durchgeführt"
  log_info "Neues Oracle Home: ${NEW_ORACLE_HOME}"
  log_info "Für Produktion: ${SCRIPT_NAME} --prod"

  report_finalize
}

# ---------------------------------------------------------------------------
# Ablauf: Produktions-Modus
# ---------------------------------------------------------------------------
run_prod_flow() {
  log_section "Produktions-Modus"
  report_init

  # Phase 1: Prechecks (immer)
  if [[ "${SWITCH_ONLY:-false}" != "true" ]] && \
     [[ "${DATAPATCH_ONLY:-false}" != "true" ]]; then
    run_prechecks
    [[ "${VALIDATE_ONLY:-false}" == "true" ]] && {
      log_success "Validate-Only: alle Prechecks bestanden — kein Eingriff"
      report_finalize
      return 0
    }
  fi

  # Phase 2: Clone + OPatch (außer bei switch-only / datapatch-only)
  if [[ "${SWITCH_ONLY:-false}" != "true" ]] && \
     [[ "${DATAPATCH_ONLY:-false}" != "true" ]]; then

    if [[ "${RESUME_MODE:-false}" == "true" ]] && \
       [[ -n "${NEW_ORACLE_HOME:-}" ]] && \
       [[ -d "${NEW_ORACLE_HOME}" ]]; then
      log_info "Resume-Modus: verwende existierendes Home: ${NEW_ORACLE_HOME}"
    else
      clone_oracle_home
    fi

    apply_opatch

    [[ "${PREPARE_ONLY:-false}" == "true" ]] && {
      log_success "Prepare-Only: Clone + Patch abgeschlossen — kein Switch"
      log_info "Neues Home: ${NEW_ORACLE_HOME}"
      log_info "Switch: ${SCRIPT_NAME} --switch-only"
      report_finalize
      return 0
    }
  fi

  # Phase 3: DB-Switch (außer datapatch-only)
  if [[ "${DATAPATCH_ONLY:-false}" != "true" ]]; then

    # Prechecks für switch-only
    [[ "${SWITCH_ONLY:-false}" == "true" ]] && {
      [[ -z "${NEW_ORACLE_HOME:-}" ]] && \
        die "--switch-only: NEW_ORACLE_HOME muss gesetzt sein (z.B. NEW_ORACLE_HOME=/oracle/19_20240115 ${SCRIPT_NAME} --switch-only)"
      run_prechecks
    }

    run_switch || {
      log_error "Switch fehlgeschlagen — Rollback empfohlen: ${SCRIPT_NAME} --rollback"
      report_add_db_result "ALL" "switch" "FAILED"
      report_finalize
      exit 1
    }
    report_add_db_result "ALL" "switch" "OK"
  fi

  # Phase 4: Datapatch
  get_active_dbs "${NEW_ORACLE_HOME:-${CURRENT_ORACLE_HOME}}"
  local -a dbs=("${ACTIVE_DBS[@]}")

  if [[ ${#dbs[@]} -eq 0 ]]; then
    log_warn "Keine Datenbanken für Datapatch gefunden"
  else
    log_section "Datapatch"

    # Seriell oder parallel je nach MAX_PARALLEL_DATAPATCH
    local running=0
    for sid in "${dbs[@]}"; do
      run_datapatch "${sid}"
      ((running++))

      if [[ ${running} -ge ${MAX_PARALLEL_DATAPATCH:-1} ]]; then
        wait_for_datapatch || true
        running=0
        # DATAPATCH_PIDS leeren für nächste Runde
        unset DATAPATCH_PIDS
        declare -gA DATAPATCH_PIDS
      fi
    done

    # Restliche Prozesse abwarten
    [[ ${running} -gt 0 ]] && wait_for_datapatch || true

    # Datapatch-Ergebnisse in Report schreiben
    for sid in "${dbs[@]}"; do
      local dp_status="OK"
      [[ "${DATAPATCH_EXIT_CODES[${sid}]:-1}" -ne 0 ]] && dp_status="FAILED"
      report_add_db_result "${sid}" "datapatch" "${dp_status}"
    done
  fi

  # Phase 5: Finale Verifikation
  log_section "Finale Verifikation"
  local verify_errors=0
  for sid in "${dbs[@]}"; do
    verify_db_open "${sid}" "${CURRENT_ORACLE_HOME}" && \
      report_add_db_result "${sid}" "verify" "OK" || {
        report_add_db_result "${sid}" "verify" "FAILED"
        ((verify_errors++))
      }
  done

  [[ ${verify_errors} -gt 0 ]] && add_error "${verify_errors} Datenbank(en) nicht OPEN nach Patching"

  # Logs aufräumen
  cleanup_logs 2>/dev/null || true

  report_finalize
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  _load_libs

  # CLI parsen (setzt MODE und andere Flags)
  parse_args "$@"

  # Sonderkommandos ohne Lock und Config
  _handle_special_commands

  # Konfiguration laden und validieren
  load_config
  init_logging 2>/dev/null || true

  # Traps setzen
  _setup_traps

  # Lock setzen (außer bei Status und Rollback)
  if [[ "${MODE}" != "status" ]]; then
    acquire_lock
  fi

  # Preflight-Zusammenfassung
  log_preflight_summary

  # Modus ausführen
  case "${MODE}" in
    status)
      run_status
      ;;
    test)
      run_test_flow
      ;;
    prod)
      run_prod_flow
      ;;
    rollback)
      report_init
      run_rollback
      report_finalize
      ;;
    cleanup)
      run_cleanup
      cleanup_logs
      ;;
    interactive)
      _run_interactive_menu
      ;;
    *)
      log_error "Unbekannter Modus: ${MODE}"
      usage
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Interaktives Menü (Fallback wenn kein Argument)
# ---------------------------------------------------------------------------
_run_interactive_menu() {
  while true; do
    echo ""
    echo -e "\033[0;36m┌─────────────────────────────────────────────┐\033[0m"
    echo -e "\033[0;36m│\033[0m  Oracle 19c OOP Patching v${SCRIPT_VERSION}              \033[0;36m│\033[0m"
    echo -e "\033[0;36m├─────────────────────────────────────────────┤\033[0m"
    echo -e "\033[0;36m│\033[0m  1) Status anzeigen                          \033[0;36m│\033[0m"
    echo -e "\033[0;36m│\033[0m  2) Vorabprüfung (validate-only)             \033[0;36m│\033[0m"
    echo -e "\033[0;36m│\033[0m  3) Test-Modus (Clone + Patch, kein Switch)  \033[0;36m│\033[0m"
    echo -e "\033[0;36m│\033[0m  4) Produktions-Modus (vollständig)          \033[0;36m│\033[0m"
    echo -e "\033[0;36m│\033[0m  5) Rollback                                 \033[0;36m│\033[0m"
    echo -e "\033[0;36m│\033[0m  6) Cleanup alte Homes                       \033[0;36m│\033[0m"
    echo -e "\033[0;36m│\033[0m  7) Konfiguration prüfen                     \033[0;36m│\033[0m"
    echo -e "\033[0;36m│\033[0m  0) Beenden                                  \033[0;36m│\033[0m"
    echo -e "\033[0;36m└─────────────────────────────────────────────┘\033[0m"
    echo ""
    read -r -p "  Auswahl: " choice

    case "${choice}" in
      1) MODE="status";   run_status ;;
      2) MODE="prod"; VALIDATE_ONLY=true; run_prod_flow ;;
      3) MODE="test";     run_test_flow ;;
      4) MODE="prod";     run_prod_flow ;;
      5) MODE="rollback"; report_init; run_rollback; report_finalize ;;
      6) MODE="cleanup";  run_cleanup; cleanup_logs ;;
      7) config_doctor ;;
      0) log_info "Beendet"; exit 0 ;;
      *) log_warn "Ungültige Auswahl: ${choice}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Einstiegspunkt
# ---------------------------------------------------------------------------
main "$@"
