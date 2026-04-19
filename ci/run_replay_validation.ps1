param(
    [string]$CurrentRunPath,
    [string]$PreviousRunPath,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($CurrentRunPath)) {
    throw "CurrentRunPath is required"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Split-Path $CurrentRunPath -Parent
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Get-CaseMap {
    param([object[]]$Cases)
    $map = @{}
    foreach ($case in @($Cases)) {
        $map[$case.id] = $case
    }
    return $map
}

function Get-CaseSignature {
    param([object]$Case)

    $decision = [string]$Case.actual_decision
    $reasons = [string]::Join("|", @($Case.actual_reasons | Sort-Object))
    return "$decision::$reasons"
}

$current = Get-Content -Raw -Path $CurrentRunPath | ConvertFrom-Json
$previousExists = -not [string]::IsNullOrWhiteSpace($PreviousRunPath) -and (Test-Path $PreviousRunPath)

$report = [ordered]@{
    audit = "replay_validation"
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = "pass"
    compared = $false
    notes = @()
    differences = @()
}

if (-not $previousExists) {
    $report.notes = @("No previous run found. Replay comparison skipped.")
}
else {
    $previous = Get-Content -Raw -Path $PreviousRunPath | ConvertFrom-Json
    $report.compared = $true

    if ($current.policy_hash -ne $previous.policy_hash) {
        $report.differences += [pscustomobject]@{
            id = "policy_hash"
            previous = $previous.policy_hash
            current = $current.policy_hash
        }
    }

    $currentMap = Get-CaseMap -Cases $current.cases
    $previousMap = Get-CaseMap -Cases $previous.cases

    foreach ($id in $currentMap.Keys) {
        if (-not $previousMap.ContainsKey($id)) {
            $report.differences += [pscustomobject]@{
                id = "case_missing_in_previous:$id"
                previous = "missing"
                current = "present"
            }
            continue
        }

        $curr = $currentMap[$id]
        $prev = $previousMap[$id]

        if ($curr.actual_decision -ne $prev.actual_decision) {
            $report.differences += [pscustomobject]@{
                id = "decision:$id"
                previous = $prev.actual_decision
                current = $curr.actual_decision
            }
        }

        $currReasons = @($curr.actual_reasons | Sort-Object)
        $prevReasons = @($prev.actual_reasons | Sort-Object)
        $currJoined = [string]::Join("|", $currReasons)
        $prevJoined = [string]::Join("|", $prevReasons)
        if ($currJoined -ne $prevJoined) {
            $report.differences += [pscustomobject]@{
                id = "reasons:$id"
                previous = $prevJoined
                current = $currJoined
            }
        }
    }

    foreach ($id in $previousMap.Keys) {
        if (-not $currentMap.ContainsKey($id)) {
            $report.differences += [pscustomobject]@{
                id = "case_missing_in_current:$id"
                previous = "present"
                current = "missing"
            }
        }
    }

    # Production runs often have a unique request_id per execution. If both runs contain
    # exactly one case and behavior is identical, treat id-only churn as non-drift.
    if (@($current.cases).Count -eq 1 -and @($previous.cases).Count -eq 1) {
        $currSig = Get-CaseSignature -Case $current.cases[0]
        $prevSig = Get-CaseSignature -Case $previous.cases[0]
        $currId = [string]$current.cases[0].id
        $prevId = [string]$previous.cases[0].id

        if ($currSig -eq $prevSig -and $currId -ne $prevId) {
            $filtered = New-Object System.Collections.Generic.List[object]
            foreach ($diff in @($report.differences)) {
                if ($diff.id -ne "case_missing_in_previous:$currId" -and $diff.id -ne "case_missing_in_current:$prevId") {
                    $filtered.Add($diff) | Out-Null
                }
            }
            $report.differences = @($filtered)
            $report.notes = @("Replay matched behavioral signature; request_id changed from '$prevId' to '$currId'.")
        }
    }

    if (@($report.differences).Count -gt 0) {
        $report.status = "fail"
    }
    else {
        $report.notes = @("Replay comparison matched previous run.")
    }
}

$jsonPath = Join-Path $OutputDir "replay_report.json"
$mdPath = Join-Path $OutputDir "replay_report.md"

$report | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Replay Validation")
$lines.Add("")
$lines.Add("- Status: $($report.status)")
$lines.Add("- Compared with previous: $($report.compared)")
$lines.Add("")
if (@($report.notes).Count -gt 0) {
    $lines.Add("## Notes")
    $lines.Add("")
    foreach ($n in $report.notes) { $lines.Add("- $n") }
    $lines.Add("")
}
if (@($report.differences).Count -gt 0) {
    $lines.Add("## Differences")
    $lines.Add("")
    foreach ($d in $report.differences) {
        $lines.Add("- $($d.id): previous=$($d.previous), current=$($d.current)")
    }
}
$lines | Set-Content -Path $mdPath -Encoding UTF8

if ($report.status -eq "fail") {
    throw "Replay validation failed: run drift detected"
}

Write-Host "Replay validation completed. Artifacts written to: $OutputDir"
