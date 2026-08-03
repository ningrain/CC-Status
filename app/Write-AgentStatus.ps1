[CmdletBinding()]
param(
    [ValidateSet('codex', 'claude')]
    [string]$Provider = 'codex'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$providerName = $Provider.ToLowerInvariant()
$appRoot = $PSScriptRoot
$dataRoot = Join-Path $appRoot 'data'
$statePath = Join-Path $dataRoot 'state.json'
$logPath = Join-Path $dataRoot 'hook-errors.log'
$permissionWatcherPath = Join-Path $appRoot 'Watch-ClaudePermission.ps1'
$hookEventName = $null
$mutex = $null
$hasMutex = $false

function Write-PrivateError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        if (-not (Test-Path -LiteralPath $dataRoot)) {
            $null = New-Item -ItemType Directory -Path $dataRoot -Force
        }

        $line = '{0:o} provider={1} {2}' -f [DateTimeOffset]::UtcNow, $providerName, $ErrorRecord.Exception.Message
        [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        # Status hooks must never interfere with the host CLI.
    }
}

function Get-StringProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    if ($null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) {
        return [string]$Object.$Name
    }
    return $Default
}

function Get-ExistingProvider {
    param($Session)

    $value = Get-StringProperty -Object $Session -Name 'provider' -Default 'codex'
    if ([string]::IsNullOrWhiteSpace($value)) { return 'codex' }
    return $value.ToLowerInvariant()
}

function Start-ClaudePermissionWatcher {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$TranscriptPath,
        [string]$ToolName = ''
    )

    if (-not (Test-Path -LiteralPath $permissionWatcherPath) -or [string]::IsNullOrWhiteSpace($TranscriptPath)) {
        return
    }

    if ($TranscriptPath.StartsWith('~\')) {
        $TranscriptPath = Join-Path $env:USERPROFILE $TranscriptPath.Substring(2)
    }
    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return
    }

    try {
        $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argumentList = @(
            '-NoProfile'
            '-ExecutionPolicy Bypass'
            '-WindowStyle Hidden'
            ('-File "{0}"' -f $permissionWatcherPath.Replace('"', '\"'))
            ('-SessionId "{0}"' -f $SessionId.Replace('"', '\"'))
            ('-TranscriptPath "{0}"' -f $TranscriptPath.Replace('"', '\"'))
        )
        if (-not [string]::IsNullOrWhiteSpace($ToolName)) {
            $argumentList += ('-ToolName "{0}"' -f $ToolName.Replace('"', '\"'))
        }
        Start-Process -FilePath $powershellPath -ArgumentList ($argumentList -join ' ') -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        # The watcher is only a fallback; never let it affect Claude Code.
    }
}

