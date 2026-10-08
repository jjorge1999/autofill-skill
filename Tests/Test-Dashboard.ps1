# Dashboard view-model logic (no WPF, no network). Run: powershell -File .\Tests\Test-Dashboard.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'AutoFile.Common.ps1')
. (Join-Path $root 'Dashboard.Data.ps1')

$script:failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ("$Expected" -ceq "$Actual") { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  expected '$Expected' got '$Actual'" -ForegroundColor Red; $script:failures++ }
}
function D([string]$s) { ConvertFrom-IsoDate $s }
$dot = [char]0x00B7

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("dash-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

# week dates: Fri 2026-10-02 -> Mon 09-28 .. Fri 10-02; Sun 10-04 -> next week
Assert-Equal '2026-09-28,2026-09-29,2026-09-30,2026-10-01,2026-10-02' ((Get-WeekDates -Today (D '2026-10-02') | ForEach-Object { ConvertTo-IsoDate $_ }) -join ',') 'week of a Friday'
Assert-Equal '2026-10-05' (ConvertTo-IsoDate (Get-WeekDates -Today (D '2026-10-04'))[0]) 'Sunday shows the coming week'

# run logs: empty and broken files are skipped
$logs = Join-Path $tmp 'logs'; New-Item -ItemType Directory -Path $logs | Out-Null
Set-Content -LiteralPath (Join-Path $logs 'run-1.json') -Value '' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $logs 'run-2.json') -Value '{ "broken": ' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $logs 'run-3.json') -Value '{ "dryRun": false, "results": [ { "date": "2026-09-28", "planCode": "248", "result": "filed" } ] }' -Encoding UTF8
Assert-Equal 1 (@(Read-RunLogs -Dir $logs).Count) 'unreadable run logs skipped'
Assert-Equal 0 (@(Read-RunLogs -Dir (Join-Path $tmp 'missing')).Count) 'missing log dir -> empty'

# HCM filed dates
$hcmLogs = @(
    ('{ "dryRun": false, "results": [ {"date":"2026-09-28","planCode":"248","result":"filed"}, {"date":"2026-09-29","planCode":"248","result":"skipped-existing","detail":"Telecommuting: Full Day"}, {"date":"2026-09-30","planCode":"248","result":"skipped-existing","detail":"Vacation: Full Day"}, {"date":"2026-10-01","planCode":"248","result":"filed-unverified"} ] }' | ConvertFrom-Json),
    ('{ "dryRun": true, "results": [ {"date":"2026-10-02","planCode":"248","result":"filed"} ] }' | ConvertFrom-Json))
$f = Get-HcmFiledDates -Logs $hcmLogs
Assert-Equal '2026-09-28,2026-09-29' (($f.Keys | Sort-Object) -join ',') 'HCM filed = filed or existing Telecommuting, real runs only'

# XM week status
$xmLogs = @(
    ('{ "week": {"start":"2026-09-27"}, "options": {"dryRun": false}, "result": "error", "error": {"code":"EXISTS"} }' | ConvertFrom-Json),
    ('{ "week": {"start":"2026-10-04"}, "options": {"dryRun": false}, "result": "saved-draft", "expectedTotal": 45 }' | ConvertFrom-Json),
    ('{ "week": {"start":"2026-10-04"}, "options": {"dryRun": true}, "result": "dry-run", "expectedTotal": 44 }' | ConvertFrom-Json),
    ('{ "week": {"start":"2026-10-11"}, "options": {"dryRun": false}, "result": "submitted", "expectedTotal": 44 }' | ConvertFrom-Json),
    ('{ "week": {"start":"2026-10-18"}, "options": {"dryRun": false}, "result": "error", "error": {"code":"LOGIN_NEEDED"} }' | ConvertFrom-Json))
$state = [pscustomobject]@{ xmWeeksDone = @('2026-09-27') }
Assert-Equal 'already in XM' (Get-XmWeekStatus -Logs $xmLogs -WeekStart '2026-09-27' -State $state).Text 'XM exists'
Assert-Equal 'True' (Get-XmWeekStatus -Logs $xmLogs -WeekStart '2026-09-27' -State $state).Done 'XM done flag from state'
Assert-Equal "45.00 h $dot draft saved" (Get-XmWeekStatus -Logs $xmLogs -WeekStart '2026-10-04').Text 'XM draft; dry runs ignored'
Assert-Equal "44.00 h $dot submitted" (Get-XmWeekStatus -Logs $xmLogs -WeekStart '2026-10-11').Text 'XM submitted'
Assert-Equal 'last run failed (LOGIN_NEEDED)' (Get-XmWeekStatus -Logs $xmLogs -WeekStart '2026-10-18').Text 'XM failure code'
Assert-Equal 'not filed yet' (Get-XmWeekStatus -Logs $xmLogs -WeekStart '2026-10-25').Text 'XM nothing yet'

