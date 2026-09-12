[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

if ($null -eq (Get-Variable -Name AgentUsageFileCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AgentUsageFileCache = @{}
}
if ($null -eq (Get-Variable -Name AgentUsageDirectoryCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AgentUsageDirectoryCache = @{}
}

if (-not ('CCStatus.UsageJsonLines' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
namespace CCStatus {
    public sealed class UsageJsonLine {
        public string Text;
        public long NextOffset;
    }
    public sealed class UsageJsonCursor : IDisposable {
        private readonly IEnumerator<UsageJsonLine> iterator;
        public UsageJsonCursor(string path, long start, string marker) { iterator = UsageJsonLines.ReadMatching(path, start, marker).GetEnumerator(); }
        public UsageJsonLine Current { get { return iterator.Current; } }
        public bool MoveNext() { return iterator.MoveNext(); }
        public void Dispose() { iterator.Dispose(); }
    }
    public static class UsageJsonLines {
        public static IEnumerable<UsageJsonLine> ReadMatching(string path, long start, string marker) {
            long offset = start;
            long emittedOffset = start;
            foreach (var row in Read(path, start)) {
                offset = row.NextOffset;
                if (row.Text.IndexOf(marker, StringComparison.Ordinal) < 0) continue;
                emittedOffset = offset;
                yield return row;
            }
            // Non-usage records still count as consumed bytes.
            if (offset != emittedOffset) yield return new UsageJsonLine { Text = null, NextOffset = offset };
        }
        // Read fixed-size blocks and retain only one JSON record at a time.
        // Only newline-terminated records advance the caller's cursor.
        public static IEnumerable<UsageJsonLine> Read(string path, long start) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var line = new MemoryStream()) {
                long end = stream.Length;
                long position = start >= 0 && start <= end ? start : 0;
                stream.Position = position;
                byte[] buffer = new byte[65536];
                while (position < end) {
                    int count = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, end - position));
                    if (count == 0) yield break;
                    int segment = 0;
                    for (int i = 0; i < count; i++) {
                        if (buffer[i] != 10) continue;
                        int length = i - segment;
                        line.Write(buffer, segment, length);
                        yield return new UsageJsonLine {
                            Text = Encoding.UTF8.GetString(line.GetBuffer(), 0, (int)line.Length).TrimEnd('\r'),
                            NextOffset = position + i + 1
                        };
                        line.SetLength(0);
                        if (line.Capacity > 1048576) line.Capacity = 0;
                        segment = i + 1;
                    }
                    int remaining = count - segment;
                    line.Write(buffer, segment, remaining);
                    position += count;
                }
            }
        }
    }
}
'@
}

$ccSwitchUsageReaderPath = Join-Path $PSScriptRoot 'Get-CCSwitchUsage.ps1'
if (Test-Path -LiteralPath $ccSwitchUsageReaderPath -PathType Leaf) {
    try { . $ccSwitchUsageReaderPath } catch {}
}

function Get-AgentUsageProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-AgentUsageLong {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    try {
        $number = [long]$Value
        if ($number -lt 0) { return $null }
        return $number
    }
    catch {
        return $null
    }
}

function ConvertTo-AgentUsageTimestamp {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        if ($Value -is [DateTimeOffset]) {
            return [DateTimeOffset]$Value
        }
        if ($Value -is [DateTime]) {
            return [DateTimeOffset]([DateTime]$Value)
        }
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch {
        return $null
    }
}

function ConvertTo-AgentUsageResetTime {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    try {
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$Value)
    }
    catch {
        return $null
    }
}

function New-AgentUsageTotals {
    return [pscustomobject][ordered]@{
        total = [long]0
        input = [long]0
        output = [long]0
        cached = [long]0
        cacheCreated = [long]0
        eventCount = 0
    }
}

function Add-AgentUsageValue {
    param(
        [Parameter(Mandatory)]$Totals,
        [Parameter(Mandatory)][string]$Target,
        [object]$Value
    )

    $number = ConvertTo-AgentUsageLong -Value $Value
    if ($null -eq $number) { return $false }
    $Totals.$Target = [long]$Totals.$Target + $number
    return $true
}

