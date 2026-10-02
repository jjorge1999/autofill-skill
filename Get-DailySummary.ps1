<#
.SYNOPSIS
  Summarises the presence log into one status per workday.
.DESCRIPTION
  office  : at least one reading that day was 'office'
  wfh     : at least one 'remote' reading and none 'office'
  unknown : no readings (PC off - possibly leave) or only 'offline' readings. Never guessed.
  Readings at or after config file_time (default 16:30) are ignored: they never decide a day.
.EXAMPLE
  .\Get-DailySummary.ps1
  .\Get-DailySummary.ps1 -From 2025-01-01 -To 2025-01-31 -AsJson -JsonPath .\jan.json
#>
[CmdletBinding()]
param(
    [datetime]$From = (Get-Date -Day 1).Date,
    [datetime]$To = (Get-Date).Date,
    [switch]$AsJson,
    [string]$JsonPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Presence.Common.ps1')

$config = Get-InforConfig -Path $ConfigPath
if (-not $LogPath) { $LogPath = Resolve-LogPath $config.log_path }
if (-not $JsonPath) { $JsonPath = Join-Path (Split-Path -Parent $LogPath) 'summary.json' }
if ($From.Date -gt $To.Date) { throw "-From ($($From.ToString('yyyy-MM-dd'))) is after -To ($($To.ToString('yyyy-MM-dd')))" }

$readings = @()
if (Test-Path -LiteralPath $LogPath) {
    $readings = @(Import-Csv -LiteralPath $LogPath)
} else {
    Write-Warning "Presence log not found: $LogPath (all days will be 'unknown')"
}

# Whole-day rule: a day is decided by its working-hours readings only. Readings at or after
# file_time (default 16:30) - or with no readable time - are ignored, so an evening reading never decides a day.
$fileTime = if ($config.PSObject.Properties.Name -contains 'file_time' -and $config.file_time) { [string]$config.file_time } else { '16:30' }
if ($fileTime -notmatch '^\d{2}:\d{2}$') { throw "config file_time must be HH:mm (got '$fileTime')" }
$byDate = @{}
foreach ($r in $readings) {
    if (-not $r.date) { continue }
    $ts = [string]$r.timestamp
    if ($ts -notmatch '^\d{4}-\d{2}-\d{2}T(\d{2}:\d{2})') { Write-Verbose "ignored reading without a time: $ts"; continue }
    if ([string]::CompareOrdinal($Matches[1], $fileTime) -ge 0) { Write-Verbose "ignored after-hours reading: $ts"; continue }
    if (-not $byDate.ContainsKey($r.date)) { $byDate[$r.date] = New-Object System.Collections.ArrayList }
    [void]$byDate[$r.date].Add([string]$r.status)
}

$workdays = @($config.workdays)
$inv = [Globalization.CultureInfo]::InvariantCulture
$summary = @()
for ($d = $From.Date; $d -le $To.Date; $d = $d.AddDays(1)) {
    $abbr = Get-DayAbbrev $d
    if ($workdays -notcontains $abbr) { continue }
    $key = $d.ToString('yyyy-MM-dd', $inv)
    $statuses = @()
    if ($byDate.ContainsKey($key)) { $statuses = @($byDate[$key]) }
    $summary += [pscustomobject]@{
        date            = $key
        day             = $abbr
        status          = Get-DayStatus -Statuses $statuses
        office_readings = @($statuses | Where-Object { $_ -eq 'office' }).Count
        remote_readings = @($statuses | Where-Object { $_ -eq 'remote' }).Count
        offline_readings = @($statuses | Where-Object { $_ -eq 'offline' }).Count
    }
}

if ($AsJson) {
    $JsonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath)
    $dir = Split-Path -Parent $JsonPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($summary) -Depth 3
    [IO.File]::WriteAllText($JsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Verbose "Summary written to $JsonPath"
}

$summary
