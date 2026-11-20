#!/bin/bash
# scripts/npm-security-updates.sh
#
# Sicherheitsupdates mit Neustart, samstags 05:00. Der Proxy ist das
# zentrale Einfallstor ins Netz — deshalb bekommt er (anders als die
# übrigen Gäste) einen festen Termin, an dem Lücken auch per Neustart
# wirklich geschlossen werden: neuer Kernel, neue Systembibliotheken.
#
# Ablauf: Paketlisten laden → unattended-upgrade (Debian-Sicherheits-
# updates) → Neustart, falls nötig (~1 Minute Proxy-Ausfall).
# Damit wird auch ein Kernel aktiv, den das Freitags-Update installiert hat.
#
# unattended-upgrades läuft NUR zu diesem Termin, nicht täglich: die
# Debian-Timer apt-daily/apt-daily-upgrade bleiben aus.
#
# Einrichtung (einmalig):
#   ./scripts/npm-security-updates.sh --install
#
# Von Hand sofort ausführen (startet ggf. neu!):
#   npm-security-updates
#
# Logging: /var/log/npm-security-updates.log

set -euo pipefail

BIN=/usr/local/sbin/npm-security-updates
UNIT_DIR=/etc/systemd/system
ON_CALENDAR="Sat *-*-* 05:00:00 Europe/Berlin"
LOG=/var/log/npm-security-updates.log

[[ $EUID -eq 0 ]] || { echo "FEHLER: bitte als root ausführen"; exit 1; }

install_self() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
    install -m 0755 "$(readlink -f "${BASH_SOURCE[0]}")" "$BIN"

    # Nicht täglich — nur über unseren Timer.
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    systemctl disable --now apt-daily-upgrade.timer apt-daily.timer >/dev/null 2>&1 || true

    # Neustart erledigt dieses Script selbst (zuverlässiger: Debian legt
    # /run/reboot-required nicht bei jedem Kernel-Update an).
    rm -f /etc/apt/apt.conf.d/52npm-unattended-upgrades
    cat > /etc/apt/apt.conf.d/52npm-security-updates <<'EOF'
// Eingerichtet von npm-security-updates.sh — Neustart macht das Script.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF

    cat > "$UNIT_DIR/npm-security-updates.service" <<EOF
[Unit]
Description=Sicherheitsupdates mit Neustart (NPM-Proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
EOF
    cat > "$UNIT_DIR/npm-security-updates.timer" <<EOF
[Unit]
Description=Sicherheitsupdates samstags 05:00

[Timer]
OnCalendar=$ON_CALENDAR
Persistent=false

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now npm-security-updates.timer
    echo "→ Sicherheitsupdates samstags 05:00 aktiv (Neustart bei Bedarf)"
    systemctl list-timers npm-security-updates.timer --no-pager | sed -n '1,2p'
}

reboot_needed() {
    [[ -f /run/reboot-required ]] && return 0
    local newest
    newest=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' \
        | sed 's/^vmlinuz-//' | sort -V | tail -1)
    [[ -n "$newest" && "$newest" != "$(uname -r)" ]]
}

run_update() {
    exec > >(tee -a "$LOG") 2>&1
    echo "=== $(date -Iseconds)  npm-security-updates ==="
    export DEBIAN_FRONTEND=noninteractive
    # Ein Fehler hier soll den Neustart für einen schon installierten
    # Kernel (z.B. vom Freitag) nicht verhindern.
    apt-get -q -o DPkg::Lock::Timeout=600 update \
        || echo "FEHLER: apt-get update fehlgeschlagen"
    unattended-upgrade -v || echo "FEHLER: unattended-upgrade fehlgeschlagen"

    if reboot_needed; then
        echo "→ Neustart nötig — VM startet in 5 Sekunden neu."
        systemd-run --on-active=5s --unit=npm-security-reboot.service \
            systemctl reboot 2>/dev/null || systemctl reboot
    else
        echo "→ Kein Neustart nötig."
    fi
}

if [[ "${1:-}" == "--install" ]]; then
    install_self
else
    run_update
fi
