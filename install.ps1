#Requires -Version 5.1
<#
.SYNOPSIS
    Local (link) install of the dsh-open-in-app bundle into a profile.

.DESCRIPTION
    The standard installation path is the plugin manager: once the packages are
    published, install `dsh-open-in-app` and DSH applies the bundle patch by
    itself. This script is the offline / desktop-profile fallback, which cannot
    use `dsh plugin` because the desktop profile is reserved for Electron.

    It links the bundle plus both halves into the profile's node_modules,
    declares them as `link:` dependencies, and appends the bundle to
    `dsh.profile.bundles`. The disable/insert rows live in the bundle's
    cordis.patch.yml, so the profile's own patch file is never edited.

.PARAMETER ProfileName
    Profile directory name under $DshHome\profiles. Default: desktop

.PARAMETER DshHome
    DeepSeek Harness user directory. Default: $env:USERPROFILE\.dsh

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
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

# The bundle first, then the halves it depends on: linking all three locally
# keeps the bundle's version-pinned dependencies resolvable without npm.
$packages = @(
    @{ Name = 'dsh-open-in-app-lite';        Path = (Join-Path $root 'packages\bundle') },
    @{ Name = 'dsh-open-in-app-lite-host';   Path = (Join-Path $root 'packages\host') },
    @{ Name = 'dsh-open-in-app-lite-client'; Path = (Join-Path $root 'packages\client') }
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
    Write-Host "    link  $($package.Name)"
}

# ------------------------------------------------- package.json: deps + bundles
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

$bundles = @()
if ($null -ne $json.dsh -and $null -ne $json.dsh.profile -and $null -ne $json.dsh.profile.bundles) {
    $bundles = @($json.dsh.profile.bundles)
}
if ($bundles -notcontains 'dsh-open-in-app-lite') {
    $bundles += 'dsh-open-in-app-lite'
}
if ($null -eq $json.PSObject.Properties['dsh']) {
    $json | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{ profile = [pscustomobject]@{ bundles = $bundles } })
}
else {
    if ($null -eq $json.dsh.PSObject.Properties['profile']) {
        $json.dsh | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{ bundles = $bundles })
    }
    else {
        $json.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue $bundles -Force
    }
}

[System.IO.File]::WriteAllText($packagePath, ($json | ConvertTo-Json -Depth 20), $utf8)
Write-Host "    profile package.json updated (backup: .bak-$stamp)"

Write-Host ''
Write-Host '==> done'
Write-Host ''
Write-Host '    Fully quit DeepSeek Harness (including the tray icon) and relaunch it.'
Write-Host '    The Open In menu then lists Explorer, VS Code, Git Bash and VSCodium only.'
Write-Host ''
Write-Host '    Already installed by hand before? Remove the old manual patch block from'
Write-Host '    cordis.patch.yml first, otherwise both layers insert the same rows.'
Write-Host ''
