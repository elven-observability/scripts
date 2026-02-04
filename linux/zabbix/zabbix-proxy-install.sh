#!/bin/bash
# zabbix-proxy-install.sh
# Universal installer for Zabbix Proxy 7.0 LTS + PostgreSQL 17
# Elven Observability - Production-ready with performance tuning
#
# Supported distributions:
# - Ubuntu/Debian (apt)
# - RHEL/CentOS/Rocky/AlmaLinux/Oracle Linux (yum/dnf)
# - Amazon Linux 2/2023 (yum/dnf)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Versions
ZABBIX_VERSION="7.0"
ZABBIX_RELEASE="7.0-2"
POSTGRES_VERSION="17"

# Directories
ZABBIX_CONF="/etc/zabbix/zabbix_proxy.conf"
POSTGRES_CONF_DIR="/etc/postgresql/${POSTGRES_VERSION}/main"

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

# Check root
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

    case $OS in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update"
            PKG_INSTALL="apt install -y"
            POSTGRES_CONF_DIR="/etc/postgresql/${POSTGRES_VERSION}/main"
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
            POSTGRES_CONF_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf check-update || true"
            PKG_INSTALL="dnf install -y"
            POSTGRES_CONF_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            ;;
        amzn)
            PKG_MANAGER="yum"
            PKG_UPDATE="yum check-update || true"
            PKG_INSTALL="yum install -y"
            POSTGRES_CONF_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            ;;
        *)
            print_error "Unsupported distribution: $OS"
            exit 1
            ;;
    esac

    print_success "Package manager: $PKG_MANAGER"
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
                print_success "Download complete!"
                return 0
            fi
        fi
        
        print_warning "Attempt $retry failed"
        [ $retry -lt $max_retries ] && sleep 3
    done

    print_error "Failed to download after $max_retries attempts"
    return 1
}

# Get memory in GB
get_memory_gb() {
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_gb=$((mem_kb / 1024 / 1024))
    echo $mem_gb
}

# Get CPU count
get_cpu_count() {
    nproc
}

# Get user input
get_user_input() {
    print_info ""
    print_header "Configuration"
    print_info ""

    # Check for env vars (non-interactive mode)
    if [ -n "$ZABBIX_SERVER" ] && [ -n "$PROXY_NAME" ] && [ -n "$DB_PASSWORD" ]; then
        print_info "Using environment variables for configuration..."
        
        PROXY_MODE=${PROXY_MODE:-0}
        PERFORMANCE_PROFILE=${PERFORMANCE_PROFILE:-medium}
        
        print_success "Configuration loaded:"
        echo "  Zabbix Server:  $ZABBIX_SERVER"
        echo "  Proxy Name:     $PROXY_NAME"
        echo "  Proxy Mode:     $([ $PROXY_MODE -eq 0 ] && echo 'Active' || echo 'Passive')"
        echo "  Performance:    $PERFORMANCE_PROFILE"
        print_info ""
        
        return 0
    fi

    # Zabbix Server
    while [ -z "$ZABBIX_SERVER" ]; do
        read -p "Zabbix Server IP/Hostname: " ZABBIX_SERVER < /dev/tty
        if [ -z "$ZABBIX_SERVER" ]; then
            print_error "Zabbix Server cannot be empty!"
        fi
    done

    # Proxy Name
    read -p "Proxy Name [default: $(hostname)]: " PROXY_NAME < /dev/tty
    if [ -z "$PROXY_NAME" ]; then
        PROXY_NAME=$(hostname)
        print_info "  → Using hostname: $PROXY_NAME"
    fi

    # Proxy Mode
    print_info ""
    print_info "Proxy Mode:"
    echo "  0 = Active (proxy connects to server)"
    echo "  1 = Passive (server connects to proxy)"
    read -p "Select mode [default: 0]: " PROXY_MODE < /dev/tty
    if [ -z "$PROXY_MODE" ]; then
        PROXY_MODE=0
        print_info "  → Using Active mode"
    fi

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

    print_info ""
    print_success "Configuration summary:"
    echo "  Zabbix Server:  $ZABBIX_SERVER"
    echo "  Proxy Name:     $PROXY_NAME"
    echo "  Proxy Mode:     $([ $PROXY_MODE -eq 0 ] && echo 'Active' || echo 'Passive')"
    echo "  Performance:    $PERFORMANCE_PROFILE"
    print_info ""

    read -p "Confirm and continue? (y/n): " CONFIRM < /dev/tty
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_warning "Installation cancelled"
        exit 0
    fi
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
            TREND_CACHE_SIZE="32M"
            VALUE_CACHE_SIZE="64M"
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
            TREND_CACHE_SIZE="128M"
            VALUE_CACHE_SIZE="256M"
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
            TREND_CACHE_SIZE="256M"
            VALUE_CACHE_SIZE="512M"
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
            TREND_CACHE_SIZE="512M"
            VALUE_CACHE_SIZE="1G"
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
    
    if systemctl is-active --quiet zabbix-proxy 2>/dev/null; then
        print_info "  Stopping zabbix-proxy..."
        systemctl stop zabbix-proxy
    fi
    
    print_success "Clean!"
}

