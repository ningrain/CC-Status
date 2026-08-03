[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$TranscriptPath,
    [string]$ToolName = '',
    [int]$TimeoutSeconds = 90
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

$bridgePath = Join-Path $PSScriptRoot 'Write-ClaudeStatus.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $TimeoutSeconds))
$targetToolUseId = ''

function Read-TranscriptRows {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $rows = New-Object System.Collections.ArrayList
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $row = $line | ConvertFrom-Json
                $null = $rows.Add($row)
            }
            catch {
                # Claude may be writing the final JSONL line while we read it.
            }
        }
    }
    catch {
        return @()
    }
    return @($rows)
}

function Get-LatestToolUseId {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [string]$ExpectedToolName = ''
    )

    $uses = @{}
    $sequence = 0
    foreach ($row in $Rows) {
        $sequence++
        if ([string]$row.type -eq 'assistant' -and $null -ne $row.message) {
            foreach ($block in @($row.message.content)) {
                if ([string]$block.type -eq 'tool_use' -and -not [string]::IsNullOrWhiteSpace([string]$block.id)) {
                    $uses[[string]$block.id] = [pscustomobject]@{
                        id = [string]$block.id
                        name = [string]$block.name
                        sequence = $sequence
                    }
                }
            }
        }
    }

    $candidate = @($uses.Values |
        Where-Object {
            ([string]::IsNullOrWhiteSpace($ExpectedToolName) -or [string]$_.name -eq $ExpectedToolName)
        } |
        Sort-Object sequence -Descending |
        Select-Object -First 1)[0]
    if ($null -eq $candidate) { return '' }
    return [string]$candidate.id
}

function Find-ToolResult {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$ToolUseId
    )

    foreach ($row in $Rows) {
        if ([string]$row.type -ne 'user' -or $null -eq $row.message) { continue }
        foreach ($block in @($row.message.content)) {
            if ([string]$block.type -eq 'tool_result' -and [string]$block.tool_use_id -eq $ToolUseId) {
                return $block
            }
        }
    }
    return $null
}

function Invoke-ResolutionHook {
    param([Parameter(Mandatory)][string]$EventName)

    $payload = [pscustomobject][ordered]@{
        session_id = $SessionId
        transcript_path = $TranscriptPath
        hook_event_name = $EventName
        tool_name = $ToolName
        cwd = ''
    } | ConvertTo-Json -Compress
    $payload | & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $bridgePath | Out-Null
}

while ([DateTime]::UtcNow -lt $deadline) {
    $rows = Read-TranscriptRows -Path $TranscriptPath
    if ([string]::IsNullOrWhiteSpace($targetToolUseId)) {
        $targetToolUseId = Get-LatestToolUseId -Rows $rows -ExpectedToolName $ToolName
    }
    if (-not [string]::IsNullOrWhiteSpace($targetToolUseId)) {
        $result = Find-ToolResult -Rows $rows -ToolUseId $targetToolUseId
        if ($null -ne $result) {
            $isError = $false
            if ($null -ne $result.PSObject.Properties['is_error']) {
                $isError = [bool]$result.is_error
            }
            $eventName = if ($isError) { 'PostToolUseFailure' } else { 'PostToolUse' }
            Invoke-ResolutionHook -EventName $eventName
            exit 0
        }
    }
    Start-Sleep -Milliseconds 250
}

exit 0
