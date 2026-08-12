[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CC Status'),
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$SkipShortcuts,
    [switch]$SkipLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$productName = 'CC Status'
$sourceAppRoot = Join-Path $PSScriptRoot 'app'
$codexHooksPath = Join-Path $CodexHome 'hooks.json'
$claudeSettingsPath = Join-Path $ClaudeHome 'settings.json'
$codexBridgePath = Join-Path $InstallRoot 'Write-Codex.ps1'
$agentBridgePath = Join-Path $InstallRoot 'Write-AgentStatus.ps1'
$claudeBridgePath = Join-Path $InstallRoot 'Write-ClaudeStatus.ps1'
$claudePermissionWatcherPath = Join-Path $InstallRoot 'Watch-ClaudePermission.ps1'
$claudeTurnWatcherPath = Join-Path $InstallRoot 'Watch-ClaudeTurn.ps1'
$claudeIncrementalReaderPath = Join-Path $InstallRoot 'Read-ClaudeTranscriptIncremental.ps1'
$rolloutReaderPath = Join-Path $InstallRoot 'Get-CodexRolloutState.ps1'
$approvalReaderPath = Join-Path $InstallRoot 'Get-CodexApprovalState.ps1'
$usageReaderPath = Join-Path $InstallRoot 'Get-AgentUsageState.ps1'
$ccSwitchUsageReaderPath = Join-Path $InstallRoot 'Get-CCSwitchUsage.ps1'
$claudeTranscriptReaderPath = Join-Path $InstallRoot 'Get-ClaudeTranscriptState.ps1'
$statusAppPath = Join-Path $InstallRoot 'CCStatus.ps1'
$sourceIconPath = Join-Path $PSScriptRoot 'assets\CCStatus.ico'
$iconPath = Join-Path $InstallRoot 'CCStatus.ico'
$uninstallerPath = Join-Path $InstallRoot 'Uninstall.ps1'
$exitRequestPath = Join-Path $InstallRoot 'data\exit.request'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-Step {
    param([string]$Message)
    Write-Host "[CC Status] $Message" -ForegroundColor Cyan
}

function Save-JsonAtomic {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $tempPath = "$Path.installing.tmp"
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Test-StatusHandler {
    param($Handler)

    if ($null -eq $Handler) { return $false }
    $command = ''
    if ($null -ne $Handler.PSObject.Properties['command']) { $command += [string]$Handler.command }
    if ($null -ne $Handler.PSObject.Properties['commandWindows']) { $command += [string]$Handler.commandWindows }
    return $command -match '(?i)Write-(AgentStatus|ClaudeStatus|Codex)\.ps1'
}

function Remove-ExistingStatusHandlers {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$EventNames
    )

    if ($null -eq $Config.hooks) { return }

    foreach ($eventName in $EventNames) {
        if ($null -eq $Config.hooks.PSObject.Properties[$eventName]) { continue }

        $keptGroups = New-Object System.Collections.ArrayList
        foreach ($group in @($Config.hooks.$eventName)) {
            $handlers = @($group.hooks | Where-Object { -not (Test-StatusHandler $_) })
            if ($handlers.Count -gt 0) {
                Set-ObjectProperty -Object $group -Name 'hooks' -Value $handlers
                $null = $keptGroups.Add($group)
            }
        }
        Set-ObjectProperty -Object $Config.hooks -Name $eventName -Value @($keptGroups)
    }
}

function Add-CodexHookGroup {
    param(
        [Parameter(Mandatory)]$Hooks,
        [Parameter(Mandatory)][string]$EventName,
        [string]$Matcher,
        [Parameter(Mandatory)][string]$Command
    )

    $handler = [pscustomobject][ordered]@{
        type = 'command'
        command = $Command
        commandWindows = $Command
        timeout = 5
        statusMessage = 'Updating CC Status'
    }

    $groupProperties = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($Matcher)) {
        $groupProperties.matcher = $Matcher
    }
    $groupProperties.hooks = @($handler)
    $group = [pscustomobject]$groupProperties

    $groups = @()
    if ($null -ne $Hooks.PSObject.Properties[$EventName]) {
        $groups = @($Hooks.$EventName)
    }
    $groups += $group
    Set-ObjectProperty -Object $Hooks -Name $EventName -Value $groups
}

function Add-ClaudeHookGroup {
    param(
        [Parameter(Mandatory)]$Hooks,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$Matcher
    )

    $escapedPath = $ScriptPath.Replace("'", "''")
    $handler = [pscustomobject][ordered]@{
        type = 'command'
        shell = 'powershell'
        command = "& '$escapedPath'"
        timeout = 5
        async = $true
    }
    $groupProperties = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($Matcher)) {
        $groupProperties.matcher = $Matcher
    }
    $groupProperties.hooks = @($handler)
    $group = [pscustomobject]$groupProperties

    $groups = @()
    if ($null -ne $Hooks.PSObject.Properties[$EventName]) {
        $groups = @($Hooks.$EventName)
    }
    $groups += $group
    Set-ObjectProperty -Object $Hooks -Name $EventName -Value $groups
}

