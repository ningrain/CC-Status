[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot '.test-installer'
$installRoot = Join-Path $testRoot 'install'
$codexHome = Join-Path $testRoot 'codex-home'
$claudeHome = Join-Path $testRoot 'claude-home'
$hooksPath = Join-Path $codexHome 'hooks.json'
$claudeSettingsPath = Join-Path $claudeHome 'settings.json'
$fakeClaudeBin = Join-Path $testRoot 'fake-bin'
$fakeClaudePath = Join-Path $fakeClaudeBin 'claude.cmd'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $codexHome -Force
$null = New-Item -ItemType Directory -Path $claudeHome -Force
$null = New-Item -ItemType Directory -Path $fakeClaudeBin -Force
[System.IO.File]::WriteAllText($fakeClaudePath, ([char]64 + 'echo off' + [Environment]::NewLine + 'exit /b 0'), [System.Text.Encoding]::ASCII)
$originalPath = $env:Path
$env:Path = $fakeClaudeBin + ';' + $env:Path

# First validate the empty, first-install path that has no hooks.json.
$firstInstallRoot = Join-Path $testRoot 'first-install'
$firstCodexHome = Join-Path $testRoot 'first-codex-home'
$firstClaudeHome = Join-Path $testRoot 'first-claude-home'
$null = New-Item -ItemType Directory -Path $firstCodexHome -Force
$null = New-Item -ItemType Directory -Path $firstClaudeHome -Force
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'Install.ps1') -InstallRoot $firstInstallRoot -CodexHome $firstCodexHome -ClaudeHome $firstClaudeHome -SkipShortcuts -SkipLaunch
if ($LASTEXITCODE -ne 0) { throw 'First-time installation failed.' }
$firstHooksPath = Join-Path $firstCodexHome 'hooks.json'
Assert-True (Test-Path -LiteralPath $firstHooksPath) 'First-time install did not create hooks.json.'
$firstConfig = Get-Content -LiteralPath $firstHooksPath -Raw | ConvertFrom-Json
Assert-True (@($firstConfig.hooks.UserPromptSubmit).Count -eq 1) 'First-time install did not create status hooks.'
$firstClaudeSettingsPath = Join-Path $firstClaudeHome 'settings.json'
Assert-True (Test-Path -LiteralPath $firstClaudeSettingsPath) 'First-time install did not create Claude settings.json.'
$firstClaudeConfig = Get-Content -LiteralPath $firstClaudeSettingsPath -Raw | ConvertFrom-Json
Assert-True (@($firstClaudeConfig.hooks.UserPromptSubmit).Count -eq 1) 'First-time install did not create Claude hooks.'

