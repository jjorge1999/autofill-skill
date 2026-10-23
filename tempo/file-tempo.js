#!/usr/bin/env node
'use strict';
/*
 * Makes every worked weekday hold at least `dailyHours` (8 h) in Tempo (Jira Cloud) through the Tempo REST API,
 * split across the issues in tempo.config.json `worklogs`.
 *
 *   node file-tempo.js --from 2026-10-19 --to 2026-10-23 [--leave hcm-leave.json] [--skip d1,d2]
 *                      [--dry-run] [--config tempo.config.json] [--overrides f] [--holidays f]
 *
 * Worked day = Mon-Fri that is not a holiday (xm/holidays.json), not leave or skip in hcm/overrides.json,
 * not leave in the HCM leave export (--leave), not in --skip, and not in the future. WFH vs office does not matter.
 * Leave days get nothing in Tempo.
 *
 * The day's existing Tempo worklogs (on any issue) are read first, so a rerun never logs twice: a day already
 * at 8 h or more is left alone, and a day under 8 h gets only the missing hours, on the configured issues in
 * config order (each up to its configured share).
 *
 * Secrets are never in tempo.config.json or arguments:
 *   Tempo token                  TEMPO_API_TOKEN, else the file named by tokenFile (Tempo > Settings > API integration)
 *   JIRA_EMAIL + JIRA_API_TOKEN  optional; used only to look up issue ids for issueKey and your accountId
 *                                when tempo.config.json does not give them
 *
 * Exit codes: 0 ok, 1 error, 3 not configured (token / config).
 */
const fs = require('fs');
const path = require('path');

const TEMPO_DIR = __dirname;
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const LEAVE = ['vacation', 'sick', 'holiday', 'leave'];
const SKIP = ['skip', 'none', 'ignore'];
const WORK = ['office', 'wfh'];
const EXIT = { OK: 0, ERROR: 1, CONFIG: 3 };
const MAX_DAYS = 31;

class TempoError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// ---------- args / config ----------
function parseArgs(argv) {
  const o = {};
  const takes = { '--from': 'from', '--to': 'to', '--leave': 'leave', '--skip': 'skip', '--config': 'config', '--recent': 'recent', '--account': 'account',
    '--overrides': 'overrides', '--holidays': 'holidays' };
  const flags = { '--dry-run': 'dryRun', '--check': 'check', '--help': 'help', '-h': 'help' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (takes[a]) {
      if (i + 1 >= argv.length) throw new TempoError('ARGS', `${a} needs a value`);
      o[takes[a]] = argv[++i];
    } else if (flags[a]) o[flags[a]] = true;
    else throw new TempoError('ARGS', `Unknown argument: ${a}`);
  }
  return o;
}

function readJson(file) {
  const buf = fs.readFileSync(file);
  let text;
  if (buf[0] === 0xff && buf[1] === 0xfe) text = buf.slice(2).toString('utf16le');
  else text = buf.toString('utf8');
  text = text.replace(/^﻿/, '').trim();
  return text ? JSON.parse(text) : {};
}
function resolveFrom(base, p) { return path.isAbsolute(p) ? p : path.resolve(base, p); }

/** Checks tempo.config.json and returns the worklog split in seconds. Throws CONFIG with every problem found. */
function validateConfig(cfg) {
  const problems = [];
  const daily = Number(cfg.dailyHours);
  if (!(daily > 0)) problems.push('dailyHours must be a positive number');
  if (!/^\d{1,2}:\d{2}(:\d{2})?$/.test(String(cfg.startTime || ''))) problems.push("startTime must look like '09:00'");
  const list = Array.isArray(cfg.worklogs) ? cfg.worklogs : [];
  if (!list.length) problems.push('worklogs needs at least one {issueKey, hours} entry');
  list.forEach((w, i) => {
    if (!String(w.issueKey || '').trim() && !w.issueId) problems.push(`worklogs[${i}] needs issueKey (e.g. "ABC-123") or issueId`);
    if (!(Number(w.hours) > 0)) problems.push(`worklogs[${i}] hours must be > 0`);
  });
  const sum = list.reduce((s, w) => s + (Number(w.hours) || 0), 0);
  if (list.length && daily > 0 && Math.round(sum * 3600) !== Math.round(daily * 3600)) {
    problems.push(`worklogs hours add up to ${sum}, not dailyHours ${daily}`);
  }
  const ids = list.map(w => String(w.issueId || w.issueKey || '').trim().toUpperCase()).filter(Boolean);
  if (new Set(ids).size !== ids.length) problems.push('worklogs lists the same issue twice; merge the entries');
  if (problems.length) throw new TempoError('CONFIG', 'tempo.config.json is not ready:\n  ' + problems.join('\n  '));
}

