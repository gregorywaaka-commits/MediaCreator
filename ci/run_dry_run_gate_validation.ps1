param(
    [string]$RootDir,
    [string]$OutputDir
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

$thresholdsPath = Join-Path $RootDir "policy\thresholds_v1.json"
$releasePolicyPath = Join-Path $RootDir "config\release_class_policy.template.yaml"
$runtimeDefaultsPath = Join-Path $RootDir "config\runtime_defaults.template.yaml"
$goldenVectorsPath = Join-Path $RootDir "tests\golden_vectors_v1.json"
$goldenSchemaPath = Join-Path $RootDir "tests\golden_vectors.schema.json"
$reportSchemaPath = Join-Path $RootDir "reports\gate_report.schema.json"

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

function Parse-SimpleYaml {
    param([string]$Path)

    $lines = Get-Content -Path $Path
    $stack = @([pscustomobject]@{ Indent = -1; Path = "" })
    $scalars = @{}
    $lists = @{}

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*#') { continue }

        if ($line -match '^(\s*)-\s*(.+)$') {
            $indent = $Matches[1].Length
            while ($stack.Count -gt 0 -and $stack[-1].Indent -ge $indent) {
                $stack = @($(if ($stack.Count -gt 1) { $stack[0..($stack.Count - 2)] } else { @() }))
            }
            $parentPath = if ($stack.Count -gt 0) { $stack[-1].Path } else { "" }
            if ([string]::IsNullOrWhiteSpace($parentPath)) {
                throw "List item found without parent context in ${Path}: $rawLine"
            }
            if (-not $lists.ContainsKey($parentPath)) {
                $lists[$parentPath] = New-Object System.Collections.Generic.List[string]
            }
            $lists[$parentPath].Add($Matches[2].Trim()) | Out-Null
            continue
        }

        if ($line -match '^(\s*)([A-Za-z0-9_]+):(?:\s*(.+))?$') {
            $indent = $Matches[1].Length
            $key = $Matches[2]
            $value = $Matches[3]

            while ($stack.Count -gt 0 -and $stack[-1].Indent -ge $indent) {
                $stack = @($(if ($stack.Count -gt 1) { $stack[0..($stack.Count - 2)] } else { @() }))
            }

            $parentPath = if ($stack.Count -gt 0) { $stack[-1].Path } else { "" }
            $pathKey = if ([string]::IsNullOrWhiteSpace($parentPath)) { $key } else { "$parentPath.$key" }

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $scalars[$pathKey] = $value.Trim()
            }

            $stack += [pscustomobject]@{ Indent = $indent; Path = $pathKey }
            continue
        }

        throw "Unsupported YAML shape in ${Path}: $rawLine"
    }

    return [pscustomobject]@{
        Scalars = $scalars
        Lists = $lists
    }
}

function Assert-GoldenVectorsShape {
    param([object]$Vectors)

    if ($null -eq $Vectors) { throw "Golden vectors payload is null" }
    if ($Vectors.version -lt 1) { throw "Golden vectors version must be >= 1" }
    if ($null -eq $Vectors.cases -or @($Vectors.cases).Count -lt 1) { throw "Golden vectors must include at least one case" }

    foreach ($case in $Vectors.cases) {
        if ([string]::IsNullOrWhiteSpace($case.id)) { throw "Golden vector case id is required" }
        if (@("open", "licensed", "protected") -notcontains $case.release_class) {
            throw "Golden vector '$($case.id)' has invalid release_class: $($case.release_class)"
        }
        foreach ($signal in @("missing_docs", "compliance_fail", "watermark_fail_twice", "quality_pass")) {
            if (-not $case.signals.PSObject.Properties.Name.Contains($signal)) {
                throw "Golden vector '$($case.id)' missing signal: $signal"
            }
        }
        if (@("pass", "hold", "warn", "block_release") -notcontains $case.expected.decision) {
            throw "Golden vector '$($case.id)' has invalid expected decision: $($case.expected.decision)"
        }
    }
}

