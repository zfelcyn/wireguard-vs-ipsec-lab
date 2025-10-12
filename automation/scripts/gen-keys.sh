#!/usr/bin/env bash
set -euo pipefail
for SIDE in envs/network-a envs/network-b; do
  K="$SIDE/wireguard/keys"
  mkdir -p "$K"
  [ -f "$K/privatekey" ] || wg genkey | tee "$K/privatekey" | wg pubkey > "$K/publickey"
  echo "Generated keys for $SIDE"
done
echo "Remember to supply peer public keys in Ansible vars or render templates manually."
