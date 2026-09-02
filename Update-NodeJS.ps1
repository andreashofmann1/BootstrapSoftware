<#
.SYNOPSIS
    Updates the portable Node.js install in Apps\NodeJS to the latest
    release. Non-admin: downloads the official zip from nodejs.org and
    extracts it in place. Also ensures Apps\NodeJS is on the User PATH.

    Files are only added/overwritten, never deleted, so any packages you
    `npm install -g` (which land inside this folder for a portable Node
    install) are preserved across updates.

.PARAMETER InstallDir
    Folder Node.js lives in. Defaults to <UserProfile>\Apps\NodeJS.

.PARAMETER Channel
    'Current' (default - matches how this install was originally set up)
    or 'LTS' to track the Long-Term-Support release line instead.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'NodeJS'),
    [ValidateSet('Current', 'LTS')]
    [string]$Channel = 'Current',
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "Node.js ($InstallDir)"

$exePath = Join-Path $InstallDir 'node.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try {
        $verLine = & $exePath --version 2>$null
        if ($verLine -match '(\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
    } catch { }
}

$index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json'
$candidate = if ($Channel -eq 'LTS') {
    $index | Where-Object { $_.lts } | Select-Object -First 1
} else {
    $index | Select-Object -First 1
}
$latestVersion = $candidate.version.TrimStart('v')
Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest ($Channel): $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $zipUrl = "https://nodejs.org/dist/$($candidate.version)/node-$($candidate.version)-win-x64.zip"
    $extracted = Expand-ZipToDir -Uri $zipUrl
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # zip wraps in node-vX.Y.Z-win-x64\
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "Node.js updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

Add-UserPathEntry -PathToAdd $InstallDir
