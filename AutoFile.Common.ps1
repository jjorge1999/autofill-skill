# Pure helpers for Invoke-AutoFile.ps1 (no browser, no network, no UI). Windows PowerShell 5.1.
# Dot-source this file; it has no side effects.

$script:AutoFileInv = [Globalization.CultureInfo]::InvariantCulture

function ConvertTo-IsoDate([datetime]$Date) { return $Date.ToString('yyyy-MM-dd', $script:AutoFileInv) }
function ConvertFrom-IsoDate([string]$Text) { return [datetime]::ParseExact($Text, 'yyyy-MM-dd', $script:AutoFileInv) }

function Read-JsonMap {
    # {"k": "v"} file -> hashtable of strings. Missing or blank file -> empty hashtable.
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $text = [IO.File]::ReadAllText($Path).Trim()
    if (-not $text) { return $map }
    $obj = $text | ConvertFrom-Json
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

function Write-JsonFile([object]$Value, [string]$Path) {
    # Windows PowerShell 5.1 can serialise arrays as {"value":[..],"Count":n}; removing this type data avoids it.
    if ($PSVersionTable.PSVersion.Major -lt 6) { Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue }
    $json = ConvertTo-Json -InputObject $Value -Depth 5
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-AutoFileState {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][datetime]$Today)
    if (Test-Path -LiteralPath $Path) {
        $s = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $s.xmWeeksDone = @($s.xmWeeksDone | Where-Object { $_ })
        $skipped = @()
        if ($s.PSObject.Properties.Name -contains 'xmWeeksSkipped') { $skipped = @($s.xmWeeksSkipped | Where-Object { $_ }) }
        $s | Add-Member -NotePropertyName xmWeeksSkipped -NotePropertyValue $skipped -Force
        # Tempo was added later: an older state file starts Tempo where HCM is, so no old days are backfilled
        # Tempo was added later: an older state file starts Tempo where HCM is, so no old days are backfilled
        $tempo = $s.hcmCoveredThrough
        if ($s.PSObject.Properties.Name -contains 'tempoCoveredThrough' -and $s.tempoCoveredThrough) { $tempo = $s.tempoCoveredThrough }
        $s | Add-Member -NotePropertyName tempoCoveredThrough -NotePropertyValue $tempo -Force
        return $s
    }
    return [pscustomobject]@{
        startedOn           = ConvertTo-IsoDate $Today.Date
        hcmCoveredThrough   = ConvertTo-IsoDate $Today.Date.AddDays(-1)
        tempoCoveredThrough = ConvertTo-IsoDate $Today.Date.AddDays(-1)
        xmWeeksDone         = @()
        xmWeeksSkipped      = @()
    }
}

function Save-AutoFileState {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Path)
    $out = [ordered]@{
        startedOn           = $State.startedOn
        hcmCoveredThrough   = $State.hcmCoveredThrough
        tempoCoveredThrough = $State.tempoCoveredThrough
        xmWeeksDone         = @(@($State.xmWeeksDone) | Where-Object { $_ } | Sort-Object -Unique)
        # weeks past the XM cap that were reported once (never filed automatically)
        xmWeeksSkipped      = @(@($State.xmWeeksSkipped) | Where-Object { $_ } | Sort-Object -Unique)
    }
    Write-JsonFile $out $Path
}

function Get-HcmRange {
    # Days still to consider for HCM: after hcmCoveredThrough, at most MaxDaysBack days before today, up to today.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxDaysBack = 14)
    return Get-RangeAfter -CoveredThrough $State.hcmCoveredThrough -Today $Today -MaxDaysBack $MaxDaysBack
}

function Get-TempoRange {
    # Days still to log in Tempo: after tempoCoveredThrough, at most MaxDaysBack days before today, up to today.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxDaysBack = 14)
    return Get-RangeAfter -CoveredThrough $State.tempoCoveredThrough -Today $Today -MaxDaysBack $MaxDaysBack
}

