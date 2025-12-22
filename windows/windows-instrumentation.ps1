# windows-instrumentation.ps1
# Automated installer for Windows Exporter + OpenTelemetry Collector
# Elven Observability - LGTM Stack as a Service
#
# This script is intended to run on customer Windows hosts (client-side).
# It is interactive by default (safe for low-technical users), but supports
# environment variables for automation.
#
#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "=== Windows Instrumentation Installer ===" -ForegroundColor Cyan
Write-Host "Elven Observability - Monitoring Setup" -ForegroundColor Cyan
Write-Host ""

# Force TLS 1.2 (some older Windows/PS need this for GitHub)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # If this fails, continue (rare)
}

# ====================
# Variables (prefer English defaults)
# ====================
$OTEL_VERSION             = "0.114.0"
$WINDOWS_EXPORTER_VERSION = "0.27.3"

$INSTALL_DIR  = "C:\Program Files\OpenTelemetry Collector"
$CONFIG_FILE  = Join-Path $INSTALL_DIR "config.yaml"
$OTEL_SERVICE_NAME = "otelcol"
$EXE_PATH     = Join-Path $INSTALL_DIR "otelcol-contrib.exe"

# NOTE: windows_exporter MSI defaults to this (lowercase folder).
# Your previous script had $EXPORTER_DIR with a different folder name,
# but later validated "C:\Program Files\windows_exporter\windows_exporter.exe".
$EXPORTER_INSTALL_DIR   = "C:\Program Files\windows_exporter"
$EXPORTER_EXE           = Join-Path $EXPORTER_INSTALL_DIR "windows_exporter.exe"
$EXPORTER_SERVICE_NAME  = "windows_exporter"
$EXPORTER_PORT          = 9182

# ====================
# Helpers
# ====================

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    Write-Host ""
}

function Stop-ServiceAndProcess {
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [Parameter(Mandatory=$true)][string]$ProcessPattern
    )

    Write-Host "Checking if $ServiceName is running..." -ForegroundColor Yellow

    # Stop service if exists
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -eq "Running") {
            Write-Host "  Stopping service $ServiceName..." -ForegroundColor Yellow
            try {
                Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            } catch {}
            Start-Sleep -Seconds 2
        }
    }

    # Kill related processes (best effort)
    try {
        $processes = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*$ProcessPattern*" }
        if ($processes) {
            Write-Host "  Terminating related processes..." -ForegroundColor Yellow
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    } catch {}

    Write-Host "  ✓ Clean!" -ForegroundColor Green
}

function Test-CommandExists {
    param([Parameter(Mandatory=$true)][string]$Name)
    try {
        $null = Get-Command $Name -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Download-WithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [int]$MaxRetries = 3,
        [int]$TimeoutSec = 60
    )

    # Ensure temp folder exists
    try {
        $outDir = Split-Path -Parent $OutputPath
        if ($outDir -and -not (Test-Path $outDir)) {
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        }
    } catch {}

    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Host "  Attempt $i of $MaxRetries..." -ForegroundColor Gray

            # Prefer Invoke-WebRequest (handles proxies better than WebClient on many systems)
            if (Test-CommandExists -Name "Invoke-WebRequest") {
                Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ "User-Agent" = "PowerShell" } | Out-Null
            } else {
                # Fallback (very old environments)
                $webClient = New-Object System.Net.WebClient
                $webClient.Headers.Add("User-Agent", "PowerShell")
                $webClient.DownloadFile($Url, $OutputPath)
            }

            # Verify file was downloaded
            if (Test-Path $OutputPath) {
                $fileSize = (Get-Item $OutputPath).Length
                if ($fileSize -gt 0) {
                    Write-Host "  ✓ Download complete! ($([math]::Round($fileSize/1MB, 2)) MB)" -ForegroundColor Green
                    return $true
                }
            }

            throw "Downloaded file is empty or missing: $OutputPath"
        } catch {
            Write-Host "  ✗ Attempt $i failed: $($_.Exception.Message)" -ForegroundColor Red
            if ($i -lt $MaxRetries) {
                Write-Host "  Waiting 3 seconds before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds 3
            }
        }
    }

    return $false
}

function Invoke-Rollback {
    param([Parameter(Mandatory=$true)][string]$Stage)

    Write-Host ""
    Write-Host "=== Rollback: Cleaning up after failure ===" -ForegroundColor Yellow
    Write-Host "Failed at stage: $Stage" -ForegroundColor Red
    Write-Host ""

    Write-Host "Stopping and removing services..." -ForegroundColor Yellow

    try { Stop-Service -Name $EXPORTER_SERVICE_NAME -Force -ErrorAction SilentlyContinue } catch {}
    try { Stop-Service -Name $OTEL_SERVICE_NAME -Force -ErrorAction SilentlyContinue } catch {}

    Start-Sleep -Seconds 2

    try { sc.exe delete $EXPORTER_SERVICE_NAME 2>$null | Out-Null } catch {}
    try { sc.exe delete $OTEL_SERVICE_NAME 2>$null | Out-Null } catch {}

    # Kill processes (best effort)
    try {
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -like "*windows_exporter*" -or $_.ProcessName -like "*otelcol*" } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}

    Write-Host ""
    Write-Host "Rollback complete. Installation directories preserved for troubleshooting." -ForegroundColor Yellow
    Write-Host "To manually clean up:" -ForegroundColor Cyan
    Write-Host "  Remove-Item '$INSTALL_DIR' -Recurse -Force" -ForegroundColor Gray
    Write-Host "  Remove-Item '$EXPORTER_INSTALL_DIR' -Recurse -Force" -ForegroundColor Gray
    Write-Host ""
}

function Test-Prerequisites {
    Write-Section "Pre-flight Checks"

    $allChecksPassed = $true

    # 1. Admin
    Write-Host "1. Checking administrator privileges..." -ForegroundColor Yellow
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Host "   ✓ Running as Administrator" -ForegroundColor Green
    } else {
        Write-Host "   ✗ NOT running as Administrator!" -ForegroundColor Red
        Write-Host "   Please run PowerShell as Administrator" -ForegroundColor Yellow
        $allChecksPassed = $false
    }

    # 2. Internet
    Write-Host "2. Checking internet connectivity..." -ForegroundColor Yellow
    try {
        $ok = Test-NetConnection -ComputerName "github.com" -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        if (-not $ok) { throw "Test-NetConnection failed" }
        Write-Host "   ✓ Internet connection OK" -ForegroundColor Green
    } catch {
        try {
            $null = Invoke-WebRequest -Uri "https://www.google.com" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            Write-Host "   ✓ Internet connection OK" -ForegroundColor Green
        } catch {
            Write-Host "   ✗ Cannot reach internet!" -ForegroundColor Red
            Write-Host "   Check your network connection and proxy settings" -ForegroundColor Yellow
            $allChecksPassed = $false
        }
    }

    # 3. Ports
    # NOTE: Collector in this script only scrapes windows_exporter and remote_writes.
    # It does NOT open OTLP receiver (4317/4318). So we only check 9182 here.
    Write-Host "3. Checking if required ports are free..." -ForegroundColor Yellow
    $portsToCheck = @(
        @{ Port = $EXPORTER_PORT; Service = "Windows Exporter" }
    )

    foreach ($portInfo in $portsToCheck) {
        $port = $portInfo.Port
        $service = $portInfo.Service

        try {
            $portInUse = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            if ($portInUse) {
                $process = Get-Process -Id $portInUse.OwningProcess -ErrorAction SilentlyContinue
                $pname = if ($process) { $process.ProcessName } else { "unknown" }
                Write-Host "   ⚠ Port $port is in use by $pname (PID: $($portInUse.OwningProcess))" -ForegroundColor Yellow
                Write-Host "     This port is needed for $service" -ForegroundColor Yellow
                Write-Host "     The script will attempt to stop conflicting services" -ForegroundColor Cyan
            } else {
                Write-Host "   ✓ Port $port is available ($service)" -ForegroundColor Green
            }
        } catch {
            Write-Host "   ⚠ Could not check port $port. Continuing..." -ForegroundColor Yellow
        }
    }

    # 4. Disk space
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

    # 5. Write permissions
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

    # 6. Previous installations
    Write-Host "6. Checking for previous installations..." -ForegroundColor Yellow
    $hasOldInstall = $false

    if (Test-Path $INSTALL_DIR) {
        Write-Host "   ⚠ Found existing OpenTelemetry Collector installation: $INSTALL_DIR" -ForegroundColor Yellow
        $hasOldInstall = $true
    }

    if (Test-Path $EXPORTER_INSTALL_DIR) {
        Write-Host "   ⚠ Found existing Windows Exporter installation: $EXPORTER_INSTALL_DIR" -ForegroundColor Yellow
        $hasOldInstall = $true
    }

    $existingServices = @()
    if (Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue) { $existingServices += $OTEL_SERVICE_NAME }
    if (Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue) { $existingServices += $EXPORTER_SERVICE_NAME }

    if ($existingServices.Count -gt 0) {
        Write-Host "   ⚠ Found existing services: $($existingServices -join ', ')" -ForegroundColor Yellow
        $hasOldInstall = $true
    }

    if ($hasOldInstall) {
        Write-Host "   → Script will clean up and reinstall" -ForegroundColor Cyan
    } else {
        Write-Host "   ✓ No previous installations found" -ForegroundColor Green
    }

    # 7. PowerShell version
    Write-Host "7. Checking PowerShell version..." -ForegroundColor Yellow
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -ge 5) {
        Write-Host "   ✓ PowerShell $($psVersion.Major).$($psVersion.Minor) is supported" -ForegroundColor Green
    } else {
        Write-Host "   ⚠ PowerShell $($psVersion.Major).$($psVersion.Minor) is old" -ForegroundColor Yellow
        Write-Host "   PowerShell 5.1 or newer is recommended" -ForegroundColor Yellow
    }

    # 8. tar availability (needed for .tar.gz)
    Write-Host "8. Checking tar availability (needed for collector extraction)..." -ForegroundColor Yellow
    if (Test-CommandExists -Name "tar.exe" -or Test-CommandExists -Name "tar") {
        Write-Host "   ✓ tar is available" -ForegroundColor Green
    } else {
        Write-Host "   ⚠ tar was not found in PATH" -ForegroundColor Yellow
        Write-Host "   On older Windows, you may need to install tar support or use Windows 10/11 built-in tar." -ForegroundColor Yellow
        # Not a hard fail, but likely to fail extraction
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

# ====================
# Run pre-flight checks
# ====================
if (-not (Test-Prerequisites)) {
    Write-Host "Exiting due to failed pre-flight checks." -ForegroundColor Red
    exit 1
}

# ====================
# Collect user input (client-friendly)
# ====================
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host ""

# Tenant ID (required)
do {
    $TENANT_ID = Read-Host "Tenant ID"
    if ([string]::IsNullOrWhiteSpace($TENANT_ID)) {
        Write-Host "  ✗ Tenant ID cannot be empty!" -ForegroundColor Red
    }
} while ([string]::IsNullOrWhiteSpace($TENANT_ID))

# API Token (required) - secure input
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
        Write-Host "    Example: https://metrics.yourcompany.com/api/v1/push" -ForegroundColor Yellow
    }
} while ($true)

