---
name: infor-attendance
description: >
  File Infor HCM and XM attendance/timesheets for the user by driving the
  existing InforAutofill PowerShell scripts on their Windows PC. Use when the
  user talks about filing attendance, HCM, XM, timesheets, WFH/office days,
  marking leave/vacation/holiday/sick, submitting, dry runs, or asks "what days
  am I down for?". Always draft before submit, and never guess unknown days.
---

# Infor attendance auto-filer

Drive the user's existing **InforAutofill** scripts to file Infor **HCM**
(Telecommuting / leave) and the Infor **XM** weekly timesheet from the detected
office/WFH presence log. You run the real scripts; you do not reimplement them.

## WHEN TO USE

Trigger on phrases like:
- "file my attendance / timesheet for this week", "submit my timesheet", "file HCM / XM".
- "what days am I down for?", "show me my days", "review my summary".
- "mark Oct 19-20 as vacation / sick / holiday", "I was WFH on...", "mark leave".
- "dry run", "test fill without saving".
- Setup: "detection isn't set up", "capture the office network", "schedule the checks".

## ASSUMPTIONS / PRECONDITIONS

- Runs on the **user's Windows PC** with Kiro able to run **Windows PowerShell**
  (5.1+). All commands below are Windows PowerShell, run from the project root.
- Project root is **configurable; default `C:\InforAutofill`**. If you are not
  sure where it is, **ask the user to confirm the root** before running anything.
  `cd` to the root (or the `hcm`/`xm` subfolder) first.
