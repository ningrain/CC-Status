[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.test-review-regressions'))
if (-not $testRoot.StartsWith($PSScriptRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid fixture root.' }
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
$null = New-Item -ItemType Directory -Path $testRoot
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message Expected [$Expected], got [$Actual]." }
}

function Get-TestFunctions([string]$Path, [string[]]$Names) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    foreach ($item in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        if ($item.Name -in $Names) { $item.Extent.Text }
    }
}

. (Join-Path $projectRoot 'app\Get-CodexApprovalState.ps1')
. (Join-Path $projectRoot 'app\Get-CodexRolloutState.ps1')
. (Join-Path $projectRoot 'app\Get-AgentUsageState.ps1')
$uiFunctions = Get-TestFunctions (Join-Path $projectRoot 'app\CCStatus.ps1') @('Update-StatusState', 'Normalize-AgentSession', 'Invoke-AgentUsageRefresh', 'Stop-AgentUsageWorker')
. ([scriptblock]::Create(($uiFunctions -join [Environment]::NewLine)))

# Execute the production aggregate path, replacing only UI and file access.
function Test-StatusPath { param($Path) return $false }
function Get-StatusFileFingerprint { param($Path) return 'unchanged' }
function Set-StatusVisual { param($State, $Sessions) $script:visualState = $State }
function Set-UsageVisual { param($Usage) }
function Write-StatusDiagnostic { param($Message) }
$exitRequestPath = 'mock-exit'
$showRequestPath = 'mock-show'
$statePath = 'mock-state'
$ignoredCodexSessionsPath = Join-Path $testRoot 'ignored-codex-sessions.json'
$usageReaderPath = Join-Path $projectRoot 'app\Get-AgentUsageState.ps1'
$script:nextUsageRefreshAt = [DateTimeOffset]::MaxValue
$script:nextRolloutRefreshAt = [DateTimeOffset]::MaxValue
$script:nextApprovalRefreshAt = [DateTimeOffset]::MaxValue
$script:cachedUsageState = $null
$script:stateFingerprint = 'unchanged'
$script:codexWeeklyTriggered = $true
$script:statusTimer = $null
$script:usageWorkerRunspace = $null
$script:usageWorkerPipeline = $null
$script:usageWorkerPending = $null

try {
    $threadId = '11111111-2222-3333-4444-555555555555'
    $turnId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $now = [DateTimeOffset]::FromUnixTimeSeconds([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $response = [pscustomobject]@{
        Id = 1L; Timestamp = $now.AddSeconds(-3).ToUnixTimeSeconds()
        Target = 'codex_core::session::handlers'; ThreadId = $threadId
        Body = "op: ExecApproval turn_id: Some(`"$turnId`") decision: Denied"
    }
    Update-CodexApprovalStates -Rows @($response)
    $hook = [pscustomobject]@{
        provider = 'codex'; sessionId = $threadId; turnId = $turnId
        status = 'approval'; startedAt = $now.AddSeconds(-5).ToString('o')
        updatedAt = $now.AddSeconds(-3).AddMilliseconds(300).ToString('o')
        cwd = 'D:\test'; model = ''; source = 'hook'
    }
    $rollout = $hook.PSObject.Copy()
    $rollout.source = 'rollout'
    $rollout.status = 'working'
    $rollout.updatedAt = $now.AddSeconds(-5).ToString('o')
    $rollout | Add-Member -NotePropertyName isLive -NotePropertyValue $true
    $script:cachedHookSessions = @($hook)
    $script:cachedRolloutSessions = @($rollout)
    $script:cachedApprovalSessions = @($script:CodexApprovalStates.Values)
    Update-StatusState
    Assert-Equal $script:visualState 'working' 'Denied permission left a stale approval visible.'
    $response | Add-Member -NotePropertyName TimestampNanos -NotePropertyValue 500000000L
    Update-CodexApprovalStates -Rows @($response)
    $script:cachedApprovalSessions = @($script:CodexApprovalStates.Values)
    Update-StatusState
    Assert-Equal $script:visualState 'working' 'Precise response did not resolve the earlier hook.'
    $hook.updatedAt = $now.AddSeconds(-3).AddMilliseconds(800).ToString('o')
    Update-StatusState
    Assert-Equal $script:visualState 'approval' 'Response cleared a later permission request in the same second.'
    $hook.turnId = 'new-turn'
    $hook.status = 'working'
    $hook.updatedAt = $now.ToString('o')
    Update-StatusState
    Assert-Equal $script:visualState 'working' 'Denial suppressed the next turn.'
    $hook.status = 'approval'
    Update-StatusState
    Assert-Equal $script:visualState 'approval' 'Old denial suppressed a new permission request.'
    $hook.turnId = $turnId
    Update-StatusState
    Assert-Equal $script:visualState 'approval' 'Old response cleared a newer request in the same turn.'
    $rollout.status = 'completed'
    $rollout.updatedAt = $now.AddMilliseconds(500).ToString('o')
    Update-StatusState
    Assert-Equal $script:visualState 'completed' 'Permission recovery overrode a completed turn.'
    $rollout.status = 'cancelled'
    Update-StatusState
    Assert-Equal $script:visualState 'idle' 'Permission recovery overrode an aborted turn.'

    . ([scriptblock]::Create((Get-TestFunctions (Join-Path $projectRoot 'app\Watch-ClaudePermission.ps1') @('Find-ClaudeShellExecution'))))
    $ToolName = 'Bash'
    $ClaudeProcessId = 100
    $ClaudeProcessStartTicks = 0L
    $creation = [DateTime]::UtcNow
    $processes = @{
        100 = [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; Name = 'claude.exe'; CommandLine = 'claude A'; CreationDate = $creation }
        200 = [pscustomobject]@{ ProcessId = 200; ParentProcessId = 0; Name = 'claude.exe'; CommandLine = 'claude B'; CreationDate = $creation }
        201 = [pscustomobject]@{ ProcessId = 201; ParentProcessId = 200; Name = 'bash.exe'; CommandLine = 'bash' }
    }
    $initial = @{ 100 = $true; 200 = $true }
    Assert-Equal ($null -eq (Find-ClaudeShellExecution $initial $processes)) $true 'Watcher selected another Claude session.'
    $processes[101] = [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'bash.exe'; CommandLine = 'bash' }
    Assert-Equal (Find-ClaudeShellExecution $initial $processes).shellProcessId 101 'Watcher missed its owning Claude process.'
    $processes[101].CommandLine = 'powershell -File Watch-ClaudeTurn.ps1'
    Assert-Equal ($null -eq (Find-ClaudeShellExecution $initial $processes)) $true 'Watcher mistook another hook for a tool.'
    $processes[101].CommandLine = 'bash'
    $ClaudeProcessStartTicks = $creation.AddSeconds(-1).Ticks
    Assert-Equal ($null -eq (Find-ClaudeShellExecution $initial $processes)) $true 'Watcher accepted a reused process ID.'
    $ClaudeProcessId = 0
    Assert-Equal ($null -eq (Find-ClaudeShellExecution $initial $processes)) $true 'Unknown owner must use the transcript fallback.'

    function New-UsageLine([long]$Total, [long]$Last, [DateTimeOffset]$At, [switch]$Legacy) {
        $info = @{ last_token_usage = @{ total_tokens = $Last; input_tokens = $Last; output_tokens = 0; cached_input_tokens = 0 } }
        if (-not $Legacy) { $info.total_token_usage = @{ total_tokens = $Total; input_tokens = $Total; output_tokens = 0; cached_input_tokens = 0 } }
        return (@{ timestamp = $At.ToString('o'); type = 'event_msg'; payload = @{ type = 'token_count'; info = $info } } | ConvertTo-Json -Depth 8 -Compress)
    }
    $usageFile = Join-Path $testRoot 'rollout-usage.jsonl'
    $today = [DateTime]::Today
    $at = [DateTimeOffset]::Now
    $first = New-UsageLine 1000 1000 $at
    [System.IO.File]::WriteAllLines($usageFile, @($first, $first), $utf8)
    $summary = Read-CodexUsageFileSummary (Get-Item $usageFile) $today
    Assert-Equal $summary.summary.totals.total 1000 'Duplicate cumulative snapshots were counted twice.'
    $nextLine = New-UsageLine 1500 500 $at
    [System.IO.File]::AppendAllText($usageFile, $nextLine.Substring(0, 40), $utf8)
    $partial = Read-CodexUsageFileSummary (Get-Item $usageFile) $today $summary.offset $summary.summary
    Assert-Equal $partial.offset $summary.offset 'Partial JSON advanced the cursor.'
    [System.IO.File]::AppendAllText($usageFile, $nextLine.Substring(40) + "`n" + $nextLine + "`n" + (New-UsageLine 200 200 $at) + "`n", $utf8)
    $summary = Read-CodexUsageFileSummary (Get-Item $usageFile) $today $partial.offset $partial.summary
    Assert-Equal $summary.summary.totals.total 1700 'Incremental append, duplicate or counter reset was miscounted.'
    Assert-Equal $partial.summary.totals.total 1000 'Incremental reader mutated a previously published snapshot.'
    [System.IO.File]::WriteAllLines($usageFile, @((New-UsageLine 900 900 ([DateTimeOffset]::new($today).AddSeconds(-1))), (New-UsageLine 1000 100 $at)), $utf8)
    $summary = Read-CodexUsageFileSummary (Get-Item $usageFile) $today
    Assert-Equal $summary.summary.totals.total 100 'Yesterday cumulative baseline was added to today.'
    [System.IO.File]::WriteAllLines($usageFile, @((New-UsageLine 0 300 $at -Legacy), (New-UsageLine 0 400 $at -Legacy)), $utf8)
    $summary = Read-CodexUsageFileSummary (Get-Item $usageFile) $today
    Assert-Equal $summary.summary.totals.total 700 'Legacy request-delta logs regressed.'

    $largeFile = Join-Path $testRoot 'large.jsonl'
    $largeRow = @{ type = 'assistant'; timestamp = $at.ToString('o'); message = @{ id = 'large-message'; content = ('x' * 5242880); usage = @{ input_tokens = 10; output_tokens = 5 } } } | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText($largeFile, $largeRow + "`n", $utf8)
    $largeSummary = Read-ClaudeUsageFileSummary (Get-Item $largeFile) $today
    Assert-Equal $largeSummary.summary.totals.total 15 'A large JSON record lost its usage.'
    $unicodeFile = Join-Path $testRoot 'unicode.jsonl'
    $unicodeRow = (' ' * 65535) + '中' + "`n"
    [System.IO.File]::WriteAllText($unicodeFile, $unicodeRow, $utf8)
    $records = @([CCStatus.UsageJsonLines]::Read($unicodeFile, 0))
    Assert-Equal $records[0].Text.Trim() '中' 'UTF-8 spanning a read block was corrupted.'
    Assert-Equal $records[0].NextOffset (Get-Item $unicodeFile).Length 'Byte cursor was calculated from character length.'

    $listed = @(Get-AgentUsageFiles $testRoot '*.jsonl')
    $newFile = Join-Path $testRoot 'new.jsonl'
    [System.IO.File]::WriteAllText($newFile, "{}`n", $utf8)
    Assert-Equal @(Get-AgentUsageFiles $testRoot '*.jsonl').Count $listed.Count 'Directory cache rescanned before expiry.'
    $script:AgentUsageDirectoryCache[$testRoot.ToLowerInvariant() + '|*.jsonl'].expiresAt = [DateTimeOffset]::MinValue
    Assert-Equal @(Get-AgentUsageFiles $testRoot '*.jsonl').Count ($listed.Count + 1) 'Expired directory cache did not discover new files.'

    # A blocked provider must not block UI refresh; release it explicitly.
    $reader = Join-Path $testRoot 'worker-reader.ps1'
    [System.IO.File]::WriteAllText($reader, @'
function Get-AgentUsageState {
    $script:workerCalls++
    if ($script:workerCalls -eq 2) { throw 'simulated read failure' }
    $script:workerStarted.Set() | Out-Null
    if ($script:workerCalls -eq 4) { Start-Sleep -Seconds 30 }
    $script:workerRelease.WaitOne() | Out-Null
    [pscustomobject]@{ calls = $script:workerCalls }
}
'@, $utf8)
    $started = [System.Threading.ManualResetEvent]::new($false)
    $release = [System.Threading.ManualResetEvent]::new($false)
    $script:usageWorkerRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:usageWorkerRunspace.Open()
    $script:usageWorkerRunspace.SessionStateProxy.SetVariable('workerCalls', 0)
    $script:usageWorkerRunspace.SessionStateProxy.SetVariable('workerStarted', $started)
    $script:usageWorkerRunspace.SessionStateProxy.SetVariable('workerRelease', $release)
    $script:nextUsageRefreshAt = [DateTimeOffset]::MinValue
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal $started.WaitOne(5000) $true 'Background reader did not start.'
    $pending = $script:usageWorkerPending
    Assert-Equal $pending.IsCompleted $false 'Blocked provider completed unexpectedly.'
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal ([object]::ReferenceEquals($pending, $script:usageWorkerPending)) $true 'Refresh started overlapping workers.'
    $release.Set() | Out-Null
    Assert-Equal $pending.AsyncWaitHandle.WaitOne(5000) $true 'Background read did not finish.'
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal $script:cachedUsageState.calls 1 'UI did not receive the worker snapshot.'
    $script:nextUsageRefreshAt = [DateTimeOffset]::MinValue
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal $script:usageWorkerPending.AsyncWaitHandle.WaitOne(5000) $true 'Failed worker did not finish.'
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal $script:cachedUsageState.calls 1 'Failure discarded the last usable snapshot.'
    $script:nextUsageRefreshAt = [DateTimeOffset]::MinValue
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal $script:usageWorkerPending.AsyncWaitHandle.WaitOne(5000) $true 'Retry did not finish.'
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal $script:cachedUsageState.calls 3 'Worker cache state was not retained across refreshes.'
    $started.Reset() | Out-Null
    $script:nextUsageRefreshAt = [DateTimeOffset]::MinValue
    Invoke-AgentUsageRefresh -ReaderPath $reader
    Assert-Equal $started.WaitOne(5000) $true 'Shutdown fixture did not start.'
    Stop-AgentUsageWorker
    Assert-Equal ($null -eq $script:usageWorkerRunspace) $true 'Worker was not disposed on shutdown.'
    $started.Dispose()
    $release.Dispose()
    Write-Host 'Review regression tests passed.' -ForegroundColor Green
}
finally {
    if ($null -ne (Get-Variable release -ErrorAction SilentlyContinue)) { try { $release.Set() | Out-Null } catch {} }
    Stop-AgentUsageWorker
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
