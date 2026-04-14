#!/usr/bin/env bash
# =============================================================================
# configure_static_ip.sh  —  v2.0
# Interactive static IPv4 configurator for Raspberry Pi OS (Debian-based)
#
# New in v2:
#   - Configure multiple interfaces in one run
#   - Sends a test/confirmation ntfy notification after each successful setup
#   - Installs a persistent connect-notifier hook so the Pi pushes its IP
#     details to your phone every time any interface connects:
#       • NetworkManager  →  /etc/NetworkManager/dispatcher.d/99-ntfy-connect.sh
#       • dhcpcd          →  /lib/dhcpcd/dhcpcd-hooks/99-ntfy-connect
#   - ntfy credentials persisted in /etc/ntfy-notify.conf (mode 600)
# =============================================================================
 
set -euo pipefail
IFS=$'\n\t'
 
# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';   GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';  BOLD='\033[1m';     RESET='\033[0m'
 
# ── Logging helpers ───────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${RESET}    $*"; }
success() { echo -e "${GREEN}[OK]${RESET}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET}   $*" >&2; }
die()     { error "$*"; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }
sep()     { echo -e "${CYAN}────────────────────────────────────────────────────${RESET}"; }
 
# ── Global state ──────────────────────────────────────────────────────────────
NETWORK_BACKEND=""   # "nm" | "dhcpcd"
ACTIVE_IFACE=""      # interface carrying the default route (first suggestion)
 
# ntfy settings (persisted to /etc/ntfy-notify.conf)
NTFY_SERVER=""
NTFY_TOPIC=""
NTFY_TOKEN=""
NTFY_CONF="/etc/ntfy-notify.conf"
 
# Accumulator for the final summary
CONFIGURED_IFACES=()
 
# =============================================================================
# §1  ROOT PRIVILEGE CHECK
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        warn "This script must be run as root."
        if command -v sudo &>/dev/null; then
            info "Relaunching with sudo…"
            exec sudo bash "$0" "$@"
            die "exec sudo failed. Please run: sudo bash $0"
        else
            die "sudo not found. Run as root: su -c 'bash $0'"
        fi
    fi
    success "Running as root."
}
 
