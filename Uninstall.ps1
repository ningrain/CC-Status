[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CC Status'),
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$SkipShortcuts,
    [switch]$SkipFileRemoval
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$codexHooksPath = Join-Path $CodexHome 'hooks.json'
$claudeSettingsPath = Join-Path $ClaudeHome 'settings.json'
$exitRequestPath = Join-Path $InstallRoot 'data\exit.request'
$eventNames = @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'PostToolBatch', 'PermissionDenied', 'Notification', 'Stop', 'StopFailure', 'SessionEnd')
$backupRetentionDays = 30

function Set-ObjectProperty {
    param($Object, [string]$Name, $Value)
    if ($null -ne $Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Test-StatusHandler {
    param($Handler)
    if ($null -eq $Handler) { return $false }
    $command = ''
    if ($null -ne $Handler.PSObject.Properties['command']) { $command += [string]$Handler.command }
    if ($null -ne $Handler.PSObject.Properties['commandWindows']) { $command += [string]$Handler.commandWindows }
    return $command -match '(?i)Write-(AgentStatus|ClaudeStatus|Codex)\.ps1'
}

function Remove-ExpiredBackups {
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }

    $cutoff = (Get-Date).AddDays(-$backupRetentionDays)
    $expired = @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(hooks|settings)\.json\..+\.bak$' -and $_.LastWriteTime -lt $cutoff
        })
    foreach ($file in $expired) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($expired.Count -gt 0) {
        Write-Host "CC Status 已清理 $($expired.Count) 个超过 $backupRetentionDays 天的配置备份。" -ForegroundColor DarkGray
    }
}

function Read-JsonConfig {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)
    try {
        return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    }
    catch {
        throw "现有 $Description 不是有效 JSON，未修改该文件：$Path"
    }
}

function Remove-StatusHandlers {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupSuffix
    )

    if ($null -eq $Config.PSObject.Properties['hooks'] -or $null -eq $Config.hooks) { return }

    foreach ($eventName in $eventNames) {
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

    $backupPath = '{0}.{1}.{2}.bak' -f $Path, $BackupSuffix, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backupPath
    $tempPath = "$Path.uninstalling.tmp"
    [System.IO.File]::WriteAllText($tempPath, ($Config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

Remove-ExpiredBackups -Directory $CodexHome
Remove-ExpiredBackups -Directory $ClaudeHome

if (Test-Path -LiteralPath $codexHooksPath) {
    $codexConfig = Read-JsonConfig -Path $codexHooksPath -Description 'Codex hooks.json'
    Remove-StatusHandlers -Config $codexConfig -Path $codexHooksPath -BackupSuffix 'before-ccstatus-uninstall'
}

if (Test-Path -LiteralPath $claudeSettingsPath) {
    $claudeConfig = Read-JsonConfig -Path $claudeSettingsPath -Description 'Claude settings.json'
    Remove-StatusHandlers -Config $claudeConfig -Path $claudeSettingsPath -BackupSuffix 'before-ccstatus-uninstall'
}

if (-not $SkipFileRemoval -and (Test-Path -LiteralPath $InstallRoot)) {
    $dataRoot = Join-Path $InstallRoot 'data'
    if (-not (Test-Path -LiteralPath $dataRoot)) {
        $null = New-Item -ItemType Directory -Path $dataRoot -Force
    }
    [System.IO.File]::WriteAllText($exitRequestPath, [DateTimeOffset]::UtcNow.ToString('o'))
    Start-Sleep -Milliseconds 1500
}

if (-not $SkipShortcuts) {
    $startupRoot = [Environment]::GetFolderPath('Startup')
    foreach ($startupName in @('CC Status.lnk')) {
        Remove-Item -LiteralPath (Join-Path $startupRoot $startupName) -Force -ErrorAction SilentlyContinue
    }

    $desktopRoot = [Environment]::GetFolderPath('Desktop')
    foreach ($desktopName in @('CC Status.lnk')) {
        Remove-Item -LiteralPath (Join-Path $desktopRoot $desktopName) -Force -ErrorAction SilentlyContinue
    }

    $programsRoot = [Environment]::GetFolderPath('Programs')
    foreach ($folderName in @('CC Status')) {
        Remove-Item -LiteralPath (Join-Path $programsRoot $folderName) -Recurse -Force -ErrorAction SilentlyContinue
    }

    $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    foreach ($runName in @('CC Status')) {
        Remove-ItemProperty -Path $runKeyPath -Name $runName -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $InstallRoot) {
    $cleanupScript = Join-Path ([System.IO.Path]::GetTempPath()) ('ccstatus-cleanup-{0}.ps1' -f [Guid]::NewGuid().ToString('N'))
    $escapedRoot = $InstallRoot.Replace("'", "''")
    $cleanup = "Start-Sleep -Milliseconds 800`nRemove-Item -LiteralPath '$escapedRoot' -Recurse -Force -ErrorAction SilentlyContinue`nRemove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue"
    [System.IO.File]::WriteAllText($cleanupScript, $cleanup, [System.Text.UTF8Encoding]::new($true))
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}"' -f $cleanupScript) -WindowStyle Hidden
}

Write-Host 'CC Status 已卸载。' -ForegroundColor Green
Write-Host 'Codex/Claude Hooks 配置已保留备份，用户设置和会话记录未删除。'
