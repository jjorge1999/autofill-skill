<#
.SYNOPSIS
  Detects whether this PC is on the office network and appends the result to the presence log.
.PARAMETER Show
  Print the detection details without writing to the log.
.EXAMPLE
  .\Detect-Presence.ps1 -Show
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Presence.Common.ps1')

$config = Get-InforConfig -Path $ConfigPath
$net = Get-NetworkSnapshot

$status = Get-PresenceStatus -Config $config `
    -Ssids $net.Ssids `
    -GatewayIps @($net.Gateways | ForEach-Object { $_.GatewayIp }) `
    -GatewayMacs @($net.Gateways | ForEach-Object { $_.GatewayMac }) `
    -WiredDnsSuffixes $net.WiredDnsSuffixes

$now = Get-Date
$inv = [Globalization.CultureInfo]::InvariantCulture
$row = [pscustomobject]@{
    timestamp   = $now.ToString('yyyy-MM-ddTHH:mm:sszzz', $inv)
    date        = $now.ToString('yyyy-MM-dd', $inv)
    status      = $status
    ssid        = ($net.Ssids -join ';')
    gateway_ip  = [string]$net.PrimaryGatewayIp
    gateway_mac = [string]$net.PrimaryGatewayMac
}

if ($Show) {
    $row | Format-List
    if ($net.Gateways.Count -gt 1) {
        Write-Host 'All default gateways:'
        $net.Gateways | Format-Table GatewayIp, GatewayMac, InterfaceAlias, Metric -AutoSize | Out-Host
    }
    Write-Host ('Wired DNS suffixes: ' + ($(if ($net.WiredDnsSuffixes.Count) { $net.WiredDnsSuffixes -join ', ' } else { '(none)' })))
    return
}

$logPath = Resolve-LogPath $config.log_path
$logDir = Split-Path -Parent $logPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$row | Export-Csv -LiteralPath $logPath -Append -NoTypeInformation -Encoding UTF8
Write-Verbose "Logged '$status' to $logPath"
