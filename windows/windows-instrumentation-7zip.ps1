#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Windows Exporter and OpenTelemetry Collector with automatic 7-Zip support
.DESCRIPTION
    Optimized for Windows Server 2012 R2+ with automatic 7-Zip detection
    Falls back to PowerShell extraction if 7-Zip not available
.NOTES
    Version: 2.0.0
    Requires: PowerShell 4.0+, Administrator privileges
#>

param(
    [string]$TenantId,
    [string]$ApiToken,
    [string]$MimirEndpoint,
    [string]$InstanceName,
    [string]$Environment,
    [string]$Customer,
    [string]$CustomLabels
)

$ErrorActionPreference = "Continue"

# ==========================================
# CONFIGURATION
# ==========================================
$WINDOWS_EXPORTER_VERSION = "0.27.3"
$OTEL_VERSION = "0.114.0"

$EXPORTER_SERVICE_NAME = "windows_exporter"
$EXPORTER_DIR = "C:\Program Files\Windows Exporter"

$OTEL_SERVICE_NAME = "otelcol"
$INSTALL_DIR = "C:\Program Files\OpenTelemetry Collector"
$CONFIG_FILE = "$INSTALL_DIR\config.yaml"
$EXE_PATH = "$INSTALL_DIR\otelcol-contrib.exe"

# Prompt for required parameters if not provided
if (-not $TenantId) {
    $TenantId = Read-Host "Enter Tenant ID (e.g., vibra-br-prd)"
}

if (-not $ApiToken) {
    $ApiToken = Read-Host "Enter API Token" -AsSecureString
    $API_TOKEN_PLAIN = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiToken)
    )
} else {
    $API_TOKEN_PLAIN = $ApiToken
}

if (-not $MimirEndpoint) {
    $MimirEndpoint = Read-Host "Enter Mimir Endpoint (e.g., https://metrics.vibraenergia.com.br/api/v1/push)"
}

if (-not $InstanceName) {
    $InstanceName = $env:COMPUTERNAME
}

if (-not $Environment) {
    $Environment = Read-Host "Enter Environment (production/staging/development)"
}

if (-not $Customer) {
    $Customer = Read-Host "Enter Customer name (e.g., vibra)"
}

# ==========================================
# HELPER FUNCTIONS
# ==========================================

function Exit-WithPause {
    param([int]$ExitCode = 0)
    
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit $ExitCode
}

function Download-WithRetry {
    param(
        [string]$Url,
        [string]$OutputPath,
        [int]$MaxRetries = 3
    )
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Host "  Downloading (attempt $i of $MaxRetries)..." -ForegroundColor Cyan
            
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing -TimeoutSec 300
            
            if (Test-Path $OutputPath) {
                $fileSize = (Get-Item $OutputPath).Length / 1MB
                Write-Host "  ✓ Downloaded successfully ($([math]::Round($fileSize, 2)) MB)" -ForegroundColor Green
                return $true
            }
        } catch {
            Write-Host "  ⚠ Attempt $i failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($i -lt $MaxRetries) {
                Write-Host "  Waiting 3 seconds before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds 3
            }
        }
    }
    
    return $false
}

# ==========================================
# BANNER
# ==========================================
Clear-Host
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Windows Instrumentation Installer" -ForegroundColor Cyan
Write-Host "  Version 2.0.0 - 7-Zip Optimized" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Tenant:      $TenantId" -ForegroundColor White
Write-Host "  Instance:    $InstanceName" -ForegroundColor White
Write-Host "  Environment: $Environment" -ForegroundColor White
Write-Host "  Customer:    $Customer" -ForegroundColor White
Write-Host "  Endpoint:    $MimirEndpoint" -ForegroundColor White
Write-Host ""

Write-Host "Confirm and continue? (y/n): " -ForegroundColor Yellow -NoNewline
$confirmation = Read-Host

if ($confirmation -ne 'y') {
    Write-Host "Installation cancelled." -ForegroundColor Red
    Exit-WithPause 0
}

Write-Host ""

