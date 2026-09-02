<#
.SYNOPSIS
    Updates the portable GitHub CLI (gh) install in Apps\GitHubCLI to the
    latest release. Non-admin: downloads the official zip from GitHub and
    extracts it in place. Also ensures Apps\GitHubCLI\bin is on the User PATH.

.PARAMETER InstallDir
    Folder GitHub CLI lives in. Defaults to <UserProfile>\Apps\GitHubCLI.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'GitHubCLI'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "GitHub CLI ($InstallDir)"

$exePath = Join-Path $InstallDir 'bin\gh.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try {
        $verLine = & $exePath --version 2>$null | Select-Object -First 1
        if ($verLine -match '(\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
    } catch { }
}

$release = Get-LatestGitHubRelease -Repo 'cli/cli'
$latestVersion = $release.tag_name.TrimStart('v')
Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $assetUrl = Get-GitHubReleaseAssetUrl -Release $release -NamePattern "gh_*_windows_amd64.zip"
    $extracted = Expand-ZipToDir -Uri $assetUrl
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # this zip is already flat (LICENSE, bin\)
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "GitHub CLI updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

Add-UserPathEntry -PathToAdd (Join-Path $InstallDir 'bin')
