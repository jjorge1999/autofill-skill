#!/usr/bin/env node
'use strict';
/*
 * Fills the weekly Infor XM timesheet from the presence summary.
 *
 *   node file-xm.js --summary summary.json [--week 2026-09-21] [--mode draft|submit]
 *                   [--dry-run] [--headless] [--assume-unknown-workday] [--force-edit]
 *                   [--no-import] [--config xm.config.json] [--overrides f] [--holidays f]
 *                   [--url u] [--profile dir] [--non-interactive]
 *
 * Exit codes: 0 ok, 1 error, 2 unknown days, 3 timesheet already exists, 4 header screen not reached, 5 sign-in needed (headless).
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const readline = require('readline');

const XM_DIR = __dirname;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const LEAVE = ['vacation', 'sick', 'holiday', 'leave'];
const WORK = ['office', 'wfh'];
const EXIT = { OK: 0, ERROR: 1, UNKNOWN_DAYS: 2, EXISTS: 3, NAV: 4, LOGIN_NEEDED: 5 };

class XmError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

// ---------- args / config ----------
function parseArgs(argv) {
  const o = { mode: 'draft' };
  const takes = { '--week': 'week', '--summary': 'summary', '--mode': 'mode', '--config': 'config',
    '--overrides': 'overrides', '--holidays': 'holidays', '--url': 'url', '--profile': 'profile', '--leave': 'leave' };
  const flags = { '--dry-run': 'dryRun', '--headless': 'headless', '--assume-unknown-workday': 'assumeUnknownWorkday',
    '--force-edit': 'forceEdit', '--no-import': 'noImport', '--non-interactive': 'nonInteractive', '--help': 'help', '-h': 'help' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (takes[a]) {
      if (i + 1 >= argv.length) throw new XmError('ARGS', `${a} needs a value`);
      o[takes[a]] = argv[++i];
    } else if (flags[a]) o[flags[a]] = true;
    else throw new XmError('ARGS', `Unknown argument: ${a}`);
  }
  if (!['draft', 'submit'].includes(o.mode)) throw new XmError('ARGS', `--mode must be draft or submit (got '${o.mode}')`);
  return o;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}

function resolveFrom(base, p) { return path.isAbsolute(p) ? p : path.resolve(base, p); }

function expandEnv(p) {
  return p.replace(/%([^%]+)%/g, (m, name) => {
    if (process.env[name]) return process.env[name];
    if (name.toUpperCase() === 'LOCALAPPDATA') return path.join(os.homedir(), 'AppData', 'Local');
    return m;
  });
}

function loadPlaywright() {
  const candidates = ['playwright', path.join(XM_DIR, '..', 'hcm', 'node_modules', 'playwright')];
  for (const c of candidates) {
    try { return require(c); } catch (e) { /* try next */ }
  }
  throw new XmError('DEPS', "Playwright not found. Run 'npm install' in the xm folder (or hcm folder).");
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
function formatDate(d, fmt) {
  return fmt.replace(/YYYY|YY|MM|DD|Mon|ddd/g, t => ({
    YYYY: String(d.getFullYear()),
    YY: String(d.getFullYear()).slice(-2),
    MM: String(d.getMonth() + 1).padStart(2, '0'),
    DD: String(d.getDate()).padStart(2, '0'),
    Mon: MONTHS[d.getMonth()],
    ddd: DAYS[d.getDay()],
  })[t]);
}
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function looseRe(text) { return '^\\s*' + escapeRe(text).replace(/\s+/g, '\\s*') + '\\s*$'; }

function weekOf(dateStr, cfg) {
  const ref = dateStr ? parseIso(dateStr) : (() => { const n = new Date(); return new Date(n.getFullYear(), n.getMonth(), n.getDate(), 12); })();
  if (!ref) throw new XmError('ARGS', `--week must be yyyy-MM-dd (got '${dateStr}')`);
  const startDay = cfg.weekStartDay || 0;
  const start = addDays(ref, -((ref.getDay() - startDay + 7) % 7));
  const dates = [...Array(7)].map((_, i) => addDays(start, i));
  return { start, end: dates[6], dates };
}

// Parses "13-Sep-2026 - 19-Sep-2026" into start/end Dates.
function parsePeriod(label) {
  const m = /(\d{1,2})-([A-Za-z]{3})-(\d{4})\s*-\s*(\d{1,2})-([A-Za-z]{3})-(\d{4})/.exec(label || '');
  if (!m) return null;
  const mon = s => MONTHS.findIndex(x => x.toLowerCase() === s.toLowerCase());
  if (mon(m[2]) < 0 || mon(m[5]) < 0) return null;
  return { start: new Date(+m[3], mon(m[2]), +m[1], 12), end: new Date(+m[6], mon(m[5]), +m[4], 12) };
}

