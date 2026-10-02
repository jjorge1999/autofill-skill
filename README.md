# InforAutofill – Part 1: office / WFH detection

> New here? See [GETTING-STARTED.md](GETTING-STARTED.md) for the full end-to-end setup walkthrough.

Records whether your PC is on the office network several times each workday. The unattended filing task (see below) uses this log.

Detection uses only local network identity: the Wi-Fi SSID, the default gateway's MAC address, and DNS suffixes on wired adapters. It does **not** use your public IP, because a corporate VPN would make home look like the office.

## Setup (Windows)

1. Copy this folder to `C:\InforAutofill`.
2. **In the office, with the VPN off**, open PowerShell and run the following. Answer `Y` to save the office SSID, gateway MAC and DNS suffix to `config.json`:
   ```powershell
   cd C:\InforAutofill
   powershell -ExecutionPolicy Bypass -File .\Find-OfficeNetwork.ps1
   ```
3. Install the scheduled tasks. The presence check runs at `check_times` on `workdays` and also when you log on; the filing task is described under "Unattended filing":
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-Scheduler.ps1
   ```
   To remove both, run `.\Install-Scheduler.ps1 -Uninstall`.
4. Check what the tool detects right now. This prints the result without logging it:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Detect-Presence.ps1 -Show
   ```
5. View the per-day summary. The default range is the start of this month through today:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Get-DailySummary.ps1
   powershell -ExecutionPolicy Bypass -File .\Get-DailySummary.ps1 -From 2025-06-01 -To 2025-06-30 -AsJson -JsonPath .\june.json
   ```

## Day status

| status    | meaning |
|-----------|---------|
| `office`  | at least one reading that day was on the office network |
| `wfh`     | at least one off-office network reading and no office readings |
| `unknown` | no readings (PC off, maybe leave), or offline only. The tool never guesses these days. |

Only readings taken before `file_time` (default 16:30) count: an evening reading never decides a day.

On Windows 11 24H2 and later, Windows only reports the Wi-Fi SSID when Location services are on. If they're off, detection still works through the gateway MAC that `Find-OfficeNetwork.ps1` saved.

Log: `%LOCALAPPDATA%\InforAutofill\presence.csv` (`log_path` in `config.json`).
Logic tests: `powershell -File .\Tests\Test-Logic.ps1`, `.\Tests\Test-Summary.ps1`, `.\Tests\Test-AutoFile.ps1`, `.\Tests\Test-Wrappers.ps1` (and `.\Tests\Test-UI.ps1`, which shows the question dialog for 3 seconds).

## Unattended filing

The `InforAutofill-File` scheduled task runs `Invoke-AutoFile.ps1` on workdays at `file_time` (default 16:30, set in `config.json`) and 2 minutes after you log on. It logs a fresh presence reading, files HCM "Telecommuting: Full Day" for work-from-home days, and fills and submits the XM weekly timesheet.

A day is filed only once its readings are complete. Today counts only at or after `file_time`; a run before that (for example at logon) handles days up to yesterday. Friday's XM week also waits until Friday at `file_time`, and a Saturday or Monday logon catches it up.

| Case | Action | Asks you? |
|---|---|---|
| Workday is `wfh` | HCM: submit Telecommuting Full Day (plan 248) | No |
| Workday is `office` (includes mixed office + remote) | HCM: nothing, even if `hcm/overrides.json` says `wfh` (that override is ignored and reported) | No |
| Workday has a Vacation / Sick / Leave / holiday entry in HCM (pending or approved) | HCM: nothing. XM: leave, 8 h | No |
| Workday is `unknown` and has no HCM leave entry | Ask "WFH / Office / Leave"; the answer is saved to `hcm/overrides.json`; WFH then files HCM. "Leave" files nothing in HCM (file the leave yourself); XM counts it 8 h. The dialog closes by itself after 15 minutes, same as "Ask me later" | **Yes** |
| HCM day has an entry that is neither Telecommuting nor leave (e.g. Official Business) | Notification; that day's XM week is not filed until the day is set in `hcm/overrides.json` | No |
| HCM leave entry and a `wfh`/`office` override on the same day | XM: leave, 8 h (HCM leave wins; a leave-type override still wins over HCM) | No |
| Unanswered `unknown` day at XM time | XM: counted as worked, 9 h | No |
| XM week has every weekday worked or leave (Friday at `file_time`, or a later catch-up) | XM: fill and **submit** | No |
| XM week already has a timesheet that is not an empty draft | Left alone; notification to check it in XM | No |
| HCM request or XM submit not confirmed on screen | Notification to check it; not counted as filed, retried next run | No |
| Days more than 14 days back (HCM) or weeks more than 2 weeks back (XM) not yet handled | Not filed; notification listing them (XM weeks reported once) | No |
| Infor session expired | Notification; an Edge window opens for SSO/MFA; the run continues after sign-in | Sign-in only |

Hours: a worked day is 9 h (ERP_M3_Experience 2 + ERP_M3_Maintenance 7), a leave day is 8 h (Personal Time Off And Holidays). Future days, office days and leave days are never filed in HCM.

- Run log: `%LOCALAPPDATA%\InforAutofill\autofile.log`. State: `%LOCALAPPDATA%\InforAutofill\autofile-state.json`.
- Preview (no browser, no dialog, no changes): `.\Invoke-AutoFile.ps1 -WhatIf` lists the day statuses (with overrides) and the days it would ask about. It does not open HCM or XM, so it cannot see HCM leave (a leave day may be listed as one it would ask about) and does not check XM.
- `-Force` reconsiders the last 14 days for HCM; XM weeks already filed stay done. `-Today` cannot be later than the real date.
- Remove both scheduled tasks: `.\Install-Scheduler.ps1 -Uninstall`
