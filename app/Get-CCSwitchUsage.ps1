[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

if ($null -eq (Get-Variable -Name CCSwitchUsageCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CCSwitchUsageCache = @{}
}

if (-not ('CCStatus.CCSwitchSqliteReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace CCStatus
{
    public sealed class CCSwitchUsageRow
    {
        public string Source { get; set; }
        public long RequestCount { get; set; }
        public long InputTokens { get; set; }
        public long OutputTokens { get; set; }
        public long CacheReadTokens { get; set; }
        public long CacheCreationTokens { get; set; }
    }

    public sealed class CCSwitchUsageSnapshot
    {
        public string ProviderMode { get; set; }
        public CCSwitchUsageRow[] Rows { get; set; }
    }

    public static class CCSwitchSqliteReader
    {
        private const int SQLITE_OK = 0;
        private const int SQLITE_ROW = 100;
        private const int SQLITE_DONE = 101;
        private const int SQLITE_OPEN_READONLY = 1;

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(IntPtr filename, out IntPtr database, int flags, IntPtr vfs);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr database);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr database, int milliseconds);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(IntPtr database, IntPtr sql, int byteCount, out IntPtr statement, IntPtr tail);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern long sqlite3_column_int64(IntPtr statement, int column);

        private static GCHandle PinUtf8(string value, out IntPtr pointer)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value + "\0");
            GCHandle handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
            pointer = handle.AddrOfPinnedObject();
            return handle;
        }

        private static IntPtr Prepare(IntPtr database, string sql)
        {
            IntPtr sqlPointer;
            IntPtr statement;
            GCHandle sqlHandle = PinUtf8(sql, out sqlPointer);
            try
            {
                int result = sqlite3_prepare_v2(database, sqlPointer, -1, out statement, IntPtr.Zero);
                if (result != SQLITE_OK || statement == IntPtr.Zero)
                    throw new InvalidOperationException("CC Switch query could not be prepared.");
                return statement;
            }
            finally
            {
                sqlHandle.Free();
            }
        }

        private static string ReadText(IntPtr statement, int column)
        {
            IntPtr pointer = sqlite3_column_text(statement, column);
            return pointer == IntPtr.Zero ? String.Empty : Marshal.PtrToStringAnsi(pointer);
        }

        public static CCSwitchUsageSnapshot ReadClaudeUsage(string databasePath, long startEpoch, long endEpoch)
        {
            const string providerSql = "SELECT id, category FROM providers WHERE app_type = 'claude' AND is_current = 1 LIMIT 1";
            const string usageSql = @"
SELECT data_source,
       COUNT(*),
       COALESCE(SUM(input_tokens), 0),
       COALESCE(SUM(output_tokens), 0),
       COALESCE(SUM(cache_read_tokens), 0),
       COALESCE(SUM(cache_creation_tokens), 0)
FROM proxy_request_logs
WHERE app_type IN ('claude', 'claude-desktop')
  AND status_code BETWEEN 200 AND 299
  AND created_at >= ?1
  AND created_at < ?2
GROUP BY data_source";

            IntPtr database = IntPtr.Zero;
            IntPtr pathPointer;
            GCHandle pathHandle = PinUtf8(databasePath, out pathPointer);
            try
            {
                int openResult = sqlite3_open_v2(pathPointer, out database, SQLITE_OPEN_READONLY, IntPtr.Zero);
                if (openResult != SQLITE_OK || database == IntPtr.Zero)
                    throw new InvalidOperationException("CC Switch database could not be opened read-only.");
                sqlite3_busy_timeout(database, 250);

                string providerMode = String.Empty;
                IntPtr providerStatement = Prepare(database, providerSql);
                try
                {
                    int providerStep = sqlite3_step(providerStatement);
                    if (providerStep == SQLITE_ROW)
                    {
                        string providerId = ReadText(providerStatement, 0);
                        string category = ReadText(providerStatement, 1);
                        providerMode = providerId == "claude-official" || category == "official" ? "official" : "cc-switch";
                    }
                    else if (providerStep != SQLITE_DONE)
                        throw new InvalidOperationException("CC Switch provider query failed.");
                }
                finally
                {
                    sqlite3_finalize(providerStatement);
                }

                List<CCSwitchUsageRow> rows = new List<CCSwitchUsageRow>();
                if (providerMode == "cc-switch")
                {
                    IntPtr usageStatement = Prepare(database, usageSql);
                    try
                    {
                        if (sqlite3_bind_int64(usageStatement, 1, startEpoch) != SQLITE_OK ||
                            sqlite3_bind_int64(usageStatement, 2, endEpoch) != SQLITE_OK)
                            throw new InvalidOperationException("CC Switch usage query parameters could not be bound.");
                        while (true)
                        {
                            int stepResult = sqlite3_step(usageStatement);
                            if (stepResult == SQLITE_DONE) break;
                            if (stepResult != SQLITE_ROW)
                                throw new InvalidOperationException("CC Switch usage query failed while reading rows.");
                            rows.Add(new CCSwitchUsageRow
                            {
                                Source = ReadText(usageStatement, 0),
                                RequestCount = sqlite3_column_int64(usageStatement, 1),
                                InputTokens = sqlite3_column_int64(usageStatement, 2),
                                OutputTokens = sqlite3_column_int64(usageStatement, 3),
                                CacheReadTokens = sqlite3_column_int64(usageStatement, 4),
                                CacheCreationTokens = sqlite3_column_int64(usageStatement, 5)
                            });
                        }
                    }
                    finally
                    {
                        sqlite3_finalize(usageStatement);
                    }
                }
                return new CCSwitchUsageSnapshot { ProviderMode = providerMode, Rows = rows.ToArray() };
            }
            finally
            {
                if (database != IntPtr.Zero) sqlite3_close(database);
                pathHandle.Free();
            }
        }
    }
}
'@
}

