# InforAutofill window (dashboard)

Date: 2026-10-02
Status: approved design, not yet implemented

## Goal

A small, modern, minimalist desktop window to see what InforAutofill is doing and to trigger it, without a terminal and
without Claude. It is a front end only: all filing logic and safety rules stay in the existing scripts, which must keep
working unchanged whether or not the window is ever opened.

## Non-goals

- No filing logic in the window. It never talks to Infor itself.
- No changes to `Invoke-AutoFile.ps1`, `hcm/`, `xm/` filers or their rules.
- No tray icon, no background process, no server, no installer beyond shortcuts.

## Technology

Windows PowerShell 5.1 + WPF (PresentationFramework, built into Windows). Window XAML embedded in the script. Must run
with `-STA`. No extra software.

## Layout (single window, ~420 x 600, not resizable below that)

```
InforAutofill                         [● On]  [⚙]
Next run  Mon 5 Oct, 16:30
------------------------------------------------
Today · Fri 2 Oct
OFFICE                         last check 16:00
------------------------------------------------
This week
Mon   Tue   Wed   Thu   Fri
WFH   WFH   OFF   OFF   OFF        (click a day)
 ✓     ✓     –     –     –         HCM filed
XM  45.00 h · submitted
------------------------------------------------
[ Preview ]                 [ File now ]
▸ Log   (expands; shows the run live)
```

Style: flat, generous whitespace, Segoe UI (Segoe UI Variable when present), rounded cards, one accent colour,
light/dark from the Windows setting (`HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme`).
Status colours: WFH = accent, Office = neutral, Leave = amber, Unknown = muted with "?".

## Behaviour

| Element | Reads / does |
|---|---|
| Schedule switch | On = task `InforAutofill-File` exists. Toggling runs `Install-Scheduler.ps1` or `Install-Scheduler.ps1 -Uninstall` (both tasks, as that script already does). |
| Next run | `Get-ScheduledTaskInfo InforAutofill-File`.NextRunTime; "Off" when not installed. |
| Today | Status of today from the summary logic (`Get-DailySummary.ps1`, which already ignores readings at/after `file_time`) and the time of the last reading in the presence log. |
| This week | Mon-Fri of the current week. Per day: override from `hcm/overrides.json` if any (shown as such), else summary status. HCM mark: ✓ when any HCM run log (`hcm/logs/run-*.json`) has a result `filed` or `skipped-existing` for that date; "–" otherwise. |
| XM line | From the newest XM run log for this week (`xm/logs/run-*.json`): hours if known and result (saved draft / submitted / already exists / error), else "not filed yet". Plus "done" when the week is in `xmWeeksDone` of `%LOCALAPPDATA%\InforAutofill\autofile-state.json`. |
| Click a day | Menu: WFH / Office / Leave / Clear. Writes or removes the date in `hcm/overrides.json` (Leave writes `leave`). Allowed for past and future days of the shown week. Refreshes the view. Hint text: an office reading still wins over WFH; Leave must also be filed in HCM yourself. |
| Preview | Runs `Invoke-AutoFile.ps1 -WhatIf` in a child `powershell.exe`, streams its output into the Log panel. |
| File now | Same with a normal run (the same run the 16:30 task does). Buttons are disabled while a run is going; if another run holds the lock, the script itself exits and the log says so. Refreshes the view when done. |
| Settings (⚙) | Filing time (HH:mm, validated) → writes `file_time` in `config.json` and re-runs `Install-Scheduler.ps1` if the schedule is on. "Open log folder" (`%LOCALAPPDATA%\InforAutofill`). "Open README". |
| Refresh | On open, after a run, after a change, and every 60 s while open. |

Errors (missing files, unreadable logs) show as a quiet line in the card ("no data yet"), never a crash dialog.

## Components

| File | Responsibility |
|---|---|
| `Dashboard.Data.ps1` | Pure functions (no WPF): build the view model from the summary rows, overrides map, HCM/XM run-log objects, state and today's date. Override set/clear helpers. |
| `InforAutofill.ps1` | The window: XAML, theme, bindings to the view model, button/menu handlers, child-process runs with live output. |
| `Install-Ui.ps1` | Creates "InforAutofill" shortcuts on the Desktop and in the Start menu: `powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "<repo>\InforAutofill.ps1"`. `-Uninstall` removes them. |
| `Tests/Test-Dashboard.ps1` | Plain-script tests for `Dashboard.Data.ps1` (no Pester). |

## Testing

- `Tests/Test-Dashboard.ps1`: view model from fixtures (week chips with override vs reading, HCM ✓ from filed and
  skipped-existing, XM line states, empty/missing data), override set/clear round trip, file_time validation.
- Parse check of all new .ps1 files; PS 5.1 syntax only.
- Manual check with the user: open the window, toggle nothing destructive, Preview shows the log, mark/clear a day.
- Existing suites (`npm test` in hcm/ and xm/, Tests/Test-AutoFile.ps1, Test-Wrappers.ps1, Test-Summary.ps1) still pass
  and the filer scripts are unchanged.