# =============================================================================
# §2  OS VERIFICATION
# =============================================================================
verify_os() {
    banner "System Check"
    [[ -f /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" == "raspbian" || "${ID:-}" == "debian" \
          || "${ID_LIKE:-}" == *"debian"* ]]; then
        success "OS: ${PRETTY_NAME:-Debian-based}"
    else
        warn "Unexpected OS: ${PRETTY_NAME:-unknown}."
        read -rp "  Continue anyway? [y/N]: " _c
        [[ "${_c,,}" == "y" ]] || { info "Aborted."; exit 0; }
    fi
}
 
# =============================================================================
# §3  DEPENDENCY MANAGEMENT
# =============================================================================
REQUIRED_CMDS=(curl ip awk grep sed ping)
 
install_deps() {
    banner "Dependency Check"
    local -a missing=()
    declare -A PKG_MAP=(
        [curl]="curl" [ip]="iproute2" [awk]="gawk"
        [grep]="grep" [sed]="sed"     [ping]="iputils-ping"
    )
    for cmd in "${REQUIRED_CMDS[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    command -v iwgetid &>/dev/null || missing+=("iwgetid_pkg")
 
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Updating package index…"
        apt-get update -qq 2>/dev/null || warn "apt-get update had warnings."
        for cmd in "${missing[@]}"; do
            local pkg
            [[ "$cmd" == "iwgetid_pkg" ]] && pkg="wireless-tools" \
                                          || pkg="${PKG_MAP[$cmd]:-$cmd}"
            info "Installing ${pkg}…"
            apt-get install -y -qq "$pkg" 2>/dev/null \
                && success "Installed ${pkg}." \
                || warn "Could not install ${pkg} — some features may be limited."
        done
    else
        success "All core dependencies present."
    fi
    command -v nmcli &>/dev/null || command -v dhcpcd &>/dev/null \
        || die "Neither NetworkManager nor dhcpcd found."
}
 
# =============================================================================
# §4  DETECT NETWORKING BACKEND
# =============================================================================
detect_network_backend() {
    banner "Networking Backend Detection"
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NETWORK_BACKEND="nm"
        success "Active backend: NetworkManager"
        return
    fi
    if systemctl is-active --quiet dhcpcd 2>/dev/null; then
        NETWORK_BACKEND="dhcpcd"
        success "Active backend: dhcpcd"
        return
    fi
    if command -v nmcli &>/dev/null \
       && systemctl list-unit-files --quiet NetworkManager.service 2>/dev/null \
          | grep -q NetworkManager; then
        NETWORK_BACKEND="nm"
        warn "NetworkManager not active; attempting to start…"
        systemctl start NetworkManager 2>/dev/null || true
        return
    fi
    if [[ -f /etc/dhcpcd.conf ]]; then
        NETWORK_BACKEND="dhcpcd"
        warn "dhcpcd not active but config found — will use dhcpcd."
        return
    fi
    die "Cannot determine a supported networking backend."
}
 
# =============================================================================
# §5  DETECT ACTIVE INTERFACE
# =============================================================================
detect_active_interface() {
    ACTIVE_IFACE=$(ip route show default 2>/dev/null \
        | awk '/^default/ {print $5; exit}')
    if [[ -z "$ACTIVE_IFACE" ]]; then
        ACTIVE_IFACE=$(ip -o link show up 2>/dev/null \
            | awk -F': ' '$2 !~ /^lo$/ {print $2; exit}')
    fi
    [[ -n "$ACTIVE_IFACE" ]] || die "Could not detect an active network interface."
    success "Detected active interface: ${ACTIVE_IFACE}"
}
 
# =============================================================================
# §6  VALIDATION HELPERS
# =============================================================================
is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    # shellcheck disable=SC2206
    read -ra _p <<< "$ip"
    [[ ${#_p[@]} -eq 4 ]] || return 1
    local part
    for part in "${_p[@]}"; do
        [[ "$part" =~ ^[0-9]+$ ]] || return 1
        (( part >= 0 && part <= 255 )) || return 1
    done
    return 0
}
 
is_private_ipv4() {
    local ip="$1"
    local IFS='.'
    # shellcheck disable=SC2206
    read -ra o <<< "$ip"
    (( o[0] == 10 ))                               && return 0  # 10/8
    (( o[0] == 172 && o[1] >= 16 && o[1] <= 31 )) && return 0  # 172.16/12
    (( o[0] == 192 && o[1] == 168 ))               && return 0  # 192.168/16
    return 1
}
 
is_valid_prefix_len() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 8 && p <= 30 ))
}
 
prefix_to_netmask() {
    local prefix=$1 mask="" i full partial
    full=$(( prefix / 8 ))
    partial=$(( prefix % 8 ))
    for (( i=0; i<4; i++ )); do
        if   (( i < full  )); then mask+="255"
        elif (( i == full )); then mask+=$(( 256 - (1 << (8 - partial)) ))
        else                       mask+="0"
        fi
        (( i < 3 )) && mask+="."
    done
    echo "$mask"
}
 
cidr_to_network() {
    local ip="$1" prefix="$2"
    local IFS='.'
    # shellcheck disable=SC2206
    read -ra o <<< "$ip"
    local mask_int=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    local ip_int=$(( (o[0]<<24) | (o[1]<<16) | (o[2]<<8) | o[3] ))
    local n=$(( ip_int & mask_int ))
    echo "$(( (n>>24)&0xFF )).$(( (n>>16)&0xFF )).$(( (n>>8)&0xFF )).$(( n&0xFF ))"
}
 
suggest_gateway() {
    local net; net=$(cidr_to_network "$1" "$2")
    local IFS='.'
    # shellcheck disable=SC2206
    read -ra n <<< "$net"
    echo "${n[0]}.${n[1]}.${n[2]}.$(( n[3] + 1 ))"
}
 
# =============================================================================
# §7  CURRENT STATE HELPERS
# =============================================================================
get_local_ip() {
    local iface="${1:-}"
    if [[ -n "$iface" ]]; then
        ip -4 addr show "$iface" scope global 2>/dev/null \
            | grep -oP '(?<=inet )[0-9.]+' | head -1
    else
        ip -4 route get 1.1.1.1 2>/dev/null \
            | grep -oP 'src \K[0-9.]+' | head -1
    fi
}
 
get_public_ip() {
    local ip=""
    ip=$(curl -sf --max-time 6 https://api.ipify.org     2>/dev/null) \
    || ip=$(curl -sf --max-time 6 https://ifconfig.me/ip 2>/dev/null) \
    || ip=$(curl -sf --max-time 6 https://icanhazip.com  2>/dev/null) \
    || true
    echo "${ip:-unavailable}"
}
 
get_ssid() {
    local iface="$1" ssid=""
    command -v iwgetid &>/dev/null \
        && ssid=$(iwgetid -r "$iface" 2>/dev/null) || true
    if [[ -z "$ssid" ]] && command -v nmcli &>/dev/null; then
        ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null \
               | awk -F: '/^yes/{print $2; exit}') || true
    fi
    echo "$ssid"
}
 
is_wireless_iface() { [[ "$1" == wlan* || "$1" == wl* ]]; }
 
# =============================================================================
# §8  NTFY — SETTINGS COLLECTION & PERSISTENCE
# =============================================================================
collect_ntfy_settings() {
    banner "ntfy Notification Settings"
    echo "  You will receive a notification:"
    echo "    • When configuration fails (failure alert)"
    echo "    • Immediately after a successful setup (confirmation test)"
    echo "    • Every time the Pi connects to a network (persistent hook)"
    sep
 
    # Offer to reuse an existing saved config
    if [[ -f "$NTFY_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$NTFY_CONF"
        info "Found existing ntfy config in ${NTFY_CONF}:"
        echo "    Server : ${NTFY_SERVER}"
        echo "    Topic  : ${NTFY_TOPIC}"
        echo "    Token  : ${NTFY_TOKEN:+<set>}${NTFY_TOKEN:-<none>}"
        echo
        read -rp "  Reuse these settings? [Y/n]: " _reuse
        if [[ "${_reuse,,}" != "n" ]]; then
            success "Reusing saved ntfy settings."
            return
        fi
        # Reset so we prompt fresh below
        NTFY_SERVER="" NTFY_TOPIC="" NTFY_TOKEN=""
    fi
 
    read -rp "  ntfy server URL [https://ntfy.sh]: " NTFY_SERVER
    NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
    NTFY_SERVER="${NTFY_SERVER%/}"
 
    while [[ -z "$NTFY_TOPIC" ]]; do
        read -rp "  ntfy topic (required): " NTFY_TOPIC
        [[ -z "$NTFY_TOPIC" ]] && warn "Topic cannot be empty."
    done
 
    read -rp "  ntfy access token (blank if public topic): " NTFY_TOKEN
    echo
 
    info "Checking ntfy server reachability…"
    curl -sf --max-time 5 "${NTFY_SERVER}" -o /dev/null \
        && success "ntfy server is reachable." \
        || warn "Could not reach ${NTFY_SERVER}. Notifications may fail."
 
    save_ntfy_conf
}
 
save_ntfy_conf() {
    cat > "$NTFY_CONF" <<EOF
# ntfy credentials — written by configure_static_ip.sh on $(date)
# Sourced by the connect-notifier hook on every network connect.
NTFY_SERVER="${NTFY_SERVER}"
NTFY_TOPIC="${NTFY_TOPIC}"
NTFY_TOKEN="${NTFY_TOKEN}"
EOF
    chmod 600 "$NTFY_CONF"
    success "ntfy settings saved to ${NTFY_CONF} (mode 600)."
}
 
# =============================================================================
# §9  NTFY — SEND HELPERS
# =============================================================================
_ntfy_send() {
    local title="$1" body="$2" priority="${3:-default}"
    local -a h=(
        -H "Title: ${title}"
        -H "Priority: ${priority}"
        -H "Tags: computer,raspberry_pi"
    )
    [[ -n "${NTFY_TOKEN:-}" ]] && h+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    curl -sf --max-time 10 "${h[@]}" \
        -d "$body" "${NTFY_SERVER}/${NTFY_TOPIC}" &>/dev/null \
        && success "ntfy notification delivered." \
        || warn "ntfy delivery failed — check server/topic/token."
}
 
build_ip_payload() {
    local iface="$1" label="${2:-}"
    local local_ip pub_ip ssid_line=""
 
    local_ip=$(get_local_ip "$iface")
    [[ -z "$local_ip" ]] && local_ip=$(get_local_ip)
    [[ -z "$local_ip" ]] && local_ip="unknown"
    pub_ip=$(get_public_ip)
 
    if is_wireless_iface "$iface"; then
        local ssid; ssid=$(get_ssid "$iface")
        [[ -n "$ssid" ]] && ssid_line=$'\n'"SSID      : ${ssid}"
    fi
 
    printf '%s\n\nInterface : %s\nLocal IP  : %s\nPublic IP : %s%s\nTimestamp : %s\n' \
        "$label" "$iface" "$local_ip" "$pub_ip" \
        "$ssid_line" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}
 
notify_failure() {
    local reason="$1" iface="${2:-$ACTIVE_IFACE}"
    warn "Sending failure notification…"
    local body; body=$(build_ip_payload "$iface" "Reason: ${reason}")
    _ntfy_send "⚠️ RPi Static IP Failed" "$body" "high"
}
 
notify_success() {
    local iface="$1" preferred_ip="$2"
    info "Sending confirmation notification…"
    local body; body=$(build_ip_payload "$iface" \
        "✅ Static IP ${preferred_ip} applied successfully on ${iface}.")
    _ntfy_send "✅ RPi Static IP Configured" "$body" "default"
}
 
# =============================================================================
# §10  PERSISTENT CONNECT NOTIFIER
# =============================================================================
# The hook is self-contained — it sources /etc/ntfy-notify.conf at runtime
# and fires for any interface-up event, including after reboots.
 
_hook_script_content() {
    # Using 'HOOK' with no quoting so variables in the heredoc are literal
    cat <<'HOOK'
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# RPi connect notifier — auto-generated by configure_static_ip.sh
# Sends local IP, public IP, interface, and SSID (if Wi-Fi) to ntfy on connect.
#
# NetworkManager dispatcher invocation:  <iface> <event>
# dhcpcd hook invocation:                env vars $interface / $reason
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
 
NTFY_CONF="/etc/ntfy-notify.conf"
[[ -f "$NTFY_CONF" ]] || exit 0
# shellcheck source=/dev/null
source "$NTFY_CONF"
[[ -z "${NTFY_SERVER:-}" || -z "${NTFY_TOPIC:-}" ]] && exit 0
 
# ── Determine interface and event ─────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
    # NetworkManager mode: positional args
    IFACE="$1"
    EVENT="$2"
    case "$EVENT" in
        up|connectivity-change) ;;
        *) exit 0 ;;
    esac
else
    # dhcpcd mode: environment variables
    IFACE="${interface:-}"
    EVENT="${reason:-}"
    case "$EVENT" in
        BOUND|RENEW|REBIND|REBOOT|INFORM) ;;
        *) exit 0 ;;
    esac
fi
 
[[ -z "$IFACE" || "$IFACE" == "lo" ]] && exit 0
 
# ── Brief pause — let the interface fully settle ──────────────────────────────
sleep 4
 
# ── Gather IP information ─────────────────────────────────────────────────────
LOCAL_IP=$(ip -4 addr show "$IFACE" scope global 2>/dev/null \
           | grep -oP '(?<=inet )[0-9.]+' | head -1 || true)
[[ -z "$LOCAL_IP" ]] && LOCAL_IP="unknown"
 
PUB_IP=$(  curl -sf --max-time 8 https://api.ipify.org    2>/dev/null \
        || curl -sf --max-time 8 https://icanhazip.com    2>/dev/null \
        || echo "unavailable")
 
# ── SSID for wireless interfaces ─────────────────────────────────────────────
SSID_LINE=""
if [[ "$IFACE" == wlan* || "$IFACE" == wl* ]]; then
    SSID=""
    command -v iwgetid &>/dev/null \
        && SSID=$(iwgetid -r "$IFACE" 2>/dev/null) || true
    if [[ -z "$SSID" ]] && command -v nmcli &>/dev/null; then
        SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null \
               | awk -F: '/^yes/{print $2; exit}') || true
    fi
    [[ -n "$SSID" ]] && SSID_LINE=$'\n'"SSID      : ${SSID}"
fi
 
# ── Compose and send notification ─────────────────────────────────────────────
BODY="Raspberry Pi connected.
 
Interface : ${IFACE}
Local IP  : ${LOCAL_IP}
Public IP : ${PUB_IP}${SSID_LINE}
Timestamp : $(date '+%Y-%m-%d %H:%M:%S %Z')"
 
declare -a HEADERS=(
    -H "Title: 🔗 RPi Connected — ${IFACE}"
    -H "Priority: default"
    -H "Tags: computer,raspberry_pi,link"
)
[[ -n "${NTFY_TOKEN:-}" ]] && HEADERS+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
 
curl -sf --max-time 10 "${HEADERS[@]}" \
    -d "$BODY" "${NTFY_SERVER}/${NTFY_TOPIC}" &>/dev/null || true
HOOK
}
 
