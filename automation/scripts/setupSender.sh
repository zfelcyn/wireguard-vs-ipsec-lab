#!/usr/bin/env bash
# setupSender.sh — Cross-platform WireGuard SENDER (client) setup for macOS & Ubuntu/Debian
#
# Usage examples (run from repo root):
#   ./automation/scripts/setupSender.sh --endpoint 192.168.88.9:51820
#   ./automation/scripts/setupSender.sh --endpoint <UBUNTU_PUBLIC_IP>:51820
#
# Optional flags:
#   --addr 10.10.10.1/24                            # sender (this machine) tunnel address
#   --priv envs/network-a/wireguard/keys/privatekey # path to THIS machine's private key
#   --peer-pub envs/network-b/wireguard/keys/publickey  # path to REMOTE peer's public key
#   --config envs/network-a/wireguard/wg0.conf      # where to write the client config
#   --dns 1.1.1.1                                   # optional DNS in [Interface]
#   --down                                          # bring interface down instead of up
#
# Notes:
# - Works on macOS (brew) and Ubuntu/Debian (apt). Needs sudo for wg-quick up/down.
# - Uses wg-quick on the CONFIG path (no need for /etc/wireguard on sender).
# - Keeps real keys in your repo’s envs/.../keys (make sure they’re git-ignored).

set -euo pipefail

# ---------- defaults ----------
ENDPOINT="${ENDPOINT:-}"                               # REQUIRED
ADDR="${ADDR:-10.10.10.1/24}"
PRIV="${PRIV:-envs/network-a/wireguard/keys/privatekey}"
PEER_PUB="${PEER_PUB:-envs/network-b/wireguard/keys/publickey}"
CONFIG="${CONFIG:-envs/network-a/wireguard/wg0.conf}"
DNS="${DNS:-1.1.1.1}"
DO_DOWN=false

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="${2:-}"; shift 2;;
    --addr)     ADDR="${2:-}"; shift 2;;
    --priv)     PRIV="${2:-}"; shift 2;;
    --peer-pub) PEER_PUB="${2:-}"; shift 2;;
    --config)   CONFIG="${2:-}"; shift 2;;
    --dns)      DNS="${2:-}"; shift 2;;
    --down)     DO_DOWN=true; shift;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# ---------- sanity ----------
if $DO_DOWN; then
  echo "Bringing WireGuard down from: $CONFIG"
  exec sudo wg-quick down "$CONFIG"
fi

if [[ -z "$ENDPOINT" ]]; then
  echo "ERROR: --endpoint <HOST:PORT> is required (e.g., --endpoint 192.168.88.9:51820)" >&2
  exit 1
fi
if [[ ! -f "$PRIV" ]]; then
  echo "ERROR: Private key not found: $PRIV" >&2
  exit 1
fi
if [[ ! -f "$PEER_PUB" ]]; then
  echo "ERROR: Peer public key not found: $PEER_PUB" >&2
  exit 1
fi

# ---------- detect OS & install tools ----------
OS="$(uname -s)"
case "$OS" in
  Darwin)
    if ! command -v wg-quick >/dev/null 2>&1; then
      echo "Installing wireguard-tools via Homebrew…"
      if ! command -v brew >/dev/null 2>&1; then
        echo "ERROR: Homebrew not found. Install from https://brew.sh and re-run." >&2
        exit 1
      fi
      brew install wireguard-tools
    fi
    ;;
  Linux)
    # check /etc/os-release for debian/ubuntu
    if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
    if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]]; then
      if ! command -v wg-quick >/dev/null 2>&1; then
        echo "Installing wireguard & tools via apt…"
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -y
        sudo apt-get install -y wireguard wireguard-tools
      fi
    else
      echo "WARN: Unrecognized Linux distro (${ID:-unknown}). Assuming wg-quick is installed."
    fi
    ;;
  *)
    echo "ERROR: Unsupported OS: $OS" >&2
    exit 1
    ;;
esac

# ---------- read keys ----------
umask 077
MY_PRIV="$(cat "$PRIV")"
PEER_PUB_VAL="$(cat "$PEER_PUB")"

# ---------- write config ----------
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF
[Interface]
Address = ${ADDR}
PrivateKey = ${MY_PRIV}
DNS = ${DNS}

[Peer]
PublicKey = ${PEER_PUB_VAL}
AllowedIPs = 10.10.10.0/24
Endpoint = ${ENDPOINT}
PersistentKeepalive = 25
EOF

chmod 600 "$CONFIG"
echo "Wrote sender config to: $CONFIG"

# ---------- bring it up ----------
echo "Bringing WireGuard up from: $CONFIG"
sudo wg-quick up "$CONFIG" || {
  echo "wg-quick up failed; trying restart (down then up)…"
  sudo wg-quick down "$CONFIG" || true
  sudo wg-quick up "$CONFIG"
}

echo
echo "==> Sender status:"
wg || true
echo
echo "All set. If the remote is listening, you should see 'latest handshake' here."
echo "To bring it down later:  $0 --config \"$CONFIG\" --down"