// ---------- day classification ----------
function loadSummary(file) {
  if (!file) return [];
  let data = readJson(file);
  if (!Array.isArray(data)) data = [data];
  return data.map(x => ({ date: String(x.date ?? x.Date ?? '').slice(0, 10), status: String(x.status ?? x.Status ?? '').toLowerCase() }));
}
function loadOverrides(file) {
  if (!file || !fs.existsSync(file)) return {};
  const raw = readJson(file);
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    const val = String(v).toLowerCase();
    if (!LEAVE.includes(val) && !WORK.includes(val)) throw new XmError('CONFIG', `overrides.json: '${k}' has invalid value '${v}' (use vacation|sick|holiday|leave|wfh|office)`);
    out[k] = val;
  }
  return out;
}
function loadHolidays(file) {
  if (!file || !fs.existsSync(file)) return new Set();
  const raw = readJson(file);
  return new Set((Array.isArray(raw) ? raw : []).map(x => (typeof x === 'string' ? x : x && x.date)).filter(x => parseIso(x)));
}

function classifyWeek(week, cfg, src, opts) {
  const weekend = cfg.weekendDays || [0, 6];
  const summary = new Map(src.summary.map(s => [s.date, s.status]));
  return week.dates.map(d => {
    const date = iso(d);
    const day = { date, day: DAYS[d.getDay()] };
    if (weekend.includes(d.getDay())) return { ...day, kind: 'weekend', source: 'calendar' };
    if (src.holidays.has(date)) return { ...day, kind: 'leave', status: 'holiday', source: 'holidays.json' };
    if (src.overrides[date]) {
      const v = src.overrides[date];
      return { ...day, kind: LEAVE.includes(v) ? 'leave' : 'workday', status: v, source: 'overrides' };
    }
    const s = summary.get(date);
    if (WORK.includes(s)) return { ...day, kind: 'workday', status: s, source: 'summary' };
    if (opts.assumeUnknownWorkday) return { ...day, kind: 'workday', status: s || 'missing', source: 'assumed' };
    return { ...day, kind: 'unknown', status: s || 'missing', source: 'summary' };
  });
}

function expectedHours(days, cfg) {
  const rules = cfg.hours;
  const rows = [...new Set([...Object.keys(rules.workday), ...Object.keys(rules.leave)])];
  const exp = {};
  for (const r of rows) {
    exp[r] = {};
    for (const d of days) {
      if (d.kind === 'workday') exp[r][d.date] = Number(rules.workday[r] || 0);
      else if (d.kind === 'leave') exp[r][d.date] = Number(rules.leave[r] || 0);
    }
  }
  return { rows, exp };
}

// ---------- browser helpers ----------
function toMatcher(v) {
  if (typeof v === 'string') {
    const m = /^\/(.*)\/([a-z]*)$/.exec(v);
    if (m) return new RegExp(m[1], m[2]);
  }
  return v;
}
function specLocator(root, s) {
  if (typeof s === 'string') return root.locator(s);
  if (s.css) return root.locator(s.css);
  if (s.role) return root.getByRole(s.role, s.name !== undefined ? { name: toMatcher(s.name), exact: s.exact } : {});
  if (s.label) return root.getByLabel(toMatcher(s.label), { exact: s.exact });
  if (s.text) return root.getByText(toMatcher(s.text), { exact: s.exact });
  throw new XmError('CONFIG', `Bad selector spec: ${JSON.stringify(s)}`);
}
async function resolve(root, specs, { state = 'visible', timeout = 0, poll = 300 } = {}) {
  const list = Array.isArray(specs) ? specs : [specs];
  const deadline = Date.now() + timeout;
  do {
    for (const s of list) {
      try {
        const loc = specLocator(root, s);
        const n = await loc.count();
        for (let i = 0; i < n; i++) {
          const el = loc.nth(i);
          if (state === 'attached' || await el.isVisible()) return el;
        }
      } catch (e) {
        if (e instanceof XmError) throw e;
      }
    }
    if (Date.now() < deadline) await sleep(poll);
  } while (Date.now() < deadline);
  return null;
}
async function mustResolve(root, specs, what, opts) {
  const el = await resolve(root, specs, { timeout: 5000, ...opts });
  if (!el) throw new XmError('UI', `Could not find ${what} (selectors: ${JSON.stringify(specs)})`);
  return el;
}
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function visibleIn(frame, sel) {
  try { return await frame.locator(`${sel} >> visible=true`).count() > 0; } catch (e) { return false; }
}
async function findFrame(page, sel) {
  for (const f of page.frames()) if (await visibleIn(f, sel)) return f;
  return null;
}
async function waitForFrame(page, sel, ms, poll = 500) {
  const deadline = Date.now() + ms;
  for (;;) {
    const f = await findFrame(page, sel);
    if (f || Date.now() >= deadline) return f;
    await sleep(poll);
  }
}
async function frameText(frame) {
  try { return (await frame.locator('body').innerText()).replace(/\s+/g, ' '); } catch (e) { return ''; }
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(res => rl.question(question, a => { rl.close(); res(a); }));
}

