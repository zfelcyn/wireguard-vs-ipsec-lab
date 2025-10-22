#!/usr/bin/env bash
# captureTunnel.sh — Capture WireGuard UDP and run an iperf3 test
# Cross-platform: macOS + Ubuntu/Debian
#
# Examples:
#   # Server (Ubuntu):
#   ./automation/scripts/captureTunnel.sh --role server --wgport 51820 --port 5201 --duration 10 --out /tmp --bind-auto
#   # Client (Mac):
#   ./automation/scripts/captureTunnel.sh --role client --peer 10.10.10.2 --wgport 51820 --port 5201 --duration 10 --out ./experiments/perf/raw
#
#   # UDP test instead of TCP:
#   ./automation/scripts/captureTunnel.sh --role server --bind-auto --port 5202 --proto udp --duration 10 --out /tmp
#   ./automation/scripts/captureTunnel.sh --role client --peer 10.10.10.2 --port 5202 --proto udp --duration 10 --out ./experiments/perf/raw
#
# Notes:
# - Captures encrypted WG traffic (udp.port == --wgport) unless --no-capture.
# - Start server first (waits for one client); then run client.

set -euo pipefail

ROLE=""
PEER=""                          # client only
BIND_IP=""                       # server: bind to this WG IP
BIND_AUTO=false                  # server: auto-detect WG IP
WGPORT="${WGPORT:-51820}"        # WireGuard UDP port for capture
IPERF_PORT="${IPERF_PORT:-5201}" # iperf3 port
PROTO="tcp"                      # tcp | udp
DURATION="${DURATION:-10}"
OUT="${OUT:-.}"
IFACE="${IFACE:-any}"            # tcpdump interface
NO_CAPTURE=false
DEBUG=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --peer) PEER="${2:-}"; shift 2;;
    --bind) BIND_IP="${2:-}"; shift 2;;
    --bind-auto) BIND_AUTO=true; shift;;
    --wgport) WGPORT="${2:-}"; shift 2;;
    --port) IPERF_PORT="${2:-}"; shift 2;;
    --proto) PROTO="${2:-}"; shift 2;;
    --duration) DURATION="${2:-}"; shift 2;;
    --out) OUT="${2:-}"; shift 2;;
    --iface) IFACE="${2:-}"; shift 2;;
    --no-capture) NO_CAPTURE=true; shift;;
    --debug) DEBUG=true; shift;;
    -h|--help)
      cat <<EOF
Usage:
  --role server|client
  --peer <10.10.10.x>            (client only)
  --bind <10.10.10.x>            (server: bind iperf3 to this local WG IP)
  --bind-auto                    (server: auto-detect local WG IP; ignored if --bind set)
  --wgport <51820>               (WireGuard UDP capture port)
  --port <5201>                  (iperf3 port)
  --proto tcp|udp                (default tcp)
  --duration <10>                (seconds)
  --out <dir>                    (where to write .pcap/.json/.log)
  --iface <any|en0|eth0|...>     (capture interface; default any)
  --no-capture                   (skip tcpdump)
  --debug                        (bash -x)
EOF
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

$DEBUG && set -x

[[ -n "$ROLE" ]] || { echo "ERROR: --role server|client is required" >&2; exit 1; }
if [[ "$ROLE" == "client" && -z "$PEER" ]]; then
  echo "ERROR: client role requires --peer <10.10.10.x>" >&2; exit 1
fi
if [[ "$PROTO" != "tcp" && "$PROTO" != "udp" ]]; then
  echo "ERROR: --proto must be tcp or udp" >&2; exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname 2>/dev/null || echo host)"
mkdir -p "$OUT"

PCAP="${OUT}/wg-${ROLE}-${HOST}-${TS}.pcap"
IPERF_JSON="${OUT}/iperf-${ROLE}-${HOST}-${TS}.json"
TCPDUMP_LOG="${OUT}/tcpdump-${ROLE}-${HOST}-${TS}.log"

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

detect_wg_ip() {
  # Prefer wg0/utun*; first 10.x match
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show | awk '/inet / && /(wg|utun)/ {print $2}' | awk -F/ '{print $1}' | grep -E '^10\.' | head -n1
  else
    ifconfig 2>/dev/null | awk '/^(utun|wg)/{i=1} i && /inet /{print $2}' | grep -E '^10\.' | head -n1
  fi
}

