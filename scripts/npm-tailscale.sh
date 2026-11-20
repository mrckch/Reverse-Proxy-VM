#!/bin/bash
# scripts/npm-tailscale.sh
#
# Optional: bringt die NPM-VM ins eigene Tailscale-Netz, damit Web-UI
# (Port 81) und SSH auch von unterwegs erreichbar sind — ohne Port-
# Freigabe am Router. Idempotent.
#
#   - installiert Tailscale aus dem offiziellen Paket-Repo
#   - meldet die VM im Tailnet an (Login-Link erscheint im Terminal)
#   - optional: hinterlegt einen SSH-Public-Key für root
#
# Der Login-Link wird zusätzlich als QR-Code angezeigt — in der
# Proxmox-Konsole kann man nichts kopieren, also einfach mit dem Handy
# scannen.
#
# DNS bleibt unangetastet (--accept-dns=false): /etc/resolv.conf ist
# per chattr +i gesperrt, Tailscale darf sie nicht umschreiben.
#
# Aufruf:
#   ./scripts/npm-tailscale.sh
#   ./scripts/npm-tailscale.sh --key "ssh-ed25519 AAAA... kommentar"
#   ./scripts/npm-tailscale.sh --claude      # Key aus scripts/keys/claude-code.pub
#   ./scripts/npm-tailscale.sh --hostname mein-proxy
#
# --claude ist nur für die VM des Repo-Besitzers gedacht: damit bekommt
# dessen Claude-Code-Sitzung SSH-Zugang. Auf fremden VMs NICHT verwenden.
#
# Logging: /var/log/npm-tailscale.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_HOSTNAME=npm-proxy
PUBKEY=
LOG=/var/log/npm-tailscale.log

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)      PUBKEY="${2:-}"; shift 2 ;;
        --claude)   PUBKEY="$(head -1 "$SCRIPT_DIR/keys/claude-code.pub")"; shift ;;
        --hostname) TS_HOSTNAME="${2:-}"; shift 2 ;;
        *) echo "Unbekannte Option: $1"; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "FEHLER: bitte als root ausführen"; exit 1; }

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Iseconds)  npm-tailscale started ==="

# ----------------------------------------------------------------------------
# 1. SSH-Key hinterlegen (optional)
# ----------------------------------------------------------------------------
if [[ -n "$PUBKEY" ]]; then
    echo "=== [1/3] SSH-Key für root hinterlegen ==="
    if [[ ! "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+)\ [A-Za-z0-9+/=]+ ]]; then
        echo "FEHLER: das sieht nicht nach einem SSH-Public-Key aus"; exit 1
    fi
    install -d -m 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if grep -qxF "$PUBKEY" /root/.ssh/authorized_keys; then
        echo "→ Key war schon hinterlegt"
    else
        echo "$PUBKEY" >> /root/.ssh/authorized_keys
        echo "→ Key hinterlegt"
    fi
else
    echo "=== [1/3] Kein --key angegeben, SSH-Keys bleiben wie sie sind ==="
fi

# ----------------------------------------------------------------------------
# 2. Tailscale installieren
# ----------------------------------------------------------------------------
echo "=== [2/3] Tailscale installieren ==="
if command -v tailscale >/dev/null; then
    echo "→ schon installiert ($(tailscale version | head -1))"
else
    # shellcheck disable=SC1091
    . /etc/os-release
    install -d -m 755 /usr/share/keyrings
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${VERSION_CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${VERSION_CODENAME}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale >/dev/null
    systemctl enable --now tailscaled
    echo "→ installiert ($(tailscale version | head -1))"
fi

# ----------------------------------------------------------------------------
# 3. Im Tailnet anmelden
# ----------------------------------------------------------------------------
echo "=== [3/3] Im Tailnet anmelden ==="
if tailscale status >/dev/null 2>&1; then
    echo "→ schon angemeldet"
else
    echo "→ Gleich erscheinen ein Login-Link und ein QR-Code."
    echo "  QR-Code mit dem Handy scannen und die VM freigeben."
    tailscale up --hostname="$TS_HOSTNAME" --accept-dns=false --qr
fi

echo
echo "Fertig. Tailscale-IP: $(tailscale ip -4)"
echo "Web-UI:  http://$(tailscale ip -4):81"
echo "SSH:     ssh root@$(tailscale ip -4)"
