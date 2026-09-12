[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'app\Get-CodexApprovalState.ps1')
. (Join-Path $projectRoot 'app\Get-CodexRolloutState.ps1')

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
Assert-Equal $script:CodexApprovalStates[$threadId].status 'working' 'Denied permission should return control to the active turn.'
Assert-Equal $script:CodexApprovalLogCursor 11 'Approval log cursor mismatch.'

$ordinaryCompletion = [pscustomobject]@{
    Id = 12L
    Timestamp = $now + 2
    Target = 'codex_core::tools::parallel'
    ThreadId = $threadId
    Body = "thread_id=$threadId turn_id=$turnId tool call completed"
}
Update-CodexApprovalStates -Rows @($ordinaryCompletion)
Assert-Equal $script:CodexApprovalStates[$threadId].status 'working' 'A denied permission should stay resolved until the turn ends.'
$script:CodexApprovalStates.Clear()

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
Assert-Equal $script:CodexApprovalStates[$legacyThreadId].status 'working' 'Approved command did not return to working state before completion.'

$legacyCompletion = [pscustomobject]@{
    Id = 15L
    Timestamp = $now + 5
    Target = 'codex_core::tools::parallel'
    ThreadId = $legacyThreadId
    Body = "thread_id=$legacyThreadId turn_id=$legacyTurnId tool call completed"
}
Update-CodexApprovalStates -Rows @($legacyCompletion)
Assert-Equal $script:CodexApprovalStates.Count 1 'Approved command completion removed the working override before the turn ended.'
Assert-Equal $script:CodexApprovalStates[$legacyThreadId].status 'working' 'Approved command completion returned to approval state.'
Assert-Equal $script:CodexApprovalStates[$legacyThreadId].updatedAt ([DateTimeOffset]::FromUnixTimeSeconds($now + 5).ToString('o')) 'Approved command completion did not refresh the working state.'

$staleHookApproval = [pscustomobject]@{
    provider = 'codex'
    sessionId = $legacyThreadId
    turnId = $legacyTurnId
    status = 'approval'
    startedAt = [DateTimeOffset]::FromUnixTimeSeconds($now + 3).ToString('o')
    updatedAt = [DateTimeOffset]::FromUnixTimeSeconds($now + 3).ToString('o')
    cwd = 'C:\Users\Administrator'
    model = 'test-model'
    source = 'hook'
}
$liveRollout = [pscustomobject]@{
    provider = 'codex'
    sessionId = $legacyThreadId
    turnId = $legacyTurnId
    status = 'working'
    startedAt = [DateTimeOffset]::FromUnixTimeSeconds($now + 2).ToString('o')
    updatedAt = [DateTimeOffset]::FromUnixTimeSeconds($now + 2).ToString('o')
    cwd = 'C:\Users\Administrator'
    model = ''
    source = 'rollout'
    surface = 'cli'
    isLive = $true
}
$resolved = @(Resolve-CodexSessionStates -Sessions @($staleHookApproval, $liveRollout, $script:CodexApprovalStates[$legacyThreadId]))
Assert-Equal $resolved.Count 1 'Approval recovery should resolve to one session.'
Assert-Equal $resolved[0].status 'working' 'Stale PermissionRequest hook overrode the approved working state.'
Assert-Equal $resolved[0].isLive $true 'Resolved approval recovery lost rollout liveness.'

$terminalRollout = $liveRollout.PSObject.Copy()
$terminalRollout.status = 'completed'
$terminalRollout.updatedAt = [DateTimeOffset]::FromUnixTimeSeconds($now + 6).ToString('o')
$terminalRollout.isLive = $false
$resolved = @(Resolve-CodexSessionStates -Sessions @($staleHookApproval, $script:CodexApprovalStates[$legacyThreadId], $terminalRollout))
Assert-Equal $resolved.Count 1 'Terminal rollout should replace approval recovery state.'
Assert-Equal $resolved[0].status 'completed' 'Approved working state survived past terminal rollout.'

