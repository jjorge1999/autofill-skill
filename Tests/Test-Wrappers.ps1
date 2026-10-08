# Wrapper behaviour (no browser: every case stops before Playwright). Run: powershell -File .\Tests\Test-Wrappers.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:failures = 0
function Assert-True([bool]$Cond, [string]$Name, [string]$Detail = '') {
    if ($Cond) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red; $script:failures++ }
}

# HCM: a 2020 range has no readings and no overrides -> exactly 5 unknown weekdays, nothing filed, no browser.
$out = & (Join-Path $root 'hcm\run-hcm.ps1') -From 2020-01-06 -To 2020-01-10 --dry-run *>&1 | Out-String
Assert-True ($out -match '5 day\(s\) considered, 0 to file') 'hcm -From/-To limits node to the range' $out
Assert-True ($LASTEXITCODE -eq 0) 'hcm exit 0' "got $LASTEXITCODE"

# XM: unknown days make node print to stderr and exit 2; the wrapper must return 2, not throw.
$threw = $false
try { $out = & (Join-Path $root 'xm\run-xm.ps1') -Week 2020-01-08 --dry-run *>&1 | Out-String } catch { $threw = $true; $out = $_.Exception.Message }
Assert-True (-not $threw) 'xm wrapper survives node stderr' $out
Assert-True ($LASTEXITCODE -eq 2) 'xm exit code 2 for unknown days' "got $LASTEXITCODE"

if ($script:failures) { Write-Host "$script:failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All wrapper tests passed' -ForegroundColor Green