try {
    $standardInput = [Console]::OpenStandardInput()
    $inputReader = [System.IO.StreamReader]::new($standardInput, [System.Text.UTF8Encoding]::new($false), $true)
    try {
        $rawInput = $inputReader.ReadToEnd()
    }
    finally {
        $inputReader.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        exit 0
    }

    $hook = $rawInput | ConvertFrom-Json
    $hookEventName = Get-StringProperty -Object $hook -Name 'hook_event_name'
    $sessionId = Get-StringProperty -Object $hook -Name 'session_id'
    $notificationType = Get-StringProperty -Object $hook -Name 'notification_type'
    $transcriptPath = Get-StringProperty -Object $hook -Name 'transcript_path'
    $toolName = Get-StringProperty -Object $hook -Name 'tool_name'

    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'Hook payload did not include session_id.'
    }

    $status = switch ($hookEventName) {
        'UserPromptSubmit' { 'working' }
        'PermissionRequest' { 'approval' }
        'PostToolUse' { 'working' }
        'PostToolUseFailure' { 'working' }
        'PostToolBatch' { 'working' }
        'PermissionDenied' { 'working' }
        'Notification' {
            switch ($notificationType) {
                'permission_prompt' { 'approval' }
                'idle_prompt' { 'completed' }
                default { $null }
            }
        }
        'Stop' { 'completed' }
        'StopFailure' { 'cancelled' }
        'SessionEnd' { 'cancelled' }
        default { $null }
    }

    if ($null -eq $status) {
        exit 0
    }

    if (-not (Test-Path -LiteralPath $dataRoot)) {
        $null = New-Item -ItemType Directory -Path $dataRoot -Force
    }

    $mutex = [System.Threading.Mutex]::new($false, 'Local\CCStatus-StateLock')
    $hasMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
    if (-not $hasMutex) {
        throw 'Timed out while waiting for the status state lock.'
    }

    $existingSessions = @()
    if (Test-Path -LiteralPath $statePath) {
        try {
            $existingState = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $existingSessions = @($existingState.sessions)
        }
        catch {
            $existingSessions = @()
        }
    }

    $now = [DateTimeOffset]::UtcNow
    $retentionCutoff = $now.AddHours(-48)
    $nextSessions = New-Object System.Collections.ArrayList
    $previousSession = $null

    foreach ($session in $existingSessions) {
        $existingProvider = Get-ExistingProvider -Session $session
        $existingSessionId = Get-StringProperty -Object $session -Name 'sessionId'
        if ($existingProvider -eq $providerName -and $existingSessionId -eq $sessionId) {
            $previousSession = $session
            continue
        }

        try {
            $updatedAt = [DateTimeOffset]::Parse([string]$session.updatedAt)
            if ($updatedAt -ge $retentionCutoff) {
                $null = $nextSessions.Add($session)
            }
        }
        catch {
            # Drop malformed or very old entries instead of breaking the hook.
        }
    }

    $cwd = Get-StringProperty -Object $hook -Name 'cwd'
    if ([string]::IsNullOrWhiteSpace($cwd) -and $null -ne $previousSession) {
        $cwd = Get-StringProperty -Object $previousSession -Name 'cwd'
    }

    $model = Get-StringProperty -Object $hook -Name 'model'
    if ([string]::IsNullOrWhiteSpace($model) -and $null -ne $previousSession) {
        $model = Get-StringProperty -Object $previousSession -Name 'model'
    }

    $turnId = if ($providerName -eq 'claude') {
        Get-StringProperty -Object $hook -Name 'prompt_id'
    }
    else {
        Get-StringProperty -Object $hook -Name 'turn_id'
    }
    if ([string]::IsNullOrWhiteSpace($turnId) -and $null -ne $previousSession) {
        $turnId = Get-StringProperty -Object $previousSession -Name 'turnId'
    }

    $startedAt = $now.ToString('o')
    $startsNewTurn = $providerName -eq 'claude' -and $hookEventName -eq 'UserPromptSubmit'
    if ($null -ne $previousSession -and -not $startsNewTurn) {
        $sameTurn = (Get-StringProperty -Object $previousSession -Name 'turnId' -Default '') -eq $turnId
        $previousStartedAt = Get-StringProperty -Object $previousSession -Name 'startedAt'
        if ($sameTurn -and -not [string]::IsNullOrWhiteSpace($previousStartedAt)) {
            $startedAt = $previousStartedAt
        }
    }

    # A session can end after a completed turn. Preserve the green completion
    # window instead of replacing it with a cancellation immediately.
    if ($providerName -eq 'claude' -and $hookEventName -eq 'SessionEnd' -and $null -ne $previousSession -and [string]$previousSession.status -eq 'completed') {
        $status = 'completed'
    }

    $sessionState = [pscustomobject][ordered]@{
        provider = $providerName
        sessionId = $sessionId
        turnId = $turnId
        status = $status
        startedAt = $startedAt
        updatedAt = $now.ToString('o')
        cwd = $cwd
        model = $model
        source = 'hook'
    }
    if ($providerName -eq 'claude') {
        $sessionState | Add-Member -NotePropertyName surface -NotePropertyValue 'cli'
    }
    elseif ($null -ne $previousSession -and $null -ne $previousSession.PSObject.Properties['surface']) {
        $sessionState | Add-Member -NotePropertyName surface -NotePropertyValue ([string]$previousSession.surface)
    }
    $null = $nextSessions.Add($sessionState)

    $state = [pscustomobject][ordered]@{
        version = 2
        updatedAt = $now.ToString('o')
        sessions = @($nextSessions)
    }

    $tempPath = '{0}.{1}.tmp' -f $statePath, $PID
    $json = $state | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $statePath -Force

    if ($providerName -eq 'claude' -and $hookEventName -eq 'PermissionRequest') {
        Start-ClaudePermissionWatcher -SessionId $sessionId -TranscriptPath $transcriptPath -ToolName $toolName
    }
}
catch {
    Write-PrivateError -ErrorRecord $_
}
finally {
    if ($hasMutex -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}

# Codex's existing Stop hook contract requires a non-blocking response. Claude
# hooks intentionally stay silent so they never inject context into the CLI.
if ($providerName -eq 'codex' -and $hookEventName -eq 'Stop') {
    [Console]::Out.Write('{"continue":true}')
}
exit 0
