[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

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
        foreach ($line in @(Get-Content -LiteralPath $Path -Tail 120 -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }
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

    if (-not (Test-Path -LiteralPath $ProjectsRoot)) { return @($Sessions) }
    $files = @(Get-ChildItem -LiteralPath $ProjectsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    foreach ($session in @($Sessions)) {
        if ([string]$session.provider -ne 'claude' -or [string]$session.status -notin @('working', 'approval')) { continue }
        $sessionId = [string]$session.sessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        $transcript = @($files | Where-Object { $_.BaseName -ieq $sessionId } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($transcript.Count -eq 0) { continue }

        $interruptedAt = Get-ClaudeTranscriptInterruptionTime -Path $transcript[0].FullName
        if ($null -ne $interruptedAt) {
            $session.status = 'cancelled'
            $session.updatedAt = $interruptedAt.ToString('o')
        }
    }
    return @($Sessions)
}
