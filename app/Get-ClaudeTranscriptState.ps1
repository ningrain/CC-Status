[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

if ($null -eq (Get-Variable -Name ClaudeTranscriptInterruptionCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:ClaudeTranscriptInterruptionCache = @{}
}

function Read-ClaudeTranscriptTailRows {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaximumBytes = 1048576
    )

    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [Math]::Max(0L, $stream.Length - [Math]::Max(65536, $MaximumBytes))
        $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $available = $stream.Length - $start
        if ($available -le 0) { return @() }
        $buffer = New-Object byte[] ([int]$available)
        $readTotal = 0
        while ($readTotal -lt $buffer.Length) {
            $read = $stream.Read($buffer, $readTotal, $buffer.Length - $readTotal)
            if ($read -le 0) { break }
            $readTotal += $read
        }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $readTotal)
        if ($start -gt 0) {
            $firstNewline = $text.IndexOf("`n")
            if ($firstNewline -lt 0) { return @() }
            $text = $text.Substring($firstNewline + 1)
        }
        $rows = New-Object System.Collections.ArrayList
        foreach ($line in @($text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $null = $rows.Add(($line | ConvertFrom-Json)) } catch {}
        }
        return @($rows)
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertTo-ClaudeTranscriptTimestamp {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
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

function Get-ClaudeTranscriptText {
    param([object]$Message)

    if ($null -eq $Message) { return '' }
    if ($Message -is [string]) { return [string]$Message }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Message.PSObject.Properties['text'] -and $null -ne $Message.text) {
        $parts.Add([string]$Message.text)
    }
    if ($null -ne $Message.PSObject.Properties['content'] -and $null -ne $Message.content) {
        foreach ($part in @($Message.content)) {
            if ($part -is [string]) {
                $parts.Add([string]$part)
            }
            elseif ($null -ne $part.PSObject.Properties['text'] -and $null -ne $part.text) {
                $parts.Add([string]$part.text)
            }
            elseif ($null -ne $part.PSObject.Properties['type']) {
                $parts.Add("[$([string]$part.type)]")
            }
        }
    }
    return ($parts -join ' ')
}

function Test-ClaudeTranscriptToolResult {
    param([object]$Row)

    if ($null -eq $Row -or $null -eq $Row.PSObject.Properties['message'] -or $null -eq $Row.message -or $Row.message -is [string]) { return $false }
    if ($null -eq $Row.message.PSObject.Properties['content'] -or $null -eq $Row.message.content) { return $false }
    foreach ($part in @($Row.message.content)) {
        if ($null -ne $part.PSObject.Properties['type'] -and [string]$part.type -eq 'tool_result') {
            return $true
        }
    }
    return $false
}

function Get-ClaudeTranscriptInterruptionTime {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $lastPromptAt = $null
    $lastInterruptedAt = $null
    try {
        foreach ($row in @(Read-ClaudeTranscriptTailRows -Path $Path)) {
            if ([string]$row.type -ne 'user' -or (Test-ClaudeTranscriptToolResult -Row $row)) { continue }

            $timestamp = ConvertTo-ClaudeTranscriptTimestamp -Value $row.timestamp
            if ($null -eq $timestamp) { continue }
            $text = Get-ClaudeTranscriptText -Message $row.message
            if ($text -match '(?i)Request interrupted by user') {
                $lastInterruptedAt = $timestamp
            }
            elseif (-not [string]::IsNullOrWhiteSpace($text)) {
                $lastPromptAt = $timestamp
            }
        }
    }
    catch {
        return $null
    }

    if ($null -eq $lastInterruptedAt) { return $null }
    if ($null -ne $lastPromptAt -and $lastPromptAt -gt $lastInterruptedAt) { return $null }
    return $lastInterruptedAt
}

function Resolve-ClaudeTranscriptStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Sessions,
        [string]$ProjectsRoot = (Join-Path (Join-Path $env:USERPROFILE '.claude') 'projects'),
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if (-not (Test-Path -LiteralPath $ProjectsRoot)) {
        $script:ClaudeTranscriptInterruptionCache.Clear()
        return @($Sessions)
    }
    $activeClaudeSessions = @($Sessions | Where-Object {
        [string]$_.provider -eq 'claude' -and [string]$_.status -in @('working', 'approval')
    })
    if ($activeClaudeSessions.Count -eq 0) {
        $script:ClaudeTranscriptInterruptionCache.Clear()
        return @($Sessions)
    }
    $files = $null
    $activeCacheKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($session in $activeClaudeSessions) {
        $sessionId = [string]$session.sessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        $transcript = @()
        if ($null -ne $session.PSObject.Properties['transcriptPath'] -and
            -not [string]::IsNullOrWhiteSpace([string]$session.transcriptPath) -and
            (Test-Path -LiteralPath ([string]$session.transcriptPath) -PathType Leaf)) {
            $transcript = @((Get-Item -LiteralPath ([string]$session.transcriptPath)))
        }
        else {
            if ($null -eq $files) {
                $files = @(Get-ChildItem -LiteralPath $ProjectsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
            }
            $transcript = @($files | Where-Object { $_.BaseName -ieq $sessionId } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        }
        if ($transcript.Count -eq 0) { continue }

        $transcriptFile = $transcript[0]
        $transcriptKey = $transcriptFile.FullName.ToLowerInvariant()
        $null = $activeCacheKeys.Add($transcriptKey)
        $cachedInterruption = if ($script:ClaudeTranscriptInterruptionCache.ContainsKey($transcriptKey)) { $script:ClaudeTranscriptInterruptionCache[$transcriptKey] } else { $null }
        if ($null -ne $cachedInterruption -and [long]$cachedInterruption.length -eq $transcriptFile.Length -and [long]$cachedInterruption.lastWriteTicks -eq $transcriptFile.LastWriteTimeUtc.Ticks) {
            $interruptedAt = $cachedInterruption.value
        }
        else {
            $interruptedAt = Get-ClaudeTranscriptInterruptionTime -Path $transcriptFile.FullName
            $script:ClaudeTranscriptInterruptionCache[$transcriptKey] = [pscustomobject]@{
                length = $transcriptFile.Length
                lastWriteTicks = $transcriptFile.LastWriteTimeUtc.Ticks
                value = $interruptedAt
            }
        }
        if ($null -ne $interruptedAt) {
            $session.status = 'cancelled'
            $session.updatedAt = $interruptedAt.ToString('o')
        }
    }
    foreach ($cacheKey in @($script:ClaudeTranscriptInterruptionCache.Keys)) {
        if (-not $activeCacheKeys.Contains([string]$cacheKey)) {
            $script:ClaudeTranscriptInterruptionCache.Remove($cacheKey)
        }
    }
    return @($Sessions)
}
