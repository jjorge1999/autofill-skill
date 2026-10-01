# Self-contained tests for the pure logic (no Pester, no network). Run: powershell -File .\Tests\Test-Logic.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Presence.Common.ps1')

$script:failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ceq $Actual) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  expected '$Expected' got '$Actual'" -ForegroundColor Red; $script:failures++ }
}

$cfg = [pscustomobject]@{
    office_ssids              = @('Corp-WiFi')
    office_gateway_macs       = @('aa:bb:cc:dd:ee:ff')
    wired_office_dns_suffixes = @('corp.example.com')
    workdays                  = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri')
    log_path                  = ''
}

# MAC normalisation
Assert-Equal 'AABBCCDDEEFF' (ConvertTo-NormalizedMac 'aa-bb-cc-dd-ee-ff') 'mac dashes'
Assert-Equal 'AABBCCDDEEFF' (ConvertTo-NormalizedMac 'AA:BB:CC:DD:EE:FF') 'mac colons'
Assert-Equal $null (ConvertTo-NormalizedMac '00-00-00-00-00-00') 'mac all-zero rejected'
Assert-Equal $null (ConvertTo-NormalizedMac 'junk') 'mac invalid rejected'

# Classification
Assert-Equal 'office'  (Get-PresenceStatus -Config $cfg -Ssids 'corp-wifi' -GatewayIps '10.0.0.1') 'ssid match, case-insensitive'
Assert-Equal 'office'  (Get-PresenceStatus -Config $cfg -GatewayIps '10.0.0.1' -GatewayMacs 'AA-BB-CC-DD-EE-FF') 'gateway mac match (dash vs colon)'
Assert-Equal 'office'  (Get-PresenceStatus -Config $cfg -GatewayIps '10.0.0.1' -WiredDnsSuffixes 'corp.example.com.') 'wired suffix exact'
Assert-Equal 'office'  (Get-PresenceStatus -Config $cfg -GatewayIps '10.0.0.1' -WiredDnsSuffixes 'site1.CORP.example.com') 'wired suffix subdomain'
Assert-Equal 'remote'  (Get-PresenceStatus -Config $cfg -Ssids 'HomeNet' -GatewayIps '192.168.1.1' -GatewayMacs '11-22-33-44-55-66') 'home wifi'
Assert-Equal 'remote'  (Get-PresenceStatus -Config $cfg -GatewayIps '192.168.1.1' -WiredDnsSuffixes 'notcorp.example.com') 'suffix must not partially match'
Assert-Equal 'offline' (Get-PresenceStatus -Config $cfg) 'no network'
Assert-Equal 'offline' (Get-PresenceStatus -Config $cfg -Ssids @() -GatewayIps @() -GatewayMacs @($null)) 'no network, null mac'

# Day classification
Assert-Equal 'office'  (Get-DayStatus @('remote', 'office', 'offline')) 'day any office'
Assert-Equal 'wfh'     (Get-DayStatus @('remote', 'offline')) 'day remote only'
Assert-Equal 'unknown' (Get-DayStatus @()) 'day no readings'
Assert-Equal 'unknown' (Get-DayStatus @('offline')) 'day offline only'
Assert-Equal 'Mon' (Get-DayAbbrev ([datetime]'2025-06-02')) 'day abbrev'

# Get-DailySummary end-to-end on a synthetic CSV
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('inforautofill-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $cfgPath = Join-Path $tmp 'config.json'
    $logPath = Join-Path $tmp 'presence.csv'
    $cfg.log_path = $logPath
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $cfgPath
    @(
        'timestamp,date,status,ssid,gateway_ip,gateway_mac'
        '2025-06-02T10:00:00+00:00,2025-06-02,office,Corp-WiFi,10.0.0.1,AA-BB-CC-DD-EE-FF'
        '2025-06-02T13:00:00+00:00,2025-06-02,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
        '2025-06-03T10:00:00+00:00,2025-06-03,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
        '2025-06-05T10:00:00+00:00,2025-06-05,offline,,,'
        '2025-06-07T10:00:00+00:00,2025-06-07,remote,HomeNet,192.168.1.1,11-22-33-44-55-66'
    ) | Set-Content -LiteralPath $logPath

    $jsonPath = Join-Path $tmp 'summary.json'
    $s = @(& (Join-Path $root 'Get-DailySummary.ps1') -From '2025-06-02' -To '2025-06-08' -ConfigPath $cfgPath -AsJson -JsonPath $jsonPath)
    Assert-Equal 5 $s.Count 'summary skips weekend'
    Assert-Equal 'office'  $s[0].status 'Mon office'
    Assert-Equal 'wfh'     $s[1].status 'Tue wfh'
    Assert-Equal 'unknown' $s[2].status 'Wed no readings -> unknown'
    Assert-Equal 'unknown' $s[3].status 'Thu offline only -> unknown'
    Assert-Equal 'unknown' $s[4].status 'Fri unknown'
    $j = @(Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json)
    Assert-Equal 5 $j.Count 'json array length'
    Assert-Equal '2025-06-03' $j[1].date 'json date'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

if ($script:failures) { Write-Host "$script:failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
