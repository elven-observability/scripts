# Linux Instrumentation - Elven Observability

Universal installer for **Node Exporter** + **OpenTelemetry Collector** on Linux servers.

## 🚀 Quick Installation

### Option 1: One-liner (direct execution)

```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh | sudo bash
```

### Option 2: Download and run (recommended for production)

```bash
# Download
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh -o install.sh

# Make executable
chmod +x install.sh

# Run
sudo ./install.sh
```

## 📋 Prerequisites

- ✅ Root or sudo access
- ✅ systemd (all modern distributions)
- ✅ Internet access
- ✅ Supported distribution:
  - **Ubuntu** (20.04+, 22.04, 24.04)
  - **Debian** (10+, 11, 12)
  - **RHEL** (7+, 8, 9)
  - **CentOS** (7, 8, Stream)
  - **Rocky Linux** (8, 9)
  - **AlmaLinux** (8, 9)
  - **Fedora** (35+)
  - **Amazon Linux** (2, 2023)

## 🔧 What does the script install?

1. **Node Exporter (v1.8.2)** - Collects Linux system metrics
2. **OpenTelemetry Collector (v0.114.0)** - Scrapes and forwards metrics to Mimir

## 📊 Metrics collected

- **CPU** (usage, load average, context switches)
- **Memory** (total, available, used, cached)
- **Disk** (I/O, read/write bytes, latency)
- **Filesystem** (usage, inodes, mount points)
- **Network** (bytes in/out, packets, errors)
- **System** (uptime, boot time, processes)

## 🎯 Validation

After installation, validate in **Grafana Explore**:

```promql
{instance="your-server-name"}
```

Or specific metrics:

```promql
node_cpu_seconds_total
node_memory_MemAvailable_bytes
node_disk_read_bytes_total
node_network_receive_bytes_total
```

## 📝 Configuration

During installation, you'll be prompted for:

- **Tenant ID** - Your Elven Observability tenant identifier
- **API Token** - Authentication token for Mimir
- **Instance Name** - Server identifier (default: hostname)
- **Customer Name** - Optional customer/company name
- **Environment** - production/staging/dev (default: production)

## 🛠️ Useful commands

### Check service status
```bash
systemctl status node_exporter otelcol
```

### Restart services
```bash
sudo systemctl restart node_exporter
sudo systemctl restart otelcol
```

### View logs (real-time)
```bash
sudo journalctl -u node_exporter -f
sudo journalctl -u otelcol -f
```

### View last 50 log lines
```bash
sudo journalctl -u otelcol -n 50 --no-pager
```

### Test Node Exporter endpoint
```bash
curl http://localhost:9100/metrics
```

### Validate configuration
```bash
sudo /opt/monitoring/otelcol/otelcol-contrib validate --config=/etc/otelcol/config.yaml
```

## 📂 Installed files

- **Node Exporter**: `/opt/monitoring/node_exporter/node_exporter`
- **OpenTelemetry Collector**: `/opt/monitoring/otelcol/otelcol-contrib`
- **Configuration**: `/etc/otelcol/config.yaml`
- **Systemd services**: 
  - `/etc/systemd/system/node_exporter.service`
  - `/etc/systemd/system/otelcol.service`

## 🔒 Security

The script:
- ✅ Validates downloads before execution
- ✅ Uses HTTPS for all connections
- ✅ Installs only from official sources (GitHub releases)
- ✅ Validates configuration before starting services
- ✅ Runs services as root (required for full system metrics access)
- ⚠️ Stores API token in collector config file (`/etc/otelcol/config.yaml` - readable only by root)

## 🏗️ Architecture

```
Linux Server
    │
    ├─> Node Exporter (port 9100)
    │       └─> Exposes /metrics endpoint
    │
    └─> OpenTelemetry Collector
            ├─> Scrapes Node Exporter
            ├─> Adds labels (instance, environment, customer, distro)
            ├─> Batches metrics
            └─> Forwards to Mimir (remote write)
```

## 🔄 Supported Architectures