install_connect_notifier() {
    banner "Installing Persistent Connect Notifier"
 
    local hook_content; hook_content=$(_hook_script_content)
 
    case "$NETWORK_BACKEND" in
        nm)
            local hook_dir="/etc/NetworkManager/dispatcher.d"
            local hook_path="${hook_dir}/99-ntfy-connect.sh"
            mkdir -p "$hook_dir"
            printf '%s\n' "$hook_content" > "$hook_path"
            chmod 755 "$hook_path"
            chown root:root "$hook_path"
            success "NM dispatcher hook installed:"
            info    "  ${hook_path}"
            ;;
 
        dhcpcd)
            local hook_dir="/lib/dhcpcd/dhcpcd-hooks"
            local hook_path="${hook_dir}/99-ntfy-connect"
 
            # Fallback if standard hooks directory doesn't exist
            if [[ ! -d "$hook_dir" ]]; then
                hook_dir="/etc/dhcpcd.exit-hook.d"
                hook_path="${hook_dir}/99-ntfy-connect"
                mkdir -p "$hook_dir"
 
                # Patch /etc/dhcpcd.exit-hook to source our directory
                local exit_hook="/etc/dhcpcd.exit-hook"
                if [[ ! -f "$exit_hook" ]] \
                   || ! grep -q "dhcpcd.exit-hook.d" "$exit_hook" 2>/dev/null; then
                    {
                        echo ""
                        echo "# Source hook directory — added by configure_static_ip.sh"
                        echo 'for _f in /etc/dhcpcd.exit-hook.d/*; do'
                        echo '    [[ -x "$_f" ]] && . "$_f"'
                        echo 'done'
                        echo 'unset _f'
                    } >> "$exit_hook"
                    chmod 644 "$exit_hook"
                    info "Patched ${exit_hook} to source hook directory."
                fi
            fi
 
            printf '%s\n' "$hook_content" > "$hook_path"
            chmod 755 "$hook_path"
            chown root:root "$hook_path"
            success "dhcpcd hook installed:"
            info    "  ${hook_path}"
            ;;
    esac
 
    info "The Pi will push IP info to ntfy on every subsequent network connect."
}
 
