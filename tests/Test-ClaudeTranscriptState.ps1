[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'app\Get-ClaudeTranscriptState.ps1')
. (Join-Path $projectRoot 'app\Read-ClaudeTranscriptIncremental.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -ne [string]$Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

$testRoot = Join-Path $PSScriptRoot '.test-claude-transcript'
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
$null = New-Item -ItemType Directory -Path $testRoot -Force
try {
    $sessionId = '539324fb-95d0-4946-bdd9-f78936dfd5b9'
    $path = Join-Path $testRoot "$sessionId.jsonl"
    $rows = @(
        '{"type":"user","timestamp":"2026-08-05T00:05:23+08:00","message":"get machine info"}',
        '{"type":"assistant","timestamp":"2026-08-05T00:05:27+08:00","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash"}]}}',
        '{"type":"user","timestamp":"2026-08-05T00:05:51+08:00","message":"[Request interrupted by user for tool use]"}',
        '{"type":"system","subtype":"turn_duration","timestamp":"2026-08-05T00:05:51+08:00"}'
    )
    [System.IO.File]::WriteAllLines($path, $rows, [System.Text.UTF8Encoding]::new($false))
    $debugTime = Get-ClaudeTranscriptInterruptionTime -Path $path
    Assert-Equal $debugTime.ToString('o') ([DateTimeOffset]::Parse('2026-08-05T00:05:51+08:00')).ToString('o') 'Interrupted timestamp mismatch.'

    $session = [pscustomobject]@{ provider='claude'; sessionId=$sessionId; status='working'; updatedAt='2026-08-05T00:05:52+08:00' }
    $resolved = @(Resolve-ClaudeTranscriptStates -Sessions @($session) -ProjectsRoot $testRoot -Now ([DateTimeOffset]::Parse('2026-08-05T00:06:00+08:00')))
    Assert-Equal $resolved[0].status 'cancelled' 'Interrupted Claude transcript should be cancelled.'

    $rows += '{"type":"user","timestamp":"2026-08-05T00:06:10+08:00","message":"new request"}'
    [System.IO.File]::WriteAllLines($path, $rows, [System.Text.UTF8Encoding]::new($false))
    $session.status = 'working'
    $script:ClaudeTranscriptInterruptionCache['stale-transcript'] = [pscustomobject]@{}
    $resolved = @(Resolve-ClaudeTranscriptStates -Sessions @($session) -ProjectsRoot $testRoot -Now ([DateTimeOffset]::Parse('2026-08-05T00:06:15+08:00')))
    Assert-Equal $resolved[0].status 'working' 'A new Claude prompt should clear the interrupted marker.'
    Assert-Equal $script:ClaudeTranscriptInterruptionCache.ContainsKey('stale-transcript') $false 'Stale transcript cache entries should be pruned.'

    $incrementalPath = Join-Path $testRoot 'incremental.jsonl'
    [System.IO.File]::WriteAllText($incrementalPath, '{"type":"user","message":"first"}' + [Environment]::NewLine + '{"type":"assistant"', [System.Text.UTF8Encoding]::new($false))
    $cursor = New-ClaudeTranscriptCursor -Path $incrementalPath
    $incrementalRows = @(Read-ClaudeTranscriptRowsIncremental -Path $incrementalPath -Cursor $cursor)
    Assert-Equal $incrementalRows.Count 1 'Incremental reader should return only complete JSONL rows.'
    [System.IO.File]::AppendAllText($incrementalPath, ',"message":"second"}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $incrementalRows = @(Read-ClaudeTranscriptRowsIncremental -Path $incrementalPath -Cursor $cursor)
    Assert-Equal $incrementalRows.Count 1 'Incremental reader should resume from the last complete row.'
    Assert-Equal ([string]$incrementalRows[0].message) 'second' 'Incremental reader returned the wrong appended row.'
    Write-Host 'Claude transcript state tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
