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

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Parse-SimpleYaml {
    param([string]$Path)

    $lines = Get-Content -Path $Path
    $stack = @([pscustomobject]@{ Indent = -1; Path = "" })
    $scalars = @{}

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*#') { continue }

        if ($line -match '^(\s*)-\s*(.+)$') {
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
    }

    return [pscustomobject]@{ Scalars = $scalars }
}

function Add-Check {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [string]$Id,
        [object]$Expected,
        [object]$Actual
    )

    $passed = "$Expected" -eq "$Actual"
    $Checks.Add([pscustomobject]@{
        id = $Id
        expected = $Expected
        actual = $Actual
        status = if ($passed) { "pass" } else { "fail" }
    }) | Out-Null
}

$thresholds = Get-Content -Raw -Path $thresholdsPath | ConvertFrom-Json
$releaseYaml = Parse-SimpleYaml -Path $releasePolicyPath
$runtimeYaml = Parse-SimpleYaml -Path $runtimeDefaultsPath

$checks = New-Object System.Collections.Generic.List[object]

Add-Check -Checks $checks -Id "open_missing_docs_action" -Expected "warn" -Actual $releaseYaml.Scalars["release_class_policy.missing_documentation.open"]
Add-Check -Checks $checks -Id "licensed_missing_docs_action" -Expected "block_release" -Actual $releaseYaml.Scalars["release_class_policy.missing_documentation.licensed"]
Add-Check -Checks $checks -Id "protected_missing_docs_action" -Expected "block_release" -Actual $releaseYaml.Scalars["release_class_policy.missing_documentation.protected"]

Add-Check -Checks $checks -Id "watermark_retry_count" -Expected $thresholds.watermark.detection_gate.retry_on_fail_count -Actual ([int]$releaseYaml.Scalars["release_class_policy.watermark_failure.retry_attempts"])
Add-Check -Checks $checks -Id "watermark_second_failure_behavior" -Expected "warn" -Actual $releaseYaml.Scalars["release_class_policy.watermark_failure.on_second_failure"]

Add-Check -Checks $checks -Id "step_cap_percent" -Expected $thresholds.runtime_defaults.second_pass.step_cap_percent -Actual ([int]$runtimeYaml.Scalars["runtime_defaults.second_pass_steps.max_increase_percent"])
Add-Check -Checks $checks -Id "leak_target_samples" -Expected $thresholds.leakage.memorization_stress_test.min_generated_samples -Actual ([int]$runtimeYaml.Scalars["runtime_defaults.leak_test.production_target_samples"])
Add-Check -Checks $checks -Id "leak_floor_samples" -Expected $thresholds.leakage.memorization_stress_test.constrained_min_generated_samples -Actual ([int]$runtimeYaml.Scalars["runtime_defaults.leak_test.constrained_floor_samples"])

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$allPassed = $failed.Count -eq 0

$report = [ordered]@{
    audit = "policy_drift"
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
    checks = $checks
    total_checks = $checks.Count
    failed_checks = $failed.Count
    status = if ($allPassed) { "pass" } else { "fail" }
}

$jsonPath = Join-Path $OutputDir "drift_audit.json"
$mdPath = Join-Path $OutputDir "drift_audit.md"

$report | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Drift Audit")
$lines.Add("")
$lines.Add("- Status: $($report.status)")
$lines.Add("- Total checks: $($report.total_checks)")
$lines.Add("- Failed checks: $($report.failed_checks)")
$lines.Add("")
$lines.Add("## Checks")
$lines.Add("")
foreach ($c in $checks) {
    $tag = if ($c.status -eq "pass") { "PASS" } else { "FAIL" }
    $lines.Add("- [$tag] $($c.id): expected=$($c.expected), actual=$($c.actual)")
}
$lines | Set-Content -Path $mdPath -Encoding UTF8

if (-not $allPassed) {
    throw "Policy drift audit failed: $($failed.Count) check(s) mismatched"
}

Write-Host "Policy drift audit passed. Artifacts written to: $OutputDir"
