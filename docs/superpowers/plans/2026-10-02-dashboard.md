# InforAutofill Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small, modern, minimalist WPF window that shows InforAutofill's status and this week, lets the user mark days, run Preview / File now, and switch the schedule — as a front end over the existing scripts.

**Architecture:** `Dashboard.Data.ps1` holds pure, tested functions that turn the presence summary, `hcm/overrides.json`, HCM/XM run logs and the auto-file state into a view model. `InforAutofill.ps1` is the WPF window (XAML embedded) that renders the model and starts the existing scripts (`Invoke-AutoFile.ps1`, `Install-Scheduler.ps1`) as child processes. `Install-Ui.ps1` creates Desktop / Start-menu shortcuts.

**Tech Stack:** Windows PowerShell 5.1, WPF (PresentationFramework), WScript.Shell COM for shortcuts.

**Spec:** `docs/superpowers/specs/2026-10-02-dashboard-design.md`

## Global Constraints

- Front end only: do NOT change `Invoke-AutoFile.ps1`, `AutoFile.Common.ps1`, `AutoFile.UI.ps1`, `Get-DailySummary.ps1`, `Install-Scheduler.ps1`, anything under `hcm/` or `xm/`. Filing logic and safety rules stay there.
- Windows PowerShell 5.1 syntax only: no `?:`, `??`, `?.`, `&&`, `||`; no Pester (plain test scripts like `Tests/Test-AutoFile.ps1`).
- No unary-comma returns (`return , $x`) in new code: in PS 5.1 `@(f)` then wraps the array again (seen in Task 6 of the previous plan). Return items plainly; callers wrap with `@(...)`.
- Source files are ASCII only (PS 5.1 reads BOM-less files as ANSI). Build non-ASCII characters in code: middle dot `[char]0x00B7`, check mark `[char]0x2713`, en dash `[char]0x2013`.
- Never start child scripts with `Start-Process -WindowStyle Hidden` (SW_HIDE can close the WinForms question dialog of `Invoke-AutoFile.ps1`). Use `System.Diagnostics.ProcessStartInfo` with `UseShellExecute = $false`, `CreateNoWindow = $true`, and `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '<script>' ..."` (the `-Command "& ..."` form keeps `$PSScriptRoot` working).
- Never run `Invoke-AutoFile.ps1` without `-WhatIf`, never run `Install-Scheduler.ps1`, never open the window's File now / schedule switch during automated verification — those touch the user's live Infor accounts and scheduled tasks. The controller does the live check with the user.
- Paths: data dir = folder of `presence.csv` (`%LOCALAPPDATA%\InforAutofill`), state `autofile-state.json` there; overrides `hcm\overrides.json`; run logs `hcm\logs\run-*.json`, `xm\logs\run-*.json` (some may be empty/truncated — skip them).
- Task names: `InforAutofill-File` (filing), `InforAutofill-PresenceCheck` (presence).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility |
|---|---|
| `Dashboard.Data.ps1` (new) | pure view-model + override/config helpers (needs `AutoFile.Common.ps1` dot-sourced first) |
| `Tests/Test-Dashboard.ps1` (new) | tests for `Dashboard.Data.ps1` |
| `InforAutofill.ps1` (new) | the WPF window; `-SelfTest` builds it without showing |
| `Install-Ui.ps1` (new) | Desktop + Start-menu shortcuts; `-Uninstall` removes them |
| `README.md`, `GETTING-STARTED.md` | how to open the window |

Real data shapes (verified 2026-10-02):
- HCM run log: `{ startedAt, today, mode, dryRun, results: [ { date, status, override, plan, planCode, result, detail } ], ... }`; `result` values include `filed`, `filed-unverified`, `skipped-existing` (detail holds the cell text, e.g. `Telecommuting: Full Day`), `skipped-office`, `skipped-override`, `needs-input`, `error`.
- XM run log: `{ week: { start, end }, options: { mode, dryRun, ... }, result, expectedTotal, error: { code, message } }`; `result` in `submitted`, `saved-draft`, `dry-run`, `error`; `error.code` e.g. `EXISTS`, `UNKNOWN_DAYS`, `VERIFY`, `LOGIN_NEEDED`.
- `presence.csv`: columns `timestamp,date,status,...`, timestamp `yyyy-MM-ddTHH:mm:ss+08:00`.
- `Get-DailySummary.ps1 -From -To -ConfigPath` returns rows `{ date, day, status, ... }` for configured workdays; status `office|wfh|unknown`.

---

### Task 1: View-model and helpers (`Dashboard.Data.ps1`)