function New-AgentUsageFileSummary {
    param([Parameter(Mandatory)][string]$Provider)

    return [pscustomobject][ordered]@{
        provider = $Provider
        totals = New-AgentUsageTotals
        latestFiveHourRate = $null
        latestFiveHourRateAt = $null
        latestWeeklyRate = $null
        latestWeeklyRateAt = $null
        previousCumulative = $null
    }
}

function Read-CodexUsageFileSummary {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][DateTime]$Today,
        [long]$StartOffset = 0,
        [object]$ExistingSummary = $null
    )

    $summary = if ($null -ne $ExistingSummary) { $ExistingSummary.PSObject.Copy() } else { New-AgentUsageFileSummary -Provider 'codex' }
    if ($null -ne $ExistingSummary) { $summary.totals = $ExistingSummary.totals.PSObject.Copy() }
    $offset = $StartOffset
    $iterator = [CCStatus.UsageJsonCursor]::new($File.FullName, $StartOffset, '"token_count"')
    try {
        while ($iterator.MoveNext()) {
            $offset = $iterator.Current.NextOffset
            $line = $iterator.Current.Text
            if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '"token_count"') { continue }
            try { $item = $line | ConvertFrom-Json } catch { continue }
            if ([string](Get-AgentUsageProperty -Object $item -Name 'type') -ne 'event_msg') { continue }

            $payload = Get-AgentUsageProperty -Object $item -Name 'payload'
            if ([string](Get-AgentUsageProperty -Object $payload -Name 'type') -ne 'token_count') { continue }
            $timestamp = ConvertTo-AgentUsageTimestamp -Value (Get-AgentUsageProperty -Object $item -Name 'timestamp')
            if ($null -eq $timestamp) { continue }

            $info = Get-AgentUsageProperty -Object $payload -Name 'info'
            $rateLimits = Get-AgentUsageProperty -Object $payload -Name 'rate_limits'
            $primary = Get-AgentUsageProperty -Object $rateLimits -Name 'primary'
            $secondary = Get-AgentUsageProperty -Object $rateLimits -Name 'secondary'
            foreach ($rateLimit in @($primary, $secondary)) {
                $windowMinutes = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $rateLimit -Name 'window_minutes')
                $usedPercent = Get-AgentUsageProperty -Object $rateLimit -Name 'used_percent'
                if ($null -eq $windowMinutes -or $windowMinutes -notin @(300, 10080) -or $null -eq $usedPercent) { continue }
                try {
                    $used = [double]$usedPercent
                    if ($used -ge 0) {
                        $candidate = [pscustomobject][ordered]@{
                            usedPercent = [Math]::Min(100.0, $used)
                            resetAt = ConvertTo-AgentUsageResetTime -Value (Get-AgentUsageProperty -Object $rateLimit -Name 'resets_at')
                        }
                        if ($windowMinutes -eq 300 -and ($null -eq $summary.latestFiveHourRateAt -or $timestamp -gt $summary.latestFiveHourRateAt)) {
                            $summary.latestFiveHourRate = $candidate
                            $summary.latestFiveHourRateAt = $timestamp
                        }
                        elseif ($windowMinutes -eq 10080 -and ($null -eq $summary.latestWeeklyRateAt -or $timestamp -gt $summary.latestWeeklyRateAt)) {
                            $summary.latestWeeklyRate = [pscustomobject][ordered]@{
                                usedPercent = [Math]::Min(100.0, $used)
                                resetAt = $candidate.resetAt
                            }
                            $summary.latestWeeklyRateAt = $timestamp
                        }
                    }
                }
                catch {}
            }

            $lastUsage = Get-AgentUsageProperty -Object $info -Name 'last_token_usage'
            $cumulative = Get-AgentUsageProperty -Object $info -Name 'total_token_usage'
            $cumulativeTotal = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $cumulative -Name 'total_tokens')
            if ($timestamp.ToLocalTime().Date -ne $Today) {
                # Historical records establish the baseline but need no delta
                # arithmetic or per-field conversion for today's display.
                if ($null -ne $cumulativeTotal) { $summary.previousCumulative = $cumulative }
                elseif ($null -ne $lastUsage) { $summary.previousCumulative = $null }
                continue
            }
            if ($null -ne $cumulativeTotal) {
                $previous = $summary.previousCumulative
                $previousTotal = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $previous -Name 'total_tokens')
                if ($null -ne $previousTotal -and $cumulativeTotal -ge $previousTotal) {
                    $delta = [ordered]@{}
                    foreach ($field in @('total_tokens', 'input_tokens', 'output_tokens', 'cached_input_tokens', 'cache_write_input_tokens')) {
                        $value = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $cumulative -Name $field)
                        $baseline = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $previous -Name $field)
                        $delta[$field] = if ($null -ne $value -and $null -ne $baseline) { [Math]::Max(0L, $value - $baseline) } else { $null }
                    }
                    $lastUsage = [pscustomobject]$delta
                }
                # At the first snapshot or a counter reset, last_token_usage is
                # the only attributable request (the total may include history).
                $summary.previousCumulative = $cumulative
            }
            elseif ($null -ne $lastUsage) {
                # Legacy records are already request deltas. Break the baseline
                # so a later cumulative snapshot cannot count them again.
                $summary.previousCumulative = $null
            }
            $totalAdded = Add-AgentUsageValue -Totals $summary.totals -Target 'total' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'total_tokens')
            $inputAdded = Add-AgentUsageValue -Totals $summary.totals -Target 'input' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'input_tokens')
            $null = Add-AgentUsageValue -Totals $summary.totals -Target 'output' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'output_tokens')
            $null = Add-AgentUsageValue -Totals $summary.totals -Target 'cached' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'cached_input_tokens')
            $null = Add-AgentUsageValue -Totals $summary.totals -Target 'cacheCreated' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'cache_write_input_tokens')
            if ($totalAdded -or $inputAdded) { $summary.totals.eventCount++ }
        }
        return [pscustomobject]@{ summary = $summary; offset = $offset }
    }
    finally {
        $iterator.Dispose()
    }
}

