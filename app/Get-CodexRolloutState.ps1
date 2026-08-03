[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

if ($null -eq (Get-Variable -Name CodexRolloutCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CodexRolloutCache = @{}
}

function Read-CodexSharedText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Start,
        [Parameter(Mandatory)][int]$MaximumBytes
    )

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $safeStart = [Math]::Max(0, [Math]::Min($Start, $stream.Length))
        $null = $stream.Seek($safeStart, [System.IO.SeekOrigin]::Begin)
        $available = [Math]::Min([long]$MaximumBytes, $stream.Length - $safeStart)
        if ($available -le 0) { return '' }

        $buffer = New-Object byte[] ([int]$available)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $offset)
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertTo-CodexUtcTimestamp {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]([DateTime]$Value)).ToUniversalTime().ToString('o')
    }

    return [DateTimeOffset]::Parse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime().ToString('o')
}

function Get-AgentSessionProvider {
    param([object]$Session)

    if ($null -ne $Session.PSObject.Properties['provider'] -and -not [string]::IsNullOrWhiteSpace([string]$Session.provider)) {
        return ([string]$Session.provider).ToLowerInvariant()
    }
    return 'codex'
}

function Get-AgentSessionIdentity {
    param([object]$Session)

    $provider = Get-AgentSessionProvider -Session $Session
    $sessionId = [string]$Session.sessionId
    $turnId = [string]$Session.turnId
    $sessionKey = if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $sessionId } else { $turnId }
    if ([string]::IsNullOrWhiteSpace($sessionKey)) { return '' }
    return $provider + '|' + $sessionKey
}

