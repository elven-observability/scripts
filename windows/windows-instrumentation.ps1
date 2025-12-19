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
$OTEL_VERSION = "0.114.0"
$WINDOWS_EXPORTER_VERSION = "0.27.3"
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

# Pre-flight validation
function Test-Prerequisites {
    Write-Host "=== Pre-flight Checks ===" -ForegroundColor Cyan
    Write-Host ""
    
    $allChecksPassed = $true
    
    # 1. Check Administrator privileges
    Write-Host "1. Checking administrator privileges..." -ForegroundColor Yellow
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Host "   ✓ Running as Administrator" -ForegroundColor Green
    } else {
        Write-Host "   ✗ NOT running as Administrator!" -ForegroundColor Red
        Write-Host "   Please run PowerShell as Administrator" -ForegroundColor Yellow
        $allChecksPassed = $false
    }
    
    # 2. Check internet connectivity
    Write-Host "2. Checking internet connectivity..." -ForegroundColor Yellow
    try {
        $null = Test-NetConnection -ComputerName "github.com" -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Host "   ✓ Internet connection OK" -ForegroundColor Green
    } catch {
        try {
            # Fallback test
            $null = Invoke-WebRequest -Uri "https://www.google.com" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            Write-Host "   ✓ Internet connection OK" -ForegroundColor Green
        } catch {
            Write-Host "   ✗ Cannot reach internet!" -ForegroundColor Red
            Write-Host "   Check your network connection and proxy settings" -ForegroundColor Yellow
            $allChecksPassed = $false
        }
    }
    
    # 3. Check if ports are available
    Write-Host "3. Checking if required ports are free..." -ForegroundColor Yellow
    $portsToCheck = @(
        @{Port=9182; Service="Windows Exporter"},
        @{Port=4317; Service="OpenTelemetry Collector"}
    )
    
    foreach ($portInfo in $portsToCheck) {
        $port = $portInfo.Port
        $service = $portInfo.Service
        
        $portInUse = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($portInUse) {
            $process = Get-Process -Id $portInUse.OwningProcess -ErrorAction SilentlyContinue
            Write-Host "   ⚠ Port $port is in use by $($process.ProcessName) (PID: $($process.Id))" -ForegroundColor Yellow
            Write-Host "     This port is needed for $service" -ForegroundColor Yellow
            Write-Host "     The script will attempt to stop conflicting services" -ForegroundColor Cyan
        } else {
            Write-Host "   ✓ Port $port is available ($service)" -ForegroundColor Green
        }
    }
    
    # 4. Check disk space
    Write-Host "4. Checking disk space..." -ForegroundColor Yellow
    $systemDrive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($systemDrive) {
        $freeSpaceGB = [math]::Round($systemDrive.Free / 1GB, 2)
        if ($freeSpaceGB -lt 1) {
            Write-Host "   ✗ Low disk space: ${freeSpaceGB}GB free" -ForegroundColor Red
            Write-Host "   At least 1GB of free space is recommended" -ForegroundColor Yellow
            $allChecksPassed = $false
        } else {
            Write-Host "   ✓ Disk space OK: ${freeSpaceGB}GB free" -ForegroundColor Green
        }
    }
    
    # 5. Check write permissions
    Write-Host "5. Checking write permissions..." -ForegroundColor Yellow
    $testDirs = @("C:\Program Files", "C:\Windows\Temp")
    $canWriteAll = $true
    
    foreach ($dir in $testDirs) {
        $testFile = Join-Path $dir "test_write_$(Get-Random).tmp"
        try {
            [System.IO.File]::WriteAllText($testFile, "test")
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "   ✗ Cannot write to: $dir" -ForegroundColor Red
            $canWriteAll = $false
        }
    }
    
    if ($canWriteAll) {
        Write-Host "   ✓ Write permissions OK" -ForegroundColor Green
    } else {
        Write-Host "   ✗ Insufficient write permissions!" -ForegroundColor Red
        $allChecksPassed = $false
    }
    
    # 6. Check if old installations exist
    Write-Host "6. Checking for previous installations..." -ForegroundColor Yellow
    $hasOldInstall = $false
    
    if (Test-Path "C:\Program Files\OpenTelemetry Collector") {
        Write-Host "   ⚠ Found existing OpenTelemetry Collector installation" -ForegroundColor Yellow
        $hasOldInstall = $true
    }
    
    if (Test-Path "C:\Program Files\windows_exporter") {
        Write-Host "   ⚠ Found existing Windows Exporter installation" -ForegroundColor Yellow
        $hasOldInstall = $true
    }
    
    $existingServices = @()
    if (Get-Service -Name "otelcol" -ErrorAction SilentlyContinue) {
        $existingServices += "otelcol"
    }
    if (Get-Service -Name "windows_exporter" -ErrorAction SilentlyContinue) {
        $existingServices += "windows_exporter"
    }
    
    if ($existingServices.Count -gt 0) {
        Write-Host "   ⚠ Found existing services: $($existingServices -join ', ')" -ForegroundColor Yellow
        $hasOldInstall = $true
    }
    
    if ($hasOldInstall) {
        Write-Host "   → Script will clean up and reinstall" -ForegroundColor Cyan
    } else {
        Write-Host "   ✓ No previous installations found" -ForegroundColor Green
    }
    
    # 7. Check PowerShell version
    Write-Host "7. Checking PowerShell version..." -ForegroundColor Yellow
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -ge 5) {
        Write-Host "   ✓ PowerShell $($psVersion.Major).$($psVersion.Minor) is supported" -ForegroundColor Green
    } else {
        Write-Host "   ⚠ PowerShell $($psVersion.Major).$($psVersion.Minor) is old" -ForegroundColor Yellow
        Write-Host "   PowerShell 5.1 or newer is recommended" -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    if (-not $allChecksPassed) {
        Write-Host "✗ Pre-flight checks FAILED!" -ForegroundColor Red
        Write-Host "Please fix the issues above before continuing." -ForegroundColor Yellow
        Write-Host ""
        return $false
    }
    
    Write-Host "✓ All pre-flight checks passed!" -ForegroundColor Green
    Write-Host ""
    return $true
}

