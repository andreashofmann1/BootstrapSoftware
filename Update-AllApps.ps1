<#
.SYNOPSIS
    Runs all eleven Apps\* updater scripts in one go: AutoHotkey,
    AutoCorrectAHK, AzCopy, AzureCLI, Git, GitHubCLI, NodeJS, Notepad++,
    PowerShell, Python, VSCode.

    Each app can also be updated independently by running its own
    Update-<App>.ps1 script directly - this is just a convenience wrapper
    that runs them all and prints a summary. One app failing doesn't stop
    the others from running.

    Note that AutoCorrectAHK also ensures a per-user Startup shortcut for
    AutoCorrect2 (run Update-AutoCorrectAHK.ps1 -NoStartupShortcut directly
    if you'd rather it didn't), and that AutoCorrect2 is a background app you
    normally leave running, so it usually needs -Force to update.

.PARAMETER Only
    Optional list of apps to run instead of all eleven, e.g.
    -Only NodeJS,VSCode

.PARAMETER Force
    Passed through to every script: re-download/re-install even if already
    on the latest version, and force-close any running instance found in
    an app's install folder.

.EXAMPLE
    .\Update-AllApps.ps1

.EXAMPLE
    .\Update-AllApps.ps1 -Only AzCopy,NodeJS -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('AutoHotkey', 'AutoCorrectAHK', 'AzCopy', 'AzureCLI', 'Git', 'GitHubCLI', 'NodeJS', 'NotepadPlusPlus', 'PowerShell', 'Python', 'VSCode')]
    [string[]]$Only,
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

$allApps = [ordered]@{
    # AutoHotkey first: AutoCorrect2 ships its own renamed AutoHotkey.exe copies
    # so it doesn't depend on the AHK install, but this is the order that reads
    # sensibly in the summary table.
    'AutoHotkey'       = 'Update-AutoHotkey.ps1'
    'AutoCorrectAHK'   = 'Update-AutoCorrectAHK.ps1'
    'AzCopy'           = 'Update-AzCopy.ps1'
    'AzureCLI'         = 'Update-AzureCLI.ps1'
    'Git'              = 'Update-Git.ps1'
    'GitHubCLI'        = 'Update-GitHubCLI.ps1'
    'NodeJS'           = 'Update-NodeJS.ps1'
    'NotepadPlusPlus'  = 'Update-NotepadPlusPlus.ps1'
    'PowerShell'       = 'Update-PowerShell.ps1'
    'Python'           = 'Update-Python.ps1'
    'VSCode'           = 'Update-VSCode.ps1'
}

$toRun = if ($Only) { $Only } else { $allApps.Keys }

Write-Host ""
Write-Host "==============================================" -ForegroundColor Magenta
Write-Host " Updating $($toRun.Count) app(s)" -ForegroundColor Magenta
Write-Host "==============================================" -ForegroundColor Magenta

if (Test-CurrentProcessInsideDir -Dir (Join-Path (Get-DefaultAppsRoot) 'PowerShell')) {
    Write-Host ""
    Write-Host "Note: you're running this from the portable pwsh being managed here." -ForegroundColor DarkYellow
    Write-Host "The PowerShell update step (if needed) will stage itself and finish" -ForegroundColor DarkYellow
    Write-Host "automatically once you close this window - see its own output below." -ForegroundColor DarkYellow
}

$results = @()

foreach ($appName in $toRun) {
    $scriptFile = $allApps[$appName]
    $scriptPath = Join-Path $PSScriptRoot $scriptFile
    Write-Host ""
    if (-not (Test-Path $scriptPath)) {
        Write-Fail "$appName - script not found: $scriptPath"
        $results += [pscustomobject]@{ App = $appName; Result = 'Not found'; Detail = $scriptPath }
        continue
    }
    try {
        & $scriptPath -Force:$Force
        $results += [pscustomobject]@{ App = $appName; Result = 'OK'; Detail = '' }
    } catch {
        Write-Fail "$appName failed: $($_.Exception.Message)"
        $results += [pscustomobject]@{ App = $appName; Result = 'FAILED'; Detail = $_.Exception.Message }
    }
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Magenta
Write-Host " Summary" -ForegroundColor Magenta
Write-Host "==============================================" -ForegroundColor Magenta
$results | Format-Table -AutoSize | Out-String | Write-Host

$failures = $results | Where-Object { $_.Result -eq 'FAILED' -or $_.Result -eq 'Not found' }
if ($failures) {
    Write-Host "$($failures.Count) app(s) had problems - see above." -ForegroundColor Red
}

# Ensure a logon scheduled task exists so updates run automatically.
$taskName = 'Update-AllApps'
$pwshExe  = (Get-Process -Id $PID).Path
$scriptFullPath = $PSCommandPath
$needsUpdate = $false

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $existing) {
    $needsUpdate = $true
} else {
    $act = $existing.Actions | Select-Object -First 1
    if ($act.Execute -ne $pwshExe -or $act.Arguments -ne "-NoProfile -File `"$scriptFullPath`"") {
        $needsUpdate = $true
    }
}

if ($needsUpdate) {
    Write-Step "Registering '$taskName' scheduled task (runs at logon)"
    $action    = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -File `"$scriptFullPath`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Run BootstrapSoftware updater at logon' -Force | Out-Null
    Write-Ok "Scheduled task '$taskName' registered"
} else {
    Write-Info "Scheduled task '$taskName' already up to date"
}

# Run shared custom commands (tracked by git, runs on all machines).
$customScript = Join-Path $PSScriptRoot 'Custom-Commands.ps1'
if (Test-Path $customScript) {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Magenta
    Write-Host " Running custom commands" -ForegroundColor Magenta
    Write-Host "==============================================" -ForegroundColor Magenta
    try {
        & $customScript
    } catch {
        Write-Fail "Custom-Commands.ps1 failed: $($_.Exception.Message)"
    }
}

# Run machine-specific hook if present (not tracked by git).
$localScript = Join-Path $PSScriptRoot 'Update-Local.ps1'
if (Test-Path $localScript) {
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Magenta
    Write-Host " Running machine-local hook" -ForegroundColor Magenta
    Write-Host "==============================================" -ForegroundColor Magenta
    try {
        & $localScript -Force:$Force
    } catch {
        Write-Fail "Update-Local.ps1 failed: $($_.Exception.Message)"
    }
}

if ($failures) {
    exit 1
} else {
    Write-Host "All done." -ForegroundColor Green
    exit 0
}
