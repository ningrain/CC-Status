[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$bridgePath = Join-Path $PSScriptRoot 'Write-AgentStatus.ps1'
& $bridgePath -Provider 'codex'
exit $LASTEXITCODE
