# ============================================
# INSTALAÇÃO MANUAL OPENTELEMETRY - SEM SECURSTRING
# ============================================
# INSTRUÇÕES:
# 1. Edite a linha $API_TOKEN abaixo e coloque o token real
# 2. Salve o arquivo
# 3. Execute: powershell -File install-otel-manual.ps1
# ============================================

# ==========================================
# CONFIGURAÇÃO - EDITAR AQUI!
# ==========================================
$TENANT_ID = "vibra-br-prd"
$API_TOKEN = "SEU_TOKEN_AQUI"  # ← MUDAR AQUI!
$MIMIR_ENDPOINT = "https://metrics.vibraenergia.com.br/api/v1/push"
$INSTANCE_NAME = $env:COMPUTERNAME
$ENVIRONMENT = "production"
$CUSTOMER = "vibra"
$OTEL_VERSION = "0.114.0"

# ==========================================
# NÃO PRECISA EDITAR DAQUI PRA BAIXO
# ==========================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenTelemetry Collector - Instalação Manual" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Verificar se é administrador
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "✗ Este script precisa ser executado como Administrador!" -ForegroundColor Red
    Write-Host "  Clique com botão direito no PowerShell → Executar como Administrador" -ForegroundColor Yellow
    pause
    exit 1
}

# Verificar token
if ($API_TOKEN -eq "SEU_TOKEN_AQUI") {
    Write-Host "✗ Você precisa editar o script e colocar o token real!" -ForegroundColor Red
    Write-Host "  Abra o script em um editor e mude a linha:" -ForegroundColor Yellow
    Write-Host '  $API_TOKEN = "SEU_TOKEN_AQUI"' -ForegroundColor White
    Write-Host ""
    pause
    exit 1
}

Write-Host "Configuração:" -ForegroundColor Yellow
Write-Host "  Tenant:      $TENANT_ID" -ForegroundColor White
Write-Host "  Instance:    $INSTANCE_NAME" -ForegroundColor White
Write-Host "  Environment: $ENVIRONMENT" -ForegroundColor White
Write-Host "  Endpoint:    $MIMIR_ENDPOINT" -ForegroundColor White
Write-Host ""

# 1. Verificar 7-Zip
Write-Host "[1/8] Verificando 7-Zip..." -ForegroundColor Cyan

$sevenZip = $null
if (Test-Path "C:\Program Files\7-Zip\7z.exe") {
    $sevenZip = "C:\Program Files\7-Zip\7z.exe"
    Write-Host "  ✓ Encontrado: $sevenZip" -ForegroundColor Green
} elseif (Test-Path "C:\Program Files (x86)\7-Zip\7z.exe") {
    $sevenZip = "C:\Program Files (x86)\7-Zip\7z.exe"
    Write-Host "  ✓ Encontrado: $sevenZip" -ForegroundColor Green
} else {
    Write-Host "  ✗ 7-Zip não encontrado!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Por favor, instale 7-Zip:" -ForegroundColor Yellow
    Write-Host "  1. Baixe de: https://www.7-zip.org/download.html" -ForegroundColor White
    Write-Host "  2. Instale o 7-Zip" -ForegroundColor White
    Write-Host "  3. Execute este script novamente" -ForegroundColor White
    Write-Host ""
    pause
    exit 1
}

# 2. Baixar OpenTelemetry
Write-Host ""
Write-Host "[2/8] Baixando OpenTelemetry Collector..." -ForegroundColor Cyan

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol-contrib_${OTEL_VERSION}_windows_amd64.tar.gz"
$downloadPath = "$env:TEMP\otelcol.tar.gz"

try {
    Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing -TimeoutSec 300
    $size = (Get-Item $downloadPath).Length / 1MB
    Write-Host "  ✓ Download completo! ($([math]::Round($size, 2)) MB)" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Erro no download: $($_.Exception.Message)" -ForegroundColor Red
    pause
    exit 1
}

# 3. Criar diretório
Write-Host ""
Write-Host "[3/8] Preparando diretório..." -ForegroundColor Cyan

$destDir = "C:\Program Files\OpenTelemetry Collector"