**Files:**
- Create: `Dashboard.Data.ps1`
- Test: `Tests/Test-Dashboard.ps1`

**Interfaces:**
- Consumes: `AutoFile.Common.ps1` — `ConvertTo-IsoDate`, `ConvertFrom-IsoDate`, `Read-JsonMap`, `Write-JsonFile`, `Merge-OverrideAnswers`.
- Produces:
  - `Get-WeekDates -Today <datetime> -> datetime[]` (Mon..Fri of the Sun-Sat week containing Today)
  - `Read-RunLogs -Dir <string> [-Newest 200] -> object[]` (parsed, oldest first, unreadable skipped)
  - `Get-HcmFiledDates -Logs <object[]> -> hashtable` (iso date -> $true)
  - `Get-XmWeekStatus -Logs <object[]> -WeekStart <iso Sunday> [-State <obj>] -> hashtable @{ Text; Done }`
  - `Get-LastReadingTime -PresencePath <string> -Date <datetime> -> 'HH:mm' or $null`
  - `ConvertTo-DayStatus <string> -> 'wfh'|'office'|'leave'|'unknown'`
  - `New-DashboardModel -Today -WeekDates -Summary -Overrides -HcmFiled -Xm -LastReading -> pscustomobject { TodayLabel; TodayStatus; LastReading; Days[]; Xm }`; each day `{ Date; DayName; DayNumber; Status; Source ('reading'|'override'); Note; HcmFiled; IsToday; IsFuture }`
  - `Set-DayOverride -Path -Date -Value wfh|office|leave|clear`
  - `Test-FileTime <string> -> bool`, `Set-ConfigFileTime -ConfigPath -Time`

- [ ] **Step 1: Write the failing test** — `Tests/Test-Dashboard.ps1`:

```powershell
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `powershell -NoProfile -File .\Tests\Test-Dashboard.ps1` — expected: error, `Dashboard.Data.ps1` not found.

- [ ] **Step 3: Implement `Dashboard.Data.ps1`**

```powershell
# Pure helpers for the InforAutofill window (no WPF, no network). Windows PowerShell 5.1, ASCII source.
# Dot-source AutoFile.Common.ps1 first (ConvertTo-IsoDate, Read-JsonMap, Write-JsonFile, Merge-OverrideAnswers).

$script:DashInv = [Globalization.CultureInfo]::InvariantCulture
$script:DashDot = [char]0x00B7
$script:DashLeave = @('leave', 'vacation', 'sick', 'holiday')

function Get-WeekDates {
    # Mon..Fri of the Sun-Sat week that contains Today.
    param([Parameter(Mandatory = $true)][datetime]$Today)
    $sun = $Today.Date.AddDays(-[int]$Today.DayOfWeek)
    return @(1..5 | ForEach-Object { $sun.AddDays($_) })
}

function Read-RunLogs {
    # Parsed run-*.json files in Dir, oldest first. Empty or truncated files (killed runs) are skipped on purpose.
    # Returns the items on the pipeline (no unary comma): callers wrap with @(...).
    param([Parameter(Mandatory = $true)][string]$Dir, [int]$Newest = 200)
    $out = @()
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter 'run-*.json' | Sort-Object Name | Select-Object -Last $Newest)
    foreach ($f in $files) {
        try {
            $text = [IO.File]::ReadAllText($f.FullName).Trim()
            if ($text) { $out += ($text | ConvertFrom-Json) }
        } catch { Write-Verbose "skipping unreadable run log $($f.Name)" }
    }
    return $out
}

function Get-HcmFiledDates {
    # Dates with a Telecommuting entry in HCM, as seen by real (non-dry) runs: filed now, or already there.
    param([object[]]$Logs = @())
    $set = @{}
    foreach ($l in $Logs) {
        if (-not $l -or $l.dryRun) { continue }
        foreach ($r in @($l.results)) {
            if (-not $r) { continue }
            $isFiled = ([string]$r.result -eq 'filed')
            $isThere = ([string]$r.result -eq 'skipped-existing' -and [string]$r.detail -match 'Telecommut')
            if ($isFiled -or $isThere) { $set[[string]$r.date] = $true }
        }
    }
    return $set
}