# Rollback function in case of failure
function Invoke-Rollback {
    param($Stage)
    
    Write-Host ""
    Write-Host "=== Rollback: Cleaning up after failure ===" -ForegroundColor Yellow
    Write-Host "Failed at stage: $Stage" -ForegroundColor Red
    Write-Host ""
    
    # Stop and remove services
    Write-Host "Stopping and removing services..." -ForegroundColor Yellow
    Stop-Service -Name "windows_exporter" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "otelcol" -Force -ErrorAction SilentlyContinue
    
    Start-Sleep -Seconds 2
    
    sc.exe delete "windows_exporter" 2>$null | Out-Null
    sc.exe delete "otelcol" 2>$null | Out-Null
    
    # Kill processes
    Get-Process | Where-Object {$_.ProcessName -like "*windows_exporter*" -or $_.ProcessName -like "*otelcol*"} | 
        Stop-Process -Force -ErrorAction SilentlyContinue
    
    # Remove directories (optional - commented out to preserve logs)
    # Write-Host "Removing installation directories..." -ForegroundColor Yellow
    # Remove-Item "C:\Program Files\OpenTelemetry Collector" -Recurse -Force -ErrorAction SilentlyContinue
    # Remove-Item "C:\Program Files\Windows Exporter" -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "Rollback complete. Installation directories preserved for troubleshooting." -ForegroundColor Yellow
    Write-Host "To manually clean up:" -ForegroundColor Cyan
    Write-Host "  Remove-Item 'C:\Program Files\OpenTelemetry Collector' -Recurse -Force" -ForegroundColor Gray
    Write-Host "  Remove-Item 'C:\Program Files\Windows Exporter' -Recurse -Force" -ForegroundColor Gray
    Write-Host ""
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

# Run pre-flight checks
if (-not (Test-Prerequisites)) {
    Write-Host "Exiting due to failed pre-flight checks." -ForegroundColor Red
    exit 1
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
    $process = Start-Process msiexec.exe -ArgumentList $installArgs -Wait -NoNewWindow -PassThru
    
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        Write-Host "  ⚠ MSI exit code: $($process.ExitCode)" -ForegroundColor Yellow
    }
    
    Write-Host "✓ Windows Exporter MSI completed!" -ForegroundColor Green
} catch {
    Write-Host "✗ Error installing Windows Exporter: $_" -ForegroundColor Red
    exit 1
}

# Verify installation
Write-Host "Verifying installation..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

