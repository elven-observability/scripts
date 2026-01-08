# ============================================
# INSTALAÇÃO OPENTELEMETRY - POWERSHELL 4.0 COMPATIBLE
# ============================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenTelemetry Collector - Instalação" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Verificar administrador
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "✗ Execute como Administrador!" -ForegroundColor Red
    pause
    exit 1
}

# Configuração
Write-Host "CONFIGURAÇÃO:" -ForegroundColor Yellow
Write-Host ""

$TENANT_ID = Read-Host "Enter Tenant ID (e.g., vibra-br-prd)"

# Ler token SEM SecureString (compatível com PS 4.0)
Write-Host "Enter API Token: " -NoNewline -ForegroundColor White
$API_TOKEN = ""
do {
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    if ($key.VirtualKeyCode -eq 13) { break }  # Enter
    if ($key.VirtualKeyCode -eq 8) {  # Backspace
        if ($API_TOKEN.Length -gt 0) {
            $API_TOKEN = $API_TOKEN.Substring(0, $API_TOKEN.Length - 1)
            Write-Host "`b `b" -NoNewline
        }
    } else {
        $API_TOKEN += $key.Character
        Write-Host "*" -NoNewline
    }
} while ($true)
Write-Host ""

$MIMIR_ENDPOINT = Read-Host "Enter Mimir Endpoint (e.g., https://metrics.vibraenergia.com.br/api/v1/push)"
$INSTANCE_NAME = Read-Host "Enter Instance Name ($($env:COMPUTERNAME))"
if ([string]::IsNullOrEmpty($INSTANCE_NAME)) { $INSTANCE_NAME = $env:COMPUTERNAME }
$ENVIRONMENT = Read-Host "Enter Environment (production/staging/development)"
$CUSTOMER = Read-Host "Enter Customer name (e.g., vibra)"

Write-Host ""
Write-Host "Confirm? (y/n): " -NoNewline -ForegroundColor Yellow
$confirm = Read-Host
if ($confirm -ne 'y') {
    Write-Host "Cancelled." -ForegroundColor Red
    exit 0
}

# Verificar 7-Zip
Write-Host ""
Write-Host "[1/7] Verificando 7-Zip..." -ForegroundColor Cyan

$sevenZip = $null
if (Test-Path "C:\Program Files\7-Zip\7z.exe") {
    $sevenZip = "C:\Program Files\7-Zip\7z.exe"
} elseif (Test-Path "C:\Program Files (x86)\7-Zip\7z.exe") {
    $sevenZip = "C:\Program Files (x86)\7-Zip\7z.exe"
} else {
    Write-Host "  ✗ 7-Zip não encontrado!" -ForegroundColor Red
    Write-Host "  Instale de: https://www.7-zip.org/" -ForegroundColor Yellow
    pause
    exit 1
}
Write-Host "  ✓ Encontrado: $sevenZip" -ForegroundColor Green

# Baixar
Write-Host ""
Write-Host "[2/7] Baixando OpenTelemetry..." -ForegroundColor Cyan

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.114.0/otelcol-contrib_0.114.0_windows_amd64.tar.gz"
$downloadPath = "$env:TEMP\otelcol.tar.gz"

Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing
$size = (Get-Item $downloadPath).Length / 1MB
Write-Host "  ✓ Download completo! ($([math]::Round($size, 2)) MB)" -ForegroundColor Green

# Preparar diretório
Write-Host ""
Write-Host "[3/7] Preparando diretório..." -ForegroundColor Cyan

$destDir = "C:\Program Files\OpenTelemetry Collector"

$svc = Get-Service -Name "otelcol" -ErrorAction SilentlyContinue
if ($svc) {
    Stop-Service -Name "otelcol" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

if (Test-Path $destDir) {
    Remove-Item $destDir -Recurse -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Write-Host "  ✓ Diretório pronto!" -ForegroundColor Green

# Extrair
Write-Host ""
Write-Host "[4/7] Extraindo com 7-Zip..." -ForegroundColor Cyan

& $sevenZip x "$downloadPath" -o"$env:TEMP" -y | Out-Null
$tarPath = "$env:TEMP\otelcol.tar"
& $sevenZip x "$tarPath" -o"$destDir" -y | Out-Null

if (Test-Path "$destDir\otelcol-contrib.exe") {
    Write-Host "  ✓ Extração completa!" -ForegroundColor Green
} else {
    Write-Host "  ✗ Executável não encontrado!" -ForegroundColor Red
    pause
    exit 1
}

Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue

# Configuração
Write-Host ""
Write-Host "[5/7] Criando configuração..." -ForegroundColor Cyan

$config = @"
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
      Authorization: "Bearer $API_TOKEN"
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
        value: "$ENVIRONMENT"
      - action: insert
        key: customer
        value: "$CUSTOMER"
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

$configPath = "$destDir\config.yaml"
$config | Out-File -FilePath $configPath -Encoding UTF8
Write-Host "  ✓ Configuração criada!" -ForegroundColor Green

# Criar serviço
Write-Host ""
Write-Host "[6/7] Criando serviço..." -ForegroundColor Cyan

$svc = Get-Service -Name "otelcol" -ErrorAction SilentlyContinue
if ($svc) {
    Stop-Service -Name "otelcol" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    sc.exe delete otelcol | Out-Null
    Start-Sleep -Seconds 2
}

$exePath = "$destDir\otelcol-contrib.exe"
$binPath = "`"$exePath`" --config=`"$configPath`""
sc.exe create otelcol binPath= $binPath start= auto obj= LocalSystem DisplayName= "OpenTelemetry Collector" | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Serviço criado!" -ForegroundColor Green
    sc.exe description otelcol "OpenTelemetry Collector" | Out-Null
} else {
    Write-Host "  ✗ Falha ao criar serviço!" -ForegroundColor Red
    pause
    exit 1
}

# Iniciar
Write-Host ""
Write-Host "[7/7] Iniciando serviço..." -ForegroundColor Cyan

Start-Service -Name "otelcol"
Start-Sleep -Seconds 3

$svc = Get-Service -Name "otelcol"

if ($svc.Status -eq 'Running') {
    Write-Host "  ✓ Serviço rodando!" -ForegroundColor Green
} else {
    Write-Host "  ✗ Serviço não iniciou!" -ForegroundColor Red
    Write-Host "  Status: $($svc.Status)" -ForegroundColor Yellow
    pause
    exit 1
}

# Resultado
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "✅ INSTALAÇÃO COMPLETA!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Get-Service windows_exporter, otelcol -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType

Write-Host ""
pause