$responseOnlyThreadId = '33333333-4444-5555-6666-777777777777'
$responseOnlyTurnId = 'cccccccc-dddd-eeee-ffff-000000000000'
$responseOnlyApproval = [pscustomobject]@{
    Id = 16L
    Timestamp = $now + 7
    Target = 'codex_core::session::handlers'
    ThreadId = $responseOnlyThreadId
    Body = "thread_id=$responseOnlyThreadId op: ExecApproval turn_id: Some(`"$responseOnlyTurnId`") decision: Approved"
}
Update-CodexApprovalStates -Rows @($responseOnlyApproval)
Assert-Equal $script:CodexApprovalStates[$responseOnlyThreadId].status 'working' 'Approval response without a request row did not establish working state.'
Assert-Equal $script:CodexApprovalStates[$responseOnlyThreadId].turnId $responseOnlyTurnId 'Response-only approval lost its turn identity.'

$responseOnlyCompletion = [pscustomobject]@{
    Id = 17L
    Timestamp = $now + 8
    Target = 'codex_core::tools::parallel'
    ThreadId = $responseOnlyThreadId
    Body = "thread_id=$responseOnlyThreadId turn_id=$responseOnlyTurnId tool call completed"
}
Update-CodexApprovalStates -Rows @($responseOnlyCompletion)
Assert-Equal $script:CodexApprovalStates[$responseOnlyThreadId].status 'working' 'Response-only approval returned to approval after tool completion.'
Assert-Equal $script:CodexApprovalStates[$responseOnlyThreadId].updatedAt ([DateTimeOffset]::FromUnixTimeSeconds($now + 8).ToString('o')) 'Response-only completion did not refresh working state.'

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ApprovalTestDatabase {
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] path, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr callback, IntPtr argument, IntPtr error);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    public static void Create(string path, string sql) {
        IntPtr db = IntPtr.Zero;
        try {
            if (sqlite3_open_v2(Encoding.UTF8.GetBytes(path + "\0"), out db, 6, IntPtr.Zero) != 0)
                throw new Exception("Could not create SQLite fixture.");
            if (sqlite3_exec(db, Encoding.UTF8.GetBytes(sql + "\0"), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0)
                throw new Exception("Could not populate SQLite fixture.");
        }
        finally { if (db != IntPtr.Zero) sqlite3_close(db); }
    }
}
'@
$databaseRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.test-approval-reader'))
if (-not $databaseRoot.StartsWith($PSScriptRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid fixture root.' }
$null = New-Item -ItemType Directory -Path $databaseRoot -Force
try {
    foreach ($precise in @($false, $true)) {
        $path = Join-Path $databaseRoot ([Guid]::NewGuid().ToString('N') + '.sqlite')
        $column = if ($precise) { ', ts_nanos INTEGER' } else { '' }
        $value = if ($precise) { ', 500000000' } else { '' }
        $sql = "CREATE TABLE logs (id INTEGER, ts INTEGER, target TEXT, feedback_log_body TEXT, thread_id TEXT$column); INSERT INTO logs VALUES (1, 1000, 'codex_core::session::handlers', 'op: ExecApproval decision: Denied', '$threadId'$value);"
        [ApprovalTestDatabase]::Create($path, $sql)
        $rows = @([CodexSqliteApprovalReader]::ReadRows($path, 0))
        Assert-Equal $rows.Count 1 'SQLite reader failed for a supported log schema.'
        $expected = if ($precise) { 500000000L } else { $null }
        Assert-Equal $rows[0].TimestampNanos $expected 'SQLite timestamp precision was lost.'
        $time = Get-CodexLogTimestamp $rows[0]
        Assert-Equal $time.Millisecond $(if ($precise) { 500 } else { 0 }) 'Nanoseconds were converted incorrectly.'
    }
}
finally { Remove-Item -LiteralPath $databaseRoot -Recurse -Force }

Write-Host 'Approval monitor tests passed.' -ForegroundColor Green
