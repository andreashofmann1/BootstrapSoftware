# BootstrapSoftware

A set of standalone PowerShell scripts that install and keep a handful of
developer tools up to date **without admin rights**. Everything lives as a
portable, xcopy-deployable install under `%USERPROFILE%\Apps\<AppName>`, and
each command-line app's folder is added to your *User* `PATH` — no elevation,
no system-wide installers, no registry changes outside `HKCU`.

## Apps managed

| Script | App | Source |
|---|---|---|
| [`Update-AutoHotkey.ps1`](Update-AutoHotkey.ps1) | AutoHotkey v2 | Latest GitHub release (`AutoHotkey/AutoHotkey`), official zip |
| [`Update-AutoCorrectAHK.ps1`](Update-AutoCorrectAHK.ps1) | AutoCorrect2 (AHK v2 autocorrect suite) | Latest commit on `main` (`kunkel321/AutoCorrect2`) — no tagged releases |
| [`Update-AzCopy.ps1`](Update-AzCopy.ps1) | AzCopy | Latest GitHub release (`Azure/azure-storage-azcopy`) |
| [`Update-AzureCLI.ps1`](Update-AzureCLI.ps1) | Azure CLI | Latest PyPI `azure-cli`, installed into a bootstrapped portable Python |
| [`Update-GitHubCLI.ps1`](Update-GitHubCLI.ps1) | GitHub CLI (`gh`) | Latest GitHub release (`cli/cli`) |
| [`Update-NodeJS.ps1`](Update-NodeJS.ps1) | Node.js | `nodejs.org` dist index (Current or LTS channel) |
| [`Update-NotepadPlusPlus.ps1`](Update-NotepadPlusPlus.ps1) | Notepad++ | Latest GitHub release (`notepad-plus-plus/notepad-plus-plus`), portable x64 build |
| [`Update-PowerShell.ps1`](Update-PowerShell.ps1) | PowerShell 7 (`pwsh`) | Latest GitHub release (`PowerShell/PowerShell`) |
| [`Update-Python.ps1`](Update-Python.ps1) | Python (full CPython, for development) | Latest GitHub release (`astral-sh/python-build-standalone`) |
| [`Update-VSCode.ps1`](Update-VSCode.ps1) | VS Code | Official `win32-x64-archive` stable update feed |

All of them dot-source [`Common.ps1`](Common.ps1) for shared helpers (console
output, version comparison, GitHub release lookup, download/extract,
running-process safety checks, pip `--target` dist-info handling, and User
`PATH`/env var management).

## Usage

Update everything at once:

```powershell
.\Update-AllApps.ps1
```

Update just a subset:

```powershell
.\Update-AllApps.ps1 -Only AzCopy,NodeJS
```

