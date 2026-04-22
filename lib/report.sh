#!/usr/bin/env bash
# =============================================================================
# lib/report.sh - Reporting Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: report_init, report_add_db_result, report_finalize,
#           report_print_summary, report_write_json, report_notify
# Depends on: log.sh, config.sh
# =============================================================================

[[ -n "${_LIB_REPORT_SH:-}" ]] && return 0
readonly _LIB_REPORT_SH=1

# ---------------------------------------------------------------------------
# Globale Report-Variablen
# ---------------------------------------------------------------------------
REPORT_START_TIME=""
REPORT_END_TIME=""
REPORT_MODE=""
REPORT_OVERALL_STATUS="SUCCESS"   # SUCCESS | WARNING | FAILED
REPORT_OLD_HOME=""
REPORT_NEW_HOME=""
REPORT_PATCH_IDS=()
REPORT_ERRORS=()
REPORT_WARNINGS=()

# Pro-DB Ergebnisse: assoziative Arrays
declare -A REPORT_DB_CLONE_STATUS
declare -A REPORT_DB_SWITCH_STATUS
declare -A REPORT_DB_DATAPATCH_STATUS
declare -A REPORT_DB_VERIFY_STATUS

# ---------------------------------------------------------------------------
# report_init
# Initialisiert den Report zu Beginn des Patchings
# ---------------------------------------------------------------------------
report_init() {
  REPORT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  REPORT_MODE="${MODE:-unknown}"
  REPORT_OLD_HOME="${CURRENT_ORACLE_HOME:-unknown}"
  REPORT_NEW_HOME="${NEW_ORACLE_HOME:-TBD}"

  # Patch-IDs aus PATCH_BASE_DIR einlesen
  REPORT_PATCH_IDS=()
  if [[ -d "${PATCH_BASE_DIR:-}" ]]; then
    while IFS= read -r -d '' p; do
      REPORT_PATCH_IDS+=("$(basename "${p}")")
    done < <(find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" -print0 2>/dev/null)
  fi

  log_debug "Report initialisiert: ${REPORT_START_TIME}"
}

# ---------------------------------------------------------------------------
# report_add_db_result <sid> <phase> <status>
# phase: clone | switch | datapatch | verify
# status: OK | FAILED | SKIPPED | WARNING
# ---------------------------------------------------------------------------
report_add_db_result() {
  local sid="${1:?report_add_db_result: SID fehlt}"
  local phase="${2:?report_add_db_result: phase fehlt}"
  local status="${3:?report_add_db_result: status fehlt}"

  case "${phase}" in
    clone)     REPORT_DB_CLONE_STATUS["${sid}"]="${status}" ;;
    switch)    REPORT_DB_SWITCH_STATUS["${sid}"]="${status}" ;;
    datapatch) REPORT_DB_DATAPATCH_STATUS["${sid}"]="${status}" ;;
    verify)    REPORT_DB_VERIFY_STATUS["${sid}"]="${status}" ;;
    *)         log_warn "Unbekannte Report-Phase: ${phase}" ;;
  esac

  [[ "${status}" == "FAILED" ]] && REPORT_OVERALL_STATUS="FAILED"
  [[ "${status}" == "WARNING" ]] && \
    [[ "${REPORT_OVERALL_STATUS}" != "FAILED" ]] && \
    REPORT_OVERALL_STATUS="WARNING"
}

# ---------------------------------------------------------------------------
# add_error / add_warning
# Fügt globale Fehler/Warnungen dem Report hinzu
# ---------------------------------------------------------------------------
add_error() {
  REPORT_ERRORS+=("$*")
  REPORT_OVERALL_STATUS="FAILED"
}

add_warning() {
  REPORT_WARNINGS+=("$*")
  [[ "${REPORT_OVERALL_STATUS}" != "FAILED" ]] && REPORT_OVERALL_STATUS="WARNING"
}

# ---------------------------------------------------------------------------
# report_finalize
# Setzt Endzeit und schreibt alle Report-Ausgaben
# ---------------------------------------------------------------------------
report_finalize() {
  REPORT_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  REPORT_NEW_HOME="${NEW_ORACLE_HOME:-${REPORT_NEW_HOME}}"

  report_print_summary

  if [[ "${JSON_REPORT:-true}" == "true" ]]; then
    report_write_json
  fi

  if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
    report_notify
  fi
}

