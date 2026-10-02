# Getting started

A single, in-order walkthrough for setting up InforAutofill on your Windows PC. Work through the sections top to bottom.

## 1. What this does

InforAutofill works out whether you were in the office or working from home each workday by looking only at the **network you are connected to**: the Wi-Fi SSID, the office gateway's MAC address, and the DNS suffix on a wired/dock connection. It deliberately ignores your public IP, so a corporate VPN cannot make home look like the office. It then auto-files your Infor **HCM** "Telecommuting: Full Day" entries and your Infor **XM** weekly timesheet from that record.

It only files what the detected network (and your manual overrides) say. Days with no readings show up as `unknown` (laptop off, possibly leave) and are **never guessed** - you decide what they were.

## 2. Prerequisites

- Windows with **Windows PowerShell 5.1+**.
- **Node.js 18+** on PATH (for the HCM/XM Playwright filers). Get it from [nodejs.org](https://nodejs.org/).
- **Microsoft Edge** (the filers drive it with a saved profile, so you complete Infor SSO/MFA login only once).

Then:

1. Copy this whole folder to, for example, `C:\InforAutofill`.
2. Allow the local scripts to run (once per user):
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

## 3. Capture the office network

Do this **while you are physically in the office, with the VPN OFF**. Run it once on **Wi-Fi** and once **docked/wired** so both signals are saved - the finder *merges* new values into whatever is already in `config.json`.

```powershell
cd C:\InforAutofill
.\Find-OfficeNetwork.ps1
```

It prints the current Wi-Fi SSID, default gateway MAC and DNS suffixes. Press `Y` to save. It writes `office_ssids`, `office_gateway_macs` and `wired_office_dns_suffixes` into `config.json`.

## 4. Verify and enable automatic detection

Check what the tool sees right now (prints without logging):

```powershell
.\Detect-Presence.ps1 -Show
```

Expect `office` while in the office, `remote` at home, and `offline` when there is no network. Once that looks right, register the scheduled checks:

```powershell
.\Install-Scheduler.ps1
```

This runs detection at the `check_times` in `config.json` (default `10:00`, `13:00`, `16:00`) on your `workdays`, plus at logon. To remove it later:

```powershell
.\Install-Scheduler.ps1 -Uninstall
```

## 5. Review the detected days

```powershell
.\Get-DailySummary.ps1
```

Each workday shows as `office`, `wfh`, or `unknown` (default range is the start of this month through today).

- `office` - at least one office-network reading that day.
- `wfh` - off-office readings and no office readings.
- `unknown` - no readings (PC off, maybe leave) or offline only. The tool never guesses these.

Before filing, resolve your `unknown` days:

- **Leave / special days:** edit `hcm\overrides.json` (create it if missing). Shape:
  ```json
  { "2026-10-19": "vacation" }
  ```
  Values are plan-code keys like `vacation` / `sick`, plus `office` / `wfh` / `skip`. Overrides win over the detected status.
- **Public holidays:** list them in `xm\holidays.json`, e.g. `["2026-12-25"]`.

## 6. File HCM

Files one Infor HCM entry per `wfh` day (plan `248`, Telecommuting, full day) and any override leave days.

```powershell
cd C:\InforAutofill\hcm
npm install
```

**First run:** run without `--headless`. An Edge window opens - complete the Infor SSO/MFA login once. The session is saved in `%LOCALAPPDATA%\InforAutofill\browser-profile` and reused afterwards.

```powershell
.\run-hcm.ps1 --dry-run     # fills each dialog, screenshots it, then Cancels - nothing saved
.\run-hcm.ps1               # DEFAULT: draft mode (fills requests without submitting)
.\run-hcm.ps1 --mode submit # only once you trust the drafts
```

The **default is draft** on purpose: it fills the requests without submitting so you can review them in the Infor UI first, then switch to `--mode submit`. See `hcm\README.md` for the full option list.

## 7. File the XM weekly timesheet

```powershell
cd C:\InforAutofill\xm
npm install
```

First run also opens an Edge window for login (saved separately in `%LOCALAPPDATA%\InforAutofill\browser-profile-xm`, so HCM and XM can run at once).

```powershell
.\run-xm.ps1 --dry-run       # fills, screenshots, then stops - review in XM
.\run-xm.ps1                 # this week, DEFAULT: draft mode
.\run-xm.ps1 --mode submit   # once you trust it
.\run-xm.ps1 -Week 2026-09-21  # any date in the target Sun-Sat week
```

Same draft-first safety as HCM. It reaches the new-timesheet screen via the **Create a New...** button then the **Timesheet** menu item, and overwrites **every weekday cell**:

- workday (`office` / `wfh`): 2h `ERP_M3_Experience` + 7h `ERP_M3_Maintenance`.
- leave / holiday: 8h `Personal Time Off And Holidays`.

If any weekday is still `unknown`, it files nothing and exits with code `2`, listing the dates to add to `overrides.json`. See `xm\README.md` for details and exit codes.

## 8. Typical weekly routine

1. Detection and filing run themselves via the scheduled tasks (presence checks all day, filing at 16:30 and after logon).
2. If a dialog asks about an `unknown` day, answer WFH / Office / Leave.
3. If a notification says Infor needs a sign-in, sign in in the Edge window that opens; the run continues.
4. If a notification says an XM week already has a timesheet, check it in XM; it is not touched.
5. If you answer "Leave" in the dialog, file that leave in HCM yourself (XM counts it 8 h; HCM gets nothing).
6. To preview what the next run would do: `.\Invoke-AutoFile.ps1 -WhatIf` (day statuses and the days it would ask about; it does not check HCM leave or XM).

## 9. A note on publishing

Publishing this project to GitHub is still pending (connection issue), so it currently lives only in the local git repo.
