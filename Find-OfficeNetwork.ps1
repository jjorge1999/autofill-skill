<#
.SYNOPSIS
  Run once while IN THE OFFICE (VPN off). Shows the current network identity and offers to save it to config.json.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Presence.Common.ps1')

$config = Get-InforConfig -Path $ConfigPath
$ssids = @(Get-WifiSsids)
$gateways = @(Get-DefaultGateways | Where-Object { $_.GatewayMac })
$wiredSuffixes = @(Get-WiredDnsSuffixes)
$allSuffixes = @(Get-AllDnsSuffixes)

Write-Host ''
Write-Host '=== Current network ==='
Write-Host ('Wi-Fi SSID       : ' + $(if ($ssids.Count) { $ssids -join ', ' } else { '(not on Wi-Fi)' }))
if ($gateways.Count) {
    foreach ($g in $gateways) { Write-Host ("Default gateway  : {0}  MAC {1}  ({2})" -f $g.GatewayIp, $g.GatewayMac, $g.InterfaceAlias) }
} else {
    Write-Host 'Default gateway  : (none with a resolvable MAC)'
}
if ($allSuffixes.Count) {
    foreach ($s in $allSuffixes) { Write-Host ("DNS suffix       : {0}  ({1}{2})" -f $s.Suffix, $s.Adapter, $(if ($s.Physical) { '' } else { ', virtual - ignored' })) }
} else {
    Write-Host 'DNS suffix       : (none)'
}
Write-Host ''
Write-Host 'Make sure the corporate VPN is OFF, otherwise these values may be the VPN, not the office.' -ForegroundColor Yellow

if (-not ($ssids.Count -or $gateways.Count -or $wiredSuffixes.Count)) {
    Write-Host 'Nothing to save.'
    return
}

$answer = Read-Host 'Save these as OFFICE network values in config.json? (Y/N)'
if ($answer -notmatch '^\s*[Yy]') {
    Write-Host 'Not saved.'
    return
}

function Merge-List([object[]]$Existing, [object[]]$New) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Existing) + @($New)) {
        if ([string]::IsNullOrWhiteSpace($v) -or $v -eq 'OFFICE-WIFI-NAME') { continue }
        if (-not ($out -contains $v)) { $out.Add([string]$v) }
    }
    return , $out.ToArray()
}

$config.office_ssids = Merge-List $config.office_ssids $ssids
$config.office_gateway_macs = Merge-List $config.office_gateway_macs @($gateways | ForEach-Object { $_.GatewayMac })
$config.wired_office_dns_suffixes = Merge-List $config.wired_office_dns_suffixes $wiredSuffixes

# Windows PowerShell 5.1 can serialise arrays as {"value":[..],"Count":n}; removing this type data avoids it.
if ($PSVersionTable.PSVersion.Major -lt 6) { Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue }

$json = $config | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Resolve-Path -LiteralPath $ConfigPath).ProviderPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Saved to $ConfigPath" -ForegroundColor Green
