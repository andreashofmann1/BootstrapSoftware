<#
.SYNOPSIS
    Updates the portable Azure CLI install in Apps\AzureCLI to the latest
    version. Non-admin: there is no official Azure CLI zip for Windows, so
    this mirrors how it was set up originally - a portable embeddable
    Python in Apps\Python, with the azure-cli package installed via
    `pip install --target` directly into Apps\AzureCLI, driven by a
    generated az_launcher.py that repairs sys.path, plus an az.cmd shim.

    If Apps\Python is missing or incomplete (no pip), it is bootstrapped
    automatically from the official embeddable Python distribution.

.PARAMETER InstallDir
    Folder the azure-cli package payload lives in (where az.cmd is).
    Defaults to <UserProfile>\Apps\AzureCLI.

.PARAMETER PythonDir
    Folder the portable Python runtime lives in. Defaults to
    <UserProfile>\Apps\Python.

.PARAMETER PythonMajorMinor
    Python line to bootstrap if Apps\Python doesn't exist yet. Defaults to
    '3.12' (a broadly-compatible, well-supported line for azure-cli). Only
    used the first time Python is bootstrapped; existing installs are left
    alone unless -Force is also used.

.PARAMETER Force
    Re-run pip install --upgrade even if azure-cli looks current, and
    re-bootstrap Python even if it already exists.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'AzureCLI'),
    [string]$PythonDir  = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'Python'),
    [string]$PythonMajorMinor = '3.12',
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "Azure CLI ($InstallDir)"

# --------------------------------------------------------------------------
# 1. Ensure the portable Python runtime exists and has working pip.
# --------------------------------------------------------------------------
$pythonExe = Join-Path $PythonDir 'python.exe'
$needPythonBootstrap = $Force -or -not (Test-Path $pythonExe)

if ($needPythonBootstrap) {
    Write-Info "Bootstrapping portable Python ($PythonMajorMinor.x) into $PythonDir ..."

    $listing = Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/' -UseBasicParsing
    $pattern = 'href="(' + [regex]::Escape($PythonMajorMinor) + '\.\d+)/"'
    $candidates = [regex]::Matches($listing.Content, $pattern) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Property { [version]$_ } -Descending
    if (-not $candidates) { throw "Could not find any $PythonMajorMinor.x release on python.org." }

    # Once a line moves to security-fix-only support, python.org stops building
    # Windows installers (embeddable zip included) for new point releases - only
    # the source tarball ships. Walk down from the newest folder until we find
    # one that actually has the embeddable zip.
    $pyVersion = $null
    $embedUrl = $null
    foreach ($candidate in $candidates) {
        $candidateUrl = "https://www.python.org/ftp/python/$candidate/python-$candidate-embed-amd64.zip"
        try {
            Invoke-WebRequest -Uri $candidateUrl -Method Head -UseBasicParsing | Out-Null
            $pyVersion = $candidate
            $embedUrl = $candidateUrl
            break
        } catch {
            Write-Info "No Windows embeddable zip for $candidate (likely security-fix-only release), trying older..."
        }
    }
    if (-not $pyVersion) { throw "Could not find a $PythonMajorMinor.x release on python.org with a Windows embeddable zip." }
    $extracted = Expand-ZipToDir -Uri $embedUrl
    Copy-AppFiles -SourceDir $extracted -DestDir $PythonDir   # this zip is already flat
    Remove-TempStagingDir -Dir $extracted

    # Embeddable Python ships with `import site` commented out in its ._pth file,
    # which disables site-packages (and therefore pip). Uncomment it.
    $pthFile = Get-ChildItem -Path $PythonDir -Filter '*._pth' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pthFile) {
        $content = Get-Content -LiteralPath $pthFile.FullName
        $updated = $content -replace '^\s*#\s*import site\s*$', 'import site'
        Set-Content -LiteralPath $pthFile.FullName -Value $updated
    } else {
        Write-Info "No ._pth file found - pip may already be enabled by default in this build."
    }

    Write-Ok "Python $pyVersion installed."
}

$pipWorks = $false
try {
    & $pythonExe -m pip --version *>$null
    $pipWorks = ($LASTEXITCODE -eq 0)
} catch { $pipWorks = $false }