# =============================================================================
# §11  BACKUP HELPERS
# =============================================================================
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local bak="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -- "$file" "$bak"
        info "Backed up $(basename "$file") → ${bak}"
        echo "$bak"
    fi
}
 
# =============================================================================
# §12  CONFIGURE VIA dhcpcd
# =============================================================================
configure_dhcpcd() {
    local iface="$1" ip="$2" prefix="$3" gw="$4" dns1="$5" dns2="$6"
    local conf="/etc/dhcpcd.conf"
    [[ -f "$conf" ]] || die "${conf} not found."
    backup_file "$conf" >/dev/null
 
    # Rebuild config without the old static block for this interface
    local tmp; tmp=$(mktemp /tmp/dhcpcd_XXXXXX.conf)
    awk -v i="$iface" '
        /^interface / { if ($2 == i) { skip=1; next } else skip=0 }
        !skip          { print }
    ' "$conf" > "$tmp"
 
    # Append fresh static block
    {
        printf '\n# Static IP (%s) — configure_static_ip.sh — %s\n' "$iface" "$(date)"
        printf 'interface %s\n'                          "$iface"
        printf '    static ip_address=%s/%s\n'           "$ip" "$prefix"
        printf '    static routers=%s\n'                 "$gw"
        printf '    static domain_name_servers=%s %s\n'  "$dns1" "$dns2"
    } >> "$tmp"
 
    install -m 644 "$tmp" "$conf"
    rm -f "$tmp"
    success "dhcpcd.conf updated for ${iface}."
 
    info "Restarting dhcpcd…"
    systemctl restart dhcpcd || return 1
 
    local i
    for (( i=1; i<=8; i++ )); do
        sleep 2
        [[ "$(get_local_ip "$iface")" == "$ip" ]] \
            && { success "Interface settled on ${ip}."; return 0; }
        info "Waiting for ${iface} to settle… (${i}/8)"
    done
    warn "Interface did not settle on ${ip} within timeout."
    return 1
}
 