- Node.js 18+ and Microsoft Edge are installed. `npm install` has already been
  run in `hcm\` and `xm\`. If a filer fails with "Dependencies missing. Run
  'npm install' in ..." then run `npm install` **once** in that subfolder and
  retry. Do not install anything else.
- Reference docs (point the user here, do not duplicate them):
  `GETTING-STARTED.md`, `README.md`, `hcm\README.md`, `xm\README.md`.

## HARD SAFETY RAILS (always apply)

1. **Never guess `unknown` days.** If any weekday is `unknown`, stop and ask the
   user to classify each date. Do not fabricate attendance.
2. **Draft before submit, always.** First run of HCM and XM is draft (no mode
   flag). Only run `--mode submit` after the user explicitly confirms they
   reviewed the drafts in the Infor UI.
3. **Never run `--mode submit`** on the first run or without that explicit
   confirmation.
4. Weekends are left untouched; the scripts skip them.

## CORE WORKFLOWS

### a) "Show me my days / what am I down for"

1. `cd <root>` then:
   ```powershell
   .\Get-DailySummary.ps1
   ```
   Default range is **start of this month through today**. For another range use
   `-From 2026-09-01 -To 2026-09-30` (yyyy-MM-dd).
2. Summarize back to the user in a short table of date / day / status, grouping
   `office`, `wfh`, and `unknown`. Status meanings:
   - `office` = at least one office-network reading that day.
   - `wfh` = off-office readings and no office readings.
   - `unknown` = no readings (PC off, maybe leave) or offline only. Never guessed.
3. If there are `unknown` weekdays, flag them and offer to classify + file.

### b) "File my attendance / timesheet for the week" (full safe sequence)

1. **Summary first:** run `.\Get-DailySummary.ps1` (step a).
2. **Resolve unknowns:** if ANY weekday is `unknown`, **STOP**. Ask the user to
   classify each unknown date. Do NOT guess.
3. **Apply the user's answers:**
   - Leave / special days -> edit `hcm\overrides.json` (create if missing). Shape:
     ```json
     { "2026-10-19": "vacation", "2026-10-20": "sick" }
     ```
     Valid values: `vacation`, `sick`, `holiday`, `wfh`, `office`, `skip`
     (`skip` = never file). Overrides win over the detected status.
   - Public holidays -> add to `xm\holidays.json`, an array of dates:
     ```json
     ["2026-12-25"]
     ```
4. **Draft HCM then XM** (no mode flag = draft default):
   ```powershell
   cd <root>\hcm
   .\run-hcm.ps1
   cd <root>\xm
   .\run-xm.ps1
   ```
   HCM files this month so far; `-From`/`-To` narrow the range. XM files the
   current Sun-Sat week; `-Week 2026-09-21` targets another week.
   Report results and the per-run log paths: HCM `hcm\logs\run-<timestamp>.json`,
   XM `xm\logs\run-*.json`. Interpret exit codes (see below).
5. **Submit only after confirmation:** once the user confirms they reviewed the
   drafts in Infor, run again with submit:
   ```powershell
   .\run-hcm.ps1 --mode submit
   .\run-xm.ps1 --mode submit
   ```
   Never jump straight to submit on the first run.

### c) "Mark these days as leave / vacation / holiday"

1. Edit `hcm\overrides.json` for the dates (values `vacation`/`sick`/`holiday`/
   `wfh`/`office`/`skip`), and add any public holidays to `xm\holidays.json`.
2. Confirm the edits back to the user, then offer to file (workflow b).

### d) "Dry run"

Fills every dialog/cell, screenshots it, then cancels. Nothing is submitted.
```powershell
cd <root>\hcm
.\run-hcm.ps1 --dry-run     # screenshots to hcm\screenshots\
cd <root>\xm
.\run-xm.ps1 --dry-run      # screenshots to xm\screenshots\
```
Report the screenshot directories. **XM caveat:** `--dry-run` still runs the
header Save (the hours grid only appears after it), so XM may keep an empty or
imported draft for that week. Tell the user to check XM after a dry run and
delete that draft if needed.

### e) First-ever run / login

The first HCM or XM run opens a Microsoft Edge window for a one-time Infor
SSO/MFA login. **Warn the user to complete that login when the window appears**;
the script waits up to 5 minutes. Run **without** `--headless` on the first run.
Sessions are saved under `%LOCALAPPDATA%\InforAutofill\browser-profile` (HCM) and
`%LOCALAPPDATA%\InforAutofill\browser-profile-xm` (XM), which are separate so both
can run at once. Add `--headless` only on later runs.

### f) Setup / not-yet-configured

If detection is not set up (no office network captured, every day `unknown`):
- Capture the office network **in the office, with the VPN off**:
  ```powershell
  cd <root>
  .\Find-OfficeNetwork.ps1      # press Y to save SSID / gateway MAC / DNS suffix
  ```
- Enable scheduled checks (and to remove: `-Uninstall`):
  ```powershell
  .\Install-Scheduler.ps1
  .\Install-Scheduler.ps1 -Uninstall
  ```
- Check live detection without logging it: `.\Detect-Presence.ps1 -Show`.
- Point the user to `GETTING-STARTED.md` for the full walkthrough.

## HOURS / RULES (do not change these; just know them)

- **XM workday** (`office`/`wfh`): 2h `ERP_M3_Experience` + 7h
  `ERP_M3_Maintenance` (+ 0h `General Internal Meetings`, 0h `Personal Time Off
  And Holidays`).
- **XM leave / holiday** (`vacation`/`sick`/`holiday`): 8h `Personal Time Off
  And Holidays`.
- **HCM `wfh`**: plan `248` Telecommuting, full day.
- Weekends are untouched by both filers.
- **HCM vacation/sick plan codes are currently `null`** in `hcm\hcm.config.json`
  (`planCodes.vacation` / `planCodes.sick`). While null, HCM **skips** those
  overrides with a warning (`skipped-unconfigured`). If the user asks to file
  HCM vacation/sick, **warn them** those plan codes must be set in
  `hcm.config.json` first, or the days will not be filed in HCM. (XM still files
  such days as 8h leave regardless.)

## EXIT CODES

**XM (`run-xm.ps1`):**
- `0` done.
- `1` error, including a failed grid check (nothing saved).
- `2` unknown days: nothing filled. **Surface the listed unknown dates to the
  user** and ask them to add them to `hcm\overrides.json` (or re-run with
  `--assume-unknown-workday` only if the user says to treat them as workdays).
- `3` a timesheet for that week already exists (nothing changed).
- `4` the new-timesheet (Document Header) screen was not reached.

**HCM (`run-hcm.ps1` / `file-hcm.js`):**
- Exit `1` if any date ended in `error`. Per-date results in the run log include
  `filed`, `filed-unverified`, `skipped-existing`, `skipped-holiday`,
  `skipped-weekend`, `skipped-future`, `skipped-office`, `skipped-unconfigured`,
  `needs-input`, `dry-run`, `error`. Report any `error` dates (log includes the
  dialog message and a screenshot) and any `needs-input` (unknown) dates.

## USEFUL FLAGS

- HCM: `--summary`, `--overrides`, `--from`/`-From`, `--to`/`-To`,
  `--mode draft|submit`, `--dry-run`, `--headless`, `--allow-future`,
  `--config <file>`. Default mode is **draft**.
- XM: `-Week <yyyy-MM-dd>`, `--mode draft|submit`, `--dry-run`, `--headless`,
  `--assume-unknown-workday`. Default mode is **draft**.
