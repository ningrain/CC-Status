[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CCStatusNativeMethods
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);

    public static IntPtr FindCodexWindow()
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;
            var title = new StringBuilder(512);
            var className = new StringBuilder(256);
            GetWindowText(hWnd, title, title.Capacity);
            GetClassName(hWnd, className, className.Capacity);
            if (String.Equals(title.ToString(), "Codex", StringComparison.OrdinalIgnoreCase)) {
                result = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static IntPtr FindTerminalWindow()
    {
        IntPtr result = IntPtr.Zero;
        IntPtr fallback = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;
            var className = new StringBuilder(256);
            GetClassName(hWnd, className, className.Capacity);
            string value = className.ToString();
            if (String.Equals(value, "CASCADIA_HOSTING_WINDOW_CLASS", StringComparison.Ordinal)) {
                result = hWnd;
                return false;
            }
            if (fallback == IntPtr.Zero && String.Equals(value, "ConsoleWindowClass", StringComparison.Ordinal)) {
                fallback = hWnd;
            }
            return true;
        }, IntPtr.Zero);
        return result != IntPtr.Zero ? result : fallback;
    }

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@

$appRoot = $PSScriptRoot
$dataRoot = Join-Path $appRoot 'data'
$statePath = Join-Path $dataRoot 'state.json'
$settingsPath = Join-Path $dataRoot 'settings.json'
$exitRequestPath = Join-Path $dataRoot 'exit.request'
$showRequestPath = Join-Path $dataRoot 'show.request'
$pidPath = Join-Path $dataRoot 'status.pid'
$rolloutReaderPath = Join-Path $appRoot 'Get-CodexRolloutState.ps1'
$approvalReaderPath = Join-Path $appRoot 'Get-CodexApprovalState.ps1'
$usageReaderPath = Join-Path $appRoot 'Get-AgentUsageState.ps1'
$claudeTranscriptReaderPath = Join-Path $appRoot 'Get-ClaudeTranscriptState.ps1'

if (Test-Path -LiteralPath $rolloutReaderPath) {
    . $rolloutReaderPath
}
if (Test-Path -LiteralPath $approvalReaderPath) {
    . $approvalReaderPath
}
if (Test-Path -LiteralPath $usageReaderPath) {
    . $usageReaderPath
}
if (Test-Path -LiteralPath $claudeTranscriptReaderPath) {
    . $claudeTranscriptReaderPath
}

if (-not (Test-Path -LiteralPath $dataRoot)) {
    $null = New-Item -ItemType Directory -Path $dataRoot -Force
}

$createdNew = $false
$singleInstance = [System.Threading.Mutex]::new($true, 'Local\CCStatus-SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    $singleInstance.Dispose()
    exit 0
}

