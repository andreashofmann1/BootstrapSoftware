# Common.ps1
# Shared helper functions for the app updater scripts.
# Dot-source this from each Update-*.ps1 script:  . "$PSScriptRoot\Common.ps1"
# Everything here is non-admin: user-scope PATH/env vars only, no elevation required.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster

# --------------------------------------------------------------------------
# Console output helpers
# --------------------------------------------------------------------------
function Write-Step    { param([string]$Message) Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Message) Write-Host "   OK: $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "   $Message" -ForegroundColor Gray }
function Write-Skip    { param([string]$Message) Write-Host "   SKIP: $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "   FAIL: $Message" -ForegroundColor Red }

# --------------------------------------------------------------------------
# Version helpers
# --------------------------------------------------------------------------

# Pull the first dotted-number run (e.g. "8.9.7" out of "v8.9.7" or "8.9.7.0")
# and return a [version] so -lt / -gt comparisons work reliably.
function ConvertTo-ComparableVersion {
    param([Parameter(Mandatory)][string]$Text)
    $m = [regex]::Match($Text, '\d+(\.\d+){1,3}')
    if (-not $m.Success) { throw "Could not parse a version number out of '$Text'" }
    return [version]$m.Value
}

function Test-UpdateNeeded {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$InstalledVersionText,
        [Parameter(Mandatory)][string]$LatestVersionText
    )
    if ([string]::IsNullOrWhiteSpace($InstalledVersionText)) { return $true }
    try {
        $installed = ConvertTo-ComparableVersion $InstalledVersionText
        $latest    = ConvertTo-ComparableVersion $LatestVersionText
        return $installed -lt $latest
    } catch {
        # If we can't parse/compare, err on the side of updating.
        return $true
    }
}

# --------------------------------------------------------------------------
# GitHub releases helpers
# --------------------------------------------------------------------------
function Invoke-GitHubApi {
    param([Parameter(Mandatory)][string]$Uri)
    $headers = @{ 'User-Agent' = 'AppUpdateScripts' }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Get-LatestGitHubRelease {
    <# Returns the release object (tag_name, assets[], ...) for the latest release of owner/repo #>
    param([Parameter(Mandatory)][string]$Repo)
    return Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repo/releases/latest"
}

function Get-GitHubReleaseAssetUrl {
    <# Finds the first asset whose name matches a wildcard pattern, e.g. "*windows_amd64.zip" #>
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$NamePattern
    )
    $asset = $Release.assets | Where-Object { $_.name -like $NamePattern } | Select-Object -First 1
    if (-not $asset) {
        throw "No release asset matching '$NamePattern' found in release $($Release.tag_name)"
    }
    return $asset.browser_download_url
}

# --------------------------------------------------------------------------
# Download / extract helpers
# --------------------------------------------------------------------------
function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $attempts = 0
    while ($true) {
        $attempts++
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        } catch {
            if ($attempts -ge 3) { throw }
            Write-Info "Download failed ($($_.Exception.Message)), retrying ($attempts/3)..."
            Start-Sleep -Seconds 2
        }
    }
}

function New-TempStagingDir {
    param([string]$Prefix = 'appupdate')
    $dir = Join-Path $env:TEMP "$Prefix-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Expand-ZipToDir {
    <# Downloads a zip from $Uri and extracts it into a fresh temp directory. Returns that directory. #>
    param([Parameter(Mandatory)][string]$Uri)
    $staging = New-TempStagingDir
    $zipPath = Join-Path $staging 'download.zip'
    Write-Info "Downloading $Uri"
    Invoke-FileDownload -Uri $Uri -OutFile $zipPath
    $extractDir = Join-Path $staging 'extracted'
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    return $extractDir
}

function Get-EffectiveContentRoot {
    <#
    Many release zips wrap everything in a single top-level folder
    (e.g. node-v26.7.0-win-x64\...). Others are flat (pwsh, notepad++).
    This returns the directory that actually holds the payload, stripping
    a lone wrapping folder when present.
    #>
    param([Parameter(Mandatory)][string]$ExtractedDir)
    $items = Get-ChildItem -LiteralPath $ExtractedDir
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        return $items[0].FullName
    }
    return $ExtractedDir
}

# --------------------------------------------------------------------------
# Copy strategies
#   - Copy-AppFiles: overwrite/add only, NEVER deletes anything already in
#     the destination. Safe default for apps that may hold user state
#     (npm global packages, Notepad++ session/config, PowerShell modules).
#   - Copy-AppFilesMirror: exact mirror of source into destination,
#     removing anything not present in the new release. Only use this for
#     apps that keep zero user data inside the install folder (VS Code).
# --------------------------------------------------------------------------
function Copy-AppFiles {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestDir,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs  = @()
    )
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $roboArgs = @($SourceDir, $DestDir, '/E', '/IS', '/IT', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS')
    if ($ExcludeFiles.Count -gt 0) { $roboArgs += '/XF'; $roboArgs += $ExcludeFiles }
    if ($ExcludeDirs.Count  -gt 0) { $roboArgs += '/XD'; $roboArgs += $ExcludeDirs }
    robocopy @roboArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed copying '$SourceDir' -> '$DestDir' (exit code $LASTEXITCODE)"
    }
}

