# Infor XM weekly timesheet

`file-xm.js` creates the XM timesheet for one Sun–Sat week. It imports last week's timesheet, then overwrites every weekday cell of every row using the rules below. It never keeps the imported values, because those still contain last week's leave.

| day | ERP_M3_Experience | ERP_M3_Maintenance | General Internal Meetings | Personal Time Off And Holidays |
|---|---|---|---|---|
| office / wfh | 2 | 7 | 0 | 0 |
| vacation / sick / holiday | 0 | 0 | 0 | 8 |

Weekends are left untouched. You can change the rules in `hours` in `xm.config.json`.

## Setup

```powershell
cd C:\InforAutofill\xm
npm install
```

## Run (on Friday, after the last presence check)

```powershell
.\run-xm.ps1 --dry-run          # fill everything, take a screenshot, then Cancel
.\run-xm.ps1                    # this week, Save as draft (default --mode draft)
.\run-xm.ps1 --mode submit      # Save, then Submit and confirm
.\run-xm.ps1 -Week 2026-09-21   # any date in the week you want
```

On the first run, log in to the Edge window that opens. You have up to 5 minutes. The login is kept in `%LOCALAPPDATA%\InforAutofill\browser-profile-xm`, which is separate from the HCM profile so both can run at once. Add `--headless` only after that first login.

## Day sources (highest priority first)

1. `xm/holidays.json`: public holidays, e.g. `["2026-12-25"]`.
2. `..\hcm\overrides.json`: e.g. `{"2026-10-19": "vacation"}`. Values are `vacation`, `sick`, `holiday`, `wfh` or `office`.
3. The presence summary (`office` / `wfh`).

If any weekday is still `unknown`, nothing is filled. The script exits with code 2 and lists the dates for you to add to `overrides.json`. Use `--assume-unknown-workday` to count those days as workdays instead.

## Exit codes

| code | meaning |
|---|---|
| 0 | done |
| 1 | error, including a failed grid check (nothing is saved) |
| 2 | unknown days |
| 3 | a timesheet for that week already exists (nothing is changed) |
| 4 | the new-timesheet screen was not reached |

Logs are written to `xm/logs/run-*.json` and screenshots to `xm/screenshots/`.

## Notes

- **Reaching the "Document Header" screen.** From the XM Inbox landing page the filler clicks the **Create a New...** button and then the **Timesheet** item in the menu that opens; those clicks live in `navigation` in `xm.config.json`. The selectors are text/role based and tolerate both the literal `...` and a unicode ellipsis in the button label. If the screen still doesn't show up, an interactive run asks you to open it yourself and press Enter. If XM changes those labels, edit `navigation` in `xm.config.json`.
- **`--dry-run` still runs the header Save**, because the hours grid only appears after it. XM may therefore keep an empty or imported draft for that week. Check it in XM after a dry run, and delete it if needed.
- **Grid cells are found by position**: the row whose charge-code text matches, crossed with the column headed `Mon 21/09` (and so on). If XM looks different, all selectors and formats can be changed in `xm.config.json`.
- **Test:** `npm test` runs the script against the mock in `test/mock-xm.html`.