# Install PostgreSQL
install_postgresql() {
    print_info ""
    print_header "[1/3] Installing PostgreSQL $POSTGRES_VERSION"
    print_info ""

    case $OS in
        ubuntu|debian)
            print_info "Adding PostgreSQL repository..."
            
            # Install prerequisites
            $PKG_INSTALL wget ca-certificates gnupg lsb-release > /dev/null 2>&1
            
            # Add PostgreSQL GPG key
            wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
            
            # Add repository
            echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
            
            # Update and install
            print_info "Installing PostgreSQL..."
            $PKG_UPDATE > /dev/null 2>&1
            $PKG_INSTALL postgresql-${POSTGRES_VERSION} postgresql-contrib-${POSTGRES_VERSION} > /dev/null 2>&1
            
            print_success "PostgreSQL installed!"
            ;;
            
        rhel|centos|rocky|almalinux|ol|fedora|amzn)
            print_info "Adding PostgreSQL repository..."
            
            # Install repository RPM
            if [ "$OS" = "amzn" ]; then
                $PKG_INSTALL https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{rhel})-x86_64/pgdg-redhat-repo-latest.noarch.rpm > /dev/null 2>&1 || true
            else
                $PKG_INSTALL https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{rhel})-x86_64/pgdg-redhat-repo-latest.noarch.rpm > /dev/null 2>&1
            fi
            
            # Disable built-in PostgreSQL module (RHEL 8+)
            if [ "$PKG_MANAGER" = "dnf" ]; then
                dnf -qy module disable postgresql > /dev/null 2>&1 || true
            fi
            
            print_info "Installing PostgreSQL..."
            $PKG_INSTALL postgresql${POSTGRES_VERSION}-server postgresql${POSTGRES_VERSION}-contrib > /dev/null 2>&1
            
            # Initialize database
            print_info "Initializing database..."
            /usr/pgsql-${POSTGRES_VERSION}/bin/postgresql-${POSTGRES_VERSION}-setup initdb > /dev/null 2>&1
            
            # Update path for psql commands
            POSTGRES_CONF_DIR="/var/lib/pgsql/${POSTGRES_VERSION}/data"
            
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
        journalctl -u postgresql -n 20 --no-pager
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
    cp $PG_CONF ${PG_CONF}.backup
    
    # Apply tuning
    cat >> $PG_CONF <<EOF

# Zabbix Proxy Tuning - Added by installation script
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
    
    # Create user and database
    sudo -u postgres psql -c "CREATE USER zabbix WITH PASSWORD '$DB_PASSWORD';" > /dev/null 2>&1 || print_warning "User zabbix already exists"
    sudo -u postgres psql -c "CREATE DATABASE zabbix_proxy OWNER zabbix;" > /dev/null 2>&1 || print_warning "Database zabbix_proxy already exists"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE zabbix_proxy TO zabbix;" > /dev/null 2>&1
    
    print_success "Database created!"
}

# Install Zabbix Proxy
install_zabbix() {
    print_info ""
    print_header "[2/3] Installing Zabbix Proxy ${ZABBIX_VERSION} LTS"
    print_info ""

    case $OS in
        ubuntu|debian)
            print_info "Adding Zabbix repository..."
            
            # Determine Debian/Ubuntu codename
            CODENAME=$(lsb_release -cs)
            
            # Download and install repository package
            local repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${CODENAME}_all.deb"
            if [ "$OS" = "debian" ]; then
                repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_latest_${CODENAME}_all.deb"
            fi
            
            wget -q $repo_url -O /tmp/zabbix-release.deb
            dpkg -i /tmp/zabbix-release.deb > /dev/null 2>&1
            rm /tmp/zabbix-release.deb
            
            # Update and install
            print_info "Installing Zabbix Proxy..."
            $PKG_UPDATE > /dev/null 2>&1
            $PKG_INSTALL zabbix-proxy-pgsql zabbix-sql-scripts > /dev/null 2>&1
            
            print_success "Zabbix Proxy installed!"
            ;;
            
        rhel|centos|rocky|almalinux|ol|fedora|amzn)
            print_info "Adding Zabbix repository..."
            
            # Install repository
            local rhel_version=$(rpm -E %{rhel})
            rpm -Uvh https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/rhel/${rhel_version}/x86_64/zabbix-release-${ZABBIX_RELEASE}.el${rhel_version}.noarch.rpm > /dev/null 2>&1
            
            # Clean cache
            $PKG_MANAGER clean all > /dev/null 2>&1
            
            # Install
            print_info "Installing Zabbix Proxy..."
            $PKG_INSTALL zabbix-proxy-pgsql zabbix-sql-scripts > /dev/null 2>&1
            
            print_success "Zabbix Proxy installed!"
            ;;
    esac
}

