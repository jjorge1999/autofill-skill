#!/usr/bin/env node
'use strict';
/*
 * Finds YOUR Jira account id (for tempo.config.json authorAccountId) by opening Jira in an Edge window
 * and asking Jira who is signed in (/rest/api/3/myself). Only your own profile is read.
 *
 *   node find-account.js [--save] [--url <jira page>] [--issues 123,456]   (--issues: print key/summary of issue ids)
 *
 * Sign in yourself in the window if asked (up to 5 minutes); the login is kept in
 * %LOCALAPPDATA%\InforAutofill\browser-profile-tempo. --save writes authorAccountId into tempo.config.json.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = __dirname;
const CFG = path.join(DIR, 'tempo.config.json');
const LOGIN_MS = 300000;

function loadPlaywright() {
  for (const c of ['playwright', path.join(DIR, '..', 'hcm', 'node_modules', 'playwright'), path.join(DIR, '..', 'xm', 'node_modules', 'playwright')]) {
    try { return require(c); } catch (e) { /* try next */ }
  }
  throw new Error("Playwright not found. Run 'npm install' in the hcm folder.");
}

(async () => {
  const argv = process.argv.slice(2);
  const save = argv.includes('--save');
  const cfg = JSON.parse(fs.readFileSync(CFG, 'utf8').replace(/^﻿/, ''));
  const jira = String(cfg.jiraBaseUrl || 'https://infor.atlassian.net').replace(/\/+$/, '');
  const ui = argv.includes('--url') ? argv[argv.indexOf('--url') + 1] : `${jira}/jira/your-work`;
  const profile = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'InforAutofill', 'browser-profile-tempo');
  fs.mkdirSync(profile, { recursive: true });

  const pw = loadPlaywright();
  let context;
  try { context = await pw.chromium.launchPersistentContext(profile, { channel: 'msedge', headless: false, viewport: null }); }
  catch (e) { context = await pw.chromium.launchPersistentContext(profile, { headless: false, viewport: null }); }
  try {
    const page = context.pages()[0] || await context.newPage();
    await page.goto(ui, { waitUntil: 'domcontentloaded' });
    console.log('[tempo] waiting for Jira to be signed in (sign in in the Edge window if asked)...');
    const deadline = Date.now() + LOGIN_MS;
    let me = null;
    while (!me && Date.now() < deadline) {
      if (page.url().startsWith(jira)) {
        me = await page.evaluate(async (base) => {
          try {
            const r = await fetch(`${base}/rest/api/3/myself`, { headers: { Accept: 'application/json' }, credentials: 'include' });
            if (!r.ok) return null;
            const j = await r.json();
            return j && j.accountId ? { accountId: j.accountId, displayName: j.displayName } : null;
          } catch (e) { return null; }
        }, jira).catch(() => null);
      }
      if (!me) await page.waitForTimeout(2000);
    }
    if (!me) { console.log('[tempo] not signed in to Jira within 5 minutes; nothing found.'); process.exitCode = 1; return; }
    console.log(`[tempo] signed in as ${me.displayName}: accountId ${me.accountId}`);
    // --issues 123,456: print key and summary of those issue ids (to fill worklogs in tempo.config.json)
    const ids = argv.includes('--issues') ? String(argv[argv.indexOf('--issues') + 1] || '').split(',').map(s => s.trim()).filter(Boolean) : [];
    for (const id of ids) {
      const issue = await page.evaluate(async ([base, i]) => {
        const r = await fetch(`${base}/rest/api/3/issue/${encodeURIComponent(i)}?fields=summary,status`, { headers: { Accept: 'application/json' }, credentials: 'include' });
        if (!r.ok) return { error: `HTTP ${r.status}` };
        const j = await r.json();
        return { key: j.key, summary: j.fields && j.fields.summary, status: j.fields && j.fields.status && j.fields.status.name };
      }, [jira, id]).catch(e => ({ error: e.message }));
      console.log(issue.error ? `[tempo] issue ${id}: ${issue.error}` : `[tempo] issue ${id} = ${issue.key} [${issue.status}] ${issue.summary}`);
    }
    if (save) {
      const text = fs.readFileSync(CFG, 'utf8');
      const next = text.replace(/"authorAccountId":\s*"[^"]*"/, `"authorAccountId": "${me.accountId}"`);
      if (next === text && cfg.authorAccountId !== me.accountId) throw new Error('authorAccountId not found in tempo.config.json');
      fs.writeFileSync(CFG, next);
      console.log('[tempo] saved authorAccountId in tempo.config.json');
    }
  } finally {
    await context.close().catch(() => {});
  }
})().catch(e => { console.error(`[tempo] ${e.message}`); process.exitCode = 1; });