# =============================================================================
# §13  CONFIGURE VIA NetworkManager
# =============================================================================
configure_networkmanager() {
    local iface="$1" ip="$2" prefix="$3" gw="$4" dns1="$5" dns2="$6"
    command -v nmcli &>/dev/null || die "nmcli not found."
 
    # Find an existing profile bound to this interface
    local conn_name
    conn_name=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
                | awk -F: -v d="$iface" '$2==d {print $1; exit}')
    [[ -z "$conn_name" ]] && \
    conn_name=$(nmcli -t -f NAME,DEVICE con show 2>/dev/null \
                | awk -F: -v d="$iface" '$2==d {print $1; exit}')
 
    if [[ -z "$conn_name" ]]; then
        is_wireless_iface "$iface" && \
            die "No Wi-Fi profile found for ${iface}. Connect via raspi-config first."
        conn_name="static-${iface}"
        info "Creating new NM profile '${conn_name}'…"
        nmcli con add type ethernet con-name "$conn_name" ifname "$iface" \
            ipv4.method manual ipv4.addresses "${ip}/${prefix}" \
            ipv4.gateway "$gw" ipv4.dns "${dns1} ${dns2}" \
            connection.autoconnect yes || return 1
    else
        info "Updating NM profile '${conn_name}'…"
        nmcli con mod "$conn_name" \
            ipv4.method manual ipv4.addresses "${ip}/${prefix}" \
            ipv4.gateway "$gw" ipv4.dns "${dns1} ${dns2}" \
            connection.autoconnect yes || return 1
    fi
 
    nmcli con up "$conn_name" ifname "$iface" || return 1
 
    local i
    for (( i=1; i<=8; i++ )); do
        sleep 2
        [[ "$(get_local_ip "$iface")" == "$ip" ]] \
            && { success "Interface settled on ${ip}."; return 0; }
        info "Waiting for ${iface} to settle… (${i}/8)"
    done
    warn "Interface did not acquire ${ip} within timeout."
    return 1
}
 
