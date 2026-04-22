#!/bin/bash
# zabbix-proxy-install.sh
# Universal installer for Zabbix Proxy 7.0 LTS + PostgreSQL 17
# Elven Observability - Production-ready with performance tuning
#
# Supported distributions:
# - Ubuntu/Debian (apt)
# - RHEL/CentOS/Rocky/AlmaLinux/Oracle Linux (yum/dnf)
# - Amazon Linux 2/2023 (yum/dnf)

set -Ee -o pipefail

# Never let apt/dpkg pop an interactive prompt mid-install. Without this,
# package config prompts (e.g. kernel restart, conffile diffs) can hang
# the script silently even though apt itself was invoked with -y.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Versions
ZABBIX_VERSION="7.0"
POSTGRES_VERSION="17"

# Directories
ZABBIX_CONF="/etc/zabbix/zabbix_proxy.conf"
POSTGRES_CONF_DIR="/etc/postgresql/${POSTGRES_VERSION}/main"
POSTGRES_DATA_DIR="/var/lib/postgresql/${POSTGRES_VERSION}/main"

# Functions
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${CYAN}$1${NC}"
}

print_header() {
    echo -e "${CYAN}=== $1 ===${NC}"
}

handle_error() {
    local line_no=$1
    local command=${2:-unknown}

    if [ "$POSTGRES_STOPPED_FOR_ZABBIX_INSTALL" = "true" ]; then
        systemctl start postgresql-${POSTGRES_VERSION} > /dev/null 2>&1 || systemctl start postgresql > /dev/null 2>&1 || true
    fi

    print_error "Installation failed at line ${line_no}: ${command}"
    print_info "Review the output above and, if needed, inspect:"
    print_info "  journalctl -u zabbix-proxy -u postgresql-${POSTGRES_VERSION} -u postgresql --no-pager -n 50"
}

trap 'handle_error "${LINENO}" "${BASH_COMMAND}"' ERR

# Runtime defaults
ZABBIX_SERVER="${ZABBIX_SERVER:-}"
PROXY_NAME="${PROXY_NAME:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
PROXY_MODE="${PROXY_MODE:-}"
PERFORMANCE_PROFILE="${PERFORMANCE_PROFILE:-}"
PROXY_OFFLINE_BUFFER="${PROXY_OFFLINE_BUFFER:-72}"
PROXY_CONFIG_FREQUENCY="${PROXY_CONFIG_FREQUENCY:-60}"
DATA_SENDER_FREQUENCY="${DATA_SENDER_FREQUENCY:-5}"
LISTEN_PORT="${LISTEN_PORT:-10051}"
LISTEN_IP="${LISTEN_IP:-}"
SOURCE_IP="${SOURCE_IP:-}"
TLS_MODE="${TLS_MODE:-unencrypted}"
TLS_ACCEPT="${TLS_ACCEPT:-unencrypted}"
TLS_CA_FILE="${TLS_CA_FILE:-}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
TLS_PSK_IDENTITY="${TLS_PSK_IDENTITY:-}"
TLS_PSK_FILE="${TLS_PSK_FILE:-}"
AUTO_CREATE_SWAP="${AUTO_CREATE_SWAP:-auto}"
SWAP_FILE_PATH="${SWAP_FILE_PATH:-/swapfile.elven-zabbix-installer}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
LOW_MEMORY_THRESHOLD_MB="${LOW_MEMORY_THRESHOLD_MB:-2048}"
CLEANUP_MODE="${ELVEN_CLEANUP_MODE:-prompt}"
CLEANUP_BACKUP_ROOT="${ELVEN_CLEANUP_BACKUP_ROOT:-/var/backups/elven-zabbix-proxy}"
TEMP_SWAP_ENABLED="false"
POSTGRES_STOPPED_FOR_ZABBIX_INSTALL="false"
PREVIOUS_INSTALLATION_DETECTED="false"
PREVIOUS_INSTALLATION_FINDINGS=""
CLEANUP_PERFORMED="false"
CLEANUP_BACKUP_DIR=""
CLEANUP_TIMESTAMP=""
FPING_LOCATION=""
FPING6_LOCATION=""

# Check root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (use sudo)"
        exit 1
    fi
}

run_as_user() {
    local target_user=$1
    shift

    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$target_user" -- "$@"
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo -u "$target_user" "$@"
        return
    fi

    print_error "Neither runuser nor sudo is available to execute commands as ${target_user}"
    exit 1
}

# Detect distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        OS_NAME=$NAME
    else
        print_error "Cannot detect Linux distribution"
        exit 1
    fi

    print_info "Detected: $OS_NAME"

    case $OS in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_INSTALL="apt install -y"
            POSTGRES_CONF_DIR="/etc/postgresql/${POSTGRES_VERSION}/main"
            POSTGRES_DATA_DIR="/var/lib/postgresql/${POSTGRES_VERSION}/main"
            ;;
        rhel|centos|rocky|almalinux|ol)
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install -y --setopt=install_weak_deps=False --setopt=max_parallel_downloads=1 --setopt=keepcache=0"
            else
                PKG_MANAGER="yum"
                PKG_INSTALL="yum install -y"
            fi
            POSTGRES_CONF_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            POSTGRES_DATA_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            ;;
        amzn)
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install -y --setopt=install_weak_deps=False --setopt=max_parallel_downloads=1 --setopt=keepcache=0"
            else
                PKG_MANAGER="yum"
                PKG_INSTALL="yum install -y"
            fi
            POSTGRES_CONF_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            POSTGRES_DATA_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            ;;
        fedora)
            print_error "Fedora is not supported by this installer because Zabbix 7.0 does not publish an official Fedora repository."
            exit 1
            ;;
        *)
            print_error "Unsupported distribution: $OS"
            exit 1
            ;;
    esac

    print_success "Package manager: $PKG_MANAGER"
}

refresh_package_metadata() {
    case "$PKG_MANAGER" in
        apt)
            run_long_step "Refreshing APT metadata" apt-get update -qq
            ;;
        dnf)
            run_long_step "Refreshing DNF metadata" dnf makecache --refresh -q
            ;;
        yum)
            run_long_step "Refreshing YUM metadata" bash -c 'yum makecache -q || yum makecache fast -q'
            ;;
    esac
}

# Download with retry. Every attempt has hard connect and total timeouts
# so a dead mirror cannot hang the installer indefinitely.
download_with_retry() {
    local url=$1
    local output=$2
    local max_retries=3
    local retry=0
    local download_ok="false"

    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        echo "  Attempt $retry of $max_retries..."
        rm -f "$output"
        download_ok="false"

        if command -v curl >/dev/null 2>&1; then
            if curl -L -f --connect-timeout 15 --max-time 180 \
                -o "$output" "$url" 2>/dev/null; then
                download_ok="true"
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q --timeout=180 --tries=1 -O "$output" "$url" 2>/dev/null; then
                download_ok="true"
            fi
        else
            print_error "Neither curl nor wget is available for downloads"
            return 1
        fi

        if [ "$download_ok" = "true" ] && [ -f "$output" ] && [ -s "$output" ]; then
            print_success "Download complete!"
            return 0
        fi

        print_warning "Attempt $retry failed"
        [ $retry -lt $max_retries ] && sleep 3
    done

    print_error "Failed to download after $max_retries attempts"
    return 1
}

