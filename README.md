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

On Windows 11 24H2 and later, Windows only reports the Wi-Fi SSID when Location services are on. If they're off, detection still works through the gateway MAC that `Find-OfficeNetwork.ps1` saved.

Log: `%LOCALAPPDATA%\InforAutofill\presence.csv` (`log_path` in `config.json`).
Logic tests: `powershell -File .\Tests\Test-Logic.ps1`.

## Unattended filing

The `InforAutofill-File` scheduled task runs `Invoke-AutoFile.ps1` on workdays at `file_time` (default 16:30, set in `config.json`) and 2 minutes after you log on. It logs a fresh presence reading, files HCM "Telecommuting: Full Day" for work-from-home days, and fills and submits the XM weekly timesheet.

A day is filed only once its readings are complete. Today counts only at or after `file_time`; a run before that (for example at logon) handles days up to yesterday. Friday's XM week also waits until Friday at `file_time`, and a Saturday or Monday logon catches it up.

| Case | Action | Asks you? |
|---|---|---|
| Workday is `wfh` | HCM: submit Telecommuting Full Day (plan 248) | No |
| Workday is `office` (includes mixed office + remote) | HCM: nothing | No |
| Workday has a Vacation / Sick / Leave / holiday entry in HCM (pending or approved) | HCM: nothing. XM: leave, 8 h | No |
| Workday is `unknown` and has no HCM leave entry | Ask "WFH / Office / Leave"; the answer is saved to `hcm/overrides.json`; WFH then files HCM | **Yes** |
| Unanswered `unknown` day at XM time | XM: counted as worked, 9 h | No |
| XM week has every weekday worked or leave (Friday at `file_time`, or a later catch-up) | XM: fill and **submit** | No |
| XM week already has a timesheet that is not an empty draft | Left alone; notification to check it in XM | No |
| Infor session expired | Notification; an Edge window opens for SSO/MFA; the run continues after sign-in | Sign-in only |

Hours: a worked day is 9 h (ERP_M3_Experience 2 + ERP_M3_Maintenance 7), a leave day is 8 h (Personal Time Off And Holidays). Future days, office days and leave days are never filed in HCM.

- Run log: `%LOCALAPPDATA%\InforAutofill\autofile.log`. State: `%LOCALAPPDATA%\InforAutofill\autofile-state.json`.
- Preview what a run would do (no browser, no dialog, no changes): `.\Invoke-AutoFile.ps1 -WhatIf`
- Remove both scheduled tasks: `.\Install-Scheduler.ps1 -Uninstall`
