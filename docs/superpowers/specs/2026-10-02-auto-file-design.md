# Unattended filing (HCM Telecommuting + XM weekly timesheet)

Date: 2026-10-02
Status: approved design, not yet implemented

## Goal

File Infor HCM "Telecommuting: Full Day" and the Infor XM weekly timesheet without manual steps.
The user is only involved when the tool cannot be sure what a day was, or when Infor needs a fresh sign-in.

## Rules

Day status comes from `Get-DailySummary.ps1` (`Get-DayStatus`): `office` if any office reading,
`wfh` if at least one remote reading and no office reading, otherwise `unknown`.

| Case | Action | Asks the user? |
|---|---|---|
| Workday is `wfh` | HCM: submit Telecommuting Full Day (plan 248) | No |
| Workday is `office` (includes mixed office + remote) | HCM: nothing | No |
| Workday has a Vacation / Sick / Leave / holiday entry in HCM (pending or approved) | HCM: nothing. XM: leave, 8 h | No |
| Workday is `unknown` and has no HCM leave entry | Ask "WFH / Office / Leave"; save the answer to `hcm/overrides.json`; WFH then files HCM | **Yes** |
| Unanswered `unknown` day at XM time | XM: counted as worked, 9 h (user rule: Mon-Fri worked unless leave in HCM) | No |
| Friday (or first run after a missed Friday): XM week has every weekday worked or leave | XM: fill and **submit** | No |
| XM week already has a timesheet with hours, or grid verification fails | Nothing touched; notification with the reason | No |
| Infor session expired | Notification; visible Edge window opens for SSO/MFA; run continues after sign-in | Sign-in only |

Hours (already in `xm/xm.config.json`): worked day = ERP_M3_Experience 2 + ERP_M3_Maintenance 7 = 9 h; leave day =
Personal Time Off And Holidays 8 h. A full week is 45.00.

Never filed automatically: future days, office days, leave days in HCM.

## Components

### 1. Scheduled task `InforAutofill-File`
Registered by `Install-Scheduler.ps1` next to the existing `InforAutofill-PresenceCheck`.
Triggers: Mon-Fri 16:30 (after the 16:00 presence check) and at logon. `StartWhenAvailable`, runs only while the user
is logged on (interactive, needed for the browser and the question dialog), no admin rights. `-Uninstall` removes both.
The time is configurable as `file_time` in `config.json`.

### 2. Orchestrator `Invoke-AutoFile.ps1`
One run:
1. Log a fresh presence reading (`Detect-Presence.ps1`).
2. Read state from `%LOCALAPPDATA%\InforAutofill\autofile-state.json`:
   `{ "hcmCoveredThrough": "yyyy-MM-dd", "xmWeeksDone": ["yyyy-MM-dd", ...] }`.
3. HCM range = day after `hcmCoveredThrough` (at most 14 days back) through today.
4. Run the HCM filer headless in submit mode for that range. The same run exports HCM leave entries (see 3).
5. Ask about `unknown` workdays in the range that have no HCM leave entry (see 4). Answers go to `hcm/overrides.json`.
   If any answer is WFH, run the HCM filer again for just those dates.
6. Advance `hcmCoveredThrough` to the last date that is no longer pending (filed, skipped by rule, or answered).
   Unanswered `unknown` days stay pending and are asked again next run.
7. XM weeks due = the current Sun-Sat week if today is Friday or Saturday, plus any earlier week (at most 2 back)
   not in `xmWeeksDone`. Weeks before the first run of the task count as done. For each, run the XM filer headless with `--mode submit --assume-unknown-workday` and the leave file.
   On exit 0, or exit 3 (timesheet already exists with hours), add the week to `xmWeeksDone`.
8. Notify: one Windows notification summarising what was filed, or the failure reason and run-log path.

Switches: `-WhatIf` (print the plan from the presence log, state and overrides; no browser, no changes),
`-Force` (ignore state and reconsider the window). A lock file prevents two runs at once.

### 3. HCM leave export (`file-hcm.js --leave-out <file>`)
While reading the calendar months it already visits, collect entries whose text matches
`leaveTextRegex` (config; default `Vacation|Sick|Leave|Holiday`) and not `Rejected`, plus cells matching
`holidaySelector`. Write `{ "yyyy-MM-dd": "vacation" | "sick" | "leave" | "holiday" }`. Telecommuting entries are not leave.
The XM wrapper accepts `-Leave <file>` and merges it under `overrides.json` (explicit overrides win).
For the XM week the orchestrator makes sure the HCM range covers the whole Mon-Fri week.

### 4. Question dialog
A small WinForms dialog shown by the orchestrator (interactive session): one row per uncertain day with
WFH / Office / Leave buttons, plus "Ask me later". No extra software. If no user session is visible, nothing is asked
and the days stay pending.

### 5. Headless login detection (exit code 5)
Both filers, when `--headless` and a login form is visible (or the app URL never loads within 60 s), stop at once
with exit code 5 instead of waiting 5 minutes. The orchestrator then notifies "Infor sign-in needed", reruns that
filer without `--headless` (the existing 5-minute visible login wait), and continues.

### 6. Wrapper robustness
`run-hcm.ps1` / `run-xm.ps1` must not abort when node writes warnings to stderr while output is redirected
(the cause of the empty XM draft on 2026-10-02): call node with `$ErrorActionPreference = 'Continue'` around the
native call and rely on `$LASTEXITCODE`.

## Error handling

- A filer exit code other than 0 (or 3 for XM) leaves state unchanged for that part, so the next run retries.
- XM is never submitted unless the existing grid verification passes; HCM is never submitted unless the dialog
  shows the right plan, dates and Full Day (existing checks).
- Each orchestrator run appends to `%LOCALAPPDATA%\InforAutofill\autofile.log` (start, plan, filer exit codes).

## Testing

- HCM mock: leave export (vacation, sick, holiday, rejected, telecommuting entries) and exit code 5 when headless
  hits the login form.
- XM mock: `-Leave` merge gives 8 h rows; exit code 5 on the headless login form.
- Orchestrator: Pester-free PowerShell test script covering the pure parts: range calculation from state,
  pending/unknown selection, XM week selection (Friday, missed Friday, done weeks).
- `Invoke-AutoFile.ps1 -WhatIf` checked against the real log, then one supervised live run before the task is enabled.

## Out of scope

Editing submitted or non-empty XM timesheets, advance (future) filing, email notifications.
