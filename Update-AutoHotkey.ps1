<#
.SYNOPSIS
    Updates the portable AutoHotkey v2 install in Apps\AutoHotkey to the
    latest v2 release. Non-admin: downloads the official AutoHotkey_x.y.z.zip
    from GitHub (the same payload the setup .exe unpacks) and extracts it in
    place - no installer, no elevation. Also ensures Apps\AutoHotkey is on the
    User PATH.

    The zip ships AutoHotkey64.exe / AutoHotkey32.exe but no plain
    AutoHotkey.exe (the setup .exe builds that launcher itself), so this
    script keeps a copy of the interpreter matching your OS bitness as
    AutoHotkey.exe. That makes `AutoHotkey myscript.ahk` work from any
    shell once the folder is on PATH.

    This does NOT touch the registry, so .ahk files are not associated with
    AutoHotkey and double-clicking a script won't run it. Run scripts as
    `AutoHotkey myscript.ahk`, or run UX\install.ahk from the install folder
    if you later want the full per-user setup.

.PARAMETER InstallDir
    Folder AutoHotkey lives in. Defaults to <UserProfile>\Apps\AutoHotkey.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version. Also
    force-closes any script still running out of this folder.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'AutoHotkey'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "AutoHotkey v2 ($InstallDir)"

# The interpreter that matches this machine; the other one ships too and is
# left in place, it just isn't the one we copy to AutoHotkey.exe.
$interpreterName = if ([Environment]::Is64BitOperatingSystem) { 'AutoHotkey64.exe' } else { 'AutoHotkey32.exe' }
$interpreterPath = Join-Path $InstallDir $interpreterName
$launcherPath    = Join-Path $InstallDir 'AutoHotkey.exe'

$installedVersion = ''
if (Test-Path $interpreterPath) {
    try { $installedVersion = (Get-Item $interpreterPath).VersionInfo.ProductVersion } catch { }
}

$release = Get-LatestGitHubRelease -Repo 'AutoHotkey/AutoHotkey'
$latestVersion = $release.tag_name.TrimStart('v')
# This repo is v2's home, but guard anyway: a v1 tag showing up as "latest"
# would silently downgrade the install.
if ($latestVersion -notlike '2.*') {
    throw "Latest AutoHotkey release is $($release.tag_name), which is not a v2 release. Refusing to install it."
}

Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    # Matches AutoHotkey_2.0.26.zip, and not AutoHotkey_2.0.26_setup.exe.
    $assetUrl = Get-GitHubReleaseAssetUrl -Release $release -NamePattern 'AutoHotkey_*.zip'
    $extracted = Expand-ZipToDir -Uri $assetUrl
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # this zip is already flat

    # Overwrite/add only: anything you dropped in the folder yourself (your own
    # .ahk scripts, a compiled Ahk2Exe under Compiler\) survives the update.
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "AutoHotkey updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

# Keep AutoHotkey.exe in sync with the real interpreter (also covers the case
# where the copy is missing because a previous run predates this step).
if (-not (Test-Path $interpreterPath)) {
    throw "$interpreterName is missing from $InstallDir - the extract didn't produce a usable install."
}
$launcherVersion = ''
if (Test-Path $launcherPath) {
    try { $launcherVersion = (Get-Item $launcherPath).VersionInfo.ProductVersion } catch { }
}
$interpreterVersion = (Get-Item $interpreterPath).VersionInfo.ProductVersion
if ($launcherVersion -ne $interpreterVersion) {
    Copy-Item -LiteralPath $interpreterPath -Destination $launcherPath -Force
    Write-Ok "AutoHotkey.exe refreshed from $interpreterName ($interpreterVersion)"
}

Add-UserPathEntry -PathToAdd $InstallDir