// Runs inside the XM frame. Finds the element at (column header x, row label y).
// mode 'input' marks the matching input with data-xm-autofill=<mark>; mode 'read' returns its value/text.
function locateCellInPage(a) {
  const norm = s => (s || '').replace(/\s+/g, ' ').trim();
  const all = Array.from(document.querySelectorAll('body *'));
  const rectOf = e => e.getBoundingClientRect();
  const vis = e => { const r = rectOf(e); return r.width > 0 && r.height > 0; };
  const text = e => norm(e.innerText !== undefined ? e.innerText : e.textContent);
  const smallest = pred => all.filter(e => vis(e) && pred(e))
    .sort((x, y) => (rectOf(x).width * rectOf(x).height) - (rectOf(y).width * rectOf(y).height))[0];
  const colRe = new RegExp(a.colRe, 'i');
  const rowRe = new RegExp(a.rowRe, 'i');
  let head = smallest(e => colRe.test(text(e)));
  if (!head) return { found: false, reason: `column '${a.colLabel}' not found` };
  head = head.closest(a.headerSel) || head;
  const hr = rectOf(head);
  const label = all.filter(e => vis(e) && rowRe.test(text(e)) && rectOf(e).top > hr.top)
    .sort((x, y) => (rectOf(x).width * rectOf(x).height) - (rectOf(y).width * rectOf(y).height))[0];
  if (!label) return { found: false, reason: `row '${a.rowLabel}' not found` };
  const lr = rectOf(label);
  const ry = (lr.top + lr.bottom) / 2;
  const pick = els => els.map(e => ({ e, r: rectOf(e) }))
    .filter(({ r }) => r.width > 0 && r.height > 0)
    .map(o => ({ ...o, cx: (o.r.left + o.r.right) / 2, cy: (o.r.top + o.r.bottom) / 2 }))
    .filter(o => o.cx >= hr.left && o.cx <= hr.right && Math.abs(o.cy - ry) <= Math.max(lr.height, o.r.height) / 2 + 2)
    .sort((x, y) => Math.abs(x.cy - ry) - Math.abs(y.cy - ry))[0];
  const input = pick(Array.from(document.querySelectorAll(a.inputSel)));
  if (a.mode === 'input') {
    if (!input) return { found: false, reason: `no input at row '${a.rowLabel}' x column '${a.colLabel}'` };
    input.e.setAttribute('data-xm-autofill', a.mark);
    return { found: true, value: input.e.value, disabled: !!input.e.disabled };
  }
  if (input) return { found: true, value: input.e.value };
  const cell = pick(all.filter(e => e.children.length === 0 && /^-?\d+([.,]\d+)?$/.test(text(e))));
  if (!cell) return { found: false, reason: `no value at row '${a.rowLabel}' x column '${a.colLabel}'` };
  return { found: true, value: text(cell.e) };
}

let markSeq = 0;
async function locateCell(frame, cfg, rowLabel, rowRe, colLabel, colRe, mode) {
  const mark = `xm${++markSeq}`;
  const r = await frame.evaluate(locateCellInPage, {
    rowLabel, rowRe, colLabel, colRe, mode, mark,
    headerSel: cfg.selectors.gridHeaderCell, inputSel: cfg.selectors.gridCellInput,
  });
  return { ...r, locator: frame.locator(`[data-xm-autofill="${mark}"]`) };
}
const num = v => { const n = parseFloat(String(v ?? '').replace(',', '.')); return Number.isFinite(n) ? n : 0; };
const same = (a, b) => Math.abs(a - b) < 0.005;

