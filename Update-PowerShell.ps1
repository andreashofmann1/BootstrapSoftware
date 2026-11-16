<#
.SYNOPSIS
    Updates the portable PowerShell 7 (pwsh) install in Apps\PowerShell to
    the latest release. Non-admin: downloads the official win-x64 zip from
    GitHub. Also ensures Apps\PowerShell is on the User PATH.

    The release is unpacked next to the install (Apps\PowerShell.new) and
    swapped in with two folder renames, so pwsh never starts from a half-
    copied folder. Copying over a live install doesn't work: files a running
    pwsh has loaded can't be overwritten, which leaves it half old, half new.
    A session still running from the old files also breaks as soon as it
    loads an assembly from the new release, so the swap waits until no pwsh
    session runs from Apps\PowerShell:
      - The VS Code tunnel's pwsh (Tunnel-Watchdog.ps1) doesn't count: it is
        stopped for the swap and the tunnel restarted right after.
      - While other sessions are open (including the one running this
        script), a hidden helper on the separate, always-available Windows
        PowerShell 5.1 waits for them to close and then finishes the swap.
        It logs to %LOCALAPPDATA%\BootstrapSoftware\Update-PowerShell.log.

.PARAMETER InstallDir
    Folder pwsh lives in. Defaults to <UserProfile>\Apps\PowerShell.

.PARAMETER Force
    Re-download and re-install even if already on the latest version. Also
    force-closes other pwsh sessions running from this folder, unless this
    script itself runs from it (the helper then still waits for them).

.PARAMETER FinishStaged
    Internal: what the hidden helper runs. Waits for the pwsh sessions to
    close, then swaps Apps\PowerShell.new in.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'PowerShell'),
    [switch]$Force,
    [switch]$FinishStaged
)

. "$PSScriptRoot\Common.ps1"