function Get-XmWeekStatus {
    # One line about the XM timesheet of the week starting WeekStart (iso Sunday), from the newest real run log.
    param([object[]]$Logs = @(), [Parameter(Mandatory = $true)][string]$WeekStart, $State)
    $done = [bool]($State -and (@($State.xmWeeksDone) -contains $WeekStart))
    $last = $null
    foreach ($l in $Logs) {
        if (-not $l -or -not $l.week -or [string]$l.week.start -ne $WeekStart) { continue }
        if ($l.options -and $l.options.dryRun) { continue }
        $last = $l
    }
    $text = 'not filed yet'
    if ($last) {
        $hours = ''
        if ($null -ne $last.expectedTotal) { $hours = ([double]$last.expectedTotal).ToString('0.00', $script:DashInv) + " h $($script:DashDot) " }
        switch ([string]$last.result) {
            'submitted' { $text = $hours + 'submitted' }
            'saved-draft' { $text = $hours + 'draft saved' }
            default {
                $code = 'error'
                if ($last.error -and $last.error.code) { $code = [string]$last.error.code }
                if ($code -eq 'EXISTS') { $text = 'already in XM' } else { $text = "last run failed ($code)" }
            }
        }
    }
    if ($done -and $text -eq 'not filed yet') { $text = 'done' }
    return @{ Text = $text; Done = $done }
}

function Get-LastReadingTime {
    # 'HH:mm' of the last presence reading on Date, or $null.
    param([Parameter(Mandatory = $true)][string]$PresencePath, [Parameter(Mandatory = $true)][datetime]$Date)
    if (-not (Test-Path -LiteralPath $PresencePath)) { return $null }
    $iso = ConvertTo-IsoDate $Date
    $rows = @(Import-Csv -LiteralPath $PresencePath | Where-Object { $_.date -eq $iso -and $_.timestamp })
    if (-not $rows.Count) { return $null }
    $ts = [string](($rows | Sort-Object timestamp | Select-Object -Last 1).timestamp)
    if ($ts.Length -lt 16) { return $null }
    return $ts.Substring(11, 5)
}

function ConvertTo-DayStatus([string]$Value) {
    $v = ([string]$Value).Trim().ToLowerInvariant()
    if ($v -eq 'wfh' -or $v -eq 'office') { return $v }
    if ($script:DashLeave -contains $v) { return 'leave' }
    return 'unknown'
}

function New-DashboardModel {
    # View model for the window. Mirrors the filers' rule: an office reading beats a wfh override.
    param(
        [Parameter(Mandatory = $true)][datetime]$Today,
        [Parameter(Mandatory = $true)][datetime[]]$WeekDates,
        [object[]]$Summary = @(),
        [hashtable]$Overrides = @{},
        [hashtable]$HcmFiled = @{},
        [hashtable]$Xm = @{ Text = 'not filed yet'; Done = $false },
        [string]$LastReading
    )
    $byDate = @{}
    foreach ($s in $Summary) { if ($s) { $byDate[[string]$s.date] = [string]$s.status } }
    $days = @()
    foreach ($d in $WeekDates) {
        $iso = ConvertTo-IsoDate $d
        $reading = 'unknown'
        if ($byDate.ContainsKey($iso)) { $reading = ConvertTo-DayStatus $byDate[$iso] }
        $status = $reading
        $source = 'reading'
        $note = ''
        if ($Overrides.ContainsKey($iso)) {
            $ov = ConvertTo-DayStatus $Overrides[$iso]
            if ($ov -eq 'wfh' -and $reading -eq 'office') {
                $note = "override wfh ignored: office reading"
            } elseif ($ov -ne 'unknown') {
                $status = $ov
                $source = 'override'
            }
        }
        $days += [pscustomobject]@{
            Date      = $iso
            DayName   = $d.ToString('ddd', $script:DashInv)
            DayNumber = $d.Day
            Status    = $status
            Source    = $source
            Note      = $note
            HcmFiled  = [bool]$HcmFiled[$iso]
            IsToday   = ($d.Date -eq $Today.Date)
            IsFuture  = ($d.Date -gt $Today.Date)
        }
    }
    $todayStatus = 'weekend'
    $t = @($days | Where-Object { $_.IsToday })
    if ($t.Count) { $todayStatus = $t[0].Status }
    return [pscustomobject]@{
        TodayLabel  = "Today $($script:DashDot) " + $Today.ToString('ddd d MMM', $script:DashInv)
        TodayStatus = $todayStatus
        LastReading = $LastReading
        Days        = $days
        Xm          = $Xm
    }
}

function Set-DayOverride {
    # Writes (or with 'clear' removes) one date in hcm/overrides.json.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Date,
        [Parameter(Mandatory = $true)][ValidateSet('wfh', 'office', 'leave', 'clear')][string]$Value
    )
    if ($Value -ne 'clear') { Merge-OverrideAnswers -Path $Path -Answers @{ $Date = $Value }; return }
    $map = Read-JsonMap -Path $Path
    if (-not $map.ContainsKey($Date)) { return }
    $map.Remove($Date)
    $out = [ordered]@{}
    foreach ($k in ($map.Keys | Sort-Object)) { $out[$k] = $map[$k] }
    Write-JsonFile $out $Path
}