function Write-CommandFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Lines
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    [System.IO.File]::WriteAllLines($Path, $Lines, [System.Text.Encoding]::Default)
}

function Backup-Config {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Suffix
    )

    $backupPath = '{0}.{1}.{2}.bak' -f $Path, $Suffix, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backupPath
}

function Read-JsonConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    try {
        return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    }
    catch {
        throw "现有 $Description 不是有效 JSON，未覆盖该文件：$Path"
    }
}

if (-not (Test-Path -LiteralPath $sourceAppRoot)) {
    throw "找不到应用文件目录：$sourceAppRoot"
}

if (Test-Path -LiteralPath (Join-Path $InstallRoot 'data\status.pid')) {
    Write-Step '停止旧版本小组件'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $exitRequestPath) -Force
    [System.IO.File]::WriteAllText($exitRequestPath, [DateTimeOffset]::UtcNow.ToString('o'), [System.Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 1400
}

Write-Step '复制应用文件'
if (-not (Test-Path -LiteralPath $InstallRoot)) {
    $null = New-Item -ItemType Directory -Path $InstallRoot -Force
}
$null = New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'data') -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'CCStatus.ps1') -Destination $statusAppPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Write-AgentStatus.ps1') -Destination $agentBridgePath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Write-Codex.ps1') -Destination $codexBridgePath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Write-ClaudeStatus.ps1') -Destination $claudeBridgePath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Watch-ClaudePermission.ps1') -Destination $claudePermissionWatcherPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Watch-ClaudeTurn.ps1') -Destination $claudeTurnWatcherPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Read-ClaudeTranscriptIncremental.ps1') -Destination $claudeIncrementalReaderPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Get-CodexRolloutState.ps1') -Destination $rolloutReaderPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Get-CodexApprovalState.ps1') -Destination $approvalReaderPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Get-AgentUsageState.ps1') -Destination $usageReaderPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Get-CCSwitchUsage.ps1') -Destination $ccSwitchUsageReaderPath -Force
Copy-Item -LiteralPath (Join-Path $sourceAppRoot 'Get-ClaudeTranscriptState.ps1') -Destination $claudeTranscriptReaderPath -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination $uninstallerPath -Force
if (Test-Path -LiteralPath $sourceIconPath) {
    Copy-Item -LiteralPath $sourceIconPath -Destination $iconPath -Force
}
foreach ($installedScript in @($statusAppPath, $agentBridgePath, $codexBridgePath, $claudeBridgePath, $claudePermissionWatcherPath, $claudeTurnWatcherPath, $claudeIncrementalReaderPath, $rolloutReaderPath, $approvalReaderPath, $usageReaderPath, $ccSwitchUsageReaderPath, $claudeTranscriptReaderPath, $uninstallerPath)) {
    Unblock-File -LiteralPath $installedScript -ErrorAction SilentlyContinue
}

Write-Step '配置 Codex 生命周期 Hooks'
if (-not (Test-Path -LiteralPath $CodexHome)) {
    $null = New-Item -ItemType Directory -Path $CodexHome -Force
}
if (Test-Path -LiteralPath $codexHooksPath) {
    $codexConfig = Read-JsonConfig -Path $codexHooksPath -Description 'hooks.json'
Backup-Config -Path $codexHooksPath -Suffix 'cc-status'
}
else {
    $codexConfig = [pscustomobject][ordered]@{
        description = 'User-level Codex lifecycle hooks.'
        hooks = [pscustomobject]@{}
    }
}

if ($null -eq $codexConfig.PSObject.Properties['hooks'] -or $null -eq $codexConfig.hooks) {
    Set-ObjectProperty -Object $codexConfig -Name 'hooks' -Value ([pscustomobject]@{})
}

Remove-ExistingStatusHandlers -Config $codexConfig -EventNames @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'Stop')
$escapedCodexBridgePath = $codexBridgePath.Replace('"', '\"')
$codexHookCommand = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "{0}"' -f $escapedCodexBridgePath
Add-CodexHookGroup -Hooks $codexConfig.hooks -EventName 'UserPromptSubmit' -Command $codexHookCommand
Add-CodexHookGroup -Hooks $codexConfig.hooks -EventName 'PermissionRequest' -Matcher '.*' -Command $codexHookCommand
Add-CodexHookGroup -Hooks $codexConfig.hooks -EventName 'Stop' -Command $codexHookCommand
Save-JsonAtomic -Value $codexConfig -Path $codexHooksPath

