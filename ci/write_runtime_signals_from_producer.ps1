param(
    [string]$WorkspaceRoot,
    [string]$ProducerPayloadPath,
    [string]$OutputPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
if ([string]::IsNullOrWhiteSpace($ProducerPayloadPath)) {
    throw "ProducerPayloadPath is required"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $WorkspaceRoot "runtime\production_signals.json"
}

$payloadPath = (Resolve-Path $ProducerPayloadPath).Path
$schemaPath = Join-Path $WorkspaceRoot "tests\producer_payload.schema.json"

if (-not (Test-Path $schemaPath)) {
    throw "Missing producer payload schema: $schemaPath"
}

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

$payload = Get-Content -Raw -Path $payloadPath | ConvertFrom-Json

Assert-ExactKeys -Object $payload -ExpectedKeys @("request_id", "release_class", "run_mode", "policy_version", "expected_decision", "expected_reason_codes_contains", "break_glass", "gates") -Path "producer_payload"
Assert-ExactKeys -Object $payload.break_glass -ExpectedKeys @("used", "approved_by_owner", "ticket_id", "reason") -Path "producer_payload.break_glass"
Assert-ExactKeys -Object $payload.gates -ExpectedKeys @("quality", "deconstruction", "robustness", "leakage", "compliance", "documentation", "watermark") -Path "producer_payload.gates"

if (@("open", "licensed", "protected") -notcontains $payload.release_class) {
    throw "Invalid release_class: $($payload.release_class)"
}
if (@("draft", "production") -notcontains $payload.run_mode) {
    throw "Invalid run_mode: $($payload.run_mode)"
}
if (@("pass", "hold", "warn", "block_release") -notcontains $payload.expected_decision) {
    throw "Invalid expected_decision: $($payload.expected_decision)"
}

foreach ($k in @("quality", "deconstruction", "robustness", "leakage", "compliance", "documentation", "watermark")) {
    if (@("pass", "warn", "fail") -notcontains $payload.gates.$k) {
        throw "Invalid gate value for ${k}: $($payload.gates.$k)"
    }
}

$signals = [ordered]@{
    request_id = $payload.request_id
    release_class = $payload.release_class
    run_mode = $payload.run_mode
    policy_version = $payload.policy_version
    expected_decision = $payload.expected_decision
    expected_reason_codes_contains = @($payload.expected_reason_codes_contains)
    break_glass = [ordered]@{
        used = [bool]$payload.break_glass.used
        approved_by_owner = [bool]$payload.break_glass.approved_by_owner
        ticket_id = [string]$payload.break_glass.ticket_id
        reason = [string]$payload.break_glass.reason
    }
    gate_results = [ordered]@{
        quality = $payload.gates.quality
        deconstruction = $payload.gates.deconstruction
        robustness = $payload.gates.robustness
        leakage = $payload.gates.leakage
        compliance = $payload.gates.compliance
        documentation = $payload.gates.documentation
        watermark = $payload.gates.watermark
    }
}

$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

if ((Test-Path $OutputPath) -and -not $Force) {
    throw "Output file already exists at $OutputPath. Re-run with -Force to overwrite."
}

$signals | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Wrote runtime production signals: $OutputPath"