- ✅ x86_64 (amd64) - Intel/AMD 64-bit
- ✅ ARM64 (aarch64) - ARM 64-bit (AWS Graviton, Raspberry Pi 4+, etc)

## 🐛 Troubleshooting

### Service won't start

1. Check logs:
```bash
sudo journalctl -u otelcol -n 50 --no-pager
```

2. Test configuration:
```bash
sudo /opt/monitoring/otelcol/otelcol-contrib validate --config=/etc/otelcol/config.yaml
```

3. Run manually to see errors:
```bash
sudo /opt/monitoring/otelcol/otelcol-contrib --config=/etc/otelcol/config.yaml
```

### Node Exporter not responding

1. Check if service is running:
```bash
systemctl status node_exporter
```

2. Test endpoint:
```bash
curl http://localhost:9100/metrics
```

3. Check logs:
```bash
sudo journalctl -u node_exporter -n 50
```

4. Restart service:
```bash
sudo systemctl restart node_exporter
```

### Metrics not appearing in Grafana

1. Verify services are running:
```bash
systemctl status node_exporter otelcol
```

2. Check if Node Exporter is producing metrics:
```bash
curl -s http://localhost:9100/metrics | grep node_cpu
```

3. Verify network connectivity to Mimir:
```bash
curl -I https://mimir.elvenobservability.com
```

4. Check collector logs for errors:
```bash
sudo journalctl -u otelcol -n 100 --no-pager | grep -i error
```

### Permission denied errors

Make sure you're running the script with sudo:
```bash
sudo ./install.sh
```

### Distribution not supported

If you get "Unsupported distribution" error, check:
```bash
cat /etc/os-release
```

Currently supported: Ubuntu, Debian, RHEL, CentOS, Rocky, AlmaLinux, Fedora, Amazon Linux.

## 🔄 Updating

To update to a newer version:

```bash
# Stop services
sudo systemctl stop otelcol node_exporter

# Re-run the installation script (it will detect and update existing installations)
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh | sudo bash
```

## 🗑️ Uninstallation

To completely remove the installation:

```bash
# Stop services
sudo systemctl stop otelcol node_exporter

# Disable services
sudo systemctl disable otelcol node_exporter

# Remove service files
sudo rm /etc/systemd/system/node_exporter.service
sudo rm /etc/systemd/system/otelcol.service

# Reload systemd
sudo systemctl daemon-reload

# Remove binaries and configs
sudo rm -rf /opt/monitoring
sudo rm -rf /etc/otelcol
```

## 🔥 Firewall Configuration

If you have a firewall enabled, you may need to allow outbound HTTPS:

### UFW (Ubuntu/Debian)
```bash
sudo ufw allow out 443/tcp
```

### firewalld (RHEL/CentOS/Fedora)
```bash
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

### iptables
```bash
sudo iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
```

**Note**: Node Exporter port (9100) does NOT need to be exposed externally - the collector scrapes it locally.

## 📦 Package Manager Support

The script automatically detects and uses the appropriate package manager:

- **apt** - Ubuntu, Debian
- **yum** - RHEL 7, CentOS 7, Amazon Linux 2
- **dnf** - RHEL 8+, Rocky Linux, AlmaLinux, Fedora, Amazon Linux 2023

## 🌐 Environment Variables (Advanced)

You can pre-set variables to skip prompts:

```bash
export TENANT_ID="your-tenant-id"
export API_TOKEN="your-api-token"
export INSTANCE_NAME="server-01"
export CUSTOMER_NAME="acme-corp"
export ENVIRONMENT="production"

curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh | sudo -E bash
```

## 📞 Support

For issues or questions:
- 📧 Email: support@elvenobservability.com
- 🐛 Issues: [GitHub Issues](https://github.com/elven-observability/scripts/issues)
- 📚 Documentation: [docs.elvenobservability.com](https://docs.elvenobservability.com)

## 📝 Examples

### Basic installation on Ubuntu
```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh | sudo bash
```

### Check everything is working
```bash
# Check services
systemctl status node_exporter otelcol

