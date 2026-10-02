# InforAutofill – Part 1: office / WFH detection

> New here? See [GETTING-STARTED.md](GETTING-STARTED.md) for the full end-to-end setup walkthrough.

Records whether your PC is on the office network several times each workday. Part 2 will use this log to file entries automatically.

Detection uses only local network identity: the Wi-Fi SSID, the default gateway's MAC address, and DNS suffixes on wired adapters. It does **not** use your public IP, because a corporate VPN would make home look like the office.

## Setup (Windows)

1. Copy this folder to `C:\InforAutofill`.
2. **In the office, with the VPN off**, open PowerShell and run the following. Answer `Y` to save the office SSID, gateway MAC and DNS suffix to `config.json`:
   ```powershell
   cd C:\InforAutofill
   powershell -ExecutionPolicy Bypass -File .\Find-OfficeNetwork.ps1
   ```
3. Install the scheduled task. It runs at `check_times` on `workdays` and also when you log on:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-Scheduler.ps1
   ```
   To remove it, run `.\Install-Scheduler.ps1 -Uninstall`.
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

## Part 2 (pending)

Automatic filing in Infor HCM (Calendar → "Telecommuting: Full Day") and in Infor XM payroll through Playwright. This is waiting on screenshots of both forms.
