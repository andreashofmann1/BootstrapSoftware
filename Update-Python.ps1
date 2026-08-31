<#
.SYNOPSIS
    Installs/updates a full, portable CPython in Apps\Python<MajorMinor> for
    development work. Non-admin: downloads a relocatable build from the
    python-build-standalone project and extracts it in place, then puts it at
    the FRONT of the User PATH.

    This is deliberately separate from Apps\Python, which Update-AzureCLI.ps1
    bootstraps and owns. That one is the official *embeddable* distribution:
    a runtime meant to be shipped inside an application, with the standard
    library zipped up and no `venv`, `ensurepip`, `tkinter`, `include\` or
    `libs\`. It is fine for hosting azure-cli, but it cannot create virtual
    environments and cannot build any package lacking a prebuilt wheel, so it
    is not usable for development. Rather than disturb a working Azure CLI,
    this script installs a complete CPython alongside it.

    python.org publishes no full portable zip for Windows - only the
    embeddable one and an .exe installer - so the build comes from
    astral-sh/python-build-standalone instead. Those are ordinary,
    fully-featured CPython builds, relocatable and xcopy-deployable, which is
    what lets this stay non-admin and reproducible on a new machine.

    Files are only added/overwritten, never deleted, so anything pip-installed
    into this runtime survives an update.

.PARAMETER MajorMinor
    Python line to track, e.g. '3.12' (default) or '3.13'. Determines both the
    build downloaded and the default install folder.

.PARAMETER InstallDir
    Folder Python lives in. Defaults to <UserProfile>\Apps\Python<MajorMinor>
    with the dot removed, e.g. Apps\Python312.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version.

.EXAMPLE
    .\Update-Python.ps1

.EXAMPLE
    .\Update-Python.ps1 -MajorMinor 3.13
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+$')]
    [string]$MajorMinor = '3.12',
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') ('Python' + ($MajorMinor -replace '\.', ''))),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "Python $MajorMinor ($InstallDir)"

$exePath = Join-Path $InstallDir 'python.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try {
        $verLine = & $exePath --version 2>$null      # "Python 3.12.14"
        if ($verLine -match '(\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
    } catch { }
}

# python-build-standalone tags releases by build date, and each release carries
# builds for every supported Python line, so pick the newest patch matching the
# line we track rather than trusting asset order.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$release = Get-LatestGitHubRelease -Repo 'astral-sh/python-build-standalone'

# 'install_only' is the plain redistributable build. Don't match
# 'install_only_stripped' - it drops debug symbols some tooling expects.
$assetPattern = '^cpython-(' + [regex]::Escape($MajorMinor) + '\.\d+)\+\d+-' + $arch + '-pc-windows-msvc-install_only\.tar\.gz$'
$candidate = $release.assets |
    ForEach-Object {
        $m = [regex]::Match($_.name, $assetPattern)
        if ($m.Success) {
            [pscustomobject]@{ Version = $m.Groups[1].Value; Url = $_.browser_download_url }
        }
    } |
    Sort-Object -Property { ConvertTo-ComparableVersion $_.Version } -Descending |
    Select-Object -First 1

if (-not $candidate) {
    throw "No $MajorMinor.x $arch Windows build in python-build-standalone release $($release.tag_name)."
}
$latestVersion = $candidate.Version
Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest ($MajorMinor): $latestVersion"

# Compared on the CPython version alone: a rebuild of the same version under a
# newer python-build-standalone date tag is not worth re-downloading for.
if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    $extracted = Expand-TarGzToDir -Uri $candidate.Url
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # tarball wraps everything in python\
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "Python updated to $latestVersion"
}

# These builds ship pip already; this is a cheap repair path if it goes missing.
if (-not (Test-Path (Join-Path $InstallDir 'Scripts\pip.exe'))) {
    Write-Info "pip not found, bootstrapping with ensurepip..."
    & $exePath -m ensurepip --upgrade | Out-Null
}

# Front of PATH, not the end: Apps\Python (the embeddable runtime owned by
# Update-AzureCLI.ps1) is already on PATH and would otherwise keep answering
# to `python`. Azure CLI is unaffected - its az.cmd calls its own python.exe
# by full path.
Add-UserPathEntry -PathToAdd $InstallDir -Prepend
Add-UserPathEntry -PathToAdd (Join-Path $InstallDir 'Scripts') -Prepend

# Confirm the things the embeddable runtime could not do actually work here.
$checks = & $exePath -c "import venv, ensurepip, ssl, sqlite3, tkinter; print('ok')" 2>&1
if ($LASTEXITCODE -eq 0 -and $checks -match 'ok') {
    Write-Ok "venv, ensurepip, ssl, sqlite3 and tkinter all import"
} else {
    Write-Fail "Runtime check failed: $checks"
}
