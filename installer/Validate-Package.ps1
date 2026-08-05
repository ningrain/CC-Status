[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:LOCALAPPDATA 'CC Status'
$controlExe = Join-Path $installRoot 'CCStatusControl.exe'
$statusAppPs1 = Join-Path $installRoot 'CCStatus.ps1'
$pidFile = Join-Path $installRoot 'data\status.pid'
$hooksPath = Join-Path $env:USERPROFILE '.codex\hooks.json'
$claudeSettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

function Write-Step {
    param([string]$Message)
    Write-Host "[Validate] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[Validate] PASS: $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[Validate] FAIL: $Message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $PackagePath)) {
    Write-Fail "安装包不存在：$PackagePath"
}

Write-Step '1/5 静默安装安装包'
$process = Start-Process -FilePath $PackagePath -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru -Wait
if ($process.ExitCode -ne 0) {
    Write-Fail "安装包退出码 $($process.ExitCode)"
}
Write-Pass '安装包执行完成（退出码 0）'

Write-Step '2/5 检查安装文件、快捷方式与版本'
if (-not (Test-Path -LiteralPath $statusAppPs1)) {
    Write-Fail "主脚本缺失：$statusAppPs1"
}
if (-not (Test-Path -LiteralPath $controlExe)) {
    Write-Fail "控制程序缺失：$controlExe"
}
foreach ($bridgeName in @(
    'Write-AgentStatus.ps1',
    'Write-Codex.ps1',
    'Write-ClaudeStatus.ps1',
    'Watch-ClaudePermission.ps1',
    'Watch-ClaudeTurn.ps1',
    'Get-AgentUsageState.ps1',
    'Get-CCSwitchUsage.ps1',
    'Get-ClaudeTranscriptState.ps1'
)) {
    $bridgePath = Join-Path $installRoot $bridgeName
    if (-not (Test-Path -LiteralPath $bridgePath)) {
        Write-Fail "状态桥缺失：$bridgePath"
    }
}
$statusAppText = Get-Content -LiteralPath $statusAppPs1 -Raw
if ($statusAppText -notmatch 'CloseButton') {
    Write-Fail '主脚本缺少 CloseButton（关闭按钮）'
}
$version = (Get-Item -LiteralPath $controlExe).VersionInfo.FileVersion
if ($version -ne '1.0.0.0') {
    Write-Fail "Control.exe 版本异常：$version（期望 1.0.0.0）"
}
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CC Status.lnk'
$installedIconPath = Join-Path $installRoot 'CCStatus.ico'
if (-not (Test-Path -LiteralPath $desktopShortcutPath)) {
    Write-Fail "桌面快捷方式缺失：$desktopShortcutPath"
}
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($desktopShortcutPath)
$expectedTarget = [System.IO.Path]::GetFullPath($controlExe)
$actualTarget = [System.IO.Path]::GetFullPath($shortcut.TargetPath)
if ($actualTarget -ne $expectedTarget) {
    Write-Fail "桌面快捷方式目标异常：$actualTarget（期望 $expectedTarget）"
}
if ($shortcut.IconLocation -notmatch ('^' + [regex]::Escape($installedIconPath) + '(,0)?$')) {
    Write-Fail "桌面快捷方式图标异常：$($shortcut.IconLocation)（期望 $installedIconPath）"
}
Write-Pass "文件、桌面快捷方式和图标就位，Control.exe 版本 $version"

Write-Step '3/5 检查 hooks.json'
if (-not (Test-Path -LiteralPath $hooksPath)) {
    Write-Fail "hooks.json 缺失：$hooksPath"
}
$hooksText = Get-Content -LiteralPath $hooksPath -Raw
foreach ($eventName in @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'Stop')) {
    if ($hooksText -notmatch ('"' + [regex]::Escape($eventName) + '"')) {
        Write-Fail "hooks.json 缺少事件 $eventName"
    }
}
$expectedCommand = Join-Path $installRoot 'Write-Codex.ps1'
$jsonEscapedCommand = $expectedCommand.Replace('\', '\\')
if ($hooksText.IndexOf($jsonEscapedCommand, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    Write-Fail "hooks.json 未指向安装目录脚本：$expectedCommand"
}
Write-Pass 'Codex hooks.json 四个事件配置正确'

Write-Step '4/5 检查 Claude Code settings.json（按可用性）'
$claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
if ($null -eq $claudeCommand) {
    Write-Host '[Validate] SKIP: 未检测到 Claude Code CLI。' -ForegroundColor Yellow
}
elseif (-not (Test-Path -LiteralPath $claudeSettingsPath)) {
    Write-Fail "Claude settings.json 缺失：$claudeSettingsPath"
}
else {
    try {
        $claudeConfig = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Fail "Claude settings.json 不是有效 JSON：$claudeSettingsPath"
    }
    if ($null -eq $claudeConfig.PSObject.Properties['hooks'] -or $null -eq $claudeConfig.hooks) {
        Write-Fail 'Claude settings.json 缺少 hooks 节点。'
    }
    foreach ($eventName in @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'PostToolBatch', 'Stop', 'SessionEnd', 'Notification')) {
        if ($null -eq $claudeConfig.hooks.PSObject.Properties[$eventName]) {
            Write-Fail "Claude settings.json 缺少事件 $eventName"
        }
    }
    $claudeText = $claudeConfig | ConvertTo-Json -Depth 20
    if ($claudeText -notmatch 'Write-ClaudeStatus\.ps1') {
        Write-Fail 'Claude settings.json 未指向 Write-ClaudeStatus.ps1。'
    }
    Write-Pass 'Claude settings.json Hook 配置正确'
}

Write-Step '5/5 启动 CC Status'
# 用 WMI 创建进程启动，避免子进程链继承本脚本的输出句柄。
# 若用 Start-Process，常驻的状态进程会继承 stdout/stderr 句柄，
# 导致本脚本的调用方（例如管道环境）等待 EOF 而无法退出。
$null = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = ('"{0}" /start' -f $controlExe)
}
$running = $false
$wpid = ''
$deadline = (Get-Date).AddSeconds(15)
do {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $pidFile) {
        $wpid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if ($wpid -match '^\d+$') {
            $running = $null -ne (Get-Process -Id ([int]$wpid) -ErrorAction SilentlyContinue)
        }
    }
} while (-not $running -and (Get-Date) -lt $deadline)
if (-not $running) {
    Write-Fail 'CC Status 未能在 15 秒内启动'
}
Write-Pass "CC Status 运行中（PID $wpid）"

Write-Host ''
Write-Host '[Validate] ALL PASS - 安装验证通过。' -ForegroundColor Green
