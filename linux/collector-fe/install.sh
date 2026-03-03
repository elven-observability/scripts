#!/bin/bash
# install.sh
# Universal Linux installer for Faro Collector (Frontend Instrumentation → Loki)
# Elven Observability - Faro Collector
#
# Recommended one-liner (use this repo's script):
#   curl -sSL https://raw.githubusercontent.com/elven-observability/collector-fe-instrumentation/main/scripts/install.sh | sudo bash
#
# Supported distributions:
# - Ubuntu/Debian (apt)
# - RHEL/CentOS/Rocky/AlmaLinux/Fedora (yum/dnf)
# - Amazon Linux 2/2023 (yum/dnf)
#
# Usage:
#   Interactive:  sudo ./install.sh
#   With env vars: sudo SECRET_KEY=... LOKI_URL=... LOKI_API_TOKEN=... ALLOW_ORIGINS=... ./install.sh
#   Private repo:  GITHUB_TOKEN=$(gh auth token) sudo -E bash -c 'curl -sSL ... | bash'
#   From local binary: sudo LOCAL_BINARY=/path/to/collector-fe-instrumentation-linux-amd64 ./install.sh

set -e
trap 'e=$?; if [ $e -ne 0 ]; then echo ""; echo -e "\033[0;31m✗ Installation failed (exit $e). See errors above.\033[0m"; exit $e; fi' EXIT

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults (override via env or GitHub Release)
GITHUB_REPO="${GITHUB_REPO:-elven-observability/collector-fe-instrumentation}"
COLLECTOR_VERSION="${COLLECTOR_VERSION:-latest}"
INSTALL_DIR="/opt/collector-fe-instrumentation"
CONFIG_DIR="/etc/collector-fe-instrumentation"
ENV_FILE="$CONFIG_DIR/env"
SERVICE_NAME="collector-fe-instrumentation"
BINARY_NAME="collector-fe-instrumentation"

# Functions
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info()    { echo -e "${CYAN}$1${NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (use sudo)"
        exit 1
    fi
}

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
            PKG_UPDATE="apt update"
            PKG_INSTALL="apt install -y"
            ;;
        rhel|centos|rocky|almalinux|ol)
            if command -v dnf &> /dev/null; then
                PKG_UPDATE="dnf check-update || true"
                PKG_INSTALL="dnf install -y"
            else
                PKG_UPDATE="yum check-update || true"
                PKG_INSTALL="yum install -y"
            fi
            ;;
        fedora)
            PKG_UPDATE="dnf check-update || true"
            PKG_INSTALL="dnf install -y"
            ;;
        amzn)
            PKG_UPDATE="yum check-update || true"
            PKG_INSTALL="yum install -y"
            ;;
        *)
            print_error "Unsupported distribution: $OS"
            exit 1
            ;;
    esac
    print_success "Package manager detected"
}

