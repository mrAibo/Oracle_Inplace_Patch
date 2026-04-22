#!/usr/bin/env bash
# =============================================================================
# lib/cli.sh - CLI Argument Parser & Usage
# Oracle 19c OOP Patching Framework v3.0
# =============================================================================
# Provides: parse_args, usage
# Setzt globale Variablen: MODE, DRY_RUN, UNATTENDED_MODE,
#                          TARGET_DBS, PATCH_DIR_OVERRIDE, OH_OVERRIDE
# =============================================================================

[[ -n "${_LIB_CLI_SH:-}" ]] && return 0
readonly _LIB_CLI_SH=1

# Globale CLI-Variablen mit Defaults
MODE=""
TARGET_DBS=""        # kommaseparierte SID-Liste, leer = alle aus oratab
PATCH_DIR_OVERRIDE=""
OH_OVERRIDE=""
RESUME_MODE=false
VALIDATE_ONLY=false
PREPARE_ONLY=false
SWITCH_ONLY=false
DATAPATCH_ONLY=false

# ---------------------------------------------------------------------------
# parse_args
# ---------------------------------------------------------------------------
parse_args() {
  # Kein Argument => interaktiver Modus
  if [[ $# -eq 0 ]]; then
    MODE="${DEFAULT_MODE:-interactive}"
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        MODE="status"
        shift
        ;;
      --test)
        MODE="test"
        shift
        ;;
      --prod)
        MODE="prod"
        shift
        ;;
      --validate-only)
        MODE="prod"
        VALIDATE_ONLY=true
        shift
        ;;
      --prepare-only)
        MODE="prod"
        PREPARE_ONLY=true
        shift
        ;;
      --switch-only)
        MODE="prod"
        SWITCH_ONLY=true
        shift
        ;;
      --datapatch-only)
        MODE="prod"
        DATAPATCH_ONLY=true
        shift
        ;;
      --resume)
        MODE="prod"
        RESUME_MODE=true
        shift
        ;;
      --rollback)
        MODE="rollback"
        shift
        ;;
      --cleanup)
        MODE="cleanup"
        shift
        ;;
      --create-config)
        MODE="create-config"
        shift
        ;;
      --config-doctor)
        MODE="config-doctor"
        shift
        ;;
      --force|-f)
        UNATTENDED_MODE=true
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=true
        shift
        ;;
      --db)
        [[ -z "${2:-}" ]] && die "--db erfordert eine SID-Liste (z.B. --db PROD1,PROD2)"
        TARGET_DBS="$2"
        shift 2
        ;;
      --patch-dir)
        [[ -z "${2:-}" ]] && die "--patch-dir erfordert einen Pfad"
        PATCH_DIR_OVERRIDE="$2"
        shift 2
        ;;
      --oh|--oracle-home)
        [[ -z "${2:-}" ]] && die "--oh erfordert einen Pfad"
        OH_OVERRIDE="$2"
        shift 2
        ;;
      --json)
        JSON_REPORT=true
        shift
        ;;
      --debug)
        LOG_LEVEL="DEBUG"
        shift
        ;;
      -h|-?|--help)
        usage
        exit 0
        ;;
      --prepare-status)    ACTION="prepare_status"  ; shift ;;
      --prepare-list)      ACTION="prepare_list"    ; shift ;;
      --prepare-validate)  ACTION="prepare_validate"; shift ;;
      --unzip)             ACTION="prepare_unzip"
                         PREPARE_ZIP_FILE="${2:?--unzip: Datei fehlt}"
                         shift 2 ;;
      --unzip-all)         ACTION="prepare_unzip_all"
                           PREPARE_ZIP_DIR="${2:?--unzip-all: Verz. fehlt}"
                           shift 2 ;;
      --cleanup-zips)      ACTION="prepare_cleanup_zips"; shift ;;
      --delete-zips)       PREPARE_DELETE_ZIPS=true; shift ;;
      *)
        log_error "Unbekannte Option: $1"
        usage
        exit 1
        ;;
    esac
  done

  # Validierung: MODE muss gesetzt sein
  if [[ -z "${MODE}" ]]; then
    MODE="${DEFAULT_MODE:-interactive}"
  fi

  # OH_OVERRIDE anwenden
  [[ -n "${OH_OVERRIDE}" ]] && CURRENT_ORACLE_HOME="${OH_OVERRIDE}"

  # PATCH_DIR_OVERRIDE anwenden
  [[ -n "${PATCH_DIR_OVERRIDE}" ]] && PATCH_BASE_DIR="${PATCH_DIR_OVERRIDE}"
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  local sn="${SCRIPT_NAME:-oop_patch.sh}"
  echo ""
  echo -e "\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
  echo -e "\033[1m  Oracle 19c Out-of-Place Patching Framework v${SCRIPT_VERSION:-3.0}\033[0m"
  echo -e "\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
  echo ""
  echo -e "\033[0;32mVERWENDUNG\033[0m"
  echo "  ${sn} [OPTION] [FLAGS]"
  echo ""
  echo -e "\033[0;32mMODI\033[0m"
  echo "  --status              Detaillierte Statusanzeige"
  echo "  --test                Test-Modus: Clone + Patch, kein DB-Switch"
  echo "  --prod                Produktions-Modus: vollständiges Patching mit Downtime"
  echo "  --rollback            Zurück zum vorherigen Oracle Home"
  echo "  --cleanup             Alte Oracle Homes bereinigen"
  echo "  --create-config       Standard-Konfigurationsdatei erstellen"
  echo "  --config-doctor       Konfiguration prüfen und anzeigen"
  echo ""
  echo -e "\033[0;32mPROD-TEILSCHRITTE (einzeln ausführbar)\033[0m"
  echo "  --validate-only       Nur Vorabprüfungen (kein Clone, keine DB-Änderung)"
  echo "  --prepare-only        Clone + Patch, kein DB-Switch"
  echo "  --switch-only         Nur DB-Switch (New Home muss existieren)"
  echo "  --datapatch-only      Nur Datapatch im neuen Home ausführen"
  echo "  --resume              Unterbrochenen Lauf fortsetzen"
  echo ""
  echo -e "\033[0;32mFLAGS\033[0m"
  echo "  --db SID1,SID2        Nur diese Datenbanken patchen (Standard: alle aus oratab)"
  echo "  --patch-dir /pfad     Patch-Verzeichnis überschreiben"
  echo "  --oh /oracle/19       Aktuelles Oracle Home überschreiben"
  echo "  --force, -f           Unattended: alle Bestätigungen überspringen"
  echo "  --dry-run, -n         Simulationsmodus: keine Änderungen"
  echo "  --debug               Log-Level auf DEBUG setzen"
  echo "  --json                JSON-Report erzeugen"
  echo "  -h, --help            Diese Hilfe anzeigen"
  echo ""
  echo -e "\033[0;32mBEISPIELE\033[0m"
  echo -e "  \033[0;33m# Ersteinrichtung\033[0m"
  echo "  ${sn} --create-config"
  echo "  vi ~/.patchrc"
  echo ""
  echo -e "  \033[0;33m# Status prüfen\033[0m"
  echo "  ${sn} --status"
  echo ""
  echo -e "  \033[0;33m# Nur Vorab-Prüfung (kein Eingriff)\033[0m"
  echo "  ${sn} --validate-only"
  echo ""
  echo -e "  \033[0;33m# Test-Patching (kein DB-Switch)\033[0m"
  echo "  ${sn} --test"
  echo ""
  echo -e "  \033[0;33m# Produktion interaktiv\033[0m"
  echo "  ${sn} --prod"
  echo ""
  echo -e "  \033[0;33m# Produktion unattended, nur DB PROD1\033[0m"
  echo "  ${sn} --prod --force --db PROD1"
  echo ""
  echo -e "  \033[0;33m# Dry-Run Produktion\033[0m"
  echo "  ${sn} --prod --dry-run"
  echo ""
  echo -e "  \033[0;33m# Rollback\033[0m"
  echo "  ${sn} --rollback"
  echo ""
  echo -e "  \033[0;33m# Unterbrochenen Lauf fortsetzen\033[0m"
  echo "  ${sn} --resume"
  echo ""
  echo -e "\033[0;32mKONFIGURATION\033[0m"
  echo "  Konfig-Datei: ${PATCHRC:-~/.patchrc}"
  echo ""
}
