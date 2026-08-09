<#
.SYNOPSIS
    Updates the portable Notepad++ install in Apps\Notepad++ to the latest
    release. Non-admin: downloads the official portable x64 zip from GitHub
    and extracts it in place. Also ensures Apps\Notepad++ is on the User PATH.

    Your settings/session are preserved: config.xml, session.xml,
    shortcuts.xml, contextMenu.xml, the backup\ folder and plugins\Config\
    are never overwritten by an update.

.PARAMETER InstallDir
    Folder Notepad++ lives in. Defaults to <UserProfile>\Apps\Notepad++.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'Notepad++'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "Notepad++ ($InstallDir)"

$exePath = Join-Path $InstallDir 'notepad++.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try { $installedVersion = (Get-Item $exePath).VersionInfo.ProductVersion } catch { }
}

$release = Get-LatestGitHubRelease -Repo 'notepad-plus-plus/notepad-plus-plus'
$latestVersion = $release.tag_name.TrimStart('v')
Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $assetUrl = Get-GitHubReleaseAssetUrl -Release $release -NamePattern "npp.*.portable.x64.zip"
    $extracted = Expand-ZipToDir -Uri $assetUrl
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # this zip is already flat

    $preserveFiles = @(
        'config.xml',
        'contextMenu.xml',
        'session.xml',
        'session.xml.inCaseOfCorruption.bak',
        'shortcuts.xml'
    )
    $preserveDirs = @('backup', 'Config')   # 'Config' matches plugins\Config

    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir -ExcludeFiles $preserveFiles -ExcludeDirs $preserveDirs
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "Notepad++ updated to $latestVersion (your settings/session were left untouched)"
}

Add-UserPathEntry -PathToAdd $InstallDir
