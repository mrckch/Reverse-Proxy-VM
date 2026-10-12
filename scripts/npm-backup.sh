#!/bin/bash
# scripts/npm-backup.sh
#
# Sichert NPM-Daten + Zertifikate ohne Ausfall des Proxys nach
# /var/backups/npm. Alte Backups werden automatisch gelöscht, und bei
# knappem Plattenplatz wird gar nicht erst gesichert — die Platte kann
# durch Backups nicht volllaufen.
#
# Aufruf:
#   ./scripts/npm-backup.sh --install   # einmalig: tägliches Backup um 03:00 einrichten
#   npm-backup                          # danach: Backup sofort von Hand auslösen
#
# Logging: /var/log/npm-backup.log

set -euo pipefail

# ============================================================================
# Konstanten
# ============================================================================
NPM_DIR=/opt/npm
BACKUP_DIR=/var/backups/npm
BACKUP_KEEP=14          # so viele tägliche Backups bleiben liegen
MIN_FREE_MB=2048        # darunter wird nicht mehr gesichert
BACKUP_BIN=/usr/local/sbin/npm-backup
CRON_FILE=/etc/cron.d/npm-backup
LOG=/var/log/npm-backup.log
TMP_DIR=

# ============================================================================
# Helpers
# ============================================================================
log() { echo "$(date -Iseconds)  $*" | tee -a "$LOG"; }

require_root() {
    [[ $EUID -eq 0 ]] || { echo "FEHLER: bitte als root ausführen"; exit 1; }
}

free_mb() { df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}'; }

# Älteste Backups löschen, bis nur noch $1 Stück übrig sind
prune() {
    find "$BACKUP_DIR" -maxdepth 1 -name 'npm-backup-*.tar.gz' -printf '%T@ %p\n' \
        | sort -rn | tail -n +$(( $1 + 1 )) | cut -d' ' -f2- \
        | xargs -r rm -f
}

# ============================================================================
# Installation (einmalig)
# ============================================================================
install_self() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron sqlite3 >/dev/null
    install -m 0755 "$0" "$BACKUP_BIN"
    cat > "$CRON_FILE" <<EOF
# Tägliches NPM-Backup — eingerichtet von npm-backup.sh --install
0 3 * * * root $BACKUP_BIN >/dev/null 2>&1
EOF
    chmod 0644 "$CRON_FILE"

    # Log klein halten
    cat > /etc/logrotate.d/npm-backup <<EOF
$LOG /var/log/npm-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
EOF
    echo "→ Tägliches Backup um 03:00 eingerichtet ($BACKUP_KEEP Stück in $BACKUP_DIR)."
}

# ============================================================================
# Backup
# ============================================================================
run_backup() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    umask 077

    # Liegengebliebene Reste eines abgebrochenen Laufs wegräumen
    rm -rf "$BACKUP_DIR"/.tmp.*

    # Erst aufräumen (Platz für das neue Backup), dann Platz prüfen
    prune $(( BACKUP_KEEP - 1 ))
    local free
    free=$(free_mb)
    if (( free < MIN_FREE_MB )); then
        log "FEHLER: nur noch ${free} MB frei (Minimum ${MIN_FREE_MB} MB) — kein Backup geschrieben."
        exit 1
    fi

    local file
    TMP_DIR=$(mktemp -d "$BACKUP_DIR/.tmp.XXXXXX")
    trap 'rm -rf "$TMP_DIR"' EXIT
    file="$BACKUP_DIR/npm-backup-$(date +%F-%H%M%S).tar.gz"

    # Datenbank im laufenden Betrieb konsistent kopieren (kein Proxy-Ausfall).
    # Im Archiv liegt sie wieder an ihrem Originalplatz data/database.sqlite.
    mkdir "$TMP_DIR/data"
    sqlite3 "$NPM_DIR/data/database.sqlite" \
        ".backup '$TMP_DIR/data/database.sqlite.snapshot'"

    # Logs brauchen wir zum Wiederherstellen nicht — sie blähen nur auf.
    tar czf "$TMP_DIR/backup.tar.gz" \
        --exclude='data/logs' \
        --exclude='data/database.sqlite' \
        --exclude='data/database.sqlite-*' \
        --transform='s|^data/database[.]sqlite[.]snapshot$|data/database.sqlite|' \
        -C "$NPM_DIR" data letsencrypt docker-compose.yml \
        -C "$TMP_DIR" data/database.sqlite.snapshot

    # Prüfen, bevor es als gültiges Backup zählt
    gzip -t "$TMP_DIR/backup.tar.gz"
    tar tzf "$TMP_DIR/backup.tar.gz" | grep -qx 'data/database.sqlite' \
        || { log "FEHLER: Datenbank fehlt im Archiv — kein Backup geschrieben."; exit 1; }
    mv "$TMP_DIR/backup.tar.gz" "$file"

    log "Backup ok: $file ($(du -h "$file" | awk '{print $1}')), $(find "$BACKUP_DIR" -name 'npm-backup-*.tar.gz' | wc -l) Stück, $(du -sh "$BACKUP_DIR" | awk '{print $1}') belegt, $(free_mb) MB frei"
}

# ============================================================================
# MAIN
# ============================================================================
require_root
[[ -f "$NPM_DIR/data/database.sqlite" ]] \
    || { echo "FEHLER: $NPM_DIR/data/database.sqlite fehlt — läuft NPM hier?"; exit 1; }

if [[ "${1:-}" == "--install" ]]; then
    install_self
fi
run_backup
