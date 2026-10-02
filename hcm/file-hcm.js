#!/usr/bin/env node
'use strict';
/*
 * Infor HCM auto-filer: files one "Request Time Off" per WFH / leave day on the
 * Employee Self Service calendar, based on Get-DailySummary.ps1 -AsJson output.
 *
 *   node file-hcm.js --summary summary.json [--overrides overrides.json]
 *        [--from yyyy-mm-dd] [--to yyyy-mm-dd] [--mode draft|submit] [--dry-run]
 *        [--headless] [--allow-future] [--config other.json] [--today yyyy-mm-dd]
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const HERE = __dirname;
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'];
const NO_FILE_OVERRIDES = ['office', 'skip', 'none', 'ignore'];

// ---------------------------------------------------------------- utilities
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pad = (n) => String(n).padStart(2, '0');
const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const parseYmd = (s) => { const [y, m, d] = s.split('-').map(Number); return { y, m, d }; };
const toDmy = (s) => { const { y, m, d } = parseYmd(s); return `${pad(d)}/${pad(m)}/${y}`; };
// Dialog date format, e.g. 'DD/MM/YYYY' or 'M/D/YYYY' (D/M = no zero padding).
const DATE_TOKENS = /YYYY|DD|MM|D|M/g;
const formatDate = (s, fmt) => {
  const { y, m, d } = parseYmd(s);
  const v = { YYYY: y, DD: pad(d), MM: pad(m), D: d, M: m };
  return fmt.replace(DATE_TOKENS, (t) => String(v[t]));
};
/** True when a field value means the same y-m-d as s under fmt (the UI may re-pad what was typed). */
const sameDate = (value, s, fmt) => {
  const order = fmt.match(DATE_TOKENS).map((t) => t[0]);
  const rx = new RegExp(`^${fmt.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(DATE_TOKENS, '(\\d+)')}$`);
  const mt = String(value).trim().match(rx);
  if (!mt) return false;
  const got = Object.fromEntries(order.map((k, i) => [k, Number(mt[i + 1])]));
  const { y, m, d } = parseYmd(s);
  return got.Y === y && got.M === m && got.D === d;
};
const log = (...a) => console.log(...a);

function usage() {
  log(`Usage: node file-hcm.js --summary <summary.json> [options]
  --summary <path>     JSON from Get-DailySummary.ps1 -AsJson ([{date,status}])
  --overrides <path>   {"yyyy-mm-dd":"vacation"|"sick"|"wfh"|"office"|"skip"} (default: hcm/overrides.json if present)
  --from / --to        only process dates in this range (yyyy-mm-dd)
  --mode draft|submit  draft = "Save as draft and submit later" (default); submit = "Submit request for approval"
  --dry-run            fill the dialog, screenshot it, then Cancel
  --allow-future       allow filing dates after today
  --headless           run the browser hidden (login must already be cached)
  --config <path>      config file merged over hcm.config.json`);
}

function parseArgs(argv) {
  const a = { mode: 'draft', dryRun: false, headless: false, allowFuture: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const val = () => { if (i + 1 >= argv.length) throw new Error(`${k} needs a value`); return argv[++i]; };
    switch (k) {
      case '--summary': a.summary = val(); break;
      case '--overrides': a.overrides = val(); break;
      case '--from': a.from = val(); break;
      case '--to': a.to = val(); break;
      case '--mode': a.mode = val().toLowerCase(); break;
      case '--dry-run': a.dryRun = true; break;
      case '--headless': a.headless = true; break;
      case '--allow-future': a.allowFuture = true; break;
      case '--config': a.config = val(); break;
      case '--today': a.today = val(); break;
      case '-h': case '--help': a.help = true; break;
      default: throw new Error(`Unknown argument: ${k}`);
    }
  }
  if (!['draft', 'submit'].includes(a.mode)) throw new Error('--mode must be draft or submit');
  for (const k of ['from', 'to', 'today']) {
    if (a[k] && !/^\d{4}-\d{2}-\d{2}$/.test(a[k])) throw new Error(`--${k} must be yyyy-mm-dd`);
  }
  return a;
}

