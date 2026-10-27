// Pure logic: zone grouping, sorting, counts, time formatting. Shared by browser and node; depends only on i18n.js (all UI text goes through t()).
import { t, tCode, isEn, fmtMD, fmtYMD, fmtWeekday, fmtWeekdayShort, fmtClockEn, dayPart, colon, comma, paren, RAW } from "./i18n.js";

// names are fetched for the current language on demand (getter), not fixed at module load
const UNZONED = { code: null, get name() { return t("c.unzoned"); }, color: "#8A8F98" };

// Status groups: waiting, unread and busy are mutually exclusive, classified in this priority order.
// Unexpected exit (disconnected) is its own group, gone, and counts toward nothing (even if an old backend wrongly gives it unread)
function kindOf(s) {
  if (s.status === "waiting") return "waiting";
  if (s.disconnected === true) return "gone";
  if (s.unread) return "unread";
  if (s.status === "busy") return "busy";
  return "other";
}

function countOf(sessions) {
  const c = { waiting: 0, unread: 0, busy: 0 };
  for (const s of sessions) {
    if (s.rest) continue;
    const k = kindOf(s);
    if (k !== "other" && k !== "gone") c[k] += 1;
  }
  return c;
}

const RANK = { waiting: 1, unread: 2, busy: 3, other: 4, gone: 4 };

function sortCards(cards, lead) {
  const rank = (s) => (s.pinned ? 0 : RANK[kindOf(s)]);
  const leadRank = (s) => (lead !== undefined && s.name === lead ? 0 : 1);
  return cards.slice().sort((a, b) =>
    rank(a) - rank(b) || leadRank(a) - leadRank(b) || (b.since || 0) - (a.since || 0));
}

export function buildLanes(snapshot) {
  const zones = (snapshot.zones || []).slice().sort((a, b) => a.order - b.order);
  const known = new Set(zones.map((z) => z.code));
  const sessions = snapshot.sessions || [];
  const offduty = (snapshot.offduty || []).slice().sort((a, b) => (b.offAt || 0) - (a.offAt || 0));
  const lanes = [];
  for (const z of zones.concat([UNZONED])) {
    const inZone = (code) => (z.code === null ? !known.has(code) : code === z.code);
    const mine = sessions.filter((s) => inZone(s.zone));
    const off = offduty.filter((o) => inZone(o.zone));
    if (!mine.length && !off.length) continue;
    lanes.push({
      code: z.code,
      name: z.name,
      color: z.color,
      lead: z.lead,
      counts: countOf(mine),
      cards: sortCards(mine.filter((s) => !s.rest), z.lead),
      rest: mine.filter((s) => s.rest),
      off,
    });
  }
  return lanes;
}

// Notifications that should be closed while in the foreground: the tag is "s-<conversation id>" and that conversation is no longer waiting / unread (or no longer in the snapshot). Other tags (e.g. test notifications) are left alone.
// linkOk: when the snapshot is fresh (Mac connected), the mac-link one (disconnected / restored) is cleared too
export function staleTags(tags, sessions, linkOk) {
  const live = new Set();
  for (const s of sessions || []) if (s.status === "waiting" || s.unread) live.add("s-" + s.id);
  return (tags || []).filter((t) => typeof t === "string" && ((linkOk && t === "mac-link") || (t.startsWith("s-") && !live.has(t))));
}

export function petState(s) {
  if (s.status === "waiting") return "waiting";
  if (s.status === "busy") return "running";
  if (s.rest) return "rest";
  if (s.unread) return "waving";
  return "idle";
}
// Which frame set the avatar plays (list row / chat page header). When background work is running and the main turn is idle (idle, bgTasks>0 and not stuck), the avatar stands and plays idle frames,
// and does not switch to working frames just because background work runs: only the main-turn status counts, and work is expressed only by the figures outside the frame (the bg flag of busyFx)
export function avatarPose(s) {
  return petState(s || {});
}

// With no pet installed the avatar uses Soulgent flame (the brand plush mascot, scaled to avatar size), with an expression by conversation status:
// waiting for you -> wait, working -> busy, resting -> rest, finished with unread -> done, otherwise idle
export const FLAME_FACE = { waiting: "wait", running: "busy", rest: "rest", waving: "done", idle: "idle" };
export const FLAME_AV_V = 1;
export function flameAvatarSrc(s) {
  return "/icons/mascot-av-" + (FLAME_FACE[petState(s || {})] || "idle") + ".png?v=" + FLAME_AV_V;
}
// What the avatar draws: a pet if there is one; if the pet manifest responded and has none (petsKnown === "none") -> Soulgent flame;
// if the manifest has not arrived (offline start) show the first character, so a conversation that should have a pet does not flash Soulgent flame first
export function avatarPick(s, petName, petsKnown) {
  if (petName) return { kind: "pet", name: petName };
  if (petsKnown === "none") return { kind: "flame", src: flameAvatarSrc(s) };
  return { kind: "ini" };
}

export function usageColor(pct) {
  if (pct >= 90) return "max";
  if (pct >= 70) return "high";
  if (pct >= 50) return "warn";
  return "ok";
}

export function relTime(sec, now) {
  const d = now - sec;
  if (d < 60) return t("time.justNow");
  if (d < 3600) return t("time.min", { n: Math.floor(d / 60) });
  if (d < 86400) return t("time.hour", { n: Math.floor(d / 3600) });
  if (d < 172800) return t("time.yesterday");
  return t("time.day", { n: Math.floor(d / 86400) });
}

// The ts of a chat item is an ISO string; convert to seconds, returning 0 if unparseable (the caller then draws no time divider)
export function isoToSec(ts) {
  const ms = Date.parse(ts);
  return Number.isNaN(ms) ? 0 : ms / 1000;
}

// ---------- reply ----------
// Helper failure reason -> sentence for the user: look up fail.<code> in i18n.js by code (unknown-status does not say "failed", so the user does not resend;
// context-* are context details; the helper runs claude -p "/context")

export const REQ_MAX_MS = 35000;      // at most 35 s from the tap on send (including each request's timeout)
export const REQ_404_GRACE_MS = 8000; // a just-sent request not being found for a short while is normal, treat it as pending

// Result of one poll of /api/requests/<rid> -> next step. httpStatus 0 means network error/timeout.
// Returns { status: "pending" } | { status: "done", lines? } | { status: "failed", error }
export function nextPollAction(httpStatus, body, elapsedMs) {
  if (httpStatus === 200 && body && (body.status === "done" || body.status === "failed")) {
    const r = { status: body.status };
    if (body.status === "failed") {
      r.error = body.error || "unknown";
      if (Number.isInteger(body.sentSteps) && body.sentSteps > 0) r.sentSteps = body.sentSteps;
    }
    if (body.lines !== undefined) r.lines = body.lines;
    return r;
  }
  if (httpStatus === 400) return { status: "failed", error: "bad-request" };
  if (httpStatus === 404 && elapsedMs >= REQ_404_GRACE_MS) return { status: "failed", error: "unknown-status" };
  if (elapsedMs >= REQ_MAX_MS) return { status: "failed", error: "helper-timeout" };
  return { status: "pending" };
}
export function failReason(code, fallback) {
  return tCode("fail.", code, "") || fallback || t("send.fail");
}

// Sends the server rejected outright because it is "stopped at a question/approval menu": nothing was sent, so drop the optimistic bubble (no red !) and put the text back in the input
export function dropOnFail(code) {
  return code === "at-menu" || code === "session-waiting" || code === "slash-forbidden"; // a guest's slash command blocked by the server
}

// Same rule as the server: newlines to spaces, strip control characters, trim. The preview in the confirm dialog is exactly the text that will be sent.
export function cleanReplyText(str) {
  return String(str == null ? "" : str)
    .replace(/\r\n|\r|\n/g, " ")
    .replace(/[\x00-\x1f\x7f]/g, "")
    .trim();
}

// ---------- answering in bubbles ----------
export const MAX_STEPS = 24; // same as the server: at most 24 steps per answer (a multi-select "other" entry needs many cursor moves down)
const MAX_KEY = 9;           // digit keys only go 1..9

// Single- and multi-select can both be answered on the phone; "other" needs the n+1 key, so at most 8 options; steps must not exceed the limit.
export function askAnswerable(questions) {
  if (!Array.isArray(questions) || !questions.length) return false;
  for (const q of questions) {
    if (!q) return false;
    const n = Array.isArray(q.options) ? q.options.length : 0;
    if (n < 1 || n + 1 > MAX_KEY) return false;
  }
  return true;
}

// Preview question (server marks preview: true = single-select with some option carrying a preview): Claude Code switches to a "list on the left, preview on the right" UI (2.1.310 source, v9 component):
// digit keys only move the cursor to item k, Enter selects (single question submits, multiple move to the next question), n writes a note, and there is no "other" row.
export function isPreviewQ(q) {
  return !!q && q.preview === true && !q.multiSelect;
}
// Whether this question can be answered with "other" (preview questions have no such row)
export function askHasOwn(q) {
  return !isPreviewQ(q);
}

// Preview-question note: in the Claude Code input box "\ + Enter" is a newline rather than submit, so strip the trailing backslash
function previewNote(v) {
  return v == null ? "" : cleanReplyText(cleanReplyText(v).replace(/\\+$/, ""));
}

// picks[i]: single-select = which option (1-based) or { text } for other; multi-select = { multi: [option numbers...], text? };
// a preview single-select can also be { pick: option number, note: note }.
// Single-select: option = key 1 (advances to the next question automatically); other = n+1, text, Enter.
// Preview single-select: option = key k + Enter; cannot use other (returns null).
// Preview single-select with a note (Claude Code 2.1.310 source): digit keys only move the cursor, and "moved" is recorded only if the cursor really changed position (pressing 1 with the cursor on item 1 does not count);
// n opens the note box; Enter in the note box = if there is a note and the cursor moved, select the cursor item and answer (single question submits, multiple go to the next question); if it did not move, record "(notes only)";
// each new question puts the cursor back on item 1 and clears the moved flag. So: press a digit != k first, then k, n, text, Enter, with no extra key after Enter. A note without choosing an option is unsupported.
// Multi-select: digit keys toggle (cursor stays); without other, press right to go to the next page; other = toggle n+1, move down n rows to that row, type, Tab to Next, Enter.
// With multiple questions or any multi-select, a review page comes last, so append 1 (Submit answers). Preview questions follow the Claude Code 2.1.310 behavior.
// Returns null if any entry is missing/out of range, any text is empty, or total steps exceed the limit.
export function buildAskSteps(questions, picks) {
  if (!askAnswerable(questions) || !Array.isArray(picks)) return null;
  const steps = [];
  let multi = false;
  for (let i = 0; i < questions.length; i++) {
    const n = questions[i].options.length;
    const p = picks[i];
    if (questions[i].multiSelect) {
      multi = true;
      if (!p || typeof p !== "object" || !Array.isArray(p.multi)) return null;
      const sel = Array.from(new Set(p.multi)).sort((a, b) => a - b);
      if (sel.some((k) => !Number.isInteger(k) || k < 1 || k > n)) return null;
      const text = p.text != null ? cleanReplyText(p.text) : "";
      if (!sel.length && !text) return null;
      for (const k of sel) steps.push({ key: String(k) });
      if (text) {
        steps.push({ key: String(n + 1) });
        for (let d = 0; d < n; d++) steps.push({ key: "down" });
        steps.push({ text }, { key: "tab" }, { key: "enter" });
      } else {
        steps.push({ key: "right" });
      }
    } else if (isPreviewQ(questions[i])) {
      const k = p && typeof p === "object" ? p.pick : p;
      if (!Number.isInteger(k) || k < 1 || k > n) return null;
      const note = p && typeof p === "object" ? previewNote(p.note) : "";
      if (!note) {
        steps.push({ key: String(k) }, { key: "enter" });
      } else {
        if (n < 2) return null; // only one item: the cursor cannot move, and the note would be recorded as "(notes only)"
        // press a digit != k first, then k (so the last press is a real move), n to open the note box, text, Enter (= select the cursor item and answer)
        steps.push({ key: k === 1 ? "2" : "1" }, { key: String(k) }, { key: "n" }, { text: note }, { key: "enter" });
      }
    } else if (p && typeof p === "object") {
      const text = cleanReplyText(p.text);
      if (!text) return null;
      steps.push({ key: String(n + 1) }, { text }, { key: "enter" });
    } else if (Number.isInteger(p) && p >= 1 && p <= n) {
      steps.push({ key: String(p) });
    } else {
      return null;
    }
  }
  if (questions.length >= 2 || multi) steps.push({ key: "1" });
  return steps.length <= MAX_STEPS ? steps : null;
}

// Buttons of an approval bubble: approve=1, approve and don't ask again=2, reject=esc; the three ExitPlanMode options mean different things (see approveDefs)
const APPROVE_KEY = { approve: "1", always: "2", deny: "esc", "plan-auto": "1", "plan-manual": "2", "plan-keep": "esc" };
export function approveSteps(choice) {
  const key = APPROVE_KEY[choice];
  return key ? [{ key }] : null;
}
// Buttons by tool name: for ExitPlanMode 1/2/esc are "approve and auto-accept edits / approve but confirm edits manually / keep planning"
export function approveDefs(toolText) {
  if (String(toolText || "").split(/\s/)[0] === "ExitPlanMode") {
    return [["plan-auto", t("appr.planAuto"), "ok"], ["plan-manual", t("appr.planManual"), "alt"], ["plan-keep", t("appr.planKeep"), "no"]];
  }
  return [["approve", t("appr.approve"), "ok"], ["always", t("appr.always"), "alt"], ["deny", t("appr.deny"), "no"]];
}

// Among the trailing run of tool entries, Claude Code asks one by one in order: take the earliest one still pending.
// Returns { idx, more } (more = how many approvals remain after it); null if none.
export function approveTarget(items) {
  let start = items.length;
  while (start > 0 && items[start - 1].role === "tool") start--;
  let idx = -1;
  let n = 0;
  for (let i = start; i < items.length; i++) {
    if (items[i].pending) { if (idx < 0) idx = i; n++; }
  }
  return idx < 0 ? null : { idx, more: n - 1 };
}

// Answering is allowed only if the last entry itself is an unanswered ask (if other messages/tools follow, it is no longer asking)
export function liveAskIndex(items) {
  const i = items.length - 1;
  return i >= 0 && items[i].role === "ask" && !items[i].answered ? i : -1;
}

// Sent records: key (toolUseId) -> { partial?: k }. Delete one when that prompt is no longer live (answered / no longer pending / no longer waiting / superseded).
export function pruneSent(sent, liveKeys) {
  for (const k of Array.from(sent.keys())) if (!liveKeys.has(k)) sent.delete(k);
}
export function partialFailText(k) {
  return t("send.partial", { n: k });
}

// Pacing of status checks after sending: every 0.3 s for the first 3 s, then every 0.7 s
export function pollDelayMs(elapsedMs) {
  return elapsedMs < 3000 ? 300 : 700;
}

// Chat page detail polling interval: 1 s when the current conversation is busy or waiting for you and the page is visible, otherwise 3 s (pollDetail does not fetch when the page is hidden anyway)
export const DETAIL_POLL_SLOW_MS = 3000;
export const DETAIL_POLL_FAST_MS = 1000;
export function detailPollMs(status, visible) {
  return visible && (status === "busy" || status === "waiting") ? DETAIL_POLL_FAST_MS : DETAIL_POLL_SLOW_MS;
}

// After a status change, re-fetch the question/approval card: every 0.5 s, stopping once the card arrives, the status is no longer waiting, or 3 s have passed
export const CARD_CHASE_STEP_MS = 500;
export const CARD_CHASE_MAX_MS = 3000;
export function cardChaseDone(status, items, elapsedMs) {
  if (elapsedMs >= CARD_CHASE_MAX_MS || status !== "waiting") return true;
  return !!approveTarget(items || []) || liveAskIndex(items || []) >= 0;
}

// Merge the newly fetched first page into the loaded entries: anchored on the first entry of the new page, keep the old entries before it (earlier pages).
// If the anchor is not found (more than a page of new entries), keep only the new page with reset=true; the caller must reset the "load earlier" cursor.
const itemKey = (it) => [it.role, it.ts, it.text, it.toolUseId || ""].join("|");
export function mergeItems(old, fresh) {
  if (!fresh.length) return { items: old, reset: false };
  if (!old.length) return { items: fresh, reset: true };
  const anchor = itemKey(fresh[0]);
  let j = -1;
  for (let i = old.length - 1; i >= 0; i--) if (itemKey(old[i]) === anchor) { j = i; break; }
  if (j < 0) return { items: fresh, reset: true };
  return { items: old.slice(0, j).concat(fresh), reset: false };
}

// ---------- off duty ----------
function offSpan(offAt, now) {
  const d = Math.max(0, now - offAt);
  if (d < 60) return null;
  if (d < 3600) return t("time.min", { n: Math.floor(d / 60) });
  if (d < 86400) return t("time.hour", { n: Math.floor(d / 3600) });
  return t("time.day", { n: Math.floor(d / 86400) });
}
// each roster row shows the off-duty duration, e.g. "off 3 hours" / "off 2 days"
export function offLine(offAt, now) {
  if (!offAt) return t("off.unknownTime");
  const sp = offSpan(offAt, now);
  return sp ? t("off.line", { t: sp }) : t("off.just");
}
// read-only chat page header, e.g. "off duty · 3 hours ago"
export function offHeader(offAt, now) {
  if (!offAt) return t("off.head");
  const sp = offSpan(offAt, now);
  return t("off.headAgo", { t: sp ? t("time.ago", { t: sp }) : t("time.justNow") });
}

// ---------- wake ----------
export const WAKE_MAX_MS = 150000; // same as the server's WAKE_HELPER_TIMEOUT
// Pacing of status checks after waking: every 0.3 s for the first 3 s, then every 1 s
export function offPollDelayMs(elapsedMs) {
  return elapsedMs < 3000 ? 300 : 1000;
}
const WAKE_STATUSES = new Set(["wake-failed", "wake-timeout", "not-offduty"]);
// Result of one poll of /api/requests/<rid> -> next step. httpStatus 0 means network error/timeout.
// Returns { status: "pending" } | { status: "done" } | { status: "failed", error, message? }
// maxMs / timeoutErr: going off duty reuses this polling; the timeout and error name differ
export const OFF_MAX_MS = 90000; // same as the server's OFF_HELPER_TIMEOUT
export function nextWakeAction(httpStatus, body, elapsedMs, maxMs = WAKE_MAX_MS, timeoutErr = "wake-timeout") {
  if (httpStatus === 200 && body) {
    if (body.status === "done") return { status: "done" };
    if (body.status === "failed" || WAKE_STATUSES.has(body.status)) {
      const r = { status: "failed", error: body.status === "failed" ? (body.error || "wake-failed") : body.status };
      if (body.message) r.message = String(body.message);
      return r;
    }
  }
  if (httpStatus === 400) return { status: "failed", error: "bad-request" };
  if (httpStatus === 404 && elapsedMs >= REQ_404_GRACE_MS) return { status: "failed", error: "unknown-status" };
  if (elapsedMs >= maxMs) return { status: "failed", error: timeoutErr };
  return { status: "pending" };
}
// Wake failure reasons are looked up by code in wakefail.<code>; if the server gave a message (an old helper gave the original Chinese text), it takes priority as is
// Translate by code first (the new helper gives only a code); only a code missing from the table falls back to the server's own wording (old helper's Chinese text, technical errors)
export function wakeFailText(r) {
  return tCode("wakefail.", r && r.error, "") || (r && r.message) || t("wake.fail");
}
// After a successful wake, find the now-live conversation in the snapshot by name
export function findAwake(snapshot, name) {
  return ((snapshot && snapshot.sessions) || []).find((s) => s.name === name) || null;
}

// Optimistic state after a successful send: pending = Map(sid -> { at: ms, baseGen: generatedAt of the snapshot at send time, orig: status at send time }).
// Show it in a new snapshot (generatedAt newer than the send) that says "not waiting for you, and different from before the send" status, or give up after 10 s.
export const OPTIMISTIC_MS = 10000;

// Working timer: how long from since to now (seconds), "m:ss", "h:mm:ss" beyond an hour
export function busyClock(since, now) {
  const d = Math.max(0, Math.floor(now - since));
  const p2 = (n) => String(n).padStart(2, "0");
  const h = Math.floor(d / 3600);
  const m = Math.floor((d % 3600) / 60);
  return h ? h + ":" + p2(m) + ":" + p2(d % 60) : m + ":" + p2(d % 60);
}

export function applyOptimistic(snapshot, pending, nowMs) {
  if (!snapshot || !pending || !pending.size) return { snap: snapshot, pending };
  const next = new Map();
  const bySid = new Map((snapshot.sessions || []).map((s) => [s.id, s]));
  const busy = new Set();
  for (const [sid, p] of pending) {
    const s = bySid.get(sid);
    if (!s || nowMs - p.at >= OPTIMISTIC_MS) continue;
    const newer = (snapshot.generatedAt || 0) > (p.baseGen || 0);
    if (newer && s.status !== "waiting" && s.status !== p.orig) continue;
    next.set(sid, p);
    busy.add(sid);
  }
  if (!busy.size) return { snap: snapshot, pending: next };
  // since is set to the moment send was pressed: the working timer starts at 0 instead of counting from the last finish
  const sessions = snapshot.sessions.map((s) => (busy.has(s.id) ? { ...s, status: "busy", unread: false, since: pending.get(s.id).at / 1000 } : s));
  return { snap: { ...snapshot, sessions }, pending: next };
}

// ---------- push notifications ----------
// env: { sw, push, notif, standalone, subscribed } are booleans, permission is Notification.permission
// Returns { state: unsupported | denied | subscribed | off, text, hint }; when hint is non-empty the page must show it (iOS requires installing to the home screen)
export function pushStatus(env) {
  const hint = env.standalone ? "" : t("push.iosHint");
  if (!env.sw || !env.push || !env.notif) {
    return { state: "unsupported", text: t("push.unsupported"), hint };
  }
  if (env.permission === "denied") {
    return { state: "denied", text: t("push.denied"), hint };
  }
  if (env.permission === "granted" && env.subscribed) {
    return { state: "subscribed", text: t("push.subscribed"), hint };
  }
  return { state: "off", text: t("push.off"), hint };
}

// VAPID public key (base64url) -> the byte array pushManager.subscribe needs
export function urlB64ToBytes(s) {
  const str = String(s);
  const b64 = str.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (str.length % 4)) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}


// ---------- chat page: working hint / new messages ----------
// How long it has been working: computed from since (seconds). Under 1 minute says "under 1 minute".
export function busyText(since, now) {
  if (!since) return "";
  const m = Math.max(0, Math.floor((now - since) / 60));
  if (m < 1) return t("busy.lt1");
  if (m < 60) return t("busy.min", { m });
  const hh = Math.floor(m / 60);
  const mm = m % 60;
  return mm ? t("busy.hourMin", { h: hh, m: mm }) : t("busy.hour", { h: hh });
}