# =============================================================================
# §14  CONNECTIVITY TEST
# =============================================================================
test_connectivity() {
    local iface="$1" pref_ip="$2" gw="$3" dns1="$4"
    local failed=0
 
    local assigned; assigned=$(get_local_ip "$iface")
    if [[ "$assigned" == "$pref_ip" ]]; then
        success "IP matches preference: ${assigned}"
    else
        warn "IP mismatch — assigned: '${assigned:-none}' / wanted: '${pref_ip}'"
        (( failed++ ))
    fi
 
    if ping -c 3 -W 3 -I "$iface" "$gw" &>/dev/null 2>&1; then
        success "Gateway ${gw} reachable."
    else
        warn "Cannot reach gateway ${gw}."
        (( failed++ ))
    fi
 
    if ping -c 3 -W 4 "$dns1" &>/dev/null 2>&1; then
        success "Internet confirmed via ${dns1}."
    else
        warn "Cannot reach ${dns1} — no internet?"
        (( failed++ ))
    fi
 
    (( failed == 0 ))
}
 
# =============================================================================
# §15  ROLLBACK
# =============================================================================
rollback_dhcpcd() {
    local iface="$1"
    warn "Rolling back dhcpcd for ${iface}…"
    local bak; bak=$(ls -t /etc/dhcpcd.conf.bak.* 2>/dev/null | head -1)
    if [[ -n "$bak" ]]; then
        install -m 644 "$bak" /etc/dhcpcd.conf
        systemctl restart dhcpcd \
            && success "Rolled back to ${bak}." || true
    else
        warn "No backup found; commenting out static block for ${iface}."
        sed -i -E "s/^(interface ${iface}$)/# \1/" /etc/dhcpcd.conf
        sed -i -E "s/^(    static )/# \1/"         /etc/dhcpcd.conf
        systemctl restart dhcpcd || true
    fi
}
 
rollback_nm() {
    local iface="$1"
    warn "Reverting NM profile for ${iface} to DHCP…"
    local conn_name
    conn_name=$(nmcli -t -f NAME,DEVICE con show 2>/dev/null \
                | awk -F: -v d="$iface" '$2==d {print $1; exit}')
    if [[ -n "$conn_name" ]]; then
        nmcli con mod "$conn_name" \
            ipv4.method auto ipv4.addresses "" \
            ipv4.gateway "" ipv4.dns "" 2>/dev/null || true
        nmcli con up "$conn_name" ifname "$iface" &>/dev/null || true
        success "Reverted '${conn_name}' to DHCP."
    else
        warn "No profile found for ${iface}; nothing to revert."
    fi
}
 
do_rollback() {
    local iface="$1"
    case "$NETWORK_BACKEND" in
        nm)     rollback_nm     "$iface" ;;
        dhcpcd) rollback_dhcpcd "$iface" ;;
        *)      warn "Unknown backend — cannot rollback." ;;
    esac
}
 
