[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$TranscriptPath,
    [string]$PromptId = '',
    [int]$TimeoutSeconds = 1800,
    [int]$HeartbeatSeconds = 30,
    [string]$ReadyPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}

$bridgePath = Join-Path $PSScriptRoot 'Write-ClaudeStatus.ps1'
$incrementalReaderPath = Join-Path $PSScriptRoot 'Read-ClaudeTranscriptIncremental.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(10, $TimeoutSeconds))
$nextHeartbeatAt = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $HeartbeatSeconds))

if (-not (Test-Path -LiteralPath $incrementalReaderPath -PathType Leaf)) { exit 0 }
. $incrementalReaderPath
$cursor = New-ClaudeTranscriptCursor -Path $TranscriptPath
$promptSeen = [string]::IsNullOrWhiteSpace($PromptId)

function Get-TranscriptMessageText {
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
        }
    }
    return ($parts -join ' ')
}

function Invoke-InterruptedHook {
    $payload = [pscustomobject][ordered]@{
        session_id = $SessionId
        prompt_id = $PromptId
        transcript_path = $TranscriptPath
        hook_event_name = 'Interrupted'
        cwd = ''
    } | ConvertTo-Json -Compress
    $payload | & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $bridgePath | Out-Null
}

function Invoke-TurnHeartbeat {
    $payload = [pscustomobject][ordered]@{
        session_id = $SessionId
        prompt_id = $PromptId
        transcript_path = $TranscriptPath
        hook_event_name = 'TurnHeartbeat'
        cwd = ''
    } | ConvertTo-Json -Compress
    $payload | & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $bridgePath | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($ReadyPath)) {
    try {
        [System.IO.File]::WriteAllText($ReadyPath, '', [System.Text.UTF8Encoding]::new($false))
    }
    catch {}
}

while ([DateTime]::UtcNow -lt $deadline) {
    foreach ($row in @(Read-ClaudeTranscriptRowsIncremental -Path $TranscriptPath -Cursor $cursor)) {
        $rowPromptId = if ($null -ne $row.PSObject.Properties['promptId']) { [string]$row.promptId } else { '' }
        if ([string]$row.type -eq 'user' -and $null -ne $row.PSObject.Properties['message']) {
            $text = Get-TranscriptMessageText -Message $row.message
            if ($text -match '(?i)Request interrupted by user' -and
                ([string]::IsNullOrWhiteSpace($PromptId) -or $rowPromptId -eq $PromptId)) {
                Invoke-InterruptedHook
                exit 0
            }
            if (-not [string]::IsNullOrWhiteSpace($rowPromptId)) {
                if ($rowPromptId -eq $PromptId) {
                    $promptSeen = $true
                }
                elseif ($promptSeen -and $text -notmatch '(?i)Request interrupted by user') {
                    exit 0
                }
            }
        }
        if ($promptSeen -and [string]$row.type -eq 'system' -and
            $null -ne $row.PSObject.Properties['subtype'] -and
            [string]$row.subtype -eq 'turn_duration') {
            exit 0
        }
    }
    $now = [DateTime]::UtcNow
    if ($promptSeen -and $now -ge $nextHeartbeatAt) {
        Invoke-TurnHeartbeat
        $nextHeartbeatAt = $now.AddSeconds([Math]::Max(1, $HeartbeatSeconds))
    }
    Start-Sleep -Milliseconds 1000
}

exit 0
