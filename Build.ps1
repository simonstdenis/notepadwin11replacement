#Requires -Version 5.1
<#
.SYNOPSIS
    Compiles src\NppShim.cs into bin\npp-shim.exe using the in-box .NET Framework compiler.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }

$bin = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$out = Join-Path $bin 'npp-shim.exe'

& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$out" `
    /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'src\NppShim.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Write-Host "Built $out"
