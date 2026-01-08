#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Windows Exporter and OpenTelemetry Collector - Hardcoded Version
.DESCRIPTION
    Optimized for Windows Server 2012 R2+ with hardcoded credentials
.NOTES
    Version: 2.1.0 - Hardcoded
    Requires: PowerShell 4.0+, Administrator privileges, 7-Zip installed
#>

$ErrorActionPreference = "Continue"

# ==========================================
# HARDCODED CONFIGURATION
# ==========================================
$TenantId = "vbr-br-prd"
$API_TOKEN_PLAIN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJici1wcmQtdmlicmEtZW8tand0Iiwic3ViIjoiYnItcHJkLXZpYnJhLWVvIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.M7Px345AU6mYXskqKJUfV2zy9wAury6PxDpNaUqT7EI"
$MimirEndpoint = "https://metrics.vibraenergia.com.br/api/v1/push"
$InstanceName = $env:COMPUTERNAME
$Environment = "production"
$Customer = "vibra"

$WINDOWS_EXPORTER_VERSION = "0.27.3"
$OTEL_VERSION = "0.114.0"

$EXPORTER_SERVICE_NAME = "windows_exporter"
$EXPORTER_DIR = "C:\Program Files\Windows Exporter"

$OTEL_SERVICE_NAME = "otelcol"
$INSTALL_DIR = "C:\Program Files\OpenTelemetry Collector"
$CONFIG_FILE = "$INSTALL_DIR\config.yaml"
$EXE_PATH = "$INSTALL_DIR\otelcol-contrib.exe"

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
Write-Host "  Version 2.1.0 - Hardcoded" -ForegroundColor Cyan
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

