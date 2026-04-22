# Oracle 19c Out-of-Place Patching Framework v3.1

![Shell](https://img.shields.io/badge/Shell-Bash%205%2B-4EAA25?logo=gnubash&logoColor=white)
![Oracle](https://img.shields.io/badge/Oracle-19c-F80000?logo=oracle&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform](https://img.shields.io/badge/Platform-SLES%20%7C%20RHEL%20%7C%20OEL-lightgrey)
![Version](https://img.shields.io/badge/Version-3.1-informational)

Ein modulares Bash-Framework für **Out-of-Place Patching (OOP)** von Oracle 19c auf Linux.
Es deckt den kompletten Ablauf ab: **Patch-Vorbereitung**, Clone des Oracle Home, OPatch, DB-Switch, Datapatch, Verifikation, Rollback, Cleanup und Reporting.

---

## Inhaltsverzeichnis

- [Features](#features)
- [Quickstart](#quickstart)
- [Architektur](#architektur)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Konfiguration](#konfiguration)
- [Verwendung](#verwendung)
- [Patch-Vorbereitung](#patch-vorbereitung)
- [Patchingablauf](#patchingablauf)
- [Module](#module)
- [Sicherheit](#sicherheit)
- [Fehlerbehandlung und Rollback](#fehlerbehandlung-und-rollback)
- [Reporting](#reporting)
- [FAQ](#faq)
- [Changelog](#changelog)

---

## Features

| Feature | Beschreibung |
|---|---|
| Integrierte Patch-Vorbereitung | ZIP-Dateien direkt über `oop_patch.sh` entpacken, validieren und bereinigen |
| Modularer Aufbau | Saubere Trennung in spezialisierte `lib/*.sh`-Module |
| Out-of-Place Patching | Das alte Home bleibt bis zum Switch unberührt |
| Dry-Run | Simulation ohne Änderungen mit `--dry-run` |
| Teilschritte | Prepare, Validate, Clone, Switch, Datapatch und Cleanup getrennt steuerbar |
| Resume | Unterbrochene Läufe mit `--resume` fortsetzen |
| Rollback | Rückkehr zum alten Home mit oratab-Restore |
| JSON-Report | Maschinenlesbarer Abschlussbericht für Monitoring oder Automatisierung |
| Prozess-Lock | Schutz vor paralleler Ausführung |
| CI/CD-tauglich | Unattended-Betrieb mit `--force` |

---

## Quickstart

```bash
# 1. Konfiguration anlegen und prüfen
./oop_patch.sh --create-config
vi ~/.patchrc
./oop_patch.sh --config-doctor

# 2. Oracle Patch-ZIPs vorbereiten
./oop_patch.sh --unzip-all /downloads/oracle_patches/
./oop_patch.sh --prepare-validate

# 3. Vorabprüfung ohne Eingriff
./oop_patch.sh --validate-only

# 4. Produktives Patching
./oop_patch.sh --prod

# 5. Optional: ZIP-Dateien löschen
./oop_patch.sh --cleanup-zips
```

> Es ist **kein separates `prepare_patches.sh`** mehr nötig. Die Patch-Vorbereitung ist in `oop_patch.sh` integriert.

---

## Architektur

```text
oop_patch.sh                  ← Haupt-Orchestrator
├── lib/
│   ├── log.sh                ← Logging, Farben, Fehlerausgabe
│   ├── lock.sh               ← Prozess-Lock via mkdir
│   ├── config.sh             ← Konfiguration laden, validieren, erstellen
│   ├── cli.sh                ← Argument-Parser und Usage
│   ├── prereq.sh             ← Vorabprüfungen
│   ├── prepare.sh            ← ZIP entpacken, prüfen, listen, cleanup
│   ├── oracle.sh             ← oratab, Inventory, DB/Listener Start/Stop
│   ├── patching.sh           ← Clone, OPatch, Datapatch
│   ├── switch.sh             ← Umschalten aufs neue Home
│   ├── rollback.sh           ← Rückkehr aufs alte Home
│   ├── cleanup.sh            ← Alte Homes und Logs bereinigen
│   └── report.sh             ← Plaintext- und JSON-Report
└── etc/
    └── patchrc.example       ← Beispielkonfiguration
```

### Phasenmodell

```text
prepare → precheck → clone_home → apply_opatch → switch_db → datapatch → verify → cleanup
```

---

## Voraussetzungen

### System

| Anforderung | Minimum |
|---|---|
| Betriebssystem | SLES 12/15, RHEL/OEL 7/8, Oracle Linux 8 |
| Bash | 5.0+ |
| Oracle Database | 19c |
| OPatch | 12.2.0.1+ |
| Tools | `rsync`, `unzip`, `awk`, `sed`, `stat`, `du`, `df` |
| Freier Speicher | ca. 25–30 GB empfohlen |

### Berechtigungen

- Ausführung als Oracle Software Owner, z. B. `ora19`
- Schreibrechte auf `/etc/oratab`
- Schreibrechte auf `ORACLE_BASE`
- Schreibrechte auf `LOGDIR`

### Speicherbedarf

| Bereich | Typischer Bedarf |
|---|---|
| ZIP-Downloads | 1–3 GB |
| Entpackte Patches | 2–5 GB |
| Oracle Home Clone | 10–15 GB |
| Gesamt empfohlen | 25–30 GB |

---

## Installation

```bash
git clone https://github.com/mrAibo/Oracle_Inplace_Patch.git
cd Oracle_Inplace_Patch
chmod +x oop_patch.sh
```

### Erste Einrichtung

```bash
# Konfiguration erstellen
./oop_patch.sh --create-config

# Anpassen
vi ~/.patchrc

# Prüfen
./oop_patch.sh --config-doctor
```

> Die Patch-Vorbereitung läuft jetzt direkt über `oop_patch.sh` und `lib/prepare.sh`. Ein separates Hilfsskript ist nicht erforderlich.

---

## Konfiguration

Die Konfiguration liegt standardmäßig in `~/.patchrc`.

```bash
cp etc/patchrc.example ~/.patchrc
vi ~/.patchrc
```

### Wichtige Parameter

| Parameter | Beschreibung |
|---|---|
| `ORACLE_BASE` | Basispfad aller Oracle Homes |
| `CURRENT_ORACLE_HOME` | Aktuell aktives Oracle Home |
| `PATCH_BASE_DIR_BASE` | Basisverzeichnis für entpackte Patches |
| `LOGDIR` | Log-Verzeichnis |
| `REQUIRED_USER` | Oracle-Software-Owner |
| `DRY_RUN` | Simulationsmodus |
| `UNATTENDED_MODE` | Alle Rückfragen überspringen |
| `MAX_PARALLEL_DATAPATCH` | Parallelität für Datapatch |
| `DATAPATCH_TIMEOUT` | Timeout für Datapatch |
| `AUTO_CLEANUP_DAYS` | Alter für Cleanup alter Homes |
| `KEEP_HOMES` | Mindestanzahl alter Homes, die erhalten bleiben |

### PATCH_BASE_DIR-Auflösung

Das effektive Patch-Verzeichnis wird aus `PATCH_BASE_DIR_BASE` abgeleitet.
Optional kann zusätzlich pro Host ein Unterverzeichnis verwendet werden, z. B.:

```bash
PATCH_BASE_DIR_BASE=/work/dba/patching
USE_HOSTNAME_DIR=true
```

Dann ergibt sich z. B.:

```text
/work/dba/patching/dbserver01
```

Die vollständigen Parameter stehen in [`etc/patchrc.example`](etc/patchrc.example).

---

## Verwendung

### Wichtig: Zwei Arten von Validate

| Befehl | Bedeutung |
|---|---|
| `--prepare-validate` | Prüft die **entpackten Patch-Verzeichnisse** auf Vollständigkeit |
| `--validate-only` | Führt die **systemischen Vorabprüfungen** vor dem eigentlichen Patching aus |

### Modi und Optionen

```text
MODI
  --status              Detaillierte Statusanzeige
  --test                Test-Modus: Clone + Patch, kein DB-Switch
  --prod                Produktions-Modus: vollständiges Patching
  --rollback            Zurück zum vorherigen Oracle Home
  --cleanup             Alte Oracle Homes bereinigen
  --create-config       Standard-Konfigurationsdatei erstellen
  --config-doctor       Konfiguration prüfen und anzeigen

PATCH-VORBEREITUNG
  --prepare-status      Übersicht: Patches, ZIP-Dateien, Speicherplatz
  --prepare-list        Alle entpackten Patches auflisten
  --prepare-validate    Entpackte Patches prüfen
  --unzip <datei.zip>   Einzelne ZIP entpacken
  --unzip-all <dir/>    Alle Oracle Patch-ZIPs eines Verzeichnisses entpacken
  --cleanup-zips        Bereits verarbeitete ZIP-Dateien löschen
  --delete-zips         ZIPs direkt nach erfolgreichem Entpacken löschen

PATCHING-TEILSCHRITTE
  --validate-only       Nur Vorabprüfungen, keine Änderungen
  --prepare-only        Clone + OPatch, kein Switch
  --switch-only         Nur DB-Switch
  --datapatch-only      Nur Datapatch
  --resume              Unterbrochenen Lauf fortsetzen

FLAGS
  --db SID1,SID2        Nur bestimmte Datenbanken patchen
  --patch-dir /pfad     Patch-Verzeichnis überschreiben
  --oh /oracle/19       Oracle Home überschreiben
  --force, -f           Unattended-Modus
  --dry-run, -n         Simulation ohne Änderungen
  --debug               DEBUG-Logging aktivieren
  --json                JSON-Report aktivieren
  -h, --help            Hilfe anzeigen
```

### Typische Beispiele

```bash
# Einzelne ZIP entpacken
./oop_patch.sh --unzip /downloads/oracle_patches/p35742441_190000_Linux-x86-64.zip

# Alle ZIPs entpacken
./oop_patch.sh --unzip-all /downloads/oracle_patches/

# Vorbereitete Patches prüfen
./oop_patch.sh --prepare-validate

# Umgebung prüfen, aber nichts ändern
./oop_patch.sh --validate-only

# Produktionslauf
./oop_patch.sh --prod

# Nur bestimmte DBs
./oop_patch.sh --prod --db PROD1,PROD2

# Rollback
./oop_patch.sh --rollback
```

---

## Patch-Vorbereitung

Die manuelle README-Anweisung

```bash
mkdir -p /work/dba/patching
cd /work/dba/patching
unzip p35742441_190000_Linux-x86-64.zip
ls /work/dba/patching/
```

wird durch den integrierten Workflow ersetzt:

```bash
./oop_patch.sh --unzip-all /downloads/oracle_patches/
./oop_patch.sh --prepare-validate
./oop_patch.sh --prod
```

### Erwartete Verzeichnisstruktur

```text
PATCH_BASE_DIR/
├── 35742441/
│   ├── README.html
│   ├── etc/config/inventory
│   └── ...
└── 36912597/
    └── ...
```

### Automatisch erkannte ZIP-Dateien

Es werden ZIP-Dateien nach folgendem Schema erkannt:

```text
p<PATCH-ID>_<VERSION>_<PLATFORM>.zip
```

Beispiel:

```text
p35742441_190000_Linux-x86-64.zip
```

### Typischer Prepare-Workflow

```bash
# 1. ZIPs anzeigen
ls -lh /downloads/oracle_patches/*.zip

# 2. Erst simulieren
./oop_patch.sh --unzip-all /downloads/oracle_patches/ --dry-run

# 3. Dann wirklich entpacken
./oop_patch.sh --unzip-all /downloads/oracle_patches/

# 4. Validieren
./oop_patch.sh --prepare-validate

# 5. Optional ZIPs löschen
./oop_patch.sh --cleanup-zips
```

---

## Patchingablauf

```text
1. PRECHECK
   - Benutzer prüfen
   - Oracle Home prüfen
   - Speicherplatz prüfen
   - Tools prüfen
   - OPatch-Version prüfen
   - Patch-Verzeichnis prüfen

2. CLONE
   - CURRENT_ORACLE_HOME nach NEW_ORACLE_HOME kopieren
   - Größe plausibilisieren
   - Inventory registrieren

3. OPATCH APPLY
   - Konfliktprüfung
   - Patches anwenden

4. DB-SWITCH
   - Listener stoppen
   - DBs stoppen
   - oratab aktualisieren
   - Listener im neuen Home starten
   - DBs starten

5. DATAPATCH
   - datapatch pro DB ausführen
   - Exit-Codes und Timeout überwachen

6. VERIFY
   - DB-Status OPEN prüfen

7. REPORT
   - Plaintext-Report
   - JSON-Report
```

### Downtime

Die eigentliche Downtime fällt nur beim **DB-Switch** an.
Clone und OPatch laufen auf dem neuen Home ohne Produktions-Downtime.

---

## Module

| Modul | Zweck |
|---|---|
| `lib/log.sh` | Logging, Farben, Fehlerabbruch |
| `lib/lock.sh` | Schutz vor paralleler Ausführung |
| `lib/config.sh` | Konfiguration laden, validieren, erzeugen |
| `lib/cli.sh` | CLI-Argumente parsen |
| `lib/prereq.sh` | Vorabprüfungen |
| `lib/prepare.sh` | Patch-ZIPs entpacken, validieren, listen, löschen |
| `lib/oracle.sh` | oratab, Listener, DB-Start/Stop, Inventory |
| `lib/patching.sh` | Clone, OPatch, Datapatch |
| `lib/switch.sh` | Umschalten aufs neue Home |
| `lib/rollback.sh` | Rückschalten aufs alte Home |
| `lib/cleanup.sh` | Alte Homes und Logs bereinigen |
| `lib/report.sh` | Abschlussreport in Text und JSON |

---

## Sicherheit

- Vor jeder Änderung an `/etc/oratab` wird ein Backup erstellt.
- oratab wird atomisch aktualisiert, nicht per blindem `sed -i`.
- Inventory-Cleanup bleibt standardmäßig deaktiviert.
- Ein Prozess-Lock verhindert parallele Läufe.
- `--dry-run` ist für Prepare- und Patching-Phase verfügbar.

---

## Fehlerbehandlung und Rollback

Das Framework nutzt `set -Eeuo pipefail`.
Fehler führen zu einem kontrollierten Abbruch mit Lock-Freigabe und Report-Finalisierung.

### Rollback

```bash
./oop_patch.sh --rollback
```

Rollback-Schritte:

1. Altes Home ermitteln
2. Listener und DBs im neuen Home stoppen
3. oratab zurücksetzen
4. Listener und DBs im alten Home starten
5. Status prüfen

---

## Reporting

### Plaintext-Report

- Host, Modus, Dauer
- Altes und neues Oracle Home
- Liste der Patches
- Status pro Datenbank für Clone, Switch, Datapatch und Verify

### JSON-Report

Maschinenlesbar für Automatisierung, Monitoring oder Ticket-Systeme.

---

## FAQ

**Kann ich mehrere Patches gleichzeitig anwenden?**
Ja. Alle numerischen Verzeichnisse in `PATCH_BASE_DIR` werden erkannt.

**Was ist der Unterschied zwischen `--prepare-validate` und `--validate-only`?**
`--prepare-validate` prüft Patch-Inhalte. `--validate-only` prüft die Zielumgebung vor dem produktiven Lauf.

**Brauche ich noch `prepare_patches.sh`?**
Nein. Die Funktionalität ist in `lib/prepare.sh` und `oop_patch.sh` integriert.

**Kann ich unterbrochene Läufe fortsetzen?**
Ja, mit `--resume`, sofern das neue Home bereits vorbereitet wurde.

**Kann ich das Framework für RAC nutzen?**
Nein. Es ist für Single-Instance-Umgebungen gedacht.

---

## Changelog

### v3.1

- `lib/prepare.sh` als neues Modul integriert
- Neue Optionen für ZIP-Handling und Prepare-Validierung
- README auf integrierten Prepare-Workflow umgestellt
- Quickstart und eindeutige Unterscheidung der Validate-Optionen ergänzt

### v3.0

- Monolithisches Skript in modulare Architektur überführt
- Dry-Run, Resume, Rollback und JSON-Reporting ausgebaut

---

## Lizenz

MIT License — siehe `LICENSE`

---

## Autor

[mrAibo](https://github.com/mrAibo)
