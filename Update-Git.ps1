<#
.SYNOPSIS
    Updates the portable MinGit install in Apps\Git to the latest release.
    Non-admin: downloads the official MinGit zip from the git-for-windows
    GitHub releases and extracts it in place. Also ensures Apps\Git\cmd is
    on the User PATH so that VS Code (and everything else) can find git.exe.

    MinGit is a minimal distribution of Git for Windows designed for
    embedding / tooling use. It contains the full git command-line but
    omits Bash, Perl, and GUI helpers.

.PARAMETER InstallDir
    Folder Git lives in. Defaults to <UserProfile>\Apps\Git.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'Git'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "Git ($InstallDir)"

$exePath = Join-Path $InstallDir 'cmd\git.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try {
        $verLine = & $exePath --version 2>$null
        if ($verLine -match '(\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
    } catch { }
}

$release = Get-LatestGitHubRelease -Repo 'git-for-windows/git'
$latestTag = $release.tag_name   # e.g. "v2.55.0.windows.5"
if ($latestTag -match '(\d+\.\d+\.\d+)') { $latestVersion = $Matches[1] } else { $latestVersion = $latestTag }
Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $zipUrl = Get-GitHubReleaseAssetUrl -Release $release -NamePattern 'MinGit-*-64-bit.zip'
    $extracted = Expand-ZipToDir -Uri $zipUrl
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "Git updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

Add-UserPathEntry -PathToAdd (Join-Path $InstallDir 'cmd')
