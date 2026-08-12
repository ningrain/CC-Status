[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceAgentBridge = Join-Path $projectRoot 'app\Write-AgentStatus.ps1'
$sourceCodexBridge = Join-Path $projectRoot 'app\Write-Codex.ps1'
$sourceClaudeBridge = Join-Path $projectRoot 'app\Write-ClaudeStatus.ps1'
$sourceClaudeTranscriptState = Join-Path $projectRoot 'app\Get-ClaudeTranscriptState.ps1'
$sourceClaudePermissionWatcher = Join-Path $projectRoot 'app\Watch-ClaudePermission.ps1'
$sourceClaudeTurnWatcher = Join-Path $projectRoot 'app\Watch-ClaudeTurn.ps1'
$sourceClaudeIncrementalReader = Join-Path $projectRoot 'app\Read-ClaudeTranscriptIncremental.ps1'
$testRoot = Join-Path $PSScriptRoot '.test-status-bridge'
$testAgentBridge = Join-Path $testRoot 'Write-AgentStatus.ps1'
$testBridge = Join-Path $testRoot 'Write-Codex.ps1'
$testClaudeBridge = Join-Path $testRoot 'Write-ClaudeStatus.ps1'
$testClaudeTranscriptState = Join-Path $testRoot 'Get-ClaudeTranscriptState.ps1'
$testClaudePermissionWatcher = Join-Path $testRoot 'Watch-ClaudePermission.ps1'
$testClaudeTurnWatcher = Join-Path $testRoot 'Watch-ClaudeTurn.ps1'
$testClaudeIncrementalReader = Join-Path $testRoot 'Read-ClaudeTranscriptIncremental.ps1'
$statePath = Join-Path $testRoot 'data\state.json'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$fakeClaudeProcess = $null
$directPermissionWatcher = $null
$directTurnWatcher = $null

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-NoOutput {
    param($Value, [string]$Message)
    if (-not [string]::IsNullOrEmpty([string]$Value)) {
        throw "$Message Actual=[$Value]"
    }
}

function Invoke-Hook {
    param(
        [string]$EventName,
        [string]$SessionId = 'session-test-1',
        [string]$TurnId = 'turn-test-1'
    )

    $payload = [pscustomobject][ordered]@{
        session_id = $SessionId
        turn_id = $TurnId
        cwd = 'D:\随便玩玩'
        hook_event_name = $EventName
        model = 'test-model'
    } | ConvertTo-Json -Compress

    return $payload | & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $testBridge
}

function Invoke-ClaudeHook {
    param(
        [string]$EventName,
        [string]$SessionId = 'claude-session-1',
        [string]$PromptId = '',
        [string]$NotificationType = '',
        [string]$TranscriptPath = ''
    )

    $payloadProperties = [ordered]@{
        session_id = $SessionId
        cwd = 'D:\Claude 工作区'
        hook_event_name = $EventName
        tool_name = 'Bash'
        tool_input = @{ command = 'Write-Host test' }
        prompt = '不要把这段提示词写入状态文件'
    }
    if (-not [string]::IsNullOrWhiteSpace($PromptId)) {
        $payloadProperties.prompt_id = $PromptId
    }
    if (-not [string]::IsNullOrWhiteSpace($NotificationType)) {
        $payloadProperties.notification_type = $NotificationType
    }
    if (-not [string]::IsNullOrWhiteSpace($TranscriptPath)) {
        $payloadProperties.transcript_path = $TranscriptPath
    }

    $payload = [pscustomobject]$payloadProperties | ConvertTo-Json -Compress
    return $payload | & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $testClaudeBridge
}

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $testRoot -Force
Copy-Item -LiteralPath $sourceAgentBridge -Destination $testAgentBridge
Copy-Item -LiteralPath $sourceCodexBridge -Destination $testBridge
Copy-Item -LiteralPath $sourceClaudeBridge -Destination $testClaudeBridge
Copy-Item -LiteralPath $sourceClaudeTranscriptState -Destination $testClaudeTranscriptState
Copy-Item -LiteralPath $sourceClaudePermissionWatcher -Destination $testClaudePermissionWatcher
Copy-Item -LiteralPath $sourceClaudeTurnWatcher -Destination $testClaudeTurnWatcher
Copy-Item -LiteralPath $sourceClaudeIncrementalReader -Destination $testClaudeIncrementalReader

try {
    $output = Invoke-Hook -EventName 'UserPromptSubmit'
    Assert-NoOutput $output 'UserPromptSubmit must not write model-visible output.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-Equal 'working' $state.sessions[0].status 'Prompt should set working state.'
    Assert-Equal 'D:\随便玩玩' ([string]$state.sessions[0].cwd) 'UTF-8 workspace path should round-trip.'

    $output = Invoke-Hook -EventName 'PermissionRequest'
    Assert-NoOutput $output 'PermissionRequest must not decide the approval.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-Equal 'approval' $state.sessions[0].status 'Permission request should set approval state.'

    $output = Invoke-Hook -EventName 'PostToolUse'
    Assert-NoOutput $output 'PostToolUse must not write model-visible output.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-Equal 'working' $state.sessions[0].status 'Tool completion should restore working state.'

    $output = Invoke-Hook -EventName 'Stop'
    Assert-Equal '{"continue":true}' ([string]$output) 'Stop must return valid non-blocking JSON.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-Equal 'completed' $state.sessions[0].status 'Stop should set completed state.'

    $null = Invoke-Hook -EventName 'UserPromptSubmit' -SessionId 'session-test-2' -TurnId 'turn-test-2'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-Equal 2 @($state.sessions).Count 'Multiple sessions should be preserved.'

    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -PromptId 'claude-turn-1'
    Assert-NoOutput $output 'Claude UserPromptSubmit must not write model-visible output.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'claude' ([string]$claudeSession.provider) 'Claude hook should identify its provider.'
    Assert-Equal 'working' ([string]$claudeSession.status) 'Claude prompt should set working state.'
    Assert-Equal 'cli' ([string]$claudeSession.surface) 'Claude hook should identify the CLI surface.'
    Assert-Equal 'claude-turn-1' ([string]$claudeSession.turnId) 'Claude prompt id should be retained as turn identity.'
    Assert-True (-not (($claudeSession | ConvertTo-Json -Depth 10) -match '不要把这段提示词')) 'Claude prompt text must not be persisted.'

    $singleInterruptTranscriptPath = Join-Path $testRoot 'claude-session-single-interrupt.jsonl'
    $singleInterruptPrompt = [pscustomobject]@{
        type = 'user'
        promptId = 'claude-turn-single-interrupt'
        message = [pscustomobject]@{ role = 'user'; content = 'long running test' }
        timestamp = '2026-08-05T00:20:00+08:00'
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText(
        $singleInterruptTranscriptPath,
        $singleInterruptPrompt + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -SessionId 'claude-session-single-interrupt' -PromptId 'claude-turn-single-interrupt' -TranscriptPath $singleInterruptTranscriptPath
    Assert-NoOutput $output 'Single-interrupt Claude prompt must remain silent.'
    $singleInterruptMarker = [pscustomobject]@{
        type = 'user'
        promptId = 'claude-turn-single-interrupt'
        message = [pscustomobject]@{
            role = 'user'
            content = @([pscustomobject]@{ type = 'text'; text = '[Request interrupted by user]' })
        }
        timestamp = '2026-08-05T00:20:03+08:00'
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::AppendAllText(
        $singleInterruptTranscriptPath,
        $singleInterruptMarker + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    $singleInterruptState = $null
    $singleInterruptDeadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $statePath) {
            $candidateState = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $singleInterruptState = @($candidateState.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-single-interrupt' })[0]
        }
    } while (($null -eq $singleInterruptState -or [string]$singleInterruptState.status -eq 'working') -and (Get-Date) -lt $singleInterruptDeadline)
    Assert-Equal 'cancelled' ([string]$singleInterruptState.status) 'One Claude Ctrl+C transcript marker should cancel the current turn without requiring SessionEnd.'

    $output = Invoke-ClaudeHook -EventName 'PermissionRequest' -PromptId 'claude-turn-1'
    Assert-NoOutput $output 'Claude PermissionRequest must not decide the approval.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'approval' ([string]$claudeSession.status) 'Claude permission request should set approval state.'

    $output = Invoke-ClaudeHook -EventName 'ToolExecutionStarted' -PromptId 'claude-turn-1'
    Assert-NoOutput $output 'Claude tool-start detection must not write model-visible output.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'working' ([string]$claudeSession.status) 'Claude Bash execution start should restore working state before completion.'

    $output = Invoke-ClaudeHook -EventName 'PostToolUse' -PromptId 'claude-turn-1'
    Assert-NoOutput $output 'Claude PostToolUse must not write model-visible output.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'working' ([string]$claudeSession.status) 'Claude tool completion should restore working state.'

    $output = Invoke-ClaudeHook -EventName 'Stop' -PromptId 'claude-turn-1'
    Assert-NoOutput $output 'Claude Stop must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'completed' ([string]$claudeSession.status) 'Claude Stop should set completed state.'

    $interruptedTranscriptPath = Join-Path $testRoot 'claude-session-interrupted.jsonl'
    $interruptedPrompt = [pscustomobject]@{
        type = 'user'
        message = [pscustomobject]@{ content = 'long running test' }
        timestamp = '2026-08-05T00:10:00+08:00'
    } | ConvertTo-Json -Depth 10 -Compress
    $interruptedMarker = [pscustomobject]@{
        type = 'user'
        message = [pscustomobject]@{ content = '[Request interrupted by user]' }
        timestamp = '2026-08-05T00:10:03+08:00'
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText(
        $interruptedTranscriptPath,
        $interruptedPrompt + [Environment]::NewLine + $interruptedMarker + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -SessionId 'claude-session-interrupted' -PromptId 'claude-turn-interrupted'
    Assert-NoOutput $output 'Interrupted Claude prompt must remain silent.'
    $output = Invoke-ClaudeHook -EventName 'Stop' -SessionId 'claude-session-interrupted' -PromptId 'claude-turn-interrupted' -TranscriptPath $interruptedTranscriptPath
    Assert-NoOutput $output 'Interrupted Claude Stop must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $interruptedSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-interrupted' })[0]
    Assert-Equal 'cancelled' ([string]$interruptedSession.status) 'Claude Stop with an interruption transcript should set cancelled state.'

    $output = Invoke-ClaudeHook -EventName 'SessionEnd' -PromptId 'claude-turn-1'
    Assert-NoOutput $output 'Claude SessionEnd must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'completed' ([string]$claudeSession.status) 'Claude SessionEnd should not erase a recent completion.'

    $output = Invoke-ClaudeHook -EventName 'Notification' -NotificationType 'permission_prompt' -PromptId 'claude-turn-2'
    Assert-NoOutput $output 'Claude permission notification must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'approval' ([string]$claudeSession.status) 'Claude permission notification should set approval state.'

    $output = Invoke-ClaudeHook -EventName 'Notification' -NotificationType 'idle_prompt' -PromptId 'claude-turn-2'
    Assert-NoOutput $output 'Claude idle notification must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $claudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-1' })[0]
    Assert-Equal 'completed' ([string]$claudeSession.status) 'Claude idle notification should clear a stale approval state.'

    $deniedTranscriptPath = Join-Path $testRoot 'claude-session-denied.jsonl'
    $deniedToolUse = [pscustomobject]@{
        type = 'assistant'
        message = [pscustomobject]@{
            content = @([pscustomobject]@{ type = 'tool_use'; id = 'test-tool-use-denied'; name = 'Bash'; input = @{ command = 'Write-Host test' } })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($deniedTranscriptPath, $deniedToolUse + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -SessionId 'claude-session-denied' -PromptId 'claude-turn-denied'
    Assert-NoOutput $output 'Denied Claude prompt must remain silent.'
    $output = Invoke-ClaudeHook -EventName 'PermissionRequest' -SessionId 'claude-session-denied' -PromptId 'claude-turn-denied' -TranscriptPath $deniedTranscriptPath
    Assert-NoOutput $output 'Denied Claude permission request must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $deniedSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-denied' })[0]
    Assert-Equal 'approval' ([string]$deniedSession.status) 'Denied Claude permission request should initially set approval state.'

    $deniedToolResult = [pscustomobject]@{
        type = 'user'
        message = [pscustomobject]@{
            content = @([pscustomobject]@{ type = 'tool_result'; tool_use_id = 'test-tool-use-denied'; is_error = $true; content = 'User denied permission' })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::AppendAllText($deniedTranscriptPath, $deniedToolResult + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    $deniedState = $null
    $deniedDeadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $statePath) {
            $candidateState = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $deniedState = @($candidateState.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-denied' })[0]
        }
    } while (($null -eq $deniedState -or [string]$deniedState.status -eq 'approval') -and (Get-Date) -lt $deniedDeadline)
    Assert-Equal 'working' ([string]$deniedState.status) 'Manual Claude permission denial should clear approval through the transcript watcher.'

    $startedTranscriptPath = Join-Path $testRoot 'claude-session-started.jsonl'
    $startedToolUse = [pscustomobject]@{
        type = 'assistant'
        message = [pscustomobject]@{
            content = @([pscustomobject]@{ type = 'tool_use'; id = 'test-tool-use-started'; name = 'Bash'; input = @{ command = 'Start-Sleep -Seconds 5' } })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($startedTranscriptPath, $startedToolUse + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -SessionId 'claude-session-started' -PromptId 'claude-turn-started'
    Assert-NoOutput $output 'Started Claude prompt must remain silent.'
    $output = Invoke-ClaudeHook -EventName 'PermissionRequest' -SessionId 'claude-session-started' -PromptId 'claude-turn-started' -TranscriptPath $startedTranscriptPath
    Assert-NoOutput $output 'Started Claude permission request must remain silent.'
    Start-Sleep -Seconds 1

    $permissionWatcherReadyPath = Join-Path $testRoot 'permission-watcher.ready'
    $directPermissionWatcher = Start-Process -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$testClaudePermissionWatcher`"",
            '-SessionId', 'claude-session-started',
            '-TranscriptPath', "`"$startedTranscriptPath`"",
            '-ToolName', 'Bash',
            '-TimeoutSeconds', '8',
            '-ExecutionTimeoutSeconds', '8',
            '-HeartbeatSeconds', '1',
            '-ReadyPath', "`"$permissionWatcherReadyPath`""
        ) `
        -WindowStyle Hidden -PassThru
    $permissionWatcherReadyDeadline = (Get-Date).AddSeconds(5)
    while (-not (Test-Path -LiteralPath $permissionWatcherReadyPath) -and (Get-Date) -lt $permissionWatcherReadyDeadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $permissionWatcherReadyPath) 'Permission watcher did not finish its initial process snapshot.'

    $fakeClaudePath = Join-Path $testRoot 'claude.exe'
    Copy-Item -LiteralPath $env:ComSpec -Destination $fakeClaudePath -Force
    $fakeClaudeProcess = Start-Process -FilePath $fakeClaudePath `
        -ArgumentList @('/c', 'powershell.exe -NoProfile -Command "Start-Sleep -Seconds 8"') `
        -WindowStyle Hidden -PassThru

    $startedState = $null
    $startedDeadline = (Get-Date).AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 150
        if (Test-Path -LiteralPath $statePath) {
            $candidateState = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $startedState = @($candidateState.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-started' })[0]
        }
    } while (($null -eq $startedState -or [string]$startedState.status -eq 'approval') -and (Get-Date) -lt $startedDeadline)
    Assert-Equal 'working' ([string]$startedState.status) 'Running Claude Bash process did not clear approval before command completion.'
    Assert-True (-not $fakeClaudeProcess.HasExited) 'Claude Bash process completed before the working-state assertion.'

    $firstWorkingUpdate = [DateTimeOffset]::Parse([string]$startedState.updatedAt)
    $heartbeatState = $startedState
    $heartbeatDeadline = (Get-Date).AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 200
        $candidateState = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $heartbeatState = @($candidateState.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-started' })[0]
    } while ([DateTimeOffset]::Parse([string]$heartbeatState.updatedAt) -le $firstWorkingUpdate -and (Get-Date) -lt $heartbeatDeadline)
    Assert-True ([DateTimeOffset]::Parse([string]$heartbeatState.updatedAt) -gt $firstWorkingUpdate) 'Long-running Claude Bash process did not refresh its working heartbeat.'
    Assert-True (-not $fakeClaudeProcess.HasExited) 'Claude Bash process ended before the heartbeat assertion.'

    $startedToolResult = [pscustomobject]@{
        type = 'user'
        message = [pscustomobject]@{
            content = @([pscustomobject]@{ type = 'tool_result'; tool_use_id = 'test-tool-use-started'; is_error = $false; content = 'done' })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::AppendAllText($startedTranscriptPath, $startedToolResult + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Assert-True ($directPermissionWatcher.WaitForExit(5000)) 'Permission watcher did not stop after the Bash result was written.'

    $fetchTranscriptPath = Join-Path $testRoot 'claude-session-web-fetch.jsonl'
    $fetchPrompt = [pscustomobject]@{
        type = 'user'
        promptId = 'claude-turn-web-fetch'
        message = [pscustomobject]@{ role = 'user'; content = 'fetch a slow page' }
    } | ConvertTo-Json -Depth 10 -Compress
    $fetchToolUse = [pscustomobject]@{
        type = 'assistant'
        message = [pscustomobject]@{
            content = @([pscustomobject]@{ type = 'tool_use'; id = 'test-web-fetch'; name = 'WebFetch'; input = @{ url = 'https://example.com' } })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText(
        $fetchTranscriptPath,
        $fetchPrompt + [Environment]::NewLine + $fetchToolUse + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -SessionId 'claude-session-web-fetch' -PromptId 'claude-turn-web-fetch'
    Assert-NoOutput $output 'WebFetch Claude prompt must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $fetchState = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-web-fetch' })[0]
    $fetchInitialUpdate = [DateTimeOffset]::Parse([string]$fetchState.updatedAt)

    $turnWatcherReadyPath = Join-Path $testRoot 'turn-watcher.ready'
    $directTurnWatcher = Start-Process -FilePath $windowsPowerShell `
        -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$testClaudeTurnWatcher`"",
            '-SessionId', 'claude-session-web-fetch',
            '-TranscriptPath', "`"$fetchTranscriptPath`"",
            '-PromptId', 'claude-turn-web-fetch',
            '-TimeoutSeconds', '8',
            '-HeartbeatSeconds', '1',
            '-ReadyPath', "`"$turnWatcherReadyPath`""
        ) `
        -WindowStyle Hidden -PassThru
    $turnWatcherReadyDeadline = (Get-Date).AddSeconds(5)
    while (-not (Test-Path -LiteralPath $turnWatcherReadyPath) -and (Get-Date) -lt $turnWatcherReadyDeadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $turnWatcherReadyPath) 'Turn watcher did not start.'

    $fetchHeartbeatDeadline = (Get-Date).AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 200
        $candidateState = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $fetchState = @($candidateState.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-web-fetch' })[0]
    } while ([DateTimeOffset]::Parse([string]$fetchState.updatedAt) -le $fetchInitialUpdate -and (Get-Date) -lt $fetchHeartbeatDeadline)
    Assert-Equal 'working' ([string]$fetchState.status) 'Long-running WebFetch should remain working.'
    Assert-True ([DateTimeOffset]::Parse([string]$fetchState.updatedAt) -gt $fetchInitialUpdate) 'Long-running WebFetch did not refresh its turn heartbeat.'

    $output = Invoke-ClaudeHook -EventName 'PermissionRequest' -SessionId 'claude-session-web-fetch' -PromptId 'claude-turn-web-fetch'
    Assert-NoOutput $output 'WebFetch permission request must remain silent.'
    Start-Sleep -Milliseconds 1500
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $fetchState = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-web-fetch' })[0]
    Assert-Equal 'approval' ([string]$fetchState.status) 'Turn heartbeat must not overwrite a permission request.'

    $fetchTurnEnd = [pscustomobject]@{ type = 'system'; subtype = 'turn_duration'; durationMs = 3000 } | ConvertTo-Json -Compress
    [System.IO.File]::AppendAllText($fetchTranscriptPath, $fetchTurnEnd + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Assert-True ($directTurnWatcher.WaitForExit(5000)) 'Turn watcher did not stop after WebFetch turn completion.'

    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -SessionId 'claude-session-web-fetch' -PromptId 'claude-turn-after-fetch'
    Assert-NoOutput $output 'Prompt after WebFetch must remain silent.'
    $output = Invoke-ClaudeHook -EventName 'TurnHeartbeat' -SessionId 'claude-session-web-fetch' -PromptId 'claude-turn-web-fetch'
    Assert-NoOutput $output 'Stale turn heartbeat must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $fetchState = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-web-fetch' })[0]
    Assert-Equal 'claude-turn-after-fetch' ([string]$fetchState.turnId) 'A stale heartbeat must not replace the current Claude turn.'

    $output = Invoke-ClaudeHook -EventName 'UserPromptSubmit' -SessionId 'claude-session-2' -PromptId 'claude-turn-2'
    Assert-NoOutput $output 'Second Claude prompt must remain silent.'
    $output = Invoke-ClaudeHook -EventName 'StopFailure' -SessionId 'claude-session-2' -PromptId 'claude-turn-2'
    Assert-NoOutput $output 'Claude StopFailure must remain silent.'
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $failedClaudeSession = @($state.sessions | Where-Object { $_.provider -eq 'claude' -and $_.sessionId -eq 'claude-session-2' })[0]
    Assert-Equal 'cancelled' ([string]$failedClaudeSession.status) 'Claude StopFailure should set cancelled state.'

    Write-Host 'Status bridge tests passed for Codex and Claude.' -ForegroundColor Green
}
finally {
    if ($null -ne $directTurnWatcher -and -not $directTurnWatcher.HasExited) {
        $directTurnWatcher.Kill()
        $directTurnWatcher.WaitForExit()
    }
    if ($null -ne $directPermissionWatcher -and -not $directPermissionWatcher.HasExited) {
        $directPermissionWatcher.Kill()
        $directPermissionWatcher.WaitForExit()
    }
    if ($null -ne $fakeClaudeProcess -and -not $fakeClaudeProcess.HasExited) {
        $fakeClaudeProcess.Kill()
        $fakeClaudeProcess.WaitForExit()
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