# ==========================================
# PRE-INSTALLATION CLEANUP
# ==========================================
Write-Host "=== Pre-Installation Cleanup ===" -ForegroundColor Green
Write-Host ""

# Stop services
Write-Host "[1/5] Stopping services..." -ForegroundColor Yellow
Stop-Service -Name $EXPORTER_SERVICE_NAME -Force -ErrorAction SilentlyContinue
Stop-Service -Name $OTEL_SERVICE_NAME -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# Delete services
Write-Host "[2/5] Removing services..." -ForegroundColor Yellow
sc.exe delete $EXPORTER_SERVICE_NAME 2>$null | Out-Null
sc.exe delete $OTEL_SERVICE_NAME 2>$null | Out-Null
Start-Sleep -Seconds 2

# Kill processes
Write-Host "[3/5] Terminating processes..." -ForegroundColor Yellow
Get-Process -Name "windows_exporter","otelcol*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Free port 9182
Write-Host "[4/5] Freeing port 9182..." -ForegroundColor Yellow
$connections = Get-NetTCPConnection -LocalPort 9182 -ErrorAction SilentlyContinue
if ($connections) {
    foreach ($conn in $connections) {
        Write-Host "  → Killing process using port 9182 (PID: $($conn.OwningProcess))..." -ForegroundColor Cyan
        Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    Write-Host "  ✓ Port 9182 freed" -ForegroundColor Green
}

# Remove directories
Write-Host "[5/5] Removing old directories..." -ForegroundColor Yellow
$dirsToRemove = @(
    "C:\Program Files\windows_exporter",
    "C:\Program Files\Windows Exporter",
    "C:\Program Files\OpenTelemetry Collector",
    "C:\Program Files\otelcol"
)

foreach ($dir in $dirsToRemove) {
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Seconds 5
Write-Host "  ✓ System ready for clean installation!" -ForegroundColor Green
Write-Host ""

# ==========================================
# PART 1: Windows Exporter
# ==========================================
Write-Host "=== [1/2] Installing Windows Exporter ===" -ForegroundColor Green
Write-Host ""

# Create directory
New-Item -ItemType Directory -Force -Path $EXPORTER_DIR | Out-Null

# Download Windows Exporter - USE STANDALONE BINARY
$EXPORTER_URL = "https://github.com/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}/windows_exporter-${WINDOWS_EXPORTER_VERSION}-amd64.exe"
$EXPORTER_EXE = "$EXPORTER_DIR\windows_exporter.exe"

Write-Host "Downloading Windows Exporter v$WINDOWS_EXPORTER_VERSION (standalone binary)..." -ForegroundColor Green

if (-not (Download-WithRetry -Url $EXPORTER_URL -OutputPath $EXPORTER_EXE)) {
    Write-Host "✗ Failed to download Windows Exporter after multiple attempts." -ForegroundColor Red
    Exit-WithPause 1
}

# Verify download
if (-not (Test-Path $EXPORTER_EXE)) {
    Write-Host "✗ Downloaded file not found at $EXPORTER_EXE" -ForegroundColor Red
    Exit-WithPause 1
}

# Create Windows Exporter service
Write-Host "Creating Windows Exporter service..." -ForegroundColor Green

$binPath = "`"$EXPORTER_EXE`""
$result = sc.exe create $EXPORTER_SERVICE_NAME binPath= $binPath start= auto obj= LocalSystem DisplayName= "Windows Exporter"

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Service created with sc.exe!" -ForegroundColor Green
    sc.exe description $EXPORTER_SERVICE_NAME "Prometheus Windows Exporter for metrics collection" | Out-Null
    sc.exe failure $EXPORTER_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
} else {
    Write-Host "  ✗ Failed to create service" -ForegroundColor Red
    Exit-WithPause 1
}

# Start Windows Exporter
Write-Host "Starting Windows Exporter..." -ForegroundColor Green
Start-Service -Name $EXPORTER_SERVICE_NAME

Start-Sleep -Seconds 3

$exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
if ($exporterService -and $exporterService.Status -eq 'Running') {
    Write-Host "  ✓ Windows Exporter is running!" -ForegroundColor Green
} else {
    Write-Host "  ✗ Service failed to start!" -ForegroundColor Red
    Exit-WithPause 1
}

Write-Host ""

# ==========================================
# PART 2: OpenTelemetry Collector
# ==========================================
Write-Host "=== [2/2] Installing OpenTelemetry Collector ===" -ForegroundColor Green
Write-Host ""

# Create directory
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

# Download Collector
$OTEL_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol-contrib_${OTEL_VERSION}_windows_amd64.tar.gz"
$OTEL_PATH = "$env:TEMP\otelcol.tar.gz"

Write-Host "Downloading OpenTelemetry Collector v$OTEL_VERSION..." -ForegroundColor Green

if (-not (Download-WithRetry -Url $OTEL_URL -OutputPath $OTEL_PATH)) {
    Write-Host "✗ Failed to download Collector after multiple attempts." -ForegroundColor Red
    Exit-WithPause 1
}

# Check available extraction methods
Write-Host "Detecting extraction method..." -ForegroundColor Cyan
$hasTar = $null -ne (Get-Command tar -ErrorAction SilentlyContinue)
$has7Zip = Test-Path "C:\Program Files\7-Zip\7z.exe"
$has7ZipX86 = Test-Path "C:\Program Files (x86)\7-Zip\7z.exe"

if ($has7Zip -or $has7ZipX86) {
    $sevenZipPath = if ($has7Zip) { "C:\Program Files\7-Zip\7z.exe" } else { "C:\Program Files (x86)\7-Zip\7z.exe" }
    Write-Host "  ✓ Found 7-Zip at: $sevenZipPath" -ForegroundColor Green
    $extractionMethod = "7zip"
} elseif ($hasTar) {
    Write-Host "  ✓ Found tar command" -ForegroundColor Green
    $extractionMethod = "tar"
} else {
    Write-Host "  ⚠ Using PowerShell extraction (slower)" -ForegroundColor Yellow
    Write-Host "  Tip: Install 7-Zip from https://www.7-zip.org/ for faster extraction" -ForegroundColor Cyan
    $extractionMethod = "powershell"
}

# Extract with best available method
Write-Host "Extracting files..." -ForegroundColor Green

$extractionSuccess = $false

switch ($extractionMethod) {
    "7zip" {
        try {
            Write-Host "  → Using 7-Zip..." -ForegroundColor Cyan
            
            # Step 1: Extract .gz to .tar
            $tarPath = "$env:TEMP\otelcol.tar"
            & $sevenZipPath x "$OTEL_PATH" -o"$env:TEMP" -y | Out-Null
            
            if ($LASTEXITCODE -eq 0 -and (Test-Path $tarPath)) {
                Write-Host "  → Extracted .gz successfully" -ForegroundColor Gray
                
                # Step 2: Extract .tar to destination
                & $sevenZipPath x "$tarPath" -o"$INSTALL_DIR" -y | Out-Null
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ Extraction complete with 7-Zip!" -ForegroundColor Green
                    $extractionSuccess = $true
                }
                
                # Cleanup tar file
                Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host "  ⚠ 7-Zip extraction failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    "tar" {
        try {
            Write-Host "  → Using tar command..." -ForegroundColor Cyan
            tar -xzf $OTEL_PATH -C $INSTALL_DIR 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Extraction complete with tar!" -ForegroundColor Green
                $extractionSuccess = $true
            }
        } catch {
            Write-Host "  ⚠ tar extraction failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    "powershell" {
        Write-Host "  ⚠ PowerShell extraction is unreliable on 2012 R2" -ForegroundColor Yellow
        Write-Host "  Please install 7-Zip and run this script again!" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Download 7-Zip from: https://www.7-zip.org/" -ForegroundColor Cyan
        Write-Host ""
        Exit-WithPause 1
    }
}

# Verify extraction
if (-not $extractionSuccess) {
    Write-Host "✗ Extraction failed!" -ForegroundColor Red
    Write-Host ""
    Write-Host "=== MANUAL EXTRACTION REQUIRED ===" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Please install 7-Zip and extract manually:" -ForegroundColor Yellow
    Write-Host "  1. Download 7-Zip: https://www.7-zip.org/" -ForegroundColor White
    Write-Host "  2. Install 7-Zip" -ForegroundColor White
    Write-Host "  3. Run these commands:" -ForegroundColor White
    Write-Host "     cd `"$env:TEMP`"" -ForegroundColor Gray
    Write-Host "     & 'C:\Program Files\7-Zip\7z.exe' x otelcol.tar.gz" -ForegroundColor Gray
    Write-Host "     & 'C:\Program Files\7-Zip\7z.exe' x otelcol.tar -o`"$INSTALL_DIR`"" -ForegroundColor Gray
    Write-Host "  4. Run this script again" -ForegroundColor White
    Write-Host ""
    Exit-WithPause 1
}

# Verify executable exists
if (-not (Test-Path $EXE_PATH)) {
    Write-Host "✗ Executable not found after extraction!" -ForegroundColor Red
    Write-Host "  Expected: $EXE_PATH" -ForegroundColor Yellow
    Exit-WithPause 1
}

Write-Host "  ✓ Executable found!" -ForegroundColor Green

# Create configuration
Write-Host "Creating configuration file..." -ForegroundColor Green

$customLabelsYaml = ""
if ($CustomLabels) {
    $labels = $CustomLabels -split ',' | ForEach-Object { $_.Trim() }
    foreach ($label in $labels) {
        if ($label -match '^(.+)=(.+)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $customLabelsYaml += @"

      - action: insert
        key: $key
        value: "$value"
"@
        }
    }
}

$customerLabel = if ($Customer) { @"

      - action: insert
        key: customer
        value: "$Customer"
"@ } else { "" }

$configContent = @"
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
    endpoint: $MimirEndpoint
    headers:
      X-Scope-OrgID: "$TenantId"
      Authorization: "Bearer $API_TOKEN_PLAIN"
    resource_to_telemetry_conversion:
      enabled: true

processors:
  resource/add_labels:
    attributes:
      - action: insert
        key: instance
        value: "$InstanceName"
      - action: insert
        key: environment
        value: "$Environment"$customerLabel
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

$configContent | Out-File -FilePath $CONFIG_FILE -Encoding UTF8
Write-Host "  ✓ Configuration created!" -ForegroundColor Green

# Create service
Write-Host "Creating OpenTelemetry Collector service..." -ForegroundColor Green

$binPath = "`"$EXE_PATH`" --config=`"$CONFIG_FILE`""
$result = sc.exe create $OTEL_SERVICE_NAME binPath= $binPath start= auto obj= LocalSystem DisplayName= "OpenTelemetry Collector"

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Service created!" -ForegroundColor Green
    sc.exe description $OTEL_SERVICE_NAME "OpenTelemetry Collector for metrics forwarding" | Out-Null
    sc.exe failure $OTEL_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
} else {
    Write-Host "  ✗ Failed to create service!" -ForegroundColor Red
    Exit-WithPause 1
}

# Start service
Write-Host "Starting OpenTelemetry Collector..." -ForegroundColor Green
Start-Service -Name $OTEL_SERVICE_NAME

Start-Sleep -Seconds 3

$otelService = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue
if ($otelService -and $otelService.Status -eq 'Running') {
    Write-Host "  ✓ OpenTelemetry Collector is running!" -ForegroundColor Green
} else {
    Write-Host "  ✗ Service failed to start!" -ForegroundColor Red
    Exit-WithPause 1
}

# ==========================================
# COMPLETION
# ==========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "✅ INSTALLATION COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Host "Service Status:" -ForegroundColor Cyan
Get-Service $EXPORTER_SERVICE_NAME, $OTEL_SERVICE_NAME | Format-Table Name, Status, StartType -AutoSize

Write-Host ""
Write-Host "Metrics endpoint  : http://localhost:9182/metrics" -ForegroundColor White
Write-Host "Dashboard         : https://grafana.elvenobservability.com" -ForegroundColor White
Write-Host ""

Exit-WithPause 0