# last reading time
$csv = Join-Path $tmp 'presence.csv'
@('"timestamp","date","status"', '"2026-10-02T10:00:01+08:00","2026-10-02","office"', '"2026-10-02T16:00:02+08:00","2026-10-02","office"', '"2026-10-01T13:00:00+08:00","2026-10-01","remote"') | Set-Content -LiteralPath $csv -Encoding UTF8
Assert-Equal '16:00' (Get-LastReadingTime -PresencePath $csv -Date (D '2026-10-02')) 'last reading of the day'
Assert-Equal '' (Get-LastReadingTime -PresencePath $csv -Date (D '2026-10-03')) 'no reading -> null'
Assert-Equal '' (Get-LastReadingTime -PresencePath (Join-Path $tmp 'nope.csv') -Date (D '2026-10-02')) 'missing csv -> null'

# day status normalisation
Assert-Equal 'leave' (ConvertTo-DayStatus 'Vacation') 'vacation -> leave'
Assert-Equal 'unknown' (ConvertTo-DayStatus 'skip') 'skip -> unknown'

# model
$week = Get-WeekDates -Today (D '2026-10-01')
$summary = @(
    [pscustomobject]@{ date = '2026-09-28'; status = 'wfh' },
    [pscustomobject]@{ date = '2026-09-29'; status = 'unknown' },
    [pscustomobject]@{ date = '2026-09-30'; status = 'office' },
    [pscustomobject]@{ date = '2026-10-01'; status = 'office' })
$ov = @{ '2026-09-29' = 'sick'; '2026-09-30' = 'wfh'; '2026-10-02' = 'leave' }
$m = New-DashboardModel -Today (D '2026-10-01') -WeekDates $week -Summary $summary -Overrides $ov -HcmFiled @{ '2026-09-28' = $true } -Xm @{ Text = 'not filed yet'; Done = $false } -LastReading '13:00'
Assert-Equal 'wfh,leave,office,office,leave' (($m.Days | ForEach-Object { $_.Status }) -join ',') 'day statuses (office reading beats wfh override)'
Assert-Equal 'reading,override,reading,reading,override' (($m.Days | ForEach-Object { $_.Source }) -join ',') 'day sources'
Assert-Equal 'True' ([bool]($m.Days[2].Note -match 'office reading')) 'note when wfh override is ignored'
Assert-Equal 'True,False,False,False,False' (($m.Days | ForEach-Object { $_.HcmFiled }) -join ',') 'HCM marks'
Assert-Equal 'office' $m.TodayStatus 'today status'
Assert-Equal "Today $dot Thu 1 Oct" $m.TodayLabel 'today label'
Assert-Equal 'True' $m.Days[4].IsFuture 'Friday is future on Thursday'
$mw = New-DashboardModel -Today (D '2026-10-03') -WeekDates (Get-WeekDates -Today (D '2026-10-03')) -Summary @() -Overrides @{} -HcmFiled @{} -Xm @{ Text = 'x'; Done = $false } -LastReading $null
Assert-Equal 'weekend' $mw.TodayStatus 'Saturday -> weekend'

# overrides set / clear
$ovPath = Join-Path $tmp 'overrides.json'
Set-Content -LiteralPath $ovPath -Value '{ "2026-09-28": "wfh" }' -Encoding UTF8
Set-DayOverride -Path $ovPath -Date '2026-10-12' -Value 'leave'
Set-DayOverride -Path $ovPath -Date '2026-09-28' -Value 'clear'
$map = Read-JsonMap -Path $ovPath
Assert-Equal '2026-10-12=leave' ((($map.Keys | Sort-Object) | ForEach-Object { "$_=$($map[$_])" }) -join ',') 'override set and clear'
Set-DayOverride -Path $ovPath -Date '2026-10-12' -Value 'clear'
Assert-Equal 0 (Read-JsonMap -Path $ovPath).Count 'clearing the last override leaves an empty map'

# file time
Assert-Equal 'True' (Test-FileTime '16:30') 'valid time'
Assert-Equal 'False' (Test-FileTime '9:00') 'needs two-digit hour'
Assert-Equal 'False' (Test-FileTime '24:00') 'hour range'
$cfgPath = Join-Path $tmp 'config.json'
Set-Content -LiteralPath $cfgPath -Value '{ "office_ssids": [ "corp" ], "check_times": [ "10:00", "16:00" ], "file_time": "16:30" }' -Encoding UTF8
Set-ConfigFileTime -ConfigPath $cfgPath -Time '17:15'
$cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
Assert-Equal '17:15' $cfg.file_time 'file_time updated'
Assert-Equal 'corp' (@($cfg.office_ssids) -join ',') 'other settings kept (one-element array stays an array)'
$threw = $false; try { Set-ConfigFileTime -ConfigPath $cfgPath -Time 'soon' } catch { $threw = $true }
Assert-Equal 'True' $threw 'invalid time rejected'

Remove-Item -Recurse -Force $tmp
if ($script:failures) { Write-Host "$script:failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All dashboard tests passed' -ForegroundColor Green
