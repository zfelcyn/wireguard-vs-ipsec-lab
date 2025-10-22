#!/usr/bin/env bash
# captureTunnel.sh — Capture WG tunnel packets and run a 10s iperf3 test
# Cross-platform: macOS + Ubuntu/Debian
#
# Examples:
#   # On Ubuntu (listener/server):
#   ./automation/scripts/captureTunnel.sh --role server --wgport 51820 --port 5201 --duration 10 --out /tmp
#
#   # On Mac (sender/client):
#   ./automation/scripts/captureTunnel.sh --role client --peer 10.10.10.2 --wgport 51820 --port 5201 --duration 10 --out ./experiments/perf/raw
#
# Notes:
# - Server should be started first; it will wait for the client.
# - Captures UDP port == --wgport (WireGuard), not decrypted tunnel packets.
# - Produces .pcap and iperf3 .json with timestamped filenames.

set -euo pipefail

ROLE=""
PEER=""                   # required for client
WGPORT="${WGPORT:-51820}" # WireGuard UDP port
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-10}"
OUT="${OUT:-.}"
IFACE="${IFACE:-any}"     # tcpdump interface ("any" is safe)
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname 2>/dev/null || echo host)"

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --peer) PEER="${2:-}"; shift 2;;
    --wgport) WGPORT="${2:-}"; shift 2;;
    --port) IPERF_PORT="${2:-}"; shift 2;;
    --duration) DURATION="${2:-}"; shift 2;;
    --out) OUT="${2:-}"; shift 2;;
    --iface) IFACE="${2:-}"; shift 2;;
    -h|--help)
      echo "Usage:"
      echo "  --role server|client"
      echo "  --peer <10.10.10.x>           # required for client"
      echo "  --wgport <51820>"
      echo "  --port <5201>                 # iperf3 port"
      echo "  --duration <10>"
      echo "  --out <dir>"
      echo "  --iface <any|en0|eth0|...>"
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ -z "$ROLE" ]]; then
  echo "ERROR: --role server|client is required" >&2; exit 1
fi
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
      command -v iperf3 >/dev/null 2>&1 || { command -v brew >/dev/null 2>&1 && brew install iperf3; }
      command -v tcpdump >/dev/null 2>&1 || { echo "ERROR: tcpdump missing"; exit 1; }
      ;;
    Linux)
      if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
      if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]]; then
        command -v iperf3 >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y iperf3; }
        command -v tcpdump >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y tcpdump; }
      fi
      ;;
    *) ;;
  esac
}
ensure_tools

# ---------- start tcpdump ----------
echo "==> Starting tcpdump on interface '${IFACE}', UDP port ${WGPORT}"
# Need sudo for raw capture
sudo sh -c "tcpdump -i ${IFACE} udp port ${WGPORT} -n -w '${PCAP}' > '${TCPDUMP_LOG}' 2>&1 & echo \$! > '${PCAP}.pid'"
sleep 1
TCPDUMP_PID="$(cat "${PCAP}.pid" 2>/dev/null || true)"
if [[ -z "${TCPDUMP_PID}" ]]; then
  echo "ERROR: failed to start tcpdump" >&2; exit 1
fi

stop_capture() {
  echo "==> Stopping tcpdump (pid ${TCPDUMP_PID})"
  sudo kill -INT "${TCPDUMP_PID}" 2>/dev/null || true
  wait "${TCPDUMP_PID}" 2>/dev/null || true
}
trap stop_capture EXIT

# ---------- iperf3 action ----------
if [[ "$ROLE" == "server" ]]; then
  echo "==> Running iperf3 server: iperf3 -s -p ${IPERF_PORT} -1 -J"
  # one-shot server; JSON will go to file
  iperf3 -s -p "${IPERF_PORT}" -1 -J | tee "${IPERF_JSON}"
elif [[ "$ROLE" == "client" ]]; then
  echo "==> Running iperf3 client: iperf3 -c ${PEER} -p ${IPERF_PORT} -t ${DURATION} -J"
  iperf3 -c "${PEER}" -p "${IPERF_PORT}" -t "${DURATION}" -J | tee "${IPERF_JSON}"
else
  echo "ERROR: unknown role: ${ROLE}" >&2; exit 1
fi

echo
echo "==> Done."
echo "PCAP saved to: ${PCAP}"
echo "iperf JSON:    ${IPERF_JSON}"
echo "tcpdump log:   ${TCPDUMP_LOG}"