# =============================================================================
# §16  SINGLE-INTERFACE CONFIGURATION WIZARD
#      Called in a loop from §17; uses only local variables (safe to repeat).
# =============================================================================
configure_one_interface() {
    local target_iface="" preferred_ip="" prefix_len="" gateway="" dns1="" dns2=""
 
    # ── Interface selection ───────────────────────────────────────────────────
    sep
    echo -e "\n  ${BOLD}Available interfaces (UP):${RESET}"
    ip -o link show up 2>/dev/null \
        | awk -F': ' '$2 !~ /^lo$/ {printf "    %s\n", $2}'
    echo
 
    # Suggest the first not-yet-configured interface
    local suggest="$ACTIVE_IFACE"
    local already
    for already in "${CONFIGURED_IFACES[@]:-}"; do
        [[ "$suggest" == "$already" ]] && { suggest=""; break; }
    done
 
    while true; do
        local prompt="  Interface to configure"
        [[ -n "$suggest" ]] && prompt+=" [${suggest}]"
        read -rp "${prompt}: " target_iface
        target_iface="${target_iface:-$suggest}"
        [[ -z "$target_iface" ]] && { warn "Interface name cannot be empty."; continue; }
        ip link show "$target_iface" &>/dev/null && break
        warn "Interface '${target_iface}' not found. Try again."
    done
 
    # Warn if being reconfigured this session
    for already in "${CONFIGURED_IFACES[@]:-}"; do
        [[ "$target_iface" == "$already" ]] && \
            warn "${target_iface} was already configured this run — will overwrite."
    done
 
    # ── Show current state ────────────────────────────────────────────────────
    local cur_ip cur_prefix cur_gw
    cur_ip=$(get_local_ip "$target_iface")
    cur_prefix=$(ip -4 addr show "$target_iface" 2>/dev/null \
                 | grep -oP '(?<=inet )[0-9.]+/\K[0-9]+' | head -1)
    cur_gw=$(ip route show default dev "$target_iface" 2>/dev/null \
             | awk '/^default/ {print $3; exit}')
 
    info "Current state on ${target_iface}:"
    echo "    IP     : ${cur_ip:-none}"
    echo "    Prefix : ${cur_prefix:-unknown}"
    echo "    GW     : ${cur_gw:-unknown}"
    is_wireless_iface "$target_iface" && \
        echo "    SSID   : $(get_ssid "$target_iface")"
    echo
 
    # ── Preferred static IP ───────────────────────────────────────────────────
    while true; do
        read -rp "  Preferred static IPv4 address: " preferred_ip
        preferred_ip="${preferred_ip// /}"
        is_valid_ipv4 "$preferred_ip"   || { warn "Invalid IPv4 format."; continue; }
        is_private_ipv4 "$preferred_ip" || \
            { warn "Must be RFC-1918 private (10/8, 172.16/12, 192.168/16)."; continue; }
        break
    done
 
    # ── Subnet prefix length ──────────────────────────────────────────────────
    local def_prefix="${cur_prefix:-24}"
    while true; do
        read -rp "  Subnet prefix length [${def_prefix}]: " prefix_len
        prefix_len="${prefix_len:-$def_prefix}"
        is_valid_prefix_len "$prefix_len" && break
        warn "Prefix must be an integer between 8 and 30."
    done
 
    # ── Gateway ───────────────────────────────────────────────────────────────
    local def_gw="${cur_gw:-$(suggest_gateway "$preferred_ip" "$prefix_len")}"
    while true; do
        read -rp "  Default gateway [${def_gw}]: " gateway
        gateway="${gateway:-$def_gw}"
        gateway="${gateway// /}"
        is_valid_ipv4 "$gateway" && break
        warn "Not a valid IPv4 address."
    done
 
    # ── DNS ───────────────────────────────────────────────────────────────────
    read -rp "  Primary DNS   [1.1.1.1]: " dns1
    dns1="${dns1:-1.1.1.1}"
    is_valid_ipv4 "$dns1" || { warn "Invalid — defaulting to 1.1.1.1"; dns1="1.1.1.1"; }
 
    read -rp "  Secondary DNS [8.8.8.8]: " dns2
    dns2="${dns2:-8.8.8.8}"
    is_valid_ipv4 "$dns2" || { warn "Invalid — defaulting to 8.8.8.8"; dns2="8.8.8.8"; }
 
    # ── Confirmation summary ──────────────────────────────────────────────────
    echo
    sep
    echo -e "  ${BOLD}Summary — ${target_iface}${RESET}"
    sep
    echo "  Interface   : ${target_iface}"
    echo "  Static IP   : ${preferred_ip}/${prefix_len}"
    echo "  Netmask     : $(prefix_to_netmask "$prefix_len")"
    echo "  Gateway     : ${gateway}"
    echo "  DNS         : ${dns1},  ${dns2}"
    sep
    local confirm
    read -rp "  Apply this configuration? [Y/n]: " confirm
    [[ "${confirm,,}" == "n" ]] && { info "Skipped ${target_iface}."; return; }
 
    # ── Apply configuration ───────────────────────────────────────────────────
    banner "Applying — ${target_iface}"
    local apply_ok=0
    case "$NETWORK_BACKEND" in
        nm)
            configure_networkmanager \
                "$target_iface" "$preferred_ip" "$prefix_len" \
                "$gateway" "$dns1" "$dns2" && apply_ok=1 || true
            ;;
        dhcpcd)
            configure_dhcpcd \
                "$target_iface" "$preferred_ip" "$prefix_len" \
                "$gateway" "$dns1" "$dns2" && apply_ok=1 || true
            ;;
    esac
 
    if (( apply_ok == 0 )); then
        error "Failed to apply configuration for ${target_iface}."
        notify_failure \
            "Backend (${NETWORK_BACKEND}) failed to configure ${target_iface}." \
            "$target_iface"
        do_rollback "$target_iface"
        warn "Rolled back ${target_iface}. Moving on…"
        return
    fi
 
    # ── Connectivity check ────────────────────────────────────────────────────
    if ! test_connectivity "$target_iface" "$preferred_ip" "$gateway" "$dns1"; then
        error "Connectivity check failed for ${target_iface}."
        notify_failure \
            "IP applied but connectivity check failed on ${target_iface}." \
            "$target_iface"
        do_rollback "$target_iface"
        warn "Rolled back ${target_iface}. Moving on…"
        return
    fi
 
    # ── All good: send confirmation notification ──────────────────────────────
    notify_success "$target_iface" "$preferred_ip"
    CONFIGURED_IFACES+=("$target_iface")
    success "${target_iface} → ${preferred_ip}/${prefix_len} ✓"
}
 
