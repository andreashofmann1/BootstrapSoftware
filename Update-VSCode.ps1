<#
.SYNOPSIS
    Updates the portable VS Code install in Apps\VSCode to the latest
    stable release. Non-admin: downloads the official win32-x64 "archive"
    zip (Microsoft's xcopy-deployable build, no installer) and mirrors it
    into place. Also ensures Apps\VSCode is on the User PATH.

    VS Code keeps no user data (settings, extensions) inside its install
    folder, so this update does a full mirror - it also cleans up the
    leftover version-hash folders VS Code's own built-in updater leaves
    behind over time.

.PARAMETER InstallDir
    Folder VS Code lives in. Defaults to <UserProfile>\Apps\VSCode.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version. Also
    force-closes VS Code if it's currently running from this folder.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'VSCode'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "VS Code ($InstallDir)"

$exePath = Join-Path $InstallDir 'Code.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try { $installedVersion = (Get-Item $exePath).VersionInfo.ProductVersion } catch { }
}

$updateInfo = Invoke-RestMethod -Uri 'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest'
$latestVersion = $updateInfo.productVersion
Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $extracted = Expand-ZipToDir -Uri $updateInfo.url
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # this zip is already flat
    Copy-AppFilesMirror -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "VS Code updated to $latestVersion"
}

Add-UserPathEntry -PathToAdd $InstallDir
