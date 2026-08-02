#!/usr/bin/env bash
#
# join.sh - run on a PRIVATE VPS to connect it to your beast hub.
# Only needs the hub's public IP and a name — it does everything else
# itself: generates its own keys, SSHes into the hub to register,
# writes the tunnel config, and sets up its own background services.
#
# Usage:
#   curl -fsSL <JOIN_URL> | sudo bash -s -- <hub_ip> <server_name> [ssh_user] [ssh_port]
#
# Example:
#   curl -fsSL <JOIN_URL> | sudo bash -s -- 51.38.40.174 server1
#
# Needs SSH access from THIS box to the hub as root (key-based auth
# recommended; it'll fall back to a password prompt if that's what
# you have set up).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This needs to run as root (use sudo)."
  exit 1
fi

HUB_IP=${1:?Usage: join.sh <hub_ip> <server_name> [ssh_user] [ssh_port]}
SERVER_NAME=${2:?Usage: join.sh <hub_ip> <server_name> [ssh_user] [ssh_port]}
SSH_USER=${3:-root}
SSH_PORT=${4:-22}

if [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Server name can only contain letters, numbers, - and _"
  exit 1
fi

echo "[*] Installing WireGuard..."
if command -v apt-get >/dev/null; then
  apt-get update -y >/dev/null 2>&1
  apt-get install -y wireguard iproute2 procps iputils-ping openssh-client >/dev/null 2>&1
elif command -v yum >/dev/null; then
  yum install -y wireguard-tools iproute procps-ng iputils openssh-clients >/dev/null 2>&1
fi

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

echo "[*] Generating this server's own keypair..."
PEER_PRIV=$(wg genkey)
PEER_PUB=$(echo "$PEER_PRIV" | wg pubkey)

echo "[*] Registering with the hub at ${HUB_IP} (you may be asked to confirm"
echo "    the host key, and/or enter a password if you don't have SSH keys"
echo "    set up between these servers)..."

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$SSH_PORT")

REMOTE_RESULT=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HUB_IP}" bash -s -- "$SERVER_NAME" "$PEER_PUB" << 'REMOTE_SCRIPT'
set -euo pipefail
name="$1"
peer_pub="$2"
CFG_DIR="/etc/pfw-beast"
SRV_DB="$CFG_DIR/servers.db"

if [[ ! -f "$CFG_DIR/hub_public.key" ]]; then
  echo "ERROR:HUB_NOT_SET_UP"
  exit 0
fi

mkdir -p "$CFG_DIR"
touch "$SRV_DB"

if awk -F'|' -v n="$name" '$1==n{f=1} END{exit !f}' "$SRV_DB"; then
  echo "ERROR:NAME_TAKEN"
  exit 0
fi

last_octet=$(awk -F'|' '{print $2}' "$SRV_DB" | awk -F. '{print $4}' | sort -n | tail -1)
next_octet=$(( ${last_octet:-1} + 1 ))
if (( next_octet > 254 )); then
  echo "ERROR:NO_IPS_LEFT"
  exit 0
fi
wg_ip="10.66.0.${next_octet}"

wg set wg0 peer "$peer_pub" allowed-ips "${wg_ip}/32"
wg-quick save wg0 >/dev/null 2>&1 || true
echo "${name}|${wg_ip}|${peer_pub}" >> "$SRV_DB"

hub_pub=$(cat "$CFG_DIR/hub_public.key")
wg_port=$(grep -oP '(?<=ListenPort = ).*' /etc/wireguard/wg0.conf | head -1)

echo "OK:${wg_ip}:${hub_pub}:${wg_port}"
REMOTE_SCRIPT
) || {
  echo ""
  echo "[!] Couldn't reach or run on the hub. Check:"
  echo "    - The hub IP is correct: ${HUB_IP}"
  echo "    - This server can SSH to ${SSH_USER}@${HUB_IP} on port ${SSH_PORT}"
  echo "    - You've run beast.sh on the hub already"
  exit 1
}

if [[ "$REMOTE_RESULT" == ERROR:NAME_TAKEN* ]]; then
  echo "[!] A server named '${SERVER_NAME}' is already registered on the hub. Pick a different name."
  exit 1
elif [[ "$REMOTE_RESULT" == ERROR:HUB_NOT_SET_UP* ]]; then
  echo "[!] The hub at ${HUB_IP} hasn't been set up yet — run beast.sh there first."
  exit 1
elif [[ "$REMOTE_RESULT" == ERROR:NO_IPS_LEFT* ]]; then
  echo "[!] The hub's address pool is full (254 servers). Can't add more."
  exit 1
elif [[ "$REMOTE_RESULT" != OK:* ]]; then
  echo "[!] Unexpected response from hub:"
  echo "$REMOTE_RESULT"
  exit 1
fi

IFS=':' read -r _ WG_IP HUB_PUB WG_PORT <<< "$REMOTE_RESULT"

if [[ -z "$WG_IP" || -z "$HUB_PUB" || -z "$WG_PORT" ]]; then
  echo "[!] Hub returned an incomplete response, aborting."
  exit 1
fi

echo "[+] Registered as '${SERVER_NAME}' with tunnel IP ${WG_IP}"

HUB_TUNNEL_IP="${WG_IP%.*}.1"

echo "[*] Writing tunnel config..."
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = ${PEER_PRIV}
Address = ${WG_IP}/24

