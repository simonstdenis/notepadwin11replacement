#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the Notepad -> Notepad++ redirect installed by Install.ps1.

.DESCRIPTION
    Removes IFEO\notepad.exe\Debugger only if it points to our shim (restoring any Debugger that
    existed before install), deletes the shim and config key. Windows' AppExecutionAliasRedirect
    subkeys are never touched. The original backup in %ProgramData%\NotepadWin11Replacement is kept.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$ifeoViews = @{
    PreviousDebugger64 = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
    PreviousDebugger32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
}
$installDir = Join-Path $env:ProgramFiles 'NotepadWin11Replacement'
$configKey = 'HKLM:\SOFTWARE\NotepadWin11Replacement'
$config = Get-ItemProperty $configKey -ErrorAction SilentlyContinue

foreach ($name in $ifeoViews.Keys) {
    $view = $ifeoViews[$name]
    $current = (Get-ItemProperty $view -Name Debugger -ErrorAction SilentlyContinue).Debugger
    if (-not $current) { continue }
    if ($current -notlike '*NotepadWin11Replacement\npp-shim.exe*') {
        Write-Warning "Leaving foreign Debugger in place on $view : $current"
        continue
    }
    if ($config -and $config.$name) {
        Set-ItemProperty $view -Name Debugger -Value $config.$name
        Write-Host "Restored previous Debugger on $view"
    }
    else {
        Remove-ItemProperty $view -Name Debugger
        Write-Host "Removed Debugger from $view"
    }
}

if ($config -and $config.RemovedStoreNotepad) {
    Write-Host 'Store Notepad was removed by Install.ps1. Reinstall with:  winget install 9MSMLRH6LZF3 --source msstore'
}

Unregister-ScheduledTask -TaskName 'NotepadWin11Replacement-Repair' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $configKey -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $installDir) {
    # This script may be running from $installDir; delete what we can.
    Remove-Item (Join-Path $installDir 'npp-shim.exe') -Force -ErrorAction SilentlyContinue
    if ($PSScriptRoot -ne $installDir) { Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host 'Uninstalled.' -ForegroundColor Green