function Test-FileTime([string]$Text) { return [bool]($Text -match '^([01]\d|2[0-3]):[0-5]\d$') }

function Set-ConfigFileTime {
    # Sets file_time in config.json, keeping every other setting.
    param([Parameter(Mandatory = $true)][string]$ConfigPath, [Parameter(Mandatory = $true)][string]$Time)
    if (-not (Test-FileTime $Time)) { throw "Time must be HH:mm (00:00-23:59), got '$Time'" }
    $cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    if ($cfg.PSObject.Properties.Name -contains 'file_time') { $cfg.file_time = $Time }
    else { $cfg | Add-Member -NotePropertyName file_time -NotePropertyValue $Time }
    Write-JsonFile $cfg $ConfigPath
}
```

- [ ] **Step 4: Run the tests**

Run: `powershell -NoProfile -File .\Tests\Test-Dashboard.ps1` — expected `All dashboard tests passed`. Also `.\Tests\Test-AutoFile.ps1` still passes.

- [ ] **Step 5: Commit**

```
git add Dashboard.Data.ps1 Tests/Test-Dashboard.ps1
git commit -m "feat(ui): view-model and helpers for the InforAutofill window

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The window (`InforAutofill.ps1`)

**Files:**
- Create: `InforAutofill.ps1`

**Interfaces:**
- Consumes: Task 1 functions; `Presence.Common.ps1` (`Get-InforConfig`, `Resolve-LogPath`); `AutoFile.Common.ps1`; `Get-DailySummary.ps1`; `Invoke-AutoFile.ps1 [-WhatIf]`; `Install-Scheduler.ps1 [-Uninstall]`.
- Produces: `InforAutofill.ps1 [-SelfTest]`. `-SelfTest` builds the window and the model, prints `selftest ok` and exits 0 without showing anything or starting any script.

- [ ] **Step 1: Implement**

```powershell
<#
.SYNOPSIS
  InforAutofill window: status, this week, Preview / File now, schedule and settings.
.DESCRIPTION
  Front end only. Filing is done by Invoke-AutoFile.ps1 (also run by the 'InforAutofill-File' scheduled task);
  this window reads the presence log, hcm/overrides.json, run logs and state, and starts those scripts.
.PARAMETER SelfTest
  Build the window and the model, print 'selftest ok', exit. Shows nothing, starts nothing.
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $here 'InforAutofill.ps1')`"")
    if ($SelfTest) { $a += '-SelfTest' }
    $p = Start-Process powershell.exe -ArgumentList $a -PassThru -Wait:$SelfTest -NoNewWindow:$SelfTest
    if ($SelfTest) { exit $p.ExitCode }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $here 'Presence.Common.ps1')
. (Join-Path $here 'AutoFile.Common.ps1')
. (Join-Path $here 'Dashboard.Data.ps1')

$configPath = Join-Path $here 'config.json'
$overridesPath = Join-Path $here 'hcm\overrides.json'
$readmePath = Join-Path $here 'README.md'
$fileTaskName = 'InforAutofill-File'
$inv = [Globalization.CultureInfo]::InvariantCulture
$check = [string][char]0x2713
$dash = [string][char]0x2013

