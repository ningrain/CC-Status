[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$TranscriptPath,
    [string]$ToolName = '',
    [int]$TimeoutSeconds = 90,
    [int]$ExecutionTimeoutSeconds = 43200,
    [int]$HeartbeatSeconds = 30,
    [string]$ReadyPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}

$bridgePath = Join-Path $PSScriptRoot 'Write-ClaudeStatus.ps1'
$incrementalReaderPath = Join-Path $PSScriptRoot 'Read-ClaudeTranscriptIncremental.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $TimeoutSeconds))
$targetToolUseId = ''
$execution = $null
$executionMissingAt = $null
$nextHeartbeatAt = [DateTime]::MaxValue
$nextProcessCheckAt = if ($ToolName -eq 'Bash') { [DateTime]::MinValue } else { [DateTime]::MaxValue }
$nextTranscriptCheckAt = [DateTime]::MinValue
$initialProcessIds = @{}

if (-not (Test-Path -LiteralPath $incrementalReaderPath -PathType Leaf)) { exit 0 }
. $incrementalReaderPath
$transcriptCursor = New-ClaudeTranscriptCursor -Path $TranscriptPath

function Get-ProcessSnapshot {
    $snapshot = @{}
    try {
        $processFilter = "Name='bash.exe' OR Name='sh.exe' OR Name='cmd.exe' OR Name='powershell.exe' OR Name='pwsh.exe' OR Name='wsl.exe' OR Name='claude.exe' OR Name='node.exe'"
        foreach ($process in @(Get-CimInstance Win32_Process -Filter $processFilter -ErrorAction SilentlyContinue)) {
            $snapshot[[int]$process.ProcessId] = $process
        }
    }
    catch {}
    return $snapshot
}

function Find-ClaudeShellExecution {
    param(
        [Parameter(Mandatory)][hashtable]$InitialProcessIds,
        [Parameter(Mandatory)][hashtable]$CurrentProcesses
    )

    if ($ToolName -ne 'Bash') { return $null }
    $shellNames = @('bash.exe', 'sh.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'wsl.exe')
    foreach ($process in @($CurrentProcesses.Values)) {
        $processId = [int]$process.ProcessId
        if ($InitialProcessIds.ContainsKey($processId) -or [string]$process.Name -notin $shellNames) { continue }

        $parentId = [int]$process.ParentProcessId
        for ($depth = 0; $depth -lt 8 -and $parentId -gt 0; $depth++) {
            if (-not $CurrentProcesses.ContainsKey($parentId)) { break }
            $parent = $CurrentProcesses[$parentId]
            $parentName = [string]$parent.Name
            $parentCommandLine = [string]$parent.CommandLine
            if ($parentName -eq 'claude.exe' -or
                ($parentName -eq 'node.exe' -and $parentCommandLine -match '(?i)(claude-code|[\\/]claude(?:\.cmd|\.js)?(?:\s|$))')) {
                return [pscustomobject]@{
                    shellProcessId = $processId
                    claudeProcessId = [int]$parent.ProcessId
                }
            }
            $parentId = [int]$parent.ParentProcessId
        }
    }
    return $null
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

if ($ToolName -eq 'Bash') {
    $initialProcessIds = Get-ProcessSnapshot
}
if (-not [string]::IsNullOrWhiteSpace($ReadyPath)) {
    try {
        [System.IO.File]::WriteAllText($ReadyPath, '', [System.Text.UTF8Encoding]::new($false))
    }
    catch {}
}

while ([DateTime]::UtcNow -lt $deadline) {
    $now = [DateTime]::UtcNow
    if ($now -ge $nextTranscriptCheckAt) {
        $rows = @(Read-ClaudeTranscriptRowsIncremental -Path $TranscriptPath -Cursor $transcriptCursor)
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
        $nextTranscriptCheckAt = $now.AddSeconds(1)
    }
    if ($now -ge $nextProcessCheckAt) {
        if ($null -eq $execution) {
            $execution = Find-ClaudeShellExecution -InitialProcessIds $initialProcessIds -CurrentProcesses (Get-ProcessSnapshot)
            if ($null -ne $execution) {
                Invoke-ResolutionHook -EventName 'ToolExecutionStarted'
                $nextHeartbeatAt = $now.AddSeconds([Math]::Max(1, $HeartbeatSeconds))
                $deadline = $now.AddSeconds([Math]::Max(10, $ExecutionTimeoutSeconds))
            }
            $nextProcessCheckAt = $now.AddSeconds(2)
        }
        else {
            $claudeAlive = $null -ne (Get-Process -Id ([int]$execution.claudeProcessId) -ErrorAction SilentlyContinue)
            if (-not $claudeAlive) { exit 0 }

            $shellAlive = $null -ne (Get-Process -Id ([int]$execution.shellProcessId) -ErrorAction SilentlyContinue)
            if ($shellAlive) {
                $executionMissingAt = $null
                if ($now -ge $nextHeartbeatAt) {
                    Invoke-ResolutionHook -EventName 'ToolExecutionStarted'
                    $nextHeartbeatAt = $now.AddSeconds([Math]::Max(1, $HeartbeatSeconds))
                }
            }
            elseif ($null -eq $executionMissingAt) {
                $executionMissingAt = $now
            }
            elseif (($now - $executionMissingAt).TotalSeconds -ge 10) {
                exit 0
            }
            $nextProcessCheckAt = $now.AddSeconds(2)
        }
    }
    Start-Sleep -Milliseconds 250
}

exit 0
