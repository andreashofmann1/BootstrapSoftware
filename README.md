# BootstrapSoftware

A set of standalone PowerShell scripts that install and keep a handful of
developer tools up to date **without admin rights**. Everything lives as a
portable, xcopy-deployable install under `%USERPROFILE%\Apps\<AppName>`, and
each app's folder is added to your *User* `PATH` — no elevation, no
system-wide installers, no registry changes outside `HKCU`.

## Apps managed

| Script | App | Source |
|---|---|---|
| [`Update-AzCopy.ps1`](Update-AzCopy.ps1) | AzCopy | Latest GitHub release (`Azure/azure-storage-azcopy`) |
| [`Update-AzureCLI.ps1`](Update-AzureCLI.ps1) | Azure CLI | Latest PyPI `azure-cli`, installed into a bootstrapped portable Python |
| [`Update-GitHubCLI.ps1`](Update-GitHubCLI.ps1) | GitHub CLI (`gh`) | Latest GitHub release (`cli/cli`) |
| [`Update-NodeJS.ps1`](Update-NodeJS.ps1) | Node.js | `nodejs.org` dist index (Current or LTS channel) |
| [`Update-NotepadPlusPlus.ps1`](Update-NotepadPlusPlus.ps1) | Notepad++ | Latest GitHub release (`notepad-plus-plus/notepad-plus-plus`), portable x64 build |
| [`Update-PowerShell.ps1`](Update-PowerShell.ps1) | PowerShell 7 (`pwsh`) | Latest GitHub release (`PowerShell/PowerShell`) |
| [`Update-VSCode.ps1`](Update-VSCode.ps1) | VS Code | Official `win32-x64-archive` stable update feed |

All of them dot-source [`Common.ps1`](Common.ps1) for shared helpers (console
output, version comparison, GitHub release lookup, download/extract,
running-process safety checks, and User `PATH`/env var management).

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
  `pip install --target` straight into `Apps\AzureCLI`, driven by an
  `az.cmd` shim.
- **Running-process safety.** Before overwriting an install directory, each
  script checks whether any process is currently running from it and skips
  the update (or force-closes it with `-Force`) rather than risk corrupting
  a locked binary.

## Requirements

- Windows with PowerShell 5.1+ (or PowerShell 7/`pwsh`) to run the scripts.
- Internet access to GitHub Releases, nodejs.org, PyPI, python.org, and the
  VS Code update feed, depending on which app you're updating.