# Run a command that may take several minutes without hiding it from the user.
# Streams output to a log file, prints a heartbeat every 10s so the user can
# see progress, enforces a hard timeout so a wedged apt/dnf cannot hang the
# installer forever, and tails the log on failure.
#
# Usage: run_long_step "Human-readable description" cmd arg1 arg2 ...
run_long_step() {
    local description=$1
    shift

    local log_file="/tmp/elven-zabbix-step-$$-$(date +%s).log"
    local hard_timeout=900   # 15 minutes
    local cmd_pid rc=0 start_ts elapsed

    print_info "  ${description} (up to ${hard_timeout}s)..."

    if command -v timeout >/dev/null 2>&1; then
        timeout "$hard_timeout" "$@" > "$log_file" 2>&1 &
    else
        "$@" > "$log_file" 2>&1 &
    fi
    cmd_pid=$!
    start_ts=$SECONDS

    while kill -0 "$cmd_pid" 2>/dev/null; do
        sleep 10
        if kill -0 "$cmd_pid" 2>/dev/null; then
            elapsed=$((SECONDS - start_ts))
            printf "    ...still running (%ds)\n" "$elapsed"
        fi
    done

    wait "$cmd_pid" || rc=$?

    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
            print_error "${description} timed out after ${hard_timeout}s."
        else
            print_error "${description} failed (exit ${rc})."
        fi
        print_info "  Last 40 lines of command output:"
        tail -n 40 "$log_file" 2>&1 || true
        rm -f "$log_file"
        return "$rc"
    fi

    rm -f "$log_file"
    return 0
}

# Get memory in GB
get_memory_gb() {
    local mem_kb
    local mem_gb

    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_gb=$((mem_kb / 1024 / 1024))
    if [ "$mem_gb" -lt 1 ]; then
        mem_gb=1
    fi
    echo "$mem_gb"
}

get_memory_mb() {
    awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo
}

get_swap_mb() {
    awk '/SwapTotal/ {print int($2 / 1024)}' /proc/meminfo
}

is_postgresql_initialized() {
    [ -s "${POSTGRES_DATA_DIR}/PG_VERSION" ]
}

append_previous_installation_finding() {
    local finding=$1

    PREVIOUS_INSTALLATION_DETECTED="true"
    if [ -n "$PREVIOUS_INSTALLATION_FINDINGS" ]; then
        PREVIOUS_INSTALLATION_FINDINGS="${PREVIOUS_INSTALLATION_FINDINGS}"$'\n'"  - ${finding}"
    else
        PREVIOUS_INSTALLATION_FINDINGS="  - ${finding}"
    fi
}

package_is_installed() {
    local package_name=$1

    case "$PKG_MANAGER" in
        apt)
            dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -q "install ok installed"
            ;;
        dnf|yum)
            rpm -q "$package_name" > /dev/null 2>&1
            ;;
    esac
}

postgresql_service_name() {
    if systemctl list-unit-files "postgresql-${POSTGRES_VERSION}.service" --no-legend 2>/dev/null | grep -q "^postgresql-${POSTGRES_VERSION}\.service"; then
        echo "postgresql-${POSTGRES_VERSION}"
    else
        echo "postgresql"
    fi
}

postgresql_service_is_active() {
    systemctl is-active --quiet "$(postgresql_service_name)" 2>/dev/null
}

service_unit_exists() {
    local service_name=$1
    systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q "^${service_name}\.service"
}

# Get CPU count
get_cpu_count() {
    nproc
}

is_low_memory_host() {
    [ "$(get_memory_mb)" -lt "$LOW_MEMORY_THRESHOLD_MB" ]
}

ensure_runtime_swap() {
    local memory_mb
    local swap_mb

    memory_mb=$(get_memory_mb)
    swap_mb=$(get_swap_mb)

    case "$AUTO_CREATE_SWAP" in
        false|no|0)
            return 0
            ;;
    esac

    if [ "$memory_mb" -ge "$LOW_MEMORY_THRESHOLD_MB" ] || [ "$swap_mb" -ge 1024 ]; then
        return 0
    fi

    print_warning "Low-memory host detected (${memory_mb}MB RAM, ${swap_mb}MB swap). Enabling temporary swap to protect package installs."

    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE_PATH"; then
        TEMP_SWAP_ENABLED="true"
        return 0
    fi

    if [ ! -f "$SWAP_FILE_PATH" ]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE_PATH" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE_PATH" bs=1M count="$SWAP_SIZE_MB" status=none
        else
            dd if=/dev/zero of="$SWAP_FILE_PATH" bs=1M count="$SWAP_SIZE_MB" status=none
        fi
    fi

    chmod 600 "$SWAP_FILE_PATH"
    mkswap -f "$SWAP_FILE_PATH" > /dev/null 2>&1 || {
        print_warning "Unable to initialize swap file at $SWAP_FILE_PATH. Package installs may still fail on low-memory hosts."
        return 0
    }

    if swapon "$SWAP_FILE_PATH" > /dev/null 2>&1; then
        TEMP_SWAP_ENABLED="true"
        print_success "Temporary swap enabled at $SWAP_FILE_PATH (${SWAP_SIZE_MB}MB)"
    else
        print_warning "Unable to activate swap file at $SWAP_FILE_PATH. Package installs may still fail on low-memory hosts."
    fi
}

pause_postgresql_for_low_memory_install() {
    if ! is_low_memory_host; then
        return 0
    fi

    if systemctl is-active --quiet postgresql-${POSTGRES_VERSION} 2>/dev/null; then
        print_warning "Low-memory host detected. Temporarily stopping PostgreSQL before Zabbix package installation."
        systemctl stop postgresql-${POSTGRES_VERSION}
        POSTGRES_STOPPED_FOR_ZABBIX_INSTALL="true"
        return 0
    fi

    if systemctl is-active --quiet postgresql 2>/dev/null; then
        print_warning "Low-memory host detected. Temporarily stopping PostgreSQL before Zabbix package installation."
        systemctl stop postgresql
        POSTGRES_STOPPED_FOR_ZABBIX_INSTALL="true"
    fi

    return 0
}

resume_postgresql_after_low_memory_install() {
    if [ "$POSTGRES_STOPPED_FOR_ZABBIX_INSTALL" != "true" ]; then
        return 0
    fi

    print_info "Restarting PostgreSQL after Zabbix package installation..."
    systemctl start postgresql-${POSTGRES_VERSION} > /dev/null 2>&1 || systemctl start postgresql > /dev/null 2>&1
    POSTGRES_STOPPED_FOR_ZABBIX_INSTALL="false"
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_int_range() {
    local field_name=$1
    local value=$2
    local min_value=$3
    local max_value=$4

    if ! is_integer "$value"; then
        print_error "${field_name} must be an integer (current value: ${value})"
        exit 1
    fi

    if [ "$value" -lt "$min_value" ] || [ "$value" -gt "$max_value" ]; then
        print_error "${field_name} must be between ${min_value} and ${max_value} (current value: ${value})"
        exit 1
    fi
}

mode_name() {
    if [ "$1" -eq 0 ]; then
        echo "Active"
    else
        echo "Passive"
    fi
}

server_label() {
    if [ "$PROXY_MODE" -eq 0 ]; then
        echo "Server/Cluster"
    else
        echo "Allowed Server(s)"
    fi
}

server_prompt() {
    if [ "$PROXY_MODE" -eq 0 ]; then
        echo "Zabbix Server/Cluster endpoint [e.g. zbx.example.com:10051 or zbx-a:10051;zbx-b:10051]: "
    else
        echo "Authorized Zabbix Server IP/CIDR/DNS list [e.g. 10.10.10.5,10.10.20.0/24,zbx.example.com]: "
    fi
}

escape_sql_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

validate_tls_configuration() {
    case "$TLS_MODE" in
        unencrypted|psk|cert)
            ;;
        *)
            print_error "TLS_MODE must be one of: unencrypted, psk, cert"
            exit 1
            ;;
    esac

    if [ "$TLS_MODE" = "psk" ]; then
        [ -n "$TLS_PSK_IDENTITY" ] || { print_error "TLS_PSK_IDENTITY is required when TLS_MODE=psk"; exit 1; }
        [ -n "$TLS_PSK_FILE" ] || { print_error "TLS_PSK_FILE is required when TLS_MODE=psk"; exit 1; }
    fi

    if [ "$TLS_MODE" = "cert" ]; then
        [ -n "$TLS_CA_FILE" ] || { print_error "TLS_CA_FILE is required when TLS_MODE=cert"; exit 1; }
        [ -n "$TLS_CERT_FILE" ] || { print_error "TLS_CERT_FILE is required when TLS_MODE=cert"; exit 1; }
        [ -n "$TLS_KEY_FILE" ] || { print_error "TLS_KEY_FILE is required when TLS_MODE=cert"; exit 1; }
    fi

    return 0
}

