#Requires -RunAsAdministrator
# Dedicated Windows entrypoint: Windows Exporter -> local OTel Collector -> remote OTel Collector (OTLP/HTTP)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$baseInstallerUrl = "https://raw.githubusercontent.com/elven-observability/scripts/main/windows/windows-instrumentation.ps1"
$previousDestination = [Environment]::GetEnvironmentVariable("ELVEN_METRICS_DESTINATION", "Process")

try {
    $localInstaller = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { $null } else { Join-Path $PSScriptRoot "windows-instrumentation.ps1" }
    if ($localInstaller -and (Test-Path -LiteralPath $localInstaller -PathType Leaf)) {
        Write-Host "Using the local shared Windows instrumentation installer..." -ForegroundColor Cyan
        $installerContent = [IO.File]::ReadAllText($localInstaller)
    } else {
        Write-Host "Downloading the official Elven Windows instrumentation installer..." -ForegroundColor Cyan
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Elven-Observability-Installer")
        $installerContent = $webClient.DownloadString($baseInstallerUrl)
    }
    if ([string]::IsNullOrWhiteSpace($installerContent)) {
        throw "Downloaded installer is empty."
    }

    [Environment]::SetEnvironmentVariable("ELVEN_METRICS_DESTINATION", "collector", "Process")
    $global:LASTEXITCODE = 0
    & ([ScriptBlock]::Create($installerContent))

    if ($global:LASTEXITCODE -ne 0) {
        throw "Elven installer failed with exit code $global:LASTEXITCODE."
    }
} finally {
    [Environment]::SetEnvironmentVariable("ELVEN_METRICS_DESTINATION", $previousDestination, "Process")
}
