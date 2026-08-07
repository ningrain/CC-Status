[CmdletBinding()]
param(
    [string]$InnoCompiler = '',
    [switch]$SkipValidation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Split-Path -Parent $projectRoot
$versionPath = Join-Path $projectRoot 'VERSION'
if ([string]::IsNullOrWhiteSpace($InnoCompiler)) {
    $InnoCompiler = Join-Path $projectRoot 'tools\Inno Setup 6\ISCC.exe'
}
$source = Join-Path $PSScriptRoot 'CCStatusControl.cs'
$buildRoot = Join-Path $PSScriptRoot 'build'
$control = Join-Path $buildRoot 'CCStatusControl.exe'
$generatedVersionSource = Join-Path $buildRoot 'CCStatusVersion.g.cs'
$icon = Join-Path $projectRoot 'assets\CCStatus.ico'
$definition = Join-Path $PSScriptRoot 'CCStatus.iss'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$validator = Join-Path $PSScriptRoot 'Validate-Package.ps1'

if (-not (Test-Path -LiteralPath $versionPath)) { throw "找不到版本文件：$versionPath" }
if (-not (Test-Path -LiteralPath $compiler)) { throw "找不到 C# 编译器：$compiler" }
if (-not (Test-Path -LiteralPath $InnoCompiler)) { throw "找不到 Inno Setup 编译器：$InnoCompiler" }

$version = ([System.IO.File]::ReadAllText($versionPath, [System.Text.UTF8Encoding]::new($false))).Trim()
if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
    throw "VERSION 必须使用 MAJOR.MINOR.PATCH 格式：$version"
}
$assemblyVersion = "$version.0"

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
$generatedVersionText = @"
using System.Reflection;
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
"@
[System.IO.File]::WriteAllText($generatedVersionSource, $generatedVersionText, [System.Text.UTF8Encoding]::new($false))
& $compiler /nologo /target:winexe /optimize+ ("/out:$control") ("/win32icon:$icon") /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll $source $generatedVersionSource
if ($LASTEXITCODE -ne 0) { throw "控制程序编译失败：$LASTEXITCODE" }

Remove-StalePackages -Directory $outputRoot

& $InnoCompiler ("/DMyAppVersion=$version") ("/DMyVersionInfoVersion=$assemblyVersion") $definition
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
    & $validator -PackagePath $package -ExpectedVersion $version
}