validate_configuration() {
    [ -n "$PROXY_NAME" ] || PROXY_NAME=$(hostname)
    [ -n "$PROXY_MODE" ] || PROXY_MODE=0
    [ -n "$PERFORMANCE_PROFILE" ] || PERFORMANCE_PROFILE="medium"

    validate_int_range "PROXY_MODE" "$PROXY_MODE" 0 1
    validate_int_range "PROXY_OFFLINE_BUFFER" "$PROXY_OFFLINE_BUFFER" 1 720
    validate_int_range "PROXY_CONFIG_FREQUENCY" "$PROXY_CONFIG_FREQUENCY" 1 604800
    validate_int_range "DATA_SENDER_FREQUENCY" "$DATA_SENDER_FREQUENCY" 1 3600
    validate_int_range "LISTEN_PORT" "$LISTEN_PORT" 1024 65535

    case "$PERFORMANCE_PROFILE" in
        light|medium|heavy|ultra)
            ;;
        *)
            print_error "PERFORMANCE_PROFILE must be one of: light, medium, heavy, ultra"
            exit 1
            ;;
    esac

    if [ -z "$ZABBIX_SERVER" ]; then
        print_error "ZABBIX_SERVER cannot be empty"
        exit 1
    fi

    if [ -z "$DB_PASSWORD" ]; then
        print_error "DB_PASSWORD cannot be empty"
        exit 1
    fi

    if [ "${#DB_PASSWORD}" -lt 8 ]; then
        print_error "DB_PASSWORD must be at least 8 characters"
        exit 1
    fi

    if [ "$PROXY_MODE" -eq 0 ] && printf '%s' "$ZABBIX_SERVER" | grep -q ','; then
        print_error "Active mode expects a single endpoint or cluster separated by ';' (not commas)"
        exit 1
    fi

    if [ "$PROXY_MODE" -eq 1 ] && printf '%s' "$ZABBIX_SERVER" | grep -q ';'; then
        print_error "Passive mode expects a comma-delimited IP/CIDR/DNS list (not ';')"
        exit 1
    fi

    validate_tls_configuration
}

build_tls_config() {
    cat <<EOF
# TLS
TLSConnect=${TLS_MODE}
TLSAccept=${TLS_ACCEPT}
EOF

    if [ -n "$TLS_CA_FILE" ]; then
        echo "TLSCAFile=${TLS_CA_FILE}"
    fi

    if [ -n "$TLS_CERT_FILE" ]; then
        echo "TLSCertFile=${TLS_CERT_FILE}"
    fi

    if [ -n "$TLS_KEY_FILE" ]; then
        echo "TLSKeyFile=${TLS_KEY_FILE}"
    fi

    if [ -n "$TLS_PSK_IDENTITY" ]; then
        echo "TLSPSKIdentity=${TLS_PSK_IDENTITY}"
    fi

    if [ -n "$TLS_PSK_FILE" ]; then
        echo "TLSPSKFile=${TLS_PSK_FILE}"
    fi

    return 0
}

