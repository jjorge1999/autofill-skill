<#
.SYNOPSIS
  Stores the Tempo API token encrypted for the current Windows user (DPAPI).
.DESCRIPTION
  Writes %LOCALAPPDATA%\InforAutofill\tempo-token.dpapi. Only this Windows account on this PC can decrypt it;
  run-tempo.ps1 does so for each run. The token is never printed.
.PARAMETER From
  A text file whose first non-empty line is the token. Without it, the token is asked for (input hidden).
.EXAMPLE
  .\Save-TempoToken.ps1
  .\Save-TempoToken.ps1 -From C:\path\token.txt
#>
[CmdletBinding()]
param([string]$From)
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:LOCALAPPDATA 'InforAutofill'
$target = Join-Path $dir 'tempo-token.dpapi'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

if ($From) {
    $line = @(Get-Content -LiteralPath $From | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if (-not $line) { throw "$From has no token in it" }
    $secure = ConvertTo-SecureString -String $line -AsPlainText -Force
    Remove-Variable line
} else {
    $secure = Read-Host -Prompt 'Tempo API token' -AsSecureString
    if ($secure.Length -eq 0) { throw 'No token entered' }
}
[IO.File]::WriteAllText($target, (ConvertFrom-SecureString -SecureString $secure))
Write-Host "Saved the Tempo token ($($secure.Length) characters, encrypted for $env:USERNAME) to $target"
