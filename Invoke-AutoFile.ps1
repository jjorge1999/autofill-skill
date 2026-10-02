<#
.SYNOPSIS
  Unattended filing: HCM Telecommuting for WFH days (daily) and the XM weekly timesheet (Fridays).
.DESCRIPTION
  Run by the 'InforAutofill-File' scheduled task. Asks only about workdays with no network reading.
  Design: docs/superpowers/specs/2026-10-02-auto-file-design.md
.PARAMETER WhatIf
  Print what would be considered; no browser, no question dialog, no state change.
.PARAMETER Force
  Reconsider the last 14 days and the last 2 XM weeks regardless of the saved state (filers stay idempotent).
#>
[CmdletBinding()]
param(
    [switch]$WhatIf,
    [switch]$Force,
    [string]$ConfigPath,
    [datetime]$Today = (Get-Date).Date
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty when Windows PowerShell 5.1 runs -File with redirected stdin
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
. (Join-Path $here 'Presence.Common.ps1')
. (Join-Path $here 'AutoFile.Common.ps1')
. (Join-Path $here 'AutoFile.UI.ps1')

$config = Get-InforConfig -Path $ConfigPath
$dataDir = Split-Path -Parent (Resolve-LogPath $config.log_path)
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$statePath = Join-Path $dataDir 'autofile-state.json'
$runLogPath = Join-Path $dataDir 'autofile.log'
$leavePath = Join-Path $dataDir 'hcm-leave.json'
$overridesPath = Join-Path $here 'hcm\overrides.json'
$hcmScript = Join-Path $here 'hcm\run-hcm.ps1'
$xmScript = Join-Path $here 'xm\run-xm.ps1'

function Write-RunLog([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if (-not $WhatIf) { Add-Content -LiteralPath $runLogPath -Value $line -Encoding UTF8 }
}

$script:FilerOutput = @()
function Invoke-Filer {
    # Runs a wrapper; on exit 5 (sign-in needed) notifies, reruns it visibly (5-minute login wait) and returns that code.
    param([string]$Name, [string]$Script, [object[]]$Arguments)
    $script:FilerOutput = @()
    $code = $null
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # node stderr must not abort the run
    try {
        foreach ($attempt in 1, 2) {
            $argsNow = if ($attempt -eq 1) { $Arguments } else { @($Arguments | Where-Object { $_ -ne '--headless' }) }
            Write-RunLog "$Name> $(Split-Path -Leaf $Script) $($argsNow -join ' ')"
            & $Script @argsNow *>&1 | ForEach-Object { $s = "$_"; $script:FilerOutput += $s; Write-RunLog "  $s" }
            $code = $LASTEXITCODE
            if ($code -ne 5 -or $attempt -eq 2) { break }
            Show-AutoFileNotification -Title 'Infor sign-in needed' -Text "Sign in to Infor ($Name) in the Edge window that opens now. Filing continues after sign-in." -IsError
        }
    } finally { $ErrorActionPreference = $eap }
    Write-RunLog "$Name exit $code"
    return $code
}

$lock = $null
if (-not $WhatIf) {
    try { $lock = [IO.File]::Open((Join-Path $dataDir 'autofile.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { Write-Host 'Another InforAutofill run is in progress; exiting.'; exit 0 }
}

$filed = @()
$failed = @()
try {
    Write-RunLog "=== run for $(ConvertTo-IsoDate $Today)$(if ($WhatIf) { ' (WhatIf)' })"
    if (-not $WhatIf) { & (Join-Path $here 'Detect-Presence.ps1') -ConfigPath $ConfigPath }

    $state = Read-AutoFileState -Path $statePath -Today $Today
    if ($Force) { $state.hcmCoveredThrough = ConvertTo-IsoDate $Today.AddDays(-15); $state.xmWeeksDone = @() }
    $range = Get-HcmRange -State $state -Today $Today
    # Get-XmWeeksDue returns ,$due (keeps an empty list); wrapping the call in @() would nest it again
    $xmWeeks = Get-XmWeeksDue -State $state -Today $Today
    $xmWeeks = @($xmWeeks)
    if (-not $range -and -not $xmWeeks.Count) { Write-RunLog 'Nothing due.'; return }

    # one HCM pass covers the HCM range and every due XM week (Mon-Fri) so the leave export serves both
    $from = if ($range) { $range.From } else { $Today }
    foreach ($w in $xmWeeks) { if ($w.AddDays(1) -lt $from) { $from = $w.AddDays(1) } }
    $to = $Today
    Write-RunLog ("HCM range {0}; XM weeks due: {1}" -f $(if ($range) { "$(ConvertTo-IsoDate $range.From)..$(ConvertTo-IsoDate $range.To)" } else { 'none' }),
        $(if ($xmWeeks.Count) { ($xmWeeks | ForEach-Object { ConvertTo-IsoDate $_ }) -join ', ' } else { 'none' }))

    $summary = @(& (Join-Path $here 'Get-DailySummary.ps1') -From $from -To $to -ConfigPath $ConfigPath)
    $overrides = Read-JsonMap -Path $overridesPath

    if ($WhatIf) {
        foreach ($s in $summary) { Write-RunLog ("  {0} {1} {2}{3}" -f $s.date, $s.day, $s.status, $(if ($overrides.ContainsKey($s.date)) { " (override: $($overrides[$s.date]))" })) }
        $p = @(Get-PendingDays -Summary $summary -Overrides $overrides -Leave @{})
        Write-RunLog ("Would ask about (before checking HCM leave): {0}" -f $(if ($p.Count) { $p -join ', ' } else { 'none' }))
        return
    }

    # --- HCM: file WFH days and export leave
    Remove-Item -LiteralPath $leavePath -ErrorAction SilentlyContinue
    $hcmArgs = @('-From', (ConvertTo-IsoDate $from), '-To', (ConvertTo-IsoDate $to), '--mode', 'submit', '--headless', '--leave-out', $leavePath)
    $hcmCode = Invoke-Filer -Name 'HCM' -Script $hcmScript -Arguments $hcmArgs
    $filed += @($script:FilerOutput | Select-String '^\s+(\d{4}-\d{2}-\d{2}) \S+ \(\d+\): filed' | ForEach-Object { "HCM Telecommuting $($_.Matches[0].Groups[1].Value)" })
    $leaveKnown = Test-Path -LiteralPath $leavePath
    if ($hcmCode -ne 0) { $failed += "HCM (exit $hcmCode)" }
    $leave = if ($leaveKnown) { Read-JsonMap -Path $leavePath } else { @{} }

    # --- ask only about days nothing explains (needs HCM leave, otherwise a leave day would be asked about)
    $pending = @()
    if ($leaveKnown) {
        $pending = @(Get-PendingDays -Summary $summary -Overrides $overrides -Leave $leave)
        if ($pending.Count) {
            Write-RunLog "Asking about: $($pending -join ', ')"
            $answers = Show-DayQuestion -Dates $pending
            if ($answers.Count) {
                Merge-OverrideAnswers -Path $overridesPath -Answers $answers
                Write-RunLog ("Answers: {0}" -f (($answers.Keys | Sort-Object | ForEach-Object { "$_=$($answers[$_])" }) -join ', '))
                $wfh = @($answers.Keys | Where-Object { $answers[$_] -eq 'wfh' } | Sort-Object)
                if ($wfh.Count) {
                    $code = Invoke-Filer -Name 'HCM' -Script $hcmScript -Arguments @('-From', $wfh[0], '-To', $wfh[-1], '--mode', 'submit', '--headless')
                    $filed += @($script:FilerOutput | Select-String '^\s+(\d{4}-\d{2}-\d{2}) \S+ \(\d+\): filed' | ForEach-Object { "HCM Telecommuting $($_.Matches[0].Groups[1].Value)" })
                    if ($code -ne 0) { $failed += "HCM answered days (exit $code)"; $hcmCode = $code }
                }
                $pending = @($pending | Where-Object { -not $answers.ContainsKey($_) })
            }
        }
    }
    if ($range -and $hcmCode -eq 0) {
        $state.hcmCoveredThrough = ConvertTo-IsoDate (Get-CoveredThrough -Range $range -Pending $pending)
    }

    # --- XM: fill and submit due weeks (unanswered unknown days count as worked, per the user's rule)
    foreach ($w in $xmWeeks) {
        $label = ConvertTo-IsoDate $w
        if (-not $leaveKnown) { $failed += "XM week of $label (HCM leave not read)"; continue }
        $code = Invoke-Filer -Name 'XM' -Script $xmScript -Arguments @('-Week', (ConvertTo-IsoDate $w.AddDays(1)), '-Leave', $leavePath,
            '--mode', 'submit', '--headless', '--assume-unknown-workday', '--non-interactive')
        if ($code -eq 0) { $filed += "XM timesheet week of $label"; $state.xmWeeksDone = @(@($state.xmWeeksDone) + $label) }
        elseif ($code -eq 3) { Write-RunLog "XM week of $label already has a timesheet; left alone."; $state.xmWeeksDone = @(@($state.xmWeeksDone) + $label) }
        else { $failed += "XM week of $label (exit $code)" }
    }

    Save-AutoFileState -State $state -Path $statePath
} catch {
    $failed += "orchestrator: $($_.Exception.Message)"
    Write-RunLog "ERROR $($_.Exception.Message)"
} finally {
    if (-not $WhatIf) {
        if ($failed.Count) {
            Show-AutoFileNotification -Title 'InforAutofill: something needs a look' -Text (($failed -join '; ') + ". Log: $runLogPath") -IsError
        } elseif ($filed.Count) {
            Show-AutoFileNotification -Title 'InforAutofill: filed' -Text ($filed -join '; ')
        }
        Write-RunLog ("=== done; filed: {0}; failed: {1}" -f $filed.Count, $failed.Count)
    }
    if ($lock) { $lock.Dispose() }
}
if ($failed.Count) { exit 1 }
exit 0
