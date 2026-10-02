# The question dialog must close by itself (as "Ask me later") after its timeout.
# Shows a small dialog on the desktop for ~3 seconds. Run: powershell -File .\Tests\Test-UI.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:failures = 0
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ("$Expected" -ceq "$Actual") { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name  expected '$Expected' got '$Actual'" -ForegroundColor Red; $script:failures++ }
}

$out = Join-Path ([IO.Path]::GetTempPath()) ('inforautofill-ui-' + [guid]::NewGuid() + '.txt')
$child = @"
`$ErrorActionPreference = 'Stop'
. '$(Join-Path $root 'AutoFile.UI.ps1')'
`$a = Show-DayQuestion -Dates @('2026-09-21', '2026-09-22') -TimeoutMinutes 0.05
Set-Content -LiteralPath '$out' -Value ("count=" + `$a.Count)
"@
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-STA', '-EncodedCommand', $enc -PassThru -NoNewWindow
if (-not $p.WaitForExit(60000)) { $p.Kill(); Assert-Equal 'closed' 'still open after 60 s' 'dialog closes by itself' }
else {
    Assert-Equal 'closed' 'closed' 'dialog closes by itself'
    Assert-Equal 'count=0' $(if (Test-Path -LiteralPath $out) { (Get-Content -LiteralPath $out -Raw).Trim() } else { 'no output' }) 'timeout returns no answers (Ask me later)'
    Assert-Equal 'True' ($sw.Elapsed.TotalSeconds -ge 2 -and $sw.Elapsed.TotalSeconds -lt 30) "closed near the 3 s timeout ($([int]$sw.Elapsed.TotalSeconds) s)"
}
Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue

if ($script:failures) { Write-Host "$script:failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All UI tests passed' -ForegroundColor Green
