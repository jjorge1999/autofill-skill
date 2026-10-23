<#
.SYNOPSIS
  Logs 8h per worked weekday in Tempo for a date range.
.DESCRIPTION
  Runs node file-tempo.js --from <date> --to <date> (default: today). Any other arguments are passed
  straight through to file-tempo.js (--leave, --skip, --dry-run, ...). Needs TEMPO_API_TOKEN in the environment.
.EXAMPLE
  .\run-tempo.ps1 --dry-run
  .\run-tempo.ps1 -From 2026-10-19 -To 2026-10-23
#>
# No param() block: declared parameters bind positionally, so '--dry-run' would land in -From.
$ErrorActionPreference = 'Stop'
$From = $null; $To = $null; $passThru = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ([string]$args[$i]) {
        '^-From$' { $From = $args[++$i]; break }
        '^-To$' { $To = $args[++$i]; break }
        default { $passThru += $args[$i] }
    }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js not found on PATH. Install Node 18+ from https://nodejs.org/'
}

# token saved by Save-TempoToken.ps1 (DPAPI, this Windows user only); an explicit TEMPO_API_TOKEN wins
$tokenStore = Join-Path $env:LOCALAPPDATA 'InforAutofill\tempo-token.dpapi'
$setToken = (-not $env:TEMPO_API_TOKEN) -and (Test-Path -LiteralPath $tokenStore)
if ($setToken) {
    $secure = ConvertTo-SecureString -String ([IO.File]::ReadAllText($tokenStore).Trim())
    $env:TEMPO_API_TOKEN = (New-Object System.Management.Automation.PSCredential 'tempo', $secure).GetNetworkCredential().Password
}

$inv = [Globalization.CultureInfo]::InvariantCulture
$nodeArgs = @()
if ($From) { $nodeArgs += @('--from', ([datetime]$From).ToString('yyyy-MM-dd', $inv)) }
if ($To) { $nodeArgs += @('--to', ([datetime]$To).ToString('yyyy-MM-dd', $inv)) }
# node writes warnings to stderr; under 'Stop' a redirected stderr line would abort this script mid-run
$ErrorActionPreference = 'Continue'
try {
    & node (Join-Path $PSScriptRoot 'file-tempo.js') @nodeArgs @passThru
    $code = $LASTEXITCODE
} finally {
    if ($setToken) { Remove-Item Env:\TEMPO_API_TOKEN -ErrorAction SilentlyContinue }
}
exit $code