// ---------- background tasks / helpers (bgTasks/bgAgents/bgSince/bgStale/helpers/bgList) ----------
const okN = (v) => typeof v === "number" && Number.isFinite(v) && v >= 0;
// Background running: bgTasks>0 and not stuck (a stuck one counts as plain idle, with a grey hint). Ignores conversation status; the chat page fallback uses it too
export function bgActive(s) {
  return !!s && okN(s.bgTasks) && s.bgTasks > 0 && s.bgStale !== true;
}
// "Background running" in list rows that should roam/time: busy rows already have the working effect, and rows waiting for you stay still
export function bgRun(s) {
  return bgActive(s) && s.status !== "busy" && s.status !== "waiting";
}
export function bgStaleRow(s) {
  return !!s && okN(s.bgTasks) && s.bgTasks > 0 && s.bgStale === true;
}
// Helper count convention (same as the Mac board): M = background commands = max(0, bgTasks - bgAgents); total = snapshot helpers, falling back to bgAgents + M if absent; N = total - M
export function helperCounts(s) {
  const ba = s && okN(s.bgAgents) ? s.bgAgents : 0;
  const bt = s && okN(s.bgTasks) ? s.bgTasks : 0;
  const m = Math.max(0, bt - ba);
  const total = s && okN(s.helpers) ? s.helpers : ba + m;
  return { n: Math.max(0, total - m), m, total: Math.max(total, m) };
}
// "SA N · BG M": not translated; if a part is 0 show only the other, return "" if both are 0
export function helperLabel(n, m) {
  if (n > 0 && m > 0) return t("head.helperList", { n, m });
  if (n > 0) return t("head.agents", { n });
  if (m > 0) return t("head.bgCmds", { n: m });
  return "";
}
// Small text right of the name in the chat page header: only the helper capsule "SA N · BG M" (without queued and "worked N min"). Not shown when top is empty
export function headStat(s) {
  if (!s) return { top: "", bottom: "" };
  const c = helperCounts(s);
  return { top: helperLabel(c.n, c.m), bottom: "" };
}
// The list popped up by the capsule. With bgList: list by it (subagents first, background commands after, newest on top within each), more = count not covered by the list (foreground subagents etc.);
// without bgList: show only one row "background commands x M" (cmdOnly); tapping it falls back to finding the unfinished run_in_background Bash in the conversation
export function helperSheet(s, now) {
  const c = helperCounts(s);
  const title = helperLabel(c.n, c.m);
  const list = s && Array.isArray(s.bgList) ? s.bgList.filter((x) => x && (x.kind === "cmd" || x.kind === "agent")) : null;
  if (!list) return { title, rows: [], cmdOnly: c.m > 0 ? c.m : 0, more: 0, has: false };
  const rows = list.map((x) => {
    const sec = okN(x.since) ? Math.max(0, Math.floor(now - x.since)) : null;
    return {
      kind: x.kind,
      desc: String(x.desc == null ? "" : x.desc),
      id: String(x.id == null ? "" : x.id),
      toolUseId: String(x.toolUseId == null ? "" : x.toolUseId),
      since: okN(x.since) ? x.since : 0,
      time: sec == null ? "" : x.kind === "agent" ? busyClock(x.since, now) : t("head.bgMin", { m: Math.floor(sec / 60) }),
    };
  }).sort((a, b) => (a.kind === b.kind ? b.since - a.since : a.kind === "agent" ? -1 : 1));
  return { title, rows, cmdOnly: 0, more: Math.max(0, c.total - rows.length), has: true };
}
// toolUseIds of the "unfinished background Bash" (run_in_background) in the conversation, old -> new. It counts as unfinished only if there is no task notification (or the notification is still running)
export function bgOpenCmds(items) {
  const its = items || [];
  const ts = taskStates(its);
  const out = [];
  for (const it of its) {
    if (!it || !it.bg || it.isError || toolNameOf(it) !== "Bash" || !it.toolUseId) continue;
    const st = String(it.task || ts.get(it.toolUseId) || "");
    if (!st || st === "running") out.push(it.toolUseId);
  }
  return out;
}
// When the snapshot says background work is still running, which tool-call figures must not be misjudged as "done because a turn passed" (1.5).
// With bgList use its toolUseIds; otherwise take the latest M unfinished background Bash in the conversation. Not running / stuck: empty set (fall back to the other check)
export function bgLiveIds(items, s) {
  const out = new Set();
  if (!bgActive(s)) return out;
  if (Array.isArray(s.bgList)) {
    for (const x of s.bgList) if (x && x.toolUseId) out.add(String(x.toolUseId));
    return out;
  }
  const m = helperCounts(s).m;
  if (m > 0) for (const id of bgOpenCmds(items).slice(-m)) out.add(id);
  return out;
}
// Which toolUseId a tapped list row jumps to: rows with bgList use their own; without it (showing only "background commands x M") take the latest unfinished background Bash
export function bgJumpTu(row, items) {
  if (row && row.toolUseId) return row.toolUseId;
  const o = bgOpenCmds(items);
  return o.length ? o[o.length - 1] : "";
}
// Which anchor to look for first on a tapped row: subagent rows first look for the subagent plate (ag = .ag-flip / the group carrying figures), then fall back to the tool tag (tu = li[data-tu]);
// background command rows look for the tool tag first (where the little crab is)
export function helperJumpOrder(kind) {
  return kind === "agent" ? ["ag", "tu"] : ["tu", "ag"];
}

export const NEAR_BOTTOM_PX = 120;
// counts as "left the bottom" only beyond 120px from the bottom
export function awayFromBottom(scrollHeight, scrollTop, clientHeight) {
  return scrollHeight - scrollTop - clientHeight > NEAR_BOTTOM_PX;
}
// Among newly arrived entries, the number the user can see (collapsed tool entries do not count)
export function countNewItems(before, after) {
  const n = after.filter((it) => it.role !== "tool").length - before.filter((it) => it.role !== "tool").length;
  return n > 0 ? n : 0;
}
// New-message count: away = the user is more than 120px from the bottom. Always reset near the bottom (the caller sticks to the bottom).
export function nextNewCount(count, added, away) {
  return away ? count + Math.max(0, added) : 0;
}
export function newBtnText(n) {
  return n > 0 ? (n > 1 ? t("chat.newMsgN", { n }) : t("chat.newMsg")) : "";
}

// ---------- quote reply ----------
function oneLine(str) {
  return String(str == null ? "" : str).replace(/[\x00-\x1f\x7f\s]+/g, " ").trim();
}
// The quote bar shows "name: text", one line, at most 120 characters (CSS ellipsis at two lines)
export function quotePreview(text) {
  const t = oneLine(text);
  return t.length > 120 ? t.slice(0, 120) + "…" : t;
}
// A quote carries the speaker: "name: text", one line; with an empty name keep only the text
export function quoteHead(name, text) {
  const q = oneLine(text);
  if (!q) return "";
  const n = oneLine(name);
  return n ? n + ": " + q : q;
}
export const QUOTE_MAX = 300;
// Body to send (same rule as with_quote in the server's api/outbox.py; the frontend only uses it to draw the "sending" bubble):
// "> name: text (one line, cut to 300 characters)" + blank line + body. The helper sends the whole thing by paste, so newlines are not taken as submit
export function buildQuoteText(quote, input) {
  const q = oneLine(quote);
  const body = cleanReplyText(input);
  if (!q) return body;
  const head = "> " + (q.length > QUOTE_MAX ? q.slice(0, QUOTE_MAX) + "…" : q);
  return body ? head + "\n\n" + body : head;
}
// Quote reply in a record -> { tag (the guest's "prefix + space", prefix see setGuestTag), quote, body }; returns null if it is not a quote reply
export function parseQuoted(text) {
  const s = String(text == null ? "" : text);
  let m = null;
  for (const r of GTS) { // admin recognizes every guest's prefix; the prefixed one takes priority
    const x = r.quote.exec(s);
    if (x && (x[1] || !m)) m = x;
    if (x && x[1]) break;
  }
  return m ? { tag: m[1] || "", quote: m[2], body: m[3] } : null;
}
// Read receipts (drawn at the bottom right of the bubble). Optimistic bubbles (pend) follow the send stage: clock = not yet at the server,
// sent bright-yellow single tick = server received (got requestId), delivered bright-yellow single tick = helper typed it into the Agent input box (both count as sent but unread); failed = not delivered (red !).
// For records in the chat: read:false (queued) = delivered bright-yellow single tick, read:true = read white double tick, recalled = recalled; old data without a read field returns null (nothing drawn)
export const PEND_STAGES = ["clock", "sent", "delivered"];
export function receiptOf(it) {
  if (!it) return null;
  if (it.pend) return it.failed ? "failed" : PEND_STAGES.includes(it.stage) ? it.stage : "clock";
  if (it.role !== "user") return null;
  if (it.recalled) return "recalled";
  if (it.read === true) return "read";
  if (it.read === false) return "delivered";
  return null;
}
// Whether "recall" can appear: only for messages in the chat records (pend optimistic bubbles have no ts/text yet, so no) - queued (delivered) and read
export function canRecall(receipt, pend) {
  return !pend && (receipt === "delivered" || receipt === "read");
}
// Items of the bubble menu: copy / quote / forward / recall (recall only for my messages that are still queued; guests get no forward or recall; off-duty conversations get no quote)
export function bubbleActs({ who, receipt, pend, guest, detailOff, wide, sel, files, desktop } = {}) {
  // the long-pressed item is an attachment (files is the one pressed): save/share on phone, download on desktop; ones with a host path also get forward (path goes into the draft) and copy path. Inline images / guest uploads have no path
  if (Array.isArray(files) && files.length) {
    const hasPath = files.some((f) => f && f.path);
    const fa = [desktop ? "download" : "share"];
    if (hasPath && !guest) fa.push("forward");
    if (hasPath && !guest) fa.push("copypath"); // a guest copying the Mac path is useless
    return fa;
  }
  const acts = [wide === true && sel ? "copysel" : "copy"]; // wide screen with a selection = copy the selection
  if (wide === false) acts.push("select");                  // on phone one more item, "select text"
  if (!detailOff) acts.push("quote");
  if (!guest) acts.push("forward");
  if (who === "me" && canRecall(receipt, pend)) acts.push("recall"); // guests can also recall their own (the server re-checks the guest prefix and queueing); read ones also show it, greyed out at that point (recalled and sending ones do not show)
  return acts;
}
// Recall item greyed out; the hint when a greyed item is tapped
// A 2-minute time window like chat apps: ignores read state and looks only at how long ago (seconds) the message ts (ISO) was; exactly 120 seconds can still be recalled.
// Old data with no ts / unparseable counts as timed out. The server checks too (409 too-old)
export const RECALL_WINDOW_SEC = 120;
export function recallLock(receipt, ts, nowSec) {
  if (!canRecall(receipt)) return true;
  const at = Date.parse(String(ts || ""));
  if (!Number.isFinite(at)) return true;
  return nowSec - at / 1000 > RECALL_WINDOW_SEC;
}
// the hints are functions (not constants), fetched for the current language on demand
export function recallLockToast() { return t("recall.lockToast"); }
// Hint after a successful recall, by the mode the server returned: interrupted = Esc was pressed to interrupt; answered = already answered; processing = being processed (more behind it);
// no mode = still queued and pulled back with up-arrow. A guest's processing does not claim "more behind it" (guests do not send Esc), so the wording differs
export function recallDoneText(mode, guest) {
  if (mode === "interrupted") return t("recall.interrupted");
  if (mode === "answered") return t("recall.answered");
  if (mode === "processing") return guest ? t("recall.processingGuest") : t("recall.processing");
  return t("recall.done");
}
// Menu placement: r = bubble rect, w/hgt = menu size, box = visible area (chat area). Prefer above the bubble (arrow pointing down), else below,
// if neither fits stick to the top of the visible area; horizontally centered on the bubble midline, clamped inside the box. ax = arrow position relative to the menu's left edge
export function menuPlace(r, w, hgt, box, gap = 8) {
  const cx = (r.left + r.right) / 2;
  const x = Math.round(Math.max(box.left + gap, Math.min(cx - w / 2, box.right - gap - w)));
  let y;
  let below = false;
  if (r.top - gap - hgt >= box.top) y = r.top - gap - hgt;
  else if (r.bottom + gap + hgt <= box.bottom) { y = r.bottom + gap; below = true; }
  else y = box.top + gap;
  return { x, y, below, ax: Math.round(cx - x) };
}
// Forward: "[forwarded from <this conversation's name>] text", at most 3900 characters (server limit 4000)
export function forwardText(from, text) {
  const s = t("fwd.prefix", { name: oneLine(from) }) + " " + String(text == null ? "" : text).trim();
  return s.length > 3900 ? s.slice(0, 3899) + "…" : s;
}
// Recall failure reasons are looked up by code in recallfail.<code> (session-waiting: a guest stopped at a question/approval menu does not recall, since up-arrow would move the option;
// likewise admin-queued, too-old); codes missing from the table fall through to the send-failure table
export function recallFailText(code) {
  return tCode("recallfail.", code, "") || failReason(code, t("recall.fail"));
}
// After a long press opens the menu, lifting the finger fires a click (it would expand a collapsed bubble), which must be swallowed; but on iOS a long press often fires no click at all,
// so a pending swallow must not wait for "the next" click, or the first tap in the chat area afterwards would be lost. Only a click within PRESS_SWALLOW_MS is swallowed
export const PRESS_SWALLOW_MS = 700;
export function pressSwallow(p, now) {
  return !!(p && p.fired && now - p.at < PRESS_SWALLOW_MS);
}

// ---------- image upload ----------
export const IMG_MAX_SIDE = 2000;
export const JPEG_QUALITY = 0.85;
// Size after scaling: longest side at most max, proportional. Returned unchanged if no scaling is needed.
export function scaledSize(w, h, max = IMG_MAX_SIDE) {
  const longest = Math.max(w, h);
  if (!(longest > max)) return { w, h, scaled: false };
  const k = max / longest;
  return { w: Math.max(1, Math.round(w * k)), h: Math.max(1, Math.round(h * k)), scaled: true };
}
// How an image is handled: GIF / PNG keep their format and are scaled only above 2000px; other images are all converted to JPEG 0.85.
// Returns { mode: "keep" | "canvas", type, w, h }
export function imagePlan(type, w, h) {
  const t = String(type || "").toLowerCase();
  const sz = scaledSize(w, h);
  if (t === "image/gif" || t === "image/png") {
    return sz.scaled ? { mode: "canvas", type: t, w: sz.w, h: sz.h } : { mode: "keep", type: t, w, h };
  }
  return { mode: "canvas", type: "image/jpeg", w: sz.w, h: sz.h };
}
// File name after transcoding: the extension follows the type
export function uploadName(name, type) {
  const base = String(name || "image").replace(/\.[^./\\]*$/, "") || "image";
  const ext = { "image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif" }[type];
  return ext ? base + ext : String(name || "file");
}
export function uploadPath(sid, name, caption) {
  return "/api/sessions/" + encodeURIComponent(sid) + "/upload?name=" + encodeURIComponent(name) +
    "&caption=" + encodeURIComponent(caption || "");
}

// ---------- attachment bar ----------
export const MAX_ATTACH = 9; // same as the server
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;
// Add files to the attachment bar: current is the existing array, incoming the new file array (with a size field).
// Returns { list, overLimit (count dropped because the total exceeded 9), tooBig (count dropped because a single file exceeded 20MB) }
export function addAttachments(current, incoming, max = MAX_ATTACH, maxBytes = MAX_UPLOAD_BYTES) {
  const list = current.slice();
  let overLimit = 0;
  let tooBig = 0;
  for (const f of incoming) {
    if (f && f.size > maxBytes) { tooBig++; continue; }
    if (list.length >= max) { overLimit++; continue; }
    list.push(f);
  }
  return { list, overLimit, tooBig };
}
// Whether the send button is tappable: there is text or an attachment
export function canSend(text, attachCount) {
  return !!cleanReplyText(text) || attachCount > 0;
}
export function uploadProgressText(done, total) {
  return t("up.progress", { i: Math.min(done + 1, total), n: total });
}
export function plainUploadPath(name) {
  return "/api/uploads?name=" + encodeURIComponent(name);
}
// Body sent to the server: with attachments {text, files}, otherwise {text, enter}
// A send with attachments carries ?lang= (en/hans/hant) in the URL, and the helper uses it to pick the prompt typed into the Agent ("Please look at the image I sent from my phone:" etc.).
// Put in the URL rather than the body: an old api answers 403 for extra keys in a guest's request body, while it simply ignores URL parameters
export function sendUrl(path, body, lang) {
  return body && Array.isArray(body.files) && body.files.length && lang ? path + "?lang=" + encodeURIComponent(lang) : path;
}
// Push texts by subscription language: subscribe request body = browser subscription JSON + current UI language + device info (dev / plat / standalone)
export function pushSubBody(subJson, lang, dev) {
  return Object.assign({}, subJson || {}, lang ? { lang } : {}, dev || {});
}
// Device identity: platform roughly classified by UA; iPadOS poses as a Mac UA by default, recognized by touch points (>1)
export function devPlat(ua, maxTouchPoints) {
  const u = String(ua || "");
  if (/iPhone|iPod/.test(u)) return "iphone";
  if (/iPad/.test(u)) return "ipad";
  if (/Macintosh|Mac OS X/.test(u)) return Number(maxTouchPoints) > 1 ? "ipad" : "mac";
  if (/Android/.test(u)) return "android";
  if (/Windows/.test(u)) return "windows";
  return "other";
}
// Device id: 16 base64url characters (server allowlist [A-Za-z0-9_-]{8,40}), the randomness source is supplied by the caller (crypto.getRandomValues)
const DEV_CH = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
export function newDevId(bytes) {
  let out = "";
  for (let i = 0; i < 16; i++) out += DEV_CH[(bytes && bytes[i] != null ? bytes[i] : Math.floor(Math.random() * 256)) & 63];
  return out;
}
// The line for this device in "Notification settings": device label (home-screen app / Dock app / browser) + notification state + how many devices this account has in total (omitted if the count is unavailable)
const DEV_APP = { iphone: "push.devHome", ipad: "push.devHome", android: "push.devHome", mac: "push.devDock" };
export function devLabel(plat, standalone) {
  if (!["iphone", "ipad", "mac", "windows", "android"].includes(plat)) return t("push.devThis");
  const p = t("push.plat." + plat);
  if (!standalone) return t("push.devTab", { p });
  return t(DEV_APP[plat] || "push.devWebApp", { p });
}
export function pushDevLine(dev, stateText, n) {
  const d = devLabel(dev && dev.plat, !!(dev && dev.standalone));
  return Number.isFinite(n) ? t("push.devLine", { dev: d, state: stateText, n }) : t("push.devLine0", { dev: d, state: stateText });
}

// ---------- the device in use ----------
// In use: phones / tablets only need the page visible; on desktop (a window with its tab showing behind others also counts as visible) the window must also have focus, or have been operated within 60 s
export const ACT_INPUT_MS = 60000;
const MOBILE_PLATS = ["iphone", "ipad", "android"];
export function actNow(plat, visible, hasFocus, lastInputMs, nowMs) {
  if (!visible) return false;
  if (MOBILE_PLATS.includes(plat)) return true;
  return !!hasFocus || (lastInputMs > 0 && nowMs - lastInputMs <= ACT_INPUT_MS);
}
// Report (banner shown / viewing that conversation): s-<encoded conversation id>:<event>, recorded once per entry, keeping at most 20 (so it does not grow endlessly when it cannot be sent)
const SEEN_MAX = 20;
export function seenAdd(list, id, kind) {
  const k = "s-" + encodeURIComponent(String(id)) + ":" + kind;
  const out = (list || []).filter((x) => x !== k);
  out.push(k);
  return out.slice(-SEEN_MAX);
}
// Snapshot request headers (the server records "in use" by (account, device id); an old api ignores unknown headers)
export function presenceHeaders(dev, act, seen) {
  const h = { "X-Zbs-Dev": dev, "X-Zbs-Act": act ? "1" : "0" };
  if (seen && seen.length) h["X-Zbs-Seen"] = seen.join(",");
  return h;
}
// Beacon body when switching away (sendBeacon sends a string = text/plain, which does not trigger a preflight)
export function presenceBody(dev, act, seen) {
  return JSON.stringify({ dev, act: act ? 1 : 0, seen: (seen || []).slice() });
}
// The "how long ago" in the "Notification settings" device list
export function devAgo(sec, now) {
  const d = Math.max(0, now - sec);
  if (d < 60) return t("push.agoNow");
  if (d < 3600) return t("push.agoMin", { n: Math.floor(d / 60) });
  if (d < 86400) return t("push.agoHour", { n: Math.floor(d / 3600) });
  return t("push.agoDay", { n: Math.floor(d / 86400) });
}
// Device list (/api/push/devices) -> rows: this device first, the rest by last activity newest to oldest; old subscriptions with no device info -> unknown device (old subscription)
export function deviceRows(devs, nowSec) {
  const known = ["iphone", "ipad", "mac", "windows", "android"];
  const rows = (Array.isArray(devs) ? devs : []).filter((d) => d && typeof d.key === "string").map((d) => {
    const last = Number(d.lastActive);
    return {
      key: d.key, self: d.self === true, active: d.active === true, lastActive: Number.isFinite(last) ? last : 0,
      label: known.includes(d.plat) ? devLabel(d.plat, !!d.standalone) : t("push.devUnknown"),
      last: d.active === true ? t("push.devActive") : (Number.isFinite(last) && last > 0 ? t("push.devLast", { t: devAgo(last, nowSec) }) : ""),
    };
  });
  rows.sort((a, b) => (b.self - a.self) || (b.lastActive - a.lastActive));
  return rows;
}
// Delete confirm: deleting this device -> it no longer receives push (and unsubscribes); deleting another -> that one registers again automatically when the App is next opened (only effective for devices truly unused)
export function deviceDelAsk(row) {
  return { title: t("push.devDelTitle", { dev: row.label }), hint: t(row.self ? "push.devDelSelf" : "push.devDelOther") };
}
// Signed-in devices (/api/auth/devices: {id, desc, lastSeen, self}) -> rows: this device first, the rest by last use newest first.
// desc is a short server-made description ("iPhone Safari"); anything else (missing, too long, odd characters) shows as an unknown device
export function loginRows(devs, nowSec) {
  const rows = (Array.isArray(devs) ? devs : []).filter((d) => d && typeof d.id === "string" && /^[0-9a-f]{12}$/.test(d.id)).map((d) => {
    const seen = Number(d.lastSeen);
    const ok = typeof d.desc === "string" && /^[A-Za-z0-9 ]{1,60}$/.test(d.desc) && d.desc !== "Unknown device";
    return {
      id: d.id, self: d.self === true, lastSeen: Number.isFinite(seen) ? seen : 0,
      label: ok ? d.desc : t("signin.devUnknown"),
      last: d.self === true ? t("signin.devHere") : (Number.isFinite(seen) && seen > 0 ? t("signin.devLast", { t: devAgo(seen, nowSec) }) : ""),
    };
  });
  rows.sort((a, b) => (b.self - a.self) || (b.lastSeen - a.lastSeen));
  return rows;
}
// Sign-out confirm: this device -> back to the login page; another device -> it must enter the key again next time
export function loginRevokeAsk(row) {
  return row.self
    ? { title: t("signin.outSelfTitle"), hint: t("signin.outSelfHint") }
    : { title: t("signin.outOtherTitle", { dev: row.label }), hint: t("signin.outOtherHint") };
}
export function buildSendBody(text, savedNames) {
  if (savedNames && savedNames.length) return { text: text || "", files: savedNames.slice() };
  return { text, enter: true };
}

// ---------- chat room (messages / contacts / search) ----------
// Four bottom tabs; remember the last one, and fall back to "Messages" if the stored value is unrecognized
// "board" (a removed tab) may still be stored on older devices: it opens "Zones"
export const CHAT_TABS = ["msg", "contacts", "zones", "me"];
export function chatTab(stored) {
  if (stored === "board") return "zones";
  return CHAT_TABS.includes(stored) ? stored : "msg";
}

// Red number on the Messages tab: waiting for you + replied to you (resting ones excluded)
export function chatBadge(snapshot) {
  const c = countOf(((snapshot && snapshot.sessions) || []).filter((s) => !s.adminWait)); // guest: ones waiting for the admin do not count
  return c.waiting + c.unread;
}

// App icon badge: the number is chatBadge; this only decides how to call the API. nav is navigator (self.navigator in the sw).
// n=0 clears (setAppBadge(0) if there is no clearAppBadge); no setAppBadge (unsupported browser) or a bad number -> none (silently skipped)
export function appBadgeOps(n, nav) {
  const can = (k) => !!nav && typeof nav[k] === "function";
  if (!can("setAppBadge") || !Number.isFinite(n)) return { op: "none" };
  if (n > 0) return { op: "set", n: Math.floor(n) };
  return can("clearAppBadge") ? { op: "clear" } : { op: "set", n: 0 };
}