# ---- theme (follows the Windows app light/dark setting)
$light = $true
try {
    $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
    $light = ($v -ne 0)
} catch { $light = $true }
$theme = if ($light) {
    @{ Bg = '#F6F6F7'; Card = '#FFFFFF'; Text = '#1C1C1F'; Muted = '#6E6E76'; Border = '#E5E5E9'; Accent = '#2563EB'; Amber = '#B45309'; Chip = '#F1F1F4' }
} else {
    @{ Bg = '#161618'; Card = '#202024'; Text = '#F2F2F4'; Muted = '#9B9BA4'; Border = '#2D2D33'; Accent = '#60A5FA'; Amber = '#FBBF24'; Chip = '#2A2A30' }
}
function Format-Xaml([string]$x) { foreach ($k in $theme.Keys) { $x = $x.Replace("{$k}", $theme[$k]) }; return $x }
function Get-Brush([string]$hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

$xaml = Format-Xaml @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="InforAutofill" Width="440" SizeToContent="Height" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="{Bg}" Foreground="{Text}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{Card}"/>
      <Setter Property="BorderBrush" Value="{Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{Muted}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{Text}"/>
      <Setter Property="Background" Value="{Card}"/>
      <Setter Property="BorderBrush" Value="{Border}"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{Accent}"/>
      <Setter Property="BorderBrush" Value="{Accent}"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
  </Window.Resources>
  <StackPanel Margin="20,18,20,20">
    <Grid Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="InforAutofill" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="NextRun" Style="{StaticResource Muted}" Margin="0,2,0,0"/>
      </StackPanel>
      <Button x:Name="ScheduleBtn" Grid.Column="1" Style="{StaticResource Btn}" Margin="0,0,8,0" VerticalAlignment="Center"
              ToolTip="Turns the scheduled presence checks and filing on or off"/>
      <Button x:Name="SettingsBtn" Grid.Column="2" Style="{StaticResource Btn}" Padding="10,9" VerticalAlignment="Center"
              FontFamily="Segoe MDL2 Assets" Content="&#xE713;" ToolTip="Settings"/>
    </Grid>

    <Border Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock x:Name="TodayLabel" Style="{StaticResource Muted}"/>
        <Grid Margin="0,4,0,0">
          <TextBlock x:Name="TodayStatus" FontSize="28" FontWeight="SemiBold"/>
          <TextBlock x:Name="LastCheck" Style="{StaticResource Muted}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,6"/>
        </Grid>
      </StackPanel>
    </Border>

    <Border Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="This week" Style="{StaticResource Muted}"/>
        <UniformGrid x:Name="Days" Columns="5" Margin="-3,10,-3,0"/>
        <TextBlock x:Name="XmLine" Margin="0,14,0,0"/>
        <TextBlock x:Name="Hint" Style="{StaticResource Muted}" Margin="0,4,0,0" TextWrapping="Wrap"
                   Text="Click a day to mark it WFH, Office or Leave."/>
      </StackPanel>
    </Border>

    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Button x:Name="PreviewBtn" Style="{StaticResource Btn}" Content="Preview" ToolTip="Show what a run would do; files nothing"/>
      <Button x:Name="FileBtn" Grid.Column="2" Style="{StaticResource Primary}" Content="File now" ToolTip="Run the same filing the scheduled task does"/>
    </Grid>

    <Expander x:Name="LogExpander" Header="Log" Margin="0,14,0,0" Foreground="{Muted}">
      <TextBox x:Name="LogBox" Height="190" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="NoWrap"
               FontFamily="Cascadia Mono, Consolas" FontSize="11" Padding="8"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
    </Expander>
  </StackPanel>
</Window>
'@

$settingsXaml = Format-Xaml @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="340" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="{Bg}" Foreground="{Text}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <StackPanel Margin="20">
    <TextBlock Text="Filing time (HH:mm)" Foreground="{Muted}" FontSize="12"/>
    <TextBox x:Name="TimeBox" Margin="0,6,0,0" Padding="6" Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
    <TextBlock Foreground="{Muted}" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"
               Text="Today is only filed at or after this time, once the day's network checks are in."/>
    <TextBlock x:Name="TimeError" Foreground="{Amber}" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
    <Button x:Name="SaveBtn" Content="Save" Margin="0,12,0,0" Padding="12,8" Background="{Accent}" Foreground="White" BorderBrush="{Accent}"/>
    <Separator Margin="0,16" Background="{Border}"/>
    <Button x:Name="LogsBtn" Content="Open log folder" Padding="12,8" Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
    <Button x:Name="ReadmeBtn" Content="Open README" Margin="0,8,0,0" Padding="12,8" Background="{Card}" Foreground="{Text}" BorderBrush="{Border}"/>
  </StackPanel>
</Window>
'@

function New-WpfWindow([string]$x) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$x)
    return [Windows.Markup.XamlReader]::Load($reader)
}

$win = New-WpfWindow $xaml
$ui = @{}
foreach ($n in 'NextRun', 'ScheduleBtn', 'SettingsBtn', 'TodayLabel', 'TodayStatus', 'LastCheck', 'Days', 'XmLine', 'Hint', 'PreviewBtn', 'FileBtn', 'LogExpander', 'LogBox') {
    $ui[$n] = $win.FindName($n)
}

# ---- data
function Get-DataDir {
    $cfg = Get-InforConfig -Path $configPath
    return Split-Path -Parent (Resolve-LogPath $cfg.log_path)
}

function Get-FileTask { return Get-ScheduledTask -TaskName $fileTaskName -ErrorAction SilentlyContinue }

