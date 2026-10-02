<#
.SYNOPSIS
  Adds (or with -Uninstall removes) "InforAutofill" shortcuts on the Desktop and in the Start menu.
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$places = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))

foreach ($dir in $places) {
    $lnk = Join-Path $dir 'InforAutofill.lnk'
    if ($Uninstall) {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk; Write-Host "Removed $lnk" }
        continue
    }
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $here 'InforAutofill.ps1')`""
    $s.WorkingDirectory = $here
    $s.Description = 'InforAutofill - status and filing'
    $s.Save()
    Write-Host "Created $lnk"
}