[System.IO.File]::WriteAllText($pidPath, [string]$PID, [System.Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $exitRequestPath) {
    Remove-Item -LiteralPath $exitRequestPath -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $showRequestPath) {
    Remove-Item -LiteralPath $showRequestPath -Force -ErrorAction SilentlyContinue
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CC Status"
        Width="390" Height="136"
        WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True">
    <Grid Margin="12">
        <Border x:Name="Card" CornerRadius="16" Background="#F3000000" BorderBrush="#555B6570" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect x:Name="CardShadow" Color="#000000" BlurRadius="24" ShadowDepth="7" Opacity="0.55" />
            </Border.Effect>
            <Grid Margin="17,4,14,4">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="55" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>

                <Grid Grid.Column="0" Width="56" Height="56" VerticalAlignment="Center">
                    <Ellipse x:Name="IndicatorGlow" Fill="#224DA3FF">
                        <Ellipse.Effect>
                            <BlurEffect Radius="10" />
                        </Ellipse.Effect>
                    </Ellipse>
                    <Ellipse x:Name="IndicatorRing" Stroke="#4DA3FF" StrokeThickness="3" Margin="4" />
                    <TextBlock x:Name="IndicatorIcon" Text="●" Foreground="#4DA3FF" FontFamily="Segoe UI Symbol"
                               FontSize="22" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" />
                </Grid>

                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="5,0,8,0">
                    <TextBlock x:Name="SourceText" Text="Codex 和 Claude Code" Foreground="#A0A8B5" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,0" />
                    <Grid VerticalAlignment="Center">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="StatusText" Grid.Column="0" Text="无任务" Foreground="#FFFFFF" FontSize="26" FontWeight="SemiBold" VerticalAlignment="Center" />
                        <StackPanel Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="Center">
                            <TextBlock x:Name="CodexUsageText" Text="Codex 余- 今- 缓-" Foreground="#BBC5D1" FontSize="11" Margin="0,0,0,0"
                                       TextTrimming="CharacterEllipsis" />
                            <TextBlock x:Name="ClaudeUsageText" Text="Claude 今- 缓-" Foreground="#BBC5D1" FontSize="11" Margin="0,0,0,0"
                                       TextTrimming="CharacterEllipsis" />
                        </StackPanel>
                    </Grid>
                    <TextBlock x:Name="DetailText" Text="CC Status 当前空闲" Foreground="#BBC5D1" FontSize="15" Margin="0,0,0,0" TextTrimming="CharacterEllipsis" />
                </StackPanel>

                <Button x:Name="OpenButton" Grid.Column="2" Content="打开" Visibility="Collapsed"
                        MinWidth="84" Height="32" Padding="10,0" VerticalAlignment="Center"
                        Foreground="#FFD9A0" Background="#121212" BorderBrush="#FFB020" BorderThickness="1"
                        FontSize="11" Cursor="Hand">
                    <Button.Resources>
                        <Style TargetType="Border">
                            <Setter Property="CornerRadius" Value="8" />
                        </Style>
                    </Button.Resources>
                </Button>
            </Grid>
        </Border>
        <Button x:Name="ThemeButton" Content="☾" ToolTip="黑色主题（点击切换为白色）" Width="22" Height="22"
                HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,34,0"
                Background="Transparent" Foreground="#F0F0F0" BorderThickness="0"
                FontFamily="Segoe UI Symbol" FontSize="14" Cursor="Hand">
            <Button.Template>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="ThemeButtonBorder" Background="{TemplateBinding Background}" CornerRadius="7">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="ThemeButtonBorder" Property="Background" Value="#8890A0B0" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Button.Template>
        </Button>
        <Button x:Name="CloseButton" Content="✕" ToolTip="隐藏到托盘" Width="22" Height="22"
                HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,8,0"
                Background="Transparent" Foreground="#F0F0F0" BorderThickness="0"
                FontFamily="Segoe UI" FontSize="11" Cursor="Hand">
            <Button.Template>
                <ControlTemplate TargetType="Button">
                    <Border x:Name="CloseButtonBorder" Background="{TemplateBinding Background}" CornerRadius="7">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="CloseButtonBorder" Property="Background" Value="#CCE81123" />
                            <Setter Property="Foreground" Value="#FFFFFF" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Button.Template>
        </Button>
    </Grid>
</Window>
"@

$xmlReader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
$card = $window.FindName('Card')
$cardShadow = $window.FindName('CardShadow')
$indicatorGlow = $window.FindName('IndicatorGlow')
$indicatorRing = $window.FindName('IndicatorRing')
$indicatorIcon = $window.FindName('IndicatorIcon')
$sourceText = $window.FindName('SourceText')
$statusText = $window.FindName('StatusText')
$codexUsageText = $window.FindName('CodexUsageText')
$claudeUsageText = $window.FindName('ClaudeUsageText')
$detailText = $window.FindName('DetailText')
$openButton = $window.FindName('OpenButton')
$themeButton = $window.FindName('ThemeButton')
$closeButton = $window.FindName('CloseButton')

$script:lastAggregateState = ''
$script:lastStateWrite = [DateTime]::MinValue
$script:topmostEnabled = $true
$script:isExiting = $false
$script:currentOpenSurface = 'desktop'
$script:currentOpenCwd = ''
$script:currentOpenThreadId = ''
$script:currentOpenProvider = 'codex'
$script:currentTheme = 'dark'

function New-Brush {
    param([string]$Color)
    return [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Format-Duration {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return '{0:0} 小时 {1:00} 分' -f [Math]::Floor($Duration.TotalHours), $Duration.Minutes
    }
    return '{0:00}:{1:00}' -f [Math]::Floor($Duration.TotalMinutes), $Duration.Seconds
}

function Get-WorkspaceLabel {
    param([object[]]$Sessions)

    $paths = @($Sessions | ForEach-Object { [string]$_.cwd } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($paths.Count -eq 1) {
        try { return Split-Path -Leaf $paths[0] } catch { return $paths[0] }
    }
    if ($paths.Count -gt 1) {
        return '{0} 个工作区' -f $paths.Count
    }
    return ''
}

function Get-AgentProvider {
    param([object]$Session)

    if ($null -ne $Session.PSObject.Properties['provider'] -and -not [string]::IsNullOrWhiteSpace([string]$Session.provider)) {
        return ([string]$Session.provider).ToLowerInvariant()
    }
    return 'codex'
}

function Get-AgentSourceLabel {
    param([object[]]$Sessions)

    $providers = @($Sessions | ForEach-Object { Get-AgentProvider -Session $_ } | Sort-Object -Unique)
    if ($providers.Count -eq 0) { return 'Codex 和 Claude Code' }
    if ($providers -contains 'codex' -and $providers -contains 'claude') { return 'Codex 和 Claude Code' }
    if ($providers -contains 'claude') { return 'Claude Code' }
    return 'Codex'
}

function Apply-Theme {
    param([ValidateSet('dark', 'light')][string]$Theme)

    $script:currentTheme = $Theme
    if ($Theme -eq 'light') {
        $card.Background = New-Brush '#F9FFFFFF'
        $card.BorderBrush = New-Brush '#553C4B5D'
        $cardShadow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#667A8998')
        $cardShadow.Opacity = 0.35
        $sourceText.Foreground = New-Brush '#64748B'
        $statusText.Foreground = New-Brush '#17212F'
        $codexUsageText.Foreground = New-Brush '#64748B'
        $claudeUsageText.Foreground = New-Brush '#64748B'
        $detailText.Foreground = New-Brush '#5B6675'
        $openButton.Foreground = New-Brush '#8A5800'
        $openButton.Background = New-Brush '#FFFFFFFF'
        $themeButton.Foreground = New-Brush '#9A6700'
        $closeButton.Foreground = New-Brush '#334155'
    }
    else {
        $card.Background = New-Brush '#F3000000'
        $card.BorderBrush = New-Brush '#555B6570'
        $cardShadow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#000000')
        $cardShadow.Opacity = 0.55
        $sourceText.Foreground = New-Brush '#A0A8B5'
        $statusText.Foreground = New-Brush '#FFFFFF'
        $codexUsageText.Foreground = New-Brush '#BBC5D1'
        $claudeUsageText.Foreground = New-Brush '#BBC5D1'
        $detailText.Foreground = New-Brush '#BBC5D1'
        $openButton.Foreground = New-Brush '#FFD9A0'
        $openButton.Background = New-Brush '#121212'
        $themeButton.Foreground = New-Brush '#F0F0F0'
        $closeButton.Foreground = New-Brush '#F0F0F0'
    }

    $themeButton.Content = if ($Theme -eq 'dark') { '☾' } else { '☀' }
    $themeButton.ToolTip = if ($Theme -eq 'dark') { '黑色主题（点击切换为白色）' } else { '白色主题（点击切换为黑色）' }
}

function Format-UsageTokens {
    param([object]$Value)

    if ($null -eq $Value) { return '-' }
    try {
        $number = [double]$Value
        if ($number -ge 1000000) { return '{0:0.0}M' -f ($number / 1000000) }
        if ($number -ge 1000) { return '{0:0.0}K' -f ($number / 1000) }
        return '{0:0}' -f $number
    }
    catch { return '-' }
}

function Format-UsagePercent {
    param([object]$Value)

    if ($null -eq $Value) { return '-' }
    try { return '{0:0}%' -f [double]$Value } catch { return '-' }
}

function Format-UsageResetTime {
    param([object]$Value)

    if ($null -eq $Value) { return '-' }
    try { return '{0:M月d日 HH:mm} 重置' -f ([DateTimeOffset]$Value).ToLocalTime() } catch { return '-' }
}

function Set-UsageVisual {
    param([object]$Usage)

    $codex = if ($null -ne $Usage -and $null -ne $Usage.PSObject.Properties['codex']) { $Usage.codex } else { $null }
    $claude = if ($null -ne $Usage -and $null -ne $Usage.PSObject.Properties['claude']) { $Usage.claude } else { $null }
    $codexWeekly = if ($null -ne $codex) { $codex.weeklyRemainingPercent } else { $null }
    $codexTokens = if ($null -ne $codex) { $codex.totalTokens } else { $null }
    $codexCache = if ($null -ne $codex) { $codex.cachePercent } else { $null }
    $claudeTokens = if ($null -ne $claude) { $claude.totalTokens } else { $null }
    $claudeCache = if ($null -ne $claude) { $claude.cachePercent } else { $null }
    $codexLine = 'Codex 余{0} 今{1} 缓{2}' -f (Format-UsagePercent $codexWeekly), (Format-UsageTokens $codexTokens), (Format-UsagePercent $codexCache)
    $claudeLine = 'Claude 今{0} 缓{1}' -f (Format-UsageTokens $claudeTokens), (Format-UsagePercent $claudeCache)
    $codexUsageText.Text = $codexLine
    $claudeUsageText.Text = $claudeLine
    $codexReset = if ($null -ne $codex) { Format-UsageResetTime $codex.weeklyResetAt } else { '-' }
    $codexUsageText.ToolTip = "Codex：$codexLine；$codexReset"
    $claudeUsageText.ToolTip = "Claude：$claudeLine；周限制 -"
}

function Normalize-AgentSession {
    param([Parameter(Mandatory)]$Session)

    if ($null -eq $Session.PSObject.Properties['provider'] -or [string]::IsNullOrWhiteSpace([string]$Session.provider)) {
        $Session | Add-Member -NotePropertyName provider -NotePropertyValue 'codex'
    }
    else {
        $Session.provider = ([string]$Session.provider).ToLowerInvariant()
    }

    if ([string]$Session.provider -eq 'claude' -and ($null -eq $Session.PSObject.Properties['surface'] -or [string]::IsNullOrWhiteSpace([string]$Session.surface))) {
        $Session | Add-Member -NotePropertyName surface -NotePropertyValue 'cli'
    }
    return $Session
}

function Set-StatusVisual {
    param(
        [string]$State,
        [object[]]$Sessions
    )

    $now = [DateTimeOffset]::UtcNow
    $newState = $State
    $count = @($Sessions).Count
    $workspace = Get-WorkspaceLabel -Sessions $Sessions
    $sourceLabel = Get-AgentSourceLabel -Sessions $Sessions
    $sourceText.Text = $sourceLabel
    $latestSession = @($Sessions | Sort-Object { [DateTimeOffset]::Parse([string]$_.updatedAt) } -Descending | Select-Object -First 1)
    if ($latestSession.Count -gt 0) {
        $latestProvider = Get-AgentProvider -Session $latestSession[0]
        $script:currentOpenProvider = $latestProvider
        $script:currentOpenCwd = [string]$latestSession[0].cwd
        if ($latestProvider -eq 'claude' -or ($null -ne $latestSession[0].PSObject.Properties['surface'] -and [string]$latestSession[0].surface -eq 'cli')) {
            $script:currentOpenSurface = 'cli'
        }
        else {
            $script:currentOpenSurface = 'desktop'
        }
        if ($script:currentOpenSurface -eq 'cli' -or $latestProvider -ne 'codex') {
            $script:currentOpenThreadId = ''
        }
        else {
            $script:currentOpenThreadId = [string]$latestSession[0].sessionId
        }
    }
    $openLabel = if ($script:currentOpenSurface -eq 'cli') { '打开终端' } elseif ($script:currentOpenProvider -eq 'claude') { '打开 Claude Code' } else { '打开 Codex' }
    $openButton.Content = $openLabel
    if ($null -ne (Get-Variable -Name openMenuItem -Scope Script -ErrorAction SilentlyContinue)) {
        $openMenuItem.Text = $openLabel
    }

    $codexUsageText.Visibility = 'Visible'
    $claudeUsageText.Visibility = 'Visible'
    $detailText.Visibility = 'Visible'

    switch ($State) {
        'approval' {
            $accent = '#FFB020'
            $indicatorIcon.Text = '!'
            $statusText.Text = '需要批准'
            $codexUsageText.Visibility = 'Collapsed'
            $claudeUsageText.Visibility = 'Collapsed'
            $detailText.Text = if ($workspace) { $workspace } elseif ($count -gt 1) { "$count 个工作区" } else { '当前项目' }
            $detailText.Visibility = 'Visible'
            $openButton.Visibility = 'Visible'
        }
        'working' {
            $accent = '#4DA3FF'
            $indicatorIcon.Text = '●'
            $statusText.Text = '工作中'
            $latest = @($Sessions | Sort-Object { [DateTimeOffset]::Parse([string]$_.updatedAt) } -Descending | Select-Object -First 1)
            $elapsed = [TimeSpan]::Zero
            if ($latest.Count -gt 0) {
                $startValue = if ($null -ne $latest[0].PSObject.Properties['startedAt']) { [string]$latest[0].startedAt } else { [string]$latest[0].updatedAt }
                $elapsed = $now - [DateTimeOffset]::Parse($startValue)
            }
            $durationText = Format-Duration -Duration $elapsed
            $detailText.Text = if ($count -gt 1) {
                if ([string]::IsNullOrWhiteSpace($workspace)) { "$count 个任务运行中 · $durationText" }
                else { "$count 个任务运行中（$workspace）· $durationText" }
            } elseif ($workspace) { "$workspace · $durationText" } else { "正在处理任务 · $durationText" }
            $openButton.Visibility = 'Collapsed'
        }
        'completed' {
            $accent = '#38D996'
            $indicatorIcon.Text = '✓'
            $statusText.Text = '已完成'
            $latest = @($Sessions | Sort-Object { [DateTimeOffset]::Parse([string]$_.updatedAt) } -Descending | Select-Object -First 1)
            $completedTime = if ($latest.Count -gt 0) { [DateTimeOffset]::Parse([string]$latest[0].updatedAt).ToLocalTime().ToString('HH:mm') } else { [DateTime]::Now.ToString('HH:mm') }
            $detailText.Text = if ($count -gt 1) { "$count 个任务已完成 · $completedTime" } elseif ($workspace) { "$workspace · $completedTime 完成" } else { "任务已于 $completedTime 完成" }
            $openButton.Visibility = 'Collapsed'
        }
        default {
            $newState = 'idle'
            $accent = '#78869A'
            $indicatorIcon.Text = '·'
            $statusText.Text = '无任务'
            $detailText.Text = 'CC Status 当前空闲'
            $openButton.Visibility = 'Collapsed'
        }
    }

    $accentBrush = New-Brush $accent
    $indicatorRing.Stroke = $accentBrush
    $indicatorIcon.Foreground = $accentBrush
    $indicatorGlow.Fill = New-Brush ($accent -replace '^#', '#33')

    if ($newState -eq 'working') {
        $animation = [System.Windows.Media.Animation.DoubleAnimation]::new()
        $animation.From = 0.35
        $animation.To = 1.0
        $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(900))
        $animation.AutoReverse = $true
        $animation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $indicatorGlow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $animation)
    }
    else {
        $indicatorGlow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $indicatorGlow.Opacity = 0.85
    }

    if ($script:lastAggregateState -ne $newState) {
        if ($newState -eq 'approval') {
            [System.Media.SystemSounds]::Exclamation.Play()
        }
        elseif ($newState -eq 'completed') {
            [System.Media.SystemSounds]::Asterisk.Play()
        }
        $script:lastAggregateState = $newState
    }

    $notifyIcon.Text = switch ($newState) {
        'approval' { "$sourceLabel：需要批准" }
        'working' { "$sourceLabel：工作中" }
        'completed' { "$sourceLabel：已完成" }
        default { "$sourceLabel：无任务" }
    }
}

function Update-StatusState {
    if (Test-Path -LiteralPath $exitRequestPath) {
        $script:isExiting = $true
        $window.Close()
        return
    }
    if (Test-Path -LiteralPath $showRequestPath) {
        Remove-Item -LiteralPath $showRequestPath -Force -ErrorAction SilentlyContinue
        if (-not $window.IsVisible) { $window.Show() }
        $window.Activate()
    }

    $usageState = $null
    if (Get-Command Get-AgentUsageState -ErrorAction SilentlyContinue) {
        try { $usageState = Get-AgentUsageState } catch {}
    }
    Set-UsageVisual -Usage $usageState

    $sessions = @()
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $sessions = @($state.sessions)
        }
        catch {
            $sessions = @()
        }
    }

    if (Get-Command Get-CodexRolloutSessions -ErrorAction SilentlyContinue) {
        try {
            $sessions += @(Get-CodexRolloutSessions)
        }
        catch {}
    }
    if (Get-Command Get-CodexLogApprovalSessions -ErrorAction SilentlyContinue) {
        try {
            $sessions += @(Get-CodexLogApprovalSessions)
        }
        catch {}
    }

    $sessions = @($sessions | ForEach-Object { Normalize-AgentSession -Session $_ })

    $now = [DateTimeOffset]::UtcNow
    if (Get-Command Resolve-CodexSessionStates -ErrorAction SilentlyContinue) {
        $sessions = @(Resolve-CodexSessionStates -Sessions $sessions -Now $now)
    }
    if (Get-Command Resolve-ClaudeTranscriptStates -ErrorAction SilentlyContinue) {
        try { $sessions = @(Resolve-ClaudeTranscriptStates -Sessions $sessions -Now $now) } catch {}
    }
    $activeCutoff = $now.AddHours(-12)
    $completedCutoff = $now.AddSeconds(-90)
    $staleWorkingCutoff = $now.AddMinutes(-10)
    $hookOnlyWorkingCutoff = $now.AddSeconds(-120)
    $approvalSessions = @()
    $workingSessions = @()
    $completedSessions = @()
    $deniedApprovalThreads = @()
    if (Get-Command Get-CodexApprovalDeniedThreadIds -ErrorAction SilentlyContinue) {
        $deniedApprovalThreads = @(Get-CodexApprovalDeniedThreadIds)
    }

    foreach ($session in $sessions) {
        try {
            $updatedAt = [DateTimeOffset]::Parse([string]$session.updatedAt)
            switch ([string]$session.status) {
                'approval' { if ($updatedAt -ge $activeCutoff) { $approvalSessions += $session } }
                'working' {
                    if ($deniedApprovalThreads -contains [string]$session.sessionId) { continue }
                    $liveBacked = $null -ne $session.PSObject.Properties['isLive'] -and [bool]$session.isLive
                    # 仅 hook 记录的会话（如 codex exec / 无 rollout 文件的 CLI 会话）
                    # 没有文件锁存活信号，最后一次活动 120 秒后即视为已结束，
                    # 避免关闭后仍长时间显示“工作中”。
                    $hookOnly = $null -eq $session.PSObject.Properties['isLive']
                    $workingCutoff = if ($hookOnly) { $hookOnlyWorkingCutoff } else { $staleWorkingCutoff }
                    if ($updatedAt -ge $activeCutoff -and ($liveBacked -or $updatedAt -ge $workingCutoff)) {
                        $workingSessions += $session
                    }
                }
                'completed' { if ($updatedAt -ge $completedCutoff) { $completedSessions += $session } }
            }
        }
        catch {}
    }

    if ($approvalSessions.Count -gt 0) {
        $script:currentOpenThreadId = [string]$approvalSessions[0].sessionId
        Set-StatusVisual -State 'approval' -Sessions $approvalSessions
    }
    elseif ($workingSessions.Count -gt 0) {
        $script:currentOpenThreadId = ''
        Set-StatusVisual -State 'working' -Sessions $workingSessions
    }
    elseif ($completedSessions.Count -gt 0) {
        $script:currentOpenThreadId = ''
        Set-StatusVisual -State 'completed' -Sessions $completedSessions
    }
    else {
        $script:currentOpenThreadId = ''
        Set-StatusVisual -State 'idle' -Sessions @()
    }
}

