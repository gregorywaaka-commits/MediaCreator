param(
    [string]$WorkspaceRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

$samplePath = Join-Path $WorkspaceRoot "tests\production_signals.sample.json"
$runtimeDir = Join-Path $WorkspaceRoot "runtime"
$runtimePath = Join-Path $runtimeDir "production_signals.json"

if (-not (Test-Path $samplePath)) {
    throw "Missing sample signals file: $samplePath"
}

New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

if ((Test-Path $runtimePath) -and -not $Force) {
    throw "Runtime signals already exist at $runtimePath. Re-run with -Force to overwrite."
}

Copy-Item -Path $samplePath -Destination $runtimePath -Force
Write-Host "Seeded runtime signals file: $runtimePath"
