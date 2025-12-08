# Instrumentation Scripts - Elven Observability

Automated installers for monitoring infrastructure across **Windows** and **Linux** servers.

## 🎯 Overview

These scripts provide one-liner installation of observability agents for the **Elven Observability LGTM Stack**:

- **Windows**: Windows Exporter + OpenTelemetry Collector
- **Linux**: Node Exporter + OpenTelemetry Collector
- **Linux**: Zabbix Proxy 7.0 LTS + PostgreSQL 17 (for Zabbix monitoring infrastructure)

The instrumentation scripts automatically install, configure, and start monitoring services that send metrics to your Elven Observability Mimir instance. The Zabbix Proxy script sets up a complete Zabbix proxy infrastructure with PostgreSQL database.

## 🚀 Quick Start

### Windows

Open **PowerShell as Administrator**:

```powershell
iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/windows-instrumentation.ps1 | iex
```

📖 [Full Windows Documentation](./windows/)

### Linux

Run as **root or with sudo**:

```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh | sudo bash
```

📖 [Full Linux Documentation](./linux/)

### Zabbix Proxy (Linux)

Run as **root or with sudo**:

```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/zabbix-proxy-install.sh | sudo bash
```

📖 [Full Linux Documentation](./linux/) (includes Zabbix Proxy details)

## 🌟 Features

### Universal Detection
- **Windows**: Works on Windows Server 2016+ and Windows 10/11
- **Linux**: Auto-detects distribution (Ubuntu, Debian, RHEL, CentOS, Rocky, AlmaLinux, Fedora, Amazon Linux)

### Smart Installation
- ✅ Automatic dependency installation
- ✅ Download with retry logic
- ✅ Configuration validation
- ✅ Systemd/Windows service creation
- ✅ Automatic service startup
- ✅ Health checks and verification

### Production Ready
- ✅ Installs from official sources only
- ✅ Configures automatic service recovery
- ✅ Validates configuration before starting
- ✅ Colored, informative output
- ✅ Comprehensive error handling

## 📊 Metrics Collected

### Windows
- CPU (per core, states, utilization)
- Memory (available, used, page file)
- Logical Disks (space, I/O)
- Network (bytes, packets, errors)
- Windows Services status
- Process metrics
- OS information

### Linux
- CPU (usage, load average)
- Memory (total, available, cached)
- Disk (I/O, read/write bytes)
- Filesystem (usage, inodes)
- Network (bytes, packets, errors)
- System (uptime, processes)
- Load average

## 🏗️ Architecture

```
Server (Windows/Linux)
    │
    ├─> Exporter (Windows Exporter or Node Exporter)
    │       ├─> Collects system metrics
    │       └─> Exposes /metrics endpoint
    │
    └─> OpenTelemetry Collector
            ├─> Scrapes exporter metrics
            ├─> Adds custom labels (instance, environment, customer)
            ├─> Batches and filters metrics
            └─> Forwards to Mimir (Prometheus Remote Write)
```

## 📁 Repository Structure

```
scripts/
├── windows/
│   ├── windows-instrumentation.ps1    # Main installation script
│   └── README.md                       # Windows documentation
└── linux/
    ├── linux-instrumentation.sh        # Main installation script
    ├── zabbix-proxy-install.sh         # Zabbix Proxy installer
    └── README.md                        # Linux documentation
```

## 🔧 Configuration

Both scripts prompt for:

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| Tenant ID | Your Elven Observability tenant | - | ✅ Yes |
| API Token | Authentication token | - | ✅ Yes |
| Instance Name | Server identifier | hostname | ❌ No |
| Customer Name | Customer/company identifier | none | ❌ No |
| Environment | Environment label | production | ❌ No |

## 🎨 Labels Applied

All metrics are enriched with:

- `instance`: Server/hostname identifier
- `environment`: production/staging/dev
- `customer`: Customer/company name (if provided)
- `os`: windows/linux
- `distro`: Distribution name (Linux only)

Example query in Grafana:
```promql
{instance="web-server-01", customer="acme-corp", environment="production"}
```

## 🛠️ Management Commands

### Windows

```powershell
# Check status
Get-Service windows_exporter, otelcol

# Restart services
Restart-Service windows_exporter
Restart-Service otelcol

# View logs
Get-WinEvent -LogName Application -MaxEvents 20 | Where-Object {$_.Message -like '*otelcol*'}
```

### Linux

```bash
# Check status
systemctl status node_exporter otelcol

# Restart services
sudo systemctl restart node_exporter
sudo systemctl restart otelcol

# View logs
sudo journalctl -u otelcol -f
```

## 🔄 Updating

Simply re-run the installation script. It will:
1. Stop existing services
2. Download latest versions
3. Update configuration
4. Restart services

### Windows
```powershell
iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/windows-instrumentation.ps1 | iex
```

### Linux
```bash
curl -sSL https://raw.githubusercontent.com/elven-observability/scripts/main/linux/linux-instrumentation.sh | sudo bash
```

