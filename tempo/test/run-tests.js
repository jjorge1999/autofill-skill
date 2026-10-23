'use strict';
// file-tempo.js against an in-memory fake of the Tempo v4 and Jira REST APIs (no network).
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const { run, planDay, validateConfig, addTime, EXIT } = require('../file-tempo.js');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tempo-test-'));
const write = (name, data) => { const f = path.join(tmp, name); fs.writeFileSync(f, JSON.stringify(data, null, 2)); return f; };

const ME = 'acc-me';
const baseCfg = {
  apiBaseUrl: 'https://api.tempo.test/4',
  jiraBaseUrl: 'https://jira.test',
  authorAccountId: ME,
  dailyHours: 8,
  startTime: '09:00',
  worklogs: [
    { issueKey: 'EXP-1', issueId: 101, hours: 2, description: 'experience' },
    { issueKey: 'MNT-2', issueId: 202, hours: 6 },
  ],
  weekendDays: [0, 6],
  paths: { logDir: path.join(tmp, 'logs') },
};

// Fake server: worklogs live in `store`; every request is recorded in `calls`.
function fakeApi(store = []) {
  const calls = [];
  let seq = 1000;
  const reply = (status, body) => ({ ok: status < 300, status, headers: { get: () => null }, text: async () => (body === undefined ? '' : JSON.stringify(body)) });
  const fetch = async (url, init) => {
    const u = new URL(url);
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ method: init.method, path: u.pathname, query: Object.fromEntries(u.searchParams), body, auth: init.headers.Authorization });
    if (u.host === 'jira.test') {
      if (!init.headers.Authorization.startsWith('Basic ')) return reply(401, {});
      if (u.pathname === '/rest/api/3/myself') return reply(200, { accountId: ME });
      const m = /^\/rest\/api\/3\/issue\/([^/]+)$/.exec(u.pathname);
      if (m) return reply(200, { id: { 'EXP-1': '101', 'MNT-2': '202' }[decodeURIComponent(m[1])], fields: { summary: 's' } });
      return reply(404, {});
    }
    if (init.headers.Authorization !== 'Bearer tok') return reply(401, { errors: [{ message: 'bad token' }] });
    if (init.method === 'GET' && (u.pathname === `/4/worklogs/user/${ME}` || u.pathname === '/4/worklogs')) {
      const { from, to } = Object.fromEntries(u.searchParams);
      const results = store.filter(w => w.startDate >= from && w.startDate <= to);
      return reply(200, { metadata: { count: results.length }, results });
    }
    if (init.method === 'POST' && u.pathname === '/4/worklogs') {
      const w = { tempoWorklogId: ++seq, issue: { id: body.issueId }, startDate: body.startDate, startTime: body.startTime, timeSpentSeconds: body.timeSpentSeconds, author: { accountId: body.authorAccountId } };
      store.push(w);
      return reply(200, w);
    }
    return reply(404, {});
  };
  return { fetch, calls, store };
}
const wl = (date, issueId, hours) => ({ tempoWorklogId: Math.random(), issue: { id: issueId }, startDate: date, timeSpentSeconds: hours * 3600 });
const env = { TEMPO_API_TOKEN: 'tok' };
const now = new Date(2026, 9, 23, 17); // Fri 2026-10-23, 17:00
const lines = [];
const deps = (api, extra = {}) => ({ fetch: api.fetch, env, now, noLogFile: true, out: m => lines.push(m), ...extra });
const posts = api => api.calls.filter(c => c.method === 'POST');