function Select-CCSwitchClaudeUsageRows {
    param([object[]]$Rows)

    $allRows = @($Rows | Where-Object { $null -ne $_ })
    return $allRows
}

function Read-CCSwitchClaudeUsageSnapshot {
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][DateTimeOffset]$DayStart,
        [Parameter(Mandatory)][DateTimeOffset]$DayEnd
    )

    return [CCStatus.CCSwitchSqliteReader]::ReadClaudeUsage(
        $DatabasePath,
        $DayStart.ToUnixTimeSeconds(),
        $DayEnd.ToUnixTimeSeconds()
    )
}

function Get-CCSwitchClaudeUsage {
    [CmdletBinding()]
    param(
        [string]$DatabasePath = (Join-Path (Join-Path $env:USERPROFILE '.cc-switch') 'cc-switch.db'),
        [Parameter(Mandatory)][DateTimeOffset]$DayStart,
        [Parameter(Mandatory)][DateTimeOffset]$DayEnd,
        [int]$CacheSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { return $null }
    $cacheKey = '{0}|{1}' -f $DatabasePath.ToLowerInvariant(), $DayStart.ToString('yyyy-MM-dd')
    $clock = [DateTimeOffset]::UtcNow
    if ($script:CCSwitchUsageCache.ContainsKey($cacheKey)) {
        $cached = $script:CCSwitchUsageCache[$cacheKey]
        if ($null -ne $cached -and [DateTimeOffset]$cached.expiresAt -gt $clock) {
            return $cached.value
        }
    }

    $result = $null
    try {
        $snapshot = Read-CCSwitchClaudeUsageSnapshot -DatabasePath $DatabasePath -DayStart $DayStart -DayEnd $DayEnd
        if ([string]$snapshot.ProviderMode -eq 'cc-switch') {
            $selectedRows = @(Select-CCSwitchClaudeUsageRows -Rows $snapshot.Rows)
            if ($selectedRows.Count -gt 0) {
                $totals = [pscustomobject][ordered]@{
                    total = [long]0
                    input = [long]0
                    output = [long]0
                    cached = [long]0
                    cacheCreated = [long]0
                    eventCount = 0
                }
                foreach ($row in $selectedRows) {
                    $totals.input += [long]$row.InputTokens
                    $totals.output += [long]$row.OutputTokens
                    $totals.cached += [long]$row.CacheReadTokens
                    $totals.cacheCreated += [long]$row.CacheCreationTokens
                    $totals.eventCount += [int]$row.RequestCount
                }
                $totals.total = $totals.input + $totals.output + $totals.cached + $totals.cacheCreated
                $usesProxy = @($selectedRows | Where-Object { [string]$_.Source -eq 'proxy' }).Count -gt 0
                $usesSessionLog = @($selectedRows | Where-Object { [string]$_.Source -in @('session_log', 'claude_session') }).Count -gt 0
                $source = if ($usesProxy -and $usesSessionLog) {
                    'cc-switch-mixed'
                }
                elseif ($usesProxy) {
                    'cc-switch-proxy'
                }
                else {
                    'cc-switch-session-log'
                }
                $result = [pscustomobject][ordered]@{
                    totals = $totals
                    source = $source
                    isEstimate = (-not $usesProxy)
                }
            }
        }
    }
    catch {
        $result = $null
    }

    $script:CCSwitchUsageCache[$cacheKey] = [pscustomobject]@{
        expiresAt = $clock.AddSeconds([Math]::Max(15, $CacheSeconds))
        value = $result
    }
    return $result
}
