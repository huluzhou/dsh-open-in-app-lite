#Requires -Version 5.1
<#
.SYNOPSIS
    Install dsh-open-in-app into a DeepSeek Harness profile.

.DESCRIPTION
    Junction-links the two plugin packages into the profile's node_modules,
    declares them as `link:` dependencies, and patches cordis.patch.yml to
    disable the upstream Open In pair and insert these instead.

    Safe to re-run: existing links are replaced and the patch block is only
    appended once. Both edited files are backed up as *.bak-<timestamp>.

.PARAMETER ProfileName
    Profile directory name under $DshHome\profiles. Default: desktop

.PARAMETER DshHome
    DeepSeek Harness user directory. Default: $env:USERPROFILE\.dsh

.EXAMPLE
    pwsh -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$ProfileName = 'desktop',
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh')
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$root = $PSScriptRoot

$profileDir = Join-Path (Join-Path $DshHome 'profiles') $ProfileName
if (-not (Test-Path -LiteralPath $profileDir)) {
    throw "profile not found: $profileDir"
}

$packages = @(
    @{ Name = 'dsh-local-open-in-app';    Path = (Join-Path $root 'host') },
    @{ Name = 'dsh-local-ui-open-in-app'; Path = (Join-Path $root 'client') }
)
foreach ($package in $packages) {
    if (-not (Test-Path -LiteralPath (Join-Path $package.Path 'package.json'))) {
        throw "missing package.json in $($package.Path)"
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Write-Host "==> profile: $profileDir"

function Remove-Link {
    param([string]$Path)
    # A junction must be removed as a link: Remove-Item -Recurse would walk into
    # the target. Run from a local directory so cmd does not warn about a UNC cwd.
    Push-Location -LiteralPath $env:SystemRoot
    try {
        cmd /c rmdir "`"$Path`"" | Out-Null
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------- node_modules
$modules = Join-Path $profileDir 'node_modules'
if (-not (Test-Path -LiteralPath $modules)) {
    New-Item -ItemType Directory -Path $modules | Out-Null
}
foreach ($package in $packages) {
    $link = Join-Path $modules $package.Name
    if (Test-Path -LiteralPath $link) {
        Remove-Link -Path $link
    }
    New-Item -ItemType Junction -Path $link -Target $package.Path | Out-Null
    Write-Host "    link  $($package.Name) -> $($package.Path)"
}

# ---------------------------------------------------------------- package.json
$packagePath = Join-Path $profileDir 'package.json'
if (-not (Test-Path -LiteralPath $packagePath)) {
    throw "missing $packagePath"
}
Copy-Item -LiteralPath $packagePath -Destination "$packagePath.bak-$stamp"

$json = [System.IO.File]::ReadAllText($packagePath) | ConvertFrom-Json
$dependencies = [ordered]@{}
if ($null -ne $json.dependencies) {
    foreach ($property in $json.dependencies.PSObject.Properties) {
        $dependencies[$property.Name] = $property.Value
    }
}
foreach ($package in $packages) {
    $dependencies[$package.Name] = 'link:' + ($package.Path -replace '\\', '/')
}
if ($null -eq $json.PSObject.Properties['dependencies']) {
    $json | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]$dependencies) -Force
}
else {
    $json.dependencies = [pscustomobject]$dependencies
}
[System.IO.File]::WriteAllText($packagePath, ($json | ConvertTo-Json -Depth 20), $utf8)
Write-Host "    deps  $($packagePath) (backup: .bak-$stamp)"

# ---------------------------------------------------------------- cordis.patch
$patchPath = Join-Path $profileDir 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $patchPath)) {
    throw "missing $patchPath"
}
Copy-Item -LiteralPath $patchPath -Destination "$patchPath.bak-$stamp"

$patch = [System.IO.File]::ReadAllText($patchPath)
$block = (@(
        '# ---- dsh-open-in-app: Open In limited to Explorer / VS Code / Git Bash / VSCodium ----'
        '- id: open-in-app'
        '  disabled: true'
        '- id: ui-open-in-app'
        '  disabled: true'
        '- insert:'
        '    - id: local-open-in-app'
        "      name: 'dsh-local-open-in-app'"
        '    - id: local-ui-open-in-app'
        "      name: 'dsh-local-ui-open-in-app'"
    ) -join "`n")

# Content with comments and blank lines removed: a shipped template may be an
# empty flow sequence (`[]`), which cannot be followed by block entries.
$meaningful = (($patch -split "`n") | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join ''

if ($patch -match '(?m)^\s*-?\s*id:\s*local-open-in-app\s*$') {
    Write-Host '    patch already present, left untouched'
}
elseif ($meaningful -eq '[]') {
    $replaced = [regex]::Replace($patch, '(?m)^[ \t]*\[\][ \t]*$', { param($match) $block })
    [System.IO.File]::WriteAllText($patchPath, $replaced, $utf8)
    Write-Host "    patch $patchPath (replaced empty list; backup: .bak-$stamp)"
}
else {
    [System.IO.File]::AppendAllText($patchPath, "`n" + $block + "`n", $utf8)
    Write-Host "    patch $patchPath (backup: .bak-$stamp)"
}

Write-Host ''
Write-Host '==> done'
Write-Host ''
Write-Host '    Fully quit DeepSeek Harness (including the tray icon) and relaunch it.'
Write-Host '    Then the Open In menu lists Explorer, VS Code, Git Bash and VSCodium only.'
Write-Host ''
