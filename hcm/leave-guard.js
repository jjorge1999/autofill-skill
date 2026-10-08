'use strict';
/*
 * Shared "both or neither" leave guard for the HCM and XM filers.
 *
 * A day classified as leave (vacation / sick) must be fileable in BOTH systems:
 *   - HCM files it as a "Request Time Off" using the plan code in
 *     hcm.config.json planCodes (vacation -> 404, sick -> 403). If the plan
 *     code is null/empty the day CANNOT be filed in HCM.
 *   - XM always files a leave day as 8h "Personal Time Off And Holidays", so the
 *     XM side is always fileable.
 *
 * If a leave day can only be filed in one system, filing it would create a
 * mismatch between HCM and XM. Both filers use this module to detect that case
 * and warn loudly / flag the day instead of silently filing one-sided.
 *
 * This file lives in hcm/ and is required from xm/file-xm.js via a
 * path.join(..., 'hcm', 'leave-guard') so the require keeps working on Windows
 * regardless of the caller's working directory.
 */
const fs = require('fs');
const path = require('path');

// Leave statuses that XM books as 8h "Personal Time Off And Holidays".
const LEAVE_STATUSES = ['vacation', 'sick', 'holiday'];

// Which HCM planCodes key a leave status maps to. Only vacation/sick are
// time-off requests HCM files via a plan code; a public 'holiday' is shown
// natively in the HCM calendar (and skipped there), so it has no plan key and
// is NOT subject to the both-or-neither check.
const STATUS_TO_PLAN_KEY = { vacation: 'vacation', sick: 'sick' };

function isLeaveStatus(status) {
  return LEAVE_STATUSES.includes(String(status || '').toLowerCase().trim());
}

/** True only for leave that HCM files via a plan code (vacation/sick, not holiday). */
function isPlanCheckedLeave(status) {
  return !!STATUS_TO_PLAN_KEY[String(status || '').toLowerCase().trim()];
}

/** Reads planCodes from an hcm.config.json path (BOM tolerant). Returns {} on failure. */
function loadHcmPlanCodes(hcmConfigPath) {
  try {
    const buf = fs.readFileSync(hcmConfigPath);
    let text;
    if (buf[0] === 0xff && buf[1] === 0xfe) text = buf.slice(2).toString('utf16le');
    else if (buf[0] === 0xfe && buf[1] === 0xff) text = buf.slice(2).swap16().toString('utf16le');
    else text = buf.toString('utf8');
    text = text.replace(/^\uFEFF/, '').trim();
    const cfg = text ? JSON.parse(text) : {};
    return (cfg && cfg.planCodes) || {};
  } catch (e) {
    return {};
  }
}

/** Default path to hcm.config.json relative to this module (works from hcm/ and xm/). */
function defaultHcmConfigPath() {
  return path.join(__dirname, 'hcm.config.json');
}

/**
 * Is a given leave status fileable in HCM?
 * It is fileable when the mapped plan code is a non-null, non-empty value.
 */
function hcmCanFile(status, planCodes) {
  const key = STATUS_TO_PLAN_KEY[String(status || '').toLowerCase().trim()];
  if (!key) return false; // e.g. holiday has no HCM plan code of its own
  const code = (planCodes || {})[key];
  return code != null && String(code).trim() !== '';
}

/**
 * Checks a list of leave days against the HCM plan codes.
 *   days: [{ date, status }]
 *   planCodes: HCM planCodes object (null/missing => unconfigured)
 * Returns { ok, blocked: [{date, status, reason}] } where blocked lists every
 * vacation/sick day that cannot be filed in BOTH systems.
 */
function checkLeaveDays(days, planCodes) {
  const blocked = [];
  for (const d of days || []) {
    const status = String(d.status || '').toLowerCase().trim();
    // Only vacation/sick are time-off requests that HCM must file via a plan
    // code. A public holiday is booked as 8h in XM but shows up natively as a
    // holiday in the HCM calendar (skipped-holiday), so a holiday differing
    // between the two systems is expected, not a one-sided mismatch.
    const key = STATUS_TO_PLAN_KEY[status];
    if (!key) continue;
    if (!hcmCanFile(status, planCodes)) {
      blocked.push({
        date: d.date,
        status: d.status,
        reason: `HCM plan code for "${d.status}" is not configured (set planCodes.${key} in hcm/hcm.config.json)`,
      });
    }
  }
  return { ok: blocked.length === 0, blocked };
}

module.exports = {
  LEAVE_STATUSES,
  STATUS_TO_PLAN_KEY,
  isLeaveStatus,
  isPlanCheckedLeave,
  loadHcmPlanCodes,
  defaultHcmConfigPath,
  hcmCanFile,
  checkLeaveDays,
};
