[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

if ($null -eq ('CodexSqliteApprovalReader' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class CodexApprovalLogRow
{
    public long Id { get; set; }
    public long Timestamp { get; set; }
    public string Target { get; set; }
    public string Body { get; set; }
    public string ThreadId { get; set; }
}

public static class CodexSqliteApprovalReader
{
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_OPEN_READONLY = 1;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int bytes, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close_v2(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);

    private static byte[] Utf8(string value)
    {
        byte[] text = Encoding.UTF8.GetBytes(value);
        byte[] result = new byte[text.Length + 1];
        Buffer.BlockCopy(text, 0, result, 0, text.Length);
        return result;
    }

    private static string Text(IntPtr statement, int column)
    {
        IntPtr pointer = sqlite3_column_text(statement, column);
        int length = sqlite3_column_bytes(statement, column);
        if (pointer == IntPtr.Zero || length <= 0) return String.Empty;
        byte[] bytes = new byte[length];
        Marshal.Copy(pointer, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    public static CodexApprovalLogRow[] ReadRows(string databasePath, long afterId)
    {
        var rows = new List<CodexApprovalLogRow>();
        IntPtr db = IntPtr.Zero;
        IntPtr statement = IntPtr.Zero;
        try
        {
            if (sqlite3_open_v2(Utf8(databasePath), out db, SQLITE_OPEN_READONLY, IntPtr.Zero) != SQLITE_OK) return rows.ToArray();
            sqlite3_busy_timeout(db, 150);
            string lowerBound = afterId > 0 ? afterId.ToString() : "(SELECT COALESCE(MAX(id),0)-20000 FROM logs)";
            string sql =
                "SELECT id, ts, target, feedback_log_body, COALESCE(thread_id,'') FROM logs " +
                "WHERE id > " + lowerBound + " AND (" +
                "(target='codex_core::stream_events_utils' AND feedback_log_body LIKE '%sandbox_permissions%require_escalated%') OR " +
                "(target='codex_core::stream_events_utils' AND feedback_log_body LIKE '%tool_name=\"request_permissions\"%') OR " +
                "(target='codex_core::session::handlers' AND feedback_log_body LIKE '%op: ExecApproval%') OR " +
                "(target='codex_core::session::handlers' AND feedback_log_body LIKE '%op: RequestPermissionsResponse%') OR " +
                "(target='codex_core::tools::parallel' AND feedback_log_body LIKE '%tool call completed%')" +
                ") ORDER BY id";
            byte[] sqlBytes = Utf8(sql);
            if (sqlite3_prepare_v2(db, sqlBytes, sqlBytes.Length - 1, out statement, IntPtr.Zero) != SQLITE_OK) return rows.ToArray();
            while (sqlite3_step(statement) == SQLITE_ROW)
            {
                rows.Add(new CodexApprovalLogRow {
                    Id = sqlite3_column_int64(statement, 0),
                    Timestamp = sqlite3_column_int64(statement, 1),
                    Target = Text(statement, 2),
                    Body = Text(statement, 3),
                    ThreadId = Text(statement, 4)
                });
            }
            return rows.ToArray();
        }
        finally
        {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            if (db != IntPtr.Zero) sqlite3_close_v2(db);
        }
    }
}
'@
}

if ($null -eq (Get-Variable -Name CodexApprovalLogCursor -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CodexApprovalLogCursor = 0L
}
if ($null -eq (Get-Variable -Name CodexApprovalStates -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CodexApprovalStates = @{}
}
if ($null -eq (Get-Variable -Name CodexApprovalDeniedThreads -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CodexApprovalDeniedThreads = @{}
}

function Get-CodexLogIdentity {
    param([object]$Row)

    $threadId = [string]$Row.ThreadId
    if ([string]::IsNullOrWhiteSpace($threadId) -and [string]$Row.Body -match 'thread_id=([0-9a-fA-F-]{36})') {
        $threadId = $Matches[1]
    }

    $turnId = ''
    if ([string]$Row.Body -match 'turn_id:\s*Some\("([0-9a-fA-F-]{36})"\)') {
        $turnId = $Matches[1]
    }
    elseif ([string]$Row.Body -match 'turn_id=([0-9a-fA-F-]{36})') {
        $turnId = $Matches[1]
    }
    elseif ([string]$Row.Body -match 'turn\.id=([0-9a-fA-F-]{36})') {
        $turnId = $Matches[1]
    }

    return [pscustomobject]@{ threadId = $threadId; turnId = $turnId }
}

function Update-CodexApprovalStates {
    param([object[]]$Rows)

    foreach ($row in @($Rows)) {
        $script:CodexApprovalLogCursor = [Math]::Max([long]$script:CodexApprovalLogCursor, [long]$row.Id)
        $identity = Get-CodexLogIdentity -Row $row
        if ([string]::IsNullOrWhiteSpace($identity.threadId)) { continue }

        # Desktop builds have emitted both compact JSON
        # (sandbox_permissions":"require_escalated") and formatted tool-call
        # source (sandbox_permissions: "require_escalated"). Match the field
        # assignment, not a loose mention of the two words in diagnostic text.
        # DeepSeek/responses builds instead emit a request_permissions tool call.
        $isApprovalRequest =
            ([string]$row.Target -eq 'codex_core::stream_events_utils' -and [string]$row.Body -match '(?s)sandbox_permissions"?\s*[:=]\s*"require_escalated"') -or
            ([string]$row.Target -eq 'codex_core::stream_events_utils' -and [string]$row.Body -match 'tool_name="request_permissions"')
        if ($isApprovalRequest) {
            $timestamp = [DateTimeOffset]::FromUnixTimeSeconds([long]$row.Timestamp).ToString('o')
            $script:CodexApprovalDeniedThreads.Remove($identity.threadId)
            $script:CodexApprovalStates[$identity.threadId] = [pscustomobject][ordered]@{
                provider = 'codex'
                sessionId = $identity.threadId
                turnId = $identity.turnId
                status = 'approval'
                startedAt = $timestamp
                updatedAt = $timestamp
                cwd = ''
                model = ''
                source = 'app-log'
            }
            continue
        }

        # Resolution and completion events only close an approval. They must not
        # create a new working timestamp, because the rollout owns task duration.
        if ($script:CodexApprovalStates.ContainsKey($identity.threadId)) {
            $existing = $script:CodexApprovalStates[$identity.threadId]
            $identityTurn = [string]$identity.turnId
            if ([string]::IsNullOrWhiteSpace($identityTurn) -or [string]$existing.turnId -eq $identityTurn) {
                if ([string]$row.Body -match '(?i)\b(denied|rejected|declined|canceled|cancelled)\b') {
                    $script:CodexApprovalDeniedThreads[$identity.threadId] = [DateTimeOffset]::UtcNow
                }
                $script:CodexApprovalStates.Remove($identity.threadId)
            }
        }
    }
}

function Get-CodexApprovalDeniedThreadIds {
    [CmdletBinding()]
    param(
        [TimeSpan]$MaximumAge = ([TimeSpan]::FromMinutes(10))
    )

    $cutoff = [DateTimeOffset]::UtcNow.Subtract($MaximumAge)
    foreach ($key in @($script:CodexApprovalDeniedThreads.Keys)) {
        try {
            if ([DateTimeOffset]$script:CodexApprovalDeniedThreads[$key] -lt $cutoff) {
                $script:CodexApprovalDeniedThreads.Remove($key)
            }
        }
        catch {
            $script:CodexApprovalDeniedThreads.Remove($key)
        }
    }
    return @($script:CodexApprovalDeniedThreads.Keys)
}

function Get-CodexLogApprovalSessions {
    [CmdletBinding()]
    param(
        [string]$LogsPath = (Join-Path (Join-Path $env:USERPROFILE '.codex') 'logs_2.sqlite'),
        [TimeSpan]$MaximumAge = ([TimeSpan]::FromMinutes(30))
    )

    if (-not (Test-Path -LiteralPath $LogsPath)) { return @() }
    try {
        $rows = @([CodexSqliteApprovalReader]::ReadRows($LogsPath, [long]$script:CodexApprovalLogCursor))
        Update-CodexApprovalStates -Rows $rows
    }
    catch {
        return @()
    }

    $cutoff = [DateTimeOffset]::UtcNow.Subtract($MaximumAge)
    $sessions = New-Object System.Collections.ArrayList
    foreach ($key in @($script:CodexApprovalStates.Keys)) {
        try {
            $state = $script:CodexApprovalStates[$key]
            if ([DateTimeOffset]::Parse([string]$state.updatedAt) -ge $cutoff) {
                $null = $sessions.Add($state)
            }
            else {
                $script:CodexApprovalStates.Remove($key)
            }
        }
        catch {
            $script:CodexApprovalStates.Remove($key)
        }
    }
    return @($sessions)
}
