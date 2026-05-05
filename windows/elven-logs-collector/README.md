# elven-logs-collector for Windows

Automated installer for elven-logs-collector on Windows servers, collecting Windows Event Logs and optional file logs, then forwarding them to Elven Observability Loki. The collector runtime is powered by Grafana Alloy and installed as the official `Alloy` Windows service.

## Quick Installation

Open PowerShell as Administrator and run:

```powershell
iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/elven-logs-collector/windows-logs-instrumentation.ps1 | iex
```

## Automated Installation

```powershell
$env:ELVEN_TENANT_ID = "your-tenant-id"
$env:ELVEN_API_TOKEN = "your-token-without-bearer"
$env:ELVEN_INSTANCE_NAME = $env:COMPUTERNAME.ToLower()
$env:ELVEN_ENVIRONMENT = "production"
$env:ELVEN_AUTO_CONFIRM = "true"

iwr -useb https://raw.githubusercontent.com/elven-observability/scripts/main/windows/elven-logs-collector/windows-logs-instrumentation.ps1 | iex
```

To collect additional Event Log channels or files:

```powershell
$env:ELVEN_LOG_CHANNELS = "Application,System,Microsoft-Windows-PowerShell/Operational"
$env:ELVEN_LOG_PATHS = "C:\inetpub\logs\LogFiles\*\*.log,C:\app\logs\*.log"
```

## Defaults

- Collector runtime version: `1.16.0`
- Loki endpoint: `https://logs.elvenobservability.com/loki/api/v1/push`
- Event Log channels: `Application`
- Event Log backfill safety window: `60` minutes
- File logs: disabled unless paths are provided
- File log mode: `tail_from_end = true`
- Service: `Alloy`
- Config: `C:\Program Files\GrafanaLabs\Alloy\config.alloy`
- Data: `C:\ProgramData\GrafanaLabs\Alloy\data`
- Bookmarks: `C:\ProgramData\GrafanaLabs\Alloy\bookmarks`

## Environment Variables

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `ELVEN_TENANT_ID` / `TENANT_ID` | Yes | - | Elven tenant ID, sent as `X-Scope-OrgID`. |
| `ELVEN_API_TOKEN` / `API_TOKEN` | Yes | - | API token. The script accepts raw token or `Bearer <token>`. |
| `ELVEN_INSTANCE_NAME` / `INSTANCE_NAME` | No | Computer hostname | Host label used in Loki. |
| `ELVEN_ENVIRONMENT` / `ENVIRONMENT` | No | `production` | Environment label. |
| `ELVEN_CUSTOMER_NAME` / `CUSTOMER_NAME` | No | empty | Customer label. |
| `ELVEN_LOKI_URL` / `LOKI_URL` | No | Elven Loki URL | Loki push endpoint. |
| `ELVEN_LOG_CHANNELS` / `LOG_CHANNELS` | No | `Application` | Comma-separated Windows Event Log channels. |
| `ELVEN_LOG_PATHS` / `LOG_PATHS` | No | empty | Comma-separated absolute file log paths or globs. |
| `ELVEN_EVENTLOG_MAX_AGE_MINUTES` / `EVENTLOG_MAX_AGE_MINUTES` | No | `60` | Event Log backfill safety window. Use `0` to disable. |
| `ELVEN_AUTO_CONFIRM` / `AUTO_CONFIRM` | No | `false` | Enables non-interactive installation. |
| `ELVEN_COLLECTOR_VERSION` / `ELVEN_ALLOY_VERSION` / `ALLOY_VERSION` | No | `1.16.0` | Collector runtime release version. |

## Validation

Check service status:

```powershell
Get-Service Alloy
```

Validate the collector config:

```powershell
& "$env:ProgramFiles\GrafanaLabs\Alloy\alloy.exe" validate --stability.level=generally-available "$env:ProgramFiles\GrafanaLabs\Alloy\config.alloy"
```

Generate a test event:

```powershell
eventcreate /ID 1000 /L APPLICATION /T INFORMATION /SO ElvenLogsCollectorTest /D "elven-logs-collector-test"
```

Query in Loki/Grafana:

```logql
{job="elven-logs-collector", source="windows", host="<hostname>", channel="Application"}
```

## Useful Commands

```powershell
Restart-Service Alloy
Get-Service Alloy
Get-WinEvent -LogName Application -MaxEvents 20 | Where-Object {$_.ProviderName -like "*Alloy*" -or $_.Message -like "*Alloy*"}
```

To remove the API token from the current PowerShell session after installation:

```powershell
Remove-Item Env:ELVEN_API_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:API_TOKEN -ErrorAction SilentlyContinue
```

## Notes

- The API token is stored in the service registry environment, not in `config.alloy`.
- Existing service configs are backed up before replacement.
- If an existing config does not look Elven-managed, interactive mode asks before replacing it.
- No inbound firewall ports are opened; the collector only needs outbound HTTPS access to Loki.
