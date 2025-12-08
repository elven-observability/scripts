#!/bin/bash
# linux-instrumentation.sh
# Universal Linux installer for Node Exporter + OpenTelemetry Collector
# Elven Observability - LGTM Stack as a Service
#
# Supported distributions:
# - Ubuntu/Debian (apt)
# - RHEL/CentOS/Rocky/AlmaLinux/Fedora (yum/dnf)
# - Amazon Linux 2/2023 (yum/dnf)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Versions
NODE_EXPORTER_VERSION="1.8.2"
OTEL_VERSION="0.114.0"

# Directories
INSTALL_DIR="/opt/monitoring"
NODE_EXPORTER_DIR="$INSTALL_DIR/node_exporter"
OTEL_DIR="$INSTALL_DIR/otelcol"
CONFIG_DIR="/etc/otelcol"

# Service names
NODE_EXPORTER_SERVICE="node_exporter"
OTEL_SERVICE="otelcol"

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

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (use sudo)"
        exit 1
    fi
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

    # Determine package manager
    case $OS in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update"
            PKG_INSTALL="apt install -y"
            ;;
        rhel|centos|rocky|almalinux|ol)
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
                PKG_UPDATE="dnf check-update || true"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MANAGER="yum"
                PKG_UPDATE="yum check-update || true"
                PKG_INSTALL="yum install -y"
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf check-update || true"
            PKG_INSTALL="dnf install -y"
            ;;
        amzn)
            PKG_MANAGER="yum"
            PKG_UPDATE="yum check-update || true"
            PKG_INSTALL="yum install -y"
            ;;
        *)
            print_error "Unsupported distribution: $OS"
            print_info "Supported: Ubuntu, Debian, RHEL, CentOS, Rocky, AlmaLinux, Oracle Linux, Fedora, Amazon Linux"
            exit 1
            ;;
    esac

    print_success "Package manager: $PKG_MANAGER"
}

# Install dependencies
install_dependencies() {
    print_info "Installing dependencies..."
    
    # Update package cache
    print_info "  → Updating package cache..."
    if ! $PKG_UPDATE 2>&1 | tee /tmp/pkg_update.log; then
        # Check for RHEL subscription issues
        if grep -qi "subscription\|entitlement\|cdn.redhat.com" /tmp/pkg_update.log; then
            print_error "Red Hat subscription issue detected!"
            print_info ""
            print_info "This RHEL system is not properly registered."
            print_info "Please choose one of these solutions:"
            print_info ""
            echo "1. Install EPEL (works without subscription):"
            echo "   sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"
            print_info ""
            echo "2. Register with Red Hat subscription:"
            echo "   sudo subscription-manager register"
            echo "   sudo subscription-manager attach --auto"
            print_info ""
            echo "3. Use CentOS/Rocky repos (alternative):"
            echo "   sudo dnf install -y https://dl.rockylinux.org/pub/rocky/8/BaseOS/x86_64/os/Packages/r/rocky-release-8.9-1.6.el8.noarch.rpm"
            print_info ""
            rm /tmp/pkg_update.log
            exit 1
        fi
        print_warning "Package update had issues, continuing anyway..."
    fi
    rm -f /tmp/pkg_update.log
    
    # Install packages with proper error handling
    print_info "  → Installing curl, tar, gzip..."
    if ! $PKG_INSTALL curl tar gzip 2>&1 | tee /tmp/pkg_install.log; then
        # Check for subscription issues again
        if grep -qi "subscription\|entitlement\|cdn.redhat.com" /tmp/pkg_install.log; then
            print_error "Red Hat subscription issue detected during package installation!"
            print_info "See solutions above"
            rm /tmp/pkg_install.log
            exit 1
        fi
        
        print_error "Failed to install dependencies!"
        cat /tmp/pkg_install.log
        rm /tmp/pkg_install.log
        exit 1
    fi
    rm -f /tmp/pkg_install.log
    
    # Verify installation
    print_info "  → Verifying installation..."
    local missing=""
    for cmd in curl tar gzip; do
        if ! command -v $cmd &> /dev/null; then
            missing="$missing $cmd"
        fi
    done
    
    if [ -n "$missing" ]; then
        print_error "Missing commands after installation:$missing"
        exit 1
    fi
    
    print_success "Dependencies installed!"
}