function Copy-AppFilesMirror {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestDir
    )
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    robocopy $SourceDir $DestDir /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy /MIR failed copying '$SourceDir' -> '$DestDir' (exit code $LASTEXITCODE)"
    }
}

function Remove-TempStagingDir {
    param([Parameter(Mandatory)][string]$Dir)
    try {
        $root = Split-Path $Dir -Parent
        # Dir is the ".../extracted" folder inside a per-run staging dir; clean up the whole staging dir.
        if ((Split-Path $root -Leaf) -like 'appupdate-*') {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Best-effort cleanup only; leftover temp files are harmless.
    }
}

# --------------------------------------------------------------------------
# Running-process safety
# --------------------------------------------------------------------------
function Get-ProcessesUsingPath {
    param([Parameter(Mandatory)][string]$Dir)
    $full = (Resolve-Path -LiteralPath $Dir -ErrorAction SilentlyContinue)
    if (-not $full) { return @() }
    $full = $full.Path.TrimEnd('\')
    return Get-Process | Where-Object {
        try { $_.Path -and $_.Path.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase) }
        catch { $false }
    }
}

function Test-CurrentProcessInsideDir {
    <# True if the currently-running host process (pwsh/powershell) was launched from inside $Dir. #>
    param([Parameter(Mandatory)][string]$Dir)
    $full = (Resolve-Path -LiteralPath $Dir -ErrorAction SilentlyContinue)
    if (-not $full) { return $false }
    $full = $full.Path.TrimEnd('\')
    $me = (Get-Process -Id $PID).Path
    return $me -and $me.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DirNotInUse {
    <#
    Warns (and optionally stops) processes running out of $Dir before we overwrite files there.
    Returns $true if it is safe to proceed, $false if the caller should skip the update.
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [switch]$Force
    )
    $procs = Get-ProcessesUsingPath -Dir $Dir
    if ($procs.Count -eq 0) { return $true }

    $names = ($procs | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
    if ($Force) {
        Write-Info "Stopping running process(es) from this folder: $names"
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        return $true
    }

    Write-Skip "$names is currently running from this folder. Close it and re-run, or pass -Force to stop it automatically."
    return $false
}

# --------------------------------------------------------------------------
# User environment variables (non-admin: HKCU only)
# --------------------------------------------------------------------------
function Add-UserPathEntry {
    <# Idempotently ensures $PathToAdd is on the persistent User PATH, and on the live session PATH. #>
    param([Parameter(Mandatory)][string]$PathToAdd)

    $target = $PathToAdd.TrimEnd('\')
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @()
    if ($current) { $entries = $current -split ';' | Where-Object { $_ -ne '' } }

    $alreadyPresent = $entries | Where-Object { $_.TrimEnd('\').Equals($target, [StringComparison]::OrdinalIgnoreCase) }
    if ($alreadyPresent) {
        Write-Info "User PATH already contains $target"
    } else {
        $entries += $target
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
        Write-Ok "Added to User PATH: $target"
        Send-EnvironmentChangeBroadcast
    }

    # Make it usable in *this* session immediately, without needing a new window.
    $sessionEntries = @()
    if ($env:Path) { $sessionEntries = $env:Path -split ';' | Where-Object { $_ -ne '' } }
    $inSession = $sessionEntries | Where-Object { $_.TrimEnd('\').Equals($target, [StringComparison]::OrdinalIgnoreCase) }
    if (-not $inSession) {
        $env:Path = "$env:Path;$target"
    }
}

function Set-UserEnvVarIfMissing {
    <# Sets a User-scope env var only if it isn't already defined (never clobbers an existing value). #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $existing = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($existing) {
        Write-Info "User env var $Name already set (leaving as-is)"
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "Env:$Name" -Value $Value
    Write-Ok "Set User env var $Name=$Value"
    Send-EnvironmentChangeBroadcast
}

function Send-EnvironmentChangeBroadcast {
    <# Tells Explorer/new processes to pick up env var changes without a logoff. Best-effort only. #>
    try {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x1a
        $result = [UIntPtr]::Zero
        [Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
    } catch {
        # Non-fatal: worst case, the user needs to open a new shell to see the change.
    }
}

# --------------------------------------------------------------------------
# Misc
# --------------------------------------------------------------------------
function Get-DefaultAppsRoot {
    Join-Path $env:USERPROFILE 'Apps'
}
