[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot '.test-rollouts'
$sessionDirectory = Join-Path $testRoot '2026\08\01'
$rolloutPath = Join-Path $sessionDirectory 'rollout-2026-08-01T12-00-00-11111111-2222-3333-4444-555555555555.jsonl'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -ne [string]$Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
$null = New-Item -ItemType Directory -Path $sessionDirectory -Force
. (Join-Path $projectRoot 'app\Get-CodexRolloutState.ps1')

try {
    $started = @(
        '{"timestamp":"2026-08-01T12:00:00Z","type":"session_meta","payload":{"cwd":"D:\\随便玩玩","originator":"codex-tui","source":"cli"}}',
        '{"timestamp":"2026-08-01T12:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}'
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($rolloutPath, $started, [System.Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath $rolloutPath).LastWriteTimeUtc = [DateTime]::UtcNow

    $sessions = @(Get-CodexRolloutSessions -SessionsRoot $testRoot)
    Assert-Equal $sessions.Count 1 'Started rollout count mismatch.'
    Assert-Equal $sessions[0].status 'working' 'Started rollout state mismatch.'
    Assert-Equal $sessions[0].cwd 'D:\随便玩玩' 'UTF-8 workspace path mismatch.'
    Assert-Equal $sessions[0].surface 'cli' 'CLI surface detection mismatch.'
    Assert-Equal $sessions[0].updatedAt '2026-08-01T12:00:01.0000000+00:00' 'UTC timestamp normalization mismatch.'

    $completed = $started + [Environment]::NewLine + '{"timestamp":"2026-08-01T12:00:05Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}'
    [System.IO.File]::WriteAllText($rolloutPath, $completed, [System.Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath $rolloutPath).LastWriteTimeUtc = [DateTime]::UtcNow

    $sessions = @(Get-CodexRolloutSessions -SessionsRoot $testRoot)
    Assert-Equal $sessions[0].status 'completed' 'Completed rollout state mismatch.'
    Assert-Equal $sessions[0].turnId 'turn-1' 'Turn ID mismatch.'

    $aborted = $completed + [Environment]::NewLine + '{"timestamp":"2026-08-01T12:00:08Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}'
    [System.IO.File]::WriteAllText($rolloutPath, $aborted, [System.Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath $rolloutPath).LastWriteTimeUtc = [DateTime]::UtcNow
    $sessions = @(Get-CodexRolloutSessions -SessionsRoot $testRoot)
    Assert-Equal $sessions[0].status 'cancelled' 'Aborted rollout state mismatch.'
    Assert-Equal $sessions[0].turnId 'turn-2' 'Aborted turn ID mismatch.'

    $staleApproval = [pscustomobject]@{
        sessionId = 'session-cli'
        turnId = 'turn-aborted'
        status = 'approval'
        startedAt = '2026-08-01T12:00:01.5000000+00:00'
        updatedAt = '2026-08-01T12:00:08.0250000+00:00'
        cwd = 'C:\Users\Administrator'
        model = 'test-model'
    }
    $terminalRollout = [pscustomobject]@{
        sessionId = 'session-cli'
        turnId = 'turn-aborted'
        status = 'cancelled'
        startedAt = '2026-08-01T12:00:01.0000000+00:00'
        updatedAt = '2026-08-01T12:00:08.0000000+00:00'
        cwd = 'C:\Users\Administrator'
        model = ''
        source = 'rollout'
        surface = 'cli'
        isLive = $false
    }
    $resolved = @(Resolve-CodexSessionStates -Sessions @($staleApproval, $terminalRollout) -Now ([DateTimeOffset]::Parse('2026-08-01T12:01:00Z')))
    Assert-Equal $resolved.Count 1 'Terminal rollout should remove stale hook approval.'
    Assert-Equal $resolved[0].status 'cancelled' 'Terminal rollout must win even when the hook timestamp is slightly newer.'

    $orphanRollout = [pscustomobject]@{
        sessionId = 'session-killed'
        turnId = 'turn-killed'
        status = 'working'
        startedAt = '2026-08-01T12:00:00.0000000+00:00'
        updatedAt = '2026-08-01T12:00:01.0000000+00:00'
        cwd = 'C:\Users\Administrator'
        model = ''
        source = 'rollout'
        surface = 'cli'
        isLive = $false
    }
    $orphanApproval = [pscustomobject]@{
        sessionId = 'session-killed'
        turnId = 'turn-killed'
        status = 'approval'
        startedAt = '2026-08-01T12:00:02.0000000+00:00'
        updatedAt = '2026-08-01T12:00:02.0000000+00:00'
        cwd = 'C:\Users\Administrator'
        model = 'test-model'
    }
    $resolved = @(Resolve-CodexSessionStates -Sessions @($orphanApproval, $orphanRollout) -Now ([DateTimeOffset]::Parse('2026-08-01T12:01:00Z')))
    Assert-Equal $resolved.Count 0 'A hard-killed task must not leave working or approval state behind.'

    $liveRollout = $orphanRollout.PSObject.Copy()
    $liveRollout.isLive = $true
    $resolved = @(Resolve-CodexSessionStates -Sessions @($orphanApproval, $liveRollout) -Now ([DateTimeOffset]::Parse('2026-08-01T12:01:00Z')))
    Assert-Equal $resolved.Count 1 'A live approval should be preserved.'
    Assert-Equal $resolved[0].status 'approval' 'Live approval state mismatch.'
    Assert-Equal $resolved[0].surface 'cli' 'CLI surface should be propagated to hook approval.'
    Write-Host 'Rollout monitor tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
