#Requires -Version 5.1
<#
.SYNOPSIS
    Remove dsh-open-in-app from a DeepSeek Harness profile.

.DESCRIPTION
    Reverses install.ps1: removes the two junctions, drops the `link:`
    dependency entries, and deletes the patch block that disabled the upstream
    Open In pair. Restart DeepSeek Harness afterwards.

.PARAMETER ProfileName
    Profile directory name under $DshHome\profiles. Default: desktop

.PARAMETER DshHome
    DeepSeek Harness user directory. Default: $env:USERPROFILE\.dsh

.EXAMPLE
    pwsh -File .\uninstall.ps1
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

$names = @('dsh-local-open-in-app', 'dsh-local-ui-open-in-app')
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
foreach ($name in $names) {
    $link = Join-Path $modules $name
    if (Test-Path -LiteralPath $link) {
        Remove-Link -Path $link
        Write-Host "    unlink $name"
    }
}

# ---------------------------------------------------------------- package.json
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
        [System.IO.File]::WriteAllText($packagePath, ($json | ConvertTo-Json -Depth 20), $utf8)
        Write-Host "    deps  cleaned (backup: .bak-$stamp)"
    }
}

# ---------------------------------------------------------------- cordis.patch
$patchPath = Join-Path $profileDir 'cordis.patch.yml'
if (Test-Path -LiteralPath $patchPath) {
    $lines = @(
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
    )
    $block = $lines -join "`n"
    $text = ([System.IO.File]::ReadAllText($patchPath)) -replace "`r`n", "`n"

    if ($text.Contains($block)) {
        Copy-Item -LiteralPath $patchPath -Destination "$patchPath.bak-$stamp"
        $cleaned = $text.Replace($block, '')
        $cleaned = $cleaned -replace "(?s)\n{3,}", "`n`n"
        $cleaned = $cleaned.TrimEnd()

        # A template patch is an empty flow sequence; keep it valid YAML when
        # our block was the only content.
        $meaningful = (($cleaned -split "`n") | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join ''
        if ($meaningful -eq '') {
            $cleaned = $cleaned + "`n[]"
        }
        [System.IO.File]::WriteAllText($patchPath, $cleaned + "`n", $utf8)
        Write-Host "    patch block removed (backup: .bak-$stamp)"
    }
    elseif ($text -match '(?m)^\s*-?\s*id:\s*local-open-in-app\s*$') {
        Write-Warning "found a local-open-in-app entry in $patchPath that does not match the standard block; remove it by hand."
    }
    else {
        Write-Host '    no patch block found, nothing to remove'
    }
}

Write-Host ''
Write-Host '==> done — restart DeepSeek Harness to restore the upstream Open In menu.'
Write-Host ''
