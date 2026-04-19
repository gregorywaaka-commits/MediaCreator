param(
    [string]$WorkspaceRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$samplePath = Join-Path $WorkspaceRoot "tests\producer_payload.sample.json"
$runtimeDir = Join-Path $WorkspaceRoot "runtime"
$runtimePayloadPath = Join-Path $runtimeDir "producer_payload.json"

if (-not (Test-Path $samplePath)) {
    throw "Missing producer payload sample: $samplePath"
}

New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

if ((Test-Path $runtimePayloadPath) -and -not $Force) {
    throw "Runtime producer payload already exists at $runtimePayloadPath. Re-run with -Force to overwrite."
}

Copy-Item -Path $samplePath -Destination $runtimePayloadPath -Force
Write-Host "Seeded runtime producer payload: $runtimePayloadPath"
