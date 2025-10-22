#!/usr/bin/env bash
# setup.sh — WireGuard quick setup
# Usage:
#   ./setup.sh --config ~/wg0.conf [--port 51820] [--ufw]
# Defaults:
#   --config defaults to ~/wg0.conf
#   --port   defaults to 51820
# Behavior:
#   On Ubuntu: installs wireguard, copies config to /etc/wireguard/wg0.conf,
#              chmod 600, enables & starts wg-quick@wg0, optional ufw allow.
#   On non-Ubuntu: prints a helpful hint and exits (safe no-op).

set -euo pipefail

CONFIG="${HOME}/wg0.conf"
PORT="51820"
ALLOW_UFW=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG="${2:-}"; shift 2;;
    --port)
      PORT="${2:-}"; shift 2;;
    --ufw)
      ALLOW_UFW=true; shift;;
    -h|--help)
      grep -E '^# (Usage|Defaults|Behavior):' -A5 "$0" | sed 's/^# //'; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config file not found at: $CONFIG" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo --preserve-env=CONFIG,PORT,ALLOW_UFW "$0" "$@"
fi

# Detect Ubuntu (or Debian) via /etc/os-release
OS_ID="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  ID_LIKE_LOWER="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
fi

is_ubuntu=false
if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$ID_LIKE_LOWER" == *"debian"* ]]; then
  is_ubuntu=true
fi

if ! $is_ubuntu; then
  echo "This script is intended for Ubuntu/Debian servers."
  echo "Detected OS: ${OS_ID:-unknown}"
  echo
  echo "If you're on macOS as the client, you can do:"
  echo "  brew install wireguard-tools"
  echo "  sudo wg-quick up /path/to/your/envs/network-a/wireguard/wg0.conf"
  exit 0
fi

echo "==> Installing WireGuard (if needed)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard wireguard-tools

echo "==> Preparing /etc/wireguard…"
mkdir -p /etc/wireguard
chmod 750 /etc/wireguard

TARGET="/etc/wireguard/wg0.conf"
TS="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$TARGET" ]]; then
  echo "==> Backing up existing wg0.conf to ${TARGET}.${TS}.bak"
  cp -f "$TARGET" "${TARGET}.${TS}.bak"
fi

echo "==> Installing config from: $CONFIG"
# Accept either absolute or relative paths, and allow '~' if passed
# Expand tilde manually if present
if [[ "$CONFIG" == "~/"* ]]; then
  CONFIG="${CONFIG/\~/$HOME}"
fi
install -m 600 "$CONFIG" "$TARGET"

# Basic sanity check: ensure the file has an [Interface] stanza
if ! grep -q '^\[Interface\]' "$TARGET"; then
  echo "WARNING: $TARGET does not look like a valid WireGuard config (missing [Interface])." >&2
fi

# Optional: open UFW port
if $ALLOW_UFW; then
  if command -v ufw >/dev/null 2>&1; then
    echo "==> Allowing UDP ${PORT}/udp via UFW (if not already allowed)…"
    ufw allow "${PORT}/udp" || true
  else
    echo "==> UFW not installed. Skipping firewall rule."
  fi
fi

echo "==> Enabling & starting wg-quick@wg0 via systemd…"
systemctl daemon-reload || true
systemctl enable wg-quick@wg0
# If already active, restart for good measure
if systemctl is-active --quiet wg-quick@wg0; then
  systemctl restart wg-quick@wg0
else
  systemctl start wg-quick@wg0
fi

echo "==> Status:"
systemctl --no-pager --full status wg-quick@wg0 || true
echo
echo "==> Current interface state (wg):"
wg || true
echo
echo "All set. If this is the server (listener), ensure your peer points its Endpoint to this host’s public IP:${PORT}/udp."