// ---------- main flow ----------
async function run(argv, hooks = {}) {
  const startedAt = new Date();
  const ts = startedAt.toISOString().replace(/[:.]/g, '-');
  const log = { startedAt: startedAt.toISOString(), argv, steps: [], warnings: [], result: null };
  const step = msg => { log.steps.push({ t: new Date().toISOString(), msg }); console.log(`[xm] ${msg}`); };
  const warn = msg => { log.warnings.push(msg); console.warn(`[xm] WARNING: ${msg}`); };
  let cfg; let context; let page; let logDir; let shotDir;

  const shot = async name => {
    if (!page) return null;
    try {
      fs.mkdirSync(shotDir, { recursive: true });
      const f = path.join(shotDir, `${name}-${ts}.png`);
      await page.screenshot({ path: f, fullPage: true });
      step(`screenshot ${f}`);
      return f;
    } catch (e) { warn(`screenshot failed: ${e.message}`); return null; }
  };

  try {
    const opts = parseArgs(argv);
    log.options = opts;
    if (opts.help) {
      console.log('Usage: node file-xm.js --summary <file> [--week yyyy-MM-dd] [--mode draft|submit] [--dry-run] [--headless] [--assume-unknown-workday] [--force-edit] [--non-interactive] [--leave <file>]');
      log.result = 'help';
      return { exitCode: EXIT.OK, log };
    }
    const cfgPath = opts.config ? path.resolve(opts.config) : path.join(XM_DIR, 'xm.config.json');
    cfg = readJson(cfgPath);
    const cfgDir = path.dirname(cfgPath);
    logDir = resolveFrom(XM_DIR, cfg.paths.logDir || 'logs');
    shotDir = resolveFrom(XM_DIR, cfg.paths.screenshotDir || 'screenshots');
    const T = cfg.timeouts;
    const S = cfg.selectors;

    if (opts.noImport) {
      throw new XmError('UNSUPPORTED', '--no-import is not supported yet: without importing the previous timesheet the rows would have to be added one by one with Add. Run without --no-import.');
    }

    // 1. classify the week
    const week = weekOf(opts.week, cfg);
    log.week = { start: iso(week.start), end: iso(week.end) };
    const overridesPath = opts.overrides ? path.resolve(opts.overrides) : resolveFrom(cfgDir, cfg.paths.overrides);
    const holidaysPath = opts.holidays ? path.resolve(opts.holidays) : resolveFrom(cfgDir, cfg.paths.holidays);
    const src = {
      summary: loadSummary(opts.summary && path.resolve(opts.summary)),
      // HCM leave entries first; explicit overrides win
      overrides: { ...loadOverrides(opts.leave && path.resolve(opts.leave)), ...loadOverrides(overridesPath) },
      holidays: loadHolidays(holidaysPath),
    };
    if (!opts.summary) warn('No --summary given; every weekday without an override or holiday counts as unknown.');
    const days = classifyWeek(week, cfg, src, opts);
    log.days = days;
    step(`week ${log.week.start} .. ${log.week.end}: ` + days.filter(d => d.kind !== 'weekend').map(d => `${d.day} ${d.date}=${d.kind}(${d.status})`).join(', '));
    const unknown = days.filter(d => d.kind === 'unknown');
    if (unknown.length) {
      throw new XmError('UNKNOWN_DAYS',
        `Not filling: no office/WFH reading for ${unknown.map(d => `${d.date} (${d.day})`).join(', ')}.\n` +
        `Add these dates to ${overridesPath}, e.g. {"${unknown[0].date}": "vacation"} (vacation|sick|holiday|leave|wfh|office), ` +
        'or rerun with --assume-unknown-workday.');
    }
    const { rows, exp } = expectedHours(days, cfg);
    const weekdays = days.filter(d => d.kind !== 'weekend');
    log.expected = exp;

    // 2. browser
    const pw = loadPlaywright();
    const userDataDir = expandEnv(opts.profile || cfg.browser.userDataDir);
    fs.mkdirSync(userDataDir, { recursive: true });
    const launchOpts = { headless: !!opts.headless, viewport: cfg.browser.viewport || null };
    const attempts = cfg.browser.channel ? [{ channel: cfg.browser.channel }] : [];
    if (!cfg.browser.channel || cfg.browser.fallbackToChromium !== false) attempts.push({});
    let lastErr;
    for (const a of attempts) {
      try {
        context = await pw.chromium.launchPersistentContext(userDataDir, { ...launchOpts, ...a });
        step(`launched ${a.channel || 'bundled chromium'} with profile ${userDataDir}`);
        break;
      } catch (e) {
        lastErr = e;
        warn(`launch ${a.channel || 'chromium'} failed: ${e.message.split('\n')[0]}`);
      }
    }
    if (!context) throw new XmError('BROWSER', `Could not start a browser (is the profile ${userDataDir} open in another window?): ${lastErr && lastErr.message}`);
    page = context.pages()[0] || await context.newPage();
    page.on('dialog', async d => { step(`browser dialog '${d.message()}' -> accept`); try { await d.accept(); } catch (e) { /* already handled */ } });

    const url = opts.url || cfg.urls.portal;
    step(`opening ${url}`);
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    // 3. login
    const appPatterns = (cfg.urls.appUrlPatterns || []).map(p => new RegExp(p));
    const loginStart = Date.now();
    const loginDeadline = loginStart + T.loginMs;
    let toldLogin = false;
    let loginSince = 0;
    for (;;) {
      if (await findFrame(page, S.documentHeader)) break;
      const loginVisible = !!(await findFrame(page, S.loginForm));
      if (!loginVisible && appPatterns.some(re => re.test(page.url()))) break;
      if (opts.headless) {
        // SSO redirects show the login page briefly even with a valid session, so require it to persist
        loginSince = loginVisible ? (loginSince || Date.now()) : 0;
        if ((loginSince && Date.now() - loginSince > (T.headlessLoginMs || 15000)) || Date.now() - loginStart > (T.headlessAppMs || 60000)) {
          throw new XmError('LOGIN_NEEDED', 'Infor sign-in needed: the headless run stopped at the login page. Rerun without --headless and sign in.');
        }
      } else if (!toldLogin) { step(`waiting up to ${Math.round(T.loginMs / 60000)} min for you to log in in the browser window...`); toldLogin = true; }
      if (Date.now() > loginDeadline) throw new XmError('LOGIN', 'Timed out waiting for login.');
      await sleep(T.pollMs);
    }
    step('logged in');

    // 4. reach the Document Header screen
    let frame = await waitForFrame(page, S.documentHeader, Math.min(5000, T.headerMs), T.pollMs);
    if (!frame && (cfg.navigation || []).length) {
      for (const [i, nav] of cfg.navigation.entries()) {
        if (nav.waitMs) { await sleep(nav.waitMs); continue; }
        if (!nav.click) throw new XmError('CONFIG', `navigation[${i}] needs 'click' or 'waitMs'`);
        let target = null;
        const deadline = Date.now() + T.navStepMs;
        while (!target && Date.now() < deadline) {
          for (const f of page.frames()) { target = await resolve(f, nav.click); if (target) break; }
          if (!target) await sleep(T.pollMs);
        }
        if (!target) throw new XmError('NAV', `navigation[${i}]: ${JSON.stringify(nav.click)} not found`);
        step(`navigation[${i}]: click ${JSON.stringify(nav.click)}`);
        await target.click();
      }
    }
    if (!frame) frame = await waitForFrame(page, S.documentHeader, T.headerMs, T.pollMs);
    if (!frame) {
      if (opts.nonInteractive || !process.stdin.isTTY) {
        await shot('no-header');
        throw new XmError('NAV', "The XM 'Document Header' (new Timesheet) screen was not found. Add the clicks that open it to 'navigation' in xm.config.json, e.g. [{\"click\": \"text=New Timesheet\"}], or run interactively.");
      }
      await ask('Navigate to the new Timesheet screen in the browser, then press Enter ');
      frame = await waitForFrame(page, S.documentHeader, 10000, T.pollMs);
      if (!frame) throw new XmError('NAV', "Still no 'Document Header' screen visible.");
    }
    step('Document Header screen found');

    // 5. header
    const headerDate = formatDate(week.start, cfg.dateFormat);
    const dateInput = await mustResolve(frame, S.headerDate, 'Date input');
    await dateInput.fill(headerDate);
    await dateInput.press('Tab');
    step(`Date = ${headerDate} (field now '${await dateInput.inputValue()}')`);

    // Picks the latest timesheet before this week in a "Timesheet" dropdown and ticks Import Hours.
    // Used on the Document Header and on the grid's Import screen, which share these two controls.
    const pickImportSource = async (f) => {
      const select = await mustResolve(f, S.timesheetSelect, 'Timesheet select', { state: 'attached' });
      const options = await select.evaluate(s => Array.from(s.options).map(o => ({ value: o.value, label: (o.textContent || '').trim() })));
      const periods = options.map(o => ({ ...o, p: parsePeriod(o.label) })).filter(o => o.p);
      const prev = periods.filter(o => iso(o.p.end) < iso(week.start)).sort((x, y) => x.p.end - y.p.end).pop();
      if (!prev) throw new XmError('UI', `No previous timesheet in the dropdown to import from (options: ${options.map(o => o.label).join(' | ')})`);
      await select.selectOption(prev.value ? { value: prev.value } : { label: prev.label }, { force: true });
      const chosen = await select.evaluate(s => (s.options[s.selectedIndex] && s.options[s.selectedIndex].textContent || '').trim());
      if (chosen !== prev.label) throw new XmError('UI', `Selecting '${prev.label}' failed (dropdown shows '${chosen}')`);
      step(`Timesheet = ${prev.label}`);
      const imp = await mustResolve(f, S.importHours, 'Import Hours checkbox', { state: 'attached' });
      try { await imp.check({ timeout: 3000 }); } catch (e) { await imp.check({ force: true }); }
      if (!await imp.isChecked()) throw new XmError('UI', 'Could not tick Import Hours');
      step('Import Hours ticked');
    };

    const select = await mustResolve(frame, S.timesheetSelect, 'Timesheet select', { state: 'attached' });
    const options = await select.evaluate(s => Array.from(s.options).map(o => ({ value: o.value, label: (o.textContent || '').trim() })));
    const periods = options.map(o => ({ ...o, p: parsePeriod(o.label) })).filter(o => o.p);
    log.timesheetOptions = options.map(o => o.label);
    const existing = periods.find(o => iso(o.p.start) <= iso(week.end) && iso(o.p.end) >= iso(week.start));
    if (existing) {
      // An empty draft (e.g. a run that stopped after the header Save) is reopened and filled; anything else is left alone.
      frame = await openEmptyDraft(page, cfg, S, T, existing.label, url, step);
      if (!frame) throw new XmError('EXISTS', `A timesheet for ${existing.label} already exists and is not an empty draft; not touching it.`);
      await (await mustResolve(frame, S.gridImport, 'grid Import button')).click();
      const importFrame = await waitForFrame(page, S.importScreen, T.gridMs, T.pollMs);
      if (!importFrame) { await shot('no-import'); throw new XmError('UI', "The Import screen did not appear after clicking Import."); }
      await pickImportSource(importFrame);
      await (await mustResolve(importFrame, S.importConfirm, 'Import button on the Import screen')).click();
      step('Import clicked');
      const goneBy = Date.now() + T.gridMs;
      while (await findFrame(page, S.importScreen) && Date.now() < goneBy) await sleep(T.pollMs);
    } else {
      await pickImportSource(frame);
      await (await mustResolve(frame, S.headerSave, 'header Save button')).click();
      step('header Save clicked');
    }

    // 6. grid
    frame = await waitForFrame(page, S.editTimeItems, T.gridMs, T.pollMs);
    if (!frame) { await shot('no-grid'); throw new XmError('UI', "'Edit Time Items' screen did not appear after header Save."); }
    const periodLabel = `${formatDate(week.start, cfg.periodFormat)} - ${formatDate(week.end, cfg.periodFormat)}`;
    if (!new RegExp(escapeRe(periodLabel).replace(/\\? /g, '\\s*'), 'i').test(await frameText(frame))) {
      await shot('wrong-period');
      throw new XmError('UI', `Edit Time Items does not show period ${periodLabel}; stopping before changing anything.`);
    }
    step(`Edit Time Items for ${periodLabel}`);

    const colOf = d => { const l = formatDate(parseIso(d.date), cfg.dayColumnFormat); return { label: l, re: looseRe(l) }; };
    const rowRe = r => '^' + escapeRe(r).replace(/\\? /g, '\\s+') + '$';
    const fmt = n => Number(n).toFixed(2);

    for (const r of rows) {
      for (const d of weekdays) {
        const c = colOf(d);
        const cell = await locateCell(frame, cfg, r, rowRe(r), c.label, c.re, 'input');
        if (!cell.found) throw new XmError('UI', `Grid: ${cell.reason}. Did Import Hours bring in row '${r}'?`);
        if (cell.disabled) throw new XmError('UI', `Grid: cell ${r} / ${c.label} is disabled`);
        await cell.locator.fill(fmt(exp[r][d.date]));
        await cell.locator.press('Tab');
      }
      step(`filled ${r}: ` + weekdays.map(d => fmt(exp[r][d.date])).join(' '));
    }

    // 7. verify before Save
    const problems = [];
    const dayTotals = {};
    const weekendDays = days.filter(d => d.kind === 'weekend');
    let grand = 0;
    const totalHeader = await frame.evaluate(re => Array.from(document.querySelectorAll('body *'))
      .some(e => new RegExp(re, 'i').test((e.innerText || '').replace(/\s+/g, ' ').trim())), S.weekTotalHeader);
    for (const r of rows) {
      let rowTotal = 0;
      for (const d of weekdays) {
        const c = colOf(d);
        const cell = await locateCell(frame, cfg, r, rowRe(r), c.label, c.re, 'read');
        const v = num(cell.value);
        if (!cell.found || !same(v, exp[r][d.date])) problems.push(`${r} ${c.label}: expected ${fmt(exp[r][d.date])}, cell shows '${cell.value}'`);
        rowTotal += exp[r][d.date];
        dayTotals[d.date] = (dayTotals[d.date] || 0) + exp[r][d.date];
      }
      for (const d of weekendDays) {
        const c = colOf(d);
        const cell = await locateCell(frame, cfg, r, rowRe(r), c.label, c.re, 'read');
        const v = cell.found ? num(cell.value) : 0;
        if (v) warn(`${r} ${c.label} has ${fmt(v)} hours (weekend, left untouched)`);
        rowTotal += v;
        dayTotals[d.date] = (dayTotals[d.date] || 0) + v;
      }
      grand += rowTotal;
      if (totalHeader) {
        const t = await locateCell(frame, cfg, r, rowRe(r), 'Week Total', S.weekTotalHeader, 'read');
        if (!t.found || !same(num(t.value), rowTotal)) problems.push(`${r} Week Total: expected ${fmt(rowTotal)}, shows '${t.value}'`);
      }
    }
    if (!totalHeader) warn("'Week Total' column not found; row totals not verified");
    let footerChecked = false;
    for (const d of weekdays) {
      const c = colOf(d);
      const t = await locateCell(frame, cfg, 'footer', S.footerLabel, c.label, c.re, 'read');
      if (!t.found) continue;
      footerChecked = true;
      if (!same(num(t.value), dayTotals[d.date])) problems.push(`footer ${c.label}: expected ${fmt(dayTotals[d.date])}, shows '${t.value}' (extra rows in the grid?)`);
    }
    if (!footerChecked) warn('footer day totals not found; not verified');
    log.expectedTotal = grand;
    step(`expected total ${fmt(grand)}; ${problems.length ? problems.length + ' mismatch(es)' : 'grid verified'}`);

    if (opts.dryRun) {
      log.screenshot = await shot('dry-run');
      await (await mustResolve(frame, S.gridCancel, 'grid Cancel button')).click();
      await confirmDialog(page, S, Math.min(3000, T.confirmMs), step);
      step('dry run: Cancel clicked, nothing saved on the grid (note: header Save already ran)');
      if (problems.length) throw new XmError('VERIFY', 'Grid verification failed:\n  ' + problems.join('\n  '));
      log.result = 'dry-run';
      return { exitCode: EXIT.OK, log };
    }
    if (problems.length) {
      await shot('verify-failed');
      throw new XmError('VERIFY', 'Grid verification failed, NOT saving:\n  ' + problems.join('\n  '));
    }

    // 8. save
    await (await mustResolve(frame, S.gridSave, 'grid Save button')).click();
    step('grid Save clicked');
    const totalRe = new RegExp(`Total\\s*Hours:\\s*0*${Math.trunc(grand)}(\\.${fmt(grand).split('.')[1]}0*)?(?![\\d.])`, 'i');
    const saveDeadline = Date.now() + T.saveMs;
    let saved = null;
    while (!saved && Date.now() < saveDeadline) {
      const f = await findFrame(page, S.savedMarker);
      if (f && totalRe.test(await frameText(f))) saved = f;
      else await sleep(T.pollMs);
    }
    if (!saved) { await shot('save-unverified'); throw new XmError('VERIFY', `After Save, 'Total Hours: ${fmt(grand)}' was not shown.`); }
    frame = saved;
    step(`saved, header shows Total Hours: ${fmt(grand)}`);

    if (opts.mode === 'submit') {
      await (await mustResolve(frame, S.submitButton, 'Submit button')).click();
      step('Submit clicked');
      await confirmDialog(page, S, T.confirmMs, step);
      if (await waitForFrame(page, S.submittedMarker, T.submitMs, T.pollMs)) step('submitted');
      else warn('Submit clicked but no "Submitted" confirmation seen; check XM.');
      log.result = 'submitted';
    } else {
      log.result = 'saved-draft';
    }
    await shot(log.result);
    return { exitCode: EXIT.OK, log };
  } catch (e) {
    log.result = 'error';
    log.error = { code: e.code || 'ERROR', message: e.message };
    console.error(`[xm] ${e.code ? e.code + ': ' : ''}${e.message}`);
    if (page && !['EXISTS', 'NAV', 'LOGIN_NEEDED'].includes(e.code)) await shot('error');
    const exitCode = { UNKNOWN_DAYS: EXIT.UNKNOWN_DAYS, EXISTS: EXIT.EXISTS, NAV: EXIT.NAV, LOGIN_NEEDED: EXIT.LOGIN_NEEDED }[e.code] ?? EXIT.ERROR;
    return { exitCode, log };
  } finally {
    if (context) {
      if (hooks.beforeClose) { try { await hooks.beforeClose(page); } catch (e) { log.hookError = e.message; } }
      await context.close().catch(() => {});
    }
    log.finishedAt = new Date().toISOString();
    try {
      logDir = logDir || path.join(XM_DIR, 'logs');
      fs.mkdirSync(logDir, { recursive: true });
      const f = path.join(logDir, `run-${ts}.json`);
      fs.writeFileSync(f, JSON.stringify(log, null, 2));
      log.logFile = f;
    } catch (e) { console.error(`[xm] could not write run log: ${e.message}`); }
  }
}

