# windows-instrumentation.ps1
# Automated installer for Windows Exporter + OpenTelemetry Collector
# Elven Observability - LGTM Stack as a Service

#Requires -RunAsAdministrator

Write-Host "=== Windows Instrumentation Installer ===" -ForegroundColor Cyan
Write-Host "Elven Observability - Monitoring Setup" -ForegroundColor Cyan
Write-Host ""

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Variables
$OTEL_VERSION = "0.139.0"
$WINDOWS_EXPORTER_VERSION = "0.31.3"
$INSTALL_DIR = "C:\Program Files\OpenTelemetry Collector"
$EXPORTER_DIR = "C:\Program Files\Windows Exporter"
$CONFIG_FILE = "$INSTALL_DIR\config.yaml"
$OTEL_SERVICE_NAME = "otelcol"
$EXPORTER_SERVICE_NAME = "windows_exporter"
$EXE_PATH = "$INSTALL_DIR\otelcol-contrib.exe"

# Function to stop services and processes
function Stop-ServiceAndProcess {
    param($ServiceName, $ProcessPattern)
    
    Write-Host "Checking if $ServiceName is running..." -ForegroundColor Yellow
    
    # Stop service
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -eq "Running") {
            Write-Host "  Stopping service $ServiceName..." -ForegroundColor Yellow
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
    
    # Kill related processes
    $processes = Get-Process | Where-Object {$_.ProcessName -like "*$ProcessPattern*"}
    if ($processes) {
        Write-Host "  Terminating related processes..." -ForegroundColor Yellow
        $processes | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    
    Write-Host "  ✓ Clean!" -ForegroundColor Green
}

# Function to download with retry
function Download-WithRetry {
    param($Url, $OutputPath, $MaxRetries = 3)
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Host "  Attempt $i of $MaxRetries..." -ForegroundColor Gray
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "PowerShell")
            $webClient.DownloadFile($Url, $OutputPath)
            
            # Verify file was downloaded
            if (Test-Path $OutputPath) {
                $fileSize = (Get-Item $OutputPath).Length
                if ($fileSize -gt 0) {
                    Write-Host "  ✓ Download complete! ($([math]::Round($fileSize/1MB, 2)) MB)" -ForegroundColor Green
                    return $true
                }
            }
        } catch {
            Write-Host "  ✗ Attempt $i failed: $_" -ForegroundColor Red
            if ($i -lt $MaxRetries) {
                Write-Host "  Waiting 3 seconds before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds 3
            }
        }
    }
    
    return $false
}

# Collect user information with validation
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host ""

# Tenant ID
do {
    $TENANT_ID = Read-Host "Tenant ID"
    if ([string]::IsNullOrWhiteSpace($TENANT_ID)) {
        Write-Host "  ✗ Tenant ID cannot be empty!" -ForegroundColor Red
    }
} while ([string]::IsNullOrWhiteSpace($TENANT_ID))

# API Token
do {
    $API_TOKEN = Read-Host "API Token" -AsSecureString
    $API_TOKEN_PLAIN = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($API_TOKEN))
    if ([string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN)) {
        Write-Host "  ✗ API Token cannot be empty!" -ForegroundColor Red
    }
} while ([string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN))

# Instance name with default
$INSTANCE_NAME = Read-Host "Instance name (e.g., server-01) [default: $(hostname)]"
if ([string]::IsNullOrWhiteSpace($INSTANCE_NAME)) {
    $INSTANCE_NAME = $env:COMPUTERNAME.ToLower()
    Write-Host "  → Using hostname: $INSTANCE_NAME" -ForegroundColor Cyan
}