# Check if binary exists
$exporterExe = "C:\Program Files\windows_exporter\windows_exporter.exe"
if (-not (Test-Path $exporterExe)) {
    Write-Host "✗ Windows Exporter binary not found at expected location!" -ForegroundColor Red
    Write-Host "  Expected: $exporterExe" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ Binary found: $exporterExe" -ForegroundColor Green

# Test binary execution
Write-Host "Testing binary..." -ForegroundColor Yellow
try {
    $testProcess = Start-Process -FilePath $exporterExe -ArgumentList "--version" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\exporter_version.txt" -ErrorAction Stop
    $version = Get-Content "$env:TEMP\exporter_version.txt" -ErrorAction SilentlyContinue
    if ($version) {
        Write-Host "✓ Binary is executable: $version" -ForegroundColor Green
    }
    Remove-Item "$env:TEMP\exporter_version.txt" -ErrorAction SilentlyContinue
} catch {
    Write-Host "  ⚠ Could not test binary version, continuing anyway..." -ForegroundColor Yellow
}

# Wait for MSI service creation
Write-Host "Checking for service..." -ForegroundColor Yellow
Start-Sleep -Seconds 2

# Verify and configure service
$exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue

if (-not $exporterService) {
    Write-Host "  ⚠ MSI did not create service, creating manually..." -ForegroundColor Yellow
    
    # Create service manually with LocalSystem account
    try {
        sc.exe delete $EXPORTER_SERVICE_NAME 2>$null | Out-Null
        
        $result = sc.exe create $EXPORTER_SERVICE_NAME binPath= "`"$exporterExe`"" start= auto obj= "LocalSystem" DisplayName= "Windows Exporter"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Service created manually" -ForegroundColor Green
            
            # Set description
            sc.exe description $EXPORTER_SERVICE_NAME "Prometheus Windows Exporter for metrics collection" | Out-Null
            
            # Configure failure recovery
            sc.exe failure $EXPORTER_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
        } else {
            Write-Host "✗ Failed to create service manually" -ForegroundColor Red
            exit 1
        }
        
        # Refresh service object
        Start-Sleep -Seconds 2
        $exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
    } catch {
        Write-Host "✗ Error creating service: $_" -ForegroundColor Red
        exit 1
    }
}

if ($exporterService) {
    Write-Host "Starting Windows Exporter..." -ForegroundColor Green
    
    # Ensure service is configured for automatic start
    Set-Service -Name $EXPORTER_SERVICE_NAME -StartupType Automatic -ErrorAction SilentlyContinue
    
    # Try to start service with retry
    $maxAttempts = 3
    $attempt = 0
    $started = $false
    
    while ($attempt -lt $maxAttempts -and -not $started) {
        $attempt++
        Write-Host "  Attempt $attempt of $maxAttempts..." -ForegroundColor Cyan
        
        try {
            Start-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction Stop
            Start-Sleep -Seconds 3
            
            $exporterStatus = Get-Service -Name $EXPORTER_SERVICE_NAME
            if ($exporterStatus.Status -eq "Running") {
                $started = $true
                Write-Host "✓ Windows Exporter is running!" -ForegroundColor Green
            }
        } catch {
            Write-Host "  ⚠ Start attempt $attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 2
            }
        }
    }
    
    if (-not $started) {
        Write-Host "✗ Failed to start Windows Exporter after $maxAttempts attempts" -ForegroundColor Red
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Check Windows Event Viewer for errors" -ForegroundColor White
        Write-Host "  2. Try running manually: cd 'C:\Program Files\windows_exporter'; .\windows_exporter.exe" -ForegroundColor White
        Write-Host "  3. Check if another process is using port 9182: netstat -ano | findstr :9182" -ForegroundColor White
        Write-Host ""
        exit 1
    }
    
    # Test endpoint
    Write-Host "Testing endpoint..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    
    $maxEndpointAttempts = 5
    $endpointAttempt = 0
    $endpointWorking = $false
    
    while ($endpointAttempt -lt $maxEndpointAttempts -and -not $endpointWorking) {
        $endpointAttempt++
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -eq 200 -and $response.Content -match "windows_") {
                $endpointWorking = $true
                Write-Host "✓ Endpoint responding correctly!" -ForegroundColor Green
                $metricsCount = ([regex]::Matches($response.Content, "^windows_", [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
                Write-Host "  → Exporting $metricsCount+ Windows metrics" -ForegroundColor Cyan
            }
        } catch {
            if ($endpointAttempt -lt $maxEndpointAttempts) {
                Write-Host "  ⚠ Endpoint not ready yet, waiting... (attempt $endpointAttempt/$maxEndpointAttempts)" -ForegroundColor Yellow
                Start-Sleep -Seconds 3
            }
        }
    }
    
    if (-not $endpointWorking) {
        Write-Host "  ⚠ Service running but endpoint not responding on port 9182" -ForegroundColor Yellow
        Write-Host "  Check firewall or try: curl http://localhost:9182/metrics" -ForegroundColor Yellow
    }
} else {
    Write-Host "✗ Could not find or create Windows Exporter service!" -ForegroundColor Red
    exit 1
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
        key: instance
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
    
    # Start service with retry logic
    Write-Host "Starting Collector..." -ForegroundColor Green
    
    $maxAttempts = 3
    $attempt = 0
    $started = $false
    
    while ($attempt -lt $maxAttempts -and -not $started) {
        $attempt++
        Write-Host "  Attempt $attempt of $maxAttempts..." -ForegroundColor Cyan
        
        try {
            Start-Service -Name $OTEL_SERVICE_NAME -ErrorAction Stop
            Start-Sleep -Seconds 4
            
            $otelStatus = Get-Service -Name $OTEL_SERVICE_NAME
            if ($otelStatus.Status -eq "Running") {
                $started = $true
                Write-Host "✓ OpenTelemetry Collector is running!" -ForegroundColor Green
            } else {
                Write-Host "  ⚠ Service status: $($otelStatus.Status)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  ⚠ Start attempt $attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 3
            }
        }
    }
    
    if (-not $started) {
        Write-Host "✗ Failed to start Collector after $maxAttempts attempts" -ForegroundColor Red
        Write-Host ""
        Write-Host "Checking logs..." -ForegroundColor Yellow
        Get-WinEvent -LogName Application -MaxEvents 10 -ErrorAction SilentlyContinue | 
            Where-Object {$_.Message -like "*otelcol*"} | 
            ForEach-Object { 
                Write-Host "  [$($_.TimeCreated)] $($_.LevelDisplayName): $($_.Message)" -ForegroundColor Red 
            }
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Validate config: & '$EXE_PATH' validate --config='$CONFIG_FILE'" -ForegroundColor White
        Write-Host "  2. Test manually: & '$EXE_PATH' --config='$CONFIG_FILE'" -ForegroundColor White
        Write-Host "  3. Check config file: notepad '$CONFIG_FILE'" -ForegroundColor White
        Write-Host ""
        exit 1
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
Write-Host ""
Write-Host "Troubleshooting:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  If Windows Exporter won't start:" -ForegroundColor White
Write-Host "    1. Check if port 9182 is free: netstat -ano | findstr :9182" -ForegroundColor Gray
Write-Host "    2. Run manually to see errors:" -ForegroundColor Gray
Write-Host "       cd 'C:\Program Files\windows_exporter'" -ForegroundColor Gray
Write-Host "       .\windows_exporter.exe" -ForegroundColor Gray
Write-Host "    3. Recreate service:" -ForegroundColor Gray
Write-Host "       sc.exe delete windows_exporter" -ForegroundColor Gray
Write-Host "       sc.exe create windows_exporter binPath= 'C:\Program Files\windows_exporter\windows_exporter.exe' start= auto obj= LocalSystem" -ForegroundColor Gray
Write-Host "       Start-Service windows_exporter" -ForegroundColor Gray
Write-Host ""
Write-Host "  If OpenTelemetry Collector won't start:" -ForegroundColor White
Write-Host "    1. Validate config:" -ForegroundColor Gray
Write-Host "       & 'C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe' validate --config='C:\Program Files\OpenTelemetry Collector\config.yaml'" -ForegroundColor Gray
Write-Host "    2. Check event logs:" -ForegroundColor Gray
Write-Host "       Get-WinEvent -LogName Application -MaxEvents 20 | Where {`$_.Message -like '*otelcol*'}" -ForegroundColor Gray
Write-Host "    3. Test manually:" -ForegroundColor Gray
Write-Host "       & 'C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe' --config='C:\Program Files\OpenTelemetry Collector\config.yaml'" -ForegroundColor Gray
Write-Host ""
Write-Host "  Complete uninstall:" -ForegroundColor White
Write-Host "    Stop-Service windows_exporter, otelcol -Force" -ForegroundColor Gray
Write-Host "    sc.exe delete windows_exporter; sc.exe delete otelcol" -ForegroundColor Gray
Write-Host "    Remove-Item 'C:\Program Files\OpenTelemetry Collector' -Recurse -Force" -ForegroundColor Gray
Write-Host "    Remove-Item 'C:\Program Files\Windows Exporter' -Recurse -Force" -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan