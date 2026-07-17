# windows-instrumentation.ps1
# Automated installer for Windows Exporter + OpenTelemetry Collector
# Elven Observability - LGTM Stack as a Service

#Requires -RunAsAdministrator

# Don't exit PowerShell on errors, just continue
$ErrorActionPreference = "Continue"

# Helper functions to stop the installer without closing an interactive PowerShell window.
function Wait-BeforeReturn {
    Write-Host ""
    if (-not (Test-EnvFlag @("ELVEN_AUTO_CONFIRM", "AUTO_CONFIRM"))) {
        Write-Host "Press any key to return to PowerShell..." -ForegroundColor Cyan
        try {
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        } catch {
            try {
                $null = Read-Host "Press Enter to return to PowerShell"
            } catch {
                Start-Sleep -Seconds 10
            }
        }
    }
}

function Exit-WithPause {
    param([int]$ExitCode = 0)

    Wait-BeforeReturn
    $script:InstallerExitCode = $ExitCode
    throw "__ELVEN_WINDOWS_INSTALLER_EXIT__:$ExitCode"
}

function ConvertTo-YamlQuotedString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    $escaped = $Value.Replace("'", "''")
    $escaped = $escaped.Replace("`r", '\r')
    $escaped = $escaped.Replace("`n", '\n')
    $escaped = $escaped.Replace("`t", '\t')

    return "'" + $escaped + "'"
}

function Test-PrometheusLabelName {
    param([string]$Name)

    return $Name -match '^[a-zA-Z_][a-zA-Z0-9_]*$'
}

function ConvertTo-OtelFileConfigUri {
    param([string]$Path)

    return "file:$($Path.Replace('\', '/'))"
}

function ConvertFrom-SecureStringToPlainText {
    param([securestring]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Normalize-ApiToken {
    param([AllowNull()][string]$Token)

    if ($null -eq $Token) {
        return ""
    }

    $normalized = $Token.Trim()

    if ($normalized -match '^\s*Authorization\s*:\s*Bearer\s+(.+)$') {
        $normalized = $matches[1].Trim()
        Write-Host "  → Removed Authorization/Bearer prefix from token input" -ForegroundColor Cyan
    } elseif ($normalized -match '^\s*Bearer\s+(.+)$') {
        $normalized = $matches[1].Trim()
        Write-Host "  → Removed Bearer prefix from token input" -ForegroundColor Cyan
    }

    if (($normalized.StartsWith('"') -and $normalized.EndsWith('"')) -or
        ($normalized.StartsWith("'") -and $normalized.EndsWith("'"))) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
        Write-Host "  → Removed surrounding quotes from token input" -ForegroundColor Cyan
    }

    return $normalized
}

function Get-EnvValue {
    param([string[]]$Names)

    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return ""
}

function Test-EnvFlag {
    param([string[]]$Names)

    $value = Get-EnvValue $Names
    return $value -match '^(1|true|yes|y)$'
}

function Get-EnvBoolean {
    param([string[]]$Names)

    $value = Get-EnvValue $Names
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }
    if ($value -match '^(1|true|yes|y)$') {
        return $true
    }
    if ($value -match '^(0|false|no|n)$') {
        return $false
    }

    throw "$($Names[0]) must be true or false."
}

function ConvertTo-MetricsDestination {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "mimir"
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in @("mimir", "prometheusremotewrite", "prometheus_remote_write") } { return "mimir" }
        { $_ -in @("collector", "otlp", "otlphttp") } { return "collector" }
        default { throw "Invalid metrics destination '$Value'. Supported values: mimir, collector." }
    }
}

function Test-HttpEndpoint {
    param([string]$Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    return $uri.Scheme -in @("http", "https") -and -not [string]::IsNullOrWhiteSpace($uri.Host)
}

function ConvertFrom-OtlpHeaderList {
    param([AllowNull()][string]$Value)

    $headers = @{}
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $headers
    }

    foreach ($entry in ($Value -split ',')) {
        $separatorIndex = $entry.IndexOf('=')
        if ($separatorIndex -le 0) {
            throw "Invalid OTLP header entry. Expected name=value."
        }

        $name = $entry.Substring(0, $separatorIndex).Trim()
        $headerValue = $entry.Substring($separatorIndex + 1).Trim()
        if ($name -notmatch '^[A-Za-z0-9!#$%&''*+.^_`|~-]+$') {
            throw "Invalid OTLP header name '$name'."
        }
        if ($headerValue -match "[`r`n]") {
            throw "OTLP header values cannot contain line breaks."
        }

        $headers[$name] = $headerValue
    }

    return $headers
}

function Set-CollectorConfigAcl {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) {
        $aclOutput = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' /T /C 2>&1
    } else {
        $aclOutput = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restrict Collector path ACL: $aclOutput"
    }
}

