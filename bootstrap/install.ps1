<#
.SYNOPSIS
    One-line installer for NotepadWin11Replacement (Notepad -> Notepad++ or another editor).

.DESCRIPTION
    Downloads the release zip from GitHub, checks it against the release's SHA256SUMS.txt, and runs
    Install.ps1 (or Uninstall.ps1) elevated. Asks for UAC consent if not already elevated.

    Default (no options):
        irm https://github.com/simonstdenis/notepadwin11replacement/releases/latest/download/install.ps1 | iex

    With options:
        & ([scriptblock]::Create((irm https://github.com/simonstdenis/notepadwin11replacement/releases/latest/download/install.ps1))) -Editor VSCode
        & ([scriptblock]::Create((irm https://github.com/simonstdenis/notepadwin11replacement/releases/latest/download/install.ps1))) -Uninstall

.PARAMETER Editor
    NotepadPlusPlus (default), VSCode, SublimeText, Notepad3 or Custom (with -EditorPath).
.PARAMETER KeepStoreNotepad
    Don't uninstall the Windows 11 Store Notepad (its Start menu entry then bypasses the redirect).
.PARAMETER Version
    Release tag to install, e.g. v1.1.0. Default: latest.
.PARAMETER PackagePath
    Use a local release zip instead of downloading (offline installs, testing).
#>
[CmdletBinding()]
param(
    [ValidateSet('NotepadPlusPlus', 'VSCode', 'SublimeText', 'Notepad3', 'Custom')]
    [string]$Editor = 'NotepadPlusPlus',
    [string]$EditorPath,
    [string]$EditorArgs,
    [string]$EditorPrintArgs,
    [switch]$KeepStoreNotepad,
    [switch]$Uninstall,
    [string]$Version = 'latest',
    [string]$Repo = 'simonstdenis/notepadwin11replacement',
    [string]$PackagePath
)

# The child block below has its own (empty) $PSBoundParameters; under `irm | iex` there may be none at all.
$bound = if ($PSBoundParameters) { $PSBoundParameters } else { @{} }

# Child scope, so `irm | iex` doesn't leave settings behind in the caller's session.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is very slow with the progress bar in PS 5.1
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $work = Join-Path ([IO.Path]::GetTempPath()) ("NotepadWin11Replacement-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $zip = Join-Path $work 'NotepadWin11Replacement.zip'
        if ($PackagePath) {
            Copy-Item -LiteralPath $PackagePath $zip
            Write-Host "Using local package $PackagePath"
        }
        else {
            $base = if ($Version -eq 'latest') { "https://github.com/$Repo/releases/latest/download" }
                    else { "https://github.com/$Repo/releases/download/$Version" }
            Write-Host "Downloading $base/NotepadWin11Replacement.zip"
            Invoke-WebRequest "$base/NotepadWin11Replacement.zip" -OutFile $zip -UseBasicParsing
            $sums = (Invoke-WebRequest "$base/SHA256SUMS.txt" -UseBasicParsing).Content
            if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
            $expected = ($sums -split "`r?`n" | Where-Object { $_ -match '\s\*?NotepadWin11Replacement\.zip$' } |
                         Select-Object -First 1) -replace '\s.*$', ''
            $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
            if (-not $expected -or $actual -ne $expected.ToUpperInvariant()) {
                throw "Checksum mismatch for NotepadWin11Replacement.zip (expected '$expected', got '$actual')."
            }
            Write-Host 'Checksum OK.'
        }
        Expand-Archive $zip -DestinationPath (Join-Path $work 'pkg')
        $pkg = Join-Path $work 'pkg'

        # Build the elevated command with single-quoted literals (no expansion, ' doubled).
        function Q([string]$s) { "'" + $s.Replace("'", "''") + "'" }
        if ($Uninstall) { $cmd = "& $(Q (Join-Path $pkg 'Uninstall.ps1'))" }
        else {
            $cmd = "& $(Q (Join-Path $pkg 'Install.ps1')) -Editor $(Q $Editor)"
            if ($EditorPath) { $cmd += " -EditorPath $(Q $EditorPath)" }
            if ($bound.ContainsKey('EditorArgs')) { $cmd += " -EditorArgs $(Q $EditorArgs)" }
            if ($bound.ContainsKey('EditorPrintArgs')) { $cmd += " -EditorPrintArgs $(Q $EditorPrintArgs)" }
            if (-not $KeepStoreNotepad) { $cmd += ' -RemoveStoreNotepad' }
        }

        $log = Join-Path $work 'install.log'
        $script = "`$ErrorActionPreference = 'Stop'; try { $cmd *> $(Q $log); exit 0 } " +
                  "catch { `$_ | Out-String | Add-Content $(Q $log); exit 1 }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { Write-Host 'Requesting administrator rights (UAC)...' }
        $startArgs = @{ FilePath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"; ArgumentList = $psArgs
                        Wait = $true; PassThru = $true; WindowStyle = 'Hidden' }
        if (-not $isAdmin) { $startArgs.Verb = 'RunAs' }
        $p = Start-Process @startArgs

        if (Test-Path $log) { Get-Content $log | Write-Host }
        if ($p.ExitCode -ne 0) { throw "Setup failed (exit code $($p.ExitCode))." }
        Write-Host 'Done.' -ForegroundColor Green
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
