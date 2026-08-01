#!/usr/bin/env bash
#
# join.sh - run on a PRIVATE VPS to connect it to your beast hub.
# Sets up its OWN background services here (tunnel auto-heal + resource guard)
# so this box takes care of itself. The hub stays management-only.
#
# You normally don't run this by hand — beast.sh's "Connect a new server"
# prints the exact command with the right arguments already filled in.
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

HUB_TUNNEL_IP="${WG_IP%.*}.1"   # e.g. 10.66.0.5 -> 10.66.0.1 (the hub)

echo "[*] Installing WireGuard..."
if command -v apt-get >/dev/null; then
  apt-get update -y >/dev/null 2>&1
  apt-get install -y wireguard iproute2 procps iputils-ping >/dev/null 2>&1
elif command -v yum >/dev/null; then
  yum install -y wireguard-tools iproute procps-ng iputils >/dev/null 2>&1
fi

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

echo "[*] Writing tunnel config..."
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
echo " This server is now reachable at ${WG_IP} from your hub."
echo ""
echo " Running in the background on THIS server:"
echo "   - wg-quick@wg0            (the tunnel itself)"
echo "   - join-tunnel-watchdog    (auto-reconnects if the tunnel drops)"
echo "   - join-resource-guard     (kills RAM/CPU-hogging processes when high)"
echo ""
echo " All enabled to survive reboots. Check anytime with:"
echo "   systemctl status wg-quick@wg0 join-tunnel-watchdog join-resource-guard"
echo "=========================================="
wg show