# ---------------------------------------------------------------------------
# report_print_summary
# Gibt den Abschlussbericht auf stdout/log aus
# ---------------------------------------------------------------------------
report_print_summary() {
  local duration=""
  if [[ -n "${REPORT_START_TIME}" ]] && [[ -n "${REPORT_END_TIME}" ]]; then
    local start_epoch end_epoch
    start_epoch=$(date -d "${REPORT_START_TIME}" +%s 2>/dev/null || echo 0)
    end_epoch=$(date -d "${REPORT_END_TIME}" +%s 2>/dev/null || echo 0)
    local secs=$(( end_epoch - start_epoch ))
    duration=$(printf "%02d:%02d:%02d" \
      $(( secs / 3600 )) $(( (secs % 3600) / 60 )) $(( secs % 60 )))
  fi

  # Status-Farbe
  local status_color
  case "${REPORT_OVERALL_STATUS}" in
    SUCCESS) status_color='\033[0;32m' ;;
    WARNING) status_color='\033[0;33m' ;;
    FAILED)  status_color='\033[0;31m' ;;
    *)       status_color='\033[0m' ;;
  esac

  echo ""
  echo -e "\033[0;36m╔══════════════════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[0;36m║\033[0m  \033[1mOracle 19c OOP Patching — Abschlussbericht\033[0m               \033[0;36m║\033[0m"
  echo -e "\033[0;36m╠══════════════════════════════════════════════════════════════╣\033[0m"
  printf "  %-22s %s\n"  "Host:"        "$(hostname)"
  printf "  %-22s %s\n"  "Modus:"       "${REPORT_MODE}"
  printf "  %-22s %s\n"  "Start:"       "${REPORT_START_TIME}"
  printf "  %-22s %s\n"  "Ende:"        "${REPORT_END_TIME}"
  printf "  %-22s %s\n"  "Dauer:"       "${duration:-?}"
  printf "  %-22s %s\n"  "Altes Home:"  "${REPORT_OLD_HOME}"
  printf "  %-22s %s\n"  "Neues Home:"  "${REPORT_NEW_HOME}"
  echo ""

  # Patch-IDs
  if [[ ${#REPORT_PATCH_IDS[@]} -gt 0 ]]; then
    printf "  %-22s\n" "Patches:"
    for pid in "${REPORT_PATCH_IDS[@]}"; do
      printf "    -> %s\n" "${pid}"
    done
    echo ""
  fi

  # Pro-DB Ergebnisse
  local all_sids=()
  for sid in \
    "${!REPORT_DB_CLONE_STATUS[@]}" \
    "${!REPORT_DB_SWITCH_STATUS[@]}" \
    "${!REPORT_DB_DATAPATCH_STATUS[@]}" \
    "${!REPORT_DB_VERIFY_STATUS[@]}"; do
    all_sids+=("${sid}")
  done
  # Deduplizieren
  local -A seen_sids
  local unique_sids=()
  for sid in "${all_sids[@]}"; do
    [[ -z "${seen_sids[${sid}]:-}" ]] && unique_sids+=("${sid}") && seen_sids["${sid}"]=1
  done

  if [[ ${#unique_sids[@]} -gt 0 ]]; then
    printf "  %-14s %-10s %-10s %-12s %-10s\n" \
      "Datenbank" "Clone" "Switch" "Datapatch" "Verify"
    echo "  ──────────────────────────────────────────────────────"
    for sid in "${unique_sids[@]}"; do
      printf "  %-14s %-10s %-10s %-12s %-10s\n" \
        "${sid}" \
        "${REPORT_DB_CLONE_STATUS[${sid}]:-─}" \
        "${REPORT_DB_SWITCH_STATUS[${sid}]:-─}" \
        "${REPORT_DB_DATAPATCH_STATUS[${sid}]:-─}" \
        "${REPORT_DB_VERIFY_STATUS[${sid}]:-─}"
    done
    echo ""
  fi

  # Fehler
  if [[ ${#REPORT_ERRORS[@]} -gt 0 ]]; then
    echo -e "  \033[0;31mFEHLER (${#REPORT_ERRORS[@]}):\033[0m"
    for err in "${REPORT_ERRORS[@]}"; do
      echo -e "  \033[0;31m  ✗ ${err}\033[0m"
    done
    echo ""
  fi

  # Warnungen
  if [[ ${#REPORT_WARNINGS[@]} -gt 0 ]]; then
    echo -e "  \033[0;33mWARNUNGEN (${#REPORT_WARNINGS[@]}):\033[0m"
    for warn in "${REPORT_WARNINGS[@]}"; do
      echo -e "  \033[0;33m  ⚠ ${warn}\033[0m"
    done
    echo ""
  fi

  echo -e "\033[0;36m╠══════════════════════════════════════════════════════════════╣\033[0m"
  echo -e "\033[0;36m║\033[0m  Gesamtstatus: ${status_color}${REPORT_OVERALL_STATUS}\033[0m"
  echo -e "\033[0;36m╚══════════════════════════════════════════════════════════════╝\033[0m"
  echo ""

  if [[ -n "${LOGFILE:-}" ]]; then
    echo "  Log: ${LOGFILE}"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# report_write_json
# Schreibt maschinenlesbaren JSON-Report
# ---------------------------------------------------------------------------
report_write_json() {
  local json_file="${LOGDIR}/oop_patch_report_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}.json"

  log_info "Schreibe JSON-Report: ${json_file}"

  # DB-Ergebnisse als JSON-Array aufbauen
  local db_json="["
  local first=true
  local -A all_sids_map
  for sid in \
    "${!REPORT_DB_CLONE_STATUS[@]}" \
    "${!REPORT_DB_SWITCH_STATUS[@]}" \
    "${!REPORT_DB_DATAPATCH_STATUS[@]}" \
    "${!REPORT_DB_VERIFY_STATUS[@]}"; do
    all_sids_map["${sid}"]=1
  done

  for sid in "${!all_sids_map[@]}"; do
    [[ "${first}" == "true" ]] && first=false || db_json+=","
    db_json+=$(printf \
      '{"sid":"%s","clone":"%s","switch":"%s","datapatch":"%s","verify":"%s"}' \
      "${sid}" \
      "${REPORT_DB_CLONE_STATUS[${sid}]:-null}" \
      "${REPORT_DB_SWITCH_STATUS[${sid}]:-null}" \
      "${REPORT_DB_DATAPATCH_STATUS[${sid}]:-null}" \
      "${REPORT_DB_VERIFY_STATUS[${sid}]:-null}")
  done
  db_json+="]"

  # Patch-IDs als JSON-Array
  local patches_json="["
  local pfirst=true
  for pid in "${REPORT_PATCH_IDS[@]}"; do
    [[ "${pfirst}" == "true" ]] && pfirst=false || patches_json+=","
    patches_json+="\"${pid}\""
  done
  patches_json+="]"

  # Fehler-Array
  local errors_json="["
  local efirst=true
  for err in "${REPORT_ERRORS[@]}"; do
    local escaped="${err//\"/\\\"}"
    [[ "${efirst}" == "true" ]] && efirst=false || errors_json+=","
    errors_json+="\"${escaped}\""
  done
  errors_json+="]"

  cat > "${json_file}" <<EOF
{
  "schema_version": "3.0",
  "host": "$(hostname)",
  "timestamp_start": "${REPORT_START_TIME}",
  "timestamp_end": "${REPORT_END_TIME}",
  "mode": "${REPORT_MODE}",
  "overall_status": "${REPORT_OVERALL_STATUS}",
  "dry_run": ${DRY_RUN:-false},
  "oracle": {
    "old_home": "${REPORT_OLD_HOME}",
    "new_home": "${REPORT_NEW_HOME}",
    "patch_base_dir": "${PATCH_BASE_DIR:-}",
    "patches": ${patches_json}
  },
  "databases": ${db_json},
  "errors": ${errors_json},
  "logfile": "${LOGFILE:-}"
}
EOF

  chmod 640 "${json_file}" 2>/dev/null || true
  log_success "JSON-Report geschrieben: ${json_file}"
}

# ---------------------------------------------------------------------------
# report_notify
# Sendet E-Mail-Benachrichtigung (nur wenn NOTIFY_EMAIL gesetzt und mail verfügbar)
# ---------------------------------------------------------------------------
report_notify() {
  [[ -z "${NOTIFY_EMAIL:-}" ]] && return 0

  if ! command -v mail &>/dev/null; then
    log_warn "mail-Kommando nicht verfügbar — E-Mail-Benachrichtigung übersprungen"
    return 0
  fi

  local subject="[OOP-Patch] ${REPORT_OVERALL_STATUS} | $(hostname) | ${REPORT_MODE} | ${REPORT_END_TIME}"

  {
    echo "Oracle 19c OOP Patching Abschlussbericht"
    echo ""
    echo "Host:         $(hostname)"
    echo "Modus:        ${REPORT_MODE}"
    echo "Status:       ${REPORT_OVERALL_STATUS}"
    echo "Start:        ${REPORT_START_TIME}"
    echo "Ende:         ${REPORT_END_TIME}"
    echo "Altes Home:   ${REPORT_OLD_HOME}"
    echo "Neues Home:   ${REPORT_NEW_HOME}"
    echo "Log:          ${LOGFILE:-n/a}"
    if [[ ${#REPORT_ERRORS[@]} -gt 0 ]]; then
      echo ""
      echo "FEHLER:"
      for err in "${REPORT_ERRORS[@]}"; do
        echo "  - ${err}"
      done
    fi
  } | mail -s "${subject}" "${NOTIFY_EMAIL}"

  log_info "E-Mail-Benachrichtigung gesendet an: ${NOTIFY_EMAIL}"
}
