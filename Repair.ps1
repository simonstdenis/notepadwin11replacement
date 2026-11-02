#Requires -Version 5.1
<#
.SYNOPSIS
    Re-applies the Notepad -> Notepad++ redirect after Windows/Store updates.
    Registered by Install.ps1 as the "NotepadWin11Replacement-Repair" scheduled task (SYSTEM, at startup + daily).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$configKey = 'HKLM:\SOFTWARE\NotepadWin11Replacement'
$config = Get-ItemProperty $configKey -ErrorAction SilentlyContinue
if (-not $config) { return } # not installed

function Write-RepairLog([string]$Message) {
    $log = Join-Path $env:ProgramData 'NotepadWin11Replacement\repair.log'
    Add-Content $log ("{0:o}  {1}" -f (Get-Date), $Message)
}

$shim = Join-Path $env:ProgramFiles 'NotepadWin11Replacement\npp-shim.exe'
$debugger = "`"$shim`""
$ifeoViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
)
foreach ($view in $ifeoViews) {
    if (-not (Test-Path $view)) { New-Item -Path $view -Force | Out-Null }
    if ((Get-ItemProperty $view -Name Debugger -ErrorAction SilentlyContinue).Debugger -ne $debugger) {
        Set-ItemProperty $view -Name Debugger -Value $debugger -Type String
        Write-RepairLog "Re-applied IFEO Debugger on $view"
    }
}

if ($config.RemovedStoreNotepad -eq 1) {
    $pkgs = @(Get-AppxPackage -AllUsers Microsoft.WindowsNotepad)
    if ($pkgs.Count) {
        $pkgs | Remove-AppxPackage -AllUsers
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.WindowsNotepad' |
            Remove-AppxProvisionedPackage -Online | Out-Null
        Write-RepairLog 'Store Notepad reappeared and was removed again.'
    }
}