// ---------- guest mode (guest account: sees only the one bound conversation) ----------
// The tab bar keeps only Messages and "Me"; any other stored tab falls back to Messages
export const GUEST_TABS = ["msg", "me"];
export function guestTab(stored) {
  return GUEST_TABS.includes(stored) ? stored : "msg";
}
// A guest's read state lives only on the phone (seenAt: the time of the last activity seen, seconds). The server's unread/pinned/rest do not count.
// The first time (seenAt empty) treat the current activity as seen, showing no red dot; a conversation being viewed counts as seen when it stops.
// "Replied to you" = idle, not an inter-session/subagent turn, activity later than seenAt; "waiting for you" means waiting for the admin (adminWait) for a guest and gives no red dot.
// bound: the full name of the bound conversation; if given, keep only that one (offline, the Service Worker may replay a snapshot cached for another account on this device)
// Returns { snap, seenAt } (the caller stores seenAt if it changed)
export function guestSnapshot(raw, seenAt, viewingId, bound) {
  const isBound = (s) => !bound || s.name === bound || (s.zone && s.plate && s.zone + "-" + s.plate === bound);
  const list = ((raw && raw.sessions) || []).filter(isBound);
  let seen = Number(seenAt);
  if (seenAt == null || !Number.isFinite(seen)) {
    // Not recorded yet: if the conversation is off duty, do not record yet (take the baseline when it comes online, so its first turn after coming online does not give a red dot)
    if (!list.length) return { snap: { ...guestTop(raw), sessions: [] }, seenAt: null };
    seen = list.reduce((m, s) => Math.max(m, Number(s.since) || 0), 0);
  }
  // For a completion with errorKind take max(since, errorSince), regardless of turn source; unexpected exit gives no red
  const fin = (s) => Math.max(Number(s.since) || 0, s.errorKind ? Number(s.errorSince) || 0 : 0);
  for (const s of list) {
    if (viewingId != null && String(viewingId) === String(s.id) && s.status === "idle") seen = Math.max(seen, fin(s));
  }
  const sessions = list.map((s) => ({
    ...s,
    unread: s.status === "idle" && !gone(s) && (!!s.errorKind || (s.origin !== "peer" && s.origin !== "agent")) && fin(s) > seen,
    pinned: false,
    rest: false,
    originNote: "",
    originTag: null,
    adminWait: s.status === "waiting",
    guestView: true, // guests get no "unexpected exit" banner (pushed to the admin only)
  }));
  return { snap: { ...guestTop(raw), sessions }, seenAt: seen };
}
// A guest snapshot should have only these top-level fields (same as GUEST_SNAP_FIELDS in api/server.py): when a snapshot is replayed offline for another account, private fields like offduty are dropped too
const GUEST_TOP = ["generatedAt", "stale", "serverNow", "sessions", "zones", "bound", "roster"];
function guestTop(raw) {
  const out = {};
  for (const k of GUEST_TOP) if (raw && k in raw) out[k] = raw[k];
  return out;
}
// Sub-line of the "Me" page: the bound conversation with the zone prefix removed (Web-guest-demo -> guest-demo); only codes in the snapshot zones are recognized
export function guestBoundLabel(name, zones) {
  const n = String(name || "");
  for (const z of zones || []) {
    const c = String((z && z.code) || "");
    if (c && n.startsWith(c + "-") && n.length > c.length + 1) return n.slice(c.length + 1);
  }
  return n;
}

// Sort: waiting for you (longest wait first) -> pinned (permanently pinned: topped) -> reply later (board pinned) -> replied to you -> working (busy, or idle with a live background task) -> the rest by last activity (newest first)
// Grey cards of unexpected exit go after working and before plain idle (tier 5 is first), among themselves newest exit first
function chatTier(s) {
  if (s.status === "waiting") return 0;
  if (s.topped) return 1;
  if (s.pinned) return 2;
  if (s.disconnected === true) return 4.5;
  if (s.unread) return 3;
  if (s.status === "busy" || bgRun(s)) return 4; // working (incl. idle + background running, not stuck) ranks ahead of idle
  return 5;
}
const sortSince = (s) => (s.disconnected === true && okN(s.disconnectedSince) ? s.disconnectedSince : s.since || 0);
export function sortChat(list) {
  return list.slice().sort((a, b) => {
    const t = chatTier(a) - chatTier(b);
    if (t) return t;
    if (chatTier(a) === 0) return (a.since || 0) - (b.since || 0);
    return sortSince(b) - sortSince(a);
  });
}

function zoneFor(zones, code) {
  return (zones || []).find((z) => z.code === code) || UNZONED;
}
function zoneKey(zones, code) {
  return (zones || []).some((z) => z.code === code) ? String(code) : "_";
}
// Short name: the plate in the snapshot; if absent, strip the zone prefix ("<zone>-")
// nameUntitled (the board could not get a name and used the default "unnamed") is shown as Untitled in the current language
export function plateOf(s) {
  if (s.nameUntitled === true) return t("name.untitled");
  if (s.plate) return String(s.plate);
  const name = String(s.name || "");
  const z = String(s.zone || "");
  return z && name.startsWith(z + "-") ? name.slice(z.length + 1) : name;
}
function spanText(sec, now) {
  const d = Math.max(0, now - sec);
  if (d < 3600) return t("time.min", { n: Math.max(1, Math.floor(d / 60)) });
  if (d < 86400) return t("time.hour", { n: Math.floor(d / 3600) });
  return t("time.day", { n: Math.floor(d / 86400) });
}

// Chat-style time (local time zone): today "h:mm" with day part / yesterday with day part / within 7 days the weekday / this year "month day" / earlier years with the year
// English goes through Intl (1:42 PM / Yesterday / Monday / Oct 12 / Oct 12, 2025); the day-part words (dayPart) live in i18n.js
export function chatTime(sec, now) {
  if (!sec) return "";
  const d = new Date(sec * 1000);
  const n = new Date(now * 1000);
  const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(n) - day(d)) / 86400000);
  const hm = (d.getHours() % 12 || 12) + ":" + String(d.getMinutes()).padStart(2, "0");
  if (diff <= 0) return isEn() ? fmtClockEn(d) : dayPart(d.getHours()) + " " + hm;
  if (diff === 1) return isEn() ? t("time.yesterday") : t("time.yesterday") + " " + dayPart(d.getHours()) + hm;
  if (diff < 7) return fmtWeekday(d);
  if (d.getFullYear() === n.getFullYear()) return fmtMD(d);
  return fmtYMD(d);
}

// Status line at the top of the messages page: disconnected (offline or data stale) > Orca not running > online; an old snapshot without an orca field counts as online, no false alarm
// dot: status dot color, on green / warn yellow (Orca not running) / off grey (disconnected)
// When data is stale (not the phone being offline), state the cause using the server's down.reason (helper heartbeat): helper stopped / panel (board) not responding
const DOWN_TEXT = { helper: "mac.helperDown", panel: "mac.panelDown" };
export function macLine(snapshot, o) {
  // short: the short form used when the status line does not fit (the quota on the right carries a countdown)
  if (o.offline || o.stale) {
    const r = !o.offline && snapshot && snapshot.down && DOWN_TEXT[snapshot.down.reason];
    return { text: t(r || "mac.disconnected", { at: o.at }), short: t(r ? r + "Short" : "mac.disconnectedShort", { at: o.at }), off: true, dot: "off" };
  }
  if (orcaDown(snapshot)) return { text: t("mac.orcaDown"), short: t("mac.orcaDownShort"), off: false, dot: "warn" };
  return { text: t("mac.orcaOn"), short: t("mac.orcaOnShort"), off: false, dot: "on" };
}

// Disconnected: phone offline, server marked stale, or data not updated for STALE_SEC seconds (measured against serverNow): the whole page greys out and timers stop
export const STALE_SEC = 30;
export function macDown(snap, offline, now) {
  if (!snap) return false;
  return !!offline || !!snap.stale || now - (Number(snap.generatedAt) || 0) > STALE_SEC;
}
// Orca not open: only an explicit running === false counts (an old snapshot without an orca field counts as online, no false alarm)
export function orcaDown(snap) {
  return !!(snap && snap.orca && snap.orca.running === false);
}

// waitingFor from the Mac --dump is a machine value (permission prompt / input needed / permission request, others seen too),
// so the English word is not shown directly: known ones are translated to the current language, unknown ones shown as is, empty returns ""
export function waitingForText(v) {
  const s = String(v || "").trim();
  return s ? tCode("wf.", s, s) : "";
}
// Entry point for rendering a conversation's one-line summary. The Mac --dump carries summaryCode / summaryArgs (wired for the final 17 codes,
// the code table follows the Mac --dump; the Simplified Chinese template + args are word for word the same as summary): known codes are rendered
// with the template in the current language; text (args.kind = reply / progress / recap / raw) shows args.text as is; none = empty;
// no code, an unknown code, or a missing expected argument (old board / bad data) always shows the original summary. args are not truncated; the display site cuts to its line width
const SUM_NEED = { "wait.ask": "question", "wait.approve.run": "command", "wait.approve.tool": "tool", "prompt.you": "text", "relay.from": "peer", "state.retrying": "attempt" };
export function summaryText(s) {
  if (!s) return "";
  const raw = String(s.summary || "");
  const code = typeof s.summaryCode === "string" ? s.summaryCode : "";
  if (!code) return raw;
  const a = s.summaryArgs && typeof s.summaryArgs === "object" ? s.summaryArgs : {};
  if (code === "text") return typeof a.text === "string" ? a.text : raw;
  if (code === "none") return "";
  if (SUM_NEED[code] && a[SUM_NEED[code]] == null) return raw;
  if (code === "wait.ask" && Number(a.count) > 1) return t("sum.wait.ask.n", a);
  // file null or empty string use the same phrasing (nofile, no trailing colon; deliberately different from the board's original summary "waiting for approval to edit:")
  if (code === "wait.approve.edit") return a.file == null || a.file === "" ? t("sum.wait.approve.edit.nofile") : t("sum.wait.approve.edit", { file: String(a.file) });
  if (code === "wait.answer") return a.options == null ? t("sum.wait.answer.noopt") : t(Number(a.options) === 1 ? "sum.wait.answer.one" : "sum.wait.answer", a);
  // state.apiError (same as api/summary.py): auth is a fixed sentence; the others need text (fall back to the original if absent); rate_limit uses CC's own words directly; a null status writes no status code
  if (code === "state.apiError") {
    if (a.kind === "auth") return t("sum.state.apiError.auth", a);
    if (a.text == null) return raw;
    if (a.kind === "rate_limit") return t("sum.state.apiError.limit", a);
    return t(a.status != null ? "sum.state.apiError" : "sum.state.apiError.nostatus", a);
  }
  return tCode("sum.", code, null) != null ? t("sum." + code, a) : raw;
}

// What one message row displays (plain data, the page fills it with textContent)
// kind: w waiting for you / u replied to you / g working / d other; badge: wait capsule / dot red dot / live green dot / ""
// Correspondence note: the server gives the structure originTag {kind:"peer", peer} / {kind:"agent"}, assembled in the current language
export function originText(s) {
  const g = s && s.originTag;
  if (g && typeof g === "object") {
    if (g.kind === "agent") return t("origin.agent");
    if (g.kind === "peer") return g.peer ? t("origin.peer", { name: g.peer }) : t("origin.peerAny");
  }
  return "";
}
// WorkBuddy status: error / stopped (aborted) / paused.
// Read errorKind wb_error / wb_stopped first, otherwise fall back to summaryCode state.* (paused has only summaryCode)
const WB_STATE = { "state.error": "error", "state.stopped": "stopped", "state.paused": "paused" };
const WB_KIND = { wb_error: "error", wb_stopped: "stopped" };
export function wbState(s) {
  if (!s) return null;
  return WB_KIND[s.errorKind] || (typeof s.summaryCode === "string" && WB_STATE[s.summaryCode]) || null;
}

// ---------- error / retrying / unexpected exit (errorKind...compactedAt) ----------
// Unexpected exit (process died, not on the restart list, no new conversation with the same name): the grey card is kept for 10 minutes (managed by the Mac), no red dot, not counted
export function gone(s) {
  return !!s && s.disconnected === true;
}
// Claude conversation API error (only counts when idle; the Mac clears errorKind after a successful retry / the next message): rate_limit amber "quota used up", others red "error"
const API_ERR = { api: { cls: "e", key: "row.tagErr", ev: "err" }, auth: { cls: "e", key: "row.tagErr", ev: "err" }, rate_limit: { cls: "a", key: "row.tagLimit", ev: "limit" } };
export function apiErr(s) {
  return (s && s.status === "idle" && API_ERR[s.errorKind]) || null;
}
// Error content: with state.apiError render by it (three languages); with an old board without code, auth uses a fixed sentence and the others use CC's own words errorText, failing that the summary
export function errText(s) {
  if (!s) return "";
  if (s.summaryCode === "state.apiError") return summaryText(s);
  if (s.errorKind === "auth") return t("sum.state.apiError.auth");
  return typeof s.errorText === "string" && s.errorText ? s.errorText : summaryText(s);
}
// Retrying: busy with retryAttempt (the Mac only gives it once it is newer than all later records); retryMax defaults to CC's default 10
export function retrying(s) {
  return !!s && s.status === "busy" && okN(s.retryAttempt);
}
const retryMax = (s) => (okN(s.retryMax) ? s.retryMax : 10);
// Small text of the placeholder bubble on the chat page: when retrying "retrying API (3/10)", otherwise "worked N minutes"
export function busyLine(s, now) {
  if (retrying(s)) return t("busy.retry", { a: s.retryAttempt, m: retryMax(s) });
  return busyText(s && s.since, now);
}
// Notice bar at the top of the chat page (one line): unexpected exit grey > error red / quota used up amber > retrying amber > context just compacted (within 60 s, grey); returns null if none
export const COMPACT_HINT_SEC = 60;
export function chatAlert(s, now) {
  if (!s) return null;
  if (gone(s)) return { cls: "h", text: t("lost.banner") };
  const e = apiErr(s);
  if (e) return { cls: e.cls, text: e.cls === "a" ? t(e.key) + " " + errText(s) : t("head.err", { text: errText(s) }) };
  if (retrying(s)) return { cls: "a", text: t("busy.retry", { a: s.retryAttempt, m: retryMax(s) }) };
  if (okN(s.compactedAt) && now - s.compactedAt >= 0 && now - s.compactedAt <= COMPACT_HINT_SEC) return { cls: "h", text: t("head.compacted") };
  return null;
}
// Gray fallback line on the chat-page notice bar: the server could not understand part of the Claude Code transcript format.
// Shown when the current page response has formatWarn, or the snapshot session has formatWarn / non-empty formatWarnings. Admin only (the server never sends these to guests)
export function formatAlert(guest, pageWarn, s) {
  if (guest) return null;
  const sw = !!s && (!!s.formatWarn || (Array.isArray(s.formatWarnings) && s.formatWarnings.length > 0));
  return pageWarn || sw ? { cls: "h", text: t("dt.fmtWarn") } : null;
}
const WB_TAG = { error: { cls: "e", key: "row.tagErr" }, stopped: { cls: "h", key: "row.tagStopped" }, paused: { cls: "h", key: "row.tagPaused" } };
// Identity tag after the name: Codex (CLI and App share one tag), WorkBuddy; Claude gets none; an unseen kind gets its first letter capitalized
export function kindTag(kind) {
  const k = String(kind || "");
  if (!k || k === "claude") return null;
  if (k === "codex" || k === "codexApp") return t("kind.codex");
  if (k === "workbuddy") return t("kind.workbuddy");
  return k.charAt(0).toUpperCase() + k.slice(1);
}
export function chatRow(s, zones, now, draft) {
  const z = zoneFor(zones, s.zone);
  const lost = gone(s);
  const kind = s.status === "waiting" ? "w" : s.unread && !lost ? "u" : s.status === "busy" ? "g" : "d";
  const note = originText(s);
  const quiet = kind === "d" && !!note;
  const sum = summaryText(s);
  let tag = null;
  let text = sum;
  if (kind === "w" && s.adminWait) { tag = { cls: "w", text: t("row.tagAdminWait") }; text = sum || waitingForText(s.waitingFor) || t("row.adminWaitText"); }
  else if (kind === "w") { tag = { cls: "w", text: t("row.tagWait") }; text = sum || waitingForText(s.waitingFor) || t("row.waitText"); }
  else if (kind === "g" && retrying(s)) { tag = { cls: "a", text: t("sum.state.retrying", { attempt: s.retryAttempt, max: retryMax(s) }) }; text = ""; } // retrying: amber, replacing "working"
  else if (kind === "g") { const hn = helperCounts(s).n; tag = { cls: "g", text: hn > 0 ? t("row.agents", { n: hn }) : t("row.working") }; } // helpers running: the count follows snapshot helpers (the phone does not count itself)
  else if (lost) { tag = { cls: "h", text: t("sum.state.disconnected") }; text = ""; } // unexpected exit: the whole row grey, the time slot is the exit time
  else if (apiErr(s)) { const e = apiErr(s); tag = { cls: e.cls, text: t(e.key) }; text = errText(s); } // error red / quota used up amber + content (ordered before background running)
  else if (kind === "d" && bgRun(s)) tag = { cls: "g", text: t("row.bgRun", { n: s.bgTasks }) }; // background running (N): no red dot, the pet roams
  else if (kind === "d" && bgStaleRow(s) && !s.rest) tag = { cls: "h", text: t("row.bgStale") }; // stuck: grey text, no roaming
  else if (wbState(s)) { const w = WB_TAG[wbState(s)]; tag = { cls: w.cls, text: t(w.key) }; text = ""; } // the summary is the state itself, do not repeat it
  else if (quiet) tag = { cls: "p", text: note + colon().trimEnd() };
  else if (s.rest) text = t("row.rest", { t: spanText(s.since || 0, now) }) + (sum ? colon() + sum : "");
  else if (!sum) text = t("row.noSummary");
  // Unsent draft (as chat apps do): red "[Draft]" + the first few characters of the draft; waiting for you is more urgent than a draft, so it does not cover it
  if (kind !== "w" && draft && String(draft).trim()) { tag = { cls: "dr", text: t("row.draft") }; text = draftPreview(draft); }
  return {
    id: s.id,
    plate: plateOf(s),
    zoneName: z.name,
    zoneColor: z.color,
    lead: z.lead != null && s.name === z.lead,
    kind,
    quiet,
    pinned: !!s.pinned,
    topped: !!s.topped, // permanently pinned
    rest: !!s.rest,
    badge: kind === "w" ? (s.adminWait ? "" : "wait") : kind === "u" ? "dot" : kind === "g" ? "live" : "",
    tag,
    text,
    time: chatTime(lost && okN(s.disconnectedSince) ? s.disconnectedSince : s.since || 0, now),
    gone: lost, // whole row grey, avatar grey, pet still (app.js adds .gone)
    bgRun: kind === "d" && !lost && bgRun(s), // the list row timer starts from bgSince (liveSince)
    liveSince: kind === "g" ? s.since || 0 : kind === "d" && bgRun(s) ? (okN(s.bgSince) ? s.bgSince : s.since || 0) : 0,
    kindTag: kindTag(s.kind),
  };
}

function sortedZones(snapshot) {
  const zs = (snapshot.zones || []).slice().sort((a, b) => a.order - b.order);
  return zs.concat([UNZONED]);
}

// Zone filter tabs: "All" + zones that have conversations (zone table order, unzoned last); hot = something is waiting for you or replied to you
export function zoneChips(snapshot) {
  const ss = snapshot.sessions || [];
  const hot = (l) => l.some((s) => s.status === "waiting" || s.unread);
  const out = [{ key: "all", name: t("c.all"), color: "#8a8f98", count: ss.length, hot: hot(ss) }];
  for (const z of sortedZones(snapshot)) {
    const key = z.code === null ? "_" : String(z.code);
    const mine = ss.filter((s) => zoneKey(snapshot.zones, s.zone) === key);
    if (mine.length) out.push({ key, name: z.name, color: z.color, count: mine.length, hot: hot(mine) });
  }
  return out;
}

// Message list: filtered by zone (all / zone code / "_" unzoned), on-duty ones sorted, resting ones in a separate group (newest first)
export function msgModel(snapshot, zone) {
  let ss = snapshot.sessions || [];
  if (zone && zone !== "all") ss = ss.filter((s) => zoneKey(snapshot.zones, s.zone) === zone);
  return {
    active: sortChat(ss.filter((s) => !s.rest)),
    rest: ss.filter((s) => s.rest).sort((a, b) => (b.since || 0) - (a.since || 0)),
  };
}

function contactStatus(s) {
  if (s.status === "waiting") return { cls: "w", text: t("st.waiting") };
  if (s.unread) return { cls: "u", text: t("st.unread") };
  if (s.status === "busy") return { cls: "g", text: t("st.busy") };
  if (s.rest) return { cls: "d", text: t("st.rest") };
  return null;
}

// Contacts: sectioned by zone; the zone lead first in a section, the rest by short name; the section ends with this zone's off-duty list (newly off duty first)
export function contactsModel(snapshot) {
  const ss = snapshot.sessions || [];
  const off = snapshot.offduty || [];
  const sections = [];
  for (const z of sortedZones(snapshot)) {
    const key = z.code === null ? "_" : String(z.code);
    const isLead = (s) => z.lead != null && s.name === z.lead;
    const members = ss.filter((s) => zoneKey(snapshot.zones, s.zone) === key)
      .map((s) => ({ s, plate: plateOf(s), lead: isLead(s), status: contactStatus(s) }))
      .sort((a, b) => (b.lead - a.lead) || a.plate.localeCompare(b.plate, "zh"));
    const offs = off.filter((o) => zoneKey(snapshot.zones, o.zone) === key)
      .sort((a, b) => (b.offAt || 0) - (a.offAt || 0))
      .map((o) => ({ ...o, plate: plateOf({ name: o.name, zone: o.zone }) }));
    if (members.length || offs.length) sections.push({ key, name: z.name, color: z.color, members, off: offs });
  }
  return {
    counts: { waiting: ss.filter((s) => s.status === "waiting").length, pinned: ss.filter((s) => s.pinned).length, off: off.length },
    sections,
  };
}

// Search: only conversation name / short name / zone name / correspondent, the summary in a separate group, plus the off-duty list. Does not search full chat text.
export function chatSearch(snapshot, q) {
  const ql = String(q || "").trim().toLowerCase();
  if (!ql) return { byName: [], bySummary: [], off: [] };
  const has = (v) => String(v || "").toLowerCase().includes(ql);
  const zn = (code) => zoneFor(snapshot.zones, code).name;
  const ss = snapshot.sessions || [];
  const byName = ss.filter((s) => has(s.name) || has(plateOf(s)) || has(zn(s.zone)) || has(s.peer));
  const named = new Set(byName.map((s) => s.id));
  const bySummary = ss.filter((s) => !named.has(s.id) && (has(summaryText(s)) || has(s.summary))); // what is displayed is the summary rendered in the current language, so the original is searched too
  const off = (snapshot.offduty || []).filter((o) => has(o.name) || has(zn(o.zone)))
    .map((o) => ({ ...o, plate: plateOf({ name: o.name, zone: o.zone }) }));
  return { byName: sortChat(byName), bySummary: sortChat(bySummary), off };
}

// Highlight: split into segments at the first match (case-insensitive), the page builds nodes segment by segment
export function hlParts(text, q) {
  const t = String(text == null ? "" : text);
  const qs = String(q || "").trim();
  const i = qs ? t.toLowerCase().indexOf(qs.toLowerCase()) : -1;
  if (i < 0) return [{ t, hit: false }];
  const out = [];
  if (i > 0) out.push({ t: t.slice(0, i), hit: false });
  out.push({ t: t.slice(i, i + qs.length), hit: true });
  if (i + qs.length < t.length) out.push({ t: t.slice(i + qs.length), hit: false });
  return out;
}

