# Get-DailySummary.ps1 on a synthetic log: readings at/after file_time do not decide a day.
# Run: powershell -File .\Tests\Test-Summary.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ("$Expected" -ceq "$Actual") { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  expected '$Expected' got '$Actual'" -ForegroundColor Red; $script:failures++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('inforautofill-summary-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $logPath = Join-Path $tmp 'presence.csv'
    $cfgPath = Join-Path $tmp 'config.json'
    [pscustomobject]@{
        office_ssids = @('Corp-WiFi'); office_gateway_macs = @(); wired_office_dns_suffixes = @()
        check_times = @('10:00', '13:00', '16:00'); file_time = '16:30'
        workdays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri'); log_path = $logPath
    } | ConvertTo-Json | Set-Content -LiteralPath $cfgPath
    @(
        'timestamp,date,status,ssid,gateway_ip,gateway_mac'
        # Mon: only an evening remote reading -> unknown
        '2026-09-21T19:00:00+08:00,2026-09-21,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
        # Tue: office in the morning, remote in the evening -> office
        '2026-09-22T10:00:00+08:00,2026-09-22,office,Corp-WiFi,10.0.0.1,AA-BB-CC-DD-EE-FF'
        '2026-09-22T19:00:00+08:00,2026-09-22,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
        # Wed: remote in the morning only -> wfh
        '2026-09-23T10:00:00+08:00,2026-09-23,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
        # Thu: remote morning, office exactly at file_time (ignored) -> wfh
        '2026-09-24T10:00:00+08:00,2026-09-24,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
        '2026-09-24T16:30:00+08:00,2026-09-24,office,Corp-WiFi,10.0.0.1,AA-BB-CC-DD-EE-FF'
        # Fri: reading at 16:29 still counts -> wfh
        '2026-09-25T16:29:00+08:00,2026-09-25,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
    ) | Set-Content -LiteralPath $logPath

    $s = @(& (Join-Path $root 'Get-DailySummary.ps1') -From '2026-09-21' -To '2026-09-25' -ConfigPath $cfgPath -LogPath $logPath)
    $by = @{}; foreach ($x in $s) { $by[$x.date] = $x.status }
    Assert-Equal 'unknown' $by['2026-09-21'] 'only a 19:00 remote reading -> unknown'
    Assert-Equal 'office'  $by['2026-09-22'] '10:00 office + 19:00 remote -> office'
    Assert-Equal 'wfh'     $by['2026-09-23'] '10:00 remote only -> wfh'
    Assert-Equal 'wfh'     $by['2026-09-24'] 'office reading at exactly file_time is ignored'
    Assert-Equal 'wfh'     $by['2026-09-25'] 'reading one minute before file_time counts'

    # no file_time in config -> 16:30 default
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    $cfg.PSObject.Properties.Remove('file_time')
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $cfgPath
    $s = @(& (Join-Path $root 'Get-DailySummary.ps1') -From '2026-09-21' -To '2026-09-21' -ConfigPath $cfgPath -LogPath $logPath)
    Assert-Equal 'unknown' $s[0].status 'default file_time 16:30 applies'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

if ($script:failures) { Write-Host "$script:failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All summary tests passed' -ForegroundColor Green