## 🗑️ Uninstallation

### Windows

```powershell
# Stop and remove services
Stop-Service otelcol, windows_exporter -Force
sc.exe delete otelcol
sc.exe delete windows_exporter

# Remove files
Remove-Item "C:\Program Files\OpenTelemetry Collector" -Recurse -Force
Remove-Item "C:\Program Files\Windows Exporter" -Recurse -Force
```

### Linux

```bash
# Stop and disable services
sudo systemctl stop otelcol node_exporter
sudo systemctl disable otelcol node_exporter

# Remove files
sudo rm /etc/systemd/system/node_exporter.service
sudo rm /etc/systemd/system/otelcol.service
sudo systemctl daemon-reload
sudo rm -rf /opt/monitoring
sudo rm -rf /etc/otelcol
```

## 🐛 Troubleshooting

### Services not starting

**Windows:**
```powershell
# Check logs
Get-WinEvent -LogName Application | Where-Object {$_.Message -like '*otelcol*'} | Select -First 20

# Validate config
& "C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe" validate --config="C:\Program Files\OpenTelemetry Collector\config.yaml"
```

**Linux:**
```bash
# Check logs
sudo journalctl -u otelcol -n 50

# Validate config
sudo /opt/monitoring/otelcol/otelcol-contrib validate --config=/etc/otelcol/config.yaml
```

### Metrics not appearing in Grafana

1. Verify services are running
2. Test exporter endpoint locally (Windows: port 9182, Linux: port 9100)
3. Check network connectivity to Mimir
4. Verify credentials (Tenant ID and API Token)

### Network connectivity issues

Ensure outbound HTTPS (443) is allowed to:
- `mimir.elvenobservability.com`

## 🔒 Security Considerations

- ✅ Scripts install only from official GitHub releases
- ✅ All downloads use HTTPS
- ✅ API tokens are stored in config files with restricted permissions
- ✅ Services run with minimal required privileges
- ⚠️ Review scripts before running in production (always good practice)

## 📦 Supported Versions

| Component | Version | Source |
|-----------|---------|--------|
| Windows Exporter | 0.27.3 | [prometheus-community/windows_exporter](https://github.com/prometheus-community/windows_exporter) |
| Node Exporter | 1.8.2 | [prometheus/node_exporter](https://github.com/prometheus/node_exporter) |
| OpenTelemetry Collector | 0.114.0 | [open-telemetry/opentelemetry-collector-releases](https://github.com/open-telemetry/opentelemetry-collector-releases) |

## 🌐 Supported Platforms

### Windows
- Windows Server 2016, 2019, 2022
- Windows 10, 11

### Linux Distributions
- Ubuntu 20.04, 22.04, 24.04
- Debian 10, 11, 12
- RHEL 7, 8, 9
- CentOS 7, 8, Stream
- Rocky Linux 8, 9
- AlmaLinux 8, 9
- Fedora 35+
- Amazon Linux 2, 2023

### Architectures
- **Windows**: x86_64 (amd64)
- **Linux**: x86_64 (amd64), ARM64 (aarch64)

## 📞 Support

For issues, questions, or feature requests:

- 📧 **Email**: support@elvenobservability.com
- 🐛 **GitHub Issues**: [github.com/elven-observability/scripts/issues](https://github.com/elven-observability/scripts/issues)
- 📚 **Documentation**: [docs.elvenobservability.com](https://docs.elvenobservability.com)
- 💬 **Community**: [community.elvenobservability.com](https://community.elvenobservability.com)

## 📝 License

These scripts are provided by Elven Observability for use with the Elven Observability LGTM Stack.

## 🤝 Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch
3. Test thoroughly on multiple distributions/versions
4. Submit a pull request

## ⚡ Quick Reference

### Instrumentation Scripts

| Task | Windows | Linux |
|------|---------|-------|
| **Install** | `iwr -useb <url> \| iex` | `curl -sSL <url> \| sudo bash` |
| **Check Status** | `Get-Service otelcol` | `systemctl status otelcol` |
| **Restart** | `Restart-Service otelcol` | `sudo systemctl restart otelcol` |
| **Logs** | `Get-WinEvent` | `journalctl -u otelcol -f` |
| **Test Exporter** | `curl http://localhost:9182/metrics` | `curl http://localhost:9100/metrics` |

### Zabbix Proxy (Linux)

| Task | Command |
|------|---------|
| **Install** | `curl -sSL <url> \| sudo bash` |
| **Check Status** | `systemctl status zabbix-proxy postgresql` |
| **Restart** | `sudo systemctl restart zabbix-proxy` |
| **Logs** | `journalctl -u zabbix-proxy -f` |
| **View Config** | `cat /etc/zabbix/zabbix_proxy.conf` |

---

**Elven Observability** - LGTM Stack as a Service  
🚀 Making observability simple, powerful, and accessible.