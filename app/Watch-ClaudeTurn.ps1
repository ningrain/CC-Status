[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$TranscriptPath,
    [string]$PromptId = '',
    [int]$TimeoutSeconds = 1800
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

$bridgePath = Join-Path $PSScriptRoot 'Write-ClaudeStatus.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(10, $TimeoutSeconds))

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

while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $TranscriptPath -PathType Leaf) {
        $promptSeen = [string]::IsNullOrWhiteSpace($PromptId)
        try {
            foreach ($line in @(Get-Content -LiteralPath $TranscriptPath -Tail 240 -ErrorAction Stop)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $row = $line | ConvertFrom-Json } catch { continue }

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
        }
        catch {
            # Claude can append to the JSONL file while it is being read.
        }
    }
    Start-Sleep -Milliseconds 250
}

exit 0
