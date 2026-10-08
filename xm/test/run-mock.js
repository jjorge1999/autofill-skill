'use strict';
// End-to-end test of file-xm.js against test/mock-portal.html (Mingle page + XM iframe).
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');
const { pathToFileURL } = require('url');
const { run, parsePeriod, weekOf, formatDate } = require('../file-xm.js');

const XM = path.join(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xm-test-'));
const portal = pathToFileURL(path.join(__dirname, 'mock-portal.html')).href;

const cfg = JSON.parse(fs.readFileSync(path.join(XM, 'xm.config.json'), 'utf8'));
cfg.browser.channel = null;
cfg.urls.appUrlPatterns = ['^file:'];
cfg.paths.logDir = path.join(tmp, 'logs');
cfg.paths.screenshotDir = path.join(tmp, 'screenshots');
Object.assign(cfg.timeouts, { loginMs: 10000, headerMs: 3000, navStepMs: 3000, gridMs: 5000, saveMs: 5000, confirmMs: 3000, submitMs: 3000, pollMs: 200 });
const write = (name, data) => { const f = path.join(tmp, name); fs.writeFileSync(f, JSON.stringify(data, null, 2)); return f; };
// Point the leave guard at the real hcm.config.json (vacation 404 / sick 403)
// via an absolute path so configs written into the temp dir resolve it.
cfg.paths = { ...cfg.paths, hcmConfig: path.resolve(XM, '..', 'hcm', 'hcm.config.json') };
// cfgFile has no navigation, so the Document Header must already be on screen (?landing is not set).
const cfgFile = write('xm.config.json', { ...cfg, navigation: [] });
// The real navigation (Create a New... -> Timesheet) comes straight from xm.config.json.
const navCfgFile = write('xm.nav.config.json', { ...cfg, navigation: cfg.navigation });
assert.ok(Array.isArray(cfg.navigation) && cfg.navigation.length >= 2,
  'xm.config.json navigation must drive the landing page to the Document Header');

// Week 20-26 Sep 2026. Wed/Thu unknown in the log; Wed overridden wfh, Thu vacation; Fri is a public holiday.
const summary = write('summary.json', [
  { date: '2026-09-21', status: 'wfh' }, { Date: '2026-09-22', Status: 'office' },
  { date: '2026-09-23', status: 'unknown' }, { date: '2026-09-24', status: 'unknown' }, { date: '2026-09-25', status: 'office' },
]);
const overrides = write('overrides.json', { '2026-09-23': 'wfh', '2026-09-24': 'vacation' });
const holidays = write('holidays.json', ['YYYY-MM-DD', '2026-09-25']);
const noOverrides = write('none.json', {});
const leaveFile = write('leave.json', { '2026-09-23': 'leave', '2026-09-24': 'sick' });
const loginCfgFile = write('xm.login.config.json', { ...cfg, navigation: [], timeouts: { ...cfg.timeouts, headlessLoginMs: 1000, headlessAppMs: 5000 } });
const common = ['--week', '2026-09-22', '--summary', summary, '--holidays', holidays, '--headless', '--non-interactive', '--profile', path.join(tmp, 'profile')];

const base = ['--week', '2026-09-22', '--summary', summary, '--overrides', overrides, '--holidays', holidays,
  '--headless', '--non-interactive', '--profile', path.join(tmp, 'profile')];

async function go(args, url = portal, config = cfgFile) {
  let state = null;
  const r = await run([...base, '--config', config, '--url', url, ...args], {
    beforeClose: async page => {
      const f = page.frames().find(x => x.url().includes('mock-xm.html'));
      state = f ? await f.evaluate(() => window.mockState) : null;
    },
  });
  return { ...r, state };
}

const WORK = { ERP_M3_Experience: 2, ERP_M3_Maintenance: 7, 'General Internal Meetings': 0, 'Personal Time Off And Holidays': 0 };
const LEAVE = { ERP_M3_Experience: 0, ERP_M3_Maintenance: 0, 'General Internal Meetings': 0, 'Personal Time Off And Holidays': 8 };
function assertCells(cells) {
  const plan = [null, WORK, WORK, WORK, LEAVE, LEAVE, null]; // Sun..Sat
  for (const row of Object.keys(WORK)) {
    plan.forEach((rule, i) => assert.strictEqual(cells[row][i], rule ? rule[row] : 0, `${row} day ${i}`));
  }
}

const tests = [
  ['helpers', async () => {
    const p = parsePeriod('13-Sep-2026 - 19-Sep-2026');
    assert.strictEqual(p.start.getDate(), 13); assert.strictEqual(p.end.getMonth(), 8);
    const w = weekOf('2026-09-24', cfg);
    assert.strictEqual(formatDate(w.start, 'DD/MM/YY'), '20/09/26');
    assert.strictEqual(formatDate(w.dates[1], 'ddd DD/MM'), 'Mon 21/09');
  }],
  ['unknown day blocks the run before opening a browser', async () => {
    const r = await run(['--week', '2026-09-22', '--summary', summary, '--overrides', noOverrides, '--holidays', holidays, '--config', cfgFile, '--headless']);
    assert.strictEqual(r.exitCode, 2);
    assert.match(r.log.error.message, /2026-09-23.*2026-09-24/);
    assert.match(r.log.error.message, /none\.json/);
    assert.ok(!r.log.steps.some(s => /launched/.test(s.msg)));
  }],
  ['--no-import is rejected clearly', async () => {
    const r = await run([...base, '--config', cfgFile, '--no-import']);
    assert.strictEqual(r.exitCode, 1);
    assert.match(r.log.error.message, /--no-import is not supported/);
  }],
  ['leave day with a configured HCM plan code files in both (no mismatch warning)', async () => {
    // vacation 404 / sick 403 configured, so the Thu vacation day is fileable in
    // both systems; XM must not warn about a one-sided leave.
    const hcmOk = write('hcm.ok.config.json', { planCodes: { wfh: '248', vacation: '404', sick: '403' } });
    const cfgOk = write('xm.hcmok.config.json', { ...cfg, navigation: [], paths: { ...cfg.paths, hcmConfig: hcmOk } });
    const r = await go([], portal, cfgOk);
    assert.strictEqual(r.exitCode, 0, r.log.error && r.log.error.message);
    assert.deepStrictEqual(r.log.leaveMismatches, [], 'no leave day should be flagged when HCM can file it');
    assert.ok(!r.log.warnings.some(w => /one-sided mismatch/.test(w)), 'no one-sided warning expected');
  }],
  ['leave day with a null HCM plan code is warned as a one-sided mismatch', async () => {
    // HCM vacation plan code is null -> the Thu vacation day would be filed in
    // XM only. XM must warn loudly and record the mismatch (but still fills XM).
    const hcmNull = write('hcm.null.config.json', { planCodes: { wfh: '248', vacation: null, sick: '403' } });
    const cfgNull = write('xm.hcmnull.config.json', { ...cfg, navigation: [], paths: { ...cfg.paths, hcmConfig: hcmNull } });
    const r = await go([], portal, cfgNull);
    assert.strictEqual(r.exitCode, 0, r.log.error && r.log.error.message);
    assert.ok(Array.isArray(r.log.leaveMismatches), 'leaveMismatches must be recorded');
    assert.deepStrictEqual(r.log.leaveMismatches.map(m => m.date), ['2026-09-24'], 'the Thu vacation day is the mismatch');
    assert.ok(r.log.warnings.some(w => /one-sided mismatch/.test(w)), 'a one-sided mismatch warning must be emitted');
    // XM still files its side (leave hours present), it just warns about HCM.
    assert.strictEqual(r.state.saved, true);
    assertCells(r.state.cells);
  }],
  ['draft: header, overwrite of imported cells, Save, no Submit (with navigation step)', async () => {
    const r = await go([], portal + '?landing=1', navCfgFile);
    assert.strictEqual(r.exitCode, 0, r.log.error && r.log.error.message);
    assert.strictEqual(r.log.result, 'saved-draft');
    // The landing page ("Create a New..." -> "Timesheet") was navigated end to end.
    assert.ok(r.state.clicks.some(c => /^Create a New/.test(c)), 'the "Create a New..." button must be clicked');
    assert.ok(r.log.steps.some(s => /navigation\[0\]/.test(s.msg)), 'navigation[0] (Create a New...) must run');
    assert.ok(r.log.steps.some(s => /navigation\[1\]/.test(s.msg)), 'navigation[1] (Timesheet) must run');
    assert.ok(r.log.steps.some(s => /Document Header screen found/.test(s.msg)), 'navigation must reach the Document Header');
    assert.strictEqual(r.state.headerSaved, true);
    assert.strictEqual(r.state.headerDate, '20/09/26');
    assert.strictEqual(r.state.selectedTimesheet, '13-Sep-2026 - 19-Sep-2026');
    assert.strictEqual(r.state.importHours, true);
    assert.strictEqual(r.state.saved, true);
    assert.strictEqual(r.state.submitted, false);
    assert.ok(!r.state.clicks.includes('Submit'), 'Submit must not be clicked in draft mode');
    assertCells(r.state.cells);
    assert.strictEqual(r.state.total, 43);
  }],
  ['submit: Save then Submit and confirm', async () => {
    const r = await go(['--mode', 'submit']);
    assert.strictEqual(r.exitCode, 0, r.log.error && r.log.error.message);
    assert.strictEqual(r.log.result, 'submitted');
    assert.strictEqual(r.state.saved, true);
    assert.strictEqual(r.state.submitted, true);
    assertCells(r.state.cells);
  }],
  ['dry run: fills, screenshots, cancels', async () => {
    const r = await go(['--dry-run']);
    assert.strictEqual(r.exitCode, 0, r.log.error && r.log.error.message);
    assert.strictEqual(r.state.saved, false);
    assert.strictEqual(r.state.cancelled, true);
    assert.ok(r.log.screenshot && fs.existsSync(r.log.screenshot));
  }],
  ['existing timesheet for the week is not duplicated', async () => {
    const r = await go([], portal + '?existing=1');
    assert.strictEqual(r.exitCode, 3);
    assert.match(r.log.error.message, /20-Sep-2026 - 26-Sep-2026 already exists/);
    assert.strictEqual(r.state.headerSaved, false);
  }],
  ['unconfigured imported row with hours aborts before Save', async () => {
    const r = await go([], portal + '?extra=1');
    assert.strictEqual(r.exitCode, 1);
    assert.strictEqual(r.log.error.code, 'VERIFY');
    assert.match(r.log.error.message, /footer Mon 21\/09/);
    assert.strictEqual(r.state.saved, false);
  }],
  ['landing page without navigation config fails clearly when non-interactive', async () => {
    const r = await go([], portal + '?landing=1');
    assert.strictEqual(r.exitCode, 4);
    assert.match(r.log.error.message, /navigation/);
  }],
  ['leave file fills unknown days as leave', async () => {
    const r = await run([...common, '--overrides', noOverrides, '--leave', leaveFile, '--config', cfgFile, '--url', portal, '--dry-run']);
    const kind = Object.fromEntries(r.log.days.map(d => [d.date, d.kind]));
    assert.strictEqual(kind['2026-09-23'], 'leave');
    assert.strictEqual(kind['2026-09-24'], 'leave');
    assert.strictEqual(r.exitCode, 0, r.log.error && r.log.error.message);
  }],
  ['HCM leave beats a wfh/office override (8 h, not 9 h)', async () => {
    const ov = write('ov-work.json', { '2026-09-23': 'wfh', '2026-09-24': 'office' });
    const lv = write('leave-wed-thu.json', { '2026-09-23': 'sick', '2026-09-24': 'leave' });
    const r = await run([...common, '--overrides', ov, '--leave', lv, '--config', cfgFile, '--url', portal, '--dry-run']);
    const day = d => r.log.days.find(x => x.date === d);
    assert.strictEqual(day('2026-09-23').kind, 'leave');
    assert.strictEqual(day('2026-09-23').status, 'sick');
    assert.strictEqual(day('2026-09-24').kind, 'leave');
    assert.strictEqual(r.log.expected['Personal Time Off And Holidays']['2026-09-23'], 8);
    assert.ok(r.log.warnings.some(w => /2026-09-23.*"wfh".*HCM shows sick/.test(w)), r.log.warnings.join(' | '));
    assert.strictEqual(r.exitCode, 0, r.log.error && r.log.error.message);
  }],
  ['a leave-type override still wins over the leave file', async () => {
    const ov = write('ov-vac.json', { '2026-09-23': 'vacation' });
    const lv = write('leave-wed.json', { '2026-09-23': 'sick' });
    const r = await run([...common, '--overrides', ov, '--leave', lv, '--config', cfgFile]);
    const wed = r.log.days.find(d => d.date === '2026-09-23');
    assert.strictEqual(wed.kind, 'leave');
    assert.strictEqual(wed.status, 'vacation');
    assert.strictEqual(r.exitCode, 2); // Thu still unknown -> stops before the browser
  }],
  ['headless run on a login page exits 5', async () => {
    const r = await run([...common, '--overrides', overrides, '--config', loginCfgFile, '--url', 'data:text/html,<input type="password">']);
    assert.strictEqual(r.exitCode, 5);
    assert.strictEqual(r.log.error.code, 'LOGIN_NEEDED');
  }],
];

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`PASS ${name}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}\n  ${e.stack}`);
    }
  }
  console.log(failed ? `${failed} test(s) failed` : 'all tests passed');
  process.exitCode = failed ? 1 : 0;
})();