Force a re-download/re-install even if already current (and force-close any
running instance found in an app's install folder):

```powershell
.\Update-AllApps.ps1 -Force
```

Each script can also be run on its own, e.g.:

```powershell
.\Update-VSCode.ps1
.\Update-NodeJS.ps1 -Channel LTS
```

One app failing in `Update-AllApps.ps1` doesn't stop the others — a summary
table is printed at the end and the process exits non-zero if anything
failed or a script was missing.

## Design notes

- **Non-admin by design.** Installs live under `%USERPROFILE%\Apps` and PATH
  changes are User-scope (`HKCU`) only.
- **User data is preserved.** Most updates only add/overwrite files
  (`Copy-AppFiles`, backed by `robocopy`) and never delete anything already
  in the destination — so npm global packages (Node), pip packages
  (Azure CLI), etc. survive an update. Notepad++ additionally excludes its
  config/session/plugin-config files and `backup\` folder by name. VS Code
  is the one exception: since it keeps no user data inside its install
  folder, it's fully mirrored (`Copy-AppFilesMirror`) to also clean up
  leftover version-hash folders left by VS Code's own updater.
- **Safe self-update.** `Update-PowerShell.ps1` detects if it's currently
  running from the `pwsh.exe` it's about to replace. If so, it stages the
  new build and hands off to a detached helper (via the always-available
  Windows PowerShell 5.1) that finishes the swap automatically once you
  close the session — no extra steps needed.
- **Azure CLI has no official Windows zip**, so it's handled differently:
  a portable embeddable Python is bootstrapped into `Apps\Python` (only
  once, if missing), then `azure-cli` is installed via
  `pip install --target` straight into `Apps\AzureCLI`. Two quirks of that
  layout are handled explicitly:
  - **A generated `az_launcher.py` repairs `sys.path`.** `pip install
    --target` drops the payload into `Apps\AzureCLI`, but nothing puts that
    folder on `sys.path`: Python only adds the *script's* own directory
    (`...\azure\cli`), and the embeddable runtime's `._pth` file forces
    isolated mode, so `PYTHONPATH` is ignored too. The launcher prepends
    the install dir — plus pywin32's `win32`, `win32\lib` and `pythonwin`
    folders, and its `pywin32_system32` DLL directory, since the pywin32
    post-install step never runs under `--target` — before handing off to
    `azure.cli`. `az.cmd` invokes the bootstrapped `python.exe` by full
    path and points it at the launcher.
  - **Stale `*.dist-info` folders are pruned.** `pip install --upgrade
    --target` overwrites the package payload but leaves the previous
    version's `*.dist-info` next to the new one. Reading "the first
    dist-info that matches" would report the old version forever, making
    every run conclude an update was due, so the installed version is read
    as the *highest* dist-info present (`Get-DistInfoVersion`) and the
    leftovers are deleted afterwards (`Remove-StaleDistInfo`).
- **There are deliberately two Pythons.** `Apps\Python` is the official
  *embeddable* distribution, bootstrapped and owned by
  `Update-AzureCLI.ps1` purely to host azure-cli. That distribution is meant
  for shipping inside an application: its standard library is zipped, and it
  has no `venv`, `ensurepip`, `tkinter`, `include\` or `libs\`, so it cannot
  create virtual environments and cannot build any package without a
  prebuilt wheel. `Update-Python.ps1` therefore installs a *separate*, full
  CPython in `Apps\Python312` for actual development work, and leaves the
  Azure CLI runtime alone. Since python.org publishes no full portable zip
  for Windows - only the embeddable one and an `.exe` installer, which would
  not be xcopy-deployable - the build comes from
  `astral-sh/python-build-standalone`: ordinary relocatable CPython builds,
  which is what keeps this non-admin. Both folders are on the User PATH, so
  `Update-Python.ps1` calls `Add-UserPathEntry -Prepend` to put the full
  Python *first* and win a bare `python` lookup. Azure CLI is unaffected -
  its `az.cmd` invokes its own `python.exe` by full path.

- **AutoHotkey ships no plain `AutoHotkey.exe`** in its zip — only
  `AutoHotkey64.exe`/`AutoHotkey32.exe`, since the setup `.exe` builds the
  launcher itself. `Update-AutoHotkey.ps1` keeps a copy matching your OS
  bitness as `AutoHotkey.exe` so `AutoHotkey myscript.ahk` works from PATH.
  It makes no registry changes, so `.ahk` files stay unassociated.
- **AutoCorrect2 is versioned by commit**, not release tag: the installed
  commit is recorded in `.autocorrect2-source.json` and compared on the next
  run. It's also the one app whose *user data lives inside its install
  folder*, so updates never overwrite your hotstring library
  (`Core\AutoCorrectHotstrings.ahk`, what Win+H appends to), personal
  hotstrings, `acSettings.ini`, API key or logs — while still refreshing
  code, tools, word lists and docs. When upstream's library differs from
  yours, the new one is saved beside it under the `NewTemporaryHotstrLib`
  name from your `acSettings.ini`, which is where the suite's own
  `UniqueStringExtractor` tool looks when merging the two. It gets a
  per-user Startup shortcut instead of a `PATH` entry (it's a background
  app, not a CLI), and needs no AutoHotkey install of its own — its bundled
  `.exe` files are renamed copies of `AutoHotkey.exe`.
- **Running-process safety.** Before overwriting an install directory, each
  script checks whether any process is currently running from it and skips
  the update (or force-closes it with `-Force`) rather than risk corrupting
  a locked binary.
- **Exit codes are honest.** `robocopy` signals *success* with low non-zero
  exit codes (1 = files copied, 2 = extra files in destination), which would
  otherwise linger in `$LASTEXITCODE` and become the script's own exit code —
  so `powershell -File Update-VSCode.ps1` reported failure after a perfectly
  good update. The copy helpers clear it (`Reset-LastExitCode`) once they've
  confirmed the code is below robocopy's real-failure threshold of 8, which
  keeps these scripts usable from scheduled tasks and CI.

## Requirements

- Windows with PowerShell 5.1+ (or PowerShell 7/`pwsh`) to run the scripts.
- Internet access to GitHub Releases, nodejs.org, PyPI, python.org, and the
  VS Code update feed, depending on which app you're updating.
