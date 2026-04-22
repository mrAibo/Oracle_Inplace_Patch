#!/usr/bin/env bash
# =============================================================================
# lib/prepare.sh - Patch-Vorbereitung Modul
# Oracle 19c OOP Patching Framework v3.1
# =============================================================================
# Bietet: action_prepare_list, action_prepare_unzip, action_prepare_unzip_all,
#         action_prepare_validate, action_prepare_status, action_prepare_cleanup_zips
# Benötigt: log.sh, config.sh
# =============================================================================

[[ -n "${_LIB_PREPARE_SH:-}" ]] && return 0
readonly _LIB_PREPARE_SH=1

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

# Prüft ob Datei dem Oracle-ZIP-Schema entspricht: p<ID>_<VER>_<PLAT>.zip
prepare_is_oracle_zip() {
  [[ "$(basename "$1")" =~ ^p[0-9]+_[0-9]+_.*\.zip$ ]]
}

# Extrahiert Patch-ID aus ZIP-Dateiname
prepare_patch_id_from_zip() {
  basename "$1" | grep -oE '^p([0-9]+)_' | tr -d 'p_'
}

# Menschenlesbare Größe
prepare_human_size() {
  local bytes="$1"
  if   command -v bc &>/dev/null; then
    if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; ${bytes}/1073741824" | bc)"
    elif (( bytes >= 1048576    )); then printf "%.0f MB" "$(echo "scale=0; ${bytes}/1048576"    | bc)"
    elif (( bytes >= 1024       )); then printf "%.0f KB" "$(echo "scale=0; ${bytes}/1024"       | bc)"
    else printf "%d B" "${bytes}"
    fi
  else
    printf "%d B" "${bytes}"
  fi
}

# Validiert ein entpacktes Patch-Verzeichnis auf Vollständigkeit
prepare_validate_dir() {
  local patch_dir="$1"
  local patch_id
  patch_id="$(basename "${patch_dir}")"
  local errors=0

  for item in "etc/config/inventory" "README.html"; do
    if [[ ! -e "${patch_dir}/${item}" ]]; then
      log_warn "  Patch ${patch_id}: fehlt ${item}"
      ((errors++))
    fi
  done

  local sub_count
  sub_count=$(find "${patch_dir}" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | wc -l)
  log_debug "  Patch ${patch_id}: ${sub_count} Sub-Patch-Verzeichnis(se)"

  return ${errors}
}

# ---------------------------------------------------------------------------
# Entpackt eine einzelne ZIP
# ---------------------------------------------------------------------------
prepare_unzip_one() {
  local zip_file="${1:?prepare_unzip_one: ZIP-Datei fehlt}"
  local target_dir="${PATCH_BASE_DIR:?PATCH_BASE_DIR nicht gesetzt}"
  local force="${2:-false}"

  [[ ! -f "${zip_file}" ]] && die "ZIP-Datei nicht gefunden: ${zip_file}"

  prepare_is_oracle_zip "${zip_file}" || \
    log_warn "Dateiname entspricht nicht dem Oracle-Schema — fahre trotzdem fort"

  local patch_id
  patch_id="$(prepare_patch_id_from_zip "${zip_file}")"
  local zip_size
  zip_size=$(stat -c%s "${zip_file}" 2>/dev/null || echo 0)

  log_info "ZIP-Datei  : ${zip_file}"
  log_info "Patch-ID   : ${patch_id:-unbekannt}"
  log_info "ZIP-Größe  : $(prepare_human_size ${zip_size})"
  log_info "Zielordner : ${target_dir}"

  # Speicherplatz prüfen
  local free_kb
  free_kb=$(df -k "${target_dir}" 2>/dev/null | awk 'NR==2 {print $4}' || echo 999999)
  local needed_kb=$(( zip_size / 1024 * 3 ))
  if (( free_kb < needed_kb )); then
    log_warn "Freier Speicher: $(prepare_human_size $((free_kb*1024))) — benötigt ca. $(prepare_human_size $((needed_kb*1024)))"
  fi

  # Bereits vorhanden?
  if [[ -n "${patch_id}" ]] && [[ -d "${target_dir}/${patch_id}" ]]; then
    if [[ "${force}" == "true" ]] || [[ "${UNATTENDED_MODE:-false}" == "true" ]]; then
      log_warn "Patch ${patch_id} bereits vorhanden — wird überschrieben (--force)"
      run_cmd rm -rf "${target_dir:?}/${patch_id}"
    else
      log_warn "Patch ${patch_id} bereits entpackt in: ${target_dir}/${patch_id}"
      read -r -p "  Überschreiben? [j/N] " confirm
      [[ "${confirm,,}" != "j" ]] && { log_info "Übersprungen"; return 0; }
      run_cmd rm -rf "${target_dir:?}/${patch_id}"
    fi
  fi

  run_cmd mkdir -p "${target_dir}"
  run_cmd unzip -q "${zip_file}" -d "${target_dir}"

  # Validieren
  if [[ -n "${patch_id}" ]] && [[ -d "${target_dir}/${patch_id}" ]]; then
    prepare_validate_dir "${target_dir}/${patch_id}" && \
      log_success "Patch ${patch_id} erfolgreich entpackt: ${target_dir}/${patch_id}" || \
      log_warn    "Patch ${patch_id} entpackt mit Warnungen"
  fi

  # ZIP löschen wenn gewünscht
  if [[ "${PREPARE_DELETE_ZIPS:-false}" == "true" ]]; then
    run_cmd rm -f "${zip_file}"
    log_info "ZIP gelöscht: $(basename "${zip_file}")"
  fi
}

