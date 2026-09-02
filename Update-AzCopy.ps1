<#
.SYNOPSIS
    Updates the portable AzCopy install in Apps\AzCopy to the latest version.
    Non-admin: downloads the official zip and extracts it in place. Also
    ensures Apps\AzCopy is on the User PATH.

.PARAMETER InstallDir
    Folder AzCopy lives in. Defaults to <UserProfile>\Apps\AzCopy.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'AzCopy'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "AzCopy ($InstallDir)"

$exePath = Join-Path $InstallDir 'azcopy.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try {
        $verLine = & $exePath --version 2>$null | Select-Object -First 1
        if ($verLine -match '(\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
    } catch { }
}

$release = Get-LatestGitHubRelease -Repo 'Azure/azure-storage-azcopy'
$asset = $release.assets | Where-Object { $_.name -match '^azcopy_windows_amd64_[\d.]+\.zip$' } | Select-Object -First 1
if (-not $asset) { throw "Could not find a windows_amd64 zip asset in the latest AzCopy release ($($release.tag_name))." }
$latestVersion = $release.tag_name.TrimStart('v')

Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $extracted = Expand-ZipToDir -Uri $asset.browser_download_url
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # zip wraps in azcopy_windows_amd64_x.y.z\
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "AzCopy updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

Add-UserPathEntry -PathToAdd $InstallDir
