#!/usr/bin/env bash
# =============================================================================
# lib/cleanup.sh - Oracle Home Cleanup Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: run_cleanup
# Logik: Findet alte Oracle Homes, prüft ob sie noch aktiv genutzt werden,
#        entfernt sie nach Bestätigung (mit Inventory-Cleanup optional)
# Depends on: log.sh, config.sh, oracle.sh
# =============================================================================

[[ -n "${_LIB_CLEANUP_SH:-}" ]] && return 0
readonly _LIB_CLEANUP_SH=1

# ---------------------------------------------------------------------------
# run_cleanup
# Hauptfunktion: findet und bereinigt alte Oracle Homes
# ---------------------------------------------------------------------------
run_cleanup() {
  log_section "Oracle Home Cleanup"
  CURRENT_PHASE="CLEANUP"

  # Alle Oracle Homes aus oratab einlesen
  get_oracle_homes
  local all_homes=("${ORACLE_HOMES[@]}")

  if [[ ${#all_homes[@]} -eq 0 ]]; then
    log_info "Keine Oracle Homes in oratab gefunden"
    CURRENT_PHASE=""
    return 0
  fi

  log_info "Gefundene Oracle Homes: ${#all_homes[@]}"
  for h in "${all_homes[@]}"; do
    log_info "  -> ${h}"
  done

  # Kandidaten für Cleanup ermitteln
  local -a candidates=()
  _cleanup_find_candidates candidates "${all_homes[@]}"

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_success "Keine bereinigungswürdigen Oracle Homes gefunden"
    CURRENT_PHASE=""
    return 0
  fi

  log_info "Cleanup-Kandidaten: ${#candidates[@]}"
  for c in "${candidates[@]}"; do
    log_info "  -> ${c}"
  done

  # Sicherheitsprüfung: KEEP_HOMES einhalten
  local active_count=${#all_homes[@]}
  local to_remove=${#candidates[@]}
  local remaining=$(( active_count - to_remove ))

  if [[ ${remaining} -lt ${KEEP_HOMES:-2} ]]; then
    log_warn "Cleanup würde nur ${remaining} Home(s) übrig lassen (KEEP_HOMES=${KEEP_HOMES:-2})"
    log_warn "Weniger Homes werden entfernt um Mindestanzahl einzuhalten"
    # Kandidatenliste kürzen
    local max_remove=$(( active_count - ${KEEP_HOMES:-2} ))
    [[ ${max_remove} -le 0 ]] && {
      log_info "Nichts zu bereinigen (KEEP_HOMES-Limit erreicht)"
      CURRENT_PHASE=""
      return 0
    }
    candidates=("${candidates[@]:0:${max_remove}}")
    log_info "Bereinige maximal ${max_remove} Home(s)"
  fi

  # Bestätigung
  _cleanup_confirm "${candidates[@]}" || {
    CURRENT_PHASE=""
    return 0
  }

  # Cleanup durchführen
  local cleaned=0
  local failed=0

  for home in "${candidates[@]}"; do
    _cleanup_remove_home "${home}" && ((cleaned++)) || ((failed++))
  done

  log_section "Cleanup-Ergebnis"
  log_info "Bereinigt:  ${cleaned}"
  log_info "Fehlerhaft: ${failed}"
  [[ ${failed} -eq 0 ]] && log_success "Cleanup erfolgreich abgeschlossen" || \
    log_warn "Cleanup mit ${failed} Fehler(n) abgeschlossen"

  CURRENT_PHASE=""
}

# ---------------------------------------------------------------------------
# _cleanup_find_candidates <array_ref> <homes...>
# Filtert Homes die bereinigt werden können:
# - Nicht das aktuelle CURRENT_ORACLE_HOME
# - Nicht aktiv in oratab eingetragen (keine laufenden DBs)
# - Älter als AUTO_CLEANUP_DAYS (wenn gesetzt, anhand mtime des Verzeichnisses)
# ---------------------------------------------------------------------------
_cleanup_find_candidates() {
  local -n _result_ref=$1
  shift
  local homes=("$@")

  local active_home="${CURRENT_ORACLE_HOME}"

  for home in "${homes[@]}"; do
    # Aktuelles Home nie anfassen
    [[ "${home}" == "${active_home}" ]] && continue

    # Home muss existieren
    [[ ! -d "${home}" ]] && continue

    # Prüfe ob noch DBs auf dieses Home zeigen
    local db_count
    db_count=$(awk -F: -v oh="${home}" \
      '!/^#/ && NF>=2 && $2==oh {count++} END{print count+0}' \
      /etc/oratab 2>/dev/null)

    if [[ ${db_count} -gt 0 ]]; then
      log_debug "Home übersprungen (${db_count} DB(s) aktiv): ${home}"
      continue
    fi

    # Alterscheck wenn AUTO_CLEANUP_DAYS gesetzt
    if [[ -n "${AUTO_CLEANUP_DAYS:-}" ]] && [[ ${AUTO_CLEANUP_DAYS} -gt 0 ]]; then
      local home_age_days
      home_age_days=$(( ( $(date +%s) - $(stat -c %Y "${home}" 2>/dev/null || echo 0) ) / 86400 ))

      if [[ ${home_age_days} -lt ${AUTO_CLEANUP_DAYS} ]]; then
        log_debug "Home zu jung für Cleanup (${home_age_days}d < ${AUTO_CLEANUP_DAYS}d): ${home}"
        continue
      fi
      log_debug "Home Alter: ${home_age_days} Tage — Cleanup-Kandidat: ${home}"
    fi

    _result_ref+=("${home}")
  done
}

# ---------------------------------------------------------------------------
# _cleanup_confirm <homes...>
# Zeigt Übersicht und fragt nach Bestätigung
# ---------------------------------------------------------------------------
_cleanup_confirm() {
  local homes=("$@")

  [[ "${DRY_RUN:-false}" == "true" ]] && {
    log_info "[DRY-RUN] Cleanup-Bestätigung übersprungen"
    for h in "${homes[@]}"; do
      log_info "[DRY-RUN] Würde löschen: ${h}"
    done
    return 0
  }

  if [[ "${ALLOW_AUTO_CLEANUP:-false}" == "true" ]] && \
     [[ "${UNATTENDED_MODE:-false}" == "true" ]]; then
    log_info "Auto-Cleanup aktiv (ALLOW_AUTO_CLEANUP=true, UNATTENDED_MODE=true)"
    return 0
  fi

  if [[ "${ALLOW_AUTO_CLEANUP:-false}" != "true" ]] && \
     [[ "${UNATTENDED_MODE:-false}" == "true" ]]; then
    log_warn "ALLOW_AUTO_CLEANUP=false — Cleanup im Unattended-Modus nicht erlaubt"
    return 1
  fi

  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │         Folgende Oracle Homes werden gelöscht       │"
  echo "  ├─────────────────────────────────────────────────────┤"
  for h in "${homes[@]}"; do
    local size_mb
    size_mb=$(du -sm "${h}" 2>/dev/null | awk '{print $1}')
    printf "  │  %-48s│\n" "${h} (~${size_mb} MB)"
  done
  echo "  └─────────────────────────────────────────────────────┘"
  echo ""
  read -r -p "  Cleanup jetzt durchführen? (yes/no): " confirm
  echo ""

  [[ "${confirm}" != "yes" ]] && { log_info "Cleanup abgebrochen"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# _cleanup_remove_home <oracle_home>
# Entfernt ein einzelnes Oracle Home:
# 1. Inventory-Eintrag entfernen (optional)
# 2. Verzeichnis löschen
# ---------------------------------------------------------------------------
_cleanup_remove_home() {
  local home="$1"

  log_info "Entferne Oracle Home: ${home}"

  # Größe vor dem Löschen ermitteln
  local size_mb
  size_mb=$(du -sm "${home}" 2>/dev/null | awk '{print $1}')

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] Würde löschen: ${home} (~${size_mb} MB)"
    return 0
  fi

  # Inventory-Eintrag entfernen (nur wenn aktiviert)
  if [[ "${ENABLE_INVENTORY_REMOVE:-false}" == "true" ]]; then
    inventory_remove_home "${home}" || log_warn "Inventory-Entfernung fehlgeschlagen: ${home}"
  fi

  # Verzeichnis löschen
  rm -rf "${home}" 2>/dev/null
  local rc=$?

  if [[ ${rc} -ne 0 ]]; then
    log_error "Löschen fehlgeschlagen (RC=${rc}): ${home}"
    return 1
  fi

  log_success "Oracle Home entfernt: ${home} (~${size_mb} MB freigegeben)"
  return 0
}

# ---------------------------------------------------------------------------
# cleanup_logs
# Entfernt alte Log-Dateien aus LOGDIR
# ---------------------------------------------------------------------------
cleanup_logs() {
  local logdir="${LOGDIR:-/work/dba/patching/logs}"
  local days="${AUTO_CLEANUP_DAYS:-30}"

  [[ ! -d "${logdir}" ]] && return 0

  log_info "Bereinige Logs älter als ${days} Tage in: ${logdir}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    find "${logdir}" -type f -name "*.log" -mtime "+${days}" 2>/dev/null | \
      while IFS= read -r f; do log_info "[DRY-RUN] Würde löschen: ${f}"; done
    return 0
  fi

  local count
  count=$(find "${logdir}" -type f -name "*.log" -mtime "+${days}" 2>/dev/null | wc -l)

  find "${logdir}" -type f \( -name "*.log" -o -name "*.log.rc" \) \
    -mtime "+${days}" -delete 2>/dev/null

  log_info "Log-Cleanup: ${count} Datei(en) entfernt"
}
