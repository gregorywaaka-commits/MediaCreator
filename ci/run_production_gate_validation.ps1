param(
    [string]$RootDir,
    [string]$OutputDir,
    [string]$SignalsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RootDir)) {
    $RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
else {
    $RootDir = (Resolve-Path $RootDir).Path
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RootDir "artifacts"
}
if ([string]::IsNullOrWhiteSpace($SignalsPath)) {
    throw "SignalsPath is required. Provide a real production gate signals JSON payload."
}

$thresholdsPath = Join-Path $RootDir "policy\thresholds_v1.json"
$schemaPath = Join-Path $RootDir "tests\production_signals.schema.json"
$signalsPathResolved = (Resolve-Path $SignalsPath).Path

if (-not (Test-Path $schemaPath)) {
    throw "Missing production signals schema: $schemaPath"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Assert-ExactKeys {
    param(
        [Parameter(Mandatory = $true)] [object]$Object,
        [Parameter(Mandatory = $true)] [string[]]$ExpectedKeys,
        [Parameter(Mandatory = $true)] [string]$Path
    )

    if ($null -eq $Object) {
        throw "Missing object at $Path"
    }

    $actual = @($Object.PSObject.Properties.Name)
    foreach ($key in $ExpectedKeys) {
        if ($actual -notcontains $key) {
            throw "Missing key '$key' at $Path"
        }
    }
    foreach ($key in $actual) {
        if ($ExpectedKeys -notcontains $key) {
            throw "Unknown key '$key' at $Path"
        }
    }
}

function Test-ReasonSubset {
    param(
        [string[]]$ExpectedReasons,
        [string[]]$ActualReasons
    )

    foreach ($r in $ExpectedReasons) {
        if ($ActualReasons -notcontains $r) {
            return $false
        }
    }
    return $true
}

function Get-ProductionDecision {
    param([object]$Signals)

    $decision = "pass"
    $reasons = New-Object System.Collections.Generic.List[string]

    $isRestricted = @("licensed", "protected") -contains $Signals.release_class
    $gate = $Signals.gate_results

    if ($isRestricted -and $gate.compliance -eq "fail") {
        $decision = "block_release"
        $reasons.Add("compliance_fail_restricted_block") | Out-Null
    }

    if ($isRestricted -and $gate.documentation -eq "fail") {
        $decision = "block_release"
        $reasons.Add("missing_docs_restricted_block") | Out-Null
    }

    if (-not $isRestricted -and $gate.documentation -eq "fail" -and @("pass", "warn") -contains $decision) {
        $decision = "warn"
        $reasons.Add("missing_docs_open_warn") | Out-Null
    }

    if (-not $isRestricted -and $gate.compliance -eq "fail" -and $decision -eq "pass") {
        $decision = "hold"
        $reasons.Add("compliance_fail_open_hold_for_review") | Out-Null
    }

    if ($gate.robustness -eq "fail" -and $decision -eq "pass") {
        $decision = "hold"
        $reasons.Add("ood_fail_conditional_hold") | Out-Null
    }

    if ($isRestricted -and $gate.watermark -eq "fail" -and $decision -eq "pass") {
        $decision = "warn"
        $reasons.Add("watermark_second_failure_warn") | Out-Null
    }

    if (-not $isRestricted -and $gate.watermark -eq "fail" -and $decision -eq "pass") {
        $decision = "warn"
        $reasons.Add("watermark_second_failure_warn") | Out-Null
    }

    if ($Signals.break_glass.used -eq $true) {
        if ($Signals.break_glass.approved_by_owner -eq $true) {
            if ($decision -eq "block_release") {
                $decision = "warn"
            }
            elseif ($decision -eq "hold") {
                $decision = "warn"
            }
            $reasons.Add("break_glass_owner_override") | Out-Null
        }
        else {
            $decision = "block_release"
            $reasons.Add("break_glass_denied_non_owner") | Out-Null
        }
    }

    if ($Signals.gate_results.quality -eq "pass" -and $Signals.gate_results.compliance -eq "fail" -and $isRestricted) {
        $reasons.Add("tie_break_safety_over_quality") | Out-Null
    }

    if ($reasons.Count -eq 0) {
        $reasons.Add("all_required_gates_passed") | Out-Null
    }

    return [pscustomobject]@{
        decision = $decision
        reasons = @($reasons)
    }
}

$signals = Get-Content -Raw -Path $signalsPathResolved | ConvertFrom-Json
$thresholds = Get-Content -Raw -Path $thresholdsPath | ConvertFrom-Json

Assert-ExactKeys -Object $signals -ExpectedKeys @("request_id", "release_class", "run_mode", "policy_version", "expected_decision", "expected_reason_codes_contains", "break_glass", "gate_results") -Path "signals"
Assert-ExactKeys -Object $signals.break_glass -ExpectedKeys @("used", "approved_by_owner", "ticket_id", "reason") -Path "signals.break_glass"

$expectedGateKeys = @("quality", "deconstruction", "robustness", "leakage", "compliance", "documentation", "watermark")
Assert-ExactKeys -Object $signals.gate_results -ExpectedKeys $expectedGateKeys -Path "signals.gate_results"

if (@("open", "licensed", "protected") -notcontains $signals.release_class) {
    throw "Invalid release_class: $($signals.release_class)"
}
if (@("draft", "production") -notcontains $signals.run_mode) {
    throw "Invalid run_mode: $($signals.run_mode)"
}

foreach ($k in $expectedGateKeys) {
    if (@("pass", "warn", "fail") -notcontains $signals.gate_results.$k) {
        throw "Invalid gate result for '$k': $($signals.gate_results.$k)"
    }
}

$evaluation = Get-ProductionDecision -Signals $signals
$policyHash = (Get-FileHash -Path $thresholdsPath -Algorithm SHA256).Hash.ToLowerInvariant()
$policyVersion = if ([string]::IsNullOrWhiteSpace($signals.policy_version)) { $thresholds.name } else { $signals.policy_version }

$gateReport = [ordered]@{
    request_id = $signals.request_id
    policy_version = "$policyVersion+sha256:$policyHash"
    release_class = $signals.release_class
    decision = $evaluation.decision
    decision_reasons = $evaluation.reasons
    gate_results = $signals.gate_results
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$expectedDecision = if ([string]::IsNullOrWhiteSpace($signals.expected_decision)) { $evaluation.decision } else { $signals.expected_decision }
$expectedReasons = if ($null -eq $signals.expected_reason_codes_contains) { @() } else { @($signals.expected_reason_codes_contains) }

$reasonMatches = Test-ReasonSubset -ExpectedReasons $expectedReasons -ActualReasons $evaluation.reasons
$decisionMatches = $evaluation.decision -eq $expectedDecision

$productionResults = [ordered]@{
    policy_hash = $policyHash
    signals_file = $signalsPathResolved
    total_cases = 1
    passed_cases = if ($decisionMatches -and $reasonMatches) { 1 } else { 0 }
    failed_cases = if ($decisionMatches -and $reasonMatches) { 0 } else { 1 }
    cases = @(
        [ordered]@{
            id = $signals.request_id
            release_class = $signals.release_class
            expected_decision = $expectedDecision
            actual_decision = $evaluation.decision
            expected_reasons = $expectedReasons
            actual_reasons = $evaluation.reasons
            passed = ($decisionMatches -and $reasonMatches)
        }
    )
}

$reportPath = Join-Path $OutputDir "production_gate_report.json"
$reportMdPath = Join-Path $OutputDir "production_gate_report.md"
$resultsPath = Join-Path $OutputDir "production_results.json"

$gateReport | ConvertTo-Json -Depth 12 | Set-Content -Path $reportPath -Encoding UTF8
$productionResults | ConvertTo-Json -Depth 12 | Set-Content -Path $resultsPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Production Gate Report")
$lines.Add("")
$lines.Add("- Request ID: $($signals.request_id)")
$lines.Add("- Decision: $($evaluation.decision)")
$lines.Add("- Release class: $($signals.release_class)")
$lines.Add("- Policy: $($gateReport.policy_version)")
$lines.Add("- Signals source: $signalsPathResolved")
$lines.Add("")
$lines.Add("## Reasons")
$lines.Add("")
foreach ($r in $evaluation.reasons) {
    $lines.Add("- $r")
}
$lines.Add("")
$lines.Add("## Gate Inputs")
$lines.Add("")
foreach ($k in $expectedGateKeys) {
    $lines.Add("- ${k}: $($signals.gate_results.$k)")
}
$lines | Set-Content -Path $reportMdPath -Encoding UTF8

if (-not ($decisionMatches -and $reasonMatches)) {
    throw "Production gate validation failed expected contract for request '$($signals.request_id)'"
}

Write-Host "Production gate validation passed. Artifacts written to: $OutputDir"