function Get-Model {
    $today = (Get-Date).Date
    $week = Get-WeekDates -Today $today
    $dataDir = Get-DataDir
    $summary = @()
    try { $summary = @(& (Join-Path $here 'Get-DailySummary.ps1') -From $week[0] -To $week[-1] -ConfigPath $configPath 3>$null) } catch { $summary = @() }
    $overrides = Read-JsonMap -Path $overridesPath
    $hcmFiled = Get-HcmFiledDates -Logs @(Read-RunLogs -Dir (Join-Path $here 'hcm\logs'))
    $state = $null
    $statePath = Join-Path $dataDir 'autofile-state.json'
    if (Test-Path -LiteralPath $statePath) { try { $state = Read-AutoFileState -Path $statePath -Today $today } catch { $state = $null } }
    $weekStart = ConvertTo-IsoDate $week[0].AddDays(-1)
    $xm = Get-XmWeekStatus -Logs @(Read-RunLogs -Dir (Join-Path $here 'xm\logs')) -WeekStart $weekStart -State $state
    $last = Get-LastReadingTime -PresencePath (Join-Path $dataDir 'presence.csv') -Date $today
    return New-DashboardModel -Today $today -WeekDates $week -Summary $summary -Overrides $overrides -HcmFiled $hcmFiled -Xm $xm -LastReading $last
}

function Get-StatusText([string]$s) {
    switch ($s) { 'wfh' { 'WFH' } 'office' { 'Office' } 'leave' { 'Leave' } 'weekend' { 'Weekend' } default { '?' } }
}
function Get-StatusBrush([string]$s) {
    switch ($s) { 'wfh' { Get-Brush $theme.Accent } 'leave' { Get-Brush $theme.Amber } 'office' { Get-Brush $theme.Text } default { Get-Brush $theme.Muted } }
}

function New-DayChip($day) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $win.FindResource('Btn')
    $b.Margin = '3'
    $b.Padding = '4,10'
    $b.Background = Get-Brush $theme.Chip
    $b.BorderBrush = Get-Brush $(if ($day.IsToday) { $theme.Accent } else { $theme.Chip })
    $b.Tag = $day.Date
    $sp = New-Object System.Windows.Controls.StackPanel
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $day.DayName
    $t1.FontSize = 11
    $t1.Foreground = Get-Brush $theme.Muted
    $t1.HorizontalAlignment = 'Center'
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = Get-StatusText $day.Status
    $t2.FontWeight = 'SemiBold'
    $t2.Margin = '0,4,0,0'
    $t2.Foreground = Get-StatusBrush $day.Status
    $t2.HorizontalAlignment = 'Center'
    $t3 = New-Object System.Windows.Controls.TextBlock
    $t3.Text = $(if ($day.HcmFiled) { "$check HCM" } else { $dash })
    $t3.FontSize = 11
    $t3.Margin = '0,4,0,0'
    $t3.Foreground = Get-Brush $theme.Muted
    $t3.HorizontalAlignment = 'Center'
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); [void]$sp.Children.Add($t3)
    $b.Content = $sp
    $tip = "$($day.Date): $(Get-StatusText $day.Status)"
    if ($day.Source -eq 'override') { $tip += ' (marked by you)' }
    if ($day.Note) { $tip += " - $($day.Note)" }
    $b.ToolTip = $tip

    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($pair in @(@('WFH', 'wfh'), @('Office', 'office'), @('Leave', 'leave'), @('Clear', 'clear'))) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $pair[0]
        $mi.Tag = "$($day.Date)|$($pair[1])"
        $mi.Add_Click({
            param($sender, $e)
            $parts = ([string]$sender.Tag).Split('|')
            try { Set-DayOverride -Path $overridesPath -Date $parts[0] -Value $parts[1] } catch { $ui.Hint.Text = "Could not save: $($_.Exception.Message)" }
            Update-View
        })
        [void]$menu.Items.Add($mi)
    }
    $b.ContextMenu = $menu
    $b.Add_Click({ param($sender, $e) $sender.ContextMenu.PlacementTarget = $sender; $sender.ContextMenu.IsOpen = $true })
    return $b
}

