#!/usr/bin/env bash
#
# join.sh - run on a PRIVATE VPS to connect it to your beast hub.
# You normally don't run this by hand — beast.sh prints the exact
# curl command with the right arguments already filled in.
#
# Usage: curl -fsSL <JOIN_URL> | sudo bash -s -- <peer_priv> <wg_ip> <hub_pub> <hub_endpoint_ip> <wg_port>

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This needs to run as root (use sudo)."
  exit 1
fi

PEER_PRIV=${1:?missing peer private key}
WG_IP=${2:?missing wg ip}
HUB_PUB=${3:?missing hub public key}
HUB_ENDPOINT_IP=${4:?missing hub endpoint ip}
WG_PORT=${5:?missing wg port}

echo "[*] Installing WireGuard..."
if command -v apt-get >/dev/null; then
  apt-get update -y >/dev/null 2>&1
  apt-get install -y wireguard >/dev/null 2>&1
elif command -v yum >/dev/null; then
  yum install -y wireguard-tools >/dev/null 2>&1
fi

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${PEER_PRIV}
Address = ${WG_IP}/24

[Peer]
PublicKey = ${HUB_PUB}
Endpoint = ${HUB_ENDPOINT_IP}:${WG_PORT}
AllowedIPs = 10.66.0.0/24
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf

systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0

echo ""
echo "[+] Connected! This server is now reachable at ${WG_IP} from your hub."
wg show
