#!/bin/bash
# install.sh
# Universal Linux installer for Faro Collector (Frontend Instrumentation → Loki)
# Elven Observability - Faro Collector
#
# Supported distributions:
# - Ubuntu/Debian (apt)
# - RHEL/CentOS/Rocky/AlmaLinux/Fedora (yum/dnf)
# - Amazon Linux 2/2023 (yum/dnf)
#
# Usage:
#   Interactive:  sudo ./install.sh
#   With env vars: sudo SECRET_KEY=... LOKI_URL=... LOKI_API_TOKEN=... ALLOW_ORIGINS=... ./install.sh
#   From local binary: sudo LOCAL_BINARY=/path/to/collector-fe-instrumentation-linux-amd64 ./install.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults (override via env or GitHub Release)
GITHUB_REPO="${GITHUB_REPO:-elven/collector-fe-instrumentation}"
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
    tag=$(curl -sL "$url" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    if [ -z "$tag" ]; then
        print_error "Could not fetch latest release from GitHub"
        exit 1
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
        if curl -L -f -o "$output" "$url" 2>/dev/null; then
            if [ -f "$output" ] && [ -s "$output" ]; then
                print_success "Download complete"
                return 0
            fi
        fi
        [ $retry -lt $max_retries ] && sleep 3
    done
    print_error "Failed to download after $max_retries attempts"
    return 1
}

get_user_input() {
    print_info ""
    print_info "=== Faro Collector Configuration ==="
    print_info ""

    if [ -n "$SECRET_KEY" ] && [ -n "$LOKI_URL" ] && [ -n "$LOKI_API_TOKEN" ] && [ -n "$ALLOW_ORIGINS" ]; then
        print_info "Using environment variables..."
        PORT=${PORT:-3000}
        JWT_ISSUER=${JWT_ISSUER:-trusted-issuer}
        JWT_VALIDATE_EXP=${JWT_VALIDATE_EXP:-false}
        if [ ${#SECRET_KEY} -lt 32 ]; then
            print_error "SECRET_KEY must be at least 32 characters"
            exit 1
        fi
        print_success "Configuration loaded from environment"
        echo "  SECRET_KEY:    (set, ${#SECRET_KEY} chars)"
        echo "  LOKI_URL:      $LOKI_URL"
        echo "  LOKI_API_TOKEN: (set)"
        echo "  ALLOW_ORIGINS: $ALLOW_ORIGINS"
        echo "  PORT:          $PORT"
        print_info ""
        return 0
    fi

    while [ -z "$SECRET_KEY" ]; do
        read -p "SECRET_KEY (min 32 chars, for JWT validation): " SECRET_KEY < /dev/tty
        if [ ${#SECRET_KEY} -lt 32 ]; then
            print_error "SECRET_KEY must be at least 32 characters"
            SECRET_KEY=""
        fi
    done

    while [ -z "$LOKI_URL" ]; do
        read -p "LOKI_URL (e.g. https://loki.elvenobservability.com): " LOKI_URL < /dev/tty
        if [ -z "$LOKI_URL" ]; then
            print_error "LOKI_URL cannot be empty"
        fi
    done

    while [ -z "$LOKI_API_TOKEN" ]; do
        read -sp "LOKI_API_TOKEN: " LOKI_API_TOKEN < /dev/tty
        echo
        if [ -z "$LOKI_API_TOKEN" ]; then
            print_error "LOKI_API_TOKEN cannot be empty"
        fi
    done

    while [ -z "$ALLOW_ORIGINS" ]; do
        read -p "ALLOW_ORIGINS (comma-separated, e.g. https://app.example.com): " ALLOW_ORIGINS < /dev/tty
        if [ -z "$ALLOW_ORIGINS" ]; then
            print_error "ALLOW_ORIGINS cannot be empty"
        fi
    done

    read -p "PORT [default: 3000]: " PORT < /dev/tty
    PORT=${PORT:-3000}

    read -p "JWT_ISSUER [default: trusted-issuer]: " JWT_ISSUER < /dev/tty
    JWT_ISSUER=${JWT_ISSUER:-trusted-issuer}

    read -p "JWT_VALIDATE_EXP (true/false) [default: false]: " JWT_VALIDATE_EXP < /dev/tty
    JWT_VALIDATE_EXP=${JWT_VALIDATE_EXP:-false}

    print_info ""
    print_success "Configuration summary:"
    echo "  LOKI_URL:      $LOKI_URL"
    echo "  ALLOW_ORIGINS: $ALLOW_ORIGINS"
    echo "  PORT:          $PORT"
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
    else
        local version="$COLLECTOR_VERSION"
        if [ "$version" = "latest" ]; then
            version=$(get_latest_version)
            print_info "Latest release: $version"
        fi
        local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${BINARY_NAME}-linux-${arch}"
        print_info "Downloading $url..."
        if ! download_with_retry "$url" "/tmp/${BINARY_NAME}-linux-${arch}"; then
            print_error "Download failed. Set LOCAL_BINARY=/path/to/binary to install from file."
            exit 1
        fi
        cp -f "/tmp/${BINARY_NAME}-linux-${arch}" "$binary_path"
        rm -f "/tmp/${BINARY_NAME}-linux-${arch}"
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
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Faro Collector (Frontend Instrumentation to Loki)
Documentation=https://github.com/${GITHUB_REPO}
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=-$ENV_FILE
ExecStart=$INSTALL_DIR/$BINARY_NAME
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
