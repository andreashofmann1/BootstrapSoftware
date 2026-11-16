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

    A running VS Code tunnel (bin\code-tunnel.exe) doesn't block the update:
    it is stopped just for the copy and then started again through the
    VSCode-Tunnel-Watchdog task (see Tunnel-Watchdog.ps1).

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
    # code-tunnel is handled below; anything else running from here (desktop VS Code) still needs -Force.
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force -Ignore 'code-tunnel')) {
        return
    }
    # Download before touching the tunnel, so it is only down for the copy itself.
    $extracted = Expand-ZipToDir -Uri $updateInfo.url
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # this zip is already flat

    # Keep Tunnel-Watchdog.ps1 from starting a tunnel mid-copy.
    $heldWatchdog = Suspend-TunnelWatchdog
    $tunnelProcs = @(Get-ProcessesUsingPath -Dir $InstallDir | Where-Object { $_.ProcessName -eq 'code-tunnel' })
    try {
        if ($tunnelProcs.Count -gt 0) {
            Write-Info "Stopping code-tunnel for the update; it is started again afterwards."
            $tunnelProcs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
        Copy-AppFilesMirror -SourceDir $contentRoot -DestDir $InstallDir
    } finally {
        Resume-TunnelWatchdog -Taken $heldWatchdog -RestartTunnel:($tunnelProcs.Count -gt 0)
    }
    Remove-TempStagingDir -Dir $extracted
    Write-Ok "VS Code updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
}

Add-UserPathEntry -PathToAdd $InstallDir
