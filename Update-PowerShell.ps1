<#
.SYNOPSIS
    Updates the portable PowerShell 7 (pwsh) install in Apps\PowerShell to
    the latest release. Non-admin: downloads the official win-x64 zip from
    GitHub and extracts it in place. Also ensures Apps\PowerShell is on the
    User PATH.

    Self-update safe: if this script is itself running from the pwsh.exe
    being updated (i.e. you launched it with `pwsh`), Windows won't allow
    overwriting the running binaries directly. In that case the new files
    are staged and a small detached helper (using the separate, always-
    available Windows PowerShell 5.1 executable) finishes the swap the
    moment this window/session closes - no extra steps needed from you.

.PARAMETER InstallDir
    Folder pwsh lives in. Defaults to <UserProfile>\Apps\PowerShell.

.PARAMETER Force
    Re-download and re-extract even if already on the latest version. Also
    force-closes any *other* pwsh processes running from this folder.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'PowerShell'),
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

Write-Step "PowerShell 7 ($InstallDir)"

$exePath = Join-Path $InstallDir 'pwsh.exe'
$installedVersion = ''
if (Test-Path $exePath) {
    try {
        $verLine = & $exePath --version 2>$null
        if ($verLine -match '(\d+\.\d+\.\d+)') { $installedVersion = $Matches[1] }
    } catch { }
}

$release = Get-LatestGitHubRelease -Repo 'PowerShell/PowerShell'
$asset = $release.assets | Where-Object { $_.name -match '^PowerShell-[\d.]+-win-x64\.zip$' } | Select-Object -First 1
if (-not $asset) { throw "Could not find a win-x64 zip asset in the latest PowerShell release ($($release.tag_name))." }
$latestVersion = $release.tag_name.TrimStart('v')

Write-Info "Installed: $(if ($installedVersion) { $installedVersion } else { '(not installed)' })   Latest: $latestVersion"

if (-not $Force -and -not (Test-UpdateNeeded -InstalledVersionText $installedVersion -LatestVersionText $latestVersion)) {
    Write-Skip "Already up to date."
    Add-UserPathEntry -PathToAdd $InstallDir
    return
}

$extracted = Expand-ZipToDir -Uri $asset.browser_download_url
$contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # this zip is already flat

$selfLocked = Test-CurrentProcessInsideDir -Dir $InstallDir

if ($selfLocked) {
    Write-Info "This script is running from the pwsh.exe being updated - files are locked while it's running."
    Write-Info "Staging the update and scheduling it to finish automatically once this session exits..."

    $sys32Pwsh = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $sys32Pwsh)) {
        Write-Fail "Could not find the built-in Windows PowerShell ($sys32Pwsh) to run the deferred update helper. Update aborted - please run this script from Windows PowerShell instead of pwsh."
    } else {
        $stagingRoot = Split-Path $extracted -Parent   # the appupdate-xxxxxxxx folder
        $helperScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
Wait-Process -Id $PID -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
for (`$i = 0; `$i -lt 20; `$i++) {
    `$stillRunning = Get-Process | Where-Object { `$_.Path -and `$_.Path.StartsWith('$InstallDir\', [System.StringComparison]::OrdinalIgnoreCase) }
    if (-not `$stillRunning) { break }
    Start-Sleep -Seconds 1
}
robocopy '$contentRoot' '$InstallDir' /E /IS /IT /R:3 /W:2 /NFL /NDL /NJH /NJS | Out-Null
Remove-Item -LiteralPath '$stagingRoot' -Recurse -Force -ErrorAction SilentlyContinue
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($helperScript))
        Start-Process -FilePath $sys32Pwsh -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
        Write-Ok "Update to $latestVersion staged. Close this pwsh window/tab (and any other pwsh sessions) to let it finish - no other action needed."
    }
} else {
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        Remove-TempStagingDir -Dir $extracted
        return
    }
    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "PowerShell updated to $latestVersion"
}

Add-UserPathEntry -PathToAdd $InstallDir