Write-Step '检测 Claude Code CLI'
$claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
if ($null -eq $claudeCommand) {
    Write-Warning '未检测到 Claude Code CLI，已跳过 Claude Code Hooks 配置。'
}
else {
    Write-Step '配置 Claude Code 用户级 Hooks'
    try {
        if (-not (Test-Path -LiteralPath $ClaudeHome)) {
            $null = New-Item -ItemType Directory -Path $ClaudeHome -Force
        }
        if (Test-Path -LiteralPath $claudeSettingsPath) {
            $claudeConfig = Read-JsonConfig -Path $claudeSettingsPath -Description 'Claude settings.json'
            Backup-Config -Path $claudeSettingsPath -Suffix 'cc-status'
        }
        else {
            $claudeConfig = [pscustomobject][ordered]@{ hooks = [pscustomobject]@{} }
        }

        if ($null -eq $claudeConfig.PSObject.Properties['hooks'] -or $null -eq $claudeConfig.hooks) {
            Set-ObjectProperty -Object $claudeConfig -Name 'hooks' -Value ([pscustomobject]@{})
        }

        $claudeCleanupEvents = @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'PostToolBatch', 'PermissionDenied', 'Notification', 'Stop', 'StopFailure', 'SessionEnd')
        $claudeEvents = @('UserPromptSubmit', 'PermissionRequest', 'PostToolBatch', 'PermissionDenied', 'Notification', 'Stop', 'StopFailure', 'SessionEnd')
        Remove-ExistingStatusHandlers -Config $claudeConfig -EventNames $claudeCleanupEvents
        foreach ($eventName in $claudeEvents) {
            if ($eventName -eq 'Notification') {
                Add-ClaudeHookGroup -Hooks $claudeConfig.hooks -EventName $eventName -ScriptPath $claudeBridgePath -Matcher 'permission_prompt'
                Add-ClaudeHookGroup -Hooks $claudeConfig.hooks -EventName $eventName -ScriptPath $claudeBridgePath -Matcher 'idle_prompt'
            }
            else {
                Add-ClaudeHookGroup -Hooks $claudeConfig.hooks -EventName $eventName -ScriptPath $claudeBridgePath
            }
        }
        Save-JsonAtomic -Value $claudeConfig -Path $claudeSettingsPath
    }
    catch {
        Write-Warning $_.Exception.Message
        Write-Warning 'Claude Code 配置未修改；CC Status 及 Codex 集成仍已安装。'
    }
}

if (-not $SkipShortcuts) {
    Write-Step '配置 CC Status 开机启动和开始菜单入口'
    $startupRoot = [Environment]::GetFolderPath('Startup')
    foreach ($startupName in @('CC Status.lnk')) {
        Remove-Item -LiteralPath (Join-Path $startupRoot $startupName) -Force -ErrorAction SilentlyContinue
    }

    $desktopRoot = [Environment]::GetFolderPath('Desktop')
    Remove-Item -LiteralPath (Join-Path $desktopRoot 'CC Status.lnk') -Force -ErrorAction SilentlyContinue

    $programsRoot = [Environment]::GetFolderPath('Programs')
    $programFolder = Join-Path $programsRoot 'CC Status'
    Remove-Item -LiteralPath $programFolder -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $programFolder -Force

    $launchLine = '@start "" "{0}" -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{1}"' -f $powershellPath, $statusAppPath
    $uninstallLine = [char]64 + ('"{0}" -NoProfile -ExecutionPolicy RemoteSigned -File "{1}"' -f $powershellPath, $uninstallerPath)
    Write-CommandFile -Path (Join-Path $programFolder 'CC Status.cmd') -Lines @('@echo off', $launchLine)
    Write-CommandFile -Path (Join-Path $programFolder 'Uninstall CC Status.cmd') -Lines @('@echo off', $uninstallLine)

    $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $null = New-Item -Path $runKeyPath -Force
    $runCommand = '"{0}" -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{1}"' -f $powershellPath, $statusAppPath
    Set-ItemProperty -Path $runKeyPath -Name $productName -Value $runCommand
}

if (-not $SkipLaunch) {
    Write-Step '启动 CC Status 小组件'
    $launchArguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}"' -f $statusAppPath
    Start-Process -FilePath $powershellPath -ArgumentList $launchArguments -WindowStyle Hidden
}

Write-Host ''
Write-Host 'CC Status 安装完成。' -ForegroundColor Green
Write-Host '“工作中/需要批准/已完成”状态已可使用。'
Write-Host 'Codex 和 Claude Code Hooks 已按可用性配置。'
Write-Host "安装目录：$InstallRoot"
Write-Host "Codex Hooks：$codexHooksPath"
if ($null -ne $claudeCommand) { Write-Host "Claude Hooks：$claudeSettingsPath" }
