<#
.SYNOPSIS
    Installs/updates kunkel321's AutoCorrect2 - an AHK v2 autocorrect suite -
    into Apps\AutoCorrect2. Non-admin: downloads the repo zip and extracts it
    in place, and (by default) puts a shortcut in your per-user Startup folder
    so it runs at logon. No elevation, no registry, no installer.

    AutoCorrect2 has no tagged releases, so "version" here is the latest commit
    on the main branch. The commit we installed is recorded in
    .autocorrect2-source.json in the install folder and compared on the next run.

    You do NOT need Update-AutoHotkey.ps1 for this: the .exe files in the repo
    (Core\AutoCorrect2.exe and the Tools\*.exe) are renamed copies of
    AutoHotkey.exe, so the suite runs portably straight out of its folder.

    YOUR DATA IS PRESERVED on update. AutoCorrect2 keeps your hotstring library,
    settings and logs inside its own folder, so an update never overwrites:
      Core\AutoCorrectHotstrings.ahk   your autocorrect library (what Win+H appends to)
      Core\PersonalHotstrings.ahk      your boilerplate/personal hotstrings
      Data\acSettings.ini              your settings, incl. renamed files and hotkeys
      Data\colorThemeSettings.ini      your color theme
      Data\PersonalApiKey.ini          your API key
      Data\PersonalHolidays.txt        your holiday list
      Data\RemovedHotstrings.txt       hotstrings you removed
      Data\LastUpdateCheck.ini         the built-in Updater's own state
      the AutoCorrect / manual-correction / error logs in Data\ and Debug\
    Everything else (code, tools, word lists, icons, docs) is refreshed.

    When upstream's hotstring library differs from yours, the new version is
    dropped next to yours under the NewTemporaryHotstrLib name from your
    acSettings.ini (default "AutoCorrectHotstrings (1).ahk"), which is exactly
    where the suite's UniqueStringExtractor tool looks when you merge the two.

.PARAMETER InstallDir
    Folder AutoCorrect2 lives in. Defaults to <UserProfile>\Apps\AutoCorrect2.

.PARAMETER NoStartupShortcut
    Skip creating/refreshing the Startup shortcut. The shortcut is per-user
    (%APPDATA%\...\Start Menu\Programs\Startup) - delete the .lnk to undo.

.PARAMETER Force
    Re-download and re-extract even if already on the latest commit, and
    force-close AutoCorrect2 if it's running from this folder. AutoCorrect2 is
    a background app you normally leave running, so updates will usually need
    -Force; the script relaunches it afterwards.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path (Join-Path $env:USERPROFILE 'Apps') 'AutoCorrect2'),
    [switch]$NoStartupShortcut,
    [switch]$Force
)

. "$PSScriptRoot\Common.ps1"

$repo   = 'kunkel321/AutoCorrect2'
$branch = 'main'

Write-Step "AutoCorrect2 ($InstallDir)"

$coreDir     = Join-Path $InstallDir 'Core'
$dataDir     = Join-Path $InstallDir 'Data'
$mainScript  = Join-Path $coreDir 'AutoCorrect2.ahk'
$mainExe     = Join-Path $coreDir 'AutoCorrect2.exe'
$markerPath  = Join-Path $InstallDir '.autocorrect2-source.json'
$settingsIni = Join-Path $dataDir 'acSettings.ini'

$isFirstInstall = -not (Test-Path $mainScript)

function Get-IniValue {
    <# Minimal [Section] key=value reader; returns $Default if the file/section/key isn't there. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Default
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $inSection = $false
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -eq $Section)
            continue
        }
        if (-not $inSection) { continue }
        if ($trimmed.StartsWith(';')) { continue }
        if ($trimmed -match '^([^=]+)=(.*)$' -and $Matches[1].Trim() -eq $Key) {
            $value = $Matches[2].Trim()
            if ($value) { return $value }
        }
    }
    return $Default
}

# The library names are configurable in acSettings.ini, so read what THIS
# install actually uses rather than assuming the stock names.
$hotstringLibName = Get-IniValue -Path $settingsIni -Section 'Files' -Key 'HotstringLibrary'             -Default 'AutoCorrectHotstrings.ahk'
$boilerplateName  = Get-IniValue -Path $settingsIni -Section 'Files' -Key 'BoilerplateHotstringLibrary'  -Default 'PersonalHotstrings.ahk'
$newLibName       = Get-IniValue -Path $settingsIni -Section 'Files' -Key 'NewTemporaryHotstrLib'        -Default 'AutoCorrectHotstrings (1).ahk'

$installedSha = ''
if (Test-Path $markerPath) {
    try { $installedSha = (Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json).Sha } catch { }
}

$commit     = Invoke-GitHubApi -Uri "https://api.github.com/repos/$repo/commits/$branch"
$latestSha  = $commit.sha
$latestDate = ([datetime]$commit.commit.committer.date).ToLocalTime().ToString('yyyy-MM-dd')

$shortInstalled = if ($installedSha) { $installedSha.Substring(0, 7) } else { '(not installed)' }
Write-Info "Installed: $shortInstalled   Latest: $($latestSha.Substring(0,7)) ($latestDate)"