# Stop services - multiple attempts
Write-Host "[1/6] Stopping services..." -ForegroundColor Yellow
for ($i = 1; $i -le 3; $i++) {
    Stop-Service -Name $EXPORTER_SERVICE_NAME -Force -ErrorAction SilentlyContinue
    Stop-Service -Name $OTEL_SERVICE_NAME -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Delete services - multiple attempts
Write-Host "[2/6] Removing services..." -ForegroundColor Yellow
for ($i = 1; $i -le 3; $i++) {
    sc.exe delete $EXPORTER_SERVICE_NAME 2>&1 | Out-Null
    sc.exe delete $OTEL_SERVICE_NAME 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    # Verify they're gone
    $svc1 = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
    $svc2 = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue
    
    if (-not $svc1 -and -not $svc2) {
        Write-Host "  ✓ Services removed" -ForegroundColor Green
        break
    }
}

# Kill processes - force kill everything
Write-Host "[3/6] Terminating processes..." -ForegroundColor Yellow
Get-Process -Name "windows_exporter*" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "otelcol*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

# Free port 9182
Write-Host "[4/6] Freeing port 9182..." -ForegroundColor Yellow
$connections = Get-NetTCPConnection -LocalPort 9182 -ErrorAction SilentlyContinue
if ($connections) {
    foreach ($conn in $connections) {
        Write-Host "  → Killing process using port 9182 (PID: $($conn.OwningProcess))..." -ForegroundColor Cyan
        Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    
    # Verify port is free
    $checkPort = Get-NetTCPConnection -LocalPort 9182 -ErrorAction SilentlyContinue
    if ($checkPort) {
        Write-Host "  ⚠ Port 9182 still in use!" -ForegroundColor Yellow
    } else {
        Write-Host "  ✓ Port 9182 freed" -ForegroundColor Green
    }
} else {
    Write-Host "  ✓ Port 9182 already free" -ForegroundColor Green
}

# Remove directories - multiple attempts with force
Write-Host "[5/6] Removing old directories..." -ForegroundColor Yellow
$dirsToRemove = @(
    "C:\Program Files\windows_exporter",
    "C:\Program Files\Windows Exporter",
    "C:\Program Files\OpenTelemetry Collector",
    "C:\Program Files\otelcol"
)

foreach ($dir in $dirsToRemove) {
    if (Test-Path $dir) {
        for ($i = 1; $i -le 3; $i++) {
            try {
                Remove-Item $dir -Recurse -Force -ErrorAction Stop
                break
            } catch {
                if ($i -eq 3) {
                    Write-Host "  ⚠ Could not remove: $dir" -ForegroundColor Yellow
                }
                Start-Sleep -Seconds 2
            }
        }
    }
}

# Wait for Windows to settle
Write-Host "[6/6] Waiting for Windows to release resources..." -ForegroundColor Yellow
Start-Sleep -Seconds 10
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

Write-Host "Verifying executable..." -ForegroundColor Green
try {
    $versionOutput = & $EXPORTER_EXE --version 2>&1
    Write-Host "  ✓ Binary is valid" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ Could not verify binary, but continuing..." -ForegroundColor Yellow
}

# Create Windows Exporter service
Write-Host "Creating Windows Exporter service..." -ForegroundColor Green

# Safety check: ensure service doesn't exist
$existingSvc = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Host "  → Removing existing service..." -ForegroundColor Yellow
    Stop-Service -Name $EXPORTER_SERVICE_NAME -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    sc.exe delete $EXPORTER_SERVICE_NAME 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

$binPath = "`"$EXPORTER_EXE`""
Write-Host "  → Creating service with binPath: $binPath" -ForegroundColor Gray

$createOutput = sc.exe create $EXPORTER_SERVICE_NAME binPath= $binPath start= auto obj= LocalSystem DisplayName= "Windows Exporter" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Service created with sc.exe!" -ForegroundColor Green
    sc.exe description $EXPORTER_SERVICE_NAME "Prometheus Windows Exporter for metrics collection" 2>&1 | Out-Null
    sc.exe failure $EXPORTER_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 2>&1 | Out-Null
    
    # Verify service exists
    Start-Sleep -Seconds 2
    $verifySvc = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
    if (-not $verifySvc) {
        Write-Host "  ✗ Service created but not found!" -ForegroundColor Red
        Exit-WithPause 1
    }
} else {
    Write-Host "  ✗ Failed to create service" -ForegroundColor Red
    Write-Host "  Exit code: $LASTEXITCODE" -ForegroundColor Yellow
    Write-Host "  Output: $createOutput" -ForegroundColor Yellow
    Exit-WithPause 1
}

# Start Windows Exporter
Write-Host "Starting Windows Exporter..." -ForegroundColor Green
Start-Service -Name $EXPORTER_SERVICE_NAME

Start-Sleep -Seconds 3

$exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
if ($exporterService -and $exporterService.Status -eq 'Running') {
    Write-Host "  ✓ Windows Exporter is running!" -ForegroundColor Green
    
    # Test endpoint
    Write-Host "Testing endpoint..." -ForegroundColor Green
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            Write-Host "  ✓ Endpoint responding correctly!" -ForegroundColor Green
            $metricsCount = ($response.Content -split "`n" | Where-Object { $_ -notmatch "^#" -and $_.Trim() -ne "" }).Count
            Write-Host "  ✓ Exporting $metricsCount+ Windows metrics" -ForegroundColor Green
        }
    } catch {
        Write-Host "  ⚠ Could not test endpoint, but service is running" -ForegroundColor Yellow
    }
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
    Write-Host "  ✗ No extraction tool found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install 7-Zip from: https://www.7-zip.org/" -ForegroundColor Yellow
    Write-Host "Then run this script again." -ForegroundColor Yellow
    Write-Host ""
    Exit-WithPause 1
}

# Clean up any previous extraction attempts
Write-Host "Cleaning temporary files..." -ForegroundColor Cyan
$tempTar = "$env:TEMP\otelcol.tar"
if (Test-Path $tempTar) {
    Remove-Item $tempTar -Force -ErrorAction SilentlyContinue
}
Remove-Item "$env:TEMP\otelcol-contrib.exe" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\LICENSE" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\README.md" -Force -ErrorAction SilentlyContinue

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
}

