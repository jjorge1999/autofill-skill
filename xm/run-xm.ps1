<#
.SYNOPSIS
  Builds the presence summary for one week and fills the Infor XM timesheet.
.DESCRIPTION
  Calls ..\Get-DailySummary.ps1 -AsJson for the Sun-Sat week containing -Week
  (default: this week) into a temp file, then runs
  node file-xm.js --summary <that file> --week <date>. Any other arguments are
  passed straight through to file-xm.js (--mode, --dry-run, --headless, ...).
.EXAMPLE
  .\run-xm.ps1 --dry-run
  .\run-xm.ps1 -Week 2026-09-21 --mode draft
  .\run-xm.ps1 --mode submit
#>
# No param() block: declared parameters bind positionally, so '--mode draft' would land in -Week.
# Parse -Week by name and pass everything else (--mode, --dry-run, ...) through to node.
$ErrorActionPreference = 'Stop'
$Week = $null; $passThru = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ([string]$args[$i]) {
        '^-Week$' { $Week = $args[++$i]; break }
        default { $passThru += $args[$i] }
    }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js not found on PATH. Install Node 18+ from https://nodejs.org/'
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'node_modules\playwright'))) {
    throw "Dependencies missing. Run 'npm install' in $PSScriptRoot first."
}

$inv = [Globalization.CultureInfo]::InvariantCulture
$ref = if ($Week) { [datetime]::ParseExact($Week, 'yyyy-MM-dd', $inv) } else { (Get-Date).Date }
$start = $ref.AddDays(-[int]$ref.DayOfWeek)
$end = $start.AddDays(6)
$weekArg = $ref.ToString('yyyy-MM-dd', $inv)

$summaryScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-DailySummary.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("infor-xm-summary-{0}.json" -f [guid]::NewGuid())

try {
    & $summaryScript -From $start -To $end -AsJson -JsonPath $tmp | Out-Null
    if (-not (Test-Path -LiteralPath $tmp)) { throw "Get-DailySummary.ps1 did not produce $tmp" }

    & node (Join-Path $PSScriptRoot 'file-xm.js') --summary $tmp --week $weekArg @passThru
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
exit $code