// Opens the week's existing timesheet from My Documents if it is an empty draft (status matches
// selectors.emptyDraftStatus, every amount 0). Returns its Edit Time Items frame, or null to leave it alone.
async function openEmptyDraft(page, cfg, S, T, label, url, step) {
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  let row = null;
  const deadline = Date.now() + T.navStepMs;
  while (!row && Date.now() < deadline) {
    for (const f of page.frames()) {
      const r = f.locator(S.documentRow).filter({ hasText: label });
      if (await r.count().catch(() => 0)) { row = r; break; }
    }
    if (!row) await sleep(T.pollMs);
  }
  if (!row) { step(`${label} not found in My Documents`); return null; }
  if (await row.count() > 1) { step(`${label}: more than one document in My Documents`); return null; }
  const cells = (await row.locator('td').allInnerTexts()).map(t => t.replace(/\s+/g, ' ').trim()).filter(Boolean);
  step(`existing ${label}: ${cells.join(' | ')}`);
  const amounts = cells.filter(t => /^\d[\d,]*\.\d+$/.test(t)).map(t => Number(t.replace(/,/g, '')));
  const statusRe = toMatcher(S.emptyDraftStatus);
  if (!cells.some(t => statusRe.test(t)) || !amounts.length || amounts.some(n => n !== 0)) return null;
  await row.getByText(label).first().click();
  const grid = await waitForFrame(page, S.editTimeItems, T.gridMs, T.pollMs);
  if (!grid) throw new XmError('UI', `Opened ${label} but its 'Edit Time Items' screen did not appear.`);
  step(`opened empty draft ${label}`);
  return grid;
}

// Clicks Yes/OK/Submit/Confirm in an in-page modal if one appears (native dialogs are auto-accepted).
async function confirmDialog(page, S, ms, step) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    for (const f of page.frames()) {
      try {
        const dlg = f.locator(`${S.confirmDialog} >> visible=true`).first();
        if (await dlg.count()) {
          const btn = dlg.getByRole('button', { name: toMatcher(S.confirmButtonName) }).first();
          if (await btn.count()) {
            step(`confirm dialog: clicking '${(await btn.innerText()).trim()}'`);
            await btn.click();
            return true;
          }
        }
      } catch (e) { /* frame detached */ }
    }
    await sleep(300);
  }
  return false;
}

module.exports = { run, parseArgs, parsePeriod, weekOf, classifyWeek, expectedHours, formatDate, EXIT };

if (require.main === module) {
  run(process.argv.slice(2)).then(r => {
    console.log(`[xm] result: ${r.log.result}${r.log.logFile ? ` (log ${r.log.logFile})` : ''}`);
    process.exitCode = r.exitCode;
  });
}