# Verify extraction
if (-not $extractionSuccess) {
    Write-Host "✗ Extraction failed!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install 7-Zip and run this script again." -ForegroundColor Yellow
    Write-Host "Download from: https://www.7-zip.org/" -ForegroundColor Cyan
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
        key: hostname
        value: "$InstanceName"
      - action: insert
        key: environment
        value: "$Environment"
      - action: insert
        key: customer
        value: "$Customer"
      - action: insert
        key: os
        value: "windows"

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

# Create service - with multiple safeguards
Write-Host "Creating OpenTelemetry Collector service..." -ForegroundColor Green

# Triple-check: Remove any existing service (even if we already did it)
$existingSvc = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Host "  → Removing existing service (safety check)..." -ForegroundColor Yellow
    Stop-Service -Name $OTEL_SERVICE_NAME -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    
    # Try multiple times to delete
    for ($i = 1; $i -le 3; $i++) {
        sc.exe delete $OTEL_SERVICE_NAME 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $checkSvc = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue
        if (-not $checkSvc) {
            Write-Host "  ✓ Old service removed" -ForegroundColor Green
            break
        }
        if ($i -eq 3) {
            Write-Host "  ✗ Could not remove existing service!" -ForegroundColor Red
            Write-Host "  Run manually: sc.exe delete $OTEL_SERVICE_NAME" -ForegroundColor Yellow
            Exit-WithPause 1
        }
    }
    Start-Sleep -Seconds 3
}

# Verify paths exist
if (-not (Test-Path $EXE_PATH)) {
    Write-Host "  ✗ Executable not found: $EXE_PATH" -ForegroundColor Red
    Exit-WithPause 1
}

if (-not (Test-Path $CONFIG_FILE)) {
    Write-Host "  ✗ Config not found: $CONFIG_FILE" -ForegroundColor Red
    Exit-WithPause 1
}

# Create service with proper escaping
$binPath = "`"$EXE_PATH`" --config=`"$CONFIG_FILE`""
Write-Host "  → Creating service with binPath: $binPath" -ForegroundColor Gray

# Try to create service - capture output
$createOutput = sc.exe create $OTEL_SERVICE_NAME binPath= $binPath start= auto obj= LocalSystem DisplayName= "OpenTelemetry Collector" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Service created!" -ForegroundColor Green
    
    # Set description and failure recovery
    sc.exe description $OTEL_SERVICE_NAME "OpenTelemetry Collector for metrics forwarding" 2>&1 | Out-Null
    sc.exe failure $OTEL_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 2>&1 | Out-Null
    
    # Verify service exists
    Start-Sleep -Seconds 2
    $verifySvc = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue
    if (-not $verifySvc) {
        Write-Host "  ✗ Service created but not found!" -ForegroundColor Red
        Exit-WithPause 1
    }
} else {
    Write-Host "  ✗ Failed to create service!" -ForegroundColor Red
    Write-Host "  Exit code: $LASTEXITCODE" -ForegroundColor Yellow
    Write-Host "  Output: $createOutput" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Check if service exists: Get-Service otelcol" -ForegroundColor White
    Write-Host "  2. Delete manually: sc.exe delete otelcol" -ForegroundColor White
    Write-Host "  3. Check paths:" -ForegroundColor White
    Write-Host "     Exe: $EXE_PATH" -ForegroundColor Gray
    Write-Host "     Config: $CONFIG_FILE" -ForegroundColor Gray
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
    Write-Host ""
    Write-Host "Check logs with:" -ForegroundColor Yellow
    Write-Host "  Get-EventLog -LogName Application -Source otelcol -Newest 10" -ForegroundColor White
    Write-Host ""
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