// ---------- diagnostic log (switch under "Me") ----------
// Element description: tag#id.class first 40 characters[placeholder], so the log shows at a glance what was tapped
export function diagDesc(tag, id, cls, ph) {
  let s = String(tag || "?").toLowerCase();
  if (id) s += "#" + id;
  const c = String(cls || "").trim().replace(/\s+/g, ".").slice(0, 40);
  if (c) s += "." + c;
  if (ph) s += "[" + String(ph).slice(0, 30) + "]";
  return s;
}

// Throttle: events of the same kind are recorded once within gap ms; later ones in the window are not lost, and the last one is recorded when the window ends (trailing).
// s = { last: time of the last record, pending: whether a trailing record is already scheduled }. Returns act: now record immediately / later record after delay ms / skip a trailing record is already scheduled, only swap the data
// The window is anchored at the last recorded time, so a continuous stream still lands an entry every gap ms and is not pushed back forever
export function throttleStep(s, now, gap) {
  if (s.pending) return { act: "skip", s };
  if (now - s.last >= gap) return { act: "now", s: { last: now, pending: false } };
  return { act: "later", delay: s.last + gap - now, s: { last: s.last, pending: true } };
}

// Cache cap: drop the oldest when exceeded
export function diagCap(buf, max) {
  if (buf.length > max) buf.splice(0, buf.length - max);
  return buf;
}

// ---------- "working" effects in the message list ----------
// Chosen by zone: snapshot zones[].fx (the helper reads it from workzones.json / the machine-private zone-style.json) = marquee / circuit / halo / orbit.
// A zone with no fx, unzoned (or a zone not in the zone table) -> the pet walks out of the avatar frame. Zone codes are not recognized.
export const FX_KINDS = ["marquee", "circuit", "halo", "orbit"];
// Which pets can walk is not a hardcoded list; read each pet's caps in the pet manifest (data/pets/<name>/caps.json, aggregated into the manifest by build_pets.py):
// {"walk": true} can walk (row 7 "working" animation is walking) -> the pet goes out on errands / carries files itself, a stable pick of one of two by conversation id.
// No desk play: the pet only runs errands / carries files, it does not sit.
// Pets that cannot walk (no caps.json, or not marked walk) and the case of no pet installed: a Soulgent flame stand-in goes out of the frame, the pet stays in the avatar.
// Minimum runway width (CSS px) for a pet to leave the frame; if not enough it stays in the avatar and animates there
export const FX_TRACK_MIN = { run: 96, carry: 96 };
// Frame count of the Soulgent flame stand-in (web/figures/soulflame/, same spec as pets, 96x104 per frame)
export const FLAME_ROWS = { "7": 6 };

// A small stable hash (the same conversation id always gets the same number)
function strHash(str) {
  let x = 5381;
  const s = String(str);
  for (let i = 0; i < s.length; i++) x = ((x << 5) + x + s.charCodeAt(i)) | 0;
  return Math.abs(x);
}

// Which effect a working conversation uses. zones: the snapshot's zone table (decides "unzoned" consistently with the app's zone classification: a code not in the table counts as unzoned).
// caps: this pet's abilities (caps in the manifest, see above); petsKnown: the pet manifest's response ("none" = none installed at all).
// Returns { kind: marquee|circuit|halo|orbit|walk, mode: run|carry|null, actor: {type:"pet",name}|{type:"flame"}|null };
// returns null when not working, or unzoned while it is not yet known whether pets exist (manifest not fetched).
export function busyFx(s, petId, zones, caps, petsKnown) {
  if (!s || (s.status !== "busy" && !bgRun(s))) return null; // background running (idle but bgTasks>0 and not stuck) roams too
  // bg = background running while the main turn is idle: the figure outside the frame still roams, and the pet in the avatar stays standing on idle frames (no "on an errand" tag, no shadow left)
  const bg = s.status !== "busy";
  const z = (zones || []).find((x) => x && x.code === s.zone);
  const kind = z && FX_KINDS.includes(z.fx) ? z.fx : null;
  if (kind) return { kind, mode: null, actor: null, bg };
  const mode = strHash(s.id) % 2 ? "carry" : "run";
  const c = caps && typeof caps === "object" ? caps : {};
  if (petId && c.walk === true) return { kind: "walk", mode, actor: { type: "pet", name: petId }, bg };
  if (petId || petsKnown === "none") return { kind: "walk", mode, actor: { type: "flame" }, bg };
  return null; // pet manifest not fetched yet: no leaving the frame for now, only the text glow and timer remain
}

// While background work runs (bg of busyFx), the zone effects (marquee / circuit / halo / orbit) drop one level; busy + background, and unzoned walking, are not counted
export const fxCalm = (fx) => !!fx && fx.bg === true && fx.kind !== "walk";

// Whether the runway is wide enough: if so use the original play, otherwise return null (the pet stays animating in the avatar)
export function walkFit(mode, avail) {
  return FX_TRACK_MIN[mode] && avail >= FX_TRACK_MIN[mode] ? mode : null;
}

// ---------- foreground mini banner (iOS does not show web push while the App is in the foreground) ----------
// Same rules as push (api/notify.py): waiting for you for 3 s, finished-unread for 10 s before showing; unread already excludes inter-session/subagent turns on the server.
// The first snapshot (just opened, just back from the background) only records the state at that moment and shows nothing; the conversation being viewed counts as already shown.
export const BANNER_WAIT_MS = 3000;
export const BANNER_DONE_MS = 10000;
export function newBannerState() {
  return { init: false, e: {} };
}
// WorkBuddy error / aborted (summaryCode state.*) map to events by the same rules as push (same as _DONE_AS in api/notify.py): error 3 s, aborted 10 s
const BANNER_AS = { "state.error": "err", "state.stopped": "stopped" };
// With errorKind, it decides (same as _ERR_AS in api/notify.py); unexpected exit shows lost once; error / quota used up / unexpected exit all 3 s
const BANNER_ERR = { api: "err", auth: "err", wb_error: "err", rate_limit: "limit", wb_stopped: "stopped" };
const BANNER_FAST = { wait: 1, err: 1, limit: 1, lost: 1 };
function bannerTrig(s) {
  if (s.adminWait) return null; // guest: ones waiting for the admin do not show
  if (s.muted) return null; // banners for do-not-disturb conversations do not show either (same as system notifications)
  if (s.status === "waiting") return { kind: "wait", key: "w:" + (s.since || 0) };
  if (gone(s)) return s.guestView === true ? null : { kind: "lost", key: "l:" + (s.disconnectedSince || s.since || 0) };
  // Round key: the server's finishedAt (including bgEndedAt, errorSince; an error reported after being seen also counts as a new round), falling back to since for old backends
  if (s.unread && !s.manualUnread) return { kind: BANNER_ERR[s.errorKind] || BANNER_AS[s.summaryCode] || "done", key: "u:" + (s.finishedAt || s.since || 0) }; // a manually marked unread does not show
  return null;
}
// Returns { state, fire: [{ id, kind }], seen: [{ id, kind }] }; does not modify the passed state.
// seen = conversations being viewed: no banner, but they count as "seen in the App"; app.js reports them to the server (X-Zbs-Seen), after which the server stops sending system notifications
export function bannerStep(state, sessions, nowMs, viewingId) {
  const first = !state.init;
  const e = {};
  const fire = [];
  const seen = [];
  for (const s of sessions || []) {
    const sid = String(s.id);
    const t = bannerTrig(s);
    if (!t) continue;
    const old = state.e[sid];
    const x = old && old.key === t.key ? { ...old } : { key: t.key, kind: t.kind, first: nowMs, fired: first };
    e[sid] = x;
    if (x.fired) continue;
    if (viewingId != null && String(viewingId) === sid) { x.fired = true; seen.push({ id: sid, kind: x.kind }); continue; }
    if (nowMs - x.first < (BANNER_FAST[x.kind] ? BANNER_WAIT_MS : BANNER_DONE_MS)) continue;
    x.fired = true;
    fire.push({ id: sid, kind: x.kind });
  }
  return { state: { init: true, e }, fire, seen };
}
// Whether the banner should still show (a conversation may already be handled while queued)
export function bannerStill(s, kind) {
  if (!s || s.muted) return false;
  if (kind === "lost") return gone(s) && s.status !== "waiting";
  return kind === "wait" ? s.status === "waiting" : !!s.unread && !s.manualUnread && s.status !== "waiting";
}
// Banner text (same as the push text): title = short name (the banner has an avatar in the zone color); body "[waiting for you] content", with no tag when finished, just the summary;
// for waiting-for-you with no content write a fallback; for finished with no summary, and for error / aborted (the summary is the state word, same meaning) write only the full event word
export function bannerText(s, kind) {
  const one = (x) => String(x || "").replace(/\s+/g, " ").trim();
  const title = plateOf(s);
  if (kind === "wait") {
    const c = one(summaryText(s)) || one(waitingForText(s.waitingFor)) || t("pushmsg.fbWait");
    return { title, body: "[" + t("pushmsg.wait") + "] " + c };
  }
  // API error / quota used up carry content, "[error] API error 529: ..." "[quota used up] CC's own words" (same as push); unexpected exit writes only the full word
  if ((kind === "err" || kind === "limit") && API_ERR[s.errorKind]) {
    const c = one(errText(s));
    return { title, body: c ? "[" + t("pushmsg." + kind) + "] " + c : t("pushmsg." + kind) };
  }
  if (kind === "err" || kind === "stopped" || kind === "limit" || kind === "lost") return { title, body: t("pushmsg." + kind) };
  return { title, body: one(summaryText(s)) || t("pushmsg.fbDone") };
}

// ---------- Orca stats, monitoring, zone board ----------
// Token count: Chinese units (wan / yi) in zh, about three significant digits; English uses K / M / B
export function fmtTokens(n) {
  const v = Math.max(0, Number(n) || 0);
  if (isEn()) {
    if (v < 1e3) return String(Math.round(v));
    if (v < 1e6) return (v / 1e3).toFixed(v < 1e4 ? 1 : 0) + "K";
    if (v < 1e9) return (v / 1e6).toFixed(v < 1e7 ? 1 : 0) + "M";
    return (v / 1e9).toFixed(v < 1e11 ? 2 : 0) + "B";
  }
  if (v < 1e4) return String(Math.round(v));
  if (v < 1e8) return t("num.wan", { n: (v / 1e4).toFixed(v < 1e5 ? 1 : 0) });
  return t("num.yi", { n: (v / 1e8).toFixed(v < 1e10 ? 2 : 0) });
}
// Agent working time: minutes under 1 hour, otherwise hours (thousands separator)
export function fmtHours(ms) {
  const m = Math.max(0, Number(ms) || 0) / 60000;
  if (m < 60) return { n: String(Math.round(m)), unit: t("unit.min") };
  return { n: Math.round(m / 60).toLocaleString("en-US"), unit: t("unit.hour") };
}
export function fmtUsd(n) {
  const v = Math.max(0, Number(n) || 0);
  return "$" + (v >= 100 ? Math.round(v).toLocaleString("en-US") : v.toFixed(2));
}
// Disk uses base 1000 (same as Finder); memory passes bin=true for base 1024 (same as the 32 GB in "About This Mac")
export function fmtBytes(n, bin) {
  const v = Math.max(0, Number(n) || 0);
  const K = bin ? 1024 : 1000;
  const units = [["TB", K ** 4], ["GB", K ** 3], ["MB", K ** 2]];
  for (const [u, base] of units) {
    if (v >= base) {
      const x = v / base;
      return (u === "MB" || x >= 100 ? String(Math.round(x)) : x.toFixed(u === "TB" ? 2 : 1)) + " " + u;
    }
  }
  return Math.round(v / K) + " KB";
}

// Intensity levels: 0 unused; the rest are split into levels 1-4 by the ratio to that day / the max day (<=25% level 1 ... >75% level 4)
export function heatLevel(t, max) {
  if (!(t > 0) || !(max > 0)) return 0;
  return Math.min(4, Math.max(1, Math.ceil((t / max) * 4)));
}
// Intensity grid: 7 columns (Monday...Sunday) x several rows (weeks), the last row is this week; days of this week not yet arrived are null.
// days is the last 42 days in the snapshot [{day, tokens}] (old to new, the last is today). Take only enough days for 6 rows.
export function heatGrid(days) {
  const list = Array.isArray(days) ? days.filter((d) => d && typeof d.day === "string") : [];
  if (!list.length) return { rows: [], max: 0 };
  const last = list[list.length - 1];
  const [y, m, dd] = last.day.split("-").map(Number);
  const wd = (new Date(y, m - 1, dd).getDay() + 6) % 7; // Monday=0
  const take = Math.min(list.length, 35 + wd + 1);
  const cells = list.slice(list.length - take).map((d) => ({ day: d.day, tokens: d.tokens || 0 }));
  const lead = (((wd + 1 - take) % 7) + 7) % 7; // pad the front with blanks so today lands in its weekday column
  const padded = Array(lead).fill(null).concat(cells, Array(6 - wd).fill(null));
  const max = Math.max(0, ...cells.map((c) => c.tokens));
  const rows = [];
  for (let i = 0; i < padded.length; i += 7) {
    rows.push(padded.slice(i, i + 7).map((c) => (c ? { ...c, level: heatLevel(c.tokens, max) } : null)));
  }
  return { rows, max };
}

// "Me" page Orca stats (null if the snapshot has no orcaStats)
export function meStats(snapshot) {
  const o = snapshot && snapshot.orcaStats;
  if (!o) return null;
  const u = o.usage || null;
  return {
    agents: o.agents || 0,
    hours: fmtHours(o.agentTimeMs),
    today: u ? fmtTokens(u.todayTokens) : "—",
    total: u ? fmtTokens(u.totalTokens) : "—",
    cost: u ? fmtUsd(u.costUsd) : "—",
    costNote: u && u.unpricedTokens > 0 ? t("me.costNote", { n: fmtTokens(u.unpricedTokens) }) : "",
    activeDays: u ? u.activeDays : 0,
    peak: u && u.peakDay ? { day: u.peakDay.day, tokens: fmtTokens(u.peakDay.tokens) } : null,
    grid: heatGrid(u ? u.days : []),
    models: u ? (u.byModel || []).slice(0, 4) : [],
  };
}

// "2026-09-09" -> "Sep 9" (month-day in the current language)
export function shortDay(day) {
  const p = String(day || "").split("-");
  return p.length === 3 ? fmtMD(new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))) : "";
}