# ---------------------------------------------------------------------------
# AKTION: Einzelne ZIP entpacken
# ---------------------------------------------------------------------------
action_prepare_unzip() {
  local zip_file="${PREPARE_ZIP_FILE:?--unzip: Datei nicht gesetzt}"
  log_section "Patch entpacken"
  prepare_unzip_one "${zip_file}"
}

# ---------------------------------------------------------------------------
# AKTION: Alle ZIPs in einem Verzeichnis entpacken
# ---------------------------------------------------------------------------
action_prepare_unzip_all() {
  local src_dir="${PREPARE_ZIP_DIR:?--unzip-all: Verzeichnis nicht gesetzt}"
  [[ ! -d "${src_dir}" ]] && die "Quellverzeichnis nicht gefunden: ${src_dir}"

  log_section "Alle Oracle Patch-ZIPs entpacken"
  log_info "Quelle : ${src_dir}"
  log_info "Ziel   : ${PATCH_BASE_DIR}"

  local -a zips=()
  while IFS= read -r -d '' f; do
    prepare_is_oracle_zip "${f}" && zips+=("${f}")
  done < <(find "${src_dir}" -maxdepth 1 -name "*.zip" -print0 2>/dev/null)

  if [[ ${#zips[@]} -eq 0 ]]; then
    log_warn "Keine Oracle Patch-ZIPs gefunden in: ${src_dir}"
    return 0
  fi

  log_info "Gefundene ZIPs: ${#zips[@]}"
  local ok=0 skipped=0 failed=0

  for zip_file in "${zips[@]}"; do
    local patch_id
    patch_id="$(prepare_patch_id_from_zip "${zip_file}")"
    local zip_size
    zip_size=$(stat -c%s "${zip_file}" 2>/dev/null || echo 0)
    echo -e "\n  → $(basename "${zip_file}") ($(prepare_human_size ${zip_size}), ID: ${patch_id:-?})"

    if [[ -n "${patch_id}" ]] && [[ -d "${PATCH_BASE_DIR}/${patch_id}" ]]; then
      log_warn "    Bereits vorhanden — übersprungen"
      ((skipped++)); continue
    fi

    run_cmd mkdir -p "${PATCH_BASE_DIR}"
    if run_cmd unzip -q "${zip_file}" -d "${PATCH_BASE_DIR}"; then
      if [[ -n "${patch_id}" ]] && [[ -d "${PATCH_BASE_DIR}/${patch_id}" ]]; then
        prepare_validate_dir "${PATCH_BASE_DIR}/${patch_id}" && \
          { log_success "    OK: ${PATCH_BASE_DIR}/${patch_id}"; ((ok++)); } || \
          { log_warn    "    Warnungen: ${patch_id}";            ((ok++)); }
      else
        log_success "    Entpackt"; ((ok++))
      fi
      [[ "${PREPARE_DELETE_ZIPS:-false}" == "true" ]] && \
        run_cmd rm -f "${zip_file}" && log_info "    ZIP gelöscht"
    else
      log_error "    FEHLER beim Entpacken"; ((failed++))
    fi
  done

  echo ""
  log_success "Erfolgreich : ${ok}"
  (( skipped > 0 )) && log_warn  "Übersprungen: ${skipped}"
  (( failed  > 0 )) && { log_error "Fehlgeschlagen: ${failed}"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# AKTION: Validierung aller entpackten Patches
# ---------------------------------------------------------------------------
action_prepare_validate() {
  log_section "Patch-Validierung"
  log_info "Patch-Verzeichnis: ${PATCH_BASE_DIR}"
  [[ ! -d "${PATCH_BASE_DIR}" ]] && die "Verzeichnis nicht gefunden: ${PATCH_BASE_DIR}"

  local -a patch_dirs=()
  while IFS= read -r -d '' d; do
    patch_dirs+=("${d}")
  done < <(find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" -print0 2>/dev/null)

  if [[ ${#patch_dirs[@]} -eq 0 ]]; then
    log_warn "Keine entpackten Patches gefunden in: ${PATCH_BASE_DIR}"
    return 0
  fi

  local ok=0 warn=0

  printf "\n  %-15s %-10s %-8s %s\n" "Patch-ID" "Sub-Patches" "Status" "Pfad"
  printf "  %s\n" "$(printf '─%.0s' {1..72})"

  for d in "${patch_dirs[@]}"; do
    local pid="$(basename "${d}")"
    local sub_count
    sub_count=$(find "${d}" -maxdepth 1 -type d -name "[0-9]*" 2>/dev/null | wc -l)
    local size
    size=$(du -sh "${d}" 2>/dev/null | awk '{print $1}' || echo "?")
    local status="OK"

    [[ ! -f "${d}/README.html"          ]] && status="WARN"
    [[ ! -f "${d}/etc/config/inventory" ]] && status="WARN"

    case "${status}" in
      OK)   printf "  \033[0;32m%-15s\033[0m %-10s \033[0;32m%-8s\033[0m %s (%s)\n" \
              "${pid}" "${sub_count}" "${status}" "${d}" "${size}"; ((ok++)) ;;
      WARN) printf "  \033[0;33m%-15s\033[0m %-10s \033[0;33m%-8s\033[0m %s\n" \
              "${pid}" "${sub_count}" "${status}" "${d}"; ((warn++)) ;;
    esac
  done

  echo ""
  log_success "Valide    : ${ok}"
  (( warn > 0 )) && log_warn "Warnungen : ${warn}"
}

# ---------------------------------------------------------------------------
# AKTION: Liste aller Patches
# ---------------------------------------------------------------------------
action_prepare_list() {
  log_section "Vorbereitete Patches"
  [[ ! -d "${PATCH_BASE_DIR}" ]] && { log_warn "Kein Patch-Verzeichnis: ${PATCH_BASE_DIR}"; return 0; }

  local -a patch_dirs=()
  while IFS= read -r -d '' d; do
    patch_dirs+=("${d}")
  done < <(find "${PATCH_BASE_DIR}" -maxdepth 1 -type d -name "[0-9]*" -print0 2>/dev/null)

  if [[ ${#patch_dirs[@]} -eq 0 ]]; then
    log_warn "Keine entpackten Patches gefunden"
    return 0
  fi

  printf "\n  %-15s %-8s %-12s %s\n" "Patch-ID" "Größe" "Geändert" "Pfad"
  printf "  %s\n" "$(printf '─%.0s' {1..65})"
  for d in "${patch_dirs[@]}"; do
    local pid="$(basename "${d}")"
    local size; size=$(du -sh "${d}" 2>/dev/null | awk '{print $1}' || echo "?")
    local mtime; mtime=$(stat -c '%y' "${d}" 2>/dev/null | cut -c1-10 || echo "?")
    printf "  %-15s %-8s %-12s %s\n" "${pid}" "${size}" "${mtime}" "${d}"
  done
  echo ""
  log_info "Gesamt: ${#patch_dirs[@]} Patch(es)"
}

# ---------------------------------------------------------------------------
# AKTION: Status-Übersicht
# ---------------------------------------------------------------------------
action_prepare_status() {
  log_section "Patch-Verzeichnis Status"
  echo -e "  Verzeichnis: ${PATCH_BASE_DIR}"
  echo ""

  if [[ -d "${PATCH_BASE_DIR}" ]]; then
    echo -e "  Speicherplatz:"
    df -h "${PATCH_BASE_DIR}" 2>/dev/null | awk '
      NR==1 { printf "  %-20s %-8s %-8s %-8s %s\n",$1,$2,$3,$4,$5 }
      NR==2 { printf "  %-20s %-8s %-8s %-8s %s\n",$1,$2,$3,$4,$5 }
    '
    echo ""
  fi

  action_prepare_list

  local zip_count
  zip_count=$(find "${PATCH_BASE_DIR}" -maxdepth 2 -name "p*.zip" 2>/dev/null | wc -l)
  if (( zip_count > 0 )); then
    echo ""
    log_info "Noch vorhandene ZIP-Dateien: ${zip_count} (--cleanup-zips zum Löschen)"
    find "${PATCH_BASE_DIR}" -maxdepth 2 -name "p*.zip" 2>/dev/null | while read -r z; do
      local sz; sz=$(du -sh "${z}" 2>/dev/null | awk '{print $1}' || echo "?")
      printf "    %-8s %s\n" "${sz}" "$(basename "${z}")"
    done
  fi
}

# ---------------------------------------------------------------------------
# AKTION: Bereits entpackte ZIPs löschen
# ---------------------------------------------------------------------------
action_prepare_cleanup_zips() {
  log_section "ZIP-Cleanup"
  [[ ! -d "${PATCH_BASE_DIR}" ]] && { log_warn "Kein Patch-Verzeichnis: ${PATCH_BASE_DIR}"; return 0; }

  local -a zips=()
  while IFS= read -r -d '' f; do
    prepare_is_oracle_zip "${f}" && zips+=("${f}")
  done < <(find "${PATCH_BASE_DIR}" -maxdepth 2 -name "p*.zip" -print0 2>/dev/null)

  [[ ${#zips[@]} -eq 0 ]] && { log_info "Keine ZIP-Dateien gefunden"; return 0; }

  local total_size=0
  local -a to_delete=()

  for zip_file in "${zips[@]}"; do
    local patch_id; patch_id="$(prepare_patch_id_from_zip "${zip_file}")"
    local zip_size; zip_size=$(stat -c%s "${zip_file}" 2>/dev/null || echo 0)
    if [[ -n "${patch_id}" ]] && [[ -d "${PATCH_BASE_DIR}/${patch_id}" ]]; then
      to_delete+=("${zip_file}")
      total_size=$(( total_size + zip_size ))
      printf "  \033[0;32m✓ Entpackt\033[0m — löschen: %-40s (%s)\n" \
        "$(basename "${zip_file}")" "$(prepare_human_size ${zip_size})"
    else
      printf "  \033[0;33m! Nicht entpackt\033[0m — behalten: %s\n" "$(basename "${zip_file}")"
    fi
  done

  [[ ${#to_delete[@]} -eq 0 ]] && { log_info "Nichts zu löschen"; return 0; }

  echo ""
  log_info "Freizugebender Speicher: $(prepare_human_size ${total_size})"

  if [[ "${UNATTENDED_MODE:-false}" != "true" ]] && [[ "${DRY_RUN:-false}" != "true" ]]; then
    read -r -p "  ${#to_delete[@]} ZIP(s) löschen? [j/N] " confirm
    [[ "${confirm,,}" != "j" ]] && { log_info "Abgebrochen"; return 0; }
  fi

  local deleted=0
  for f in "${to_delete[@]}"; do
    run_cmd rm -f "${f}" && {
      log_success "Gelöscht: $(basename "${f}")"
      ((deleted++))
    } || log_error "Fehler: ${f}"
  done
  log_success "Fertig — ${deleted} Datei(en) gelöscht, $(prepare_human_size ${total_size}) freigegeben"
}