# Download with retry
download_with_retry() {
    local url=$1
    local output=$2
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        echo "  Attempt $retry of $max_retries..."
        
        if curl -L -f -o "$output" "$url" 2>/dev/null; then
            if [ -f "$output" ] && [ -s "$output" ]; then
                local size=$(du -h "$output" | cut -f1)
                print_success "Download complete! ($size)"
                return 0
            fi
        fi
        
        print_warning "Attempt $retry failed"
        [ $retry -lt $max_retries ] && sleep 3
    done

    print_error "Failed to download after $max_retries attempts"
    return 1
}

# Get user input with validation
get_user_input() {
    print_info ""
    print_info "=== Configuration ==="
    print_info ""

    # Check if running non-interactively (via environment variables)
    if [ -n "$TENANT_ID" ] && [ -n "$API_TOKEN" ]; then
        print_info "Using environment variables for configuration..."
        
        # Use defaults if not set
        INSTANCE_NAME=${INSTANCE_NAME:-$(hostname)}
        CUSTOMER_NAME=${CUSTOMER_NAME:-}
        ENVIRONMENT=${ENVIRONMENT:-production}
        MIMIR_ENDPOINT=${MIMIR_ENDPOINT:-https://mimir.elvenobservability.com/api/v1/push}
        
        print_success "Configuration loaded from environment:"
        echo "  Tenant ID:   $TENANT_ID"
        echo "  Instance:    $INSTANCE_NAME"
        [ -n "$CUSTOMER_NAME" ] && echo "  Customer:    $CUSTOMER_NAME"
        echo "  Environment: $ENVIRONMENT"
        echo "  Endpoint:    $MIMIR_ENDPOINT"
        print_info ""
        
        return 0
    fi

    # Tenant ID
    while [ -z "$TENANT_ID" ]; do
        read -p "Tenant ID: " TENANT_ID < /dev/tty
        if [ -z "$TENANT_ID" ]; then
            print_error "Tenant ID cannot be empty!"
        fi
    done

    # API Token
    while [ -z "$API_TOKEN" ]; do
        read -sp "API Token: " API_TOKEN < /dev/tty
        echo
        if [ -z "$API_TOKEN" ]; then
            print_error "API Token cannot be empty!"
        fi
    done

    # Instance name with default
    read -p "Instance name (e.g., server-01) [default: $(hostname)]: " INSTANCE_NAME < /dev/tty
    if [ -z "$INSTANCE_NAME" ]; then
        INSTANCE_NAME=$(hostname)
        print_info "  → Using hostname: $INSTANCE_NAME"
    fi

    # Customer name (optional)
    read -p "Customer/Company name (optional) [default: none]: " CUSTOMER_NAME < /dev/tty

    # Environment with default
    read -p "Environment (production/staging/dev) [default: production]: " ENVIRONMENT < /dev/tty
    if [ -z "$ENVIRONMENT" ]; then
        ENVIRONMENT="production"
        print_info "  → Using default: $ENVIRONMENT"
    fi

    # Mimir endpoint with default
    print_info ""
    while true; do
        read -p "Mimir endpoint [default: https://mimir.elvenobservability.com/api/v1/push]: " MIMIR_ENDPOINT < /dev/tty
        if [ -z "$MIMIR_ENDPOINT" ]; then
            MIMIR_ENDPOINT="https://mimir.elvenobservability.com/api/v1/push"
            print_info "  → Using default (SaaS): $MIMIR_ENDPOINT"
            break
        elif [[ "$MIMIR_ENDPOINT" =~ ^https?:// ]]; then
            print_info "  → Using custom endpoint: $MIMIR_ENDPOINT"
            break
        else
            print_error "Endpoint must start with http:// or https://"
            print_info "  Example: https://metrics.vibraenergia.com.br/api/v1/push"
        fi
    done

    print_info ""
    print_success "Configuration summary:"
    echo "  Tenant ID:   $TENANT_ID"
    echo "  Instance:    $INSTANCE_NAME"
    [ -n "$CUSTOMER_NAME" ] && echo "  Customer:    $CUSTOMER_NAME"
    echo "  Environment: $ENVIRONMENT"
    echo "  Endpoint:    $MIMIR_ENDPOINT"
    print_info ""

    read -p "Confirm and continue? (y/n): " CONFIRM < /dev/tty
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_warning "Installation cancelled"
        exit 0
    fi
}

# Stop existing services
stop_existing_services() {
    print_info "Checking for existing services..."
    
    if systemctl is-active --quiet $NODE_EXPORTER_SERVICE 2>/dev/null; then
        print_info "  Stopping $NODE_EXPORTER_SERVICE..."
        systemctl stop $NODE_EXPORTER_SERVICE
    fi
    
    if systemctl is-active --quiet $OTEL_SERVICE 2>/dev/null; then
        print_info "  Stopping $OTEL_SERVICE..."
        systemctl stop $OTEL_SERVICE
    fi
    
    print_success "Clean!"
}

# Install Node Exporter
install_node_exporter() {
    print_info ""
    print_info "=== [1/2] Installing Node Exporter ==="
    print_info ""

    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            print_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    print_info "Architecture: $ARCH"

    # Download
    local download_url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    local temp_file="/tmp/node_exporter.tar.gz"

    print_info "Downloading Node Exporter v$NODE_EXPORTER_VERSION..."
    if ! download_with_retry "$download_url" "$temp_file"; then
        exit 1
    fi

    # Extract
    print_info "Extracting..."
    mkdir -p $NODE_EXPORTER_DIR
    tar -xzf $temp_file -C /tmp/
    mv /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter $NODE_EXPORTER_DIR/
    chmod +x $NODE_EXPORTER_DIR/node_exporter
    rm -rf /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}
    rm $temp_file

    print_success "Node Exporter installed to $NODE_EXPORTER_DIR"

    # Create systemd service
    print_info "Creating systemd service..."
    cat > /etc/systemd/system/$NODE_EXPORTER_SERVICE.service <<EOF
[Unit]
Description=Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network.target

[Service]
Type=simple
User=root
ExecStart=$NODE_EXPORTER_DIR/node_exporter
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $NODE_EXPORTER_SERVICE > /dev/null 2>&1
    systemctl start $NODE_EXPORTER_SERVICE

    sleep 2

    if systemctl is-active --quiet $NODE_EXPORTER_SERVICE; then
        print_success "Node Exporter running on port 9100!"
        
        # Test endpoint
        if curl -s http://localhost:9100/metrics > /dev/null; then
            print_success "Endpoint responding correctly!"
        else
            print_warning "Service running but endpoint not responding"
        fi
    else
        print_error "Node Exporter failed to start"
        journalctl -u $NODE_EXPORTER_SERVICE -n 20 --no-pager
        exit 1
    fi
}

# Install OpenTelemetry Collector
install_otel_collector() {
    print_info ""
    print_info "=== [2/2] Installing OpenTelemetry Collector ==="
    print_info ""

    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            print_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    # Download
    local download_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_${ARCH}.tar.gz"
    local temp_file="/tmp/otelcol.tar.gz"

    print_info "Downloading OpenTelemetry Collector v$OTEL_VERSION..."
    if ! download_with_retry "$download_url" "$temp_file"; then
        exit 1
    fi

    # Extract
    print_info "Extracting..."
    mkdir -p $OTEL_DIR
    tar -xzf $temp_file -C $OTEL_DIR/
    chmod +x $OTEL_DIR/otelcol-contrib
    rm $temp_file

    print_success "Collector installed to $OTEL_DIR"

    # Create config directory
    mkdir -p $CONFIG_DIR

    # Create configuration
    print_info "Creating configuration..."
    
    # Build customer label if provided
    local customer_label=""
    if [ -n "$CUSTOMER_NAME" ]; then
        customer_label="      - action: insert
        key: customer
        value: \"$CUSTOMER_NAME\""
    fi

    cat > $CONFIG_DIR/config.yaml <<EOF
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'node_exporter'
          scrape_interval: 30s
          static_configs:
            - targets: ['localhost:9100']

exporters:
  prometheusremotewrite:
    endpoint: $MIMIR_ENDPOINT
    headers:
      X-Scope-OrgID: "$TENANT_ID"
      Authorization: "Bearer $API_TOKEN"
    resource_to_telemetry_conversion:
      enabled: true

processors:
  resource/add_labels:
    attributes:
      - action: insert
        key: hostname
        value: "$INSTANCE_NAME"
      - action: insert
        key: environment
        value: "$ENVIRONMENT"
$customer_label
      - action: insert
        key: os
        value: "linux"
      - action: insert
        key: distro
        value: "$OS"

  batch:
    timeout: 10s
    send_batch_size: 1024

  filter:
    metrics:
      exclude:
        match_type: regexp
        metric_names:
          - "go_.*"
          - "scrape_.*"
          - "otlp_.*"
          - "promhttp_.*"
          - "process_.*"

service:
  pipelines:
    metrics:
      receivers: [prometheus]
      processors: [resource/add_labels, batch, filter]
      exporters: [prometheusremotewrite]
EOF

    print_success "Configuration created!"

    # Validate configuration
    print_info "Validating configuration..."
    if $OTEL_DIR/otelcol-contrib validate --config=$CONFIG_DIR/config.yaml > /dev/null 2>&1; then
        print_success "Configuration is valid!"
    else
        print_error "Invalid configuration!"
        $OTEL_DIR/otelcol-contrib validate --config=$CONFIG_DIR/config.yaml
        exit 1
    fi

    # Create systemd service
    print_info "Creating systemd service..."
    cat > /etc/systemd/system/$OTEL_SERVICE.service <<EOF
[Unit]
Description=OpenTelemetry Collector
Documentation=https://opentelemetry.io/docs/collector/
After=network.target

[Service]
Type=simple
User=root
ExecStart=$OTEL_DIR/otelcol-contrib --config=$CONFIG_DIR/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $OTEL_SERVICE > /dev/null 2>&1
    systemctl start $OTEL_SERVICE

    sleep 3

    if systemctl is-active --quiet $OTEL_SERVICE; then
        print_success "OpenTelemetry Collector is running!"
    else
        print_error "Collector failed to start"
        journalctl -u $OTEL_SERVICE -n 20 --no-pager
        exit 1
    fi
}

# Print final summary
print_summary() {
    print_info ""
    print_info "========================================"
    print_success "INSTALLATION COMPLETE!"
    print_info "========================================"
    print_info ""

    # Check service status
    print_success "Service Status:"
    if systemctl is-active --quiet $NODE_EXPORTER_SERVICE; then
        echo -e "  ${GREEN}✓${NC} Node Exporter: Running"
    else
        echo -e "  ${RED}✗${NC} Node Exporter: Not running"
    fi

    if systemctl is-active --quiet $OTEL_SERVICE; then
        echo -e "  ${GREEN}✓${NC} OpenTelemetry Collector: Running"
    else
        echo -e "  ${RED}✗${NC} OpenTelemetry Collector: Not running"
    fi

    print_info ""
    print_success "Configuration:"
    echo "  Instance:     $INSTANCE_NAME"
    [ -n "$CUSTOMER_NAME" ] && echo "  Customer:     $CUSTOMER_NAME"
    echo "  Environment:  $ENVIRONMENT"
    echo "  Tenant ID:    $TENANT_ID"
    echo "  Endpoint:     $MIMIR_ENDPOINT"
    echo "  Distribution: $OS_NAME"

    print_info ""
    print_success "Files:"
    echo "  Node Exporter:  $NODE_EXPORTER_DIR/node_exporter"
    echo "  Collector:      $OTEL_DIR/otelcol-contrib"
    echo "  Config:         $CONFIG_DIR/config.yaml"

    print_info ""
    print_success "Useful commands:"
    echo "  Check status:"
    echo "    systemctl status node_exporter otelcol"
    print_info ""
    echo "  Restart services:"
    echo "    systemctl restart node_exporter"
    echo "    systemctl restart otelcol"
    print_info ""
    echo "  View logs:"
    echo "    journalctl -u node_exporter -f"
    echo "    journalctl -u otelcol -f"
    print_info ""
    echo "  Test Node Exporter:"
    echo "    curl http://localhost:9100/metrics"
    print_info ""
    echo "  Validate config:"
    echo "    $OTEL_DIR/otelcol-contrib validate --config=$CONFIG_DIR/config.yaml"

    print_info ""
    print_success "Grafana validation:"
    if [ -n "$CUSTOMER_NAME" ]; then
        echo "  Query: {instance=\"$INSTANCE_NAME\", customer=\"$CUSTOMER_NAME\"}"
    else
        echo "  Query: {instance=\"$INSTANCE_NAME\"}"
    fi

    print_info ""
    print_success "Available metrics:"
    echo "  - node_cpu_*"
    echo "  - node_memory_*"
    echo "  - node_disk_*"
    echo "  - node_filesystem_*"
    echo "  - node_network_*"
    echo "  - node_load*"

    print_info ""
    print_info "========================================"
}

# Main execution
main() {
    print_info "=== Linux Instrumentation Installer ==="
    print_info "Elven Observability - Monitoring Setup"
    print_info ""

    check_root
    detect_distro
    get_user_input
    install_dependencies
    stop_existing_services
    install_node_exporter
    install_otel_collector
    print_summary
}

# Run main function
main