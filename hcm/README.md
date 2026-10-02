# Infor HCM auto-filer

Files one **Request Time Off** per day on the Infor HCM Employee Self Service calendar, using the
presence summary from `..\Get-DailySummary.ps1`:

| Day status / override | Action |
|---|---|
| `wfh` | files plan `248` (Telecommuting), full day |
| override `vacation` / `sick` / … | files the plan code configured in `planCodes` (skipped with a warning while it is `null`) |
| `office` | nothing |
| `unknown` | nothing. Listed at the end as "unknown days need your input" |

A date is also skipped if it is a weekend, after today (unless you pass `--allow-future`), or if the calendar
cell already has an entry or a holiday.

## Setup (once)

```powershell
cd infor-autofill\hcm
npm install
```

The script drives the Microsoft Edge that ships with Windows, so you can skip `npx playwright install`. If Edge
won't start, the script falls back to Playwright's Chromium. To use that fallback, run `npx playwright install chromium` once.

**First run:** run the script without `--headless`. An Edge window opens. Complete the Infor SSO/MFA login in that
window. The script waits up to 5 minutes for the calendar to appear. The session is stored in
`%LOCALAPPDATA%\InforAutofill\browser-profile` and reused on later runs.

## Usage

```powershell
.\run-hcm.ps1 --dry-run                       # fill each dialog, screenshot it to screenshots\, then Cancel
.\run-hcm.ps1                                 # this month so far, "Save as draft and submit later" (default)
.\run-hcm.ps1 -From 2026-09-01 -To 2026-09-30 --mode submit   # "Submit request for approval"

# or call node directly with an existing summary
node file-hcm.js --summary summary.json --from 2026-09-01 --to 2026-09-30 --mode draft
```

Options: `--summary`, `--overrides`, `--from`, `--to`, `--mode draft|submit`, `--dry-run`, `--headless`,
`--allow-future`, `--config <file merged over hcm.config.json>`.

The default mode is **draft** until you've checked the drafts in HCM. After that, switch to `--mode submit`.

**Leave days:** put them in `hcm\overrides.json`. Overrides win over the detected status:

```json
{ "2026-10-19": "vacation", "2026-10-20": "vacation", "2026-10-21": "office" }
```

Valid values are any key of `planCodes`, plus `office` / `skip` (never file).

**Results:** each run writes `logs\run-<timestamp>.json`. Every date gets one of these results:
`filed`, `filed-unverified`, `skipped-existing`, `skipped-holiday`, `skipped-weekend`, `skipped-future`,
`skipped-office`, `skipped-unconfigured`, `needs-input`, `dry-run`, or `error` (the error result includes the dialog's message
and a screenshot). The exit code is 1 if any date ended in `error`.

## Config (`hcm.config.json`)

- `urls.app`: the HCM calendar opened directly. `urls.portal` is the Mingle fallback, where the app sits in an iframe.
  Every frame is searched for the calendar.
- `planCodes`: `wfh` is `248`. Set `vacation` / `sick` to your plan codes before using those overrides.
  `planLabels` maps a code to the label that must appear after the code is entered, e.g. `248` → `Telecommuting`.
- `openStrategies`: how the dialog is opened, tried in order. `click` clicks an empty area of the day cell,
  `dblclick` double-clicks it, and `button` clicks a "Request Time Off" / "New Request" / "Add" button or menu item.
  The first strategy that works is reused for the rest of the run.
- `selectors`: every locator the script uses. Each one is a list of specs, tried in order:
  - `{"label": "..."}`
  - `{"role": "button", "name": "OK"}`
  - `{"text": "..."}`
  - `{"css": "..."}`
  - `{"near": "Dates", "nth": 1}`: the n-th input after a label with that text

  Strings like `"/regex/i"` are treated as regular expressions. Cell parsing uses `dayCell`, `dayNumber`,
  `otherMonthClassRegex`, `eventSelector`, and `holidaySelector`. If every day is reported as
  `skipped-holiday` because of stray cell text, set `cellTextIgnoreRegex`.

## Test

`npm test` runs `file-hcm.js` headless against `test\mock-hcm.html`. The mock is a local copy of the calendar and dialog,
rebuilt from screenshots. **The mock is not the real site.** Do your first real run with `--dry-run` and check the
screenshots. If a step fails there, adjust `selectors` / `openStrategies`.
