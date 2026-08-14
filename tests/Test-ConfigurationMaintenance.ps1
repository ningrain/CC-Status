[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceAppRoot = Join-Path $projectRoot 'app'
$testRoot = Join-Path $PSScriptRoot '.test-configuration-maintenance'
$appRoot = Join-Path $testRoot 'app'
$fakeHome = Join-Path $testRoot 'home'
$claudeHome = Join-Path $fakeHome '.claude'
$codexHome = Join-Path $fakeHome '.codex'
$settingsPath = Join-Path $claudeHome 'settings.json'
$codexHooksPath = Join-Path $codexHome 'hooks.json'
$codexTomlPath = Join-Path $codexHome 'config.toml'
$stdoutPath = Join-Path $testRoot 'cc-status.stdout.log'
$stderrPath = Join-Path $testRoot 'cc-status.stderr.log'
$process = $null

function Write-TestSettings {
    param([Parameter(Mandatory)][string]$Json)
    [System.IO.File]::WriteAllText($settingsPath, $Json, [System.Text.UTF8Encoding]::new($false))
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 15,
        [string]$FailureMessage = 'Condition was not met.'
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw $FailureMessage
}

if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
$null = New-Item -ItemType Directory -Path $appRoot, $claudeHome, $codexHome -Force
Copy-Item -Path (Join-Path $sourceAppRoot '*') -Destination $appRoot -Recurse -Force

try {
    $oldClaudePath = 'D:\CC Status\Write-ClaudeStatus.ps1'
    $oldCodexPath = 'D:\CC Status\Write-Codex.ps1'
    $initialClaudeConfig = [pscustomobject][ordered]@{
        env = [pscustomobject]@{ ANTHROPIC_BASE_URL = 'https://initial.example' }
        customMarker = 'initial'
        hooks = [pscustomobject]@{
            UserPromptSubmit = @([pscustomobject]@{
                hooks = @(
                    [pscustomobject]@{ type = 'command'; command = "& '$oldClaudePath'" },
                    [pscustomobject]@{ type = 'command'; command = 'custom-claude-hook' }
                )
            })
        }
    }
    Write-TestSettings -Json ($initialClaudeConfig | ConvertTo-Json -Depth 10)
    $initialCodexConfig = [pscustomobject][ordered]@{
        customMarker = 'codex-preserve'
        hooks = [pscustomobject]@{
            UserPromptSubmit = @([pscustomobject]@{
                hooks = @(
                    [pscustomobject]@{ type = 'command'; command = "powershell.exe -File `"$oldCodexPath`"" },
                    [pscustomobject]@{ type = 'command'; command = 'custom-codex-hook' }
                )
            })
        }
    }
    [System.IO.File]::WriteAllText($codexHooksPath, ($initialCodexConfig | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    $oldStatusTrustKey = '{0}:user_prompt_submit:0:0' -f $codexHooksPath
    $customTrustKey = '{0}:user_prompt_submit:0:1' -f $codexHooksPath
    $unrelatedTrustKey = '{0}:session_start:0:0' -f $codexHooksPath
    $initialCodexToml = @"
[hooks.state]

[hooks.state.'$oldStatusTrustKey']
trusted_hash = "sha256:old-status"

[hooks.state.'$customTrustKey']
trusted_hash = "sha256:custom-same-event"

[hooks.state.'$unrelatedTrustKey']
trusted_hash = "sha256:unrelated"
"@
    [System.IO.File]::WriteAllText($codexTomlPath, $initialCodexToml, [System.Text.UTF8Encoding]::new($false))

    $oldUserProfile = $env:USERPROFILE
    $env:USERPROFILE = $fakeHome
    try {
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $appRoot 'CCStatus.ps1')) `
            -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    }
    finally {
        $env:USERPROFILE = $oldUserProfile
    }

    Wait-ForCondition -FailureMessage 'Temporary CC Status did not start.' -Condition {
        (Test-Path -LiteralPath (Join-Path $appRoot 'data\status.pid')) -and -not $process.HasExited
    }

    Wait-ForCondition -FailureMessage 'Temporary CC Status did not finish its initial Hook setup.' -Condition {
        try {
            $config = [System.IO.File]::ReadAllText($settingsPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $codexConfig = [System.IO.File]::ReadAllText($codexHooksPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $codexToml = [System.IO.File]::ReadAllText($codexTomlPath, [System.Text.UTF8Encoding]::new($false))
            $claudeCommands = @($config.hooks.UserPromptSubmit | ForEach-Object { @($_.hooks) } | ForEach-Object { $_.command })
            $codexCommands = @($codexConfig.hooks.UserPromptSubmit | ForEach-Object { @($_.hooks) } | ForEach-Object { $_.command })
            return $config.customMarker -eq 'initial' -and
                $null -ne $config.PSObject.Properties['hooks'] -and
                $null -ne $config.hooks.PSObject.Properties['UserPromptSubmit'] -and
                @($claudeCommands | Where-Object { $_ -eq 'custom-claude-hook' }).Count -eq 1 -and
                @($claudeCommands | Where-Object { $_ -like "*$appRoot\Write-ClaudeStatus.ps1*" }).Count -eq 1 -and
                @($claudeCommands | Where-Object { $_ -like "*$oldClaudePath*" }).Count -eq 0 -and
                $codexConfig.customMarker -eq 'codex-preserve' -and
                @($codexCommands | Where-Object { $_ -eq 'custom-codex-hook' }).Count -eq 1 -and
                @($codexCommands | Where-Object { $_ -like "*$appRoot\Write-Codex.ps1*" }).Count -eq 1 -and
                @($codexCommands | Where-Object { $_ -like "*$oldCodexPath*" }).Count -eq 0 -and
                $codexToml -notmatch [regex]::Escape($oldStatusTrustKey) -and
                $codexToml -notmatch [regex]::Escape($customTrustKey) -and
                $codexToml -match [regex]::Escape($unrelatedTrustKey)
        }
        catch { return $false }
    }

    Write-TestSettings -Json '{"env":{"ANTHROPIC_BASE_URL":"https://switched.example"},"customMarker":"preserve-me"}'
    Wait-ForCondition -FailureMessage 'CC Status did not restore Hooks after CC Switch rewrote the configuration.' -Condition {
        try {
            $config = [System.IO.File]::ReadAllText($settingsPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            return $config.customMarker -eq 'preserve-me' -and
                $config.env.ANTHROPIC_BASE_URL -eq 'https://switched.example' -and
                $null -ne $config.PSObject.Properties['hooks'] -and
                $null -ne $config.hooks.PSObject.Properties['UserPromptSubmit'] -and
                $null -ne $config.hooks.PSObject.Properties['Notification']
        }
        catch { return $false }
    }

    $repaired = [System.IO.File]::ReadAllText($settingsPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    foreach ($eventName in @('UserPromptSubmit', 'PermissionRequest', 'PostToolBatch', 'PermissionDenied', 'Stop', 'StopFailure', 'SessionEnd', 'Notification')) {
        if ($null -eq $repaired.hooks.PSObject.Properties[$eventName]) { throw "Hook was not restored: $eventName" }
    }
    $claudePostToolHandlers = if ($null -ne $repaired.hooks.PSObject.Properties['PostToolUse']) { @($repaired.hooks.PostToolUse | ForEach-Object { @($_.hooks) }) } else { @() }
    if (@($claudePostToolHandlers | Where-Object { [string]$_.command -match 'Write-ClaudeStatus\.ps1' }).Count -gt 0) { throw 'Claude PostToolUse status hook was not removed.' }
    $codexRepaired = [System.IO.File]::ReadAllText($codexHooksPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $codexPostToolHandlers = if ($null -ne $codexRepaired.hooks.PSObject.Properties['PostToolUse']) { @($codexRepaired.hooks.PostToolUse | ForEach-Object { @($_.hooks) }) } else { @() }
    if (@($codexPostToolHandlers | Where-Object { [string]$_.command -match 'Write-Codex\.ps1' }).Count -gt 0) { throw 'Codex PostToolUse status hook was not removed.' }

    $invalidJson = '{"env":'
    Write-TestSettings -Json $invalidJson
    Start-Sleep -Seconds 4
    $afterInvalid = [System.IO.File]::ReadAllText($settingsPath, [System.Text.UTF8Encoding]::new($false))
    if ($afterInvalid -ne $invalidJson) { throw 'Transient invalid JSON was overwritten.' }

    Write-TestSettings -Json '{"env":{"ANTHROPIC_BASE_URL":"https://recovered.example"},"customMarker":"after-invalid"}'
    Wait-ForCondition -FailureMessage 'Hook repair did not recover after settings.json became valid.' -Condition {
        try {
            $config = [System.IO.File]::ReadAllText($settingsPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            return $config.customMarker -eq 'after-invalid' -and $null -ne $config.hooks.PSObject.Properties['UserPromptSubmit']
        }
        catch { return $false }
    }

    Write-Host 'Configuration maintenance tests passed.' -ForegroundColor Green
}
catch {
    if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath }
    if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath | Write-Error }
    throw
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        $exitRequestPath = Join-Path $appRoot 'data\exit.request'
        [System.IO.File]::WriteAllText($exitRequestPath, '', [System.Text.UTF8Encoding]::new($false))
        if (-not $process.WaitForExit(5000)) { $process.Kill() }
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
