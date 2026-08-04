[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot '.test-agent-usage'
$codexRoot = Join-Path $testRoot 'codex\2026\08\04'
$claudeRoot = Join-Path $testRoot 'claude\C--Test'
$codexFile = Join-Path $codexRoot 'rollout-test.jsonl'
$claudeFile = Join-Path $claudeRoot 'session-test.jsonl'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected [$Expected], got [$Actual]." }
}

function Assert-Approximately {
    param([double]$Actual, [double]$Expected, [double]$Tolerance, [string]$Message)
    if ([Math]::Abs($Actual - $Expected) -gt $Tolerance) {
        throw "$Message Expected [$Expected], got [$Actual]."
    }
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
$null = New-Item -ItemType Directory -Path $codexRoot -Force
$null = New-Item -ItemType Directory -Path $claudeRoot -Force

. (Join-Path $projectRoot 'app\Get-AgentUsageState.ps1')

try {
    $codexLines = @(
        '{"timestamp":"2026-08-03T15:59:59Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":999,"input_tokens":900,"output_tokens":99,"cached_input_tokens":600}}}}',
        '{"timestamp":"2026-08-04T01:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000,"input_tokens":900,"output_tokens":100,"cached_input_tokens":600}},"rate_limits":{"primary":{"window_minutes":10080,"used_percent":33,"resets_at":1786198904}}}}',
        '{"timestamp":"2026-08-04T02:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2500,"input_tokens":2000,"output_tokens":500,"cached_input_tokens":1500,"cache_write_input_tokens":50}},"rate_limits":{"primary":{"window_minutes":10080,"used_percent":33,"resets_at":1786198904}}}}'
    )
    [System.IO.File]::WriteAllLines($codexFile, $codexLines, [System.Text.UTF8Encoding]::new($false))

    $claudeLines = @(
        '{"timestamp":"2026-08-03T15:59:59Z","type":"assistant","message":{"model":"test-model","usage":{"input_tokens":999,"output_tokens":99,"cache_read_input_tokens":500,"cache_creation_input_tokens":100}}}',
        '{"timestamp":"2026-08-04T03:00:00+08:00","type":"assistant","message":{"model":"test-model-a","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":300,"cache_creation_input_tokens":200}}}',
        '{"timestamp":"2026-08-04T04:00:00+08:00","type":"assistant","message":{"model":"test-model-b","usage":{"input_tokens":2000,"output_tokens":500,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}'
    )
    [System.IO.File]::WriteAllLines($claudeFile, $claudeLines, [System.Text.UTF8Encoding]::new($false))

    $now = [DateTimeOffset]::Parse('2026-08-04T12:00:00+08:00')
    $usage = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'codex') -ClaudeProjectsRoot (Join-Path $testRoot 'claude') -Now $now

    Assert-Equal $usage.codex.totalTokens 3500 'Codex should sum only today\'s incremental tokens.'
    Assert-Approximately $usage.codex.cachePercent (2100 * 100.0 / 2900) 0.001 'Codex cache ratio mismatch.'
    Assert-Equal $usage.codex.weeklyRemainingPercent 67 'Codex weekly remaining percentage mismatch.'
    Assert-Equal $usage.codex.weeklyResetAt ([DateTimeOffset]::FromUnixTimeSeconds(1786198904)) 'Codex weekly reset time mismatch.'

    Assert-Equal $usage.claude.totalTokens 4100 'Claude should sum today\'s assistant usage across models.'
    Assert-Approximately $usage.claude.cachePercent (1000 * 100.0 / 4000) 0.001 'Claude cache ratio mismatch.'
    Assert-Equal $usage.claude.weeklyRemainingPercent $null 'Claude weekly quota should remain unavailable.'

    $empty = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'missing-codex') -ClaudeProjectsRoot (Join-Path $testRoot 'missing-claude') -Now $now
    Assert-Equal $empty.codex.totalTokens $null 'Missing Codex data should not be shown as zero.'
    Assert-Equal $empty.claude.totalTokens $null 'Missing Claude data should not be shown as zero.'
    Write-Host 'Agent usage tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