# Test Node Exporter
curl http://localhost:9100/metrics | head -20

# Check collector logs
sudo journalctl -u otelcol -f
```

### Reinstall/Update
```bash
# Just run the script again - it will stop existing services and reinstall
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh | sudo bash
```

---

## 🎯 Zabbix Proxy Installation

Universal installer for **Zabbix Proxy 7.0 LTS** + **PostgreSQL 17** on Linux servers.

### 🚀 Quick Installation

#### Option 1: One-liner (direct execution)

```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/zabbix-proxy-install.sh | sudo bash
```

#### Option 2: Download and run (recommended for production)

```bash
# Download
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/zabbix-proxy-install.sh -o zabbix-proxy-install.sh

# Make executable
chmod +x zabbix-proxy-install.sh

# Run
sudo ./zabbix-proxy-install.sh
```

### 📋 Prerequisites

- ✅ Root or sudo access
- ✅ systemd (all modern distributions)
- ✅ Internet access
- ✅ Supported distribution:
  - **Ubuntu** (20.04+, 22.04, 24.04)
  - **Debian** (10+, 11, 12)
  - **RHEL** (7+, 8, 9)
  - **CentOS** (7, 8, Stream)
  - **Rocky Linux** (8, 9)
  - **AlmaLinux** (8, 9)
  - **Oracle Linux** (7, 8, 9)
  - **Fedora** (35+)
  - **Amazon Linux** (2, 2023)

### 🔧 What does the script install?

1. **PostgreSQL 17** - Database for Zabbix Proxy
2. **Zabbix Proxy 7.0 LTS** - Zabbix monitoring proxy
3. **Performance tuning** - Auto-configured based on system resources and profile
4. **Systemd services** - Automatic startup and management

### 📝 Configuration

During installation, you'll be prompted for:

- **Zabbix Server** - IP address or hostname of your Zabbix Server (required)
- **Proxy Name** - Unique name for this proxy (default: hostname)
- **Proxy Mode** - Active (0) or Passive (1) mode (default: Active)
- **Database Password** - PostgreSQL password for zabbix user (min 8 characters)
- **Performance Profile** - Based on number of monitored hosts:
  - `light` - Up to 500 hosts
  - `medium` - 500-2000 hosts (recommended)
  - `heavy` - 2000-5000 hosts
  - `ultra` - 5000+ hosts

### 🎨 Performance Profiles

The script automatically configures optimal settings based on your selected profile:

| Profile | Pollers | Trappers | Cache Size | History Cache |
|---------|---------|----------|------------|---------------|
| light   | 5       | 5        | 8M         | 16M           |
| medium  | 10      | 10       | 16M        | 32M           |
| heavy   | 20      | 20       | 32M        | 64M           |
| ultra   | 50      | 50       | 64M        | 128M          |

### 🛠️ Useful Commands

#### Check service status
```bash
systemctl status zabbix-proxy postgresql
```

#### Restart services
```bash
sudo systemctl restart zabbix-proxy
sudo systemctl restart postgresql
```

#### View logs (real-time)
```bash
tail -f /var/log/zabbix/zabbix_proxy.log
journalctl -u zabbix-proxy -f
```

#### View last 50 log lines
```bash
journalctl -u zabbix-proxy -n 50 --no-pager
```

#### Database access
```bash
sudo -u postgres psql -d zabbix_proxy
```

### 📂 Installed Files

- **Zabbix Proxy Config**: `/etc/zabbix/zabbix_proxy.conf`
- **PostgreSQL Config**: 
  - Ubuntu/Debian: `/etc/postgresql/17/main/postgresql.conf`
  - RHEL/CentOS: `/var/lib/pgsql/17/data/postgresql.conf`
- **Log File**: `/var/log/zabbix/zabbix_proxy.log`
- **Database**: `zabbix_proxy` (PostgreSQL)

### 🏗️ Architecture

```
Zabbix Server
    │
    └─> Zabbix Proxy (this server)
            ├─> PostgreSQL Database
            ├─> Collects metrics from agents
            ├─> Caches data locally
            └─> Forwards to Zabbix Server