function Save-StatusSettings {
    try {
        $settings = [pscustomobject][ordered]@{
            left = [Math]::Round($window.Left, 2)
            top = [Math]::Round($window.Top, 2)
            topmost = [bool]$script:topmostEnabled
            theme = $script:currentTheme
        }
        [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    }
    catch {}
}

function Restore-StatusSettings {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $workArea.Right - $window.Width - 18
    $window.Top = $workArea.Top + 18
    Apply-Theme -Theme 'dark'

    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = [System.IO.File]::ReadAllText($settingsPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            if ($null -ne $settings.left -and $null -ne $settings.top) {
                $window.Left = [Math]::Max($workArea.Left, [Math]::Min([double]$settings.left, $workArea.Right - $window.Width))
                $window.Top = [Math]::Max($workArea.Top, [Math]::Min([double]$settings.top, $workArea.Bottom - $window.Height))
            }
            if ($null -ne $settings.topmost) {
                $script:topmostEnabled = [bool]$settings.topmost
                $window.Topmost = $script:topmostEnabled
            }
            if ($null -ne $settings.theme) {
                $savedTheme = ([string]$settings.theme).ToLowerInvariant()
                if ($savedTheme -eq 'light') { Apply-Theme -Theme 'light' }
                else { Apply-Theme -Theme 'dark' }
            }
        }
        catch {}
    }
}