function Get-RangeAfter {
    param([Parameter(Mandatory = $true)][string]$CoveredThrough, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxDaysBack = 14)
    $from = (ConvertFrom-IsoDate $CoveredThrough).AddDays(1)
    $floor = $Today.Date.AddDays(-$MaxDaysBack)
    if ($from -lt $floor) { $from = $floor }
    if ($from -gt $Today.Date) { return $null }
    return @{ From = $from; To = $Today.Date }
}

function Get-XmWeeksDue {
    # Sundays of the Sun-Sat weeks to file: earlier weeks (up to MaxWeeksBack, not before the week of startedOn)
    # that are not done, plus the current week on Friday/Saturday.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxWeeksBack = 2)
    $done = @($State.xmWeeksDone)
    $thisSun = $Today.Date.AddDays(-[int]$Today.DayOfWeek)
    $started = ConvertFrom-IsoDate $State.startedOn
    $firstSun = $started.AddDays(-[int]$started.DayOfWeek)
    $due = @()
    for ($i = $MaxWeeksBack; $i -ge 1; $i--) {
        $w = $thisSun.AddDays(-7 * $i)
        if ($w -lt $firstSun -or $done -contains (ConvertTo-IsoDate $w)) { continue }
        $due += $w
    }
    if (@(5, 6) -contains [int]$Today.DayOfWeek -and -not ($done -contains (ConvertTo-IsoDate $thisSun))) { $due += $thisSun }
    return , $due
}

function Get-PendingDays {
    # Workdays with no usable reading that neither overrides.json nor HCM leave explains.
    param([object[]]$Summary = @(), [hashtable]$Overrides = @{}, [hashtable]$Leave = @{})
    return @($Summary | Where-Object { $_.status -eq 'unknown' -and -not $Overrides.ContainsKey($_.date) -and -not $Leave.ContainsKey($_.date) } |
        ForEach-Object { $_.date } | Sort-Object)
}

function Get-CoveredThrough {
    # Last date of the range that needs nothing more: the day before the first pending day, or the range end.
    param([Parameter(Mandatory = $true)][hashtable]$Range, [string[]]$Pending = @())
    $first = @($Pending | Sort-Object | Select-Object -First 1)
    if (-not $first.Count -or -not $first[0]) { return $Range.To }
    $d = (ConvertFrom-IsoDate $first[0]).AddDays(-1)
    if ($d -lt $Range.From.AddDays(-1)) { $d = $Range.From.AddDays(-1) }
    return $d
}

function Merge-OverrideAnswers {
    # Adds {date: wfh|office|leave} answers to hcm/overrides.json (existing keys are replaced), keys sorted.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Answers)
    $map = Read-JsonMap -Path $Path
    foreach ($k in $Answers.Keys) { $map[$k] = [string]$Answers[$k] }
    $out = [ordered]@{}
    foreach ($k in ($map.Keys | Sort-Object)) { $out[$k] = $map[$k] }
    Write-JsonFile $out $Path
}

function Reset-AutoFileStateForForce {
    # -Force: reconsider the last 14 days for HCM. XM weeks already done stay done (the filer's exists-check is not a substitute).
    # The Tempo filer reads existing worklogs before logging, so reconsidering its days is safe too.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today)
    $State.hcmCoveredThrough = ConvertTo-IsoDate $Today.Date.AddDays(-15)
    $State | Add-Member -NotePropertyName tempoCoveredThrough -NotePropertyValue (ConvertTo-IsoDate $Today.Date.AddDays(-15)) -Force
}

function Get-SkippedHcmDays {
    # Days after hcmCoveredThrough that Get-HcmRange drops because they are more than MaxDaysBack days back: @{From; To} or $null.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxDaysBack = 14)
    return Get-SkippedDaysAfter -CoveredThrough $State.hcmCoveredThrough -Today $Today -MaxDaysBack $MaxDaysBack
}

function Get-SkippedTempoDays {
    # Days after tempoCoveredThrough that Get-TempoRange drops (more than MaxDaysBack days back): @{From; To} or $null.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxDaysBack = 14)
    return Get-SkippedDaysAfter -CoveredThrough $State.tempoCoveredThrough -Today $Today -MaxDaysBack $MaxDaysBack
}

