[CmdletBinding()]
param(
    [string]$InnoCompiler = '',
    [switch]$SkipValidation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Split-Path -Parent $projectRoot
if ([string]::IsNullOrWhiteSpace($InnoCompiler)) {
    $InnoCompiler = Join-Path $projectRoot 'tools\Inno Setup 6\ISCC.exe'
}
$source = Join-Path $PSScriptRoot 'CCStatusControl.cs'
$buildRoot = Join-Path $PSScriptRoot 'build'
$control = Join-Path $buildRoot 'CCStatusControl.exe'
$icon = Join-Path $projectRoot 'assets\CCStatus.ico'
$definition = Join-Path $PSScriptRoot 'CCStatus.iss'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$validator = Join-Path $PSScriptRoot 'Validate-Package.ps1'

if (-not (Test-Path -LiteralPath $compiler)) { throw "找不到 C# 编译器：$compiler" }
if (-not (Test-Path -LiteralPath $InnoCompiler)) { throw "找不到 Inno Setup 编译器：$InnoCompiler" }

$versionMatch = Select-String -Path $definition -Pattern '^#define\s+MyAppVersion\s+"([^"]+)"'
if ($null -eq $versionMatch) { throw "无法从 iss 读取 MyAppVersion：$definition" }
$version = $versionMatch.Matches[0].Groups[1].Value

function Remove-StalePackages {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $stale = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'CC-Status-Setup-*.exe' -or $_.Name -like 'CC Status Setup *.exe' })
    foreach ($file in $stale) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    if ($stale.Count -gt 0) {
        Write-Host "已清理旧安装包 $($stale.Count) 个（$Directory）" -ForegroundColor Yellow
    }
}

$null = New-Item -ItemType Directory -Path $buildRoot -Force
$null = New-Item -ItemType Directory -Path $outputRoot -Force
& $compiler /nologo /target:winexe /optimize+ ("/out:$control") ("/win32icon:$icon") /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0) { throw "控制程序编译失败：$LASTEXITCODE" }

Remove-StalePackages -Directory $outputRoot

& $InnoCompiler $definition
if ($LASTEXITCODE -ne 0) { throw "安装包编译失败：$LASTEXITCODE" }

$package = Join-Path $outputRoot "CC-Status-Setup-$version.exe"
Write-Host '安装包生成完成。' -ForegroundColor Green
Get-Item -LiteralPath $package

if (-not $SkipValidation) {
    Write-Host ''
    Write-Host '开始验证安装...' -ForegroundColor Cyan
    # 内联运行验证脚本：验证失败时 exit 1 会中止本次构建。
    # 不要用 Start-Process -Wait 包装（重定向输出时它会等待输出流 EOF，
    # 而常驻的小组件进程持有句柄，会导致构建进程无法退出）。
    & $validator -PackagePath $package
}
