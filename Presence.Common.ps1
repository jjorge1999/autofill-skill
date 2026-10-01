# Shared functions for InforAutofill presence detection.
# Windows PowerShell 5.1 compatible. Dot-source this file; it has no side effects.
#
# Pure functions (testable anywhere): Get-InforConfig, ConvertTo-NormalizedMac,
#   ConvertTo-NormalizedSuffix, Get-PresenceStatus, Get-DayStatus, Get-DayAbbrev
# Windows-only functions: Get-WifiSsids, Get-DefaultGateways, Get-WiredDnsSuffixes,
#   Get-NetworkSnapshot

function Get-InforConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($name in 'office_ssids', 'office_gateway_macs', 'wired_office_dns_suffixes', 'check_times', 'workdays') {
        if ($cfg.PSObject.Properties.Name -notcontains $name -or $null -eq $cfg.$name) {
            $cfg | Add-Member -NotePropertyName $name -NotePropertyValue @() -Force
        }
    }
    if ($cfg.PSObject.Properties.Name -notcontains 'log_path' -or [string]::IsNullOrWhiteSpace($cfg.log_path)) {
        $cfg | Add-Member -NotePropertyName log_path -NotePropertyValue '%LOCALAPPDATA%\InforAutofill\presence.csv' -Force
    }
    return $cfg
}

function Resolve-LogPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function ConvertTo-NormalizedMac {
    # "00-1A-2b:3c.4D5E" -> "001A2B3C4D5E". Returns $null for empty / invalid / all-zero MACs.
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12 -or $hex -eq '000000000000') { return $null }
    return $hex
}

function ConvertTo-NormalizedSuffix {
    param([string]$Suffix)
    if ([string]::IsNullOrWhiteSpace($Suffix)) { return $null }
    return $Suffix.Trim().Trim('.').ToLowerInvariant()
}

