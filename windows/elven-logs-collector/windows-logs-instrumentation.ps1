# windows-logs-instrumentation.ps1
# Automated installer for Elven Logs Collector on Windows
# Elven Observability - Loki Logs as a Service

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$script:AutoConfirm = $false

function Wait-BeforeReturn {
    Write-Host ""
    if (-not $script:AutoConfirm) {
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
    throw "__ELVEN_LOGS_INSTALLER_EXIT__:$ExitCode"
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
}

function ConvertTo-AlloyString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    $escaped = $Value.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`r", '\r')
    $escaped = $escaped.Replace("`n", '\n')
    $escaped = $escaped.Replace("`t", '\t')

    return '"' + $escaped + '"'
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
        Write-Host "  -> Removed Authorization/Bearer prefix from token input" -ForegroundColor Cyan
    } elseif ($normalized -match '^\s*Bearer\s+(.+)$') {
        $normalized = $matches[1].Trim()
        Write-Host "  -> Removed Bearer prefix from token input" -ForegroundColor Cyan
    }

    if (($normalized.StartsWith('"') -and $normalized.EndsWith('"')) -or
        ($normalized.StartsWith("'") -and $normalized.EndsWith("'"))) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
        Write-Host "  -> Removed surrounding quotes from token input" -ForegroundColor Cyan
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

function Get-SplitValues {
    param([AllowNull()][string]$Value)

    $items = @()
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $items
    }

    foreach ($item in ($Value -split ',')) {
        $trimmed = $item.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $items += $trimmed
        }
    }

    return $items
}

function Normalize-Version {
    param([string]$Version)

    $normalized = $Version.Trim()
    if ($normalized.StartsWith("v")) {
        $normalized = $normalized.Substring(1)
    }

    return $normalized
}

function ConvertTo-AlloyPath {
    param([string]$Path)

    return $Path.Replace('\', '/')
}

function Test-AbsoluteWindowsPath {
    param([string]$Path)

    return ($Path -match '^[a-zA-Z]:[\\/]' -or $Path -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+')
}

function Get-SafeComponentLabel {
    param([string]$Name)

    $label = $Name.ToLowerInvariant() -replace '[^a-z0-9_]+', '_'
    $label = $label.Trim('_')

    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = "source"
    }

    if ($label -match '^[0-9]') {
        $label = "log_" + $label
    }

    return $label
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-AlloyExecutable {
    param([string]$InstallDir)

    $preferredNames = @(
        "alloy.exe",
        "alloy-windows-amd64.exe"
    )

    foreach ($name in $preferredNames) {
        $candidate = Join-Path $InstallDir $name
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $candidateExe = Get-ChildItem -Path $InstallDir -Filter "alloy*.exe" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '(?i)(service|install|uninstall)' } |
        Sort-Object Name |
        Select-Object -First 1

    if ($candidateExe) {
        return $candidateExe.FullName
    }

    return ""
}

function Show-AlloyInstallDirectory {
    param([string]$InstallDir)

    if (-not (Test-Path $InstallDir)) {
        Write-Host "  Install directory does not exist: $InstallDir" -ForegroundColor Yellow
        return
    }

    Write-Host "  Files found in ${InstallDir}:" -ForegroundColor Yellow
    Get-ChildItem -Path $InstallDir -ErrorAction SilentlyContinue |
        Select-Object -First 30 |
        ForEach-Object {
            Write-Host "    $($_.Name)" -ForegroundColor Yellow
        }
}

function Download-WithRetry {
    param(
        [string]$Url,
        [string]$OutputPath,
        [int]$MaxRetries = 3
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-Host "  Download attempt $attempt of $MaxRetries..." -ForegroundColor Gray

            $client = New-Object System.Net.WebClient
            try {
                $client.Headers.Add("User-Agent", "elven-logs-collector-windows-installer")
                $client.DownloadFile($Url, $OutputPath)
            } finally {
                $client.Dispose()
            }

            if ((Test-Path $OutputPath) -and ((Get-Item $OutputPath).Length -gt 0)) {
                return $true
            }
        } catch {
            Write-Warn "Download failed: $($_.Exception.Message)"
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds 3
            }
        }
    }

    return $false
}