# Custom labels (optional)
Write-Host ""
$CustomLabels = @{}

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
    $addLabels = Read-Host "Add custom labels? (e.g., group=BASPA, dept=TI) [y/n]"
    if ($addLabels -eq "y" -or $addLabels -eq "Y") {
        Write-Host "Enter custom labels (press Enter without input to finish):" -ForegroundColor Cyan
        while ($true) {
            $labelName = Read-Host "  Label name"
            if ([string]::IsNullOrWhiteSpace($labelName)) { break }
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
Write-Host "  Tenant ID:   $TENANT_ID" -ForegroundColor White
Write-Host "  Instance:    $INSTANCE_NAME" -ForegroundColor White
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) { Write-Host "  Customer:    $CUSTOMER_NAME" -ForegroundColor White }
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
if ($confirm -notin @("y","Y","yes","YES","Yes")) {
    Write-Host "Installation cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host ""

# ====================
# PART 1: Windows Exporter
# ====================
try {
    Write-Section "[1/2] Installing Windows Exporter"

    Stop-ServiceAndProcess -ServiceName $EXPORTER_SERVICE_NAME -ProcessPattern "windows_exporter"

    # Download Windows Exporter MSI
    $EXPORTER_URL  = "https://github.com/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}/windows_exporter-${WINDOWS_EXPORTER_VERSION}-amd64.msi"
    $EXPORTER_PATH = Join-Path $env:TEMP "windows_exporter.msi"

    Write-Host "Downloading Windows Exporter v$WINDOWS_EXPORTER_VERSION..." -ForegroundColor Green
    if (-not (Download-WithRetry -Url $EXPORTER_URL -OutputPath $EXPORTER_PATH)) {
        throw "Failed to download Windows Exporter after multiple attempts."
    }

    # Install Windows Exporter
    Write-Host "Installing Windows Exporter..." -ForegroundColor Green
    $ENABLED_COLLECTORS = "cpu,cs,logical_disk,net,os,system,memory,process,service"

    $installArgs = "/i `"$EXPORTER_PATH`" ENABLED_COLLECTORS=$ENABLED_COLLECTORS /quiet /norestart"
    $process = Start-Process msiexec.exe -ArgumentList $installArgs -Wait -NoNewWindow -PassThru

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        Write-Host "  ⚠ MSI exit code: $($process.ExitCode)" -ForegroundColor Yellow
        # Keep going; we verify the binary and service after.
    }

    Write-Host "✓ Windows Exporter MSI completed!" -ForegroundColor Green

    # Verify installation
    Write-Host "Verifying installation..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3

    if (-not (Test-Path $EXPORTER_EXE)) {
        throw "Windows Exporter binary not found at expected location: $EXPORTER_EXE"
    }
    Write-Host "✓ Binary found: $EXPORTER_EXE" -ForegroundColor Green

    # Test version (best effort)
    Write-Host "Testing binary..." -ForegroundColor Yellow
    try {
        $tmpVer = Join-Path $env:TEMP "exporter_version.txt"
        $null = Start-Process -FilePath $EXPORTER_EXE -ArgumentList "--version" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $tmpVer
        $version = Get-Content $tmpVer -ErrorAction SilentlyContinue
        if ($version) { Write-Host "✓ Binary is executable: $version" -ForegroundColor Green }
        Remove-Item $tmpVer -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  ⚠ Could not test binary version, continuing anyway..." -ForegroundColor Yellow
    }

    # Ensure service exists; MSI should create it, but sometimes it doesn't.
    Write-Host "Checking for service..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    $exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue

    if (-not $exporterService) {
        Write-Host "  ⚠ MSI did not create service, creating manually..." -ForegroundColor Yellow

        # Remove if a broken service exists
        try { sc.exe delete $EXPORTER_SERVICE_NAME 2>$null | Out-Null } catch {}

        $result = sc.exe create $EXPORTER_SERVICE_NAME binPath= "`"$EXPORTER_EXE`"" start= auto obj= "LocalSystem" DisplayName= "Windows Exporter"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Windows Exporter service manually."
        }

        Write-Host "✓ Service created manually" -ForegroundColor Green

        # Description and recovery
        try { sc.exe description $EXPORTER_SERVICE_NAME "Prometheus Windows Exporter for metrics collection" | Out-Null } catch {}
        try { sc.exe failure $EXPORTER_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null } catch {}

        Start-Sleep -Seconds 2
        $exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
    }

    if (-not $exporterService) {
        throw "Could not find or create Windows Exporter service."
    }

    Write-Host "Starting Windows Exporter..." -ForegroundColor Green
    try { Set-Service -Name $EXPORTER_SERVICE_NAME -StartupType Automatic -ErrorAction SilentlyContinue } catch {}

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
            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 2 }
        }
    }

    if (-not $started) {
        Write-Host "✗ Failed to start Windows Exporter after $maxAttempts attempts" -ForegroundColor Red
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Check Windows Event Viewer for errors" -ForegroundColor White
        Write-Host "  2. Try running manually: cd '$EXPORTER_INSTALL_DIR'; .\windows_exporter.exe" -ForegroundColor White
        Write-Host "  3. Check if another process is using port $EXPORTER_PORT: netstat -ano | findstr :$EXPORTER_PORT" -ForegroundColor White
        Write-Host ""
        throw "Windows Exporter did not start."
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
            $response = Invoke-WebRequest -Uri "http://localhost:$EXPORTER_PORT/metrics" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
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
        Write-Host "  ⚠ Service running but endpoint not responding on port $EXPORTER_PORT" -ForegroundColor Yellow
        Write-Host "  Check firewall or try: Invoke-WebRequest http://localhost:$EXPORTER_PORT/metrics" -ForegroundColor Yellow
    }

} catch {
    Invoke-Rollback -Stage "Windows Exporter"
    Write-Host "✗ Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ====================
# PART 2: OpenTelemetry Collector
# ====================
try {
    Write-Section "[2/2] Installing OpenTelemetry Collector"

    Stop-ServiceAndProcess -ServiceName $OTEL_SERVICE_NAME -ProcessPattern "otelcol"

    # Create directory
    New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

    # Remove old executable if exists
    if (Test-Path $EXE_PATH) {
        Write-Host "Removing old executable..." -ForegroundColor Yellow
        Remove-Item $EXE_PATH -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    # Download Collector (.tar.gz)
    $OTEL_URL  = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol-contrib_${OTEL_VERSION}_windows_amd64.tar.gz"
    $OTEL_PATH = Join-Path $env:TEMP "otelcol.tar.gz"

    Write-Host "Downloading OpenTelemetry Collector v$OTEL_VERSION..." -ForegroundColor Green
    if (-not (Download-WithRetry -Url $OTEL_URL -OutputPath $OTEL_PATH)) {
        throw "Failed to download Collector after multiple attempts."
    }

    # Extract
    Write-Host "Extracting files..." -ForegroundColor Green
    if (-not (Test-CommandExists -Name "tar.exe") -and -not (Test-CommandExists -Name "tar")) {
        throw "tar was not found on this system. Collector extraction requires tar to extract .tar.gz."
    }

    # Use tar
    & tar -xzf $OTEL_PATH -C $INSTALL_DIR 2>&1 | Out-Null
    Write-Host "✓ Extraction complete!" -ForegroundColor Green

    # Verify executable
    if (-not (Test-Path $EXE_PATH)) {
        throw "Executable not found after extraction: $EXE_PATH"
    }
    Write-Host "✓ Executable found!" -ForegroundColor Green

    # Build optional labels blocks for YAML
    $customerLabel = ""
    if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
        $customerLabel = @"

      - action: insert
        key: customer
        value: "$CUSTOMER_NAME"
"@
    }

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

    # Create Collector configuration
    Write-Host "Creating Collector configuration..." -ForegroundColor Green

    $CONFIG_CONTENT = @"
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'windows_exporter'
          scrape_interval: 30s
          static_configs:
            - targets: ['localhost:$EXPORTER_PORT']

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

    # Save config as UTF8 without BOM (important for some parsers & PS 5.1)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($CONFIG_FILE, $CONFIG_CONTENT, $utf8NoBom)
    Write-Host "✓ Configuration created!" -ForegroundColor Green

    # Validate configuration
    Write-Host "Validating configuration..." -ForegroundColor Green
    $validateOutput = & $EXE_PATH validate --config=$CONFIG_FILE 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Invalid configuration!" -ForegroundColor Red
        Write-Host $validateOutput -ForegroundColor Red
        Write-Host ""
        Write-Host "Config file contents:" -ForegroundColor Yellow
        Get-Content $CONFIG_FILE | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        throw "Collector configuration validation failed."
    }
    Write-Host "✓ Configuration is valid!" -ForegroundColor Green

    # Remove old service if exists
    $existingService = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Host "Removing existing service..." -ForegroundColor Yellow
        try { Stop-Service -Name $OTEL_SERVICE_NAME -Force -ErrorAction SilentlyContinue } catch {}
        try { sc.exe delete $OTEL_SERVICE_NAME | Out-Null } catch {}
        Start-Sleep -Seconds 2
    }

    # Create service
    Write-Host "Creating OpenTelemetry Collector service..." -ForegroundColor Green
    $FULL_COMMAND = "`"$EXE_PATH`" --config=`"$CONFIG_FILE`""

    New-Service -Name $OTEL_SERVICE_NAME `
                -BinaryPathName $FULL_COMMAND `
                -DisplayName "OpenTelemetry Collector" `
                -StartupType Automatic `
                -Description "OpenTelemetry Collector - Metrics Collection" `
                -ErrorAction Stop

    Write-Host "✓ Service created!" -ForegroundColor Green

    # Configure recovery
    try { sc.exe failure $OTEL_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null } catch {}

    # Start service with retries
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
            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 3 }
        }
    }

    if (-not $started) {
        Write-Host "✗ Failed to start Collector after $maxAttempts attempts" -ForegroundColor Red
        Write-Host ""
        Write-Host "Checking logs..." -ForegroundColor Yellow
        Get-WinEvent -LogName Application -MaxEvents 30 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -like "*otelcol*" } |
            ForEach-Object {
                Write-Host "  [$($_.TimeCreated)] $($_.LevelDisplayName): $($_.Message)" -ForegroundColor Red
            }

        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Validate config: & '$EXE_PATH' validate --config='$CONFIG_FILE'" -ForegroundColor White
        Write-Host "  2. Test manually:  & '$EXE_PATH' --config='$CONFIG_FILE'" -ForegroundColor White
        Write-Host "  3. Check config:   notepad '$CONFIG_FILE'" -ForegroundColor White
        Write-Host ""
        throw "Collector did not start."
    }

} catch {
    Invoke-Rollback -Stage "OpenTelemetry Collector"
    Write-Host "✗ Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ====================
# Cleanup
# ====================
try { Remove-Item (Join-Path $env:TEMP "otelcol.tar.gz") -Force -ErrorAction SilentlyContinue } catch {}
try { Remove-Item (Join-Path $env:TEMP "windows_exporter.msi") -Force -ErrorAction SilentlyContinue } catch {}

# ====================
# Final summary
# ====================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✅ INSTALLATION COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$finalExporterStatus = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue
$finalOtelStatus     = Get-Service -Name $OTEL_SERVICE_NAME -ErrorAction SilentlyContinue

Write-Host "Service Status:" -ForegroundColor Yellow
if ($finalExporterStatus) {
    $exporterIcon  = if ($finalExporterStatus.Status -eq "Running") { "✓" } else { "✗" }
    $exporterColor = if ($finalExporterStatus.Status -eq "Running") { "Green" } else { "Red" }
    Write-Host "  $exporterIcon Windows Exporter: $($finalExporterStatus.Status)" -ForegroundColor $exporterColor
} else {
    Write-Host "  ✗ Windows Exporter: Not found" -ForegroundColor Red
}

if ($finalOtelStatus) {
    $otelIcon  = if ($finalOtelStatus.Status -eq "Running") { "✓" } else { "✗" }
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
Write-Host "Files:" -Foreg
