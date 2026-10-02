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

# state keeps xmWeeksSkipped (weeks reported once as past the cap)
$st3 = Read-AutoFileState -Path (Join-Path $tmp 'state.json') -Today (D '2026-10-08')
Assert-Equal '' ($st3.xmWeeksSkipped -join ',') 'old state file without xmWeeksSkipped reads as empty'
$st3.xmWeeksSkipped = @('2026-09-06')
Save-AutoFileState -State $st3 -Path (Join-Path $tmp 'state.json')
$st4 = Read-AutoFileState -Path (Join-Path $tmp 'state.json') -Today (D '2026-10-08')
Assert-Equal '2026-09-06' ($st4.xmWeeksSkipped -join ',') 'xmWeeksSkipped round trip'

# -Force resets only the HCM coverage
$sf = S '2026-09-01' '2026-10-06' @('2026-09-27')
Reset-AutoFileStateForForce -State $sf -Today (D '2026-10-07')
Assert-Equal '2026-09-22' $sf.hcmCoveredThrough '-Force: HCM coverage goes back 15 days'
Assert-Equal '2026-09-27' ($sf.xmWeeksDone -join ',') '-Force keeps xmWeeksDone'

# window caps never drop days silently
$sk = Get-SkippedHcmDays -State (S '2026-01-01' '2026-09-10' @()) -Today (D '2026-10-07')
Assert-Equal '2026-09-11..2026-09-22' ("{0}..{1}" -f (ConvertTo-IsoDate $sk.From), (ConvertTo-IsoDate $sk.To)) 'HCM days past the 14-day cap are listed'
Assert-Equal '' (Get-SkippedHcmDays -State (S '2026-01-01' '2026-09-22' @()) -Today (D '2026-10-07')) 'nothing skipped when within the cap'
$sw = Get-SkippedXmWeeks -State (S '2026-09-01' '2026-10-11' @('2026-09-06')) -Today (D '2026-10-12')
Assert-Equal '2026-08-30,2026-09-13,2026-09-20' (($sw | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'XM weeks past the 2-week cap, from the week of startedOn, not done'
$st5 = S '2026-09-01' '2026-10-11' @('2026-09-06')
$st5 | Add-Member -NotePropertyName xmWeeksSkipped -NotePropertyValue @('2026-08-30')
$sw = Get-SkippedXmWeeks -State $st5 -Today (D '2026-10-12')
Assert-Equal '2026-09-13,2026-09-20' (($sw | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'already reported weeks are not reported again'
$sw = Get-SkippedXmWeeks -State (S '2026-10-07' '2026-10-11' @()) -Today (D '2026-10-12')
Assert-Equal '' (($sw | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'no skipped weeks right after the first run'

# filer output scanning
$hcmOut = @(
    'WARNING 2026-10-05: office reading in the presence log; override "wfh" ignored, not filed (skipped-office-reading)',
    '  2026-10-06 wfh (248): filed - calendar shows "Telecommuting: Full Day"',
    '  2026-10-07 wfh (248): filed-unverified - dialog closed but no entry visible in the cell yet',
    'UNRECOGNISED 2026-10-08: Official Business: Full Day',
    '2026-10-05  wfh       skipped-office-reading')
$f = Get-HcmFilerFindings -Output $hcmOut
Assert-Equal '2026-10-05=wfh' (($f.OfficeReading | ForEach-Object { "$($_.Date)=$($_.Override)" }) -join ',') 'HCM office-reading warnings found once'
Assert-Equal '2026-10-07' ($f.Unverified -join ',') 'HCM filed-unverified found'
Assert-Equal '2026-10-06' ($f.Filed -join ',') 'HCM filed (verified only)'
Assert-Equal '2026-10-08=Official Business: Full Day' (($f.Unrecognised | ForEach-Object { "$($_.Date)=$($_.Text)" }) -join ',') 'HCM unrecognised entries found'
Assert-Equal 'True' (Test-XmSubmitUnconfirmed -Output @('[xm] Submit clicked', '[xm] WARNING: Submit clicked but no "Submitted" confirmation seen; check XM.')) 'XM unconfirmed submit detected'
Assert-Equal 'False' (Test-XmSubmitUnconfirmed -Output @('[xm] Submit clicked', '[xm] submitted')) 'XM confirmed submit'

# weeks blocked by unrecognised HCM entries (Sun-Sat), unless overrides.json explains the date
Assert-Equal '2026-10-08' ((Get-WeekBlockers -Week (D '2026-10-04') -Dates @('2026-10-08', '2026-10-12') -Overrides @{}) -join ',') 'unrecognised date inside the week blocks it'
Assert-Equal '' ((Get-WeekBlockers -Week (D '2026-10-04') -Dates @('2026-10-08') -Overrides @{ '2026-10-08' = 'wfh' }) -join ',') 'override explains an unrecognised date'
Assert-Equal '' ((Get-WeekBlockers -Week (D '2026-10-04') -Dates @('2026-10-03', '2026-10-11') -Overrides @{}) -join ',') 'dates outside the week do not block it'

Remove-Item -Recurse -Force $tmp
if ($script:failures) { Write-Host "$script:failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All auto-file logic tests passed' -ForegroundColor Green
