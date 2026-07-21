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
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Versions
NODE_EXPORTER_VERSION="1.12.1"
OTEL_VERSION="0.156.0"

# Directories
INSTALL_DIR="/opt/monitoring"
NODE_EXPORTER_DIR="$INSTALL_DIR/node_exporter"
OTEL_DIR="$INSTALL_DIR/otelcol"
CONFIG_DIR="/etc/otelcol"
OTEL_STORAGE_DIR="/var/lib/otelcol/file_storage"

# Service names
NODE_EXPORTER_SERVICE="node_exporter"
OTEL_SERVICE="otelcol"

# Runtime configuration populated by get_user_input.
declare -A CUSTOM_LABELS_MAP=()
declare -A OTLP_HEADERS_MAP=()
METRICS_DESTINATION="mimir"

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

get_env_value() {
    local name
    local value

    for name in "$@"; do
        value="${!name-}"
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    done

    return 1
}

is_true() {
    case "${1,,}" in
        1|true|yes|y) return 0 ;;
        *) return 1 ;;
    esac
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_api_token() {
    local token
    token=$(trim_whitespace "$1")

    if [[ "$token" =~ ^[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+(.+)$ ]]; then
        token="${BASH_REMATCH[1]}"
    elif [[ "$token" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then
        token="${BASH_REMATCH[1]}"
    fi

    if [[ "$token" == \"*\" && "$token" == *\" ]] || [[ "$token" == \'*\' && "$token" == *\' ]]; then
        token="${token:1:${#token}-2}"
    fi

    trim_whitespace "$token"
}

yaml_quote() {
    local value="$1"

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        print_error "Configuration values cannot contain line breaks."
        return 1
    fi

    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

validate_http_url() {
    [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

validate_prometheus_label_name() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

parse_otlp_headers() {
    local header_list="$1"
    local entry
    local name
    local value
    local -a entries=()

    [ -z "$header_list" ] && return 0

    IFS=',' read -r -a entries <<< "$header_list"
    for entry in "${entries[@]}"; do
        if [[ "$entry" != *=* ]]; then
            print_error "Invalid OTLP header entry. Expected name=value."
            return 1
        fi

        name=$(trim_whitespace "${entry%%=*}")
        value=$(trim_whitespace "${entry#*=}")

        if [[ ! "$name" =~ ^[a-zA-Z0-9!#\$%\&\'*+.^_\`|~-]+$ ]]; then
            print_error "Invalid OTLP header name: $name"
            return 1
        fi
        if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
            print_error "OTLP header values cannot contain line breaks."
            return 1
        fi

        OTLP_HEADERS_MAP["$name"]="$value"
    done
}

validate_otlp_tls_files() {
    local path

    if { [ -n "$OTLP_TLS_CERT_FILE" ] && [ -z "$OTLP_TLS_KEY_FILE" ]; } ||
       { [ -z "$OTLP_TLS_CERT_FILE" ] && [ -n "$OTLP_TLS_KEY_FILE" ]; }; then
        print_error "ELVEN_OTLP_TLS_CERT_FILE and ELVEN_OTLP_TLS_KEY_FILE must be configured together."
        return 1
    fi

    for path in "$OTLP_TLS_CA_FILE" "$OTLP_TLS_CERT_FILE" "$OTLP_TLS_KEY_FILE"; do
        if [ -n "$path" ] && [ ! -r "$path" ]; then
            print_error "TLS file is not readable: $path"
            return 1
        fi
    done
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
        # shellcheck source=/dev/null
        . /etc/os-release
        OS=$ID
        # shellcheck disable=SC2153 # NAME comes from /etc/os-release.
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
            ;;
        rhel|centos|rocky|almalinux|ol)
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        amzn)
            if command -v dnf &> /dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            print_error "Unsupported distribution: $OS"
            print_info "Supported: Ubuntu, Debian, RHEL, CentOS, Rocky, AlmaLinux, Oracle Linux, Fedora, Amazon Linux"
            exit 1
            ;;
    esac

    print_success "Package manager: $PKG_MANAGER"
}

update_package_cache() {
    local status

    case "$PKG_MANAGER" in
        apt)
            apt update
            ;;
        dnf|yum)
            # check-update returns 100 when updates are available; that is not an error.
            "$PKG_MANAGER" check-update || {
                status=$?
                [ "$status" -eq 100 ]
            }
            ;;
    esac
}

install_packages() {
    case "$PKG_MANAGER" in
        apt)
            apt install -y "$@"
            ;;
        dnf|yum)
            "$PKG_MANAGER" install -y "$@"
            ;;
    esac
}

package_for_command() {
    case "$1" in
        curl)
            # Amazon Linux 2023 ships curl-minimal by default. Installing the full
            # curl package alongside it causes a package conflict.
            if [ "$OS" = "amzn" ] && [[ "${VERSION_ID:-}" == 2023* ]]; then
                printf '%s' "curl-minimal"
            else
                printf '%s' "curl"
            fi
            ;;
        tar|gzip)
            printf '%s' "$1"
            ;;
    esac
}

# Install dependencies
install_dependencies() {
    local command_name
    local package_name
    local update_log
    local install_log
    local -a missing_commands=()
    local -a packages=()

    print_info "Installing dependencies..."

    for command_name in curl tar gzip; do
        if ! command -v "$command_name" &> /dev/null; then
            missing_commands+=("$command_name")
            package_name=$(package_for_command "$command_name")
            packages+=("$package_name")
        fi
    done

    if [ "${#missing_commands[@]}" -eq 0 ]; then
        print_success "Dependencies already available; no packages changed."
        return 0
    fi

    print_info "  → Missing commands: ${missing_commands[*]}"

    # Update package cache
    print_info "  → Updating package cache..."
    update_log=$(mktemp /tmp/elven-pkg-update.XXXXXX)
    chmod 600 "$update_log"
    if ! update_package_cache 2>&1 | tee "$update_log"; then
        # Check for RHEL subscription issues
        if grep -qi "subscription\|entitlement\|cdn.redhat.com" "$update_log"; then
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
            rm -f "$update_log"
            exit 1
        fi
        print_warning "Package update had issues, continuing anyway..."
    fi
    rm -f "$update_log"

    # Install packages with proper error handling
    print_info "  → Installing packages: ${packages[*]}"
    install_log=$(mktemp /tmp/elven-pkg-install.XXXXXX)
    chmod 600 "$install_log"
    if ! install_packages "${packages[@]}" 2>&1 | tee "$install_log"; then
        # Check for subscription issues again
        if grep -qi "subscription\|entitlement\|cdn.redhat.com" "$install_log"; then
            print_error "Red Hat subscription issue detected during package installation!"
            print_info "See solutions above"
            rm -f "$install_log"
            exit 1
        fi

        print_error "Failed to install dependencies!"
        rm -f "$install_log"
        exit 1
    fi
    rm -f "$install_log"

    # Verify installation
    print_info "  → Verifying installation..."
    missing_commands=()
    for command_name in curl tar gzip; do
        if ! command -v "$command_name" &> /dev/null; then
            missing_commands+=("$command_name")
        fi
    done

    if [ "${#missing_commands[@]}" -ne 0 ]; then
        print_error "Missing commands after installation: ${missing_commands[*]}"
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
                local size
                size=$(du -h "$output" | cut -f1)
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

calculate_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        print_error "Neither sha256sum nor shasum is available for checksum validation."
        return 1
    fi
}

verify_sha256_from_manifest() {
    local file_path="$1"
    local asset_name="$2"
    local manifest_url="$3"
    local manifest_file
    local expected
    local actual

    manifest_file=$(mktemp /tmp/elven-checksums.XXXXXX)
    if ! download_with_retry "$manifest_url" "$manifest_file"; then
        rm -f "$manifest_file"
        print_error "Could not download the checksum manifest."
        return 1
    fi

    expected=$(awk -v asset="$asset_name" '$2 == asset || $2 == "*" asset {print $1; exit}' "$manifest_file")
    rm -f "$manifest_file"

    if [ -z "$expected" ]; then
        print_error "Checksum not found for $asset_name"
        return 1
    fi

    actual=$(calculate_sha256 "$file_path") || return 1
    if [ "$actual" != "$expected" ]; then
        print_error "SHA-256 validation failed for $asset_name"
        print_error "Expected: $expected"
        print_error "Actual:   $actual"
        return 1
    fi

    print_success "SHA-256 verified for $asset_name"
}

# Get user input with validation
get_user_input() {
    local destination_input
    local auto_confirm_input
    local legacy_non_interactive="false"
    local non_interactive="false"
    local token_input
    local add_token
    local add_labels
    local label
    local label_name
    local label_value
    local confirm
    local insecure_skip_verify_input

    print_info ""
    print_info "=== Configuration ==="
    print_info ""

    auto_confirm_input=$(get_env_value ELVEN_AUTO_CONFIRM AUTO_CONFIRM || true)
    AUTO_CONFIRM="false"
    if [ -n "$auto_confirm_input" ]; then
        if is_true "$auto_confirm_input"; then
            AUTO_CONFIRM="true"
        elif [[ ! "${auto_confirm_input,,}" =~ ^(0|false|no|n)$ ]]; then
            print_error "ELVEN_AUTO_CONFIRM must be true or false."
            exit 1
        fi
    fi

    destination_input=$(get_env_value ELVEN_METRICS_DESTINATION METRICS_DESTINATION || true)
    destination_input=${destination_input:-mimir}
    case "${destination_input,,}" in
        mimir|prometheusremotewrite|prometheus_remote_write)
            METRICS_DESTINATION="mimir"
            ;;
        collector|otlp|otlphttp)
            METRICS_DESTINATION="collector"
            ;;
        *)
            print_error "Invalid metrics destination: $destination_input"
            print_info "Supported values: mimir, collector"
            exit 1
            ;;
    esac

    TENANT_ID=$(get_env_value ELVEN_TENANT_ID TENANT_ID || true)
    token_input=$(get_env_value ELVEN_API_TOKEN API_TOKEN || true)
    API_TOKEN=$(normalize_api_token "$token_input")
    INSTANCE_NAME=$(get_env_value ELVEN_INSTANCE_NAME INSTANCE_NAME || true)
    CUSTOMER_NAME=$(get_env_value ELVEN_CUSTOMER_NAME CUSTOMER_NAME || true)
    ENVIRONMENT=$(get_env_value ELVEN_ENVIRONMENT ENVIRONMENT || true)
    CUSTOM_LABELS=$(get_env_value ELVEN_CUSTOM_LABELS CUSTOM_LABELS || true)

    OTLP_ENDPOINT=$(get_env_value ELVEN_OTLP_ENDPOINT OTLP_ENDPOINT OTEL_EXPORTER_OTLP_ENDPOINT || true)
    token_input=$(get_env_value ELVEN_OTLP_API_TOKEN OTLP_API_TOKEN || true)
    OTLP_API_TOKEN=$(normalize_api_token "$token_input")
    OTLP_HEADERS=$(get_env_value ELVEN_OTLP_HEADERS OTLP_HEADERS || true)
    OTLP_TLS_CA_FILE=$(get_env_value ELVEN_OTLP_TLS_CA_FILE OTLP_TLS_CA_FILE || true)
    OTLP_TLS_CERT_FILE=$(get_env_value ELVEN_OTLP_TLS_CERT_FILE OTLP_TLS_CERT_FILE || true)
    OTLP_TLS_KEY_FILE=$(get_env_value ELVEN_OTLP_TLS_KEY_FILE OTLP_TLS_KEY_FILE || true)
    insecure_skip_verify_input=$(get_env_value ELVEN_OTLP_TLS_INSECURE_SKIP_VERIFY OTLP_TLS_INSECURE_SKIP_VERIFY || true)
    OTLP_TLS_INSECURE_SKIP_VERIFY="false"
    if [ -n "$insecure_skip_verify_input" ]; then
        if is_true "$insecure_skip_verify_input"; then
            OTLP_TLS_INSECURE_SKIP_VERIFY="true"
        elif [[ ! "${insecure_skip_verify_input,,}" =~ ^(0|false|no|n)$ ]]; then
            print_error "ELVEN_OTLP_TLS_INSECURE_SKIP_VERIFY must be true or false."
            exit 1
        fi
    fi

    if [ "$METRICS_DESTINATION" = "mimir" ] && [ -n "$TENANT_ID" ] && [ -n "$API_TOKEN" ]; then
        legacy_non_interactive="true"
    fi
    if [ "$AUTO_CONFIRM" = "true" ] || [ "$legacy_non_interactive" = "true" ]; then
        non_interactive="true"
        print_info "Using environment variables for configuration..."
    fi

    if [ -z "$INSTANCE_NAME" ] && [ "$non_interactive" != "true" ]; then
        read -r -p "Instance name (e.g., server-01) [default: $(hostname)]: " INSTANCE_NAME < /dev/tty
    fi
    if [ -z "$INSTANCE_NAME" ]; then
        INSTANCE_NAME=$(hostname)
        print_info "  → Using hostname: $INSTANCE_NAME"
    fi

    if [ -z "$CUSTOMER_NAME" ] && [ "$non_interactive" != "true" ]; then
        read -r -p "Customer/Company name (optional) [default: none]: " CUSTOMER_NAME < /dev/tty
    fi

    if [ -z "$ENVIRONMENT" ] && [ "$non_interactive" != "true" ]; then
        read -r -p "Environment (production/staging/dev) [default: production]: " ENVIRONMENT < /dev/tty
    fi
    if [ -z "$ENVIRONMENT" ]; then
        ENVIRONMENT="production"
        print_info "  → Using default: $ENVIRONMENT"
    fi

    if [ "$METRICS_DESTINATION" = "mimir" ]; then
        while [ -z "$TENANT_ID" ]; do
            if [ "$AUTO_CONFIRM" = "true" ]; then
                print_error "ELVEN_TENANT_ID is required for the Mimir destination."
                exit 1
            fi
            read -r -p "Tenant ID: " TENANT_ID < /dev/tty
            [ -z "$TENANT_ID" ] && print_error "Tenant ID cannot be empty!"
        done

        while [ -z "$API_TOKEN" ]; do
            if [ "$AUTO_CONFIRM" = "true" ]; then
                print_error "ELVEN_API_TOKEN is required for the Mimir destination."
                exit 1
            fi
            read -r -s -p "API Token: " token_input < /dev/tty
            echo
            API_TOKEN=$(normalize_api_token "$token_input")
            [ -z "$API_TOKEN" ] && print_error "API Token cannot be empty!"
        done

        MIMIR_ENDPOINT=$(get_env_value ELVEN_MIMIR_ENDPOINT MIMIR_ENDPOINT || true)
        while true; do
            if [ -z "$MIMIR_ENDPOINT" ] && [ "$non_interactive" != "true" ]; then
                read -r -p "Mimir endpoint [default: https://mimir.elvenobservability.com/api/v1/push]: " MIMIR_ENDPOINT < /dev/tty
            fi
            MIMIR_ENDPOINT=${MIMIR_ENDPOINT:-https://mimir.elvenobservability.com/api/v1/push}
            if validate_http_url "$MIMIR_ENDPOINT"; then
                break
            fi
            print_error "Mimir endpoint must be a valid http:// or https:// URL."
            MIMIR_ENDPOINT=""
            [ "$AUTO_CONFIRM" = "true" ] && exit 1
        done
        if [[ "$MIMIR_ENDPOINT" == http://* ]]; then
            print_warning "Mimir credentials will be sent over plaintext HTTP. HTTPS is strongly recommended."
        fi
    else
        while [ -z "$OTLP_ENDPOINT" ]; do
            if [ "$AUTO_CONFIRM" = "true" ]; then
                print_error "ELVEN_OTLP_ENDPOINT is required for the collector destination."
                exit 1
            fi
            read -r -p "OTLP/HTTP Collector endpoint (for example https://collector.example.com:4318): " OTLP_ENDPOINT < /dev/tty
        done
        if ! validate_http_url "$OTLP_ENDPOINT"; then
            print_error "OTLP endpoint must be a valid http:// or https:// URL."
            exit 1
        fi

        if [ -z "$OTLP_API_TOKEN" ] && [ "$non_interactive" != "true" ]; then
            read -r -p "Configure a Bearer token for the Collector? [y/N]: " add_token < /dev/tty
            if [[ "$add_token" =~ ^[Yy]$ ]]; then
                read -r -s -p "Collector API token: " token_input < /dev/tty
                echo
                OTLP_API_TOKEN=$(normalize_api_token "$token_input")
                if [ -z "$OTLP_API_TOKEN" ]; then
                    print_error "Collector API token cannot be empty after selecting Bearer authentication."
                    exit 1
                fi
            fi
        fi

        parse_otlp_headers "$OTLP_HEADERS" || exit 1
        for label_name in "${!OTLP_HEADERS_MAP[@]}"; do
            if [ "${label_name,,}" = "authorization" ] && [ -n "$OTLP_API_TOKEN" ]; then
                print_error "Authorization is configured twice: use ELVEN_OTLP_API_TOKEN or ELVEN_OTLP_HEADERS, not both."
                exit 1
            fi
        done
        [ -n "$OTLP_API_TOKEN" ] && OTLP_HEADERS_MAP["Authorization"]="Bearer $OTLP_API_TOKEN"

        validate_otlp_tls_files || exit 1
        if [[ "$OTLP_ENDPOINT" == http://* ]]; then
            if [ -n "$OTLP_API_TOKEN" ] || [ ${#OTLP_HEADERS_MAP[@]} -gt 0 ]; then
                print_warning "OTLP authentication headers will be sent over plaintext HTTP. HTTPS is strongly recommended."
            else
                print_warning "OTLP is configured over plaintext HTTP. Use this only on a trusted private network."
            fi
        fi
        if [ "$OTLP_TLS_INSECURE_SKIP_VERIFY" = "true" ]; then
            print_warning "TLS certificate verification is disabled for the OTLP Collector."
        fi
    fi

    print_info ""
    if [ -n "$CUSTOM_LABELS" ]; then
        print_info "Using custom labels from environment variable..."
        local -a labels=()
        IFS=',' read -r -a labels <<< "$CUSTOM_LABELS"
        for label in "${labels[@]}"; do
            if [[ $label =~ ^([^=]+)=(.+)$ ]]; then
                label_name=$(trim_whitespace "${BASH_REMATCH[1]}")
                label_value=$(trim_whitespace "${BASH_REMATCH[2]}")
                if validate_prometheus_label_name "$label_name"; then
                    CUSTOM_LABELS_MAP["$label_name"]="$label_value"
                else
                    print_error "Invalid Prometheus label name: $label_name"
                    exit 1
                fi
            else
                print_error "Invalid custom label entry. Expected name=value."
                exit 1
            fi
        done
        print_success "Loaded ${#CUSTOM_LABELS_MAP[@]} custom labels"
    elif [ "$non_interactive" != "true" ]; then
        read -r -p "Add custom labels? (e.g., group=BASPA, dept=TI) [y/N]: " add_labels < /dev/tty
        if [[ "$add_labels" =~ ^[Yy]$ ]]; then
            print_info "Enter custom labels (press Enter without input to finish):"
            while true; do
                read -r -p "  Label name: " label_name < /dev/tty
                if [ -z "$label_name" ]; then
                    break
                fi
                if ! validate_prometheus_label_name "$label_name"; then
                    print_error "Invalid Prometheus label name: $label_name"
                    continue
                fi
                read -r -p "  Label value: " label_value < /dev/tty
                if [ -n "$label_value" ]; then
                    CUSTOM_LABELS_MAP["$label_name"]="$label_value"
                    print_success "Added: $label_name = $label_value"
                fi
            done
        fi
    fi

    print_info ""
    print_success "Configuration summary:"
    echo "  Destination: $METRICS_DESTINATION"
    echo "  Instance:    $INSTANCE_NAME"
    [ -n "$CUSTOMER_NAME" ] && echo "  Customer:    $CUSTOMER_NAME"
    echo "  Environment: $ENVIRONMENT"
    if [ "$METRICS_DESTINATION" = "mimir" ]; then
        echo "  Tenant ID:   $TENANT_ID"
        echo "  Endpoint:    $MIMIR_ENDPOINT"
    else
        echo "  Endpoint:    $OTLP_ENDPOINT"
        [ -n "$OTLP_API_TOKEN" ] && echo "  Bearer auth: configured"
        echo "  OTLP headers: ${#OTLP_HEADERS_MAP[@]} configured"
        echo "  TLS verify:  $([ "$OTLP_TLS_INSECURE_SKIP_VERIFY" = "true" ] && echo disabled || echo enabled)"
    fi
    if [ ${#CUSTOM_LABELS_MAP[@]} -gt 0 ]; then
        echo "  Custom Labels:"
        for label_name in "${!CUSTOM_LABELS_MAP[@]}"; do
            echo "    - $label_name: ${CUSTOM_LABELS_MAP[$label_name]}"
        done
    fi
    print_info ""

    if [ "$non_interactive" = "true" ]; then
        print_info "Configuration auto-confirmed by environment."
    else
        read -r -p "Confirm and continue? (y/N): " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_warning "Installation cancelled"
            exit 0
        fi
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

# Set SELinux context for a binary
set_selinux_binary_context() {
    local binary_path=$1
    
    if ! command -v getenforce &> /dev/null; then
        return 0  # SELinux not installed
    fi
    
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
    if [ "$selinux_status" = "Disabled" ]; then
        return 0  # SELinux disabled
    fi
    
    print_info "  → Setting SELinux context for $(basename "$binary_path")..."
    
    # Set context directly
    chcon -t bin_t "$binary_path" 2>/dev/null || true
    
    # Verify
    local context
    # shellcheck disable=SC2012 # SELinux context is read from ls -Z.
    context=$(ls -Z "$binary_path" 2>/dev/null | awk '{print $1}')
    if [[ "$context" == *bin_t* ]]; then
        print_success "SELinux context: OK"
    else
        print_warning "SELinux context may need adjustment: $context"
    fi
}

# Configure SELinux for monitoring tools
configure_selinux() {
    # Check if SELinux is installed and enforcing
    if ! command -v getenforce &> /dev/null; then
        return 0  # SELinux not installed, skip
    fi
    
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
    
    if [ "$selinux_status" = "Disabled" ]; then
        return 0  # SELinux disabled, nothing to do
    fi
    
    print_info ""
    print_info "SELinux detected ($selinux_status), configuring permissions..."
    
    # Install SELinux utilities if needed
    if [ "$PKG_MANAGER" = "apt" ]; then
        if ! command -v semanage &> /dev/null; then
            print_info "  → Installing SELinux utilities..."
            install_packages policycoreutils-python-utils 2>/dev/null || \
            install_packages policycoreutils 2>/dev/null || true
        fi
    else
        if ! command -v semanage &> /dev/null; then
            print_info "  → Installing SELinux utilities..."
            install_packages policycoreutils-python-utils 2>/dev/null || \
            install_packages policycoreutils-python 2>/dev/null || true
        fi
    fi
    
    # Add permanent SELinux file contexts FIRST
    print_info "  → Adding permanent SELinux file contexts..."
    if command -v semanage &> /dev/null; then
        # Remove old contexts if they exist
        semanage fcontext -d "/opt/monitoring/node_exporter/node_exporter" 2>/dev/null || true
        semanage fcontext -d "/opt/monitoring/otelcol/otelcol-contrib" 2>/dev/null || true
        
        # Add new contexts as bin_t (executable type)
        semanage fcontext -a -t bin_t "/opt/monitoring/node_exporter/node_exporter" 2>/dev/null || \
        semanage fcontext -m -t bin_t "/opt/monitoring/node_exporter/node_exporter" 2>/dev/null || true
        
        semanage fcontext -a -t bin_t "/opt/monitoring/otelcol/otelcol-contrib" 2>/dev/null || \
        semanage fcontext -m -t bin_t "/opt/monitoring/otelcol/otelcol-contrib" 2>/dev/null || true
        
        print_success "Permanent contexts added!"
    else
        print_warning "semanage not available, using temporary contexts"
    fi
    
    # Apply the contexts to actual files
    print_info "  → Applying SELinux contexts to binaries..."
    
    if [ -f /opt/monitoring/node_exporter/node_exporter ]; then
        chcon -t bin_t /opt/monitoring/node_exporter/node_exporter 2>/dev/null || true
        restorecon -v /opt/monitoring/node_exporter/node_exporter 2>&1 | grep -v "restorecon reset" || true
    fi
    
    if [ -f /opt/monitoring/otelcol/otelcol-contrib ]; then
        chcon -t bin_t /opt/monitoring/otelcol/otelcol-contrib 2>/dev/null || true
        restorecon -v /opt/monitoring/otelcol/otelcol-contrib 2>&1 | grep -v "restorecon reset" || true
    fi
    
    # Verify contexts were applied
    print_info "  → Verifying contexts..."
    local node_context
    # shellcheck disable=SC2012 # SELinux context is read from ls -Z.
    node_context=$(ls -Z /opt/monitoring/node_exporter/node_exporter 2>/dev/null | awk '{print $1}')
    if [[ "$node_context" == *bin_t* ]]; then
        print_success "Node Exporter context: OK ($node_context)"
    else
        print_warning "Node Exporter context may be incorrect: $node_context"
    fi
    
    # Allow network binding for monitoring ports
    if command -v semanage &> /dev/null; then
        print_info "  → Configuring port permissions..."
        semanage port -a -t http_port_t -p tcp 9100 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp 9100 2>/dev/null || true
    fi
    
    # Reload systemd to pick up SELinux changes
    print_info "  → Reloading systemd..."
    systemctl daemon-reload
    
    print_success "SELinux configured!"
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
    local asset_name="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    local download_url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${asset_name}"
    local checksum_url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/sha256sums.txt"
    local temp_file="/tmp/node_exporter.tar.gz"

    print_info "Downloading Node Exporter v$NODE_EXPORTER_VERSION..."
    if ! download_with_retry "$download_url" "$temp_file"; then
        exit 1
    fi
    if ! verify_sha256_from_manifest "$temp_file" "$asset_name" "$checksum_url"; then
        rm -f "$temp_file"
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
    
    # Set SELinux context if needed
    set_selinux_binary_context "$NODE_EXPORTER_DIR/node_exporter"
    
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
    local asset_name="otelcol-contrib_${OTEL_VERSION}_linux_${ARCH}.tar.gz"
    local download_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${asset_name}"
    local checksum_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/opentelemetry-collector-releases_otelcol-contrib_checksums.txt"
    local temp_file="/tmp/otelcol.tar.gz"

    print_info "Downloading OpenTelemetry Collector v$OTEL_VERSION..."
    if ! download_with_retry "$download_url" "$temp_file"; then
        exit 1
    fi
    if ! verify_sha256_from_manifest "$temp_file" "$asset_name" "$checksum_url"; then
        rm -f "$temp_file"
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

    local instance_yaml
    local environment_yaml
    local os_yaml
    local customer_label=""
    local custom_labels_yaml=""
    local exporters_yaml
    local exporter_name
    local extensions_yaml=""
    local service_extensions_yaml=""
    local key

    instance_yaml=$(yaml_quote "$INSTANCE_NAME")
    environment_yaml=$(yaml_quote "$ENVIRONMENT")
    os_yaml=$(yaml_quote "$OS")

    if [ -n "$CUSTOMER_NAME" ]; then
        customer_label="      - action: insert
        key: 'customer'
        value: $(yaml_quote "$CUSTOMER_NAME")"
    fi

    if [ ${#CUSTOM_LABELS_MAP[@]} -gt 0 ]; then
        while IFS= read -r key; do
            custom_labels_yaml="${custom_labels_yaml}
      - action: insert
        key: $(yaml_quote "$key")
        value: $(yaml_quote "${CUSTOM_LABELS_MAP[$key]}")"
        done < <(printf '%s\n' "${!CUSTOM_LABELS_MAP[@]}" | LC_ALL=C sort)
    fi

    if [ "$METRICS_DESTINATION" = "mimir" ]; then
        exporter_name="prometheus_remote_write"
        exporters_yaml="  prometheus_remote_write:
    endpoint: $(yaml_quote "$MIMIR_ENDPOINT")
    headers:
      'X-Scope-OrgID': $(yaml_quote "$TENANT_ID")
      'Authorization': $(yaml_quote "Bearer $API_TOKEN")
    resource_to_telemetry_conversion:
      enabled: true"
    else
        local endpoint_property="endpoint"
        local otlp_headers_yaml=""
        local headers_section=""
        local tls_section=""

        if [[ "$OTLP_ENDPOINT" =~ /v1/metrics/?$ ]]; then
            endpoint_property="metrics_endpoint"
        fi

        if [ ${#OTLP_HEADERS_MAP[@]} -gt 0 ]; then
            while IFS= read -r key; do
                otlp_headers_yaml="${otlp_headers_yaml}
      $(yaml_quote "$key"): $(yaml_quote "${OTLP_HEADERS_MAP[$key]}")"
            done < <(printf '%s\n' "${!OTLP_HEADERS_MAP[@]}" | LC_ALL=C sort)
            headers_section="    headers:${otlp_headers_yaml}"
        fi

        if [ -n "$OTLP_TLS_CA_FILE" ] || [ -n "$OTLP_TLS_CERT_FILE" ] || [ "$OTLP_TLS_INSECURE_SKIP_VERIFY" = "true" ]; then
            tls_section="    tls:"
            [ -n "$OTLP_TLS_CA_FILE" ] && tls_section="${tls_section}
      ca_file: $(yaml_quote "$OTLP_TLS_CA_FILE")"
            [ -n "$OTLP_TLS_CERT_FILE" ] && tls_section="${tls_section}
      cert_file: $(yaml_quote "$OTLP_TLS_CERT_FILE")
      key_file: $(yaml_quote "$OTLP_TLS_KEY_FILE")"
            [ "$OTLP_TLS_INSECURE_SKIP_VERIFY" = "true" ] && tls_section="${tls_section}
      insecure_skip_verify: true"
        fi

        mkdir -p "$OTEL_STORAGE_DIR"
        chmod 700 "$OTEL_STORAGE_DIR"
        extensions_yaml="extensions:
  file_storage/otlp:
    directory: $(yaml_quote "$OTEL_STORAGE_DIR")"
        service_extensions_yaml="  extensions: [file_storage/otlp]"
        exporter_name="otlphttp/collector"
        exporters_yaml="  otlphttp/collector:
    ${endpoint_property}: $(yaml_quote "$OTLP_ENDPOINT")
    compression: gzip
    timeout: 30s
${headers_section:+$headers_section
}${tls_section:+$tls_section
}    sending_queue:
      enabled: true
      num_consumers: 2
      queue_size: 10000
      storage: file_storage/otlp
    retry_on_failure:
      enabled: true
      initial_interval: 1s
      max_interval: 30s
      max_elapsed_time: 0s"
    fi

    local previous_umask
    previous_umask=$(umask)
    umask 077
    cat > "$CONFIG_DIR/config.yaml" <<EOF
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'node_exporter'
          scrape_interval: 30s
          static_configs:
            - targets: ['localhost:9100']

$extensions_yaml

exporters:
$exporters_yaml

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
    spike_limit_mib: 64

  resource/add_labels:
    attributes:
      - action: insert
        key: 'hostname'
        value: $instance_yaml
      - action: insert
        key: 'environment'
        value: $environment_yaml
$customer_label
      - action: insert
        key: 'os'
        value: 'linux'
      - action: insert
        key: 'distro'
        value: $os_yaml
$custom_labels_yaml

  batch:
    timeout: 10s
    send_batch_size: 1024

  filter/drop_internal:
    error_mode: ignore
    metric_conditions:
      - 'IsMatch(metric.name, "^(go_|scrape_|otlp_|promhttp_|process_).*")'

service:
$service_extensions_yaml
  pipelines:
    metrics:
      receivers: [prometheus]
      processors: [memory_limiter, resource/add_labels, filter/drop_internal, batch]
      exporters: [$exporter_name]
EOF

    chmod 600 "$CONFIG_DIR/config.yaml"
    umask "$previous_umask"

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
UMask=0077
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $OTEL_SERVICE > /dev/null 2>&1
    
    # Set SELinux context if needed
    set_selinux_binary_context "$OTEL_DIR/otelcol-contrib"
    
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
    echo "  Destination:  $METRICS_DESTINATION"
    if [ "$METRICS_DESTINATION" = "mimir" ]; then
        echo "  Tenant ID:    $TENANT_ID"
        echo "  Endpoint:     $MIMIR_ENDPOINT"
    else
        echo "  Endpoint:     $OTLP_ENDPOINT"
        echo "  Queue:        persistent ($OTEL_STORAGE_DIR)"
    fi
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
    if [ "$METRICS_DESTINATION" = "collector" ]; then
        print_success "Downstream validation (when the Collector exports to Prometheus/Mimir):"
    else
        print_success "Grafana validation:"
    fi
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
    configure_selinux
    print_summary
}

# Run main function. Library mode is used only by local validation tooling.
if [ "${ELVEN_INSTALLER_LIBRARY_MODE:-false}" != "true" ]; then
    main "$@"
fi
