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

const HCM = path.resolve(__dirname, '..');
const TODAY = '2026-10-01';
const MOCK_URL = `${pathToFileURL(path.join(__dirname, 'mock-hcm.html')).href}?today=${TODAY}`;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hcm-mock-'));

let failures = 0;
function check(name, fn) {
  try { fn(); console.log(`  PASS ${name}`); } catch (e) { failures++; console.log(`  FAIL ${name}\n       ${e.message}`); }
}

function writeConfig(name) {
  const p = path.join(tmp, `${name}.config.json`);
  fs.writeFileSync(p, JSON.stringify({
    urls: { app: MOCK_URL, portal: null, appUrlPatterns: ['^file:'] },
    browser: { channel: null, userDataDir: path.join(tmp, `${name}-profile`) },
    planCodes: { wfh: '248', vacation: null, sick: '300' },
    planLabels: { 248: 'Telecommuting', 300: 'Sick Leave' },
    paths: { logDir: path.join(tmp, `${name}-logs`), screenshotDir: path.join(tmp, `${name}-shots`) },
    timeouts: { calendarMs: 15000, loginMs: 15000, monthSettleMs: 800 },
  }));
  return p;
}

function run(name, extraArgs, summary, overrides) {
  const cfg = writeConfig(name);
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

  console.log(failures ? `\n${failures} check(s) FAILED` : '\nAll checks passed');
  fs.rmSync(tmp, { recursive: true, force: true });
  process.exitCode = failures ? 1 : 0;
})().catch((e) => { console.error(e); process.exitCode = 1; });