port_in_use() {
  local port="$1"
  if [[ "$OS" == "Darwin" ]]; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .
  else
    sudo ss -lptn 2>/dev/null | grep -q ":$port "
  fi
}

start_capture() {
  $NO_CAPTURE && return 0
  echo "==> Starting tcpdump on '${IFACE}', UDP port ${WGPORT}"
  sudo sh -c "tcpdump -i ${IFACE} udp port ${WGPORT} -n -w '${PCAP}' > '${TCPDUMP_LOG}' 2>&1 & echo \$! > '${PCAP}.pid'"
  sleep 1
  TCPDUMP_PID="$(cat "${PCAP}.pid" 2>/dev/null || true)"
  [[ -n "${TCPDUMP_PID}" ]] || { echo "ERROR: failed to start tcpdump"; exit 1; }
}

stop_capture() {
  $NO_CAPTURE && return 0
  if [[ -n "${TCPDUMP_PID:-}" ]]; then
    echo "==> Stopping tcpdump (pid ${TCPDUMP_PID})"
    sudo kill -INT "${TCPDUMP_PID}" 2>/dev/null || true
    wait "${TCPDUMP_PID}" 2>/dev/null || true
  fi
}

trap stop_capture EXIT

case "$ROLE" in
  server)
    # Resolve bind IP
    if [[ -z "$BIND_IP" && "$BIND_AUTO" == true ]]; then
      BIND_IP="$(detect_wg_ip || true)"
    fi
    if [[ -z "$BIND_IP" ]]; then
      echo "ERROR: server needs a local WG IP to bind. Use --bind-auto or --bind <10.10.10.x>" >&2
      exit 1
    fi

    if port_in_use "$IPERF_PORT"; then
      echo "Port ${IPERF_PORT} busy; killing stray iperf3…"
      sudo pkill iperf3 || true
      sleep 1
      port_in_use "$IPERF_PORT" && { echo "ERROR: Port ${IPERF_PORT} still busy. Pick another with --port."; exit 1; }
    fi

    start_capture

    if [[ "$PROTO" == "udp" ]]; then
      echo "==> Running iperf3 UDP server: iperf3 -s -p ${IPERF_PORT} -1 -J -B ${BIND_IP} -u"
      iperf3 -s -p "${IPERF_PORT}" -1 -J -B "${BIND_IP}" -u | tee "${IPERF_JSON}"
    else
      echo "==> Running iperf3 TCP server: iperf3 -s -p ${IPERF_PORT} -1 -J -B ${BIND_IP}"
      iperf3 -s -p "${IPERF_PORT}" -1 -J -B "${BIND_IP}" | tee "${IPERF_JSON}"
    fi
    ;;

  client)
    [[ -n "$PEER" ]] || { echo "ERROR: client needs --peer <10.10.10.x>"; exit 1; }

    start_capture

    if [[ "$PROTO" == "udp" ]]; then
      echo "==> Running iperf3 UDP client: iperf3 -c ${PEER} -p ${IPERF_PORT} -u -b 0 -t ${DURATION} -J"
      # -b 0 = unlimited rate (let TCP/OS shape); tweak if you want a cap
      iperf3 -c "${PEER}" -p "${IPERF_PORT}" -u -b 0 -t "${DURATION}" -J | tee "${IPERF_JSON}"
    else
      echo "==> Running iperf3 TCP client: iperf3 -c ${PEER} -p ${IPERF_PORT} -t ${DURATION} -J"
      iperf3 -c "${PEER}" -p "${IPERF_PORT}" -t "${DURATION}" -J | tee "${IPERF_JSON}"
    fi
    ;;

  *)
    echo "ERROR: unknown role: ${ROLE}" >&2; exit 1;;
esac

echo
echo "==> Done."
$NO_CAPTURE || echo "PCAP saved to: ${PCAP}"
echo "iperf JSON:    ${IPERF_JSON}"
$NO_CAPTURE || echo "tcpdump log:   ${TCPDUMP_LOG}"