if (-not $Force -and -not $isFirstInstall -and $installedSha -eq $latestSha) {
    Write-Skip "Already up to date."
} else {
    # Note who is running before Assert-DirNotInUse gets a chance to stop them.
    $wasRunning = @(Get-ProcessesUsingPath -Dir $InstallDir).Count -gt 0
    if (-not (Assert-DirNotInUse -Dir $InstallDir -Force:$Force)) {
        return
    }

    # Pin the download to the commit we just resolved, so a push landing
    # mid-run cannot leave us with files the marker does not describe.
    $extracted   = Expand-ZipToDir -Uri "https://github.com/$repo/archive/$latestSha.zip"
    $contentRoot = Get-EffectiveContentRoot -ExtractedDir $extracted   # zip wraps in AutoCorrect2-<sha>\

    # desktop.ini only carries the author's own absolute icon path, so it is
    # never worth copying.
    $excludeFiles = @('desktop.ini')
    if (-not $isFirstInstall) {
        # On a first install these are the seed copies and must be laid down;
        # after that they belong to the user.
        $excludeFiles += @(
            $hotstringLibName,
            $boilerplateName,
            'acSettings.ini',
            'colorThemeSettings.ini',
            'PersonalApiKey.ini',
            'PersonalHolidays.txt',
            'RemovedHotstrings.txt',
            'LastUpdateCheck.ini',
            'AutoCorrectsLog.txt',
            'ACLogContinuous.txt',
            'ManualCorrectionsLog.txt',
            'MCLogContinuous.txt',
            'ErrContextLog.txt',
            'Updater_debug.txt',
            'ac2_error_debug_log.txt'
        )
    }

    Copy-AppFiles -SourceDir $contentRoot -DestDir $InstallDir -ExcludeFiles $excludeFiles

    # Upstream keeps adding corrections to the stock library, but so do you via
    # Win+H - so hand over the new one for merging instead of overwriting.
    if (-not $isFirstInstall) {
        $upstreamLib = Join-Path (Join-Path $contentRoot 'Core') 'AutoCorrectHotstrings.ahk'
        $currentLib  = Join-Path $coreDir $hotstringLibName
        if ((Test-Path $upstreamLib) -and (Test-Path $currentLib)) {
            $upstreamHash = (Get-FileHash -LiteralPath $upstreamLib -Algorithm SHA256).Hash
            $currentHash  = (Get-FileHash -LiteralPath $currentLib  -Algorithm SHA256).Hash
            if ($upstreamHash -ne $currentHash) {
                $newLibPath = Join-Path $coreDir $newLibName
                Copy-Item -LiteralPath $upstreamLib -Destination $newLibPath -Force
                Write-Info "Upstream hotstring library differs from yours; new copy saved as Core\$newLibName"
                Write-Info "Merge it with Tools\UniqueStringExtractor.exe (or from the Hotstring Helper control panel)."
            }
        }
    }

    Remove-TempStagingDir -Dir $extracted

    $marker = [pscustomobject]@{
        Repo        = $repo
        Branch      = $branch
        Sha         = $latestSha
        CommitDate  = $latestDate
        InstalledAt = (Get-Date).ToString('s')
    }
    Set-Content -LiteralPath $markerPath -Value ($marker | ConvertTo-Json) -Encoding UTF8

    if ($isFirstInstall) {
        Write-Ok "AutoCorrect2 installed at commit $($latestSha.Substring(0,7)) ($latestDate)"
    } else {
        Write-Ok "AutoCorrect2 updated to commit $($latestSha.Substring(0,7)) ($latestDate) - your library, settings and logs were left untouched"
    }

    if ($wasRunning) {
        Start-Process -FilePath $mainExe -WorkingDirectory $coreDir
        Write-Ok "Relaunched AutoCorrect2."
    }
}

# --------------------------------------------------------------------------
# Startup shortcut - per-user Startup folder, so no admin rights needed.
# --------------------------------------------------------------------------
if ($NoStartupShortcut) {
    Write-Info "Skipping Startup shortcut (-NoStartupShortcut)."
} else {
    $startupDir = [Environment]::GetFolderPath('Startup')
    $lnkPath    = Join-Path $startupDir 'AutoCorrect2.lnk'
    $iconPath   = Join-Path (Join-Path $InstallDir 'Resources\Icons') 'ACicon.ico'

    $shell = New-Object -ComObject WScript.Shell
    try {
        $existingTarget = ''
        if (Test-Path $lnkPath) {
            try { $existingTarget = $shell.CreateShortcut($lnkPath).TargetPath } catch { }
        }
        if ($existingTarget -eq $mainExe) {
            Write-Info "Startup shortcut already points at $mainExe"
        } else {
            $shortcut = $shell.CreateShortcut($lnkPath)
            $shortcut.TargetPath       = $mainExe
            $shortcut.WorkingDirectory = $coreDir
            $shortcut.Description      = 'AutoCorrect2 - AHK v2 autocorrect suite'
            if (Test-Path $iconPath) { $shortcut.IconLocation = $iconPath }
            $shortcut.Save()
            Write-Ok "Startup shortcut written: $lnkPath"
            Write-Info "Delete that .lnk (or re-run with -NoStartupShortcut) to stop it running at logon."
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

if ($isFirstInstall) {
    Write-Info "Start it with: $mainExe"
    Write-Info "Then press Win+H to open Hotstring Helper and register your own corrections."
}