function Verify-Sha256 {
    param(
        [string]$FilePath,
        [string]$Sha256SumsPath,
        [string]$AssetName
    )

    if (-not (Test-Path $Sha256SumsPath)) {
        Write-Warn "SHA256SUMS not available; continuing with TLS-only download verification."
        return $true
    }

    $assetRegex = "^\s*[a-fA-F0-9]{64}\s+\*?$([regex]::Escape($AssetName))\s*$"
    $sumLine = Get-Content $Sha256SumsPath | Where-Object { $_ -match $assetRegex } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($sumLine)) {
        Write-Warn "No checksum entry found for $AssetName; continuing with TLS-only download verification."
        return $true
    }

    if ($sumLine -notmatch '([a-fA-F0-9]{64})') {
        Write-Warn "Could not parse checksum entry for $AssetName; continuing with TLS-only download verification."
        return $true
    }

    $expected = $matches[1].ToLowerInvariant()
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($actual -ne $expected) {
        Write-Fail "SHA256 verification failed."
        Write-Host "  Expected: $expected" -ForegroundColor Red
        Write-Host "  Actual:   $actual" -ForegroundColor Red
        return $false
    }

    Write-Success "SHA256 verification passed"
    return $true
}

function Set-RegistryMultiString {
    param(
        [string]$Path,
        [string]$Name,
        [string[]]$Value
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    New-ItemProperty -Path $Path -Name $Name -PropertyType MultiString -Value $Value -Force | Out-Null
}

function Confirm-OverwriteExistingConfig {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        return $true
    }

    $content = Get-Content $ConfigPath -Raw -ErrorAction SilentlyContinue
    $isElvenManaged = $content -match 'Elven Observability'

    if ($isElvenManaged) {
        Write-Warn "Existing Elven-managed collector config will be backed up and replaced."
        return $true
    }

    Write-Warn "Existing collector config does not appear to be Elven-managed."
    Write-Warn "A timestamped backup will be created before replacement."

    if ($script:AutoConfirm) {
        Write-Success "Auto-confirm enabled; proceeding with backup and replacement."
        return $true
    }

    $answer = Read-Host "Continue and replace existing collector config? (y/n)"
    return ($answer -match '^(y|yes)$')
}

function Backup-FileIfExists {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$Path.elven-backup-$timestamp"
    Copy-Item -Path $Path -Destination $backupPath -Force
    return $backupPath
}

function Build-EventLogComponent {
    param(
        [string]$Channel,
        [string]$ComponentLabel,
        [string]$BookmarkPath,
        [int]$MaxAgeMinutes,
        [string]$InstanceName,
        [string]$Environment,
        [string]$CustomerName
    )

    $channelString = ConvertTo-AlloyString $Channel
    $bookmarkString = ConvertTo-AlloyString (ConvertTo-AlloyPath $BookmarkPath)
    $instanceString = ConvertTo-AlloyString $InstanceName
    $environmentString = ConvertTo-AlloyString $Environment
    $customerString = ConvertTo-AlloyString $CustomerName

    $xpathLine = ""
    if ($MaxAgeMinutes -gt 0) {
        $maxAgeMs = [int64]$MaxAgeMinutes * 60 * 1000
        $xpathLine = "  xpath_query            = `"*[System[TimeCreated[timediff(@SystemTime) <= $maxAgeMs]]]`"`n"
    }

    return @"
loki.source.windowsevent "$ComponentLabel" {
  eventlog_name          = $channelString
  bookmark_path          = $bookmarkString
  use_incoming_timestamp = true
  poll_interval          = "3s"
$xpathLine  forward_to             = [loki.write.default.receiver]

  labels = {
    job         = "elven-logs-collector",
    log_source  = "windows-eventlog",
    source      = "windows",
    host        = $instanceString,
    hostname    = $instanceString,
    environment = $environmentString,
    customer    = $customerString,
    channel     = $channelString,
  }
}

"@
}

