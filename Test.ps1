#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the Notepad -> Notepad++ redirect.

.PARAMETER Suite
    Parsing : runs bin\npp-shim.exe in dry-run mode against sample Notepad command lines (no admin, no install needed).
    Routes  : launches Notepad through every known entry point and reports which ones reach the shim.
    All     : both.

.NOTES
    The Routes suite opens test files in Notepad++ (new tabs) and closes any Store Notepad
    windows it causes. It never closes Notepad++.
#>
[CmdletBinding()]
param(
    [ValidateSet('Parsing', 'Routes', 'All')]
    [string]$Suite = 'All',
    [string]$ShimPath,
    [int]$SettleSeconds = 4
)
$ErrorActionPreference = 'Stop'

$logFile = Join-Path $env:LOCALAPPDATA 'NotepadWin11Replacement\shim.log'
$failures = 0

function Get-LogLines {
    if (Test-Path $logFile) { @(Get-Content $logFile -Encoding UTF8) } else { @() }
}

function Get-StoreNotepad {
    Get-Process -Name Notepad -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*\WindowsApps\*' }
}

function Write-Result([string]$Name, [bool]$Ok, [string]$Detail) {
    $tag = if ($Ok) { 'PASS' } else { 'FAIL'; $script:failures++ }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f $tag, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" }
}

