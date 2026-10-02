<#
.SYNOPSIS
  Builds the daily presence summary and files it into Infor HCM.
.DESCRIPTION
  Calls ..\Get-DailySummary.ps1 -AsJson into a temp file, then runs
  node file-hcm.js --summary <that file>. Any other arguments are passed
  straight through to file-hcm.js (--mode, --dry-run, --headless, --allow-future, ...).
.EXAMPLE
  .\run-hcm.ps1 --dry-run
  .\run-hcm.ps1 -From 2026-09-01 -To 2026-09-30 --mode draft
  .\run-hcm.ps1 --mode submit
#>
param(
    [string]$From,
    [string]$To
)
# Intentionally not [CmdletBinding()]: unbound args such as --dry-run land in $args.
$ErrorActionPreference = 'Stop'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js not found on PATH. Install Node 18+ from https://nodejs.org/'
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'node_modules\playwright'))) {
    throw "Dependencies missing. Run 'npm install' in $PSScriptRoot first."
}

$summaryScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-DailySummary.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("infor-summary-{0}.json" -f [guid]::NewGuid())

$summaryArgs = @{ AsJson = $true; JsonPath = $tmp }
if ($From) { $summaryArgs.From = [datetime]$From }
if ($To) { $summaryArgs.To = [datetime]$To }

try {
    & $summaryScript @summaryArgs | Out-Null
    if (-not (Test-Path -LiteralPath $tmp)) { throw "Get-DailySummary.ps1 did not produce $tmp" }

    & node (Join-Path $PSScriptRoot 'file-hcm.js') --summary $tmp @args
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
exit $code
