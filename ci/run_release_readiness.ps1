param(
    [string]$RootDir,
    [string]$OutputDir,
    [string]$ProductionSignalsPath,
    [switch]$UseSampleSignals,
    [switch]$UpdateBaseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RootDir)) {
    $RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RootDir "artifacts"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$dryScript = Join-Path $PSScriptRoot "run_dry_run_gate_validation.ps1"
$productionScript = Join-Path $PSScriptRoot "run_production_gate_validation.ps1"
$driftScript = Join-Path $PSScriptRoot "run_policy_drift_audit.ps1"
$replayScript = Join-Path $PSScriptRoot "run_replay_validation.ps1"

$productionPath = Join-Path $OutputDir "production_results.json"
$prevPath = Join-Path $OutputDir "production_results.prev.json"
$baselinePath = Join-Path $OutputDir "production_results.baseline.json"

if (Test-Path $productionPath) {
    Copy-Item -Force -Path $productionPath -Destination $prevPath
}

$steps = New-Object System.Collections.Generic.List[object]

function Add-Step {
    param([string]$Name, [string]$Status, [string]$Details)
    $steps.Add([pscustomobject]@{ name = $Name; status = $Status; details = $Details }) | Out-Null
}

try {
    & $dryScript -RootDir $RootDir -OutputDir $OutputDir
    Add-Step -Name "golden_vector_contract_validation" -Status "pass" -Details "Dry-run validator completed"
}
catch {
    Add-Step -Name "golden_vector_contract_validation" -Status "fail" -Details $_.Exception.Message
}

$signalsPathToUse = $ProductionSignalsPath
if ([string]::IsNullOrWhiteSpace($signalsPathToUse) -and $UseSampleSignals) {
    $signalsPathToUse = Join-Path $RootDir "tests\production_signals.sample.json"
}

if ([string]::IsNullOrWhiteSpace($signalsPathToUse)) {
    Add-Step -Name "production_gate_validation" -Status "fail" -Details "Missing ProductionSignalsPath (or set -UseSampleSignals for local smoke runs)"
}
else {
    try {
        & $productionScript -RootDir $RootDir -OutputDir $OutputDir -SignalsPath $signalsPathToUse
        Add-Step -Name "production_gate_validation" -Status "pass" -Details "Production validator completed"
    }
    catch {
        Add-Step -Name "production_gate_validation" -Status "fail" -Details $_.Exception.Message
    }
}

try {
    & $driftScript -RootDir $RootDir -OutputDir $OutputDir
    Add-Step -Name "policy_drift_audit" -Status "pass" -Details "Policy drift audit completed"
}
catch {
    Add-Step -Name "policy_drift_audit" -Status "fail" -Details $_.Exception.Message
}

$replayComparePath = if (Test-Path $prevPath) { $prevPath } elseif (Test-Path $baselinePath) { $baselinePath } else { "" }
try {
    & $replayScript -CurrentRunPath $productionPath -PreviousRunPath $replayComparePath -OutputDir $OutputDir
    Add-Step -Name "replay_validation" -Status "pass" -Details "Replay validation completed"
}
catch {
    Add-Step -Name "replay_validation" -Status "fail" -Details $_.Exception.Message
}

$failedSteps = @($steps | Where-Object { $_.status -eq "fail" })
$overallPass = $failedSteps.Count -eq 0

if ($UpdateBaseline -and $overallPass -and (Test-Path $productionPath)) {
    Copy-Item -Force -Path $productionPath -Destination $baselinePath
    Add-Step -Name "baseline_update" -Status "pass" -Details "Baseline updated"
}

$readiness = [ordered]@{
    audit = "release_readiness"
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
    decision = if ($overallPass) { "pass" } else { "block_release" }
    reason_codes = if ($overallPass) { @("all_readiness_checks_passed") } else { @($failedSteps | ForEach-Object { "step_failed:$($_.name)" }) }
    steps = $steps
}

$jsonPath = Join-Path $OutputDir "release_readiness.json"
$mdPath = Join-Path $OutputDir "release_readiness.md"

$readiness | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Release Readiness")
$lines.Add("")
$lines.Add("- Decision: $($readiness.decision)")
$lines.Add("- Timestamp: $($readiness.timestamp_utc)")
$lines.Add("- Reason codes: $([string]::Join(', ', $readiness.reason_codes))")
$lines.Add("")
$lines.Add("## Steps")
$lines.Add("")
foreach ($s in $steps) {
    $tag = if ($s.status -eq "pass") { "PASS" } else { "FAIL" }
    $lines.Add("- [$tag] $($s.name): $($s.details)")
}
$lines | Set-Content -Path $mdPath -Encoding UTF8

if (-not $overallPass) {
    throw "Release readiness failed. See $jsonPath"
}

Write-Host "Release readiness passed. Artifacts written to: $OutputDir"