function Get-PresenceStatus {
    # Pure classification. Returns 'office', 'remote' or 'offline'.
    # Public IP is deliberately NOT used: a corporate VPN would make home look like the office.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string[]]$Ssids = @(),
        [string[]]$GatewayMacs = @(),
        [string[]]$GatewayIps = @(),
        [string[]]$WiredDnsSuffixes = @()
    )
    $Ssids = @($Ssids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $GatewayIps = @($GatewayIps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $officeSsids = @($Config.office_ssids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    foreach ($s in $Ssids) {
        if ($officeSsids -contains $s) { return 'office' }   # -contains is case-insensitive
    }

    $officeMacs = @($Config.office_gateway_macs | ForEach-Object { ConvertTo-NormalizedMac $_ } | Where-Object { $_ })
    foreach ($m in $GatewayMacs) {
        $n = ConvertTo-NormalizedMac $m
        if ($n -and ($officeMacs -contains $n)) { return 'office' }
    }

    $officeSuffixes = @($Config.wired_office_dns_suffixes | ForEach-Object { ConvertTo-NormalizedSuffix $_ } | Where-Object { $_ })
    foreach ($sfx in $WiredDnsSuffixes) {
        $n = ConvertTo-NormalizedSuffix $sfx
        if (-not $n) { continue }
        foreach ($o in $officeSuffixes) {
            if ($n -eq $o -or $n.EndsWith('.' + $o)) { return 'office' }
        }
    }

    if ($Ssids.Count -eq 0 -and $GatewayIps.Count -eq 0) { return 'offline' }
    return 'remote'
}

function Get-DayAbbrev {
    # Culture-invariant "Mon".."Sun"
    param([Parameter(Mandatory = $true)][datetime]$Date)
    return $Date.DayOfWeek.ToString().Substring(0, 3)
}

function Get-DayStatus {
    # Pure per-day classification from that day's status values.
    #   office  : any reading was office
    #   wfh     : at least one 'remote' reading and none office
    #   unknown : no readings, or only 'offline' readings (never guessed - may be leave)
    param([string[]]$Statuses = @())
    $Statuses = @($Statuses | Where-Object { $_ })
    if ($Statuses -contains 'office') { return 'office' }
    if ($Statuses -contains 'remote') { return 'wfh' }
    return 'unknown'
}

# ---------------- Windows-only network probes ----------------

function Get-WifiSsids {
    # Parses `netsh wlan show interfaces`. Returns @() when there is no Wi-Fi / not connected.
    $ssids = @()
    $ErrorActionPreference = 'Continue'   # native stderr + 'Stop' throws in Windows PowerShell 5.1
    try {
        $out = & netsh.exe wlan show interfaces 2>$null
    } catch {
        return @()
    }
    if (-not $out) { return @() }
    foreach ($line in $out) {
        # "    SSID                   : Name"  (the anchored \s*SSID excludes the BSSID line)
        if ($line -match '^\s*SSID\s*:\s*(.*?)\s*$') {
            if ($Matches[1]) { $ssids += $Matches[1] }
        }
    }
    return @($ssids | Select-Object -Unique)
}

function Get-DefaultGateways {
    # Returns IPv4 default gateways ordered by effective metric (route + interface), each with its MAC.
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' })
    $result = @()
    foreach ($r in $routes) {
        $ifMetric = 0
        $ipIf = Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ipIf) { $ifMetric = [int]$ipIf.InterfaceMetric }
        if ($ipIf -and $ipIf.ConnectionState -ne 'Connected') { continue }

        $mac = Get-GatewayMac -IpAddress $r.NextHop -InterfaceIndex $r.ifIndex
        $result += [pscustomobject]@{
            GatewayIp      = $r.NextHop
            GatewayMac     = $mac
            InterfaceIndex = $r.ifIndex
            InterfaceAlias = $r.InterfaceAlias
            Metric         = [int]$r.RouteMetric + $ifMetric
        }
    }
    return @($result | Sort-Object Metric)
}

function Get-GatewayMac {
    param([string]$IpAddress, [int]$InterfaceIndex)
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $n = Get-NetNeighbor -IPAddress $IpAddress -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object { ConvertTo-NormalizedMac $_.LinkLayerAddress } | Select-Object -First 1
        if ($n) { return ($n.LinkLayerAddress -replace '[^0-9A-Fa-f]', '' -replace '(..)(?!$)', '$1-').ToUpperInvariant() }
        # Not in ARP cache yet: ping once to populate it, then retry.
        $null = Test-Connection -ComputerName $IpAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
    }
    return $null
}

function Get-WiredDnsSuffixes {
    # Connection-specific DNS suffixes of physical, connected, non-Wi-Fi adapters only.
    # VPN adapters are virtual and are excluded, so a VPN's corporate suffix cannot fake "office".
    $wired = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -ne 9 -and $_.PhysicalMediaType -notmatch '802\.11|Wireless'
        })
    $suffixes = @()
    foreach ($a in $wired) {
        $c = Get-DnsClient -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        foreach ($x in @($c)) {
            if ($x -and $x.ConnectionSpecificSuffix) { $suffixes += $x.ConnectionSpecificSuffix }
        }
    }
    return @($suffixes | Select-Object -Unique)
}

function Get-AllDnsSuffixes {
    # All active adapters' suffixes (informational, used by Find-OfficeNetwork).
    $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    $list = @()
    foreach ($a in $up) {
        $c = Get-DnsClient -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        foreach ($x in @($c)) {
            if ($x -and $x.ConnectionSpecificSuffix) {
                $list += [pscustomobject]@{ Adapter = $a.Name; Suffix = $x.ConnectionSpecificSuffix; Physical = [bool]$a.HardwareInterface }
            }
        }
    }
    return $list
}

function Get-NetworkSnapshot {
    $ssids = @(Get-WifiSsids)
    $gws = @(Get-DefaultGateways)
    $sfx = @(Get-WiredDnsSuffixes)
    $primary = $gws | Select-Object -First 1
    return [pscustomobject]@{
        Ssids            = $ssids
        Gateways         = $gws
        WiredDnsSuffixes = $sfx
        PrimaryGatewayIp = $(if ($primary) { $primary.GatewayIp } else { $null })
        PrimaryGatewayMac = $(if ($primary) { $primary.GatewayMac } else { $null })
    }
}
