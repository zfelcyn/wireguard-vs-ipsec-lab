#!/usr/bin/env bash
set -euo pipefail

command -v wg >/dev/null 2>&1 || { echo "ERROR: 'wg' not found. Install wireguard-tools."; exit 1; }
umask 077

gen() {
  local side="$1"
  local k="$side/wireguard/keys"
  mkdir -p "$k"

  # generate private key if missing or empty
  if [[ ! -s "$k/privatekey" ]]; then
    wg genkey > "$k/privatekey"
    echo "Generated private key for $side"
  else
    echo "Private key already present for $side (non-empty)"
  fi

  # always regenerate public key from private key
  < "$k/privatekey" wg pubkey > "$k/publickey"
  echo "Wrote public key for $side"
}

gen "envs/network-a"
gen "envs/network-b"
echo "Done. Keys in envs/*/wireguard/keys/ (git-ignored)."