function Update-View {
    try {
        $m = Get-Model
    } catch {
        $ui.TodayStatus.Text = '?'
        $ui.Hint.Text = "No data yet: $($_.Exception.Message)"
        return
    }
    $ui.TodayLabel.Text = $m.TodayLabel
    $ui.TodayStatus.Text = Get-StatusText $m.TodayStatus
    $ui.TodayStatus.Foreground = Get-StatusBrush $m.TodayStatus
    $ui.LastCheck.Text = $(if ($m.LastReading) { "last check $($m.LastReading)" } else { 'no check yet today' })
    $ui.Days.Children.Clear()
    foreach ($d in $m.Days) { [void]$ui.Days.Children.Add((New-DayChip $d)) }
    $ui.XmLine.Text = "XM  $($m.Xm.Text)"
    $ui.Hint.Text = 'Click a day to mark it WFH, Office or Leave. An office reading always wins over WFH; file leave in HCM yourself.'

    $task = Get-FileTask
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        $ui.ScheduleBtn.Content = 'On'
        $ui.ScheduleBtn.Foreground = Get-Brush $theme.Accent
        $ui.NextRun.Text = 'Next run  ' + $info.NextRunTime.ToString('ddd d MMM, HH:mm', $inv)
    } else {
        $ui.ScheduleBtn.Content = 'Off'
        $ui.ScheduleBtn.Foreground = Get-Brush $theme.Muted
        $ui.NextRun.Text = 'Automatic filing is off'
    }
}

