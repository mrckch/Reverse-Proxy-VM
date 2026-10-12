#!/bin/bash
# scripts/npm-auto-updates.sh
#
# Richtet automatische Sicherheitsupdates für Debian ein
# (unattended-upgrades). Idempotent.
#
#   - Debian-Sicherheitsupdates werden täglich von selbst eingespielt
#   - braucht ein Update einen Neustart (z.B. neuer Kernel), startet die
#     VM um 04:30 von selbst neu (~1 Minute Proxy-Ausfall)
#   - alte Kernel + nicht mehr benötigte Pakete werden entfernt
#
# NICHT automatisch: Docker und NPM selbst — dafür regelmäßig
# ./scripts/npm-update.sh laufen lassen.
#
# Aufruf:
#   ./scripts/npm-auto-updates.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "FEHLER: bitte als root ausführen"; exit 1; }

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/52npm-unattended-upgrades <<'EOF'
// Eingerichtet von npm-auto-updates.sh
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer >/dev/null

echo "→ Automatische Sicherheitsupdates aktiv (Neustart bei Bedarf um 04:30)."
echo "  Protokoll: /var/log/unattended-upgrades/unattended-upgrades.log"