$existingConfig = @'
{
  "description": "Installer preservation test",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -File C:\\keep-me.ps1"
          }
        ]
      }
    ]
  }
}
'@
[System.IO.File]::WriteAllText($hooksPath, $existingConfig, [System.Text.UTF8Encoding]::new($false))
$existingClaudeConfig = @'
{
  "env": {
    "CC_STATUS_TEST": "preserve-me"
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -File C:\\keep-claude-me.ps1"
          }
        ]
      }
    ]
  }
}
'@
$null = New-Item -ItemType Directory -Path $claudeHome -Force
[System.IO.File]::WriteAllText($claudeSettingsPath, $existingClaudeConfig, [System.Text.UTF8Encoding]::new($false))
$oldInstallCodexBackup = Join-Path $codexHome 'hooks.json.cc-status.20250101-000000.bak'
$oldInstallClaudeBackup = Join-Path $claudeHome 'settings.json.cc-status.20250101-000000.bak'
[System.IO.File]::WriteAllText($oldInstallCodexBackup, '{}', [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($oldInstallClaudeBackup, '{}', [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::SetLastWriteTime($oldInstallCodexBackup, (Get-Date).AddDays(-31))
[System.IO.File]::SetLastWriteTime($oldInstallClaudeBackup, (Get-Date).AddDays(-31))

try {
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'Install.ps1') -InstallRoot $installRoot -CodexHome $codexHome -ClaudeHome $claudeHome -SkipShortcuts -SkipLaunch
    if ($LASTEXITCODE -ne 0) { throw 'Test installation failed.' }

    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'CCStatus.ps1')) 'CC Status file was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Write-AgentStatus.ps1')) 'Shared bridge file was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Write-Codex.ps1')) 'Codex bridge file was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Write-ClaudeStatus.ps1')) 'Claude bridge file was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Watch-ClaudePermission.ps1')) 'Claude permission watcher was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Get-CodexRolloutState.ps1')) 'Rollout reader was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'Get-CodexApprovalState.ps1')) 'Approval reader was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'CCStatus.ico')) 'Application icon was not installed.'
    Assert-True (-not (Test-Path -LiteralPath $oldInstallCodexBackup)) 'Installer did not remove the expired Codex backup.'
    Assert-True (-not (Test-Path -LiteralPath $oldInstallClaudeBackup)) 'Installer did not remove the expired Claude backup.'

    $installedConfig = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    Assert-True (@($installedConfig.hooks.UserPromptSubmit).Count -eq 1) 'UserPromptSubmit hook was not added.'
    Assert-True (@($installedConfig.hooks.PermissionRequest).Count -eq 1) 'PermissionRequest hook was not added.'
    Assert-True (@($installedConfig.hooks.PostToolUse).Count -eq 1) 'PostToolUse hook was not added.'
    Assert-True (@($installedConfig.hooks.Stop).Count -eq 2) 'Existing Stop hook was not preserved.'
    Assert-True (($installedConfig | ConvertTo-Json -Depth 20) -match 'keep-me\.ps1') 'Existing hook content was changed.'
    Assert-True (-not (($installedConfig | ConvertTo-Json -Depth 20) -match 'ExecutionPolicy Bypass')) 'Installed hooks still use ExecutionPolicy Bypass.'
    Assert-True (($installedConfig | ConvertTo-Json -Depth 20) -match 'ExecutionPolicy RemoteSigned') 'Installed hooks do not use RemoteSigned.'

    $installedClaudeConfig = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
    Assert-True (@($installedClaudeConfig.hooks.UserPromptSubmit).Count -eq 1) 'Claude UserPromptSubmit hook was not added.'
    Assert-True (@($installedClaudeConfig.hooks.PermissionRequest).Count -eq 1) 'Claude PermissionRequest hook was not added.'
    Assert-True (@($installedClaudeConfig.hooks.PostToolUse).Count -eq 1) 'Claude PostToolUse hook was not added.'
    Assert-True (@($installedClaudeConfig.hooks.PostToolBatch).Count -eq 1) 'Claude PostToolBatch hook was not added.'
    Assert-True (@($installedClaudeConfig.hooks.Notification).Count -eq 2) 'Claude Notification hooks were not added.'
    Assert-True (($installedClaudeConfig.hooks.Notification | ForEach-Object { [string]$_.matcher }) -contains 'permission_prompt') 'Claude permission notification hook was not added.'
    Assert-True (($installedClaudeConfig.hooks.Notification | ForEach-Object { [string]$_.matcher }) -contains 'idle_prompt') 'Claude idle notification hook was not added.'
    Assert-True (@($installedClaudeConfig.hooks.Stop).Count -eq 2) 'Existing Claude Stop hook was not preserved.'
    Assert-True (($installedClaudeConfig | ConvertTo-Json -Depth 20) -match 'keep-claude-me\.ps1') 'Existing Claude hook content was changed.'
    Assert-True (($installedClaudeConfig | ConvertTo-Json -Depth 20) -match 'Write-ClaudeStatus\.ps1') 'Claude settings do not reference the Claude bridge.'
    Assert-True (($installedClaudeConfig.hooks.UserPromptSubmit[0].hooks[0].shell) -eq 'powershell') 'Claude hooks do not explicitly use PowerShell.'

    $oldUninstallCodexBackup = Join-Path $codexHome 'hooks.json.before-ccstatus-uninstall.20250101-000000.bak'
    $oldUninstallClaudeBackup = Join-Path $claudeHome 'settings.json.before-ccstatus-uninstall.20250101-000000.bak'
    [System.IO.File]::WriteAllText($oldUninstallCodexBackup, '{}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($oldUninstallClaudeBackup, '{}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::SetLastWriteTime($oldUninstallCodexBackup, (Get-Date).AddDays(-31))
    [System.IO.File]::SetLastWriteTime($oldUninstallClaudeBackup, (Get-Date).AddDays(-31))

    $installerSource = Get-Content -LiteralPath (Join-Path $projectRoot 'Install.ps1') -Raw
    Assert-True (-not ($installerSource -match 'CreateShortcut|WScript\.Shell')) 'Installer still creates script-targeting LNK files.'
    Assert-True ($installerSource -match 'CurrentVersion\\Run') 'Installer does not configure the HKCU Run startup entry.'
    Assert-True ($installerSource -match 'Desktop') 'Installer does not handle the legacy desktop shortcut.'

    $packageSource = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\CCStatus.iss') -Raw
    Assert-True ($packageSource -match '#define MyAppName "CC Status"') 'Installer product name still contains the legacy hyphen.'
    Assert-True ($packageSource -match '\{userdesktop\}\\CC Status') 'Package does not create the CC Status desktop shortcut.'
    Assert-True ($packageSource -match 'IconFilename\s*:\s*"\{app\}\\CCStatus\.ico"') 'Desktop shortcut is not explicitly tied to the tray icon file.'

    $statusSource = Get-Content -LiteralPath (Join-Path $projectRoot 'app\CCStatus.ps1') -Raw
    Assert-True ($statusSource -match '\[System\.Windows\.Threading\.Dispatcher\]::Run\(\)') 'CC Status does not keep an independent dispatcher loop alive while hidden.'
    Assert-True (-not ($statusSource -match '\.ShowDialog\(\)')) 'CC Status still uses a modal loop that exits when the window is hidden.'
    Assert-True ($statusSource -match 'Apply-Theme') 'CC Status does not expose theme switching.'
    Assert-True ($statusSource -match 'x:Name="ThemeButton"') 'CC Status does not place the theme button in the component.'
    Assert-True (($statusSource -match "'☾'") -and ($statusSource -match "'☀'")) 'Theme button does not use moon and sun icons.'
    Assert-True (-not ($statusSource -match 'themeMenuItem')) 'Theme switching is still exposed from the tray menu.'
    Assert-True ($statusSource -match 'theme = \$script:currentTheme') 'CC Status does not persist the selected theme.'
    Assert-True ($packageSource -match 'OutputDir=\.\.\\release') 'Installer output is not configured for the release directory.'

    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'Uninstall.ps1') -InstallRoot $installRoot -CodexHome $codexHome -ClaudeHome $claudeHome -SkipShortcuts
    if ($LASTEXITCODE -ne 0) { throw 'Test uninstall failed.' }

    Start-Sleep -Milliseconds 1200
    $uninstalledConfig = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    Assert-True (($uninstalledConfig | ConvertTo-Json -Depth 20) -match 'keep-me\.ps1') 'Uninstaller removed an unrelated hook.'
    Assert-True (-not (($uninstalledConfig | ConvertTo-Json -Depth 20) -match 'Write-Codex\.ps1')) 'Uninstaller left Codex status hooks behind.'
    $uninstalledClaudeConfig = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
    Assert-True (($uninstalledClaudeConfig | ConvertTo-Json -Depth 20) -match 'keep-claude-me\.ps1') 'Uninstaller removed an unrelated Claude hook.'
    Assert-True (-not (($uninstalledClaudeConfig | ConvertTo-Json -Depth 20) -match 'Write-ClaudeStatus\.ps1')) 'Uninstaller left Claude status hooks behind.'
    Assert-True (-not (Test-Path -LiteralPath $oldUninstallCodexBackup)) 'Uninstaller did not remove the expired Codex backup.'
    Assert-True (-not (Test-Path -LiteralPath $oldUninstallClaudeBackup)) 'Uninstaller did not remove the expired Claude backup.'

    $invalidClaudeHome = Join-Path $testRoot 'invalid-claude-home'
    $invalidClaudePath = Join-Path $invalidClaudeHome 'settings.json'
    $invalidInstallRoot = Join-Path $testRoot 'invalid-claude-install'
    $null = New-Item -ItemType Directory -Path $invalidClaudeHome -Force
    $invalidJson = '{ this is not valid JSON'
    [System.IO.File]::WriteAllText($invalidClaudePath, $invalidJson, [System.Text.UTF8Encoding]::new($false))
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'Install.ps1') -InstallRoot $invalidInstallRoot -CodexHome (Join-Path $testRoot 'invalid-codex-home') -ClaudeHome $invalidClaudeHome -SkipShortcuts -SkipLaunch
    if ($LASTEXITCODE -ne 0) { throw 'Invalid Claude configuration should not fail the whole installation.' }
    Assert-True ((Get-Content -LiteralPath $invalidClaudePath -Raw) -eq $invalidJson) 'Invalid Claude settings.json was overwritten.'

    Write-Host 'Installer tests passed.' -ForegroundColor Green
}
finally {
    $env:Path = $originalPath
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
