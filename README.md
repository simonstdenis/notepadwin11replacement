# NotepadWin11Replacement

Makes every Notepad launch on Windows 11 open **Notepad++** (or another editor of your choice), like the classic
`Image File Execution Options\notepad.exe\Debugger` trick, including the Store (modern) Notepad.

## Quick install

**One line** in PowerShell (asks for admin rights; installs Notepad++ as the editor and removes the Store Notepad):

```powershell
irm https://github.com/simonstdenis/notepadwin11replacement/releases/latest/download/install.ps1 | iex
```

With options (same names as `Install.ps1`, plus `-KeepStoreNotepad`, `-Uninstall`, `-Version v1.1.0`):

```powershell
& ([scriptblock]::Create((irm https://github.com/simonstdenis/notepadwin11replacement/releases/latest/download/install.ps1))) -Editor VSCode
& ([scriptblock]::Create((irm https://github.com/simonstdenis/notepadwin11replacement/releases/latest/download/install.ps1))) -Uninstall
```

The script downloads `NotepadWin11Replacement.zip` from the release, checks it against
`SHA256SUMS.txt`, and runs `Install.ps1` elevated.

**Setup exe**: download `NotepadRedirect-Setup.exe` from the
[latest release](https://github.com/simonstdenis/notepadwin11replacement/releases/latest) and run it.
Without options it shows an editor menu.

```text
NotepadRedirect-Setup.exe --quiet                         # Notepad++, unattended (Intune / GPO / scripts)
NotepadRedirect-Setup.exe --quiet --editor VSCode
NotepadRedirect-Setup.exe --quiet --editor Custom --editor-path "C:\Tools\micro\micro.exe"
NotepadRedirect-Setup.exe --quiet --keep-store-notepad
NotepadRedirect-Setup.exe --uninstall --quiet
```

The exe is self-contained (it carries the release zip and runs the same scripts) and not code-signed,
so SmartScreen may warn on first run ("More info" → "Run anyway").

## Releasing

Push a `v*` tag. `.github/workflows/release.yml` runs `Package.ps1`, the parsing tests and publishes
`install.ps1`, `NotepadRedirect-Setup.exe`, `NotepadWin11Replacement.zip` and `SHA256SUMS.txt`.
The asset names carry no version, so the `releases/latest/download/...` URLs above always point to
the newest release. `.\Package.ps1 -Version 1.2.0` builds the same files locally into `dist\`.

## How it works

| Launch route | Mechanism |
|---|---|
| `notepad`, `notepad.exe`, System32 / SysWOW64 / Windows paths, "Edit" context menus | IFEO `Debugger` → `npp-shim.exe` → configured editor |
| Store Notepad (alias, Start menu, AppX file associations) | Packaged activation **ignores IFEO**, so the Store app is removed (`-RemoveStoreNotepad`) |
| Double-click `.txt` / `.log` / `.ini` | Default app set to the editor (manual, see below) |

Windows 11 itself uses `IFEO\notepad.exe\0|1|2` (`AppExecutionAliasRedirect`) to send classic
`notepad.exe` launches to the Store app. Those subkeys are never modified; the `Debugger` value is
evaluated first.

`npp-shim.exe` (built from `src\NppShim.cs`) drops the original notepad image path from the command
line, applies Notepad's rules (rest of line = one file name, spaces allowed), maps `/p` and `/pt` to
the editor's print arguments (Notepad++ `-quickPrint`), drops `/A` and `/W`, and resolves relative paths. Every call is logged to
`%LOCALAPPDATA%\NotepadWin11Replacement\shim.log`.

## Usage from a clone

```powershell
.\Build.ps1                                # compile bin\npp-shim.exe (in-box csc.exe)
.\Install.ps1 -RemoveStoreNotepad          # elevated
.\Test.ps1                                 # non-elevated: parsing + live launch routes
.\Uninstall.ps1                            # elevated; Store Notepad: winget install 9MSMLRH6LZF3 --source msstore
```

## Choosing another editor

Re-run `Install.ps1` (elevated) with `-Editor` to switch. Nothing else changes.

| `-Editor` | Looks in | Open args | Print (`/p`) args |
|---|---|---|---|
| `NotepadPlusPlus` (default) | `Program Files\Notepad++`, `Program Files (x86)\Notepad++` | `{file}` | `-quickPrint {file}` |
| `VSCode` | `Program Files\Microsoft VS Code`, `%LOCALAPPDATA%\Programs\Microsoft VS Code` | `{file}` | opens the file |
| `SublimeText` | `Program Files\Sublime Text`, `Program Files\Sublime Text 3` | `{file}` | opens the file |
| `Notepad3` | `Program Files\Notepad3`, `Program Files (x86)\Notepad3` | `{file}` | `/p {file}` |
| `Custom` | `-EditorPath` (required) | `{file}` | opens the file |

`-EditorPath`, `-EditorArgs` and `-EditorPrintArgs` override any preset. `{file}` becomes the quoted
full path. `-NppPath` still works as an alias of `-EditorPath`.

```powershell
.\Install.ps1 -Editor VSCode
.\Install.ps1 -Editor Custom -EditorPath 'C:\Tools\micro\micro.exe' -EditorArgs '{file}'
```

The settings are stored in `HKLM\SOFTWARE\NotepadWin11Replacement` (`EditorPath`, `EditorArgs`,
`EditorPrintArgs`, and optionally `EditorNoFileArgs` for launches without a file) and are read on every launch.
Install refuses an editor named `notepad.exe`, because the redirect would loop back to itself.
Editors installed per user (for example VS Code's user installer) only work for that user.

After removing the Store app, the `.txt`/`.log`/`.ini` defaults still point at it, and Windows
protects that choice with a hash so scripts can't change it. Set your editor once in
**Settings › Apps › Default apps**, or pick it with "Always" in the "Open with" dialog.

`Install.ps1` also registers the `NotepadWin11Replacement-Repair` scheduled task (SYSTEM, at startup +
daily). It puts the `Debugger` value back and removes the Store app again if an update restores either
(log: `%ProgramData%\NotepadWin11Replacement\repair.log`).

Installed files: `%ProgramFiles%\NotepadWin11Replacement\`. Original IFEO backup:
`%ProgramData%\NotepadWin11Replacement\ifeo-notepad-original.reg`.

## Caveats

- Security products may flag an IFEO `Debugger` value, because malware uses it for persistence (MITRE T1546.012).
- Programs that start `notepad.exe` and wait for it to close (some installers, `git` set up with
  `core.editor=notepad`) continue right away, because the shim hands off to the editor and exits.
