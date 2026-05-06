#!/bin/bash
#
# Zscaler Split Tunneling Script for macOS
#
# This script removes overly broad routes that Zscaler creates,
# enabling split tunneling. It monitors and removes these routes
# continuously to prevent Zscaler from adding them back.
#
# Usage:
#   ./zscaler-split-tunnel.sh [options]
#
# Options:
#   --start        Start split tunneling (default)
#   --stop         Stop split tunneling monitoring
#   --status       Show current route status
#   --list         List all current routes
#   --daemon       Run as daemon (keeps removing routes)
#   --interval N   Check interval in seconds (default: 30)
#   --verbose      Enable verbose output
#   --enable-autostart  Install launchd job to start daemon at boot
#   --disable-autostart Remove launchd job
#
# Updates:
#   - Added 128/2 and 192/2 routes to cover full IPv4 space (128.0.0.0-255.255.255.255)
#   - Added automatic Zscaler interface detection (typically utun8)
#   - Improved route existence checking with proper regex escaping
#   - Enhanced status display with interface information
#   - Added network change detection to automatically refresh routes
#     when switching networks (prevents ERR_ADDRESS_INVALID errors)
#

# Script metadata
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Default values
INTERVAL=30
VERBOSE=0
DAEMON_PID_FILE="/tmp/zscaler-split-tunnel.pid"
LOG_FILE="/tmp/zscaler-split-tunnel.log"
CACHE_EXPIRE=3600  # 1 hour
REMOTE_CACHE_EXPIRE=3600  # 1 hour

# Configuration paths
USER_CONFIG_DIR="$HOME/.config/zscaler-split-tunnel"
CONFIG_FILE="$USER_CONFIG_DIR/routes.conf"
BYPASS_CONFIG_FILE="$USER_CONFIG_DIR/bypass.conf"
CONFIG_MTIME_FILE="$USER_CONFIG_DIR/routes.mtime"
DOMAIN_CACHE_FILE="$USER_CONFIG_DIR/domain-cache.txt"
REMOTE_ROUTE_CACHE_FILE="$USER_CONFIG_DIR/remote-route-cache.txt"

LEGACY_CONFIG_FILE="$HOME/.config/zscaler-split-tunnel.conf"
LEGACY_BYPASS_CONFIG_FILE="$HOME/.config/zscaler-bypass.conf"
LEGACY_CONFIG_MTIME_FILE="$HOME/.config/zscaler-split-tunnel.mtime"

DEFAULT_CONFIG_FILE="$SCRIPT_DIR/config/zscaler-split-tunnel.conf"
DEFAULT_BYPASS_FILE="$SCRIPT_DIR/config/zscaler-bypass.conf"

# Auto-update configuration
BACKUP_DIR="$HOME/.zscaler-split-tunnel-backups"
BACKUP_PATTERN="${SCRIPT_NAME}"'*.backup'

# Broad IPv4 routes to remove (these cover most of the internet)
IPV4_BROAD_ROUTES=(
    "1"
    "2/7"
    "4/6"
    "8/5"
    "11"
    "16/4"
    "32/3"
    "64/2"
    "128/2"  # This covers 128.0.0.0 - 191.255.255.255
    "192/2"  # This covers 192.0.0.0 - 255.255.255.255
)

# Broad IPv6 routes to remove (equivalent broad blocks)
IPV6_BROAD_ROUTES=(
    "2000::/3"  # Global unicast addresses
    "fc00::/7"  # Unique local addresses
    "::/1"      # Half of IPv6 space
    "8000::/1"  # Other half of IPv6 space
)

# Zscaler routes to add through the tunnel (populated from config)
declare -a CUSTOM_ROUTES=()
# Direct overrides to route outside Zscaler (populated from direct override config)
declare -a BYPASS_ROUTES=()
# Initialize domain cache (associative array not used for compatibility)

AUTOSTART_LABEL="com.github.zscaler-split-tunnel"
AUTOSTART_PLIST_PATH="/Library/LaunchDaemons/${AUTOSTART_LABEL}.plist"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case $level in
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        INFO)
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        *)
            echo "$message"
            ;;
    esac

    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Verbose logging
vlog() {
    if [[ $VERBOSE -eq 1 ]]; then
        log INFO "$@"
    fi
}

# Function to detect Zscaler interface
detect_zscaler_interface() {
    route get 100.64.1.3 | grep 'interface:' | sed -E 's,.*:[[:space:]]*,,'
}

