# Oracle 19c Out-of-Place Patching Framework v3.0

![Shell](https://img.shields.io/badge/Shell-Bash%205%2B-4EAA25?logo=gnubash&logoColor=white)
![Oracle](https://img.shields.io/badge/Oracle-19c-F80000?logo=oracle&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform](https://img.shields.io/badge/Platform-SLES%20%7C%20RHEL%20%7C%20OEL-lightgrey)

Ein modulares, produktionserprobtes Bash-Framework für das **Out-of-Place Patching (OOP)** von Oracle 19c Datenbanken auf Linux. Das Framework klont das aktuelle Oracle Home, wendet Patches an, schaltet alle Datenbanken auf das neue Home um und führt Datapatch durch — mit vollständigem Rollback, Dry-Run-Modus und maschinenlesbarem JSON-Report.

---

## Inhaltsverzeichnis

- [Features](#features)
- [Architektur](#architektur)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Konfiguration](#konfiguration)
- [Verwendung](#verwendung)
- [Patchingablauf](#patchingablauf)
- [Module](#module)
- [Sicherheit](#sicherheit)
- [Fehlerbehandlung & Rollback](#fehlerbehandlung--rollback)
- [Reporting](#reporting)
- [FAQ](#faq)

---

## Features

| Feature | Beschreibung |
|---|---|
| **Modularer Aufbau** | 10 unabhängige Bash-Module, einzeln testbar und wartbar |
| **Out-of-Place** | Aktuelles Home bleibt unberührt bis Switch — sofortiger Rollback möglich |
| **Dry-Run** | Vollständige Simulation ohne reale Änderungen (`--dry-run`) |
| **Teilschritte** | Clone, Switch und Datapatch einzeln ausführbar |
| **Resume** | Unterbrochenen Lauf fortsetzen (`--resume`) |
| **Multi-DB** | Alle DBs eines Homes werden automatisch erkannt und umgeschaltet |
| **DB-Filter** | Nur bestimmte Datenbanken patchen (`--db SID1,SID2`) |
| **Rollback** | Vollautomatischer Rollback auf altes Home inkl. oratab-Restore |
| **JSON-Report** | Maschinenlesbarer Abschlussbericht für Monitoring/ITSM |
| **Prozess-Lock** | Verhindert parallele Ausführung auf demselben Host |
| **Unattended** | Vollautomatischer Betrieb für CI/CD-Pipelines (`--force`) |
| **Config-Doctor** | Konfigurationsdiagnose und Validierung |

---

## Architektur

```
oop_patch.sh                  ← Haupt-Orchestrator
├── lib/
│   ├── log.sh                ← Logging, Farben, log_section, die()
│   ├── lock.sh               ← Prozess-Locking via mkdir (atomar)
│   ├── config.sh             ← Konfiguration laden, validieren, erstellen
│   ├── cli.sh                ← Argument-Parser, Usage
│   ├── prereq.sh             ← Vorabprüfungen (User, Platz, Tools, OPatch)
│   ├── oracle.sh             ← oratab, Inventory, DB/Listener Start/Stop
│   ├── patching.sh           ← Clone (rsync), OPatch apply, Datapatch
│   ├── switch.sh             ← DB-Switch: Stop → oratab → Start
│   ├── rollback.sh           ← Rollback: Stop → oratab-Restore → Start
│   ├── cleanup.sh            ← Alte Homes + Logs bereinigen
│   └── report.sh             ← Plaintext + JSON Abschlussbericht
└── etc/
    └── patchrc.example       ← Kommentierte Beispielkonfiguration
```

### Phasenmodell

```
precheck → clone_home → apply_opatch → switch_db → datapatch → verify → cleanup
```

Jede Phase kann einzeln ausgeführt werden. Der Zustand wird über globale
Variablen und oratab-Backups konsistent gehalten.

---

## Voraussetzungen

### System

| Anforderung | Minimum |
|---|---|
| Betriebssystem | SLES 12/15, RHEL/OEL 7/8, Oracle Linux 8 |
| Bash | 5.0+ |
| Oracle Database | 19c (getestet mit 19.3 – 19.23) |
| OPatch | 12.2.0.1+ |
| Tools | `rsync`, `unzip`, `awk`, `sed`, `stat`, `du`, `df` |
| Speicherplatz | ~12–15 GB pro Oracle Home Clone |

### Berechtigungen

- Ausführung als **Oracle Software Owner** (z.B. `ora19`)
- Schreibrechte auf `/etc/oratab` (für oratab-Switch)
- Schreibrechte auf `ORACLE_BASE` (für Clone-Verzeichnis)
- Schreibrechte auf `LOGDIR`

---

## Installation

```bash
# Repository klonen
git clone https://github.com/mrAibo/Oracle_Inplace_Patch.git
cd Oracle_Inplace_Patch

# Ausführbar machen
chmod +x oop_patch.sh

# Konfigurationsdatei erstellen
./oop_patch.sh --create-config

# Konfiguration anpassen
vi ~/.patchrc

# Konfiguration prüfen
./oop_patch.sh --config-doctor
```

### Patches vorbereiten

```bash
# 1. ZIPs automatisch vorbereiten
./oop_patch.sh --unzip-all /downloads/oracle_patches/

# 2. Ergebnis prüfen
./oop_patch.sh --prepare-validate

# 3. Patchen
./oop_patch.sh --prod
```

---

## Konfiguration

Die Konfiguration erfolgt über `~/.patchrc` (oder `$PATCHRC`).

```bash
# Erstellen aus Vorlage
./oop_patch.sh --create-config

# Oder manuell aus Beispiel
cp etc/patchrc.example ~/.patchrc
vi ~/.patchrc
```

### Wichtigste Parameter

| Parameter | Standard | Beschreibung |
|---|---|---|
| `ORACLE_BASE` | `/oracle` | Oracle Base Verzeichnis |
| `CURRENT_ORACLE_HOME` | `/oracle/19` | Aktuell aktives Oracle Home |
| `PATCH_BASE_DIR_BASE` | `/work/dba/patching` | Verzeichnis mit den Patches |
| `LOGDIR` | `/work/dba/patching/logs` | Log-Verzeichnis |
| `REQUIRED_USER` | `ora19` | Oracle Software Owner |
| `DRY_RUN` | `false` | Simulationsmodus |
| `UNATTENDED_MODE` | `false` | Alle Bestätigungen überspringen |
| `MAX_PARALLEL_DATAPATCH` | `1` | Parallele Datapatch-Prozesse |
| `DATAPATCH_TIMEOUT` | `7200` | Datapatch-Timeout in Sekunden |
| `AUTO_CLEANUP_DAYS` | `30` | Homes älter als N Tage bereinigen |
| `KEEP_HOMES` | `2` | Mindestanzahl beizubehaltender Homes |
| `NOTIFY_EMAIL` | `` | E-Mail nach Abschluss |

Vollständige Dokumentation aller Parameter: [`etc/patchrc.example`](etc/patchrc.example)

---

## Verwendung

### Schnellstart

```bash
# 1. Status prüfen
./oop_patch.sh --status

# 2. Vorabprüfung (ohne Eingriff)
./oop_patch.sh --validate-only

# 3. Test-Modus: Clone + Patch, kein DB-Switch
./oop_patch.sh --test

# 4. Produktions-Modus (interaktiv)
./oop_patch.sh --prod

# 5. Rollback falls nötig
./oop_patch.sh --rollback
```

### Alle Optionen

```
MODI
  --status              Detaillierte Statusanzeige
  --test                Test-Modus: Clone + Patch, kein DB-Switch
  --prod                Produktions-Modus: vollständiges Patching mit Downtime
  --rollback            Zurück zum vorherigen Oracle Home
  --cleanup             Alte Oracle Homes bereinigen
  --create-config       Standard-Konfigurationsdatei erstellen
  --config-doctor       Konfiguration prüfen und anzeigen

PROD-TEILSCHRITTE
  --validate-only       Nur Vorabprüfungen (kein Clone, keine DB-Änderung)
  --prepare-only        Clone + Patch, kein DB-Switch
  --switch-only         Nur DB-Switch (New Home muss existieren)
  --datapatch-only      Nur Datapatch im neuen Home
  --resume              Unterbrochenen Lauf fortsetzen

FLAGS
  --db SID1,SID2        Nur diese Datenbanken patchen
  --patch-dir /pfad     Patch-Verzeichnis überschreiben
  --oh /oracle/19       Aktuelles Oracle Home überschreiben
  --force, -f           Unattended: alle Bestätigungen überspringen
  --dry-run, -n         Simulationsmodus: keine Änderungen
  --debug               Log-Level auf DEBUG
  --json                JSON-Report erzeugen
  -h, --help            Hilfe anzeigen
```

### Beispiele

```bash
# Nur bestimmte DBs patchen
./oop_patch.sh --prod --db PROD1,PROD2

# Vollautomatisch (CI/CD)
./oop_patch.sh --prod --force --json

# Schrittweise: erst vorbereiten, dann switchen
./oop_patch.sh --prepare-only
./oop_patch.sh --switch-only

# Dry-Run: alles simulieren
./oop_patch.sh --prod --dry-run

# Unterbrochenen Lauf fortsetzen
./oop_patch.sh --resume

# Anderes Patch-Verzeichnis verwenden
./oop_patch.sh --prod --patch-dir /mnt/patches/35742441

# Debug-Ausgabe
./oop_patch.sh --prod --debug
```

---

## Patchingablauf

### Vollständiger Produktions-Ablauf (`--prod`)

```
1. PRECHECK
   ├── Benutzer prüfen (REQUIRED_USER)
   ├── Oracle Home Struktur validieren
   ├── Speicherplatz prüfen (SPACE_BUFFER_FACTOR)
   ├── Pflicht-Tools prüfen (rsync, unzip, awk, ...)
   ├── ulimits prüfen
   ├── Laufende Patch-Prozesse erkennen
   ├── OPatch-Version validieren
   └── Patch-Verzeichnis prüfen

2. CLONE
   ├── Speicherplatz-Vorabprüfung
   ├── rsync CURRENT_ORACLE_HOME → NEW_ORACLE_HOME_<timestamp>
   ├── Größenvergleich (Plausibilität)
   └── Oracle Inventory aktualisieren

3. OPATCH APPLY
   ├── OPatch Konfliktprüfung (prereq CheckConflictAgainstOHWithDetail)
   └── Patches anwenden (opatch apply -silent)

4. DB-SWITCH  ← Downtime beginnt hier
   ├── Listener stoppen
   ├── Alle DBs stoppen (shutdown immediate)
   ├── oratab atomisch aktualisieren (alle SIDs → neues Home)
   ├── Listener im neuen Home starten
   └── Alle DBs starten (startup open)
                ← Downtime endet hier

5. DATAPATCH
   ├── datapatch -verbose pro Datenbank
   ├── Parallele Ausführung möglich (MAX_PARALLEL_DATAPATCH)
   └── Timeout-Überwachung (DATAPATCH_TIMEOUT)

6. VERIFY
   └── DB-Status OPEN für alle Datenbanken prüfen

7. REPORT
   ├── Plaintext-Zusammenfassung
   └── JSON-Report (wenn JSON_REPORT=true)
```

### Downtime-Fenster

Die tatsächliche Downtime beschränkt sich auf **Phase 4 (DB-Switch)**:
- Listener-Stop bis Listener-Start im neuen Home
- Typisch: **2–8 Minuten** (abhängig von Anzahl und Größe der DBs)

Clone und OPatch (Phase 2+3) laufen ohne Downtime auf dem neuen Home.

---

## Module

### `lib/log.sh`
Einheitliches Logging mit Farben, Level-Filter und Datei-Output.
- Funktionen: `log_debug`, `log_info`, `log_warn`, `log_error`, `log_success`, `log_section`, `die`
- Konfiguration: `LOG_LEVEL` (DEBUG/INFO/WARN/ERROR)
- Output: farbig auf stdout/stderr + plain in `LOGFILE`

### `lib/lock.sh`
Prozess-Locking via atomarem `mkdir` — verhindert parallele Ausführung.
- Lock-Verzeichnis: `/tmp/oracle_oop_patching.lock`
- Enthält: PID, Timestamp, User, Mode
- Verwaiste Locks (toter Prozess) werden automatisch entfernt

### `lib/config.sh`
Konfigurationsverwaltung mit Syntax-Check und Validierung.
- Lädt `~/.patchrc` mit `bash -n` Syntax-Check vor dem Sourcen
- Validiert Pflichtfelder und Verzeichnisexistenz
- `create_default_config`: erstellt kommentierte `.patchrc`
- `config_doctor`: zeigt vollständigen Konfigurationsstatus

### `lib/cli.sh`
Argument-Parser und Usage-Dokumentation.
- Alle Flags und Modi (siehe [Verwendung](#verwendung))
- Trennung von CLI-Parsing und Fachlogik

### `lib/prereq.sh`
Vorabprüfungen vor jedem Eingriff.
- Benutzer, Oracle Home Struktur, Speicherplatz, Tools, ulimits
- Laufende Patch-Prozesse, OPatch-Version, Patch-Verzeichnis
- Exit-Code 2 bei kritischen Fehlern

### `lib/oracle.sh`
Oracle-spezifische Operationen — das kritischste Modul.
- `oratab_backup`: zeitgestempeltes Backup vor jeder Änderung
- `oratab_update_home`: atomische Änderung via tmp-Datei + awk
- `db_stop` / `db_start`: sqlplus mit Fehlerbehandlung
- `listener_stop` / `listener_start`: Listener-Name auto-erkannt aus `listener.ora`
- `inventory_register_home` / `inventory_remove_home`: OUI attach/detach
- `verify_db_open`: prüft `v$instance.status`

### `lib/patching.sh`
Clone, OPatch und Datapatch.
- `clone_oracle_home`: rsync mit Ausschluss von `dbs/*.ora`, `network/admin/*.ora`
- `apply_opatch`: Konfliktprüfung + silent apply aller Patches
- `run_datapatch`: startet Datapatch im Hintergrund, PID in `DATAPATCH_PIDS[]`
- `wait_for_datapatch`: wartet mit Timeout, Exit-Codes in `DATAPATCH_EXIT_CODES[]`

### `lib/switch.sh`
Datenbankumschaltung mit minimaler Downtime.
- Listener-Name auto-erkannt aus `listener.ora`
- Alle DBs des alten Homes werden umgeschaltet
- Bei DB-Stop-Fehlern: interaktive Bestätigung ob weiter
- Bei oratab-Fehlern: sofortiger `die()` — kein inkonsistenter Zustand

### `lib/rollback.sh`
Vollautomatischer Rollback.
- Home-Ermittlung: `OLD_ORACLE_HOME` → oratab-Backup → Inventory
- Gleicher Ablauf wie Switch, rückwärts
- Bietet nach Rollback an, das neue Home zu löschen

### `lib/cleanup.sh`
Bereinigung alter Oracle Homes und Logs.
- Berücksichtigt `KEEP_HOMES` (Mindestanzahl)
- Alterscheck via `stat` mtime + `AUTO_CLEANUP_DAYS`
- Prüft ob Home noch aktiv in oratab genutzt wird
- `ALLOW_AUTO_CLEANUP=true` + `UNATTENDED_MODE=true` für automatischen Cleanup

### `lib/report.sh`
Abschlussbericht in zwei Formaten.
- Plaintext: farbige Tabelle mit Pro-DB-Status
- JSON: maschinenlesbar, Schema-Version, alle Felder
- E-Mail-Benachrichtigung via `mail` (optional)

---

## Sicherheit

### oratab-Änderungen
- Vor **jeder** Änderung wird `/etc/oratab` gesichert: `/etc/oratab.bak_<timestamp>`
- Atomische Änderung via tmp-Datei + `mv` (kein direktes `sed -i`)
- SID-Existenz wird vor Änderung geprüft
- Neues Home wird auf Existenz geprüft

### Oracle Inventory
- Inventory-Entfernung beim Cleanup **standardmäßig deaktiviert** (`ENABLE_INVENTORY_REMOVE=false`)
- Explizite Aktivierung erforderlich

### Prozess-Locking
- Verhindert parallele Ausführung auf demselben Host
- Lock-Datei enthält Timestamp und Benutzer zur Diagnose
- Automatische Freigabe über EXIT-Trap

### Dry-Run
```bash
# Alle Aktionen simulieren — kein Eingriff ins System
./oop_patch.sh --prod --dry-run
```
Im Dry-Run werden alle Befehle geloggt aber nicht ausgeführt.
Ausnahmen: Verzeichnisstruktur-Erstellung für den Clone (harmlos).

---

## Fehlerbehandlung & Rollback

### Automatische Fehlerbehandlung

Das Framework verwendet `set -Eeuo pipefail` — jeder nicht abgefangene
Fehler beendet das Skript sofort. Der EXIT-Trap sorgt für:
- Lock-Freigabe
- Report-Finalisierung mit Fehlerstatus

### Rollback

```bash
./oop_patch.sh --rollback
```

Der Rollback:
1. Ermittelt altes Home aus `OLD_ORACLE_HOME`, oratab-Backup oder Inventory
2. Stoppt Listener und alle DBs im neuen Home
3. Setzt oratab auf altes Home zurück
4. Startet Listener und DBs im alten Home
5. Verifiziert DB-Status OPEN
6. Bietet optionales Löschen des neuen Homes an

### Manuelle Wiederherstellung

Falls der Rollback ebenfalls fehlschlägt:

```bash
# oratab manuell wiederherstellen
ls -lt /etc/oratab.bak_*
cp /etc/oratab.bak_<timestamp> /etc/oratab

# DB manuell starten
export ORACLE_HOME=/oracle/19
export ORACLE_SID=PROD1
$ORACLE_HOME/bin/sqlplus / as sysdba <<< "startup"
```

---

## Reporting

### Plaintext-Report (immer)

```
╔══════════════════════════════════════════════════════════════╗
║  Oracle 19c OOP Patching — Abschlussbericht               ║
╠══════════════════════════════════════════════════════════════╣
  Host:                  dbserver01
  Modus:                 prod
  Start:                 2024-01-15 02:00:05
  Ende:                  2024-01-15 02:47:33
  Dauer:                 00:47:28
  Altes Home:            /oracle/19
  Neues Home:            /oracle/19_20240115_020005

  Patches:
    -> 35742441

  Datenbank      Clone      Switch     Datapatch    Verify
  ──────────────────────────────────────────────────────
  PROD1          OK         OK         OK           OK
  PROD2          OK         OK         OK           OK

╠══════════════════════════════════════════════════════════════╣
║  Gesamtstatus: SUCCESS
╚══════════════════════════════════════════════════════════════╝
```

### JSON-Report (`JSON_REPORT=true`)

```json
{
  "schema_version": "3.0",
  "host": "dbserver01",
  "timestamp_start": "2024-01-15 02:00:05",
  "timestamp_end": "2024-01-15 02:47:33",
  "mode": "prod",
  "overall_status": "SUCCESS",
  "dry_run": false,
  "oracle": {
    "old_home": "/oracle/19",
    "new_home": "/oracle/19_20240115_020005",
    "patch_base_dir": "/work/dba/patching",
    "patches": ["35742441"]
  },
  "databases": [
    {
      "sid": "PROD1",
      "clone": "OK",
      "switch": "OK",
      "datapatch": "OK",
      "verify": "OK"
    }
  ],
  "errors": [],
  "logfile": "/work/dba/patching/logs/oop_patching_20240115_020005.log"
}
```

---

## FAQ

**Q: Kann ich mehrere Patches gleichzeitig anwenden?**  
A: Ja. Alle numerischen Verzeichnisse in `PATCH_BASE_DIR` werden automatisch erkannt und nacheinander angewendet. OPatch führt vorher eine Konfliktprüfung durch.

**Q: Was passiert wenn der Clone abbricht?**  
A: Das neue Home wird gelöscht (`rm -rf`), das alte Home ist unberührt. Einfach erneut starten oder `--resume` verwenden.

**Q: Was passiert wenn Datapatch fehlschlägt?**  
A: Der Report zeigt `FAILED` für die betroffene DB. Die DB bleibt gestartet. Datapatch-Log unter `LOGDIR/datapatch_<SID>_<timestamp>.log`. Manuell nacharbeiten oder `--datapatch-only` nach Behebung erneut ausführen.

**Q: Kann ich das Framework für Oracle RAC verwenden?**  
A: Nein. Das Framework ist für **Single Instance** ausgelegt. RAC-Patching erfordert Rolling Upgrade Prozeduren die hier nicht abgedeckt sind.

**Q: Wie lange dauert der Clone?**  
A: Abhängig von Home-Größe (~10-12 GB) und Storage-Performance. Typisch: 5–15 Minuten via rsync auf lokalem Storage.

**Q: Wie groß ist das Downtime-Fenster?**  
A: Clone und OPatch laufen ohne Downtime. Die eigentliche Downtime (Phase 4: Switch) beträgt typisch 2–8 Minuten pro Instanz.

**Q: Was bedeutet `ENABLE_INVENTORY_REMOVE=false`?**  
A: Das Oracle Central Inventory wird beim Cleanup **nicht** automatisch bereinigt. Das ist der sichere Standard. Aktiviere `ENABLE_INVENTORY_REMOVE=true` nur wenn du sicher bist dass das Home nicht mehr benötigt wird und das Inventory konsistent bleiben soll.

**Q: Kann ich den Lauf nach einem Abbruch fortsetzen?**  
A: Ja, wenn der Clone bereits abgeschlossen war:
```bash
NEW_ORACLE_HOME=/oracle/19_<timestamp> ./oop_patch.sh --resume
```

---

## Lizenz

MIT License — siehe [LICENSE](LICENSE)

---

## Autor

[mrAibo](https://github.com/mrAibo)
