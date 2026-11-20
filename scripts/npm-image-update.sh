#!/bin/bash
# scripts/npm-image-update.sh
#
# Wöchentliches Update des NPM-Containers (freitags 17:00). Ergänzt das
# Debian-Update: apt bringt Pakete und Docker auf Stand, dieses Script das
# NPM-Image selbst — das macht apt nämlich nicht.
#
# Ablauf: neues Image laden → Backup → Container neu starten → prüfen,
# ob die Web-UI wieder antwortet → alte Images aufräumen.
# Startet die VM NIE neu.
#
# Einrichtung (einmalig):
#   ./scripts/npm-image-update.sh --install
#
#   - Läuft auf der VM schon das Freitags-Update „guest-autoupdate"
#     (Ansible-Rolle guest_autoupdate), hängt sich das Script dort als
#     Hook ein: /etc/guest-autoupdate/post.d/40-npm-image — also nach apt
#     und vor dem Smoketest.
#   - Sonst bekommt es einen eigenen Timer: npm-image-update.timer,
#     freitags 17:00 — der spielt dann vorher auch die Debian-Pakete ein
#     (--with-apt), sodass freitags alles auf einmal aktuell wird.
#   - In beiden Fällen werden die alten täglichen Updates mit Neustart
#     04:30 abgeschaltet. Sicherheitsupdates + Neustart kommen samstags
#     05:00 über npm-security-updates.sh.
#
# Von Hand sofort ausführen:
#   npm-image-update
#
# Logging: /var/log/npm-image-update.log

set -euo pipefail

NPM_DIR=/opt/npm
BIN=/usr/local/sbin/npm-image-update
HOOK=/etc/guest-autoupdate/post.d/40-npm-image
GUEST_AUTOUPDATE=/usr/local/sbin/guest-autoupdate
UNIT_DIR=/etc/systemd/system
ON_CALENDAR="Fri *-*-* 17:00:00 Europe/Berlin"
LOG=/var/log/npm-image-update.log

[[ $EUID -eq 0 ]] || { echo "FEHLER: bitte als root ausführen"; exit 1; }

# ============================================================================
# Einrichtung
# ============================================================================
# Frühere Repo-Versionen (npm-auto-updates.sh) richteten tägliche Updates
# mit Neustart um 04:30 ein. Das wird abgeschaltet; das Paket selbst bleibt,
# weil npm-security-updates.sh es samstags 05:00 nutzt.
remove_legacy_daily() {
    rm -f /etc/apt/apt.conf.d/52npm-unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    systemctl disable --now apt-daily-upgrade.timer apt-daily.timer >/dev/null 2>&1 || true
    echo "→ tägliche Updates mit Neustart 04:30 abgeschaltet"
}

install_self() {
    remove_legacy_daily

    install -m 0755 "$(readlink -f "${BASH_SOURCE[0]}")" "$BIN"
    echo "→ Script installiert: $BIN"

    if [[ -x "$GUEST_AUTOUPDATE" ]]; then
        install -d -m 0755 "$(dirname "$HOOK")"
        ln -sf "$BIN" "$HOOK"
        # Ein evtl. früher angelegter eigener Timer würde doppelt laufen.
        if systemctl list-unit-files npm-image-update.timer >/dev/null 2>&1; then
            systemctl disable --now npm-image-update.timer >/dev/null 2>&1 || true
            rm -f "$UNIT_DIR/npm-image-update.timer" "$UNIT_DIR/npm-image-update.service"
            systemctl daemon-reload
        fi
        echo "→ Eingehängt ins Freitags-Update: $HOOK"
        systemctl list-timers guest-autoupdate.timer --no-pager | sed -n '1,2p'
    else
        cat > "$UNIT_DIR/npm-image-update.service" <<EOF
[Unit]
Description=Wöchentliches Update des NPM-Containers
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN --with-apt
EOF
        cat > "$UNIT_DIR/npm-image-update.timer" <<EOF
[Unit]
Description=NPM-Container freitags 17:00 aktualisieren

[Timer]
OnCalendar=$ON_CALENDAR
Persistent=false

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now npm-image-update.timer
        echo "→ Eigener Timer aktiv (kein guest-autoupdate gefunden)"
        systemctl list-timers npm-image-update.timer --no-pager | sed -n '1,2p'
    fi
}

# ============================================================================
# Update
# ============================================================================
npm_version() {
    curl -sf -m 5 http://127.0.0.1:81/api/ 2>/dev/null \
        | sed -n 's/.*"major":\([0-9]*\),"minor":\([0-9]*\),"revision":\([0-9]*\).*/\1.\2.\3/p'
}

wait_for_npm() {
    local _
    for _ in $(seq 1 60); do
        [[ -n "$(npm_version)" ]] && return 0
        sleep 2
    done
    return 1
}

# Nur im eigenen Timer-Modus: Debian-Pakete wie guest-autoupdate —
# upgrade ohne Entfernen, nie Neustart, fälliger Neustart wird gemeldet.
run_apt() {
    echo "--- Debian-Pakete ---"
    export DEBIAN_FRONTEND=noninteractive
    # Ein apt-Fehler soll das NPM-Update nicht verhindern.
    { apt-get -q -y -o DPkg::Lock::Timeout=600 update \
        && apt-get -q -y -o DPkg::Lock::Timeout=600 --with-new-pkgs \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold upgrade; } \
        || echo "FEHLER: apt-Update fehlgeschlagen, mache mit NPM weiter"
    local newest
    newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' \
        | sed 's/^vmlinuz-//' | sort -V | tail -1)
    if [[ -e /run/reboot-required || ( -n "$newest" && "$newest" != "$(uname -r)" ) ]]; then
        echo "→ HINWEIS: Neustart fällig (Kernel $newest installiert, $(uname -r) läuft) — bitte von Hand: reboot"
    fi
}

run_update() {
    exec > >(tee -a "$LOG") 2>&1
    echo "=== $(date -Iseconds)  npm-image-update ==="
    [[ "${1:-}" == "--with-apt" ]] && run_apt
    echo "--- NPM-Image ---"
    cd "$NPM_DIR"

    local before after
    before=$(npm_version || true)

    docker compose pull -q

    # Nur neu starten, wenn es wirklich ein neues Image gibt.
    local cid running latest
    cid=$(docker compose ps -q | head -1)
    running=$([[ -n "$cid" ]] && docker inspect -f '{{.Image}}' "$cid" || true)
    latest=$(docker image inspect -f '{{.Id}}' \
        "$(docker compose config --images | head -1)" 2>/dev/null || true)
    if [[ -n "$running" && "$running" == "$latest" ]]; then
        echo "→ NPM ist aktuell (${before:-?}), nichts zu tun."
        return 0
    fi

    if command -v npm-backup >/dev/null; then
        npm-backup
    else
        echo "WARNUNG: npm-backup fehlt — Update läuft ohne frisches Backup."
    fi

    docker compose up -d
    if ! wait_for_npm; then
        echo "FEHLER: NPM antwortet nach dem Update nicht auf Port 81."
        echo "        Logs: cd $NPM_DIR && docker compose logs --tail 50 npm"
        exit 1
    fi
    docker image prune -f >/dev/null
    after=$(npm_version)
    echo "→ NPM aktualisiert: ${before:-?} → $after"
}

if [[ "${1:-}" == "--install" ]]; then
    install_self
else
    run_update "${1:-}"
fi
