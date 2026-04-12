#!/usr/bin/env bash
# ==============================================================================
# Raspberry Pi OS Lite — Smart Network Manager with AP Fallback
# Interactive Installer · v1.0
# ==============================================================================
# Run as root:  sudo bash netmanager-install.sh
# Compatible:   Raspberry Pi OS Lite Bookworm (Debian 12) + NetworkManager
#
# What this installer sets up:
#   • /etc/netmanager/netmanager.conf     — runtime configuration (all values
#                                           collected interactively; nothing is
#                                           hard-coded in the generated scripts)
#   • /usr/local/bin/netmanager.sh        — boot-time daemon (systemd service)
#   • /usr/local/bin/wifi-provision.sh    — SSH setup wizard for WiFi
#   • /etc/systemd/system/netmanager.service
#   • /etc/update-motd.d/99-netmanager    — login banner over fallback AP
#   • A persistent NetworkManager AP connection profile
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Colour palette ─────────────────────────────────────────────────────────────
RED=$'\033[0;31m'   GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'  CYAN=$'\033[0;36m'   BOLD=$'\033[1m'       NC=$'\033[0m'

# ── Fixed installation paths (constants shared with generated scripts) ─────────
CONFIG_DIR="/etc/netmanager"
CONFIG_FILE="/etc/netmanager/netmanager.conf"
STATE_FILE="/etc/netmanager/current-mode"
NM_SCRIPT="/usr/local/bin/netmanager.sh"
PROVISION_SCRIPT="/usr/local/bin/wifi-provision.sh"
SERVICE_FILE="/etc/systemd/system/netmanager.service"
MOTD_SCRIPT="/etc/update-motd.d/99-netmanager"

# ── Pretty-print helpers ───────────────────────────────────────────────────────
info()   { printf '%b[INFO]%b  %s\n'  "$BLUE"   "$NC" "$*"; }
ok()     { printf '%b[OK]%b    %s\n'  "$GREEN"  "$NC" "$*"; }
warn()   { printf '%b[WARN]%b  %s\n'  "$YELLOW" "$NC" "$*"; }
err()    { printf '%b[ERROR]%b %s\n'  "$RED"    "$NC" "$*"; }
header() {
    printf '\n%b══════════════════════════════════════════════════%b\n' "$CYAN$BOLD" "$NC"
    printf '%b  %s%b\n' "$CYAN$BOLD" "$*" "$NC"
    printf '%b══════════════════════════════════════════════════%b\n\n' "$CYAN$BOLD" "$NC"
}

# ── Interactive prompt helpers ─────────────────────────────────────────────────

# ask VAR_NAME "Question" "default"  – stores answer in VAR_NAME
ask() {
    local _var="$1" _q="$2" _def="${3-}" _inp
    while true; do
        if [[ -n "$_def" ]]; then
            printf '%b▶%b %s [%s]: ' "$YELLOW" "$NC" "$_q" "$_def"
        else
            printf '%b▶%b %s: ' "$YELLOW" "$NC" "$_q"
        fi
        read -r _inp
        [[ -z "$_inp" && -n "$_def" ]] && _inp="$_def"
        if [[ -n "$_inp" ]]; then
            printf -v "$_var" '%s' "$_inp"
            return
        fi
        warn "This field is required."
    done
}

# ask_secret VAR_NAME "Question" min_length
ask_secret() {
    local _var="$1" _q="$2" _min="${3:-8}" _inp
    while true; do
        printf '%b▶%b %s (hidden, min %s chars): ' "$YELLOW" "$NC" "$_q" "$_min"
        read -rs _inp; echo
        if (( ${#_inp} >= _min )); then
            printf -v "$_var" '%s' "$_inp"
            return
        fi
        warn "Must be at least $_min characters."
    done
}

# ask_int VAR_NAME "Question" default min max
ask_int() {
    local _var="$1" _q="$2" _def="$3" _min="${4:-1}" _max="${5:-999999}" _inp
    while true; do
        printf '%b▶%b %s [%s]: ' "$YELLOW" "$NC" "$_q" "$_def"
        read -r _inp
        [[ -z "$_inp" ]] && _inp="$_def"
        if [[ "$_inp" =~ ^[0-9]+$ ]] && (( _inp >= _min && _inp <= _max )); then
            printf -v "$_var" '%s' "$_inp"
            return
        fi
        warn "Please enter an integer between $_min and $_max."
    done
}

# confirm "Question" [y|n]  – returns 0 for yes, 1 for no
confirm() {
    local _q="$1" _def="${2:-y}" _inp _hint
    [[ "$_def" == "y" ]] && _hint="[Y/n]" || _hint="[y/N]"
    printf '%b▶%b %s %s: ' "$YELLOW" "$NC" "$_q" "$_hint"
    read -r _inp
    _inp="${_inp:-$_def}"
    [[ "$_inp" =~ ^[Yy]$ ]]
}

# ── Root guard ─────────────────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] && return
    err "Must be run as root.  Use:  sudo bash $0"
    exit 1
}

# ── Auto-detect network interfaces ────────────────────────────────────────────
detect_interfaces() {
    ETH_CANDIDATES=()
    WIFI_CANDIDATES=()
    while IFS= read -r iface; do
        [[ -n "$iface" ]] && ETH_CANDIDATES+=("$iface")
    done < <(ip -o link show \
        | awk -F': ' '{print $2}' \
        | grep -E '^(eth|en|eno|enp|ens)[0-9]' \
        | grep -v '@' || true)

    for d in /sys/class/net/*/; do
        local name; name=$(basename "$d")
        [[ -d "$d/wireless" ]] && WIFI_CANDIDATES+=("$name")
    done
}

# ── Prerequisite check/install ─────────────────────────────────────────────────
check_prerequisites() {
    header "Checking Prerequisites"

    # NetworkManager
    if ! command -v nmcli &>/dev/null; then
        warn "NetworkManager not found – installing …"
        apt-get update -qq
        apt-get install -y -qq network-manager
        systemctl enable NetworkManager
        systemctl start NetworkManager
        sleep 4
    fi
    ok "NetworkManager: $(nmcli --version 2>/dev/null | head -1)"

    # Ensure NM is managing wireless (disable wpa_supplicant standalone if present)
    if systemctl is-active --quiet wpa_supplicant 2>/dev/null; then
        warn "Stopping standalone wpa_supplicant (NM manages it)"
        systemctl stop wpa_supplicant 2>/dev/null || true
        systemctl disable wpa_supplicant 2>/dev/null || true
    fi

    # openssh-server
    if ! systemctl is-active --quiet ssh 2>/dev/null \
       && ! systemctl is-active --quiet sshd 2>/dev/null; then
        warn "SSH server not active – installing …"
        apt-get install -y -qq openssh-server
        systemctl enable ssh
        systemctl start ssh
    fi
    ok "SSH server active"

    # iw (WiFi scan utility)
    if ! command -v iw &>/dev/null; then
        info "Installing iw …"
        apt-get install -y -qq iw
    fi
    ok "iw available"

    # Ensure NM is running
    if ! systemctl is-active --quiet NetworkManager; then
        systemctl start NetworkManager
        sleep 3
    fi
    ok "NetworkManager daemon running"
}

# ── Interactive configuration collection ──────────────────────────────────────
collect_config() {
    # ── Interfaces ────────────────────────────────────────────────────────────
    header "Network Interface Configuration"
    detect_interfaces

    if [[ ${#ETH_CANDIDATES[@]} -gt 0 ]]; then
        info "Detected Ethernet interface(s): ${ETH_CANDIDATES[*]}"
        ask ETH_INTERFACE "Ethernet interface name" "${ETH_CANDIDATES[0]}"
    else
        warn "No Ethernet interface auto-detected."
        ask ETH_INTERFACE "Ethernet interface name (e.g. eth0)" "eth0"
    fi

    if [[ ${#WIFI_CANDIDATES[@]} -gt 0 ]]; then
        info "Detected WiFi interface(s): ${WIFI_CANDIDATES[*]}"
        ask WIFI_INTERFACE "WiFi interface name" "${WIFI_CANDIDATES[0]}"
    else
        warn "No WiFi interface auto-detected."
        ask WIFI_INTERFACE "WiFi interface name (e.g. wlan0)" "wlan0"
    fi

    # ── Fallback Access Point ─────────────────────────────────────────────────
    header "Fallback Access Point Configuration"
    cat <<'INFO'
  This AP is created automatically when neither Ethernet nor a configured
  WiFi network is available.  Clients connect to it, SSH in, and run the
  WiFi provisioning wizard.
INFO
    echo
    ask AP_SSID     "Fallback AP network name (SSID)"  "PiSetup"

    echo
    warn "Security: an open AP lets anyone nearby connect and attempt SSH."
    warn "A password limits access but you must remember it to connect later."
    echo
    if confirm "Protect the fallback AP with a WPA2 password?" y; then
        ask_secret AP_PASSWORD "Fallback AP password (min 8 chars)" 8
        AP_SECURED="yes"
    else
        AP_PASSWORD=""
        AP_SECURED="no"
        warn "Fallback AP will be open (no password). Make sure SSH is secured."
    fi

    ask    AP_IP      "Fallback AP IP address for this Pi" "192.168.4.1"
    ask_int AP_CHANNEL "WiFi channel (1–13)"               6  1 13

    # ── Connectivity & Timing ─────────────────────────────────────────────────
    header "Connectivity & Timing Settings"

    ask     CONNECTIVITY_HOST     "Host to ping for connectivity test"  "1.1.1.1"
    ask_int CONNECTIVITY_TIMEOUT  "Ping timeout in seconds"              5   1  30
    ask_int CONNECTIVITY_RETRIES  "Ping attempts before declaring failure" 3  1  10
    ask_int CHECK_INTERVAL        "Seconds between network checks"        30  5 3600
    ask_int SWITCH_DELAY          "Stability delay (s) before switching mode" 5 1 60
    ask_int DHCP_WAIT             "Max seconds to wait for DHCP lease"   20  5 120

    # ── SSH ───────────────────────────────────────────────────────────────────
    header "SSH & User Settings"
    ask_int SSH_PORT    "SSH port"                     22   1 65535
    ask     AP_SSH_USER "Username to SSH in via the fallback AP" "pi"

    # ── NM connection name ────────────────────────────────────────────────────
    header "NetworkManager Profile Name"
    info "Internal name used by NetworkManager for the fallback AP connection."
    ask AP_CON_NAME "NM connection name for fallback AP" "netmanager-ap"

    # ── Log ───────────────────────────────────────────────────────────────────
    header "Log Settings"
    ask_int LOG_MAXSIZE_MB "Max log size in MB before rotation" 10 1 500
}

# ── Summary & confirmation ─────────────────────────────────────────────────────
confirm_config() {
    header "Configuration Summary"
    printf '  %-30s %s\n' "Ethernet interface:"    "$ETH_INTERFACE"
    printf '  %-30s %s\n' "WiFi interface:"        "$WIFI_INTERFACE"
    printf '  %-30s %s\n' "Fallback AP SSID:"      "$AP_SSID"
    if [[ "$AP_SECURED" == "yes" ]]; then
        printf '  %-30s %s\n' "Fallback AP security:"  "WPA2 (password set)"
    else
        printf '  %-30s %s\n' "Fallback AP security:"  "OPEN (no password)"
    fi
    printf '  %-30s %s\n' "Fallback AP IP:"        "$AP_IP"
    printf '  %-30s %s\n' "AP WiFi channel:"       "$AP_CHANNEL"
    printf '  %-30s %s\n' "Connectivity host:"     "$CONNECTIVITY_HOST"
    printf '  %-30s %s\n' "Ping timeout / retries:" "${CONNECTIVITY_TIMEOUT}s / ${CONNECTIVITY_RETRIES}x"
    printf '  %-30s %s\n' "Check interval:"        "${CHECK_INTERVAL}s"
    printf '  %-30s %s\n' "Switch stability delay:" "${SWITCH_DELAY}s"
    printf '  %-30s %s\n' "DHCP wait:"             "${DHCP_WAIT}s"
    printf '  %-30s %s\n' "SSH port:"              "$SSH_PORT"
    printf '  %-30s %s\n' "AP SSH user hint:"      "$AP_SSH_USER"
    printf '  %-30s %s\n' "NM AP profile name:"    "$AP_CON_NAME"
    printf '  %-30s %s\n' "Log max size:"          "${LOG_MAXSIZE_MB} MB"
    echo
    confirm "Proceed with installation?" y || { echo "Aborted."; exit 0; }
}

# ── Write configuration file ───────────────────────────────────────────────────
write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << CONF
# ============================================================
# Raspberry Pi Network Manager — Configuration
# Generated: $(date)
# Edit values here; restart the service to apply changes.
# ============================================================

ETH_INTERFACE="${ETH_INTERFACE}"
WIFI_INTERFACE="${WIFI_INTERFACE}"

AP_SSID="${AP_SSID}"
AP_PASSWORD="${AP_PASSWORD}"
AP_IP="${AP_IP}"
AP_CHANNEL="${AP_CHANNEL}"
AP_CON_NAME="${AP_CON_NAME}"
AP_SSH_USER="${AP_SSH_USER}"

SSH_PORT="${SSH_PORT}"

CONNECTIVITY_HOST="${CONNECTIVITY_HOST}"
CONNECTIVITY_TIMEOUT="${CONNECTIVITY_TIMEOUT}"
CONNECTIVITY_RETRIES="${CONNECTIVITY_RETRIES}"

CHECK_INTERVAL="${CHECK_INTERVAL}"
SWITCH_DELAY="${SWITCH_DELAY}"
DHCP_WAIT="${DHCP_WAIT}"

LOG_FILE="/var/log/netmanager.log"
LOG_MAXSIZE_MB="${LOG_MAXSIZE_MB}"

AP_SECURED="${AP_SECURED}"

CONFIG_DIR="/etc/netmanager"
STATE_FILE="/etc/netmanager/current-mode"
CONF
    # Only store password if one was set
    if [[ "$AP_SECURED" == "no" ]]; then
        chmod 644 "$CONFIG_FILE"   # no secret to protect
    else
        chmod 600 "$CONFIG_FILE"   # protects AP password
    fi
    ok "Config written → $CONFIG_FILE"
}

# ── Generate /usr/local/bin/netmanager.sh ─────────────────────────────────────
write_netmanager_script() {
cat > "$NM_SCRIPT" << 'NETMANAGER_EOF'
#!/usr/bin/env bash
# ==============================================================================
# netmanager.sh — Boot-time network manager daemon for Raspberry Pi OS Lite
# Managed by: netmanager.service (systemd)
# Do NOT edit this file — re-run netmanager-install.sh to reconfigure.
# ==============================================================================
set -uo pipefail

CONFIG_FILE="/etc/netmanager/netmanager.conf"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

CURRENT_MODE=""    # ethernet | wifi | ap | ""

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return
    local size_mb
    size_mb=$(( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) / 1048576 ))
    if (( size_mb >= LOG_MAXSIZE_MB )); then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "Log rotated (was ${size_mb} MB)"
    fi
}

set_state() {
    CURRENT_MODE="$1"
    echo "$1" > "$STATE_FILE"
}

# ── Ethernet checks ───────────────────────────────────────────────────────────

# True if Ethernet cable is physically connected (carrier present)
eth_has_carrier() {
    local carrier
    carrier=$(cat "/sys/class/net/${ETH_INTERFACE}/carrier" 2>/dev/null) || return 1
    [[ "$carrier" == "1" ]]
}

# Wait up to DHCP_WAIT seconds for an IP on the given interface
wait_for_ip() {
    local iface="$1" elapsed=0
    while ! ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; do
        sleep 1
        (( elapsed++ ))
        (( elapsed >= DHCP_WAIT )) && return 1
    done
    return 0
}

# True if interface has an IPv4 address
iface_has_ip() {
    ip -4 addr show "$1" 2>/dev/null | grep -q "inet "
}

# Ping test through a specific interface (retries)
ping_via() {
    local iface="$1"
    for _ in $(seq 1 "$CONNECTIVITY_RETRIES"); do
        ping -c 1 -W "$CONNECTIVITY_TIMEOUT" -I "$iface" "$CONNECTIVITY_HOST" &>/dev/null \
            && return 0
        sleep 1
    done
    return 1
}

# Generic ping (follows default route)
ping_generic() {
    for _ in $(seq 1 "$CONNECTIVITY_RETRIES"); do
        ping -c 1 -W "$CONNECTIVITY_TIMEOUT" "$CONNECTIVITY_HOST" &>/dev/null && return 0
        sleep 1
    done
    return 1
}

# Full Ethernet connectivity check
eth_is_connected() {
    eth_has_carrier || return 1
    # Ask NM to bring up the wired interface if not already managed
    if ! nmcli -t -f DEVICE connection show --active 2>/dev/null \
            | grep -q "^${ETH_INTERFACE}$"; then
        nmcli device connect "$ETH_INTERFACE" &>/dev/null || true
        wait_for_ip "$ETH_INTERFACE" || return 1
    fi
    iface_has_ip "$ETH_INTERFACE" || return 1
    ping_via "$ETH_INTERFACE"
}

# ── WiFi checks ───────────────────────────────────────────────────────────────

wifi_is_connected() {
    # NM reports the WiFi device as 'connected' (state 100)
    local state
    state=$(nmcli -t -f GENERAL.STATE device show "$WIFI_INTERFACE" 2>/dev/null \
        | cut -d: -f2 | head -1)
    [[ "$state" =~ ^100 ]] || return 1
    iface_has_ip "$WIFI_INTERFACE" || return 1
    ping_via "$WIFI_INTERFACE"
}

# ── Ethernet route priority ───────────────────────────────────────────────────
prioritize_ethernet() {
    # Lower metric = higher priority for routing
    local eth_con
    eth_con=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | grep ":${ETH_INTERFACE}$" | cut -d: -f1 | head -1)
    if [[ -n "$eth_con" ]]; then
        nmcli connection modify "$eth_con" ipv4.route-metric 10 &>/dev/null || true
        nmcli connection modify "$eth_con" ipv6.route-metric 10 &>/dev/null || true
    fi

    local wifi_con
    wifi_con=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | grep ":${WIFI_INTERFACE}$" | cut -d: -f1 | head -1)
    if [[ -n "$wifi_con" ]]; then
        nmcli connection modify "$wifi_con" ipv4.route-metric 200 &>/dev/null || true
    fi
}

# ── AP management ─────────────────────────────────────────────────────────────
ap_is_active() {
    nmcli -t -f NAME connection show --active 2>/dev/null \
        | grep -q "^${AP_CON_NAME}$"
}

start_ap() {
    log "Starting fallback AP '$AP_SSID' …"
    rfkill unblock wifi 2>/dev/null || true

    # Disconnect any active WiFi client session on the interface
    if nmcli -t -f DEVICE connection show --active 2>/dev/null \
            | grep -q "^${WIFI_INTERFACE}$"; then
        nmcli device disconnect "$WIFI_INTERFACE" &>/dev/null || true
        sleep 2
    fi

    sleep "$SWITCH_DELAY"

    if nmcli connection up "$AP_CON_NAME" &>/dev/null; then
        log "Fallback AP active · SSID='${AP_SSID}' · IP=${AP_IP}"
        log "  → SSH: ${AP_SSH_USER}@${AP_IP} -p ${SSH_PORT}"
        log "  → Then run: sudo wifi-provision.sh"
        set_state "ap"
        return 0
    else
        log "ERROR: Failed to bring up AP profile '${AP_CON_NAME}'"
        return 1
    fi
}

stop_ap() {
    if ap_is_active; then
        log "Stopping fallback AP …"
        nmcli connection down "$AP_CON_NAME" &>/dev/null || true
        sleep 2
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
main() {
    log "========================================"
    log "netmanager.sh starting"
    log "  ETH:  ${ETH_INTERFACE}  |  WiFi: ${WIFI_INTERFACE}"
    log "  Check interval: ${CHECK_INTERVAL}s"
    log "========================================"

    mkdir -p "$CONFIG_DIR"
    set_state "init"

    # Brief boot grace period — let NM settle after startup
    sleep 5

    while true; do
        rotate_log

        # ── Priority 1: Ethernet ─────────────────────────────────────────────
        if eth_is_connected; then
            if [[ "$CURRENT_MODE" != "ethernet" ]]; then
                log "Ethernet available — switching to Ethernet mode"
                stop_ap
                sleep "$SWITCH_DELAY"
                prioritize_ethernet
                set_state "ethernet"
                log "Now using Ethernet (${ETH_INTERFACE})"
            fi
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Ethernet not available ─────────────────────────────────────────────

        # ── Priority 2: WiFi (only when not in AP mode) ──────────────────────
        # When wlan0 is in AP mode we cannot simultaneously run a WiFi client
        # on the same radio.  WiFi reconnection is handled by wifi-provision.sh.
        if [[ "$CURRENT_MODE" != "ap" ]]; then
            if wifi_is_connected; then
                if [[ "$CURRENT_MODE" != "wifi" ]]; then
                    log "WiFi connected — using WiFi (${WIFI_INTERFACE})"
                    set_state "wifi"
                fi
                sleep "$CHECK_INTERVAL"
                continue
            fi
        fi

        # ── Priority 3: Fallback AP ──────────────────────────────────────────
        if [[ "$CURRENT_MODE" != "ap" ]]; then
            log "No usable network found — activating fallback AP"
            if start_ap; then
                set_state "ap"
            else
                log "WARNING: AP start failed; will retry in ${CHECK_INTERVAL}s"
            fi
        fi
        # While in AP mode only Ethernet can auto-recover (WiFi recovery needs
        # user interaction via wifi-provision.sh over SSH).

        sleep "$CHECK_INTERVAL"
    done
}

main
NETMANAGER_EOF

    chmod +x "$NM_SCRIPT"
    ok "Network manager daemon written → $NM_SCRIPT"
}

# ── Generate /usr/local/bin/wifi-provision.sh ─────────────────────────────────
write_provision_script() {
cat > "$PROVISION_SCRIPT" << 'PROVISION_EOF'
#!/usr/bin/env bash
# ==============================================================================
# wifi-provision.sh — Interactive WiFi Setup Wizard
# Run via SSH while connected to the fallback AP:
#   ssh <user>@<AP_IP>  then  sudo wifi-provision.sh
# ==============================================================================
set -uo pipefail

CONFIG_FILE="/etc/netmanager/netmanager.conf"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

RED=$'\033[0;31m'   GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'  CYAN=$'\033[0;36m'   BOLD=$'\033[1m'      NC=$'\033[0m'

info()   { printf '%b[INFO]%b  %s\n'  "$BLUE"   "$NC" "$*"; }
ok()     { printf '%b[OK]%b    %s\n'  "$GREEN"  "$NC" "$*"; }
warn()   { printf '%b[WARN]%b  %s\n'  "$YELLOW" "$NC" "$*"; }
err()    { printf '%b[ERROR]%b %s\n'  "$RED"    "$NC" "$*" >&2; }
header() {
    printf '\n%b══════════════════════════════════════════════════%b\n' "$CYAN$BOLD" "$NC"
    printf '%b  %s%b\n' "$CYAN$BOLD" "$*" "$NC"
    printf '%b══════════════════════════════════════════════════%b\n\n' "$CYAN$BOLD" "$NC"
}
ask_input() {
    local _v="$1" _q="$2" _def="${3-}" _i
    while true; do
        [[ -n "$_def" ]] \
            && printf '%b▶%b %s [%s]: ' "$YELLOW" "$NC" "$_q" "$_def" \
            || printf '%b▶%b %s: '       "$YELLOW" "$NC" "$_q"
        read -r _i
        [[ -z "$_i" && -n "$_def" ]] && _i="$_def"
        [[ -n "$_i" ]] && { printf -v "$_v" '%s' "$_i"; return; }
        warn "This field is required."
    done
}
ask_secret_input() {
    local _v="$1" _q="$2" _min="${3:-8}" _i
    while true; do
        printf '%b▶%b %s (hidden, min %s chars): ' "$YELLOW" "$NC" "$_q" "$_min"
        read -rs _i; echo
        (( ${#_i} >= _min )) && { printf -v "$_v" '%s' "$_i"; return; }
        warn "Must be at least $_min characters."
    done
}
confirm_yn() {
    local _q="$1" _def="${2:-y}" _i _hint
    [[ "$_def" == "y" ]] && _hint="[Y/n]" || _hint="[y/N]"
    printf '%b▶%b %s %s: ' "$YELLOW" "$NC" "$_q" "$_hint"
    read -r _i; _i="${_i:-$_def}"
    [[ "$_i" =~ ^[Yy]$ ]]
}

# ── Root guard ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { err "Run with sudo or as root."; exit 1; }

# ── Scan for WiFi networks ────────────────────────────────────────────────────
scan_networks() {
    info "Scanning for available WiFi networks (this takes a few seconds) …"
    # Trigger active scan
    nmcli device wifi rescan ifname "$WIFI_INTERFACE" 2>/dev/null || true
    sleep 4

    # Collect SSIDs: de-duplicate, sort by signal strength
    mapfile -t RAW < <(
        nmcli --color no -t -f SSID,SIGNAL,SECURITY \
            device wifi list ifname "$WIFI_INTERFACE" 2>/dev/null \
        | grep -v '^:' \
        | awk -F: '
            $1 != "" {
                key = $1
                if (!(key in seen) || $2+0 > seen_sig[key]+0) {
                    seen[key] = $0
                    seen_sig[key] = $2
                }
            }
            END { for (k in seen) print seen[k] }
        ' \
        | sort -t: -k2 -rn \
        | head -20
    )
}

# ── Display and choose network ─────────────────────────────────────────────────
choose_network() {
    local selected_ssid="" selected_security="" choice

    scan_networks

    if [[ ${#RAW[@]} -eq 0 ]]; then
        warn "No networks found.  You can enter an SSID manually."
    else
        echo
        printf '  %3s  %-34s  %6s  %s\n' "No." "SSID" "Signal" "Security"
        printf '  %s\n' "$(printf '─%.0s' {1..60})"
        for i in "${!RAW[@]}"; do
            IFS=':' read -r ssid signal security <<< "${RAW[$i]}"
            printf '  [%2d] %-34s  %5s%%  %s\n' \
                "$((i+1))" "${ssid:0:34}" "$signal" "${security:-Open}"
        done
    fi
    echo
    printf '  [ 0] Enter SSID manually\n\n'

    while true; do
        printf '%b▶%b Select network [0-%s]: ' "$YELLOW" "$NC" "${#RAW[@]}"
        read -r choice
        if [[ "$choice" == "0" ]]; then
            ask_input selected_ssid "Enter SSID"
            selected_security="WPA"
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] \
             && (( choice >= 1 && choice <= ${#RAW[@]} )); then
            IFS=':' read -r selected_ssid _ selected_security <<< "${RAW[$((choice-1))]}"
            break
        fi
        warn "Please enter a number between 0 and ${#RAW[@]}."
    done

    CHOSEN_SSID="$selected_ssid"
    CHOSEN_SECURITY="$selected_security"
}

# ── Check for existing NM profiles ────────────────────────────────────────────
find_existing_profile() {
    local ssid="$1"
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | grep "802-11-wireless" \
        | while IFS=: read -r name _type; do
            local stored
            stored=$(nmcli -t -f 802-11-wireless.ssid connection show "$name" 2>/dev/null \
                | cut -d: -f2)
            [[ "$stored" == "$ssid" ]] && echo "$name" && break
        done
}

# ── Add / update NM WiFi profile ──────────────────────────────────────────────
configure_wifi_profile() {
    local ssid="$1" password="$2"
    local con_name="wifi-$(echo "$ssid" | tr -cd '[:alnum:]-_' | cut -c1-30)"

    # Remove old profile for this SSID if it exists
    local existing
    existing=$(find_existing_profile "$ssid")
    if [[ -n "$existing" ]]; then
        info "Removing outdated profile '$existing' …"
        nmcli connection delete "$existing" &>/dev/null || true
    fi

    info "Creating NM connection profile '$con_name' …"
    if nmcli connection add \
            type wifi \
            ifname "$WIFI_INTERFACE" \
            con-name "$con_name" \
            ssid "$ssid" \
            connection.autoconnect yes \
            ipv4.method auto \
            ipv4.route-metric 100 \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$password" &>/dev/null; then
        ok "Profile created"
        echo "$con_name"
    else
        err "Failed to create NM profile"
        echo ""
    fi
}

# ── Open / unsecured network ──────────────────────────────────────────────────
configure_open_wifi_profile() {
    local ssid="$1"
    local con_name="wifi-$(echo "$ssid" | tr -cd '[:alnum:]-_' | cut -c1-30)"

    local existing; existing=$(find_existing_profile "$ssid")
    [[ -n "$existing" ]] && nmcli connection delete "$existing" &>/dev/null || true

    if nmcli connection add \
            type wifi \
            ifname "$WIFI_INTERFACE" \
            con-name "$con_name" \
            ssid "$ssid" \
            connection.autoconnect yes \
            ipv4.method auto \
            ipv4.route-metric 100 &>/dev/null; then
        echo "$con_name"
    else
        echo ""
    fi
}

# ── Attempt WiFi connection in background ─────────────────────────────────────
# This runs AFTER the SSH session ends (connection will drop when AP stops).
schedule_wifi_switch() {
    local con_name="$1"
    local switch_script="/tmp/netmanager-switch-$$.sh"

    cat > "$switch_script" << SWITCH
#!/usr/bin/env bash
set -uo pipefail
source /etc/netmanager/netmanager.conf
LOG=/var/log/netmanager-provision.log
ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[\$(ts)] Scheduled WiFi switch starting" >> "\$LOG"
sleep 6   # let SSH session close gracefully

# Stop the AP
nmcli connection down "\${AP_CON_NAME}" &>>"\$LOG" || true
sleep 3

# Attempt WiFi
echo "[\$(ts)] Connecting to '${con_name}' …" >> "\$LOG"
if nmcli connection up "${con_name}" &>>"\$LOG"; then
    sleep 8
    # Verify connectivity
    if ping -c 3 -W "\${CONNECTIVITY_TIMEOUT}" "\${CONNECTIVITY_HOST}" &>/dev/null; then
        echo "[\$(ts)] SUCCESS — WiFi connected" >> "\$LOG"
        echo "wifi" > "\${STATE_FILE}"
        exit 0
    fi
fi

echo "[\$(ts)] WiFi connection failed — restoring AP" >> "\$LOG"
nmcli connection down "${con_name}" &>/dev/null || true
echo "ap_pending" > "\${STATE_FILE}"
# Restart netmanager service so it re-evaluates and restores AP
systemctl restart netmanager &>/dev/null || true
SWITCH

    chmod +x "$switch_script"
    # Detach fully from the terminal so it survives SSH disconnect
    nohup bash "$switch_script" &>/dev/null </dev/null &
    disown
    ok "WiFi switch scheduled (runs after your SSH session ends)"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
clear
header "Raspberry Pi — WiFi Provisioning Wizard"
cat << MSG
  Current fallback AP:  ${AP_SSID}
  This Pi's AP IP:      ${AP_IP}

  This wizard will:
    1. Scan for available WiFi networks
    2. Let you choose one and enter the password
    3. Stop the fallback AP and connect to your network

  ${YELLOW}IMPORTANT:${NC} When you confirm the switch, this SSH session will
  disconnect within ~10 seconds (the AP is shutting down).

  If the WiFi connection fails, restart the Pi.  The fallback
  AP will reappear automatically so you can try again.

MSG

read -rp "Press ENTER to start scanning …"

# ── Step 1: Choose network ─────────────────────────────────────────────────────
header "Step 1 — Select WiFi Network"
choose_network

echo
ok "Selected: ${CHOSEN_SSID}"

# ── Step 2: Get credentials ────────────────────────────────────────────────────
WIFI_PASSWORD=""
WIFI_CON_NAME=""

if [[ -z "$CHOSEN_SECURITY" || "$CHOSEN_SECURITY" == "--" \
   || "${CHOSEN_SECURITY,,}" == "none" ]]; then
    warn "This network appears to be open (no password)."
    confirm_yn "Connect to open network '${CHOSEN_SSID}'?" y \
        && WIFI_CON_NAME=$(configure_open_wifi_profile "$CHOSEN_SSID")
else
    # Check if we already have a saved profile for this SSID
    local_existing=$(find_existing_profile "$CHOSEN_SSID")
    if [[ -n "$local_existing" ]]; then
        warn "A saved profile for '${CHOSEN_SSID}' already exists ('${local_existing}')."
        if confirm_yn "Use existing profile (skip password entry)?" y; then
            WIFI_CON_NAME="$local_existing"
        else
            header "Step 2 — Enter WiFi Password"
            ask_secret_input WIFI_PASSWORD "Password for '${CHOSEN_SSID}'" 8
            WIFI_CON_NAME=$(configure_wifi_profile "$CHOSEN_SSID" "$WIFI_PASSWORD")
        fi
    else
        header "Step 2 — Enter WiFi Password"
        ask_secret_input WIFI_PASSWORD "Password for '${CHOSEN_SSID}'" 8
        WIFI_CON_NAME=$(configure_wifi_profile "$CHOSEN_SSID" "$WIFI_PASSWORD")
    fi
fi

if [[ -z "$WIFI_CON_NAME" ]]; then
    err "Failed to create WiFi profile.  Aborting."
    exit 1
fi

# ── Step 3: Confirm and switch ─────────────────────────────────────────────────
header "Step 3 — Confirm Switch"
cat << MSG
  Network:   ${CHOSEN_SSID}
  Profile:   ${WIFI_CON_NAME}

  ${YELLOW}After you confirm:${NC}
    • This SSH session will disconnect in ~10 seconds
    • The Pi will stop the AP and connect to '${CHOSEN_SSID}'
    • If successful, find the Pi's new IP in your router's DHCP list
    • If it fails, reboot the Pi — the AP will reappear automatically

MSG

if ! confirm_yn "Proceed with switching to '${CHOSEN_SSID}'?" y; then
    warn "Cancelled.  No changes applied."
    nmcli connection delete "$WIFI_CON_NAME" &>/dev/null || true
    exit 0
fi

schedule_wifi_switch "$WIFI_CON_NAME"

echo
ok "Switch initiated.  This session will close shortly …"
echo "  Check your router for the Pi's new IP address."
echo "  If the AP comes back, just SSH in and try again."
echo
sleep 3
PROVISION_EOF

    chmod +x "$PROVISION_SCRIPT"
    ok "WiFi provisioning wizard written → $PROVISION_SCRIPT"
}

# ── Generate systemd service ───────────────────────────────────────────────────
write_service() {
cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=Raspberry Pi Smart Network Manager (Ethernet > WiFi > AP Fallback)
Documentation=file://${NM_SCRIPT}
After=NetworkManager.service network-pre.target
Wants=NetworkManager.service
# Restart if it crashes; not after clean stop
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${NM_SCRIPT}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=netmanager

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    ok "Systemd service written → $SERVICE_FILE"
}

# ── Generate MOTD banner for SSH logins ───────────────────────────────────────
write_motd() {
    mkdir -p /etc/update-motd.d
cat > "$MOTD_SCRIPT" << 'MOTD_EOF'
#!/usr/bin/env bash
# Shown on SSH login — indicates network mode and setup instructions
CONFIG_FILE="/etc/netmanager/netmanager.conf"
STATE_FILE="/etc/netmanager/current-mode"
[[ -f "$CONFIG_FILE" ]] || exit 0
# shellcheck source=/dev/null
source "$CONFIG_FILE"

mode=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m' C=$'\033[0;36m' N=$'\033[0m'

case "$mode" in
    ethernet) clr="$G"; label="ETHERNET (preferred)" ;;
    wifi)     clr="$G"; label="WiFi" ;;
    ap)       clr="$Y"; label="FALLBACK ACCESS POINT" ;;
    *)        clr="$C"; label="initialising …" ;;
esac

printf '\n%b┌─────────────────────────────────────────────────┐%b\n' "$C" "$N"
printf '%b│  Raspberry Pi Network Manager%b\n' "$C" "$N"
printf '%b│  Mode: %b%-40s%b%b│%b\n' "$C" "$clr" "$label" "$N" "$C" "$N"

if [[ "$mode" == "ap" ]]; then
    printf '%b│%b\n' "$C" "$N"
    printf '%b│  AP SSID    : %s%b\n' "$C" "$AP_SSID" "$N"
    printf '%b│  AP IP      : %s%b\n' "$C" "$AP_IP"   "$N"
    printf '%b│%b\n' "$C" "$N"
    printf '%b│  %bRun this to configure WiFi:%b%b\n' "$C" "$Y" "$N" "$C"
    printf '%b│    sudo wifi-provision.sh%b\n' "$C" "$N"
fi

printf '%b└─────────────────────────────────────────────────┘%b\n\n' "$C" "$N"
MOTD_EOF
    chmod +x "$MOTD_SCRIPT"
    # Disable the plain /etc/motd if it would override dynamic motd
    [[ -f /etc/motd ]] && : > /etc/motd
    ok "MOTD banner written → $MOTD_SCRIPT"
}

# ── Create NetworkManager AP connection profile ────────────────────────────────
create_ap_nm_profile() {
    header "Creating NetworkManager AP Profile"

    # Remove stale profile if it exists
    if nmcli connection show "$AP_CON_NAME" &>/dev/null; then
        info "Removing existing profile '$AP_CON_NAME' …"
        nmcli connection delete "$AP_CON_NAME" &>/dev/null || true
    fi

    info "Creating AP profile '$AP_CON_NAME' …"
    if [[ "$AP_SECURED" == "yes" ]]; then
        nmcli connection add \
            type wifi \
            ifname "$WIFI_INTERFACE" \
            con-name "$AP_CON_NAME" \
            autoconnect no \
            ssid "$AP_SSID" \
            mode ap \
            ipv4.method shared \
            ipv4.addresses "${AP_IP}/24" \
            ipv6.method disabled \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$AP_PASSWORD" \
            802-11-wireless.band bg \
            802-11-wireless.channel "$AP_CHANNEL"
        ok "AP profile created (SSID='${AP_SSID}', IP=${AP_IP}, WPA2)"
    else
        nmcli connection add \
            type wifi \
            ifname "$WIFI_INTERFACE" \
            con-name "$AP_CON_NAME" \
            autoconnect no \
            ssid "$AP_SSID" \
            mode ap \
            ipv4.method shared \
            ipv4.addresses "${AP_IP}/24" \
            ipv6.method disabled \
            802-11-wireless.band bg \
            802-11-wireless.channel "$AP_CHANNEL"
        warn "AP profile created (SSID='${AP_SSID}', IP=${AP_IP}, OPEN — no password)"
    fi
}

# ── Enable & start service ────────────────────────────────────────────────────
enable_service() {
    header "Enabling Service"
    systemctl daemon-reload
    systemctl enable netmanager.service
    ok "netmanager.service enabled (will start on boot)"

    # Stop any old run first
    systemctl stop netmanager.service 2>/dev/null || true
    systemctl start netmanager.service
    ok "netmanager.service started"
    sleep 2
    if systemctl is-active --quiet netmanager.service; then
        ok "Service is running"
    else
        warn "Service may not be running — check: journalctl -u netmanager -n 40"
    fi
}

# ── Print final summary ───────────────────────────────────────────────────────
print_summary() {
    header "Installation Complete"
    cat << MSG
  ${GREEN}All components installed and service started.${NC}

  Key files:
    Config:       ${CONFIG_FILE}
    Daemon:       ${NM_SCRIPT}
    WiFi wizard:  ${PROVISION_SCRIPT}
    Service:      ${SERVICE_FILE}
    State:        ${STATE_FILE}
    Log:          /var/log/netmanager.log

  How it works:
    1. On every boot the daemon checks for Ethernet connectivity first.
    2. If Ethernet is found, it is used and kept prioritised automatically.
    3. If only WiFi is available, WiFi is used.
    4. If neither works, the fallback AP '${AP_SSID}' appears
       (${AP_SECURED/yes/WPA2 password protected}${AP_SECURED/no/open — no password}).
    5. Connect to '${AP_SSID}' and SSH in:
         ssh ${AP_SSH_USER}@${AP_IP} -p ${SSH_PORT}
    6. Run the wizard:
         sudo wifi-provision.sh
    7. The wizard scans networks, lets you pick one, saves credentials,
       then switches — the AP stops and WiFi connects automatically.
    8. If WiFi fails, reboot; the AP will reappear for another attempt.

  Useful commands:
    sudo systemctl status netmanager    # service status
    sudo journalctl -u netmanager -f    # live log
    cat ${STATE_FILE}                   # current mode
    sudo systemctl restart netmanager   # force re-evaluate network
    sudo wifi-provision.sh              # re-run WiFi wizard (as root)
    sudo nano ${CONFIG_FILE}            # edit config
MSG
}

# ══════════════════════════════════════════════════════════════════════════════
# Entry point
# ══════════════════════════════════════════════════════════════════════════════
main() {
    clear
    header "Raspberry Pi OS Lite — Smart Network Manager Installer"

    check_root
    check_prerequisites
    collect_config
    confirm_config

    header "Installing Files"
    write_config
    write_netmanager_script
    write_provision_script
    write_service
    write_motd
    create_ap_nm_profile
    enable_service

    print_summary
}

main