function Test-CodexRolloutIsLive {
    param([Parameter(Mandatory)][string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::None
        )
        return $false
    }
    catch {
        # Codex keeps the active rollout open. Once the owning process exits,
        # an exclusive read succeeds and the session is no longer live.
        return $true
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Resolve-CodexSessionStates {
    [CmdletBinding()]
    param(
        [object[]]$Sessions,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [TimeSpan]$OrphanGrace = ([TimeSpan]::FromSeconds(10))
    )

    $surfaceBySession = @{}
    $terminalByTurn = @{}
    $orphanedWorkingTurns = @{}

    foreach ($session in @($Sessions)) {
        $sessionId = [string]$session.sessionId
        $turnId = [string]$session.turnId
        $sessionKey = Get-AgentSessionIdentity -Session $session
        if (-not [string]::IsNullOrWhiteSpace($sessionKey) -and $null -ne $session.PSObject.Properties['surface'] -and -not [string]::IsNullOrWhiteSpace([string]$session.surface)) {
            $surfaceBySession[$sessionKey] = [string]$session.surface
        }

        if ([string]::IsNullOrWhiteSpace($sessionId) -or [string]::IsNullOrWhiteSpace($turnId)) { continue }
        if ($null -eq $session.PSObject.Properties['source'] -or [string]$session.source -ne 'rollout') { continue }

        $turnKey = (Get-AgentSessionProvider -Session $session) + '|' + $sessionId + '|' + $turnId
        $status = [string]$session.status
        if ($status -in @('completed', 'cancelled')) {
            $terminalByTurn[$turnKey] = $session
            continue
        }

        $hasLiveness = $null -ne $session.PSObject.Properties['isLive']
        if ($status -eq 'working' -and $hasLiveness -and -not [bool]$session.isLive) {
            try {
                $updatedAt = [DateTimeOffset]::Parse([string]$session.updatedAt)
                if ($updatedAt -le $Now.Subtract($OrphanGrace)) {
                    $orphanedWorkingTurns[$turnKey] = $true
                }
            }
            catch {}
        }
    }

    $filtered = New-Object System.Collections.ArrayList
    foreach ($session in @($Sessions)) {
        $sessionId = [string]$session.sessionId
        $turnId = [string]$session.turnId
        $turnKey = if (-not [string]::IsNullOrWhiteSpace($sessionId) -and -not [string]::IsNullOrWhiteSpace($turnId)) { (Get-AgentSessionProvider -Session $session) + '|' + $sessionId + '|' + $turnId } else { '' }

        if ($turnKey -and $terminalByTurn.ContainsKey($turnKey)) {
            $isAuthoritativeTerminal = $null -ne $session.PSObject.Properties['source'] -and [string]$session.source -eq 'rollout' -and [string]$session.status -in @('completed', 'cancelled')
            if (-not $isAuthoritativeTerminal) { continue }
        }
        elseif ($turnKey -and $orphanedWorkingTurns.ContainsKey($turnKey)) {
            # A task whose rollout file is no longer held open was terminated
            # without a final hook (for example Task Manager or a hard CLI exit).
            continue
        }

        $null = $filtered.Add($session)
    }

    $latestBySession = @{}
    foreach ($session in @($filtered)) {
        try {
            $key = Get-AgentSessionIdentity -Session $session
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $updatedAt = [DateTimeOffset]::Parse([string]$session.updatedAt)
            if (-not $latestBySession.ContainsKey($key) -or $updatedAt -ge [DateTimeOffset]::Parse([string]$latestBySession[$key].updatedAt)) {
                $latestBySession[$key] = $session
            }
        }
        catch {}
    }

    # 同一会话可能同时有 hook 记录（无 isLive）和 rollout 记录（有 isLive）。
    # 合并时以最新记录为准，但存活状态必须从 rollout 记录继承，
    # 否则活跃会话会被误判为“仅 hook 会话”而过早过期。
    $liveBySession = @{}
    foreach ($session in @($filtered)) {
        try {
            if ($null -ne $session.PSObject.Properties['isLive'] -and [bool]$session.isLive) {
                $key = Get-AgentSessionIdentity -Session $session
                if (-not [string]::IsNullOrWhiteSpace($key)) { $liveBySession[$key] = $true }
            }
        }
        catch {}
    }

    $resolved = @($latestBySession.Values)
    foreach ($session in $resolved) {
        $key = Get-AgentSessionIdentity -Session $session
        if ($liveBySession.ContainsKey($key) -and $null -eq $session.PSObject.Properties['isLive']) {
            $session | Add-Member -NotePropertyName isLive -NotePropertyValue $true
        }
        if ($surfaceBySession.ContainsKey($key) -and ($null -eq $session.PSObject.Properties['surface'] -or [string]::IsNullOrWhiteSpace([string]$session.surface))) {
            $session | Add-Member -NotePropertyName surface -NotePropertyValue $surfaceBySession[$key]
        }
    }
    return $resolved
}

function Get-CodexRolloutSessions {
    [CmdletBinding()]
    param(
        [string]$SessionsRoot = (Join-Path (Join-Path $env:USERPROFILE '.codex') 'sessions'),
        [int]$MaximumFiles = 30,
        [int]$TailBytes = 33554432,
        [TimeSpan]$MaximumAge = ([TimeSpan]::FromHours(12))
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return @() }

    $cutoff = [DateTime]::UtcNow.Subtract($MaximumAge)
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $cutoff } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First $MaximumFiles)

    $sessions = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        try {
            $isLive = Test-CodexRolloutIsLive -Path $file.FullName
            $cacheKey = $file.FullName.ToLowerInvariant()
            $cached = if ($script:CodexRolloutCache.ContainsKey($cacheKey)) { $script:CodexRolloutCache[$cacheKey] } else { $null }
            if ($null -ne $cached -and [long]$cached.length -eq $file.Length -and [long]$cached.lastWriteTicks -eq $file.LastWriteTimeUtc.Ticks) {
                if ($null -eq $cached.session.PSObject.Properties['isLive']) {
                    $cached.session | Add-Member -NotePropertyName isLive -NotePropertyValue $isLive
                }
                else {
                    $cached.session.isLive = $isLive
                }
                $null = $sessions.Add($cached.session)
                continue
            }

            $start = [Math]::Max(0, $file.Length - $TailBytes)
            if ($null -ne $cached -and $file.Length -ge [long]$cached.length) {
                $incrementalStart = [Math]::Max(0, [long]$cached.length - 65536)
                if (($file.Length - $incrementalStart) -le $TailBytes) {
                    $start = $incrementalStart
                }
            }
            $bytesToRead = [int][Math]::Min([long]$TailBytes, $file.Length - $start)
            $text = Read-CodexSharedText -Path $file.FullName -Start $start -MaximumBytes $bytesToRead
            if ($start -gt 0) {
                $firstNewline = $text.IndexOf("`n")
                if ($firstNewline -ge 0) { $text = $text.Substring($firstNewline + 1) }
            }

            $lines = @($text -split "`r?`n")
            $lifecycle = $null
            $cwd = if ($null -ne $cached) { [string]$cached.session.cwd } else { '' }
            $originator = if ($null -ne $cached -and $null -ne $cached.session.PSObject.Properties['originator']) { [string]$cached.session.originator } else { '' }
            $taskSource = if ($null -ne $cached -and $null -ne $cached.session.PSObject.Properties['taskSource']) { [string]$cached.session.taskSource } else { '' }

            for ($index = $lines.Count - 1; $index -ge 0; $index--) {
                $line = $lines[$index]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($null -eq $lifecycle -and $line -notmatch '"(task_started|task_complete|turn_aborted)"') { continue }
                if ($cwd -and $null -ne $lifecycle) { break }

                try {
                    $item = $line | ConvertFrom-Json
                    if (-not $cwd -and ([string]$item.type -in @('turn_context', 'session_meta')) -and $null -ne $item.payload.cwd) {
                        $cwd = [string]$item.payload.cwd
                    }
                    if ([string]$item.type -eq 'session_meta') {
                        if (-not $originator -and $null -ne $item.payload.PSObject.Properties['originator']) { $originator = [string]$item.payload.originator }
                        if (-not $taskSource -and $null -ne $item.payload.PSObject.Properties['source']) { $taskSource = [string]$item.payload.source }
                    }
                    if ($null -eq $lifecycle -and [string]$item.type -eq 'event_msg' -and [string]$item.payload.type -in @('task_started', 'task_complete', 'turn_aborted')) {
                        $lifecycle = $item
                    }
                }
                catch {}
            }

            if ($null -eq $lifecycle -and $null -ne $cached) {
                $script:CodexRolloutCache[$cacheKey] = [pscustomobject]@{
                    length = $file.Length
                    lastWriteTicks = $file.LastWriteTimeUtc.Ticks
                    session = $cached.session
                }
                $null = $sessions.Add($cached.session)
                continue
            }
            if ($null -eq $lifecycle) { continue }

            if (-not $cwd -or -not $originator -or -not $taskSource) {
                $head = Read-CodexSharedText -Path $file.FullName -Start 0 -MaximumBytes 65536
                foreach ($line in @($head -split "`r?`n")) {
                    if ($line -notmatch '"session_meta"') { continue }
                    try {
                        $item = $line | ConvertFrom-Json
                        if ([string]$item.type -eq 'session_meta') {
                            if (-not $cwd -and $null -ne $item.payload.PSObject.Properties['cwd']) { $cwd = [string]$item.payload.cwd }
                            if (-not $originator -and $null -ne $item.payload.PSObject.Properties['originator']) { $originator = [string]$item.payload.originator }
                            if (-not $taskSource -and $null -ne $item.payload.PSObject.Properties['source']) { $taskSource = [string]$item.payload.source }
                            if ($cwd -and $originator -and $taskSource) { break }
                        }
                    }
                    catch {}
                }
            }

            $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($sessionId -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$') {
                $sessionId = $Matches[1]
            }

            $eventType = [string]$lifecycle.payload.type
            $timestamp = ConvertTo-CodexUtcTimestamp -Value $lifecycle.timestamp
            $turnId = if ($null -ne $lifecycle.payload.turn_id) { [string]$lifecycle.payload.turn_id } else { '' }
            $surface = if ($taskSource -eq 'cli' -or $originator -match '(?i)codex-tui|cli') { 'cli' } elseif ($originator -match '(?i)Codex Desktop') { 'desktop' } else { 'unknown' }
            $session = [pscustomobject][ordered]@{
                provider = 'codex'
                sessionId = $sessionId
                turnId = $turnId
                status = switch ($eventType) {
                    'task_started' { 'working' }
                    'task_complete' { 'completed' }
                    default { 'cancelled' }
                }
                startedAt = $timestamp
                updatedAt = $timestamp
                cwd = $cwd
                model = ''
                source = 'rollout'
                surface = $surface
                originator = $originator
                taskSource = $taskSource
                isLive = $isLive
            }
            $script:CodexRolloutCache[$cacheKey] = [pscustomobject]@{
                length = $file.Length
                lastWriteTicks = $file.LastWriteTimeUtc.Ticks
                session = $session
            }
            $null = $sessions.Add($session)
        }
        catch {
            # A partially-written or locked rollout must not interrupt the status app.
        }
    }

    return @($sessions)
}