# =============================================================================
# §17  MULTI-INTERFACE CONFIGURATION LOOP
# =============================================================================
configure_interfaces_loop() {
    banner "Interface Configuration"
    while true; do
        configure_one_interface
        echo
        sep
        local more
        read -rp "  Configure another interface? [y/N]: " more
        [[ "${more,,}" == "y" ]] || break
        echo
    done
}
 
# =============================================================================
# §18  FINAL SUMMARY
# =============================================================================
print_summary() {
    banner "Session Summary"
    sep
    if [[ ${#CONFIGURED_IFACES[@]} -eq 0 ]]; then
        warn "No interfaces were successfully configured this session."
    else
        echo -e "  ${BOLD}${GREEN}Successfully configured:${RESET}"
        local iface ip
        for iface in "${CONFIGURED_IFACES[@]}"; do
            ip=$(get_local_ip "$iface")
            printf '    %-12s  →  %s\n' "$iface" "${ip:-unknown}"
        done
    fi
    sep
    echo "  ntfy config      : ${NTFY_CONF}"
    case "$NETWORK_BACKEND" in
        nm)
            echo "  Connect notifier : /etc/NetworkManager/dispatcher.d/99-ntfy-connect.sh"
            ;;
        dhcpcd)
            echo "  Connect notifier : /lib/dhcpcd/dhcpcd-hooks/99-ntfy-connect"
            ;;
    esac
    sep
    echo
    info "Static IPs are persistent across reboots."
    info "ntfy push will fire on every subsequent network connect."
    echo
}
 
# =============================================================================
# §19  MAIN
# =============================================================================
main() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║       Raspberry Pi OS — Static IP Configurator  v2.0             ║"
    echo "║                  Made by IamSboby(GitHub)                        ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
 
    check_root "$@"
    verify_os
    install_deps
    detect_network_backend
    detect_active_interface
 
    # Collect ntfy settings up front — needed for failure notifications too
    collect_ntfy_settings
 
    # Configure one or more interfaces
    configure_interfaces_loop
 
    # Install the hook that fires on every future network connect
    install_connect_notifier
 
    print_summary
}
 
main "$@"