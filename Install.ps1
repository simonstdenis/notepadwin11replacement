#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Redirects Notepad (classic notepad.exe AND the Windows 11 Store Notepad) to Notepad++ or another
    editor, using the Image File Execution Options "Debugger" value.

.DESCRIPTION
    - Installs bin\npp-shim.exe to "%ProgramFiles%\NotepadWin11Replacement" (admin-only writable).
    - Backs up the IFEO\notepad.exe keys (64- and 32-bit views) to %ProgramData%\NotepadWin11Replacement.
    - Sets IFEO\notepad.exe\Debugger to the shim in both views. Windows' own AppExecutionAliasRedirect
      subkeys (0, 1, 2) are left untouched.
    - Stores the chosen editor in HKLM\SOFTWARE\NotepadWin11Replacement (read by the shim on every launch).
    IFEO matches by file name, so the value covers System32/SysWOW64/Windows notepad.exe and the
    Store app's ...\WindowsApps\Microsoft.WindowsNotepad_*\Notepad\Notepad.exe.
    Re-run with a different -Editor to switch editors; everything else is idempotent.

.PARAMETER Editor
    NotepadPlusPlus (default), VSCode, SublimeText, Notepad3, or Custom (requires -EditorPath).
    Presets look for the editor in its usual install folders.

.PARAMETER EditorPath
    Full path to the editor executable. Overrides the preset's search. Alias: -NppPath.

.PARAMETER EditorArgs
    Argument template used when a file is opened. {file} becomes the quoted full path. Default from the preset, else "{file}".

.PARAMETER EditorPrintArgs
    Argument template for Notepad's /p and /pt (print). Default from the preset; when empty the file is just opened.

.PARAMETER RemoveStoreNotepad
    Also uninstalls the Store Notepad for all users and deprovisions it for new users.
    Use only if Test.ps1 -Suite Routes shows the Store app bypassing the redirect.

.EXAMPLE
    .\Install.ps1 -Editor VSCode
.EXAMPLE
    .\Install.ps1 -Editor Custom -EditorPath 'C:\Tools\micro\micro.exe' -EditorArgs '{file}'
#>
[CmdletBinding()]
param(
    [ValidateSet('NotepadPlusPlus', 'VSCode', 'SublimeText', 'Notepad3', 'Custom')]
    [string]$Editor = 'NotepadPlusPlus',
    [Alias('NppPath')]
    [string]$EditorPath,
    [string]$EditorArgs,
    [string]$EditorPrintArgs,
    [switch]$RemoveStoreNotepad
)$ErrorActionPreference = 'Stop'

$ifeoViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
)
$installDir = Join-Path $env:ProgramFiles 'NotepadWin11Replacement'
$dataDir = Join-Path $env:ProgramData 'NotepadWin11Replacement'
$configKey = 'HKLM:\SOFTWARE\NotepadWin11Replacement'
$shimTarget = Join-Path $installDir 'npp-shim.exe'
$debugger = "`"$shimTarget`""

# 0. Resolve the editor
$presets = @{
    NotepadPlusPlus = @{ Name = 'Notepad++'; Args = '{file}'; PrintArgs = '-quickPrint {file}'
                         Paths = @("$env:ProgramFiles\Notepad++\notepad++.exe", "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe") }
    VSCode          = @{ Name = 'Visual Studio Code'; Args = '{file}'; PrintArgs = ''
                         Paths = @("$env:ProgramFiles\Microsoft VS Code\Code.exe", "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe") }
    SublimeText     = @{ Name = 'Sublime Text'; Args = '{file}'; PrintArgs = ''
                         Paths = @("$env:ProgramFiles\Sublime Text\sublime_text.exe", "$env:ProgramFiles\Sublime Text 3\sublime_text.exe") }
    Notepad3        = @{ Name = 'Notepad3'; Args = '{file}'; PrintArgs = '/p {file}'
                         Paths = @("$env:ProgramFiles\Notepad3\Notepad3.exe", "${env:ProgramFiles(x86)}\Notepad3\Notepad3.exe") }
    Custom          = @{ Name = 'Custom editor'; Args = '{file}'; PrintArgs = ''; Paths = @() }
}
$preset = $presets[$Editor]
if (-not $EditorPath) {
    $EditorPath = $preset.Paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $EditorPath) {
        if ($Editor -eq 'Custom') { throw '-Editor Custom requires -EditorPath.' }
        throw "$($preset.Name) not found in: $($preset.Paths -join '; '). Pass -EditorPath."
    }
}
if (-not (Test-Path $EditorPath -PathType Leaf)) { throw "Editor not found at '$EditorPath'." }
$EditorPath = (Resolve-Path $EditorPath).Path
if ((Split-Path $EditorPath -Leaf) -eq 'notepad.exe') {
    throw 'The editor cannot be a notepad.exe: the IFEO redirect would send it straight back to the shim.'
}
if (-not $PSBoundParameters.ContainsKey('EditorArgs')) { $EditorArgs = $preset.Args }
if (-not $PSBoundParameters.ContainsKey('EditorPrintArgs')) { $EditorPrintArgs = $preset.PrintArgs }
if ($EditorArgs -notlike '*{file}*') { Write-Warning "-EditorArgs has no {file} placeholder; the file name will not be passed." }
if ($EditorPath -like "$env:SystemDrive\Users\*") {
    Write-Warning "$EditorPath is a per-user install; other users on this PC will get an 'editor not found' error."
}

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
# Not New-Item -Force on an existing key: that recreates it and drops RemovedStoreNotepad / PreviousDebugger*.
if (-not (Test-Path $configKey)) { New-Item -Path $configKey | Out-Null }
Set-ItemProperty $configKey -Name EditorName -Value $preset.Name
Set-ItemProperty $configKey -Name EditorPath -Value $EditorPath
Set-ItemProperty $configKey -Name EditorArgs -Value $EditorArgs
Set-ItemProperty $configKey -Name EditorPrintArgs -Value ([string]$EditorPrintArgs)
Remove-ItemProperty $configKey -Name NotepadPlusPlusPath -ErrorAction SilentlyContinue # pre-1.1 setting
Write-Host "Editor: $($preset.Name) ($EditorPath $EditorArgs)"
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
    the editor as default for .txt/.log/.ini in Settings > Apps > Default apps, and turn off the
    'Notepad' entry in Settings > Apps > Advanced app settings > App execution aliases.
  * Shim log: %LOCALAPPDATA%\NotepadWin11Replacement\shim.log
"@
