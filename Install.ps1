#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Redirects Notepad (classic notepad.exe AND the Windows 11 Store Notepad) to Notepad++
    using the Image File Execution Options "Debugger" value.

.DESCRIPTION
    - Installs bin\npp-shim.exe to "%ProgramFiles%\NotepadWin11Replacement" (admin-only writable).
    - Backs up the IFEO\notepad.exe keys (64- and 32-bit views) to %ProgramData%\NotepadWin11Replacement.
    - Sets IFEO\notepad.exe\Debugger to the shim in both views. Windows' own AppExecutionAliasRedirect
      subkeys (0, 1, 2) are left untouched.
    IFEO matches by file name, so the value covers System32/SysWOW64/Windows notepad.exe and the
    Store app's ...\WindowsApps\Microsoft.WindowsNotepad_*\Notepad\Notepad.exe.

.PARAMETER NppPath
    Path to notepad++.exe. Defaults to the standard install location.

.PARAMETER RemoveStoreNotepad
    Also uninstalls the Store Notepad for all users and deprovisions it for new users.
    Use only if Test.ps1 -Suite Routes shows the Store app bypassing the redirect.
#>
[CmdletBinding()]
param(
    [string]$NppPath = (Join-Path $env:ProgramFiles 'Notepad++\notepad++.exe'),
    [switch]$RemoveStoreNotepad
)
$ErrorActionPreference = 'Stop'

$ifeoViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
)
$installDir = Join-Path $env:ProgramFiles 'NotepadWin11Replacement'
$dataDir = Join-Path $env:ProgramData 'NotepadWin11Replacement'
$configKey = 'HKLM:\SOFTWARE\NotepadWin11Replacement'
$shimTarget = Join-Path $installDir 'npp-shim.exe'
$debugger = "`"$shimTarget`""

if (-not (Test-Path $NppPath)) { throw "Notepad++ not found at '$NppPath'. Pass -NppPath." }

# 1. Build (if needed) and install the shim
$shimSource = Join-Path $PSScriptRoot 'bin\npp-shim.exe'
if (-not (Test-Path $shimSource)) { & (Join-Path $PSScriptRoot 'Build.ps1') }
New-Item -ItemType Directory -Force $installDir, $dataDir | Out-Null
Copy-Item $shimSource $shimTarget -Force
Copy-Item (Join-Path $PSScriptRoot 'Uninstall.ps1'), (Join-Path $PSScriptRoot 'Repair.ps1') $installDir -Force
Write-Host "Installed shim to $shimTarget"

# 2. Back up the IFEO keys once (the first backup is the pristine Windows state)
$backup = Join-Path $dataDir 'ifeo-notepad-original.reg'
if (-not (Test-Path $backup)) {
    $tmp = @()
    foreach ($view in $ifeoViews) {
        $f = Join-Path $env:TEMP ("ifeo-{0}.reg" -f [guid]::NewGuid())
        & reg.exe export ($view -replace '^HKLM:', 'HKLM') $f /y | Out-Null
        if ($LASTEXITCODE -eq 0) { $tmp += $f }
    }
    # Merge into one file (keep the header of the first export only)
    $merged = foreach ($f in $tmp) { Get-Content $f -Encoding Unicode | Select-Object -Skip ([int]($f -ne $tmp[0])) }
    Set-Content $backup $merged -Encoding Unicode
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Write-Host "Backed up original IFEO keys to $backup"
}

# 3. Remember config (and any third-party Debugger we are replacing) for the shim and uninstaller
New-Item -Path $configKey -Force | Out-Null
Set-ItemProperty $configKey -Name NotepadPlusPlusPath -Value $NppPath
foreach ($view in $ifeoViews) {
    $prev = (Get-ItemProperty $view -Name Debugger -ErrorAction SilentlyContinue).Debugger
    $name = if ($view -like '*WOW6432Node*') { 'PreviousDebugger32' } else { 'PreviousDebugger64' }
    if ($prev -and $prev -ne $debugger -and -not (Get-ItemProperty $configKey -Name $name -ErrorAction SilentlyContinue)) {
        Set-ItemProperty $configKey -Name $name -Value $prev
        Write-Warning "Replacing existing Debugger '$prev' (saved; Uninstall.ps1 restores it)."
    }
}

# 4. Set the Debugger value in both registry views
foreach ($view in $ifeoViews) {
    if (-not (Test-Path $view)) { New-Item -Path $view -Force | Out-Null }
    Set-ItemProperty $view -Name Debugger -Value $debugger -Type String
}
Write-Host "IFEO Debugger set to $debugger (64- and 32-bit views)" -ForegroundColor Green

# 5. Optional: remove the Store Notepad entirely
if ($RemoveStoreNotepad) {
    Get-AppxPackage -AllUsers Microsoft.WindowsNotepad | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.WindowsNotepad' |
        Remove-AppxProvisionedPackage -Online | Out-Null
    Set-ItemProperty $configKey -Name RemovedStoreNotepad -Value 1 -Type DWord
    Write-Host 'Removed Store Notepad (all users + provisioning).'
}

# 6. Self-repair after Windows / Store updates
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'Repair.ps1')`""
$triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Daily -At 3am))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'NotepadWin11Replacement-Repair' -Action $action -Trigger $triggers `
    -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Write-Host 'Registered scheduled task NotepadWin11Replacement-Repair (startup + daily).'

Write-Host @"

Next steps:
  * Run  .\Test.ps1 -Suite Routes  (non-elevated) to check every launch path.
  * If routes C/D still open the Store Notepad, either re-run with -RemoveStoreNotepad, or set
    Notepad++ as default for .txt/.log/.ini in Settings > Apps > Default apps, and turn off the
    'Notepad' entry in Settings > Apps > Advanced app settings > App execution aliases.
  * Shim log: %LOCALAPPDATA%\NotepadWin11Replacement\shim.log
"@
