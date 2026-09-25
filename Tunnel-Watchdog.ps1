<#
.SYNOPSIS
    Keeps a VS Code tunnel (code-tunnel.exe from Apps\VSCode) alive. Meant to
    run from a scheduled task every few minutes; see -Register.

    "Healthy" means some code-tunnel.exe process holds an ESTABLISHED TCP
    connection to port 443 (the dev tunnels relay). `code tunnel status` is
    NOT trusted: it keeps reporting "Connected" after the relay has dropped
    the connection, and a stuck self-update can leave a zombie tunnel holding
    the singleton lock so every new tunnel just attaches to it. When unhealthy,
    every code-tunnel.exe is killed and a fresh tunnel is started.

    Tunnel output goes to <UserProfile>\.vscode\cli\tunnel-output.log and
    watchdog decisions to <UserProfile>\.vscode\cli\tunnel-watchdog.log.

.PARAMETER Restart
    Kill and restart the tunnel even if it looks healthy (daily backstop).

.PARAMETER Register
    Register the scheduled tasks instead of checking the tunnel:
      VSCode-Tunnel-Watchdog  - at logon, then every 2 minutes
      VSCode-Tunnel-Restart   - daily at 4 AM with -Restart

.PARAMETER InstallDir
    Folder VS Code lives in. Defaults to <UserProfile>\Apps\VSCode.
#>
[CmdletBinding()]
param(
    [switch]$Restart,
    [switch]$Register,
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'VSCode')
)

$ErrorActionPreference = 'Stop'

$tunnelExe  = Join-Path $InstallDir 'bin\code-tunnel.exe'
$cliDir     = Join-Path $env:USERPROFILE '.vscode\cli'
$logFile    = Join-Path $cliDir 'tunnel-watchdog.log'
$outputLog  = Join-Path $cliDir 'tunnel-output.log'
$startGrace = [TimeSpan]::FromMinutes(3)   # time a fresh tunnel gets to connect before we judge it

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $line
    try { Add-Content -Path $logFile -Value $line } catch { }
}

# Keep a log file from growing without bound: once over $MaxBytes, keep the newest half.
function Limit-LogFile {
    param([string]$Path, [int]$MaxBytes = 1MB)
    try {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt $MaxBytes) {
            $lines = Get-Content $Path
            $lines | Select-Object -Last ([int]($lines.Count / 2)) | Set-Content $Path
        }
    } catch { }   # the tunnel may hold the output log open; trimming is best-effort
}

if ($Register) {
    $pwshExe = (Get-Process -Id $PID).Path
    $taskArgs = "-NoProfile -WindowStyle Hidden -File `"$PSCommandPath`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

    $atLogon  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $atLogon.Delay = 'PT1M'   # let Update-AllApps write its marker first (the check below then waits for it)
    $every2   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName 'VSCode-Tunnel-Watchdog' -Force `
        -Action (New-ScheduledTaskAction -Execute $pwshExe -Argument $taskArgs) `
        -Trigger $atLogon, $every2 -Settings $settings -Principal $principal `
        -Description 'Restart the VS Code tunnel if it is not connected to the relay' | Out-Null

    Register-ScheduledTask -TaskName 'VSCode-Tunnel-Restart' -Force `
        -Action (New-ScheduledTaskAction -Execute $pwshExe -Argument "$taskArgs -Restart") `
        -Trigger (New-ScheduledTaskTrigger -Daily -At '4:00 AM') -Settings $settings -Principal $principal `
        -Description 'Daily unconditional restart of the VS Code tunnel' | Out-Null

    Write-Host "Registered scheduled tasks VSCode-Tunnel-Watchdog and VSCode-Tunnel-Restart"
    return
}

New-Item -ItemType Directory -Force -Path $cliDir | Out-Null
Limit-LogFile $logFile
Limit-LogFile $outputLog

# Don't start a tunnel out of Apps\VSCode while the updater may be mirroring files into it.
# Update-AllApps.ps1 writes this marker (holding its PID) when it starts and removes it
# once updates are done, before its "Press Enter to close" prompt. The marker only counts
# while that same process is alive, so a crashed run or one from before a reboot is
# ignored, and never beyond $updaterMaxWait in case the updater itself hangs.
$runningMarker  = Join-Path $env:LOCALAPPDATA 'BootstrapSoftware\Update-AllApps.running'
$updaterMaxWait = [TimeSpan]::FromMinutes(60)
if (Test-Path $runningMarker) {
    $marker = Get-Item $runningMarker
    $updaterPid = 0
    [int]::TryParse((Get-Content $runningMarker -TotalCount 1), [ref]$updaterPid) | Out-Null
    $updater = if ($updaterPid -gt 0) { Get-Process -Id $updaterPid -ErrorAction SilentlyContinue }
    if ($updater -and $updater.StartTime -and $updater.StartTime -le $marker.LastWriteTime -and
        ((Get-Date) - $marker.LastWriteTime) -lt $updaterMaxWait) {
        Write-Log "Update-AllApps (PID $updaterPid, started $($updater.StartTime)) is still updating; skipping this check."
        return
    }
}

if (-not (Test-Path $tunnelExe)) {
    Write-Log "ERROR: $tunnelExe not found."
    return
}

$tunnelProcs = @(Get-Process -Name 'code-tunnel' -ErrorAction SilentlyContinue)

if (-not $Restart) {
    $connected = @(Get-NetTCPConnection -State Established -RemotePort 443 -ErrorAction SilentlyContinue |
        Where-Object { $tunnelProcs.Id -contains $_.OwningProcess })
    if ($connected.Count -gt 0) {
        return   # healthy; stay quiet so the log only records events
    }

    $newest = $tunnelProcs | Sort-Object StartTime -Descending | Select-Object -First 1
    if ($newest -and ((Get-Date) - $newest.StartTime) -lt $startGrace) {
        Write-Log "Tunnel started at $($newest.StartTime) is not connected yet; giving it more time."
        return
    }

    if ($tunnelProcs.Count -eq 0) {
        Write-Log "No tunnel running; starting one."
    } else {
        Write-Log "Tunnel not connected to relay ($($tunnelProcs.Count) code-tunnel process(es), no established :443 connection); restarting."
    }
} else {
    Write-Log "Scheduled restart."
}

if ($tunnelProcs.Count -gt 0) {
    # Ask politely first (bounded - it can hang talking to a zombie), then force.
    try {
        $kill = Start-Process -FilePath $tunnelExe -ArgumentList 'tunnel', 'kill' -WindowStyle Hidden -PassThru
        if (-not $kill.WaitForExit(15000)) { $kill | Stop-Process -Force -ErrorAction SilentlyContinue }
    } catch { }
    Get-Process -Name 'code-tunnel' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

# cmd.exe handles the append redirection; Start-Process can only overwrite.
$tunnelCmd = "`"$tunnelExe`" tunnel --accept-server-license-terms --no-sleep --log info >> `"$outputLog`" 2>&1"
Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d', '/c', "`"$tunnelCmd`"" -WindowStyle Hidden
Write-Log "Started new tunnel."