function Read-ClaudeUsageFileSummary {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][DateTime]$Today,
        [long]$StartOffset = 0,
        [hashtable]$ExistingSnapshots = $null,
        [int]$AnonymousIndex = 0
    )

    $snapshots = if ($null -ne $ExistingSnapshots) { $ExistingSnapshots.Clone() } else { @{} }
    $offset = $StartOffset
    $iterator = [CCStatus.UsageJsonCursor]::new($File.FullName, $StartOffset, '"assistant"')
    try {
        while ($iterator.MoveNext()) {
            $offset = $iterator.Current.NextOffset
            $line = $iterator.Current.Text
            if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '"assistant"') { continue }
            try { $item = $line | ConvertFrom-Json } catch { continue }
            if ([string](Get-AgentUsageProperty -Object $item -Name 'type') -ne 'assistant') { continue }

            $timestamp = ConvertTo-AgentUsageTimestamp -Value (Get-AgentUsageProperty -Object $item -Name 'timestamp')
            if ($null -eq $timestamp -or $timestamp.ToLocalTime().Date -ne $Today) { continue }
            $message = Get-AgentUsageProperty -Object $item -Name 'message'
            $usage = Get-AgentUsageProperty -Object $message -Name 'usage'
            if ($null -eq $usage) { continue }

            $input = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $usage -Name 'input_tokens')
            $output = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $usage -Name 'output_tokens')
            $cached = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $usage -Name 'cache_read_input_tokens')
            $cacheCreated = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $usage -Name 'cache_creation_input_tokens')
            if ($null -eq $input -and $null -eq $output -and $null -eq $cached -and $null -eq $cacheCreated) { continue }

            $messageId = [string](Get-AgentUsageProperty -Object $message -Name 'id')
            if ([string]::IsNullOrWhiteSpace($messageId)) {
                $anonymousIndex++
                $messageKey = 'anonymous:{0}' -f $anonymousIndex
            }
            else {
                $messageKey = 'message:{0}' -f $messageId
            }
            $stopReason = [string](Get-AgentUsageProperty -Object $message -Name 'stop_reason')
            $candidate = [pscustomobject][ordered]@{
                input = if ($null -ne $input) { [long]$input } else { [long]0 }
                output = if ($null -ne $output) { [long]$output } else { [long]0 }
                cached = if ($null -ne $cached) { [long]$cached } else { [long]0 }
                cacheCreated = if ($null -ne $cacheCreated) { [long]$cacheCreated } else { [long]0 }
                isFinal = -not [string]::IsNullOrWhiteSpace($stopReason)
                timestamp = $timestamp
            }
            $existing = if ($snapshots.ContainsKey($messageKey)) { $snapshots[$messageKey] } else { $null }
            $replace = $null -eq $existing
            if (-not $replace -and $candidate.isFinal -and -not $existing.isFinal) {
                $replace = $true
            }
            elseif (-not $replace -and $candidate.isFinal -eq $existing.isFinal) {
                if ($candidate.output -gt $existing.output -or
                    ($candidate.output -eq $existing.output -and $candidate.timestamp -gt $existing.timestamp)) {
                    $replace = $true
                }
            }
            if ($replace) {
                $snapshots[$messageKey] = $candidate
            }
        }

        $summary = New-AgentUsageFileSummary -Provider 'claude'
        foreach ($snapshot in $snapshots.Values) {
            $summary.totals.input += [long]$snapshot.input
            $summary.totals.output += [long]$snapshot.output
            $summary.totals.cached += [long]$snapshot.cached
            $summary.totals.cacheCreated += [long]$snapshot.cacheCreated
            $summary.totals.total += [long]$snapshot.input + [long]$snapshot.output + [long]$snapshot.cached + [long]$snapshot.cacheCreated
            $summary.totals.eventCount++
        }
        return [pscustomobject]@{
            summary = $summary
            offset = $offset
            snapshots = $snapshots
            anonymousIndex = $anonymousIndex
        }
    }
    finally {
        $iterator.Dispose()
    }
}