find_executable_path() {
    local candidate

    for candidate in "$@"; do
        if [[ "$candidate" == */* ]]; then
            if [ -x "$candidate" ]; then
                echo "$candidate"
                return 0
            fi
        elif command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    return 1
}

configure_ping_tools() {
    if [ "${START_PINGERS:-0}" -le 0 ]; then
        FPING_LOCATION=""
        FPING6_LOCATION=""
        return 0
    fi

    if ! FPING_LOCATION=$(find_executable_path fping /usr/sbin/fping /usr/bin/fping); then
        print_warning "fping binary not found. Attempting to install package 'fping'..."
        if ! run_long_step "Installing fping" $PKG_INSTALL fping; then
            print_warning "Unable to install fping automatically. ICMP pingers will be disabled to keep Zabbix Proxy startable."
            START_PINGERS=0
            FPING_LOCATION=""
            FPING6_LOCATION=""
            return 0
        fi

        if ! FPING_LOCATION=$(find_executable_path fping /usr/sbin/fping /usr/bin/fping); then
            print_warning "fping package installed, but binary path could not be resolved. ICMP pingers will be disabled."
            START_PINGERS=0
            FPING_LOCATION=""
            FPING6_LOCATION=""
            return 0
        fi
    fi

    if FPING6_LOCATION=$(find_executable_path fping6 /usr/sbin/fping6 /usr/bin/fping6); then
        :
    else
        FPING6_LOCATION=""
    fi

    return 0
}

show_mode_guidance() {
    print_info "Recommended usage:"
    print_info "  Active  = use when the proxy can reach the central Zabbix server, but the server cannot open inbound connections to the site."
    print_info "  Passive = use when the Zabbix server can initiate TCP/10051 towards the proxy."
    print_info ""
    print_warning "Zabbix documents that active proxy configuration requests are not authenticated on the server trapper port."
    print_warning "Do not expose the Zabbix server trapper port broadly on the Internet; protect it with ACLs / firewalls / private links."
}

get_zabbix_repo_url() {
    local arch
    local zabbix_repo_family
    arch=$(uname -m)

    case "$OS" in
        rhel)
            zabbix_repo_family="rhel"
            ;;
        centos)
            zabbix_repo_family="centos"
            ;;
        rocky)
            zabbix_repo_family="rocky"
            ;;
        almalinux)
            zabbix_repo_family="alma"
            ;;
        ol)
            zabbix_repo_family="oracle"
            ;;
    esac

    case "$OS" in
        ubuntu)
            echo "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+ubuntu${VERSION}_all.deb"
            ;;
        debian)
            echo "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+debian${VERSION%%.*}_all.deb"
            ;;
        amzn)
            echo "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/amazonlinux/${VERSION%%.*}/${arch}/zabbix-release-latest-${ZABBIX_VERSION}.amzn${VERSION%%.*}.noarch.rpm"
            ;;
        rhel|centos|rocky|almalinux|ol)
            echo "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${zabbix_repo_family}/$(rpm -E %{rhel})/${arch}/zabbix-release-latest-${ZABBIX_VERSION}.el$(rpm -E %{rhel}).noarch.rpm"
            ;;
    esac
}

is_interactive_mode() {
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        return 0
    fi

    return 1
}

detect_previous_installation() {
    local postgres_service
    postgres_service=$(postgresql_service_name)

    PREVIOUS_INSTALLATION_DETECTED="false"
    PREVIOUS_INSTALLATION_FINDINGS=""

    if [ -f "$ZABBIX_CONF" ]; then
        append_previous_installation_finding "existing proxy configuration found at $ZABBIX_CONF"
    fi

    if [ -d "/var/log/zabbix" ] && [ -n "$(ls -A /var/log/zabbix 2>/dev/null)" ]; then
        append_previous_installation_finding "existing Zabbix log files found in /var/log/zabbix"
    fi

    if [ -d "/var/log/snmptrap" ] && [ -n "$(ls -A /var/log/snmptrap 2>/dev/null)" ]; then
        append_previous_installation_finding "existing SNMP trap log files found in /var/log/snmptrap"
    fi

    if [ -f "${POSTGRES_DATA_DIR}/PG_VERSION" ]; then
        append_previous_installation_finding "existing PostgreSQL cluster detected at ${POSTGRES_DATA_DIR}"
    elif [ -d "${POSTGRES_DATA_DIR}" ] && [ -n "$(ls -A "${POSTGRES_DATA_DIR}" 2>/dev/null)" ]; then
        append_previous_installation_finding "non-empty PostgreSQL data directory detected at ${POSTGRES_DATA_DIR}"
    fi

    if [ "$POSTGRES_CONF_DIR" != "$POSTGRES_DATA_DIR" ] && [ -d "$POSTGRES_CONF_DIR" ]; then
        append_previous_installation_finding "existing PostgreSQL configuration detected at ${POSTGRES_CONF_DIR}"
    fi

    if service_unit_exists "zabbix-proxy"; then
        append_previous_installation_finding "zabbix-proxy service is already installed"
    fi

    if service_unit_exists "$postgres_service"; then
        append_previous_installation_finding "${postgres_service} service is already installed"
    fi

    if package_is_installed "zabbix-proxy-pgsql"; then
        append_previous_installation_finding "package zabbix-proxy-pgsql is already installed"
    fi

    if package_is_installed "zabbix-sql-scripts"; then
        append_previous_installation_finding "package zabbix-sql-scripts is already installed"
    fi

    case "$OS" in
        ubuntu|debian)
            if package_is_installed "postgresql-${POSTGRES_VERSION}"; then
                append_previous_installation_finding "package postgresql-${POSTGRES_VERSION} is already installed"
            fi
            ;;
        rhel|centos|rocky|almalinux|ol|amzn)
            if package_is_installed "postgresql${POSTGRES_VERSION}-server"; then
                append_previous_installation_finding "package postgresql${POSTGRES_VERSION}-server is already installed"
            fi
            ;;
    esac

    if id postgres > /dev/null 2>&1 && command -v psql > /dev/null 2>&1 && postgresql_service_is_active; then
        if run_as_user postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='zabbix_proxy'" 2>/dev/null | grep -q 1; then
            append_previous_installation_finding "database zabbix_proxy already exists"
        fi

        if run_as_user postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='zabbix'" 2>/dev/null | grep -q 1; then
            append_previous_installation_finding "database role zabbix already exists"
        fi
    fi

    return 0
}

print_previous_installation_summary() {
    print_info ""
    print_warning "Previous installation artifacts were detected:"
    printf '%s\n' "$PREVIOUS_INSTALLATION_FINDINGS"
    print_info ""
    print_info "Cleanup will stop Zabbix Proxy/PostgreSQL and move the old state to ${CLEANUP_BACKUP_ROOT}/<timestamp> before reinstalling."
    print_info "Use ELVEN_CLEANUP_MODE=force for non-interactive cleanup or ELVEN_CLEANUP_MODE=none to continue without cleanup."
}

ensure_cleanup_backup_dir() {
    if [ -z "$CLEANUP_TIMESTAMP" ]; then
        CLEANUP_TIMESTAMP=$(date +%F-%H%M%S)
    fi

    if [ -z "$CLEANUP_BACKUP_DIR" ]; then
        CLEANUP_BACKUP_DIR="${CLEANUP_BACKUP_ROOT}/${CLEANUP_TIMESTAMP}"
        mkdir -p "$CLEANUP_BACKUP_DIR"
    fi
}

backup_and_remove_path() {
    local target_path=$1
    local backup_path

    [ -e "$target_path" ] || return 0

    ensure_cleanup_backup_dir
    backup_path="${CLEANUP_BACKUP_DIR}${target_path}"
    mkdir -p "$(dirname "$backup_path")"
    mv "$target_path" "$backup_path"
    print_info "  Backed up ${target_path} to ${backup_path}"
}

cleanup_previous_installation() {
    local postgres_service
    postgres_service=$(postgresql_service_name)

    print_info ""
    print_header "Cleanup"
    print_info "Stopping old services and backing up previous installation state..."

    systemctl stop zabbix-proxy > /dev/null 2>&1 || true
    systemctl stop "$postgres_service" > /dev/null 2>&1 || true

    backup_and_remove_path "$ZABBIX_CONF"
    backup_and_remove_path "${ZABBIX_CONF}.backup"
    backup_and_remove_path "/var/log/zabbix"
    backup_and_remove_path "/var/log/snmptrap"
    backup_and_remove_path "$POSTGRES_DATA_DIR"

    if [ "$POSTGRES_CONF_DIR" != "$POSTGRES_DATA_DIR" ]; then
        backup_and_remove_path "$POSTGRES_CONF_DIR"
    fi

    rm -f /tmp/elven-postgresql-initdb.log
    rm -f /tmp/pgdg-redhat-repo-latest.noarch.rpm
    rm -f /tmp/zabbix-release-latest.noarch.rpm
    rm -f /tmp/zabbix-release.deb
    rm -f /tmp/proxy.sql

    case "$PKG_MANAGER" in
        apt)
            apt clean > /dev/null 2>&1 || true
            ;;
        dnf|yum)
            $PKG_MANAGER clean all > /dev/null 2>&1 || true
            ;;
    esac

    CLEANUP_PERFORMED="true"
    print_success "Previous installation state was cleaned up."
    print_info "Backup saved to: ${CLEANUP_BACKUP_DIR}"

    return 0
}

handle_previous_installation() {
    local cleanup_answer

    detect_previous_installation

    if [ "$PREVIOUS_INSTALLATION_DETECTED" != "true" ]; then
        return 0
    fi

    print_previous_installation_summary

    case "$CLEANUP_MODE" in
        none)
            print_warning "ELVEN_CLEANUP_MODE=none, continuing without cleanup."
            return 0
            ;;
        force)
            cleanup_previous_installation
            return 0
            ;;
        prompt)
            if ! is_interactive_mode; then
                print_error "Previous installation artifacts were found, but ELVEN_CLEANUP_MODE=prompt requires a terminal attached to /dev/tty."
                print_info "Set ELVEN_CLEANUP_MODE=force to clean automatically or ELVEN_CLEANUP_MODE=none to continue without cleanup."
                exit 1
            fi

            read -p "Clean previous installation now (backup + remove old state) before continuing? (y/n): " cleanup_answer < /dev/tty
            case "$cleanup_answer" in
                y|Y)
                    cleanup_previous_installation
                    ;;
                *)
                    print_warning "Continuing without cleanup. If the previous state is inconsistent, the rerun may fail again."
                    ;;
            esac
            ;;
        *)
            print_error "ELVEN_CLEANUP_MODE must be one of: none, prompt, force"
            exit 1
            ;;
    esac

    return 0
}

# Get user input
get_user_input() {
    print_info ""
    print_header "Configuration"
    print_info ""

    # Check for env vars (non-interactive mode)
    if [ -n "$ZABBIX_SERVER" ] && [ -n "$DB_PASSWORD" ]; then
        print_info "Using environment variables for configuration..."

        validate_configuration

        print_success "Configuration loaded:"
        echo "  $(server_label):  $ZABBIX_SERVER"
        echo "  Proxy Name:     $PROXY_NAME"
        echo "  Proxy Mode:     $(mode_name "$PROXY_MODE")"
        echo "  Performance:    $PERFORMANCE_PROFILE"
        echo "  Offline Buffer: ${PROXY_OFFLINE_BUFFER}h"
        echo "  Listen Port:    ${LISTEN_PORT}"
        print_info ""

        return 0
    fi

    # Proxy Name
    read -p "Proxy Name [default: $(hostname)]: " PROXY_NAME < /dev/tty
    if [ -z "$PROXY_NAME" ]; then
        PROXY_NAME=$(hostname)
        print_info "  → Using hostname: $PROXY_NAME"
    fi

    # Proxy Mode
    print_info ""
    show_mode_guidance
    print_info ""
    print_info "Proxy Mode:"
    echo "  0 = Active (proxy connects to server)"
    echo "  1 = Passive (server connects to proxy)"
    read -p "Select mode [default: 0]: " PROXY_MODE < /dev/tty
    if [ -z "$PROXY_MODE" ]; then
        PROXY_MODE=0
        print_info "  → Using Active mode"
    fi

    validate_int_range "PROXY_MODE" "$PROXY_MODE" 0 1

    # Zabbix Server / Allowed servers
    while [ -z "$ZABBIX_SERVER" ]; do
        read -p "$(server_prompt)" ZABBIX_SERVER < /dev/tty
        if [ -z "$ZABBIX_SERVER" ]; then
            print_error "$(server_label) cannot be empty!"
        fi
    done

    # Database Password
    while [ -z "$DB_PASSWORD" ]; do
        read -sp "PostgreSQL Password for zabbix user: " DB_PASSWORD < /dev/tty
        echo
        if [ -z "$DB_PASSWORD" ]; then
            print_error "Password cannot be empty!"
        elif [ ${#DB_PASSWORD} -lt 8 ]; then
            print_error "Password must be at least 8 characters!"
            DB_PASSWORD=""
        fi
    done

    # Performance Profile
    print_info ""
    print_info "Performance Profile (based on number of monitored hosts):"
    echo "  light  = Up to 500 hosts"
    echo "  medium = 500-2000 hosts (recommended)"
    echo "  heavy  = 2000-5000 hosts"
    echo "  ultra  = 5000+ hosts"
    read -p "Select profile [default: medium]: " PERFORMANCE_PROFILE < /dev/tty
    if [ -z "$PERFORMANCE_PROFILE" ]; then
        PERFORMANCE_PROFILE="medium"
        print_info "  → Using medium profile"
    fi

    # Validate performance profile
    case $PERFORMANCE_PROFILE in
        light|medium|heavy|ultra)
            ;;
        *)
            print_warning "Invalid profile, using medium"
            PERFORMANCE_PROFILE="medium"
            ;;
    esac

    validate_configuration

    print_info ""
    print_success "Configuration summary:"
    echo "  $(server_label):  $ZABBIX_SERVER"
    echo "  Proxy Name:     $PROXY_NAME"
    echo "  Proxy Mode:     $(mode_name "$PROXY_MODE")"
    echo "  Performance:    $PERFORMANCE_PROFILE"
    echo "  Offline Buffer: ${PROXY_OFFLINE_BUFFER}h"
    echo "  Listen Port:    ${LISTEN_PORT}"
    print_info ""

    read -p "Confirm and continue? (y/n): " CONFIRM < /dev/tty
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_warning "Installation cancelled"
        exit 0
    fi

    return 0
}

# Get performance parameters based on profile
get_performance_params() {
    local profile=$1
    local mem_gb=$(get_memory_gb)
    local cpu_count=$(get_cpu_count)

    case $profile in
        light)
            START_POLLERS=5
            START_IPMI_POLLERS=0
            START_POLLERS_UNREACHABLE=1
            START_TRAPPERS=5
            START_PINGERS=1
            START_DISCOVERERS=1
            START_HTTP_POLLERS=1
            CACHE_SIZE="128M"
            HISTORY_CACHE_SIZE="64M"
            HISTORY_INDEX_CACHE_SIZE="32M"
            # PostgreSQL
            PG_SHARED_BUFFERS="256MB"
            PG_EFFECTIVE_CACHE_SIZE="512MB"
            PG_WORK_MEM="4MB"
            PG_MAINTENANCE_WORK_MEM="64MB"
            ;;
        medium)
            START_POLLERS=$((cpu_count * 2))
            [ $START_POLLERS -lt 10 ] && START_POLLERS=10
            [ $START_POLLERS -gt 30 ] && START_POLLERS=30
            START_IPMI_POLLERS=0
            START_POLLERS_UNREACHABLE=3
            START_TRAPPERS=10
            START_PINGERS=3
            START_DISCOVERERS=3
            START_HTTP_POLLERS=3
            CACHE_SIZE="512M"
            HISTORY_CACHE_SIZE="256M"
            HISTORY_INDEX_CACHE_SIZE="128M"
            # PostgreSQL
            PG_SHARED_BUFFERS="$(($mem_gb * 256 / 4))MB"
            PG_EFFECTIVE_CACHE_SIZE="$(($mem_gb * 768 / 4))MB"
            PG_WORK_MEM="16MB"
            PG_MAINTENANCE_WORK_MEM="128MB"
            ;;
        heavy)
            START_POLLERS=$((cpu_count * 3))
            [ $START_POLLERS -lt 20 ] && START_POLLERS=20
            [ $START_POLLERS -gt 50 ] && START_POLLERS=50
            START_IPMI_POLLERS=5
            START_POLLERS_UNREACHABLE=5
            START_TRAPPERS=20
            START_PINGERS=5
            START_DISCOVERERS=5
            START_HTTP_POLLERS=5
            CACHE_SIZE="1G"
            HISTORY_CACHE_SIZE="512M"
            HISTORY_INDEX_CACHE_SIZE="256M"
            # PostgreSQL
            PG_SHARED_BUFFERS="$(($mem_gb * 256 / 2))MB"
            PG_EFFECTIVE_CACHE_SIZE="$(($mem_gb * 768 / 2))MB"
            PG_WORK_MEM="32MB"
            PG_MAINTENANCE_WORK_MEM="256MB"
            ;;
        ultra)
            START_POLLERS=$((cpu_count * 4))
            [ $START_POLLERS -lt 40 ] && START_POLLERS=40
            [ $START_POLLERS -gt 100 ] && START_POLLERS=100
            START_IPMI_POLLERS=10
            START_POLLERS_UNREACHABLE=10
            START_TRAPPERS=30
            START_PINGERS=10
            START_DISCOVERERS=10
            START_HTTP_POLLERS=10
            CACHE_SIZE="2G"
            HISTORY_CACHE_SIZE="1G"
            HISTORY_INDEX_CACHE_SIZE="512M"
            # PostgreSQL
            PG_SHARED_BUFFERS="$(($mem_gb * 256))MB"
            PG_EFFECTIVE_CACHE_SIZE="$(($mem_gb * 768))MB"
            PG_WORK_MEM="64MB"
            PG_MAINTENANCE_WORK_MEM="512MB"
            ;;
    esac

    print_info ""
    print_success "Performance parameters for $profile profile:"
    echo "  System: ${mem_gb}GB RAM, ${cpu_count} CPUs"
    echo "  Pollers: $START_POLLERS"
    echo "  Trappers: $START_TRAPPERS"
    echo "  Cache Size: $CACHE_SIZE"
    echo "  History Cache: $HISTORY_CACHE_SIZE"
    echo "  PostgreSQL Shared Buffers: $PG_SHARED_BUFFERS"
}

# Stop existing services
stop_existing_services() {
    print_info "Checking for existing services..."

    # Stop and clear any failed/restart state so a previous broken install
    # doesn't keep the unit in an auto-restart loop while we reinstall.
    if systemctl list-unit-files zabbix-proxy.service >/dev/null 2>&1; then
        print_info "  Stopping zabbix-proxy..."
        systemctl stop zabbix-proxy > /dev/null 2>&1 || true
        systemctl reset-failed zabbix-proxy > /dev/null 2>&1 || true
    fi

    print_success "Clean!"
}

initialize_postgresql_cluster() {
    local initdb_log_file="/tmp/elven-postgresql-initdb.log"

    if is_postgresql_initialized; then
        print_warning "PostgreSQL data directory already initialized at ${POSTGRES_DATA_DIR}. Skipping initialization."
        return 0
    fi

    print_info "Initializing database..."

    case "$OS" in
        ubuntu|debian)
            if ! command -v pg_createcluster > /dev/null 2>&1; then
                print_error "pg_createcluster is required to initialize PostgreSQL on ${OS_NAME}"
                return 1
            fi

            if ! pg_createcluster "${POSTGRES_VERSION}" main > "$initdb_log_file" 2>&1; then
                print_error "PostgreSQL cluster creation failed. Output:"
                cat "$initdb_log_file"
                return 1
            fi
            ;;
        rhel|centos|rocky|almalinux|ol|amzn)
            if ! /usr/pgsql-${POSTGRES_VERSION}/bin/postgresql-${POSTGRES_VERSION}-setup initdb > "$initdb_log_file" 2>&1; then
                print_error "PostgreSQL initdb failed. Output:"
                cat "$initdb_log_file"
                return 1
            fi
            ;;
    esac

    return 0
}

# Install PostgreSQL
install_postgresql() {
    print_info ""
    print_header "[1/3] Installing PostgreSQL $POSTGRES_VERSION"
    print_info ""

    local pgdg_repo_arch
    local pgdg_repo_rpm_url
    local pgdg_repo_rpm_file="/tmp/pgdg-redhat-repo-latest.noarch.rpm"
    pgdg_repo_arch=$(uname -m)

    case $OS in
        ubuntu|debian)
            print_info "Adding PostgreSQL repository..."

            # Install prerequisites
            run_long_step "Installing download prerequisites" \
                $PKG_INSTALL wget curl ca-certificates gnupg lsb-release

            # Add PostgreSQL GPG key
            wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --yes -o /usr/share/keyrings/postgresql-keyring.gpg

            # Add repository
            echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

            # Update and install
            refresh_package_metadata
            run_long_step "Installing PostgreSQL ${POSTGRES_VERSION} packages" \
                $PKG_INSTALL postgresql-${POSTGRES_VERSION} postgresql-contrib-${POSTGRES_VERSION}

            initialize_postgresql_cluster

            print_success "PostgreSQL installed!"
            ;;

        rhel|centos|rocky|almalinux|ol|amzn)
            print_info "Adding PostgreSQL repository..."

            # Install repository RPM locally instead of asking dnf/yum to fetch a remote URL.
            # This is lighter on constrained hosts and avoids opaque "Killed" failures from the package manager.
            pgdg_repo_rpm_url="https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{rhel})-${pgdg_repo_arch}/pgdg-redhat-repo-latest.noarch.rpm"
            download_with_retry "$pgdg_repo_rpm_url" "$pgdg_repo_rpm_file"
            rpm -Uvh --quiet --replacepkgs "$pgdg_repo_rpm_file"
            rm -f "$pgdg_repo_rpm_file"

            # Disable built-in PostgreSQL module (RHEL 8+)
            if [ "$PKG_MANAGER" = "dnf" ]; then
                dnf -qy module disable postgresql > /dev/null 2>&1 || true
            fi

            run_long_step "Installing PostgreSQL ${POSTGRES_VERSION} packages" \
                $PKG_INSTALL postgresql${POSTGRES_VERSION}-server postgresql${POSTGRES_VERSION}-contrib

            initialize_postgresql_cluster

            print_success "PostgreSQL installed!"
            ;;
    esac

    # Start and enable PostgreSQL
    systemctl enable postgresql-${POSTGRES_VERSION} > /dev/null 2>&1 || systemctl enable postgresql > /dev/null 2>&1
    systemctl start postgresql-${POSTGRES_VERSION} > /dev/null 2>&1 || systemctl start postgresql > /dev/null 2>&1
    
    sleep 3
    
    if systemctl is-active --quiet postgresql-${POSTGRES_VERSION} 2>/dev/null || systemctl is-active --quiet postgresql 2>/dev/null; then
        print_success "PostgreSQL running!"
    else
        print_error "PostgreSQL failed to start"
        journalctl -u postgresql-${POSTGRES_VERSION} -u postgresql -n 20 --no-pager
        exit 1
    fi
}

# Configure PostgreSQL
configure_postgresql() {
    print_info ""
    print_info "Configuring PostgreSQL for optimal performance..."
    
    # Find postgresql.conf
    if [ -f "/etc/postgresql/${POSTGRES_VERSION}/main/postgresql.conf" ]; then
        PG_CONF="/etc/postgresql/${POSTGRES_VERSION}/main/postgresql.conf"
    elif [ -f "/var/lib/pgsql/${POSTGRES_VERSION}/data/postgresql.conf" ]; then
        PG_CONF="/var/lib/pgsql/${POSTGRES_VERSION}/data/postgresql.conf"
    else
        print_warning "Could not find postgresql.conf, skipping tuning"
        return
    fi
    
    # Backup original config
    cp "$PG_CONF" "${PG_CONF}.backup"

    # Apply tuning idempotently
    sed -i '/^# BEGIN ELVEN ZABBIX PROXY TUNING$/,/^# END ELVEN ZABBIX PROXY TUNING$/d' "$PG_CONF"
    cat >> "$PG_CONF" <<EOF

# BEGIN ELVEN ZABBIX PROXY TUNING
max_connections = 200
shared_buffers = ${PG_SHARED_BUFFERS}
effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE}
maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM}
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = ${PG_WORK_MEM}
min_wal_size = 1GB
max_wal_size = 4GB
max_worker_processes = $(get_cpu_count)
max_parallel_workers_per_gather = 2
max_parallel_workers = $(get_cpu_count)
max_parallel_maintenance_workers = 2
# END ELVEN ZABBIX PROXY TUNING
EOF

    # Restart PostgreSQL
    systemctl restart postgresql-${POSTGRES_VERSION} > /dev/null 2>&1 || systemctl restart postgresql > /dev/null 2>&1
    sleep 3
    
    print_success "PostgreSQL configured and restarted!"
}

# Create Zabbix database
create_database() {
    print_info ""
    print_info "Creating Zabbix database and user..."

    local escaped_db_password
    escaped_db_password=$(escape_sql_literal "$DB_PASSWORD")

    run_as_user postgres psql -v ON_ERROR_STOP=1 >/dev/null <<EOF
DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'zabbix') THEN
        ALTER ROLE zabbix WITH PASSWORD '${escaped_db_password}';
    ELSE
        CREATE ROLE zabbix LOGIN PASSWORD '${escaped_db_password}';
    END IF;
END
\$\$;
EOF

    if ! run_as_user postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='zabbix_proxy'" | grep -q 1; then
        run_as_user postgres createdb -O zabbix zabbix_proxy
    else
        print_warning "Database zabbix_proxy already exists"
    fi

    run_as_user postgres psql -d zabbix_proxy -c "ALTER SCHEMA public OWNER TO zabbix;" > /dev/null 2>&1 || true
    run_as_user postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE zabbix_proxy TO zabbix;" > /dev/null 2>&1

    print_success "Database and user ready!"
}

# Install Zabbix Proxy
install_zabbix() {
    print_info ""
    print_header "[2/3] Installing Zabbix Proxy ${ZABBIX_VERSION} LTS"
    print_info ""

    local repo_url
    local repo_rpm_file
    pause_postgresql_for_low_memory_install

    case $OS in
        ubuntu|debian)
            print_info "Adding Zabbix repository..."

            repo_url=$(get_zabbix_repo_url)

            download_with_retry "$repo_url" /tmp/zabbix-release.deb
            dpkg -i /tmp/zabbix-release.deb > /dev/null 2>&1
            rm /tmp/zabbix-release.deb

            # Update and install
            refresh_package_metadata
            run_long_step "Installing zabbix-proxy-pgsql" \
                $PKG_INSTALL zabbix-proxy-pgsql
            run_long_step "Installing zabbix-sql-scripts" \
                $PKG_INSTALL zabbix-sql-scripts

            print_success "Zabbix Proxy installed!"
            ;;

        rhel|centos|rocky|almalinux|ol|amzn)
            print_info "Adding Zabbix repository..."

            repo_url=$(get_zabbix_repo_url)
            repo_rpm_file="/tmp/zabbix-release-latest.noarch.rpm"
            download_with_retry "$repo_url" "$repo_rpm_file"
            rpm -Uvh --replacepkgs "$repo_rpm_file" > /dev/null 2>&1
            rm -f "$repo_rpm_file"

            # Clean cache
            $PKG_MANAGER clean all > /dev/null 2>&1

            run_long_step "Installing zabbix-proxy-pgsql" \
                $PKG_INSTALL zabbix-proxy-pgsql
            run_long_step "Installing zabbix-sql-scripts" \
                $PKG_INSTALL zabbix-sql-scripts

            print_success "Zabbix Proxy installed!"
            ;;
    esac

    resume_postgresql_after_low_memory_install
}

# Check if a table exists in the zabbix_proxy public schema
schema_table_exists() {
    local table=$1
    run_as_user postgres psql -tAc \
        "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='${table}'" \
        zabbix_proxy 2>/dev/null | grep -q 1
}

# Count user tables in the zabbix_proxy public schema
schema_public_table_count() {
    local count
    count=$(run_as_user postgres psql -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'" \
        zabbix_proxy 2>/dev/null | tr -d '[:space:]')
    printf '%s' "${count:-0}"
}

# A fully imported Zabbix 7.0 proxy schema contains all of these tables.
# Missing any one means the previous import was interrupted or failed.
# dbversion must also hold at least one row so we know the version
# metadata was populated at the tail end of the import.
schema_is_complete() {
    local required="hosts items interface proxy_history dbversion"
    local t
    for t in $required; do
        schema_table_exists "$t" || return 1
    done

    local dbversion_rows
    dbversion_rows=$(run_as_user postgres psql -tAc \
        "SELECT count(*) FROM dbversion" zabbix_proxy 2>/dev/null | tr -d '[:space:]')
    [ -n "$dbversion_rows" ] && [ "$dbversion_rows" -gt 0 ]
}

# Drop any leftover objects in the public schema so re-import is clean.
reset_public_schema() {
    run_as_user postgres psql -v ON_ERROR_STOP=1 -d zabbix_proxy >/dev/null <<'EOF'
DROP SCHEMA public CASCADE;
CREATE SCHEMA public AUTHORIZATION zabbix;
GRANT ALL ON SCHEMA public TO zabbix;
GRANT ALL ON SCHEMA public TO public;
EOF
}

# Import Zabbix schema
import_schema() {
    print_info ""
    print_info "Importing Zabbix database schema..."
    local schema_file

    # Find schema file
    if [ -f "/usr/share/zabbix-sql-scripts/postgresql/proxy.sql" ]; then
        schema_file="/usr/share/zabbix-sql-scripts/postgresql/proxy.sql"
    elif [ -f "/usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql.gz" ]; then
        zcat /usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql.gz > /tmp/proxy.sql
        chmod 644 /tmp/proxy.sql
        schema_file="/tmp/proxy.sql"
    else
        print_error "Could not find Zabbix schema file"
        exit 1
    fi

    if schema_is_complete; then
        print_warning "Schema already imported, skipping"
    else
        local existing_tables
        existing_tables=$(schema_public_table_count)
        if [ "$existing_tables" -gt 0 ]; then
            print_warning "Detected incomplete schema from previous run (${existing_tables} table(s) present). Resetting and re-importing..."
            reset_public_schema
        fi

        local import_log="/tmp/elven-zabbix-proxy-schema-import.log"
        if ! run_as_user zabbix psql -v ON_ERROR_STOP=1 zabbix_proxy < "$schema_file" > "$import_log" 2>&1; then
            print_error "Schema import failed. Output:"
            tail -n 40 "$import_log"
            rm -f /tmp/proxy.sql "$import_log"
            exit 1
        fi
        rm -f "$import_log"
        print_success "Schema imported!"
    fi

    # Clean temp file
    rm -f /tmp/proxy.sql
}

# Configure Zabbix Proxy
configure_zabbix() {
    print_info ""
    print_header "[3/3] Configuring Zabbix Proxy"
    print_info ""

    configure_ping_tools

    # Backup original config
    [ -f "$ZABBIX_CONF" ] && cp "$ZABBIX_CONF" "${ZABBIX_CONF}.backup"

    # Create configuration
    cat > "$ZABBIX_CONF" <<EOF
# Zabbix Proxy Configuration
# Auto-generated by installation script

ProxyMode=${PROXY_MODE}
Server=${ZABBIX_SERVER}
Hostname=${PROXY_NAME}

# Database
DBHost=localhost
DBName=zabbix_proxy
DBUser=zabbix
DBPassword=${DB_PASSWORD}

# Performance Tuning (${PERFORMANCE_PROFILE} profile)
StartPollers=${START_POLLERS}
StartIPMIPollers=${START_IPMI_POLLERS}
StartPollersUnreachable=${START_POLLERS_UNREACHABLE}
StartTrappers=${START_TRAPPERS}
StartPingers=${START_PINGERS}
StartDiscoverers=${START_DISCOVERERS}
StartHTTPPollers=${START_HTTP_POLLERS}

# Timeouts
Timeout=10
TrapperTimeout=300

# Cache Configuration
# Note: TrendCacheSize and ValueCacheSize are server-only parameters.
# Zabbix Proxy does not compute trends and has no trigger value cache.
CacheSize=${CACHE_SIZE}
HistoryCacheSize=${HISTORY_CACHE_SIZE}
HistoryIndexCacheSize=${HISTORY_INDEX_CACHE_SIZE}

# Data Transfer
ProxyConfigFrequency=${PROXY_CONFIG_FREQUENCY}
DataSenderFrequency=${DATA_SENDER_FREQUENCY}
ProxyOfflineBuffer=${PROXY_OFFLINE_BUFFER}

# Logging
LogFile=/var/log/zabbix/zabbix_proxy.log
LogFileSize=10
DebugLevel=3

# PID file location.
# Must match the PIDFile= directive in the systemd unit shipped by the
# Zabbix package, otherwise systemd can't confirm the forking daemon
# started and leaves the unit stuck in "activating" forever.
PidFile=/run/zabbix/zabbix_proxy.pid
SocketDir=/run/zabbix

# Process Management
StartVMwareCollectors=0
VMwareFrequency=60
VMwarePerfFrequency=60
VMwareCacheSize=8M
VMwareTimeout=10

# Network
ListenPort=${LISTEN_PORT}

# Other
SNMPTrapperFile=/var/log/snmptrap/snmptrap.log
ExternalScripts=/usr/lib/zabbix/externalscripts
LogSlowQueries=3000

# StatsAllowedIP=127.0.0.1
EOF

    if [ -n "$LISTEN_IP" ]; then
        echo "ListenIP=${LISTEN_IP}" >> "$ZABBIX_CONF"
    fi

    if [ -n "$SOURCE_IP" ]; then
        echo "SourceIP=${SOURCE_IP}" >> "$ZABBIX_CONF"
    fi

    if [ -n "$FPING_LOCATION" ]; then
        echo "FpingLocation=${FPING_LOCATION}" >> "$ZABBIX_CONF"
        if [ -n "$FPING6_LOCATION" ]; then
            echo "Fping6Location=${FPING6_LOCATION}" >> "$ZABBIX_CONF"
        else
            echo "Fping6Location=" >> "$ZABBIX_CONF"
        fi
    fi

    build_tls_config >> "$ZABBIX_CONF"

    print_success "Configuration created!"

    # Set permissions
    chown zabbix:zabbix "$ZABBIX_CONF"
    chmod 640 "$ZABBIX_CONF"

    # Create log directory if needed
    mkdir -p /var/log/zabbix
    chown zabbix:zabbix /var/log/zabbix
    mkdir -p /var/log/snmptrap

    # /run/zabbix is normally populated by the package's tmpfiles.d snippet
    # at boot, but it may not exist yet on a fresh install or after a manual
    # /run cleanup. Without it, zabbix_proxy cannot write its PID file and
    # systemd leaves the service stuck in "activating".
    mkdir -p /run/zabbix
    chown zabbix:zabbix /run/zabbix
    chmod 755 /run/zabbix
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        systemd-tmpfiles --create > /dev/null 2>&1 || true
    fi
}

# Start Zabbix Proxy
start_zabbix() {
    print_info ""
    print_info "Starting Zabbix Proxy..."

    systemctl enable zabbix-proxy > /dev/null 2>&1 || true
    # Clear any leftover failed/restart state from previous installs
    # so the auto-restart loop doesn't race with our start.
    systemctl reset-failed zabbix-proxy > /dev/null 2>&1 || true

    local start_status=0
    systemctl start zabbix-proxy || start_status=$?

    sleep 5

    if systemctl is-active --quiet zabbix-proxy; then
        print_success "Zabbix Proxy running!"
        return 0
    fi

    print_error "Zabbix Proxy failed to start (systemctl exit: ${start_status})"
    print_info ""
    print_info "Service status:"
    systemctl status zabbix-proxy --no-pager -l 2>&1 || true
    print_info ""
    print_info "Last 40 lines of journal for zabbix-proxy:"
    journalctl -u zabbix-proxy -n 40 --no-pager 2>&1 || true
    if [ -s /var/log/zabbix/zabbix_proxy.log ]; then
        print_info ""
        print_info "Last 40 lines of /var/log/zabbix/zabbix_proxy.log:"
        tail -n 40 /var/log/zabbix/zabbix_proxy.log
    fi
    exit 1
}

# Print summary
print_summary() {
    print_info ""
    print_info "========================================"
    print_success "INSTALLATION COMPLETE!"
    print_info "========================================"
    print_info ""

    # Check services
    print_success "Service Status:"
    if systemctl is-active --quiet postgresql-${POSTGRES_VERSION} 2>/dev/null || systemctl is-active --quiet postgresql 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} PostgreSQL: Running"
    else
        echo -e "  ${RED}✗${NC} PostgreSQL: Not running"
    fi

    if systemctl is-active --quiet zabbix-proxy; then
        echo -e "  ${GREEN}✓${NC} Zabbix Proxy: Running"
    else
        echo -e "  ${RED}✗${NC} Zabbix Proxy: Not running"
    fi

    print_info ""
    print_success "Configuration:"
    echo "  $(server_label):  $ZABBIX_SERVER"
    echo "  Proxy Name:      $PROXY_NAME"
    echo "  Proxy Mode:      $(mode_name "$PROXY_MODE")"
    echo "  Performance:     $PERFORMANCE_PROFILE"
    echo "  Offline Buffer:  ${PROXY_OFFLINE_BUFFER}h"
    echo "  Listen Port:     ${LISTEN_PORT}"
    echo "  Distribution:    $OS_NAME"
    if [ "$TEMP_SWAP_ENABLED" = "true" ]; then
        echo "  Temporary Swap:  ${SWAP_FILE_PATH} (${SWAP_SIZE_MB}MB)"
    fi
    
    print_info ""
    print_success "Files:"
    echo "  Proxy Config:    $ZABBIX_CONF"
    echo "  PostgreSQL Conf: $POSTGRES_CONF_DIR/postgresql.conf"
    echo "  PostgreSQL Data: $POSTGRES_DATA_DIR"
    echo "  Log File:        /var/log/zabbix/zabbix_proxy.log"
    if [ "$CLEANUP_PERFORMED" = "true" ]; then
        echo "  Cleanup Backup:  $CLEANUP_BACKUP_DIR"
    fi
    
    print_info ""
    print_success "Database:"
    echo "  Database:        zabbix_proxy"
    echo "  User:            zabbix"
    echo "  Host:            localhost"
    
    print_info ""
    print_success "Performance Parameters:"
    echo "  Pollers:         $START_POLLERS"
    echo "  Trappers:        $START_TRAPPERS"
    echo "  Cache Size:      $CACHE_SIZE"
    echo "  History Cache:   $HISTORY_CACHE_SIZE"
    
    print_info ""
    print_success "Useful commands:"
    echo "  Check status:"
    echo "    systemctl status zabbix-proxy"
    echo "    systemctl status postgresql-${POSTGRES_VERSION} || systemctl status postgresql"
    print_info ""
    echo "  View logs:"
    echo "    tail -f /var/log/zabbix/zabbix_proxy.log"
    echo "    journalctl -u zabbix-proxy -f"
    print_info ""
    echo "  Restart services:"
    echo "    systemctl restart zabbix-proxy"
    echo "    systemctl restart postgresql-${POSTGRES_VERSION} || systemctl restart postgresql"
    print_info ""
    echo "  Database access:"
    echo "    runuser -u postgres -- psql -d zabbix_proxy"
    
    print_info ""
    print_success "Next steps:"
    echo "  1. Go to Zabbix Server web interface"
    echo "  2. Administration → Proxies → Create proxy"
    echo "  3. Set proxy name to: $PROXY_NAME"
    echo "  4. Set proxy mode to: $(mode_name "$PROXY_MODE")"
    if [ "$PROXY_MODE" -eq 0 ]; then
        echo "  5. Ensure the proxy can initiate TCP/${LISTEN_PORT} to: $ZABBIX_SERVER"
        echo "  6. Protect the Zabbix server trapper port with network ACLs / VPN / private connectivity"
    else
        echo "  5. Ensure the Zabbix server can initiate TCP/${LISTEN_PORT} to this proxy"
        echo "  6. Allow only the server IPs/CIDRs declared in Server=${ZABBIX_SERVER}"
    fi
    
    print_info ""
    print_info "========================================"
}

# Main execution
main() {
    print_info "=== Zabbix Proxy 7.0 LTS Installer ==="
    print_info "Elven Observability - Production Ready"
    print_info ""

    check_root
    detect_distro
    handle_previous_installation
    get_user_input
    get_performance_params "$PERFORMANCE_PROFILE"
    ensure_runtime_swap
    stop_existing_services
    install_postgresql
    configure_postgresql
    create_database
    install_zabbix
    import_schema
    configure_zabbix
    start_zabbix
    print_summary
}

# Run
main
