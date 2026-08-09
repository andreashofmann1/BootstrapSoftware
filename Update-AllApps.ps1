<#
.SYNOPSIS
    Runs all seven Apps\* updater scripts in one go: AzCopy, AzureCLI,
    GitHubCLI, NodeJS, Notepad++, PowerShell, VSCode.

    Each app can also be updated independently by running its own
    Update-<App>.ps1 script directly - this is just a convenience wrapper
    that runs them all and prints a summary. One app failing doesn't stop
    the others from running.

.PARAMETER Only
    Optional list of apps to run instead of all seven, e.g.
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
    [ValidateSet('AzCopy', 'AzureCLI', 'GitHubCLI', 'NodeJS', 'NotepadPlusPlus', 'PowerShell', 'VSCode')]
    [string[]]$Only,
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

$allApps = [ordered]@{
    'AzCopy'           = 'Update-AzCopy.ps1'
    'AzureCLI'         = 'Update-AzureCLI.ps1'
    'GitHubCLI'        = 'Update-GitHubCLI.ps1'
    'NodeJS'           = 'Update-NodeJS.ps1'
    'NotepadPlusPlus'  = 'Update-NotepadPlusPlus.ps1'
    'PowerShell'       = 'Update-PowerShell.ps1'
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
    exit 1
} else {
    Write-Host "All done." -ForegroundColor Green
    exit 0
}
