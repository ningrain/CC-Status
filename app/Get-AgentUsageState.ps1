[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

if ($null -eq (Get-Variable -Name AgentUsageFileCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AgentUsageFileCache = @{}
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
        latestWeeklyRate = $null
        latestWeeklyRateAt = $null
    }
}

function Read-CodexUsageFileSummary {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][DateTime]$Today
    )

    $summary = New-AgentUsageFileSummary -Provider 'codex'
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        while ($null -ne ($line = $reader.ReadLine())) {
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
            $windowMinutes = ConvertTo-AgentUsageLong -Value (Get-AgentUsageProperty -Object $primary -Name 'window_minutes')
            $usedPercent = Get-AgentUsageProperty -Object $primary -Name 'used_percent'
            if ($null -ne $windowMinutes -and $windowMinutes -eq 10080 -and $null -ne $usedPercent) {
                try {
                    $used = [double]$usedPercent
                    if ($used -ge 0) {
                        if ($null -eq $summary.latestWeeklyRateAt -or $timestamp -gt $summary.latestWeeklyRateAt) {
                            $summary.latestWeeklyRate = [pscustomobject][ordered]@{
                                usedPercent = [Math]::Min(100.0, $used)
                                resetAt = ConvertTo-AgentUsageResetTime -Value (Get-AgentUsageProperty -Object $primary -Name 'resets_at')
                            }
                            $summary.latestWeeklyRateAt = $timestamp
                        }
                    }
                }
                catch {}
            }

            if ($timestamp.ToLocalTime().Date -ne $Today) { continue }
            $lastUsage = Get-AgentUsageProperty -Object $info -Name 'last_token_usage'
            $totalAdded = Add-AgentUsageValue -Totals $summary.totals -Target 'total' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'total_tokens')
            $inputAdded = Add-AgentUsageValue -Totals $summary.totals -Target 'input' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'input_tokens')
            $null = Add-AgentUsageValue -Totals $summary.totals -Target 'output' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'output_tokens')
            $null = Add-AgentUsageValue -Totals $summary.totals -Target 'cached' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'cached_input_tokens')
            $null = Add-AgentUsageValue -Totals $summary.totals -Target 'cacheCreated' -Value (Get-AgentUsageProperty -Object $lastUsage -Name 'cache_write_input_tokens')
            if ($totalAdded -or $inputAdded) { $summary.totals.eventCount++ }
        }
        $reader.Dispose()
        return $summary
    }
    catch {
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        return $summary
    }
}

function Read-ClaudeUsageFileSummary {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][DateTime]$Today
    )

    $summary = New-AgentUsageFileSummary -Provider 'claude'
    $stream = $null
    $snapshots = @{}
    $anonymousIndex = 0
    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        while ($null -ne ($line = $reader.ReadLine())) {
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
        $reader.Dispose()
        foreach ($snapshot in $snapshots.Values) {
            $summary.totals.input += [long]$snapshot.input
            $summary.totals.output += [long]$snapshot.output
            $summary.totals.cached += [long]$snapshot.cached
            $summary.totals.cacheCreated += [long]$snapshot.cacheCreated
            $summary.totals.total += [long]$snapshot.input + [long]$snapshot.output + [long]$snapshot.cached + [long]$snapshot.cacheCreated
            $summary.totals.eventCount++
        }
        return $summary
    }
    catch {
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        return $summary
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

function Get-AgentUsageState {
    [CmdletBinding()]
    param(
        [string]$CodexSessionsRoot = (Join-Path (Join-Path $env:USERPROFILE '.codex') 'sessions'),
        [string]$ClaudeProjectsRoot = (Join-Path (Join-Path $env:USERPROFILE '.claude') 'projects'),
        [string]$ClaudeSettingsPath = (Join-Path (Join-Path $env:USERPROFILE '.claude') 'settings.json'),
        [string]$CCSwitchDatabasePath = (Join-Path (Join-Path $env:USERPROFILE '.cc-switch') 'cc-switch.db'),
        [int]$CCSwitchCacheSeconds = 60,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $today = $Now.ToLocalTime().Date
    $recentCutoff = $Now.ToLocalTime().Date.AddDays(-8)
    $codex = New-AgentUsageFileSummary -Provider 'codex'
    $claude = New-AgentUsageFileSummary -Provider 'claude'

    $codexFiles = @()
    if (Test-Path -LiteralPath $CodexSessionsRoot) {
        $codexFiles = @(Get-ChildItem -LiteralPath $CodexSessionsRoot -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $recentCutoff })
    }
    foreach ($file in $codexFiles) {
        $cacheKey = 'codex|' + $file.FullName.ToLowerInvariant()
        $cached = if ($script:AgentUsageFileCache.ContainsKey($cacheKey)) { $script:AgentUsageFileCache[$cacheKey] } else { $null }
        if ($null -ne $cached -and [string]$cached.day -eq $today.ToString('yyyy-MM-dd') -and [long]$cached.length -eq $file.Length -and [long]$cached.lastWriteTicks -eq $file.LastWriteTimeUtc.Ticks) {
            $summary = $cached.summary
        }
        else {
            $summary = Read-CodexUsageFileSummary -File $file -Today $today
            $script:AgentUsageFileCache[$cacheKey] = [pscustomobject]@{
                day = $today.ToString('yyyy-MM-dd')
                length = $file.Length
                lastWriteTicks = $file.LastWriteTimeUtc.Ticks
                summary = $summary
            }
        }
        Merge-AgentUsageTotals -Target $codex.totals -Source $summary.totals
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
            $claudeFiles = @(Get-ChildItem -LiteralPath $ClaudeProjectsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $recentCutoff })
        }
        foreach ($file in $claudeFiles) {
            $cacheKey = 'claude|' + $file.FullName.ToLowerInvariant()
            $cached = if ($script:AgentUsageFileCache.ContainsKey($cacheKey)) { $script:AgentUsageFileCache[$cacheKey] } else { $null }
            if ($null -ne $cached -and [string]$cached.day -eq $today.ToString('yyyy-MM-dd') -and [long]$cached.length -eq $file.Length -and [long]$cached.lastWriteTicks -eq $file.LastWriteTimeUtc.Ticks) {
                $summary = $cached.summary
            }
            else {
                $summary = Read-ClaudeUsageFileSummary -File $file -Today $today
                $script:AgentUsageFileCache[$cacheKey] = [pscustomobject]@{
                    day = $today.ToString('yyyy-MM-dd')
                    length = $file.Length
                    lastWriteTicks = $file.LastWriteTimeUtc.Ticks
                    summary = $summary
                }
            }
            Merge-AgentUsageTotals -Target $claude.totals -Source $summary.totals
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

    $weeklyRemaining = $null
    $weeklyResetAt = $null
    if ($null -ne $codex.latestWeeklyRate) {
        $weeklyRemaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - [double]$codex.latestWeeklyRate.usedPercent))
        $weeklyResetAt = $codex.latestWeeklyRate.resetAt
    }

    return [pscustomobject][ordered]@{
        codex = [pscustomobject][ordered]@{
            totalTokens = if ($codex.totals.eventCount -gt 0) { $codex.totals.total } else { $null }
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