# Parar serviço se existir
$svc = Get-Service -Name "otelcol" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  → Parando serviço existente..." -ForegroundColor Yellow
    Stop-Service -Name "otelcol" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Remover diretório antigo
if (Test-Path $destDir) {
    Write-Host "  → Removendo instalação anterior..." -ForegroundColor Yellow
    Remove-Item $destDir -Recurse -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Criar novo diretório
New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Write-Host "  ✓ Diretório pronto: $destDir" -ForegroundColor Green

# 4. Extrair com 7-Zip
Write-Host ""
Write-Host "[4/8] Extraindo arquivos com 7-Zip..." -ForegroundColor Cyan

# Extrair .gz
Write-Host "  → Extraindo .gz..." -ForegroundColor Gray
& $sevenZip x "$downloadPath" -o"$env:TEMP" -y | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ✗ Erro ao extrair .gz!" -ForegroundColor Red
    pause
    exit 1
}

# Extrair .tar
$tarPath = "$env:TEMP\otelcol.tar"
Write-Host "  → Extraindo .tar..." -ForegroundColor Gray
& $sevenZip x "$tarPath" -o"$destDir" -y | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ✗ Erro ao extrair .tar!" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "  ✓ Extração completa!" -ForegroundColor Green

# Limpar temporários
Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue

# 5. Verificar executável
Write-Host ""
Write-Host "[5/8] Verificando executável..." -ForegroundColor Cyan

$exePath = "$destDir\otelcol-contrib.exe"
if (Test-Path $exePath) {
    Write-Host "  ✓ Executável encontrado!" -ForegroundColor Green
} else {
    Write-Host "  ✗ Executável não encontrado!" -ForegroundColor Red
    Write-Host "  Esperado: $exePath" -ForegroundColor Yellow
    pause
    exit 1
}

# 6. Criar configuração
Write-Host ""
Write-Host "[6/8] Criando configuração..." -ForegroundColor Cyan

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
        key: instance
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

# 7. Criar/Atualizar serviço
Write-Host ""
Write-Host "[7/8] Criando serviço..." -ForegroundColor Cyan

# Remover serviço existente
$svc = Get-Service -Name "otelcol" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  → Removendo serviço anterior..." -ForegroundColor Yellow
    Stop-Service -Name "otelcol" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    sc.exe delete otelcol | Out-Null
    Start-Sleep -Seconds 2
}

# Criar serviço
$binPath = "`"$exePath`" --config=`"$configPath`""
sc.exe create otelcol binPath= $binPath start= auto obj= LocalSystem DisplayName= "OpenTelemetry Collector" | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Serviço criado!" -ForegroundColor Green
    sc.exe description otelcol "OpenTelemetry Collector for metrics forwarding" | Out-Null
    sc.exe failure otelcol reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
} else {
    Write-Host "  ✗ Falha ao criar serviço!" -ForegroundColor Red
    pause
    exit 1
}

# 8. Iniciar serviço
Write-Host ""
Write-Host "[8/8] Iniciando serviço..." -ForegroundColor Cyan

Start-Service -Name "otelcol"
Start-Sleep -Seconds 3

$svc = Get-Service -Name "otelcol"

if ($svc.Status -eq 'Running') {
    Write-Host "  ✓ Serviço iniciado com sucesso!" -ForegroundColor Green
} else {
    Write-Host "  ✗ Serviço não iniciou!" -ForegroundColor Red
    Write-Host "  Status: $($svc.Status)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Verifique os logs com:" -ForegroundColor Yellow
    Write-Host "  Get-EventLog -LogName Application -Source otelcol -Newest 10" -ForegroundColor White
    Write-Host ""
    pause
    exit 1
}

# Resultado final
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "✅ INSTALAÇÃO COMPLETA!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Host "Status dos Serviços:" -ForegroundColor Cyan
Get-Service windows_exporter, otelcol -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize

Write-Host ""
Write-Host "Métricas:" -ForegroundColor Cyan
Write-Host "  Windows Exporter: http://localhost:9182/metrics" -ForegroundColor White
Write-Host ""
Write-Host "Dashboard:" -ForegroundColor Cyan
Write-Host "  https://grafana.elvenobservability.com" -ForegroundColor White
Write-Host ""

Write-Host "Pressione qualquer tecla para sair..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")