function Get-SkippedDaysAfter {
    param([Parameter(Mandatory = $true)][string]$CoveredThrough, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxDaysBack = 14)
    $from = (ConvertFrom-IsoDate $CoveredThrough).AddDays(1)
    $floor = $Today.Date.AddDays(-$MaxDaysBack)
    if ($from -ge $floor) { return $null }
    return @{ From = $from; To = $floor.AddDays(-1) }
}

function Get-SkippedXmWeeks {
    # Sundays of weeks older than MaxWeeksBack (not before the week of startedOn) that are neither done nor already reported.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxWeeksBack = 2)
    $done = @($State.xmWeeksDone)
    $reported = @()
    if ($State.PSObject.Properties.Name -contains 'xmWeeksSkipped') { $reported = @($State.xmWeeksSkipped) }
    $thisSun = $Today.Date.AddDays(-[int]$Today.DayOfWeek)
    $started = ConvertFrom-IsoDate $State.startedOn
    $firstSun = $started.AddDays(-[int]$started.DayOfWeek)
    $last = $thisSun.AddDays(-7 * ($MaxWeeksBack + 1))
    $out = @()
    for ($w = $firstSun; $w -le $last; $w = $w.AddDays(7)) {
        $k = ConvertTo-IsoDate $w
        if ($done -contains $k -or $reported -contains $k) { continue }
        $out += $w
    }
    return , $out
}

function Get-HcmFilerFindings {
    # Scans file-hcm.js output: verified filings, filed-unverified days, office readings that beat an override, unrecognised entries.
    param([string[]]$Output = @())
    $r = @{ Filed = @(); Unverified = @(); OfficeReading = @(); Unrecognised = @() }
    foreach ($line in $Output) {
        if ($line -match '^\s+(\d{4}-\d{2}-\d{2}) \S+ \(\d+\): filed( |$)') { $r.Filed += $Matches[1] }
        elseif ($line -match '^\s+(\d{4}-\d{2}-\d{2}) \S+ \(\d+\): filed-unverified') { $r.Unverified += $Matches[1] }
        elseif ($line -match '^\s*WARNING (\d{4}-\d{2}-\d{2}): .*override "([^"]*)".*skipped-office-reading') { $r.OfficeReading += @{ Date = $Matches[1]; Override = $Matches[2] } }
        elseif ($line -match '^\s*UNRECOGNISED (\d{4}-\d{2}-\d{2}): (.*)$') { $r.Unrecognised += @{ Date = $Matches[1]; Text = $Matches[2].Trim() } }
    }
    return $r
}

function Get-TempoFilerFindings {
    # Scans file-tempo.js output: days that got hours added to reach 8h.
    param([string[]]$Output = @())
    $r = @{ Filed = @() }
    foreach ($line in $Output) {
        if ($line -match '^\[tempo\] (\d{4}-\d{2}-\d{2}) \S+: filed ') { $r.Filed += $Matches[1] }
    }
    return $r
}

function Test-XmSubmitUnconfirmed {
    # True when file-xm.js clicked Submit but saw no "Submitted" confirmation.
    param([string[]]$Output = @())
    return [bool](@($Output | Where-Object { $_ -match '\[xm\] WARNING: Submit clicked but no' }).Count)
}

function Get-WeekBlockers {
    # Dates (yyyy-MM-dd) inside the Sun-Sat week starting at Week that overrides.json does not explain.
    param([Parameter(Mandatory = $true)][datetime]$Week, [string[]]$Dates = @(), [hashtable]$Overrides = @{})
    return Get-RangeBlockers -Range @{ From = $Week; To = $Week.AddDays(6) } -Dates $Dates -Overrides $Overrides
}

function Get-RangeBlockers {
    # Dates (yyyy-MM-dd) inside Range (@{From; To}) that overrides.json does not explain.
    param([Parameter(Mandatory = $true)][hashtable]$Range, [string[]]$Dates = @(), [hashtable]$Overrides = @{})
    $from = ConvertTo-IsoDate $Range.From
    $to = ConvertTo-IsoDate $Range.To
    return @($Dates | Where-Object { $_ -and $_ -ge $from -and $_ -le $to -and -not $Overrides.ContainsKey($_) } | Sort-Object -Unique)
}
