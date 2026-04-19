param(
    [string]$WorkspaceRoot,
    [string]$ProducerPayloadPath,
    [string]$RootDir,
    [string]$OutputDir,
    [switch]$UpdateBaseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if ([string]::IsNullOrWhiteSpace($RootDir)) {
    $RootDir = $WorkspaceRoot
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RootDir "artifacts"
}
if ([string]::IsNullOrWhiteSpace($ProducerPayloadPath)) {
    $ProducerPayloadPath = Join-Path $WorkspaceRoot "runtime\producer_payload.json"
}

$signalsPath = Join-Path $WorkspaceRoot "runtime\production_signals.json"
$writerScript = Join-Path $RootDir "ci\write_runtime_signals_from_producer.ps1"
$readinessScript = Join-Path $RootDir "ci\run_release_readiness.ps1"

if (-not (Test-Path $ProducerPayloadPath)) {
    throw "Missing producer payload input: $ProducerPayloadPath"
}

& $writerScript -WorkspaceRoot $WorkspaceRoot -ProducerPayloadPath $ProducerPayloadPath -OutputPath $signalsPath -Force

$readinessArgs = @{
    RootDir = $RootDir
    OutputDir = $OutputDir
    ProductionSignalsPath = $signalsPath
}
if ($UpdateBaseline) {
    $readinessArgs["UpdateBaseline"] = $true
}

& $readinessScript @readinessArgs
Write-Host "Producer->runtime->readiness orchestration completed."