// ---------- monitoring thresholds ----------
export const DISK_WARN = 50e9;
export const DISK_BAD = 20e9;
export function pressureInfo(p) {
  if (p === "normal") return { text: t("mon.normal"), cls: "ok" };
  if (p === "warn") return { text: t("mon.warn"), cls: "warn" };
  if (p === "critical") return { text: t("mon.critical"), cls: "bad" };
  return { text: t("mon.unknown"), cls: "na" };
}
export function diskInfo(d) {
  if (!d || !(d.free >= 0)) return { text: "—", cls: "na" };
  const cls = d.free < DISK_BAD ? "bad" : d.free < DISK_WARN ? "warn" : "ok";
  return { text: t("mon.free", { v: fmtBytes(d.free) }), cls };
}
// Load: 1-minute load above the core count is busy (yellow), above twice the core count is very busy (red); no coloring if the core count is unknown
export function loadInfo(load, cores) {
  if (!Array.isArray(load) || load.length < 3) return { text: "—", cls: "na" };
  const s = load.map((x) => x.toFixed(x >= 100 ? 0 : 1)).join(" / ");
  if (!(cores > 0)) return { text: s, cls: "ok" };
  return { text: s, cls: load[0] > cores * 2 ? "bad" : load[0] > cores ? "warn" : "ok" };
}
// The color of the memory-related rows follows the system memory pressure level (Activity Monitor's convention), not judged by ratio itself
const PRESSURE_CLS = { normal: "ok", warn: "warn", critical: "bad" };
// Memory GB display: one decimal, integers drop the .0 (32.0 -> 32)
function gib(n) {
  return String(Number((Math.max(0, Number(n) || 0) / 1024 ** 3).toFixed(1))) + " GB";
}
// "Memory" row: used = App + wired + compressed; if compressed exceeds 25% of the total add "(compression high)". cached feeds the "Cached (reclaimable)" row (grey)
export function memInfo(mem, pressure) {
  if (!mem || !(mem.used >= 0)) return { text: "—", cls: "na", cached: { text: "—", cls: "na" } };
  const total = mem.total > 0 ? mem.total : 0;
  const used = gib(mem.used).replace(" GB", "");
  let text = t("mon.memUsed", { v: total ? used + " / " + gib(total) : gib(mem.used), c: gib(mem.compressed) });
  if (total && mem.compressed > total * 0.25) text += paren(t("mon.memHigh"));
  return { text, cls: PRESSURE_CLS[pressure] || "na", cached: { text: mem.cached >= 0 ? gib(mem.cached) : "—", cls: "na" } };
}
// Swap: does not fall back until reboot, so the ratio alone cannot tell whether things are slow. With pressure passed: critical red; warn with ratio > 0.5 yellow; the rest green.
// Without pressure (old callers): ratio > 0.8 red, > 0.5 yellow
export function swapInfo(s, pressure) {
  if (!s) return { text: "—", cls: "na" };
  if (!(s.total > 0)) return { text: t("mon.swapNone"), cls: "ok" };
  const pct = s.used / s.total;
  const text = fmtBytes(s.used, true) + " / " + fmtBytes(s.total, true);
  if (pressure === undefined) return { text, cls: pct > 0.8 ? "bad" : pct > 0.5 ? "warn" : "ok" };
  return { text, cls: pressure === "critical" ? "bad" : pressure === "warn" && pct > 0.5 ? "warn" : "ok" };
}
export function batteryInfo(b) {
  if (!b) return { text: t("mon.noBattery"), cls: "na" };
  const state = b.charging ? t("mon.charging") : b.ac ? t("mon.ac") : t("mon.onBattery");
  return { text: b.pct + "% · " + state, cls: !b.ac && b.pct <= 20 ? "bad" : "ok" };
}
// If monitoring data has not updated for over 30 seconds: returns "data as of hh:mm", otherwise ""
export const MONITOR_STALE_SEC = 30;
export function monitorStale(at, now) {
  if (!(at > 0)) return t("mon.noData");
  if (now - at <= MONITOR_STALE_SEC) return "";
  const d = new Date(at * 1000);
  return t("mon.dataAt", { t: String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0") });
}
// "Snapshot freshness" at the top of the monitoring page: seconds ago / minutes ago
export function freshText(at, now) {
  const d = Math.max(0, Math.round(now - at));
  if (!(at > 0)) return "—";
  if (d < 60) return t("time.secAgo", { n: d });
  if (d < 3600) return t("time.minAgo", { n: Math.floor(d / 60) });
  return t("time.hourAgo", { n: Math.floor(d / 3600) });
}

// ---------- zone board ----------
// One card per zone: lead short name (star), on duty, working, waiting for you, replied to you, off-duty count, today's token (null if the helper cannot match, not shown), whether there is a task board
export function zoneBoard(snapshot) {
  const ss = (snapshot && snapshot.sessions) || [];
  const off = (snapshot && snapshot.offduty) || [];
  const tokens = (snapshot && snapshot.zoneTokens && snapshot.zoneTokens.byZone) || {};
  const out = [];
  for (const z of sortedZones(snapshot || {})) {
    const key = z.code === null ? "_" : String(z.code);
    const inZ = (code) => zoneKey(snapshot.zones, code) === key;
    const mine = ss.filter((s) => inZ(s.zone));
    const offs = off.filter((o) => inZ(o.zone));
    if (z.code === null && !mine.length && !offs.length) continue; // an unzoned group with nobody is not drawn
    const leadS = z.lead != null ? mine.find((s) => s.name === z.lead) : null;
    const c = countOf(mine);
    out.push({
      key,
      code: z.code,
      name: z.name,
      color: z.color || "#8A8F98",
      lead: z.lead ? plateOf({ name: z.lead, zone: z.code }) : null,
      leadOn: !!leadS,
      onDuty: mine.length,
      busy: c.busy,
      waiting: c.waiting,
      unread: c.unread,
      off: offs.length,
      tokens: z.code != null && tokens[z.code] > 0 ? tokens[z.code] : null,
      taskboard: !!z.taskboard,
    });
  }
  return out;
}

// Suffix for numbers on the board page: when the Mac is disconnected (same macDown test) give "(as of hh:mm)", with hh:mm from snapshot generatedAt (local time zone, 24-hour); returns "" when not disconnected or no valid time
export function boardAsOf(snap, offline, now) {
  if (!snap || !macDown(snap, offline, now)) return "";
  const at = Number(snap.generatedAt);
  if (!(at > 0)) return "";
  const d = new Date(at * 1000);
  return paren(t("board.asOf", { t: String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0") }));
}

// ---------- usage mini rings (quota, context) ----------
// Ring color tiers: <60 grey (neutral) / 60-79 yellow / >=80 red; no data counts as grey
// Color tiers of the context ring in the chat page header: <50 theme blue / 50-69 orange / >=70 red; no data counts as blue (stale falls back to grey separately)
export const CTX_WARN = 50;
export const CTX_BAD = 70;
export function ctxLevel(pct) {
  const v = Number(pct);
  if (pct == null || !isFinite(v)) return "ok";
  if (v >= CTX_BAD) return "bad";
  if (v >= CTX_WARN) return "warn";
  return "ok";
}
// Context ring of a message-list row: only if the snapshot s.meta.ctxPct is a number give { pct (0-100 integer), lv (ok/warn/bad/n), text, stale }; with no data, and for resting rows, return null (not drawn)
// When meta is stale (metaStale, the same test as the chat page header) fall back to tier n (grey)
export function rowCtx(s, now) {
  if (!s || s.rest || !s.meta || typeof s.meta !== "object") return null;
  const v = s.meta.ctxPct;
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  const pct = Math.max(0, Math.min(100, Math.round(v)));
  const stale = metaStale(s.meta, now);
  return { pct, lv: stale ? "n" : ctxLevel(pct), text: pct + "%", stale };
}

export function meterLevel(pct) {
  const v = Number(pct);
  if (pct == null || !isFinite(v)) return "n";
  if (v >= 80) return "d";
  if (v >= 60) return "w";
  return "n";
}

// The 5H / 7D mini rings on the right of the messages-page status line; an item missing from snapshot usage is not shown
// If now (seconds) is passed, include left: a very short form of how long until recovery, "" when stale or no data; leftC is an even shorter form for when space is tight
export function quotaRings(usage, now) {
  const out = [];
  for (const [label, q] of [["5H", usage && usage.fiveHour], ["7D", usage && usage.sevenDay]]) {
    if (!q || q.pct == null || !isFinite(Number(q.pct))) continue;
    const pct = Math.max(0, Math.min(100, Math.round(Number(q.pct))));
    const r = { label, pct, lv: meterLevel(pct) };
    if (now != null) { r.left = quotaLeft(q.resetsAt, now); r.leftC = quotaLeftC(q.resetsAt, now); }
    out.push(r);
  }
  return out;
}

// ---------- quota recovery countdown ----------
// Remaining minutes (under 1 minute counts as 1); null if stale / no data
function leftMins(resetsAt, now) {
  const d = Number(resetsAt) - Number(now);
  if (resetsAt == null || !isFinite(d) || d <= 0) return null;
  return Math.max(1, Math.floor(d / 60));
}
// Very short form for the status line, e.g. 58m / 3h12m / 3h / 1d18h / 2d (localized units)
export function quotaLeft(resetsAt, now) {
  const mins = leftMins(resetsAt, now);
  if (mins == null) return "";
  if (mins < 60) return t("ql.m", { m: mins });
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h < 24) return m ? t("ql.hm", { h, m }) : t("ql.h", { h });
  const hh = h % 24;
  return hh ? t("ql.dh", { d: Math.floor(h / 24), h: hh }) : t("ql.d", { d: Math.floor(h / 24) });
}
// Even shorter form when the status line is tight: keep only the largest unit, rounded: 58m / 1h59m -> 2h / 23h40m -> 1d / 3d23h -> 4d
export function quotaLeftC(resetsAt, now) {
  const mins = leftMins(resetsAt, now);
  if (mins == null) return "";
  if (mins < 60) return t("ql.m", { m: mins });
  const h = Math.round(mins / 60);
  if (h < 24) return t("ql.h", { h });
  return t("ql.d", { d: Math.max(1, Math.round(mins / 1440)) });
}
// Recovery clock time (phone local time): today 20:00 / tomorrow 01:00 / Thu 10:00 (weekday via fmtWeekdayShort in i18n.js)
export function resetClock(resetsAt, now) {
  const d = new Date(Number(resetsAt) * 1000);
  const n = new Date(Number(now) * 1000);
  const hm = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  const day0 = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day0(d) - day0(n)) / 86400000);
  if (days <= 0) return hm;
  if (days === 1) return t("qc.tomorrow", { t: hm });
  return fmtWeekdayShort(d) + " " + hm;
}
// Description line on the monitoring page quota card: used 8% · recovers in 58 minutes (20:00) / used 60% · resets in 1 day 18 hours (Thu 10:00)
// kind "5H" says "recovers", "7D" says "resets"; if stale or no resetsAt, write only "used N%"
export function quotaCaption(q, kind, now) {
  const pct = Math.max(0, Math.min(100, Math.round(Number(q && q.pct) || 0)));
  const head = t("qc.used", { pct });
  const mins = leftMins(q && q.resetsAt, now);
  if (mins == null) return head;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  const span = mins < 60 ? t("qc.min", { m: mins })
    : h < 24 ? (m ? t("qc.hm", { h, m }) : t("qc.h", { h }))
    : (h % 24 ? t("qc.dh", { d: Math.floor(h / 24), h: h % 24 }) : t("qc.d", { d: Math.floor(h / 24) }));
  return t(kind === "5H" ? "qc.recover" : "qc.reset", { head, span, at: resetClock(q.resetsAt, now) });
}

// Shorten a token count: 414432 -> 414k, 1000000 -> 1M, 1500000 -> 1.5M
export function fmtCtx(n) {
  const v = Math.max(0, Number(n) || 0);
  if (v >= 1e6) return String(+(v / 1e6).toFixed(v % 1e6 === 0 ? 0 : 1)) + "M";
  if (v >= 1e3) return Math.round(v / 1e3) + "k";
  return String(Math.round(v));
}

// How long ago (difference in seconds): 12 seconds ago / 3 minutes ago / 2 hours ago
export function agoText(sec) {
  const d = Math.max(0, Math.round(Number(sec) || 0));
  if (d < 60) return t("time.secAgo", { n: d });
  if (d < 3600) return t("time.minAgo", { n: Math.floor(d / 60) });
  return t("time.hourAgo", { n: Math.floor(d / 3600) });
}

// What the chat page header needs: line = model row (null when there is no model, and the page falls back to "zone · project"), context ring, t/s, the hint for tapping the ring
// meta is old if not updated for META_STALE_SEC (the ring greys and fades)
export const META_STALE_SEC = 300;
// Whether meta is old (no timestamp also counts as old): shared by the chat page header ring (ctxPanel) and the message-list row ring (rowCtx)
export function metaStale(meta, now) {
  const at = Number(meta && typeof meta === "object" ? meta.at : NaN);
  const age = isFinite(at) && at > 0 ? Math.max(0, now - at) : null;
  return age == null || age > META_STALE_SEC;
}
export function metaView(meta, now) {
  if (!meta || typeof meta !== "object") return null;
  const model = typeof meta.model === "string" && meta.model ? meta.model : null;
  const effort = typeof meta.effort === "string" && meta.effort ? meta.effort.toLowerCase() : "";
  const line = model ? model + (meta.fast ? " ⚡" : "") + (effort ? " · " + effort : "") : null;
  const p = ctxPanel(meta, now);
  const ring = p.has ? { pct: p.pct, lv: p.lv, cl: p.stale ? "n" : ctxLevel(p.pct), stale: p.stale, tip: [p.usage, p.tps, p.ageText].filter(Boolean).join(" · ") } : null;
  return { line, ring, tps: p.tps };
}

// Top half of the panel popped up by tapping the context ring: percent used (progress bar), "context used / window", t/s, how long ago the data is.
// When has=false the panel says "no context data"; to add category details later, add fields to this object
export function ctxPanel(meta, now) {
  const m = meta && typeof meta === "object" ? meta : {};
  const at = Number(m.at);
  const age = isFinite(at) && at > 0 ? Math.max(0, now - at) : null;
  const stale = metaStale(m, now);
  const tps = Number(m.tps) > 0 ? Math.round(Number(m.tps)) + " t/s" : "";
  const has = m.ctxPct != null && isFinite(Number(m.ctxPct));
  if (!has) {
    return { has: false, pct: 0, lv: "n", stale: true, used: null, window: null, usage: t("ctx.none"), tps, age, ageText: "" };
  }
  const pct = Math.max(0, Math.min(100, Math.round(Number(m.ctxPct))));
  const used = m.ctxUsed != null ? fmtCtx(m.ctxUsed) : null;
  const window = m.ctxWindow ? fmtCtx(m.ctxWindow) : null;
  const usage = t("ctx.usage", { v: (used != null ? used : pct + "%") + (window ? " / " + window : "") });
  const ageText = age == null ? t("ctx.ageUnknown") : t("ctx.age", { t: agoText(age) });
  return { has: true, pct, lv: stale ? "n" : meterLevel(pct), cl: stale ? "n" : ctxLevel(pct), stale, used, window, usage, tps, age, ageText };
}

// Context details: data of /api/session/<id>/context -> what the panel draws.
// rows: one row per category, keeping the original /context order, only moving Free space to the end (grey); w = percent of the window (bar width)
// groups: collapsible details (MCP tools / custom agents / memory files / skills), empty ones omitted; memory files show only the file name, with the path in sub
// the second column is an i18n key (ctx.g.<key>), passed through t() when used
export const CTX_DETAIL_GROUPS = [
  ["mcpTools", "ctx.g.mcpTools"], ["agents", "ctx.g.agents"], ["memory", "ctx.g.memory"], ["skills", "ctx.g.skills"],
];
export const CTX_POLL_MS = 1000;
export const CTX_MAX_MS = 25000;
export function ctxRows(data) {
  const d = data && typeof data === "object" ? data : {};
  const win = Number(d.window) > 0 ? Number(d.window) : 0;
  const rows = [];
  let free = null;
  let i = 0;
  for (const c of Array.isArray(d.categories) ? d.categories : []) {
    if (!c || typeof c.name !== "string") continue;
    const tokens = Math.max(0, Number(c.tokens) || 0);
    let pct = c.pct == null ? NaN : Number(c.pct);
    if (!isFinite(pct)) pct = win ? tokens * 100 / win : 0;
    const isFree = /^free space$/i.test(c.name.trim());
    const row = {
      name: c.name, tokens, text: fmtCtx(tokens), pct,
      pctText: (pct > 0 && pct < 0.1 ? "<0.1" : pct.toFixed(1)) + "%",
      w: Math.max(0, Math.min(100, pct)), free: isFree, color: isFree ? "free" : "c" + (i % 6),
    };
    if (isFree) { free = row; continue; }
    rows.push(row);
    i += 1;
  }
  if (free) rows.push(free);
  const groups = [];
  const det = d.details && typeof d.details === "object" ? d.details : {};
  for (const [key, titleKey] of CTX_DETAIL_GROUPS) {
    const title = t(titleKey);
    const list = Array.isArray(det[key]) ? det[key] : [];
    const items = [];
    let sum = 0;
    for (const it of list) {
      if (!it || typeof it.name !== "string") continue;
      const tokens = Number(it.tokens) || 0;
      sum += tokens;
      let name = it.name;
      let sub = it.server || it.source || it.type || "";
      if (key === "memory") {
        name = it.name.split("/").filter(Boolean).pop() || it.name;
        sub = (it.type ? it.type + " · " : "") + it.name;
      }
      items.push({ name, sub, text: typeof it.label === "string" && it.label ? it.label : fmtCtx(tokens) });
    }
    if (items.length) groups.push({ key, title, count: items.length, sumText: fmtCtx(sum), items });
  }
  const head = d.used != null && win ? fmtCtx(d.used) + " / " + fmtCtx(win) + (d.pct != null ? " · " + Math.round(Number(d.pct)) + "%" : "") : "";
  return { model: typeof d.model === "string" ? d.model : "", head, rows, groups };
}
// Context panel: category name -> bar segment (msg orange / sys system and tools grey-blue / oth other / free)
export function ctxSegOf(name) {
  const n = String(name || "").trim();
  if (/^free space$/i.test(n)) return "free";
  if (/^messages$/i.test(n)) return "msg";
  if (/^system\b|^mcp\b/i.test(n)) return "sys";
  return "oth";
}
// What the bar + legend draw: segs by share of the total window (Free = window - used); big = items >= 1% (including Free); small = items < 1% merged into "Other (n items)"
// No categories (only the statusline total) -> only used / free segments; no window -> all empty
export function ctxBreakdown(data) {
  const d = data && typeof data === "object" ? data : {};
  const win = Number(d.window) > 0 ? Number(d.window) : 0;
  const empty = { segs: [], big: [], small: [], smallTitle: "", smallText: "" };
  if (!win) return empty;
  const rows = ctxRows(d).rows;
  const body = rows.filter((r) => !r.free);
  const sum = body.reduce((a, r) => a + r.tokens, 0);
  let used = d.used != null && isFinite(Number(d.used)) ? Number(d.used) : (d.pct != null && isFinite(Number(d.pct)) && !body.length ? win * Number(d.pct) / 100 : sum);
  used = Math.max(0, used);
  const freeTok = Math.max(0, win - used);
  const denom = Math.max(win, sum + freeTok);
  const mk = (k, tokens) => ({ k, tokens, w: tokens * 100 / denom });
  if (!body.length) return { ...empty, segs: [mk("used", used), mk("free", freeTok)] };
  const tot = { msg: 0, sys: 0, oth: 0 };
  for (const r of body) { r.seg = ctxSegOf(r.name); tot[r.seg] += r.tokens; }
  const segs = [mk("msg", tot.msg), mk("sys", tot.sys), mk("oth", tot.oth), mk("free", freeTok)];
  const free = rows.find((r) => r.free);
  if (free) { free.seg = "free"; free.tokens = freeTok; free.text = fmtCtx(freeTok); free.pct = freeTok * 100 / win; free.pctText = free.pct.toFixed(1).replace(/\.0$/, "") + "%"; }
  const big = body.filter((r) => r.pct >= 1).sort((a, b) => b.tokens - a.tokens);
  if (free) big.push(free);
  const small = body.filter((r) => r.pct < 1);
  const st = small.reduce((a, r) => a + r.tokens, 0);
  return {
    segs, big, small,
    smallTitle: small.length ? t("ctx.smallTitle", { n: small.length }) : "",
    smallText: small.length ? fmtCtx(st) + " · " + (st * 100 / win).toFixed(1) + "%" : "",
  };
}
// "Details N seconds ago": at is the cache/read time (seconds)
export function ctxAgeText(at, now) {
  const a = Number(at);
  return isFinite(a) && a > 0 ? t("ctx.detailAge", { t: agoText(Math.max(0, now - a)) }) : "";
}

// ---------- swipe-left menu on message rows ----------
// Decide whether a touch is a left swipe: horizontal displacement beyond the threshold and clearly horizontal; mostly vertical is left to page scrolling.
// If startX is too far left (the start of iOS swipe-back) and the swipe is rightward, do not take it; a rightward swipe on a row that is not open is not taken either.
// Returns "h" (take over the left swipe) / "v" (leave to scrolling) / "" (cannot tell yet)
export const SWIPE_SLOP = 12;
export function swipeDecide(dx, dy, startX, isOpen) {
  const ax = Math.abs(dx);
  const ay = Math.abs(dy);
  if (ax < SWIPE_SLOP && ay < SWIPE_SLOP) return "";
  if (ay >= SWIPE_SLOP && ay * 1.2 >= ax) return "v";
  if (ax < SWIPE_SLOP || ax < ay * 1.5) return "";
  if (dx > 0 && !isOpen) return "v"; // rightward swipe on a closed row: not ours (may be iOS back)
  if (dx > 0 && startX < 24) return "v";
  return "h";
}
// Open or closed after release: base is the position at press (0 closed / -w open), dx is how far it was dragged, w is the total button width
export function swipeSettle(base, dx, w) {
  const x = base + dx;
  const need = Math.min(60, w * 0.3);
  return base === 0 ? x < -need : x < -w + need;
}
// Buttons revealed by a row's left swipe (left to right): mark unread/read (blue), rest/return (orange), off duty (red)
// Whether it can be marked unread: idle with no red dot can be marked (turns from inter-session traffic / subagent reports can be marked too);
// working has no notion of "finished viewing", and waiting for you already counts as a red dot, so not offered
export const SWIPE_COLORS = { read: "#1E6FD9", rest: "#C87A2E", off: "#FA5151" };
export function swipeActions(s) {
  const out = [];
  // Grey card of unexpected exit: no read/unread, no rest (the wake endpoint only recognizes the off-duty list; after 10 minutes it falls into off duty and can then be woken), only off duty remains
  if (gone(s)) return s.kind === "claude" ? [{ key: "off", label: t("act.off"), color: SWIPE_COLORS.off }] : [];
  if (s.unread) out.push({ key: "seen", label: t("act.seen"), color: SWIPE_COLORS.read });
  else if (s.status === "idle") out.push({ key: "unseen", label: t("act.unseen"), color: SWIPE_COLORS.read });
  out.push(s.rest ? { key: "back", label: t("act.back"), color: SWIPE_COLORS.rest } : { key: "rest", label: t("act.rest"), color: SWIPE_COLORS.rest });
  if (s.kind === "claude") out.push({ key: "off", label: t("act.off"), color: SWIPE_COLORS.off });
  return out;
}
// Long-press (right-click on desktop) menu of a list row, in a vertical list. Combination by status:
//   working / waiting for you: pin / mute | off duty
//   idle (finished):           pin / mark unread·read / mute | rest / off duty
//   resting:                   pin / mute | return / off duty
// Pin = permanent pin (top/untop, stored in api top.json); an already pinned row always shows "Unpin"; the board's "reply later" does not go in the menu.
// A separator sits between the state class (pin/unread/mute) and the action class (rest/return/off duty); the red off-duty item is last (Claude only); guests have no menu
export function rowMenuActs(s, guest) {
  if (!s || guest) return [];
  const out = [s.topped ? { key: "untop", label: t("act.untop") } : { key: "top", label: t("act.top") }];
  const idle = s.status === "idle" && !gone(s); // unexpected exit: no read/unread, no rest
  if (idle && !s.rest) out.push(s.unread ? { key: "seen", label: t("act.seen") } : { key: "unseen", label: t("act.unseen") });
  out.push(s.muted ? { key: "unmute", label: t("act.unmute") } : { key: "mute", label: t("act.mute") });
  out.push({ sep: true });
  if (idle) out.push(s.rest ? { key: "back", label: t("act.back") } : { key: "rest", label: t("act.rest") });
  if (s.kind === "claude") out.push({ key: "off", label: t("act.off"), danger: true });
  if (out[out.length - 1].sep) out.pop(); // non-Claude busy/waiting conversations have no action class, so leave no trailing separator
  return out;
}
// Small floating hint shown when a receipt is tapped (look up rc.<receipt>)
export function rcTipText(rc) {
  return tCode("rc.", rc, "");
}
// Optimistic display after a swipe action: opt = Map(id -> { at: ms, unread?: boolean, rest?: boolean })
// Dropped when the snapshot already matches the phone, the conversation is gone, or FLAG_OPT_MS has passed; unread only applies to idle conversations (give up if it becomes busy/waiting for you)
export const FLAG_OPT_MS = 10000;
export function applyFlagOpt(snapshot, opt, nowMs) {
  if (!snapshot || !opt || !opt.size) return { snap: snapshot, opt: opt || new Map() };
  const next = new Map();
  const by = new Map((snapshot.sessions || []).map((s) => [s.id, s]));
  for (const [id, o] of opt) {
    const s = by.get(id);
    if (!s || nowMs - o.at >= FLAG_OPT_MS) continue;
    const keep = {};
    if (o.unread != null && s.status === "idle" && !!s.unread !== o.unread) keep.unread = o.unread;
    if (o.rest != null && !!s.rest !== o.rest && s.status !== "waiting") keep.rest = o.rest;
    if (Object.keys(keep).length) next.set(id, { at: o.at, ...keep });
  }
  if (!next.size) return { snap: snapshot, opt: next };
  const sessions = snapshot.sessions.map((s) => {
    if (!next.has(s.id)) return s;
    const { at, ...flags } = next.get(s.id);
    const out = { ...s, ...flags };
    if (flags.unread === true) out.manualUnread = true; // optimistically marked unread = manually marked, so no in-page banner
    else if (flags.unread === false) delete out.manualUnread;
    return out;
  });
  return { snap: { ...snapshot, sessions }, opt: next };
}
// Off-duty failure reasons are looked up by code in offfail.<code>
export function offFailText(r) {
  // Translate by code first; only a code missing from the table uses the original words (in the old helper's Chinese text, the part about adding --force is for the command line and is not shown)
  const m = r && r.message ? String(r.message).replace(RAW.forceRe, "").trim() : "";
  return tCode("offfail.", r && r.error, "") || m || t("off.fail");
}

// ---------- double-tap the bottom SoulChat tab ----------
// rows: rows with red dots on the page [{ id, top }] (top is the scrollY when scrolled to that row); ref: scrollY before the double tap; last: the row jumped to last time
// Returns the index of the next row: the first row below ref (skipping the row just jumped to, which happens when the page cannot scroll further), or back to the first if none; returns -1 if there are no red dots
export function nextDot(rows, ref, last) {
  if (!rows.length) return -1;
  let i = rows.findIndex((r) => r.top > ref + 1);
  if (i >= 0 && rows[i].id === last) i += 1;
  if (i < 0 || i >= rows.length) i = 0;
  if (rows.length > 1 && rows[i].id === last) i = (i + 1) % rows.length;
  return i;
}

// ---------- desktop wide screen (Windows / Mac browser, mouse) ----------
// The conditions must match the @media at the end of style.css exactly: wide enough, hover-capable, primary pointer is a mouse (phones and tablets never count)
export const WIDE_MQ = "(min-width: 700px) and (hover: hover) and (pointer: fine)";
export function wideMatch(width, hover, fine) {
  return Number(width) >= 700 && !!hover && !!fine;
}
// Tabs with the list + chat two-pane layout (as in a desktop web chat client); other tabs (zones, me) fill the content, with the chat page laid over them. A guest has only one conversation, no panes
const SPLIT_TABS = ["msg", "contacts"];
export function wideSplit(tab, guest) {
  return !guest && SPLIT_TABS.includes(tab);
}
// The wide-screen list pane width is draggable: min 280, max min(560, 45% of window width); if the window cannot fit, use the min; a non-number returns the default 370
export const LISTW_MIN = 280;
export const LISTW_MAX = 560;
export const LISTW_DEF = 370;
export function clampListW(w, winW) {
  let n = Number(w);
  if (w === null || w === undefined || w === "" || !Number.isFinite(n)) n = LISTW_DEF;
  const hi = Math.max(LISTW_MIN, Math.min(LISTW_MAX, Number(winW) * 0.45 || LISTW_MAX));
  return Math.round(Math.min(hi, Math.max(LISTW_MIN, n)));
}
// When switching tabs on wide screen, whether an open chat page stays: it stays only when switching between the two panes (Messages <-> Contacts), otherwise it is closed
export function keepDetailOnTab(from, to, guest) {
  return wideSplit(from, guest) && wideSplit(to, guest);
}
// Guest wide screen: when on "SoulChat" with no chat page open, directly open the bound conversation (returns the bound conversation id, null if it should not open)
export function guestAutoOpen(o) {
  const x = o || {};
  if (!x.wide || !x.guest || x.tab !== "msg" || x.detailId || x.searching) return null;
  const list = x.sessions || [];
  return list.length ? list[0].id : null;
}
// Whether pasted content counts as attachment or text: types = clipboardData.types, files = the files in the paste, plain = the plain text content
// Files count as attachments; exception: copying a paragraph or table from Word/Excel brings along a preview image (html/rtf plus non-empty text together), in which case paste as text
export function pasteKind(types, files, plain) {
  const fs = (files || []).filter(Boolean);
  if (!fs.length) return "text";
  const t = types || [];
  const allImg = fs.every((f) => /^image\//.test(f.type || ""));
  const rich = t.includes("text/html") || t.includes("text/rtf");
  if (allImg && rich && String(plain || "").trim()) return "text";
  return "files";
}

// ---------- group-chat style conversation page: speaker identity, grouping ----------
// Short zone name for the cross-team badge: snapshot zones[].short, else the zone name, else the code; unzoned writes "Other" (see speakerOf)
// The guest message prefix is not hardcoded: the server's .env GUEST_TAG is added before every guest sentence (no space in the tag, followed by one space),
// and /api/auth/me gives the tag to the frontend (to both accounts: the admin must also recognize guest bubbles by it). setGuestTag is called once at startup
export const DEFAULT_GUEST_TAG = "[Guest]";
const GUEST_TAG_MAX = 24; // same as clean_tag in api/guestcfg.py
const reEsc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
export function cleanGuestTag(t) {
  const v = typeof t === "string" ? t.trim() : "";
  return v && v.length <= GUEST_TAG_MAX && !/[\s\x00-\x1f\x7f]/.test(v) ? v : null;
}
// Claude Code turns a pasted image into "[Image #N] " at the very front, and the server's prefix follows it, so any number of [Image #N] are allowed before the prefix
function tagRes(tag) {
  const t = reEsc(tag);
  return {
    tag,
    prefix: new RegExp("^((?:\\[Image #\\d+\\]\\s*)*)" + t + "\\s*"),
    text: new RegExp("^(?:\\[Image #\\d+\\]\\s*)*" + t + "\\s"),
    quote: new RegExp("^(" + t + " )?> ([^\\n]+)\\n\\n([\\s\\S]*)$"),
  };
}
let GT = tagRes(DEFAULT_GUEST_TAG);
// Multiple guests: all recognized guest prefixes (a guest: only their own; the admin: each guest in guests from /api/auth/me). GT is the main prefix (the guest's own /
// the first guest's on the admin side), used for sending and avatar letters; recognizing "was it said by a guest" and stripping the prefix use all of GTS
let GTS = [GT];
export function setGuestTag(t) { GT = tagRes(cleanGuestTag(t) || DEFAULT_GUEST_TAG); GTS = [GT]; return GT.tag; }
export function setGuestTags(tags) {
  const seen = new Set([GT.tag]);
  GTS = [GT];
  for (const t of tags || []) {
    const c = cleanGuestTag(t);
    if (c && !seen.has(c)) { seen.add(c); GTS.push(tagRes(c)); }
  }
  return GTS.map((r) => r.tag);
}
export const guestTag = () => GT.tag;
// For an admin viewing a conversation: which guest is bound to it (guests from /api/auth/me: {account, tag, session}). Matches the conversation name or "zone-plate"; null if none
export function guestFor(s, guests) {
  if (!s) return null;
  const names = [s.name];
  if (s.zone && s.plate) names.push(s.zone + "-" + s.plate);
  return (guests || []).find((g) => g && g.session && names.includes(g.session)) || null;
}
// The optimistic bubble while sending must match the original text in the records: a guest's text gets "prefix + space" prepended
export const withGuestTag = (text) => GT.tag + " " + String(text == null ? "" : text);
// Where the prefix comes from: the API -> the last remembered one -> the old API (old versions give no tag; the guest prefix is "[ACCOUNT NAME UPPERCASE]") -> default
export function pickGuestTag(me, stored, account) {
  return cleanGuestTag(me && me.tag) || cleanGuestTag(stored)
    || (account && account !== "admin" && !(me && "tag" in me) ? cleanGuestTag("[" + String(account).toUpperCase() + "]") : null)
    || DEFAULT_GUEST_TAG;
}
// How the "Me" page card avatar is drawn: if an avatar is set use it (photo); if not - a guest uses the initial block (initial, the same as in the chat), the admin still uses the Orca icon (orca)
export function meCardAvatarKind(isGuest, hasUrl) {
  return hasUrl ? "photo" : isGuest ? "initial" : "orca";
}
// Letter on the guest avatar block: the prefix with outer brackets stripped; up to three characters as is, longer takes the first character ([Guest] -> G)
export function guestInitials(tag) {
  const s = String(tag || GT.tag);
  const m = RAW.bracketRe.exec(s);
  const inner = m ? m[1] : s;
  return Array.from(inner).length <= 3 ? inner : Array.from(inner)[0];
}
// Text of a guest's pending bubble: same rule as _guest_send in the server's api/server.py - plain text (no quote) starting with / is a slash command and gets no prefix; the rest gets the prefix.
// Change the rule on both sides together, otherwise the record does not match the bubble on arrival and shows twice.
export function guestPendText(quote, input) {
  const body = cleanReplyText(input);
  const t = buildQuoteText(quote, input);
  return t === body && SLASH_CMD_RE.test(body) && slashOk.includes(body.split(/\s+/)[0]) ? body : withGuestTag(t);
}
// A letter right after /, and no further / in the command name (absolute paths like /tmp/... are not commands); same as _SLASH_CMD_RE in api/server.py
export const SLASH_CMD_RE = /^\/[A-Za-z][\w:.-]*(\s|$)/;
// A guest can send only these slash commands (with arguments allowed); others are blocked with the hint "can only be typed on the Mac", leaving the text in the input.
// The list is GUEST_SLASH_COMMANDS on the server (default empty = none), delivered as `slash` in /api/auth/me and set at startup with setGuestSlashCommands
// (the server also rejects the rest: 403 slash-forbidden). The admin is not restricted
let slashOk = [];
export function setGuestSlashCommands(list) {
  slashOk = Array.isArray(list) ? list.filter((c) => typeof c === "string" && /^\/\S+$/.test(c)) : [];
}
export const guestSlashCommands = () => slashOk.slice();
export function guestSlashBlocked(quote, input) {
  const body = cleanReplyText(input);
  return buildQuoteText(quote, input) === body && SLASH_CMD_RE.test(body) && !slashOk.includes(body.split(/\s+/)[0]);
}
export const isGuestText = (text) => GTS.some((r) => r.text.test(String(text || "")));
export const stripGuestTag = (text) => {
  const s = String(text || "");
  const r = GTS.find((x) => x.prefix.test(s));
  return r ? s.replace(r.prefix, "$1") : s;
};

// Infer the zone from the conversation name prefix ("Web-xxx" -> Web); only codes present in zones are recognized, null if it cannot be inferred
export function zoneOfName(name, zones) {
  const n = String(name || "");
  let best = null;
  for (const z of zones || []) {
    const c = String((z && z.code) || "");
    if (c && n.startsWith(c + "-") && n.length > c.length + 1 && (!best || c.length > best.length)) best = c;
  }
  return best;
}

// Speaker roster: conversation name -> { name, zone, plate, lead, pet, id }.
// admin: snapshot sessions (with pets) + offduty (off-duty ones use sid as the pet seed, consistent with the off-duty chat page); the lead comes from zones[].lead.
// guest: snapshot roster (only name, zone, whether lead) + the bound conversation itself; other conversations get no pet (pet/id are null).
export function speakerDir(snap, guest) {
  const zones = (snap && snap.zones) || [];
  const codes = new Set(zones.map((z) => z && z.code).filter(Boolean));
  const leads = new Set(zones.map((z) => z && z.lead).filter(Boolean));
  const dir = new Map();
  const put = (name, zone, lead, pet, id, plate) => {
    const n = String(name || "");
    if (!n || dir.has(n)) return;
    const zc = codes.has(zone) ? zone : zoneOfName(n, zones);
    dir.set(n, { name: n, zone: zc, plate: plate ? String(plate) : plateOf({ name: n, zone: zc }), lead: !!lead, pet: pet || null, id: id == null ? null : String(id) });
  };
  for (const s of (snap && snap.sessions) || []) {
    if (!s) continue;
    // A guest snapshot has only the bound conversation; roster gives its lead (a guest's zones have no lead field)
    const r = guest ? ((snap.roster || []).find((x) => x && x.name === s.name) || {}) : null;
    put(s.name, s.zone, guest ? r.lead : leads.has(s.name), s.pet, s.id, plateOf(s)); // short name goes through plateOf (unnamed follows the language)
  }
  if (guest) {
    for (const r of (snap && snap.roster) || []) if (r) put(r.name, r.zone, r.lead, null, null);
  } else {
    for (const o of (snap && snap.offduty) || []) if (o) put(o.name, o.zone, leads.has(o.name), null, o.sid);
  }
  return dir;
}

// When the full name is not found in the roster, look up by short name (plate): only accept a unique match
function byPlate(dir, n) {
  let hit = null;
  for (const e of dir.values()) {
    if (e.plate === n) { if (hit) return null; hit = e; }
  }
  return hit;
}

// Speaker identity. self = this chat page's conversation ({name, zone, pet, id}); role:
//   self this conversation / mate teammate on the same team / lead the same team's lead / cross a member of another team / crossLead another team's lead
// pet: { pet, id } (handed to petName resolution in app.js), null when a guest views another conversation (avatar with the zone-color initial)
export function speakerOf(name, self, dir, zones, guest) {
  const me = self || {};
  const n = String(name || "");
  const isSelf = !!n && n === me.name;
  const e = (dir && (dir.get(n) || byPlate(dir, n))) || null;
  const zc = isSelf ? (me.zone || null) : e ? e.zone : zoneOfName(n, zones);
  const z = (zones || []).find((x) => x && x.code === zc) || null;
  const full = e ? e.name : n;
  const lead = e ? e.lead : (zones || []).some((x) => x && x.lead === n);
  const selfZone = me.zone && (zones || []).some((x) => x && x.code === me.zone) ? me.zone : null;
  const cross = !isSelf && (zc || null) !== selfZone;
  let pet = null;
  if (isSelf) pet = { pet: me.pet || null, id: me.id == null ? null : String(me.id) };
  else if (!guest && e && (e.pet || e.id)) pet = { pet: e.pet, id: e.id };
  return {
    name: full,
    plate: e ? e.plate : plateOf({ name: n, zone: zc }),
    zone: zc,
    zoneName: z ? z.name : UNZONED.name,
    short: zc ? ((z && z.short) || (z && z.name) || zc) : t("c.other"),
    color: z && z.color ? z.color : UNZONED.color,
    lead: !!lead,
    cross,
    role: isSelf ? "self" : cross ? (lead ? "crossLead" : "cross") : lead ? "lead" : "mate",
    pet,
  };
}

// Initial in the avatar: leading alphanumerics take two uppercase letters (FE-refactor -> FE), otherwise the first character
export function speakerInitials(plate) {
  const p = String(plate || "");
  const m = p.match(/^[A-Za-z0-9&]+/);
  return m ? m[0].slice(0, 2).toUpperCase() : p.slice(0, 1) || "?";
}

// Name-row tags: the lead gets a star; speech from other conversations (peers) always carries a zone badge (short name + the speaker's zone color, also for the same team); this conversation's own replies do not
export function whoTags(sp, who) {
  const s = sp || {};
  return {
    star: !!s.lead,
    zone: who === "peer" ? { short: s.short || t("c.other"), color: s.color || UNZONED.color } : null,
  };
}

// Whom a chat item belongs to: self this conversation (replies and tools) / peer:name inter-session / agent:task name subagent / guest / admin
export function speakerKey(it) {
  if (!it) return null;
  if (it.role === "assistant" || it.role === "tool") return "self";
  if (it.role === "peer") return "peer:" + (it.from || "");
  if (it.role === "agent") return "agent:" + (it.agentName || "");
  if (it.role === "user") return isGuestText(it.text) ? "guest" : "admin"; // the prefix the server adds to a guest's text
  return null;
}

// If an inter-session message body still starts with "from X:", strip it (the name row already says who)
export function stripFrom(text) {
  return String(text || "").replace(RAW.fromRe, "");
}

// Time divider on the chat page (group-chat style): today "AM 11:45" / yesterday "Yesterday PM 10:49" / within 7 days "Monday AM 11:45" /
// this year "Sep 4 AM 11:45" / earlier years "Sep 4, 2025 AM 11:45". Same naming as chatTime in the message list, but always with the clock time
// English: 1:42 PM / Yesterday 1:42 PM / Monday 1:42 PM / Oct 12, 1:42 PM / Oct 12, 2025, 1:42 PM
export const STAMP_GAP_SEC = 300; // a time shows only when more than 5 minutes apart
export function chatStamp(sec, now) {
  if (!sec) return "";
  const d = new Date(sec * 1000);
  const n = new Date(now * 1000);
  const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(n) - day(d)) / 86400000);
  const en = isEn();
  const clock = en ? fmtClockEn(d) : dayPart(d.getHours()) + (d.getHours() % 12 || 12) + ":" + String(d.getMinutes()).padStart(2, "0");
  if (diff <= 0) return clock;
  if (diff === 1) return t("time.yesterday") + " " + clock;
  if (diff < 7) return fmtWeekday(d) + " " + clock;
  if (d.getFullYear() === n.getFullYear()) return fmtMD(d) + (en ? ", " : " ") + clock;
  return fmtYMD(d) + (en ? ", " : " ") + clock;
}

// System notices: the server gives { role: "notice", code } (e.g. code=compacted, context compacted), shown as centered grey text in the current language;
// an old backend gives a user bubble "(context compacted)", recognized as the same notice. For an unknown code use text if present, and show nothing if neither exists
export const isSysLine = (it) => !!it && (it.role === "notice" || (it.role === "user" && it.text === RAW.compacted));
export function sysLineText(it) {
  if (!it) return "";
  if (it.role !== "notice") return t("notice.compacted");
  if (it.code === "apiError") { // CC's API error - auth is a fixed sentence (same as the list / notice bar), others use CC's own words (the server already stripped the "API Error:" prefix)
    if (it.kind === "auth") return t("sum.state.apiError.auth");
    return typeof it.text === "string" ? it.text : "";
  }
  return tCode("notice.", it.code, typeof it.text === "string" ? it.text : "");
}
// Task notifications ("Agent "X" finished", background command done): not shown, used only to decide whether dispatched tools have finished
export const isNotice = (it) => !!it && it.role === "agent" && it.notice === true;
// Subagent reports: not their own bubble, folded into the tool tag that dispatched them
export const isHandback = (it) => !!it && it.role === "agent" && it.notice !== true;
// Task notification -> { toolUseId: latest state } (one task may notify several times, the later one wins)
export function taskStates(items) {
  const m = new Map();
  for (const it of items || []) if (isNotice(it) && it.forTool) m.set(it.forTool, String(it.task || ""));
  return m;
}
const TASK_FAIL = new Set(["failed", "killed", "error"]);
// Whether a full turn has happened after i (the user spoke and the Agent replied with text): when a background task got no notification, one turn later it is treated as finished
export function turnAfter(items, i) {
  let user = false;
  for (let k = i + 1; k < (items || []).length; k++) {
    const r = (items[k] || {}).role;
    if (r === "user") user = true;
    else if (user && r === "assistant") return true;
  }
  return false;
}
// Tool tag badge: ok = all have results and none errored (background-dispatched ones wait for the task notification to finish) / err = one errored or a task failed or was killed / null = some are unfinished.
// stopped (stopped on purpose, mostly long-running background processes) counts as finished, not as an error.
// Task state first uses it.task from the server index (the notification may be on another page, or only recorded in the queued record), otherwise this page's notifications;
// a background task with no notification and a full turn since also counts as done (only truly unknown ones get no badge).
export function toolMark(idx, items, tasks) {
  if (!idx || !idx.length) return null;
  const ts = tasks || taskStates(items);
  let open = false;
  for (const i of idx) {
    const it = items[i] || {};
    const st = String(it.task || ts.get(it.toolUseId || "") || "");
    if (it.isError || TASK_FAIL.has(st)) return "err";
    if (it.pending) open = true;
    else if (it.bg && (!st || st === "running") && !turnAfter(items, idx[idx.length - 1])) open = true;
  }
  return open ? null : "ok";
}

// Conversation -> display blocks:
//   { t: "time", sec } time divider; { t: "ask", i } question card; { t: "approve", i } approval card (right after its group of tools)
//   { t: "group", key, who, from?, name?, parts } consecutive messages of the same speaker; who: self/peer/agent/me/guest/admin (me = the current account itself)
//   parts: { t: "msg", i } or { t: "tools", idx: [...], hand: [...], open?, trail? } (hand = folded-in subagent reports)
// or { t: "ph" } (the reply placeholder bubble at the end when opts.busy)
// A gap over 5 minutes inserts a time and breaks the group; question and approval cards break the group.
// Task notifications do not appear; a subagent report attaches to the tool tag that dispatched it (forTool), else to the nearest tool tag, and if there is none before it, starts an empty tag of its own.
// Within this conversation's group, a run of tools moves below the reply right after it (see the reply first, then which commands ran for it); trailing tools with no reply yet stay.
export function chatPlan(items, opts) {
  const o = opts || {};
  const approveIdx = o.approveIdx == null ? -1 : o.approveIdx;
  const mine = o.guest ? "guest" : "admin";
  const out = [];
  let g = null;
  let run = null; // the run of tools being collected
  let prevTs = 0;
  const byTool = new Map(); // toolUseId -> the tool tag it is in
  let lastTools = null;
  const endRun = () => { run = null; };
  const close = () => {
    endRun();
    if (!g) return;
    if (g.who === "self") {
      const p = g.parts;
      for (let k = 0; k + 1 < p.length; k++) {
        if (p[k].t === "tools" && !p[k].approve && (p[k + 1].t === "msg" || p[k + 1].t === "ph")) { const x = p[k]; p[k] = p[k + 1]; p[k + 1] = x; k++; }
      }
    }
    for (const p of g.parts) delete p.approve;
    g = null;
  };
  const open = (key, it) => {
    close();
    let who = key;
    if (key === mine) who = "me";
    else if (key.startsWith("peer:")) who = "peer";
    else if (key.startsWith("agent:")) who = "agent";
    g = { t: "group", key, who, parts: [] };
    if (who === "peer") g.from = it.from || "";
    if (who === "agent") g.name = it.agentName || "";
    out.push(g);
  };
  (items || []).forEach((it, i) => {
    if (isNotice(it)) return;
    if (isHandback(it)) {
      let p = (it.forTool && byTool.get(it.forTool)) || lastTools;
      if (!p) {
        if (!g || g.key !== "self") open("self", it);
        p = { t: "tools", idx: [], hand: [] };
        g.parts.push(p);
        lastTools = p;
      }
      p.hand.push(i);
      return;
    }
    const sec = isoToSec(it.ts);
    if (sec && (!prevTs || sec - prevTs > STAMP_GAP_SEC) && it.role !== "tool") {
      // (figure edge case 1): this conversation sits on a run of tools and replies only after more than 5 minutes - the divider is still drawn, but the run follows the reply
      // (taken off the old group, put into the new one, and moved below the reply by close() as usual), not left as a separate row; the figure key (first toolUseId) is unchanged
      let carry = null;
      if (run && g && g.key === "self" && !run.approve && g.parts[g.parts.length - 1] === run && it.role !== "ask" && speakerKey(it) === "self") {
        carry = run;
        g.parts.pop();
        if (!g.parts.length) {
          out.splice(out.lastIndexOf(g), 1); g = null;
          if (out.length && out[out.length - 1].t === "time") out.pop(); // the old group has only this run left, immediately preceded by a divider: the new divider wins
        }
      }
      close();
      out.push({ t: "time", sec });
      if (carry) { open("self", it); g.parts.push(carry); run = carry; }
    }
    if (sec) prevTs = sec;
    if (it.role === "ask") { close(); out.push({ t: "ask", i }); return; }
    if (isSysLine(it)) { close(); const text = sysLineText(it); if (text) out.push(it.code === "apiError" ? { t: "sys", i, text, cls: it.kind === "rate_limit" ? "limit" : "err" } : { t: "sys", i, text }); return; } // system notice: one centered grey line
    const key = speakerKey(it);
    if (!key) return;
    if (!g || g.key !== key) open(key, it);
    if (it.role === "tool") {
      if (!run) { run = { t: "tools", idx: [], hand: [] }; g.parts.push(run); lastTools = run; }
      run.idx.push(i);
      if (it.toolUseId) byTool.set(it.toolUseId, run);
      if (i === approveIdx) { run.open = true; run.approve = true; close(); out.push({ t: "approve", i }); }
      return;
    }
    endRun();
    g.parts.push({ t: "msg", i });
  });
  // The conversation ends on a run of tools (the last item is a tool): mark it, expanded when waiting for you
  const last = out[out.length - 1];
  const lp = last && last.t === "group" ? last.parts[last.parts.length - 1] : null;
  if (lp && lp.t === "tools" && lp.idx[lp.idx.length - 1] === (items || []).length - 1) lp.trail = true;
  // Reply placeholder: when busy append a placeholder bubble { t: "ph" } (used as a msg). If the last group is this conversation's, put it in;
  // the swap in close() moves the trailing unreplied tool run after it ([...][ph][tools]); otherwise start a new group [ph] for this conversation.
  // Exception: when this conversation's last group has a running subagent and the group has a bubble to attach to, no placeholder - the bubble that dispatched it carries the glow effect and already expresses "waiting",
  // and the "worked" time is on the back; when the subagent finishes (the main session is writing a reply) or there is no bubble above to attach to (the group starts with the Agent call), the placeholder is left as is.
  const agentBusy = !!g && g.key === "self" && g.parts.some((p) => p.t === "msg") &&
    g.parts.some((p) => p.t === "tools" && p.idx.some((i) => { const a = ((items || [])[i] || {}).agent; return !!a && a.state === "running"; }));
  if (o.busy && !agentBusy) {
    if (!g || g.key !== "self") open("self", {});
    endRun();
    g.parts.push({ t: "ph" });
  }
  close();
  return out;
}

// Whether a time divider goes before a pending bubble: same rule as chatPlan (more than 5 minutes after the previous one, or the chat is still empty).
// This way, when the real record arrives and replaces it, the layout is the same as when pending, with no extra time row pushing everything up.
// lastStampSec: the final value of prevTs in chatPlan = the time of the last counted record (excluding task notifications and subagent reports)
export function lastStampSec(items) {
  let last = 0;
  for (const it of items || []) {
    if (isNotice(it) || isHandback(it)) continue;
    const sec = isoToSec(it.ts);
    if (sec) last = sec;
  }
  return last;
}
// prevSec: the time (seconds) of the previous pending bubble; if present it takes priority
export function pendNeedsStamp(items, sec, prevSec) {
  const prev = prevSec || lastStampSec(items);
  return !prev || sec - prev > STAMP_GAP_SEC;
}

// Answered card: split one question's answer into display pieces. { t: "opt", text } is a selected option (small rounded tag), { t: "txt", text } is text the user typed.
// Claude Code records a multi-select answer by joining options with ", " (typed text last); split only if every piece matches an option, so an answer that itself contains commas is not broken.
export function answerParts(answer, options, multi) {
  const a = String(answer == null ? "" : answer).trim();
  if (!a) return [];
  const opts = (options || []).map(String).filter(Boolean);
  if (!multi) return [opts.includes(a) ? { t: "opt", text: a } : { t: "txt", text: a }];
  const byLen = opts.slice().sort((x, y) => y.length - x.length);
  const out = [];
  let rest = a;
  while (rest) {
    const hit = byLen.find((l) => rest === l || rest.startsWith(l + ", "));
    if (!hit) break;
    out.push({ t: "opt", text: hit });
    rest = rest.slice(hit.length + 2);
  }
  if (rest) out.push({ t: "txt", text: rest });
  return out;
}

// The answer Claude Code records when a preview question has only a note and no option (2.1.310 source Qen); not shown as answer text
export const NOTES_ONLY = "(notes only)";
// Answered card: list { q, parts } in question order; when the questions are unavailable, use the answers' original order.
// notes (taken by the server from toolUseResult.annotations): { question: note }, appended after the answer as { t: "note", text }
export function answeredRows(questions, answers, notes) {
  const ans = answers && typeof answers === "object" ? answers : {};
  const nts = notes && typeof notes === "object" ? notes : {};
  const qs = Array.isArray(questions) ? questions : [];
  const rows = [];
  const used = new Set();
  const row = (key, v, opts, multi) => {
    const ps = v === NOTES_ONLY ? [] : answerParts(v, opts, multi);
    const nt = String(nts[key] == null ? "" : nts[key]).trim();
    if (nt) ps.push({ t: "note", text: nt });
    rows.push({ q: key, parts: ps });
  };
  for (const q of qs) {
    const key = String((q && q.question) || "");
    if (!(key in ans) && !(key in nts)) continue;
    used.add(key);
    row(key, ans[key], q.options, q.multiSelect === true);
  }
  for (const k of new Set([...Object.keys(ans), ...Object.keys(nts)])) if (!used.has(k)) row(k, ans[k], [], false);
  return rows.filter((r) => r.parts.length);
}

// Inter-session message folding: marker of the expanded state (so it does not collapse back after the chat poll redraws)
export function peerKey(it) {
  return String((it && it.ts) || "") + "|" + String((it && it.text) || "").slice(0, 60);
}

// ---------- tool figures ----------
// Tool name -> 6 badge classes (as on the Mac board, filled in from the tools actually seen in conversations of the last 3 days); AskUserQuestion is a question card and draws no figure (null).
// MCP tools are always mcp__<server>__<tool>, all counted as thinking, with no need to split the server segment.
export const FIG_CLASSES = ["terminal", "pencil", "magnifier", "globe", "agents", "thinking"];
const FIG_CLASS_OF = {
  terminal: ["Bash", "BashOutput", "KillShell", "PowerShell", "Monitor", "TaskStop"],
  pencil: ["Edit", "Write", "MultiEdit", "NotebookEdit", "Artifact"],
  magnifier: ["Read", "Grep", "Glob", "LS", "ToolSearch", "ListMcpResourcesTool", "ReadMcpResourceTool"],
  globe: ["WebFetch", "WebSearch"],
  agents: ["Agent", "Task", "SendMessage", "ListAgents", "Workflow"],
};
const FIG_BY_NAME = new Map();
for (const [cls, names] of Object.entries(FIG_CLASS_OF)) for (const n of names) FIG_BY_NAME.set(n, cls);
export function toolClass(name) {
  const n = String(name || "");
  if (!n || n === "AskUserQuestion") return null;
  return FIG_BY_NAME.get(n) || "thinking";
}
// Records without a name (written by older servers): take the first word of the summary
const toolNameOf = (it) => String((it && it.name) || String((it && it.text) || "").split(/\s/)[0] || "");
export const FIG_WAIT_SEC = 30; // a single tool unfinished for over 30 seconds: roaming speed halves (no pose change, there is only the roaming pose)

// Figures of each tool tag: draw only for tool tags in this conversation's (self) groups that have a bubble above (a tool tag that is the first item in its group is not drawn).
// Returns [{ key, idx, figs: [{ id, cls, state, since }] }] (one entry per tool call, in call order; id = toolUseId, or "i:" + the index within the run if absent), key uses the first tool's toolUseId of the tool tag (unchanged when moved below a new reply).
// A single tool's working / done / error reuses toolMark (pending, task notifications like background bg, TASK_FAIL, isError, a full turn passed).
// agents class (decided): when an Agent is dispatched the tool_result returns immediately (bg), and real completion is read from the task notification (taskStates / it.task):
// completed = done, failed/killed = error, no notification = running; "report arrived" or "a reply followed" is not used as the criterion,
// so the agents class does not take toolMark's fallback of "a background task counts as done after a full turn" (background commands still do).
// Still running is always working (the figure has only the roaming pose; the half speed when running long is decided by figures.js from since); finished with an error is error, otherwise done; since = the time of this call.
export function figurePlan(items, tasks, now, plan, bgLive) {
  const its = items || [];
  const ts = tasks || taskStates(its);
  const blocks = plan || chatPlan(its, {});
  const out = [];
  for (const b of blocks) {
    if (b.t !== "group" || b.who !== "self") continue;
    // Under one bubble there may hang several consecutive tool tags (a moved run + a trailing run with no reply yet): merge them into one group of figures, all anchored to this bubble
    const runs = [];
    let cur = null, msg = false;
    b.parts.forEach((p) => {
      if (p.t === "msg" || p.t === "ph") { cur = null; msg = true; return; }   // the placeholder bubble is an anchor like a real reply
      if (p.t !== "tools" || !p.idx.length) return;            // an empty tag with only subagent reports: skip, do not interrupt
      if (!cur) {
        if (!msg) return;                                       // the group starts with a tool tag (no bubble above): not drawn
        cur = { parts: [] };
        runs.push(cur);
      }
      cur.parts.push(p);
    });
    for (const run of runs) {
      const idx = run.parts.flatMap((p) => p.idx);
      const first = its[idx[0]] || {};
      const key = first.toolUseId ? "t:" + first.toolUseId : "i:" + String(first.ts || "") + ":" + toolNameOf(first);
      const figs = [];
      idx.forEach((i, k) => {                                   // one figure per tool call
        const it = its[i] || {};
        const cls = toolClass(toolNameOf(it));
        if (!cls) return;
        const sec = isoToSec(it.ts) || 0;
        let mark = toolMark([i], its, ts);
        if (cls === "agents" && mark === "ok" && it.bg && !it.isError) {   // a subagent that has not received a task notification counts as running, not taking the "a turn passed" fallback
          const tst = String(it.task || ts.get(it.toolUseId || "") || "");
          if (!tst || tst === "running") mark = null;
        }
        if (mark === "ok" && cls !== "agents" && it.bg && !it.isError && bgLive && bgLive.has(it.toolUseId || "")) { // the snapshot says background work is still running, so do not take the "a turn passed" fallback
          const tst = String(it.task || ts.get(it.toolUseId || "") || "");
          if (!tst || tst === "running") mark = null;
        }
        let state;
        if (mark === null) state = "working";
        else state = mark === "err" ? "error" : "done";
        figs.push({ id: it.toolUseId || "i:" + k, cls, state, since: sec });
      });
      if (!figs.length) continue;
      // part / parts: used by app.js to mark data-fig on these tool tags and bubbles
      out.push({ key, idx, figs, part: run.parts[0], parts: run.parts });
    }
  }
  return out;
}

// Figure geometry (constants locked by figures.test.mjs): display 18x20, at least 14px per figure on the top-edge band, 10px spacing below (6.5px when most crowded), at most 10, 16px kept on the left for +N
// The figure-dependent items (FOOT feet, TOP top of the visible body, CLIP how much to clip at the top once parked) are not hardcoded; they are rewritten by setFigGeom from the "figure config";
// this is the placeholder before the config is read. Display size 18x20 is shared by all figures (sprites are all 96x104 per frame, scaled proportionally).
// Sprite frame stepping as "hold" keyframes (Web Animations format): frame k is held for [k/n, (k+1)/n) and then jumps within 0.0001% of the cycle.
// Looks the same as easing steps(n) from translateX(0) to translateX(-n*w), but Safari only runs transform animations without steps() off the main thread;
// a single steps() animation makes it re-render the whole page every frame.
export function holdFrames(n, w) {
  const out = [];
  for (let k = 0; k < n; k++) {
    const tf = "translateX(" + (k ? -k * w : 0) + "px)";
    out.push({ transform: tf, offset: k / n });
    out.push({ transform: tf, offset: k < n - 1 ? (k + 1) / n - 1e-6 : 1 });
  }
  return out;
}

export const FIG = { CW: 18, CH: 20, FOOT: 18, LANE: 14, QSTEP: 10, QMIN: 6.5, QMAX: 10, TOP: 0, CLIP: 0, QRESERVE: 16 };

// ---------- which figure the tool figures use ----------
// Figure config (figure.json, one per figure; every field is optional, missing ones use FIG_GEOM_DEFAULT):
//   frame [w, h]   pixels of one sprite frame (frames are counted by width)
//   foot           which px of the display box the feet are at (when standing on the bubble's top edge, box top = bubble top - foot)
//   footBase       baseline row of the feet within a frame; footRow { strip: row } the row of the feet within the frame for each sprite strip, differing ones are padded downward so the feet all stand on one line
//   top            the row (/frame height) of the top of the visible body when parked under a bubble; this row aligns with the bubble's bottom edge
//   dockClip       how many px to clip from the top of the display box once parked (hiding props above the head); 0 = no clip
export const FIG_ROWS = ["0", "1", "2", "3", "4", "6", "7"];
export const FIG_GEOM_DEFAULT = { frame: [96, 104], foot: 18, footBase: 100, footRow: {}, top: 24, dockClip: 0 };
export const FIG_BUILTIN = "/figures/soulflame/";
// Pick the figure: use the pet whose manifest entry has a figure field (a figure config object); if none has it, use the first pet with all 7 sprite strips (default figure config);
// an empty manifest (no pet installed) returns null -> use the built-in Soulgent flame (FIG_BUILTIN).
export function pickFigure(pets) {
  const names = Object.keys(pets || {}).sort();
  const full = (e) => !!e && FIG_ROWS.every((r) => Number(e[r]) > 0);
  for (const n of names) {
    const f = pets[n] && pets[n].figure;
    if (f && typeof f === "object" && full(pets[n])) return { name: n, cfg: f };
  }
  const n = names.find((k) => full(pets[k]));
  return n ? { name: n, cfg: null } : null;
}
// Figure config -> geometry for the figure layer (px, scaled by the display height FIG.CH)
export function figureGeom(cfg) {
  const c = Object.assign({}, FIG_GEOM_DEFAULT, cfg && typeof cfg === "object" ? cfg : {});
  const fw = Number(c.frame && c.frame[0]) || 96, fh = Number(c.frame && c.frame[1]) || 104;
  const base = Number(c.footBase) || fh;
  const rows = {};
  for (const [k, v] of Object.entries(c.footRow || {})) if (Number(v)) rows[k] = Number(v);
  const top = Number(c.top) / fh * FIG.CH || 0;
  return {
    fw, fh, foot: Number(c.foot) || FIG.FOOT, top, clip: Math.max(0, Number(c.dockClip) || 0),
    // how many px each sprite strip shifts down in the display box (aligning feet to the baseline row)
    shift: (name) => (base - (rows[name] || base)) / fh * FIG.CH,
    // once parked, the badge moves to the center above the head, badge bottom = top of the visible body: how far up from the working anchor (12, 5) (badge 9px)
    bdgDy: Number((top - 9 - 5).toFixed(2)),
  };
}
export function setFigGeom(g) {
  FIG.FOOT = g.foot; FIG.TOP = g.top; FIG.CLIP = g.clip;
  return FIG;
}
// Top-edge band: from 6px right of the name to 2px inside the bubble's right edge
export function figBand(nameR, r) { const lo = nameR + 6; return [lo, Math.max(lo, r - 2)]; }
export function figTopCap(lo, hi) { return Math.max(0, Math.floor((hi - lo) / FIG.LANE)); }
// How many fit on top; when they do not all fit, one slot is kept for +N
export function figTopShown(n, cap) { return n <= cap ? n : Math.max(0, cap - 1); }
export function figLane(i, k, lo, hi) {
  const w = Math.max(FIG.LANE, (hi - lo) / Math.max(1, k));
  const a = lo + w * i, b = a + w - FIG.CW;
  return [a, Math.max(a, b)];
}
// Queue at the bottom (w = bubble width, r = bubble's right edge)
export function figQCap(w) { return Math.max(1, Math.min(FIG.QMAX, Math.floor((w - FIG.CW - FIG.QRESERVE) / FIG.QMIN) + 1)); }
export function figQStep(n, w) {
  if (n <= 1) return FIG.QSTEP;
  return Math.max(FIG.QMIN, Math.min(FIG.QSTEP, (w - FIG.CW - FIG.QRESERVE) / (n - 1)));
}
export function figQX(i, n, r, w) { return r - FIG.CW - figQStep(n, w) * i; }
export function figCrowd(n, w) { return (FIG.QSTEP - figQStep(n, w)) / (FIG.QSTEP - FIG.QMIN); } // 0 not crowded, 1 packed tightest

// ---------- subagent flip bubble ----------
// The server adds an agent field to Agent/Task tool entries (only if there is meta): { id, description, model, agentType, task, state, startedAt, lastAt, endedAt, lastStep, tokens }
// state: running / done / failed / gone (running but no activity for 30 minutes)
const AG_ORDER = { failed: 0, running: 1, gone: 2, done: 3 };
// Which bubble glows: each figurePlan group (anchor = the bubble above the group, a real reply or placeholder bubble, key same as the figures) containing a call with an agent field
// Returns Map<group key, { status: run/done/fail, agents: sorted }>
export function agentGlowPlan(items, figPlan) {
  const out = new Map();
  for (const e of figPlan || []) {
    const agents = (e.idx || []).map((i) => (items || [])[i]).filter((it) => it && it.agent && it.agent.id).map((it) => it.agent);
    if (agents.length) out.set(e.key, { status: agentStatus(agents), agents: agentSort(agents) });
  }
  return out;
}
// State of the whole glow ring: any failure -> fail (still, reddish); otherwise any running -> run (breathing + sweep); all finished -> done (still .6)
export function agentStatus(list) {
  const ss = (list || []).map((a) => a.state);
  if (ss.includes("failed")) return "fail";
  if (ss.includes("running")) return "run";
  return "done";
}
// Back-side card order: failed -> running -> lost -> done, within a tier by dispatch order
export function agentSort(list) {
  const rank = (a) => (a.state in AG_ORDER ? AG_ORDER[a.state] : 3);
  return [...(list || [])].sort((a, b) => rank(a) - rank(b) || (isoToSec(a.startedAt) || 0) - (isoToSec(b.startedAt) || 0));
}
const agEnd = (a) => isoToSec(a.endedAt) || Number(a.lastAt) || 0;
function agMin(s) {
  s = Math.max(0, Math.floor(s));
  if (s < 60) return t("ag.lt1");
  const m = Math.floor(s / 60);
  return m < 60 ? t("ag.m", { m }) : t("ag.hm", { h: Math.floor(m / 60), m: m % 60 });
}
// Space between "total time" and the duration: Chinese "under 1 min" sits tight, the others get a space; English always gets a space
const agSp = (x) => (!isEn() && x === t("ag.lt1") ? x : " " + x);
export function agentClock(s) {
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = String(s % 60).padStart(2, "0");
  return h ? h + ":" + String(m).padStart(2, "0") + ":" + x : m + ":" + x;
}
// Token display in k: rounded at 10k and above, one decimal below
export function agentTok(n) {
  n = Number(n) || 0;
  if (n >= 10000) return Math.round(n / 1000) + "k";
  return (n ? (n / 1000).toFixed(1) : "0") + "k";
}
export function modelLabel(m) {
  const s = String(m || "").toLowerCase();
  for (const k of ["opus", "sonnet", "haiku", "fable"]) if (s.includes(k)) return k[0].toUpperCase() + k.slice(1);
  return s ? String(m).slice(0, 8) : t("ag.default");
}
// Back-side title: "N subagents" + "· ran 12 min · total 96k" (when all finished, write "total time")
export function agentBackTitle(list, now) {
  const ls = list || [];
  const starts = ls.map((a) => isoToSec(a.startedAt)).filter(Boolean);
  const t0 = starts.length ? Math.min(...starts) : now;
  const run = ls.some((a) => a.state === "running");
  const t1 = run ? now : Math.max(t0, ...ls.map(agEnd));
  const tok = ls.reduce((n, a) => n + (Number(a.tokens) || 0), 0);
  return { n: ls.length === 1 ? t("ag.n1") : t("ag.n", { n: ls.length }), rest: "· " + t(run ? "ag.ran" : "ag.took") + agSp(agMin(t1 - t0)) + " · " + t("ag.total", { v: agentTok(tok) }) };
}
// Top right of the card: running 12:34 (ticks every second) / took 8 min / failed · 3 min / no activity · 40 min (since the last record write)
export function agentCardTime(a, now) {
  const t0 = isoToSec(a.startedAt) || agEnd(a);
  if (a.state === "running") return t("ag.running", { t: agentClock(now - t0) });
  if (a.state === "gone") return t("ag.gone", { t: agMin(now - (Number(a.lastAt) || now)) });
  const d = agMin(agEnd(a) - t0);
  if (a.state === "failed") return t("ag.failed", { t: d });
  return t("ag.used") + agSp(d);
}
// Height needed by the back side: top margin 8 + title 28 + list top/bottom 16 + min(n,5) cards (66 high, 6 between)
// Measured values may be passed in, m={hd title height, card card height, gap card spacing}; the back height counts only "title + cards" and is independent of the front
export function agentBackH(n, m) {
  const k = Math.max(1, Math.min(n, 5)), hd = (m && m.hd) || 28, card = (m && m.card) || 66, gap = m && m.gap != null ? m.gap : 6, ft = (m && m.ft) || 28;
  return 8 + hd + 16 + k * card + (k - 1) * gap + ft; // the 28 "tap to flip back" bar at the bottom is included in the back
}
// Where does a tap flip back? kind = card (small card, enters the subagent page) / head / list (gaps between cards, margins) / back (other blank space); with more than 5 cards the list is a scroll area and does not flip
export function agentBackFlips(kind, n) { if (kind === "card") return false; if (kind === "list") return n <= 5; return true; }
// Subagent read-only chat page: grouped like chatPlan, user (dispatch, the main session's words) -> main = the main session on the left, assistant/tool -> bot = the subagent itself
export function agentPagePlan(items) {
  const blocks = chatPlan(items || [], {});
  for (const b of blocks) {
    if (b.t !== "group") continue;
    b.who = b.who === "self" ? "bot" : "main";
  }
  return blocks;
}

// ---------- chat info page / in-conversation search / history before window switch ----------
const chPad = (n) => String(n).padStart(2, "0");
// Time in search results and dividers: today "09:05", this year "Oct 21 14:38", earlier years include the year
export function chTime(ts, now) {
  const ms = Date.parse(ts || "");
  if (Number.isNaN(ms)) return "";
  const d = new Date(ms);
  const n = new Date(now * 1000);
  const hm = chPad(d.getHours()) + ":" + chPad(d.getMinutes());
  if (d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate()) return hm;
  return (d.getFullYear() === n.getFullYear() ? fmtMD(d) : fmtYMD(d)) + (isEn() ? ", " : " ") + hm;
}
// Divider between the previous window and this one: via=continued is the same window continued after compaction, guess is a same-name inference
export function chSepText(win, now) {
  const tm = chTime(win && win.at, now);
  const guess = win && win.via === "guess";
  const what = t(win && win.via === "continued" ? "sep.continued" : "sep.prev");
  const inner = guess ? (tm ? tm + comma() + t("sep.guess") : t("sep.guess")) : tm;
  return "—— " + what + (inner ? paren(inner) : "") + (isEn() ? " ——" : "——");
}
// Query string of the chat record API: before (byte offset), from (previous window id), around (jump to a row)
export function chQuery(before, from, around) {
  const q = [];
  if (before != null) q.push("before=" + before);
  if (from) q.push("from=" + encodeURIComponent(from));
  if (around != null) q.push("around=" + around);
  return q.length ? "?" + q.join("&") : "";
}
// What "load earlier" should do: hist = { segs: previous windows already attached (near -> far, each with next), base: the bottom window (null = this window) };
// next = the paging cursor of the bottom window; wins = the chain of previous windows (near -> far). base: page the bottom window; seg: page the farthest previous window; win: attach a new window; end: reached the end
export function chOlderPlan(hist, next, wins) {
  const segs = (hist && hist.segs) || [];
  if (!segs.length && next != null) return { kind: "base" };
  if (segs.length) {
    const last = segs[segs.length - 1];
    if (last.next != null) return { kind: "seg", sid: last.sid, before: last.next };
  }
  if (!Array.isArray(wins) || !wins.length) return { kind: "end" };
  const from = segs.length ? segs[segs.length - 1].sid : (hist && hist.base) || null;
  const i = from ? wins.findIndex((w) => w.sid === from) : -1;
  if (from && i < 0) return { kind: "end" };
  const w = wins[i + 1];
  return w ? { kind: "win", win: w } : { kind: "end" };
}
const chNorm = (t) => String(t || "").replace(/\s+/g, "");
// Whether the text shown on a bubble (stripGuestTag / stripFrom already applied) is the original text of this record
export function chSameText(raw, shown) {
  const s = chNorm(shown).slice(0, 40);
  return !!s && chNorm(raw).includes(s);
}
// Index of the search hit in the loaded items (same role + ts, original text contains the hit fragment), -1 if none
export function chHitIndex(items, hit) {
  const core = chNorm(String(hit.snippet || "").replace(/^…|…$/g, "")).slice(0, 40);
  for (let i = items.length - 1; i >= 0; i--) {
    const it = items[i];
    if (it.role === hit.role && it.ts === hit.ts && chNorm(it.text).includes(core)) return i;
  }
  return -1;
}
// Speaker in search results: Agent uses the conversation short name, the user "Me", other conversations use the source name
export function chWho(hit, s, me, o) {
  if (hit.role === "assistant") return (s && plateOf(s)) || "Agent";
  if (hit.role === "peer") return hit.from || t("c.peer");
  const x = o || {};
  const byGuest = chHitGuest(hit); // a guest's words
  if (x.guest) return byGuest ? (me || guestName()) : t("c.admin");
  if (byGuest) return x.guestName || guestName();
  return me || t("c.me"); // my nickname
}
// Whether this hit was said by a guest: the server marks from="guest" (the summary may cut off the beginning), old data falls back to looking at the start of the summary
export function chHitGuest(hit) {
  return !!hit && hit.role === "user" && (hit.from === "guest" || GTS.some((r) => r.prefix.test(String(hit.snippet || ""))));
}
// Search result summary: strip the leading guest prefix (who said it is already on the name)
export function chHitText(snippet) {
  return stripGuestTag(snippet);
}

// ===== draft persistence (localStorage zbs.drafts), forward selection =====
const DRAFT_MAX_N = 100;    // how many conversations' drafts to keep at most
const DRAFT_MAX_LEN = 8000; // longest single draft (the server's send limit is 4000, leaving some extra for manual trimming)
export function draftsParse(str) {
  const m = new Map();
  let o = null;
  try { o = JSON.parse(str); } catch (e) { return m; }
  if (!o || typeof o !== "object" || Array.isArray(o)) return m;
  for (const [k, v] of Object.entries(o)) {
    if (typeof v !== "string" || !v.trim()) continue;
    m.set(k, v.slice(0, DRAFT_MAX_LEN));
    if (m.size >= DRAFT_MAX_N) break;
  }
  return m;
}
export function draftsDump(map) {
  const o = {};
  let n = 0;
  // newly written ones go at the end of the Map: when over the limit, drop the earliest
  const all = [...(map || new Map()).entries()].filter(([, v]) => typeof v === "string" && v.trim());
  for (const [k, v] of all.slice(-DRAFT_MAX_N)) { o[k] = v.slice(0, DRAFT_MAX_LEN); n++; }
  return JSON.stringify(o);
}
// Per-account storage key ("" = no confirmed account: keep in memory only, never write)
export function acctKey(base, acct) {
  return acct ? base + ":" + encodeURIComponent(String(acct)) : "";
}
export const LEGACY_DRAFTS_KEY = "zbs.drafts"; // old shared key (all accounts): dropped, never handed to another identity
// Drafts: unsent text per session, persisted under a per-account key so it survives page changes and restarts;
// empty text means delete; newly written drafts move to the end (the oldest is dropped past the limit)
export class DraftMap extends Map {
  constructor(key, storage) { super(); this.key = key || ""; this.storage = storage || null; }
  set(k, v) {
    super.delete(k);
    if (v != null && String(v).trim()) super.set(k, String(v));
    this.save();
    return this;
  }
  delete(k) {
    const had = super.delete(k);
    if (had) this.save();
    return had;
  }
  save() {
    if (!this.key || !this.storage) return;
    try { this.storage.setItem(this.key, draftsDump(this)); } catch (e) { /* private mode can't store: keep in memory only */ }
  }
  // dropLegacy: also remove the old shared key (call once the account is confirmed)
  static load(key, storage, dropLegacy) {
    const m = new DraftMap(key, storage);
    if (!storage) return m;
    if (dropLegacy) { try { storage.removeItem(LEGACY_DRAFTS_KEY); } catch (e) { /* ignore */ } }
    let raw = null;
    if (key) { try { raw = storage.getItem(key); } catch (e) { raw = null; } }
    for (const [k, v] of draftsParse(raw)) Map.prototype.set.call(m, k, v);
    return m;
  }
}
// ===== outbox: text sent but not yet confirmed delivered (persisted per account so a failed send survives a reload) =====
const OUTBOX_MAX = 50;
const OUTBOX_KEYS = ["text", "raw", "quote", "at", "body"];
export function outboxDump(map) {
  const o = {};
  for (const [sid, list] of (map || new Map()).entries()) {
    const keep = (list || []).filter((p) => p && !p.done && !p.items && typeof p.text === "string" && p.body && typeof p.body === "object")
      .slice(-OUTBOX_MAX).map((p) => { const q = {}; for (const k of OUTBOX_KEYS) if (p[k] !== undefined) q[k] = p[k]; return q; });
    if (keep.length) o[sid] = keep;
  }
  return JSON.stringify(o);
}
// Restored entries are always failed (delivery unknown): the user chooses resend / delete, nothing is sent automatically
export function outboxRestore(str) {
  const m = new Map();
  let o = null;
  try { o = JSON.parse(str); } catch (e) { return m; }
  if (!o || typeof o !== "object" || Array.isArray(o)) return m;
  for (const [sid, list] of Object.entries(o)) {
    if (!Array.isArray(list)) continue;
    const ok = list.filter((p) => p && typeof p.text === "string" && p.body && typeof p.body === "object" && !Array.isArray(p.body))
      .slice(-OUTBOX_MAX)
      .map((p) => ({ text: p.text, raw: typeof p.raw === "string" ? p.raw : p.text, quote: typeof p.quote === "string" ? p.quote : "",
        at: Number(p.at) || Date.now(), body: p.body, n0: 0, stage: "clock", failed: true }));
    if (ok.length) m.set(sid, ok);
  }
  return m;
}
export function draftPreview(text) {
  const t = oneLine(text);
  return t.length > 40 ? t.slice(0, 40) + "…" : t;
}
export function draftMerge(old, add) {
  const o = String(old == null ? "" : old);
  return o.trim() ? o + "\n" + add : add;
}
// Forward card: other claude conversations (excluding the current), filtered by name / short name / zone name (case-insensitive)
export function forwardTargets(sessions, curId, q, zones) {
  const k = String(q || "").trim().toLowerCase();
  const out = [];
  for (const s of sessions || []) {
    if (!s || s.kind !== "claude" || s.id === curId || !s.name) continue;
    const z = zoneFor(zones, s.zone);
    const x = { id: s.id, name: s.name, plate: plateOf(s), zoneName: z.name, zoneColor: z.color };
    if (k && ![x.name, x.plate, x.zoneName].some((v) => String(v || "").toLowerCase().includes(k))) continue;
    out.push(x);
  }
  return out;
}

// ---------- "Chat history" section of the outer global search ----------
export const GS_DELAY = 400; // how long after typing stops to search chat history (milliseconds)
export function gsReady(q) {
  return String(q || "").trim().length >= 2;
}
export function gsUrl(q) {
  return "/api/search?q=" + encodeURIComponent(String(q || "").trim()) + "&limit=60";
}
// /api/search groups -> list rows; conversations no longer in the snapshot are not shown (the server filters too, this guards against the snapshot having changed)
export function gsRows(data, snap) {
  const res = data && Array.isArray(data.results) ? data.results : [];
  const live = new Set(((snap && snap.sessions) || []).map((s) => s && s.id));
  const off = new Set(((snap && snap.offduty) || []).map((o) => o && o.sid));
  const out = [];
  for (const g of res) {
    if (!g || !g.sid || !(g.off ? off.has(g.sid) : live.has(g.sid))) continue;
    const hit = (Array.isArray(g.hits) && g.hits[0]) || {};
    out.push({
      sid: g.sid, off: !!g.off, name: g.name || "", zone: g.zone || "",
      plate: plateOf({ name: g.name || "", zone: g.zone || "" }),
      count: g.count || 0, countText: t("gs.count", { n: g.count || 0 }),
      snippet: hit.snippet || "", ts: hit.ts || g.last || "", prev: !!(hit.sid && hit.sid !== g.sid),
    });
  }
  return out;
}

// ---------- Blaze Mode flame on Fable conversation avatars ----------
// A Claude conversation's model appears in two places in the snapshot: s.model (orca --dump, e.g. "claude-fable-5-1") and s.meta.model (status bar, e.g. "Fable 5.1").
// If either, lowercased, contains "fable" there is a flame; busy = strong tier, the rest (idle / waiting / resting) = weak tier; no model, no flame. A guest snapshot also carries model (the backend GUEST_SESSION_FIELDS lets model through, and guestSnapshot leaves it alone), so guests get the flame too.
export function fireLevel(s) {
  if (!s || typeof s !== "object") return null;
  const ms = [s.model, s.meta && typeof s.meta === "object" ? s.meta.model : null];
  if (!ms.some((m) => typeof m === "string" && m.toLowerCase().includes("fable"))) return null;
  return s.status === "busy" ? "strong" : "weak";
}

// ===== my nickname and avatar =====
export function profileView(p) {
  // When the nickname was never changed, the server gives "Me" (DEFAULT_NAME in api/profile.py), shown in the current language (the newer server gives an empty value instead)
  const raw = (p && typeof p.name === "string" && p.name.trim()) || "";
  const isDefault = !raw || raw === RAW.me; // "never changed" is decided by the field, not by comparing the displayed name with translated text (a nickname that happens to be Me is not misjudged)
  const name = isDefault ? t("c.me") : raw;
  return { name, isDefault, url: p && p.avatar ? "/api/avatar?v=" + encodeURIComponent(String(p.v || 0)) : "" };
}
// The guest default nickname is not hardcoded: the default from /api/profile (the server reads GUEST_NAME from .env); if unavailable (old API, not yet fetched) use "Guest"
// The former constant GUEST_NAME is now the function guestName(), fetched for the current language on demand
export function guestName() { return t("c.guest"); }
export function guestDefaultName(p) {
  // If default equals the built-in default "Guest" (or empty), show it in the current language; any other value (GUEST_NAME configured in .env) as is
  const d = (p && typeof p.default === "string" && p.default.trim()) || "";
  return !d || d === RAW.guest ? guestName() : d;
}
// The guest bubble seen from the admin uses that guest's nickname and avatar (GET /api/profile?account=guest)
// account = which guest (the admin finds the bound guest by conversation, see guestFor; defaults to the first guest, "guest")
export function guestProfileView(p, account) {
  const name = (p && typeof p.name === "string" && p.name.trim()) || guestDefaultName(p);
  const acc = encodeURIComponent(String(account || "guest"));
  return { name, url: p && p.avatar ? "/api/avatar?account=" + acc + "&v=" + encodeURIComponent(String(p.v || 0)) : "" };
}
// The chosen image is center-cropped to a square, then scaled to size x size
export function avatarCrop(w, hgt, size = 160) {
  const side = Math.min(w, hgt);
  return { sx: Math.round((w - side) / 2), sy: Math.round((hgt - side) / 2), sw: side, sh: side, size };
}

// ===== figures keep roaming until the work is done =====
// Walkable range: use the figure's own segment (figLane) if wide enough; if too narrow (< 3px, common when crowded) use the whole band (figBand, left edge to right edge minus body width), allowing overlap with companions
export function figRoamRange(lane, band) {
  const [lo, hi] = lane;
  if (hi - lo >= 3) return [lo, hi];
  const blo = band[0];
  return [blo, Math.max(blo, band[1] - FIG.CW)];
}
// How to move next: working 7.webp at 12px/s; when running long (slow, beyond FIG_WAIT_SEC) the same row 7 with only the speed halved (there is no waiting row 6 for standing still). Other phases do not walk (null)
// Segment wide enough: walk back and forth to the other end; segment too narrow: pick a random point in the whole band
export function figRoam(phase, x, lane, band, rnd = Math.random, slow = false) {
  if (phase !== "working") return null;
  const [lo, hi] = figRoamRange(lane, band);
  let tx;
  if (lane[1] - lane[0] >= 3) tx = Math.abs(x - lo) < Math.abs(x - hi) ? hi : lo;
  else tx = lo + rnd() * (hi - lo);
  const ms = Math.max(300, Math.abs(tx - x) / 12 * 1000) * (slow ? 2 : 1); // working 12px/s; halved when running long (slow)
  return { tx, ms, strip: "7", rest: "7", pause: 1200 + rnd() * 1600 };
}

// Compare a bubble's geometry (relative to the overlay) with the last layout; if any side drifted more than tol px, re-layout (ResizeObserver cannot see "position changed but size did not", e.g. #older getting taller)
export function figDrift(prev, cur, tol = 1) {
  if (!prev || !cur) return false;
  return ["l", "r", "t", "b"].some((k) => Math.abs((cur[k] || 0) - (prev[k] || 0)) > tol);
}
// Group shift when parked figures change position. Distance <= 6px returns null (land directly);
// each 320-520ms, overshoot 1.3-1.8 (same curve as the bump), start staggered by position in the queue by 30-80ms (chain push, position capped at 6 so the head of the queue does not drag for seconds);
// beyond 12px horizontally use walking frames (1 for right, 2 for left), return to 7 on arrival; a small displacement only squashes and rebounds (strip is empty)
export function figGlide(dx, dy, i, rnd = Math.random) {
  if (Math.hypot(dx, dy) <= 6) return null;
  const walk = Math.abs(dx) > 12;
  return {
    ms: 320 + rnd() * 200,
    delay: Math.min(Math.max(0, i), 6) * (30 + rnd() * 50),
    over: (1.3 + rnd() * 0.5).toFixed(2),
    walk,
    strip: walk ? (dx > 0 ? "1" : "2") : "",
    rest: "7",
  };
}

// ---------- notification path and robustness ----------
// An "open" within this long after a swipe-back is swallowed as an accidental touch on release; opens from a notification / cold start / URL hash are not finger taps and are never swallowed
export const OPEN_SWALLOW_MS = 600;
const OPEN_NEVER_SWALLOW = ["notify", "launch", "hashchange"];
export function openSwallowed(from, sinceBackMs) {
  if (OPEN_NEVER_SWALLOW.includes(from)) return false;
  return sinceBackMs < OPEN_SWALLOW_MS;
}
// Shell version gate: when the sw replies shell-mismatch, reload once (the gate remembers which version it already reloaded for, and does not reload again for the same version, to prevent loops);
// reply shell-ok clears the gate. Returns { reload, gate } (gate null means clear)
export function shellGate(msg, gate) {
  const g = gate == null ? null : gate;
  if (!msg || typeof msg !== "object") return { reload: false, gate: g };
  if (msg.type === "shell-ok") return { reload: false, gate: null };
  if (msg.type !== "shell-mismatch") return { reload: false, gate: g };
  const v = String(msg.v || "");
  if (g === v) return { reload: false, gate: g };
  return { reload: true, gate: v };
}

// ---------- attachments ----------
// Get the file URL: inline uploaded images use sid+ref, guest uploads use tok, the rest use the host path p. t = thumb|full
// v = file version from the server (mtime_ns): after the same path is overwritten the URL changes with it, so the old version in the browser's 1-hour cache is not used (the server ignores v)
// dl = true: the server replies Content-Disposition: attachment and the browser downloads directly (non-ASCII names go through filename*)
export function fileUrl(f, sid, t = "full", dl = false) {
  const v = (dl ? "&dl=1" : "") + (f.v ? `&v=${encodeURIComponent(f.v)}` : "");
  // f.sid: an inline image in a previous-window record (before the window switch); the server stamps the ref item with the conversation id of the record it is actually in; this window's have none, use the current conversation id
  if (f.ref) return `/api/file?sid=${encodeURIComponent(f.sid || sid)}&ref=${encodeURIComponent(f.ref)}&t=${t}${v}`;
  if (f.tok) return `/api/file?tok=${encodeURIComponent(f.tok)}&t=${t}${v}`;
  return `/api/file?p=${encodeURIComponent(f.path)}&t=${t}${v}`;
}
// Attachment layout plan: 1 image single; 2-4 images 2 columns; 5-9 images 3 columns; files only = cards; neither = none
export function attachPlan(files) {
  const list = Array.isArray(files) ? files : [];
  const imgs = list.filter((f) => f.kind === "image");
  const cards = list.filter((f) => f.kind !== "image");
  if (imgs.length === 1) return { mode: "single", imgs, cards, cols: 1 };
  if (imgs.length >= 2) return { mode: "grid", imgs, cards, cols: imgs.length <= 4 ? 2 : 3 };
  return { mode: cards.length ? "cards" : "none", imgs, cards, cols: 1 };
}
// Single image size: height clamped to <= maxH, wPct is the max share of the container width, ratio is for aspect-ratio; without width and height give a 4:3 placeholder
export function singleBox(w, h, maxW = 0.68, maxH = 260) {
  if (!(w > 0) || !(h > 0)) return { wPct: maxW, h: 0, ratio: 4 / 3 };
  return { wPct: maxW, h: Math.min(h, maxH), ratio: w / h };
}
// After a single image loads, set the box by the original ratio: width = min(68vw, display height x ratio), display height = min(original height, 260); the height follows from aspect-ratio,
// so when a wide image is limited by 68vw the height shrinks with it, with no cropping. Invalid dimensions return null (keep the 4:3 placeholder)
export function singleFit(nw, nh, maxW = 0.68, maxH = 260) {
  if (!(nw > 0) || !(nh > 0)) return null;
  const ratio = nw / nh;
  return { ratio, width: `min(${Math.round(maxW * 100)}vw, ${Math.round(Math.min(nh, maxH) * ratio)}px)` };
}
// Broken-image retry (atBroken: attachment -> failure time): the first failure is recorded as "expired" (now - AT_RETRY_MS, so the next redraw retries once immediately), a further failure records the current time,
// after that the same attachment is retried at most once per AT_RETRY_MS (so a 404 does not trigger a request on every poll)
export const AT_RETRY_MS = 30000;
export function atBrokenNext(prev, now) { return prev === undefined ? now - AT_RETRY_MS : now; }
export function atRetryDue(t, now) { return t !== undefined && now - t >= AT_RETRY_MS; }
// The items to flip use getters, fetched for the current language on demand
export const KIND_LABEL = { pdf: "PDF", doc: "Word", get sheet() { return t("kind.sheet"); }, slide: "PPT", md: "Markdown", get text() { return t("kind.text"); }, get html() { return t("kind.html"); }, get data() { return t("kind.data"); } };
// Desktop (hover + fine pointer: Mac Dock web App, desktop browsers, iPad with an external keyboard and mouse)
export const DESK_MQ = "(hover: hover) and (pointer: fine)";
export function isDesktopPointer(mm = typeof matchMedia === "function" ? matchMedia : null) {
  try { return !!(mm && mm(DESK_MQ).matches); } catch (e) { return false; }
}
// What tapping a file card does: on desktop Word/Excel/PPT download directly ("download"); on phones the other native types (PDF and Office on phone) open in a new tab for system preview; md/txt and other in-site reader pages open in-app
export function fileOpenHow(kind, desktop) {
  const how = kindOpen(kind);
  return how === "native" && desktop && (kind === "doc" || kind === "sheet" || kind === "slide") ? "download" : how;
}
// Final action for tapping a file card. On phones native (PDF/Office) does not use window.open (a new view in a home-screen App has no login state and goes black); instead fetch the file in-page + system share sheet ("share")
export function fileTapAction(kind, desktop) {
  const how = fileOpenHow(kind, desktop);
  return how === "native" ? "share" : how;
}
// What to do when sharing did not complete. The user dismissed the sheet -> none; gesture expired (NotAllowedError) -> retry (cache the file, prompt to tap again); others (file sharing unsupported, file fetch error) -> download (invisible <a download>). Never open a new tab
export function shareFailPlan(errName) {
  if (errName === "AbortError") return "none";
  if (errName === "NotAllowedError") return "retry";
  return "download";
}
export function kindOpen(kind) {
  if (kind === "pdf" || kind === "doc" || kind === "sheet" || kind === "slide") return "native";
  if (kind === "html") return "html";
  return "reader";
}
export function fmtSize(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1048576) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1048576).toFixed(1)} MB`;
}
export function imgRefsOf(files) {
  return (Array.isArray(files) ? files : []).filter((f) => f.kind === "image");
}
// Viewer: image index when switching (no wrapping) and zoom factor (clamped 1-4)
export function vwNext(index, delta, n) {
  if (!(n > 0)) return 0;
  return Math.max(0, Math.min(n - 1, index + delta));
}
export function vwScale(prev, ratio) {
  return Math.max(1, Math.min(4, prev * ratio));
}
// Viewer: what this touch counts as when the finger lifts. moved is the max displacement, sinceLastTap is milliseconds since the last tap
// Taps at any zoom take part in double-tap detection; only at 1x are prev/next/close allowed
export function vwTapAction({ moved = 0, dt = 0, sinceLastTap = Infinity, scale = 1, dy = 0, dx = 0, n = 1 } = {}) {
  if (moved <= 10) return sinceLastTap < 300 ? "double" : "tap";
  if (scale > 1.01) return "none";
  if (Math.abs(dx) >= Math.abs(dy)) {
    if (n > 1 && Math.abs(dx) >= 50) return dx < 0 ? "next" : "prev";
    return "none";
  }
  return dy >= 80 ? "close" : "none";
}
// When a user message has attachments, the "[Image #N]" text left by Claude Code's image paste is removed from the displayed text (the thumbnail replaces it)
// Only the marker itself and one adjacent space (the following one preferred) are removed, other whitespace is kept as is; if only whitespace remains it counts as no text; a line holding only the marker leaves no blank line
export function stripImageMarks(text) {
  const s = String(text == null ? "" : text);
  if (!/\[Image #\d+\]/.test(s)) return s;
  const out = s.replace(/\[Image #\d+\] /g, "").replace(/ ?\[Image #\d+\]/g, "").replace(/^\n+|\n+$/g, "");
  return out.trim() ? out : "";
}
// ---------- no flicker when sending images: the pending bubble's local preview image is "handed over" to the record's one (same <img>, no new request) ----------
export function imageMarkCount(text) {
  const m = String(text == null ? "" : text).match(/\[Image #\d+\]/g);
  return m ? m.length : 0;
}
const carryImgs = (it) => (Array.isArray(it && it.files) ? it.files.filter((f) => f && f.kind === "image").length : 0);
// Whether this user entry can take over n handed-over images: it carries the same number of images (the official row), or has no files yet and only the same number of [Image #N] markers (the queued copy)
const carryFits = (it, n) => !!it && it.role === "user" && !it.recalled &&
  (carryImgs(it) === n || (carryImgs(it) === 0 && imageMarkCount(it.text) === n));
export const carryKey = (it) => [it.role, it.ts, it.text].join("|");
export const carryText = (it) => stripImageMarks(it && it.text).replace(/\s+/g, "").slice(0, 80);
// When a pending bubble (n0 = how many user entries preceded it at send time, nImg = how many images it carries) leaves, its images go to the n0-th user entry (index) in the records; -1 if they do not match (release them as usual)
export function carryTarget(items, n0, nImg) {
  if (!(nImg > 0) || !Array.isArray(items)) return -1;
  let k = 0;
  for (let i = 0; i < items.length; i++) {
    if (!items[i] || items[i].role !== "user") continue;
    if (k++ === n0) return carryFits(items[i], nImg) ? i : -1;
  }
  return -1;
}
// Which entry the handed-over images hang on this round (carries: [{ key, txt, ts, n }], returns each one's items index, -1 = not found this round):
// if the original entry (key) is still there, it is that one; if gone (the queued copy was replaced by the official row), find a user with ts no earlier than it, the same text after removing [Image #N], able to hold n images and not claimed by another
export function carryPlan(carries, items) {
  const list = Array.isArray(items) ? items : [];
  const used = new Set();
  const out = carries.map((c) => {
    const i = list.findIndex((it) => it && it.role === "user" && carryKey(it) === c.key && carryFits(it, c.n));
    if (i >= 0) used.add(i);
    return i;
  });
  return out.map((i, k) => {
    if (i >= 0) return i;
    const c = carries[k];
    const j = list.findIndex((it, x) => !used.has(x) && carryFits(it, c.n) && String(it.ts || "") >= String(c.ts || "") && carryText(it) === c.txt);
    if (j >= 0) used.add(j);
    return j;
  });
}
// Whether the address of a Markdown image ![](href) matches an image in this entry's files (recognizing the file:// prefix and %XX encoding); null if not
export function mdImgMatch(files, href) {
  if (!Array.isArray(files) || !href) return null;
  let h = String(href).replace(/^file:\/\//i, "");
  const cands = [h];
  try { const d = decodeURI(h); if (d !== h) cands.push(d); } catch (e) { /* bad encoding: compare as is only */ }
  return files.find((f) => f && f.kind === "image" && f.path && cands.includes(f.path)) || null;
}
// Guess the kind of a local attachment being sent from its file name (used only for the optimistic preview's small card)
export function kindByName(name) {
  const m = /\.([A-Za-z0-9]+)$/.exec(String(name || ""));
  const e = m ? m[1].toLowerCase() : "";
  if (/^(png|jpe?g|gif|webp|heic|heif|bmp|svg)$/.test(e)) return "image";
  if (e === "pdf") return "pdf";
  if (/^docx?$/.test(e)) return "doc";
  if (/^(xlsx?|csv|numbers)$/.test(e)) return "sheet";
  if (/^(pptx?|key)$/.test(e)) return "slide";
  if (/^(md|markdown)$/.test(e)) return "md";
  if (/^html?$/.test(e)) return "html";
  if (/^(json|ya?ml|xml|toml)$/.test(e)) return "data";
  return "text";
}

// ---------- file paths in the body -> clickable file name chips ----------
// Same convention as PATH_RE in the server's api/files.py: starts with /Users|/tmp|/private|/Volumes|~ plus /, contains no whitespace or "'`<>()[],
// ends with an allowlisted extension (a bare path does not accept json), and must not be directly adjacent to alphanumerics, _ or / on either side. The server uses lookbehind; here the previous character is checked by hand (old iOS does not support (?<!))
const CHIP_EXTS = "pptx|xlsx|docx|jpeg|webp|html|png|jpg|gif|svg|pdf|doc|xls|ppt|txt|htm|csv|md";
const CHIP_RE = new RegExp("(?:/(?:Users|tmp|private|Volumes)|~)/[^\\s\"'`<>()\\[\\]]+?\\.(?:" + CHIP_EXTS + ")(?![A-Za-z0-9_/])", "gi");
// /private/tmp and /tmp are equivalent (same as the server's Roots._match); the rest compare as written (the path in files is the body text as is anyway)
const chipKey = (p) => String(p).replace(/^\/private\/tmp(?=\/)/, "/tmp");
// Of this entry's files, those that can become chips: ones the server recognized from the body (src=text) that have a path; the guest side has only upload and is always empty
export function chipFiles(files) {
  return (Array.isArray(files) ? files : []).filter((f) => f && f.src === "text" && typeof f.path === "string" && f.path);
}
// Cut a text into [{t:"text",text} | {t:"chip",text:original,f}]; joining the texts gives back the original. Returns null if nothing can be replaced (the caller draws as is)
export function pathChips(text, files) {
  if (typeof text !== "string" || !text) return null;
  const cand = chipFiles(files);
  if (!cand.length) return null;
  const map = new Map();
  for (const f of cand) if (!map.has(chipKey(f.path))) map.set(chipKey(f.path), f);
  const out = [];
  let last = 0;
  CHIP_RE.lastIndex = 0;
  let m;
  while ((m = CHIP_RE.exec(text))) {
    const i = m.index;
    if (i > 0 && /[A-Za-z0-9_/]/.test(text[i - 1])) { CHIP_RE.lastIndex = i + 1; continue; } // lookbehind boundary does not hold: search again from the next character (same as the server trying each position)
    const f = map.get(chipKey(m[0]));
    if (!f) continue;
    if (i > last) out.push({ t: "text", text: text.slice(last, i) });
    out.push({ t: "chip", text: m[0], f });
    last = i + m[0].length;
  }
  if (!out.length) return null;
  if (last < text.length) out.push({ t: "text", text: text.slice(last) });
  return out;
}
// Attachments to draw at the bottom of a bubble: ones already drawn in place as Markdown images (inl) are not repeated; non-images that already have a chip in the body (chip) get no card again; image thumbnails still stay at the bottom
export function atBottom(files, inl, chip) {
  return (Array.isArray(files) ? files : []).filter((f) => !(f.path && inl && inl.has(f.path)) &&
    !(f.kind !== "image" && f.path && chip && chip.has(f.path)));
}
// Recalling a read message while the conversation is busy = the server presses Esc to interrupt this turn, so the admin must confirm first; guests (the server does not interrupt guests) and other cases are recalled directly
export const RECALL_ASK = { get q() { return t("recall.askQ"); }, get ok() { return t("recall.askOk"); } };
export function recallAsk(receipt, status, guest) {
  return receipt === "read" && status === "busy" && !guest;
}

