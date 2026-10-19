#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the locally linked dsh-open-in-app bundle from a profile.

.DESCRIPTION
    Reverses install.ps1: drops the `dsh-open-in-app` entry from
    `dsh.profile.bundles`, removes the three `link:` dependencies and the
    junctions. The profile's own cordis.patch.yml is not touched, because the
    bundle carries its own patch layer.

.PARAMETER ProfileName
    Profile directory name under $DshHome\profiles. Default: desktop

.PARAMETER DshHome
    DeepSeek Harness user directory. Default: $env:USERPROFILE\.dsh

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$ProfileName = 'desktop',
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh')
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$profileDir = Join-Path (Join-Path $DshHome 'profiles') $ProfileName
if (-not (Test-Path -LiteralPath $profileDir)) {
    throw "profile not found: $profileDir"
}

$names = @('dsh-open-in-app-lite', 'dsh-open-in-app-lite-host', 'dsh-open-in-app-lite-client')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Write-Host "==> profile: $profileDir"

function Remove-Link {
    param([string]$Path)
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
foreach ($name in $names) {
    $link = Join-Path $modules $name
    if (Test-Path -LiteralPath $link) {
        Remove-Link -Path $link
        Write-Host "    unlink $name"
    }
}

# ------------------------------------------------- package.json: deps + bundles
$packagePath = Join-Path $profileDir 'package.json'
if (Test-Path -LiteralPath $packagePath) {
    Copy-Item -LiteralPath $packagePath -Destination "$packagePath.bak-$stamp"
    $json = [System.IO.File]::ReadAllText($packagePath) | ConvertFrom-Json

    if ($null -ne $json.dependencies) {
        $kept = [ordered]@{}
        foreach ($property in $json.dependencies.PSObject.Properties) {
            if ($names -notcontains $property.Name) {
                $kept[$property.Name] = $property.Value
            }
        }
        $json.dependencies = [pscustomobject]$kept
    }

    $changedBundles = $false
    if ($null -ne $json.dsh -and $null -ne $json.dsh.profile -and $null -ne $json.dsh.profile.bundles) {
        $keptBundles = @($json.dsh.profile.bundles | Where-Object { $_ -ne 'dsh-open-in-app-lite' })
        if ($keptBundles.Count -ne @($json.dsh.profile.bundles).Count) {
            $json.dsh.profile.bundles = $keptBundles
            $changedBundles = $true
        }
    }

    if ($null -ne $json.dependencies -or $changedBundles) {
        [System.IO.File]::WriteAllText($packagePath, ($json | ConvertTo-Json -Depth 20), $utf8)
        Write-Host "    profile package.json updated (backup: .bak-$stamp)"
    }
}

Write-Host ''
Write-Host '==> done — restart DeepSeek Harness to restore the upstream Open In menu.'
Write-Host ''
