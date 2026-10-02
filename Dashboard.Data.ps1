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
        if ('dry-run', 'help' -contains [string]$l.result) { continue }
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
    # The presence task may be writing the file; an unreadable log means "no data yet".
    try { $rows = @(Import-Csv -LiteralPath $PresencePath -ErrorAction Stop | Where-Object { $_.date -eq $iso -and $_.timestamp }) }
    catch { return $null }
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
