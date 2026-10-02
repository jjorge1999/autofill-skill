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
        return $s
    }
    return [pscustomobject]@{
        startedOn         = ConvertTo-IsoDate $Today.Date
        hcmCoveredThrough = ConvertTo-IsoDate $Today.Date.AddDays(-1)
        xmWeeksDone       = @()
    }
}

function Save-AutoFileState {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Path)
    $out = [ordered]@{
        startedOn         = $State.startedOn
        hcmCoveredThrough = $State.hcmCoveredThrough
        xmWeeksDone       = @(@($State.xmWeeksDone) | Where-Object { $_ } | Sort-Object -Unique)
    }
    Write-JsonFile $out $Path
}

function Get-HcmRange {
    # Days still to consider for HCM: after hcmCoveredThrough, at most MaxDaysBack days before today, up to today.
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][datetime]$Today, [int]$MaxDaysBack = 14)
    $from = (ConvertFrom-IsoDate $State.hcmCoveredThrough).AddDays(1)
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
