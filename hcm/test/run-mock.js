'use strict';
/*
 * End-to-end test of file-hcm.js against the local mock (test/mock-hcm.html).
 * Uses bundled headless Chromium and a throw-away browser profile.
 *   node test/run-mock.js
 */
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { pathToFileURL } = require('url');
const { chromium } = require('playwright');
const { leaveKind, splitEntries, judgeEntries } = require('../file-hcm.js');

const HCM = path.resolve(__dirname, '..');
const TODAY = '2026-10-01';
const MOCK_URL = `${pathToFileURL(path.join(__dirname, 'mock-hcm.html')).href}?today=${TODAY}`;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hcm-mock-'));

let failures = 0;
function check(name, fn) {
  try { fn(); console.log(`  PASS ${name}`); } catch (e) { failures++; console.log(`  FAIL ${name}\n       ${e.message}`); }
}

function writeConfig(name, extra = {}) {
  const p = path.join(tmp, `${name}.config.json`);
  fs.writeFileSync(p, JSON.stringify({
    urls: { app: MOCK_URL, portal: null, appUrlPatterns: ['^file:'] },
    browser: { channel: null, userDataDir: path.join(tmp, `${name}-profile`) },
    dateFormat: 'DD/MM/YYYY', // the mock's format; the real tenant uses M/D/YYYY

    planCodes: { wfh: '248', vacation: null, sick: '300' },
    planLabels: { 248: 'Telecommuting', 300: 'Sick Leave' },
    paths: { logDir: path.join(tmp, `${name}-logs`), screenshotDir: path.join(tmp, `${name}-shots`) },
    timeouts: { calendarMs: 15000, loginMs: 15000, monthSettleMs: 800 },
    ...extra,
  }));
  return p;
}

function run(name, extraArgs, summary, overrides, cfgExtra) {
  const cfg = writeConfig(name, cfgExtra);
  const sumPath = path.join(tmp, `${name}.summary.json`);
  // UTF-8 BOM + mixed-case keys, as PowerShell may produce
  fs.writeFileSync(sumPath, '\uFEFF' + JSON.stringify(summary));
  const ovPath = path.join(tmp, `${name}.overrides.json`);
  fs.writeFileSync(ovPath, JSON.stringify(overrides || {}));
  const args = [path.join(HCM, 'file-hcm.js'), '--summary', sumPath, '--overrides', ovPath,
    '--config', cfg, '--headless', '--today', TODAY, ...extraArgs];
  const env = { ...process.env };
  delete env.NODE_OPTIONS;
  const r = spawnSync(process.execPath, args, { encoding: 'utf8', env, timeout: 300000 });
  console.log(r.stdout.split('\n').map((l) => `    | ${l}`).join('\n'));
  if (r.stderr) console.log(r.stderr.split('\n').map((l) => `    ! ${l}`).join('\n'));
  const logDir = path.join(tmp, `${name}-logs`);
  const logFile = fs.readdirSync(logDir).filter((f) => f.startsWith('run-')).sort().pop();
  const log = JSON.parse(fs.readFileSync(path.join(logDir, logFile), 'utf8'));
  const byDate = Object.fromEntries(log.results.map((x) => [x.date, x]));
  return { code: r.status, stdout: r.stdout, log, byDate, shots: path.join(tmp, `${name}-shots`), profile: path.join(tmp, `${name}-profile`) };
}

async function savedRequests(profile) {
  const ctx = await chromium.launchPersistentContext(profile, { headless: true });
  const page = ctx.pages()[0] || (await ctx.newPage());
  await page.goto(MOCK_URL);
  const reqs = await page.evaluate(() => JSON.parse(localStorage.getItem('mock-hcm-requests') || '[]'));
  await ctx.close();
  return reqs;
}

