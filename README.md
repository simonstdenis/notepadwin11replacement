# NotepadWin11Replacement

Makes every Notepad launch on Windows 11 open **Notepad++**, like the classic
`Image File Execution Options\notepad.exe\Debugger` trick, including the Store (modern) Notepad.

## How it works

| Launch route | Mechanism |
|---|---|
| `notepad`, `notepad.exe`, System32 / SysWOW64 / Windows paths, "Edit" context menus | IFEO `Debugger` → `npp-shim.exe` → Notepad++ |
| Store Notepad (alias, Start menu, AppX file associations) | Packaged activation **ignores IFEO**, so the Store app is removed (`-RemoveStoreNotepad`) |
| Double-click `.txt` / `.log` / `.ini` | Default app set to Notepad++ (manual, see below) |

Windows 11 itself uses `IFEO\notepad.exe\0|1|2` (`AppExecutionAliasRedirect`) to send classic
`notepad.exe` launches to the Store app. Those subkeys are never modified; the `Debugger` value is
evaluated first.

`npp-shim.exe` (built from `src\NppShim.cs`) drops the original notepad image path from the command
line, applies Notepad's rules (rest of line = one file name, spaces allowed), maps `/p` and `/pt` to
`-quickPrint`, drops `/A` and `/W`, and resolves relative paths. Every call is logged to
`%LOCALAPPDATA%\NotepadWin11Replacement\shim.log`.

## Usage

```powershell
.\Build.ps1                                # compile bin\npp-shim.exe (in-box csc.exe)
.\Install.ps1 -RemoveStoreNotepad          # elevated
.\Test.ps1                                 # non-elevated: parsing + live launch routes
.\Uninstall.ps1                            # elevated; Store Notepad: winget install 9MSMLRH6LZF3 --source msstore
```

After removing the Store app, the `.txt`/`.log`/`.ini` defaults still point at it, and Windows
protects that choice with a hash so scripts can't change it. Set Notepad++ once in
**Settings › Apps › Default apps › Notepad++**, or pick it with "Always" in the "Open with" dialog.

`Install.ps1` also registers the `NotepadWin11Replacement-Repair` scheduled task (SYSTEM, at startup +
daily). It puts the `Debugger` value back and removes the Store app again if an update restores either
(log: `%ProgramData%\NotepadWin11Replacement\repair.log`).

Installed files: `%ProgramFiles%\NotepadWin11Replacement\`. Original IFEO backup:
`%ProgramData%\NotepadWin11Replacement\ifeo-notepad-original.reg`.

## Caveats

- Security products may flag an IFEO `Debugger` value, because malware uses it for persistence (MITRE T1546.012).
- Programs that start `notepad.exe` and wait for it to close (some installers, `git` set up with
  `core.editor=notepad`) continue right away, because the shim hands off to Notepad++ and exits.