```

### 🔄 Proxy Modes

#### Active Mode (Default)
- Proxy connects to Zabbix Server
- No firewall changes needed on proxy
- Recommended for most deployments

#### Passive Mode
- Zabbix Server connects to proxy
- Requires port 10051 open on proxy
- Useful for proxies behind NAT/firewall

### 🌐 Environment Variables (Non-Interactive Mode)

You can pre-set variables to skip prompts:

```bash
export ZABBIX_SERVER="zabbix.example.com"
export PROXY_NAME="proxy-01"
export PROXY_MODE="0"  # 0=Active, 1=Passive
export DB_PASSWORD="secure-password"
export PERFORMANCE_PROFILE="medium"

curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/zabbix-proxy-install.sh | sudo -E bash
```

### 🔒 Security

The script:
- ✅ Installs from official Zabbix repositories
- ✅ Uses PostgreSQL with secure authentication
- ✅ Configures proper file permissions
- ✅ Sets up firewall-friendly defaults (Active mode)
- ⚠️ Database password is stored in config file (readable only by root)

### 🐛 Troubleshooting

#### Service won't start

1. Check logs:
```bash
journalctl -u zabbix-proxy -n 50 --no-pager
```

2. Verify configuration:
```bash
zabbix_proxy -t -c /etc/zabbix/zabbix_proxy.conf
```

3. Check PostgreSQL is running:
```bash
systemctl status postgresql
```

#### Proxy not connecting to server

1. Verify Zabbix Server address:
```bash
grep Server= /etc/zabbix/zabbix_proxy.conf
```

2. Test connectivity:
```bash
telnet <zabbix-server> 10051
```

3. Check proxy logs for connection errors:
```bash
tail -f /var/log/zabbix/zabbix_proxy.log | grep -i error
```

#### Database connection issues

1. Check PostgreSQL is running:
```bash
systemctl status postgresql
```

2. Test database connection:
```bash
sudo -u zabbix psql -h localhost -U zabbix -d zabbix_proxy
```

3. Verify database exists:
```bash
sudo -u postgres psql -l | grep zabbix_proxy
```

### 🔄 Updating

To update to a newer version:

```bash
# Stop services
sudo systemctl stop zabbix-proxy

# Re-run the installation script (it will detect and update existing installations)
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/zabbix-proxy-install.sh | sudo bash
```

### 🗑️ Uninstallation

To completely remove the installation:

```bash
# Stop services
sudo systemctl stop zabbix-proxy postgresql

# Disable services
sudo systemctl disable zabbix-proxy

# Remove Zabbix packages (Ubuntu/Debian)
sudo apt remove --purge zabbix-proxy-pgsql zabbix-release

# Remove Zabbix packages (RHEL/CentOS)
sudo yum remove zabbix-proxy-pgsql zabbix-release

# Remove database (optional - will delete all proxy data)
sudo -u postgres dropdb zabbix_proxy
```

### 🔥 Firewall Configuration

#### Active Mode (Default)
No firewall changes needed - proxy makes outbound connections.

#### Passive Mode
Allow inbound connections on port 10051:

**UFW (Ubuntu/Debian):**
```bash
sudo ufw allow 10051/tcp
```

**firewalld (RHEL/CentOS/Fedora):**
```bash
sudo firewall-cmd --permanent --add-port=10051/tcp
sudo firewall-cmd --reload
```

**iptables:**
```bash
sudo iptables -A INPUT -p tcp --dport 10051 -j ACCEPT
```

### 📞 Support

For issues or questions:
- 📧 Email: support@elvenobservability.com
- 🐛 Issues: [GitHub Issues](https://github.com/elven-observability/scripts/issues)
- 📚 Documentation: [docs.elvenobservability.com](https://docs.elvenobservability.com)

---

**Elven Observability** - LGTM Stack as a Service