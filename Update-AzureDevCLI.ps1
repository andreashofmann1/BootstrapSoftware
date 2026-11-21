<#
.SYNOPSIS
    Updates the portable Azure Developer CLI (azd, winget id Microsoft.Azd)
    install in Apps\AzureDevCLI to the latest stable release. Non-admin:
    downloads the official zip from GitHub and extracts it in place instead of
    running the MSI. Also ensures Apps\AzureDevCLI is on the User PATH.

    azd keeps its config, extensions and the Bicep CLI it downloads under
    %USERPROFILE%\.azd, not in the install folder, so nothing is lost on update.

.PARAMETER InstallDir
    Folder azd lives in. Defaults to <UserProfile>\Apps\AzureDevCLI.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'AzureDevCLI'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "Azure Developer CLI ($InstallDir)"

$exePath = Join-Path $InstallDir 'azd.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    # Keep azd's own update check out of the version probe: it adds a network round
    # trip and can print an "out of date" warning on stderr.
    $prevSkip = $env:AZD_SKIP_UPDATE_CHECK
    $env:AZD_SKIP_UPDATE_CHECK = 'true'
    try {
        # Prints e.g. "azd version 1.39.1 (commit 1282883...) (stable)"; there is no --version flag.
        $verText = (& $exePath version 2>$null) -join "`n"
        if ($verText -match 'azd version (\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
    } catch {
    } finally {
        $env:AZD_SKIP_UPDATE_CHECK = $prevSkip
    }
}

# Azure/azure-dev also publishes its extensions (azd-ext-*) as releases of the same repo,
# so releases/latest isn't guaranteed to be the CLI. Pick the highest stable CLI release.
# (Assigned first: Windows PowerShell 5.1 pipes a JSON array on as one object, not item by item.)
$releases = Invoke-GitHubApi -Uri 'https://api.github.com/repos/Azure/azure-dev/releases?per_page=100'
$release = $releases |
    Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^azure-dev-cli_\d+\.\d+\.\d+$' } |
    Sort-Object -Property { ConvertTo-ComparableVersion $_.tag_name } -Descending |
    Select-Object -First 1
if (-not $release) { throw "Could not find a stable azure-dev-cli_* release in Azure/azure-dev." }
$latestVersion = $release.tag_name -replace '^azure-dev-cli_', ''

Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $assetUrl = Get-GitHubReleaseAssetUrl -Release $release -NamePattern 'azd-windows-amd64.zip'
    $extracted = Expand-ZipToDir -Uri $assetUrl
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # flat: azd-windows-amd64.exe, NOTICE.txt
    # The zip names the binary after its platform; the official installer renames it to
    # azd.exe, so do the same before copying for `azd` to work from PATH.
    $platformExe = Join-Path $contentRoot 'azd-windows-amd64.exe'
    if (-not (Test-Path $platformExe)) { throw "azd-windows-amd64.exe not found in $assetUrl" }
    Move-Item -LiteralPath $platformExe -Destination (Join-Path $contentRoot 'azd.exe') -Force
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "Azure Developer CLI updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

Add-UserPathEntry -PathToAdd $InstallDir