if ($Suite -in 'Parsing', 'All') {
    if (-not $ShimPath) { $ShimPath = Join-Path $PSScriptRoot 'bin\npp-shim.exe' }
    if (-not (Test-Path $ShimPath)) { throw "Shim not found: $ShimPath (run Build.ps1)" }
    Write-Host "`n== Parsing (dry run of $ShimPath) ==" -ForegroundColor Cyan

    $cwd = (Get-Location).Path
    $cases = @(
        @{ Name = 'no file';                 Args = 'C:\Windows\System32\notepad.exe';                    Expect = '' }
        @{ Name = 'quoted exe, no file';     Args = '"C:\Windows\System32\notepad.exe"';                  Expect = '' }
        @{ Name = 'simple file';             Args = 'notepad.exe C:\tmp\a.txt';                           Expect = '"C:\tmp\a.txt"' }
        @{ Name = 'unquoted spaces';         Args = 'notepad C:\My Folder\my file.txt';                   Expect = '"C:\My Folder\my file.txt"' }
        @{ Name = 'quoted file';             Args = '"C:\Windows\notepad.exe" "C:\My Folder\x.log"';      Expect = '"C:\My Folder\x.log"' }
        @{ Name = 'Store app exe';           Args = '"C:\Program Files\WindowsApps\Microsoft.WindowsNotepad_1.0_x64__8wekyb3d8bbwe\Notepad\Notepad.exe" "C:\x y\z.ini"'; Expect = '"C:\x y\z.ini"' }
        @{ Name = '/A /W switches dropped';  Args = 'notepad.exe /A /W C:\tmp\b.txt';                     Expect = '"C:\tmp\b.txt"' }
        @{ Name = '/p -> quickPrint';        Args = 'notepad.exe /p C:\tmp\c.txt';                        Expect = '-quickPrint "C:\tmp\c.txt"' }
        @{ Name = '/pt -> quickPrint';       Args = 'notepad.exe /pt "C:\tmp\d.txt" "My Printer" drv port'; Expect = '-quickPrint "C:\tmp\d.txt"' }
        @{ Name = 'relative path made full'; Args = 'notepad.exe rel.txt';                                Expect = "`"$(Join-Path $cwd 'rel.txt')`"" }
    )

    $env:NPP_SHIM_DRYRUN = '1'
    try {
        foreach ($c in $cases) {
            $before = (Get-LogLines).Count
            Start-Process -FilePath $ShimPath -ArgumentList $c.Args -Wait -WorkingDirectory $cwd
            $line = (Get-LogLines) | Select-Object -Skip $before | Select-Object -Last 1
            $launch = if ($line -match "launch=(.*)$") { $Matches[1] } else { '<no log line>' }
            $args_ = ($launch -replace '^.*?notepad\+\+\.exe ?', '')
            Write-Result $c.Name ($args_ -ceq $c.Expect) "expected [$($c.Expect)] got [$args_]"
        }
    }
    finally { Remove-Item Env:NPP_SHIM_DRYRUN -ErrorAction SilentlyContinue }
}

if ($Suite -in 'Routes', 'All') {
    Write-Host "`n== Routes (live) ==" -ForegroundColor Cyan
    $dir = Join-Path $env:TEMP 'NotepadWin11Replacement-test'
    New-Item -ItemType Directory -Force $dir | Out-Null

    $aumid = (Get-StartApps | Where-Object AppID -like 'Microsoft.WindowsNotepad_*!App' | Select-Object -First 1).AppID
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\notepad.exe'

    $routes = [ordered]@{
        'A1 System32\notepad.exe'      = { param($f) Start-Process "$env:WINDIR\System32\notepad.exe" "`"$f`"" }
        'A2 SysWOW64\notepad.exe'      = { param($f) Start-Process "$env:WINDIR\SysWOW64\notepad.exe" "`"$f`"" }
        'A3 Windows\notepad.exe'       = { param($f) Start-Process "$env:WINDIR\notepad.exe" "`"$f`"" }
        'A4 "notepad" via PATH (cmd)'  = { param($f) Start-Process cmd.exe "/c start `"`" notepad `"$f`"" -WindowStyle Hidden }
        'B  App execution alias'       = { param($f) if (Test-Path $alias) { Start-Process $alias "`"$f`"" } else { 'skip: alias disabled' } }
        'C  Start menu (AUMID)'        = { param($f) if ($aumid) { Start-Process "shell:AppsFolder\$aumid" } else { 'skip: Store Notepad not installed' } }
        # With no handler, ShellExecute blocks on a modal "Open with" dialog.
        'D  .txt default association'  = { param($f) if ($txtHandled) { Start-Process $f } else { 'skip: no .txt handler (see Default app check)' } }
    }

    Add-Type -Namespace NpTest -Name Shell -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern int AssocQueryString(int flags, int str, string assoc, string extra, System.Text.StringBuilder outBuf, ref uint outLen);
'@ -ErrorAction SilentlyContinue
    $txtHandled = $true
    foreach ($ext in '.txt', '.log', '.ini') {
        $sb = New-Object System.Text.StringBuilder 1024; $len = [uint32]1024
        [void][NpTest.Shell]::AssocQueryString(0, 2 <# ASSOCSTR_EXECUTABLE #>, $ext, $null, $sb, [ref]$len)
        $exe = $sb.ToString()
        $ok = $exe -match '\\(notepad\+\+|notepad)\.exe$' -and $exe -notlike '*\WindowsApps\*'
        $hint = if ($ok) { $exe } elseif ($exe) { "resolves to $exe" } else { 'no handler (stale Store Notepad choice): set Notepad++ as default in Settings > Apps > Default apps' }
        Write-Result "Default app for $ext" $ok $hint
        if ($ext -eq '.txt' -and -not $exe) { $txtHandled = $false }
    }

    foreach ($name in $routes.Keys) {
        $file = Join-Path $dir ("{0}.txt" -f ($name -replace '[^\w]+', '_'))
        Set-Content $file "Route test: $name" -Encoding UTF8
        $before = (Get-LogLines).Count
        $storeBefore = @(Get-StoreNotepad | ForEach-Object Id)
        $pickerBefore = @(Get-Process OpenWith -ErrorAction SilentlyContinue | ForEach-Object Id)
        $nppBefore = @(Get-Process notepad++ -ErrorAction SilentlyContinue | ForEach-Object Id)

        $skip = & $routes[$name] $file
        if ($skip -is [string] -and $skip -like 'skip:*') {
            Write-Host "[SKIP] $name ($($skip.Substring(5).Trim()))" -ForegroundColor Yellow
            continue
        }
        Start-Sleep -Seconds $SettleSeconds

        $newLog = @(Get-LogLines | Select-Object -Skip $before)
        $newStore = @(Get-StoreNotepad | Where-Object { $_.Id -notin $storeBefore })
        $newStore | Stop-Process -Force -ErrorAction SilentlyContinue
        $newPicker = @(Get-Process OpenWith -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $pickerBefore })
        $newPicker | Stop-Process -Force -ErrorAction SilentlyContinue
        # A direct Notepad++ association never goes through the shim; a fresh Notepad++ process counts.
        $newNpp = @(Get-Process notepad++ -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $nppBefore })

        $ok = ($newLog.Count -gt 0 -or $newNpp.Count -gt 0) -and $newStore.Count -eq 0 -and $newPicker.Count -eq 0
        $detail = if ($newLog.Count) { ($newLog[-1] -split "`t" | Where-Object { $_ -like 'raw=*' -or $_ -like 'launch=*' }) -join ' | ' }
                  elseif ($newNpp.Count) { 'opened Notepad++ directly (association)' }
                  else { 'shim was not invoked' }
        if ($newStore.Count) { $detail += ' | Store Notepad opened (closed by test)' }
        if ($newPicker.Count) { $detail += ' | "Open with" picker shown: default app not set (closed by test)' }
        Write-Result $name $ok $detail
    }
}

Write-Host ''
if ($failures) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
