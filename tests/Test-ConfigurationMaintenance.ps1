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
$settingsPath = Join-Path $claudeHome 'settings.json'
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
$null = New-Item -ItemType Directory -Path $appRoot, $claudeHome -Force
Copy-Item -Path (Join-Path $sourceAppRoot '*') -Destination $appRoot -Recurse -Force

try {
    Write-TestSettings -Json '{"env":{"ANTHROPIC_BASE_URL":"https://initial.example"},"customMarker":"initial"}'

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
            return $config.customMarker -eq 'initial' -and
                $null -ne $config.PSObject.Properties['hooks'] -and
                $null -ne $config.hooks.PSObject.Properties['UserPromptSubmit']
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
    foreach ($eventName in @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'PostToolBatch', 'PermissionDenied', 'Stop', 'StopFailure', 'SessionEnd', 'Notification')) {
        if ($null -eq $repaired.hooks.PSObject.Properties[$eventName]) { throw "Hook was not restored: $eventName" }
    }

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
