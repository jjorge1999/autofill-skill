<#
.SYNOPSIS
  Unattended filing: HCM Telecommuting for WFH days (daily) and the XM weekly timesheet (Fridays).
.DESCRIPTION
  Run by the 'InforAutofill-File' scheduled task. Asks only about workdays with no network reading.
  Design: docs/superpowers/specs/2026-10-02-auto-file-design.md
.PARAMETER WhatIf
  Print what would be considered; no browser, no question dialog, no state change.
.PARAMETER Force
  Reconsider the last 14 days for HCM regardless of the saved state (the HCM filer stays idempotent).
  XM weeks already filed stay done; -Force never redoes XM.
.PARAMETER Today
  Pretend the run happens at the end of this day (testing / catching up). Must not be later than the real date.
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
if ($Today.Date -gt (Get-Date).Date) {
    throw "-Today $(ConvertTo-IsoDate $Today) is later than the real date $(ConvertTo-IsoDate (Get-Date).Date); future days are never filed."
}

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
$attention = @()
try {
    Write-RunLog "=== run for $(ConvertTo-IsoDate $Today)$(if ($WhatIf) { ' (WhatIf)' })"
    if (-not $WhatIf) {
        # a failed presence check must not stop the filing of days already in the log
        try { & (Join-Path $here 'Detect-Presence.ps1') -ConfigPath $ConfigPath }
        catch { $attention += "presence check failed: $($_.Exception.Message)"; Write-RunLog "WARNING presence check failed: $($_.Exception.Message)" }
    }

    $fileTime = if ($config.file_time) { [string]$config.file_time } else { '16:30' }
    $includeToday = (Get-Date) -ge $Today.Date.Add([timespan]::ParseExact($fileTime, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture))
    if ($PSBoundParameters.ContainsKey('Today')) { $includeToday = $true }   # explicit -Today = end of that day
    $lastDay = if ($includeToday) { $Today } else { $Today.AddDays(-1) }
    Write-RunLog ("Today counted: {0}" -f $(if ($includeToday) { 'yes' } else { "no (before $fileTime)" }))

    $state = Read-AutoFileState -Path $statePath -Today $Today
    if ($Force) { Reset-AutoFileStateForForce -State $state -Today $Today }
    # the caps below must never drop days silently: anything past them becomes an attention item
    $skippedHcm = Get-SkippedHcmDays -State $state -Today $lastDay
    if ($skippedHcm) {
        $attention += "HCM days $(ConvertTo-IsoDate $skippedHcm.From)..$(ConvertTo-IsoDate $skippedHcm.To) not checked (over 14 days back) - check them in HCM"
    }
    # Get-SkippedXmWeeks / Get-XmWeeksDue return ,$list (keeps an empty list); wrapping the call in @() would nest it again
    $skippedWeeks = Get-SkippedXmWeeks -State $state -Today $lastDay
    $skippedWeeks = @($skippedWeeks)
    if ($skippedWeeks.Count) {
        $labels = @($skippedWeeks | ForEach-Object { ConvertTo-IsoDate $_ })
        $attention += "XM weeks of $($labels -join ', ') not filed (over 2 weeks back) - file them in XM"
        $state.xmWeeksSkipped = @(@($state.xmWeeksSkipped) + $labels)   # reported once
    }
    foreach ($a in $attention) { Write-RunLog "Attention: $a" }
    $range = Get-HcmRange -State $state -Today $lastDay
    $xmWeeks = Get-XmWeeksDue -State $state -Today $lastDay
    $xmWeeks = @($xmWeeks)
    if (-not $range -and -not $xmWeeks.Count) {
        Write-RunLog 'Nothing due.'
        if (-not $WhatIf -and $skippedWeeks.Count) { Save-AutoFileState -State $state -Path $statePath }
        return
    }

    # one HCM pass covers the HCM range and every due XM week (Mon-Fri) so the leave export serves both
    $from = if ($range) { $range.From } else { $lastDay }
    foreach ($w in $xmWeeks) { if ($w.AddDays(1) -lt $from) { $from = $w.AddDays(1) } }
    $to = $lastDay
    Write-RunLog ("HCM range {0}; XM weeks due: {1}" -f $(if ($range) { "$(ConvertTo-IsoDate $range.From)..$(ConvertTo-IsoDate $range.To)" } else { 'none' }),
        $(if ($xmWeeks.Count) { ($xmWeeks | ForEach-Object { ConvertTo-IsoDate $_ }) -join ', ' } else { 'none' }))

    $summary = @(& (Join-Path $here 'Get-DailySummary.ps1') -From $from -To $to -ConfigPath $ConfigPath)
    $overrides = Read-JsonMap -Path $overridesPath

    if ($WhatIf) {
        foreach ($s in $summary) {
            $note = ''
            if ($overrides.ContainsKey($s.date)) {
                $note = " (override: $($overrides[$s.date]))"
                # file-hcm.js never files a day with an office reading, whatever the override says
                if ($s.status -eq 'office' -and $overrides[$s.date] -notmatch '^(office|skip|none|ignore|leave)$') { $note += ' - ignored for HCM: office reading' }
            }
            Write-RunLog ("  {0} {1} {2}{3}" -f $s.date, $s.day, $s.status, $note)
        }
        $p = @(Get-PendingDays -Summary $summary -Overrides $overrides -Leave @{})
        Write-RunLog ("Would ask about (before checking HCM leave): {0}" -f $(if ($p.Count) { $p -join ', ' } else { 'none' }))
        return
    }

    # --- HCM: file WFH days and export leave
    Remove-Item -LiteralPath $leavePath -ErrorAction SilentlyContinue
    $hcmArgs = @('-From', (ConvertTo-IsoDate $from), '-To', (ConvertTo-IsoDate $to), '--mode', 'submit', '--headless', '--leave-out', $leavePath)
    $hcmCode = Invoke-Filer -Name 'HCM' -Script $hcmScript -Arguments $hcmArgs
    $hf = Get-HcmFilerFindings -Output $script:FilerOutput
    $filed += @($hf.Filed | ForEach-Object { "HCM Telecommuting $_" })
    $unverified = @($hf.Unverified)
    foreach ($o in $hf.OfficeReading) { $attention += "HCM $($o.Date): office reading, override '$($o.Override)' ignored - not filed" }
    foreach ($u in $hf.Unrecognised) { $attention += "HCM $($u.Date): unrecognised entry '$($u.Text)' - check it" }
    $unrecognisedDates = @($hf.Unrecognised | ForEach-Object { $_.Date })
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
                    $hf2 = Get-HcmFilerFindings -Output $script:FilerOutput
                    $filed += @($hf2.Filed | ForEach-Object { "HCM Telecommuting $_" })
                    $unverified += @($hf2.Unverified)
                    if ($code -ne 0) { $failed += "HCM answered days (exit $code)"; $hcmCode = $code }
                }
                $pending = @($pending | Where-Object { -not $answers.ContainsKey($_) })
                $overrides = Read-JsonMap -Path $overridesPath
            }
        }
    }
    # an unconfirmed HCM filing is not reported as filed; its day stays uncovered so the next run checks it again
    $unverified = @($unverified | Sort-Object -Unique)
    foreach ($u in $unverified) { $attention += "HCM $u filed but not seen on the calendar - check it in HCM" }
    if ($range -and $hcmCode -eq 0 -and $leaveKnown) {
        $state.hcmCoveredThrough = ConvertTo-IsoDate (Get-CoveredThrough -Range $range -Pending (@($pending) + $unverified))
    }

    # --- XM: fill and submit due weeks (unanswered unknown days count as worked, per the user's rule)
    foreach ($w in $xmWeeks) {
        $label = ConvertTo-IsoDate $w
        if (-not $leaveKnown) { $failed += "XM week of $label (HCM leave not read)"; continue }
        # an HCM entry that is neither Telecommuting nor leave could change the hours: not filed until explained
        $blockers = @(Get-WeekBlockers -Week $w -Dates $unrecognisedDates -Overrides $overrides)
        if ($blockers.Count) {
            Write-RunLog "XM week of $label skipped: unrecognised HCM entry on $($blockers -join ', ')"
            $attention += "XM week of $label not filed: unrecognised HCM entry on $($blockers -join ', ') (set the day in hcm/overrides.json to go on)"
            continue
        }
        $code = Invoke-Filer -Name 'XM' -Script $xmScript -Arguments @('-Week', (ConvertTo-IsoDate $w.AddDays(1)), '-Leave', $leavePath,
            '--mode', 'submit', '--headless', '--assume-unknown-workday', '--non-interactive')
        if ($code -eq 0 -and (Test-XmSubmitUnconfirmed -Output $script:FilerOutput)) {
            # not marked done: the next run retries, and the filer's exists-check then reports it if it was submitted
            $attention += "XM week of ${label}: submit not confirmed - check it in XM"
        }
        elseif ($code -eq 0) { $filed += "XM timesheet week of $label"; $state.xmWeeksDone = @(@($state.xmWeeksDone) + $label) }
        elseif ($code -eq 3) { Write-RunLog "XM week of $label already has a timesheet; left alone."; $attention += "XM week of $label already has a timesheet; not touched - check it in XM"; $state.xmWeeksDone = @(@($state.xmWeeksDone) + $label) }
        else { $failed += "XM week of $label (exit $code)" }
    }

    Save-AutoFileState -State $state -Path $statePath
} catch {
    $failed += "orchestrator: $($_.Exception.Message)"
    Write-RunLog "ERROR $($_.Exception.Message)"
} finally {
    if (-not $WhatIf) {
        if ($failed.Count -or $attention.Count) {
            # log path first: the notification text is cut at 250 characters
            Show-AutoFileNotification -Title 'InforAutofill: something needs a look' -Text ("Log: $runLogPath | " + (@($failed) + @($attention) -join '; ')) -IsError
        } elseif ($filed.Count) {
            Show-AutoFileNotification -Title 'InforAutofill: filed' -Text ($filed -join '; ')
        }
        Write-RunLog ("=== done; filed: {0}; failed: {1}" -f $filed.Count, $failed.Count)
    }
    if ($lock) { $lock.Dispose() }
}
if ($failed.Count) { exit 1 }
exit 0