function Invoke-ThreadDeepLink {
    if ([string]::IsNullOrWhiteSpace($script:currentOpenThreadId)) { return }

    $url = "codex://threads/$($script:currentOpenThreadId)"

    # 优先走官方方式：启动 AppX 包在 manifest 中声明的 codex 协议入口，
    # 传 resources\app.asar + 深链，绕开 MSIX 协议处理器可能无法导航的缺陷。
    try {
        $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue
        if ($null -ne $package) {
            $manifest = Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction SilentlyContinue
            if ($null -ne $manifest) {
                $exeRelative = ''
                foreach ($appNode in @($manifest.Package.Applications.Application)) {
                    foreach ($extNode in @($appNode.Extensions.Extension)) {
                        if ($null -ne $extNode -and $extNode.Category -eq 'windows.protocol' -and $null -ne $extNode.Protocol -and $extNode.Protocol.Name -eq 'codex') {
                            $exeRelative = [string]$appNode.Executable
                            break
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($exeRelative)) { break }
                }
                if (-not [string]::IsNullOrWhiteSpace($exeRelative)) {
                    $appExe = Join-Path $package.InstallLocation $exeRelative
                    $appDir = Split-Path -Parent $appExe
                    $appBundle = Join-Path $appDir 'resources\app.asar'
                    if ((Test-Path -LiteralPath $appExe) -and (Test-Path -LiteralPath $appBundle)) {
                        Start-Process -FilePath $appExe -WorkingDirectory $appDir -ArgumentList @('resources\app.asar', $url)
                        return
                    }
                }
            }
        }
    }
    catch {}

    # 兜底：走系统注册的 codex:// 协议
    try { Start-Process $url } catch {}
}

function Open-Codex {
    try {
        # CLI 会话：审批发生在终端里，直接激活终端即可，不跳桌面应用
        if ($script:currentOpenSurface -eq 'cli') {
            $terminalWindow = [CCStatusNativeMethods]::FindTerminalWindow()
            if ($terminalWindow -ne [IntPtr]::Zero) {
                $null = [CCStatusNativeMethods]::ShowWindowAsync($terminalWindow, 9)
                $null = [CCStatusNativeMethods]::SetForegroundWindow($terminalWindow)
                return
            }

            $terminalCommand = Get-Command wt.exe -ErrorAction SilentlyContinue
            if ($null -ne $terminalCommand) {
                $arguments = @()
                if (-not [string]::IsNullOrWhiteSpace($script:currentOpenCwd) -and (Test-Path -LiteralPath $script:currentOpenCwd)) {
                    $arguments = @('-d', ('"{0}"' -f $script:currentOpenCwd.Replace('"', '\"')))
                }
                Start-Process -FilePath $terminalCommand.Source -ArgumentList $arguments
                return
            }
        }

        # 桌面会话：有待审批会话时，直接深链跳转到该会话
        if (-not [string]::IsNullOrWhiteSpace($script:currentOpenThreadId)) {
            Invoke-ThreadDeepLink
            return
        }

        $codexWindow = [CCStatusNativeMethods]::FindCodexWindow()
        if ($codexWindow -ne [IntPtr]::Zero) {
            $null = [CCStatusNativeMethods]::ShowWindowAsync($codexWindow, 9)
            $null = [CCStatusNativeMethods]::SetForegroundWindow($codexWindow)
            return
        }

        $candidate = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match '^(ChatGPT|Codex)$' -and $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1

        if ($null -ne $candidate) {
            $null = [CCStatusNativeMethods]::ShowWindowAsync($candidate.MainWindowHandle, 9)
            $null = [CCStatusNativeMethods]::SetForegroundWindow($candidate.MainWindowHandle)
            return
        }

        $executable = Get-Process ChatGPT -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
            Select-Object -First 1 -ExpandProperty Path

        if (-not [string]::IsNullOrWhiteSpace($executable)) {
            Start-Process -FilePath $executable
            return
        }

        $startApp = Get-StartApps -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Codex|ChatGPT' } |
            Select-Object -First 1
        if ($null -ne $startApp) {
            Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($startApp.AppID)"
        }
    }
    catch {}
}

function Add-HookProperty {
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

function Test-EventHasStatusHandler {
    param(
        [Parameter(Mandatory)]$Hooks,
        [Parameter(Mandatory)][string]$EventName
    )

    if ($null -eq $Hooks.PSObject.Properties[$EventName]) { return $false }
    foreach ($group in @($Hooks.$EventName)) {
        $handlers = @()
        if ($null -ne $group.PSObject.Properties['hooks']) { $handlers = @($group.hooks) }
        foreach ($handler in $handlers) {
            if (Test-StatusHandler $handler) { return $true }
        }
    }
    return $false
}

function Test-NotificationMatcherHandler {
    param(
        [Parameter(Mandatory)]$Hooks,
        [Parameter(Mandatory)][string]$Matcher
    )

    if ($null -eq $Hooks.PSObject.Properties['Notification']) { return $false }
    foreach ($group in @($Hooks.Notification)) {
        $groupMatcher = ''
        if ($null -ne $group.PSObject.Properties['matcher']) { $groupMatcher = [string]$group.matcher }
        if ($groupMatcher -ne $Matcher) { continue }
        $handlers = @()
        if ($null -ne $group.PSObject.Properties['hooks']) { $handlers = @($group.hooks) }
        foreach ($handler in $handlers) {
            if (Test-StatusHandler $handler) { return $true }
        }
    }
    return $false
}

function Add-ClaudeStatusHook {
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
    Add-HookProperty -Object $Hooks -Name $EventName -Value $groups
}

function Add-CodexStatusHook {
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
    Add-HookProperty -Object $Hooks -Name $EventName -Value $groups
}

function Save-ConfigAtomic {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $tempPath = '{0}.repair.tmp' -f $Path
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Write-RepairLog {
    param([string]$Message)

    try {
        if (-not (Test-Path -LiteralPath $dataRoot)) {
            $null = New-Item -ItemType Directory -Path $dataRoot -Force
        }
        $logPath = Join-Path $dataRoot 'hook-repair.log'
        $line = '{0:o} {1}' -f [DateTimeOffset]::UtcNow, $Message
        [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }
    catch {}
}

function Repair-StatusHooks {
    $claudeBridgePath = Join-Path $appRoot 'Write-ClaudeStatus.ps1'
    $codexBridgePath = Join-Path $appRoot 'Write-Codex.ps1'

    if (Test-Path -LiteralPath $claudeBridgePath) {
        try {
            $claudeSettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
            $config = [pscustomobject][ordered]@{}
            if (Test-Path -LiteralPath $claudeSettingsPath) {
                $config = [System.IO.File]::ReadAllText($claudeSettingsPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            }
            if ($null -eq $config.PSObject.Properties['hooks'] -or $null -eq $config.hooks) {
                Add-HookProperty -Object $config -Name 'hooks' -Value ([pscustomobject]@{})
            }

            $claudeEvents = @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'PostToolBatch', 'PermissionDenied', 'Stop', 'StopFailure', 'SessionEnd')
            $changed = $false
            foreach ($eventName in $claudeEvents) {
                if (-not (Test-EventHasStatusHandler -Hooks $config.hooks -EventName $eventName)) {
                    Add-ClaudeStatusHook -Hooks $config.hooks -EventName $eventName -ScriptPath $claudeBridgePath
                    $changed = $true
                }
            }
            foreach ($matcher in @('permission_prompt', 'idle_prompt')) {
                if (-not (Test-NotificationMatcherHandler -Hooks $config.hooks -Matcher $matcher)) {
                    Add-ClaudeStatusHook -Hooks $config.hooks -EventName 'Notification' -ScriptPath $claudeBridgePath -Matcher $matcher
                    $changed = $true
                }
            }

            if ($changed) {
                Save-ConfigAtomic -Value $config -Path $claudeSettingsPath
                Write-RepairLog "claude hooks restored: $claudeSettingsPath"
            }
        }
        catch {
            Write-RepairLog ('claude hooks repair failed: ' + $_.Exception.Message)
        }
    }

    if (Test-Path -LiteralPath $codexBridgePath) {
        try {
            $codexHooksPath = Join-Path $env:USERPROFILE '.codex\hooks.json'
            $config = [pscustomobject][ordered]@{}
            if (Test-Path -LiteralPath $codexHooksPath) {
                $config = [System.IO.File]::ReadAllText($codexHooksPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            }
            if ($null -eq $config.PSObject.Properties['hooks'] -or $null -eq $config.hooks) {
                Add-HookProperty -Object $config -Name 'hooks' -Value ([pscustomobject]@{})
            }

            $escapedCodexBridgePath = $codexBridgePath.Replace('"', '\"')
            $codexHookCommand = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "{0}"' -f $escapedCodexBridgePath

            $codexEvents = @('UserPromptSubmit', 'PermissionRequest', 'PostToolUse', 'Stop')
            $changed = $false
            foreach ($eventName in $codexEvents) {
                if (-not (Test-EventHasStatusHandler -Hooks $config.hooks -EventName $eventName)) {
                    $matcher = if ($eventName -eq 'PermissionRequest' -or $eventName -eq 'PostToolUse') { '.*' } else { '' }
                    Add-CodexStatusHook -Hooks $config.hooks -EventName $eventName -Matcher $matcher -Command $codexHookCommand
                    $changed = $true
                }
            }

            if ($changed) {
                Save-ConfigAtomic -Value $config -Path $codexHooksPath
                Write-RepairLog "codex hooks restored: $codexHooksPath"
            }
        }
        catch {
            Write-RepairLog ('codex hooks repair failed: ' + $_.Exception.Message)
        }
    }
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIconPath = Join-Path $appRoot 'CCStatus.ico'
if (-not (Test-Path -LiteralPath $trayIconPath)) {
    $assetIconPath = Join-Path (Split-Path -Parent $appRoot) 'assets\CCStatus.ico'
    if (Test-Path -LiteralPath $assetIconPath) { $trayIconPath = $assetIconPath }
}
$ownsTrayIcon = Test-Path -LiteralPath $trayIconPath
$trayIcon = if ($ownsTrayIcon) { New-Object System.Drawing.Icon($trayIconPath) } else { [System.Drawing.SystemIcons]::Application }
$notifyIcon.Icon = $trayIcon
$notifyIcon.Text = 'CC Status：无任务'
$notifyIcon.Visible = $true
$script:hideTipShown = $false

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showMenuItem = $contextMenu.Items.Add('显示 / 隐藏')
$openMenuItem = $contextMenu.Items.Add('打开')
$topmostMenuItem = $contextMenu.Items.Add('保持置顶')
$topmostMenuItem.Checked = $true
$null = $contextMenu.Items.Add('-')
$exitMenuItem = $contextMenu.Items.Add('退出小组件')
$notifyIcon.ContextMenuStrip = $contextMenu

$showMenuItem.add_Click({
    if ($window.IsVisible) { $window.Hide() } else { $window.Show(); $window.Activate() }
})
$openMenuItem.add_Click({ Open-Codex })
$themeButton.add_Click({
    $nextTheme = if ($script:currentTheme -eq 'dark') { 'light' } else { 'dark' }
    Apply-Theme -Theme $nextTheme
    Save-StatusSettings
})
$topmostMenuItem.add_Click({
    $script:topmostEnabled = -not $script:topmostEnabled
    $window.Topmost = $script:topmostEnabled
    $topmostMenuItem.Checked = $script:topmostEnabled
    Save-StatusSettings
})
$exitMenuItem.add_Click({
    $script:isExiting = $true
    $window.Close()
})
$notifyIcon.add_DoubleClick({
    if ($window.IsVisible) { $window.Activate() } else { $window.Show(); $window.Activate() }
})

$card.add_MouseLeftButtonDown({
    if ($_.ClickCount -ge 2) {
        Open-Codex
        return
    }
    if ($_.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        try { $window.DragMove(); Save-StatusSettings } catch {}
    }
})
$openButton.add_Click({ Open-Codex })
$closeButton.add_Click({
    # 关闭按钮 = 隐藏到托盘；关闭事件由 Closing 处理（取消关闭并隐藏，首次弹出恢复提示）。
    $window.Close()
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(850)
$timer.add_Tick({ Update-StatusState })

$window.add_SourceInitialized({ Restore-StatusSettings })
$window.add_Closing({
    param($sender, $eventArgs)
    if (-not $script:isExiting) {
        $eventArgs.Cancel = $true
        $window.Hide()
        if (-not $script:hideTipShown) {
            try {
    $notifyIcon.ShowBalloonTip(
                    3500,
                    'CC Status',
                    '已隐藏到右下角托盘。双击 CC Status 图标可恢复。',
                    [System.Windows.Forms.ToolTipIcon]::Info
                )
            }
            catch {
                # Windows may suppress notification balloons; hiding must still succeed.
            }
            $script:hideTipShown = $true
        }
        return
    }
    Save-StatusSettings
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($ownsTrayIcon -and $null -ne $trayIcon) { $trayIcon.Dispose() }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $exitRequestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $showRequestPath -Force -ErrorAction SilentlyContinue
})
$window.add_Closed({
    $window.Dispatcher.InvokeShutdown()
})

Repair-StatusHooks
Update-StatusState
$timer.Start()
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()

try { $singleInstance.ReleaseMutex() } catch {}
$singleInstance.Dispose()
