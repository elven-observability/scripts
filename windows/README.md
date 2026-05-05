# Windows Instrumentation - Elven Observability

Automated installers for Windows observability on Windows servers.

- **Metrics**: Windows Exporter + OpenTelemetry Collector
- **Logs**: elven-logs-collector -> Loki

## 🚀 Quick Installation

### Metrics

### Option 1: One-liner (direct execution)

Open PowerShell as **Administrator** and run:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/windows-instrumentation.ps1 | iex
```

### Option 2: Download and run (recommended for production)

```powershell
# Download
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri https://raw.githubusercontent.com/elven-observability/scripts/main/windows/windows-instrumentation.ps1 -OutFile install.ps1

# Run
.\install.ps1
```

### Logs with elven-logs-collector

Open PowerShell as **Administrator** and run:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/elven-logs-collector/windows-logs-instrumentation.ps1 | iex
```

For automated installs:

```powershell
$env:ELVEN_TENANT_ID = "your-tenant-id"
$env:ELVEN_API_TOKEN = "your-token-without-bearer"
$env:ELVEN_INSTANCE_NAME = $env:COMPUTERNAME.ToLower()
$env:ELVEN_ENVIRONMENT = "production"
$env:ELVEN_AUTO_CONFIRM = "true"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/elven-logs-collector/windows-logs-instrumentation.ps1 | iex
```

If PowerShell returns `Could not create SSL/TLS secure channel`, the current session is not using TLS 1.2 for GitHub. Run the commands above exactly as shown, including the `[Net.ServicePointManager]::SecurityProtocol` prefix.

Full logs documentation: [elven-logs-collector](./elven-logs-collector/)

## 📋 Prerequisites

- ✅ Windows Server 2016+ or Windows 10/11
- ✅ PowerShell 5.1+
- ✅ Run as **Administrator**
- ✅ Internet access

## 🔧 What do the scripts install?

1. **Windows Exporter (v0.27.3)** - Collects Windows system metrics
2. **OpenTelemetry Collector (v0.114.0)** - Scrapes and forwards metrics to Mimir
3. **elven-logs-collector runtime (v1.16.0)** - Collects Windows Event Logs and optional file logs, then forwards them to Loki

## 📊 Metrics collected

- **CPU** (per core and total)
- **Memory** (utilization, available, etc)
- **Disk** (I/O, latency, space)
- **Network** (bytes in/out, errors, packets)
- **Operating System**
- **Windows Services**
- **Processes**

## 🎯 Validation

After installation, validate in **Grafana Explore**:

```promql
{instance="your-server-name"}
```

Or specific metrics:

```promql
windows_cpu_time_total
windows_memory_available_bytes
windows_logical_disk_free_bytes
windows_net_bytes_received_total
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
```powershell
Get-Service windows_exporter, otelcol
```

### Restart services
```powershell
Restart-Service windows_exporter
Restart-Service otelcol
```

### Test Windows Exporter endpoint
```powershell
Invoke-WebRequest http://localhost:9182/metrics
```

### View logs
```powershell
Get-WinEvent -LogName Application -MaxEvents 20 | Where-Object {$_.Message -like '*otelcol*'}
```

### Validate configuration
```powershell
& "C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe" validate --config="C:\Program Files\OpenTelemetry Collector\config.yaml"
```

## 📂 Installed files

- **Windows Exporter**: `C:\Program Files\Windows Exporter\`
- **OpenTelemetry Collector**: `C:\Program Files\OpenTelemetry Collector\`
- **Configuration**: `C:\Program Files\OpenTelemetry Collector\config.yaml`

## 🔒 Security

The scripts:
- ✅ Validates downloads before execution
- ✅ Uses TLS 1.2 for all connections
- ✅ Installs only from official sources (GitHub releases)
- ✅ Validates configuration before starting services
- ⚠️ Metrics token is stored in the OpenTelemetry Collector config; elven-logs-collector stores the token in the Alloy service registry environment, not in `config.alloy`

## 🏗️ Architecture

```
Windows Server
    │
    ├─> Windows Exporter (port 9182)
    │       └─> Exposes /metrics endpoint
    │
    └─> OpenTelemetry Collector
            ├─> Scrapes Windows Exporter
            ├─> Adds labels (instance, environment, customer)
            ├─> Batches metrics
            └─> Forwards to Mimir (remote write)
```

## 🐛 Troubleshooting

### Service won't start

1. Check logs:
```powershell
Get-WinEvent -LogName Application -MaxEvents 50 | Where-Object {$_.Message -like '*otelcol*'} | Format-List
```

2. Test configuration:
```powershell
& "C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe" validate --config="C:\Program Files\OpenTelemetry Collector\config.yaml"
```

3. Run manually to see errors:
```powershell
& "C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe" --config="C:\Program Files\OpenTelemetry Collector\config.yaml"
```

### Windows Exporter not responding

1. Check if service is running:
```powershell
Get-Service windows_exporter
```

2. Test endpoint:
```powershell
Invoke-WebRequest http://localhost:9182/metrics
```

3. Restart service:
```powershell
Restart-Service windows_exporter
```

### Metrics not appearing in Grafana

1. Verify services are running:
```powershell
Get-Service windows_exporter, otelcol | Format-Table -AutoSize
```

2. Check if Windows Exporter is producing metrics:
```powershell
(Invoke-WebRequest http://localhost:9182/metrics).Content | Select-String "windows_cpu"
```

3. Verify network connectivity to Mimir:
```powershell
Test-NetConnection mimir.elvenobservability.com -Port 443
```

## 🔄 Updating

To update to a newer version:

1. Stop services:
```powershell
Stop-Service otelcol, windows_exporter
```

2. Re-run the installation script (it will detect and update existing installations)

## 🗑️ Uninstallation

To completely remove the installation:

```powershell
# Stop services
Stop-Service otelcol, windows_exporter -Force

# Remove services
sc.exe delete otelcol
sc.exe delete windows_exporter

# Remove files
Remove-Item "C:\Program Files\OpenTelemetry Collector" -Recurse -Force
Remove-Item "C:\Program Files\Windows Exporter" -Recurse -Force
```

## 📞 Support

For issues or questions:
- 📧 Email: support@elvenobservability.com
- 🐛 Issues: [GitHub Issues](https://github.com/elven-observability/scripts/issues)
- 📚 Documentation: [docs.elvenobservability.com](https://docs.elvenobservability.com)

---

**Elven Observability** - LGTM Stack as a Service