$InstallDir  = $InstallDir.TrimEnd('\')
$installLeaf = Split-Path $InstallDir -Leaf
$stagedDir   = "$InstallDir.new"
$helperLock  = 'Local\BootstrapSoftware-Update-PowerShell'   # named mutex the waiting helper holds
$helperLog   = Join-Path $env:LOCALAPPDATA 'BootstrapSoftware\Update-PowerShell.log'

function Get-PwshProcesses {
    <# Processes running from $InstallDir. IsTunnel marks the VS Code tunnel's (Tunnel-Watchdog.ps1). #>
    $all = @(Get-CimInstance Win32_Process)
    foreach ($p in $all) {
        if (-not ($p.ExecutablePath -and $p.ExecutablePath.StartsWith("$InstallDir\", [StringComparison]::OrdinalIgnoreCase))) { continue }
        $parent = $all | Where-Object { $_.ProcessId -eq $p.ParentProcessId } | Select-Object -First 1
        $from = if ($p.ProcessId -eq $PID) { 'this session' } elseif ($parent) { "in $($parent.Name)" } else { 'parent exited' }
        [pscustomobject]@{
            Id       = $p.ProcessId
            Label    = "PID $($p.ProcessId) ($from)"
            IsTunnel = $p.CommandLine -match 'Tunnel-Watchdog\.ps1'
        }
    }
}

function Get-PwshSessionList {
    (@(Get-PwshProcesses | Where-Object { -not $_.IsTunnel }) | ForEach-Object { $_.Label }) -join ', '
}

function Rename-WithRetry {
    <# Rename-Item, retried for a while: antivirus scanning freshly written files can hold them briefly. #>
    param([string]$Path, [string]$NewName)
    for ($i = 1; $i -le 15; $i++) {
        try { Rename-Item -LiteralPath $Path -NewName $NewName; return $true } catch { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Install-StagedPwsh {
    <#
    One attempt at swapping $stagedDir in as $InstallDir. Returns $false, changing nothing, while pwsh
    sessions other than the VS Code tunnel's run from $InstallDir; -StopSessions closes them instead.
    #>
    param([switch]$StopSessions)
    $procs    = @(Get-PwshProcesses)
    $sessions = @($procs | Where-Object { -not $_.IsTunnel })
    $tunnel   = @($procs | Where-Object { $_.IsTunnel })
    if ($sessions.Count -gt 0) {
        if (-not $StopSessions) { return $false }
        Write-Info "Stopping pwsh session(s): $(($sessions | ForEach-Object { $_.Label }) -join ', ')"
        $sessions | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
    $heldWatchdog = $false
    if ($tunnel.Count -gt 0) {
        $heldWatchdog = Suspend-TunnelWatchdog
        Write-Info "Stopping the VS Code tunnel's pwsh for the swap; the tunnel is started again afterwards."
        Stop-ScheduledTask -TaskName 'VSCode-Tunnel' -ErrorAction SilentlyContinue
        $tunnel | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    }
    try {
        $oldDir = Join-Path (Split-Path $InstallDir) "$installLeaf.old-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        if (Test-Path $InstallDir) {
            # Keep anything the release doesn't ship (e.g. a $PSHOME profile.ps1): copy over only the
            # files the staged folder doesn't have.
            robocopy $InstallDir $stagedDir /E /XC /XN /XO /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed carrying files over from '$InstallDir' (exit code $LASTEXITCODE)" }
            Reset-LastExitCode
            if (-not (Rename-WithRetry $InstallDir (Split-Path $oldDir -Leaf))) {
                throw "Could not rename $InstallDir (a process may have it as its current directory); the update stays staged in $stagedDir."
            }
        }
        if (-not (Rename-WithRetry $stagedDir $installLeaf)) {
            if (Test-Path $oldDir) { Rename-WithRetry $oldDir $installLeaf | Out-Null }
            throw "Could not move $stagedDir into place; the previous install was put back."
        }
        # Anything a process still has loaded can't be deleted yet; the next update clears it.
        Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    } finally {
        if ($tunnel.Count -gt 0) { Resume-TunnelWatchdog -Taken $heldWatchdog -RestartTunnel }
    }
}

if ($FinishStaged) {
    # The hidden helper: wait for the pwsh sessions to close, then swap.
    $mutex = New-Object System.Threading.Mutex($false, $helperLock)
    if (-not $mutex.WaitOne(0)) { return }   # another helper is already waiting
    New-Item -ItemType Directory -Force -Path (Split-Path $helperLog) | Out-Null
    Start-Transcript -Path $helperLog | Out-Null
    try {
        $waitingFor = ''
        while (Test-Path $stagedDir) {
            if (Install-StagedPwsh) {
                Write-Ok "PowerShell updated."
                break
            }
            $now = Get-PwshSessionList
            if ($now -ne $waitingFor) { Write-Info "Waiting for these pwsh sessions to close: $now" }
            $waitingFor = $now
            Start-Sleep -Seconds 10
        }
    } catch {
        Write-Fail $_.Exception.Message
    } finally {
        Stop-Transcript | Out-Null
        $mutex.ReleaseMutex()
    }
    return
}

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

$waitingHelper = $null
if ([System.Threading.Mutex]::TryOpenExisting($helperLock, [ref]$waitingHelper)) {
    $waitingHelper.Dispose()
    Write-Skip "An update is already staged; it installs once these pwsh sessions have closed: $(Get-PwshSessionList)"
    $global:AppUpdateResult = 'staged'
    Add-UserPathEntry -PathToAdd $InstallDir
    return
}

# Leftovers from an interrupted earlier run (no helper is waiting on them).
if (Test-Path $stagedDir) { Remove-Item -LiteralPath $stagedDir -Recurse -Force }
Get-ChildItem -Path (Split-Path $InstallDir) -Directory -Filter "$installLeaf.old-*" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$extracted = Expand-ZipToDir -Uri $asset.browser_download_url
$contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # this zip is already flat
# Staged beside the install so the swap is a rename on the same volume.
Copy-AppFilesMirror -SourceDir $contentRoot -DestDir $stagedDir
Remove-TempStagingDir -Dir $extracted

# Make sure what's staged actually runs before it replaces anything.
$stagedVersion = ''
try { $stagedVersion = "$(& (Join-Path $stagedDir 'pwsh.exe') --version 2>$null)" } catch { }
if ($stagedVersion -notmatch [regex]::Escape($latestVersion)) {
    throw "The staged PowerShell in $stagedDir doesn't run as $latestVersion (got '$stagedVersion'); the install was left as it was."
}

if (-not (Test-CurrentProcessInsideDir -Dir $InstallDir) -and (Install-StagedPwsh -StopSessions:$Force)) {
    Write-Ok "PowerShell updated to $latestVersion"
    $global:AppUpdateResult = 'updated'
} else {
    $sys32Pwsh = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $sys32Pwsh)) {
        throw "Could not find Windows PowerShell ($sys32Pwsh) to finish the update. Close every pwsh session and re-run this script from Windows PowerShell."
    }
    # Unset PSModulePath for the helper so Windows PowerShell builds its own: inherited from pwsh, it
    # lists pwsh's module folders first, and Windows PowerShell then loads pwsh's newer modules.
    $modulePath = $env:PSModulePath
    $env:PSModulePath = $null
    try {
        Start-Process -FilePath $sys32Pwsh -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"", '-InstallDir', "`"$InstallDir`"", '-FinishStaged')
    } finally {
        $env:PSModulePath = $modulePath
    }
    Write-Ok "PowerShell $latestVersion staged. It installs by itself once these pwsh sessions have closed: $(Get-PwshSessionList)"
    $global:AppUpdateResult = 'staged'
}

Add-UserPathEntry -PathToAdd $InstallDir
