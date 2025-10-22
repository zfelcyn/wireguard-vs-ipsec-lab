#!/usr/bin/env bash
# setupUbuntu.sh — Full WireGuard + test tools setup
# Usage:
#   ./automation/scripts/setupUbuntu.sh --config ~/wg0.conf [--port 51820] [--ufw]
# Defaults:
#   --config defaults to ~/wg0.conf
#   --port   defaults to 51820
# Behavior:
#   Installs all dependencies (WireGuard, UFW, iperf3, tcpdump),
#   installs config to /etc/wireguard/wg0.conf, enables wg-quick@wg0,
#   opens the firewall if requested, and starts a one-shot iperf3 server for testing.

set -euo pipefail

CONFIG="${HOME}/wg0.conf"
PORT="51820"
ALLOW_UFW=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2;;
    --port)   PORT="${2:-}"; shift 2;;
    --ufw)    ALLOW_UFW=true; shift;;
    -h|--help)
      grep -E '^# (Usage|Defaults|Behavior):' -A5 "$0" | sed 's/^# //'
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
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

# Detect Ubuntu/Debian
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  case "${ID,,}" in
    ubuntu|debian) ;;
    *) echo "This script is intended for Ubuntu/Debian."; exit 1;;
  esac
fi

echo "==> Updating and installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard wireguard-tools iperf3 tcpdump ufw systemd

echo "==> Preparing /etc/wireguard..."
mkdir -p /etc/wireguard
chmod 750 /etc/wireguard

TARGET="/etc/wireguard/wg0.conf"
TS="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$TARGET" ]]; then
  echo "==> Backing up existing wg0.conf to ${TARGET}.${TS}.bak"
  cp -f "$TARGET" "${TARGET}.${TS}.bak"
fi

echo "==> Installing config from: $CONFIG"
if [[ "$CONFIG" == "~/"* ]]; then CONFIG="${CONFIG/\~/$HOME}"; fi
install -m 600 "$CONFIG" "$TARGET"

if ! grep -q '^\[Interface\]' "$TARGET"; then
  echo "WARNING: $TARGET may be invalid (missing [Interface])." >&2
fi

# Enable forwarding
sysctl -w net.ipv4.ip_forward=1

# Firewall rules
if $ALLOW_UFW; then
  if command -v ufw >/dev/null 2>&1; then
    echo "==> Allowing UDP ${PORT}/udp via UFW..."
    ufw allow "${PORT}/udp" || true
  fi
fi

echo "==> Enabling and starting wg-quick@wg0..."
systemctl daemon-reload || true
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "==> Verifying WireGuard status..."
systemctl --no-pager --full status wg-quick@wg0 || true
wg || true

echo
echo "==> Launching temporary iperf3 server on port 5201..."
pkill iperf3 || true
nohup iperf3 -s -p 5201 -1 -J >/tmp/iperf3-server.json 2>&1 &
sleep 1
echo "iperf3 server ready for one test on port 5201 (JSON will be in /tmp/iperf3-server.json)"
echo
echo "==> All set."
echo "If this is the server (listener), ensure your peer's Endpoint is set to this host’s public IP:${PORT}/udp."
echo "Use:   sudo wg     # to inspect state"
echo "       sudo tcpdump -ni any udp port ${PORT}   # to debug traffic"