# Customer name (optional)
$CUSTOMER_NAME = Read-Host "Customer/Company name (optional) [default: none]"
if ([string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    $CUSTOMER_NAME = ""
}

# Environment with default
$ENVIRONMENT = Read-Host "Environment (production/staging/dev) [default: production]"
if ([string]::IsNullOrWhiteSpace($ENVIRONMENT)) {
    $ENVIRONMENT = "production"
    Write-Host "  → Using default: $ENVIRONMENT" -ForegroundColor Cyan
}

# Mimir endpoint with default
Write-Host ""
do {
    $MIMIR_ENDPOINT = Read-Host "Mimir endpoint [default: https://mimir.elvenobservability.com/api/v1/push]"
    if ([string]::IsNullOrWhiteSpace($MIMIR_ENDPOINT)) {
        $MIMIR_ENDPOINT = "https://mimir.elvenobservability.com/api/v1/push"
        Write-Host "  → Using default (SaaS): $MIMIR_ENDPOINT" -ForegroundColor Cyan
        break
    } elseif ($MIMIR_ENDPOINT -match '^https?://') {
        Write-Host "  → Using custom endpoint: $MIMIR_ENDPOINT" -ForegroundColor Cyan
        break
    } else {
        Write-Host "  ✗ Endpoint must start with http:// or https://" -ForegroundColor Red
        Write-Host "    Example: https://metrics.vibraenergia.com.br/api/v1/push" -ForegroundColor Yellow
    }
} while ($true)

# Custom labels (optional)
Write-Host ""
$CustomLabels = @{}

# Check if CUSTOM_LABELS env var is set
if ($env:CUSTOM_LABELS) {
    Write-Host "Using custom labels from environment variable..." -ForegroundColor Cyan
    # Parse CUSTOM_LABELS="key1=value1,key2=value2"
    $env:CUSTOM_LABELS -split ',' | ForEach-Object {
        if ($_ -match '^([^=]+)=(.+)$') {
            $CustomLabels[$matches[1]] = $matches[2]
        }
    }
    
    if ($CustomLabels.Count -gt 0) {
        Write-Host "  ✓ Loaded $($CustomLabels.Count) custom labels" -ForegroundColor Green
        foreach ($key in $CustomLabels.Keys) {
            Write-Host "    $key`: $($CustomLabels[$key])" -ForegroundColor White
        }
    }
} else {
    # Interactive mode
    $addLabels = Read-Host "Add custom labels? (e.g., group=BASPA, dept=TI) [y/n]"
    if ($addLabels -eq "y" -or $addLabels -eq "Y") {
        Write-Host "Enter custom labels (press Enter without input to finish):" -ForegroundColor Cyan
        while ($true) {
            $labelName = Read-Host "  Label name"
            if ([string]::IsNullOrWhiteSpace($labelName)) {
                break
            }
            $labelValue = Read-Host "  Label value"
            if (-not [string]::IsNullOrWhiteSpace($labelValue)) {
                $CustomLabels[$labelName] = $labelValue
                Write-Host "  ✓ Added: $labelName = $labelValue" -ForegroundColor Green
            }
        }
        
        if ($CustomLabels.Count -gt 0) {
            Write-Host "  ✓ Total custom labels: $($CustomLabels.Count)" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Green
Write-Host "  Tenant ID:  $TENANT_ID" -ForegroundColor White
Write-Host "  Instance:   $INSTANCE_NAME" -ForegroundColor White
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    Write-Host "  Customer:   $CUSTOMER_NAME" -ForegroundColor White
}
Write-Host "  Environment: $ENVIRONMENT" -ForegroundColor White
Write-Host "  Endpoint:    $MIMIR_ENDPOINT" -ForegroundColor White
if ($CustomLabels.Count -gt 0) {
    Write-Host "  Custom Labels:" -ForegroundColor White
    foreach ($key in $CustomLabels.Keys) {
        Write-Host "    - $key`: $($CustomLabels[$key])" -ForegroundColor White
    }
}
Write-Host ""

$confirm = Read-Host "Confirm and continue? (y/n)"
if ($confirm -ne "y" -and $confirm -ne "Y" -and $confirm -ne "yes") {
    Write-Host "Installation cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host ""

# ====================
# PART 1: Windows Exporter
# ====================
Write-Host "=== [1/2] Installing Windows Exporter ===" -ForegroundColor Green
Write-Host ""

# Stop existing service
Stop-ServiceAndProcess -ServiceName $EXPORTER_SERVICE_NAME -ProcessPattern "windows_exporter"

# Create directory
New-Item -ItemType Directory -Force -Path $EXPORTER_DIR | Out-Null

# Download Windows Exporter
$EXPORTER_URL = "https://github.com/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}/windows_exporter-${WINDOWS_EXPORTER_VERSION}-amd64.msi"
$EXPORTER_PATH = "$env:TEMP\windows_exporter.msi"

Write-Host "Downloading Windows Exporter v$WINDOWS_EXPORTER_VERSION..." -ForegroundColor Green

if (-not (Download-WithRetry -Url $EXPORTER_URL -OutputPath $EXPORTER_PATH)) {
    Write-Host "✗ Failed to download Windows Exporter after multiple attempts." -ForegroundColor Red
    exit 1
}

# Install Windows Exporter
Write-Host "Installing Windows Exporter..." -ForegroundColor Green
$ENABLED_COLLECTORS = "cpu,cs,logical_disk,net,os,system,memory,process,service"

try {
    $installArgs = "/i `"$EXPORTER_PATH`" ENABLED_COLLECTORS=$ENABLED_COLLECTORS /quiet /norestart"
    Start-Process msiexec.exe -ArgumentList $installArgs -Wait -NoNewWindow
    Write-Host "✓ Windows Exporter installed!" -ForegroundColor Green
} catch {
    Write-Host "✗ Error installing Windows Exporter: $_" -ForegroundColor Red
    exit 1
}

# Wait for service creation
Write-Host "Waiting for service creation..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Verify and start service
$exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue

if ($exporterService) {
    Write-Host "Starting Windows Exporter..." -ForegroundColor Green
    Start-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    
    $exporterStatus = Get-Service -Name $EXPORTER_SERVICE_NAME
    if ($exporterStatus.Status -eq "Running") {
        Write-Host "✓ Windows Exporter running on port 9182!" -ForegroundColor Green
        
        # Test endpoint
        try {
            $testResponse = Invoke-WebRequest -Uri "http://localhost:9182/metrics" -TimeoutSec 5 -UseBasicParsing
            if ($testResponse.StatusCode -eq 200) {
                Write-Host "✓ Endpoint responding correctly!" -ForegroundColor Green
            }
        } catch {
            Write-Host "⚠ Service running but endpoint not responding. Waiting for initialization..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    } else {
        Write-Host "⚠ Windows Exporter installed but not running." -ForegroundColor Yellow
        Write-Host "  Trying to start manually..." -ForegroundColor Yellow
        Start-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
} else {
    Write-Host "⚠ Windows Exporter service was not created automatically." -ForegroundColor Yellow
}

Write-Host ""

# ====================
# PART 2: OpenTelemetry Collector
# ====================
Write-Host "=== [2/2] Installing OpenTelemetry Collector ===" -ForegroundColor Green
Write-Host ""

# Stop everything related to collector
Stop-ServiceAndProcess -ServiceName $OTEL_SERVICE_NAME -ProcessPattern "otelcol"

# Create directory
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

# Remove old executable if exists
if (Test-Path $EXE_PATH) {
    Write-Host "Removing old executable..." -ForegroundColor Yellow
    Remove-Item $EXE_PATH -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# Download Collector
$OTEL_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol-contrib_${OTEL_VERSION}_windows_amd64.tar.gz"
$OTEL_PATH = "$env:TEMP\otelcol.tar.gz"

Write-Host "Downloading OpenTelemetry Collector v$OTEL_VERSION..." -ForegroundColor Green

if (-not (Download-WithRetry -Url $OTEL_URL -OutputPath $OTEL_PATH)) {
    Write-Host "✗ Failed to download Collector after multiple attempts." -ForegroundColor Red
    exit 1
}

# Extract
Write-Host "Extracting files..." -ForegroundColor Green
try {
    tar -xzf $OTEL_PATH -C $INSTALL_DIR 2>&1 | Out-Null
    Write-Host "✓ Extraction complete!" -ForegroundColor Green
} catch {
    Write-Host "⚠ Error during extraction (may be normal if file already existed): $_" -ForegroundColor Yellow
}

# Verify executable was extracted
if (-not (Test-Path $EXE_PATH)) {
    Write-Host "✗ Executable not found after extraction!" -ForegroundColor Red
    Write-Host "  Check manually: $INSTALL_DIR" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ Executable found!" -ForegroundColor Green

# Create Collector configuration
Write-Host "Creating Collector configuration..." -ForegroundColor Green

# Build customer label if provided
$customerLabel = ""
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    $customerLabel = @"

      - action: insert
        key: customer
        value: "$CUSTOMER_NAME"
"@
}

# Build custom labels if provided
$customLabelsYaml = ""
if ($CustomLabels.Count -gt 0) {
    foreach ($key in $CustomLabels.Keys) {
        $customLabelsYaml += @"

      - action: insert
        key: $key
        value: "$($CustomLabels[$key])"
"@
    }
}

$CONFIG_CONTENT = @"
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'windows_exporter'
          scrape_interval: 30s
          static_configs:
            - targets: ['localhost:9182']

exporters:
  prometheusremotewrite:
    endpoint: $MIMIR_ENDPOINT
    headers:
      X-Scope-OrgID: "$TENANT_ID"
      Authorization: "Bearer $API_TOKEN_PLAIN"
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
        value: "$ENVIRONMENT"$customerLabel
      - action: insert
        key: os
        value: "windows"$customLabelsYaml

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
"@

# Save with UTF8 encoding without BOM
[System.IO.File]::WriteAllText($CONFIG_FILE, $CONFIG_CONTENT)
Write-Host "✓ Configuration created!" -ForegroundColor Green

# Validate configuration
Write-Host "Validating configuration..." -ForegroundColor Green
try {
    $validateOutput = & $EXE_PATH validate --config=$CONFIG_FILE 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Configuration is valid!" -ForegroundColor Green
    } else {
        Write-Host "✗ Invalid configuration!" -ForegroundColor Red
        Write-Host $validateOutput -ForegroundColor Red
        Write-Host ""
        Write-Host "Config file contents:" -ForegroundColor Yellow
        Get-Content $CONFIG_FILE | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        exit 1
    }
} catch {
    Write-Host "⚠ Could not validate configuration: $_" -ForegroundColor Yellow
}

# Remove old service if exists
$existingService = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Removing existing service..." -ForegroundColor Yellow
    sc.exe delete $OTEL_SERVICE_NAME | Out-Null
    Start-Sleep -Seconds 2
}

# Create Collector service
Write-Host "Creating OpenTelemetry Collector service..." -ForegroundColor Green
$FULL_COMMAND = "`"$EXE_PATH`" --config=`"$CONFIG_FILE`""

try {
    New-Service -Name $OTEL_SERVICE_NAME `
                -BinaryPathName $FULL_COMMAND `
                -DisplayName "OpenTelemetry Collector" `
                -StartupType Automatic `
                -Description "OpenTelemetry Collector - Metrics Collection" `
                -ErrorAction Stop
    
    Write-Host "✓ Service created!" -ForegroundColor Green
    
    # Configure automatic recovery
    sc.exe failure $OTEL_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    
    # Start service
    Write-Host "Starting Collector..." -ForegroundColor Green
    Start-Service -Name $OTEL_SERVICE_NAME -ErrorAction Stop
    
    Start-Sleep -Seconds 3
    
    # Check status
    $otelStatus = Get-Service -Name $OTEL_SERVICE_NAME
    if ($otelStatus.Status -eq "Running") {
        Write-Host "✓ OpenTelemetry Collector is running!" -ForegroundColor Green
    } else {
        Write-Host "⚠ Collector created but not running." -ForegroundColor Yellow
        Write-Host "  Status: $($otelStatus.Status)" -ForegroundColor Yellow
        
        # Try to see error
        Write-Host "  Checking logs..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Get-WinEvent -LogName Application -MaxEvents 5 -ErrorAction SilentlyContinue | 
            Where-Object {$_.Message -like "*otelcol*"} | 
            ForEach-Object { Write-Host "    $($_.Message)" -ForegroundColor Red }
    }
    
} catch {
    Write-Host "✗ Error creating/starting Collector service: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Debug - Config contents:" -ForegroundColor Yellow
    Get-Content $CONFIG_FILE
    exit 1
}

# Clean up temporary files
Remove-Item $OTEL_PATH -Force -ErrorAction SilentlyContinue
Remove-Item $EXPORTER_PATH -Force -ErrorAction SilentlyContinue

# Final summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✅ INSTALLATION COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check final status
$finalExporterStatus = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
$finalOtelStatus = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue

Write-Host "Service Status:" -ForegroundColor Yellow
if ($finalExporterStatus) {
    $exporterIcon = if ($finalExporterStatus.Status -eq "Running") { "✓" } else { "✗" }
    $exporterColor = if ($finalExporterStatus.Status -eq "Running") { "Green" } else { "Red" }
    Write-Host "  $exporterIcon Windows Exporter: $($finalExporterStatus.Status)" -ForegroundColor $exporterColor
} else {
    Write-Host "  ✗ Windows Exporter: Not found" -ForegroundColor Red
}

if ($finalOtelStatus) {
    $otelIcon = if ($finalOtelStatus.Status -eq "Running") { "✓" } else { "✗" }
    $otelColor = if ($finalOtelStatus.Status -eq "Running") { "Green" } else { "Red" }
    Write-Host "  $otelIcon OpenTelemetry Collector: $($finalOtelStatus.Status)" -ForegroundColor $otelColor
} else {
    Write-Host "  ✗ OpenTelemetry Collector: Not found" -ForegroundColor Red
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Instance:     $INSTANCE_NAME" -ForegroundColor White
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    Write-Host "  Customer:     $CUSTOMER_NAME" -ForegroundColor White
}
Write-Host "  Environment:  $ENVIRONMENT" -ForegroundColor White
Write-Host "  Tenant ID:    $TENANT_ID" -ForegroundColor White
Write-Host "  Endpoint:     $MIMIR_ENDPOINT" -ForegroundColor White
Write-Host ""
Write-Host "Files:" -ForegroundColor Yellow
Write-Host "  Collector:    $EXE_PATH" -ForegroundColor White
Write-Host "  Config:       $CONFIG_FILE" -ForegroundColor White
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Yellow
Write-Host "  Check status:" -ForegroundColor White
Write-Host "    Get-Service windows_exporter, otelcol" -ForegroundColor Gray
Write-Host ""
Write-Host "  Restart services:" -ForegroundColor White
Write-Host "    Restart-Service windows_exporter" -ForegroundColor Gray
Write-Host "    Restart-Service otelcol" -ForegroundColor Gray
Write-Host ""
Write-Host "  Test Windows Exporter:" -ForegroundColor White
Write-Host "    Invoke-WebRequest http://localhost:9182/metrics" -ForegroundColor Gray
Write-Host ""
Write-Host "  View logs:" -ForegroundColor White
Write-Host "    Get-WinEvent -LogName Application -MaxEvents 20 | Where-Object {`$_.Message -like '*otelcol*'}" -ForegroundColor Gray
Write-Host ""
Write-Host "Grafana validation:" -ForegroundColor Yellow
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    Write-Host "  Query: {instance=`"$INSTANCE_NAME`", customer=`"$CUSTOMER_NAME`"}" -ForegroundColor White
} else {
    Write-Host "  Query: {instance=`"$INSTANCE_NAME`"}" -ForegroundColor White
}
Write-Host ""
Write-Host "Available metrics:" -ForegroundColor Yellow
Write-Host "  - windows_cpu_*" -ForegroundColor Gray
Write-Host "  - windows_memory_*" -ForegroundColor Gray
Write-Host "  - windows_logical_disk_*" -ForegroundColor Gray
Write-Host "  - windows_net_*" -ForegroundColor Gray
Write-Host "  - windows_os_*" -ForegroundColor Gray
Write-Host "  - windows_system_*" -ForegroundColor Gray
Write-Host "  - windows_service_*" -ForegroundColor Gray
Write-Host "  - windows_process_*" -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan