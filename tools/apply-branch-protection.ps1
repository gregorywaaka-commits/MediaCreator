param(
    [string]$Owner = "gregorywaaka-commits",
    [string]$Repo = "MediaCreator",
    [string]$Branch = "main",
    [string]$RequiredStatusCheck = "evaluate-gates",
    [switch]$EnforceAdmins
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { "" }
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Missing GitHub token. Set GITHUB_TOKEN or GH_TOKEN with repo admin scope."
}

$headers = @{
    Authorization = "Bearer $token"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$body = @{
    required_status_checks = @{
        strict = $true
        contexts = @($RequiredStatusCheck)
    }
    enforce_admins = [bool]$EnforceAdmins
    required_pull_request_reviews = @{
        required_approving_review_count = 1
        dismiss_stale_reviews = $true
        require_code_owner_reviews = $false
        require_last_push_approval = $false
    }
    restrictions = $null
    allow_force_pushes = $false
    allow_deletions = $false
    block_creations = $false
    required_conversation_resolution = $true
    lock_branch = $false
    allow_fork_syncing = $true
} | ConvertTo-Json -Depth 10

$url = "https://api.github.com/repos/$Owner/$Repo/branches/$Branch/protection"

$resp = Invoke-RestMethod -Method Put -Uri $url -Headers $headers -Body $body -ContentType "application/json"
Write-Host "Branch protection applied for $Owner/$Repo:$Branch"
Write-Host "Required checks: $($resp.required_status_checks.contexts -join ', ')"