# Import Zabbix schema
import_schema() {
    print_info ""
    print_info "Importing Zabbix database schema..."
    
    # Find schema file
    if [ -f "/usr/share/zabbix-sql-scripts/postgresql/proxy.sql" ]; then
        SCHEMA_FILE="/usr/share/zabbix-sql-scripts/postgresql/proxy.sql"
    elif [ -f "/usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql.gz" ]; then
        zcat /usr/share/doc/zabbix-sql-scripts/postgresql/proxy.sql.gz > /tmp/proxy.sql
        SCHEMA_FILE="/tmp/proxy.sql"
    else
        print_error "Could not find Zabbix schema file"
        exit 1
    fi
    
    # Import schema (check if already imported)
    sudo -u postgres psql -d zabbix_proxy -c "\dt" | grep -q "hosts" && {
        print_warning "Schema already imported, skipping"
    } || {
        cat $SCHEMA_FILE | sudo -u zabbix psql zabbix_proxy > /dev/null 2>&1
        print_success "Schema imported!"
    }
    
    # Clean temp file
    [ -f /tmp/proxy.sql ] && rm /tmp/proxy.sql
}

# Configure Zabbix Proxy
configure_zabbix() {
    print_info ""
    print_header "[3/3] Configuring Zabbix Proxy"
    print_info ""

    # Backup original config
    [ -f $ZABBIX_CONF ] && cp $ZABBIX_CONF ${ZABBIX_CONF}.backup

    # Create configuration
    cat > $ZABBIX_CONF <<EOF
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
CacheSize=${CACHE_SIZE}
HistoryCacheSize=${HISTORY_CACHE_SIZE}
HistoryIndexCacheSize=${HISTORY_INDEX_CACHE_SIZE}
TrendCacheSize=${TREND_CACHE_SIZE}
ValueCacheSize=${VALUE_CACHE_SIZE}

# Data Transfer
ConfigFrequency=60
DataSenderFrequency=5

# Logging
LogFile=/var/log/zabbix/zabbix_proxy.log
LogFileSize=10
DebugLevel=3

# Process Management
StartVMwareCollectors=0
VMwareFrequency=60
VMwarePerfFrequency=60
VMwareCacheSize=8M
VMwareTimeout=10

# Network
ListenPort=10051
SourceIP=

# Other
SNMPTrapperFile=/var/log/snmptrap/snmptrap.log
ExternalScripts=/usr/lib/zabbix/externalscripts
FpingLocation=/usr/bin/fping
Fping6Location=/usr/bin/fping6
SSHKeyLocation=
LogSlowQueries=3000

# TLS (optional - configure as needed)
# TLSConnect=unencrypted
# TLSAccept=unencrypted
# TLSCAFile=
# TLSCertFile=
# TLSKeyFile=
# TLSPSKIdentity=
# TLSPSKFile=

# StatsAllowedIP=127.0.0.1
EOF

    print_success "Configuration created!"
    
    # Set permissions
    chown zabbix:zabbix $ZABBIX_CONF
    chmod 640 $ZABBIX_CONF
    
    # Create log directory if needed
    mkdir -p /var/log/zabbix
    chown zabbix:zabbix /var/log/zabbix
}

# Start Zabbix Proxy
start_zabbix() {
    print_info ""
    print_info "Starting Zabbix Proxy..."
    
    systemctl enable zabbix-proxy > /dev/null 2>&1
    systemctl start zabbix-proxy
    
    sleep 5
    
    if systemctl is-active --quiet zabbix-proxy; then
        print_success "Zabbix Proxy running!"
    else
        print_error "Zabbix Proxy failed to start"
        print_info "Checking logs..."
        tail -n 30 /var/log/zabbix/zabbix_proxy.log
        exit 1
    fi
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
    echo "  Zabbix Server:   $ZABBIX_SERVER"
    echo "  Proxy Name:      $PROXY_NAME"
    echo "  Proxy Mode:      $([ $PROXY_MODE -eq 0 ] && echo 'Active' || echo 'Passive')"
    echo "  Performance:     $PERFORMANCE_PROFILE"
    echo "  Distribution:    $OS_NAME"
    
    print_info ""
    print_success "Files:"
    echo "  Proxy Config:    $ZABBIX_CONF"
    echo "  PostgreSQL:      $POSTGRES_CONF_DIR/postgresql.conf"
    echo "  Log File:        /var/log/zabbix/zabbix_proxy.log"
    
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
    echo "    systemctl status postgresql"
    print_info ""
    echo "  View logs:"
    echo "    tail -f /var/log/zabbix/zabbix_proxy.log"
    echo "    journalctl -u zabbix-proxy -f"
    print_info ""
    echo "  Restart services:"
    echo "    systemctl restart zabbix-proxy"
    echo "    systemctl restart postgresql"
    print_info ""
    echo "  Database access:"
    echo "    sudo -u postgres psql -d zabbix_proxy"
    
    print_info ""
    print_success "Next steps:"
    echo "  1. Go to Zabbix Server web interface"
    echo "  2. Administration → Proxies → Create proxy"
    echo "  3. Set proxy name to: $PROXY_NAME"
    echo "  4. Set proxy mode to: $([ $PROXY_MODE -eq 0 ] && echo 'Active' || echo 'Passive')"
    if [ $PROXY_MODE -eq 1 ]; then
        echo "  5. For Passive mode, configure firewall to allow port 10051"
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
    get_user_input
    get_performance_params "$PERFORMANCE_PROFILE"
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