function readJsonFile(p) {
  let buf = fs.readFileSync(p);
  let text;
  if (buf[0] === 0xff && buf[1] === 0xfe) text = buf.slice(2).toString('utf16le');
  else if (buf[0] === 0xfe && buf[1] === 0xff) text = buf.slice(2).swap16().toString('utf16le');
  else text = buf.toString('utf8');
  text = text.replace(/^\uFEFF/, '').trim();
  return text ? JSON.parse(text) : null;
}

function deepMerge(base, over) {
  if (!over || typeof over !== 'object' || Array.isArray(over)) return over === undefined ? base : over;
  const out = { ...(base || {}) };
  for (const [k, v] of Object.entries(over)) {
    out[k] = v && typeof v === 'object' && !Array.isArray(v) && base && typeof base[k] === 'object' && !Array.isArray(base[k])
      ? deepMerge(base[k], v) : v;
  }
  return out;
}

function loadConfig(extraPath) {
  let cfg = readJsonFile(path.join(HERE, 'hcm.config.json'));
  if (extraPath) cfg = deepMerge(cfg, readJsonFile(path.resolve(extraPath)));
  return cfg;
}

function expandEnv(p) {
  return p.replace(/%([^%]+)%/g, (m, name) => {
    if (process.env[name]) return process.env[name];
    if (name.toUpperCase() === 'LOCALAPPDATA') return path.join(os.homedir(), '.local', 'share');
    return m;
  });
}

