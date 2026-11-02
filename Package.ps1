#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the release artifacts into dist\:
      NotepadWin11Replacement.zip   scripts + prebuilt npp-shim.exe (used by install.ps1 and the setup exe)
      NotepadRedirect-Setup.exe     self-contained installer (zip embedded)
      install.ps1                   one-line bootstrap (irm ... | iex)
      SHA256SUMS.txt
    Asset names carry no version, so .../releases/latest/download/<name> URLs always work.

.PARAMETER Version
    Release version, e.g. 1.1.0 or v1.1.0. Defaults to `git describe`, else 0.0.0-dev.
#>
[CmdletBinding()]
param([string]$Version)
$ErrorActionPreference = 'Stop'

if (-not $Version) {
    $Version = (git -C $PSScriptRoot describe --tags --always 2>$null)
    if (-not $Version) { $Version = '0.0.0-dev' }
}
$Version = $Version.TrimStart('v')
$numeric = if ($Version -match '^(\d+)\.(\d+)\.(\d+)') { "$($Matches[1]).$($Matches[2]).$($Matches[3]).0" } else { '0.0.0.0' }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$dist = Join-Path $PSScriptRoot 'dist'
$obj = Join-Path $PSScriptRoot 'obj'
Remove-Item $dist, $obj -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $dist, $obj | Out-Null

# 1. Shim
& (Join-Path $PSScriptRoot 'Build.ps1')

# 2. Zip payload
$stage = Join-Path $obj 'stage'
New-Item -ItemType Directory -Force (Join-Path $stage 'bin') | Out-Null
'Install.ps1', 'Uninstall.ps1', 'Repair.ps1', 'Test.ps1', 'Build.ps1', 'README.md' |
    ForEach-Object { Copy-Item (Join-Path $PSScriptRoot $_) $stage }
Copy-Item (Join-Path $PSScriptRoot 'src') $stage -Recurse
Copy-Item (Join-Path $PSScriptRoot 'bin\npp-shim.exe') (Join-Path $stage 'bin')
Set-Content (Join-Path $stage 'VERSION') $Version -NoNewline
$zip = Join-Path $dist 'NotepadWin11Replacement.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "Built $zip"

# 3. Setup exe with the zip embedded
$versionCs = Join-Path $obj 'BuildInfo.cs'
Set-Content $versionCs @"
[assembly: System.Reflection.AssemblyTitle("NotepadWin11Replacement setup")]
[assembly: System.Reflection.AssemblyVersion("$numeric")]
[assembly: System.Reflection.AssemblyInformationalVersion("$Version")]
static class BuildInfo { public const string Version = "$Version"; }
"@
$setup = Join-Path $dist 'NotepadRedirect-Setup.exe'
& $csc /nologo /target:exe /optimize+ /platform:anycpu "/out:$setup" `
    "/win32manifest:$(Join-Path $PSScriptRoot 'src\setup.manifest')" "/resource:$zip,payload.zip" `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    (Join-Path $PSScriptRoot 'src\Setup.cs') $versionCs
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Write-Host "Built $setup"

# 4. Bootstrap + checksums
Copy-Item (Join-Path $PSScriptRoot 'bootstrap\install.ps1') $dist
$sums = Get-ChildItem $dist -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
}
Set-Content (Join-Path $dist 'SHA256SUMS.txt') $sums -Encoding ascii
Get-Content (Join-Path $dist 'SHA256SUMS.txt')