function Verify-Sha256FromManifest {
    param(
        [string]$FilePath,
        [string]$AssetName,
        [string]$ManifestUrl
    )

    $manifestPath = Join-Path $env:TEMP ("elven-checksums-" + [Guid]::NewGuid().ToString("N") + ".txt")
    try {
        if (-not (Download-WithRetry -Url $ManifestUrl -OutputPath $manifestPath)) {
            throw "Could not download checksum manifest."
        }

        $assetPattern = '^(?<hash>[0-9a-fA-F]{64})\s+\*?' + [Regex]::Escape($AssetName) + '$'
        $expectedHash = $null
        foreach ($line in (Get-Content -Path $manifestPath -ErrorAction Stop)) {
            if ($line -match $assetPattern) {
                $expectedHash = $matches['hash'].ToLowerInvariant()
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            throw "Checksum not found for $AssetName."
        }

        $actualHash = (Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 validation failed for $AssetName. Expected $expectedHash; got $actualHash."
        }

        Write-Host "  ✓ SHA-256 verified for $AssetName" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  ✗ $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "=== Windows Instrumentation Installer ===" -ForegroundColor Cyan
Write-Host "Elven Observability - Monitoring Setup" -ForegroundColor Cyan
Write-Host ""

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Variables
$OTEL_VERSION = "0.156.0"
$WINDOWS_EXPORTER_VERSION = "0.31.7"
$INSTALL_DIR = "C:\Program Files\OpenTelemetry Collector"
$EXPORTER_DIR = "C:\Program Files\Windows Exporter"
$CONFIG_FILE = "$INSTALL_DIR\config.yaml"
$OTEL_STORAGE_DIR = "$env:ProgramData\OpenTelemetry Collector\file_storage"
$OTEL_SERVICE_NAME = "otelcol"
$EXPORTER_SERVICE_NAME = "windows_exporter"
$EXE_PATH = "$INSTALL_DIR\otelcol-contrib.exe"
$CONFIG_URI = ConvertTo-OtelFileConfigUri $CONFIG_FILE

function Invoke-PreInstallationCleanup {
    # ============================================================================
    # CLEANUP - Remove all previous installations to avoid conflicts
    # ============================================================================
    Write-Host "=== Pre-Installation Cleanup ===" -ForegroundColor Yellow
    Write-Host "Removing any previous installations to ensure clean setup..." -ForegroundColor Yellow
    Write-Host ""

# 1. Stop and delete services
Write-Host "[1/6] Stopping and removing services..." -ForegroundColor Cyan
try {
    # Stop services first
    $services = @($EXPORTER_SERVICE_NAME, $OTEL_SERVICE_NAME)
    foreach ($svcName in $services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq "Running") {
                Write-Host "  → Stopping $svcName..." -ForegroundColor Gray
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            # Delete service
            Write-Host "  → Deleting $svcName service..." -ForegroundColor Gray
            sc.exe delete $svcName 2>$null | Out-Null
            Start-Sleep -Seconds 1
        }
    }
    Write-Host "  ✓ Services cleaned" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ Could not fully clean services (continuing anyway)" -ForegroundColor Yellow
}

# 2. Kill any running processes
Write-Host "[2/6] Terminating processes..." -ForegroundColor Cyan
try {
    $processes = @("windows_exporter", "otelcol", "otelcol-contrib")
    foreach ($procName in $processes) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Host "  → Killing $procName process(es)..." -ForegroundColor Gray
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
    Write-Host "  ✓ Processes terminated" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ Could not kill all processes (continuing anyway)" -ForegroundColor Yellow
}

# 3. Free port 9182
Write-Host "[3/6] Freeing port 9182..." -ForegroundColor Cyan
try {
    $connections = Get-NetTCPConnection -LocalPort 9182 -ErrorAction SilentlyContinue
    if ($connections) {
        foreach ($conn in $connections) {
            Write-Host "  → Killing process using port 9182 (PID: $($conn.OwningProcess))..." -ForegroundColor Gray
            Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
        Write-Host "  ✓ Port 9182 freed" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Port 9182 already free" -ForegroundColor Green
    }
} catch {
    Write-Host "  ⚠ Could not check port (continuing anyway)" -ForegroundColor Yellow
}

# 4. Remove installation directories
Write-Host "[4/6] Removing old directories..." -ForegroundColor Cyan
$directoriesToRemove = @(
    "C:\Program Files\windows_exporter",
    "C:\Program Files\Windows Exporter",
    "C:\Program Files\OpenTelemetry Collector",
    "C:\Program Files\otelcol",
    $EXPORTER_DIR,
    $INSTALL_DIR
)

$removed = 0
foreach ($dir in $directoriesToRemove) {
    if (Test-Path $dir) {
        try {
            Write-Host "  → Removing: $dir" -ForegroundColor Gray
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
            $removed++
        } catch {
            Write-Host "  ⚠ Could not remove: $dir" -ForegroundColor Yellow
            # Try with cmd
            try {
                cmd /c "rmdir /s /q `"$dir`"" 2>$null
            } catch {}
        }
    }
}
if ($removed -gt 0) {
    Write-Host "  ✓ Removed $removed director(ies)" -ForegroundColor Green
} else {
    Write-Host "  ✓ No old directories found" -ForegroundColor Green
}

# 5. Clean temporary files
Write-Host "[5/6] Cleaning temporary files..." -ForegroundColor Cyan
$tempFiles = @(
    "$env:TEMP\windows_exporter*.msi",
    "$env:TEMP\otelcol*.tar.gz",
    "$env:TEMP\otelcol*.zip",
    "$env:TEMP\otelcol*.msi",
    "C:\temp\windows_exporter*.msi",
    "C:\temp\otelcol*.tar.gz"
)

foreach ($pattern in $tempFiles) {
    try {
        Remove-Item $pattern -Force -ErrorAction SilentlyContinue
    } catch {}
}
Write-Host "  ✓ Temporary files cleaned" -ForegroundColor Green

# 6. Wait for Windows to fully release resources
Write-Host "[6/6] Waiting for Windows to release all resources..." -ForegroundColor Cyan
Start-Sleep -Seconds 5
Write-Host "  ✓ System ready for clean installation!" -ForegroundColor Green

    Write-Host ""
    Write-Host "=== Cleanup Complete - Starting Fresh Installation ===" -ForegroundColor Green
    Write-Host ""
    Write-Host ""
}

# ============================================================================


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
        $downloadHost = "github.com"
        $githubReachable = Test-NetConnection -ComputerName $downloadHost -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
        if (-not $githubReachable) {
            throw "TCP connectivity to $downloadHost`:443 failed."
        }
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
        @{Port=9182; Service="Windows Exporter"}
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
    
    # 7. Check PowerShell version and extraction method
    Write-Host "7. Checking PowerShell version..." -ForegroundColor Yellow
    $psVersion = $PSVersionTable.PSVersion
    $hasTar = $null -ne (Get-Command tar -ErrorAction SilentlyContinue)
    
    if ($psVersion.Major -ge 5) {
        Write-Host "   ✓ PowerShell $($psVersion.Major).$($psVersion.Minor) is supported" -ForegroundColor Green
    } elseif ($psVersion.Major -eq 4) {
        Write-Host "   ⚠ PowerShell $($psVersion.Major).$($psVersion.Minor) (legacy system)" -ForegroundColor Yellow
        Write-Host "   Script will use compatibility mode" -ForegroundColor Cyan
    } else {
        Write-Host "   ✗ PowerShell $($psVersion.Major).$($psVersion.Minor) is too old!" -ForegroundColor Red
        Write-Host "   PowerShell 4.0 or newer is required" -ForegroundColor Yellow
        $allChecksPassed = $false
    }
    
    # Show extraction method that will be used
    if ($hasTar) {
        Write-Host "   → Will use tar for extraction (modern system)" -ForegroundColor Cyan
    } else {
        Write-Host "   → Will use official MSI extraction fallback (legacy system)" -ForegroundColor Cyan
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

function Install-OtelCollectorFromMsi {
    param(
        [string]$MsiUrl,
        [string]$MsiPath,
        [string]$MsiAssetName,
        [string]$ChecksumUrl,
        [string]$InstallDir,
        [string]$ExePath
    )

    Write-Host "  Using official MSI administrative extraction fallback..." -ForegroundColor Cyan

    if (-not (Download-WithRetry -Url $MsiUrl -OutputPath $MsiPath)) {
        Write-Host "✗ Failed to download Collector MSI after multiple attempts." -ForegroundColor Red
        Write-Host "  URL tried: $MsiUrl" -ForegroundColor Yellow
        return $false
    }
    if (-not (Verify-Sha256FromManifest -FilePath $MsiPath -AssetName $MsiAssetName -ManifestUrl $ChecksumUrl)) {
        Remove-Item $MsiPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    $msiExtractDir = Join-Path $env:TEMP "otelcol-msi-extract"
    Remove-Item $msiExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $msiExtractDir | Out-Null

    try {
        Write-Host "  Extracting MSI with msiexec..." -ForegroundColor Cyan
        $msiArgs = "/a `"$MsiPath`" /qn TARGETDIR=`"$msiExtractDir`""
        $msiProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop

        if ($msiProcess.ExitCode -ne 0 -and $msiProcess.ExitCode -ne 3010) {
            Write-Host "✗ MSI extraction failed with exit code $($msiProcess.ExitCode)." -ForegroundColor Red
            return $false
        }

        $extractedExe = Get-ChildItem -Path $msiExtractDir -Filter "otelcol-contrib.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $extractedExe) {
            Write-Host "✗ MSI extraction completed, but otelcol-contrib.exe was not found." -ForegroundColor Red
            return $false
        }

        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Copy-Item -Path $extractedExe.FullName -Destination $ExePath -Force

        if ((Test-Path $ExePath) -and ((Get-Item $ExePath).Length -gt 0)) {
            $fileSize = (Get-Item $ExePath).Length / 1MB
            Write-Host "✓ Collector extracted from MSI ($([math]::Round($fileSize, 2)) MB)" -ForegroundColor Green
            return $true
        }

        Write-Host "✗ Copied collector executable was not found or is empty." -ForegroundColor Red
        return $false
    } catch {
        Write-Host "✗ Error during MSI extraction: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        Remove-Item $msiExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    # Run pre-flight checks
    if (-not (Test-Prerequisites)) {
        Write-Host "Exiting due to failed pre-flight checks." -ForegroundColor Red
        Exit-WithPause 1
    }

# Collect user information with validation
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host ""

$AUTO_CONFIRM = Get-EnvBoolean @("ELVEN_AUTO_CONFIRM", "AUTO_CONFIRM")
if ($AUTO_CONFIRM) {
    Write-Host "  ✓ Auto-confirm enabled from environment" -ForegroundColor Green
}

$METRICS_DESTINATION = ConvertTo-MetricsDestination (Get-EnvValue @("ELVEN_METRICS_DESTINATION", "METRICS_DESTINATION"))
Write-Host "  ✓ Metrics destination: $METRICS_DESTINATION" -ForegroundColor Green

$TENANT_ID = ""
$API_TOKEN_PLAIN = ""
$MIMIR_ENDPOINT = ""
$OTLP_ENDPOINT = ""
$OTLP_API_TOKEN = ""
$OTLP_HEADERS_MAP = @{}
$OTLP_TLS_CA_FILE = Get-EnvValue @("ELVEN_OTLP_TLS_CA_FILE", "OTLP_TLS_CA_FILE")
$OTLP_TLS_CERT_FILE = Get-EnvValue @("ELVEN_OTLP_TLS_CERT_FILE", "OTLP_TLS_CERT_FILE")
$OTLP_TLS_KEY_FILE = Get-EnvValue @("ELVEN_OTLP_TLS_KEY_FILE", "OTLP_TLS_KEY_FILE")
$OTLP_TLS_INSECURE_SKIP_VERIFY = Get-EnvBoolean @("ELVEN_OTLP_TLS_INSECURE_SKIP_VERIFY", "OTLP_TLS_INSECURE_SKIP_VERIFY")

if ($METRICS_DESTINATION -eq "mimir") {
    $TENANT_ID = Get-EnvValue @("ELVEN_TENANT_ID", "TENANT_ID")
    if (-not [string]::IsNullOrWhiteSpace($TENANT_ID)) {
        Write-Host "  ✓ Using Tenant ID from environment" -ForegroundColor Green
    } elseif ($AUTO_CONFIRM) {
        throw "ELVEN_TENANT_ID is required for the Mimir destination."
    } else {
        do {
            $TENANT_ID = Read-Host "Tenant ID"
            if ([string]::IsNullOrWhiteSpace($TENANT_ID)) {
                Write-Host "  ✗ Tenant ID cannot be empty!" -ForegroundColor Red
            }
        } while ([string]::IsNullOrWhiteSpace($TENANT_ID))
    }

    $apiTokenInput = Get-EnvValue @("ELVEN_API_TOKEN", "API_TOKEN")
    $API_TOKEN_PLAIN = Normalize-ApiToken $apiTokenInput
    if (-not [string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN)) {
        Write-Host "  ✓ Using API Token from environment ($($API_TOKEN_PLAIN.Length) characters)" -ForegroundColor Green
    } elseif ($AUTO_CONFIRM) {
        throw "ELVEN_API_TOKEN is required for the Mimir destination."
    } else {
        do {
            $API_TOKEN = Read-Host "API Token" -AsSecureString
            $API_TOKEN_PLAIN = Normalize-ApiToken (ConvertFrom-SecureStringToPlainText $API_TOKEN)
            if ([string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN)) {
                Write-Host "  ✗ API Token cannot be empty!" -ForegroundColor Red
            }
        } while ([string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN))
    }

    $MIMIR_ENDPOINT = Get-EnvValue @("ELVEN_MIMIR_ENDPOINT", "MIMIR_ENDPOINT")
    if ([string]::IsNullOrWhiteSpace($MIMIR_ENDPOINT)) {
        if (-not $AUTO_CONFIRM) {
            $MIMIR_ENDPOINT = Read-Host "Mimir endpoint [default: https://mimir.elvenobservability.com/api/v1/push]"
        }
        if ([string]::IsNullOrWhiteSpace($MIMIR_ENDPOINT)) {
            $MIMIR_ENDPOINT = "https://mimir.elvenobservability.com/api/v1/push"
        }
    }
    if (-not (Test-HttpEndpoint $MIMIR_ENDPOINT)) {
        throw "Mimir endpoint must be a valid http:// or https:// URL."
    }
    if ($MIMIR_ENDPOINT.StartsWith("http://", [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "  ⚠ Mimir credentials will be sent over plaintext HTTP. HTTPS is strongly recommended." -ForegroundColor Yellow
    }
} else {
    $OTLP_ENDPOINT = Get-EnvValue @("ELVEN_OTLP_ENDPOINT", "OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_ENDPOINT")
    if ([string]::IsNullOrWhiteSpace($OTLP_ENDPOINT) -and -not $AUTO_CONFIRM) {
        $OTLP_ENDPOINT = Read-Host "OTLP/HTTP Collector endpoint (for example https://collector.example.com:4318)"
    }
    if ([string]::IsNullOrWhiteSpace($OTLP_ENDPOINT)) {
        throw "ELVEN_OTLP_ENDPOINT is required for the collector destination."
    }
    if (-not (Test-HttpEndpoint $OTLP_ENDPOINT)) {
        throw "OTLP endpoint must be a valid http:// or https:// URL."
    }

    $otlpTokenInput = Get-EnvValue @("ELVEN_OTLP_API_TOKEN", "OTLP_API_TOKEN")
    $OTLP_API_TOKEN = Normalize-ApiToken $otlpTokenInput
    if ([string]::IsNullOrWhiteSpace($OTLP_API_TOKEN) -and -not $AUTO_CONFIRM) {
        $addToken = Read-Host "Configure a Bearer token for the Collector? [y/N]"
        if ($addToken -match '^[Yy]$') {
            $secureToken = Read-Host "Collector API token" -AsSecureString
            $OTLP_API_TOKEN = Normalize-ApiToken (ConvertFrom-SecureStringToPlainText $secureToken)
            if ([string]::IsNullOrWhiteSpace($OTLP_API_TOKEN)) {
                throw "Collector API token cannot be empty after selecting Bearer authentication."
            }
        }
    }

    $OTLP_HEADERS_MAP = ConvertFrom-OtlpHeaderList (Get-EnvValue @("ELVEN_OTLP_HEADERS", "OTLP_HEADERS"))
    if ($OTLP_HEADERS_MAP.ContainsKey("Authorization") -and -not [string]::IsNullOrWhiteSpace($OTLP_API_TOKEN)) {
        throw "Authorization is configured twice. Use ELVEN_OTLP_API_TOKEN or ELVEN_OTLP_HEADERS, not both."
    }
    if (-not [string]::IsNullOrWhiteSpace($OTLP_API_TOKEN)) {
        $OTLP_HEADERS_MAP["Authorization"] = "Bearer $OTLP_API_TOKEN"
    }

    if ([string]::IsNullOrWhiteSpace($OTLP_TLS_CERT_FILE) -xor [string]::IsNullOrWhiteSpace($OTLP_TLS_KEY_FILE)) {
        throw "ELVEN_OTLP_TLS_CERT_FILE and ELVEN_OTLP_TLS_KEY_FILE must be configured together."
    }
    foreach ($tlsFile in @($OTLP_TLS_CA_FILE, $OTLP_TLS_CERT_FILE, $OTLP_TLS_KEY_FILE)) {
        if (-not [string]::IsNullOrWhiteSpace($tlsFile) -and -not (Test-Path -LiteralPath $tlsFile -PathType Leaf)) {
            throw "TLS file was not found: $tlsFile"
        }
    }

    if ($OTLP_ENDPOINT.StartsWith("http://", [StringComparison]::OrdinalIgnoreCase)) {
        if ($OTLP_HEADERS_MAP.Count -gt 0) {
            Write-Host "  ⚠ Authentication headers will be sent over plaintext HTTP. HTTPS is strongly recommended." -ForegroundColor Yellow
        } else {
            Write-Host "  ⚠ OTLP is configured over plaintext HTTP. Use this only on a trusted private network." -ForegroundColor Yellow
        }
    }
    if ($OTLP_TLS_INSECURE_SKIP_VERIFY) {
        Write-Host "  ⚠ TLS certificate verification is disabled for the OTLP Collector." -ForegroundColor Yellow
    }
}

# Instance name with default
$INSTANCE_NAME = Get-EnvValue @("ELVEN_INSTANCE_NAME", "INSTANCE_NAME")
if (-not [string]::IsNullOrWhiteSpace($INSTANCE_NAME)) {
    Write-Host "  ✓ Using instance name from environment: $INSTANCE_NAME" -ForegroundColor Green
} elseif (-not $AUTO_CONFIRM) {
    $INSTANCE_NAME = Read-Host "Instance name (e.g., server-01) [default: $(hostname)]"
}
if ([string]::IsNullOrWhiteSpace($INSTANCE_NAME)) {
    $INSTANCE_NAME = $env:COMPUTERNAME.ToLower()
    Write-Host "  → Using hostname: $INSTANCE_NAME" -ForegroundColor Cyan
}

# Customer name (optional)
$CUSTOMER_NAME = Get-EnvValue @("ELVEN_CUSTOMER_NAME", "CUSTOMER_NAME")
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    Write-Host "  ✓ Using customer name from environment: $CUSTOMER_NAME" -ForegroundColor Green
} elseif (-not $AUTO_CONFIRM) {
    $CUSTOMER_NAME = Read-Host "Customer/Company name (optional) [default: none]"
}
if ([string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    $CUSTOMER_NAME = ""
}

# Environment with default
$ENVIRONMENT = Get-EnvValue @("ELVEN_ENVIRONMENT", "ENVIRONMENT")
if (-not [string]::IsNullOrWhiteSpace($ENVIRONMENT)) {
    Write-Host "  ✓ Using environment from environment variable: $ENVIRONMENT" -ForegroundColor Green
} elseif (-not $AUTO_CONFIRM) {
    $ENVIRONMENT = Read-Host "Environment (production/staging/dev) [default: production]"
}
if ([string]::IsNullOrWhiteSpace($ENVIRONMENT)) {
    $ENVIRONMENT = "production"
    Write-Host "  → Using default: $ENVIRONMENT" -ForegroundColor Cyan
}

# Custom labels (optional)
Write-Host ""
$CustomLabels = @{}

# Check if CUSTOM_LABELS env var is set
$customLabelsInput = Get-EnvValue @("ELVEN_CUSTOM_LABELS", "CUSTOM_LABELS")
if (-not [string]::IsNullOrWhiteSpace($customLabelsInput)) {
    Write-Host "Using custom labels from environment variable..." -ForegroundColor Cyan
    # Parse CUSTOM_LABELS="key1=value1,key2=value2"
    $customLabelsInput -split ',' | ForEach-Object {
        if ($_ -match '^([^=]+)=(.+)$') {
            $labelName = $matches[1].Trim()
            $labelValue = $matches[2].Trim()

            if (-not (Test-PrometheusLabelName $labelName)) {
                throw "Invalid Prometheus label name '$labelName'."
            } else {
                $CustomLabels[$labelName] = $labelValue
            }
        } else {
            throw "Invalid custom label entry. Expected name=value."
        }
    }
    
    if ($CustomLabels.Count -gt 0) {
        Write-Host "  ✓ Loaded $($CustomLabels.Count) custom labels" -ForegroundColor Green
        foreach ($key in $CustomLabels.Keys) {
            Write-Host "    $key`: $($CustomLabels[$key])" -ForegroundColor White
        }
    }
} elseif (-not $AUTO_CONFIRM) {
    # Interactive mode
    $addLabels = Read-Host "Add custom labels? (e.g., group=BASPA, dept=TI) [y/n]"
    if ($addLabels -eq "y" -or $addLabels -eq "Y") {
        Write-Host "Enter custom labels (press Enter without input to finish):" -ForegroundColor Cyan
        while ($true) {
            $labelName = Read-Host "  Label name"
            if ([string]::IsNullOrWhiteSpace($labelName)) {
                break
            }
            $labelName = $labelName.Trim()
            if (-not (Test-PrometheusLabelName $labelName)) {
                Write-Host "  ⚠ Invalid label name: $labelName" -ForegroundColor Yellow
                Write-Host "    Use only letters, numbers, and underscore; do not start with a number." -ForegroundColor Yellow
                continue
            }
            $labelValue = Read-Host "  Label value"
            if (-not [string]::IsNullOrWhiteSpace($labelValue)) {
                $CustomLabels[$labelName] = $labelValue.Trim()
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
Write-Host "  Destination: $METRICS_DESTINATION" -ForegroundColor White
Write-Host "  Instance:   $INSTANCE_NAME" -ForegroundColor White
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    Write-Host "  Customer:   $CUSTOMER_NAME" -ForegroundColor White
}
Write-Host "  Environment: $ENVIRONMENT" -ForegroundColor White
if ($METRICS_DESTINATION -eq "mimir") {
    Write-Host "  Tenant ID:   $TENANT_ID" -ForegroundColor White
    Write-Host "  Endpoint:    $MIMIR_ENDPOINT" -ForegroundColor White
} else {
    Write-Host "  Endpoint:    $OTLP_ENDPOINT" -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($OTLP_API_TOKEN)) {
        Write-Host "  Bearer auth: configured" -ForegroundColor White
    }
    Write-Host "  OTLP headers: $($OTLP_HEADERS_MAP.Count) configured" -ForegroundColor White
    Write-Host "  TLS verify:  $(if ($OTLP_TLS_INSECURE_SKIP_VERIFY) { 'disabled' } else { 'enabled' })" -ForegroundColor White
}
if ($CustomLabels.Count -gt 0) {
    Write-Host "  Custom Labels:" -ForegroundColor White
    foreach ($key in $CustomLabels.Keys) {
        Write-Host "    - $key`: $($CustomLabels[$key])" -ForegroundColor White
    }
}
Write-Host ""

$confirm = if ($AUTO_CONFIRM) { "yes" } else { Read-Host "Confirm and continue? (y/n)" }
if ($AUTO_CONFIRM) {
    Write-Host "  → Auto-confirmed by environment" -ForegroundColor Cyan
}
if ($confirm -ne "y" -and $confirm -ne "Y" -and $confirm -ne "yes") {
    Write-Host "Installation cancelled." -ForegroundColor Yellow
    Exit-WithPause 0
}

Write-Host ""
Invoke-PreInstallationCleanup
Write-Host ""

# ====================
# PART 1: Windows Exporter
# ====================
Write-Host "=== [1/2] Installing Windows Exporter ===" -ForegroundColor Green
Write-Host ""

# Create directory
New-Item -ItemType Directory -Force -Path $EXPORTER_DIR | Out-Null

# Download Windows Exporter - USE STANDALONE BINARY INSTEAD OF MSI
# MSI has issues on some systems, so we download the .exe directly
$EXPORTER_ASSET_NAME = "windows_exporter-${WINDOWS_EXPORTER_VERSION}-amd64.exe"
$EXPORTER_URL = "https://github.com/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}/${EXPORTER_ASSET_NAME}"
$EXPORTER_CHECKSUM_URL = "https://github.com/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}/sha256sums.txt"
$EXPORTER_EXE = "$EXPORTER_DIR\windows_exporter.exe"

Write-Host "Downloading Windows Exporter v$WINDOWS_EXPORTER_VERSION (standalone binary)..." -ForegroundColor Green
Write-Host "  Using direct .exe download (avoiding MSI issues)" -ForegroundColor Cyan

if (-not (Download-WithRetry -Url $EXPORTER_URL -OutputPath $EXPORTER_EXE)) {
    Write-Host "✗ Failed to download Windows Exporter after multiple attempts." -ForegroundColor Red
    Exit-WithPause 1
}
if (-not (Verify-Sha256FromManifest -FilePath $EXPORTER_EXE -AssetName $EXPORTER_ASSET_NAME -ManifestUrl $EXPORTER_CHECKSUM_URL)) {
    Remove-Item $EXPORTER_EXE -Force -ErrorAction SilentlyContinue
    Exit-WithPause 1
}

# Verify download
if (-not (Test-Path $EXPORTER_EXE)) {
    Write-Host "✗ Downloaded file not found at $EXPORTER_EXE" -ForegroundColor Red
    Exit-WithPause 1
}

$fileSize = (Get-Item $EXPORTER_EXE).Length / 1MB
Write-Host "✓ Downloaded successfully ($([math]::Round($fileSize, 2)) MB)" -ForegroundColor Green

# Verify it's a valid executable
Write-Host "Verifying executable..." -ForegroundColor Yellow
try {
    $testProcess = Start-Process -FilePath $EXPORTER_EXE -ArgumentList "--version" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\exporter_version.txt" -RedirectStandardError "$env:TEMP\exporter_error.txt" -ErrorAction Stop
    
    if ($testProcess.ExitCode -eq 0) {
        $version = Get-Content "$env:TEMP\exporter_version.txt" -ErrorAction SilentlyContinue
        Write-Host "✓ Binary is valid: $version" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Version check returned exit code: $($testProcess.ExitCode)" -ForegroundColor Yellow
        $error = Get-Content "$env:TEMP\exporter_error.txt" -ErrorAction SilentlyContinue
        if ($error) {
            Write-Host "  Error: $error" -ForegroundColor Red
        }
    }
    
    Remove-Item "$env:TEMP\exporter_version.txt" -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\exporter_error.txt" -ErrorAction SilentlyContinue
} catch {
    Write-Host "✗ Binary verification failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  This may indicate the download is corrupted or blocked by antivirus." -ForegroundColor Yellow
    Exit-WithPause 1
}

# Wait a moment for file system to stabilize
Start-Sleep -Seconds 2


# Create Windows Exporter service manually
# (Since we're using standalone binary, no MSI to create service)
Write-Host "Creating Windows Exporter service..." -ForegroundColor Green

$exporterExe = "$EXPORTER_DIR\windows_exporter.exe"

# Remove any existing service first
$existingSvc = sc.exe query $EXPORTER_SERVICE_NAME 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  → Removing existing service..." -ForegroundColor Yellow
    sc.exe delete $EXPORTER_SERVICE_NAME | Out-Null
    Start-Sleep -Seconds 3
}

Write-Host "  → Creating service with sc.exe..." -ForegroundColor Cyan
$binPath = "`"$exporterExe`""
$result = sc.exe create $EXPORTER_SERVICE_NAME binPath= $binPath start= auto obj= LocalSystem DisplayName= "Windows Exporter"

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Service created with sc.exe!" -ForegroundColor Green
    
    # Set description
    sc.exe description $EXPORTER_SERVICE_NAME "Prometheus Windows Exporter for metrics collection" | Out-Null
    
    # Configure failure recovery (restart on failure)
    sc.exe failure $EXPORTER_SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    
    Write-Host "  ✓ Service configured!" -ForegroundColor Green
} else {
    Write-Host "  ⚠ sc.exe failed, trying New-Service..." -ForegroundColor Yellow
    
    try {
        # Try with New-Service as fallback
        New-Service -Name $EXPORTER_SERVICE_NAME `
                   -BinaryPathName $binPath `
                   -DisplayName "Windows Exporter" `
                   -StartupType Automatic `
                   -Description "Prometheus Windows Exporter for metrics collection" `
                   -ErrorAction Stop
        
        Write-Host "  ✓ Service created with New-Service!" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ Failed to create service: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
        Write-Host "Manual creation command:" -ForegroundColor Yellow
        Write-Host "  sc.exe create $EXPORTER_SERVICE_NAME binPath= `"$exporterExe`" start= auto obj= LocalSystem" -ForegroundColor White
        Exit-WithPause 1
    }
}

# Give Windows time to register the service
Start-Sleep -Seconds 3

# Get service object
$exporterService = Get-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction SilentlyContinue

if (-not $exporterService) {
    Write-Host "✗ Service was not created successfully!" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "Please try creating manually:" -ForegroundColor Yellow
    Write-Host "  sc.exe create $EXPORTER_SERVICE_NAME binPath= `"$exporterExe`" start= auto obj= LocalSystem" -ForegroundColor White
    Exit-WithPause 1
}

if ($exporterService) {
    # Show service details before starting
    Write-Host "Service details:" -ForegroundColor Cyan
    $svcInfo = Get-Service -Name $EXPORTER_SERVICE_NAME | Select-Object Name, Status, StartType
    Write-Host "  Name: $($svcInfo.Name)" -ForegroundColor White
    Write-Host "  Status: $($svcInfo.Status)" -ForegroundColor White
    Write-Host "  StartType: $($svcInfo.StartType)" -ForegroundColor White
    Write-Host ""
    
    # Test if executable can run before trying service
    Write-Host "Testing if binary can execute..." -ForegroundColor Yellow
    try {
        $testProc = Start-Process -FilePath $exporterExe -ArgumentList "--version" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\we_test.txt" -RedirectStandardError "$env:TEMP\we_error.txt"
        if ($testProc.ExitCode -eq 0) {
            Write-Host "  ✓ Binary can execute successfully!" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Binary test returned exit code: $($testProc.ExitCode)" -ForegroundColor Yellow
            $errorContent = Get-Content "$env:TEMP\we_error.txt" -ErrorAction SilentlyContinue
            if ($errorContent) {
                Write-Host "  Error: $errorContent" -ForegroundColor Red
            }
        }
        Remove-Item "$env:TEMP\we_test.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\we_error.txt" -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  ⚠ Could not test binary: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host ""
    
    Write-Host "Starting Windows Exporter..." -ForegroundColor Green
    
    # Ensure service is configured for automatic start
    try {
        Set-Service -Name $EXPORTER_SERVICE_NAME -StartupType Automatic -ErrorAction Stop
        Write-Host "  ✓ Service set to Automatic startup" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Could not set startup type: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Try to start service with retry
    $maxAttempts = 3
    $attempt = 0
    $started = $false
    
    while ($attempt -lt $maxAttempts -and -not $started) {
        $attempt++
        Write-Host "  Attempt $attempt of $maxAttempts..." -ForegroundColor Cyan
        
        try {
            Start-Service -Name $EXPORTER_SERVICE_NAME -ErrorAction Stop
            Start-Sleep -Seconds 5  # Increased wait time
            
            $exporterStatus = Get-Service -Name $EXPORTER_SERVICE_NAME
            Write-Host "    Service status after start: $($exporterStatus.Status)" -ForegroundColor Cyan
            
            if ($exporterStatus.Status -eq "Running") {
                $started = $true
                Write-Host "  ✓ Windows Exporter is running!" -ForegroundColor Green
            } else {
                Write-Host "    ⚠ Service status is: $($exporterStatus.Status)" -ForegroundColor Yellow
            }
        } catch {
            $errorMsg = $_.Exception.Message
            Write-Host "    ✗ Start attempt $attempt failed!" -ForegroundColor Red
            Write-Host "    Error: $errorMsg" -ForegroundColor Red
            
            # Check Windows Event Log for specific error
            try {
                $recentErrors = Get-WinEvent -LogName System -MaxEvents 5 -ErrorAction SilentlyContinue | 
                    Where-Object {$_.TimeCreated -gt (Get-Date).AddMinutes(-2) -and $_.Message -like "*$EXPORTER_SERVICE_NAME*"}
                
                if ($recentErrors) {
                    Write-Host "    Recent Windows errors:" -ForegroundColor Yellow
                    foreach ($err in $recentErrors) {
                        Write-Host "      [$($err.LevelDisplayName)] $($err.Message.Substring(0, [Math]::Min(150, $err.Message.Length)))" -ForegroundColor Red
                    }
                }
            } catch {
                # Ignore event log errors
            }
            
            if ($attempt -lt $maxAttempts) {
                Write-Host "    → Waiting 5 seconds before retry..." -ForegroundColor Cyan
                Start-Sleep -Seconds 5
            }
        }
    }
    
    if (-not $started) {
        Write-Host ""
        Write-Host "⚠ Service failed to start. Trying alternative: run as background process..." -ForegroundColor Yellow
        Write-Host ""
        
        try {
            # Try to run as a background process instead of service
            $processStarted = $false
            
            # Kill any existing process first
            Get-Process -Name "windows_exporter" -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            
            Write-Host "  Starting Windows Exporter as background process..." -ForegroundColor Cyan
            Start-Process -FilePath $exporterExe -WindowStyle Hidden -ErrorAction Stop
            Start-Sleep -Seconds 5
            
            # Check if process is running
            $exporterProcess = Get-Process -Name "windows_exporter" -ErrorAction SilentlyContinue
            if ($exporterProcess) {
                Write-Host "  ✓ Windows Exporter running as process (PID: $($exporterProcess.Id))" -ForegroundColor Green
                
                # Test endpoint
                Start-Sleep -Seconds 3
                try {
                    $response = Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-Host "  ✓ Endpoint responding correctly!" -ForegroundColor Green
                        $processStarted = $true
                        
                        Write-Host ""
                        Write-Host "⚠ NOTE: Running as process instead of service!" -ForegroundColor Yellow
                        Write-Host "  This means it will stop if you log out or restart the server." -ForegroundColor Yellow
                        Write-Host "  To fix the service issue, follow the troubleshooting steps above." -ForegroundColor Yellow
                        Write-Host ""
                    }
                } catch {
                    Write-Host "  ⚠ Process started but endpoint not responding" -ForegroundColor Yellow
                }
            }
            
            if (-not $processStarted) {
                Write-Host ""
                Write-Host "✗ Both service and process methods failed!" -ForegroundColor Red
                Write-Host ""
                Write-Host "=== TROUBLESHOOTING STEPS ===" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "1. Check if port 9182 is free:" -ForegroundColor Cyan
                Write-Host "   netstat -ano | findstr :9182" -ForegroundColor White
                Write-Host ""
                Write-Host "2. Try running the binary manually:" -ForegroundColor Cyan
                Write-Host "   cd 'C:\Program Files\windows_exporter'" -ForegroundColor White
                Write-Host "   .\windows_exporter.exe" -ForegroundColor White
                Write-Host "   (Press Ctrl+C to stop after testing)" -ForegroundColor Gray
                Write-Host ""
                Write-Host "3. Check Windows Event Viewer:" -ForegroundColor Cyan
                Write-Host "   Get-WinEvent -LogName System -MaxEvents 20 | Where-Object {`$_.Message -like '*windows_exporter*'}" -ForegroundColor White
                Write-Host ""
                Write-Host "4. Try recreating the service:" -ForegroundColor Cyan
                Write-Host "   sc.exe delete windows_exporter" -ForegroundColor White
                Write-Host "   sc.exe create windows_exporter binPath= 'C:\Program Files\windows_exporter\windows_exporter.exe' start= auto obj= LocalSystem" -ForegroundColor White
                Write-Host "   Start-Service windows_exporter" -ForegroundColor White
                Write-Host ""
                Write-Host "5. Check service configuration:" -ForegroundColor Cyan
                Write-Host "   sc.exe qc windows_exporter" -ForegroundColor White
                Write-Host ""
                Exit-WithPause 1
            }
        } catch {
            Write-Host "  ✗ Failed to start as process: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            Write-Host "=== MANUAL STEPS REQUIRED ===" -ForegroundColor Yellow
            Write-Host "Please try running manually:" -ForegroundColor Yellow
            Write-Host "  cd 'C:\Program Files\windows_exporter'" -ForegroundColor White
            Write-Host "  .\windows_exporter.exe" -ForegroundColor White
            Write-Host ""
            Exit-WithPause 1
        }
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
    Exit-WithPause 1
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
Write-Host "Downloading OpenTelemetry Collector v$OTEL_VERSION..." -ForegroundColor Green

# Official release assets used by this installer.
$OTEL_ARCHIVE_ASSET_NAME = "otelcol-contrib_${OTEL_VERSION}_windows_amd64.tar.gz"
$OTEL_MSI_ASSET_NAME = "otelcol-contrib_${OTEL_VERSION}_windows_x64.msi"
$OTEL_ARCHIVE_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/$OTEL_ARCHIVE_ASSET_NAME"
$OTEL_MSI_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/$OTEL_MSI_ASSET_NAME"
$OTEL_CHECKSUM_URL = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/opentelemetry-collector-releases_otelcol-contrib_checksums.txt"
$OTEL_PATH = "$env:TEMP\otelcol.tar.gz"
$OTEL_MSI_PATH = "$env:TEMP\otelcol-contrib.msi"

# Windows 10 1803+ / Server 2019+ include tar. Legacy hosts use MSI extraction.
$hasTar = $null -ne (Get-Command tar -ErrorAction SilentlyContinue)
$collectorExtracted = $false

Write-Host "Extracting files..." -ForegroundColor Green

if ($hasTar) {
    Write-Host "  Using native tar for extraction" -ForegroundColor Cyan

    if (-not (Download-WithRetry -Url $OTEL_ARCHIVE_URL -OutputPath $OTEL_PATH)) {
        Write-Host "✗ Failed to download Collector archive after multiple attempts." -ForegroundColor Red
        Write-Host "  URL tried: $OTEL_ARCHIVE_URL" -ForegroundColor Yellow
    } elseif (-not (Verify-Sha256FromManifest -FilePath $OTEL_PATH -AssetName $OTEL_ARCHIVE_ASSET_NAME -ManifestUrl $OTEL_CHECKSUM_URL)) {
        Remove-Item $OTEL_PATH -Force -ErrorAction SilentlyContinue
        Write-Host "  ⚠ Collector archive checksum validation failed." -ForegroundColor Yellow
    } else {
        try {
            $tarOutput = tar -xzf $OTEL_PATH -C $INSTALL_DIR 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path $EXE_PATH)) {
                Write-Host "✓ Extraction complete with tar!" -ForegroundColor Green
                $collectorExtracted = $true
            } else {
                Write-Host "  ⚠ tar extraction did not produce the expected executable." -ForegroundColor Yellow
                Write-Host "  tar exit code: $LASTEXITCODE" -ForegroundColor Yellow
                if ($tarOutput) {
                    Write-Host "  Output: $tarOutput" -ForegroundColor Gray
                }
            }
        } catch {
            Write-Host "  ⚠ Error during tar extraction: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  tar command not found; using official MSI extraction for this legacy Windows host." -ForegroundColor Yellow
}

if (-not $collectorExtracted) {
    if ($hasTar) {
        Write-Host "  Falling back to official MSI extraction..." -ForegroundColor Cyan
    }

    $collectorExtracted = Install-OtelCollectorFromMsi `
        -MsiUrl $OTEL_MSI_URL `
        -MsiPath $OTEL_MSI_PATH `
        -MsiAssetName $OTEL_MSI_ASSET_NAME `
        -ChecksumUrl $OTEL_CHECKSUM_URL `
        -InstallDir $INSTALL_DIR `
        -ExePath $EXE_PATH
}

if (-not $collectorExtracted) {
    Write-Host "" -ForegroundColor Red
    Write-Host "=== MANUAL EXTRACTION REQUIRED ===" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "The automated extraction failed. Please extract manually:" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor White
    Write-Host "Option 1 - MSI administrative extraction:" -ForegroundColor Cyan
    Write-Host "  1. Download: $OTEL_MSI_URL" -ForegroundColor White
    Write-Host "  2. Run: msiexec /a otelcol-contrib_${OTEL_VERSION}_windows_x64.msi /qn TARGETDIR=`"$env:TEMP\otelcol-msi-extract`"" -ForegroundColor White
    Write-Host "  3. Copy otelcol-contrib.exe to: $INSTALL_DIR" -ForegroundColor White
    Write-Host "  4. Run this script again" -ForegroundColor White
    Write-Host "" -ForegroundColor White
    Write-Host "Option 2 - 7-Zip archive extraction:" -ForegroundColor Cyan
    Write-Host "  1. Download: $OTEL_ARCHIVE_URL" -ForegroundColor White
    Write-Host "  2. Extract with 7-Zip or WinRAR (extract twice: .gz then .tar)" -ForegroundColor White
    Write-Host "  3. Copy otelcol-contrib.exe to: $INSTALL_DIR" -ForegroundColor White
    Write-Host "  4. Run this script again" -ForegroundColor White
    Write-Host "" -ForegroundColor White
    Exit-WithPause 1
}

# Wait for file system to catch up
Start-Sleep -Seconds 2

# Verify executable was extracted
if (-not (Test-Path $EXE_PATH)) {
    Write-Host "✗ Executable not found after extraction!" -ForegroundColor Red
    Write-Host "  Check manually: $INSTALL_DIR" -ForegroundColor Yellow
    Exit-WithPause 1
}

Write-Host "✓ Executable found!" -ForegroundColor Green

# Create Collector configuration
Write-Host "Creating Collector configuration..." -ForegroundColor Green

$instanceNameYaml = ConvertTo-YamlQuotedString $INSTANCE_NAME
$environmentYaml = ConvertTo-YamlQuotedString $ENVIRONMENT
$extensionsYaml = ""
$serviceExtensionsYaml = ""

# Build customer label if provided
$customerLabel = ""
if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
    $customerNameYaml = ConvertTo-YamlQuotedString $CUSTOMER_NAME
    $customerLabel = @"

      - action: insert
        key: "customer"
        value: $customerNameYaml
"@
}

# Build custom labels if provided
$customLabelsYaml = ""
if ($CustomLabels.Count -gt 0) {
    foreach ($key in ($CustomLabels.Keys | Sort-Object)) {
        $keyYaml = ConvertTo-YamlQuotedString $key
        $valueYaml = ConvertTo-YamlQuotedString $CustomLabels[$key]
        $customLabelsYaml += @"

      - action: insert
        key: $keyYaml
        value: $valueYaml
"@
    }
}

if ($METRICS_DESTINATION -eq "mimir") {
    $mimirEndpointYaml = ConvertTo-YamlQuotedString $MIMIR_ENDPOINT
    $tenantIdYaml = ConvertTo-YamlQuotedString $TENANT_ID
    $authorizationYaml = ConvertTo-YamlQuotedString "Bearer $API_TOKEN_PLAIN"
    $metricsExporterName = "prometheus_remote_write"
    $exportersYaml = @"
  prometheus_remote_write:
    endpoint: $mimirEndpointYaml
    headers:
      'X-Scope-OrgID': $tenantIdYaml
      'Authorization': $authorizationYaml
    resource_to_telemetry_conversion:
      enabled: true
"@
} else {
    $endpointProperty = "endpoint"
    $otlpUri = [Uri]$OTLP_ENDPOINT
    if ($otlpUri.AbsolutePath -match '/v1/metrics/?$') {
        $endpointProperty = "metrics_endpoint"
    }

    $headersSection = ""
    if ($OTLP_HEADERS_MAP.Count -gt 0) {
        $headersSection = "    headers:"
        foreach ($headerName in ($OTLP_HEADERS_MAP.Keys | Sort-Object)) {
            $headerNameYaml = ConvertTo-YamlQuotedString $headerName
            $headerValueYaml = ConvertTo-YamlQuotedString $OTLP_HEADERS_MAP[$headerName]
            $headersSection += "`n      ${headerNameYaml}: $headerValueYaml"
        }
    }

    $tlsSection = ""
    if (-not [string]::IsNullOrWhiteSpace($OTLP_TLS_CA_FILE) -or
        -not [string]::IsNullOrWhiteSpace($OTLP_TLS_CERT_FILE) -or
        $OTLP_TLS_INSECURE_SKIP_VERIFY) {
        $tlsSection = "    tls:"
        if (-not [string]::IsNullOrWhiteSpace($OTLP_TLS_CA_FILE)) {
            $tlsSection += "`n      ca_file: $(ConvertTo-YamlQuotedString $OTLP_TLS_CA_FILE)"
        }
        if (-not [string]::IsNullOrWhiteSpace($OTLP_TLS_CERT_FILE)) {
            $tlsSection += "`n      cert_file: $(ConvertTo-YamlQuotedString $OTLP_TLS_CERT_FILE)"
            $tlsSection += "`n      key_file: $(ConvertTo-YamlQuotedString $OTLP_TLS_KEY_FILE)"
        }
        if ($OTLP_TLS_INSECURE_SKIP_VERIFY) {
            $tlsSection += "`n      insecure_skip_verify: true"
        }
    }

    New-Item -ItemType Directory -Force -Path $OTEL_STORAGE_DIR | Out-Null
    Set-CollectorConfigAcl -Path $OTEL_STORAGE_DIR
    $storageDirYaml = ConvertTo-YamlQuotedString $OTEL_STORAGE_DIR
    $extensionsYaml = @"
extensions:
  file_storage/otlp:
    directory: $storageDirYaml
"@
    $serviceExtensionsYaml = "  extensions: [file_storage/otlp]"
    $metricsExporterName = "otlphttp/collector"
    $otlpEndpointYaml = ConvertTo-YamlQuotedString $OTLP_ENDPOINT
    $exportersYaml = @"
  otlphttp/collector:
    ${endpointProperty}: $otlpEndpointYaml
    compression: gzip
    timeout: 30s
$headersSection
$tlsSection
    sending_queue:
      enabled: true
      num_consumers: 2
      queue_size: 10000
      storage: file_storage/otlp
    retry_on_failure:
      enabled: true
      initial_interval: 1s
      max_interval: 30s
      max_elapsed_time: 0s
"@
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

$extensionsYaml

exporters:
$exportersYaml

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
    spike_limit_mib: 64

  resource/add_labels:
    attributes:
      - action: insert
        key: "hostname"
        value: $instanceNameYaml
      - action: insert
        key: "environment"
        value: $environmentYaml$customerLabel
      - action: insert
        key: "os"
        value: "windows"$customLabelsYaml

  batch:
    timeout: 10s
    send_batch_size: 1024

  filter/drop_internal:
    error_mode: ignore
    metric_conditions:
      - 'IsMatch(metric.name, "^(go_|scrape_|otlp_|promhttp_|process_).*")'

service:
$serviceExtensionsYaml
  pipelines:
    metrics:
      receivers: [prometheus]
      processors: [memory_limiter, resource/add_labels, filter/drop_internal, batch]
      exporters: [$metricsExporterName]
"@

# Save with UTF8 encoding without BOM
[System.IO.File]::WriteAllText($CONFIG_FILE, $CONFIG_CONTENT)
Set-CollectorConfigAcl -Path $CONFIG_FILE
Write-Host "✓ Configuration created!" -ForegroundColor Green

# Validate configuration
Write-Host "Validating configuration..." -ForegroundColor Green
try {
    $validateOutput = & $EXE_PATH validate "--config=$CONFIG_URI" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Configuration is valid!" -ForegroundColor Green
    } else {
        Write-Host "✗ Invalid configuration!" -ForegroundColor Red
        Write-Host $validateOutput -ForegroundColor Red
        Write-Host "  Config path: $CONFIG_FILE" -ForegroundColor Yellow
        Write-Host "  Config contents are not printed because they may contain credentials." -ForegroundColor Yellow
        Exit-WithPause 1
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
$FULL_COMMAND = "`"$EXE_PATH`" --config=`"$CONFIG_URI`""

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
        Write-Host "  1. Validate config: & '$EXE_PATH' validate --config='$CONFIG_URI'" -ForegroundColor White
        Write-Host "  2. Test manually: & '$EXE_PATH' --config='$CONFIG_URI'" -ForegroundColor White
        Write-Host "  3. Check config file: notepad '$CONFIG_FILE'" -ForegroundColor White
        Write-Host ""
        Exit-WithPause 1
    }
    
} catch {
    Write-Host "✗ Error creating/starting Collector service: $_" -ForegroundColor Red
    Write-Host "  Config path: $CONFIG_FILE" -ForegroundColor Yellow
    Write-Host "  Config contents are not printed because they may contain credentials." -ForegroundColor Yellow
    Exit-WithPause 1
}

# Clean up temporary files
Remove-Item $OTEL_PATH -Force -ErrorAction SilentlyContinue
Remove-Item $OTEL_MSI_PATH -Force -ErrorAction SilentlyContinue

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
Write-Host "  Destination:  $METRICS_DESTINATION" -ForegroundColor White
if ($METRICS_DESTINATION -eq "mimir") {
    Write-Host "  Tenant ID:    $TENANT_ID" -ForegroundColor White
    Write-Host "  Endpoint:     $MIMIR_ENDPOINT" -ForegroundColor White
} else {
    Write-Host "  Endpoint:     $OTLP_ENDPOINT" -ForegroundColor White
    Write-Host "  Queue:        persistent ($OTEL_STORAGE_DIR)" -ForegroundColor White
}
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
if ($METRICS_DESTINATION -eq "collector") {
    Write-Host "Downstream validation (when the Collector exports to Prometheus/Mimir):" -ForegroundColor Yellow
} else {
    Write-Host "Grafana validation:" -ForegroundColor Yellow
}
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
Write-Host "       & 'C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe' validate --config='file:C:/Program Files/OpenTelemetry Collector/config.yaml'" -ForegroundColor Gray
Write-Host "    2. Check event logs:" -ForegroundColor Gray
Write-Host "       Get-WinEvent -LogName Application -MaxEvents 20 | Where {`$_.Message -like '*otelcol*'}" -ForegroundColor Gray
Write-Host "    3. Test manually:" -ForegroundColor Gray
Write-Host "       & 'C:\Program Files\OpenTelemetry Collector\otelcol-contrib.exe' --config='file:C:/Program Files/OpenTelemetry Collector/config.yaml'" -ForegroundColor Gray
Write-Host ""
Write-Host "  Complete uninstall:" -ForegroundColor White
Write-Host "    Stop-Service windows_exporter, otelcol -Force" -ForegroundColor Gray
Write-Host "    sc.exe delete windows_exporter; sc.exe delete otelcol" -ForegroundColor Gray
Write-Host "    Remove-Item 'C:\Program Files\OpenTelemetry Collector' -Recurse -Force" -ForegroundColor Gray
Write-Host "    Remove-Item 'C:\Program Files\Windows Exporter' -Recurse -Force" -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan

} catch {
    $errorMessage = $_.Exception.Message
    if ($errorMessage -match '^__ELVEN_WINDOWS_INSTALLER_EXIT__:(\d+)$') {
        $global:LASTEXITCODE = [int]$matches[1]
        return
    }

    Write-Host ""
    Write-Host "✗ Unexpected installer error: $errorMessage" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "The PowerShell window was intentionally kept open so the error can be copied." -ForegroundColor Yellow
    $global:LASTEXITCODE = 1
    Wait-BeforeReturn
    return
}
