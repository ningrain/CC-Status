[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot '.test-agent-usage'
$codexRoot = Join-Path $testRoot 'codex\2026\08\04'
$legacyCodexRoot = Join-Path $testRoot 'legacy-codex\2026\08\04'
$claudeRoot = Join-Path $testRoot 'claude\C--Test'
$codexFile = Join-Path $codexRoot 'rollout-test.jsonl'
$legacyCodexFile = Join-Path $legacyCodexRoot 'rollout-legacy-test.jsonl'
$claudeFile = Join-Path $claudeRoot 'session-test.jsonl'
$officialSettingsFile = Join-Path $testRoot 'official-settings.json'
$customSettingsFile = Join-Path $testRoot 'custom-settings.json'
$ccSwitchDatabaseFile = Join-Path $testRoot 'cc-switch.db'

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
$null = New-Item -ItemType Directory -Path $legacyCodexRoot -Force
$null = New-Item -ItemType Directory -Path $claudeRoot -Force

. (Join-Path $projectRoot 'app\Get-AgentUsageState.ps1')
$script:AgentUsageFileCache['stale|missing.jsonl'] = [pscustomobject]@{ day = '2026-08-03' }

try {
    $codexLines = @(
        '{"timestamp":"2026-08-03T15:59:59Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":999,"input_tokens":900,"output_tokens":99,"cached_input_tokens":600}}}}',
        '{"timestamp":"2026-08-04T09:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000,"input_tokens":900,"output_tokens":100,"cached_input_tokens":600}},"rate_limits":{"primary":{"window_minutes":10080,"used_percent":33,"resets_at":1786198904}}}}',
        '{"timestamp":"2026-08-04T10:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2500,"input_tokens":2000,"output_tokens":500,"cached_input_tokens":1500,"cache_write_input_tokens":50}},"rate_limits":{"primary":{"window_minutes":300,"used_percent":40,"resets_at":1786180000},"secondary":{"window_minutes":10080,"used_percent":35,"resets_at":1786198904}}}}'
    )
    [System.IO.File]::WriteAllLines($codexFile, $codexLines, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText(
        $legacyCodexFile,
        '{"timestamp":"2026-08-04T09:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"primary":{"window_minutes":10080,"used_percent":33,"resets_at":1786198904}}}}' + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )

    $claudeLines = @(
        '{"timestamp":"2026-08-03T15:59:59Z","type":"assistant","message":{"id":"outside-day","model":"test-model","stop_reason":"end_turn","usage":{"input_tokens":999,"output_tokens":99,"cache_read_input_tokens":500,"cache_creation_input_tokens":100}}}',
        '{"timestamp":"2026-08-04T11:00:00+08:00","type":"assistant","message":{"id":"message-a","model":"test-model-a","stop_reason":null,"usage":{"input_tokens":1000,"output_tokens":300,"cache_read_input_tokens":300,"cache_creation_input_tokens":200}}}',
        '{"timestamp":"2026-08-04T11:00:01+08:00","type":"assistant","message":{"id":"message-a","model":"test-model-a","stop_reason":"end_turn","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":300,"cache_creation_input_tokens":200}}}',
        '{"timestamp":"2026-08-04T12:00:00+08:00","type":"assistant","message":{"id":"message-b","model":"test-model-b","stop_reason":null,"usage":{"input_tokens":2000,"output_tokens":200,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}',
        '{"timestamp":"2026-08-04T12:00:01+08:00","type":"assistant","message":{"id":"message-b","model":"test-model-b","stop_reason":"end_turn","usage":{"input_tokens":2000,"output_tokens":500,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}',
        '{"timestamp":"2026-08-04T13:00:00+08:00","type":"assistant","message":{"id":"message-c","model":"test-model-c","stop_reason":null,"usage":{"input_tokens":400,"output_tokens":50,"cache_read_input_tokens":100,"cache_creation_input_tokens":50}}}',
        '{"timestamp":"2026-08-04T13:00:01+08:00","type":"assistant","message":{"id":"message-c","model":"test-model-c","stop_reason":null,"usage":{"input_tokens":400,"output_tokens":150,"cache_read_input_tokens":100,"cache_creation_input_tokens":50}}}'
    )
    [System.IO.File]::WriteAllLines($claudeFile, $claudeLines, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($officialSettingsFile, '{}', [System.Text.UTF8Encoding]::new($false))

    $now = [DateTimeOffset]::Parse('2026-08-04T12:00:00+08:00')
    $usage = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'codex') -ClaudeProjectsRoot (Join-Path $testRoot 'claude') -ClaudeSettingsPath $officialSettingsFile -Now $now
    Assert-Equal $script:AgentUsageFileCache.ContainsKey('stale|missing.jsonl') $false 'Expired usage cache entries should be pruned.'

    Assert-Equal $usage.codex.totalTokens 3500 "Codex should sum only today's incremental tokens."
    Assert-Approximately $usage.codex.cachePercent (2100 * 100.0 / 2900) 0.001 'Codex cache ratio mismatch.'
    Assert-Equal $usage.codex.fiveHourRemainingPercent 60 'Codex five-hour remaining percentage mismatch.'
    Assert-Equal $usage.codex.fiveHourResetAt ([DateTimeOffset]::FromUnixTimeSeconds(1786180000)) 'Codex five-hour reset time mismatch.'
    Assert-Equal $usage.codex.weeklyRemainingPercent 65 'Codex weekly remaining percentage mismatch.'
    Assert-Equal $usage.codex.weeklyResetAt ([DateTimeOffset]::FromUnixTimeSeconds(1786198904)) 'Codex weekly reset time mismatch.'

    $legacyUsage = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'legacy-codex') -ClaudeProjectsRoot (Join-Path $testRoot 'missing-claude') -ClaudeSettingsPath $officialSettingsFile -Now $now
    Assert-Equal $legacyUsage.codex.fiveHourRemainingPercent $null 'Legacy Codex usage should not invent a five-hour limit.'
    Assert-Equal $legacyUsage.codex.weeklyRemainingPercent 67 'Legacy primary weekly limit compatibility mismatch.'

    Assert-Equal $usage.claude.totalTokens 5300 'Claude should deduplicate assistant usage snapshots by message id.'
    Assert-Approximately $usage.claude.cachePercent (900 * 100.0 / 4550) 0.001 'Claude cache ratio should count cache reads as hits but not cache creation.'
    Assert-Equal $usage.claude.weeklyRemainingPercent $null 'Claude weekly quota should remain unavailable.'
    Assert-Equal $usage.claude.source 'transcript-official' 'Official Claude should use transcript usage.'
    Assert-Equal $usage.claude.isEstimate $false 'Official Claude transcript usage should not be marked as an estimate.'

    $codexAppend = '{"timestamp":"2026-08-04T14:00:00+08:00","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":500,"input_tokens":400,"output_tokens":100,"cached_input_tokens":200}}}}'
    [System.IO.File]::AppendAllText($codexFile, $codexAppend + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $incrementalUsage = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'codex') -ClaudeProjectsRoot (Join-Path $testRoot 'claude') -ClaudeSettingsPath $officialSettingsFile -Now $now
    Assert-Equal $incrementalUsage.codex.totalTokens 4000 'Codex appended usage should be parsed incrementally without losing prior totals.'

    $claudeAppend = '{"timestamp":"2026-08-04T14:00:00+08:00","type":"assistant","message":{"id":"message-d","model":"test-model-d","stop_reason":"end_turn","usage":{"input_tokens":300,"output_tokens":75,"cache_read_input_tokens":125,"cache_creation_input_tokens":25}}}'
    [System.IO.File]::AppendAllText($claudeFile, $claudeAppend + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $incrementalUsage = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'codex') -ClaudeProjectsRoot (Join-Path $testRoot 'claude') -ClaudeSettingsPath $officialSettingsFile -Now $now
    Assert-Equal $incrementalUsage.claude.totalTokens 5825 'Claude appended usage should be parsed incrementally without losing prior snapshots.'

    $claudeSnapshotUpdate = '{"timestamp":"2026-08-04T14:00:01+08:00","type":"assistant","message":{"id":"message-c","model":"test-model-c","stop_reason":"end_turn","usage":{"input_tokens":400,"output_tokens":200,"cache_read_input_tokens":100,"cache_creation_input_tokens":50}}}'
    [System.IO.File]::AppendAllText($claudeFile, $claudeSnapshotUpdate + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $incrementalUsage = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'codex') -ClaudeProjectsRoot (Join-Path $testRoot 'claude') -ClaudeSettingsPath $officialSettingsFile -Now $now
    Assert-Equal $incrementalUsage.claude.totalTokens 5875 'Claude incremental parsing should replace an older snapshot of the same message.'

    $empty = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'missing-codex') -ClaudeProjectsRoot (Join-Path $testRoot 'missing-claude') -ClaudeSettingsPath $officialSettingsFile -Now $now
    Assert-Equal $empty.codex.totalTokens $null 'Missing Codex data should not be shown as zero.'
    Assert-Equal $empty.claude.totalTokens $null 'Missing Claude data should not be shown as zero.'

    [System.IO.File]::WriteAllText($customSettingsFile, '{"env":{"ANTHROPIC_BASE_URL":"https://custom.example.test"}}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllBytes($ccSwitchDatabaseFile, [byte[]](0))
    $script:CCSwitchUsageCache = @{}
    $script:CCSwitchReadCount = 0
    function Read-CCSwitchClaudeUsageSnapshot {
        param([string]$DatabasePath, [DateTimeOffset]$DayStart, [DateTimeOffset]$DayEnd)
        $script:CCSwitchReadCount++
        return [pscustomobject]@{
            ProviderMode = 'cc-switch'
            Rows = @(
                [pscustomobject]@{ Source = 'session_log'; RequestCount = 4; InputTokens = 400; OutputTokens = 40; CacheReadTokens = 600; CacheCreationTokens = 20 },
                [pscustomobject]@{ Source = 'proxy'; RequestCount = 2; InputTokens = 100; OutputTokens = 20; CacheReadTokens = 300; CacheCreationTokens = 10 }
            )
        }
    }
    $dayStart = [DateTimeOffset]::Parse('2026-08-04T00:00:00+08:00')
    $dayEnd = $dayStart.AddDays(1)
    $firstCCSwitch = Get-CCSwitchClaudeUsage -DatabasePath $ccSwitchDatabaseFile -DayStart $dayStart -DayEnd $dayEnd -CacheSeconds 30
    $secondCCSwitch = Get-CCSwitchClaudeUsage -DatabasePath $ccSwitchDatabaseFile -DayStart $dayStart -DayEnd $dayEnd -CacheSeconds 30
    Assert-Equal $script:CCSwitchReadCount 1 'CC Switch usage should be queried at most once during the cache interval.'
    Assert-Equal $firstCCSwitch.totals.total 1490 'CC Switch usage should combine all data sources using the UI aggregation scope.'
    Assert-Equal $secondCCSwitch.totals.total 1490 'Cached CC Switch usage should match the first query.'

    $customUsage = Get-AgentUsageState -CodexSessionsRoot (Join-Path $testRoot 'missing-codex') -ClaudeProjectsRoot (Join-Path $testRoot 'claude') -ClaudeSettingsPath $customSettingsFile -CCSwitchDatabasePath $ccSwitchDatabaseFile -Now $now
    Assert-Equal $customUsage.claude.totalTokens 1490 'CC Switch-managed Claude should use all CC Switch usage data.'
    Assert-Approximately $customUsage.claude.cachePercent (900 * 100.0 / 1430) 0.001 'CC Switch cache ratio mismatch.'
    Assert-Equal $customUsage.claude.source 'cc-switch-mixed' 'Combined CC Switch data source should be exposed.'
    Write-Host 'Agent usage tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