(async () => {
  const cfgFile = write('tempo.config.json', baseCfg);
  // week 19-23 Oct: Tue override vacation, Wed holiday, Thu HCM sick, Mon/Fri worked (Fri wfh override is still worked)
  const overrides = write('overrides.json', { '2026-10-20': 'vacation', '2026-10-23': 'office' });
  const holidays = write('holidays.json', ['YYYY-MM-DD', '2026-10-21']);
  const leave = write('leave.json', { '2026-10-22': 'sick' });
  const common = ['--config', cfgFile, '--overrides', overrides, '--holidays', holidays, '--leave', leave];

  // 1. worked days get exactly 2h + 6h; leave, holidays, weekends skipped
  let api = fakeApi();
  let r = await run(['--from', '2026-10-18', '--to', '2026-10-24', ...common], deps(api));
  assert.strictEqual(r.exitCode, EXIT.OK, JSON.stringify(r.log.error));
  assert.deepStrictEqual(posts(api).map(c => `${c.body.startDate} ${c.body.issueId} ${c.body.timeSpentSeconds / 3600}h ${c.body.startTime}`), [
    '2026-10-19 101 2h 09:00:00', '2026-10-19 202 6h 11:00:00',
    '2026-10-23 101 2h 09:00:00', '2026-10-23 202 6h 11:00:00',
  ]);
  assert.strictEqual(posts(api)[0].body.authorAccountId, ME);
  assert.strictEqual(posts(api)[0].body.description, 'experience');
  assert.strictEqual(posts(api)[1].body.description, 'Working on issue MNT-2');
  assert.deepStrictEqual(r.log.filed, ['2026-10-19', '2026-10-23']);
  assert.ok(lines.some(l => /^\[tempo\] 2026-10-19 Mon: filed 8\.00h \(EXP-1 2\.00h, MNT-2 6\.00h\), day total 8\.00h$/.test(l)), 'filed line format');
  const reasons = Object.fromEntries(r.log.days.map(d => [d.date, d.kind === 'work' ? 'work' : d.reason]));
  assert.deepStrictEqual(reasons, {
    '2026-10-18': 'weekend', '2026-10-19': 'work', '2026-10-20': 'vacation (overrides.json)', '2026-10-21': 'holiday (holidays.json)',
    '2026-10-22': 'sick (HCM)', '2026-10-23': 'work', '2026-10-24': 'weekend',
  });
  console.log('PASS  worked days get 2h + 6h, leave/holiday/weekend skipped');

  // 2. rerun files nothing
  const before = posts(api).length;
  r = await run(['--from', '2026-10-19', '--to', '2026-10-23', ...common], deps(api));
  assert.strictEqual(r.exitCode, EXIT.OK);
  assert.strictEqual(posts(api).length, before, 'rerun must not post');
  console.log('PASS  rerun is idempotent');

  // 3. a half-filed day (earlier run died after the first post) gets only the missing 6h
  api = fakeApi([wl('2026-10-19', 101, 2)]);
  r = await run(['--from', '2026-10-19', '--to', '2026-10-19', ...common], deps(api));
  assert.strictEqual(r.exitCode, EXIT.OK);
  assert.deepStrictEqual(posts(api).map(c => `${c.body.issueId} ${c.body.timeSpentSeconds / 3600}h ${c.body.startTime}`), ['202 6h 11:00:00']);
  console.log('PASS  partial day completed with missing hours only');

  // 4. at least 8h: other hours count and the day is topped up; a day already at 8h+ is left alone
  api = fakeApi([wl('2026-10-19', 999, 1), wl('2026-10-20', 999, 9), wl('2026-10-23', 202, 7)]);
  lines.length = 0;
  r = await run(['--from', '2026-10-19', '--to', '2026-10-23', '--config', cfgFile, '--overrides', write('none.json', {})], deps(api));
  assert.strictEqual(r.exitCode, EXIT.OK, JSON.stringify(r.log.error));
  assert.deepStrictEqual(r.log.filed, ['2026-10-19', '2026-10-21', '2026-10-22', '2026-10-23']);
  const byDay = d => posts(api).filter(c => c.body.startDate === d).map(c => `${c.body.issueId} ${c.body.timeSpentSeconds / 3600}h`);
  assert.deepStrictEqual(byDay('2026-10-19'), ['101 2h', '202 5h'], '1h elsewhere -> 7h added');
  assert.deepStrictEqual(byDay('2026-10-20'), [], '9h already -> nothing added');
  assert.deepStrictEqual(byDay('2026-10-23'), ['101 1h'], '7h on MNT-2 -> 1h on EXP-1');
  assert.ok(lines.some(l => /^\[tempo\] 2026-10-19 Mon: filed 7\.00h \(EXP-1 2\.00h, MNT-2 5\.00h\), day total 8\.00h$/.test(l)));
  for (const d of ['2026-10-19', '2026-10-20', '2026-10-21', '2026-10-22', '2026-10-23']) {
    const total = api.store.filter(w => w.startDate === d).reduce((s, w) => s + w.timeSpentSeconds, 0) / 3600;
    assert.ok(total >= 8, `${d} has ${total}h`);
  }
  console.log('PASS  every worked day ends with at least 8h');

  // 5. dry run posts nothing
  api = fakeApi();
  r = await run(['--from', '2026-10-19', '--to', '2026-10-23', '--dry-run', ...common], deps(api));
  assert.strictEqual(r.exitCode, EXIT.OK);
  assert.strictEqual(posts(api).length, 0);
  assert.strictEqual(r.log.result, 'dry-run');
  console.log('PASS  dry run posts nothing');

  // 6. future days are never filed; --skip days are skipped
  api = fakeApi();
  r = await run(['--from', '2026-10-22', '--to', '2026-10-27', '--skip', '2026-10-22', '--config', cfgFile], deps(api));
  assert.deepStrictEqual([...new Set(posts(api).map(c => c.body.startDate))], ['2026-10-23']);
  console.log('PASS  future and --skip days not filed');

  // 7. issue ids and accountId looked up in Jira when missing
  const lookupCfg = write('lookup.json', { ...baseCfg, authorAccountId: '', worklogs: baseCfg.worklogs.map(w => ({ ...w, issueId: null })) });
  api = fakeApi();
  r = await run(['--from', '2026-10-19', '--to', '2026-10-19', '--config', lookupCfg], deps(api, { env: { ...env, JIRA_EMAIL: 'me@x', JIRA_API_TOKEN: 'j' } }));
  assert.strictEqual(r.exitCode, EXIT.OK, JSON.stringify(r.log.error));
  assert.deepStrictEqual(posts(api).map(c => c.body.issueId), [101, 202]);
  r = await run(['--from', '2026-10-19', '--to', '2026-10-19', '--config', lookupCfg], deps(fakeApi()));
  assert.strictEqual(r.exitCode, EXIT.CONFIG, 'missing ids without Jira creds = not configured');
  console.log('PASS  Jira lookup of issue ids / accountId');

  // 8. not configured: no token, placeholder config, hours not adding to 8
  r = await run(['--from', '2026-10-19', '--to', '2026-10-19', '--config', cfgFile], deps(fakeApi(), { env: {} }));
  assert.strictEqual(r.exitCode, EXIT.CONFIG);
  assert.match(r.log.error.message, /tokenFile/);
  // token from tokenFile (first non-empty line, BOM tolerant); TEMPO_API_TOKEN wins over it
  const tokFile = path.join(tmp, 'token.txt');
  fs.writeFileSync(tokFile, '﻿\r\n  tok  \r\n');
  const fileCfg = write('file.json', { ...baseCfg, tokenFile: tokFile });
  api = fakeApi();
  r = await run(['--from', '2026-10-19', '--to', '2026-10-19', '--config', fileCfg], deps(api, { env: {} }));
  assert.strictEqual(r.exitCode, EXIT.OK, JSON.stringify(r.log.error));
  assert.strictEqual(api.calls[0].auth, 'Bearer tok');
  api = fakeApi();
  await run(['--from', '2026-10-19', '--to', '2026-10-19', '--config', write('file2.json', { ...baseCfg, tokenFile: path.join(tmp, 'nope.txt') })], deps(api));
  assert.strictEqual(api.calls[0].auth, 'Bearer tok', 'env token used before tokenFile');
  r = await run(['--from', '2026-10-19', '--to', '2026-10-19', '--config', write('file3.json', { ...baseCfg, tokenFile: path.join(tmp, 'nope.txt') })], deps(fakeApi(), { env: {} }));
  assert.strictEqual(r.exitCode, EXIT.CONFIG);
  assert.match(r.log.error.message, /cannot be read/);
  assert.ok(!JSON.stringify(r.log).includes('tok"'), 'token value never in the log');
  const shipped = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'tempo.config.json'), 'utf8'));
  assert.throws(() => validateConfig(shipped), /issueKey/);
  assert.throws(() => validateConfig({ ...baseCfg, worklogs: [{ issueId: 1, hours: 7 }] }), /add up to 7/);
  validateConfig(baseCfg);
  r = await run(['--from', '2026-10-19', '--to', '2026-10-19', '--config', cfgFile], deps(fakeApi(), { env: { TEMPO_API_TOKEN: 'wrong' } }));
  assert.strictEqual(r.exitCode, EXIT.ERROR);
  assert.match(r.log.error.message, /HTTP 401 \(token wrong or expired\?\)/);
  assert.ok(!/Bearer/.test(JSON.stringify(r.log)), 'token never in the log');
  console.log('PASS  config / token errors');

  // 9. --recent: read-only, only your own account's worklogs (works before the config is ready)
  api = fakeApi([wl('2026-10-19', 101, 2), wl('2026-10-19', 202, 6)]);
  lines.length = 0;
  const noIssues = write('noissues.json', { ...baseCfg, authorAccountId: '', worklogs: [] });
  r = await run(['--recent', '30', '--account', ME, '--config', noIssues], deps(api));
  assert.strictEqual(r.exitCode, EXIT.OK, JSON.stringify(r.log.error));
  assert.strictEqual(posts(api).length, 0);
  assert.deepStrictEqual(api.calls.map(c => c.path), [`/4/worklogs/user/${ME}`], 'only your own worklogs are queried');
  assert.ok(lines.some(l => l.includes(`account ${ME}, 2026-09-23..2026-10-23: 2 worklog(s) on 1 day(s)`)));
  assert.ok(lines.some(l => l.includes('hours by issue id: 202=6.00, 101=2.00')));
  api = fakeApi();
  r = await run(['--recent', '30', '--config', noIssues], deps(api));
  assert.strictEqual(r.exitCode, EXIT.CONFIG, 'no account id -> refuses instead of listing everyone');
  assert.match(r.log.error.message, /jira\/people\/<accountId>/);
  assert.strictEqual(api.calls.length, 0);
  r = await run(['--recent', '30', '--config', noIssues], deps(fakeApi(), { env: { ...env, JIRA_EMAIL: 'me@x', JIRA_API_TOKEN: 'j' } }));
  assert.strictEqual(r.exitCode, EXIT.OK, 'account id looked up in Jira');
  console.log('PASS  --recent shows only your own worklogs');

  // 10. helpers
  assert.strictEqual(addTime('09:00:00', 2 * 3600 + 30 * 60), '11:30:00');
  assert.strictEqual(planDay([], [{ issueId: 1, hours: 8 }], 8 * 3600).action, 'create');
  assert.strictEqual(planDay([{ issueId: 1, seconds: 8 * 3600 }], [{ issueId: 1, hours: 8 }], 8 * 3600).action, 'done');
  assert.strictEqual(planDay([{ issueId: 9, seconds: 10 * 3600 }], [{ issueId: 1, hours: 8 }], 8 * 3600).action, 'done');
  // more than the configured share already on the first issue: the rest still reaches 8h
  const p = planDay([{ issueId: 1, seconds: 3 * 3600 }], [{ issueId: 1, hours: 2 }, { issueId: 2, hours: 6 }], 8 * 3600);
  assert.deepStrictEqual(p.creates.map(c => `${c.issueId} ${c.seconds / 3600}`), ['2 5']);
  console.log('PASS  helpers');

  fs.rmSync(tmp, { recursive: true, force: true });
  console.log('All Tempo tests passed');
})().catch(e => { console.error('FAIL ', e); process.exit(1); });