get_latest_version() {
    local url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local tag
    if [ -n "$GITHUB_TOKEN" ]; then
        tag=$(curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" "$url" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    else
        tag=$(curl -sL "$url" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    fi
    if [ -z "$tag" ]; then
        print_warning "Could not fetch latest release from GitHub (repo: $GITHUB_REPO), trying v0.1.0"
        tag="v0.1.0"
    fi
    echo "$tag"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

download_with_retry() {
    local url=$1
    local output=$2
    local max_retries=3
    local retry=0
    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        print_info "  Attempt $retry of $max_retries..."
        local code
        if [ -n "$GITHUB_TOKEN" ]; then
            code=$(curl -sSL -w '%{http_code}' -o "$output" -H "Authorization: Bearer $GITHUB_TOKEN" "$url" 2>/dev/null) || code="000"
        else
            code=$(curl -sSL -w '%{http_code}' -o "$output" "$url" 2>/dev/null) || code="000"
        fi
        if [ -f "$output" ] && [ -s "$output" ] && [ "$code" = "200" ]; then
            print_success "Download complete"
            return 0
        fi
        if [ $retry -eq $max_retries ]; then
            print_error "Download failed (HTTP $code). URL: $url"
        else
            print_warning "Attempt $retry failed (HTTP $code)"
        fi
        [ $retry -lt $max_retries ] && sleep 3
    done
    return 1
}

# Download release asset from private repo via GitHub API (requires GITHUB_TOKEN).
download_github_asset() {
    local token=$1
    local repo=$2
    local version=$3
    local asset_name=$4
    local output=$5
    local api_url
    if [ "$version" = "latest" ]; then
        api_url="https://api.github.com/repos/${repo}/releases/latest"
    else
        api_url="https://api.github.com/repos/${repo}/releases/tags/${version}"
    fi
    local json
    json=$(curl -sL -H "Authorization: Bearer $token" "$api_url" 2>/dev/null)
    [ -z "$json" ] && return 1
    local asset_id
    if command -v jq &>/dev/null; then
        asset_id=$(echo "$json" | jq -r --arg n "$asset_name" '.assets[] | select(.name == $n) | .id' 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        asset_id=$(echo "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for a in d.get('assets', []):
        if a.get('name') == sys.argv[1]:
            print(a['id'])
            break
except Exception:
    pass
" "$asset_name" 2>/dev/null)
    fi
    [ -z "$asset_id" ] && return 1
    local asset_url="https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
    if curl -sSL -H "Authorization: Bearer $token" -H "Accept: application/octet-stream" -o "$output" "$asset_url" 2>/dev/null; then
        [ -f "$output" ] && [ -s "$output" ] && return 0
    fi
    return 1
}

get_user_input() {
    print_info ""
    print_info "=== Faro Collector Configuration ==="
    print_info ""

    # 1. Apply Defaults to optional variables
    LOKI_URL=${LOKI_URL:-"https://loki.elvenobservability.com"}
    ALLOW_ORIGINS=${ALLOW_ORIGINS:-"*"}
    PORT=${PORT:-3000}
    JWT_ISSUER=${JWT_ISSUER:-"trusted-issuer"}
    JWT_VALIDATE_EXP=${JWT_VALIDATE_EXP:-"false"}

    # 2. Check if we have required variables for auto-install
    if [ -n "$SECRET_KEY" ] && [ -n "$LOKI_API_TOKEN" ]; then
        print_info "Using environment variables..."
        
        if [ ${#SECRET_KEY} -lt 64 ]; then
            print_error "SECRET_KEY must be at least 64 characters"
            exit 1
        fi

        print_success "Configuration loaded from environment"
        echo "  SECRET_KEY:     (set, ${#SECRET_KEY} chars)"
        echo "  LOKI_URL:       $LOKI_URL"
        echo "  LOKI_API_TOKEN: ****"
        echo "  ALLOW_ORIGINS:  $ALLOW_ORIGINS"
        echo "  PORT:           $PORT"
        print_info ""
        return 0
    fi

    # 3. If required vars are missing, check if we can prompt interactively
    # 3. If required vars are missing, check if we can prompt interactively
    # We check /dev/tty because when running "curl | bash", stdin is the script, not the terminal.
    # But /dev/tty is still available for user input.
    if [ ! -c /dev/tty ]; then
        print_error "Non-interactive installation blocked: Missing required environment variables."
        print_error "Please set SECRET_KEY and LOKI_API_TOKEN."
        exit 1
    fi

    # 4. Interactive Mode
    print_info "Interactive Setup (press Enter to use defaults)"
    
    while [ -z "$SECRET_KEY" ]; do
        read -p "SECRET_KEY (min 64 chars, for JWT validation): " SECRET_KEY < /dev/tty
        if [ ${#SECRET_KEY} -lt 64 ]; then
            print_error "SECRET_KEY must be at least 64 characters"
            SECRET_KEY=""
        fi
    done

    # Show default in prompt, but we already set the variable, so we need to handle that.
    # Actually, since we set defaults above, we can just display them.
    
    read -p "LOKI_URL [default: $LOKI_URL]: " input_loki < /dev/tty
    [ -n "$input_loki" ] && LOKI_URL="$input_loki"

    while [ -z "$LOKI_API_TOKEN" ]; do
        read -sp "LOKI_API_TOKEN: " LOKI_API_TOKEN < /dev/tty
        echo
        if [ -z "$LOKI_API_TOKEN" ]; then
            print_error "LOKI_API_TOKEN cannot be empty"
        fi
    done

    read -p "ALLOW_ORIGINS (comma-separated or * for all) [default: $ALLOW_ORIGINS]: " input_origins < /dev/tty
    [ -n "$input_origins" ] && ALLOW_ORIGINS="$input_origins"

    read -p "PORT [default: $PORT]: " input_port < /dev/tty
    [ -n "$input_port" ] && PORT="$input_port"

    read -p "JWT_ISSUER [default: $JWT_ISSUER]: " input_jwt < /dev/tty
    [ -n "$input_jwt" ] && JWT_ISSUER="$input_jwt"

    read -p "JWT_VALIDATE_EXP (true/false) [default: $JWT_VALIDATE_EXP]: " input_exp < /dev/tty
    [ -n "$input_exp" ] && JWT_VALIDATE_EXP="$input_exp"

    print_info ""
    print_success "Configuration summary:"
    echo "  LOKI_URL:       $LOKI_URL"
    echo "  LOKI_API_TOKEN: ****"
    echo "  ALLOW_ORIGINS:  $ALLOW_ORIGINS"
    echo "  PORT:           $PORT"
    print_info ""

    read -p "Continue with installation? (y/n): " CONFIRM < /dev/tty
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_warning "Installation cancelled"
        exit 0
    fi
}

install_dependencies() {
    print_info "Installing dependencies..."
    $PKG_UPDATE 2>/dev/null || true
    if ! $PKG_INSTALL curl 2>&1 | tee /tmp/pkg_install.log; then
        if grep -qi "subscription\|entitlement\|cdn.redhat.com" /tmp/pkg_install.log 2>/dev/null; then
            print_error "Package manager issue (e.g. RHEL subscription). Install curl manually and re-run."
            rm -f /tmp/pkg_install.log
            exit 1
        fi
        print_error "Failed to install curl"
        rm -f /tmp/pkg_install.log
        exit 1
    fi
    rm -f /tmp/pkg_install.log
    print_success "Dependencies OK"
}

stop_existing_service() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "Stopping existing $SERVICE_NAME..."
        systemctl stop "$SERVICE_NAME"
    fi
    print_success "Clean"
}

install_binary() {
    print_info ""
    print_info "=== Installing Faro Collector ==="
    print_info ""

    local arch
    arch=$(detect_arch)
    print_info "Architecture: $arch"

    mkdir -p "$INSTALL_DIR"
    local binary_path="$INSTALL_DIR/$BINARY_NAME"

    if [ -n "$LOCAL_BINARY" ]; then
        if [ ! -f "$LOCAL_BINARY" ]; then
            print_error "Local binary not found: $LOCAL_BINARY"
            exit 1
        fi
        print_info "Copying from $LOCAL_BINARY..."
        cp -f "$LOCAL_BINARY" "$binary_path"
    elif [ -n "$BINARY_URL" ]; then
        print_info "Downloading from BINARY_URL..."
        if ! download_with_retry "$BINARY_URL" "/tmp/${BINARY_NAME}-linux-${arch}"; then
            print_error "Download failed. Check BINARY_URL or use LOCAL_BINARY=/path/to/binary"
            exit 1
        fi
        cp -f "/tmp/${BINARY_NAME}-linux-${arch}" "$binary_path"
        rm -f "/tmp/${BINARY_NAME}-linux-${arch}"
    else
        # Resolve token: GITHUB_TOKEN or gh auth token (for private repo)
        [ -z "$GITHUB_TOKEN" ] && command -v gh &>/dev/null && GITHUB_TOKEN=$(gh auth token 2>/dev/null)
        local version="$COLLECTOR_VERSION"
        if [ "$version" = "latest" ]; then
            version=$(get_latest_version)
            print_info "Release: $version"
        fi
        local output_tmp="/tmp/${BINARY_NAME}-linux-${arch}"
        local asset_name="${BINARY_NAME}-linux-${arch}"
        if [ -n "$GITHUB_TOKEN" ]; then
            if ! command -v jq &>/dev/null && ! command -v python3 &>/dev/null; then
                print_error "Private repo requires jq or python3 to parse release. Install one: apt install -y jq"
                exit 1
            fi
            print_info "Repo: $GITHUB_REPO (private) | Downloading asset: $asset_name"
            if ! download_github_asset "$GITHUB_TOKEN" "$GITHUB_REPO" "$version" "$asset_name" "$output_tmp"; then
                print_error "Download failed (private repo). Check GITHUB_TOKEN or run: gh auth login"
                print_info "  Or use: GITHUB_TOKEN=\$(gh auth token) $0"
                exit 1
            fi
        else
            local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${asset_name}"
            print_info "Repo: $GITHUB_REPO | Downloading: $url"
            if ! download_with_retry "$url" "$output_tmp"; then
                print_error "Download failed."
                print_info "  For private repo use: GITHUB_TOKEN=\$(gh auth token) $0"
                print_info "  Or: LOCAL_BINARY=/path/to/${asset_name} $0"
                print_info "  Or: BINARY_URL=<public-url> $0"
                exit 1
            fi
        fi
        cp -f "$output_tmp" "$binary_path"
        rm -f "$output_tmp"
    fi

    chmod +x "$binary_path"
    print_success "Binary installed to $binary_path"
}

write_env_file() {
    print_info "Writing configuration..."
    mkdir -p "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
    PORT=${PORT:-3000}
    JWT_ISSUER=${JWT_ISSUER:-trusted-issuer}
    JWT_VALIDATE_EXP=${JWT_VALIDATE_EXP:-false}
    cat > "$ENV_FILE" << EOF
# Faro Collector - generated by install.sh
SECRET_KEY=$SECRET_KEY
LOKI_URL=$LOKI_URL
LOKI_API_TOKEN=$LOKI_API_TOKEN
ALLOW_ORIGINS=$ALLOW_ORIGINS
PORT=$PORT
JWT_ISSUER=$JWT_ISSUER
JWT_VALIDATE_EXP=$JWT_VALIDATE_EXP
EOF
    chmod 600 "$ENV_FILE"
    print_success "Config: $ENV_FILE"
}

create_systemd_service() {
    print_info "Creating systemd service..."
    # Use wrapper so env file is always loaded (source + exec); some systemd setups don't load EnvironmentFile.
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Faro Collector (Frontend Instrumentation to Loki)
Documentation=https://github.com/${GITHUB_REPO}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/bin/bash -c 'set -a; . $ENV_FILE; set +a; exec $INSTALL_DIR/$BINARY_NAME'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    print_success "Service: $SERVICE_NAME"
}

set_selinux_context() {
    local binary_path="$INSTALL_DIR/$BINARY_NAME"
    if ! command -v getenforce &> /dev/null; then
        return 0
    fi
    local status
    status=$(getenforce 2>/dev/null || echo "Disabled")
    if [ "$status" = "Disabled" ]; then
        return 0
    fi
    print_info "Setting SELinux context..."
    chcon -t bin_t "$binary_path" 2>/dev/null || true
    if command -v semanage &> /dev/null; then
        semanage fcontext -a -t bin_t "$binary_path" 2>/dev/null || \
        semanage fcontext -m -t bin_t "$binary_path" 2>/dev/null || true
        restorecon -v "$binary_path" 2>/dev/null || true
    fi
    print_success "SELinux OK"
}

start_service() {
    print_info "Starting $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "$SERVICE_NAME is running"
    else
        print_error "Service failed to start"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
        exit 1
    fi
}

print_summary() {
    print_info ""
    print_info "========================================"
    print_success "INSTALLATION COMPLETE!"
    print_info "========================================"
    print_info ""
    print_success "Service:"
    echo "  Status:  systemctl status $SERVICE_NAME"
    echo "  Restart: systemctl restart $SERVICE_NAME"
    echo "  Logs:    journalctl -u $SERVICE_NAME -f"
    print_info ""
    print_success "Paths:"
    echo "  Binary:  $INSTALL_DIR/$BINARY_NAME"
    echo "  Config: $ENV_FILE"
    print_info ""
    print_success "Endpoints:"
    echo "  Collect: POST http://<host>:${PORT}/collect/:tenant/:token"
    echo "  Health:  GET  http://<host>:${PORT}/health"
    print_info ""
    print_info "========================================"
}

main() {
    print_info "=== Faro Collector Installer ==="
    print_info "Elven Observability - Frontend Instrumentation to Loki"
    print_info ""

    check_root
    detect_distro
    get_user_input
    install_dependencies
    stop_existing_service
    install_binary
    write_env_file
    create_systemd_service
    set_selinux_context
    start_service
    print_summary
}

main