# Function to get current network signature (for detecting changes)
get_network_signature() {
    local gateway
    gateway=$(route -n get default 2>/dev/null | grep 'gateway:' | sed -E 's,.*:[[:space:]]*,,' || echo "none")
    local interface
    interface=$(route -n get default 2>/dev/null | grep 'interface:' | sed -E 's,.*:[[:space:]]*,,' || echo "none")
    local ip_addr
    ip_addr=$(ifconfig "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' || echo "none")
    echo "${gateway}:${interface}:${ip_addr}"
}

# Function to clear DNS resolution cache
clear_dns_cache() {
    if [[ -f "$DOMAIN_CACHE_FILE" ]]; then
        rm -f "$DOMAIN_CACHE_FILE"
        vlog "Cleared DNS resolution cache"
    fi
    if [[ -f "$REMOTE_ROUTE_CACHE_FILE" ]]; then
        rm -f "$REMOTE_ROUTE_CACHE_FILE"
        vlog "Cleared remote route cache"
    fi
    # Flush macOS system DNS cache
    sudo dscacheutil -flushcache 2>/dev/null
    sudo killall -HUP mDNSResponder 2>/dev/null
    vlog "Flushed macOS system DNS cache"
}

# Function to handle network change
handle_network_change() {
    log INFO "Network change detected! Refreshing all routes..."

    # Clear DNS cache to force re-resolution with new network
    clear_dns_cache

    # Remove all existing Zscaler routes and direct overrides
    remove_custom_routes
    remove_bypass_routes

    # Reload configurations (this will re-resolve domains)
    load_config
    load_bypass_config

    # Remove broad routes
    remove_broad_routes

    # Re-add Zscaler routes with new tunnel interface
    add_custom_routes

    # Re-add direct overrides with new gateway
    add_bypass_routes

    log SUCCESS "Routes refreshed for new network"
}

# Determine the current console user (fallback to sudo user or $USER)
get_console_user() {
    local console_user
    console_user=$(stat -f '%Su' /dev/console 2>/dev/null || true)

    if [[ -z "$console_user" || "$console_user" == "root" ]]; then
        if [[ -n "$SUDO_USER" ]]; then
            console_user=$SUDO_USER
        else
            console_user=$USER
        fi
    fi

    echo "$console_user"
}

# Function to resolve domain to IP addresses
resolve_domain() {
    local domain=$1
    local cache_key="domain:$domain"
    local current_time
    current_time=$(date +%s)

    # Check cache
    if [[ -f "$DOMAIN_CACHE_FILE" ]]; then
        local cache_line
        cache_line=$(grep -F "$cache_key=" "$DOMAIN_CACHE_FILE" 2>/dev/null)
        if [[ -n "$cache_line" ]]; then
            local cache_data="${cache_line#*=}"
            local cache_time
            cache_time=$(echo "$cache_data" | cut -d' ' -f1)
            local cache_ips
            cache_ips=$(echo "$cache_data" | cut -d' ' -f2-)

            if (( current_time - cache_time < CACHE_EXPIRE )); then
                echo "$cache_ips"
                return
            fi
        fi
    fi

    # Resolve domain
    local ips
    ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    local ipv6s
    ipv6s=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$')

    local all_ips_raw="$ips $ipv6s"
    local all_ips
    all_ips=$(printf '%s\n' "$all_ips_raw" | tr ' ' '\n' | sort -u | tr '\n' ' ')

    # Remove old cache entry if exists
    if [[ -f "$DOMAIN_CACHE_FILE" ]]; then
        grep -Fv "$cache_key=" "$DOMAIN_CACHE_FILE" > "$DOMAIN_CACHE_FILE.tmp" 2>/dev/null || true
        mv "$DOMAIN_CACHE_FILE.tmp" "$DOMAIN_CACHE_FILE"
    fi

    # Cache result (only if resolution succeeded)
    if [[ -n "$all_ips" ]]; then
        echo "$cache_key=$current_time $all_ips" >> "$DOMAIN_CACHE_FILE"
        echo "$all_ips"
    fi
}

ensure_default_bypass_entries() {
    mkdir -p "$USER_CONFIG_DIR"

    if [[ ! -f "$BYPASS_CONFIG_FILE" ]]; then
        : > "$BYPASS_CONFIG_FILE"
        vlog "Initialized direct override file at $BYPASS_CONFIG_FILE"
    fi
}

# Function to validate IP address or CIDR
validate_ip_cidr() {
    local input=$1

    # Check if it's a valid IPv4 address or CIDR
    if echo "$input" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
        # Additional validation for proper IP range
        local ip_part=${input%/*}
        IFS='.' read -ra OCTETS <<< "$ip_part"
        for octet in "${OCTETS[@]}"; do
            if (( octet > 255 )); then
                return 1
            fi
        done

        # Check CIDR if present
        if [[ "$input" == */* ]]; then
            local cidr=${input#*/}
            if (( cidr > 32 )); then
                return 1
            fi
        fi
        return 0
    fi

    # Check if it's a valid IPv6 address or CIDR
    if echo "$input" | grep -qE '^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?$'; then
        return 0
    fi

    return 1
}

# Function to check if input is a domain
is_domain() {
    local input=$1
    # Basic domain validation
    if echo "$input" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
        return 0
    fi
    return 1
}

# Function to check if input is a URL (http/https)
is_url() {
    local input=$1
    if echo "$input" | grep -qE '^https?://'; then
        return 0
    fi
    return 1
}

# Fetch remote IP routes from URL with simple caching
fetch_remote_routes() {
    local url=$1

    # Only allow HTTPS URLs for security
    if [[ "$url" != https://* ]]; then
        log ERROR "Refusing to fetch remote routes over insecure URL: $url"
        return 1
    fi

    local cache_key="url:$url"
    local current_time
    current_time=$(date +%s)
    local cached_routes=""
    local cache_time=0

    if [[ -f "$REMOTE_ROUTE_CACHE_FILE" ]]; then
        local cache_line
        cache_line=$(grep -F "$cache_key=" "$REMOTE_ROUTE_CACHE_FILE" 2>/dev/null || true)
        if [[ -n "$cache_line" ]]; then
            local cache_data="${cache_line#*=}"
            cache_time=${cache_data%%|*}
            if [[ "$cache_time" != "$cache_data" ]]; then
                cached_routes="${cache_data#*|}"
                if [[ -n "$cached_routes" && "$cache_time" =~ ^[0-9]+$ ]]; then
                    if (( current_time - cache_time < REMOTE_CACHE_EXPIRE )); then
                        vlog "Using cached remote routes for $url"
                        echo "$cached_routes" | tr ' ' '\n'
                        return 0
                    fi
                fi
            fi
        fi
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log ERROR "curl is required to fetch remote routes ($url)"
        if [[ -n "$cached_routes" ]]; then
            log WARN "Using cached remote routes for $url due to missing curl"
            echo "$cached_routes" | tr ' ' '\n'
            return 0
        fi
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)
    if ! curl -fsSL --max-time 20 "$url" -o "$tmp_file"; then
        log WARN "Failed to fetch remote routes from $url"
        rm -f "$tmp_file"
        if [[ -n "$cached_routes" ]]; then
            log WARN "Using cached remote routes for $url after fetch failure"
            echo "$cached_routes" | tr ' ' '\n'
            return 0
        fi
        return 1
    fi

    local parsed_routes
    if command -v python3 >/dev/null 2>&1; then
        parsed_routes=$(REMOTE_ROUTE_SOURCE="$tmp_file" python3 <<'PY' 2>/dev/null
import ipaddress
import os
import re
from pathlib import Path

source_path = Path(os.environ.get("REMOTE_ROUTE_SOURCE", ""))
try:
    data = source_path.read_text()
except Exception:
    data = ""

routes = set()

for token in re.findall(r'\b[0-9A-Fa-f:.]+/[0-9]{1,3}\b', data):
    try:
        routes.add(ipaddress.ip_network(token, strict=False))
    except ValueError:
        continue

for token in re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', data):
    try:
        routes.add(ipaddress.ip_network(f"{token}/32", strict=False))
    except ValueError:
        continue

for token in re.findall(r'\b(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4}\b', data):
    if '/' in token:
        continue
    try:
        routes.add(ipaddress.ip_network(f"{token}/128", strict=False))
    except ValueError:
        continue

sorted_routes = sorted(
    routes,
    key=lambda net: (net.version, int(net.network_address), net.prefixlen)
)

for net in sorted_routes:
    print(str(net))
PY
        )
    else
        parsed_routes=$(LC_ALL=C grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$tmp_file" 2>/dev/null | while read -r token; do
                if [[ -z "$token" ]]; then
                    continue
                fi
                if [[ "$token" != */* ]]; then
                    token="$token/32"
                fi
                if validate_ip_cidr "$token"; then
                    echo "$token"
                fi
            done
        )
        parsed_routes+=$'\n'$(LC_ALL=C grep -Eo '([0-9a-fA-F:]+)/[0-9]{1,3}' "$tmp_file" 2>/dev/null | while read -r token; do
                if [[ -z "$token" ]]; then
                    continue
                fi
                if validate_ip_cidr "$token"; then
                    echo "$token"
                fi
            done
        )
        parsed_routes=$(echo "$parsed_routes" | grep -v '^\s*$' | sort -u)
    fi

    rm -f "$tmp_file"

    if [[ -z "$parsed_routes" ]]; then
        log WARN "No valid routes found in remote source: $url"
        if [[ -n "$cached_routes" ]]; then
            log WARN "Using cached remote routes for $url due to empty response"
            echo "$cached_routes" | tr ' ' '\n'
            return 0
        fi
        return 1
    fi

    local normalized_cache
    normalized_cache=$(echo "$parsed_routes" | tr '\n' ' ' | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//')

    if [[ -n "$normalized_cache" ]]; then
        if [[ -f "$REMOTE_ROUTE_CACHE_FILE" ]]; then
            grep -Fv "$cache_key=" "$REMOTE_ROUTE_CACHE_FILE" > "$REMOTE_ROUTE_CACHE_FILE.tmp" 2>/dev/null || true
            mv "$REMOTE_ROUTE_CACHE_FILE.tmp" "$REMOTE_ROUTE_CACHE_FILE"
        fi
        echo "$cache_key=$current_time|$normalized_cache" >> "$REMOTE_ROUTE_CACHE_FILE"
    fi

    printf '%s\n' "$parsed_routes"
    return 0
}

# Function to load direct override configuration
load_bypass_config() {
    BYPASS_ROUTES=()

    ensure_default_bypass_entries

    local sources=()
    if [[ -f "$DEFAULT_BYPASS_FILE" ]]; then
        sources+=("$DEFAULT_BYPASS_FILE")
    fi

    if [[ -f "$BYPASS_CONFIG_FILE" ]]; then
        sources+=("$BYPASS_CONFIG_FILE")
    elif [[ -f "$LEGACY_BYPASS_CONFIG_FILE" ]]; then
        sources+=("$LEGACY_BYPASS_CONFIG_FILE")
    fi

    if [[ ${#sources[@]} -eq 0 ]]; then
        vlog "No direct override configuration found"
        return
    fi

    local source
    for source in "${sources[@]}"; do
        vlog "Loading direct override configuration from $source"

        # Process each line in direct override config
        while IFS= read -r line; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Trim whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"

            local original_line="$line"
            local normalized_line="$line"
            local is_wildcard=0

            if [[ "$normalized_line" == \*.* ]]; then
                normalized_line=${normalized_line#*.}
                is_wildcard=1
            elif [[ "$normalized_line" == .* ]]; then
                normalized_line=${normalized_line#.}
                is_wildcard=1
            fi

            if is_domain "$normalized_line"; then
                if (( is_wildcard )); then
                    vlog "Resolving direct override wildcard: $original_line (normalized to $normalized_line)"
                else
                    vlog "Resolving direct override domain: $normalized_line"
                fi
                local ips
                ips=$(resolve_domain "$normalized_line")
                if [[ -n "$ips" ]]; then
                    local ip
                    for ip in $ips; do
                        local candidate="$ip/32"
                        if [[ " ${BYPASS_ROUTES[*]} " != *" $candidate "* ]]; then
                            BYPASS_ROUTES+=("$candidate")
                            vlog "  Added direct override IP: $candidate"
                        fi
                    done
                else
                    log WARN "Failed to resolve direct override domain in $source: $original_line"
                fi
            elif is_url "$line"; then
                vlog "Fetching direct overrides from remote source: $line"
                local remote_entries=""
                remote_entries=$(fetch_remote_routes "$line")
                if [[ -n "$remote_entries" ]]; then
                    local remote_route=""
                    local remote_count=0
                    while IFS= read -r remote_route; do
                        remote_route="${remote_route#"${remote_route%%[![:space:]]*}"}"
                        remote_route="${remote_route%"${remote_route##*[![:space:]]}"}"
                        [[ -z "$remote_route" ]] && continue
                        if ! validate_ip_cidr "$remote_route"; then
                            continue
                        fi
                        if [[ " ${BYPASS_ROUTES[*]} " != *" $remote_route "* ]]; then
                            BYPASS_ROUTES+=("$remote_route")
                            ((remote_count++))
                        fi
                    done <<< "$remote_entries"
                    if (( remote_count > 0 )); then
                        log INFO "Loaded $remote_count direct overrides from $line"
                    else
                        vlog "No new direct overrides from remote source: $line"
                    fi
                else
                    log WARN "Failed to load direct overrides from remote source: $line"
                fi
            elif validate_ip_cidr "$line"; then
                if [[ " ${BYPASS_ROUTES[*]} " != *" $line "* ]]; then
                    BYPASS_ROUTES+=("$line")
                    vlog "Added direct override IP/CIDR from $source: $line"
                fi
            else
                log WARN "Invalid entry in direct override config ($source): $original_line"
            fi
        done < "$source"
    done

    log INFO "Loaded ${#BYPASS_ROUTES[@]} direct overrides from ${#sources[@]} source(s)"
}

# Function to load configuration
load_config() {
    CUSTOM_ROUTES=()

    local sources=()
    if [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
        sources+=("$DEFAULT_CONFIG_FILE")
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        sources+=("$CONFIG_FILE")
    elif [[ -f "$LEGACY_CONFIG_FILE" ]]; then
        sources+=("$LEGACY_CONFIG_FILE")
    fi

    if [[ ${#sources[@]} -eq 0 ]]; then
        vlog "No Zscaler routes configuration found"
        return
    fi

    local source
    for source in "${sources[@]}"; do
        vlog "Loading configuration from $source"

        # Process each line in config
        while IFS= read -r line; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Trim whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"

            if is_domain "$line"; then
                vlog "Resolving domain: $line"
                local ips
                ips=$(resolve_domain "$line")
                if [[ -n "$ips" ]]; then
                    local ip
                    for ip in $ips; do
                        local candidate="$ip/32"
                        if [[ " ${CUSTOM_ROUTES[*]} " != *" $candidate "* ]]; then
                            CUSTOM_ROUTES+=("$candidate")
                            vlog "  Added IP: $candidate"
                        fi
                    done
                else
                    log WARN "Failed to resolve domain in $source: $line"
                fi
            elif is_url "$line"; then
                vlog "Fetching Zscaler routes from remote source: $line"
                local remote_entries=""
                remote_entries=$(fetch_remote_routes "$line")
                if [[ -n "$remote_entries" ]]; then
                    local remote_route=""
                    local remote_count=0
                    while IFS= read -r remote_route; do
                        remote_route="${remote_route#"${remote_route%%[![:space:]]*}"}"
                        remote_route="${remote_route%"${remote_route##*[![:space:]]}"}"
                        [[ -z "$remote_route" ]] && continue
                        if ! validate_ip_cidr "$remote_route"; then
                            continue
                        fi
                        if [[ " ${CUSTOM_ROUTES[*]} " != *" $remote_route "* ]]; then
                            CUSTOM_ROUTES+=("$remote_route")
                            ((remote_count++))
                        fi
                    done <<< "$remote_entries"
                    if (( remote_count > 0 )); then
                        log INFO "Loaded $remote_count Zscaler routes from $line"
                    else
                        vlog "No new Zscaler routes from remote source: $line"
                    fi
                else
                    log WARN "Failed to load Zscaler routes from remote source: $line"
                fi
            elif validate_ip_cidr "$line"; then
                if [[ " ${CUSTOM_ROUTES[*]} " != *" $line "* ]]; then
                    CUSTOM_ROUTES+=("$line")
                    vlog "Added IP/CIDR from $source: $line"
                fi
            else
                log WARN "Invalid entry in config ($source): $line"
            fi
        done < "$source"
    done

    # Domain cache is automatically saved to file during resolution

    log INFO "Loaded ${#CUSTOM_ROUTES[@]} Zscaler routes from ${#sources[@]} source(s)"
}

# Function to add Zscaler routes through the tunnel
add_custom_routes() {
    local zscaler_interface
    zscaler_interface=$(detect_zscaler_interface)

    if [[ -z "$zscaler_interface" ]]; then
        log ERROR "Cannot add Zscaler routes: Zscaler interface not detected"
        return 1
    fi

    local added_count=0

    for route in "${CUSTOM_ROUTES[@]}"; do
        # Determine if IPv4 or IPv6
        if [[ "$route" =~ : ]]; then
            # IPv6
            if ! netstat -rn -f inet6 | grep -q "^${route//\//\\/}[[:space:]]"; then
                if sudo route -n add -inet6 "$route" -interface "$zscaler_interface" 2>/dev/null; then
                    vlog "Added IPv6 route through Zscaler: $route"
                    ((added_count++))
                else
                    vlog "Failed to add IPv6 route: $route"
                fi
            else
                vlog "IPv6 route already exists: $route"
            fi
        else
            # IPv4
            if ! netstat -rn -f inet | grep -q "^${route//\//\\/}[[:space:]]"; then
                if sudo route -n add -net "$route" -interface "$zscaler_interface" 2>/dev/null; then
                    vlog "Added IPv4 route through Zscaler: $route"
                    ((added_count++))
                else
                    vlog "Failed to add IPv4 route: $route"
                fi
            else
                vlog "IPv4 route already exists: $route"
            fi
        fi
    done

    if [[ $added_count -gt 0 ]]; then
        log SUCCESS "Added $added_count Zscaler routes"
    fi
}

# Function to add direct overrides (direct, not through Zscaler)
add_bypass_routes() {
    local added_count=0
    local default_gateway
    default_gateway=$(route -n get default | grep 'gateway:' | sed -E 's,.*:[[:space:]]*,,')
    local default_interface
    default_interface=$(route -n get default | grep 'interface:' | sed -E 's,.*:[[:space:]]*,,')

    if [[ -z "$default_gateway" || -z "$default_interface" ]]; then
        log ERROR "Cannot add direct overrides: Default gateway/interface not detected"
        return 1
    fi

    vlog "Using default gateway: $default_gateway via $default_interface"

    for route in "${BYPASS_ROUTES[@]}"; do
        # Determine if IPv4 or IPv6
        if [[ "$route" =~ : ]]; then
            # IPv6 - check if route already exists
            if ! netstat -rn -f inet6 | grep -q "^${route//\//\\/}[[:space:]]"; then
                if sudo route -n add -inet6 "$route" -gateway "$default_gateway" 2>/dev/null; then
                    vlog "Added direct override IPv6 route: $route"
                    ((added_count++))
                else
                    vlog "Failed to add direct override IPv6 route: $route"
                fi
            else
                vlog "Direct override IPv6 route already exists: $route"
            fi
        else
            # IPv4 - check if route already exists
            if ! netstat -rn -f inet | grep -q "^${route//\//\\/}[[:space:]]"; then
                if sudo route -n add -net "$route" -gateway "$default_gateway" 2>/dev/null; then
                    vlog "Added direct override IPv4 route: $route"
                    ((added_count++))
                else
                    vlog "Failed to add direct override IPv4 route: $route"
                fi
            else
                vlog "Direct override IPv4 route already exists: $route"
            fi
        fi
    done

    if [[ $added_count -gt 0 ]]; then
        log SUCCESS "Added $added_count direct overrides"
    fi
}

# Function to remove direct overrides
remove_bypass_routes() {
    local removed_count=0

    for route in "${BYPASS_ROUTES[@]}"; do
        # Determine if IPv4 or IPv6
        if [[ "$route" =~ : ]]; then
            # IPv6
            if sudo route -n delete -inet6 "$route" 2>/dev/null; then
                vlog "Removed direct override IPv6 route: $route"
                ((removed_count++))
            fi
        else
            # IPv4
            if sudo route -n delete -net "$route" 2>/dev/null; then
                vlog "Removed direct override IPv4 route: $route"
                ((removed_count++))
            fi
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        log SUCCESS "Removed $removed_count direct overrides"
    fi
}

# Function to remove Zscaler routes
remove_custom_routes() {
    local removed_count=0

    for route in "${CUSTOM_ROUTES[@]}"; do
        # Determine if IPv4 or IPv6
        if [[ "$route" =~ : ]]; then
            # IPv6
            if sudo route -n delete -inet6 "$route" 2>/dev/null; then
                vlog "Removed Zscaler IPv6 route: $route"
                ((removed_count++))
            fi
        else
            # IPv4
            if sudo route -n delete -net "$route" 2>/dev/null; then
                vlog "Removed Zscaler IPv4 route: $route"
                ((removed_count++))
            fi
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        log SUCCESS "Removed $removed_count Zscaler routes"
    fi
}

# Notify daemon process to reload configuration immediately
trigger_daemon_reload() {
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            if kill -USR1 "$pid" 2>/dev/null; then
                log INFO "Notified daemon (PID: $pid) to reload configuration"
                return 0
            fi
        fi
    fi

    vlog "Split tunnel daemon not running; skipping reload signal"
    return 1
}

# Immediately apply route for a single entry without waiting for daemon
apply_route_now() {
    local entry="$1"
    local mode="$2"  # "custom" or "bypass"
    local ips=()

    if is_url "$entry"; then
        return 0
    elif is_domain "$entry"; then
        local resolved
        resolved=$(resolve_domain "$entry")
        if [[ -z "$resolved" ]]; then
            log WARN "Could not resolve domain: $entry (route will be applied by daemon on next cycle)"
            return 1
        fi
        local ip
        for ip in $resolved; do
            [[ "$ip" =~ / ]] && ips+=("$ip") || ips+=("$ip/32")
        done
    elif validate_ip_cidr "$entry"; then
        ips+=("$entry")
    else
        return 1
    fi

    if [[ "$mode" == "custom" ]]; then
        local zscaler_interface
        zscaler_interface=$(detect_zscaler_interface)
        if [[ -z "$zscaler_interface" ]]; then
            log WARN "Zscaler interface not detected (route will be applied by daemon)"
            return 1
        fi
        local route
        for route in "${ips[@]}"; do
            if [[ "$route" =~ : ]]; then
                if netstat -rn -f inet6 | grep -q "^${route//\//\\/}[[:space:]]"; then
                    vlog "Route already active: $route via $zscaler_interface"
                elif sudo route -n add -inet6 "$route" -interface "$zscaler_interface" &>/dev/null; then
                    log SUCCESS "Route applied: $route via $zscaler_interface"
                else
                    log WARN "Failed to apply route: $route"
                fi
            else
                if netstat -rn -f inet | grep -q "^${route//\//\\/}[[:space:]]"; then
                    vlog "Route already active: $route via $zscaler_interface"
                elif sudo route -n add -net "$route" -interface "$zscaler_interface" &>/dev/null; then
                    log SUCCESS "Route applied: $route via $zscaler_interface"
                else
                    log WARN "Failed to apply route: $route"
                fi
            fi
        done
    elif [[ "$mode" == "bypass" ]]; then
        local default_gateway
        default_gateway=$(route -n get default | grep 'gateway:' | sed -E 's,.*:[[:space:]]*,,')
        if [[ -z "$default_gateway" ]]; then
            log WARN "Default gateway not detected (route will be applied by daemon)"
            return 1
        fi
        local route
        for route in "${ips[@]}"; do
            if [[ "$route" =~ : ]]; then
                if netstat -rn -f inet6 | grep -q "^${route//\//\\/}[[:space:]]"; then
                    vlog "Direct override already active: $route"
                elif sudo route -n add -inet6 "$route" -gateway "$default_gateway" &>/dev/null; then
                    log SUCCESS "Direct override applied: $route via $default_gateway"
                else
                    log WARN "Failed to apply direct override: $route"
                fi
            else
                if netstat -rn -f inet | grep -q "^${route//\//\\/}[[:space:]]"; then
                    vlog "Direct override already active: $route"
                elif sudo route -n add -net "$route" -gateway "$default_gateway" &>/dev/null; then
                    log SUCCESS "Direct override applied: $route via $default_gateway"
                else
                    log WARN "Failed to apply direct override: $route"
                fi
            fi
        done
    fi
}

# Immediately remove route for a single entry without waiting for daemon
remove_route_now() {
    local entry="$1"
    local ips=()

    if is_url "$entry"; then
        return 0
    elif is_domain "$entry"; then
        local resolved
        resolved=$(resolve_domain "$entry")
        if [[ -z "$resolved" ]]; then
            log WARN "Could not resolve domain: $entry (route will be removed by daemon on next cycle)"
            return 1
        fi
        local ip
        for ip in $resolved; do
            [[ "$ip" =~ / ]] && ips+=("$ip") || ips+=("$ip/32")
        done
    elif validate_ip_cidr "$entry"; then
        ips+=("$entry")
    else
        return 1
    fi

    local route
    for route in "${ips[@]}"; do
        if [[ "$route" =~ : ]]; then
            if sudo route -n delete -inet6 "$route" &>/dev/null; then
                log SUCCESS "Route removed: $route"
            fi
        else
            if sudo route -n delete -net "$route" &>/dev/null; then
                log SUCCESS "Route removed: $route"
            fi
        fi
    done
}

# Ensure configuration directories use the new layout and migrate legacy files
initialize_config_paths() {
    mkdir -p "$USER_CONFIG_DIR"

    if [[ -f "$LEGACY_CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
        if mv "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"; then
            log INFO "Migrated routes config to $CONFIG_FILE"
        else
            log WARN "Failed to migrate legacy routes config from $LEGACY_CONFIG_FILE"
        fi
    fi

    if [[ -f "$LEGACY_BYPASS_CONFIG_FILE" && ! -f "$BYPASS_CONFIG_FILE" ]]; then
        if mv "$LEGACY_BYPASS_CONFIG_FILE" "$BYPASS_CONFIG_FILE"; then
            log INFO "Migrated direct override config to $BYPASS_CONFIG_FILE"
        else
            log WARN "Failed to migrate legacy direct override config from $LEGACY_BYPASS_CONFIG_FILE"
        fi
    fi

    if [[ -f "$LEGACY_CONFIG_MTIME_FILE" && ! -f "$CONFIG_MTIME_FILE" ]]; then
        mv "$LEGACY_CONFIG_MTIME_FILE" "$CONFIG_MTIME_FILE" 2>/dev/null || true
    fi
}

# Auto-update functions

# Check if script is in a git repository
is_git_repo() {
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Get current script version (git commit hash)
get_current_version() {
    if is_git_repo; then
        git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null
    else
        echo "unknown"
    fi
}

# Get remote version (latest commit hash)
get_remote_version() {
    if is_git_repo; then
        git -C "$SCRIPT_DIR" fetch origin >/dev/null 2>&1 && \
            git -C "$SCRIPT_DIR" rev-parse --short origin/main 2>/dev/null
    else
        echo "unknown"
    fi
}

# Check if updates are available
check_for_updates() {
    local current_version
    current_version=$(get_current_version)
    local remote_version
    remote_version=$(get_remote_version)

    if [[ "$current_version" == "unknown" ]]; then
        log ERROR "Not in a git repository - cannot check for updates"
        return 1
    fi

    if [[ "$remote_version" == "unknown" ]]; then
        log ERROR "Cannot fetch remote version - check network connection"
        return 1
    fi

    if [[ "$current_version" != "$remote_version" ]]; then
        log INFO "Update available!"
        log INFO "Current version: $current_version"
        log INFO "Remote version:  $remote_version"
        return 0
    else
        log INFO "Script is up to date (version: $current_version)"
        return 1
    fi
}

# Create backup of current script
create_backup() {
    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_name="$SCRIPT_NAME.$backup_timestamp.backup"
    local backup_path="$BACKUP_DIR/$backup_name"

    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"

    # Copy current script to backup
    if cp "$SCRIPT_DIR/$SCRIPT_NAME" "$backup_path"; then
        log SUCCESS "Backup created: $backup_path"

        # Keep only last 5 backups (filenames contain sortable timestamp)
        local backups_to_remove=()
        while IFS= read -r backup; do
            backups_to_remove+=("$backup")
        done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$BACKUP_PATTERN" -print 2>/dev/null | sort -r | tail -n +6)

        for old_backup in "${backups_to_remove[@]}"; do
            rm -f "$old_backup" 2>/dev/null || true
        done

        echo "$backup_path"
        return 0
    else
        log ERROR "Failed to create backup"
        return 1
    fi
}

# Restore from backup
restore_backup() {
    local backup_file="$1"

    if [[ -z "$backup_file" ]]; then
        # Find the most recent backup
        local latest_backup
        latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$BACKUP_PATTERN" -print 2>/dev/null | sort -r | head -n 1)
        backup_file="$latest_backup"
        if [[ -z "$backup_file" ]]; then
            log ERROR "No backup files found in $BACKUP_DIR"
            return 1
        fi
    fi

    if [[ ! -f "$backup_file" ]]; then
        log ERROR "Backup file not found: $backup_file"
        return 1
    fi

    if cp "$backup_file" "$SCRIPT_DIR/$SCRIPT_NAME"; then
        chmod +x "$SCRIPT_DIR/$SCRIPT_NAME"
        log SUCCESS "Script restored from backup: $(basename "$backup_file")"
        return 0
    else
        log ERROR "Failed to restore from backup"
        return 1
    fi
}

# Perform auto-update
auto_update() {
    local force_update="$1"

    log INFO "Checking for script updates..."

    if ! is_git_repo; then
        log ERROR "Script is not in a git repository - cannot auto-update"
        log INFO "Manual update required or re-download from source"
        return 1
    fi

    # Check if daemon is running and stop it
    local daemon_was_running=false
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log INFO "Stopping daemon for update..."
            daemon_was_running=true
            stop_split_tunnel
        fi
    fi

    # Fetch latest changes
    if ! git -C "$SCRIPT_DIR" fetch origin; then
        log ERROR "Failed to fetch updates from remote repository"
        return 1
    fi

    local current_version
    current_version=$(get_current_version)
    local remote_version
    remote_version=$(git -C "$SCRIPT_DIR" rev-parse --short origin/main 2>/dev/null)

    if [[ "$current_version" == "$remote_version" ]] && [[ "$force_update" != "force" ]]; then
        log INFO "Script is already up to date (version: $current_version)"

        # Restart daemon if it was running
        if [[ "$daemon_was_running" == "true" ]]; then
            log INFO "Restarting daemon..."
            start_split_tunnel
        fi
        return 0
    fi

    log INFO "Updating from version $current_version to $remote_version"

    # Create backup before update
    local backup_path
    if ! backup_path=$(create_backup); then
        log ERROR "Failed to create backup - aborting update"
        return 1
    fi

    # Check for uncommitted changes
    if ! git -C "$SCRIPT_DIR" diff --quiet || ! git -C "$SCRIPT_DIR" diff --cached --quiet; then
        log WARN "Uncommitted changes detected - they will be stashed"
        git -C "$SCRIPT_DIR" stash push -m "Auto-stash before update $(date)" || {
            log ERROR "Failed to stash changes"
            return 1
        }
    fi

    # Pull latest changes
    if git -C "$SCRIPT_DIR" pull origin main; then
        local new_version
        new_version=$(get_current_version)
        log SUCCESS "Script updated successfully!"
        log SUCCESS "Updated from $current_version to $new_version"

        # Make sure script is executable
        chmod +x "$SCRIPT_DIR/$SCRIPT_NAME"

        # Restart daemon if it was running
        if [[ "$daemon_was_running" == "true" ]]; then
            log INFO "Restarting daemon with updated script..."
            start_split_tunnel
        fi

        log INFO "Backup saved at: $backup_path"
        return 0
    else
        log ERROR "Update failed - restoring from backup"
        restore_backup "$backup_path"

        # Restart daemon if it was running
        if [[ "$daemon_was_running" == "true" ]]; then
            log INFO "Restarting daemon..."
            start_split_tunnel
        fi
        return 1
    fi
}

# Show version information
show_version() {
    local current_version
    current_version=$(get_current_version)
    local script_path="$SCRIPT_DIR/$SCRIPT_NAME"

    echo -e "${BLUE}=== Zscaler Split Tunnel Script Version Info ===${NC}"
    echo -e "Script Path: $script_path"
    echo -e "Current Version: $current_version"

    if is_git_repo; then
        local remote_version
        remote_version=$(get_remote_version)
        local branch
        branch=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
        local remote_url
        remote_url=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "unknown")

        echo -e "Git Branch: $branch"
        echo -e "Remote URL: $remote_url"
        echo -e "Remote Version: $remote_version"

        if [[ "$current_version" != "$remote_version" ]] && [[ "$remote_version" != "unknown" ]]; then
            echo -e "\nUpdate Status: ${YELLOW}Update Available${NC}"
            echo -e "Run '$0 --update' to update to the latest version"
        else
            echo -e "\nUpdate Status: ${GREEN}Up to Date${NC}"
        fi

        # Show recent commits
        echo -e "\n${BLUE}Recent Changes:${NC}"
        git -C "$SCRIPT_DIR" log --oneline -5 2>/dev/null || echo "Cannot fetch commit history"
    else
        echo -e "\nUpdate Status: ${RED}Not in git repository${NC}"
        echo -e "Auto-update not available"
    fi

    # Show backup information
    if [[ -d "$BACKUP_DIR" ]]; then
        local backups=()
        while IFS= read -r backup; do
            backups+=("$backup")
        done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$BACKUP_PATTERN" -print 2>/dev/null | sort -r)

        local backup_count=${#backups[@]}
        echo -e "\nBackups: $backup_count backup(s) available in $BACKUP_DIR"
        if [[ $backup_count -gt 0 ]]; then
            echo -e "Latest backup: $(basename "${backups[0]}")"
        fi
    fi
}

# Check if running as root when needed
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        log ERROR "This operation requires sudo privileges"
        exit 1
    fi
}

# Remove a single route
remove_route() {
    local route=$1
    local ipv=$2

    if [ "$ipv" = "ipv6" ]; then
        if sudo route -n delete -inet6 "$route" 2>/dev/null; then
            vlog "Removed IPv6 route: $route"
            return 0
        fi
    else
        if sudo route -n delete -net "$route" 2>/dev/null; then
            vlog "Removed IPv4 route: $route"
            return 0
        fi
    fi
    return 1
}

# Remove all broad routes
remove_broad_routes() {
    local removed_count=0
    local zscaler_interface
    zscaler_interface=$(detect_zscaler_interface)

    if [ -n "$zscaler_interface" ]; then
        vlog "Detected Zscaler interface: $zscaler_interface"
    fi

    # Remove IPv4 routes
    for route in "${IPV4_BROAD_ROUTES[@]}"; do
        if remove_route "$route" "ipv4"; then
            ((removed_count++))
        fi
    done

    # Remove IPv6 routes
    for route in "${IPV6_BROAD_ROUTES[@]}"; do
        if remove_route "$route" "ipv6"; then
            ((removed_count++))
        fi
    done

    # Also check for and remove any default IPv6 routes through Zscaler interface
    if [ -n "$zscaler_interface" ]; then
        # Remove default IPv6 routes that go through the Zscaler interface
        if sudo route -n delete -inet6 default -interface "$zscaler_interface" 2>/dev/null; then
            vlog "Removed default IPv6 route through $zscaler_interface"
            ((removed_count++))
        fi
    fi

    if [ $removed_count -gt 0 ]; then
        log SUCCESS "Removed $removed_count broad routes"
    else
        vlog "No broad routes found to remove"
    fi
}

# Check if a route exists
route_exists() {
    local route=$1
    local ipv=$2

    if [ "$ipv" = "ipv6" ]; then
        netstat -rn -f inet6 | grep -q "^${route//\//\\/}[[:space:]]"
    else
        netstat -rn -f inet | grep -q "^${route//\//\\/}[[:space:]]"
    fi
}

# List current routes
list_routes() {
    local zscaler_interface
    zscaler_interface=$(detect_zscaler_interface)

    echo -e "\n${BLUE}=== Zscaler Interface ===${NC}"
    if [ -n "$zscaler_interface" ]; then
        echo -e "Interface: ${GREEN}$zscaler_interface${NC}"
        echo -e "Gateway: ${GREEN}100.64.0.1${NC}"
    else
        echo -e "Interface: ${RED}Not detected${NC}"
    fi

    echo -e "\n${BLUE}=== Current IPv4 Routes ===${NC}"
    netstat -rn -f inet | head -20

    echo -e "\n${BLUE}=== Current IPv6 Routes ===${NC}"
    netstat -rn -f inet6 | head -20

    echo -e "\n${YELLOW}=== Broad Routes Status ===${NC}"
    echo "IPv4 Broad Routes:"
    for route in "${IPV4_BROAD_ROUTES[@]}"; do
        if route_exists "$route" "ipv4"; then
            echo -e "  ${RED}✗${NC} $route (present)"
        else
            echo -e "  ${GREEN}✓${NC} $route (removed)"
        fi
    done

    echo -e "\nIPv6 Broad Routes:"
    for route in "${IPV6_BROAD_ROUTES[@]}"; do
        if route_exists "$route" "ipv6"; then
            echo -e "  ${RED}✗${NC} $route (present)"
        else
            echo -e "  ${GREEN}✓${NC} $route (removed)"
        fi
    done

    # Check for default IPv6 routes through Zscaler
    if [ -n "$zscaler_interface" ]; then
        if netstat -rn -f inet6 | grep -q "^default.*$zscaler_interface"; then
            echo -e "\n${YELLOW}Note:${NC} Default IPv6 route through $zscaler_interface detected"
        fi
    fi
}

# Check if config file has been modified
config_has_changed() {
    local tracked_files=(
        "$CONFIG_FILE"
        "$LEGACY_CONFIG_FILE"
        "$BYPASS_CONFIG_FILE"
        "$LEGACY_BYPASS_CONFIG_FILE"
    )

    local signature=""
    local file
    for file in "${tracked_files[@]}"; do
        local stamp="missing"
        if [[ -f "$file" ]]; then
            stamp=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo 0)
        fi
        signature+="$file:$stamp;"
    done

    local last_signature=""
    if [[ -f "$CONFIG_MTIME_FILE" ]]; then
        last_signature=$(cat "$CONFIG_MTIME_FILE")
    elif [[ -f "$LEGACY_CONFIG_MTIME_FILE" ]]; then
        last_signature=$(cat "$LEGACY_CONFIG_MTIME_FILE")
    fi

    if [[ "$signature" != "$last_signature" ]]; then
        mkdir -p "$USER_CONFIG_DIR"
        echo "$signature" > "$CONFIG_MTIME_FILE"
        return 0  # Config has changed
    fi

    return 1  # Config has not changed
}

# Monitor and remove routes continuously
monitor_routes() {
    log INFO "Starting route monitoring (interval: ${INTERVAL}s)"
    log INFO "Process ID: $$"
    echo $$ > "$DAEMON_PID_FILE"

    # Trap signals to clean up
    trap 'log INFO "Stopping route monitoring"; rm -f "$DAEMON_PID_FILE" "$CONFIG_MTIME_FILE" "$LEGACY_CONFIG_MTIME_FILE"; exit 0' SIGTERM SIGINT
    local reload_requested=0
    trap 'reload_requested=1' SIGUSR1

    # Initial config load
    load_config
    load_bypass_config

    # Track network signature for change detection
    local last_network_signature=""
    last_network_signature=$(get_network_signature)
    vlog "Initial network: $last_network_signature"

    while true; do
        # Check for network changes
        local current_network_signature
        current_network_signature=$(get_network_signature)

        if [[ -n "$last_network_signature" ]] && [[ "$current_network_signature" != "$last_network_signature" ]]; then
            log INFO "Network changed from '$last_network_signature' to '$current_network_signature'"
            handle_network_change
            last_network_signature="$current_network_signature"
            # Skip other checks this iteration since we just refreshed everything
            sleep "$INTERVAL" || true
            continue
        fi

        last_network_signature="$current_network_signature"

        # Check if config has changed or a reload was requested
        if config_has_changed || (( reload_requested )); then
            if (( reload_requested )); then
                log INFO "Reload signal received, refreshing configuration..."
            else
                log INFO "Configuration file changed, reloading..."
            fi
            reload_requested=0
            # Clear caches and remove old routes before loading new ones
            clear_dns_cache
            remove_custom_routes
            remove_bypass_routes
            # Reload config
            load_config
            load_bypass_config
        fi

        # Remove broad routes
        remove_broad_routes

        # Add Zscaler routes through the tunnel
        add_custom_routes

        # Add direct overrides
        add_bypass_routes

        sleep "$INTERVAL" || true
    done
}

# Install LaunchDaemon to auto-start the monitoring daemon on boot
enable_autostart() {
    check_sudo

    local plist_path="$AUTOSTART_PLIST_PATH"
    local script_path="$SCRIPT_DIR/$SCRIPT_NAME"

    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path"
    fi

    cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AUTOSTART_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$script_path</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF

    chmod 644 "$plist_path"
    chown root:wheel "$plist_path"

    launchctl bootout system "$plist_path" 2>/dev/null || true
    if launchctl bootstrap system "$plist_path"; then
        log SUCCESS "Autostart enabled via $plist_path"
    else
        log ERROR "Failed to load LaunchDaemon from $plist_path"
        return 1
    fi
}

# Remove LaunchDaemon autostart configuration
disable_autostart() {
    check_sudo

    local plist_path="$AUTOSTART_PLIST_PATH"

    if [[ -f "$plist_path" ]]; then
        launchctl bootout system "$plist_path" 2>/dev/null || true
        rm -f "$plist_path"
        log SUCCESS "Autostart disabled and LaunchDaemon removed"
    else
        log INFO "No autostart LaunchDaemon found at $plist_path"
    fi
}

# Start split tunneling
start_split_tunnel() {
    log INFO "Starting Zscaler split tunneling"

    local console_user
    console_user=$(get_console_user)
    local console_uid=""
    console_uid=$(id -u "$console_user" 2>/dev/null || printf '')
    local console_domain=""
    if [[ -n "$console_uid" ]]; then
        console_domain="gui/$console_uid"
    fi

    # Ensure launchd jobs are loaded so Zscaler can restart cleanly later
    while IFS= read -r daemon; do
        [[ -z "$daemon" ]] && continue
        if launchctl bootstrap system "$daemon" 2>/dev/null; then
            vlog "Bootstrapped LaunchDaemon: $daemon"
        elif launchctl load "$daemon" 2>/dev/null; then
            vlog "Loaded LaunchDaemon: $daemon"
        fi
    done < <(find /Library/LaunchDaemons -type f -name '*zscaler*' 2>/dev/null)

    if [[ -n "$console_domain" ]]; then
        while IFS= read -r agent; do
            [[ -z "$agent" ]] && continue
            if launchctl bootstrap "$console_domain" "$agent" 2>/dev/null; then
                vlog "Bootstrapped LaunchAgent for $console_user: $agent"
            elif command -v sudo >/dev/null 2>&1 && sudo -u "$console_user" launchctl load "$agent" 2>/dev/null; then
                vlog "Loaded LaunchAgent for $console_user: $agent"
            fi
        done < <(find /Library/LaunchAgents -type f -name '*zscaler*' 2>/dev/null)
    fi

    # Check if Zscaler is already running
    if ! pgrep -x "Zscaler" > /dev/null; then
        log INFO "Starting Zscaler application and services"
        open -a /Applications/Zscaler/Zscaler.app --hide
        sleep 2  # Give Zscaler time to start
    else
        log INFO "Zscaler is already running"
    fi

    # Load configuration
    load_config
    load_bypass_config

    # Initial removal of broad routes
    remove_broad_routes

    # Add Zscaler routes through the tunnel
    add_custom_routes

    # Add direct overrides
    add_bypass_routes

    # Check if daemon is already running
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log WARN "Split tunnel daemon already running (PID: $pid)"
            return
        else
            rm -f "$DAEMON_PID_FILE"
        fi
    fi

    # Start monitoring in background
    log INFO "Starting background monitoring daemon"
    local verbose_flag=()
    if [[ $VERBOSE -eq 1 ]]; then
        verbose_flag=(--verbose)
    fi
    nohup "$0" --daemon --interval "$INTERVAL" "${verbose_flag[@]}" > /dev/null 2>&1 &

    sleep 1
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE")
        log SUCCESS "Split tunnel daemon started (PID: $pid)"
        log INFO "Routes will be checked every ${INTERVAL} seconds"
    else
        log ERROR "Failed to start daemon"
    fi
}

# Stop split tunneling
stop_split_tunnel() {
    log INFO "Stopping Zscaler split tunneling"

    # Load config to remove Zscaler routes and direct overrides
    load_config
    load_bypass_config
    remove_custom_routes
    remove_bypass_routes

    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE")
        if kill "$pid" 2>/dev/null; then
            log SUCCESS "Split tunnel daemon stopped"
            rm -f "$DAEMON_PID_FILE" "$CONFIG_MTIME_FILE"
        else
            log WARN "Daemon not running or already stopped"
            rm -f "$DAEMON_PID_FILE" "$CONFIG_MTIME_FILE"
        fi
    else
        log WARN "No daemon PID file found"
    fi
}

# Kill Zscaler completely
kill_zscaler() {
    log INFO "Killing Zscaler application and services"

    # First stop the split tunnel daemon if running
    if [ -f "$DAEMON_PID_FILE" ]; then
        stop_split_tunnel
    fi

    # Warm sudo cache so unload commands do not stall mid-way
    if command -v sudo >/dev/null 2>&1; then
        sudo whoami > /dev/null
    fi

    local console_user
    console_user=$(get_console_user)
    local console_uid=""
    console_uid=$(id -u "$console_user" 2>/dev/null || printf '')
    local console_domain=""
    if [[ -n "$console_uid" ]]; then
        console_domain="gui/$console_uid"
    fi

    local agents_removed=0
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        if [[ -n "$console_domain" ]] && launchctl bootout "$console_domain" "$agent" 2>/dev/null; then
            vlog "Booted LaunchAgent for $console_user: $agent"
            ((agents_removed++))
        elif launchctl unload "$agent" 2>/dev/null; then
            vlog "Unloaded LaunchAgent: $agent"
            ((agents_removed++))
        else
            log WARN "Failed to unload LaunchAgent: $agent"
        fi
    done < <(find /Library/LaunchAgents -type f -name '*zscaler*' 2>/dev/null)

    local daemons_removed=0
    while IFS= read -r daemon; do
        [[ -z "$daemon" ]] && continue
        if launchctl bootout system "$daemon" 2>/dev/null; then
            vlog "Booted LaunchDaemon: $daemon"
            ((daemons_removed++))
        elif launchctl unload "$daemon" 2>/dev/null; then
            vlog "Unloaded LaunchDaemon: $daemon"
            ((daemons_removed++))
        else
            log WARN "Failed to unload LaunchDaemon: $daemon"
        fi
    done < <(find /Library/LaunchDaemons -type f -name '*zscaler*' 2>/dev/null)

    local processes_killed=0
    local process
    for process in Zscaler ZSTunnel ZSTray ZTunnelService; do
        if pkill -x "$process" 2>/dev/null || killall "$process" 2>/dev/null; then
            log INFO "Stopped process: $process"
            ((processes_killed++))
        fi
    done

    if pgrep -x Zscaler > /dev/null || pgrep -x ZSTunnel > /dev/null; then
        log WARN "Some Zscaler processes are still running; they may require manual intervention"
    else
        log SUCCESS "Zscaler services stopped (agents: $agents_removed, daemons: $daemons_removed, processes: $processes_killed)"
    fi
}

# Show status
show_status() {
    local zscaler_interface
    zscaler_interface=$(detect_zscaler_interface)

    echo -e "${BLUE}=== Zscaler Split Tunnel Status ===${NC}"

    # Check daemon status
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid
        pid=$(cat "$DAEMON_PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "Daemon Status: ${GREEN}Running${NC} (PID: $pid)"
        else
            echo -e "Daemon Status: ${RED}Not Running${NC} (stale PID file)"
        fi
    else
        echo -e "Daemon Status: ${RED}Not Running${NC}"
    fi

    # Check Zscaler status
    if pgrep -x "Zscaler" > /dev/null; then
        echo -e "Zscaler Status: ${GREEN}Running${NC}"
    else
        echo -e "Zscaler Status: ${RED}Not Running${NC}"
    fi

    # Show Zscaler interface
    if [ -n "$zscaler_interface" ]; then
        echo -e "Zscaler Interface: ${GREEN}$zscaler_interface${NC}"
    else
        echo -e "Zscaler Interface: ${RED}Not detected${NC}"
    fi

    # Count broad routes
    local ipv4_count=0
    local ipv6_count=0

    for route in "${IPV4_BROAD_ROUTES[@]}"; do
        if route_exists "$route" "ipv4"; then
            ((ipv4_count++))
        fi
    done

    for route in "${IPV6_BROAD_ROUTES[@]}"; do
        if route_exists "$route" "ipv6"; then
            ((ipv6_count++))
        fi
    done

    echo -e "\nBroad Routes Present:"
    echo -e "  IPv4: ${ipv4_count}/${#IPV4_BROAD_ROUTES[@]}"
    echo -e "  IPv6: ${ipv6_count}/${#IPV6_BROAD_ROUTES[@]}"

    # Load config to show Zscaler routes
    load_config > /dev/null 2>&1
    echo -e "\nZscaler Routes: ${#CUSTOM_ROUTES[@]} configured"

    if [[ $ipv4_count -eq 0 ]] && [[ $ipv6_count -eq 0 ]]; then
        echo -e "\nSplit Tunneling: ${GREEN}Active${NC} (all broad routes removed)"
    elif [[ $ipv4_count -gt 0 ]] || [[ $ipv6_count -gt 0 ]]; then
        echo -e "\nSplit Tunneling: ${YELLOW}Partial${NC} (some broad routes present)"
    fi

    # Show which specific routes are still present
    if [[ $ipv4_count -gt 0 ]] || [[ $ipv6_count -gt 0 ]]; then
        echo -e "\n${YELLOW}Routes still present:${NC}"
        for route in "${IPV4_BROAD_ROUTES[@]}"; do
            if route_exists "$route" "ipv4"; then
                echo -e "  IPv4: $route"
            fi
        done
        for route in "${IPV6_BROAD_ROUTES[@]}"; do
            if route_exists "$route" "ipv6"; then
                echo -e "  IPv6: $route"
            fi
        done
    fi
}

# Add entries to config file
add_to_config() {
    local entry="$1"

    if [[ -z "$entry" ]]; then
        log ERROR "No entry provided"
        return 1
    fi

    # Validate entry
    if ! is_domain "$entry" && ! validate_ip_cidr "$entry" && ! is_url "$entry"; then
        log ERROR "Invalid entry: $entry (must be a domain, IP address, CIDR range, or URL)"
        return 1
    fi

    # Ensure config directory exists
    mkdir -p "$USER_CONFIG_DIR"

    # Check if already exists
    if [[ -f "$CONFIG_FILE" ]] && grep -Fxq "$entry" "$CONFIG_FILE" 2>/dev/null; then
        log WARN "Entry already exists in user config: $entry"
        apply_route_now "$entry" "custom"
        return 0
    fi

    if [[ -f "$DEFAULT_CONFIG_FILE" ]] && grep -Fxq "$entry" "$DEFAULT_CONFIG_FILE" 2>/dev/null; then
        log WARN "Entry already present in default config: $entry"
        apply_route_now "$entry" "custom"
        return 0
    fi

    # Add to config
    echo "$entry" >> "$CONFIG_FILE"
    log SUCCESS "Added to config: $entry"

    apply_route_now "$entry" "custom"
    trigger_daemon_reload
}

# Remove entries from config file
remove_from_config() {
    local entry="$1"

    if [[ -z "$entry" ]]; then
        log ERROR "No entry provided"
        return 1
    fi

    # Remove from config
    local temp_file
    temp_file=$(mktemp)
    if [[ -f "$CONFIG_FILE" ]]; then
        grep -Fxv "$entry" "$CONFIG_FILE" > "$temp_file" || true
    fi

    if [[ -f "$CONFIG_FILE" && $(wc -l < "$temp_file") -lt $(wc -l < "$CONFIG_FILE") ]]; then
        mv "$temp_file" "$CONFIG_FILE"
        log SUCCESS "Removed from config: $entry"
        remove_route_now "$entry"
        trigger_daemon_reload
    else
        rm -f "$temp_file"
        if [[ -f "$DEFAULT_CONFIG_FILE" ]] && grep -Fxq "$entry" "$DEFAULT_CONFIG_FILE" 2>/dev/null; then
            log WARN "Entry is provided by the default config: $entry"
        else
            log WARN "Entry not found in user config: $entry"
        fi
    fi
}

# Add entries to direct override config file
add_to_bypass_config() {
    local entry="$1"

    if [[ -z "$entry" ]]; then
        log ERROR "No entry provided"
        return 1
    fi

    # Validate entry
    if ! is_domain "$entry" && ! validate_ip_cidr "$entry" && ! is_url "$entry"; then
        log ERROR "Invalid entry: $entry (must be a domain, IP address, CIDR range, or URL)"
        return 1
    fi

    # Ensure config directory exists
    mkdir -p "$USER_CONFIG_DIR"

    # Check if already exists
    if [[ -f "$BYPASS_CONFIG_FILE" ]] && grep -Fxq "$entry" "$BYPASS_CONFIG_FILE" 2>/dev/null; then
        log WARN "Entry already exists in direct override config: $entry"
        apply_route_now "$entry" "bypass"
        return 0
    fi

    if [[ -f "$DEFAULT_BYPASS_FILE" ]] && grep -Fxq "$entry" "$DEFAULT_BYPASS_FILE" 2>/dev/null; then
        log WARN "Entry already present in default direct override config: $entry"
        apply_route_now "$entry" "bypass"
        return 0
    fi

    # Add to direct override config
    echo "$entry" >> "$BYPASS_CONFIG_FILE"
    log SUCCESS "Added to direct override config: $entry"

    apply_route_now "$entry" "bypass"
    trigger_daemon_reload
}

# Remove entries from direct override config file
remove_from_bypass_config() {
    local entry="$1"

    if [[ -z "$entry" ]]; then
        log ERROR "No entry provided"
        return 1
    fi

    # Remove from config
    local temp_file
    temp_file=$(mktemp)
    if [[ -f "$BYPASS_CONFIG_FILE" ]]; then
        grep -Fxv "$entry" "$BYPASS_CONFIG_FILE" > "$temp_file" || true
    fi

    if [[ -f "$BYPASS_CONFIG_FILE" && $(wc -l < "$temp_file") -lt $(wc -l < "$BYPASS_CONFIG_FILE") ]]; then
        mv "$temp_file" "$BYPASS_CONFIG_FILE"
        log SUCCESS "Removed from direct override config: $entry"
        remove_route_now "$entry"
        trigger_daemon_reload
    else
        rm -f "$temp_file"
        if [[ -f "$DEFAULT_BYPASS_FILE" ]] && grep -Fxq "$entry" "$DEFAULT_BYPASS_FILE" 2>/dev/null; then
            log WARN "Entry is provided by the default direct override config: $entry"
        else
            log WARN "Entry not found in user direct override config: $entry"
        fi
    fi
}

# Show direct override config
show_bypass_config() {
    echo -e "${BLUE}=== Direct Overrides Configuration ===${NC}"
    echo -e "Default config: $DEFAULT_BYPASS_FILE"
    echo -e "User overrides: $BYPASS_CONFIG_FILE\n"

    local displayed=0
    local source
    for source in "$DEFAULT_BYPASS_FILE" "$BYPASS_CONFIG_FILE"; do
        if [[ -f "$source" ]] && [[ -s "$source" ]]; then
            echo "Entries from $source:"
            cat -n "$source"
            echo
            displayed=1
        fi
    done

    if (( ! displayed )); then
        echo "No direct overrides configured."
        echo -e "\nTo add direct overrides, use:"
        echo "  $0 --add-bypass <domain|ip|cidr>"
        return
    fi

    # Load and show resolved routes
    load_bypass_config > /dev/null 2>&1

    if [[ ${#BYPASS_ROUTES[@]} -gt 0 ]]; then
        echo -e "\n${GREEN}Resolved direct overrides:${NC}"
        for route in "${BYPASS_ROUTES[@]}"; do
            echo "  $route"
        done
    fi
}

# Show Zscaler route config
show_config() {
    echo -e "${BLUE}=== Zscaler Routes Configuration ===${NC}"
    echo -e "Default config: $DEFAULT_CONFIG_FILE"
    echo -e "User overrides: $CONFIG_FILE\n"

    local displayed=0
    local source
    for source in "$DEFAULT_CONFIG_FILE" "$CONFIG_FILE"; do
        if [[ -f "$source" ]] && [[ -s "$source" ]]; then
            echo "Entries from $source:"
            cat -n "$source"
            echo
            displayed=1
        fi
    done

    if (( ! displayed )); then
        echo "No Zscaler routes configured."
        echo -e "\nTo add routes, use:"
        echo "  $0 --add <domain|ip|cidr>"
        return
    fi

    # Load and show resolved routes
    load_config > /dev/null 2>&1

    if [[ ${#CUSTOM_ROUTES[@]} -gt 0 ]]; then
        echo -e "\n${GREEN}Resolved routes:${NC}"
        for route in "${CUSTOM_ROUTES[@]}"; do
            echo "  $route"
        done
    fi
}

# Print usage
usage() {
    cat << EOF
Zscaler Split Tunneling Script for macOS

Usage: $0 [command] [options]

Commands accept an optional leading "--" (use 'start' or '--start').

Options:
    --start / start        Start split tunneling (default)
    --stop / stop          Stop split tunneling monitoring
    --kill / kill          Kill Zscaler completely (app and services)
    --status / status      Show current route status
    --list / list          List all current routes
    --daemon / daemon      Run as daemon (keeps removing routes)
    --interval / interval N   Check interval in seconds (default: 30)
    --verbose / verbose    Enable verbose output
    --help / help          Show this help message

Update Options:
    --update / update             Update script to latest version from git
    --update-force / update-force Force update even if already up to date
    --check / check               Check for available updates
    --version / version           Show version information and update status
    --restore / restore [BACKUP]  Restore script from most recent backup

Zscaler Routes Options:
    --add / add ENTRY               Add domain/IP/CIDR to route through Zscaler
    --remove / remove ENTRY         Remove domain/IP/CIDR from config
    --show-config / show-config     Show current Zscaler routes configuration
    --clear-config / clear-config   Clear all Zscaler routes

Direct Override Options (for AI tools, etc.):
    --add-bypass / add-bypass ENTRY          Add domain/IP/CIDR to route directly
    --remove-bypass / remove-bypass ENTRY    Remove domain/IP/CIDR from direct override config
    --show-bypass / show-bypass              Show current direct override configuration
    --clear-bypass / clear-bypass            Clear all direct overrides

Autostart Options:
    --enable-autostart / enable-autostart    Install launchd job so daemon starts on boot
    --disable-autostart / disable-autostart  Remove launchd job

Examples:
    # Start split tunneling with default settings
    sudo $0 --start
    sudo $0 start

    # Check for updates and show version info
    $0 --check
    $0 --version

    # Update script to latest version
    $0 --update

    # Force update even if up to date
    $0 --update-force

    # Add specific domains/IPs to route through Zscaler
    $0 --add example.com
    $0 --add 192.168.1.0/24
    $0 --add 10.0.0.5

    # Add AI tools as direct overrides
    $0 --add-bypass api.openai.com
    $0 --add-bypass claude.ai
    $0 --add-bypass api.anthropic.com

    # Show Zscaler routes configuration
    $0 --show-config

    # Start with custom interval and verbose output
    sudo $0 --start --interval 10 --verbose

    # Check status
    $0 --status
    $0 status

    # Stop split tunneling
    sudo $0 --stop

    # Restore from backup if update fails
    $0 --restore

Configuration File:
    Default Zscaler routes: $DEFAULT_CONFIG_FILE
    User Zscaler routes:    $CONFIG_FILE
    Default direct overrides: $DEFAULT_BYPASS_FILE
    User direct overrides:    $BYPASS_CONFIG_FILE

    Format: One entry per line (domain, IP, or CIDR)
    Comments start with #

    Example config file:
    # Corporate resources
    internal.company.com
    vpn.company.com
    192.168.100.0/24
    10.0.0.50

EOF
}

# Main function
main() {
    local action="start"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --start|start)
                action="start"
                shift
                ;;
            --stop|stop)
                action="stop"
                shift
                ;;
            --kill|kill)
                action="kill"
                shift
                ;;
            --status|status)
                action="status"
                shift
                ;;
            --list|list)
                action="list"
                shift
                ;;
            --daemon|daemon)
                action="daemon"
                shift
                ;;
            --add|add)
                action="add"
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    echo "Error: --add requires an argument (domain, IP, or CIDR)" >&2
                    exit 1
                fi
                ADD_ENTRY="$2"
                shift 2
                ;;
            --remove|remove)
                action="remove"
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    echo "Error: --remove requires an argument (domain, IP, or CIDR)" >&2
                    exit 1
                fi
                REMOVE_ENTRY="$2"
                shift 2
                ;;
            --show-config|show-config)
                action="show-config"
                shift
                ;;
            --clear-config|clear-config)
                action="clear-config"
                shift
                ;;
            --add-bypass|add-bypass)
                action="add-bypass"
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    echo "Error: --add-bypass requires an argument (domain, IP, or CIDR)" >&2
                    exit 1
                fi
                ADD_BYPASS_ENTRY="$2"
                shift 2
                ;;
            --remove-bypass|remove-bypass)
                action="remove-bypass"
                if [[ -z "${2:-}" || "$2" == --* ]]; then
                    echo "Error: --remove-bypass requires an argument (domain, IP, or CIDR)" >&2
                    exit 1
                fi
                REMOVE_BYPASS_ENTRY="$2"
                shift 2
                ;;
            --show-bypass|show-bypass)
                action="show-bypass"
                shift
                ;;
            --clear-bypass|clear-bypass)
                action="clear-bypass"
                shift
                ;;
            --interval|interval)
                INTERVAL="$2"
                shift 2
                ;;
            --verbose|verbose)
                VERBOSE=1
                shift
                ;;
            --update|update)
                action="update"
                shift
                ;;
            --update-force|update-force)
                action="update-force"
                shift
                ;;
            --check|check)
                action="check"
                shift
                ;;
            --version|version)
                action="version"
                shift
                ;;
            --restore|restore)
                action="restore"
                RESTORE_BACKUP="$2"
                if [[ -n "$2" && "$2" != --* ]]; then
                    shift 2
                else
                    shift
                fi
                ;;
            --enable-autostart|enable-autostart)
                action="enable-autostart"
                shift
                ;;
            --disable-autostart|disable-autostart)
                action="disable-autostart"
                shift
                ;;
            --help|-h|help)
                usage
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    initialize_config_paths

    # Execute action
    case $action in
        start)
            check_sudo
            start_split_tunnel
            ;;
        stop)
            check_sudo
            stop_split_tunnel
            ;;
        kill)
            check_sudo
            kill_zscaler
            ;;
        status)
            show_status
            ;;
        list)
            list_routes
            ;;
        daemon)
            check_sudo
            monitor_routes
            ;;
        add)
            add_to_config "$ADD_ENTRY"
            ;;
        remove)
            remove_from_config "$REMOVE_ENTRY"
            ;;
        show-config)
            show_config
            ;;
        clear-config)
            mkdir -p "$USER_CONFIG_DIR"
            if [[ -f "$CONFIG_FILE" ]]; then
                : > "$CONFIG_FILE"
                log SUCCESS "Configuration cleared"
                trigger_daemon_reload
            else
                log INFO "No configuration to clear"
            fi
            ;;
        add-bypass)
            add_to_bypass_config "$ADD_BYPASS_ENTRY"
            ;;
        remove-bypass)
            remove_from_bypass_config "$REMOVE_BYPASS_ENTRY"
            ;;
        show-bypass)
            show_bypass_config
            ;;
        clear-bypass)
            mkdir -p "$USER_CONFIG_DIR"
            if [[ -f "$BYPASS_CONFIG_FILE" ]]; then
                : > "$BYPASS_CONFIG_FILE"
                log SUCCESS "Direct override configuration cleared"
                trigger_daemon_reload
            else
                log INFO "No direct override configuration to clear"
            fi
            ;;
        update)
            auto_update
            ;;
        update-force)
            auto_update "force"
            ;;
        check)
            check_for_updates
            ;;
        version)
            show_version
            ;;
        restore)
            restore_backup "$RESTORE_BACKUP"
            ;;
        enable-autostart)
            enable_autostart
            ;;
        disable-autostart)
            disable_autostart
            ;;
    esac
}

# Run main function
main "$@"
