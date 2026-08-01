#!/usr/bin/env bash
#
# beast.sh - Port Forward Beast INSTALLER
# Run this ONCE on your public VPS (the hub). It does NOT show any menu.
# It silently installs everything, then gives you a `beast` command to
# use whenever you actually want to manage forwards.
#
# Usage: sudo bash beast.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo: sudo bash beast.sh"
  exit 1
fi

CFG_DIR="/etc/pfw-beast"
WG_NET_PREFIX="10.66.0"
WG_HUB_IP="${WG_NET_PREFIX}.1"
WG_PORT="51820"

# URL where join.sh is hosted. Edit this before running the installer.
JOIN_URL="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/join.sh"

echo "[*] Installing dependencies (iptables, wireguard)..."
mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR"
touch "$CFG_DIR/forwards.db" "$CFG_DIR/servers.db"

if command -v apt-get >/dev/null; then
  apt-get update -y >/dev/null 2>&1
  apt-get install -y iptables wireguard curl >/dev/null 2>&1
elif command -v yum >/dev/null; then
  yum install -y iptables wireguard-tools curl >/dev/null 2>&1
fi

if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

if [[ ! -f "$CFG_DIR/hub_private.key" ]]; then
  echo "[*] Setting up this VPS as the WireGuard hub..."
  wg genkey | tee "$CFG_DIR/hub_private.key" | wg pubkey > "$CFG_DIR/hub_public.key"
  chmod 600 "$CFG_DIR/hub_private.key"
  hub_priv=$(cat "$CFG_DIR/hub_private.key")
  cat > /etc/wireguard/wg0.conf << WG0EOF