function Build-FileLogComponent {
    param(
        [string[]]$Paths,
        [string]$InstanceName,
        [string]$Environment,
        [string]$CustomerName
    )

    if ($Paths.Count -eq 0) {
        return ""
    }

    $instanceString = ConvertTo-AlloyString $InstanceName
    $environmentString = ConvertTo-AlloyString $Environment
    $customerString = ConvertTo-AlloyString $CustomerName
    $targets = ""

    foreach ($path in $Paths) {
        $alloyPath = ConvertTo-AlloyPath $path
        $pathString = ConvertTo-AlloyString $alloyPath
        $excludePath = $alloyPath
        if ($excludePath -match '\.\*$') {
            $excludePath = $excludePath -replace '\.\*$', '.{gz,zip,bak,old,1,2,3}'
        } elseif ($excludePath -match '\*$') {
            $excludePath = $excludePath + '.{gz,zip,bak,old,1,2,3}'
        } else {
            $excludePath = $excludePath + '.{gz,zip,bak,old,1,2,3}'
        }
        $excludeString = ConvertTo-AlloyString $excludePath

        $targets += @"
    {
      __path__         = $pathString,
      __path_exclude__ = $excludeString,
      job              = "elven-logs-collector",
      log_source       = "windows-filelog",
      source           = "windows",
      host             = $instanceString,
      hostname         = $instanceString,
      environment      = $environmentString,
      customer         = $customerString,
      log_path         = $pathString,
    },
"@
    }

    return @"
loki.source.file "custom_files" {
  targets = [
$targets  ]
  tail_from_end           = true
  on_positions_file_error = "restart_from_end"
  forward_to              = [loki.write.default.receiver]

  file_match {
    enabled     = true
    sync_period = "10s"
  }
}

"@
}

