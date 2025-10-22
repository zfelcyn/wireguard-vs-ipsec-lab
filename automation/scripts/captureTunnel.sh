#!/usr/bin/env bash
# captureTunnel.sh — Capture WG tunnel packets and run an iperf3 test
# Cross-platform: macOS + Ubuntu/Debian
#
# Examples:
#   # On Ubuntu (listener/server):
#   ./automation/scripts/captureTunnel.sh --role server --wgport 51820 --port 5201 --duration 10 --out /tmp
#   # (Optional) bind explicitly to server's WG IP:
#   ./automation/scripts/captureTunnel.sh --role server --bind 10.10.10.2 --port 5201 --duration 10 --out /tmp
#
#   # On Mac (sender/client):
#   ./automation/scripts/captureTunnel.sh --role client --peer 10.10.10.2 --wgport 51820 --port 5201 --duration 10 --out ./experiments/perf/raw
#
# Notes:
# - Start the server first (it will wait for one client), then run the client.
# - We capture encrypted WG UDP (udp.port == --wgport), not the decrypted tunnel.
# - Produces timestamped .pcap and iperf .json files in --out.

set -euo pipefail

ROLE=""
PEER=""                         # required for client
BIND_IP=""                      # optional for server (auto-detects if empty)
WGPORT="${WGPORT:-51820}"       # WireGuard UDP port
IPERF_PORT="${IPERF_PORT:-5201}"# iperf3 TCP port
DURATION="${DURATION:-10}"
OUT="${OUT:-.}"
IFACE="${IFACE:-any}"           # tcpdump interface
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname 2>/dev/null || echo host)"

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --peer) PEER="${2:-}"; shift 2;;
    --bind) BIND_IP="${2:-}"; shift 2;;
    --wgport) WGPORT="${2:-}"; shift 2;;
    --port) IPERF_PORT="${2:-}"; shift 2;;
    --duration) DURATION="${2:-}"; shift 2;;
    --out) OUT="${2:-}"; shift 2;;
    --iface) IFACE="${2:-}"; shift 2;;
    -h|--help)
      cat <<EOF
Usage:
  --role server|client
  --peer <10.10.10.x>            (client only)
  --bind <10.10.10.x>            (server: bind iperf3 to this local WG IP; auto-detects if omitted)
  --wgport <51820>               (WireGuard UDP capture port)
  --port <5201>                  (iperf3 TCP port)
  --duration <10>                (seconds)
  --out <dir>                    (output directory)
  --iface <any|en0|eth0|...>     (tcpdump interface; default "any")
EOF
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

[[ -n "$ROLE" ]] || { echo "ERROR: --role server|client is required" >&2; exit 1; }
if [[ "$ROLE" == "client" && -z "$PEER" ]]; then
  echo "ERROR: client role requires --peer <10.10.10.x>" >&2; exit 1
fi

mkdir -p "$OUT"

PCAP="${OUT}/wg-${ROLE}-${HOST}-${TS}.pcap"
IPERF_JSON="${OUT}/iperf-${ROLE}-${HOST}-${TS}.json"
TCPDUMP_LOG="${OUT}/tcpdump-${ROLE}-${HOST}-${TS}.log"

# ---------- ensure tools ----------
OS="$(uname -s)"
ensure_tools() {
  case "$OS" in
    Darwin)
      command -v tcpdump >/dev/null 2>&1 || { echo "ERROR: tcpdump missing on macOS"; exit 1; }
      command -v iperf3  >/dev/null 2>&1 || { command -v brew >/dev/null 2>&1 && brew install iperf3 || { echo "ERROR: install Homebrew and iperf3"; exit 1; }; }
      ;;
    Linux)
      if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
      if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]]; then
        command -v tcpdump >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y tcpdump; }
        command -v iperf3  >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y iperf3; }
      fi
      ;;
    *) : ;;
  esac
}
ensure_tools

# ---------- helpers ----------
detect_wg_ip() {
  # Finds first 10.x WG address on this host
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show | awk '/10\./ && /wg|utun/ {print $2}' | sed 's#/.*##' | head -n1
  else
    ifconfig 2>/dev/null | awk '/utun|wg/ {f=1} f && /inet /{print $2; exit}'
  fi
}

port_in_use() {
  local port="$1"
  if [[ "$OS" == "Darwin" ]]; then
    lsof -iTCP:"$port" -sTCP:LISTEN -nP 2>/dev/null | grep -q .
  else
    sudo ss -lptn 2>/dev/null | grep -q ":$port "
  fi
}

# ---------- start tcpdump ----------
echo "==> Starting tcpdump on interface '${IFACE}', UDP port ${WGPORT}"
sudo sh -c "tcpdump -i ${IFACE} udp port ${WGPORT} -n -w '${PCAP}' > '${TCPDUMP_LOG}' 2>&1 & echo \$! > '${PCAP}.pid'"
sleep 1
TCPDUMP_PID="$(cat "${PCAP}.pid" 2>/dev/null || true)"
[[ -n "${TCPDUMP_PID}" ]] || { echo "ERROR: failed to start tcpdump"; exit 1; }

stop_capture() {
  echo "==> Stopping tcpdump (pid ${TCPDUMP_PID})"
  sudo kill -INT "${TCPDUMP_PID}" 2>/dev/null || true
  wait "${TCPDUMP_PID}" 2>/dev/null || true
}
trap stop_capture EXIT

# ---------- iperf3 action ----------
if [[ "$ROLE" == "server" ]]; then
  # Pick bind IP: user-specified or auto-detect local WG IP
  if [[ -z "$BIND_IP" ]]; then
    BIND_IP="$(detect_wg_ip || true)"
  fi
  if [[ -z "$BIND_IP" ]]; then
    echo "ERROR: could not detect local WG IP to bind. Pass --bind <10.10.10.x>." >&2
    exit 1
  fi

  if port_in_use "$IPERF_PORT"; then
    echo "Port ${IPERF_PORT} already in use; killing stray iperf3 if any..."
    sudo pkill iperf3 || true
    sleep 1
    if port_in_use "$IPERF_PORT"; then
      echo "ERROR: Port ${IPERF_PORT} still busy. Choose another with --port." >&2
      exit 1
    fi
  fi

  echo "==> Running iperf3 server: iperf3 -s -p ${IPERF_PORT} -1 -J -B ${BIND_IP}"
  iperf3 -s -p "${IPERF_PORT}" -1 -J -B "${BIND_IP}" | tee "${IPERF_JSON}"

elif [[ "$ROLE" == "client" ]]; then
  echo "==> Running iperf3 client: iperf3 -c ${PEER} -p ${IPERF_PORT} -t ${DURATION} -J"
  iperf3 -c "${PEER}" -p "${IPERF_PORT}" -t "${DURATION}" -J | tee "${IPERF_JSON}"

else
  echo "ERROR: unknown role: ${ROLE}" >&2
  exit 1
fi

echo
echo "==> Done."
echo "PCAP saved to: ${PCAP}"
echo "iperf JSON:    ${IPERF_JSON}"
echo "tcpdump log:   ${TCPDUMP_LOG}"
