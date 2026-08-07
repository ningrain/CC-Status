[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path $projectRoot 'VERSION'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $versionPath -PathType Leaf) 'VERSION file is missing.'
$version = ([System.IO.File]::ReadAllText($versionPath, [System.Text.UTF8Encoding]::new($false))).Trim()
Assert-True ($version -match '^\d+\.\d+\.\d+$') "VERSION is not MAJOR.MINOR.PATCH: $version"

$definition = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\CCStatus.iss') -Raw
$controlSource = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\CCStatusControl.cs') -Raw
$buildSource = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Build-Installer.ps1') -Raw
$validatorSource = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Validate-Package.ps1') -Raw
$readme = Get-Content -LiteralPath (Join-Path $projectRoot 'README.md') -Raw
$changelog = Get-Content -LiteralPath (Join-Path $projectRoot 'CHANGELOG.md') -Raw

Assert-True (-not ($definition -match '#define\s+MyAppVersion\s+"')) 'CCStatus.iss still hard-codes MyAppVersion.'
Assert-True ($definition -match 'MyAppVersion must be supplied by Build-Installer\.ps1') 'CCStatus.iss does not require the centralized version.'
Assert-True ($definition -match 'Source:\s*"\.\.\\VERSION"') 'CCStatus.iss does not include VERSION in the package.'
Assert-True (-not ($controlSource -match 'Assembly(File)?Version\("')) 'CCStatusControl.cs still hard-codes an assembly version.'
Assert-True ($buildSource -match 'Join-Path \$projectRoot ''VERSION''') 'Build-Installer.ps1 does not read VERSION.'
Assert-True ($buildSource -match 'CCStatusVersion\.g\.cs') 'Build-Installer.ps1 does not generate assembly version metadata.'
Assert-True ($validatorSource -match '\$ExpectedVersion') 'Validate-Package.ps1 does not validate the requested version.'
Assert-True (-not ($validatorSource -match "-ne\s+'\d+\.\d+\.\d+\.\d+'")) 'Validate-Package.ps1 still hard-codes a file version.'
Assert-True (-not ($readme -match 'CC-Status-Setup-\d+\.\d+\.\d+\.exe')) 'README still hard-codes an installer version.'
Assert-True ($changelog -match ('(?m)^## \[' + [regex]::Escape($version) + '\]')) "CHANGELOG.md has no section for $version."

$parseErrors = @()
foreach ($scriptPath in @(Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter '*.ps1' -File | Where-Object {
    $_.FullName -notmatch '[\\/]tools[\\/]' -and $_.FullName -notmatch '[\\/]tests[\\/]\.test-'
})) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($error in @($errors)) {
        $parseErrors += "$($scriptPath.FullName): $($error.Message)"
    }
}
Assert-True ($parseErrors.Count -eq 0) ("PowerShell parse errors:`n" + ($parseErrors -join "`n"))

$trackedRuntimeData = @(git -C $projectRoot ls-files 'app/data/*')
Assert-True ($trackedRuntimeData.Count -eq 0) ("Runtime data is tracked:`n" + ($trackedRuntimeData -join "`n"))

Write-Host "Version and repository hygiene tests passed for $version." -ForegroundColor Green