function Build-AlloyConfig {
    param(
        [string[]]$Channels,
        [string[]]$FilePaths,
        [string]$BookmarkDir,
        [int]$MaxAgeMinutes,
        [string]$InstanceName,
        [string]$Environment,
        [string]$CustomerName,
        [string]$LokiUrl
    )

    $eventComponents = ""
    $usedLabels = @{}

    foreach ($channel in $Channels) {
        $baseLabel = Get-SafeComponentLabel $channel
        $label = $baseLabel
        $counter = 2
        while ($usedLabels.ContainsKey($label)) {
            $label = "$baseLabel`_$counter"
            $counter++
        }
        $usedLabels[$label] = $true

        $bookmarkPath = Join-Path $BookmarkDir "$label.xml"
        $eventComponents += Build-EventLogComponent `
            -Channel $channel `
            -ComponentLabel $label `
            -BookmarkPath $bookmarkPath `
            -MaxAgeMinutes $MaxAgeMinutes `
            -InstanceName $InstanceName `
            -Environment $Environment `
            -CustomerName $CustomerName
    }

    $fileComponent = Build-FileLogComponent `
        -Paths $FilePaths `
        -InstanceName $InstanceName `
        -Environment $Environment `
        -CustomerName $CustomerName

    $lokiUrlString = ConvertTo-AlloyString $LokiUrl

    return @"
// Managed by Elven Observability elven-logs-collector.
// Local edits may be overwritten when the installer is re-run.

logging {
  level  = "info"
  format = "logfmt"
}

$eventComponents$fileComponent
loki.write "default" {
  endpoint {
    url = $lokiUrlString

    authorization {
      type        = "Bearer"
      credentials = sys.env("API_TOKEN")
    }

    headers = {
      "X-Scope-OrgID" = sys.env("TENANT_ID"),
    }

    tls_config {
      min_version = "TLS12"
    }
  }
}
"@
}

try {
    Write-Host "=== Elven Observability - elven-logs-collector ===" -ForegroundColor Cyan
    Write-Host ""

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $script:AutoConfirm = Test-EnvFlag @("ELVEN_AUTO_CONFIRM", "AUTO_CONFIRM")

    $ALLOY_VERSION = Normalize-Version (Get-EnvValue @("ELVEN_COLLECTOR_VERSION", "ELVEN_ALLOY_VERSION", "ALLOY_VERSION"))
    if ([string]::IsNullOrWhiteSpace($ALLOY_VERSION)) {
        $ALLOY_VERSION = "1.16.0"
    }
    if ($ALLOY_VERSION -notmatch '^\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$') {
        Write-Fail "Collector runtime version must look like 1.16.0 or 1.16.0-rc.1."
        Exit-WithPause 1
    }

    $SERVICE_NAME = "Alloy"
    $LOKI_DEFAULT_URL = "https://loki.elvenobservability.com/loki/api/v1/push"
    $ALLOY_INSTALL_DIR = Join-Path $env:ProgramFiles "GrafanaLabs\Alloy"
    $ALLOY_DATA_DIR = Join-Path $env:ProgramData "GrafanaLabs\Alloy\data"
    $ALLOY_BOOKMARK_DIR = Join-Path $env:ProgramData "GrafanaLabs\Alloy\bookmarks"
    $CONFIG_FILE = Join-Path $ALLOY_INSTALL_DIR "config.alloy"
    $ALLOY_EXE = Join-Path $ALLOY_INSTALL_DIR "alloy.exe"
    $REGISTRY_PATH = "HKLM:\Software\GrafanaLabs\Alloy"
    $TEMP_DIR = Join-Path $env:TEMP "elven-logs-collector"
    $INSTALLER_NAME = "alloy-installer-windows-amd64.exe"
    $INSTALLER_PATH = Join-Path $TEMP_DIR $INSTALLER_NAME
    $SHA256SUMS_PATH = Join-Path $TEMP_DIR "SHA256SUMS"
    $RELEASE_BASE_URL = "https://github.com/grafana/alloy/releases/download/v$ALLOY_VERSION"
    $INSTALLER_URL = "$RELEASE_BASE_URL/$INSTALLER_NAME"
    $SHA256SUMS_URL = "$RELEASE_BASE_URL/SHA256SUMS"

    Write-Step "Pre-flight checks"
    if (-not (Test-Administrator)) {
        Write-Fail "This installer must be run as Administrator."
        Exit-WithPause 1
    }
    Write-Success "Running as Administrator"

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Fail "Only 64-bit Windows is supported."
        Exit-WithPause 1
    }
    Write-Success "64-bit Windows detected"

    if (-not [Environment]::Is64BitProcess) {
        Write-Fail "Run this installer from 64-bit PowerShell, not 32-bit PowerShell."
        Exit-WithPause 1
    }
    Write-Success "64-bit PowerShell process detected"

    if ($PSVersionTable.PSVersion -lt [version]"5.1") {
        Write-Fail "PowerShell 5.1+ is required."
        Exit-WithPause 1
    }
    Write-Success "PowerShell $($PSVersionTable.PSVersion) detected"

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        Write-Fail "Windows Server 2016+ or Windows 10+ is required."
        Exit-WithPause 1
    }
    Write-Success "Supported Windows version detected"

    Write-Step "Configuration"

    $TENANT_ID = Get-EnvValue @("ELVEN_TENANT_ID", "TENANT_ID")
    if (-not [string]::IsNullOrWhiteSpace($TENANT_ID)) {
        $TENANT_ID = $TENANT_ID.Trim()
        Write-Success "Using Tenant ID from environment"
    } else {
        if ($script:AutoConfirm) {
            Write-Fail "ELVEN_TENANT_ID or TENANT_ID must be set when ELVEN_AUTO_CONFIRM=true."
            Exit-WithPause 1
        }

        do {
            $TENANT_ID = (Read-Host "Tenant ID").Trim()
            if ([string]::IsNullOrWhiteSpace($TENANT_ID)) {
                Write-Fail "Tenant ID cannot be empty"
            }
        } while ([string]::IsNullOrWhiteSpace($TENANT_ID))
    }

    if ($TENANT_ID -match '\s') {
        Write-Fail "Tenant ID contains whitespace. Copy only the raw tenant identifier."
        Exit-WithPause 1
    }

    $apiTokenInput = Get-EnvValue @("ELVEN_API_TOKEN", "API_TOKEN")
    $apiTokenFromEnv = -not [string]::IsNullOrWhiteSpace($apiTokenInput)
    $API_TOKEN_PLAIN = Normalize-ApiToken $apiTokenInput
    if ($apiTokenFromEnv -and -not [string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN)) {
        Write-Success "Using API Token from environment ($($API_TOKEN_PLAIN.Length) characters)"
    } else {
        if ($script:AutoConfirm) {
            Write-Fail "ELVEN_API_TOKEN or API_TOKEN must be set when ELVEN_AUTO_CONFIRM=true."
            Exit-WithPause 1
        }

        do {
            $API_TOKEN = Read-Host "API Token" -AsSecureString
            $API_TOKEN_PLAIN = Normalize-ApiToken (ConvertFrom-SecureStringToPlainText $API_TOKEN)
            if ([string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN)) {
                Write-Fail "API Token cannot be empty"
            }
        } while ([string]::IsNullOrWhiteSpace($API_TOKEN_PLAIN))
        Write-Success "API Token captured ($($API_TOKEN_PLAIN.Length) characters)"
    }

    if ($API_TOKEN_PLAIN -match '\s') {
        Write-Fail "API Token contains whitespace after normalization. Copy only the raw token or 'Bearer <token>'."
        Exit-WithPause 1
    }

    if ($script:AutoConfirm) {
        Write-Success "Auto-confirm enabled from environment"
    }

    $INSTANCE_NAME = Get-EnvValue @("ELVEN_INSTANCE_NAME", "INSTANCE_NAME")
    if (-not [string]::IsNullOrWhiteSpace($INSTANCE_NAME)) {
        Write-Success "Using instance name from environment: $INSTANCE_NAME"
    } elseif (-not $script:AutoConfirm) {
        $INSTANCE_NAME = Read-Host "Instance name [default: $($env:COMPUTERNAME.ToLower())]"
    }
    if ([string]::IsNullOrWhiteSpace($INSTANCE_NAME)) {
        $INSTANCE_NAME = $env:COMPUTERNAME.ToLower()
        Write-Host "  -> Using hostname: $INSTANCE_NAME" -ForegroundColor Cyan
    }

    $CUSTOMER_NAME = Get-EnvValue @("ELVEN_CUSTOMER_NAME", "CUSTOMER_NAME")
    if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
        Write-Success "Using customer name from environment: $CUSTOMER_NAME"
    } elseif (-not $script:AutoConfirm) {
        $CUSTOMER_NAME = Read-Host "Customer/Company name (optional) [default: none]"
    }
    if ([string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
        $CUSTOMER_NAME = ""
    }

    $ENVIRONMENT = Get-EnvValue @("ELVEN_ENVIRONMENT", "ENVIRONMENT")
    if (-not [string]::IsNullOrWhiteSpace($ENVIRONMENT)) {
        Write-Success "Using environment from environment variable: $ENVIRONMENT"
    } elseif (-not $script:AutoConfirm) {
        $ENVIRONMENT = Read-Host "Environment (production/staging/dev) [default: production]"
    }
    if ([string]::IsNullOrWhiteSpace($ENVIRONMENT)) {
        $ENVIRONMENT = "production"
        Write-Host "  -> Using default environment: $ENVIRONMENT" -ForegroundColor Cyan
    }

    $LOKI_URL = Get-EnvValue @("ELVEN_LOKI_URL", "LOKI_URL")
    do {
        if ([string]::IsNullOrWhiteSpace($LOKI_URL)) {
            if (-not $script:AutoConfirm) {
                $LOKI_URL = Read-Host "Loki URL [default: $LOKI_DEFAULT_URL]"
            }
        } else {
            Write-Success "Using Loki URL: $LOKI_URL"
        }

        if ([string]::IsNullOrWhiteSpace($LOKI_URL)) {
            $LOKI_URL = $LOKI_DEFAULT_URL
            Write-Host "  -> Using default Loki URL: $LOKI_URL" -ForegroundColor Cyan
            break
        } elseif ($LOKI_URL -match '^https?://') {
            break
        } else {
            Write-Fail "Loki URL must start with http:// or https://"
            $LOKI_URL = ""
        }
    } while ($true)

    $channelsInput = Get-EnvValue @("ELVEN_LOG_CHANNELS", "LOG_CHANNELS")
    if ([string]::IsNullOrWhiteSpace($channelsInput) -and -not $script:AutoConfirm) {
        $channelsInput = Read-Host "Event Log channels [default: Application]"
    }
    $LOG_CHANNELS = Get-SplitValues $channelsInput
    if ($LOG_CHANNELS.Count -eq 0) {
        $LOG_CHANNELS = @("Application")
    }

    $validChannels = @()
    foreach ($channel in $LOG_CHANNELS) {
        try {
            $null = Get-WinEvent -ListLog $channel -ErrorAction Stop
            if ($validChannels -notcontains $channel) {
                $validChannels += $channel
            }
        } catch {
            Write-Warn "Skipping unavailable Event Log channel: $channel"
        }
    }
    if ($validChannels.Count -eq 0) {
        Write-Fail "No valid Event Log channels were selected."
        Exit-WithPause 1
    }
    $LOG_CHANNELS = $validChannels
    Write-Success "Event Log channels: $($LOG_CHANNELS -join ', ')"

    $pathsInput = Get-EnvValue @("ELVEN_LOG_PATHS", "LOG_PATHS")
    $LOG_PATHS = Get-SplitValues $pathsInput
    if ($LOG_PATHS.Count -eq 0 -and -not $script:AutoConfirm) {
        $addPaths = Read-Host "Add custom file log paths? (e.g. C:\inetpub\logs\LogFiles\*\*.log) [y/n]"
        if ($addPaths -match '^(y|yes)$') {
            Write-Host "Enter one absolute log path or glob per line. Press Enter without input to finish." -ForegroundColor Cyan
            while ($true) {
                $path = Read-Host "  Log path"
                if ([string]::IsNullOrWhiteSpace($path)) {
                    break
                }
                $LOG_PATHS += $path.Trim()
            }
        }
    }

    $validatedPaths = @()
    foreach ($path in $LOG_PATHS) {
        if (Test-AbsoluteWindowsPath $path) {
            $validatedPaths += $path
        } else {
            Write-Warn "Skipping non-absolute log path: $path"
        }
    }
    $LOG_PATHS = $validatedPaths
    if ($LOG_PATHS.Count -gt 0) {
        Write-Success "Custom file log paths: $($LOG_PATHS -join ', ')"
    } else {
        Write-Success "No custom file log paths configured"
    }

    $maxAgeInput = Get-EnvValue @("ELVEN_EVENTLOG_MAX_AGE_MINUTES", "EVENTLOG_MAX_AGE_MINUTES")
    if ([string]::IsNullOrWhiteSpace($maxAgeInput) -and -not $script:AutoConfirm) {
        $maxAgeInput = Read-Host "Event Log max age in minutes [default: 60, 0 disables]"
    }
    if ([string]::IsNullOrWhiteSpace($maxAgeInput)) {
        $maxAgeInput = "60"
    }
    $EVENTLOG_MAX_AGE_MINUTES = 60
    if (-not [int]::TryParse($maxAgeInput, [ref]$EVENTLOG_MAX_AGE_MINUTES) -or $EVENTLOG_MAX_AGE_MINUTES -lt 0) {
        Write-Fail "ELVEN_EVENTLOG_MAX_AGE_MINUTES must be a non-negative integer."
        Exit-WithPause 1
    }
    Write-Success "Event Log max age: $EVENTLOG_MAX_AGE_MINUTES minute(s)"

    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Green
    Write-Host "  Collector runtime version: $ALLOY_VERSION" -ForegroundColor White
    Write-Host "  Tenant ID:     $TENANT_ID" -ForegroundColor White
    Write-Host "  Instance:      $INSTANCE_NAME" -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($CUSTOMER_NAME)) {
        Write-Host "  Customer:      $CUSTOMER_NAME" -ForegroundColor White
    }
    Write-Host "  Environment:   $ENVIRONMENT" -ForegroundColor White
    Write-Host "  Loki URL:      $LOKI_URL" -ForegroundColor White
    Write-Host "  Channels:      $($LOG_CHANNELS -join ', ')" -ForegroundColor White
    if ($LOG_PATHS.Count -gt 0) {
        Write-Host "  File paths:    $($LOG_PATHS -join ', ')" -ForegroundColor White
    }
    Write-Host ""

    $confirm = if ($script:AutoConfirm) { "yes" } else { Read-Host "Confirm and continue? (y/n)" }
    if ($script:AutoConfirm) {
        Write-Host "  -> Auto-confirmed by environment" -ForegroundColor Cyan
    }
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Warn "Installation cancelled."
        Exit-WithPause 0
    }

    Write-Step "Preparing directories"
    New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $ALLOY_INSTALL_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $ALLOY_DATA_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $ALLOY_BOOKMARK_DIR | Out-Null
    Write-Success "Directories ready"

    if (-not (Confirm-OverwriteExistingConfig $CONFIG_FILE)) {
        Write-Warn "Installation cancelled to preserve existing collector config."
        Exit-WithPause 0
    }

    $backupPath = Backup-FileIfExists $CONFIG_FILE
    if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
        Write-Success "Existing config backed up: $backupPath"
    }

    $configContent = Build-AlloyConfig `
        -Channels $LOG_CHANNELS `
        -FilePaths $LOG_PATHS `
        -BookmarkDir $ALLOY_BOOKMARK_DIR `
        -MaxAgeMinutes $EVENTLOG_MAX_AGE_MINUTES `
        -InstanceName $INSTANCE_NAME `
        -Environment $ENVIRONMENT `
        -CustomerName $CUSTOMER_NAME `
        -LokiUrl $LOKI_URL

    [System.IO.File]::WriteAllText($CONFIG_FILE, $configContent, [System.Text.Encoding]::UTF8)
    Write-Success "Initial config written: $CONFIG_FILE"

    Write-Step "Downloading elven-logs-collector runtime"
    Write-Host "  Installer: $INSTALLER_URL" -ForegroundColor Gray
    if (-not (Download-WithRetry -Url $INSTALLER_URL -OutputPath $INSTALLER_PATH -MaxRetries 3)) {
        Write-Fail "Could not download collector runtime installer."
        Exit-WithPause 1
    }
    Unblock-File -Path $INSTALLER_PATH -ErrorAction SilentlyContinue
    Write-Success "Collector runtime installer downloaded"

    $shaDownloaded = Download-WithRetry -Url $SHA256SUMS_URL -OutputPath $SHA256SUMS_PATH -MaxRetries 2
    if (-not $shaDownloaded) {
        Remove-Item $SHA256SUMS_PATH -Force -ErrorAction SilentlyContinue
    }
    if (-not (Verify-Sha256 -FilePath $INSTALLER_PATH -Sha256SumsPath $SHA256SUMS_PATH -AssetName $INSTALLER_NAME)) {
        Exit-WithPause 1
    }

    Write-Step "Installing elven-logs-collector runtime"
    $installerArgumentList = @(
        "/S",
        "/CONFIG=`"$CONFIG_FILE`"",
        "/DISABLEREPORTING=yes",
        "/DISABLEPROFILING=yes",
        "/STABILITY=generally-available",
        "/FORCEREGISTRY=yes"
    ) -join " "

    Write-Host "  Running installer in silent mode..." -ForegroundColor Gray
    $installerProcess = Start-Process -FilePath $INSTALLER_PATH -ArgumentList $installerArgumentList -Wait -PassThru -ErrorAction Stop
    $installerExitCode = $installerProcess.ExitCode

    if ($null -eq $installerExitCode) {
        Write-Warn "Collector runtime installer did not report an exit code; checking installed files."
        Start-Sleep -Seconds 3
        $serviceAfterInstaller = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
        $resolvedAlloyExe = Resolve-AlloyExecutable -InstallDir $ALLOY_INSTALL_DIR
        if (-not [string]::IsNullOrWhiteSpace($resolvedAlloyExe)) {
            $ALLOY_EXE = $resolvedAlloyExe
        }

        if ((Test-Path $ALLOY_EXE) -and $serviceAfterInstaller) {
            Write-Success "Collector runtime appears installed despite missing installer exit code"
        } else {
            Write-Fail "Collector runtime installer did not report an exit code and installed files were not found."
            Write-Host "  Installer path: $INSTALLER_PATH" -ForegroundColor Yellow
            Write-Host "  Arguments: $installerArgumentList" -ForegroundColor Yellow
            Show-AlloyInstallDirectory -InstallDir $ALLOY_INSTALL_DIR
            Exit-WithPause 1
        }
    } elseif ($installerExitCode -ne 0 -and $installerExitCode -ne 3010) {
        Write-Fail "Collector runtime installer failed with exit code $installerExitCode."
        Write-Host "  Installer path: $INSTALLER_PATH" -ForegroundColor Yellow
        Write-Host "  Arguments: $installerArgumentList" -ForegroundColor Yellow
        Exit-WithPause 1
    }
    Write-Success "Collector runtime installer completed"

    Start-Sleep -Seconds 3
    $resolvedAlloyExe = Resolve-AlloyExecutable -InstallDir $ALLOY_INSTALL_DIR
    if (-not [string]::IsNullOrWhiteSpace($resolvedAlloyExe)) {
        $ALLOY_EXE = $resolvedAlloyExe
        Write-Success "Alloy executable found: $ALLOY_EXE"
    }

    $existingService = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($existingService -and $existingService.Status -eq "Running") {
        Write-Host "  Stopping service before applying Elven config..." -ForegroundColor Gray
        Stop-Service -Name $SERVICE_NAME -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Write-Step "Writing collector configuration"
    [System.IO.File]::WriteAllText($CONFIG_FILE, $configContent, [System.Text.Encoding]::UTF8)
    Write-Success "Config written: $CONFIG_FILE"

    Write-Step "Configuring collector service registry"
    $serviceEnvironment = @(
        "TENANT_ID=$TENANT_ID",
        "API_TOKEN=$API_TOKEN_PLAIN",
        "INSTANCE_NAME=$INSTANCE_NAME",
        "ENVIRONMENT=$ENVIRONMENT",
        "CUSTOMER_NAME=$CUSTOMER_NAME",
        "LOKI_URL=$LOKI_URL"
    )

    $serviceArguments = @(
        "run",
        "--server.http.listen-addr=127.0.0.1:12345",
        "--server.http.enable-pprof=false",
        "--disable-reporting",
        "--storage.path=$ALLOY_DATA_DIR",
        "--stability.level=generally-available",
        $CONFIG_FILE
    )

    Set-RegistryMultiString -Path $REGISTRY_PATH -Name "Environment" -Value $serviceEnvironment
    Set-RegistryMultiString -Path $REGISTRY_PATH -Name "Arguments" -Value $serviceArguments
    Write-Success "Service registry configured"

    $env:TENANT_ID = $TENANT_ID
    $env:API_TOKEN = $API_TOKEN_PLAIN
    $env:INSTANCE_NAME = $INSTANCE_NAME
    $env:ENVIRONMENT = $ENVIRONMENT
    $env:CUSTOMER_NAME = $CUSTOMER_NAME
    $env:LOKI_URL = $LOKI_URL

    Write-Step "Validating collector configuration"
    if (-not (Test-Path $ALLOY_EXE)) {
        Write-Fail "Alloy executable not found: $ALLOY_EXE"
        Show-AlloyInstallDirectory -InstallDir $ALLOY_INSTALL_DIR
        Exit-WithPause 1
    }

    $validateOutput = & $ALLOY_EXE validate "--stability.level=generally-available" $CONFIG_FILE 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Collector config validation failed."
        Write-Host $validateOutput -ForegroundColor Red
        Exit-WithPause 1
    }
    Write-Success "Collector config is valid"

    Write-Step "Starting collector service"
    $service = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Fail "Collector service was not found after installation."
        Exit-WithPause 1
    }

    sc.exe failure $SERVICE_NAME reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null

    $maxAttempts = 3
    $started = $false
    for ($attempt = 1; $attempt -le $maxAttempts -and -not $started; $attempt++) {
        Write-Host "  Start attempt $attempt of $maxAttempts..." -ForegroundColor Gray
        try {
            Start-Service -Name $SERVICE_NAME -ErrorAction Stop
            Start-Sleep -Seconds 5
            $service = Get-Service -Name $SERVICE_NAME
            if ($service.Status -eq "Running") {
                $started = $true
            }
        } catch {
            Write-Warn "Start attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }

    if (-not $started) {
        Write-Fail "Collector service did not start."
        Write-Host ""
        Write-Host "Recent Alloy-related events:" -ForegroundColor Yellow
        Get-WinEvent -LogName Application -MaxEvents 30 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'Alloy|Grafana' } |
            Select-Object -First 10 |
            ForEach-Object {
                Write-Host "  [$($_.TimeCreated)] $($_.LevelDisplayName): $($_.Message)" -ForegroundColor Red
            }
        Exit-WithPause 1
    }

    Write-Success "Collector service is running"

    Write-Host ""
    Write-Host "=== Installation complete ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "Files:" -ForegroundColor Yellow
    Write-Host "  Config:    $CONFIG_FILE" -ForegroundColor White
    Write-Host "  Data:      $ALLOY_DATA_DIR" -ForegroundColor White
    Write-Host "  Bookmarks: $ALLOY_BOOKMARK_DIR" -ForegroundColor White
    Write-Host ""
    Write-Host "Useful commands:" -ForegroundColor Yellow
    Write-Host "  Get-Service Alloy" -ForegroundColor Gray
    Write-Host "  Restart-Service Alloy" -ForegroundColor Gray
    Write-Host "  & `"$ALLOY_EXE`" validate --stability.level=generally-available `"$CONFIG_FILE`"" -ForegroundColor Gray
    Write-Host "  eventcreate /ID 1000 /L APPLICATION /T INFORMATION /SO ElvenLogsCollectorTest /D `"elven-logs-collector-test`"" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Grafana/Loki validation query:" -ForegroundColor Yellow
    Write-Host "  {job=`"elven-logs-collector`", source=`"windows`", host=`"$INSTANCE_NAME`", channel=`"Application`"}" -ForegroundColor White
    Write-Host ""

    Exit-WithPause 0
} catch {
    $errorMessage = $_.Exception.Message
    if ($errorMessage -match '^__ELVEN_LOGS_INSTALLER_EXIT__:(\d+)$') {
        $global:LASTEXITCODE = [int]$matches[1]
        return
    }

    Write-Fail "Unexpected error: $errorMessage"
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    $global:LASTEXITCODE = 1
    Wait-BeforeReturn
    return
}