# ---- child processes (never Start-Process -WindowStyle Hidden: it can close the question dialog)
function Start-Child([string]$CommandText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$CommandText`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $here
    return [System.Diagnostics.Process]::Start($psi)
}

function Read-SharedText([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { $sr = New-Object IO.StreamReader($fs, $true); return $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

$script:Run = $null
$runTimer = New-Object System.Windows.Threading.DispatcherTimer
$runTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$runTimer.Add_Tick({
    if (-not $script:Run) { $runTimer.Stop(); return }
    $text = Read-SharedText $script:Run.Out
    if ($text) { $ui.LogBox.Text = $text; $ui.LogBox.ScrollToEnd() }
    if ($script:Run.Proc.HasExited) {
        $runTimer.Stop()
        $ui.LogBox.Text = (Read-SharedText $script:Run.Out) + "`r`n(exit $($script:Run.Proc.ExitCode))"
        $ui.LogBox.ScrollToEnd()
        Remove-Item -LiteralPath $script:Run.Out -ErrorAction SilentlyContinue
        $script:Run = $null
        $ui.PreviewBtn.IsEnabled = $true; $ui.FileBtn.IsEnabled = $true; $ui.ScheduleBtn.IsEnabled = $true
        Update-View
    }
})

function Start-AutoFile([switch]$Preview) {
    if ($script:Run) { return }
    $out = Join-Path ([IO.Path]::GetTempPath()) ("inforautofill-ui-{0}.log" -f [guid]::NewGuid())
    $flag = ''
    if ($Preview) { $flag = ' -WhatIf' }
    $cmd = "& '{0}'{1} *> '{2}'" -f (Join-Path $here 'Invoke-AutoFile.ps1'), $flag, $out
    $ui.PreviewBtn.IsEnabled = $false; $ui.FileBtn.IsEnabled = $false; $ui.ScheduleBtn.IsEnabled = $false
    $ui.LogExpander.IsExpanded = $true
    $ui.LogBox.Text = $(if ($Preview) { 'Preview running...' } else { 'Filing running... (Edge may open if Infor needs you to sign in)' })
    $script:Run = @{ Proc = (Start-Child $cmd); Out = $out }
    $runTimer.Start()
}

function Invoke-Scheduler([switch]$Uninstall) {
    $flag = ''
    if ($Uninstall) { $flag = ' -Uninstall' }
    $p = Start-Child ("& '{0}'{1}" -f (Join-Path $here 'Install-Scheduler.ps1'), $flag)
    [void]$p.WaitForExit(60000)
}

$ui.PreviewBtn.Add_Click({ Start-AutoFile -Preview })
$ui.FileBtn.Add_Click({
    $r = [System.Windows.MessageBox]::Show($win, 'Run the filing now? It submits WFH days to HCM and, when due, the XM timesheet - the same as the scheduled run.', 'InforAutofill', 'OKCancel', 'Question')
    if ($r -eq 'OK') { Start-AutoFile }
})
$ui.ScheduleBtn.Add_Click({
    $on = [bool](Get-FileTask)
    $msg = $(if ($on) { 'Turn automatic filing off? This removes both scheduled tasks (presence checks and filing).' } else { 'Turn automatic filing on? This registers the presence checks and the filing task for your user.' })
    $r = [System.Windows.MessageBox]::Show($win, $msg, 'InforAutofill', 'OKCancel', 'Question')
    if ($r -ne 'OK') { return }
    $win.Cursor = 'Wait'
    try { if ($on) { Invoke-Scheduler -Uninstall } else { Invoke-Scheduler } } finally { $win.Cursor = $null }
    Update-View
})
$ui.SettingsBtn.Add_Click({
    $sw = New-WpfWindow $settingsXaml
    $sw.Owner = $win
    $tb = $sw.FindName('TimeBox')
    $err = $sw.FindName('TimeError')
    $cfg = Get-InforConfig -Path $configPath
    $tb.Text = $(if ($cfg.PSObject.Properties.Name -contains 'file_time' -and $cfg.file_time) { [string]$cfg.file_time } else { '16:30' })
    $sw.FindName('SaveBtn').Add_Click({
        $t = $tb.Text.Trim()
        if (-not (Test-FileTime $t)) { $err.Text = 'Use HH:mm, for example 16:30.'; return }
        try {
            Set-ConfigFileTime -ConfigPath $configPath -Time $t
            if (Get-FileTask) { Invoke-Scheduler }
            $sw.Close()
            Update-View
        } catch { $err.Text = $_.Exception.Message }
    })
    $sw.FindName('LogsBtn').Add_Click({ Start-Process explorer.exe -ArgumentList "`"$(Get-DataDir)`"" })
    $sw.FindName('ReadmeBtn').Add_Click({ Start-Process notepad.exe -ArgumentList "`"$readmePath`"" })
    [void]$sw.ShowDialog()
})

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(60)
$refreshTimer.Add_Tick({ if (-not $script:Run) { Update-View } })

Update-View
if ($SelfTest) {
    $win.Close()
    Write-Output 'selftest ok'
    exit 0
}
$refreshTimer.Start()
[void]$win.ShowDialog()
```

- [ ] **Step 2: Verify without showing anything**

Run the parse check: `powershell -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('C:\InforAutofill\InforAutofill.ps1',[ref]$null,[ref]$e); if ($e) { $e; exit 1 } else { 'parse ok' }"` — expected `parse ok`.
Run: `powershell -NoProfile -STA -File .\InforAutofill.ps1 -SelfTest` — expected `selftest ok`, exit 0, no window appears, no script started (check no new `autofile.log` line).
Check ASCII only: `Select-String -Path InforAutofill.ps1,Dashboard.Data.ps1 -Pattern '[^\x00-\x7F]'` — expected no output.

- [ ] **Step 3: Commit**

```
git add InforAutofill.ps1
git commit -m "feat(ui): InforAutofill window (status, week, preview/file, schedule, settings)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Shortcuts and docs

**Files:**
- Create: `Install-Ui.ps1`
- Modify: `README.md` (new "Window" section), `GETTING-STARTED.md` (one step)

**Interfaces:**
- Consumes: `InforAutofill.ps1`.
- Produces: `Install-Ui.ps1 [-Uninstall]` creating/removing `InforAutofill.lnk` on the Desktop and in Start menu Programs.

- [ ] **Step 1: Implement `Install-Ui.ps1`**

```powershell
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
```

- [ ] **Step 2: Docs**

`README.md`: add a short "Window" section after "Unattended filing": run `.\Install-Ui.ps1` once, then open **InforAutofill** from the Desktop or Start menu; what it shows (today, this week with HCM marks, XM line), Preview / File now, click a day to mark WFH/Office/Leave (writes `hcm\overrides.json`; an office reading still wins; leave must be filed in HCM), the On/Off switch (both scheduled tasks), Settings (filing time, log folder). It is optional: filing runs without it. `.\Install-Ui.ps1 -Uninstall` removes the shortcuts.
`GETTING-STARTED.md`: one step pointing to `.\Install-Ui.ps1`.

- [ ] **Step 3: Verify**

Parse check `Install-Ui.ps1` (same command as Task 2 Step 2). Do NOT run it (the controller runs it with the user). ASCII check on the new file.

- [ ] **Step 4: Commit**

```
git add Install-Ui.ps1 README.md GETTING-STARTED.md
git commit -m "feat(ui): shortcuts for the InforAutofill window; docs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Live check with the user (controller, no code)

- [ ] Run `.\Install-Ui.ps1`, open the window from the Desktop shortcut.
- [ ] Today and This week match `.\Get-DailySummary.ps1` and `hcm\overrides.json`; HCM ticks on 28-29 Sep; XM line for the current week.
- [ ] Preview: log streams, ends with `(exit 0)`, nothing filed.
- [ ] Mark a future day Leave, then Clear it; `hcm\overrides.json` reflects both.
- [ ] Settings opens; Cancel without changes. Schedule switch only if the user wants it on.
- [ ] Existing suites still pass: `npm test` (hcm, xm), `Tests\Test-AutoFile.ps1`, `Test-Wrappers.ps1`, `Test-Summary.ps1`, `Test-Dashboard.ps1`.
