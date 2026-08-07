[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tests = @(
    'Test-Version.ps1',
    'Test-StatusBridge.ps1',
    'Test-RolloutMonitor.ps1',
    'Test-ApprovalMonitor.ps1',
    'Test-ClaudeTranscriptState.ps1',
    'Test-AgentUsage.ps1',
    'Test-Installer.ps1'
)

foreach ($testName in $tests) {
    $testPath = Join-Path $PSScriptRoot $testName
    Write-Host "[Tests] $testName" -ForegroundColor Cyan
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $testPath
    if ($LASTEXITCODE -ne 0) {
        throw "$testName failed with exit code $LASTEXITCODE"
    }
}

Write-Host '[Tests] ALL PASS' -ForegroundColor Green
