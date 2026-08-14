[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$statusSource = Get-Content -LiteralPath (Join-Path $projectRoot 'app\CCStatus.ps1') -Raw

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True ($statusSource -match 'ProcessPriorityClass\]::BelowNormal') 'CC Status does not yield CPU priority to monitored agents.'
Assert-True ($statusSource -match '\[System\.Windows\.Threading\.Dispatcher\]::Run\(\)') 'CC Status does not keep an independent dispatcher loop alive while hidden.'
Assert-True (-not ($statusSource -match '\.ShowDialog\(\)')) 'CC Status still uses a modal loop that exits when the window is hidden.'
Assert-True ($statusSource -match 'Apply-Theme') 'CC Status does not expose theme switching.'
Assert-True ($statusSource -match 'x:Name="ThemeButton"') 'CC Status does not place the theme button in the component.'
Assert-True ($statusSource -match 'x:Name="SoundButton"') 'CC Status does not place the sound button in the component.'
Assert-True ($statusSource -match 'x:Name="AppNameText"[^>]*Text="CC Status"') 'CC Status does not display its product name in the component.'
Assert-True (($statusSource -match "'🔔'") -and ($statusSource -match "'🔕'")) 'Sound button does not expose enabled and disabled icons.'
Assert-True (($statusSource -match '提示音已开启（点击关闭）') -and ($statusSource -match '提示音已关闭（点击开启）')) 'Sound button tooltips do not describe the toggle action.'
Assert-True (($statusSource -match "'☾'") -and ($statusSource -match "'☀'")) 'Theme button does not use moon and sun icons.'
Assert-True (-not ($statusSource -match 'themeMenuItem')) 'Theme switching is still exposed from the tray menu.'
Assert-True ($statusSource -match 'theme = \$script:currentTheme') 'CC Status does not persist the selected theme.'
Assert-True ($statusSource -match 'soundEnabled = \[bool\]\$script:soundEnabled') 'CC Status does not persist the sound setting.'
Assert-True ($statusSource -match 'if \(\$script:soundEnabled\) \{\s*if \(\$newState -eq ''approval''\)') 'CC Status sounds are not guarded by the sound setting.'
Assert-True ($statusSource -match 'function Test-StatusPath') 'CC Status does not tolerate transient path access failures.'
Assert-True ($statusSource -match 'function Invoke-ConfigurationMaintenance') 'CC Status does not monitor Claude configuration changes.'
Assert-True ($statusSource -match '\$script:claudeSettingsFingerprint = Get-StatusFileFingerprint -Path \$claudeSettingsPath\s*\$script:claudeSettingsChangedAt = \[DateTimeOffset\]::UtcNow') 'CC Status does not schedule a startup Hook verification after recording the configuration fingerprint.'
Assert-True ($statusSource -match '\$script:statusTimer\.add_Tick\(\{ Invoke-ConfigurationMaintenance; Invoke-StatusRefresh \}\)') 'CC Status timer does not maintain configuration before refreshing.'
Assert-True ($statusSource -match 'Claude settings\.json changed during hook repair') 'CC Status hook repair does not guard against concurrent configuration writes.'
Assert-True ($statusSource -match "Codex：周限制余\{0\}；今日用量\{1\}；缓存\{2\}；\{3\}") 'Codex usage tooltip does not use the explicit weekly-limit wording.'
Assert-True ($statusSource -match "Claude：今日用量\{0\}；缓存\{1\}；数据源 \{2\}") 'Claude usage tooltip contains duplicated or unsupported fields.'
Assert-True (-not ($statusSource -match 'Claude：\$claudeLine|Claude.*周限制')) 'Claude usage tooltip still duplicates its label or shows a weekly limit.'
Assert-True ($statusSource -match 'if \(-not \$window\.IsVisible\) \{ \$window\.Show\(\) \}\s*try \{\s*\[System\.Windows\.Threading\.Dispatcher\]::Run\(\)') 'CC Status startup can still show an already-visible window.'
Assert-True ($statusSource -match 'dispatcher failed:') 'CC Status does not record fatal dispatcher failures.'

Write-Host 'Application contract tests passed.' -ForegroundColor Green