[Interface]
Address = ${WG_HUB_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${hub_priv}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
WG0EOF
  systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
  systemctl restart wg-quick@wg0
fi

echo "[*] Installing auto-restore of your forwards after reboot..."
cat > /usr/local/bin/pfw-beast-restore.sh << 'RESTOREEOF'
#!/usr/bin/env bash
set -euo pipefail
CFG_DIR="/etc/pfw-beast"
FWD_DB="$CFG_DIR/forwards.db"
SRV_DB="$CFG_DIR/servers.db"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

[[ -f "$FWD_DB" ]] || exit 0
[[ -f "$SRV_DB" ]] || exit 0

while IFS='|' read -r id proto lport sname dport; do
  [[ -z "$id" ]] && continue
  dip=$(awk -F'|' -v n="$sname" '$1==n{print $2}' "$SRV_DB")
  [[ -z "$dip" ]] && continue
  # remove first (ignore errors if not present) so re-running this script
  # (e.g. on service restart) never creates duplicate rules
  iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${dip}:${dport}" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p "$proto" -d "$dip" --dport "$dport" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p "$proto" -d "$dip" --dport "$dport" -j ACCEPT 2>/dev/null || true
  iptables -t nat -A PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${dip}:${dport}" 2>/dev/null || true
  iptables -t nat -A POSTROUTING -p "$proto" -d "$dip" --dport "$dport" -j MASQUERADE 2>/dev/null || true
  iptables -A FORWARD -p "$proto" -d "$dip" --dport "$dport" -j ACCEPT 2>/dev/null || true
done < "$FWD_DB"
RESTOREEOF
chmod +x /usr/local/bin/pfw-beast-restore.sh

cat > /etc/systemd/system/pfw-beast-restore.service << 'SERVICEEOF'
[Unit]
Description=Restore Port Forward Beast rules after reboot
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
Requires=wg-quick@wg0.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pfw-beast-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICEEOF

echo "[*] Installing RAM guard (auto-kills memory-hungry processes when RAM gets low)..."
cat > /usr/local/bin/beast-ram-guard.sh << 'RAMEOF'
#!/usr/bin/env bash
# Kills the biggest non-essential RAM user whenever available memory
# drops below THRESHOLD_MB. Never touches whitelisted system processes.
set -uo pipefail

THRESHOLD_MB=64
CHECK_INTERVAL=30
LOG="/var/log/beast-ram-guard.log"

# Never kill these (system-critical / this stack's own processes).
WHITELIST_REGEX='^(sshd|systemd.*|init|kthreadd|wg|wg-quick|iptables|cron|crond|dbus-daemon|rsyslogd|agetty|login|bash|sh|beast|beast-ram-guar|networkd-disp|systemd-resolve|systemd-network|chronyd|ntpd|multipathd|NetworkManager|journald)$'

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

while true; do
  avail_mb=$(free -m | awk '/^Mem:/{print $7}')
  if [[ -z "$avail_mb" ]]; then
    avail_mb=$(free -m | awk '/^Mem:/{print $4}')
  fi

  if [[ -n "$avail_mb" ]] && (( avail_mb < THRESHOLD_MB )); then
    log "Low memory: ${avail_mb}MB available (threshold ${THRESHOLD_MB}MB). Checking for something to kill..."
    while read -r pid pmem comm; do
      [[ "$pid" == "$$" ]] && continue
      if [[ "$comm" =~ $WHITELIST_REGEX ]]; then
        continue
      fi
      log "Killing PID ${pid} (${comm}), using ${pmem}% memory"
      kill -TERM "$pid" 2>/dev/null || true
      break
    done < <(ps -eo pid,%mem,comm --sort=-%mem | tail -n +2)
  fi

  sleep "$CHECK_INTERVAL"
done
RAMEOF
chmod +x /usr/local/bin/beast-ram-guard.sh

cat > /etc/systemd/system/beast-ram-guard.service << 'RAMSERVICEEOF'
[Unit]
Description=Beast RAM Guard - kills memory-hungry processes when RAM is low
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/beast-ram-guard.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
RAMSERVICEEOF

systemctl daemon-reload
systemctl enable pfw-beast-restore.service >/dev/null 2>&1 || true
systemctl enable --now beast-ram-guard.service >/dev/null 2>&1 || true

echo "[*] Installing the 'beast' management command..."
cat > /usr/local/bin/beast << 'CLIEOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo: sudo beast"
  exit 1
fi

CFG_DIR="__CFG_DIR__"
FWD_DB="$CFG_DIR/forwards.db"
SRV_DB="$CFG_DIR/servers.db"
WG_NET_PREFIX="__WG_NET_PREFIX__"
WG_PORT="__WG_PORT__"
JOIN_URL="__JOIN_URL__"
PASS_FILE="$CFG_DIR/password.hash"

mkdir -p "$CFG_DIR"
touch "$FWD_DB" "$SRV_DB"

hash_pw() {
  echo -n "$1" | sha256sum | awk '{print $1}'
}

setup_password() {
  echo ""
  echo "=========================================="
  echo " No password set yet — let's set one now."
  echo " This locks the tool so only you can run it."
  echo "=========================================="
  local p1 p2
  while true; do
    read -rsp "Set a password: " p1; echo ""
    read -rsp "Confirm password: " p2; echo ""
    if [[ -z "$p1" ]]; then
      echo "Password can't be empty."
      continue
    fi
    if [[ "$p1" != "$p2" ]]; then
      echo "Didn't match, try again."
      continue
    fi
    break
  done
  hash_pw "$p1" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "[+] Password set."
}

check_password() {
  local attempts=0
  local entered hash stored
  stored=$(cat "$PASS_FILE")
  while [[ $attempts -lt 3 ]]; do
    read -rsp "Password: " entered; echo ""
    hash=$(hash_pw "$entered")
    if [[ "$hash" == "$stored" ]]; then
      return 0
    fi
    attempts=$((attempts+1))
    echo "Wrong password. ($((3-attempts)) attempts left)"
    sleep 2
  done
  echo "Too many failed attempts. Exiting."
  exit 1
}

get_pub_ip() {
  curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_VPS_PUBLIC_IP"
}

next_fwd_id() {
  local last
  last=$(tail -n1 "$FWD_DB" 2>/dev/null | cut -d'|' -f1)
  echo $(( ${last:-0} + 1 ))
}

next_srv_octet() {
  local last
  last=$(awk -F'|' '{print $2}' "$SRV_DB" | awk -F. '{print $4}' | sort -n | tail -1)
  echo $(( ${last:-1} + 1 ))
}

server_ip_by_name() {
  awk -F'|' -v n="$1" '$1==n{print $2}' "$SRV_DB"
}

apply_rule() {
  local proto=$1 lport=$2 dip=$3 dport=$4
  iptables -t nat -A PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${dip}:${dport}"
  iptables -t nat -A POSTROUTING -p "$proto" -d "$dip" --dport "$dport" -j MASQUERADE
  iptables -A FORWARD -p "$proto" -d "$dip" --dport "$dport" -j ACCEPT
}

remove_rule() {
  local proto=$1 lport=$2 dip=$3 dport=$4
  iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "${dip}:${dport}" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p "$proto" -d "$dip" --dport "$dport" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p "$proto" -d "$dip" --dport "$dport" -j ACCEPT 2>/dev/null || true
}

pause() {
  echo ""
  read -rp "Press Enter to go back to the menu..." _
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

safe_apply_rule() {
  if ! apply_rule "$@"; then
    echo "[!] Failed to apply that rule (maybe it already exists, or bad input). Nothing was saved."
    return 1
  fi
}

# Is this listen_port/proto already used by another forward we manage?
# Pass an id to exclude (used when editing) or "" to check all.
listen_port_taken() {
  local proto=$1 lport=$2 exclude_id=${3:-}
  awk -F'|' -v p="$proto" -v lp="$lport" -v ex="$exclude_id" \
    '$2==p && $3==lp && $1!=ex{found=1} END{exit !found}' "$FWD_DB"
}

# Is this port already bound by a real process on this VPS? (not our DNAT
# rules — those don't bind a socket — this catches things like sshd on 22)
port_in_use_by_system() {
  local proto=$1 port=$2
  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi
  if [[ "$proto" == "tcp" ]]; then
    ss -H -tln "sport = :${port}" 2>/dev/null | grep -q .
  else
    ss -H -uln "sport = :${port}" 2>/dev/null | grep -q .
  fi
}

# Quick reachability test to a destination ip:port. TCP only (UDP has no
# reliable connect-test without a cooperating server on the other end).
test_tcp_reachable() {
  local ip=$1 port=$2
  timeout 2 bash -c "echo > /dev/tcp/${ip}/${port}" 2>/dev/null
}

action_connect_server() {
  if [[ "$JOIN_URL" == *"YOUR_USERNAME"* ]]; then
    echo ""
    echo "[!] JOIN_URL is still set to the placeholder value."
    echo "    Re-run the installer (beast.sh) with JOIN_URL set to your"
    echo "    real GitHub raw link for join.sh first."
    return
  fi
  echo ""
  echo "--- Connect a New Server (any provider, anywhere) ---"
  read -rp "Give this server a short name (e.g. server1): " name
  if [[ -z "$name" ]]; then
    echo "Name required, cancelled."
    return
  fi
  if awk -F'|' -v n="$name" '$1==n{found=1} END{exit !found}' "$SRV_DB"; then
    echo "That name is already used."
    return
  fi

  local octet; octet=$(next_srv_octet)
  local wg_ip="${WG_NET_PREFIX}.${octet}"
  local peer_priv peer_pub hub_pub pub_ip
  peer_priv=$(wg genkey)
  peer_pub=$(echo "$peer_priv" | wg pubkey)
  hub_pub=$(cat "$CFG_DIR/hub_public.key")
  pub_ip=$(get_pub_ip)

  wg set wg0 peer "$peer_pub" allowed-ips "${wg_ip}/32"
  wg-quick save wg0 >/dev/null 2>&1 || true

  echo "${name}|${wg_ip}|${peer_pub}" >> "$SRV_DB"

  echo ""
  echo "=========================================================="
  echo " '${name}' registered! Now SSH into THAT server and run"
  echo " this single command to connect it:"
  echo "=========================================================="
  echo ""
  echo "curl -fsSL ${JOIN_URL} | sudo bash -s -- ${peer_priv} ${wg_ip} ${hub_pub} ${pub_ip} ${WG_PORT}"
  echo ""
  echo "=========================================================="
  echo " Once you run that on '${name}', it'll be reachable at ${wg_ip}"
  echo " Come back here and use 'Add port forward' with server"
  echo " name '${name}'."
  echo "=========================================================="
}

action_list_servers() {
  echo ""
  echo "=========== CONNECTED SERVERS ==========="
  if [[ ! -s "$SRV_DB" ]]; then
    echo "  (none yet — use 'Connect a new server' first)"
  else
    printf "%-15s %-15s\n" "NAME" "TUNNEL IP"
    while IFS='|' read -r name ip pub; do
      [[ -z "$name" ]] && continue
      printf "%-15s %-15s\n" "$name" "$ip"
    done < "$SRV_DB"
  fi
  echo "==========================================="
}

action_add_forward() {
  action_list_servers
  echo ""
  echo "--- New Port Forward ---"
  read -rp "Protocol (tcp/udp) [tcp]: " proto
  proto=${proto:-tcp}
  if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
    echo "Invalid protocol."
    return
  fi
  read -rp "Port people connect to on THIS vps: " lport
  read -rp "Server name (from list above): " sname
  read -rp "Port on that server to reach: " dport

  if ! is_valid_port "$lport"; then
    echo "Invalid listen port — must be a number 1-65535."
    return
  fi
  if ! is_valid_port "$dport"; then
    echo "Invalid destination port — must be a number 1-65535."
    return
  fi

  if listen_port_taken "$proto" "$lport"; then
    echo "[!] ${proto}/${lport} is already used by another forward. Pick a different port or edit/delete the existing one."
    return
  fi
  if port_in_use_by_system "$proto" "$lport"; then
    echo "[!] Warning: something on this VPS is already listening on ${proto}/${lport}"
    echo "    (e.g. sshd, a webserver, etc). Forwarding this port may conflict with it."
    read -rp "    Continue anyway? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }
  fi

  local dip; dip=$(server_ip_by_name "$sname")
  if [[ -z "$dip" ]]; then
    echo "No connected server named '${sname}'. Use 'Connect a new server' first."
    return
  fi

  if [[ "$proto" == "tcp" ]]; then
    echo "[*] Testing if ${dip}:${dport} is actually reachable..."
    if test_tcp_reachable "$dip" "$dport"; then
      echo "[+] Reachable — the destination is responding."
    else
      echo "[!] Not reachable right now (nothing listening there yet, or it's blocked)."
      echo "    You can still add the forward — it'll work once that service is up."
    fi
  fi

  local id; id=$(next_fwd_id)
  if safe_apply_rule "$proto" "$lport" "$dip" "$dport"; then
    echo "${id}|${proto}|${lport}|${sname}|${dport}" >> "$FWD_DB"
    echo ""
    echo "[+] Done! ${proto}/${lport} on this VPS now reaches ${sname} (${dip}) port ${dport}"
  fi
}

action_bulk_add_forward() {
  action_list_servers
  echo ""
  echo "--- Bulk Add Forwards ---"
  echo "Format per line: proto,listen_port,server_name,dest_port"
  echo "Example:"
  echo "  tcp,2201,server1,22"
  echo "  tcp,8080,server2,80"
  echo "  udp,5000,server1,5000"
  echo ""
  echo "Paste lines, then press Ctrl+D when done:"
  echo ""
  local count=0
  while IFS=',' read -r proto lport sname dport; do
    proto=$(echo "$proto" | xargs); lport=$(echo "$lport" | xargs)
    sname=$(echo "$sname" | xargs); dport=$(echo "$dport" | xargs)
    [[ -z "$proto" ]] && continue
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
      echo "  [skip] bad protocol: $proto,$lport,$sname,$dport"; continue
    fi
    if ! is_valid_port "$lport" || ! is_valid_port "$dport"; then
      echo "  [skip] bad port: $proto,$lport,$sname,$dport"; continue
    fi
    if listen_port_taken "$proto" "$lport"; then
      echo "  [skip] ${proto}/${lport} already used by another forward: $proto,$lport,$sname,$dport"; continue
    fi
    local dip; dip=$(server_ip_by_name "$sname")
    if [[ -z "$dip" ]]; then
      echo "  [skip] unknown server '${sname}': $proto,$lport,$sname,$dport"; continue
    fi
    local id; id=$(next_fwd_id)
    if safe_apply_rule "$proto" "$lport" "$dip" "$dport"; then
      echo "${id}|${proto}|${lport}|${sname}|${dport}" >> "$FWD_DB"
      echo "  [+] added: ${proto}/${lport} -> ${sname} (${dip}):${dport}"
      count=$((count+1))
    fi
  done
  echo ""
  echo "[+] Bulk add complete. Added ${count} forward(s)."
}

action_list_forwards() {
  echo ""
  echo "=========== PORT FORWARDS ==========="
  if [[ ! -s "$FWD_DB" ]]; then
    echo "  (none yet)"
  else
    printf "%-4s %-6s %-10s %-12s %-8s\n" "ID" "PROTO" "LISTEN" "SERVER" "PORT"
    while IFS='|' read -r id proto lport sname dport; do
      [[ -z "$id" ]] && continue
      printf "%-4s %-6s %-10s %-12s %-8s\n" "$id" "$proto" "$lport" "$sname" "$dport"
    done < "$FWD_DB"
  fi
  echo "======================================"
}

action_edit_forward() {
  action_list_forwards
  echo ""
  read -rp "Enter the forward ID to edit: " id
  local line; line=$(awk -F'|' -v id="$id" '$1==id' "$FWD_DB")
  if [[ -z "$line" ]]; then
    echo "No forward with that ID."
    return
  fi
  IFS='|' read -r oid oproto olport osname odport <<< "$line"
  local odip; odip=$(server_ip_by_name "$osname")

  echo ""
  echo "Editing forward ${id} (leave blank to keep current value)"
  read -rp "Protocol [$oproto]: " proto
  read -rp "Listen port [$olport]: " lport
  read -rp "Server name [$osname]: " sname
  read -rp "Destination port [$odport]: " dport
  proto=${proto:-$oproto}; lport=${lport:-$olport}
  sname=${sname:-$osname}; dport=${dport:-$odport}

  if ! is_valid_port "$lport" || ! is_valid_port "$dport"; then
    echo "Invalid port(s), cancelled."
    return
  fi

  if listen_port_taken "$proto" "$lport" "$id"; then
    echo "[!] ${proto}/${lport} is already used by a different forward. Pick another port."
    return
  fi

  local dip; dip=$(server_ip_by_name "$sname")
  if [[ -z "$dip" ]]; then
    echo "Unknown server '${sname}', cancelled."
    return
  fi

  remove_rule "$oproto" "$olport" "$odip" "$odport"
  if safe_apply_rule "$proto" "$lport" "$dip" "$dport"; then
    sed -i "s/^${id}|.*/${id}|${proto}|${lport}|${sname}|${dport}/" "$FWD_DB"
    echo ""
    echo "[+] Forward ${id} updated."
  else
    echo "[!] New rule failed — restoring the old one."
    apply_rule "$oproto" "$olport" "$odip" "$odport" || true
  fi
}

action_delete_forward() {
  action_list_forwards
  echo ""
  read -rp "Enter the forward ID to delete: " id
  local line; line=$(awk -F'|' -v id="$id" '$1==id' "$FWD_DB")
  if [[ -z "$line" ]]; then
    echo "No forward with that ID."
    return
  fi
  IFS='|' read -r oid oproto olport osname odport <<< "$line"
  local odip; odip=$(server_ip_by_name "$osname")
  remove_rule "$oproto" "$olport" "$odip" "$odport"
  sed -i "/^${id}|/d" "$FWD_DB"
  echo ""
  echo "[-] Forward ${id} deleted."
}

action_change_password() {
  echo ""
  local entered hash stored
  stored=$(cat "$PASS_FILE")
  read -rsp "Current password: " entered; echo ""
  hash=$(hash_pw "$entered")
  if [[ "$hash" != "$stored" ]]; then
    echo "Wrong password, cancelled."
    return
  fi
  setup_password
}

action_ram_status() {
  echo ""
  echo "=========== MEMORY STATUS ==========="
  free -h
  echo ""
  echo "Top 5 RAM users right now:"
  ps -eo pid,%mem,comm --sort=-%mem | head -n 6
  echo ""
  echo "Recent RAM guard actions:"
  if [[ -f /var/log/beast-ram-guard.log ]]; then
    tail -n 10 /var/log/beast-ram-guard.log
  else
    echo "  (no actions logged yet)"
  fi
  echo "======================================"
}

BEAST_SERVICES=(wg-quick@wg0 pfw-beast-restore beast-ram-guard)

action_service_status() {
  echo ""
  echo "=========== SERVICE STATUS ==========="
  for svc in "${BEAST_SERVICES[@]}"; do
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    printf "%-25s %s\n" "$svc" "$state"
  done
  echo "======================================="
}

action_restart_services() {
  echo ""
  echo "--- Restarting all beast services ---"
  for svc in "${BEAST_SERVICES[@]}"; do
    echo -n "Restarting ${svc}... "
    if systemctl restart "$svc" 2>/dev/null; then
      echo "OK"
    else
      echo "FAILED (check: systemctl status ${svc})"
    fi
  done
  echo ""
  echo "[+] Done. Your existing forwards were NOT removed — wg-quick@wg0"
  echo "    reloads its saved peers, and pfw-beast-restore reapplies your"
  echo "    saved port forwards automatically on restart."
}

action_port_capacity() {
  echo ""
  echo "=========== PORT / CAPACITY CHECK ==========="
  local active_forwards
  active_forwards=$(grep -c . "$FWD_DB" 2>/dev/null || echo 0)
  echo "Active forwards right now:      ${active_forwards}"
  echo ""

  echo "Max open files (per-process):   $(ulimit -n)"
  echo "  Each active connection through a forward uses a file descriptor"
  echo "  and a conntrack entry — this is your rough ceiling for concurrent"
  echo "  connections, not for number of forward rules (those are cheap)."
  echo ""

  if [[ -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    local ct_max ct_count
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    echo "Connection tracking (conntrack):"
    echo "  In use:  ${ct_count}"
    echo "  Max:     ${ct_max}"
    echo "  This is the real limit on concurrent forwarded connections."
  else
    echo "Connection tracking info not available on this system"
    echo "(conntrack module may not be loaded — it loads automatically"
    echo "the first time a forward rule is used, so this is normal on"
    echo "a freshly installed VPS)."
  fi
  echo ""

  echo "Currently listening ports on this VPS (from the OS, not our rules):"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | awk 'NR==1 || NR>1{print "  "$0}' | head -n 15
  else
    echo "  (ss command not available)"
  fi
  echo "==============================================="
}

action_health_check() {
  echo ""
  echo "=========== FORWARD HEALTH CHECK ==========="
  if [[ ! -s "$FWD_DB" ]]; then
    echo "  (no forwards to check yet)"
    echo "=============================================="
    return
  fi
  printf "%-4s %-6s %-10s %-12s %-8s %-10s\n" "ID" "PROTO" "LISTEN" "SERVER" "PORT" "STATUS"
  while IFS='|' read -r id proto lport sname dport; do
    [[ -z "$id" ]] && continue
    local dip status
    dip=$(server_ip_by_name "$sname")
    if [[ -z "$dip" ]]; then
      status="NO SERVER"
    elif [[ "$proto" == "tcp" ]]; then
      if test_tcp_reachable "$dip" "$dport"; then
        status="OK"
      else
        status="NOT RESPONDING"
      fi
    else
      status="UDP (unverified)"
    fi
    printf "%-4s %-6s %-10s %-12s %-8s %-10s\n" "$id" "$proto" "$lport" "$sname" "$dport" "$status"
  done < "$FWD_DB"
  echo ""
  echo "Note: UDP can't be reliably tested with a simple connect check —"
  echo "a service being silent doesn't always mean it's down."
  echo "=============================================="
}

if [[ ! -f "$PASS_FILE" ]]; then
  setup_password
else
  check_password
fi

while true; do
  clear
  echo "=================================="
  echo "        PORT FORWARD BEAST"
  echo "=================================="
  echo "1) Connect a new server (any provider)"
  echo "2) Add port forward"
  echo "3) Bulk add port forwards"
  echo "4) List connected servers"
  echo "5) List port forwards"
  echo "6) Edit a forward"
  echo "7) Delete a forward"
  echo "8) Change password"
  echo "9) RAM / memory status"
  echo "10) Service status"
  echo "11) Restart all services"
  echo "12) Port capacity check"
  echo "13) Health check all forwards"
  echo "0) Exit"
  echo "=================================="
  read -rp "Choose an option: " choice

  case "$choice" in
    1) action_connect_server; pause ;;
    2) action_add_forward; pause ;;
    3) action_bulk_add_forward; pause ;;
    4) action_list_servers; pause ;;
    5) action_list_forwards; pause ;;
    6) action_edit_forward; pause ;;
    7) action_delete_forward; pause ;;
    8) action_change_password; pause ;;
    9) action_ram_status; pause ;;
    10) action_service_status; pause ;;
    11) action_restart_services; pause ;;
    12) action_port_capacity; pause ;;
    13) action_health_check; pause ;;
    0) echo "Bye!"; exit 0 ;;
    *) echo "Invalid option"; pause ;;
  esac
done
CLIEOF

sed -i "s#__CFG_DIR__#${CFG_DIR}#g; s#__WG_NET_PREFIX__#${WG_NET_PREFIX}#g; s#__WG_PORT__#${WG_PORT}#g; s#__JOIN_URL__#${JOIN_URL}#g" /usr/local/bin/beast
chmod +x /usr/local/bin/beast

echo ""
echo "=================================================="
echo " Setup complete. This VPS is now the hub."
echo "=================================================="
echo " Nothing is running in your face — it's all quiet"
echo " in the background (tunnel, auto-restore, RAM guard)."
echo ""
echo " Whenever you want to manage forwards, just run:"
echo "   sudo beast"
echo "=================================================="