// ---------- dates ----------
function parseIso(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(s || '').trim());
  if (!m) return null;
  const d = new Date(+m[1], +m[2] - 1, +m[3], 12);
  return d.getMonth() === +m[2] - 1 ? d : null;
}
function iso(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function addDays(d, n) { const r = new Date(d); r.setDate(r.getDate() + n); return r; }

// ---------- day classification ----------
function loadMap(file) {
  if (!file || !fs.existsSync(file)) return {};
  const raw = readJson(file);
  const out = {};
  for (const [k, v] of Object.entries(raw || {})) if (parseIso(k)) out[k] = String(v).toLowerCase().trim();
  return out;
}
function loadHolidays(file) {
  if (!file || !fs.existsSync(file)) return new Set();
  const raw = readJson(file);
  return new Set((Array.isArray(raw) ? raw : []).map(x => (typeof x === 'string' ? x : x && x.date)).filter(x => parseIso(x)));
}

/**
 * One entry per date in from..to: kind 'work' (log hours) or 'skip' with a reason.
 * Holidays, leave overrides and HCM leave beat everything; a wfh/office override does not hide HCM leave.
 */
function classifyDays(from, to, src, cfg, today) {
  const weekend = cfg.weekendDays || [0, 6];
  const out = [];
  for (let d = from; iso(d) <= iso(to); d = addDays(d, 1)) {
    const date = iso(d);
    const day = { date, day: DAYS[d.getDay()] };
    const ov = src.overrides[date];
    if (weekend.includes(d.getDay())) out.push({ ...day, kind: 'skip', reason: 'weekend' });
    else if (date > today) out.push({ ...day, kind: 'skip', reason: 'future' });
    else if (src.holidays.has(date)) out.push({ ...day, kind: 'skip', reason: 'holiday (holidays.json)' });
    else if (ov && LEAVE.includes(ov)) out.push({ ...day, kind: 'skip', reason: `${ov} (overrides.json)` });
    else if (ov && SKIP.includes(ov)) out.push({ ...day, kind: 'skip', reason: `${ov} (overrides.json)` });
    else if (src.leave[date]) out.push({ ...day, kind: 'skip', reason: `${src.leave[date]} (HCM)` });
    else if (src.skip.has(date)) out.push({ ...day, kind: 'skip', reason: 'unexplained HCM entry (--skip)' });
    else if (ov && !WORK.includes(ov)) throw new TempoError('CONFIG', `overrides.json: '${date}' has unknown value '${ov}'`);
    else out.push({ ...day, kind: 'work' });
  }
  return out;
}

/** The Tempo token: TEMPO_API_TOKEN, else the first line of cfg.tokenFile. The value is never logged. */
function readToken(cfg, env) {
  if (env.TEMPO_API_TOKEN) return env.TEMPO_API_TOKEN.trim();
  if (cfg.tokenFile) {
    const file = expandEnv(cfg.tokenFile, env);
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch (e) { throw new TempoError('CONFIG', `tokenFile ${file} cannot be read: ${e.code || e.message}`); }
    const token = text.replace(/^﻿/, '').split(/\r?\n/).map(s => s.trim()).find(Boolean);
    if (!token) throw new TempoError('CONFIG', `tokenFile ${file} is empty`);
    return token;
  }
  throw new TempoError('CONFIG', 'No Tempo token: run .\\Save-TempoToken.ps1 in the tempo folder (or set TEMPO_API_TOKEN, or tokenFile in tempo.config.json). Create the token in Tempo > Settings > API integration.');
}
function expandEnv(p, env) { return String(p).replace(/%([^%]+)%/g, (m, name) => env[name] || process.env[name] || m); }

// ---------- HTTP ----------
async function request(fetchImpl, method, url, { auth, body, retries = 3 } = {}) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetchImpl(url, {
      method,
      headers: { Authorization: auth, Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 429 && attempt < retries) {
      const wait = Math.min(30, Number(res.headers && res.headers.get && res.headers.get('retry-after')) || 2 ** attempt);
      await new Promise(r => setTimeout(r, wait * 1000));
      continue;
    }
    const text = await res.text();
    if (!res.ok) {
      const hint = res.status === 401 ? ' (token wrong or expired?)' : res.status === 403 ? ' (token lacks permission?)' : '';
      throw new TempoError('HTTP', `${method} ${url.replace(/\?.*$/, '')} -> HTTP ${res.status}${hint}: ${text.slice(0, 400)}`);
    }
    return text ? JSON.parse(text) : null;
  }
}

/** Fills in issueId (from issueKey) and authorAccountId through the Jira REST API when the config leaves them out. */
async function resolveIds(cfg, env, fetchImpl, step) {
  const needIssue = cfg.worklogs.some(w => !w.issueId);
  const needAccount = !cfg.authorAccountId;
  if (!needIssue && !needAccount) return { accountId: cfg.authorAccountId, worklogs: cfg.worklogs.map(w => ({ ...w, issueId: Number(w.issueId) })) };
  if (!env.JIRA_EMAIL || !env.JIRA_API_TOKEN) {
    const what = [needAccount && 'authorAccountId', needIssue && 'issueId for ' + cfg.worklogs.filter(w => !w.issueId).map(w => w.issueKey).join(', ')].filter(Boolean).join(' and ');
    throw new TempoError('CONFIG', `tempo.config.json has no ${what}. Put them in tempo.config.json, or set JIRA_EMAIL and JIRA_API_TOKEN so they can be looked up.`);
  }
  const jira = String(cfg.jiraBaseUrl || '').replace(/\/+$/, '');
  if (!jira) throw new TempoError('CONFIG', 'jiraBaseUrl is needed to look up issue ids / accountId');
  const auth = 'Basic ' + Buffer.from(`${env.JIRA_EMAIL}:${env.JIRA_API_TOKEN}`).toString('base64');
  let accountId = cfg.authorAccountId;
  if (needAccount) {
    accountId = (await request(fetchImpl, 'GET', `${jira}/rest/api/3/myself`, { auth })).accountId;
    step(`Jira accountId ${accountId} (put it in authorAccountId to skip this lookup)`);
  }
  const worklogs = [];
  for (const w of cfg.worklogs) {
    if (w.issueId) { worklogs.push({ ...w, issueId: Number(w.issueId) }); continue; }
    const issue = await request(fetchImpl, 'GET', `${jira}/rest/api/3/issue/${encodeURIComponent(w.issueKey)}?fields=summary`, { auth });
    step(`Jira ${w.issueKey} = issue id ${issue.id} (${issue.fields && issue.fields.summary})`);
    worklogs.push({ ...w, issueId: Number(issue.id) });
  }
  return { accountId, worklogs };
}

async function fetchWorklogs(fetchImpl, base, auth, accountId, from, to) {
  let url = `${base}/worklogs/user/${encodeURIComponent(accountId)}?from=${from}&to=${to}&limit=1000`;
  const all = [];
  while (url) {
    const page = await request(fetchImpl, 'GET', url, { auth });
    all.push(...((page && page.results) || []));
    url = page && page.metadata && page.metadata.next;
  }
  return all.map(w => ({ id: w.tempoWorklogId, issueId: Number(w.issue && w.issue.id), date: String(w.startDate).slice(0, 10), seconds: Number(w.timeSpentSeconds) || 0 }));
}

/**
 * What to post for one worked day so it holds at least dailySeconds: {action: 'done'|'create', creates, total}.
 * Every existing worklog counts (any issue). The shortfall goes to the configured issues in config order,
 * each up to its configured share not yet logged; a day already at or above dailySeconds is left alone.
 */
function planDay(existing, worklogs, dailySeconds) {
  const have = new Map();
  for (const e of existing) have.set(e.issueId, (have.get(e.issueId) || 0) + e.seconds);
  const total = existing.reduce((s, e) => s + e.seconds, 0);
  if (total >= dailySeconds) return { action: 'done', total };
  let short = dailySeconds - total;
  const creates = [];
  for (const w of worklogs) {
    const s = Math.min(short, Math.max(0, Math.round(w.hours * 3600) - (have.get(w.issueId) || 0)));
    if (s > 0) { creates.push({ ...w, seconds: s }); short -= s; }
  }
  // the configured shares add up to dailySeconds, so they always cover the shortfall; never end under it
  if (short > 0) {
    const last = worklogs[worklogs.length - 1];
    const c = creates.find(x => x.issueId === last.issueId);
    if (c) c.seconds += short; else creates.push({ ...last, seconds: short });
  }
  return { action: 'create', creates, total };
}
function fmtH(seconds) { return (seconds / 3600).toFixed(2); }
function addTime(hhmm, seconds) {
  const [h, m, s = 0] = hhmm.split(':').map(Number);
  const t = h * 3600 + m * 60 + s + seconds;
  return [Math.floor(t / 3600) % 24, Math.floor(t / 60) % 60, t % 60].map(n => String(n).padStart(2, '0')).join(':');
}

// ---------- main flow ----------
async function run(argv, deps = {}) {
  const fetchImpl = deps.fetch || globalThis.fetch;
  const env = deps.env || process.env;
  const now = deps.now || new Date();
  const startedAt = new Date();
  const ts = startedAt.toISOString().replace(/[:.]/g, '-');
  const log = { startedAt: startedAt.toISOString(), argv, steps: [], warnings: [], days: [], result: null };
  const out = deps.out || (m => console.log(m));
  const step = msg => { log.steps.push({ t: new Date().toISOString(), msg }); out(`[tempo] ${msg}`); };
  const warn = msg => { log.warnings.push(msg); out(`[tempo] WARNING: ${msg}`); };
  let logDir;

  try {
    const opts = parseArgs(argv);
    log.options = opts;
    if (opts.help) {
      out('Usage: node file-tempo.js --from yyyy-MM-dd --to yyyy-MM-dd [--leave <hcm-leave.json>] [--skip d1,d2] [--dry-run] [--config <file>]\n' +
        '       node file-tempo.js --check          (is the token accepted?)\n' +
        '       node file-tempo.js --recent <days> [--account <id>]  (read-only: your recent worklogs by issue id)');
      log.result = 'help';
      return { exitCode: EXIT.OK, log };
    }
    const cfgPath = opts.config ? path.resolve(opts.config) : path.join(TEMPO_DIR, 'tempo.config.json');
    const cfg = readJson(cfgPath);
    const cfgDir = path.dirname(cfgPath);
    logDir = resolveFrom(TEMPO_DIR, (cfg.paths && cfg.paths.logDir) || 'logs');
    if (opts.check) {
      // one read-only call: proves the token is accepted without needing the rest of the config
      const base = String(cfg.apiBaseUrl || 'https://api.tempo.io/4').replace(/\/+$/, '');
      await request(fetchImpl, 'GET', `${base}/work-attributes`, { auth: `Bearer ${readToken(cfg, env)}` });
      step('token OK: Tempo API accepted it');
      log.result = 'token-ok';
      return { exitCode: EXIT.OK, log };
    }
    if (opts.recent) {
      // read-only: your own worklogs of the last N days, to find the issue ids for worklogs. Only one account is
      // ever queried (Tempo has no "current user" call, so the account id must be given or looked up in Jira).
      const base = String(cfg.apiBaseUrl || 'https://api.tempo.io/4').replace(/\/+$/, '');
      const days = Math.min(90, Math.max(1, Number(opts.recent) || 30));
      const to = iso(now);
      const from = iso(addDays(now, -days));
      const auth = `Bearer ${readToken(cfg, env)}`;
      let accountId = opts.account || cfg.authorAccountId;
      if (!accountId && env.JIRA_EMAIL && env.JIRA_API_TOKEN) {
        accountId = (await resolveIds({ ...cfg, worklogs: [] }, env, fetchImpl, step)).accountId;
      }
      if (!accountId) {
        throw new TempoError('CONFIG', '--recent needs your account id: open your profile in Jira (avatar > Profile); the URL ends in it ' +
          `(${String(cfg.jiraBaseUrl || 'https://<site>.atlassian.net').replace(/\/+$/, '')}/jira/people/<accountId>). ` +
          'Then run: .\\run-tempo.ps1 --recent 45 --account <accountId>  (or put it in authorAccountId).');
      }
      let url = `${base}/worklogs/user/${encodeURIComponent(accountId)}?from=${from}&to=${to}&limit=1000`;
      const all = [];
      while (url && all.length < 10000) {
        const page = await request(fetchImpl, 'GET', url, { auth });
        all.push(...((page && page.results) || []));
        url = page && page.metadata && page.metadata.next;
      }
      const issues = new Map();
      const byDay = new Map();
      for (const w of all) {
        const s = Number(w.timeSpentSeconds) || 0;
        const id = w.issue && w.issue.id;
        issues.set(id, (issues.get(id) || 0) + s);
        byDay.set(w.startDate, (byDay.get(w.startDate) || 0) + s);
      }
      step(`account ${accountId}, ${from}..${to}: ${all.length} worklog(s) on ${byDay.size} day(s)`);
      step(`  hours by issue id: ${[...issues].sort((x, y) => y[1] - x[1]).map(([i, s]) => `${i}=${fmtH(s)}`).join(', ') || 'none'}`);
      step(`  hours by day: ${[...byDay].sort().map(([d, s]) => `${d.slice(5)}=${fmtH(s)}`).join(' ') || 'none'}`);
      log.result = 'recent';
      return { exitCode: EXIT.OK, log };
    }
    validateConfig(cfg);

    const today = iso(now);
    const from = parseIso(opts.from || today);
    const to = parseIso(opts.to || opts.from || today);
    if (!from || !to) throw new TempoError('ARGS', '--from / --to must be yyyy-MM-dd');
    if (iso(from) > iso(to)) throw new TempoError('ARGS', `--from ${iso(from)} is after --to ${iso(to)}`);
    if ((to - from) / 86400000 >= MAX_DAYS) throw new TempoError('ARGS', `range is longer than ${MAX_DAYS} days; split it`);

    const p = cfg.paths || {};
    const src = {
      overrides: loadMap(opts.overrides ? path.resolve(opts.overrides) : p.overrides && resolveFrom(cfgDir, p.overrides)),
      holidays: loadHolidays(opts.holidays ? path.resolve(opts.holidays) : p.holidays && resolveFrom(cfgDir, p.holidays)),
      leave: loadMap(opts.leave && path.resolve(opts.leave)),
      skip: new Set(String(opts.skip || '').split(',').map(s => s.trim()).filter(s => parseIso(s))),
    };
    if (!opts.leave) warn('No --leave file: HCM leave is not known, only overrides.json / holidays.json leave is skipped.');
    const days = classifyDays(from, to, src, cfg, today);
    log.days = days;
    const work = days.filter(d => d.kind === 'work');
    step(`${iso(from)}..${iso(to)}: ${days.filter(d => d.reason !== 'weekend').map(d => `${d.day} ${d.date}=${d.kind === 'work' ? 'work' : d.reason}`).join(', ') || 'weekend only'}`);
    if (!work.length) { step('no worked days in range; nothing to log'); log.result = 'nothing-to-do'; return { exitCode: EXIT.OK, log }; }

    const token = readToken(cfg, env);
    if (typeof fetchImpl !== 'function') throw new TempoError('ERROR', 'fetch is not available; Node 18+ is needed');
    const base = String(cfg.apiBaseUrl || 'https://api.tempo.io/4').replace(/\/+$/, '');
    const auth = `Bearer ${token}`;

    const { accountId, worklogs } = await resolveIds(cfg, env, fetchImpl, step);
    const existing = await fetchWorklogs(fetchImpl, base, auth, accountId, work[0].date, work[work.length - 1].date);

    const daily = Math.round(cfg.dailyHours * 3600);
    const filed = [];
    for (const d of work) {
      const plan = planDay(existing.filter(e => e.date === d.date), worklogs, daily);
      const entry = log.days.find(x => x.date === d.date);
      entry.plan = plan.action;
      if (plan.action === 'done') { step(`  ${d.date} ${d.day}: already ${fmtH(plan.total)}h, left alone`); continue; }
      if (plan.total) step(`  ${d.date} ${d.day}: already ${fmtH(plan.total)}h, adding ${fmtH(daily - plan.total)}h to reach ${fmtH(daily)}h`);
      // later worklogs of the day start where the earlier configured ones end
      let start = String(cfg.startTime).length === 5 ? `${cfg.startTime}:00` : String(cfg.startTime);
      const created = [];
      for (const w of worklogs) {
        const c = plan.creates.find(x => x.issueId === w.issueId);
        if (c && !opts.dryRun) {
          const body = {
            authorAccountId: accountId,
            issueId: w.issueId,
            startDate: d.date,
            startTime: start,
            timeSpentSeconds: c.seconds,
            description: w.description || cfg.defaultDescription || `Working on issue ${w.issueKey || w.issueId}`,
          };
          if (Array.isArray(w.attributes) && w.attributes.length) body.attributes = w.attributes;
          const res = await request(fetchImpl, 'POST', `${base}/worklogs`, { auth, body });
          existing.push({ id: res && res.tempoWorklogId, issueId: w.issueId, date: d.date, seconds: c.seconds });
        }
        if (c) created.push(`${w.issueKey || w.issueId} ${fmtH(c.seconds)}h`);
        start = addTime(start, Math.round(w.hours * 3600));
      }
      if (opts.dryRun) { step(`  ${d.date} ${d.day}: would log ${created.join(', ')}`); continue; }
      filed.push(d.date);
      out(`[tempo] ${d.date} ${d.day}: filed ${fmtH(daily - plan.total)}h (${created.join(', ')}), day total ${fmtH(daily)}h`);
    }

    // re-read what Tempo now holds: every filed day must reach at least dailyHours
    if (filed.length) {
      const after = await fetchWorklogs(fetchImpl, base, auth, accountId, filed[0], filed[filed.length - 1]);
      const bad = filed.filter(date => planDay(after.filter(e => e.date === date), worklogs, daily).action !== 'done');
      if (bad.length) throw new TempoError('VERIFY', `After posting, Tempo shows less than ${cfg.dailyHours}h on ${bad.join(', ')}; check them in Tempo.`);
      step(`verified ${filed.length} day(s) at ${cfg.dailyHours}h or more in Tempo`);
    }
    log.filed = filed;
    log.result = opts.dryRun ? 'dry-run' : 'ok';
    return { exitCode: EXIT.OK, log };
  } catch (e) {
    log.result = 'error';
    log.error = { code: e.code || 'ERROR', message: e.message };
    out(`[tempo] ${e.code ? e.code + ': ' : ''}${e.message}`);
    return { exitCode: e.code === 'CONFIG' ? EXIT.CONFIG : EXIT.ERROR, log };
  } finally {
    log.finishedAt = new Date().toISOString();
    if (!deps.noLogFile) {
      try {
        logDir = logDir || path.join(TEMPO_DIR, 'logs');
        fs.mkdirSync(logDir, { recursive: true });
        const f = path.join(logDir, `run-${ts}.json`);
        fs.writeFileSync(f, JSON.stringify(log, null, 2));
        log.logFile = f;
      } catch (e) { console.error(`[tempo] could not write run log: ${e.message}`); }
    }
  }
}

module.exports = { run, parseArgs, classifyDays, planDay, validateConfig, addTime, EXIT };

if (require.main === module) {
  run(process.argv.slice(2)).then(r => {
    console.log(`[tempo] result: ${r.log.result}${r.log.logFile ? ` (log ${r.log.logFile})` : ''}`);
    process.exitCode = r.exitCode;
  });
}