function Assert-GateReportShape {
    param([object]$Report)

    foreach ($required in @("request_id", "policy_version", "release_class", "decision", "decision_reasons", "gate_results", "timestamp_utc")) {
        if (-not $Report.PSObject.Properties.Name.Contains($required)) {
            throw "gate_report.json missing required key: $required"
        }
    }

    if (@("open", "licensed", "protected") -notcontains $Report.release_class) {
        throw "gate_report.json has invalid release_class: $($Report.release_class)"
    }
    if (@("pass", "hold", "warn", "block_release") -notcontains $Report.decision) {
        throw "gate_report.json has invalid decision: $($Report.decision)"
    }
    if ($null -eq $Report.decision_reasons -or @($Report.decision_reasons).Count -lt 1) {
        throw "gate_report.json must contain at least one decision reason"
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

function Evaluate-Case {
    param([object]$Case)

    $decision = "pass"
    $reasons = New-Object System.Collections.Generic.List[string]

    $isRestricted = @("licensed", "protected") -contains $Case.release_class

    if ($Case.signals.compliance_fail -and $isRestricted) {
        $decision = "block_release"
        $reasons.Add("compliance_fail_restricted_block")
    }

    if ($Case.signals.missing_docs -and $isRestricted) {
        $decision = "block_release"
        $reasons.Add("missing_docs_restricted_block")
    }

    if ($Case.signals.compliance_fail -and -not $isRestricted -and $decision -eq "pass") {
        $decision = "hold"
        $reasons.Add("compliance_fail_open_hold_for_review")
    }

    if ($Case.signals.missing_docs -and -not $isRestricted -and @("pass", "warn") -contains $decision) {
        $decision = "warn"
        $reasons.Add("missing_docs_open_warn")
    }

    if ($Case.signals.watermark_fail_twice) {
        if ($isRestricted) {
            if ($decision -eq "pass") {
                $decision = "warn"
            }
            $reasons.Add("watermark_second_failure_warn")
        }
        elseif ($decision -eq "pass") {
            $decision = "warn"
            $reasons.Add("watermark_second_failure_warn")
        }
    }

    if ($Case.signals.quality_pass -and $Case.signals.compliance_fail -and $isRestricted) {
        $reasons.Add("tie_break_safety_over_quality")
    }

    if ($reasons.Count -eq 0) {
        $reasons.Add("all_required_gates_passed")
    }

    $reasonsArray = @($reasons)
    $decisionMatches = $decision -eq $Case.expected.decision
    $reasonMatches = Test-ReasonSubset -ExpectedReasons @($Case.expected.reason_codes_contains) -ActualReasons $reasonsArray

    return [pscustomobject]@{
        id = $Case.id
        release_class = $Case.release_class
        expected_decision = $Case.expected.decision
        actual_decision = $decision
        expected_reasons = @($Case.expected.reason_codes_contains)
        actual_reasons = $reasonsArray
        passed = ($decisionMatches -and $reasonMatches)
    }
}

$thresholds = Get-Content -Raw -Path $thresholdsPath | ConvertFrom-Json
$releaseYaml = Parse-SimpleYaml -Path $releasePolicyPath
$runtimeYaml = Parse-SimpleYaml -Path $runtimeDefaultsPath

$goldenVectorsRaw = Get-Content -Raw -Path $goldenVectorsPath
$goldenVectors = $goldenVectorsRaw | ConvertFrom-Json
Assert-GoldenVectorsShape -Vectors $goldenVectors

$allowedReleaseKeys = @(
    "version",
    "release_class_policy",
    "release_class_policy.allowed_values",
    "release_class_policy.defaults",
    "release_class_policy.defaults.release_class",
    "release_class_policy.missing_documentation",
    "release_class_policy.missing_documentation.open",
    "release_class_policy.missing_documentation.licensed",
    "release_class_policy.missing_documentation.protected",
    "release_class_policy.compliance_fail_behavior",
    "release_class_policy.compliance_fail_behavior.open",
    "release_class_policy.compliance_fail_behavior.licensed",
    "release_class_policy.compliance_fail_behavior.protected",
    "release_class_policy.watermark_checks_required_for",
    "release_class_policy.watermark_failure",
    "release_class_policy.watermark_failure.retry_attempts",
    "release_class_policy.watermark_failure.on_second_failure",
    "release_class_policy.break_glass",
    "release_class_policy.break_glass.allowed_roles",
    "release_class_policy.break_glass.requires_reason",
    "release_class_policy.break_glass.requires_ticket_id"
)

$releaseScalarKeys = @($releaseYaml.Scalars.Keys)
foreach ($k in $releaseScalarKeys) {
    if ($allowedReleaseKeys -notcontains $k) {
        throw "Unknown key in release_class_policy template: $k"
    }
}

foreach ($requiredKey in @("version", "release_class_policy.defaults.release_class", "release_class_policy.missing_documentation.open", "release_class_policy.missing_documentation.licensed", "release_class_policy.missing_documentation.protected", "release_class_policy.watermark_failure.retry_attempts", "release_class_policy.watermark_failure.on_second_failure")) {
    if (-not $releaseYaml.Scalars.ContainsKey($requiredKey)) {
        throw "Missing required key in release_class_policy template: $requiredKey"
    }
}

$allowedRuntimeKeys = @(
    "version",
    "runtime_defaults",
    "runtime_defaults.post_stack_intensity",
    "runtime_defaults.second_pass_cfg",
    "runtime_defaults.second_pass_cfg.auto_delta_enabled",
    "runtime_defaults.second_pass_steps",
    "runtime_defaults.second_pass_steps.max_increase_percent",
    "runtime_defaults.sampler_scheduler",
    "runtime_defaults.sampler_scheduler.draft",
    "runtime_defaults.sampler_scheduler.production",
    "runtime_defaults.manual_polish",
    "runtime_defaults.manual_polish.required",
    "runtime_defaults.manual_polish.recommended",
    "runtime_defaults.source_ledger_strictness",
    "runtime_defaults.source_ledger_strictness.draft_open",
    "runtime_defaults.source_ledger_strictness.production",
    "runtime_defaults.attribution_leak_policy",
    "runtime_defaults.attribution_leak_policy.draft_open",
    "runtime_defaults.attribution_leak_policy.production",
    "runtime_defaults.style_influence_high",
    "runtime_defaults.style_influence_high.action",
    "runtime_defaults.leak_test",
    "runtime_defaults.leak_test.production_target_samples",
    "runtime_defaults.leak_test.constrained_floor_samples"
)

$runtimeScalarKeys = @($runtimeYaml.Scalars.Keys)
foreach ($k in $runtimeScalarKeys) {
    if ($allowedRuntimeKeys -notcontains $k) {
        throw "Unknown key in runtime_defaults template: $k"
    }
}

foreach ($requiredKey in @("version", "runtime_defaults.post_stack_intensity", "runtime_defaults.second_pass_cfg.auto_delta_enabled", "runtime_defaults.second_pass_steps.max_increase_percent", "runtime_defaults.leak_test.production_target_samples", "runtime_defaults.leak_test.constrained_floor_samples")) {
    if (-not $runtimeYaml.Scalars.ContainsKey($requiredKey)) {
        throw "Missing required key in runtime_defaults template: $requiredKey"
    }
}

if ($releaseYaml.Scalars["release_class_policy.missing_documentation.open"] -ne "warn") {
    throw "Locked policy mismatch: open missing documentation must be 'warn'"
}
if ($releaseYaml.Scalars["release_class_policy.missing_documentation.licensed"] -ne "block_release") {
    throw "Locked policy mismatch: licensed missing documentation must be 'block_release'"
}
if ($releaseYaml.Scalars["release_class_policy.missing_documentation.protected"] -ne "block_release") {
    throw "Locked policy mismatch: protected missing documentation must be 'block_release'"
}
if ([int]$releaseYaml.Scalars["release_class_policy.watermark_failure.retry_attempts"] -ne 1) {
    throw "Locked policy mismatch: watermark retry_attempts must be 1"
}
if ($releaseYaml.Scalars["release_class_policy.watermark_failure.on_second_failure"] -ne "warn") {
    throw "Locked policy mismatch: watermark on_second_failure must be 'warn'"
}
if ([int]$runtimeYaml.Scalars["runtime_defaults.second_pass_steps.max_increase_percent"] -ne $thresholds.runtime_defaults.second_pass.step_cap_percent) {
    throw "Locked policy mismatch: second pass step cap differs from thresholds"
}
if ([int]$runtimeYaml.Scalars["runtime_defaults.leak_test.production_target_samples"] -ne $thresholds.leakage.memorization_stress_test.min_generated_samples) {
    throw "Locked policy mismatch: production leak test target differs from thresholds"
}
if ([int]$runtimeYaml.Scalars["runtime_defaults.leak_test.constrained_floor_samples"] -ne $thresholds.leakage.memorization_stress_test.constrained_min_generated_samples) {
    throw "Locked policy mismatch: constrained leak floor differs from thresholds"
}

$results = @()
foreach ($case in $goldenVectors.cases) {
    $results += Evaluate-Case -Case $case
}

$allPassed = @($results | Where-Object { -not $_.passed }).Count -eq 0
$policyHash = (Get-FileHash -Path $thresholdsPath -Algorithm SHA256).Hash.ToLowerInvariant()

$gateResults = [ordered]@{
    strict_config_validation = $(if ($allPassed) { "pass" } else { "fail" })
    golden_vectors = $(if ($allPassed) { "pass" } else { "fail" })
    dry_run_evaluation = $(if ($allPassed) { "pass" } else { "fail" })
}

$topReasons = @()
if ($allPassed) {
    $topReasons = @("all_golden_vectors_passed")
}
else {
    $topReasons = @("golden_vector_mismatch_detected")
}

$gateReport = [ordered]@{
    request_id = "prepared-pack-dry-run"
    policy_version = "$($thresholds.name)+sha256:$policyHash"
    release_class = "open"
    decision = $(if ($allPassed) { "pass" } else { "block_release" })
    decision_reasons = $topReasons
    gate_results = $gateResults
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$gateReportPath = Join-Path $OutputDir "gate_report.json"
$dryRunPath = Join-Path $OutputDir "dry_run_results.json"
$markdownPath = Join-Path $OutputDir "gate_report.md"

$gateReport | ConvertTo-Json -Depth 12 | Set-Content -Path $gateReportPath -Encoding UTF8

$dryRun = [ordered]@{
    policy_hash = $policyHash
    vectors_file = $goldenVectorsPath
    total_cases = $results.Count
    passed_cases = @($results | Where-Object { $_.passed }).Count
    failed_cases = @($results | Where-Object { -not $_.passed }).Count
    cases = $results
}
$dryRun | ConvertTo-Json -Depth 12 | Set-Content -Path $dryRunPath -Encoding UTF8

$reportJsonRaw = Get-Content -Raw -Path $gateReportPath
$reportParsed = $reportJsonRaw | ConvertFrom-Json
Assert-GateReportShape -Report $reportParsed

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Gate Report")
$lines.Add("")
$lines.Add("- Decision: $($gateReport.decision)")
$lines.Add("- Policy: $($gateReport.policy_version)")
$lines.Add("- Total vectors: $($dryRun.total_cases)")
$lines.Add("- Passed vectors: $($dryRun.passed_cases)")
$lines.Add("- Failed vectors: $($dryRun.failed_cases)")
$lines.Add("")
$lines.Add("## Case Results")
$lines.Add("")
foreach ($r in $results) {
    $status = if ($r.passed) { "PASS" } else { "FAIL" }
    $lines.Add("- [$status] $($r.id): expected=$($r.expected_decision), actual=$($r.actual_decision), reasons=$([string]::Join(', ', $r.actual_reasons))")
}

$lines | Set-Content -Path $markdownPath -Encoding UTF8

if (-not $allPassed) {
    throw "Dry-run gate validation failed: one or more golden vectors mismatched expected results"
}

Write-Host "Dry-run gate validation passed. Artifacts written to: $OutputDir"
