# Pure orchestration logic (no browser, no network). Run: powershell -File .\Tests\Test-AutoFile.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'AutoFile.Common.ps1')

$script:failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ("$Expected" -ceq "$Actual") { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  expected '$Expected' got '$Actual'" -ForegroundColor Red; $script:failures++ }
}
function D([string]$s) { ConvertFrom-IsoDate $s }
function S($started, $covered, $done) { [pscustomobject]@{ startedOn = $started; hcmCoveredThrough = $covered; xmWeeksDone = @($done) } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("autofile-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

# state round trip; a new state starts today and is covered through yesterday
$st = Read-AutoFileState -Path (Join-Path $tmp 'state.json') -Today (D '2026-10-07')
Assert-Equal '2026-10-07' $st.startedOn 'new state startedOn'
Assert-Equal '2026-10-06' $st.hcmCoveredThrough 'new state covered through yesterday'
$st.xmWeeksDone = @('2026-10-04')
Save-AutoFileState -State $st -Path (Join-Path $tmp 'state.json')
$st2 = Read-AutoFileState -Path (Join-Path $tmp 'state.json') -Today (D '2026-10-08')
Assert-Equal '2026-10-04' ($st2.xmWeeksDone -join ',') 'state round trip keeps a one-element array'

# HCM range
$r = Get-HcmRange -State (S '2026-09-01' '2026-10-05' @()) -Today (D '2026-10-07')
Assert-Equal '2026-10-06..2026-10-07' ("{0}..{1}" -f (ConvertTo-IsoDate $r.From), (ConvertTo-IsoDate $r.To)) 'range starts after covered'
$r = Get-HcmRange -State (S '2026-01-01' '2026-01-01' @()) -Today (D '2026-10-07')
Assert-Equal '2026-09-23' (ConvertTo-IsoDate $r.From) 'range capped at 14 days back'
Assert-Equal '' (Get-HcmRange -State (S '2026-10-01' '2026-10-07' @()) -Today (D '2026-10-07')) 'nothing due when covered through today'

# XM weeks due (2026-10-09 is a Friday; week of 2026-10-04)
$w = Get-XmWeeksDue -State (S '2026-09-01' '2026-10-08' @('2026-09-20', '2026-09-27')) -Today (D '2026-10-09')
Assert-Equal '2026-10-04' (($w | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'Friday: current week due'
$w = Get-XmWeeksDue -State (S '2026-09-01' '2026-10-06' @('2026-09-20', '2026-09-27')) -Today (D '2026-10-07')
Assert-Equal '' (($w | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'Wednesday: nothing due when last week done'
$w = Get-XmWeeksDue -State (S '2026-09-01' '2026-10-11' @('2026-09-27')) -Today (D '2026-10-12')
Assert-Equal '2026-10-04' (($w | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'missed Friday caught up on Monday'
$w = Get-XmWeeksDue -State (S '2026-10-07' '2026-10-11' @()) -Today (D '2026-10-12')
Assert-Equal '2026-10-04' (($w | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'week of first run counts, earlier weeks do not'
$w = Get-XmWeeksDue -State (S '2026-10-07' '2026-10-09' @('2026-10-04')) -Today (D '2026-10-10')
Assert-Equal '' (($w | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'Saturday: done week not repeated'

# pending days
$summary = @(
    [pscustomobject]@{ date = '2026-10-05'; status = 'wfh' },
    [pscustomobject]@{ date = '2026-10-06'; status = 'unknown' },
    [pscustomobject]@{ date = '2026-10-07'; status = 'unknown' },
    [pscustomobject]@{ date = '2026-10-08'; status = 'unknown' },
    [pscustomobject]@{ date = '2026-10-09'; status = 'office' })
$p = Get-PendingDays -Summary $summary -Overrides @{ '2026-10-07' = 'wfh' } -Leave @{ '2026-10-08' = 'vacation' }
Assert-Equal '2026-10-06' ($p -join ',') 'pending = unknown minus overrides and leave'

# covered-through
$range = @{ From = (D '2026-10-05'); To = (D '2026-10-09') }
Assert-Equal '2026-10-09' (ConvertTo-IsoDate (Get-CoveredThrough -Range $range -Pending @())) 'no pending -> covered to end'
Assert-Equal '2026-10-05' (ConvertTo-IsoDate (Get-CoveredThrough -Range $range -Pending @('2026-10-06', '2026-10-08'))) 'stops before first pending'

# overrides merge
$ov = Join-Path $tmp 'overrides.json'
Set-Content -LiteralPath $ov -Value '{ "2026-09-28": "wfh" }' -Encoding UTF8
Merge-OverrideAnswers -Path $ov -Answers @{ '2026-10-06' = 'office'; '2026-10-01' = 'leave' }
$m = Read-JsonMap -Path $ov
Assert-Equal '2026-09-28=wfh,2026-10-01=leave,2026-10-06=office' ((($m.Keys | Sort-Object) | ForEach-Object { "$_=$($m[$_])" }) -join ',') 'overrides merged'

Remove-Item -Recurse -Force $tmp
if ($script:failures) { Write-Host "$script:failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All auto-file logic tests passed' -ForegroundColor Green