if (-not $pipWorks) {
    Write-Info "Installing pip into the portable Python..."
    $staging = New-TempStagingDir -Prefix 'getpip'
    $getPip = Join-Path $staging 'get-pip.py'
    Invoke-FileDownload -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip
    & $pythonExe $getPip --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { throw "get-pip.py failed with exit code $LASTEXITCODE" }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "pip installed."
}

Add-UserPathEntry -PathToAdd $PythonDir

# --------------------------------------------------------------------------
# 2. Install/upgrade azure-cli's package payload into $InstallDir.
# --------------------------------------------------------------------------
$installedVersion = Get-DistInfoVersion -Dir $InstallDir -PackageName 'azure-cli'

$pypiInfo = Invoke-RestMethod -Uri 'https://pypi.org/pypi/azure-cli/json'
$latestVersion = $pypiInfo.info.version
Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "azure-cli already up to date."
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Write-Info "Running: pip install --upgrade --target `"$InstallDir`" azure-cli (this can take a few minutes)"
    & $pythonExe -m pip install --upgrade --no-warn-script-location --target $InstallDir azure-cli
    if ($LASTEXITCODE -ne 0) { throw "pip install azure-cli failed with exit code $LASTEXITCODE" }
    Write-Ok "azure-cli updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

# pip leaves the superseded version's *.dist-info behind on every --target
# upgrade. Left alone, that stale metadata makes the version check above read
# the OLD version next run, so the script would reinstall on every single run.
$staleRemoved = Remove-StaleDistInfo -Dir $InstallDir
if ($staleRemoved -gt 0) {
    Write-Ok "Removed $staleRemoved stale .dist-info folder(s) left behind by pip."
}

# --------------------------------------------------------------------------
# 3. Write the launcher and the az.cmd shim.
#
# `pip install --target` puts the payload in $InstallDir, but nothing puts
# $InstallDir on sys.path: python only adds the *script's* own directory
# (...\azure\cli), and the embeddable runtime's ._pth file forces isolated
# mode, so PYTHONPATH is ignored too. pywin32 additionally needs its win32
# folders on sys.path and its DLLs on the DLL search path, because the
# post-install step that normally arranges that never runs under --target.
# The launcher fixes both before handing off to azure.cli.
# --------------------------------------------------------------------------
$launcherPath = Join-Path $InstallDir 'az_launcher.py'
$launcherContent = @'
# Generated by Update-AzureCLI.ps1 - do not edit by hand.
import os
import sys

_root = os.path.dirname(os.path.abspath(__file__))

for _p in (os.path.join(_root, 'pythonwin'),
           os.path.join(_root, 'win32', 'lib'),
           os.path.join(_root, 'win32'),
           _root):
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

_dlls = os.path.join(_root, 'pywin32_system32')
if os.path.isdir(_dlls):
    os.environ['PATH'] = _dlls + os.pathsep + os.environ.get('PATH', '')
    try:
        os.add_dll_directory(_dlls)
    except (AttributeError, OSError):
        pass

import runpy

runpy.run_module('azure.cli', run_name='__main__', alter_sys=True)
'@
if (-not (Test-Path $launcherPath) -or (Get-Content -Raw -LiteralPath $launcherPath) -ne $launcherContent) {
    Set-Content -LiteralPath $launcherPath -Value $launcherContent -Encoding UTF8 -NoNewline
    Write-Ok "az_launcher.py written."
}

# Point the shim at this Python explicitly rather than at whatever `python`
# happens to resolve to first on PATH.
$azCmdPath = Join-Path $InstallDir 'az.cmd'
$azCmdContent = "@echo off`r`n`"$pythonExe`" `"%~dp0az_launcher.py`" %*`r`n"
if (-not (Test-Path $azCmdPath) -or (Get-Content -Raw -LiteralPath $azCmdPath) -ne $azCmdContent) {
    Set-Content -LiteralPath $azCmdPath -Value $azCmdContent -NoNewline
    Write-Ok "az.cmd shim written."
}

Add-UserPathEntry -PathToAdd $InstallDir