function Merge-AgentUsageTotals {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Source
    )

    foreach ($name in @('total', 'input', 'output', 'cached', 'cacheCreated', 'eventCount')) {
        $Target.$name = [long]$Target.$name + [long]$Source.$name
    }
}

function Test-ClaudeCustomEndpointConfigured {
    param([Parameter(Mandatory)][string]$SettingsPath)

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return $false }
    try {
        $settings = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $envSettings = Get-AgentUsageProperty -Object $settings -Name 'env'
        $baseUrl = [string](Get-AgentUsageProperty -Object $envSettings -Name 'ANTHROPIC_BASE_URL')
        return -not [string]::IsNullOrWhiteSpace($baseUrl)
    }
    catch {
        return $false
    }
}

function Get-AgentUsageFiles {
    param([string]$Root, [string]$Filter, [int]$CacheSeconds = 30)

    $key = $Root.ToLowerInvariant() + '|' + $Filter
    $clock = [DateTimeOffset]::UtcNow
    if (-not (Test-Path -LiteralPath $Root)) {
        $script:AgentUsageDirectoryCache.Remove($key)
        return @()
    }
    $cached = $script:AgentUsageDirectoryCache[$key]
    if ($null -eq $cached -or $cached.expiresAt -le $clock) {
        $cached = [pscustomobject]@{
            expiresAt = $clock.AddSeconds($CacheSeconds)
            files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue)
        }
        $script:AgentUsageDirectoryCache[$key] = $cached
    }
    foreach ($file in $cached.files) {
        $file.Refresh()
        if ($file.Exists) { $file }
    }
}