(async () => {
  console.log(`Mock: ${MOCK_URL}\nTemp: ${tmp}\n`);

  // ---------------------------------------------------------------- pure helpers
  console.log('Unit checks: leaveKind / splitEntries');
  const SEL = JSON.parse(fs.readFileSync(path.join(HCM, 'hcm.config.json'), 'utf8')).selectors;
  check('leaveKind classifies single entries', () => {
    assert.strictEqual(leaveKind('Vacation: Full Day', SEL), 'vacation');
    assert.strictEqual(leaveKind('Sick Leave: Full Day', SEL), 'sick');
    assert.strictEqual(leaveKind('Unpaid Leave', SEL), 'leave');
    assert.strictEqual(leaveKind('Telecommuting: Full Day', SEL), null);
    assert.strictEqual(leaveKind('Vacation: Full Day (Rejected)', SEL), null);
    assert.strictEqual(leaveKind('Vacation: Full Day'), 'vacation'); // selectors optional
  });
  check('splitEntries separates concatenated cell text', () => {
    assert.deepStrictEqual(splitEntries('Vacation: Full Day (Rejected) Sick Leave: Full Day'),
      ['Vacation: Full Day (Rejected)', 'Sick Leave: Full Day']);
    assert.deepStrictEqual(splitEntries('Telecommuting: Full Day'), ['Telecommuting: Full Day']);
    assert.deepStrictEqual(splitEntries('Unpaid Leave'), ['Unpaid Leave']);
  });
  check('judgeEntries: per entry, unrecognised and ambiguous cells reported', () => {
    assert.deepStrictEqual(judgeEntries(['Vacation: Full Day (Rejected)', 'Sick Leave: Full Day'], SEL), { kind: 'sick', unrecognised: [] });
    assert.deepStrictEqual(judgeEntries(['Telecommuting: Full Day'], SEL), { kind: null, unrecognised: [] });
    assert.deepStrictEqual(judgeEntries(['Official Business: Full Day'], SEL), { kind: null, unrecognised: ['Official Business: Full Day'] });
    // a bare "Rejected" that cannot be tied to one entry is never guessed
    assert.deepStrictEqual(judgeEntries(splitEntries('Vacation: Full Day Rejected'), SEL),
      { kind: null, unrecognised: ['Vacation: Full Day Rejected'] });
  });

  // ---------------------------------------------------------------- draft run
  console.log('Scenario 1: draft mode');
  const summary = [
    { date: '2026-08-31', status: 'wfh' },      // holiday (National Heroes Day)
    { date: '2026-09-01', status: 'wfh' },      // existing Telecommuting entry
    { Date: '2026-09-02', Status: 'WFH' },      // -> file (capitalised keys/values)
    { date: '2026-09-03', status: 'office' },   // never filed
    { date: '2026-09-04', status: 'unknown' },  // never filed, reported
    { date: '2026-09-05', status: 'wfh' },      // Saturday
    { date: '2026-09-10', status: 'wfh' },      // existing Vacation entry
    { date: '2026-09-14', status: 'unknown' },  // overridden -> sick (plan 300)
    { date: '2026-09-18', status: 'unknown' },  // overridden -> vacation (not configured)
    { date: '2026-09-29', status: 'wfh' },      // -> file
    { date: '2026-09-30', status: 'wfh' },      // mock rejects -> error reported
    { date: '2026-10-01', status: 'wfh' },      // today -> file (next month)
    { date: '2026-10-02', status: 'wfh' },      // future -> skipped
  ];
  const r1 = run('draft', [], summary, { '2026-09-14': 'sick', '2026-09-18': 'vacation' });
  const reqs1 = await savedRequests(r1.profile);
  const res = (d) => (r1.byDate[d] || {}).result;

  check('holiday skipped', () => assert.strictEqual(res('2026-08-31'), 'skipped-holiday'));
  check('existing entries skipped', () => {
    assert.strictEqual(res('2026-09-01'), 'skipped-existing');
    assert.strictEqual(res('2026-09-10'), 'skipped-existing');
  });
  check('weekend skipped', () => assert.strictEqual(res('2026-09-05'), 'skipped-weekend'));
  check('future skipped', () => assert.strictEqual(res('2026-10-02'), 'skipped-future'));
  check('office not filed', () => assert.strictEqual(res('2026-09-03'), 'skipped-office'));
  check('unknown not filed and reported', () => {
    assert.strictEqual(res('2026-09-04'), 'needs-input');
    assert.deepStrictEqual(r1.log.unknownDays, ['2026-09-04']);
    assert.match(r1.stdout, /unknown days need your input: 2026-09-04/);
  });
  check('unconfigured vacation override skipped', () => assert.strictEqual(res('2026-09-18'), 'skipped-unconfigured'));
  check('wfh dates filed', () => {
    for (const d of ['2026-09-02', '2026-09-29', '2026-10-01']) assert.strictEqual(res(d), 'filed', `${d}: ${JSON.stringify(r1.byDate[d])}`);
  });
  check('override sick filed with plan 300', () => assert.strictEqual(res('2026-09-14'), 'filed'));
  check('rejected date reported as error with dialog message', () => {
    assert.strictEqual(res('2026-09-30'), 'error');
    assert.match(r1.byDate['2026-09-30'].detail, /overlaps an existing request/);
  });
  check('exit code 1 because of the error', () => assert.strictEqual(r1.code, 1));
  check('mock received exactly the expected requests', () => {
    const got = reqs1.map((q) => `${q.fromIso}:${q.plan}`).sort();
    assert.deepStrictEqual(got, ['2026-09-02:248', '2026-09-14:300', '2026-09-29:248', '2026-10-01:248']);
  });
  check('DD/MM/YYYY single-day dates', () => {
    const q = reqs1.find((x) => x.fromIso === '2026-09-02');
    assert.strictEqual(q.from, '02/09/2026');
    assert.strictEqual(q.to, '02/09/2026');
  });
  check('full day + draft radio in draft mode', () => {
    for (const q of reqs1) {
      assert.strictEqual(q.fullDay, true);
      assert.strictEqual(q.halfDay, false);
      assert.strictEqual(q.action, 'draft');
    }
  });
  check('no request for unknown/office/holiday/existing/weekend/future', () => {
    const filed = new Set(reqs1.map((q) => q.fromIso));
    for (const d of ['2026-08-31', '2026-09-01', '2026-09-03', '2026-09-04', '2026-09-05', '2026-09-10', '2026-09-18', '2026-09-30', '2026-10-02']) {
      assert.ok(!filed.has(d), `${d} was filed`);
    }
  });

  // ---------------------------------------------------------------- submit run
  console.log('\nScenario 2: submit mode');
  const r2 = run('submit', ['--mode', 'submit'], [{ date: '2026-09-08', status: 'wfh' }]);
  const reqs2 = await savedRequests(r2.profile);
  check('submit radio chosen in submit mode', () => {
    assert.strictEqual(r2.byDate['2026-09-08'].result, 'filed');
    assert.strictEqual(reqs2.length, 1);
    assert.strictEqual(reqs2[0].action, 'submit');
  });

  // ---------------------------------------------------------------- dry run
  console.log('\nScenario 3: dry run');
  const r3 = run('dry', ['--dry-run'], [{ date: '2026-09-09', status: 'wfh' }]);
  const reqs3 = await savedRequests(r3.profile);
  check('dry run fills, screenshots and cancels', () => {
    assert.strictEqual(r3.byDate['2026-09-09'].result, 'dry-run');
    assert.ok(fs.existsSync(path.join(r3.shots, '2026-09-09-dryrun.png')), 'screenshot missing');
    assert.strictEqual(reqs3.length, 0);
    assert.strictEqual(r3.code, 0);
  });

  // ---------------------------------------------------------------- re-run is idempotent
  console.log('\nScenario 4: re-run of scenario 1 (idempotency)');
  // same 'draft' profile -> the mock still holds the scenario-1 requests
  const r4 = run('draft', [], summary.filter((x) => (x.date || x.Date) === '2026-09-02'));
  const reqs4 = await savedRequests(r4.profile);
  check('already-filed date is skipped on re-run', () => {
    assert.strictEqual(r4.byDate['2026-09-02'].result, 'skipped-existing');
    assert.strictEqual(reqs4.length, reqs1.length);
  });

  // ---------------------------------------------------------------- leave export
  console.log('\nScenario 5: leave export');
  const leavePath = path.join(tmp, 'leave.json');
  const r5 = run('leave', ['--from', '2026-08-31', '--to', '2026-09-15', '--leave-out', leavePath], []);
  check('leave export lists vacation, sick and holidays only', () => {
    assert.strictEqual(r5.code, 0);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(leavePath, 'utf8')),
      { '2026-08-31': 'holiday', '2026-09-10': 'vacation', '2026-09-15': 'sick' });
  });

  // ---------------------------------------------------------------- headless sign-in needed
  console.log('\nScenario 6: headless run on the login page');
  const t6 = Date.now();
  const r6 = run('login', [], [{ date: '2026-09-29', status: 'wfh' }], {}, {
    urls: { app: MOCK_URL, portal: null, appUrlPatterns: ['^https://never\\.example/'] },
    timeouts: { calendarMs: 15000, loginMs: 15000, monthSettleMs: 800, headlessLoginMs: 2000 },
  });
  check('exit 5 quickly when sign-in is needed', () => {
    assert.strictEqual(r6.code, 5);
    assert.match(r6.byDate['2026-09-29'].detail, /sign-in needed/);
    assert.ok(Date.now() - t6 < 12000, `took ${Date.now() - t6} ms`);
  });

  // ---------------------------------------------------------------- 'leave' override is never filed
  console.log('\nScenario 7: leave override');
  const r7 = run('leaveov', [], [{ date: '2026-09-16', status: 'unknown' }], { '2026-09-16': 'leave' });
  check("'leave' override is skipped, not filed", () => {
    assert.strictEqual(r7.byDate['2026-09-16'].result, 'skipped-override');
    assert.strictEqual(r7.code, 0);
  });

  // ---------------------------------------------------------------- leave export, calendar cannot be opened
  console.log('\nScenario 8: leave export when the calendar does not open');
  const leave8 = path.join(tmp, 'leave8.json');
  const r8 = run('leavefail', ['--from', '2026-09-01', '--to', '2026-09-15', '--leave-out', leave8], [], {}, {
    urls: { app: 'data:text/html,<p>not a calendar</p>', portal: null, appUrlPatterns: ['^data:'] },
    timeouts: { calendarMs: 3000, loginMs: 15000, monthSettleMs: 800 },
  });
  check('exit 1 and no leave file when the calendar cannot be opened', () => {
    assert.strictEqual(r8.code, 1);
    assert.ok(!fs.existsSync(leave8));
  });

  // ---------------------------------------------------------------- office reading beats a filing override
  console.log('\nScenario 9: office reading with a wfh/sick override');
  const r9 = run('officeov', [], [{ date: '2026-09-22', status: 'office' }, { date: '2026-09-23', status: 'office' }],
    { '2026-09-22': 'wfh', '2026-09-23': 'sick' });
  const reqs9 = await savedRequests(r9.profile);
  check('office reading is never filed, whatever the override', () => {
    assert.strictEqual(r9.byDate['2026-09-22'].result, 'skipped-office-reading');
    assert.strictEqual(r9.byDate['2026-09-23'].result, 'skipped-office-reading');
    assert.strictEqual(reqs9.length, 0);
    assert.match(r9.stdout, /WARNING 2026-09-22: .*override "wfh".*skipped-office-reading/);
    assert.match(r9.stdout, /WARNING 2026-09-23: .*override "sick".*skipped-office-reading/);
    assert.strictEqual(r9.code, 0);
  });

  // ---------------------------------------------------------------- leave export judged per entry
  console.log('\nScenario 10: leave export, one entry at a time');
  const leave10 = path.join(tmp, 'leave10.json');
  const r10 = run('leaveentries', ['--from', '2026-09-16', '--to', '2026-09-22', '--leave-out', leave10], []);
  check('a rejected entry does not hide a valid leave entry in the same cell', () => {
    assert.strictEqual(r10.code, 0);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(leave10, 'utf8')), { '2026-09-17': 'sick' });
  });
  check('an unrecognised entry is reported, not exported', () => {
    assert.match(r10.stdout, /^UNRECOGNISED 2026-09-21: Official Business: Full Day\r?$/m);
    assert.deepStrictEqual(r10.log.unrecognised, [{ date: '2026-09-21', text: 'Official Business: Full Day' }]);
    assert.ok(!/UNRECOGNISED 2026-09-17/.test(r10.stdout), 'rejected + sick cell must not be unrecognised');
  });

  console.log(failures ? `\n${failures} check(s) FAILED` : '\nAll checks passed');
  fs.rmSync(tmp, { recursive: true, force: true });
  process.exitCode = failures ? 1 : 0;
})().catch((e) => { console.error(e); process.exitCode = 1; });
