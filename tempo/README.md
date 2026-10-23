# Tempo (Jira) daily worklogs

`file-tempo.js` makes sure every worked weekday holds **at least 8 h** in Tempo, through the Tempo REST API
(`https://api.tempo.io/4`). Missing hours go to the issues in `worklogs` in `tempo.config.json`.
No browser is involved.

| day | Tempo |
|---|---|
| Mon–Fri, office or WFH (or `unknown`, as for XM) | topped up to at least 8 h, split per `worklogs` |
| vacation / sick / leave / holiday (HCM leave, `hcm/overrides.json`, `xm/holidays.json`) | nothing |
| `skip` / `none` / `ignore` in `hcm/overrides.json` | nothing |
| weekend, future day | nothing |

## Setup (once)

1. **API token.** In Jira, open Tempo > Settings > **API integration** > New token (scope: worklogs view + manage).
   Store it encrypted for your Windows account (DPAPI) in `%LOCALAPPDATA%\InforAutofill\tempo-token.dpapi`:
   ```powershell
   .\Save-TempoToken.ps1                            # asks for the token, input hidden
   .\Save-TempoToken.ps1 -From C:\path\token.txt    # or reads it from a file (delete the file afterwards)
   .\run-tempo.ps1 --check                          # one read-only call: is the token accepted?
   ```
   `run-tempo.ps1` decrypts it for each run. Only your Windows account on this PC can read it; it is never written
   to the repo, config or logs. When the token expires, run `Save-TempoToken.ps1` again. (`TEMPO_API_TOKEN`, or a
   `tokenFile` path in the config, also work and are used first.)
2. **Issues and split.** Edit `tempo.config.json`, `worklogs`. The `hours` must add up to `dailyHours` (8):
   ```json
   "worklogs": [
     { "issueKey": "ABC-123", "issueId": 10001, "hours": 2, "description": "" },
     { "issueKey": "ABC-456", "issueId": 10002, "hours": 6, "description": "" }
   ]
   ```
   Optional per entry: `description` (default `defaultDescription`, else "Working on issue ABC-123") and
   `attributes` (Tempo work attributes, e.g. `[{"key": "_Account_", "value": "ACC1"}]`) if your Tempo requires them.
3. **Your account id and the numeric issue ids.** The Tempo v4 API takes numeric ids, not keys.
   Your account id is the end of your Jira profile URL (avatar > Profile: `.../jira/people/<accountId>`).
   `.\run-tempo.ps1 --recent 45 --account <accountId>` (read-only) then lists only your own worklogs of the last
   45 days: hours per issue id and per day, so you can see which issue ids you log to. Then either:
   - fill in `authorAccountId` (your Jira profile URL ends in it) and each `issueId`, or
   - set `JIRA_EMAIL` and `JIRA_API_TOKEN` (an Atlassian API token from id.atlassian.com) with `setx`, and leave them
     empty. They are then looked up on each run and printed, so you can paste them into the config.
4. Try it:
   ```powershell
   cd C:\InforAutofill\tempo
   .\run-tempo.ps1 -From 2026-10-19 -To 2026-10-23 --dry-run   # shows what it would log, posts nothing
   .\run-tempo.ps1 -From 2026-10-19 -To 2026-10-23             # logs it
   ```
   A manual run does not know HCM leave unless you pass `--leave <file>` (the scheduled run does). Put any leave
   days in `hcm\overrides.json` first.

## Daily run

`Invoke-AutoFile.ps1` (the 16:30 scheduled task) runs Tempo after HCM, for the days since the last Tempo run
(at most 14 days back), with the HCM leave export. It stores its own progress (`tempoCoveredThrough` in
`autofile-state.json`), so a Tempo failure never stops HCM/XM, and the days are retried on the next run.
Days with an unrecognised HCM entry (e.g. Official Business) are not logged until you set them in `hcm/overrides.json`.

## Safe to rerun

The day's existing Tempo worklogs (on **any** issue) are read before anything is posted:

- a day that already has 8 h or more is left alone;
- a day under 8 h gets only the missing hours, so it ends at exactly 8 h. They go to the `worklogs` issues in
  order, each up to its configured share not logged yet. Example with 2 h + 6 h: 1 h already on a meeting
  issue -> 2 h + 5 h added; 7 h already on the second issue -> 1 h added on the first.

After posting, the days are read back and must show at least 8 h.

## Exit codes

| code | meaning |
|---|---|
| 0 | done (or nothing to do) |
| 1 | error (HTTP, network, verification) |
| 3 | not set up: no token (run `Save-TempoToken.ps1`) or `tempo.config.json` incomplete |

Logs: `tempo/logs/run-*.json`. Test: `npm test` (runs against an in-memory fake API, no network).
