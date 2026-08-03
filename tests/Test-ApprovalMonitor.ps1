[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'app\Get-CodexApprovalState.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -ne [string]$Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

$script:CodexApprovalLogCursor = 0L
$script:CodexApprovalStates = @{}
$threadId = '11111111-2222-3333-4444-555555555555'
$turnId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$request = [pscustomobject]@{
    Id = 10L
    Timestamp = $now
    Target = 'codex_core::stream_events_utils'
    ThreadId = $threadId
    Body = "thread_id=$threadId turn_id=$turnId ToolCall sandbox_permissions: `"require_escalated`""
}
Update-CodexApprovalStates -Rows @($request)
Assert-Equal $script:CodexApprovalStates[$threadId].status 'approval' 'Pending approval state mismatch.'

$resolution = [pscustomobject]@{
    Id = 11L
    Timestamp = $now + 1
    Target = 'codex_core::session::handlers'
    ThreadId = $threadId
    Body = "thread_id=$threadId op: ExecApproval turn_id: Some(`"$turnId`") decision: Denied"
}
Update-CodexApprovalStates -Rows @($resolution)
Assert-Equal $script:CodexApprovalStates.ContainsKey($threadId) $false 'Resolved approval was not cleared.'
Assert-Equal $script:CodexApprovalLogCursor 11 'Approval log cursor mismatch.'

$ordinaryCompletion = [pscustomobject]@{
    Id = 12L
    Timestamp = $now + 2
    Target = 'codex_core::tools::parallel'
    ThreadId = $threadId
    Body = "thread_id=$threadId turn_id=$turnId tool call completed"
}
Update-CodexApprovalStates -Rows @($ordinaryCompletion)
Assert-Equal $script:CodexApprovalStates.Count 0 'Ordinary tool completion created a false working state.'

$legacyThreadId = '22222222-3333-4444-5555-666666666666'
$legacyTurnId = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff'
$legacyRequest = [pscustomobject]@{
    Id = 13L
    Timestamp = $now + 3
    Target = 'codex_core::stream_events_utils'
    ThreadId = $legacyThreadId
    Body = "thread_id=$legacyThreadId turn_id=$legacyTurnId ToolCall sandbox_permissions`":`"require_escalated`""
}
Update-CodexApprovalStates -Rows @($legacyRequest)
Assert-Equal $script:CodexApprovalStates[$legacyThreadId].status 'approval' 'Compact approval format compatibility mismatch.'

$legacyResolution = [pscustomobject]@{
    Id = 14L
    Timestamp = $now + 4
    Target = 'codex_core::session::handlers'
    ThreadId = $legacyThreadId
    Body = "thread_id=$legacyThreadId op: ExecApproval turn_id: Some(`"$legacyTurnId`") decision: Approved"
}
Update-CodexApprovalStates -Rows @($legacyResolution)
Assert-Equal $script:CodexApprovalStates.Count 0 'Compact approval state was not cleared.'

Write-Host 'Approval monitor tests passed.' -ForegroundColor Green
