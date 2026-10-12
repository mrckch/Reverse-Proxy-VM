#!/bin/bash
# scripts/npm-update.sh
#
# Bringt die NPM-VM auf den aktuellen Stand: Backup, Debian-Pakete
# (inkl. Kernel + Docker), NPM-Container. Idempotent — kann beliebig oft
# laufen.
#
# Aufruf:
#   ./scripts/npm-update.sh             # fragt am Ende, ob neu gestartet wird
#   ./scripts/npm-update.sh --reboot    # startet ohne Rückfrage neu, falls nötig
#
# Logging: /var/log/npm-update.log

set -euo pipefail

# ============================================================================
# Konstanten
# ============================================================================
NPM_DIR=/opt/npm
BACKUP_DIR=/root
BACKUP_KEEP=5
LOG=/var/log/npm-update.log

AUTO_REBOOT=0
[[ "${1:-}" == "--reboot" ]] && AUTO_REBOOT=1

# ============================================================================
# Logging
# ============================================================================
exec > >(tee -a "$LOG") 2>&1
echo
echo "================================================================"
echo " $(date -Iseconds)  npm-update started  (pid=$$)"
echo "================================================================"

# ============================================================================
# Helpers
# ============================================================================
require_root() {
    [[ $EUID -eq 0 ]] || { echo "FEHLER: bitte als root ausführen"; exit 1; }
}

npm_version() {
    curl -sf -m 5 http://127.0.0.1:81/api/ 2>/dev/null \
        | sed -n 's/.*"major":\([0-9]*\),"minor":\([0-9]*\),"revision":\([0-9]*\).*/\1.\2.\3/p'
}

wait_for_npm() {
    local i
    for i in $(seq 1 60); do
        [[ -n "$(npm_version)" ]] && return 0
        sleep 2
    done
    return 1
}

# ============================================================================
# Schritte
# ============================================================================
step_pull() {
    echo "=== [1/4] Neues NPM-Image laden (Proxy läuft weiter) ==="
    cd "$NPM_DIR"
    docker compose pull
}

step_backup() {
    echo "=== [2/4] Backup von Daten + Zertifikaten ==="
    local file
    file="${BACKUP_DIR}/npm-pre-update-$(date +%F-%H%M%S).tar.gz"

    # Container kurz anhalten, damit die SQLite-DB konsistent gesichert wird.
    cd "$NPM_DIR"
    docker compose stop
    ( umask 077; tar czf "$file" -C "$NPM_DIR" data letsencrypt docker-compose.yml )
    docker compose up -d

    echo "→ Backup: $file ($(du -h "$file" | awk '{print $1}'))"

    # Nur die letzten $BACKUP_KEEP Update-Backups behalten
    find "$BACKUP_DIR" -maxdepth 1 -name 'npm-pre-update-*.tar.gz' -printf '%T@ %p\n' \
        | sort -rn | tail -n +$(( BACKUP_KEEP + 1 )) | cut -d' ' -f2- \
        | xargs -r rm -f
}

step_npm() {
    echo "=== [3/4] NPM-Container prüfen ==="
    if ! wait_for_npm; then
        echo "FEHLER: NPM antwortet nach dem Update nicht auf Port 81."
        echo "        Logs:   cd $NPM_DIR && docker compose logs --tail 50 npm"
        echo "        Backup: ls -t $BACKUP_DIR/npm-pre-update-*.tar.gz | head -1"
        exit 1
    fi
    echo "→ NPM läuft, Version $(npm_version)"
    docker image prune -f >/dev/null
}

step_system() {
    echo "=== [4/4] Debian-Pakete (inkl. Kernel + Docker) ==="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" full-upgrade
    apt-get -y autoremove --purge
    apt-get clean

    # Ein Docker-Update startet den Daemon (und damit NPM) neu — nochmal prüfen.
    wait_for_npm || { echo "FEHLER: NPM nach dem System-Update nicht erreichbar."; exit 1; }
}

# Debian legt /var/run/reboot-required nur mit Zusatzpaketen an — deshalb
# zusätzlich prüfen, ob ein neuerer Kernel installiert ist als gerade läuft.
reboot_needed() {
    [[ -f /var/run/reboot-required ]] && return 0
    local newest
    newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' \
        | sed 's/^vmlinuz-//' | sort -V | tail -1)
    [[ -n "$newest" && "$newest" != "$(uname -r)" ]]
}

step_reboot() {
    if ! reboot_needed; then
        echo "→ Kein Neustart nötig."
        return 0
    fi
    echo "→ Neustart nötig (neuer Kernel oder Systembibliotheken)."
    if [[ "$AUTO_REBOOT" != "1" ]]; then
        local ans
        read -rp "Jetzt neu starten? Der Proxy ist ~1 Minute weg. [yes/NO] " ans
        [[ "$ans" == "yes" ]] || { echo "→ Bitte später selbst neu starten: reboot"; return 0; }
    fi
    systemd-run --on-active=5s --unit=npm-update-reboot.service \
        systemctl reboot 2>/dev/null \
        || systemctl reboot
    echo "→ Neustart in 5 Sekunden."
}

# ============================================================================
# MAIN
# ============================================================================
require_root
[[ -f "$NPM_DIR/docker-compose.yml" ]] \
    || { echo "FEHLER: $NPM_DIR/docker-compose.yml fehlt — erst npm-bootstrap.sh ausführen."; exit 1; }

VERSION_BEFORE=$(npm_version || true)

step_pull
step_backup
step_npm
step_system

cat <<EOF

================================================================
 Update abgeschlossen.
================================================================

  NPM vorher:   ${VERSION_BEFORE:-unbekannt}
  NPM jetzt:    $(npm_version)
  Debian:       $(cat /etc/debian_version)
  Kernel:       $(uname -r) (läuft gerade)
  Docker:       $(docker --version | awk '{print $3}' | tr -d ',')

EOF

step_reboot