[Peer]
PublicKey = ${HUB_PUB}
Endpoint = ${HUB_IP}:${WG_PORT}
AllowedIPs = 10.66.0.0/24
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf

systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0

echo "[*] Installing tunnel auto-heal watchdog..."
cat > /usr/local/bin/join-tunnel-watchdog.sh << WATCHEOF
#!/usr/bin/env bash
# Pings the hub through the tunnel every 30s. If it's unreachable for
# 3 checks in a row, restarts wg-quick@wg0 to force a reconnect.
set -uo pipefail

HUB_IP="${HUB_TUNNEL_IP}"
CHECK_INTERVAL=30
FAIL_LIMIT=3
LOG="/var/log/join-tunnel-watchdog.log"

log() { echo "\$(date '+%F %T') \$*" >> "\$LOG"; }

fails=0
while true; do
  if ping -c 1 -W 3 "\$HUB_IP" >/dev/null 2>&1; then
    fails=0
  else
    fails=\$((fails+1))
    log "Hub unreachable (\${fails}/\${FAIL_LIMIT})"
    if [[ \$fails -ge \$FAIL_LIMIT ]]; then
      log "Restarting wg-quick@wg0 to reconnect..."
      systemctl restart wg-quick@wg0 2>/dev/null || true
      fails=0
    fi
  fi
  sleep "\$CHECK_INTERVAL"
done
WATCHEOF
chmod +x /usr/local/bin/join-tunnel-watchdog.sh

cat > /etc/systemd/system/join-tunnel-watchdog.service << 'WATCHSERVICEEOF'
[Unit]
Description=Join Tunnel Watchdog - auto-reconnects the WireGuard tunnel if it drops
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
Requires=wg-quick@wg0.service

[Service]
Type=simple
ExecStart=/usr/local/bin/join-tunnel-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
WATCHSERVICEEOF

echo "[*] Installing resource guard for this server..."
cat > /usr/local/bin/join-resource-guard.sh << 'RESEOF'
#!/usr/bin/env bash
# Watches memory AND CPU load. Kills the biggest non-essential offender
# whenever either crosses its threshold. Never touches whitelisted
# system processes or this stack's own processes.
set -uo pipefail

RAM_THRESHOLD_MB=64      # kill something if available RAM drops below this
CPU_LOAD_MULT=2          # kill something if 1-min load avg exceeds cores * this
CHECK_INTERVAL=30
LOG="/var/log/join-resource-guard.log"

WHITELIST_REGEX='^(sshd|systemd.*|init|kthreadd|wg|wg-quick|iptables|cron|crond|dbus-daemon|rsyslogd|agetty|login|bash|sh|join-tunnel-wat|join-resource-g|networkd-dispat|systemd-resolve|systemd-network|chronyd|ntpd|multipathd|NetworkManager|journald)$'

CORES=$(nproc 2>/dev/null || echo 1)

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

kill_top_offender() {
  local sort_field=$1 reason=$2
  while read -r pid usage comm; do
    [[ "$pid" == "$$" ]] && continue
    if [[ "$comm" =~ $WHITELIST_REGEX ]]; then
      continue
    fi
    log "${reason}: killing PID ${pid} (${comm}), using ${usage}"
    kill -TERM "$pid" 2>/dev/null || true
    return 0
  done < <(ps -eo pid,"${sort_field}",comm --sort="-${sort_field}" | tail -n +2)
  return 1
}

while true; do
  avail_mb=$(free -m | awk '/^Mem:/{print $7}')
  if [[ -z "$avail_mb" ]]; then
    avail_mb=$(free -m | awk '/^Mem:/{print $4}')
  fi

  if [[ -n "$avail_mb" ]] && (( avail_mb < RAM_THRESHOLD_MB )); then
    log "Low memory: ${avail_mb}MB available (threshold ${RAM_THRESHOLD_MB}MB)."
    kill_top_offender "%mem" "RAM"
  fi

  load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
  load_threshold=$(( CORES * CPU_LOAD_MULT ))
  load1_int=${load1%%.*}
  if [[ -n "$load1_int" ]] && (( load1_int >= load_threshold )); then
    log "High load: ${load1} (threshold ${load_threshold}, cores ${CORES})."
    kill_top_offender "%cpu" "CPU"
  fi

  sleep "$CHECK_INTERVAL"
done
RESEOF
chmod +x /usr/local/bin/join-resource-guard.sh

cat > /etc/systemd/system/join-resource-guard.service << 'RESSERVICEEOF'
[Unit]
Description=Join Resource Guard - kills RAM/CPU-hogging processes when this box is under pressure
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/join-resource-guard.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
RESSERVICEEOF

systemctl daemon-reload
systemctl enable --now join-tunnel-watchdog.service >/dev/null 2>&1 || true
systemctl enable --now join-resource-guard.service >/dev/null 2>&1 || true

echo ""
echo "=========================================="
echo " Connected and self-managing!"
echo "=========================================="
echo " Registered on the hub as '${SERVER_NAME}', reachable at ${WG_IP}"
echo ""
echo " Running in the background on THIS server:"
echo "   - wg-quick@wg0            (the tunnel itself)"
echo "   - join-tunnel-watchdog    (auto-reconnects if the tunnel drops)"
echo "   - join-resource-guard     (kills RAM/CPU-hogging processes when high)"
echo ""
echo " On the hub, use 'sudo beast' -> Add port forward -> server name '${SERVER_NAME}'"
echo "=========================================="
wg show
