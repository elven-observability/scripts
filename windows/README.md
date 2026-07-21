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

### Metrics to another OpenTelemetry Collector (OTLP/HTTP)

Open PowerShell as **Administrator**:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/windows-collector-instrumentation.ps1 | iex
```

Automated installation:

```powershell
$env:ELVEN_OTLP_ENDPOINT = "https://collector.example.com:4318"
$env:ELVEN_OTLP_API_TOKEN = "your-token"            # Optional
$env:ELVEN_INSTANCE_NAME = $env:COMPUTERNAME.ToLower()
$env:ELVEN_ENVIRONMENT = "production"
$env:ELVEN_AUTO_CONFIRM = "true"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/windows-collector-instrumentation.ps1 | iex
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

1. **Windows Exporter (v0.31.7)** - Collects Windows system metrics
2. **OpenTelemetry Collector Contrib (v0.156.0)** - Scrapes metrics and exports to Mimir or another Collector
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

The direct entrypoint requires a Mimir tenant and API token. The dedicated Collector entrypoint asks for:

- **OTLP/HTTP endpoint** - Base URL such as `https://collector.example.com:4318`, or a full `/v1/metrics` URL
- **API Token** - Optional Bearer token
- **Instance Name** - Server identifier (default: hostname)
- **Customer Name** - Optional customer/company name
- **Environment** - production/staging/dev (default: production)

The VM does not ask for or automatically send a backend tenant header. Configure the Mimir tenant on the remote Collector.

Optional Collector variables:

| Variable | Purpose |
|----------|---------|
| `ELVEN_OTLP_HEADERS` | Extra headers in `name=value,name2=value2` format. Values may contain `=`, but not commas. |
| `ELVEN_OTLP_TLS_CA_FILE` | Custom CA certificate path. |
| `ELVEN_OTLP_TLS_CERT_FILE` | mTLS client certificate path. Must be used with the key. |
| `ELVEN_OTLP_TLS_KEY_FILE` | mTLS client key path. Must be used with the certificate. |
| `ELVEN_OTLP_TLS_INSECURE_SKIP_VERIFY` | Disables certificate verification when `true`. Emergency use only. |

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
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='otelcol'} -MaxEvents 20 | Format-List TimeCreated, LevelDisplayName, Message
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'} -MaxEvents 50 | Where-Object {$_.Message -like '*otelcol*'}
```

### Validate configuration
```powershell
& "C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe" validate --config="C:\Program Files\OpenTelemetry Collector\config.yaml"
```

## 📂 Installed files

- **Windows Exporter**: `C:\Program Files\Windows Exporter\`
- **OpenTelemetry Collector**: `C:\Program Files\OpenTelemetry Collector\`
- **Configuration**: `C:\Program Files\OpenTelemetry Collector\config.yaml`
- **Persistent OTLP queue**: `C:\ProgramData\OpenTelemetry Collector\file_storage` (Collector mode only)

## 🔒 Security

The scripts:
- ✅ Verifies release artifacts with SHA-256 before extraction or execution
- ✅ Uses TLS 1.2 for installer and release downloads
- ✅ Installs only from official sources (GitHub releases)
- ✅ Validates configuration before starting services
- ✅ Restricts the metrics config and persistent queue to SYSTEM and local Administrators
- ✅ Does not print config contents that may contain credentials during failures
- ⚠️ Credentials are stored in the restricted Collector config when authentication is configured

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
            └─> Mimir (remote write) or another Collector (OTLP/HTTP)
```

## 🐛 Troubleshooting

### Service won't start

1. Check logs:
```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='otelcol'} -MaxEvents 50 | Format-List TimeCreated, LevelDisplayName, Message
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'} -MaxEvents 50 | Where-Object {$_.Message -like '*otelcol*'} | Format-List TimeCreated, LevelDisplayName, Message
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

3. Verify network connectivity to the configured destination:
```powershell
Test-NetConnection mimir.elvenobservability.com -Port 443
# Collector example:
Test-NetConnection collector.example.com -Port 4318
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