// ===== pure logic of frontend error reporting (diagErr in app.js) =====
// Where errors are swallowed the fallback is kept and the error is also reported; this only decides whether to report and what: the same sentence at the same place is reported once within ERR_GAP_MS, at most ERR_MAX per page load
export const ERR_GAP_MS = 60000;
export const ERR_MAX = 20;
export function newErrGate() { return { seen: new Map(), n: 0 }; }
export function errGate(g, key, now) {
  if (!g || g.n >= ERR_MAX) return false;
  const last = g.seen.get(key);
  if (last != null && now - last < ERR_GAP_MS) return false;
  g.seen.delete(key); // re-insert: a Map keeps insertion order, so drop the oldest beyond the limit
  g.seen.set(key, now);
  while (g.seen.size > 100) g.seen.delete(g.seen.keys().next().value);
  g.n++;
  return true;
}
// One k:"err" diagnostic record: the message takes the first line cut to 300 characters, the stack takes the first 8 lines cut to 800 characters (small POST, carries no page content)
export function errEvent(where, err, now, extra) {
  const e = err == null ? "" : err;
  const msg = String((e && typeof e === "object" && "message" in e) ? e.message : e).split("\n")[0].slice(0, 300);
  const stack = e && typeof e === "object" && e.stack ? String(e.stack).split("\n").slice(0, 8).join("\n").slice(0, 800) : "";
  const name = e && typeof e === "object" && e.name ? String(e.name).slice(0, 40) : "";
  return { t: now, k: "err", where: String(where || "?").slice(0, 60), name, msg, stack, ...(extra || {}) };
}
// Attachment display name: for user inline images the backend gives a number n (which one), assembled per UI language as "Image N" (zh-Hans / zh-Hant / English);
// the rest (including inline images from an old backend giving only name) show name as is. Looks only at fields, not at text inside name
export function attName(f) {
  if (!f || typeof f !== "object") return "";
  const n = f.n;
  if (Number.isInteger(n) && n > 0) return t("at.imageN", { n });
  return typeof f.name === "string" ? f.name : "";
}
// Failure fetching an attachment is worded by status code: only truly gone (404/403/410) is "file no longer exists"; rate limit 429, server errors etc. are "load failed" (retryable)
export function fileFailKey(status) {
  return status === 404 || status === 403 || status === 410 ? "c.fileGone" : "c.loadFail";
}