function Get-AgentUsageState {
    [CmdletBinding()]
    param(
        [string]$CodexSessionsRoot = (Join-Path (Join-Path $env:USERPROFILE '.codex') 'sessions'),
        [string]$ClaudeProjectsRoot = (Join-Path (Join-Path $env:USERPROFILE '.claude') 'projects'),
        [string]$ClaudeSettingsPath = (Join-Path (Join-Path $env:USERPROFILE '.claude') 'settings.json'),
        [string]$CCSwitchDatabasePath = (Join-Path (Join-Path $env:USERPROFILE '.cc-switch') 'cc-switch.db'),
        [int]$CCSwitchCacheSeconds = 30,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $today = $Now.ToLocalTime().Date
    $recentCutoff = $Now.ToLocalTime().Date.AddDays(-8)
    $codex = New-AgentUsageFileSummary -Provider 'codex'
    $claude = New-AgentUsageFileSummary -Provider 'claude'
    $activeCacheKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $codexFiles = @()
    if (Test-Path -LiteralPath $CodexSessionsRoot) {
        $recentCodexFiles = @(Get-AgentUsageFiles -Root $CodexSessionsRoot -Filter 'rollout-*.jsonl' |
            Where-Object { $_.LastWriteTime -ge $recentCutoff } |
            Sort-Object LastWriteTime -Descending)
        $codexFiles = @($recentCodexFiles | Where-Object { $_.LastWriteTime -ge $today })
        if ($recentCodexFiles.Count -gt 0 -and @($codexFiles | Where-Object { $_.FullName -eq $recentCodexFiles[0].FullName }).Count -eq 0) {
            $codexFiles += $recentCodexFiles[0]
        }
    }
    foreach ($file in $codexFiles) {
        $cacheKey = 'codex|' + $file.FullName.ToLowerInvariant()
        $null = $activeCacheKeys.Add($cacheKey)
        $cached = if ($script:AgentUsageFileCache.ContainsKey($cacheKey)) { $script:AgentUsageFileCache[$cacheKey] } else { $null }
        if ($null -ne $cached -and [string]$cached.day -eq $today.ToString('yyyy-MM-dd') -and [long]$cached.length -eq $file.Length -and [long]$cached.lastWriteTicks -eq $file.LastWriteTimeUtc.Ticks) {
            $summary = $cached.summary
        }
        else {
            $canAppend = $null -ne $cached -and
                [string]$cached.day -eq $today.ToString('yyyy-MM-dd') -and
                $null -ne $cached.PSObject.Properties['offset'] -and
                $file.Length -gt [long]$cached.length -and $file.Length -ge [long]$cached.offset
            $readResult = if ($canAppend) {
                Read-CodexUsageFileSummary -File $file -Today $today -StartOffset ([long]$cached.offset) -ExistingSummary $cached.summary
            }
            else {
                Read-CodexUsageFileSummary -File $file -Today $today
            }
            $summary = $readResult.summary
            $script:AgentUsageFileCache[$cacheKey] = [pscustomobject]@{
                day = $today.ToString('yyyy-MM-dd')
                length = $file.Length
                lastWriteTicks = $file.LastWriteTimeUtc.Ticks
                summary = $summary
                offset = [long]$readResult.offset
            }
        }
        Merge-AgentUsageTotals -Target $codex.totals -Source $summary.totals
        if ($null -ne $summary.latestFiveHourRateAt -and ($null -eq $codex.latestFiveHourRateAt -or $summary.latestFiveHourRateAt -gt $codex.latestFiveHourRateAt)) {
            $codex.latestFiveHourRate = $summary.latestFiveHourRate
            $codex.latestFiveHourRateAt = $summary.latestFiveHourRateAt
        }
        if ($null -ne $summary.latestWeeklyRateAt -and ($null -eq $codex.latestWeeklyRateAt -or $summary.latestWeeklyRateAt -gt $codex.latestWeeklyRateAt)) {
            $codex.latestWeeklyRate = $summary.latestWeeklyRate
            $codex.latestWeeklyRateAt = $summary.latestWeeklyRateAt
        }
    }

    $usesCustomEndpoint = Test-ClaudeCustomEndpointConfigured -SettingsPath $ClaudeSettingsPath
    $claudeSource = if ($usesCustomEndpoint) { 'transcript-estimate' } else { 'transcript-official' }
    $claudeIsEstimate = $usesCustomEndpoint
    $ccSwitchUsage = $null
    if ($usesCustomEndpoint -and (Get-Command Get-CCSwitchClaudeUsage -ErrorAction SilentlyContinue)) {
        try {
            $dayStart = [DateTimeOffset]::new($today, [TimeZoneInfo]::Local.GetUtcOffset($today))
            $dayEndDate = $today.AddDays(1)
            $dayEnd = [DateTimeOffset]::new($dayEndDate, [TimeZoneInfo]::Local.GetUtcOffset($dayEndDate))
            $ccSwitchUsage = Get-CCSwitchClaudeUsage -DatabasePath $CCSwitchDatabasePath -DayStart $dayStart -DayEnd $dayEnd -CacheSeconds $CCSwitchCacheSeconds
        }
        catch {}
    }

    if ($null -ne $ccSwitchUsage) {
        Merge-AgentUsageTotals -Target $claude.totals -Source $ccSwitchUsage.totals
        $claudeSource = [string]$ccSwitchUsage.source
        $claudeIsEstimate = [bool]$ccSwitchUsage.isEstimate
    }
    else {
        $claudeFiles = @()
        if (Test-Path -LiteralPath $ClaudeProjectsRoot) {
            $claudeFiles = @(Get-AgentUsageFiles -Root $ClaudeProjectsRoot -Filter '*.jsonl' |
                Where-Object { $_.LastWriteTime -ge $today })
        }
        foreach ($file in $claudeFiles) {
            $cacheKey = 'claude|' + $file.FullName.ToLowerInvariant()
            $null = $activeCacheKeys.Add($cacheKey)
            $cached = if ($script:AgentUsageFileCache.ContainsKey($cacheKey)) { $script:AgentUsageFileCache[$cacheKey] } else { $null }
            if ($null -ne $cached -and [string]$cached.day -eq $today.ToString('yyyy-MM-dd') -and [long]$cached.length -eq $file.Length -and [long]$cached.lastWriteTicks -eq $file.LastWriteTimeUtc.Ticks) {
                $summary = $cached.summary
            }
            else {
                $canAppend = $null -ne $cached -and
                    [string]$cached.day -eq $today.ToString('yyyy-MM-dd') -and
                    $null -ne $cached.PSObject.Properties['offset'] -and
                    $null -ne $cached.PSObject.Properties['snapshots'] -and
                    $file.Length -gt [long]$cached.length -and $file.Length -ge [long]$cached.offset
                $readResult = if ($canAppend) {
                    Read-ClaudeUsageFileSummary -File $file -Today $today -StartOffset ([long]$cached.offset) -ExistingSnapshots $cached.snapshots -AnonymousIndex ([int]$cached.anonymousIndex)
                }
                else {
                    Read-ClaudeUsageFileSummary -File $file -Today $today
                }
                $summary = $readResult.summary
                $script:AgentUsageFileCache[$cacheKey] = [pscustomobject]@{
                    day = $today.ToString('yyyy-MM-dd')
                    length = $file.Length
                    lastWriteTicks = $file.LastWriteTimeUtc.Ticks
                    summary = $summary
                    offset = [long]$readResult.offset
                    snapshots = $readResult.snapshots
                    anonymousIndex = [int]$readResult.anonymousIndex
                }
            }
            Merge-AgentUsageTotals -Target $claude.totals -Source $summary.totals
        }
    }

    foreach ($cacheKey in @($script:AgentUsageFileCache.Keys)) {
        if (-not $activeCacheKeys.Contains([string]$cacheKey)) {
            $script:AgentUsageFileCache.Remove($cacheKey)
        }
    }

    $codexCachePercent = $null
    if ($codex.totals.input -gt 0) {
        $codexCachePercent = [Math]::Min(100.0, [Math]::Max(0.0, ($codex.totals.cached * 100.0 / $codex.totals.input)))
    }
    $claudeInputTotal = $claude.totals.input + $claude.totals.cached + $claude.totals.cacheCreated
    $claudeCachePercent = $null
    if ($claudeInputTotal -gt 0) {
        $claudeCachePercent = [Math]::Min(100.0, [Math]::Max(0.0, ($claude.totals.cached * 100.0 / $claudeInputTotal)))
    }

    $fiveHourRemaining = $null
    $fiveHourResetAt = $null
    if ($null -ne $codex.latestFiveHourRate) {
        $fiveHourRemaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - [double]$codex.latestFiveHourRate.usedPercent))
        $fiveHourResetAt = $codex.latestFiveHourRate.resetAt
    }
    $weeklyRemaining = $null
    $weeklyResetAt = $null
    if ($null -ne $codex.latestWeeklyRate) {
        $weeklyRemaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - [double]$codex.latestWeeklyRate.usedPercent))
        $weeklyResetAt = $codex.latestWeeklyRate.resetAt
    }

    return [pscustomobject][ordered]@{
        codex = [pscustomobject][ordered]@{
            totalTokens = if ($codex.totals.eventCount -gt 0) { $codex.totals.total } else { $null }
            fiveHourRemainingPercent = $fiveHourRemaining
            fiveHourResetAt = $fiveHourResetAt
            weeklyRemainingPercent = $weeklyRemaining
            weeklyResetAt = $weeklyResetAt
            cachePercent = $codexCachePercent
        }
        claude = [pscustomobject][ordered]@{
            totalTokens = if ($claude.totals.eventCount -gt 0) { $claude.totals.total } else { $null }
            weeklyRemainingPercent = $null
            weeklyResetAt = $null
            cachePercent = $claudeCachePercent
            source = $claudeSource
            isEstimate = $claudeIsEstimate
        }
    }
}
