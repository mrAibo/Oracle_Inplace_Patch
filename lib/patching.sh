#!/usr/bin/env bash
# =============================================================================
# lib/patching.sh - Clone, OPatch & Datapatch Module
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: clone_oracle_home, apply_opatch, run_datapatch,
#           wait_for_datapatch, verify_patch_applied
# Depends on: log.sh, config.sh, oracle.sh
# =============================================================================

[[ -n "${_LIB_PATCHING_SH:-}" ]] && return 0
readonly _LIB_PATCHING_SH=1

# ---------------------------------------------------------------------------
# clone_oracle_home
# Klont CURRENT_ORACLE_HOME nach NEW_ORACLE_HOME via rsync
# Setzt globale Variable NEW_ORACLE_HOME
# ---------------------------------------------------------------------------
clone_oracle_home() {
  local timestamp="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
  NEW_ORACLE_HOME="${ORACLE_BASE}/$(basename "${CURRENT_ORACLE_HOME}")_${timestamp}"

  log_section "Clone Oracle Home"
  log_info "Quelle:  ${CURRENT_ORACLE_HOME}"
  log_info "Ziel:    ${NEW_ORACLE_HOME}"

  # Speicherplatz-Vorabprüfung
  local src_size_mb
  src_size_mb=$(du -sm "${CURRENT_ORACLE_HOME}" 2>/dev/null | awk '{print $1}')
  local avail_mb
  avail_mb=$(df -m "${ORACLE_BASE}" 2>/dev/null | tail -1 | awk '{print $4}')
  local needed_mb
  needed_mb=$(awk "BEGIN{printf \"%d\", ${src_size_mb} * ${SPACE_BUFFER_FACTOR:-1.5}}")

  log_info "Größe Quelle: ${src_size_mb} MB | Benötigt: ${needed_mb} MB | Verfügbar: ${avail_mb} MB"

  if [[ ${avail_mb} -lt ${needed_mb} ]]; then
    die "Zu wenig Speicherplatz für Clone: benötigt ${needed_mb} MB, verfügbar ${avail_mb} MB"
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] rsync -a --delete ${CURRENT_ORACLE_HOME}/ ${NEW_ORACLE_HOME}/"
    mkdir -p "${NEW_ORACLE_HOME}"
    return 0
  fi

  mkdir -p "${NEW_ORACLE_HOME}" || die "Konnte Zielverzeichnis nicht erstellen: ${NEW_ORACLE_HOME}"

  log_info "Starte rsync Clone..."
  local rsync_start
  rsync_start=$(date +%s)

  rsync -a --delete \
    --exclude="dbs/*.ora" \
    --exclude="network/admin/*.ora" \
    --exclude="log/" \
    --exclude="rdbms/audit/" \
    "${CURRENT_ORACLE_HOME}/" \
    "${NEW_ORACLE_HOME}/" 2>&1 | \
    while IFS= read -r line; do log_debug "rsync: ${line}"; done

  local rc=${PIPESTATUS[0]}
  local rsync_end
  rsync_end=$(date +%s)
  local elapsed=$(( rsync_end - rsync_start ))

  if [[ ${rc} -ne 0 ]]; then
    rm -rf "${NEW_ORACLE_HOME}" 2>/dev/null || true
    die "rsync Clone fehlgeschlagen (RC=${rc})"
  fi

  # Größenvergleich zur Plausibilitätsprüfung
  local new_size_mb
  new_size_mb=$(du -sm "${NEW_ORACLE_HOME}" 2>/dev/null | awk '{print $1}')
  local diff_pct
  diff_pct=$(awk "BEGIN{printf \"%d\", \
    (${src_size_mb} - ${new_size_mb}) * 100 / (${src_size_mb} + 0.001)}")

  if [[ ${diff_pct#-} -gt ${CLONE_TOLERANCE_PCT:-5} ]]; then
    log_warn "Clone-Größe weicht um ${diff_pct}% ab (Quelle: ${src_size_mb} MB, Klon: ${new_size_mb} MB)"
  fi

  log_success "Clone abgeschlossen: ${NEW_ORACLE_HOME} (${new_size_mb} MB, ${elapsed}s)"

  # Oracle Central Inventory aktualisieren
  inventory_register_home "${NEW_ORACLE_HOME}"
}

# ---------------------------------------------------------------------------
# apply_opatch
# Wendet alle Patches aus PATCH_BASE_DIR auf NEW_ORACLE_HOME an
# ---------------------------------------------------------------------------
apply_opatch() {
  local oh="${NEW_ORACLE_HOME:?apply_opatch: NEW_ORACLE_HOME nicht gesetzt}"
  local opatch="${oh}/OPatch/opatch"
  local patch_dir="${PATCH_BASE_DIR:?apply_opatch: PATCH_BASE_DIR nicht gesetzt}"

  log_section "OPatch Apply"
  log_info "Oracle Home: ${oh}"
  log_info "Patch-Dir:   ${patch_dir}"

  [[ ! -x "${opatch}" ]] && die "OPatch nicht gefunden: ${opatch}"

  # Alle numerischen Patch-Verzeichnisse finden
  local -a patches
  while IFS= read -r -d '' p; do
    patches+=("${p}")
  done < <(find "${patch_dir}" -maxdepth 1 -type d -name "[0-9]*" -print0 2>/dev/null)

  if [[ ${#patches[@]} -eq 0 ]]; then
    die "Keine Patches in ${patch_dir} gefunden"
  fi

  log_info "Gefundene Patches: ${#patches[@]}"
  for p in "${patches[@]}"; do
    log_info "  -> $(basename "${p}")"
  done

  # Konfliktprüfung
  log_info "Prüfe Patch-Konflikte..."
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    ORACLE_HOME="${oh}" "${opatch}" prereq CheckConflictAgainstOHWithDetail \
      -phBaseDir "${patch_dir}" 2>&1 | \
      while IFS= read -r line; do log_debug "opatch prereq: ${line}"; done

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      die "OPatch Konfliktprüfung fehlgeschlagen — Patching abgebrochen"
    fi
    log_success "Keine Konflikte gefunden"
  else
    log_info "[DRY-RUN] OPatch Konfliktprüfung übersprungen"
  fi

  # Patch anwenden
  local patch_start
  patch_start=$(date +%s)

  for patch_path in "${patches[@]}"; do
    local patch_id
    patch_id=$(basename "${patch_path}")
    log_info "Wende Patch an: ${patch_id}"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      log_info "[DRY-RUN] opatch apply ${patch_path}"
      continue
    fi

    local output
    output=$(ORACLE_HOME="${oh}" "${opatch}" apply \
      -silent \
      -ocmrf /dev/null \
      "${patch_path}" 2>&1)
    local rc=$?

    log_debug "opatch output: ${output}"

    if [[ ${rc} -ne 0 ]]; then
      # Bereits installiert ist kein Fehler
      if echo "${output}" | grep -qi "already installed\|Patch already applied"; then
        log_warn "Patch ${patch_id} ist bereits installiert — übersprungen"
        continue
      fi
      die "OPatch Apply fehlgeschlagen für Patch ${patch_id} (RC=${rc})"
    fi

    log_success "Patch ${patch_id} erfolgreich angewendet"
  done

  local patch_end
  patch_end=$(date +%s)
  local elapsed=$(( patch_end - patch_start ))
  log_success "OPatch Apply abgeschlossen (${elapsed}s)"
}

# ---------------------------------------------------------------------------
# run_datapatch <sid>
# Führt datapatch für eine einzelne DB aus (im Hintergrund)
# Schreibt PID in DATAPATCH_PIDS[sid]
# ---------------------------------------------------------------------------
declare -A DATAPATCH_PIDS
declare -A DATAPATCH_LOGFILES
declare -A DATAPATCH_EXIT_CODES

run_datapatch() {
  local sid="${1:?run_datapatch: SID fehlt}"
  local oh="${NEW_ORACLE_HOME:?run_datapatch: NEW_ORACLE_HOME nicht gesetzt}"
  local datapatch="${oh}/OPatch/datapatch"
  local dp_log="${LOGDIR}/datapatch_${sid}_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}.log"

  DATAPATCH_LOGFILES["${sid}"]="${dp_log}"

  log_info "Starte Datapatch für: ${sid}"

  if [[ ! -x "${datapatch}" ]]; then
    log_error "datapatch nicht gefunden: ${datapatch}"
    DATAPATCH_EXIT_CODES["${sid}"]=1
    return 1
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] datapatch -verbose für ${sid}"
    DATAPATCH_EXIT_CODES["${sid}"]=0
    return 0
  fi

  # Datapatch im Hintergrund starten
  (
    ORACLE_HOME="${oh}" \
    ORACLE_SID="${sid}" \
    "${datapatch}" -verbose >> "${dp_log}" 2>&1
    echo $? > "${dp_log}.rc"
  ) &

  DATAPATCH_PIDS["${sid}"]=$!
  log_info "Datapatch PID ${DATAPATCH_PIDS[${sid}]} gestartet für ${sid} (Log: ${dp_log})"
}

# ---------------------------------------------------------------------------
# wait_for_datapatch
# Wartet auf alle laufenden Datapatch-Prozesse (mit Timeout)
# Setzt DATAPATCH_EXIT_CODES[]
# ---------------------------------------------------------------------------
wait_for_datapatch() {
  local timeout="${DATAPATCH_TIMEOUT:-7200}"
  local overall_rc=0

  if [[ ${#DATAPATCH_PIDS[@]} -eq 0 ]]; then
    log_info "Keine laufenden Datapatch-Prozesse"
    return 0
  fi

  log_section "Warte auf Datapatch-Abschluss (Timeout: ${timeout}s)"

  local deadline=$(( $(date +%s) + timeout ))

  for sid in "${!DATAPATCH_PIDS[@]}"; do
    local pid="${DATAPATCH_PIDS[${sid}]}"
    local dp_log="${DATAPATCH_LOGFILES[${sid}]}"

    log_info "Warte auf Datapatch ${sid} (PID: ${pid})..."

    while kill -0 "${pid}" 2>/dev/null; do
      if [[ $(date +%s) -gt ${deadline} ]]; then
        log_error "Datapatch Timeout (${timeout}s) für ${sid} (PID: ${pid})"
        kill "${pid}" 2>/dev/null || true
        DATAPATCH_EXIT_CODES["${sid}"]=124
        overall_rc=1
        break
      fi
      sleep 10
    done

    # Exit-Code aus .rc Datei lesen
    if [[ -z "${DATAPATCH_EXIT_CODES[${sid}]:-}" ]]; then
      local rc_file="${dp_log}.rc"
      if [[ -f "${rc_file}" ]]; then
        DATAPATCH_EXIT_CODES["${sid}"]=$(cat "${rc_file}" 2>/dev/null || echo "1")
        rm -f "${rc_file}"
      else
        DATAPATCH_EXIT_CODES["${sid}"]=1
      fi
    fi

    local dp_rc="${DATAPATCH_EXIT_CODES[${sid}]}"
    if [[ ${dp_rc} -eq 0 ]]; then
      log_success "Datapatch ${sid}: erfolgreich"
    else
      log_error "Datapatch ${sid}: fehlgeschlagen (RC=${dp_rc})"
      log_error "Log: ${dp_log}"
      overall_rc=1
    fi
  done

  return ${overall_rc}
}

# ---------------------------------------------------------------------------
# verify_patch_applied <oracle_home> <patch_id>
# Prüft ob ein bestimmter Patch installiert ist
# ---------------------------------------------------------------------------
verify_patch_applied() {
  local oh="${1:?verify_patch_applied: oracle_home fehlt}"
  local patch_id="${2:?verify_patch_applied: patch_id fehlt}"
  local opatch="${oh}/OPatch/opatch"

  if ORACLE_HOME="${oh}" "${opatch}" lspatches 2>/dev/null | grep -q "${patch_id}"; then
    log_success "Patch ${patch_id} ist installiert in ${oh}"
    return 0
  else
    log_error "Patch ${patch_id} NICHT gefunden in ${oh}"
    return 1
  fi
}