function normDate(v) {
  if (v == null) return null;
  const s = String(v);
  const ms = s.match(/\/Date\((\d+)/); // legacy PowerShell ConvertTo-Json DateTime
  if (ms) return ymd(new Date(Number(ms[1])));
  const m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

function loadSummary(p) {
  let data = readJsonFile(p);
  if (data && !Array.isArray(data)) data = Array.isArray(data.days) ? data.days : [data];
  const out = [];
  for (const row of data || []) {
    if (!row || typeof row !== 'object') continue;
    const get = (name) => { const k = Object.keys(row).find((x) => x.toLowerCase() === name); return k ? row[k] : undefined; };
    const date = normDate(get('date'));
    if (!date) continue;
    out.push({ date, status: String(get('status') || 'unknown').toLowerCase().trim() });
  }
  return out;
}

function parseText(v) {
  if (typeof v === 'string') {
    const m = v.match(/^\/(.*)\/([a-z]*)$/s);
    if (m) return new RegExp(m[1], m[2]);
  }
  return v;
}

const xq = (s) => (s.includes("'") ? `concat('${s.split("'").join("',\"'\",'")}')` : `'${s}'`);

/** Turns a selector spec from the config into a Playwright locator. */
function specToLocator(scope, spec) {
  if (typeof spec === 'string') return scope.locator(spec);
  const exact = spec.exact === undefined ? {} : { exact: spec.exact };
  if (spec.label) return scope.getByLabel(parseText(spec.label), exact);
  if (spec.role) return scope.getByRole(spec.role, spec.name ? { name: parseText(spec.name), ...exact } : {});
  if (spec.text) return scope.getByText(parseText(spec.text), exact);
  if (spec.near) {
    // editable inputs that follow the (innermost) element whose text starts with spec.near;
    // firstAvailable picks the n-th *visible* one (datepickers can add hidden inputs in between)
    const t = xq(spec.near);
    const input = "input[not(@type='hidden') and not(@type='checkbox') and not(@type='radio') and not(@type='file') and not(@type='button')]";
    return scope.locator(`xpath=(.//*[starts-with(normalize-space(.), ${t}) and not(.//*[starts-with(normalize-space(.), ${t})])]/following::${input})`);
  }
  if (spec.css) return scope.locator(spec.css);
  throw new Error(`Bad selector spec: ${JSON.stringify(spec)}`);
}

/** First spec that resolves to a (visible, unless requireVisible=false) element. */
async function firstAvailable(scope, specs, timeoutMs = 3000, requireVisible = true) {
  const list = Array.isArray(specs) ? specs : [specs];
  const deadline = Date.now() + timeoutMs;
  let fallback = null;
  do {
    for (const spec of list) {
      const loc = specToLocator(scope, spec);
      const nth = typeof spec === 'object' && spec.nth !== undefined && !spec.near ? [spec.nth] : null;
      const count = await loc.count().catch(() => 0);
      if (typeof spec === 'object' && spec.near) {
        let seen = 0;
        for (let i = 0; i < Math.min(count, 10); i++) {
          const el = loc.nth(i);
          if (!(await el.isVisible().catch(() => false))) continue;
          if (seen++ === (spec.nth || 0)) return el;
        }
        continue;
      }
      for (const i of nth || [...Array(Math.min(count, 10)).keys()]) {
        if (i >= count) continue;
        const el = loc.nth(i);
        if (await el.isVisible().catch(() => false)) return el;
        if (!fallback) fallback = el;
      }
    }
    if (!requireVisible && fallback) return fallback;
    await sleep(250);
  } while (Date.now() < deadline);
  return requireVisible ? null : fallback;
}

// ---------------------------------------------------------------- calendar
async function readHeader(frame, sel) {
  const t = await frame.evaluate(({ css, re }) => {
    const rx = new RegExp(re, 'i');
    const norm = (el) => (el.textContent || '').replace(/\s+/g, ' ').trim();
    const els = document.querySelectorAll(css || 'body *');
    for (const el of els) {
      if (!el.getClientRects().length) continue;
      const t = norm(el);
      if (t.length > 40 || !rx.test(t)) continue;
      if (!css && [...el.children].some((c) => rx.test(norm(c)))) continue;
      return t;
    }
    return null;
  }, { css: sel.monthHeaderCss, re: sel.monthHeaderRegex }).catch(() => null);
  if (!t) return null;
  const m = t.match(new RegExp(sel.monthHeaderRegex, 'i'));
  const month = MONTHS.findIndex((x) => x.toLowerCase() === m[1].toLowerCase()) + 1;
  return { text: t, year: Number(m[2]), month };
}

async function readCells(frame, sel) {
  return frame.evaluate((s) => {
    const visible = (el) => el.getClientRects().length > 0;
    const otherRx = s.otherMonthClassRegex ? new RegExp(s.otherMonthClassRegex, 'i') : null;
    const cells = [...document.querySelectorAll(s.dayCell)].filter(visible)
      .filter((c) => !c.closest('[role="dialog"], .modal, .popupmenu-wrapper, .datepicker'));
    // FullCalendar draws entries in a separate layer positioned over the grid, not inside the day cells,
    // so match them to cells by geometry.
    const overlays = s.overlayEventSelector
      ? [...document.querySelectorAll(s.overlayEventSelector)].filter(visible)
        .map((e) => ({ r: e.getBoundingClientRect(), text: (e.textContent || '').replace(/\s+/g, ' ').trim() }))
      : [];
    const overlaps = (a, b) => Math.min(a.right, b.right) - Math.max(a.left, b.left) > 2
      && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 2;
    let phase = 0;
    return cells.map((c, idx) => {
      c.setAttribute('data-autofill-idx', String(idx));
      let numEl = s.dayNumber ? c.querySelector(s.dayNumber) : null;
      let day = numEl ? parseInt(numEl.textContent.trim(), 10) : NaN;
      if (Number.isNaN(day)) {
        const w = document.createTreeWalker(c, NodeFilter.SHOW_TEXT);
        let n;
        while ((n = w.nextNode())) {
          if (/^\d{1,2}$/.test(n.textContent.trim())) { day = parseInt(n.textContent.trim(), 10); numEl = n.parentElement; break; }
        }
      }
      if (day === 1) phase++;
      const parts = [];
      const w = document.createTreeWalker(c, NodeFilter.SHOW_TEXT);
      let n;
      while ((n = w.nextNode())) {
        if (numEl && numEl.contains(n)) continue;
        const p = n.parentElement;
        if (p && !visible(p)) continue;
        const t = n.textContent.replace(/\s+/g, ' ').trim();
        if (t) parts.push(t);
      }
      const cr = c.getBoundingClientRect();
      const overlayHits = overlays.filter((o) => overlaps(o.r, cr));
      for (const o of overlayHits) if (o.text) parts.push(o.text);
      const key = (c.getAttribute('data-key') || c.getAttribute('data-date') || '').replace(/-/g, '').trim();
      return {
        idx,
        day,
        key: /^\d{8}$/.test(key) ? key : '',
        other: (otherRx ? otherRx.test(c.className || '') : false) || phase !== 1,
        text: parts.join(' ').trim(),
        hasEvent: s.eventSelector ? !!c.querySelector(s.eventSelector) : false,
        isHoliday: s.holidaySelector ? (c.matches(s.holidaySelector) || !!c.querySelector(s.holidaySelector)) : false,
      };
    });
  }, sel);
}

async function isCalendar(frame, sel) {
  const h = await readHeader(frame, sel);
  if (!h) return false;
  const cells = await readCells(frame, sel).catch(() => []);
  return cells.length >= 28;
}

/** Re-reads the cells until two consecutive reads match (events loaded) and no busy indicator. */
async function stableCells(frame, cfg) {
  const sel = cfg.selectors;
  await sleep(cfg.timeouts.monthSettleMs);
  let prev = null;
  for (let i = 0; i < 20; i++) {
    const busy = sel.busySelector ? await frame.locator(sel.busySelector).filter({ visible: true }).count().catch(() => 0) : 0;
    const cells = await readCells(frame, sel);
    const sig = JSON.stringify(cells.map((c) => [c.day, c.text, c.hasEvent]));
    if (!busy && sig === prev) return cells;
    prev = sig;
    await sleep(700);
  }
  return readCells(frame, sel);
}

async function gotoMonth(frame, cfg, year, month) {
  const sel = cfg.selectors;
  for (let i = 0; i < 48; i++) {
    const h = await readHeader(frame, sel);
    if (!h) throw new Error('Calendar month header not found');
    const diff = (year - h.year) * 12 + (month - h.month);
    if (diff === 0) return;
    const btn = await firstAvailable(frame, diff < 0 ? sel.prevMonth : sel.nextMonth, 5000);
    if (!btn) throw new Error(`${diff < 0 ? 'Previous' : 'Next'} month button not found`);
    await btn.click();
    const until = Date.now() + 10000;
    while (Date.now() < until) {
      const n = await readHeader(frame, sel);
      if (n && n.text !== h.text) break;
      await sleep(200);
    }
  }
  throw new Error(`Could not navigate to ${MONTHS[month - 1]} ${year}`);
}

function findCell(cells, date) {
  const { y, m, d } = parseYmd(date);
  const key = `${y}${pad(m)}${pad(d)}`;
  return cells.find((c) => c.key === key) || cells.find((c) => !c.key && !c.other && c.day === d) || null;
}

function classifyCell(cell, sel) {
  let text = cell.text;
  if (sel.cellTextIgnoreRegex) text = text.replace(new RegExp(sel.cellTextIgnoreRegex, 'gi'), '').trim();
  if (cell.hasEvent || (text && new RegExp(sel.entryTextRegex, 'i').test(text))) return { kind: 'existing', text };
  if (cell.isHoliday || text) return { kind: 'holiday', text };
  return { kind: 'empty', text };
}

// ---------------------------------------------------------------- page / login
async function looksLikeLogin(page, cfg) {
  const url = page.url();
  const onApp = (cfg.urls.appUrlPatterns || []).some((p) => new RegExp(p, 'i').test(url));
  if (/^(about:|chrome-error:|edge-error:)/.test(url)) return false;
  if (!onApp) return true;
  for (const f of page.frames()) {
    const n = await f.locator(cfg.selectors.loginForm).filter({ visible: true }).count().catch(() => 0);
    if (n) return true;
  }
  return false;
}

async function waitForCalendar(page, cfg) {
  const start = Date.now();
  let deadline = start + cfg.timeouts.calendarMs;
  let told = false;
  while (Date.now() < deadline) {
    for (const f of page.frames()) {
      if (await isCalendar(f, cfg.selectors).catch(() => false)) return f;
    }
    if (await looksLikeLogin(page, cfg).catch(() => false)) {
      if (!told) {
        log('Please log in in the opened browser window (waiting up to 5 minutes)...');
        told = true;
        deadline = Math.max(deadline, Date.now() + cfg.timeouts.loginMs);
      }
    } else if (told) {
      // login finished: give the app the normal amount of time to load from here
      deadline = Math.min(deadline, Date.now() + cfg.timeouts.calendarMs);
      told = false;
    }
    await sleep(1000);
  }
  return null;
}

async function openCalendar(page, cfg) {
  for (const [name, url] of [['app', cfg.urls.app], ['portal', cfg.urls.portal]]) {
    if (!url) continue;
    log(`Opening HCM calendar (${name} URL)...`);
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    } catch (e) {
      log(`  navigation warning: ${e.message.split('\n')[0]}`);
    }
    const frame = await waitForCalendar(page, cfg);
    if (frame) return frame;
    log(`  calendar not found via ${name} URL.`);
  }
  return null;
}

async function launch(cfg, headless) {
  const { chromium } = require('playwright');
  const userDataDir = expandEnv(cfg.browser.userDataDir);
  fs.mkdirSync(userDataDir, { recursive: true });
  const opts = headless
    ? { headless: true, viewport: { width: 1440, height: 900 } }
    : { headless: false, viewport: null, args: ['--start-maximized'] };
  if (cfg.browser.channel) {
    try {
      return await chromium.launchPersistentContext(userDataDir, { ...opts, channel: cfg.browser.channel });
    } catch (e) {
      log(`Could not start ${cfg.browser.channel} (${e.message.split('\n')[0]}); falling back to bundled Chromium.`);
    }
  }
  return chromium.launchPersistentContext(userDataDir, opts);
}

// ---------------------------------------------------------------- dialog
async function findDialog(page, frame, cfg, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  do {
    for (const f of [frame, ...page.frames().filter((x) => x !== frame)]) {
      const d = await firstAvailable(f, cfg.selectors.dialog, 0);
      if (d) return d;
    }
    await sleep(250);
  } while (Date.now() < deadline);
  return null;
}

async function openDialog(page, frame, cfg, cellIdx, state) {
  const strategies = state.strategy
    ? [state.strategy, ...cfg.openStrategies.filter((s) => s !== state.strategy)]
    : cfg.openStrategies;
  const cell = frame.locator(`[data-autofill-idx="${cellIdx}"]`);
  for (const s of strategies) {
    try {
      if (s === 'click' || s === 'dblclick') {
        const box = await cell.boundingBox();
        const position = box ? { x: box.width * cfg.clickPosition.x, y: box.height * cfg.clickPosition.y } : undefined;
        await (s === 'click' ? cell.click({ position }) : cell.dblclick({ position }));
      } else if (s === 'button') {
        const b = await firstAvailable(frame, cfg.selectors.openButton, 1500);
        if (!b) continue;
        await b.click();
      } else continue;
      let dlg = await findDialog(page, frame, cfg, cfg.timeouts.dialogOpenMs);
      if (!dlg && s !== 'button') {
        // the click may have opened a context menu/popover containing the action
        const b = await firstAvailable(frame, cfg.selectors.openButton, 500);
        if (b) { await b.click(); dlg = await findDialog(page, frame, cfg, cfg.timeouts.dialogOpenMs); }
      }
      if (dlg) { state.strategy = s; return dlg; }
      await page.keyboard.press('Escape').catch(() => {});
    } catch (e) {
      log(`    open strategy "${s}" failed: ${e.message.split('\n')[0]}`);
    }
  }
  return null;
}

async function setChecked(dlg, specs, labelText) {
  // HCM reveals Full Day / Half Day only after the plan's details load, a moment after its label shows,
  // so wait for a visible control before falling back to a hidden one.
  const el = (await firstAvailable(dlg, specs, 10000)) || (await firstAvailable(dlg, specs, 0, false));
  if (!el) throw new Error(`"${labelText}" control not found`);
  if (await el.isChecked().catch(() => false)) return;
  try { await el.check({ timeout: 3000 }); } catch {
    try { await el.check({ force: true, timeout: 3000 }); } catch {
      // Infor's styled checkboxes keep the <input> invisible and render the visible control on its <label>;
      // the dialog also holds hidden copies, so click the visible label and judge by the input it points to.
      const esc = labelText.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const labels = dlg.locator('label').filter({ hasText: new RegExp(`^\\s*${esc}\\s*$`) });
      const n = Math.min(await labels.count().catch(() => 0), 10);
      for (let i = 0; i < n; i++) {
        const lb = labels.nth(i);
        if (!(await lb.isVisible().catch(() => false))) continue;
        await lb.click({ timeout: 5000 });
        const forId = await lb.getAttribute('for');
        if (forId && (await dlg.locator(`[id="${forId}"]`).isChecked().catch(() => false))) return;
      }
    }
  }
  if (!(await el.isChecked().catch(() => false))) throw new Error(`Could not select "${labelText}"`);
}

async function fillInput(dlg, specs, value, what) {
  const el = await firstAvailable(dlg, specs, 3000);
  if (!el) throw new Error(`${what} field not found`);
  await el.click();
  await el.fill('');
  await el.fill(value);
  await el.press('Tab');
  return el;
}

async function readErrors(dlg, sel) {
  const loc = dlg.locator(sel.dialogError);
  const n = Math.min(await loc.count().catch(() => 0), 10);
  const msgs = [];
  for (let i = 0; i < n; i++) {
    const el = loc.nth(i);
    if (!(await el.isVisible().catch(() => false))) continue;
    const t = (await el.innerText().catch(() => '')).replace(/\s+/g, ' ').trim();
    if (t && !msgs.includes(t)) msgs.push(t);
  }
  return msgs;
}

async function cancelDialog(page, dlg, cfg) {
  const c = await firstAvailable(dlg, cfg.selectors.cancelButton, 2000);
  if (c) await c.click().catch(() => {}); else await page.keyboard.press('Escape').catch(() => {});
  await dlg.waitFor({ state: 'hidden', timeout: 5000 }).catch(() => {});
}

async function fillAndSave(page, frame, dlg, cfg, args, job, shotDir) {
  const sel = cfg.selectors;
  const dateFmt = cfg.dateFormat || 'DD/MM/YYYY';
  const dmy = formatDate(job.date, dateFmt);
  const label = (cfg.planLabels || {})[job.planCode];

  // Dates before the plan: editing a date makes HCM clear the plan (and its Full Day / Half Day options).
  // The dialog opens pre-filled with the clicked day, so only retype a date that differs.
  const dateField = async (specs, what) => {
    const el = await firstAvailable(dlg, specs, 3000);
    if (!el) throw new Error(`${what} field not found`);
    // pin it: the "n-th input after 'Dates'" locator resolves elsewhere once the plan's fields appear
    const id = await el.getAttribute('id').catch(() => null);
    const pinned = id ? dlg.locator(`[id="${id}"]`) : el;
    if (!sameDate(await pinned.inputValue(), job.date, dateFmt)) await fillInput(dlg, id ? [`[id="${id}"]`] : specs, dmy, what);
    return pinned;
  };
  const from = await dateField(sel.dateFrom, 'From date');
  const to = await dateField(sel.dateTo, 'To date');

  await fillInput(dlg, sel.planInput, job.planCode, 'Plan');
  if (label) {
    try {
      await dlg.getByText(label, { exact: false }).first().waitFor({ state: 'visible', timeout: cfg.timeouts.planConfirmMs });
    } catch {
      throw new Error(`Plan ${job.planCode} not confirmed: label "${label}" did not appear`);
    }
  } else {
    await sleep(1500);
  }

  await setChecked(dlg, sel.fullDay, 'Full Day');
  await setChecked(dlg, args.mode === 'submit' ? sel.submitRadio : sel.draftRadio,
    args.mode === 'submit' ? 'Submit request for approval' : 'Save as draft and submit later');
  if (cfg.additionalInfo) {
    const ai = await firstAvailable(dlg, sel.additionalInfo, 2000);
    if (ai) await ai.fill(cfg.additionalInfo);
  }
  const got = [await from.inputValue(), await to.inputValue()];
  if (!sameDate(got[0], job.date, dateFmt) || !sameDate(got[1], job.date, dateFmt)) throw new Error(`Date fields hold "${got[0]}" / "${got[1]}", expected "${dmy}"`);

  if (args.dryRun) {
    const shot = path.join(shotDir, `${job.date}-dryrun.png`);
    await page.screenshot({ path: shot });
    await cancelDialog(page, dlg, cfg);
    return { result: 'dry-run', detail: `filled and cancelled; screenshot ${shot}` };
  }

  const ok = await firstAvailable(dlg, sel.okButton, 3000);
  if (!ok) throw new Error('OK button not found');
  await ok.click();

  const deadline = Date.now() + cfg.timeouts.afterOkMs;
  let errors = [];
  while (Date.now() < deadline) {
    if (!(await dlg.isVisible().catch(() => false))) break;
    errors = await readErrors(dlg, sel);
    if (errors.length) { await sleep(1000); errors = await readErrors(dlg, sel); break; }
    await sleep(300);
  }
  if (await dlg.isVisible().catch(() => false)) {
    const shot = path.join(shotDir, `${job.date}-error.png`);
    await page.screenshot({ path: shot }).catch(() => {});
    await cancelDialog(page, dlg, cfg);
    return { result: 'error', detail: errors.length ? errors.join(' | ') : 'dialog did not close after OK', screenshot: shot };
  }

  // a follow-up message box (confirmation / warning) may appear after the dialog closes
  let message = null;
  const msg = await (async () => {
    for (const f of [frame, ...page.frames().filter((x) => x !== frame)]) {
      const m = await firstAvailable(f, sel.postSubmitMessage, 0);
      if (m) return m;
    }
    return null;
  })();
  if (msg) {
    message = (await msg.innerText().catch(() => '')).replace(/\s+/g, ' ').trim();
    const b = await firstAvailable(msg, [{ role: 'button', name: '/^(OK|Close|Yes)$/i' }], 1000);
    if (b) await b.click().catch(() => {});
    if (/error|fail|not allowed|invalid/i.test(message)) return { result: 'error', detail: message };
  }

  const cells = await stableCells(frame, cfg);
  const cell = findCell(cells, job.date);
  const verified = cell && classifyCell(cell, sel).kind !== 'empty';
  return {
    result: verified ? 'filed' : 'filed-unverified',
    detail: (verified ? `calendar shows "${cell.text}"` : 'dialog closed but no entry visible in the cell yet') + (message ? `; message: ${message}` : ''),
  };
}

// ---------------------------------------------------------------- main
function planJobs(summary, overrides, cfg, args, today) {
  const byDate = new Map();
  for (const r of summary) byDate.set(r.date, { date: r.date, status: r.status });
  for (const [d, v] of Object.entries(overrides)) {
    const date = normDate(d);
    if (date) byDate.set(date, { ...(byDate.get(date) || { date, status: 'unknown' }), override: String(v).toLowerCase().trim() });
  }
  const results = [];
  const jobs = [];
  const unknown = [];
  for (const e of [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date))) {
    if (args.from && e.date < args.from) continue;
    if (args.to && e.date > args.to) continue;
    const r = { date: e.date, status: e.status, override: e.override };
    results.push(r);
    let planKey = null;
    if (e.override) {
      if (NO_FILE_OVERRIDES.includes(e.override)) { r.result = 'skipped-override'; continue; }
      planKey = e.override;
    } else if (e.status === 'wfh') planKey = 'wfh';
    else if (e.status === 'office') { r.result = 'skipped-office'; continue; }
    else { r.result = 'needs-input'; unknown.push(e.date); continue; }

    const { y, m, d } = parseYmd(e.date);
    if ((cfg.weekendDays || []).includes(new Date(y, m - 1, d).getDay())) { r.result = 'skipped-weekend'; continue; }
    if (e.date > today && !args.allowFuture) { r.result = 'skipped-future'; continue; }
    const code = (cfg.planCodes || {})[planKey];
    if (code == null || code === '') {
      r.result = 'skipped-unconfigured';
      r.detail = `no plan code configured for "${planKey}" (set planCodes.${planKey} in hcm.config.json)`;
      log(`WARNING ${e.date}: ${r.detail}`);
      continue;
    }
    r.plan = planKey;
    r.planCode = String(code);
    jobs.push(r);
  }
  return { results, jobs, unknown };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { usage(); return 0; }
  if (!args.summary && !args.overrides && !fs.existsSync(path.join(HERE, 'overrides.json'))) {
    usage();
    throw new Error('--summary is required');
  }
  const cfg = loadConfig(args.config);
  const today = args.today || ymd(new Date());
  const summary = args.summary ? loadSummary(path.resolve(args.summary)) : [];
  const ovPath = args.overrides ? path.resolve(args.overrides) : path.join(HERE, 'overrides.json');
  const overrides = fs.existsSync(ovPath) ? readJsonFile(ovPath) || {} : {};
  if (args.overrides && !fs.existsSync(ovPath)) throw new Error(`Overrides file not found: ${ovPath}`);

  const logDir = path.resolve(HERE, cfg.paths.logDir);
  const shotDir = path.resolve(HERE, cfg.paths.screenshotDir);
  fs.mkdirSync(logDir, { recursive: true });
  fs.mkdirSync(shotDir, { recursive: true });

  const { results, jobs, unknown } = planJobs(summary, overrides, cfg, args, today);
  log(`Mode: ${args.mode}${args.dryRun ? ' (dry run)' : ''}; ${results.length} day(s) considered, ${jobs.length} to file.`);

  const runLog = {
    startedAt: new Date().toISOString(), today, mode: args.mode, dryRun: args.dryRun,
    summary: args.summary ? path.resolve(args.summary) : null, overrides: fs.existsSync(ovPath) ? ovPath : null,
    results,
  };

  let context = null;
  try {
    if (jobs.length) {
      context = await launch(cfg, args.headless);
      const page = context.pages()[0] || (await context.newPage());
      const frame = await openCalendar(page, cfg);
      if (!frame) {
        for (const j of jobs) { j.result = 'error'; j.detail = 'HCM calendar could not be opened (login timeout or page changed)'; }
      } else {
        const state = { strategy: null };
        for (const job of jobs) {
          try {
            const { y, m } = parseYmd(job.date);
            await gotoMonth(frame, cfg, y, m);
            const cells = await stableCells(frame, cfg);
            const cell = findCell(cells, job.date);
            if (!cell) throw new Error('day cell not found in month view');
            const c = classifyCell(cell, cfg.selectors);
            if (c.kind !== 'empty') {
              job.result = c.kind === 'existing' ? 'skipped-existing' : 'skipped-holiday';
              job.detail = c.text || '(cell marked)';
            } else {
              const dlg = await openDialog(page, frame, cfg, cell.idx, state);
              if (!dlg) throw new Error(`could not open the Request Time Off dialog (tried: ${cfg.openStrategies.join(', ')})`);
              try {
                Object.assign(job, await fillAndSave(page, frame, dlg, cfg, args, job, shotDir));
              } catch (e) {
                const shot = path.join(shotDir, `${job.date}-error.png`);
                await page.screenshot({ path: shot }).catch(() => {});
                job.screenshot = shot;
                await cancelDialog(page, dlg, cfg).catch(() => {});
                throw e;
              }
            }
          } catch (e) {
            job.result = 'error';
            job.detail = e.message.split('\n')[0];
          }
          log(`  ${job.date} ${job.plan} (${job.planCode}): ${job.result}${job.detail ? ' - ' + job.detail : ''}`);
        }
      }
    }
  } finally {
    if (context) await context.close().catch(() => {});
    runLog.finishedAt = new Date().toISOString();
    runLog.unknownDays = unknown;
    const logFile = path.join(logDir, `run-${runLog.startedAt.replace(/[:.]/g, '-')}.json`);
    fs.writeFileSync(logFile, JSON.stringify(runLog, null, 2));
    log('');
    for (const r of results) log(`${r.date}  ${(r.override || r.status).padEnd(9)} ${r.result || '?'}`);
    if (unknown.length) log(`\nunknown days need your input: ${unknown.join(', ')}\n  (add them to hcm/overrides.json, e.g. {"${unknown[0]}":"vacation"})`);
    log(`Run log: ${logFile}`);
  }
  return results.some((r) => r.result === 'error') ? 1 : 0;
}

if (require.main === module) {
  main().then((code) => { process.exitCode = code; }, (e) => { console.error(`ERROR: ${e.message}`); process.exitCode = 2; });
}

module.exports = { loadSummary, planJobs, toDmy, normDate };
