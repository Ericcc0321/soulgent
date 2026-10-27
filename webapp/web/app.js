// Soulgent web app frontend: chat list, chat page, Agents / dashboard / Me tabs and sheets. No framework; rows are reused
// by session id so pet animations aren't rebuilt on every poll.
import { ctxLevel, rowCtx, busyFx, walkFit, bannerStep, newBannerState, bannerStill, bannerText, chatTab, guestTab, guestSnapshot, guestBoundLabel, chatBadge, appBadgeOps, chatRow, chatSearch, hlParts, zoneChips, msgModel, contactsModel, plateOf, pushStatus, urlB64ToBytes, buildLanes, petState, usageColor, isoToSec, failReason, dropOnFail, cleanReplyText, nextPollAction, REQ_MAX_MS, askAnswerable, buildAskSteps, approveSteps, pollDelayMs, mergeItems, approveDefs, approveTarget, liveAskIndex, detailPollMs, cardChaseDone, CARD_CHASE_STEP_MS, pruneSent, partialFailText, offLine, offHeader, offPollDelayMs, WAKE_MAX_MS, nextWakeAction, wakeFailText, findAwake, applyOptimistic, busyClock, macLine, staleTags, busyText, awayFromBottom, countNewItems, nextNewCount, newBtnText, quotePreview, buildQuoteText, quoteHead, parseQuoted, receiptOf, canRecall, bubbleActs, recallLock, recallLockToast, summaryText, formatAlert, attName, menuPlace, forwardText, recallFailText, pressSwallow,imagePlan, uploadName, JPEG_QUALITY, addAttachments, canSend, uploadProgressText, plainUploadPath, buildSendBody, diagDesc, throttleStep, diagCap, meStats, shortDay, fmtTokens, fmtBytes, pressureInfo, diskInfo, loadInfo, swapInfo, memInfo, batteryInfo, monitorStale, freshText, zoneBoard, quotaRings, metaView, ctxPanel, ctxRows, ctxBreakdown, ctxAgeText, CTX_POLL_MS, CTX_MAX_MS, meterLevel, quotaCaption, swipeDecide, swipeSettle, swipeActions, rowMenuActs, rcTipText, applyFlagOpt, offFailText, nextDot, OFF_MAX_MS, WIDE_MQ, wideSplit, clampListW, LISTW_DEF, keepDetailOnTab, guestAutoOpen, pasteKind, speakerDir, speakerOf, speakerInitials, stripGuestTag, chatPlan, toolMark, taskStates, chatStamp, stripFrom, answeredRows, peerKey, figurePlan, toolClass, whoTags, agentGlowPlan, agentBackTitle, agentCardTime, agentTok, modelLabel, agentBackH, agentBackFlips, agentPagePlan, agentClock, pickFigure, avatarPick, sendUrl, pushSubBody, devPlat, newDevId, pushDevLine, actNow, seenAdd, presenceHeaders, presenceBody, deviceRows, deviceDelAsk, loginRows, loginRevokeAsk, askHasOwn, isPreviewQ } from "./logic.js";
import { reconcileFigures, resetFigures, tickFigures, holdLayout, setFigure, setFrozen } from "./figures.js";
import { macDown, orcaDown, kindTag, wbState, FLAME_ROWS, FIG_BUILTIN } from "./logic.js"; // status display
import { pendNeedsStamp, lastStampSec } from "./logic.js";
import { boardAsOf } from "./logic.js"; // dashboard page disconnected suffix
import { fireLevel } from "./logic.js"; // Fable flame
import { fxCalm } from "./logic.js"; // reduce effects while background work runs
import { chTime, chSepText, chQuery, chOlderPlan, chSameText, chHitIndex, chWho } from "./logic.js";
import { gsReady, gsUrl, gsRows, GS_DELAY } from "./logic.js"; // global search over chat history (outside the list)
import { parseMarkdown, tsvText } from "./md.js";
import { DraftMap, acctKey, outboxDump, outboxRestore, draftMerge, forwardTargets, profileView, avatarCrop } from "./logic.js";
import { guestProfileView, chHitText, chHitGuest } from "./logic.js"; // guest additions
import { setGuestTag, guestTag, withGuestTag, guestPendText, pickGuestTag, guestInitials } from "./logic.js"; // configurable guest prefix
import { openSwallowed, shellGate } from "./logic.js";
import { fileUrl, attachPlan, singleBox, singleFit, atBrokenNext, atRetryDue, KIND_LABEL, kindOpen, fileOpenHow, isDesktopPointer, fmtSize, imgRefsOf, stripImageMarks, mdImgMatch, kindByName, carryTarget, carryPlan, carryKey, carryText } from "./logic.js"; // attachments
import { pathChips, atBottom, recallAsk, RECALL_ASK } from "./logic.js"; // path chips in body text, recall-interrupt confirmation
import { recallDoneText, headStat } from "./logic.js"; // recall time window / header counts
import { bgLiveIds, helperSheet, bgJumpTu } from "./logic.js"; // background: fallback figure / helper list
import { chatAlert, busyLine, helperJumpOrder } from "./logic.js"; // errors / retrying / unexpected exit; list agent rows jump to the sub-agent tag first
import { avatarPose } from "./logic.js"; // avatar shows the idle frame while background work runs
import { newErrGate, errGate, errEvent, fileFailKey } from "./logic.js"; // error reporting, attachment failures by status code
import { guestDefaultName } from "./logic.js"; // guest default nickname comes from the `default` field of /api/profile
import { setGuestTags, guestFor, guestSlashBlocked, setGuestSlashCommands } from "./logic.js"; // multi-guest: admin recognizes all guest prefixes, looks up guest by session; guest slash-command allowlist
import { t, tCode, lang, langPref, saveLangPref, applyI18n, isEn, joinList, comma, paren, fmtMD, weekHeads, LANG_NAMES } from "./i18n.js"; // three languages
import { meCardAvatarKind } from "./logic.js"; // profile card avatar: a guest with no avatar gets an initial-letter square
import { fileTapAction } from "./logic.js"; // file card tap action (native on phone: fetch the file in-page + share sheet)
import { openViewer, shareFile, downloadFile } from "./viewer.js"; // fullscreen viewer (index.html loads the same module too, it runs only once); shareFile = save/share (shared with the viewer)

const POLL_MS = 2000;
const FETCH_TIMEOUT_MS = 5000;
const PETS_RETRY_MS = 60000;
const STALE_SEC = 30;
const LONG_PRESS_MS = 500;
const PULL_TRIGGER = 70;
const DETAIL_POLL_MS = 3000; // while the chat page is open, fetch the first page every 3 seconds
const AWAKE_WAIT_MS = 15000; // after a successful wake, wait up to 15 more seconds for a session with the same name to appear in the snapshot
const AFTER_SENT_MS = [500, 1500, 3000, 5000]; // refresh in sequence after a successful send
const BUSY_TICK_MS = 30000;  // the "working for X minutes" text in the placeholder bubble updates every 30 seconds (text only, no list redraw)
const MAX_UPLOAD = 20 * 1024 * 1024; // same as the server
const REPLY_MAX_H = 120;    // input box is at most 5 rows (22px x 5 + vertical padding)
const ROW = { waiting: "6", running: "7", waving: "3", idle: "0" };
const PEN_SVG = '<svg class="o-pen" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M14 6l4 4"/></svg>';

const $ = (sel) => document.querySelector(sel);
// desktop wide screen (mouse, wide enough): list + chat two-pane layout, styles in the matching @media at the end of style.css; always false on phones
const WIDE = window.matchMedia ? matchMedia(WIDE_MQ) : { matches: false };
const isWide = () => WIDE.matches;
// the list pane width is draggable on wide screens: divider .split-h, width stored in localStorage zbs.listw, double-click resets to 370
function initSplitDrag() {
  const h = document.createElement("div");
  h.className = "split-h"; h.setAttribute("aria-hidden", "true");
  document.body.appendChild(h);
  let cur = null;
  const apply = (w) => {
    cur = clampListW(w, window.innerWidth);
    document.body.style.setProperty("--lwu", cur + "px");
  };
  const save = () => { try { localStorage.setItem("zbs.listw", String(cur)); } catch {} };
  let saved = null;
  try { saved = localStorage.getItem("zbs.listw"); } catch {}
  if (saved !== null) apply(saved);
  window.addEventListener("resize", () => { if (cur !== null) apply(cur); });
  let drag = null;
  h.addEventListener("pointerdown", (e) => {
    if (!isWide() || e.button > 0) return;
    drag = { x: e.clientX, w: Math.round(h.getBoundingClientRect().left + 3 - (document.querySelector(".cr-tabbar") || h).getBoundingClientRect().right) };
    try { h.setPointerCapture(e.pointerId); } catch {}
    h.classList.add("drag"); document.body.classList.add("split-drag");
    e.preventDefault();
  });
  h.addEventListener("pointermove", (e) => { if (drag) apply(drag.w + e.clientX - drag.x); });
  const end = (e) => {
    if (!drag) return;
    drag = null;
    try { h.releasePointerCapture(e.pointerId); } catch {}
    h.classList.remove("drag"); document.body.classList.remove("split-drag");
    if (cur !== null) save();
  };
  h.addEventListener("pointerup", end);
  h.addEventListener("pointercancel", end);
  h.addEventListener("dblclick", () => { apply(LISTW_DEF); save(); });
}
function h(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
function setText(el, t) { if (el.textContent !== t) el.textContent = t; }

const st = {
  homeY: 0,             // home scroll position before opening the chat page
  pinBottomUntil: 0,    // deadline for staying pinned to the bottom while the keyboard is rising
  revealUntil: 0,       // deadline for keeping the bubble input above the keyboard while it is rising
  backAt: 0,            // time of the last swipe-back (prevents accidental taps on home rows when the finger lifts)
  snap: null,
  raw: null,            // raw server snapshot (snap has optimistic state layered on top)
  ctxSeq: 0,            // token for the context detail panel: when the panel is replaced or closed, the old poll stops
  pending: new Map(),   // sessions optimistically shown as busy after a successful send: sid -> { at, baseGen, orig }
  byId: new Map(),
  pets: {},
  petNames: [],
  petsKnown: "",        // decided once the pet manifest responds: "some" = has pets / "none" = no pets at all (avatar uses the flame); empty if no response yet
  petsTriedAt: 0,
  offline: false,
  down: false,          // Mac disconnected (offline or snapshot stale): whole page grayed out, timer frozen
  downAt: 0,            // moment of disconnection = generatedAt of the last snapshot
  timer: null,
  inflight: null,
  detailId: null,
  detailOff: null,      // read-only off-duty chat page: the current offduty entry (null for a normal chat page)
  waking: false,        // waking up
  dToken: 0,
  next: null,
  loading: false,
  sending: false,       // a message is being sent; no second one can be sent meanwhile, and the chat is not redrawn
  items: [],            // entries loaded on the chat page (oldest to newest)
  sig: "",              // signature of the last drawn content; no redraw if unchanged
  detailTimer: null,
  chase: null,        // progress of follow-up card fetches after a state change { id, t0, timer }
  pollQueued: false,  // another fetch was requested while the detail was loading: fetch once more when done
  ask: new Map(),       // choices in a bubble not yet sent: toolUseId -> { sel: [], txt: [] }
  sent: new Map(),      // bubbles whose keys were sent and are awaiting chat confirmation: toolUseId -> {} or { partial: steps sent }
  peerOpen: new Set(),  // cross-session messages (peerKey) the user expanded, kept expanded after redraw
  agFlip: new Set(),    // sub-agent bubbles flipped to the back side (figurePlan group key), kept across the 3-second redraw
  agentView: null,      // read-only sub-agent chat page: { sid, agentId, a, top, items, next, token, loading } (same #detail)
  agTimer: null,
  agToken: 0,
  figOpen: new Map(),   // row expanded by tapping the figure: tool tag key -> tool call id, restored after redraw
  outgoing: new Map(),  // text just sent but not yet in the transcript: sid -> [{ text, n0, at }] (drawn right away)
  drafts: new DraftMap("", null), // unsent drafts per session: memory only until the account is confirmed, then per-account storage (initAccountStores)
  shown: [],            // entries drawn last time in the chat area (to count how many are new)
  newCount: 0,          // number of entries that arrived while the user was away from the bottom
  quote: "",            // quote reply: the full quoted text
  clipUrl: "",          // thumbnail URL for the clipboard image card
  clipBlob: null,
  tray: [],             // attachment bar: { id, file, isImg, url, saved }
  busyTimer: null,
  queued: 0,            // number of my still-queued messages in the first detail page (queuedFor = which session)
  queuedFor: null,
  fmtWarn: "",          // formatWarn of the current first page (transcript format not fully understood; admin only)
  uploading: false,
  // chat room
  tab: "msg",           // msg / contacts / zones / me (remembered in localStorage zbs.tab)
  tabScroll: {},        // scroll position of each tab when leaving it
  zone: "all",          // zone filter of the message list
  restOpen: false,      // whether the "resting N" group is expanded
  searching: false,
  q: "",
  crSig: {},            // contacts / search / me / zone: signature drawn last time; no redraw if unchanged
  push: null,           // notification state (state of pushStatus; null = not checked yet)
  macLine: null,        // message-page status line text (long / short variants; the short one is used when space is tight)
  flagOpt: new Map(),   // optimistic display for left-swipe "mark unread/read, rest/return": id -> { at, unread?, rest? }
  swipeId: null,        // the row currently open by left swipe (only one at a time)
  swipeEat: 0,          // just swiped or collapsed: clicks before this don't open a session (ms timestamp)
  offing: new Set(),    // id of the session going off duty
  tabTapAt: 0,          // time of the last tap on the already-selected "SoulChat" tab (to detect a double tap)
  tabTapY: 0,           // scroll position at that time
  dotLast: null,        // red-dot row last jumped to by double tap
  // guest mode (guest account): sees only the one bound session; cannot answer/approve/manage; read state is stored locally only
  guest: false,
  // admin: guest list (guests from /api/auth/me: {account, tag, session}), each guest's nickname and avatar (account -> {p, url, key}),
  // prefix of the guest on the current chat page (the letters on the avatar square)
  guests: [],
  gpf: {},
  guestTagCur: "",
  bound: "",            // full name of the bound session (from /api/auth/me)
  account: "",          // current account (/api/auth/me; the last confirmed one when offline): snapshot request header X-Zbs-Acct
};
// guest read state: time of the last seen activity (seconds). The key name is the storage name given by the server (store in /api/auth/me; old deployments keep the old name,
// so read state isn't lost across versions); set by loadAccount
let guestSeenKey = "zbs.guestSeen";
const ACCOUNT_KEY = "zbs.account";      // last confirmed account (used on offline start)
const DRAFTS_KEY = "zbs.drafts";        // per-account suffix is added by acctKey; the bare key is the old shared one (dropped on first load)
const OUTBOX_KEY = "zbs.outbox";        // unconfirmed outgoing text per account (survives a reload as failed)
// Drafts and the outbox are account-scoped: load only once the account is known, empty them on logout so nothing leaks to the next identity
function initAccountStores(acc) {
  let ls = null;
  try { ls = localStorage; } catch (e) { ls = null; }
  st.drafts = DraftMap.load(acctKey(DRAFTS_KEY, acc), ls, !!acc);
  st.outgoing = new Map();
  const key = acctKey(OUTBOX_KEY, acc);
  if (!key || !ls) return;
  try { st.outgoing = outboxRestore(ls.getItem(key)); } catch (e) { /* unreadable: start empty */ }
}
function clearAccountStores() {
  st.drafts = new DraftMap("", null);
  st.outgoing = new Map();
}
// Persist unconfirmed text sends (not-done, no attachments); call after every change to a pend's state
function outboxSave() {
  const key = acctKey(OUTBOX_KEY, st.account);
  if (!key) return;
  try {
    const raw = outboxDump(st.outgoing);
    if (raw === "{}") localStorage.removeItem(key); else localStorage.setItem(key, raw);
  } catch (e) { /* private mode / quota: memory only */ }
}

// ---------- error reporting not gated by the "diagnostic log" switch ----------
// Where an error is swallowed, keep the user-facing degradation (plain text, "load failed", ...) and also call diagErr: console.error + one k:"err" record POSTed to /api/diag
// (view with tools/diag.sh on the Mac). Throttling/dedup/truncation live in logic.js (errGate/errEvent).
// Guests report as usual (the server accepts only whitelisted fields of k:"err", rate-limits by source, and records account=guest); before the account is confirmed, reports are queued (up to ERR_MAX).
// Does not go through api() (a 401 would redirect to the login page); if reporting itself fails, give up without reporting again. viewer.js / md.js can't import this file, so they dispatch an sg-err event
const ERR = { gate: newErrGate(), sid: "e" + Math.random().toString(36).slice(2, 10), wait: [], acct: false };
function diagErr(where, err) {
  try { console.error("[soulgent] " + where, err); } catch (e) { /* ignore */ }
  try {
    const now = Date.now();
    const ev = errEvent(where, err, now, { shell: shellVer(), lang: lang(), path: location.hash ? "#…" : location.pathname });
    if (!errGate(ERR.gate, ev.where + "|" + ev.msg, now)) return;
    if (!ERR.acct) { ERR.wait.push(ev); return; }
    errSend([ev]);
  } catch (e) { /* reporting itself failed: ignore */ }
}
function errSend(events) {
  if (!events.length) return;
  fetch("/api/diag", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session: D ? D.sid : ERR.sid, events }) }).catch(() => {});
}
function errAccountReady() { // called once loadAccount knows who the user is: flush the queued reports
  ERR.acct = true;
  const w = ERR.wait.splice(0);
  errSend(w);
}
function shellVer() {
  const m = document.querySelector('meta[name="zbs-shell"]');
  return m ? m.getAttribute("content") || "" : "";
}
addEventListener("error", (e) => { if (e && (e.error || e.message)) diagErr("window.error", e.error || new Error(String(e.message) + " @" + (e.filename || "") + ":" + (e.lineno || 0))); });
addEventListener("unhandledrejection", (e) => { const r = e && e.reason; if (!(r && r.message === "auth")) diagErr("rejection", r); });
addEventListener("sg-err", (e) => { const d = (e && e.detail) || {}; diagErr(d.where || "module", d.err); });

// ---------- network ----------
function goLogin() { location.replace("/login.html"); }

// timeoutMs: abort on timeout and let the caller treat it as offline (the Service Worker answers from cache after 3.5 s; this is slightly longer as a fallback)
async function api(path, opts, timeoutMs) {
  const ctl = timeoutMs ? new AbortController() : null;
  const timer = ctl ? setTimeout(() => ctl.abort(), timeoutMs) : 0;
  let res;
  try {
    res = await fetch(path, Object.assign({ credentials: "same-origin", cache: "no-store" },
      opts, ctl ? { signal: ctl.signal } : null));
  } finally {
    clearTimeout(timer);
  }
  if (res.status === 401 || (res.redirected && res.url.indexOf("/login.html") >= 0)) {
    goLogin();
    throw new Error("auth");
  }
  return res;
}
function post(path, body, timeoutMs) {
  return api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  }, timeoutMs);
}

async function loadPets() {
  st.petsTriedAt = Date.now();
  let res = null;
  try {
    res = await api("/pets/manifest.json", null, FETCH_TIMEOUT_MS);
    if (res.ok) st.pets = await res.json();
  } catch (e) { res = null; /* network down / manifest broken: usable without pets */ }
  // Pick the tool figure: the pet in the manifest that has `figure` -> else the first complete one -> if the manifest is missing or empty use the built-in flame.
  // Decided only once a response arrives (including 404); on network errors leave it undecided and retry later (so a pet user doesn't see a flame flash first)
  // errors in picking/switching the figure are code bugs, don't swallow them together with "no network"
  if (res) { try { setFigure(pickFigure(res.ok ? st.pets : {})); } catch (e) { diagErr("loadPets.figure", e); } }
  st.petNames = Object.keys(st.pets).sort();
  // same criterion for the avatar fallback: decide whether pets exist only once a response arrives (including 404)
  if (res) st.petsKnown = st.petNames.length ? "some" : "none";
}

function refresh() {
  if (st.inflight) return st.inflight;
  st.inflight = (async () => {
    try {
      let snap;
      try {
        // carries the device id, whether in use, and banner report (the server uses it to decide whether to send a system notification); only counts as delivered once a real snapshot is received
        const sent = PR.seen.slice();
        const hd = presenceHeaders(devId(), actApp(), sent);
        if (st.account) hd["X-Zbs-Acct"] = st.account; // the sw uses it to fetch this account's offline snapshot (stored separately per account)
        const res = await api("/api/snapshot", { headers: hd }, FETCH_TIMEOUT_MS);
        if (!res.ok) throw new Error("http " + res.status);
        snap = await res.json();
        st.offline = res.headers.get("X-Zbs-Cache") === "1";
        if (res.ok && !st.offline) PR.seen = PR.seen.filter((k) => !sent.includes(k));
        // the pet manifest was not fetched on offline start; fetch it after recovery; if it fails, don't retry for one minute
        if (!st.petNames.length && !st.offline && Date.now() - st.petsTriedAt > PETS_RETRY_MS) await loadPets();
      } catch (e) {
        if (e.message === "auth") return;
        st.offline = true;
        if (st.snap) renderNotice(); else renderNoConn();
        return;
      }
      // data was fetched but drawing failed: that's not a disconnection, so report it instead of showing "disconnected"
      try { applySnapshot(snap); } catch (e) { diagErr("applySnapshot", e); }
    } finally {
      st.inflight = null;
    }
  })();
  return st.inflight;
}

// idempotent: if already polling, don't start a second timer
function startPolling() {
  if (st.timer) return;
  refresh();
  st.timer = setInterval(refresh, POLL_MS);
}
function stopPolling() {
  if (st.timer) clearInterval(st.timer);
  st.timer = null;
}

// ---------- tell the server whether this device is in use ----------
// No new heartbeat: the foreground snapshot poll carries X-Zbs-Dev / X-Zbs-Act / X-Zbs-Seen; on switching away (hidden / pagehide / desktop blur) send one sendBeacon.
// If the in-use device showed a banner or is viewing that session, it reports it and the server stops sending system notifications (if nothing is reported within 12 seconds, push as usual)
const PR = { seen: [], lastInput: 0, beaconAct: null, beaconAt: 0 };
function actApp() {
  return actNow(devInfo().plat, !document.hidden, document.hasFocus(), PR.lastInput, Date.now());
}
function seenMark(id, kind) {
  PR.seen = seenAdd(PR.seen, id, kind);
}
function presenceBeacon() {
  if (!navigator.sendBeacon) return;
  const act = actApp();
  const seen = PR.seen.slice();
  // hidden, pagehide and blur often fire together: send at most once per 1.5 seconds for the same state (send anyway if there is a report to carry)
  if (!seen.length && act === PR.beaconAct && Date.now() - PR.beaconAt < 1500) return;
  try {
    if (navigator.sendBeacon("/api/presence", presenceBody(devId(), act, seen))) {
      PR.seen = PR.seen.filter((k) => !seen.includes(k));
      PR.beaconAct = act;
      PR.beaconAt = Date.now();
    }
  } catch (e) { /* send failed: the server also treats the device as gone after 8 seconds without a poll */ }
}
function initPresence() {
  const mark = () => { PR.lastInput = Date.now(); };
  for (const ev of ["pointerdown", "keydown", "wheel", "touchstart"]) addEventListener(ev, mark, { passive: true, capture: true });
  // desktop: on window blur tell the server immediately (earlier actions no longer count as "active within 60 seconds"; only scrolling / clicking in this window afterwards does)
  addEventListener("blur", () => { PR.lastInput = 0; presenceBeacon(); });
  addEventListener("pagehide", () => presenceBeacon());
}

// guest: recompute the red dots from local read state; a session being viewed counts as seen once it stops
function guestView(raw) {
  let seen = null;
  try { seen = localStorage.getItem(guestSeenKey); } catch (e) { seen = null; }
  const viewing = st.detailId && !document.hidden ? st.detailId : null;
  const g = guestSnapshot(raw, seen == null ? null : Number(seen), viewing, st.bound);
  if (g.seenAt != null && String(g.seenAt) !== seen) { try { localStorage.setItem(guestSeenKey, String(g.seenAt)); } catch (e) { /* can't store: recompute every time */ } }
  return g.snap;
}

// app icon badge: the number is the same chatBadge as the tab bar red dot (guests computed from the guest's own snapshot); silently skipped on unsupported browsers
function syncAppBadge(snap) {
  try {
    const nav = navigator;
    const n = snap ? chatBadge(snap) : 0;
    const o = appBadgeOps(n, nav);
    if (o.op === "set") nav.setAppBadge(o.n).catch(() => {});
    else if (o.op === "clear") nav.clearAppBadge().catch(() => {});
  } catch (e) { /* a badge failure must not affect the main flow */ }
}

function applySnapshot(raw) {
  const o = applyOptimistic(st.guest ? guestView(raw) : raw, st.pending, Date.now());
  const f = applyFlagOpt(o.snap, st.flagOpt, Date.now());
  st.raw = raw;
  st.pending = o.pending;
  st.flagOpt = f.opt;
  const snap = f.snap;
  const prev = st.detailId ? st.byId.get(st.detailId) : null;
  const oldById = st.byId;
  st.snap = snap;
  st.byId = new Map((snap.sessions || []).map((s) => [s.id, s]));
  diagWaitSeen(oldById, snap);
  render(); // render -> renderChat -> renderBadge also syncs the app icon badge
  runBanner(snap);
  if (!document.hidden && !snap.stale) closeStaleNotifs(snap.sessions || []);
  if (st.agentView) {
    // sub-agent page is open: header and input bar belong to it; refill them when the main chat returns
  } else if (st.detailOff) {
    const o = (snap.offduty || []).find((x) => x.sid === st.detailOff.sid);
    if (o) { st.detailOff = o; fillOffHeader(o); }
  } else if (st.detailId) {
    const s = st.byId.get(st.detailId);
    if (s) {
      fillDetailHeader(s, false);
      // session state changed (e.g. started waiting for you): fetch immediately, and re-fetch every 0.5 seconds until the card appears (up to 3 seconds), without waiting for the timed poll
      if (prev && prev.status !== s.status) chaseCard();
    }
  }
  deskAuto();
}

// ---------- pets ----------
function hash(str) {
  let x = 5381;
  for (let i = 0; i < str.length; i++) x = ((x << 5) + x + str.charCodeAt(i)) | 0;
  return Math.abs(x);
}
function petName(s) {
  if (s.pet && st.pets[s.pet]) return s.pet;
  if (!st.petNames.length) return null;
  return st.petNames[hash(String(s.id)) % st.petNames.length];
}
function setPet(el, s) {
  const name = petName(s);
  const state = avatarPose(s); // follow only the main turn; background work doesn't switch the working frame
  const pick = avatarPick(s, name, st.petsKnown);
  const key = name + "/" + state + "/" + pick.kind;
  if (el.dataset.k === key) return; // leave it alone if unchanged, so the animation doesn't restart
  el.dataset.k = key;
  el.classList.toggle("rest", state === "rest");
  el.classList.toggle("pet-flame", pick.kind === "flame");
  if (!name) {
    // no pet installed: the flame changes expression by state (single image, no frame animation)
    el.style.backgroundImage = pick.kind === "flame" ? 'url("' + pick.src + '")' : "";
    el.removeAttribute("data-n");
    return;
  }
  const base = "/pets/" + encodeURIComponent(name) + "/";
  if (state === "rest") {
    el.style.backgroundImage = 'url("' + base + 'still.webp")';
    el.removeAttribute("data-n");
    return;
  }
  const row = ROW[state];
  const n = Math.max(1, Math.min(8, Number((st.pets[name] || {})[row]) || 1));
  el.style.backgroundImage = 'url("' + base + row + '.webp")';
  if (n > 1) el.dataset.n = String(n); else el.removeAttribute("data-n");
}

// pause animation of off-screen list rows
const io = "IntersectionObserver" in window
  ? new IntersectionObserver((entries) => {
    for (const e of entries) e.target.classList.toggle("off", !e.isIntersecting);
  }, { rootMargin: "40px" })
  : null;

// ---------- home rendering ----------
function hhmm(sec) {
  const d = new Date(sec * 1000);
  return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
}
function nowSec() {
  return st.snap && st.snap.serverNow ? st.snap.serverNow : Math.floor(Date.now() / 1000);
}
function zoneOf(code) {
  return (st.snap.zones || []).find((z) => z.code === code) || { name: t("c.unzoned"), color: "#8A8F98" };
}

function render() {
  const snap = st.snap;
  if (!snap) return;
  renderNotice();
  renderChat();
}

function renderNotice() {
  const snap = st.snap;
  if (!snap) return;
  const stale = !!snap.stale || nowSec() - snap.generatedAt > STALE_SEC;
  const down = macDown(snap, st.offline, nowSec());
  applyDown(down, Number(snap.generatedAt) || 0, down ? macLine(snap, { offline: st.offline, stale, at: hhmm(snap.generatedAt) }).text : "");
  let text = "";
  if (st.offline) text = t("notice.offline", { t: hhmm(snap.generatedAt) });
  else if (stale) text = t("notice.stale", { t: hhmm(snap.generatedAt) });
  // guest: no Mac/Orca/quota row; use it only to show a hint when offline or data is stale
  if (st.guest) {
    $("#cr-mac").hidden = !text;
    $("#cr-mac-dot").className = "cr-macdot off";
    setText($("#cr-mac-t"), text);
    $("#cr-quota").replaceChildren();
    st.macLine = null;
    return;
  }
  // the message page uses a gray status line instead of a yellow bar
  $("#cr-mac").hidden = false;
  const ml = macLine(snap, { offline: st.offline, stale, at: hhmm(snap.generatedAt) });
  $("#cr-mac-dot").className = "cr-macdot " + ml.dot;
  renderQuota(snap.usage);
  st.macLine = ml;
  fitMacLine();
}
// if the left text doesn't fit (the right side carries the quota countdown), shrink to "Orca ✓"; if still too wide, replace the countdown with a short form keeping only the largest unit
function fitMacLine() {
  const ml = st.macLine;
  const el = $("#cr-mac-t");
  if (!ml) return;
  const over = () => el.clientWidth && el.scrollWidth > el.clientWidth + 1;
  $("#cr-mac").classList.remove("qt-c");
  setText(el, ml.text);
  if (!over()) return;
  setText(el, ml.short);
  if (over()) $("#cr-mac").classList.add("qt-c");
}

// small usage ring: SVG circle drawn clockwise from 12 o'clock; only assembles numbers, never touches user data
function ringSvg(pct, size, sw) {
  const c = size / 2;
  const r = c - sw / 2;
  const len = 2 * Math.PI * r;
  const on = len * Math.max(0, Math.min(100, pct)) / 100;
  return '<svg class="rg" width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + " " + size + '" aria-hidden="true">' +
    '<circle class="rg-t" cx="' + c + '" cy="' + c + '" r="' + r + '" stroke-width="' + sw + '"/>' +
    (on > 0 ? '<circle class="rg-f" cx="' + c + '" cy="' + c + '" r="' + r + '" stroke-width="' + sw +
      '" stroke-dasharray="' + on.toFixed(2) + " " + len.toFixed(2) + '" transform="rotate(-90 ' + c + " " + c + ')"/>' : "") +
    "</svg>";
}

// right side of the message-page status line: two small rings for 5H / 7D; no redraw if data is unchanged
function renderQuota(usage) {
  const box = $("#cr-quota");
  const rings = quotaRings(usage, nowSec());
  const key = JSON.stringify(rings);
  if (box.dataset.k === key) return;
  box.dataset.k = key;
  box.replaceChildren(...rings.map((q) => {
    const el = h("span", "cr-q " + q.lv);
    el.insertAdjacentHTML("afterbegin", ringSvg(q.pct, 15, 2));
    el.append(h("span", "cr-ql", q.label), h("span", "cr-qp", q.pct + "%"));
    if (q.left) el.append(h("span", "cr-qt", q.left), h("span", "cr-qt cr-qtc", q.leftC)); // time until recovery: both the full and the shortened forms are kept, and fitMacLine picks one by width
    return el;
  }));
  box.setAttribute("aria-label", rings.map((q) => t("quota.aria", { label: q.label, pct: q.pct }) + (q.left ? t("quota.ariaLeft", { t: q.left }) : "")).join(comma()));
}

// no snapshot yet and the fetch failed: the message tab shows "can't connect" with a retry button
function renderNoConn() {
  const li = h("li", "cr-empty");
  li.append(h("b", null, t("empty.noConn")), document.createTextNode(t("empty.noConnSub")));
  const btn = h("button", null, t("c.retry"));
  btn.type = "button";
  btn.onclick = () => refresh();
  li.append(btn);
  $("#cr-msgs").replaceChildren(li);
}

// only move nodes when the order changed (moving restarts animations)
function syncChildren(parent, want) {
  const cur = parent.children;
  if (cur.length === want.length && want.every((w, i) => cur[i] === w)) return;
  want.forEach((w, i) => { if (parent.children[i] !== w) parent.insertBefore(w, parent.children[i] || null); });
  while (parent.children.length > want.length) parent.lastElementChild.remove();
}

// ---------- chat room: messages / contacts / search / me ----------
// row text always uses textContent; innerHTML only for the fixed icons below.
const MUTE_SVG = '<svg class="cr-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-label="' + t("svg.mute") + '"><path d="M9 18a3 3 0 006 0M18 14V10a6 6 0 00-9.3-5M6 10v4l-2 3h12M3 3l18 18"/></svg>';
const PIN_ROW_SVG = '<svg class="cr-ic" viewBox="0 0 24 24" fill="currentColor" aria-label="' + t("svg.pinned") + '"><path d="M15 3l6 6-3 1-3.5 3.5L14 18l-2 1-3.5-3.5L4 20l-.5-.5L7.5 15 4 11.5l1-2 4.5-.5L13 5.5z"/></svg>';
const MOON_SVG = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.5A8 8 0 019.5 4a8 8 0 1010.5 10.5z"/></svg>';
const CLOCK_SVG = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="8"/><path d="M12 8v4.5l3 2"/></svg>';
const PIN_W_SVG = '<svg width="20" height="20" viewBox="0 0 24 24" fill="#fff"><path d="M15 3l6 6-3 1-3.5 3.5L14 18l-2 1-3.5-3.5L4 20l-.5-.5L7.5 15 4 11.5l1-2 4.5-.5L13 5.5z"/></svg>';
const MOON_W_SVG = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.5A8 8 0 019.5 4a8 8 0 1010.5 10.5z"/></svg>';
const CHEV_SVG = '<svg class="cr-chev" viewBox="0 0 24 24" width="16" height="16"><path d="M9 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
// title is fetched for the current language when needed (the dashboard cell)
const TAB_TITLE = { msg: "Soulgent", get contacts() { return t("tab.agents"); }, get zones() { return t("tab.zones"); }, get me() { return t("tab.me"); } };

function svgEl(markup) {
  const t = document.createElement("template");
  t.innerHTML = markup; // pass only the fixed constants above
  return t.content.firstChild;
}
// strip the ↔ / ⚙ symbols from the peer note text
function quietNote(t) {
  return String(t).replace(/^[\s↔⚙️⚙]+/u, "");
}
function initials(plate) {
  const p = String(plate).split("-")[0] || String(plate);
  const m = p.match(/^[A-Za-z0-9&]+/);
  return m ? m[0].slice(0, 2).toUpperCase() : p.slice(0, 1);
}
function hlInto(parent, text, q) {
  for (const p of hlParts(text, q)) parent.append(p.hit ? h("mark", null, p.t) : document.createTextNode(p.t));
}

// avatar: zone-colored square + pixel pet (setPet), first letter when there is no pet; badge wait / dot / live
// Each pet is wrapped in a fixed .cr-pin layer: the busy-effect moves (appear / shocked / look up) act on this layer's transform so they don't fight the .pet frame animation for `animation`;
// create it up front, since moving .pet into it later would restart the frame animation (moving nodes does that)
function makeAv() {
  const av = h("div", "cr-av");
  const clip = h("div", "cr-clip");
  const pin = h("div", "cr-pin");
  const pet = h("div", "pet");
  pin.append(pet);
  const ini = h("span", "cr-ini");
  clip.append(pin, ini);
  const badge = h("i");
  av.append(clip, badge);
  av._p = { clip, pet, ini, badge };
  return av;
}
function fillAv(av, s, o) {
  const p = av._p;
  let cls = "cr-av";
  if (o.lead) cls += " lead";
  if (o.rest) cls += " rest";
  if (o.off) cls += " off";
  if (av.className !== cls) av.className = cls;
  av.style.setProperty("--zc", o.color || "#8A8F98");
  av.style.setProperty("--nd", -(hash(String(s.id)) % 3000) / 1000 + "s"); // the "waiting for you" urgent shake is staggered per session (negative delay = start mid-cycle)
  setPet(p.pet, s);
  const has = avatarPick(s, petName(s), st.petsKnown).kind !== "ini";
  p.pet.hidden = !has;
  p.ini.hidden = has;
  setText(p.ini, initials(o.plate));
  const b = o.badge || "";
  if (p.badge.dataset.k !== b) {
    p.badge.dataset.k = b;
    const red = b === "wait" || b === "dot"; // both waiting-for-you and replied-to-you show as a red dot on the avatar's top-right corner; working shows no badge
    p.badge.className = red ? "cr-dot" : "";
    p.badge.hidden = !red;
  }
  syncFire(av, av.firstChild, fireLevel(s)); // the Fable flame sits at the very bottom (under the zone effect's outer frame and under the pet)
}

// One message row: the avatar, first line (name / track / time) nodes are all kept and only text is swapped,
// because the busy-effect track and the timer's "bounce" animation hang on these nodes; rebuilding would restart them and desync from the thrown item
function makeMsgLi(id) {
  const li = h("li");
  const row = h("button", "cr-row");
  row.type = "button";
  row.dataset.id = id;
  const av = makeAv();
  const body = h("div", "cr-body");
  const l1 = h("div", "cr-l1");
  const nm = h("span", "cr-nm");
  const tm = h("span", "cr-tm");
  l1.append(nm, tm);
  const l2 = h("div", "cr-l2");
  body.append(l1, l2);
  row.append(av, body);
  const acts = h("div", "cr-acts"); // button revealed by left swipe, hidden normally
  li.append(row, acts);
  li._p = { row, av, body, l1, nm, tm, l2, acts };
  return li;
}
// the left-swipe button text follows session state (mark unread/read, rest/return); not rebuilt if unchanged
function fillActs(li, s) {
  const acts = swipeActions(s);
  const sig = JSON.stringify(acts);
  const box = li._p.acts;
  if (box._sig === sig) return;
  // don't swap buttons on a row that is open or being dragged: the node would be replaced after the finger goes down and the tap would be lost
  if (box._sig && (st.swipeId === s.id || (sw && sw.li === li))) return;
  box._sig = sig;
  box.replaceChildren(...acts.map((a) => {
    const b = h("button", "cr-act", a.label);
    b.type = "button";
    b.dataset.sw = a.key;
    b.style.background = a.color;
    return b;
  }));
}
// context ring after the second-line summary: node is reused, untouched if the number is unchanged, otherwise only the ring and text change (the summary is left alone so the "working" text shimmer doesn't restart)
function fillCtx(li, c) {
  const p = li._p;
  if (!c) { if (p.cx) { p.cx.remove(); p.cx = null; } return; }
  if (!p.cx) {
    p.cx = h("span", "cr-cx ok");
    p.cx.append(h("b"));
    const pv = p.l2.querySelector(".cr-pv");
    if (pv) pv.after(p.cx); else p.l2.append(p.cx);
  }
  const cls = "cr-cx " + c.lv;
  if (p.cx.className !== cls) p.cx.className = cls;
  if (p.cx._pct === c.pct) return;
  p.cx._pct = c.pct;
  p.cx.querySelector("svg")?.remove();
  p.cx.insertAdjacentHTML("afterbegin", ringSvg(c.pct, 15, 2));
  setText(p.cx.lastChild, c.text);
  p.cx.setAttribute("aria-label", t("ctx.usage", { v: c.text }));
}
function fillMsgLi(li, s, now, o) {
  const p = li._p;
  const r = chatRow(s, (st.snap && st.snap.zones) || [], now, s.id === st.detailId && !st.detailOff ? "" : st.drafts.get(s.id)); // draft: not shown for the session currently open
  let cls = "cr-row " + r.kind;
  if (r.pinned || r.topped) cls += " pin"; // the permanent pin and the dashboard pin share the --row-pin background
  if (s.id === st.detailId && !st.detailOff) cls += " sel"; // in two-pane mode, the one currently open on the right
  if (r.lead) cls += " lead";
  if (r.quiet) cls += " quiet";
  if (r.gone) cls += " gone"; // unexpected exit: whole row grayed
  if (p.row.className !== cls) p.row.className = cls;
  fillActs(li, s);
  li.classList.toggle("sw-leaving", st.offing.has(s.id));
  fillAv(p.av, s, { color: r.zoneColor, lead: r.lead, rest: r.rest, plate: r.plate, badge: r.badge, off: r.gone });
  // name: refill only when the content changed (no animation on the name)
  const sigN = JSON.stringify([r.plate, r.lead, o.zoneTag && r.zoneName, o.q, r.kindTag]);
  if (p.nm._sig !== sigN) {
    p.nm._sig = sigN;
    const kids = [];
    if (o.q) for (const x of hlParts(r.plate, o.q)) kids.push(x.hit ? h("mark", null, x.t) : document.createTextNode(x.t));
    else kids.push(document.createTextNode(r.plate));
    if (r.lead) kids.push(h("span", "cr-star", "★"));
    if (r.kindTag) kids.push(h("span", "cr-kind", r.kindTag)); // Codex / WorkBuddy badge
    if (o.zoneTag) kids.push(h("span", "cr-zn", r.zoneName));
    p.nm.replaceChildren(...kids);
  }
  // time: while working it is the elapsed time ticking every second (tickLive); the node stays, only class and text change
  const live = r.kind === "g" || r.bgRun; // for rows running in the background the timer starts from bgSince
  const tcls = live ? "cr-tm live" : "cr-tm";
  if (p.tm.className !== tcls) p.tm.className = tcls;
  if (live) {
    p.tm.dataset.since = String(r.liveSince);
    setText(p.tm, busyClock(r.liveSince, liveNow()));
  } else {
    delete p.tm.dataset.since;
    setText(p.tm, r.time);
  }
  fillCtx(li, rowCtx(s, nowSec())); // meta stale goes gray (same as the header's metaStale)
  // second line: not rebuilt if the text is unchanged (otherwise the "working" shimmer would restart on every poll)
  const sig = JSON.stringify([r.tag, r.text, r.quiet, r.pinned, o.q, o.snippet, !!s.muted]);
  if (li._sig === sig) return;
  li._sig = sig;
  const pv = h("span", "cr-pv");
  if (o.snippet != null) {
    hlInto(pv, o.snippet, o.q);
  } else {
    if (r.tag) {
      const t = h("span", "cr-pt " + r.tag.cls, r.tag.cls === "p" ? quietNote(r.tag.text) : r.tag.text);
      if (r.tag.cls === "g") {
        const dots = h("span", "cr-typing");
        dots.append(h("i"), h("i"), h("i"));
        // light sweep over "working": two masked windows draw copies of the label from data-t (CSS ::before, green + light), adding no text nodes
        const shine = ["cr-shn b", "cr-shn"].map((c) => { const e = h("span", c); e.dataset.t = r.tag.text; e.setAttribute("aria-hidden", "true"); return e; });
        t.append(dots, ...shine, document.createTextNode(" "));
      }
      pv.append(t);
    }
    pv.append(document.createTextNode(r.text));
  }
  const kids = [pv];
  if (p.cx) kids.push(p.cx);
  if (s.muted) kids.push(svgEl(MUTE_SVG)); else if (r.pinned) kids.push(svgEl(PIN_ROW_SVG)); // the bell only for true do-not-disturb; peer rows (quiet) don't draw it
  p.l2.replaceChildren(...kids);
}

// when the Mac disconnects the timer freezes at the moment of disconnection (the data cutoff) instead of continuing with the local clock
function liveNow() {
  return st.down ? st.downAt : Date.now() / 1000;
}
// disconnect / recovery: whole page gray (CSS body.mac-down pauses all animations), timers frozen, chat-page figures stop starting, a gray bar under the chat header
function applyDown(down, at, text) {
  const bar = $("#d-down");
  if (bar) { bar.hidden = !down; if (down) setText(bar, text || ""); }
  if (down && $("#d-alert")) $("#d-alert").hidden = true; // the hint bar yields to the Mac-disconnected gray bar (shown again by the next renderAlert after recovery)
  if (down === st.down && (!down || at === st.downAt)) return;
  st.down = down;
  st.downAt = at;
  document.body.classList.toggle("mac-down", down);
  setFrozen(down);
  if (down) for (const el of document.querySelectorAll(".cr-tm.live")) setText(el, busyClock(Number(el.dataset.since) || 0, at));
}
// the working timer in the message list ticks once per second; not on the chat page or when the app is in the background; also frozen while the Mac is disconnected
function tickLive() {
  if (document.hidden) return;
  if (st.detailId) { if (!st.down) { tickFig(); tickAgents(); } return; }
  if (st.down) return;
  const now = liveNow();
  for (const el of document.querySelectorAll(".cr-tm.live")) setText(el, busyClock(Number(el.dataset.since) || 0, now));
}
setInterval(tickLive, 1000);

// ---------- "working" effects in the message list ----------
// Per zone (snapshot zones[].fx): marquee / circuit / halo / orbit (effect outside the frame + every 5 seconds a small item is thrown at the timer);
// no zone: the pet (or flame stand-in) walks out of the avatar frame (errand / carrying files, see busyFx in logic.js).
// The effect layer is built once per "style + pet" and attached to the reused row node; it is torn down and rebuilt only when state changes, and poll redraws leave it alone.
// Rule: animations only touch transform / opacity; each style's static pose is in the base style, so turning animation off under reduced motion falls back to the static pose.
const FX_GAP = 8; // gap of .cr-l1
const fxl = (cls) => h("div", "fxl " + cls);
function fxSvg(w, ht, body) {
  return svgEl('<svg class="px" width="' + w + '" height="' + ht + '" viewBox="0 0 ' + w + " " + ht + '">' + body + "</svg>");
}
const fxRects = (list) => list.map(([x, y, w, ht, c]) => '<rect x="' + x + '" y="' + y + '" width="' + w + '" height="' + ht + '" fill="' + c + '"/>').join("");
// pixel items (SVG assembled only from the fixed data above)
const FX_PAPER = (w = 10, ht = 12) => fxSvg(w, ht, fxRects([[0, 0, w, ht, "#f4f1e6"], [0, ht - 1, w, 1, "#c9c2ad"], [2, 3, w - 4, 1, "#9aa3b5"], [2, 5, w - 4, 1, "#9aa3b5"], [2, 7, Math.max(1, w - 6), 1, "#07c160"]]));
const FX_STAR = (c) => fxSvg(11, 11, fxRects([[5, 0, 1, 11, c], [0, 5, 11, 1, c], [4, 2, 3, 7, c], [2, 4, 7, 3, c], [3, 3, 5, 5, c], [4, 4, 3, 3, "#ffffff"]]));
const FX_BOLT = () => fxSvg(9, 13, fxRects([[4, 0, 5, 2, "#fff6a0"], [3, 2, 4, 2, "#ffe14a"], [2, 4, 3, 2, "#ffe14a"], [1, 6, 7, 2, "#fff6a0"], [4, 8, 3, 2, "#ffe14a"], [3, 10, 2, 2, "#ffe14a"], [2, 12, 1, 1, "#ffe14a"]]));
const FX_HEART = () => fxSvg(9, 8, fxRects([[1, 0, 3, 1, "#ff8fc8"], [5, 0, 3, 1, "#ff8fc8"], [0, 1, 9, 3, "#ff8fc8"], [1, 4, 7, 1, "#ff8fc8"], [2, 5, 5, 1, "#ff8fc8"], [3, 6, 3, 1, "#ff8fc8"], [4, 7, 1, 1, "#ff8fc8"], [1, 1, 2, 1, "#ffffff"]]));
const FX_TICKET = () => fxSvg(12, 8, fxRects([[0, 0, 12, 8, "#ffcf4a"], [0, 0, 12, 1, "#fff1b0"], [0, 7, 12, 1, "#c9921c"], [0, 3, 1, 2, "#7a5410"], [11, 3, 1, 2, "#7a5410"], [3, 2, 1, 4, "#c9921c"], [5, 3, 5, 1, "#7a5410"], [5, 5, 3, 1, "#7a5410"]]));
const FX_TOSS_STAR = () => fxSvg(9, 9, fxRects([[4, 0, 1, 9, "#f3e8ff"], [0, 4, 9, 1, "#f3e8ff"], [3, 2, 3, 5, "#e2c8ff"], [2, 3, 5, 3, "#e2c8ff"], [3, 3, 3, 3, "#ffffff"]]));

// small pet on the track: the sprite of the real list (.pet strip + frame animation) scaled to 2/3; dur is seconds per frame cycle (faster runs get faster frames)
// actor: {type:"pet", name} the pet itself / {type:"flame"} the flame stand-in (built-in /figures/soulflame/, row 7, 6 frames)
function fxSprite(actor, dur) {
  const box = h("div", "cr-spr");
  const pet = h("div", "pet");
  const flame = actor.type === "flame";
  const n = Math.max(1, Math.min(8, Number(flame ? FLAME_ROWS[ROW.running] : (st.pets[actor.name] || {})[ROW.running]) || 1));
  pet.style.backgroundImage = flame ? 'url("' + FIG_BUILTIN + ROW.running + '.webp")'
    : 'url("/pets/' + encodeURIComponent(actor.name) + "/" + ROW.running + '.webp")';
  if (n > 1) { pet.dataset.n = String(n); pet.style.animationDuration = dur + "s"; }
  box.append(pet);
  return box;
}
function fxStill(name, cls) {
  const i = h("img", cls);
  i.src = "/pets/" + encodeURIComponent(name) + "/still.webp";
  i.alt = "";
  return i;
}

// F: { nodes built (removed on teardown), cls class added to the li }; clip is the clipping layer in the avatar, pin is the layer wrapping the pet
function fxMarquee(F, av, clip, pin) {
  F.cls.push("fx-marquee");
  const bulbs = fxl("fxa-bulbs"), L = 58, o = -4, per = 8;
  for (let s = 0; s < 4; s++) for (let i = 0; i < per; i++) {
    const t = (i / per) * L, k = s * per + i;
    const [x, y] = s === 0 ? [t, 0] : s === 1 ? [L, t] : s === 2 ? [L - t, L] : [0, L - t];
    const b = h("span", "fxa-b" + (k % 4 === 2 ? " w" : ""));
    b.style.left = (x + o) + "px"; b.style.top = (y + o) + "px";
    const li = h("i"); li.style.animationDelay = (-(16 - (k % 16)) / 16 * .8).toFixed(3) + "s";
    b.append(li); bulbs.append(b);
  }
  clip.classList.add("fxa-stage");
  const conf = fxl("fxa-conf");
  [["-14px", "-10px", "#ffd36a"], ["12px", "-12px", "#ff6fae"], ["-8px", "-16px", "#ffffff"], ["16px", "-4px", "#7fe3ff"], ["-17px", "-2px", "#ff6fae"], ["5px", "-17px", "#ffd36a"], ["-3px", "-8px", "#7fe3ff"], ["9px", "-7px", "#ffffff"]]
    .forEach(([dx, dy, c]) => { const i = h("i"); i.style.cssText = "--dx:" + dx + ";--dy:" + dy + ";--c:" + c; conf.append(i); });
  F.under(fxl("fxa-floor"), fxl("fxa-spot"), fxl("fxa-pool"));
  F.over(conf, fxl("fxa-cur l"), fxl("fxa-cur r"), fxl("fxa-val"));
  F.before(fxl("fxa-glow"), fxl("fxa-frame"));
  F.after(bulbs, fxl("fxa-flash"));
}
function fxCircuit(F, av, clip) {
  F.cls.push("fx-circuit");
  // 66x66 circuit board: outer trace + pins + corner pads + a few outward branches
  const T = "#1f5c55", H = "#2c8a7e", PAD = "#40b0a0", HOLE = "#0a1a19";
  const board = fxSvg(66, 66, fxRects([
    [2, 2, 62, 2, T], [62, 2, 2, 62, T], [2, 62, 62, 2, T], [2, 2, 2, 62, T],
    [2, 2, 62, 1, H], [2, 2, 1, 62, H],
    [16, 4, 2, 4, T], [33, 4, 2, 4, T], [48, 4, 2, 4, T], [4, 22, 4, 2, T], [4, 42, 4, 2, T],
    [58, 18, 4, 2, T], [58, 40, 4, 2, T], [33, 58, 2, 4, T], [20, 58, 2, 4, T], [46, 58, 2, 4, T],
    [0, 0, 7, 7, PAD], [59, 0, 7, 7, PAD], [59, 59, 7, 7, PAD], [0, 59, 7, 7, PAD],
    [2, 2, 3, 3, HOLE], [61, 2, 3, 3, HOLE], [61, 61, 3, 3, HOLE], [2, 61, 3, 3, HOLE],
    [31, 60, 6, 6, PAD], [33, 62, 2, 2, HOLE],
  ]));
  const bwrap = fxl("fxe-board"); bwrap.append(board);
  const run = fxl("fxe-run");
  for (const lane of ["a", "b"]) {
    const base = lane === "a" ? 0 : -1.6;
    run.append(h("i", "fxe-p " + lane));
    [[.05, "t"], [.1, "t t2"]].forEach(([lag, c]) => { const t = h("i", "fxe-p " + lane + " " + c); t.style.animationDelay = (base + lag) + "s"; run.append(t); });
  }
  // corner sparks: TL/BR are hit by the pulse at 0, TR/BL at T/4 (period T/2)
  [[3, 3, 0], [63, 3, -.8], [63, 63, 0], [3, 63, -.8]].forEach(([x, y, d]) => {
    const sp = h("span", "fxe-sp"); sp.style.left = x + "px"; sp.style.top = y + "px"; sp.style.setProperty("--d", d + "s");
    [[-6, -5], [6, -6], [-5, 6], [7, 4]].forEach(([dx, dy]) => { const i = h("i"); i.style.cssText = "--dx:" + dx + "px;--dy:" + dy + "px"; sp.append(i); });
    run.append(sp);
  });
  clip.classList.add("fxe-pcb");
  const inT = fxl("fxe-in"); inT.append(h("i"));
  const bolt = fxl("fxe-bolt"); bolt.append(FX_BOLT());
  F.under(inT);
  F.over(fxl("fxe-zap"), bolt);
  F.before(fxl("fxe-glow"), bwrap);
  F.after(run);
}
function fxHalo(F, av, clip) {
  F.cls.push("fx-halo");
  const glow = fxl("fxb-glow"); glow.append(h("i"));
  const ring = fxl("fxb-ring"); ring.append(h("i"), h("i"));
  clip.classList.add("fxb-in");
  const wash = fxl("fxb-wash"); wash.append(h("i"));
  const dots = fxl("fxb-dots");
  [[-30, -22], [-32, 8], [10, -26], [12, 18], [-20, 20], [-6, -30]].forEach(([x, y], i) => {
    const d = h("i", "fxb-d"); d.style.cssText = "--x:" + x + "px;--y:" + y + "px;--d:" + (-i * .5) + "s"; dots.append(d);
  });
  const holo = fxl("fxb-holo"); holo.append(h("i"), h("i"), h("i"));
  F.under(wash);
  F.over(fxl("fxb-scan"), dots, holo);
  F.before(glow, ring);
}
function fxOrbit(F, av, clip) {
  F.cls.push("fx-orbit");
  clip.classList.add("fxm-sky");
  const tw = [[8, 9, 0], [40, 7, -.5], [14, 22, -.9], [36, 18, -.3], [26, 5, -1.1], [44, 30, -.7]].map(([x, y, d]) => {
    const s = fxl("fxm-tw"); s.style.left = x + "px"; s.style.top = y + "px"; s.style.animationDelay = d + "s"; return s;
  });
  const shoot = fxl("fxm-shoot"); shoot.append(h("i"));
  const wish = fxl("fxm-wish"); wish.append(FX_HEART());
  F.under(...tw, shoot);
  F.over(wish);
  const ORB = [
    { rx: 29, ry: 10, tilt: -18, t: 1.5, c: "#e2c8ff" },
    { rx: 29, ry: 12, tilt: 32, t: 1.9, c: "#ff9ad5", d0: -.9 },
    { rx: 30, ry: 9, tilt: 72, t: 1.25, c: "#fff1a8", d0: -.4 },
  ];
  const layer = (side) => { // bk = rotated to the back (behind the frame), fr = front (in front of the frame)
    const wrap = fxl("fxm-orbs " + side);
    for (const ob of ORB) for (let k = 0; k < 3; k++) {
      const o = h("div", "fxm-o");
      o.style.cssText = "transform:rotate(" + ob.tilt + "deg);--t:" + ob.t + "s;--d:" + ((ob.d0 || 0) + k * .07) + "s;--rx:" + ob.rx + "px;--ry:" + ob.ry + "px;--c:" + ob.c;
      if (!k) { const pa = h("i", "fxm-path"); pa.style.cssText = "left:" + -ob.rx + "px;top:" + -ob.ry + "px;width:" + 2 * ob.rx + "px;height:" + 2 * ob.ry + "px"; o.append(pa); }
      const x = h("div", "fxm-x"), y = h("div", "fxm-y"), s = h("div", "fxm-s" + (k ? " tail" : ""));
      const sv = FX_STAR(ob.c); if (k) { sv.style.transform = "scale(" + (k === 1 ? .7 : .45) + ")"; s.style.setProperty("--o", k === 1 ? ".5" : ".3"); }
      s.append(sv); y.append(s); x.append(y); o.append(x); wrap.append(o);
    }
    return wrap;
  };
  F.before(fxl("fxm-aura"), layer("bk"));
  F.after(layer("fr"));
}
// no zone: mode = run (errand) / carry (carrying files); track is the lane between name and timer (no station).
// when the actor is the pet itself only a shadow stays in the avatar; with the flame stand-in (pet that can't walk / no pet installed) the pet stays in the avatar and animates as usual while the stand-in is out, and no shadow is drawn
// bg: background work running, main turn idle. The pet in the avatar stays standing (fxw-bg doesn't hide .cr-pin), no "on an errand" badge, no shadow; only the figure outside the frame strolls
function fxWalk(F, av, clip, track, actor, mode, bg) {
  const pet = actor.type === "pet";
  const ghost = pet && !bg;
  F.cls.push("fx-walk");
  if (!pet) F.cls.push("fxw-flame");
  if (bg) F.cls.push("fxw-bg");
  if (mode === "run") {
    if (ghost) F.under(fxStill(actor.name, "fxw-ghost"));
    if (!bg) { const sign = fxl("fxw-sign"); sign.append(h("b", null, t("fx.errand"))); F.after(sign); }
    const runner = h("div", "fxw-runner"), face = h("div", "fxw-face"), hop = h("div", "fxw-hop");
    hop.append(fxSprite(actor, .5));
    face.append(hop); for (let i = 0; i < 3; i++) face.append(h("i", "fxw-dust"));
    runner.append(face); track.append(runner);
  } else {
    F.cls.push("fxw-carry-row");
    const inbox = fxl("fxw-inbox");
    [[2, 0, ""], [1, 6, ""], [3, 12, "top"]].forEach(([x, y, c]) => { const pp = FX_PAPER(22, 6); pp.style.left = x + "px"; pp.style.bottom = y + "px"; if (c) pp.classList.add(c); inbox.append(pp); });
    if (ghost) { const g = fxStill(actor.name, "fxw-ghost"); g.style.opacity = ".1"; F.under(g, inbox); } else F.under(inbox);
    const car = h("div", "fxw-carrier"); car.append(fxSprite(actor, .7));
    const load = h("div", "fxw-load"); load.append(FX_PAPER()); car.append(load);
    const toss = h("div", "fxw-toss"); toss.append(FX_PAPER());
    track.append(car, toss);
    [["-9px", "3px"], ["8px", "-6px"], ["-6px", "-7px"], ["10px", "4px"]].forEach(([dx, dy]) => { const s = h("i", "fxw-spark"); s.style.cssText = "--dx:" + dx + ";--dy:" + dy; track.append(s); });
  }
}
// item throw: every 5 seconds a zone item flies from the avatar to the top-right timer; the timer bounces once with a puff of zone-colored light
function fxLane(kind, obj, delay, op) {
  const ln = h("div", "fxt " + kind);
  if (delay) ln.style.setProperty("--td", delay + "s");
  if (op) ln.style.setProperty("--o", op);
  const mv = h("div", "mv"), y = h("div", "fxt-y"), o = h("div", "fxt-o");
  if (obj) o.append(obj);
  y.append(o); mv.append(y); ln.append(mv);
  return ln;
}
function fxToss(F, li, kind) {
  F.cls.push("fxt-row", "fxt-" + kind);
  const p = li._p;
  const hit = h("i", "fxt-hit");
  const lanes = [];
  if (kind === "marquee") lanes.push(fxLane("marquee", FX_TICKET()));
  else if (kind === "circuit") { const ln = fxLane("circuit", null); ln.prepend(h("i", "fxt-line")); lanes.push(ln); }
  else if (kind === "halo") lanes.push(fxLane("halo", null));
  else if (kind === "orbit") {
    lanes.push(fxLane("orbit", FX_TOSS_STAR()));
    const t1 = fxLane("orbit", FX_TOSS_STAR(), .05, ".5"); t1.querySelector(".px").style.transform = "scale(.7)"; lanes.push(t1);
    const t2 = fxLane("orbit", FX_TOSS_STAR(), .1, ".25"); t2.querySelector(".px").style.transform = "scale(.45)"; lanes.push(t2);
  }
  // lane: avatar right edge -> timer left edge (the timer width varies, measured once at build time); falls back to the default in the style if it can't be measured
  const rr = p.row.getBoundingClientRect(), ar = p.av.getBoundingClientRect(), tr = p.tm.getBoundingClientRect();
  if (rr.width && tr.width) {
    for (const ln of lanes) { ln.style.left = (ar.right - rr.left - 8) + "px"; ln.style.right = (rr.right - tr.left) + "px"; }
    hit.style.right = (rr.right - (tr.left + tr.right) / 2 - 27) + "px";
  }
  for (const n of [hit, ...lanes]) { p.row.append(n); F.nodes.push(n); }
}

function dropFx(li) {
  const F = li._fx;
  if (!F) return;
  for (const n of F.nodes) n.remove();
  li._p.av._p.clip.className = "cr-clip";
  if (F.cls.length) li.classList.remove(...F.cls);
  li._fx = null;
}
// row effects follow session state: do nothing if the requested style is unchanged (animation doesn't restart)
function syncFx(li, s) {
  const pet = s ? petName(s) : null;
  const want = s ? busyFx(s, pet, (st.snap && st.snap.zones) || [], pet && st.pets[pet] ? st.pets[pet].caps : null, st.petsKnown) : null;
  const actor = want && want.actor ? (want.actor.type === "flame" ? "flame" : want.actor.name) : "";
  const key = want ? want.kind + "/" + (want.mode || "") + "/" + actor + "/" + pet + (want.bg ? "/bg" : "") : "";
  if ((li._fx ? li._fx.key : "") === key) return;
  const p = li._p;
  // stepping out of the frame needs the lane measured: if the row isn't drawn yet (on another tab, during search) skip building and try next round
  if (want && want.kind === "walk" && !p.l1.clientWidth) { dropFx(li); return; }
  dropFx(li);
  if (!want) return;
  const av = p.av, clip = av._p.clip, pin = clip.querySelector(".cr-pin");
  const F = {
    key, nodes: [], cls: ["fx"],
    under: (...ns) => { for (const n of ns) { clip.insertBefore(n, pin); F.nodes.push(n); } },
    over: (...ns) => { for (const n of ns) { clip.append(n); F.nodes.push(n); } },
    before: (...ns) => { for (const n of ns) { av.insertBefore(n, clip); F.nodes.push(n); } },
    after: (...ns) => { const ref = clip.nextSibling; for (const n of ns) { av.insertBefore(n, ref); F.nodes.push(n); } },
  };
  if (want.kind === "walk") {
    // lane = first-line width - width the name wants - timer - two gaps; if too small, stay in the avatar (the default animated pet)
    // measure the width the name wants with a Range over its content (.cr-nm is flex:1, so its own width/scrollWidth are the stretched ones)
    const rg = document.createRange();
    rg.selectNodeContents(p.nm);
    const avail = p.l1.clientWidth - Math.ceil(rg.getBoundingClientRect().width) - p.tm.offsetWidth - 2 * FX_GAP;
    const mode = walkFit(want.mode, avail);
    if (mode) {
      const track = h("span", "fxw-track");
      p.l1.insertBefore(track, p.tm);
      F.nodes.push(track);
      fxWalk(F, av, clip, track, want.actor, mode, want.bg);
    } else {
      F.cls = [];
    }
  } else {
    ({ marquee: fxMarquee, circuit: fxCircuit, halo: fxHalo, orbit: fxOrbit })[want.kind](F, av, clip, pin);
    fxToss(F, li, want.kind);
  }
  if (fxCalm(want)) F.cls.push("fx-calm"); // background work running -> zone effect drops one level
  // add the class last, all together: the timer's "bounce" and the freshly inserted thrown item start at the same instant, so the beats line up
  if (F.cls.length) li.classList.add(...F.cls);
  li._fx = F;
}

// ---------- Blaze Mode flame on Fable session avatars (sprite exported from the dashboard: style.css "Blaze Mode flame" block, frames in web/fx/fire/) ----------
// the fire layer is built once per avatar and kept on host._fire; when the level changes only the class changes (strong = busy bar / weak = idle bar), removed only when there is no fire; on the 2-second redraw nothing happens if the level is unchanged (animation doesn't restart)
function fireNode() {
  return h("div", "fx-fire");
}
// the fire layer costs battery: fire layers outside the viewport (scrolled out on the chat page, list page covered / display:none) get fx-fire-off to pause frame animation,
// and when the page is not visible <html> gets fx-hid to pause everything (style.css "fire paused off-screen" block). When a fire layer is torn down with its avatar redraw,
// fireSweep drops the detached ones from the observed set (syncChatFire sweeps it every round)
const fireIO = typeof IntersectionObserver === "function"
  ? new IntersectionObserver((es) => {
    for (const e of es) {
      if (!e.target.isConnected) { fireUnwatch(e.target); continue; }
      e.target.classList.toggle("fx-fire-off", !e.isIntersecting);
    }
  })
  : null;
const fireSeen = new Set();
function fireWatch(el) {
  if (!fireIO || fireSeen.has(el)) return;
  if (fireSeen.size > 48) fireSweep(); // syncChatFire doesn't run while only the list page is shown, so clean up here
  fireSeen.add(el);
  fireIO.observe(el);
}
function fireUnwatch(el) {
  if (!el || !fireSeen.delete(el)) return;
  if (fireIO) fireIO.unobserve(el);
}
function fireSweep() {
  for (const el of fireSeen) if (!el.isConnected) fireUnwatch(el);
}
function fireVis() {
  document.documentElement.classList.toggle("fx-hid", document.hidden);
}
if (typeof document !== "undefined" && document.addEventListener) {
  document.addEventListener("visibilitychange", fireVis);
  fireVis();
}
function syncFire(host, ref, level) {
  if (!host) return;
  const lv = level || "";
  if (host._fireLv === lv) return;
  host._fireLv = lv;
  if (!lv) {
    if (host._fire) { fireUnwatch(host._fire); host._fire.remove(); }
    host._fire = null;
    return;
  }
  if (!host._fire) host._fire = fireNode();
  const off = host._fire.classList.contains("fx-fire-off"); // keep the off-screen pause when switching level
  host._fire.className = "fx-fire " + (lv === "strong" ? "fx-fire-s" : "fx-fire-w") + (off ? " fx-fire-off" : "");
  if (host._fire.parentNode !== host) host.insertBefore(host._fire, ref && ref.parentNode === host ? ref : host.firstChild);
  fireWatch(host._fire);
}
// chat-page speaker -> session in the snapshot (by pet id first; from the guest view, which has no id, by name)
// session of a speaker (by id, by name if not found)
function speakerSession(sp) {
  const list = (st.snap && st.snap.sessions) || [];
  const id = sp && sp.pet && sp.pet.id != null ? String(sp.pet.id) : null;
  return (id && list.find((x) => String(x.id) === id)) || (sp && sp.name ? list.find((x) => x.name === sp.name) : null);
}
function fireOfSpeaker(sp) {
  return fireLevel(speakerSession(sp));
}
// chat-page bubble avatars are not rebuilt on poll: whenever the header refreshes, align the already drawn avatar fire layers to the latest state
function syncChatFire() {
  fireSweep(); // fire layers of avatars removed by a redraw are no longer observed
  for (const av of document.querySelectorAll("#msgs .cav-ag")) {
    if (!av._sp) continue;
    syncFire(av._fh, av._fh.firstChild, fireOfSpeaker(av._sp));
    // the flame avatar's expression follows session state
    const fl = av._fh.querySelector(".pet-flame");
    const s = fl && speakerSession(av._sp);
    if (s) {
      const pick = avatarPick(s, null, st.petsKnown);
      const url = pick.kind === "flame" ? 'url("' + pick.src + '")' : "";
      if (url && fl.style.backgroundImage !== url) fl.style.backgroundImage = url;
    }
  }
}

const msgEls = new Map();
let foldLi = null;
function foldRow(rest) {
  if (!foldLi) {
    foldLi = h("li");
    const row = h("button", "cr-row cr-fold");
    row.type = "button";
    row.id = "cr-fold";
    const av = h("div", "cr-av");
    av.append(svgEl(MOON_SVG));
    const body = h("div", "cr-body");
    row.append(av, body);
    foldLi.append(row);
    foldLi._body = body;
  }
  const l1 = h("div", "cr-l1");
  l1.append(h("span", "cr-nm", st.restOpen ? t("list.restFold") : t("list.restN", { n: rest.length })));
  const l2 = h("div", "cr-l2");
  const names = joinList(rest.slice(0, 3).map(plateOf));
  l2.append(h("span", "cr-pv", t("list.restSub", { names: rest.length > 3 ? t("list.restMore", { names }) : names })));
  foldLi._body.replaceChildren(l1, l2);
  return foldLi;
}

// message-page title: "Messages" or "Messages · zone" followed by a ▾; tap to open the zone filter
function zoneName() {
  const c = zoneChips(st.snap).find((x) => x.key === st.zone);
  return c && c.key !== "all" ? c.name : "";
}
function renderTitle() {
  const tl = $("#cr-title");
  const msg = st.tab === "msg" && !st.searching && !st.guest; // guests have no zone filter
  const text = st.searching ? t("c.search") : msg && st.snap && zoneName() ? "Soulgent · " + zoneName() : TAB_TITLE[st.tab];
  const sig = text + (msg ? "▾" : "");
  if (tl._sig === sig) return;
  tl._sig = sig;
  tl.replaceChildren(document.createTextNode(text));
  if (msg) tl.append(h("span", "cr-caret", "▾"));
  tl.classList.toggle("tap", msg);
}
function openZoneSheet() {
  if (st.guest || st.tab !== "msg" || st.searching || !st.snap) return;
  actionSheet(t("list.byZone"), zoneChips(st.snap).map((c) => ({
    label: (c.key === st.zone ? "✓ " : "") + c.name,
    run: () => { st.zone = c.key; renderMsgs(); window.scrollTo(0, 0); },
  })));
}

function renderMsgs() {
  if (!zoneChips(st.snap).some((c) => c.key === st.zone)) st.zone = "all";
  renderTitle();
  const now = nowSec();
  const m = msgModel(st.snap, st.zone);
  const used = new Set();
  const row = (s) => {
    let li = msgEls.get(s.id);
    if (!li) { li = makeMsgLi(s.id); msgEls.set(s.id, li); }
    used.add(s.id);
    fillMsgLi(li, s, now, { zoneTag: st.zone === "all" });
    return li;
  };
  const shown = m.active.concat(st.restOpen ? m.rest : []);
  const want = m.active.map(row);
  if (m.rest.length) {
    if (st.restOpen) for (const s of m.rest) want.push(row(s));
    want.push(foldRow(m.rest));
  }
  if (!want.length) {
    const b = st.guest ? guestBoundLabel(st.bound, st.snap.zones) : "";
    want.push(h("li", "cr-empty", st.guest ? (b ? t("list.guestOffline", { name: b }) : t("list.guestUnbound"))
      : st.zone === "all" ? t("empty.noSessions") : t("list.zoneEmpty")));
  }
  syncChildren($("#cr-msgs"), want);
  // effects are built only once the row is in the page (stepping out needs the lane width); rows scrolled off-screen get .off from io to pause animation
  for (const s of shown) {
    const li = msgEls.get(s.id);
    if (io && !li._io) { io.observe(li); li._io = true; }
    syncFx(li, s);
  }
  for (const id of Array.from(msgEls.keys())) {
    if (used.has(id)) continue;
    const li = msgEls.get(id);
    if (io) io.unobserve(li);
    dropFx(li);
    msgEls.delete(id);
    if (st.swipeId === id) st.swipeId = null;
  }
}

// contacts / search / me: change infrequently, no redraw if the signature is unchanged
function contactRow(s, x, now) {
  const li = h("li");
  const row = h("button", "cr-row cr-c" + (x.lead ? " lead" : "") + (s.id === st.detailId && !st.detailOff ? " sel" : ""));
  row.type = "button";
  row.dataset.id = s.id;
  const av = makeAv();
  const z = zoneOf(s.zone);
  fillAv(av, s, { color: z.color, lead: x.lead, rest: !!s.rest, plate: x.plate });
  const body = h("div", "cr-body");
  const l1 = h("div", "cr-l1");
  l1.append(h("span", "cr-nm", x.plate));
  if (x.lead) l1.append(h("span", "cr-star", "★"));
  if (kindTag(s.kind)) l1.append(h("span", "cr-kind", kindTag(s.kind))); // Codex / WorkBuddy badge
  if (x.status) l1.append(h("span", "cr-st " + x.status.cls, x.status.text));
  body.append(l1);
  row.append(av, body);
  li.append(row);
  return li;
}
function offRow(o, now, q) {
  const li = h("li");
  const row = h("div", "cr-row cr-c cr-off");
  row.dataset.off = o.sid;
  const av = makeAv();
  fillAv(av, offAsSession(o), { color: zoneOf(o.zone).color, off: true, plate: o.plate });
  const body = h("div", "cr-body");
  const l1 = h("div", "cr-l1");
  const nm = h("span", "cr-nm");
  if (q) hlInto(nm, o.plate, q); else nm.textContent = o.plate;
  l1.append(nm, h("span", "cr-tm", offLine(o.offAt, now)));
  body.append(l1);
  const wake = h("button", "cr-wake", t("wake.btn"));
  wake.type = "button";
  wake.dataset.off = o.sid;
  wake.setAttribute("aria-label", t("wake.aria", { name: o.plate }));
  row.append(av, body, wake);
  li.append(row);
  return li;
}

function renderContacts() {
  const now = nowSec();
  const m = contactsModel(st.snap);
  const sig = JSON.stringify([m, st.petNames.length, st.petsKnown, Math.floor(now / 60), st.detailOff ? null : st.detailId]);
  if (st.crSig.contacts === sig) return;
  st.crSig.contacts = sig;
  const sc = (bg, icon, label, n, act) => {
    const li = h("li");
    const row = h("button", "cr-row cr-c");
    row.type = "button";
    row.dataset.act = act;
    const av = h("div", "cr-av");
    av.style.setProperty("--sc", bg);
    av.append(svgEl(icon));
    const body = h("div", "cr-body");
    const l1 = h("div", "cr-l1");
    l1.append(h("span", "cr-nm", label), h("span", "cr-tm", String(n)));
    body.append(l1);
    row.append(av, body);
    li.append(row);
    return li;
  };
  $("#cr-top").replaceChildren(
    sc("var(--coral)", CLOCK_SVG, t("ct.waiting"), m.counts.waiting, "wait"),
    sc("#3a7bd5", PIN_W_SVG, t("ct.pinned"), m.counts.pinned, "pin"),
    sc("#4a4f5a", MOON_W_SVG, t("ct.off"), m.counts.off, "off"));
  const secs = [];
  const rail = [];
  for (const sec of m.sections) {
    const box = h("div");
    box.id = "cr-z-" + sec.key;
    const hd = h("div", "cr-sec-h");
    hd.style.setProperty("--zc", sec.color);
    hd.append(h("i"), h("b", null, sec.name), h("span", null, t("ct.secOn", { n: sec.members.length }) + (sec.off.length ? t("ct.secOff", { n: sec.off.length }) : "")));
    box.append(hd);
    if (sec.members.length) {
      const ul = h("ul", "cr-list");
      ul.append(...sec.members.map((x) => contactRow(x.s, x, now)));
      box.append(ul);
    }
    if (sec.off.length) {
      box.append(h("div", "cr-off-h", t("ct.offHead")));
      const ul = h("ul", "cr-list");
      ul.append(...sec.off.map((o) => offRow(o, now)));
      box.append(ul);
    }
    secs.push(box);
    const b = h("button", null, sec.name.slice(0, 1));
    b.type = "button";
    b.dataset.jump = box.id;
    b.style.setProperty("--zc", sec.color);
    b.setAttribute("aria-label", t("ct.jump", { name: sec.name }));
    rail.push(b);
  }
  $("#cr-contacts").replaceChildren(...secs);
  $("#cr-rail").replaceChildren(...rail);
}

function snippetOf(text, q) {
  const t = String(text || "");
  const i = t.toLowerCase().indexOf(String(q).trim().toLowerCase());
  const from = Math.max(0, i - 8);
  return (from ? "…" : "") + t.slice(from);
}
// a summary-search hit shows the summary rendered in the current language; when the keyword matches only the original text (English UI searching Chinese) fall back to the original
function sumHit(s, q) {
  const v = summaryText(s);
  return v.toLowerCase().includes(String(q).trim().toLowerCase()) ? v : s.summary;
}
function renderSearch() {
  const q = st.q.trim();
  const now = nowSec();
  gsSchedule(q); // search chat history 400 ms after typing stops; results are stored in st.gs and drawn from state below
  const sig = JSON.stringify([q, st.snap.generatedAt, st.petNames.length, st.petsKnown, st.gs && st.gs.state, st.gs && st.gs.q]);
  if (st.crSig.search === sig) return;
  st.crSig.search = sig;
  const out = $("#cr-sout");
  if (!q) {
    const hint = h("div", "cr-s-hint", t("sr.hint1"));
    hint.append(h("br"), document.createTextNode(t("sr.hint2")));
    out.replaceChildren(hint);
    return;
  }
  const r = chatSearch(st.snap, q);
  const nodes = [];
  const group = (title, lis) => {
    nodes.push(h("div", "cr-s-h", title));
    const ul = h("ul", "cr-list");
    ul.append(...lis);
    nodes.push(ul);
  };
  const li = (s, o) => { const x = makeMsgLi(s.id); fillMsgLi(x, s, now, o); return x; };
  if (r.byName.length) group(t("sr.byName"), r.byName.map((s) => li(s, { q, zoneTag: true })));
  if (r.bySummary.length) group(t("sr.bySummary", { q }), r.bySummary.map((s) => li(s, { zoneTag: true, q, snippet: snippetOf(sumHit(s, q), q) })));
  if (r.off.length) group(t("ct.offHead"), r.off.map((o) => offRow(o, now, q)));
  const gsN = gsNodes(q, now);
  if (!nodes.length && !gsN.length) {
    const e = h("div", "cr-empty", t("sr.none", { q }));
    e.append(h("br"), document.createTextNode(gsReady(q) && !st.guest ? t("sr.noneAll") : t("sr.noneLite")));
    nodes.push(e);
  }
  nodes.push(...gsN);
  out.replaceChildren(...nodes);
}

// ---------- "chat history" section in the outer search (reads the index built by the helper, /api/search) ----------
function gsReset() {
  if (st.gs) clearTimeout(st.gs.t);
  st.gs = null;
}
function gsSchedule(q) {
  if (st.guest) return;
  if (!gsReady(q)) { if (st.gs) gsReset(); return; }
  const g = st.gs || (st.gs = { want: "", q: "", data: null, state: "", t: 0, seq: 0 });
  q = q.trim();
  if (q === g.want) return;
  g.want = q;
  g.state = "wait";
  clearTimeout(g.t);
  const my = ++g.seq;
  g.t = setTimeout(async () => {
    let data = null;
    try {
      const r = await api(gsUrl(q), null, 15000);
      if (r.ok) data = await r.json();
    } catch (e) { /* hinted uniformly below */ }
    if (st.gs !== g || my !== g.seq) return;
    g.q = q;
    g.data = data;
    g.state = data ? "done" : "err";
    st.crSig.search = "";
    if (st.searching) renderSearch();
  }, GS_DELAY);
}
function gsNodes(q, now) {
  const g = st.gs;
  q = q.trim();
  if (st.guest || !g || !gsReady(q)) return [];
  const head = h("div", "cr-s-h", t("gs.head"));
  if (g.state === "wait" || g.q !== q) return [head, h("div", "gs-note", t("gs.wait"))];
  if (g.state === "err") return [head, h("div", "gs-note", t("gs.err"))];
  const rows = gsRows(g.data, st.snap);
  if (!rows.length) return [];
  const ul = h("ul", "cr-list gs-list");
  ul.append(...rows.map((r) => gsLi(r, q, now)));
  return [head, ul];
}
function gsLi(r, q, now) {
  const li = h("li");
  const row = h("button", "cr-row cr-c gs-row");
  row.type = "button";
  const o = r.off ? ((st.snap && st.snap.offduty) || []).find((x) => x.sid === r.sid) : null;
  const s = o ? offAsSession(o) : (st.byId.get(r.sid) || { id: r.sid, name: r.name, zone: r.zone });
  const av = makeAv();
  fillAv(av, s, { color: zoneOf(r.zone).color, off: r.off, plate: r.plate });
  const body = h("div", "cr-body");
  const l1 = h("div", "cr-l1");
  const nm = h("span", "cr-nm");
  nm.append(document.createTextNode(r.plate), h("span", "cr-zn", zoneOf(r.zone).name || r.zone));
  l1.append(nm, h("span", "cr-tm gs-cnt", r.countText));
  const l2 = h("div", "cr-l2");
  const pv = h("span", "cr-pv");
  if (r.prev) pv.append(h("span", "gs-prev", t("sep.prev")));
  hlInto(pv, snippetOf(r.snippet.replace(/^…/, ""), q), q); // narrow row: keep only 8 characters before the hit so the keyword isn't cut off
  l2.append(pv);
  body.append(l1, l2);
  row.append(av, body);
  row.onclick = () => {
    if (r.off) { openOffDetail(r.sid, undefined, "search"); return; } // off-duty sessions have no "search chat" page: just open the chat
    openDetail(r.sid, undefined, "search");
    if (st.detailId === r.sid && !st.detailOff) openChatSearch(q);
  };
  li.append(row);
  return li;
}

// ---------- Me (profile page + Orca stats page) ----------
// 8pt grid: 16 side margin, 56 setting row height, 8 gap between groups. Icons are all fixed constants.
const ME_IC = {
  mon: ["#10aeff", '<rect x="3" y="4.5" width="18" height="12" rx="1.6"/><path d="M9 20h6M12 16.5V20"/>'],
  push: ["#fa9d3b", '<path d="M6 16.5V11a6 6 0 0112 0v5.5l1.5 1.5h-15z"/><path d="M10 20.5a2 2 0 004 0"/>'],
  seen: ["#e0b01c", '<circle cx="12" cy="12" r="8.5"/><path d="M8.2 12.2l2.6 2.6 5-5.3"/>'],
  refresh: ["#10aeff", '<path d="M19.5 12a7.5 7.5 0 01-13 5.1M4.5 12a7.5 7.5 0 0113-5.1"/><path d="M17.8 3.6v3.6h-3.6M6.2 20.4v-3.6h3.6"/>'],
  diag: ["#a070d0", '<path d="M3.5 12h3.5l2-5 4 10 2.2-5h5.3"/>'],
  lang: ["#07c160", '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.4 3.6 5.2 3.6 8.5s-1.2 6.1-3.6 8.5c-2.4-2.4-3.6-5.2-3.6-8.5s1.2-6.1 3.6-8.5z"/>'], // language (globe)
  profile: ["#e8719e", '<circle cx="12" cy="8.5" r="3.6"/><path d="M5 19.5c.8-3.6 3.6-5.6 7-5.6s6.2 2 7 5.6"/>'],
  logins: ["#2bb39a", '<rect x="7" y="2.5" width="10" height="19" rx="2"/><path d="M10.5 18.5h3"/><circle cx="12" cy="10" r="2.2"/><path d="M12 12.2v2.3"/>'], // signed-in devices (phone with a key)
  logout: ["#fa5151", '<path d="M14.5 4.5h3a2 2 0 012 2v11a2 2 0 01-2 2h-3"/><path d="M10 8l-4 4 4 4M6 12h9.5"/>'],
};
function meIcon(key) {
  const [c, body] = ME_IC[key];
  return svgEl('<svg class="me-ic" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="' + c +
    '" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + body + "</svg>");
}
function meRow(key, label, val) {
  const b = h("button", "me-row");
  b.type = "button";
  b.dataset.me = key;
  b.append(meIcon(key), h("span", "me-k", label));
  if (val) b.append(h("span", "me-v", val));
  b.append(svgEl(CHEV_SVG));
  return b;
}
function pushText() {
  return st.push === "subscribed" ? t("me.pushOn") : st.push === "denied" ? t("me.pushDenied") : st.push === "unsupported" ? t("me.pushUnsupported") : st.push === "off" ? t("me.pushOff") : "";
}
// language switch on the Me page. Four options: follow system / Simplified Chinese / Traditional Chinese / English (each language name is written in its own script, not translated);
// choosing one writes localStorage zbs.lang and reloads the page (DOM cached in app.js is not hot-switched)

// the "[attachment xN]" tail (written by the local optimistic bubble itself, in the current language); removed from the displayed text when there is a preview image
function attachTailRe() {
  const esc = t("chat.attachN", { n: "\u0001" }).replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace("\u0001", "\\d+");
  return new RegExp("\\n?" + esc + "$");
}
function langText() {
  const p = langPref();
  return p === "auto" ? t("me.langAutoV") : LANG_NAMES[p];
}
function openLangSheet() {
  const pick = (p) => () => {
    if (p === langPref()) return;
    saveLangPref(p);
    location.reload();
  };
  const mark = (p, label) => (langPref() === p ? "✓ " : "") + label;
  actionSheet(t("me.lang"), [
    { label: mark("auto", t("me.langAuto")), run: pick("auto") },
    { label: mark("hans", LANG_NAMES.hans), run: pick("hans") },
    { label: mark("hant", LANG_NAMES.hant), run: pick("hant") },
    { label: mark("en", LANG_NAMES.en), run: pick("en") },
  ]);
}
// notification state needs an async service worker query; redraw once when it arrives (wait up to 1.5 seconds, give up if it doesn't)
async function refreshPush() {
  try {
    const env = await Promise.race([pushEnv(), new Promise((_, rej) => setTimeout(() => rej(new Error("slow")), 1500))]);
    const s = pushStatus(env).state;
    if (s !== st.push) { st.push = s; st.crSig.me = ""; renderChat(); }
  } catch (e) { /* not available: don't show */ }
}

// guest's Me: profile card (guest nickname · bound session) + notification settings, sign out
function renderGuestMe() {
  const bound = guestBoundLabel(st.bound, st.snap.zones);
  const sig = JSON.stringify(["guest", bound, st.push, st.profile, st.profileUrl]);
  if (st.crSig.me === sig) return;
  st.crSig.me = sig;
  if (st.push == null) { st.push = ""; refreshPush(); }
  // the card shows the user's own avatar and nickname (profileView(st.profile) is the guest's own); tapping it opens profile editing
  const card = h("button", "me-card");
  card.type = "button";
  card.dataset.me = "card";
  const av = myAvatar("me-av"); // guest: use the avatar if set, otherwise the initial-letter square (same as in the chat)
  const id = h("div", "me-id");
  id.append(h("b", null, guestProfileView(st.profile).name), h("span", null, t("me.bound", { name: bound || t("me.unbound") })));
  card.append(av, id, svgEl(CHEV_SVG));
  const acts = h("section", "me-grp");
  acts.append(meRow("push", t("me.push"), pushText()), meRow("lang", t("me.lang"), langText()), meRow("logins", t("me.logins")), meRow("logout", t("me.logout")));
  $("#cr-me").replaceChildren(card, acts,
    h("div", "cr-foot", t("me.guestFoot", { tag: guestTag() })));
}

function renderMe() {
  if (st.guest) { renderGuestMe(); return; }
  const snap = st.snap;
  const u = snap.usage || {};
  const m = meStats(snap);
  const sig = JSON.stringify([m, u, Math.floor(snap.generatedAt / 60), (snap.sessions || []).length, (snap.offduty || []).length, st.offline, diagOn(), st.push, st.profile, st.profileUrl]);
  if (st.crSig.me === sig) return;
  st.crSig.me = sig;
  if (st.push == null) { st.push = ""; refreshPush(); }

  // profile card
  const card = h("button", "me-card");
  card.type = "button";
  card.dataset.me = "card";
  const pv = profileView(st.profile);
  let av;
  if (meCardAvatarKind(false, !!st.profileUrl) === "photo") av = myAvatar("me-av"); // use my avatar if set, otherwise the default terminal icon
  else {
    av = h("img", "me-av");
    av.src = "/icons/term-180.png";
    av.alt = "";
  }
  const id = h("div", "me-id");
  id.append(h("b", null, pv.isDefault ? t("me.adminName") : pv.name), h("span", null, t("me.adminId"))); // nickname never changed (profileView already replaced the server's default name with the localized "Me")
  card.append(av, id, svgEl(CHEV_SVG)); // tapping the card (avatar or name) opens profile editing directly, no separate row

  // three small cards
  const tiles = h("div", "me-tiles");
  const tile = (n, unit, label) => {
    const d = h("div", "me-tile");
    const num = h("div", "me-num");
    num.append(h("b", null, n));
    if (unit) num.append(h("small", null, unit));
    d.append(num, h("span", null, label));
    return d;
  };
  if (m) {
    const today = m.today.split(" ");
    tiles.append(tile(m.agents.toLocaleString("en-US"), "", t("me.agents")), tile(m.hours.n, m.hours.unit, t("me.hours")),
      tile(today[0], today[1] || "", t("me.today")));
  } else {
    tiles.append(tile("—", "", t("me.agents")), tile("—", "", t("me.hours")), tile("—", "", t("me.today")));
  }

  const nodes = [card, tiles];

  // usage overview: total tokens, estimated cost, active days, most active day + intensity grid of the last 6 weeks
  if (m) {
    const g = h("section", "me-grp me-use");
    const gh = h("div", "me-gh");
    gh.append(h("b", null, t("me.usage")), h("span", null, t("me.6w")));
    const kv = h("div", "me-kv");
    const cell = (label, val, note) => {
      const d = h("div");
      d.append(h("span", null, label), h("b", null, val));
      if (note) d.append(h("small", null, note));
      return d;
    };
    kv.append(cell(t("me.total"), m.total), cell(t("me.cost"), m.cost, t("me.costHint")), cell(t("me.days"), t("me.daysN", { n: m.activeDays })),
      cell(t("me.peak"), m.peak ? shortDay(m.peak.day) : "—", m.peak ? m.peak.tokens : ""));
    const heat = h("div", "me-heat");
    heat.setAttribute("role", "img");
    heat.setAttribute("aria-label", t("me.heat"));
    for (const w of weekHeads()) heat.append(h("span", "me-wd", w));
    for (const row of m.grid.rows) {
      for (const c of row) {
        const i = h("i", c ? "lv" + c.level : "lv-");
        if (c) i.title = shortDay(c.day) + " " + fmtTokens(c.tokens);
        heat.append(i);
      }
    }
    const leg = h("div", "me-leg");
    leg.append(h("span", null, t("me.less")));
    for (let i = 0; i <= 4; i++) leg.append(h("i", "lv" + i));
    leg.append(h("span", null, t("me.more")));
    g.append(gh, kv, heat, leg);
    if (m.costNote) g.append(h("p", "me-note", m.costNote));
    nodes.push(g);
  }

  // Claude quota (5 hours / this week)
  const quota = h("section", "me-grp");
  for (const [label, q] of [[t("me.q5h"), u.fiveHour], [t("me.qWeek"), u.sevenDay]]) {
    if (!q || q.pct == null) continue;
    const pct = Math.max(0, Math.min(100, Math.round(q.pct)));
    const row = h("div", "me-row me-q");
    const bar = h("span", "cr-bar " + usageColor(pct));
    const fill = h("i");
    fill.style.width = pct + "%";
    bar.append(fill);
    row.append(h("span", "me-k", label), bar, h("span", "me-v", pct + "%"));
    quota.append(row);
  }
  if (quota.children.length) nodes.push(h("div", "me-sec", t("me.quota")), quota);

  const acts = h("section", "me-grp");
  acts.append(meRow("mon", t("me.devices"), macLine(snap, { offline: st.offline, stale: !!snap.stale, at: hhmm(snap.generatedAt) }).off ? t("me.disconnected") : "Mac"),
    meRow("push", t("me.push"), pushText()), meRow("lang", t("me.lang"), langText()), meRow("seen", t("me.seenAll")), meRow("refresh", t("me.refresh")),
    meRow("diag", t("me.diag"), diagOn() ? t("c.on") : t("c.off")), meRow("logins", t("me.logins")));
  nodes.push(acts);
  nodes.push(h("div", "cr-foot", (st.offline ? t("me.footOffline") + (isEn() ? " " : "") : "") +
    t("me.foot", { t: hhmm(snap.generatedAt), on: (snap.sessions || []).length, off: (snap.offduty || []).length })));
  $("#cr-me").replaceChildren(...nodes);
}

// ---------- zone dashboard ----------
function renderZones() {
  const snap = st.snap;
  const cards = zoneBoard(snap);
  const zt = snap.zoneTokens || null;
  const asOf = boardAsOf(snap, st.offline, nowSec());
  const sig = JSON.stringify([cards, zt && zt.unmatched, asOf]);
  if (st.crSig.zones === sig) return;
  st.crSig.zones = sig;
  const nodes = [];
  for (const z of cards) {
    const c = h("div", "zc" + (z.taskboard ? " tap" : ""));
    c.style.setProperty("--zc", z.color);
    if (z.code != null) c.dataset.zone = z.code;
    if (z.code != null && z.taskboard) {
      c.setAttribute("role", "button");
      c.tabIndex = 0;
      c.setAttribute("aria-label", z.name + t("zb.openTb"));
    }
    const top = h("div", "zc-top");
    top.append(h("i", "zc-dot"), h("b", null, z.name));
    top.append(h("span", "zc-tb", z.code != null && z.taskboard ? t("zb.tb") : "")); // zones without a task board show no label
    if (z.taskboard) top.append(svgEl(CHEV_SVG));
    c.append(top);
    if (z.lead) {
      const ld = h("div", "zc-lead");
      ld.append(h("span", "zc-star", "★"), h("span", "zc-ln", z.lead), h("span", "zc-ls" + (z.leadOn ? " on" : ""), z.leadOn ? t("zb.on") : t("zb.notOn")));
      c.append(ld);
    }
    const stats = h("div", "zc-stats");
    const stat = (n, label, cls) => {
      const d = h("div", cls && n ? cls : "");
      d.append(h("b", null, String(n)), h("span", null, label));
      return d;
    };
    stats.append(stat(z.onDuty, t("zb.on")), stat(z.busy, t("zb.busy"), "g"), stat(z.waiting, t("zb.waiting"), "w"));
    if (z.tokens != null) {
      const tk = fmtTokens(z.tokens).split(" ");
      const d = h("div");
      const b = h("b", null, tk[0]);
      if (tk[1]) b.append(h("small", null, tk[1]));
      d.append(b, h("span", null, t("zb.today")));
      stats.append(d);
    }
    c.append(stats);
    if (asOf) c.append(h("div", "zc-asof", asOf));
    if (z.off) {
      const off = h("button", "zc-off");
      off.type = "button";
      off.dataset.offz = z.code == null ? "_none" : String(z.code);
      off.append(h("span", null, t("zb.offList", { n: z.off })), svgEl(CHEV_SVG));
      c.append(off);
    }
    nodes.push(c);
  }
  if (!cards.length) nodes.push(h("div", "cr-empty", t("zb.none")));
  const note = t("zb.note") + (zt && zt.unmatched > 0 ? paren(t("zb.unmatched", { n: fmtTokens(zt.unmatched) })) : "") + t("c.period");
  nodes.push(h("div", "cr-foot zb-foot", note));
  $("#zb").replaceChildren(...nodes);
}

// ---------- fullscreen page: slides up from the bottom (monitor, task board) ----------
const FS = { kind: null, code: null, sig: "" };
function openFs(kind, title) {
  const el = $("#fs");
  FS.kind = kind;
  FS.sig = "";
  setText($("#fs-t"), title);
  $("#fs-body").replaceChildren();
  $("#fs-body").scrollTop = 0;
  el.hidden = false;
  void el.offsetWidth; // lay out first and then add open, so the transition takes effect
  el.classList.add("open");
  document.body.classList.add("fs-open");
}
function closeFs() {
  const el = $("#fs");
  FS.kind = null;
  FS.code = null;
  el.classList.remove("open");
  document.body.classList.remove("fs-open");
  setTimeout(() => { if (!el.classList.contains("open")) el.hidden = true; }, 320);
}

// monitor page: a list-style page of logged-in devices. Data comes from the snapshot's monitor (the helper samples every 10 seconds)
const MAC_BIG = '<svg viewBox="0 0 64 64" width="72" height="72" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="12" width="46" height="31" rx="2.5"/><path d="M4 49h56l-3 4H7z"/><path d="M27 49.5h10"/></svg>';
const MON_IC = {
  bell: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6 16.5V11a6 6 0 0112 0v5.5l1.5 1.5h-15z"/><path d="M10 20.5a2 2 0 004 0"/></svg>',
  orca: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="17" height="17" rx="5"/><path d="M7 15.5c3 .4 5.5-.6 7.5-3.5M14 6.5l-1.5 11M14.5 9.5c1.8-.6 3.3-.4 4 .2"/></svg>',
  clock: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>',
};
function openMonitor() {
  openFs("mon", t("me.devices"));
  refreshPush();
  renderMonitor();
}
const pct1 = (x) => (x == null ? "—" : (x >= 10 ? Math.round(x) : x.toFixed(1)) + "%");
function monRow(label, sub, cpu, mem, cls) {
  const r = h("div", "mon-row" + (cls ? " " + cls : ""));
  const nm = h("div", "mon-nm");
  nm.append(h("span", null, label));
  if (sub) nm.append(h("small", null, sub));
  r.append(nm, h("span", "mon-c", cpu), h("span", "mon-m", mem));
  return r;
}
function healthRow(label, info, note) {
  const r = h("div", "mon-row mon-h");
  const v = h("span", "mon-hv " + info.cls);
  v.append(h("i"), document.createTextNode(info.text));
  r.append(h("span", "mon-nm", label), v);
  if (note) r.append(h("small", "mon-note", note));
  return r;
}
function renderMonitor() {
  if (FS.kind !== "mon" || !st.snap) return;
  const snap = st.snap;
  const mon = snap.monitor || null;
  const now = nowSec();
  const orca = snap.orca || {};
  const sig = JSON.stringify([mon, orca.running, st.push, Math.floor(now / 5), st.offline, snap.usage]);
  if (FS.sig === sig) return;
  FS.sig = sig;
  const mac = (mon && mon.mac) || {};
  const o = mon && mon.orca;
  const stale = monitorStale(mon && mon.at, now);

  const hero = h("div", "mon-hero");
  hero.append(svgEl(MAC_BIG), h("b", null, "Orca for Mac"), h("span", null, mac.name || t("mon.thisMac")));
  if (stale) hero.append(h("em", "mon-stale", stale));

  const acts = h("div", "mon-acts");
  const act = (icon, label, on, key) => {
    const b = h(key ? "button" : "div", "mon-act" + (on ? " on" : ""));
    if (key) { b.type = "button"; b.dataset.mon = key; }
    const c = h("i", "mon-circle");
    c.append(svgEl(icon));
    b.append(c, h("span", null, label));
    return b;
  };
  const pushOn = st.push === "subscribed";
  acts.append(act(MON_IC.bell, pushOn ? t("mon.pushOn") : t("mon.pushOff"), pushOn, "push"),
    act(MON_IC.orca, orca.running === false ? t("mon.orcaDown") : t("mon.orcaUp"), orca.running !== false),
    act(MON_IC.clock, t("mon.snap", { t: freshText(snap.generatedAt, now) }), !st.offline && !snap.stale && now - snap.generatedAt < 30, "refresh"));

  const nodes = [hero, acts];

  // Claude quota: first block; colors same as the status-line rings (<60 gray / 60-79 yellow / >=80 red)
  const u = snap.usage || {};
  const qg = h("section", "me-grp mon-grp");
  for (const [kind, label, q] of [["5H", t("mon.q5h"), u.fiveHour], ["7D", t("mon.q7d"), u.sevenDay]]) {
    if (!q || q.pct == null || !isFinite(Number(q.pct))) continue;
    const pct = Math.max(0, Math.min(100, Math.round(Number(q.pct))));
    const row = h("div", "mon-row mon-q " + meterLevel(pct));
    const top = h("div", "mon-qh");
    top.append(h("span", "mon-ql", label), h("b", "mon-qp", pct + "%"));
    const bar = h("span", "mon-qbar");
    const fill = h("i");
    fill.style.transform = "scaleX(" + pct / 100 + ")";
    bar.append(fill);
    row.append(top, bar, h("small", "mon-qc", quotaCaption(q, kind, now)));
    qg.append(row);
  }
  if (qg.children.length) nodes.push(h("div", "me-sec", t("me.quota")), qg);

  nodes.push(h("div", "me-sec", t("mon.orcaUse")));
  const og = h("section", "me-grp mon-grp");
  if (o) {
    og.append(monRow(t("mon.name"), "", "CPU", t("mon.mem"), "mon-th"));
    og.append(monRow(t("mon.app"), "", pct1(o.app && o.app.cpu), fmtBytes(o.app && o.app.memory, true), "mon-app"));
    for (const w of o.worktrees || []) {
      og.append(monRow(w.name, w.terminals ? t("mon.terms", { n: w.terminals }) : "", pct1(w.cpu), fmtBytes(w.memory, true)));
    }
    const rest = (o.worktreeCount || 0) - (o.worktrees || []).length;
    og.append(monRow(t("mon.total"), t("mon.projects", { n: o.worktreeCount || 0 }) + (rest > 0 ? t("mon.notListed", { n: rest }) : ""),
      pct1(o.totalCpu), fmtBytes(o.totalMemory, true), "mon-sum"));
  } else {
    og.append(h("div", "mon-empty", orca.running === false ? t("mon.orcaNotRunning") : t("mon.orcaNoData")));
  }
  nodes.push(og);

  nodes.push(h("div", "me-sec", t("mon.health")));
  const hg = h("section", "me-grp mon-grp");
  const mi = memInfo(mac.mem, mac.pressure);
  hg.append(healthRow(t("mon.pressure"), pressureInfo(mac.pressure)), healthRow(t("mon.mem"), mi), healthRow(t("mon.cached"), mi.cached),
    healthRow("Swap", swapInfo(mac.swap, mac.pressure || null), t("mon.swapNote")),
    healthRow(t("mon.load"), loadInfo(mac.load, mac.cores)), healthRow(t("mon.disk"), diskInfo(mac.disk)), healthRow(t("mon.battery"), batteryInfo(mac.battery)));
  nodes.push(hg);
  nodes.push(h("div", "cr-foot", t("mon.foot", { at: mon && mon.at ? t("mon.footAt", { t: hhmm(mon.at) }) : "", cores: mac.cores ? paren(mac.cores) : "" })));
  $("#fs-body").replaceChildren(...nodes);
}

// zone task board: read-only, rendered with md.js
async function openTaskboard(code) {
  const z = (st.snap.zones || []).find((x) => x.code === code);
  if (!z) return;
  if (!z.taskboard) return; // no task board configured for this zone: nothing to open, no hint
  openFs("tb", t("tb.title", { name: z.name }));
  FS.code = code;
  const body = $("#fs-body");
  body.replaceChildren(h("div", "tb-load", t("tb.loading")));
  let data = null;
  try {
    const res = await api("/api/zone/" + encodeURIComponent(code) + "/taskboard", null, FETCH_TIMEOUT_MS);
    if (res.ok) data = await res.json();
  } catch (e) { /* failure is shown below */ }
  if (FS.kind !== "tb" || FS.code !== code) return; // closed or switched while waiting
  if (!data) { body.replaceChildren(h("div", "tb-load", t("tb.fail"))); return; }
  const meta = h("div", "tb-meta", t("tb.ro") + (data.mtime ? " " + t("tb.updated", { t: chatTimeOf(data.mtime) }) : ""));
  const md = h("div", "md tb-md");
  try { mdBlocks(md, parseMarkdown(data.text || "")); } catch (e) { md.textContent = data.text || ""; diagErr("taskboard.md", e); } // falling back to plain text is also reported
  // table: short cells don't wrap (IDs and dates aren't split), long cells have a max width and wrap; the whole table scrolls sideways
  for (const c of md.querySelectorAll("td, th")) if (c.textContent.length > 14) c.classList.add("wrap");
  const nodes = [meta, md];
  if (data.truncated) nodes.push(h("div", "cr-foot", t("tb.cut")));
  body.replaceChildren(...nodes);
}
function chatTimeOf(sec) {
  const d = new Date(sec * 1000);
  return fmtMD(d) + (isEn() ? ", " : " ") + hhmm(sec);
}

// The app icon badge is synced here, together with the tab number, so local changes (markSeen / seenAll, which only call render) reach the icon at once,
// not only on the next snapshot poll (which never comes if the app is sent to the background within POLL_MS)
function renderBadge() {
  syncAppBadge(st.snap);
  const n = st.snap ? chatBadge(st.snap) : 0;
  const tb = $("#tb-msg");
  tb.hidden = !n;
  setText(tb, n > 99 ? "99+" : String(n));
  tb.parentElement.setAttribute("aria-label", n ? t("tab.msgAriaN", { n }) : t("tab.msgAria"));
}

// draw only the current tab
function renderChat() {
  renderBadge();
  if (!st.snap) return;
  if (st.searching) renderSearch();
  else if (st.tab === "msg") renderMsgs();
  else if (st.tab === "contacts") renderContacts();
  else if (st.tab === "zones") renderZones();
  else if (st.tab === "me") renderMe();
  if (FS.kind === "mon") renderMonitor();
}

function setCrH() {
  const nav = $("#cr-nav");
  if (!nav.hidden) document.documentElement.style.setProperty("--crh", nav.offsetHeight + "px");
}

function applyTab() {
  const t = st.tab;
  $("#cr-nav").hidden = false; // hidden in the shell until the first tab is applied
  $("#p-msg").hidden = st.searching || t !== "msg";
  $("#p-contacts").hidden = st.searching || t !== "contacts";
  $("#p-zones").hidden = st.searching || t !== "zones";
  $("#p-me").hidden = st.searching || t !== "me";
  $("#p-search").hidden = !st.searching;
  $("#cr-search").hidden = st.guest || t === "me" || t === "zones";
  renderTitle();
  document.body.classList.toggle("cr-searching", st.searching);
  // for wide-screen layout: two panes (messages/contacts) or content filling the area; only effective inside the wide-screen @media
  document.body.classList.toggle("split", wideSplit(t, st.guest));
  document.body.dataset.tab = t;
  for (const b of document.querySelectorAll(".cr-tab")) {
    const on = b.dataset.tab === t;
    b.classList.toggle("on", on);
    if (on) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current");
  }
  setCrH();
}

function setTab(tab) {
  if (st.searching) endSearch();
  if (tab === st.tab) { window.scrollTo({ top: 0, behavior: "smooth" }); return; }
  // wide screen: chat page next to the list (or covering the content area); close it when switching to a tab without panes. On phones the chat page covers the full screen and the tab bar can't be tapped, so this isn't reached
  if (isWide() && st.detailId && !keepDetailOnTab(st.tab, tab, st.guest)) closeDetail();
  st.tabScroll[st.tab] = window.scrollY;
  st.tab = tab;
  try { localStorage.setItem("zbs.tab", tab); } catch (e) { /* private mode can't store: ignore */ }
  applyTab();
  render();
  window.scrollTo(0, st.tabScroll[tab] || 0);
  deskAuto();
}

// guest on a desktop wide screen: only one session; when on "SoulChat" open it directly (if the session is offline stay on the list to show the hint; open it with the next snapshot once online)
function deskAuto() {
  const id = guestAutoOpen({ wide: isWide(), guest: st.guest, tab: st.tab, detailId: st.detailId, searching: st.searching,
    sessions: st.snap && st.snap.sessions });
  if (id) openDetail(id, undefined, "auto");
}

function endSearch() {
  const q = $("#cr-q");
  q.value = "";
  q.blur();
  st.q = "";
  st.searching = false;
  st.crSig.search = "";
  gsReset();
  $("#cr-clr").hidden = true;
  $("#cr-cancel").hidden = true;
  applyTab();
}

function scrollToEl(el) {
  if (!el) return;
  const top = el.getBoundingClientRect().top + window.scrollY - $("#cr-nav").offsetHeight;
  window.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
}

// double-click SoulChat: from the pre-click position find the next red-dot row (waiting for you / replied to you), wrapping at the end; with no red dot smooth-scroll to top
function jumpToDot(refY) {
  const navH = $("#cr-nav").offsetHeight;
  const rows = Array.from(document.querySelectorAll("#cr-msgs > li > .cr-row.w, #cr-msgs > li > .cr-row.u"))
    .map((el) => ({ id: el.dataset.id, el, top: Math.max(0, Math.round(el.getBoundingClientRect().top + window.scrollY - navH)) }));
  const i = nextDot(rows, refY, st.dotLast);
  if (i < 0) { st.dotLast = null; window.scrollTo({ top: 0, behavior: "smooth" }); return; }
  st.dotLast = rows[i].id;
  window.scrollTo({ top: rows[i].top, behavior: "smooth" });
}

// ---------- message row left swipe ----------
// only a clearly horizontal left swipe counts (swipeDecide); vertical is left to page scrolling (.cr-row sets touch-action: pan-y).
// only one row open at a time; tapping elsewhere or scrolling closes it; the open row id is kept in st.swipeId so the 2-second redraw doesn't close it.
let sw = null;
function closeSwipe() {
  const id = st.swipeId;
  if (!id) return;
  st.swipeId = null;
  const li = msgEls.get(id);
  if (!li) return;
  li.classList.remove("sw-open");
  li._p.row.style.transform = "";
  setTimeout(() => { if (st.swipeId !== id && !(sw && sw.li === li)) li.classList.remove("sw-on"); }, 320);
}
function bindSwipe() {
  const list = $("#cr-msgs");
  list.addEventListener("pointerdown", (e) => {
    if (st.guest || (e.pointerType === "mouse" && e.button)) return; // guests have no left-swipe menu
    if (e.pointerType === "mouse" && isWide()) return; // mouse dragging on desktop isn't a left swipe (right-click / long press opens the menu)
    const row = e.target.closest(".cr-row[data-id]");
    if (!row || !row.parentNode._p) return;
    sw = { li: row.parentNode, row, id: row.dataset.id, x0: e.clientX, y0: e.clientY, pid: e.pointerId,
      open: st.swipeId === row.dataset.id, base: 0, mode: "", w: 1, dx: 0 };
  });
  list.addEventListener("pointermove", (e) => {
    if (!sw || e.pointerId !== sw.pid) return;
    if (!sw.mode) {
      const m = swipeDecide(e.clientX - sw.x0, e.clientY - sw.y0, sw.x0, sw.open);
      if (!m) return;
      if (m === "v" || (crLp && crLp.fired)) { sw = null; return; }
      sw.mode = "h";
      if (st.swipeId && st.swipeId !== sw.id) closeSwipe();
      sw.li.classList.add("sw-on", "sw-drag");
      sw.w = sw.li._p.acts.offsetWidth || 1;
      sw.li.style.setProperty("--sw-w", sw.w);
      sw.base = sw.open ? -sw.w : 0;
      sw.x0 = e.clientX; // counted from the moment of takeover, so the row doesn't suddenly jump 12px
      try { sw.row.setPointerCapture(sw.pid); } catch (err) { /* works even without capture */ }
    }
    sw.dx = e.clientX - sw.x0;
    let x = Math.min(0, sw.base + sw.dx);
    if (x < -sw.w) x = -sw.w + (x + sw.w) / 3; // damping when pulled too far
    sw.row.style.transform = "translateX(" + x + "px)";
  });
  const end = (e) => {
    if (!sw || e.pointerId !== sw.pid) return;
    const g = sw;
    sw = null;
    if (g.mode !== "h") return;
    st.swipeEat = Date.now() + 400;
    g.li.classList.remove("sw-drag");
    g.row.style.transform = "";
    if (swipeSettle(g.base, g.dx, g.w)) {
      st.swipeId = g.id;
      g.li.classList.add("sw-open");
    } else {
      st.swipeId = g.id; // handed to closeSwipe for the common cleanup
      closeSwipe();
    }
  };
  list.addEventListener("pointerup", end);
  list.addEventListener("pointercancel", end);
  // pressed outside the open row: close it first, and this press no longer counts as a click (except the button itself)
  document.addEventListener("pointerdown", (e) => {
    if (!st.swipeId) return;
    const li = msgEls.get(st.swipeId);
    if (li && li.contains(e.target)) return;
    closeSwipe();
    st.swipeEat = Date.now() + 500;
  }, true);
  addEventListener("scroll", () => { if (st.swipeId && !sw) closeSwipe(); }, { passive: true });
  list.addEventListener("click", (e) => {
    const b = e.target.closest("[data-sw]");
    if (!b) return;
    e.stopPropagation();
    const li = b.closest("li");
    const s = li && li._p ? st.byId.get(li._p.row.dataset.id) : null;
    closeSwipe();
    if (s) swipeAct(b.dataset.sw, s);
  });
}
function reapply() { if (st.raw) applySnapshot(st.raw); }
async function swipeAct(key, s) {
  if (key === "off") { confirmOff(s); return; }
  const isRead = key === "seen" || key === "unseen";
  const flag = isRead ? { unread: key === "unseen" } : { rest: key === "rest" };
  st.flagOpt.set(s.id, { ...(st.flagOpt.get(s.id) || {}), at: Date.now(), ...flag });
  reapply();
  const undo = () => {
    const o = st.flagOpt.get(s.id);
    if (o) { for (const k of Object.keys(flag)) delete o[k]; }
    reapply();
  };
  try {
    const res = await post("/api/sessions/" + encodeURIComponent(s.id) + "/" + (isRead ? key : "rest"),
      isRead ? null : { on: key === "rest" });
    if (!res.ok) {
      undo();
      toast(res.status === 409 ? t("toast.noUnread") : res.status === 404 ? t("toast.gone") : t("c.opFail"));
      return;
    }
    if (key === "rest") toast(t("toast.rested"));
  } catch (e) {
    undo();
    if (e.message !== "auth") toast(t("c.opFail"));
  }
  refresh();
}
function confirmOff(s) {
  const name = plateOf(s);
  actionSheet(t("off.ask", { name }), [{ label: t("act.off"), cls: "danger", run: () => runOffduty(s) }],
    t("off.askHint"));
}
async function runOffduty(s) {
  if (st.offing.has(s.id)) return;
  const name = plateOf(s);
  st.offing.add(s.id);
  renderMsgs();
  toast(t("off.going", { name }), 30000);
  let r;
  try {
    r = await runJob("/api/sessions/" + encodeURIComponent(s.id) + "/offduty", () => true, OFF_MAX_MS, "offduty-timeout");
  } catch (e) {
    r = null; // login expired, redirected
    if (e.message !== "auth") diagErr("runOffduty", e);
  }
  st.offing.delete(s.id);
  if (r && r.status === "done") toast(t("off.done", { name }), 3500);
  else if (r) toast(t("off.failed", { why: offFailText(r) }), 5000);
  await refresh();
  renderMsgs();
}

// long press on a row (right-click on desktop): opens the row menu (openRowMenu)
let crLp = null;
function bindChat() {
  for (const b of document.querySelectorAll(".cr-tab")) b.onclick = () => {
    const t = b.dataset.tab;
    // double-click while the message tab is selected (< 350 ms): jump to the next session with a red dot; a single click still scrolls to top
    if (t === "msg" && st.tab === "msg" && !st.searching) {
      const now = Date.now();
      if (now - st.tabTapAt < 350) { st.tabTapAt = 0; jumpToDot(st.tabTapY); return; }
      st.tabTapAt = now;
      st.tabTapY = window.scrollY;
    } else st.tabTapAt = 0;
    setTab(t);
  };
  bindSwipe();
  const q = $("#cr-q");
  const enter = () => {
    if (st.searching) return;
    st.tabScroll[st.tab] = window.scrollY;
    st.searching = true;
    $("#cr-cancel").hidden = false;
    applyTab();
    renderSearch();
    window.scrollTo(0, 0);
  };
  $("#cr-title").onclick = openZoneSheet;
  q.addEventListener("focus", enter);
  q.addEventListener("input", () => {
    enter();
    st.q = q.value;
    $("#cr-clr").hidden = !q.value;
    renderSearch();
  });
  $("#cr-clr").addEventListener("click", (e) => {
    e.preventDefault();
    q.value = "";
    st.q = "";
    $("#cr-clr").hidden = true;
    renderSearch();
    q.focus();
  });
  $("#cr-cancel").onclick = () => { endSearch(); render(); window.scrollTo(0, st.tabScroll[st.tab] || 0); };
  addEventListener("resize", setCrH);
  addEventListener("resize", fitMacLine);
  addEventListener("scroll", () => $("#cr-nav").classList.toggle("solid", window.scrollY > 4), { passive: true });

  const cancel = () => { if (crLp) { clearTimeout(crLp.t); if (!crLp.fired) crLp = null; } };
  $("#cr-mac").onclick = () => { if (!st.guest) openMonitor(); };
  $("#fs-x").onclick = closeFs;
  $("#fs-body").onclick = (e) => {
    const b = e.target.closest("[data-mon]");
    if (!b) return;
    if (b.dataset.mon === "push") openPushSheet();
    else refresh().then(() => toast(st.offline ? t("toast.refreshFail") : t("toast.refreshed")));
  };
  for (const id of ["#p-msg", "#p-contacts", "#p-search", "#p-me", "#p-zones"]) {
    const pane = $(id);
    pane.addEventListener("pointerdown", (e) => {
      const r = e.target.closest(".cr-row[data-id]");
      if (!r) return;
      crLp = { r, x: e.clientX, y: e.clientY, fired: false, t: 0 };
      if (st.guest) { crLp = null; return; } // guests have no long-press menu
      crLp.t = setTimeout(() => {
        if (!crLp) return;
        crLp.fired = true;
        if (navigator.vibrate) navigator.vibrate(10);
        openRowMenu(r.dataset.id, r, crLp.x); // pop up a dark rounded menu next to the row
      }, LONG_PRESS_MS);
    });
    pane.addEventListener("pointermove", (e) => {
      if (crLp && !crLp.fired && Math.hypot(e.clientX - crLp.x, e.clientY - crLp.y) > 10) cancel();
    });
    for (const t of ["pointerup", "pointercancel", "pointerleave"]) pane.addEventListener(t, cancel);
    pane.addEventListener("contextmenu", (e) => {
      const r = e.target.closest(".cr-row[data-id]");
      if (!r) return;
      e.preventDefault();
      if (isWide() && !st.guest && e.button === 2) { if (crLp) { clearTimeout(crLp.t); crLp = null; } openRowMenu(r.dataset.id, r, e.clientX); } // right-click on desktop = long-press menu
    });
    pane.addEventListener("click", (e) => {
      // right after a left swipe is released / an open row was just collapsed: this click doesn't count (the open row is collapsed first)
      if (Date.now() < st.swipeEat) return;
      const open = st.swipeId && e.target.closest(".cr-row[data-id]");
      if (open && open.dataset.id === st.swipeId) { closeSwipe(); return; }
      if (e.target.closest("#cr-fold")) { st.restOpen = !st.restOpen; renderMsgs(); return; }
      const off = e.target.closest("[data-off]");
      if (off) { openOffDetail(off.dataset.off, undefined, "list"); return; }
      const row = e.target.closest(".cr-row[data-id]");
      if (row) {
        if (crLp && crLp.fired && crLp.r === row) { crLp = null; return; }
        crLp = null;
        openDetail(row.dataset.id, undefined, "list");
        return;
      }
      const jump = e.target.closest("[data-jump]");
      if (jump) { scrollToEl(document.getElementById(jump.dataset.jump)); return; }
      const act = e.target.closest("[data-act]");
      if (act) {
        const a = act.dataset.act;
        if (a === "off") { scrollToEl(document.querySelector(".cr-off-h")); return; }
        st.zone = "all";
        st.tabScroll.msg = 0;
        setTab("msg");
        toast(a === "wait" ? t("toast.waitTop") : t("toast.pinOrder"));
        return;
      }
      const offz = e.target.closest("[data-offz]");
      if (offz) { openOffSheet(offz.dataset.offz); return; }
      const zc = e.target.closest("[data-zone]");
      if (zc) { openTaskboard(zc.dataset.zone); return; }
      const me = e.target.closest("[data-me]");
      if (me) {
        const k = me.dataset.me;
        if (k === "logout") guestLogout();
        else if (k === "logins") openLoginsSheet(); // signed-in devices of this account (guests see only their own)
        else if (k === "lang") openLangSheet(); // language switch (guests have it too)
        else if (st.guest && !["push", "card", "profile"].includes(k)) return; // guest: notification settings, sign out, edit own profile
        else if (k === "mon") openMonitor(); // the monitor page is entered from the status line at the top of the message page (#cr-mac) and from this row
        else if (k === "card" || k === "profile") openProfileEdit(); // tapping the card edits the profile directly
        else if (k === "push") openPushSheet();
        else if (k === "seen") seenAll();
        else if (k === "refresh") refresh().then(() => toast(st.offline ? t("toast.refreshFail") : t("toast.refreshed")));
        else if (k === "diag") toggleDiag();
      }
    });
  }
}

// ---------- bottom sheet ----------
function openSheet(nodes, panel) {
  const wrap = $("#sheet-wrap");
  const sheet = $("#sheet");
  sheet.className = "sheet" + (panel ? " panel" : "");
  delete sheet.dataset.hl; // the helper list marks itself
  sheet.replaceChildren(...nodes);
  sheet.scrollTop = 0;
  wrap.hidden = false;
  void wrap.offsetWidth; // lay out first and then add open, so the transition takes effect
  wrap.classList.add("open");
}
function closeSheet() {
  const wrap = $("#sheet-wrap");
  if (wrap.hidden) return;
  if (st.push != null) refreshPush(); // may have just been toggled in the notification settings
  wrap.classList.remove("open");
  setTimeout(() => { if (!wrap.classList.contains("open")) wrap.hidden = true; }, 320);
}
// actions[].cls: danger = red text (like a destructive iOS action); hint: a gray line of explanation under the title
function actionSheet(title, actions, hint) {
  const g = h("div", "as-group");
  if (title) {
    const tt = h("div", "as-title" + (hint ? " big" : ""), title);
    if (hint) tt.append(h("small", null, hint));
    g.append(tt);
  }
  for (const a of actions) {
    const b = h("button", "as-btn" + (a.cls ? " " + a.cls : ""), a.label);
    b.type = "button";
    b.onclick = () => { closeSheet(); a.run(); };
    g.append(b);
  }
  const cg = h("div", "as-group");
  const cancel = h("button", "as-btn cancel", t("c.cancel"));
  cancel.type = "button";
  cancel.onclick = closeSheet;
  cg.append(cancel);
  openSheet([g, cg], false);
}

// ---------- row long-press (desktop right-click) menu: dark gray rounded vertical list, popping up next to the row (same shell as the bubble bm menu) ----------
// all actions reused: pin = setTop (permanent pin), unread/read/rest/back/off duty = the left-swipe swipeAct, do-not-disturb = chSetMute
function openRowMenu(id, row, px) {
  const s = st.byId.get(id);
  const acts = rowMenuActs(s, st.guest);
  if (!acts.length || !row) return;
  closeSwipe();
  const box = h("div", "jr-menu");
  for (const a of acts) {
    if (a.sep) { box.append(h("div", "jr-sep")); continue; }
    box.append(bmButton(a.label, a.danger ? "jr-danger" : "", () => rowMenuRun(a.key, id)));
  }
  const nav = $("#cr-nav") && $("#cr-nav").getBoundingClientRect();
  const tb = $("#tabbar") && $("#tabbar").getBoundingClientRect();
  const vp = { top: nav && nav.bottom > 0 ? nav.bottom : 0, bottom: tb && tb.height ? tb.top : innerHeight, left: 0, right: innerWidth };
  // next to the row, horizontally aligned with the press position (right-click / long-press point), or the row's center line if none
  const r = row.getBoundingClientRect();
  const x = Number.isFinite(px) ? px : r.left + r.width / 2;
  openBubblePop(row, box, "jr-pop", vp);
  const pop = bmState.pop;
  const pl = menuPlace({ left: x, right: x, top: r.top, bottom: r.bottom }, pop.offsetWidth, pop.offsetHeight, vp);
  pop.style.left = pl.x + "px";
  pop.style.top = pl.y + "px";
  pop.classList.toggle("below", pl.below);
  pop.querySelector(".bm-arrow").style.left = Math.max(14, Math.min(pop.offsetWidth - 14, pl.ax)) + "px";
  bmState.row = true;
}
// row menu action key -> handler; keys not listed (seen / unseen / rest / back / off) go to swipeAct (off duty goes through the confirmOff sheet)
const ROW_MENU_RUN = {
  top: (s) => setTop(s, true), untop: (s) => setTop(s, false), // permanent pin
  mute: (s) => chSetMute(s, true), unmute: (s) => chSetMute(s, false),
};
function rowMenuRun(k, id) {
  const s = st.byId.get(id);
  if (!s) return;
  (ROW_MENU_RUN[k] || ((x) => swipeAct(k, x)))(s);
}
addEventListener("scroll", () => { if (bmState && bmState.row) closeBubbleMenu(); }, { passive: true });

// on open or return to foreground, clear from the notification center the notifications of sessions already handled (no longer waiting / unread)
// opening a session immediately clears this device's notifications for it (without waiting for unread to turn false in the snapshot and the Mac to write the read state back)
async function closeSessionNotifs(id) {
  if (!("serviceWorker" in navigator) || !("Notification" in window)) return;
  try {
    const reg = await navigator.serviceWorker.ready;
    for (const n of await reg.getNotifications({ tag: "s-" + id })) n.close();
  } catch (e) { /* unsupported: ignore */ }
}
async function closeStaleNotifs(sessions) {
  if (!("serviceWorker" in navigator) || !("Notification" in window)) return;
  try {
    const reg = await navigator.serviceWorker.ready;
    const list = await reg.getNotifications();
    const stale = new Set(staleTags(list.map((n) => n.tag), sessions, true)); // call only when the snapshot is fresh: also clears the mac-link one
    for (const n of list) if (stale.has(n.tag)) n.close();
  } catch (e) { /* unsupported: ignore */ }
}

// ---------- notification settings ----------
async function pushEnv() {
  const sw = "serviceWorker" in navigator;
  const env = {
    sw, push: "PushManager" in window, notif: "Notification" in window,
    standalone: isStandalone(),
    permission: "Notification" in window ? Notification.permission : "default", subscribed: false,
  };
  if (sw && env.push) {
    try {
      const reg = await navigator.serviceWorker.ready;
      env.subscribed = !!(await reg.pushManager.getSubscription());
    } catch (e) { /* treat as unsubscribed */ }
  }
  return env;
}

async function enablePush() {
  const res = await api("/api/push/key", null, FETCH_TIMEOUT_MS);
  if (!res.ok) throw new Error("no key");
  const { key } = await res.json();
  if (await Notification.requestPermission() !== "granted") return;
  const reg = await navigator.serviceWorker.ready;
  const sub = (await reg.pushManager.getSubscription()) || await reg.pushManager.subscribe({
    userVisibleOnly: true, applicationServerKey: urlB64ToBytes(key),
  });
  const r = await post("/api/push/subscribe", pushSubBody(sub.toJSON(), lang(), devInfo()), FETCH_TIMEOUT_MS); // carries the UI language and device info
  if (!r.ok) throw new Error("subscribe");
}

// Device identity: dev is generated at first launch and then stays (home-screen app, dock app and browser tab each have their own storage);
// plat is a rough split by UA; standalone = whether it is a home-screen / dock app. If it can't be stored in localStorage (private mode) a new one is generated each time, and this device just counts as new
const DEV_KEY = "zbs.dev";
let devCache = "";
function devId() {
  if (devCache) return devCache;
  try { devCache = localStorage.getItem("zbs.dev") || ""; } catch (e) { /* private mode */ }
  if (!/^[A-Za-z0-9_-]{8,40}$/.test(devCache)) {
    const b = new Uint8Array(16);
    try { crypto.getRandomValues(b); } catch (e) { /* no crypto: newDevId falls back to Math.random */ }
    devCache = newDevId(b);
    try { localStorage.setItem(DEV_KEY, devCache); } catch (e) { /* can't store: ignore */ }
  }
  return devCache;
}
function isStandalone() {
  return navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;
}
function devInfo() {
  return { dev: devId(), plat: devPlat(navigator.userAgent, navigator.maxTouchPoints), standalone: isStandalone() };
}
// The push text is generated by the server in the language stored with the subscription; re-register on every launch (same endpoint overwrites): UI language and device info are updated,
// and old subscriptions gain device info too (online but not re-registered for 14 days counts as a dead subscription); subscriptions the server deleted on 404/410 are registered back here
async function syncPush() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) return;
  if (Notification.permission !== "granted") return;
  const reg = await navigator.serviceWorker.ready;
  const sub = await reg.pushManager.getSubscription();
  if (!sub) return;
  await post("/api/push/subscribe", pushSubBody(sub.toJSON(), lang(), devInfo()), FETCH_TIMEOUT_MS);
}

async function openPushSheet() {
  const title = h("div", "as-title", t("push.title"));
  const status = h("div", "hint");
  const hintEl = h("div", "hint");
  const on = h("button", "as-btn", t("push.enable"));
  const test = h("button", "as-btn", t("push.test"));
  const close = h("button", "as-btn cancel", t("c.close"));
  for (const b of [on, test, close]) b.type = "button";
  const g = h("div", "as-group");
  g.append(title, status, hintEl, on, test);
  let devN = null; // number of devices on this account (/api/push/devices; omit the count if unavailable)
  // device list: all devices on this account with notifications on, with type, last active, whether this device, deletable; not shown if unavailable (old api / offline)
  const dg = h("div", "as-group pd-list");
  dg.hidden = true;
  const cg = h("div", "as-group");
  cg.append(close);
  close.onclick = closeSheet;
  const paint = async () => {
    const s = pushStatus(await pushEnv());
    status.textContent = s.state === "subscribed" ? pushDevLine(devInfo(), s.text, devN) : s.text;
    hintEl.textContent = s.hint;
    hintEl.hidden = !s.hint;
    on.disabled = s.state === "unsupported" || s.state === "denied" || s.state === "subscribed";
    test.disabled = s.state !== "subscribed";
    test.hidden = st.guest; // test notifications go to all admin devices, not for guests
  };
  const paintDevs = (devs) => {
    const rows = deviceRows(devs, Date.now() / 1000);
    const head = h("div", "as-title", t("push.devList"));
    const items = rows.map((row) => {
      const li = h("div", "pd-row" + (row.self ? " self" : ""));
      li.dataset.key = row.key;
      const tx = h("div", "pd-tx");
      const nm = h("b", "pd-nm", row.label);
      if (row.self) nm.append(h("span", "pd-me", t("push.devSelf")));
      tx.append(nm, h("small", "pd-last", row.last));
      const del = h("button", "pd-del", t("push.devDel"));
      del.type = "button";
      del.onclick = () => askDeleteDevice(row);
      li.append(tx, del);
      return li;
    });
    dg.replaceChildren(head, ...(items.length ? items : [h("div", "hint", t("push.devNone"))]));
    dg.hidden = false;
  };
  const loadDevs = async () => {
    try {
      // carries this device's id: the server uses it to mark which entry is this device
      const res = await api("/api/push/devices", { headers: { "X-Zbs-Dev": devId() } }, FETCH_TIMEOUT_MS);
      if (res.ok) { const d = await res.json(); if (Array.isArray(d.devices)) { devN = d.devices.length; paint(); paintDevs(d.devices); } }
    } catch (e) { /* old api / offline: omit the count, don't list devices */ }
  };
  on.onclick = async () => {
    on.disabled = true;
    try { await enablePush(); } catch (e) { if (e.message !== "auth") toast(t("push.enableFail", { e: e.message })); }
    paint();
  };
  test.onclick = async () => {
    test.disabled = true;
    try {
      const res = await post("/api/push/test", {}, FETCH_TIMEOUT_MS);
      const d = await res.json();
      toast(res.ok ? t("push.sent", { a: d.sent, b: d.subscriptions }) : t("push.sendFailN", { n: res.status }), 4000);
    } catch (e) {
      if (e.message !== "auth") toast(t("send.fail"));
    }
    paint();
  };
  openSheet([g, dg, cg], false);
  paint();
  loadDevs();
}

// delete a device: confirm first (deleting this device warns that its push will stop), then return to notification settings
function askDeleteDevice(row) {
  const ask = deviceDelAsk(row);
  actionSheet(ask.title, [{ label: t("push.devDel"), cls: "danger", run: () => deleteDevice(row) }], ask.hint);
}
async function deleteDevice(row) {
  try {
    const res = await post("/api/push/devices/delete", { key: row.key }, FETCH_TIMEOUT_MS);
    if (!res.ok && res.status !== 404) throw new Error("http " + res.status);
    if (row.self) {
      // deleting this device: also unsubscribe in the browser, otherwise syncPush registers it again on the next launch
      try {
        const reg = await navigator.serviceWorker.ready;
        const sub = await reg.pushManager.getSubscription();
        if (sub) await sub.unsubscribe();
      } catch (e) { /* unsubscribe failed: the server entry is already deleted, it will be registered again on the next launch */ }
    }
    toast(t("push.devDeleted"));
  } catch (e) {
    if (e.message !== "auth") toast(t("c.opFail"));
  }
  openPushSheet();
}

// Signed-in devices of this account (/api/auth/devices): description, last used, this device; each can be signed out.
// Signing out this device goes through guestLogout (unsubscribe push, POST /api/auth/logout which deletes this token, clear the offline snapshot cache)
async function openLoginsSheet() {
  const g = h("div", "as-group pd-list");
  g.append(h("div", "as-title", t("signin.title")), h("div", "hint", t("c.loading")));
  const close = h("button", "as-btn cancel", t("c.close"));
  close.type = "button";
  close.onclick = closeSheet;
  const cg = h("div", "as-group");
  cg.append(close);
  openSheet([g, cg], false);
  let devs = null;
  try {
    const res = await api("/api/auth/devices", null, FETCH_TIMEOUT_MS);
    if (res.ok) { const d = await res.json(); if (Array.isArray(d.devices)) devs = d.devices; }
  } catch (e) {
    if (e.message === "auth") return;
  }
  if (!devs) { g.replaceChildren(h("div", "as-title", t("signin.title")), h("div", "hint", t("c.loadFail"))); return; }
  const rows = loginRows(devs, Date.now() / 1000);
  const items = rows.map((row) => {
    const li = h("div", "pd-row" + (row.self ? " self" : ""));
    const tx = h("div", "pd-tx");
    const nm = h("b", "pd-nm", row.label);
    if (row.self) nm.append(h("span", "pd-me", t("signin.self")));
    tx.append(nm, h("small", "pd-last", row.last));
    const out = h("button", "pd-del", t("signin.out"));
    out.type = "button";
    out.onclick = () => askRevokeLogin(row);
    li.append(tx, out);
    return li;
  });
  g.replaceChildren(h("div", "as-title", t("signin.title")), ...(items.length ? items : [h("div", "hint", t("signin.none"))]),
    h("div", "hint", t("signin.hint")));
}
function askRevokeLogin(row) {
  const ask = loginRevokeAsk(row);
  actionSheet(ask.title, [{ label: t("signin.out"), cls: "danger", run: () => revokeLogin(row) }], ask.hint);
}
async function revokeLogin(row) {
  if (row.self) { guestLogout(); return; }
  try {
    const res = await post("/api/auth/devices/revoke", { id: row.id }, FETCH_TIMEOUT_MS);
    if (!res.ok && res.status !== 404) throw new Error("http " + res.status);
    toast(t("signin.outDone"));
  } catch (e) {
    if (e.message !== "auth") toast(t("c.opFail"));
  }
  openLoginsSheet();
}

async function seenAll() {
  for (const s of st.byId.values()) s.unread = false;
  render();
  try {
    const res = await post("/api/seen-all");
    if (!res.ok) throw new Error();
    toast(t("toast.allSeen"));
  } catch (e) {
    if (e.message !== "auth") toast(t("c.opFail"));
  }
  refresh();
}

// off-duty list of this zone: name + how long off duty, newest off-duty first (already sorted by buildLanes)
function openOffSheet(key) {
  const L = buildLanes(st.snap || {}).find((x) => (x.code == null ? "_none" : String(x.code)) === key);
  const list = L ? L.off : [];
  const now = nowSec();
  const ul = h("div", "wl");
  for (const o of list) {
    const row = h("button", "wl-item");
    row.type = "button";
    const tx = h("div", "tx");
    const b = h("b");
    const dot = h("i");
    dot.style.background = (L && L.color) || "#8A8F98";
    b.append(dot, document.createTextNode(o.name));
    tx.append(b);
    row.append(tx, h("time", null, offLine(o.offAt, now)));
    row.onclick = () => { closeSheet(); openOffDetail(o.sid, undefined, "waiting"); };
    ul.append(row);
  }
  openSheet([h("div", "grabber"), h("h3", null, (L ? L.name + " · " : "") + t("sheet.offN", { n: list.length })), ul], true);
}

// ---------- hints ----------
let toastTimer = 0;
function toast(msg, ms) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), ms || 2600);
}

// ---------- chat page ----------
function fillDetailHeader(s) {
  setPet($("#d-pet"), s);
  $("#d-pet").parentNode.classList.toggle("wait", s.status === "waiting"); // waiting for you: the header avatar is still, same as in the list
  syncFire($("#d-pet").parentNode, $("#d-pet"), fireLevel(s)); // header avatar fire layer (inside .mini, before #d-pet)
  syncChatFire();
  setText($("#d-name"), plateOf(s));
  const z = zoneOf(s.zone);
  $("#d-name").classList.toggle("lead", !s.pinned && z.lead != null && s.name === z.lead);
  $("#d-zone").style.background = z.color;
  const mv = s.kind === "claude" ? metaView(s.meta, nowSec()) : null;
  setText($("#d-sub"), mv && mv.line ? mv.line : z.name + " · " + (s.project || s.cwd || ""));
  renderCtx(mv);
  syncReplyUI(s);
  updateBusy(s);
  renderAlert(s);
}
// hint bar at the top of the chat page: unexpected exit / error / quota used up / retrying / context just compacted (logic.js chatAlert).
// Same position as the "Mac disconnected" gray bar: yields to it when the Mac is disconnected; not shown on off-duty and sub-agent pages
function renderAlert(s) {
  const el = $("#d-alert");
  if (!el) return;
  const v = !s || st.down || st.detailOff || st.agentView ? null : chatAlert(s, nowSec()) || formatAlert(st.guest, st.fmtWarn, s);
  el.hidden = !v;
  if (!v) return;
  const cls = "d-down d-alert " + v.cls;
  if (el.className !== cls) el.className = cls;
  setText(el, v.text);
}
// two small lines to the right of the header name (dispatch / queued, working N min); not shown on off-duty and sub-agent pages; the queued count only trusts what the first page of this session returned
function renderStat(s) {
  const el = $("#d-stat");
  if (!el) return;
  const v = !s || st.detailOff || st.agentView ? { top: "", bottom: "" }
    : headStat(s);
  setText(el.children[0], v.top);
  setText(el.children[1], v.bottom);
  el.hidden = !v.top && !v.bottom;
  if (el.hidden) closeHelperSheet();
  else if (helperSheetOpen()) fillHelperSheet(s, true);
  el.setAttribute("aria-label", t("head.helperAria"));
}

// ---------- header helper list (opened from the "SA N · BG M" pill; data follows the snapshot; tapping a row jumps to the matching tag / crab in the chat) ----------
const helperSheetOpen = () => !$("#sheet-wrap").hidden && $("#sheet-wrap").classList.contains("open") && $("#sheet").dataset.hl === "1"; // the sheet currently shown is the helper list
const HL_ICON = {
  agent: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="3.2"/><path d="M5.5 20a6.5 6.5 0 0113 0"/></svg>',
  cmd: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 7l5 5-5 5M12 18h7"/></svg>',
  chev: '<svg class="hl-chev" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg>',
};
function helperRow(kind, big, small, time, tu) {
  const b = h("button", "hl-item" + (kind === "cmd" ? " bg" : ""));
  b.type = "button";
  const ic = h("span", "hl-ic");
  ic.innerHTML = HL_ICON[kind];
  const tx = h("span", "hl-tx");
  tx.append(h("b", null, big), h("small", null, small));
  b.append(ic, tx);
  if (time) b.append(h("span", "hl-time", time));
  const chev = h("span");
  chev.innerHTML = HL_ICON.chev;
  b.append(chev.firstChild);
  b.onclick = () => { closeSheet(); setTimeout(() => helperJump(tu, kind), 340); };
  return b;
}
function fillHelperSheet(s, refresh) {
  const v = helperSheet(s, nowSec());
  const sig = JSON.stringify([v.title, v.rows.map((r) => [r.desc, r.toolUseId, r.time]), v.cmdOnly, v.more]);
  if (refresh && $("#sheet")._hlSig === sig) return; // not redrawn if unchanged (otherwise it flashes every 3 seconds and swallows taps)
  const list = h("div", "hl-list");
  if (v.has) {
    for (const r of v.rows) list.append(helperRow(r.kind, r.desc || (r.kind === "agent" ? t("c.subagent") : "…"), r.kind === "agent" ? t("c.subagent") : t("head.helperBg"), r.time, r.toolUseId));
  } else if (v.cmdOnly > 0) {
    list.append(helperRow("cmd", t("head.helperBgN", { n: v.cmdOnly }), t("head.helperBg"), "", ""));
  }
  const kids = [h("div", "grabber"), h("h3", null, v.title), h("div", "sub", t("head.helperTip")), list];
  if (v.more > 0) kids.push(h("div", "hl-foot", t("head.helperMore", { n: v.more })));
  kids.push(h("div", "hl-foot", t("head.helperFoot")));
  openSheet(kids, true);
  $("#sheet").dataset.hl = "1";
  $("#sheet")._hlSig = sig;
}
function openHelperSheet() {
  const s = st.detailOff || st.agentView ? null : st.byId.get(st.detailId);
  if (!s || $("#d-stat").hidden) return;
  fillHelperSheet(s);
}
function closeHelperSheet() {
  if (helperSheetOpen()) closeSheet();
}
// jump to the tool tag in the chat that started the background task (where the crab is) or to the sub-agent tag, and flash twice; if not found (in older history) show a hint.
// Which to look for first is set by helperJumpOrder: sub-agent rows look for the sub-agent tag .ag-flip first (then fall back to the tool tag), background command rows look for the tool tag first
function helperJump(tu, kind) {
  const s = st.byId.get(st.detailId);
  const id = bgJumpTu({ toolUseId: tu }, st.shown || st.items || []) || "";
  const list = $("#list");
  let el = null;
  if (id) {
    const li = [...list.querySelectorAll("li[data-tu]")].find((x) => x.dataset.tu === id);
    const find = {
      tu: () => (li ? li.closest(".tools") || li : null),
      ag: () => { // figure anchor key: the group in figPlan that contains this id; otherwise the group holding the tool tag's data-fig
        const e = (st.figPlan || []).find((x) => x.figs.some((f) => f.id === id));
        const key = e ? e.key : li && li.closest(".tools[data-fig]") ? li.closest(".tools[data-fig]").dataset.fig : "";
        if (!key) return null;
        return [...list.querySelectorAll(".ag-flip[data-ag]")].find((x) => x.dataset.ag === key)
          || [...list.querySelectorAll(".tools[data-fig]")].find((x) => x.dataset.fig === key) || null;
      },
    };
    for (const k of helperJumpOrder(kind)) { el = find[k](); if (el) break; }
  }
  if (!el || !s) { toast(t("head.helperGone")); return; }
  el.scrollIntoView({ block: "center", behavior: agReduce() ? "auto" : "smooth" });
  el.classList.remove("bg-flash");
  void el.offsetWidth;
  el.classList.add("bg-flash");
  setTimeout(() => el.classList.remove("bg-flash"), 1700);
}

// the "session" on the chat page: an off-duty entry has no live state, so build a read-only one
function offAsSession(o) {
  return { id: o.sid, name: o.name, plate: o.name, zone: o.zone, kind: "claude", status: "idle", rest: true };
}
function fillOffHeader(o) {
  const s = offAsSession(o);
  renderAlert(null); // hint bar: not shown on the off-duty page
  setPet($("#d-pet"), s);
  $("#d-pet").parentNode.classList.remove("wait");
  syncFire($("#d-pet").parentNode, $("#d-pet"), null); // off-duty entries don't burn
  setText($("#d-name"), o.name);
  const z = (st.snap.zones || []).find((x) => x.code === o.zone) || { color: "#8A8F98" };
  $("#d-zone").style.background = z.color;
  setText($("#d-sub"), offHeader(o.offAt, nowSec()));
  renderCtx(null);
  updateBusy(null);
  syncOrcaUI();
}

// context ring at the right of the chat header: with no data an empty gray ring (no number or t/s) is drawn and is still tappable; stale data is dimmed; tapping opens the bottom sheet
function renderCtx(mv) {
  const btn = $("#d-ctx");
  const ring = mv && mv.ring;
  btn.hidden = false;
  const box = $("#d-ctx-svg");
  if (!ring) {
    btn.className = "d-ctx none";
    if (box.dataset.k !== "none") { box.dataset.k = "none"; box.innerHTML = ringSvg(0, 29, 2.5); }
    setText($("#d-ctx-p"), "");
    setText($("#d-ctx-tps"), "");
    btn.setAttribute("aria-label", t("ctx.ariaNone"));
    return;
  }
  const prevCl = btn.dataset.cl || "";
  const cl = ring.cl || "ok";
  btn.className = "d-ctx lv-" + cl + (ring.stale ? " stale" : "");
  btn.dataset.cl = cl;
  const LVR = { ok: 0, warn: 1, bad: 2 }; // jump once lightly when crossing the threshold (upward)
  if (prevCl && prevCl !== "n" && cl !== "n" && LVR[cl] > LVR[prevCl]) {
    btn.classList.add("lv-hop");
    setTimeout(() => btn.classList.remove("lv-hop"), 450);
  }
  const key = String(ring.pct);
  if (box.dataset.k !== key) { box.dataset.k = key; box.innerHTML = ringSvg(ring.pct, 29, 2.5); }
  setText($("#d-ctx-p"), String(ring.pct));
  setText($("#d-ctx-tps"), mv.tps);
  btn.setAttribute("aria-label", ring.tip);
}
// bottom sheet opened by the ring: top half is context usage (recomputed from the latest snapshot, one every 3 seconds), bottom half is a few chat-page actions
function openCtxPanel() {
  const acts = detailActs();
  const s = st.detailOff ? null : st.byId.get(st.detailId);
  const p = ctxPanel(s && s.kind === "claude" ? s.meta : null, nowSec());
  const box = h("div", "cp-ctx " + p.lv + (p.has ? "" : " none") + (p.stale ? " stale" : ""));
  if (p.has) {
    const hd = h("div", "cp-hd");
    hd.append(h("span", "cp-u", p.usage), h("b", "cp-p", p.pct + "%"));
    const mt = s.meta || {};
    const bd = ctxBreakdown({ used: mt.ctxUsed, window: mt.ctxWindow, pct: p.pct });
    let bar;
    if (bd.segs.length) { bar = h("span", "ctx-stack"); ctxFillStack(bar, bd); } // segmented bar (first draw the used/Free segments, split further when the detail arrives)
    else {
      bar = h("span", "cp-bar");
      const fill = h("i");
      fill.style.width = p.pct + "%";
      bar.append(fill);
    }
    const meta = h("small", "cp-meta", [p.tps, p.ageText].filter(Boolean).join(" · "));
    box._ctx = { bar, meta, base: [p.tps, p.ageText].filter(Boolean), win: mt.ctxWindow, used: mt.ctxUsed, pct: p.pct };
    box.append(hd, bar, meta);
  } else {
    box.append(h("span", "cp-u", p.usage));
    if (p.tps) box.append(h("small", "cp-meta", p.tps));
  }
  const g = h("div", "cp-acts");
  for (const a of acts) {
    const b = h("button", "cp-btn", a.label);
    b.type = "button";
    b.onclick = () => { closeSheet(); a.run(); };
    g.append(b);
  }
  const nodes = [h("div", "grabber"), h("h3", null, t("ctx.title")), box];
  if (s && s.kind === "claude") { // guests can also see the context detail of the bound session (read-only)
    const dt = h("div", "cp-dt");
    dt.append(h("div", "cp-dt-msg", t("ctx.loading")));
    nodes.push(dt);
    dt._box = box;
    loadCtxDetail(s.id, dt, ++st.ctxSeq);
  } else {
    st.ctxSeq += 1;
  }
  nodes.push(g);
  openSheet(nodes, true);
}
// context detail: GET /api/session/<id>/context -> if done draw directly; if pending ask /api/requests/<rid> every second, up to 25 seconds.
// stop when the sheet is closed or replaced by another sheet (seq changed).
async function loadCtxDetail(sid, dt, seq) {
  const t0 = Date.now();
  const alive = () => seq === st.ctxSeq && dt.isConnected && $("#sheet-wrap").classList.contains("open");
  const fail = (txt) => { if (alive()) dt.replaceChildren(h("div", "cp-dt-msg err", txt)); };
  let body = null;
  try {
    const r = await api("/api/session/" + encodeURIComponent(sid) + "/context", null, FETCH_TIMEOUT_MS);
    if (!r.ok) return fail(r.status === 404 ? t("fail.session-gone") : t("ctx.failN", { n: r.status }));
    body = await r.json();
  } catch (e) {
    return fail(t("ctx.net"));
  }
  const rid = body && body.rid;
  while (body && body.status === "pending") {
    if (!alive()) return;
    if (Date.now() - t0 >= CTX_MAX_MS) return fail(failReason("context-timeout"));
    await new Promise((ok) => setTimeout(ok, CTX_POLL_MS));
    if (!alive()) return;
    try {
      const r = await api("/api/requests/" + encodeURIComponent(rid), null, FETCH_TIMEOUT_MS);
      if (r.status === 404 && Date.now() - t0 < 8000) continue; // just enqueued, the api hasn't seen the file yet
      if (!r.ok) return fail(t("ctx.failN", { n: r.status }));
      body = await r.json();
    } catch (e) { /* one network blip: ask again next second */ }
  }
  if (!alive()) return;
  if (!body || body.status !== "done" || !body.data) return fail(failReason(body && body.error, t("fail.context-failed")));
  renderCtxDetail(dt, body.data, body.at);
}
// bar (four segments: msg / sys / oth / free, or just used / free); segment width is its share of the total window
function ctxFillStack(bar, bd) {
  bar.replaceChildren(...bd.segs.map((g) => { const i = h("i", "ctx-" + g.k); i.style.flex = Math.max(g.tokens, 0) + " 1 0"; return i; }));
}
function ctxLegItem(r) {
  const it = h("div", "ctx-it ctx-" + r.seg);
  const nu = h("span", "ctx-nu");
  nu.append(h("b", null, r.text), document.createTextNode(r.pctText));
  it.append(h("i", "ctx-dot"), h("span", "ctx-nm", r.name), nu);
  return it;
}
function renderCtxDetail(dt, data, at) {
  const v = ctxRows(data);
  const bd = ctxBreakdown(data);
  const box = dt._box;
  if (box && box._ctx) { // top: split the bar further and add the model in small text
    if (bd.segs.length && bd.segs[0].k !== "used" && box._ctx.bar.classList.contains("ctx-stack")) ctxFillStack(box._ctx.bar, bd);
    setText(box._ctx.meta, [...box._ctx.base, v.model].filter(Boolean).join(" · "));
  }
  const out = [];
  if (bd.big.length) {
    const lg = h("div", "ctx-lg");
    for (const r of bd.big) lg.append(ctxLegItem(r));
    out.push(lg);
    if (bd.small.length) {
      const more = h("details", "ctx-more");
      const sm = h("summary");
      sm.append(h("span", null, bd.smallTitle), h("small", null, bd.smallText));
      const lg2 = h("div", "ctx-lg");
      for (const r of bd.small) lg2.append(ctxLegItem(r));
      more.append(sm, lg2);
      out.push(more);
    }
  }
  if (v.groups.length) {
    const grid = h("div", "ctx-grps"), lists = h("div");
    for (const g of v.groups) {
      const b = h("button", "ctx-grp");
      b.type = "button";
      b.append(h("span", null, g.title), h("small", null, String(g.count)));
      const l = h("div", "ctx-gl");
      for (const it of g.items) {
        const row = h("div", "cp-it");
        const nm = h("span", "cp-it-name");
        nm.append(h("span", null, it.name));
        if (it.sub) nm.append(h("small", null, it.sub));
        row.append(nm, h("b", null, it.text));
        l.append(row);
      }
      b.onclick = () => {
        const on = !l.classList.contains("on");
        for (const e of dt.querySelectorAll(".ctx-gl.on, .ctx-grp.on")) e.classList.remove("on");
        if (on) { l.classList.add("on"); b.classList.add("on"); }
      };
      grid.append(b); lists.append(l);
    }
    out.push(grid, lists);
  }
  dt.replaceChildren(...out);
  dt.classList.add("ctx-dt");
}
// bottom bar: normal chat page = Orca + input box; off-duty page = only "wake"
function setOffUI(off) {
  $("#btn-plus").hidden = off;
  if (off) closePlus();
  $("#wake").hidden = !off;
  if (off) { $("#composer").hidden = true; $("#no-reply").hidden = true; }
}
function resetWakeUI() {
  st.waking = false;
  const b = $("#btn-wake");
  b.disabled = false;
  b.classList.remove("busy");
  b.replaceChildren(document.createTextNode(t("wake.btn")));
  const m = $("#wake-msg");
  m.hidden = true;
  m.textContent = "";
  syncOrcaUI();
}

function openOffDetail(sid, push, from) {
  if (push !== false && openSwallowed(from, Date.now() - st.backAt)) { diag("open-swallowed", { id: sid, from: from || null }); return; } // same as openDetail
  const o = ((st.snap && st.snap.offduty) || []).find((x) => x.sid === sid);
  if (!o) { toast(t("toast.notOff")); return; }
  if (push !== false) pushDetailState({ o: sid }, "#o/" + encodeURIComponent(sid));
  showDetail(sid, o, from);
}

function openDetail(id, push, from) {
  // just swiped back: this "click" is an accidental tap on a home row when the finger lifted; entries from notification / cold start / hash are not swallowed; a swallowed one is logged to diag
  if (push !== false && openSwallowed(from, Date.now() - st.backAt)) { diag("open-swallowed", { id, from: from || null }); return; }
  const s = st.byId.get(id);
  if (!s) { diag("open-skipped", { id, why: "gone" }); toast(t("toast.noSession")); return; } // a silent return also leaves a trace
  if (isWide() && id === st.detailId && !st.detailOff) { diag("open-skipped", { id, why: "already-open" }); return; } // two-pane: tapping the one already open on the right: don't reload
  if (push !== false) pushDetailState({ d: id }, "#s/" + encodeURIComponent(id));
  showDetail(id, null, from);
}

// from: where we came from (list / card / sheet / waiting / banner / wake / auto / popstate / notify / launch / hashchange), used only by the diagnostic log
function showDetail(id, off, from) {
  if (FS.kind) closeFs(); // when the monitor page / task board is open and we enter a chat from a banner or notification: close the fullscreen page first so the chat page isn't underneath it
  diag("detail-open", { id, off: !!off, homeY: window.scrollY, from: from || null });
  if (D) { D.ph = false; D.fig = new Map(); } // switching session: reset the baselines for placeholder / figure comparison
  if (st.agentView) closeAgent(false);
  st.agFlip.clear();
  if (!document.body.classList.contains("in-detail")) st.homeY = window.scrollY; // scroll back to the original position on return
  const s = off ? offAsSession(off) : st.byId.get(id);
  if (!off) closeSessionNotifs(id); // opening a session clears this device's notifications for it
  closeSheet();
  st.detailOff = off;
  resetWakeUI();
  setOffUI(!!off);
  st.detailId = id;
  st.fmtWarn = "";
  syncGuestCur(s); // which guest's session the admin is looking at: bubbles use that guest's nickname and avatar
  st.next = null;
  st.loading = false;
  st.items = [];
  st.shown = [];
  st.sig = "";
  st.figBlocks = null;
  resetFigures(id);
  setNewCount(0);
  setQuote("");
  clearTray();
  closePlus();
  closeClip();
  const token = ++st.dToken;
  resetReplyUI(id);
  if (off) fillOffHeader(off); else fillDetailHeader(s, true);
  $("#older").replaceChildren();
  const sk = h("div", "skeleton");
  for (let i = 0; i < 5; i++) sk.append(h("i"));
  $("#list").replaceChildren(sk);
  const d = $("#detail");
  d.hidden = false;
  d.classList.remove("drag");
  d.style.transform = "";
  void d.offsetWidth;
  autosizeReply(); // a draft may have several lines, so the height can only be measured after it is shown
  d.classList.add("open");
  // after the slide-in ends redraw the title once: iOS keeps this text at the low resolution used during the slide, which looks blurry
  if (!isWide()) d.addEventListener("transitionend", function redraw(e) {
    if (e.target !== d) return;
    d.removeEventListener("transitionend", redraw);
    if (st.detailId) { diag("covered", { on: true, via: "transitionend" }); document.body.classList.add("covered"); } // block what's behind only after the slide-in, so the home page doesn't flash black first
    const n = $("#d-name");
    n.style.display = "none";
    void n.offsetWidth;
    n.style.display = "";
  });
  // in case transitionend never arrives (animation interrupted etc.), block as a fallback too
  setTimeout(() => {
    if (token !== st.dToken || !st.detailId) return;
    if (!document.body.classList.contains("covered")) diag("covered", { on: true, via: "timer450" });
    document.body.classList.add("covered");
  }, 450);
  document.body.classList.add("in-detail");
  if (!off) markSeen(s, false);
  loadPage(token, null);
  startDetailPolling();
  if (isWide()) renderChat(); // two-pane: mark the one being viewed in the list
}

function closeDetail() {
  if (!st.detailId) return;
  diag("detail-close", { id: st.detailId, homeY: st.homeY || 0, covered: document.body.classList.contains("covered") });
  if (st.agentView) closeAgent(false);
  if (location.hash) history.replaceState(null, "", location.pathname + location.search);
  refresh(); // refresh once immediately when returning home
  st.detailId = null;
  st.detailOff = null;
  st.waking = false;
  st.figBlocks = null;
  resetFigures(null);
  st.dToken++;
  $("#reply").blur();
  closeBubbleMenu();
  clearTray();
  closePlus();
  closeClip();
  updateBusy(null);
  stopDetailPolling();
  const d = $("#detail");
  d.classList.remove("drag");
  d.style.transform = "";
  d.classList.remove("open");
  document.body.classList.remove("in-detail", "swiping", "covered");
  if (isWide()) { // wide screens have no slide-out animation and the list stays visible (the user may have scrolled it), so no need to scroll back
    d.hidden = true;
    renderChat();
    return;
  }
  window.scrollTo(0, st.homeY || 0); // when the input is tapped iOS scrolls the home page behind; scroll it back here
  setTimeout(() => { if (!st.detailId) d.hidden = true; }, 360);
}

// already on a chat page and switching to another session: replace the current history entry instead of stacking, otherwise back would return to the previous session
// replace only, don't stack: if stacked, the iOS home-screen app's built-in swipe-back would step back through history and stack with our own swipe-back, and even return to the wrong session
function pushDetailState(state, hash) {
  history.replaceState(state, "", hash);
}

function goBack() {
  if (st.agentView) { closeAgent(true); return; } // sub-agent page: return to the original position of the main chat (no history stacking)
  closeDetail();
}

function markSeen(s, notify) {
  s.unread = false;
  if (st.guest) { // a guest's read state is stored locally only, not written to the Mac dashboard
    try {
      const old = Number(localStorage.getItem(guestSeenKey)) || 0;
      localStorage.setItem(guestSeenKey, String(Math.max(old, Number(s.since) || 0)));
    } catch (e) { /* can't store: ignore */ }
    render();
    if (notify) toast(t("toast.seen"));
    return;
  }
  render();
  post("/api/sessions/" + encodeURIComponent(s.id) + "/seen")
    .then((res) => { if (notify) toast(res.ok ? t("toast.seen") : t("c.opFail")); })
    .catch((e) => { if (notify && e.message !== "auth") toast(t("c.opFail")); });
}

function detailMessage(title, text, s) {
  const box = h("div", "d-msg");
  if (s) {
    const mini = h("div", "mini");
    const pet = h("div", "pet");
    setPet(pet, s);
    mini.append(pet);
    box.append(mini);
  }
  box.append(h("b", null, title));
  if (text) box.append(document.createTextNode(text));
  return box;
}

// quiet = background refresh of the first page: failures don't disturb, no redraw if unchanged, scroll position kept
async function loadPage(token, before, quiet) {
  const id = st.detailId;
  if (!id || st.loading) return;
  st.loading = true;
  const list = $("#list");
  const older = $("#older");
  if (before != null) older.replaceChildren(h("span", null, t("c.loading")));
  let data = null;
  let status = 0;
  try {
    const res = await api((st.detailOff ? "/api/offduty/" : "/api/sessions/") + encodeURIComponent(id) + "/transcript" + chQuery(before, chBaseFrom()), null, FETCH_TIMEOUT_MS);
    status = res.status;
    if (res.ok) data = await res.json();
  } catch (e) {
    if (e.message === "auth") return;
  } finally {
    if (token === st.dToken) st.loading = false;
    if (st.pollQueued && token === st.dToken) { st.pollQueued = false; setTimeout(pollDetail, 0); } // another fetch was requested while fetching: fetch once more
  }
  if (token !== st.dToken) return;
  const s = st.detailOff ? offAsSession(st.detailOff) : (st.byId.get(id) || {});
  if (!data) {
    if (quiet) return;
    if (before == null) {
      if (status === 404) {
        list.replaceChildren(detailMessage(st.detailOff ? t("dt.noRecord") : t("toast.noSession"), st.detailOff ? t("dt.noRecordSub") : t("dt.endedSub"), null));
      } else {
        const box = detailMessage(t("c.loadFail"), t("dt.loadFailSub"), null);
        const retry = h("button", "retry", t("c.retry"));
        retry.type = "button";
        retry.onclick = () => {
          list.replaceChildren(detailMessage(t("c.loading"), null, null));
          loadPage(st.dToken, null);
        };
        box.append(h("br"), retry);
        list.replaceChildren(box);
      }
    } else {
      renderOlder();
      toast(t("c.loadFail"));
    }
    return;
  }
  if (data.supported === false) {
    if (quiet) return;
    older.replaceChildren();
    list.replaceChildren(detailMessage(summaryText(s) || t("dt.noProgress"), t("dt.noView"), s));
    return;
  }
  const items = data.items || [];
  if (before == null && st.fmtWarn !== (data.formatWarn || "")) { st.fmtWarn = data.formatWarn || ""; renderAlert(s); }
  if (before == null && !st.detailOff && typeof data.queued === "number") { // the first page carries "number of my still-queued messages" (not when viewing an earlier window; the previous value is kept)
    st.queued = data.queued;
    st.queuedFor = id;
    renderStat(s);
  }
  if (before != null) {
    st.items = items.concat(st.items);
    st.next = data.next;
    renderList(s, "prepend");
    renderOlder();
  } else if (quiet) {
    const m = mergeItems(st.items, items);
    st.items = m.items;
    if (m.reset) { st.next = data.next; renderOlder(); }
    renderList(s, "keep");
  } else {
    st.items = items;
    st.next = data.next;
    renderList(s, "bottom");
    renderOlder();
  }
}

// while the chat page is open fetch the first page periodically (not when the page is hidden); once per second when busy / waiting for you, otherwise every 3 seconds (detailPollMs)
// the previous fetch hasn't finished: don't drop it, queue it and fetch again right after (several merge into one)
function pollDetail() {
  if (!st.detailId || document.hidden || st.agentView || chPaused()) return;
  if (st.loading) { st.pollQueued = true; return; }
  loadPage(st.dToken, null, true);
}
function startDetailPolling() {
  stopDetailPolling();
  const tick = () => {
    pollDetail();
    const s = st.byId.get(st.detailId);
    st.detailTimer = setTimeout(tick, detailPollMs(s && s.status, !document.hidden));
  };
  const s0 = st.byId.get(st.detailId);
  st.detailTimer = setTimeout(tick, detailPollMs(s0 && s0.status, !document.hidden));
}
function stopDetailPolling() {
  if (st.detailTimer) clearTimeout(st.detailTimer);
  st.detailTimer = null;
  if (st.chase) clearTimeout(st.chase.timer);
  st.chase = null;
  st.pollQueued = false;
}
// follow-up fetch after a state change: fetch immediately, then every 0.5 seconds until the card arrives, it is no longer waiting, or 3 seconds pass
function chaseCard() {
  if (st.chase) clearTimeout(st.chase.timer);
  const c = (st.chase = { id: st.detailId, t0: Date.now(), timer: 0 });
  pollDetail();
  const step = () => {
    if (st.chase !== c) return;
    const s = st.byId.get(c.id);
    if (c.id !== st.detailId || !s || cardChaseDone(s.status, st.items, Date.now() - c.t0)) { st.chase = null; return; }
    pollDetail();
    c.timer = setTimeout(step, CARD_CHASE_STEP_MS);
  };
  c.timer = setTimeout(step, CARD_CHASE_STEP_MS);
}

// chat signature: the send stage of a pending bubble swaps its icon in place and is not part of the signature, so each stage change doesn't redraw the whole list; the original text / attachments used for resending are excluded too
const PEND_SIG_SKIP = new Set(["stage", "el", "atw", "body", "items", "raw", "quote", "input", "sid"]);
function listSig(s) {
  return JSON.stringify([s.status, st.items, Array.from(st.sent)]) +
    JSON.stringify(st.outgoing.get(st.detailId) || [], (k, v) => (PEND_SIG_SKIP.has(k) ? undefined : v));
}
// mode: bottom = scroll to bottom; keep = stick to the bottom if within 120px of it, otherwise stay in place and count "new messages"; prepend = load older, keep the current content position
function renderList(s, mode) {
  if (st.agentView) return; // sub-agent page is open: don't draw the main chat (redraw on return)
  const msgs = $("#msgs");
  const list = $("#list");
  if (mode === "keep") {
    // sending, or typing in a bubble: no redraw this time (signature not updated, try next round)
    if (st.sending || list.contains(document.activeElement)) return;
    const sig = listSig(s);
    if (sig === st.sig) return;
    st.sig = sig;
  } else {
    st.sig = listSig(s);
  }
  const h0 = msgs.scrollHeight;
  const t0 = msgs.scrollTop;
  const ub = D ? diagUserBusy(performance.now(), D.touchAt, D.scrollAt) : false; // diagnostic log: whether the user was scrolling before the redraw
  const away = awayFromBottom(h0, t0, msgs.clientHeight);
  const added = mode === "keep" ? countNewItems(st.shown, st.items) : 0;
  st.shown = st.items;
  const agScroll = agScrollOf(list);
  const frag = chFrag(s); // previous-window part + divider + this window (just renderItems when no previous window is attached)
  list.replaceChildren(frag);
  agSettle(list, agScroll);
  fitPeerFolds(list);
  if (!st.items.length) list.append(detailMessage(t("dt.empty"), null, null));
  if (mode === "bottom" || (mode === "keep" && !away)) msgs.scrollTop = msgs.scrollHeight;
  else if (mode === "prepend") msgs.scrollTop = t0 + (msgs.scrollHeight - h0);
  else msgs.scrollTop = t0;
  if (mode === "keep") setNewCount(nextNewCount(st.newCount, added, away));
  else if (mode === "bottom") setNewCount(0);
  reconcileFigures(st.figPlan || [], st.detailId, { instant: mode === "prepend", onTap: figTap });
  diagRender(mode, t0, h0, away, added, ub);
  diagFig(st.figPlan, mode === "prepend");
}

// tool figures (figures.js): recompute state once per second from the current time (switch the waiting action after 30 seconds) and let the lined-up ones occasionally squeeze
function tickFig() {
  if (st.agentView) return;
  if (!st.figBlocks || !st.shown.length) return;
  const items = st.shown;
  const plan = figurePlan(items, taskStates(items), Date.now() / 1000, st.figBlocks, bgLiveIds(items, st.byId.get(st.detailId)));
  const sig = (p) => p.map((e) => e.key + "=" + e.figs.map((f) => f.id + ":" + f.state).join()).join("|");
  if (sig(plan) !== sig(st.figPlan || [])) { // realign only when state changed (mostly the waiting action switch after 30 seconds); otherwise no measuring or writing
    st.figPlan = plan;
    reconcileFigures(plan, st.detailId, { onTap: figTap });
    diagFig(plan, false);
  }
  tickFigures();
}
// tap a figure (the working one on top or a parked one below): expand this group's detail showing only the row of the tapped call (agents together with their sub-agent report);
// tapping the same one collapses, tapping another switches. State is in st.figOpen, so the 3-second redraw while busy doesn't close it
function figTap(key, tu) {
  const boxes = [...$("#list").querySelectorAll(".tools[data-fig]")].filter((el) => el.dataset.fig === key);
  const box = boxes.find((el) => [...el.querySelectorAll("li[data-tu]")].some((li) => li.dataset.tu === tu));
  if (!box) return;
  const again = st.figOpen.get(key) === tu;
  for (const b of boxes) figRow(b, null);
  if (again) { st.figOpen.delete(key); return; }
  st.figOpen.set(key, tu);
  figRow(box, tu);
}
// the tool tag shows only the tu row (tu empty: collapsed)
function figRow(box, tu) {
  box.classList.toggle("open", !!tu);
  box.classList.toggle("tl-one", !!tu);
  for (const li of box.querySelectorAll("li")) li.classList.toggle("fg-hl", !!tu && li.dataset.tu === tu);
  for (const hb of box.querySelectorAll(".hb")) hb.classList.toggle("tl-on", !!tu && hb.dataset.for === tu);
}

// bottom-right "down arrow, new messages"
function setNewCount(n) {
  st.newCount = n;
  const b = $("#new-btn");
  b.hidden = n <= 0;
  b.textContent = newBtnText(n);
}

// reply placeholder bubble (renderItems draws it at the end of #list): this only handles the 30-second timer of the small "working N min" text, using setText only, no list redraw
function updateBusy(s) {
  renderStat(s); // "working N min" follows this timer (ticks every 30 seconds, enough for minute display)
  const on = !!s && s.status === "busy" && !st.detailOff;
  if (on) {
    for (const el of $("#list").querySelectorAll(".ph-t")) setText(el, busyLine(s, st.down ? st.downAt : nowSec())); // while retrying, becomes "retrying API (n/10)"
    if (!st.busyTimer) st.busyTimer = setInterval(() => updateBusy(st.byId.get(st.detailId) || null), BUSY_TICK_MS);
  } else {
    if (st.busyTimer) clearInterval(st.busyTimer);
    st.busyTimer = null;
  }
}

function renderOlder() {
  if (st.agentView) return agOlder();
  if (chOlder()) return; // after finishing this window, before switching windows
  const older = $("#older");
  if (st.next == null) {
    older.replaceChildren(h("span", null, t("dt.earliest")));
    return;
  }
  const b = h("button", null, t("dt.older"));
  b.type = "button";
  b.onclick = () => loadPage(st.dToken, st.next);
  older.replaceChildren(b);
}

function toolSummary(texts) {
  const c = { cmd: 0, read: 0, edit: 0, search: 0, agent: 0, other: 0 };
  for (const t of texts) {
    const name = String(t).split(/\s/)[0];
    if (name === "Bash") c.cmd++;
    else if (name === "Agent" || name === "Task") c.agent++;
    else if (name === "Read") c.read++;
    else if (name === "Edit" || name === "Write" || name === "MultiEdit" || name === "NotebookEdit") c.edit++;
    else if (name === "Grep" || name === "Glob") c.search++;
    else c.other++;
  }
  if (!texts.length) return t("tl.report");
  if (c.other === texts.length) return t("tl.tools", { n: texts.length });
  const parts = [];
  if (c.agent) parts.push(t("tl.agent", { n: c.agent }));
  if (c.cmd) parts.push(t("tl.cmd", { n: c.cmd }));
  if (c.read) parts.push(t("tl.read", { n: c.read }));
  if (c.edit) parts.push(t("tl.edit", { n: c.edit }));
  if (c.search) parts.push(t("tl.search", { n: c.search }));
  if (c.other) parts.push(t("tl.other", { n: c.other }));
  const sj = joinList(parts);
  return isEn() ? sj.charAt(0).toUpperCase() + sj.slice(1) : sj; // capitalize the sentence start in English
}

// tool tag: small gray text with a corner badge check/cross at the top right (mark: ok / err / null); open to see the tool list and the sub-agent reports folded in
// tools: tool records; o.tus: the figure id for each row (the li's data-tu); o.key: the figure anchor key (present = a group with a figure attached)
// a group with a figure doesn't draw the header tag (check/cross is shown by the figure badge), its detail is collapsed by default, and tapping the figure expands one row;
// but if the group holds a sub-agent report matching no tool (no figure to tap) the tag is left as is.
function toolGroup(tools, open, mark, hands, o) {
  o = o || {};
  const texts = tools.map((it) => it.text || "");
  const ids = new Set(tools.map((it) => it.toolUseId).filter(Boolean));
  const orphan = hands.some((it) => !it.forTool || !ids.has(it.forTool));
  const nohd = !!o.key && texts.length > 0 && !orphan;
  const box = h("div", "tools" + (nohd ? " tl-nohd" : "") + (open ? " open" : ""));
  if (!nohd) {
    const hd = h("button", "tl-hd" + (mark ? " mk-" + mark : ""));
    hd.type = "button";
    hd.append(h("span", "tri", "▶"), document.createTextNode(toolSummary(texts)));
    if (hands.length && texts.length) hd.append(h("span", "tl-n", t("tl.reports", { n: hands.length })));
    if (mark) {
      const b = h("i", "tl-mk", mark === "ok" ? "✓" : "✕");
      b.setAttribute("aria-label", mark === "ok" ? t("tl.allOk") : t("tl.hasErr"));
      hd.append(b);
    }
    hd.onclick = () => {                                        // tapping the tag shows everything: drops the single-row filter of tapping a figure
      const on = !box.classList.contains("open") || box.classList.contains("tl-one");
      if (o.key) st.figOpen.delete(o.key);
      figRow(box, null);
      box.classList.toggle("open", on);
    };
    box.append(hd);
  }
  const body = h("div", "tl-body");
  if (texts.length) {
    const ul = h("ul");
    texts.forEach((t, k) => {
      const li = h("li");
      const cls = toolClass(tools[k].name || String(t).split(/\s/)[0]);
      if (cls) li.dataset.cls = cls;
      const tu = (o.tus && o.tus[k]) || tools[k].toolUseId;
      if (tu) li.dataset.tu = tu;
      const str = String(t);
      const sp = str.indexOf(" ");
      if (sp > 0) li.append(h("b", null, str.slice(0, sp)), document.createTextNode(str.slice(sp + 1)));
      else li.append(h("b", null, str));
      ul.append(li);
    });
    body.append(ul);
  }
  for (const it of hands) { // sub-agent report: carries the task name, body rendered as Markdown, long-press to copy
    const hb = h("div", "hb");
    if (it.forTool) hb.dataset.for = it.forTool;
    const hh = h("div", "hb-hd");
    hh.append(botAvatar(), h("span", "hb-tag", t("tl.report")));
    if (it.agentName) hh.append(h("span", "hb-nm", it.agentName));
    hb.append(hh, mdNode(it.text || ""));
    msgText.set(hb, it.text || "");
    body.append(hb);
  }
  box.append(body);
  const tu = o.key && st.figOpen.get(o.key);
  if (tu && [...body.querySelectorAll("li")].some((li) => li.dataset.tu === tu)) figRow(box, tu);
  return box;
}

// ---------- Markdown of assistant messages: built only with createElement/textContent, never innerHTML ----------
function safeHref(u) {
  try {
    const x = new URL(String(u));
    return x.protocol === "http:" || x.protocol === "https:" ? x.href : null;
  } catch (e) { return null; }
}
function mdInline(parent, nodes) {
  for (let k = 0; k < nodes.length; k++) {
    const n = nodes[k];
    // ![alt](path): md.js leaves the "!" in the previous text node followed by a link; if the path is an image in this entry's files, draw it in place as a thumbnail (not repeated at the end)
    if (mdFx && n.t === "text" && n.text.endsWith("!") && nodes[k + 1] && nodes[k + 1].t === "link") {
      const f = mdImgMatch(mdFx.files, nodes[k + 1].href);
      if (f) {
        const pre = n.text.slice(0, -1);
        if (pre) parent.append(document.createTextNode(pre));
        parent.append(atImg(f, mdFx.sid, "at-inl"));
        k++;
        continue;
      }
    }
    if (n.t === "text") mdChipText(parent, n.text);
    else if (n.t === "br") parent.append(document.createElement("br"));
    else if (n.t === "code") mdChipCode(parent, n.text);
    else if (n.t === "link") {
      const href = safeHref(n.href);
      if (href) {
        const a = h("a");
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        const fx = mdFx;
        mdFx = null; // no tags inside link text (a button can't be nested in <a>)
        try { mdInline(a, n.c); } finally { mdFx = fx; }
        parent.append(a);
      } else { // non-http(s): show with its address as text so it's clear what it is
        mdInline(parent, n.c);
        parent.append(document.createTextNode(" (" + n.href + ")"));
      }
    } else {
      const tag = n.t === "strong" ? "strong" : n.t === "em" ? "em" : "del";
      const e = h(tag);
      mdInline(e, n.c || []);
      parent.append(e);
    }
  }
}
// paths in the body (those in this entry's files with src=text) become "type icon + file name" tags; if none can be replaced keep the original text
// inline `code`: if the whole thing is a path -> only the tag (no code box); if the path is inside a command -> text and tags mixed in the code box. Fenced code blocks don't go through here and stay as is
function mdChipText(parent, text) {
  const seg = mdFx ? pathChips(text, mdFx.files) : null;
  if (!seg) { parent.append(document.createTextNode(text)); return; }
  for (const x of seg) parent.append(x.t === "chip" ? atChip(x.f, mdFx.sid) : document.createTextNode(x.text));
}
function mdChipCode(parent, text) {
  const seg = mdFx ? pathChips(text, mdFx.files) : null;
  if (!seg) { parent.append(h("code", null, text)); return; }
  if (seg.every((x) => x.t === "chip" || !x.text.trim())) { // path only (at most a few spaces around)
    for (const x of seg) if (x.t === "chip") parent.append(atChip(x.f, mdFx.sid));
    return;
  }
  const c = h("code");
  for (const x of seg) c.append(x.t === "chip" ? atChip(x.f, mdFx.sid) : document.createTextNode(x.text));
  parent.append(c);
}
// "Copy" button at the top right of code blocks and tables. The render cache uses cloneNode (listeners aren't carried over), so clicks go through one delegated listener on document (bindMdCopy)
// a 26px header strip on top (language name on the left, "Copy" on the right) so the button doesn't cover the code area
function mdCopyWrap(inner, lang) {
  const box = h("div", "md-cb" + (inner.classList.contains("md-tbl") ? " md-cb-t" : ""));
  const hd = h("div", "md-ch");
  const btn = h("button", "md-cp", t("c.copy"));
  btn.type = "button";
  btn.setAttribute("aria-label", t("c.copy"));
  hd.append(h("span", "md-lang", lang || t("md.code")), btn); // when ``` has no language, write "code" (blank looks like an error)
  box.append(hd, inner);
  return box;
}
function mdCopyText(box) {
  const tbl = box.querySelector("table");
  if (tbl) return tsvText([...tbl.rows].map((r) => [...r.cells].map((c) => c.textContent)));
  const code = box.querySelector("pre code");
  return code ? code.textContent : "";
}
// on wide screens move the quote strip into the input area (below the text box, above the tool row); on phones put it back above the input area. Only the node moves, setQuote is untouched
function bindQuoteDock() {
  const q = $("#quote-bar");
  const dock = () => {
    if (isWide()) { if (q.parentNode.id !== "composer") $("#composer").insertBefore(q, $("#btn-send")); }
    else if (q.parentNode.id === "composer") $("#tray").after(q);
  };
  dock();
  if (WIDE.addEventListener) WIDE.addEventListener("change", dock);
}
function bindMdCopy() {
  const stop = (e) => { if (e.target.closest && e.target.closest(".md-cp")) e.stopPropagation(); };
  for (const t of ["pointerdown", "touchstart", "mousedown", "contextmenu"]) document.addEventListener(t, stop);
  document.addEventListener("click", async (e) => {
    const btn = e.target.closest && e.target.closest(".md-cp");
    if (!btn) return;
    e.stopPropagation();
    e.preventDefault();
    const text = mdCopyText(btn.closest(".md-cb"));
    let ok = false;
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) { await navigator.clipboard.writeText(text); ok = true; }
    } catch (err) { ok = false; }
    if (!ok) ok = copyFallback(text);
    btn.textContent = ok ? t("c.copied") : t("c.copyFail");
    btn.classList.add("done");
    clearTimeout(btn._t);
    btn._t = setTimeout(() => { btn.textContent = t("c.copy"); btn.classList.remove("done"); }, 1500);
  }, true);
}
function mdBlocks(parent, blocks) {
  for (const b of blocks) {
    if (b.type === "heading") {
      const e = h("div", "md-h md-h" + b.level);
      mdInline(e, b.c);
      parent.append(e);
    } else if (b.type === "para") {
      const e = h("p");
      mdInline(e, b.c);
      parent.append(e);
    } else if (b.type === "code") {
      const pre = h("pre");
      pre.append(h("code", null, b.text));
      parent.append(mdCopyWrap(pre, b.lang));
    } else if (b.type === "hr") {
      parent.append(h("hr"));
    } else if (b.type === "quote") {
      const e = h("blockquote");
      mdBlocks(e, b.blocks);
      parent.append(e);
    } else if (b.type === "list") {
      const e = h(b.ordered ? "ol" : "ul");
      if (b.ordered && b.start !== 1) e.start = b.start;
      for (const it of b.items) {
        const li = h("li");
        mdBlocks(li, it);
        e.append(li);
      }
      parent.append(e);
    } else if (b.type === "table") {
      const wrap = h("div", "md-tbl");
      const tbl = h("table");
      const cell = (tag, inl, i) => {
        const c = h(tag);
        if (b.align[i]) c.style.textAlign = b.align[i];
        mdInline(c, inl);
        return c;
      };
      const tr = h("tr");
      b.head.forEach((c, i) => tr.append(cell("th", c, i)));
      const thead = h("thead");
      thead.append(tr);
      const tbody = h("tbody");
      for (const row of b.rows) {
        const r = h("tr");
        row.forEach((c, i) => r.append(cell("td", c, i)));
        tbody.append(r);
      }
      tbl.append(thead, tbody);
      wrap.append(tbl);
      parent.append(mdCopyWrap(wrap, t("md.table")));
    }
  }
}
// render cache: text -> DOM. Each redraw reuses only messages whose text is unchanged; the same text appearing several times is cloned.
const mdCache = new Map();
let mdUsed = new Set();
let mdFx = null; // attachments { files, sid } of the message being rendered (used for drawing Markdown images in place); null when mdBlocks is called elsewhere
function mdNode(text, fx) {
  // path tags in the body also need files: images with a path (drawn in place) and src=text files (turned into tags) are both in the cache key, so late-arriving or changed files don't reuse a stale node
  const imgs = fx ? fx.files.filter((f) => f && f.path && (f.kind === "image" || f.src === "text")) : [];
  const key = imgs.length ? text + "\u0000" + JSON.stringify([fx.sid, imgs]) : text; // with attachments the cache key includes files
  let node = mdCache.get(key);
  if (!node) {
    node = h("div", "md");
    mdFx = imgs.length ? fx : null;
    try { mdBlocks(node, parseMarkdown(text)); } catch (e) { node.textContent = text; diagErr("mdNode", e); } finally { mdFx = null; } // this is where the table bug got swallowed into plain text
    mdCache.set(key, node);
    mdUsed.add(key);
    return node;
  }
  if (mdUsed.has(key)) return node.cloneNode(true);
  mdUsed.add(key);
  return node;
}
function mdSweep() {
  for (const k of mdCache.keys()) if (!mdUsed.has(k)) mdCache.delete(k);
  mdUsed = new Set();
  for (const k of [...atCache.keys()]) if (!atUsed.has(k)) atEvict(k); // attachment blocks follow the same cache rules
  atUsed = new Set();
}

// ---------- group-chat style chat page: avatar, name row, grouping ----------
const BOT_SVG = '<svg viewBox="0 0 18 18" shape-rendering="crispEdges"><rect x="8" y="1" width="2" height="2" fill="#7f8ca3"/><rect x="3" y="3" width="12" height="9" rx="2" fill="#8d9ab2"/><rect x="5" y="6" width="2" height="2" fill="#1b1f27"/><rect x="11" y="6" width="2" height="2" fill="#1b1f27"/><rect x="7" y="9" width="4" height="1" fill="#1b1f27"/><rect x="1" y="6" width="2" height="3" fill="#6f7a8f"/><rect x="15" y="6" width="2" height="3" fill="#6f7a8f"/><rect x="5" y="13" width="8" height="4" rx="1" fill="#6f7a8f"/></svg>';

// speaker lookup context for this chat page: this session, the roster, zones (built once per chat redraw)
function chatCtx(s) {
  const snap = st.snap || {};
  return {
    self: { name: s.name, zone: s.zone, pet: s.pet, id: s.id },
    dir: speakerDir(snap, st.guest),
    zones: snap.zones || [],
  };
}
// tap the avatar: the pet waves three times (waving row), then returns to the still frame
function petWave(av, pet, name) {
  const base = "/pets/" + encodeURIComponent(name) + "/";
  av.addEventListener("click", () => {
    const n = Math.max(1, Math.min(8, Number((st.pets[name] || {})[ROW.waving]) || 4));
    pet.style.setProperty("--n", n);
    pet.style.backgroundImage = 'url("' + base + ROW.waving + '.webp")';
    pet.classList.remove("wave");
    void pet.offsetWidth; // restart the animation
    pet.classList.add("wave");
    pet.onanimationend = () => { pet.classList.remove("wave"); pet.style.backgroundImage = 'url("' + base + 'still.webp")'; };
  });
}
// Agent avatar (same as the message list): transparent-background pet; with no pet = dark gray rounded square with the first letter. Identity (lead / zone) goes in the name row; the avatar has no frame or badge
function chatAvatar(sp) {
  const av = h("div", "cav cav-ag");
  const clip = h("div", "cav-clip");
  const name = sp.pet ? petName(sp.pet) : null;
  const pick = sp.pet ? avatarPick(speakerSession(sp) || sp.pet, name, st.petsKnown) : { kind: "ini" };
  if (name) {
    const pet = h("div", "cav-pet");
    pet.style.backgroundImage = 'url("/pets/' + encodeURIComponent(name) + '/still.webp")';
    clip.append(pet);
    petWave(av, pet, name);
  } else if (pick.kind === "flame") {
    // no pet installed: the flame, expression follows session state (aligned on syncChatFire polls)
    const pet = h("div", "cav-pet pet-flame");
    pet.style.backgroundImage = 'url("' + pick.src + '")';
    clip.append(pet);
  } else clip.append(h("span", "cav-ini", speakerInitials(sp.plate)));
  av.append(clip);
  av._sp = sp; av._fh = clip; // the fire layer sits in clip, before the pet (aligned on syncChatFire polls)
  syncFire(clip, clip.firstChild, fireOfSpeaker(sp));
  return av;
}
// My row mirrors the Agent row: 40px avatar on the right (row-reverse, the first one placed is on the right), and a column on the left: name row (right-aligned) + blue bubble.
// Same for guests (seen by the guest): use the guest's own avatar and nickname (with no avatar, the guest letter square taken from the prefix; the nickname defaults to the `default` of /api/profile)
function meGroup() {
  const g = h("div", "cg hu me");
  const c = h("div", "cg-col");
  const w = h("div", "cg-who");
  w.append(h("span", "nm", st.guest ? guestProfileView(st.profile).name : profileView(st.profile).name));
  c.append(w);
  g.append(myAvatar("cav"), c);
  return { g, c };
}
// guest bubble avatar from the admin view: the guest's avatar if set, otherwise the guest letter square (letters from the guest prefix, guestInitials)
function guestAvatar() {
  if (!st.guestProfileUrl) return personAvatar(guestInitials(st.guestTagCur || undefined));
  const av = h("div", "pf-av cav"); // same shell as myAvatar("cav") (circle-cropped image)
  const clip = h("div", "pf-clip cav-clip");
  const im = h("img");
  im.src = st.guestProfileUrl;
  im.alt = "";
  im.draggable = false;
  clip.append(im);
  av.append(clip);
  return av;
}
function botAvatar() {
  const av = h("div", "cav bot");
  const clip = h("div", "cav-clip");
  clip.innerHTML = BOT_SVG; // hard-coded constant, contains no conversation content
  av.append(clip);
  return av;
}
function personAvatar(label, cls) {
  const av = h("div", "cav p " + (cls || ""));
  const clip = h("div", "cav-clip");
  clip.append(h("span", "cav-ini", label));
  av.append(clip);
  return av;
}
// name row: the name; the lead is followed by a small star; messages from other sessions (peer) also get a zone badge (own team too). The session's own replies show only the name
function whoLine(sp, who) {
  const w = h("div", "cg-who");
  w.append(h("span", "nm", sp.plate || t("c.peer")));
  const tg = whoTags(sp, who); // not named t: a later `const t` in the same block would put the earlier t("c.peer") in the temporal dead zone, and unsigned cross-session messages would fail to draw the whole page
  if (tg.star) w.append(h("span", "st", "★"));
  if (tg.zone) {
    const z = h("span", "cg-zb", tg.zone.short);
    z.style.setProperty("--zc", tg.zone.color);
    w.append(z);
  }
  return w;
}
// a group of utterances -> several rows (every message carries an avatar and name).
// Agent on the left (this session / other sessions), people on the right (me without avatar / guest / admin); a tool tag hangs in the previous message's column, aligned to the bubble's left edge,
// and when the first item in a group is a tool tag it gets its own row, indented to the right of the avatar
function chatGroup(b, items, s, ctx, waiting, tasks) {
  const frag = document.createDocumentFragment();
  let sp = null;
  if (b.who === "self" || b.who === "peer") sp = speakerOf(b.who === "self" ? s.name : b.from, ctx.self, ctx.dir, ctx.zones, st.guest);
  let col = null;
  const row = () => {
    let g;
    let c = h("div", "cg-col");
    if (sp) {
      g = h("div", "cg ag" + (b.who === "peer" ? " cg-pr" : ""));
      g.style.setProperty("--zc", sp.color);
      c.append(whoLine(sp, b.who));
      g.append(chatAvatar(sp), c);
    } else if (b.who === "me") {
      ({ g, c } = meGroup()); // mirrors the Agent row (name row + right avatar)
    } else {
      const byGuest = b.who === "guest";
      g = h("div", "cg hu " + (byGuest ? "gst" : "adm"));
      const w = h("div", "cg-who");
      w.append(h("span", "nm", byGuest ? guestProfileView(st.guestProfile).name : t("c.admin"))); // nickname set by the guest
      c.append(w);
      g.append(byGuest ? guestAvatar() : personAvatar(t("c.adminInitial"), "adm"), c);
    }
    frag.append(g);
    return c;
  };
  for (const p of b.parts) {
    if (p.t === "tools") {
      const fk = (col && ctx.figKeys && ctx.figKeys.get(p)) || null;
      const tg = toolGroup(p.idx.map((i) => items[i]), p.open === true || (waiting && p.trail === true),
        toolMark(p.idx, items, tasks), (p.hand || []).map((i) => items[i]),
        { key: fk, tus: p.idx.map((i) => ctx.figIds && ctx.figIds.get(i)) });
      if (fk) { // anchor of the tool figure: the tool tag and the bubble above it
        tg.dataset.fig = fk;
        const bub = col.querySelector(":scope > .m");
        const gl = ctx.agGlow && ctx.agGlow.get(fk);
        if (bub && gl && !bub.classList.contains("ag-flip")) agWrap(bub, fk, gl, s); // swap to a flippable shell, and the shell is the anchor
        else if (bub) bub.dataset.fig = fk;
      }
      if (col) col.append(tg);
      else { tg.classList.add("solo"); frag.append(tg); }
      const tf = p.idx.flatMap((i) => (Array.isArray(items[i].files) ? items[i].files : [])); // a file opened by Bash has nowhere to attach, so attach it to the tool entry
      const tm = p.idx.reduce((a, i) => a + (Number(items[i].more) || 0), 0);
      if (tf.length) {
        const tc = atNode(tf, tm, s.id, t("chat.openedFiles"));
        if (col) col.append(tc);
        else { const sw = h("div", "at-solo"); sw.append(tc); frag.append(sw); }
      }
      continue;
    }
    if (p.t === "ph") { col = row(); col.append(phBubble(s)); continue; }
    const it = items[p.i];
    col = row();
    let el;
    let af = null; // this entry's attachments
    if (it.role === "user") {
      // strip the prefix the server added to a guest's message: admin sees an indigo bubble, the guest sees it as "me"
      const raw = b.who === "guest" || (b.who === "me" && st.guest) ? stripGuestTag(it.text) : (it.text || "");
      if (it.recalled) { col.append(rcRecalledLine(it, b.who)); continue; } // recalled: one gray line
      const qd = parseQuoted(raw); // quote reply: the bubble holds only the body text; the gray quote strip hangs under the bubble
      const uf = atFilesOf(it); // when there are attachments, remove the "[Image #N]" text (the thumbnail replaces it)
      const cy = ctx.carry && ctx.carry.get(it); // transfer the image just sent to this entry (attach it even while queued with no files yet)
      const text = uf || cy ? stripImageMarks(qd ? qd.body : raw) : qd ? qd.body : raw;
      const atn = uf || cy ? userAt(uf, it.more, s.id, cy) : null;
      const onlyAt = !!atn && !text; // attachment only, no text: the attachment is drawn inside the bubble; receipt, recall and quote behave as for normal messages
      el = h("div", "m " + (b.who === "admin" ? "adm" : b.who === "guest" ? "gst" : b.who) + (onlyAt ? " at-only" : ""), text);
      msgText.set(el, text);
      const rc = b.who === "me" ? receiptOf(it) : null;
      msgMeta.set(el, { who: b.who, name: b.who === "me" ? t("c.me") : b.who === "guest" ? guestProfileView(st.guestProfile).name : t("c.admin"), receipt: rc, raw: it.text || "", ts: it.ts }); // ts decides the 2-minute window
      col.append(el);
      if (onlyAt) el.append(atn);
      if (rc) el.append(rcMark(rc, el)); // the receipt is drawn at the bubble's bottom-right corner; the gray quote strip stays under the bubble
      if (qd) col.append(h("div", "rc-qt", qd.quote));
      if (atn && !onlyAt) col.append(atn);
      continue;
    } else {
      // cross-session message (zone-colored forward card): left bar + background mixed with the speaker's zone color; the leading "from X:" in the body is removed
      const text = it.role === "peer" ? stripFrom(it.text) : (it.text || "");
      el = h("div", "m ai md-on" + (it.role === "peer" ? " x m-pr" : ""));
      af = atFilesOf(it);
      el.append(mdNode(text, af ? { files: af, sid: s.id } : null));
      msgText.set(el, text); // long-press always copies the full text, regardless of whether it is folded
      msgMeta.set(el, { who: b.who, name: b.who === "self" ? s.name : (b.from || (sp && sp.plate) || "") }); // the quote carries the speaker
      if (it.role === "peer") peerFold(el, peerKey(it), text);
    }
    col.append(el);
    if (af) { // Markdown images already drawn in place in the body are not repeated at the end
      const used = new Set([...el.querySelectorAll(".at-inl[data-fkey]")].map((x) => x.dataset.fkey)); // a broken .at-gone also carries data-fkey
      const chips = new Set([...el.querySelectorAll(".at-chip[data-fkey]")].map((x) => x.dataset.fkey)); // non-images that already have a tag in the body don't get a card
      const rest = atBottom(af, used, chips);
      if (rest.length || Number(it.more) > 0) col.append(atNode(rest, it.more, s.id));
    }
  }
  return frag;
}

// reply placeholder bubble: three bouncing dots + "working N min" (the small text is updated by updateBusy every 30 seconds)
function phBubble(s) {
  const el = h("div", "m ai ph-bub");
  el.setAttribute("aria-label", t("chat.replying"));
  const dots = h("span", "ph-dots");
  dots.setAttribute("aria-hidden", "true");
  dots.append(h("i"), h("i"), h("i"));
  el.append(dots, h("small", "ph-t", busyLine(s, nowSec()))); // retrying: "retrying API (n/10)"
  return el;
}

// ---------- sub-agent flip bubble ----------
// The original bubble stays as the front (body, long-press copy and the placeholder's "working" text stay in it), wrapped in a .m.ai.ag-flip shell that takes its place and serves as the figure anchor;
// the back is a small sub-agent card. Flip state is in st.agFlip (group key); on redraw it is drawn already flipped (agSettle fixes the height).
const AG_FLIP_MS = 420;
const agData = new WeakMap(); // back title .ag-el -> sub-agent list (the "elapsed" time is recomputed every second)
const agReduce = () => window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
function agGlowLayer() {
  const g = h("div", "ag-glow");
  g.append(h("div", "ag-sweep"), h("div", "ag-cover"));
  return g;
}
function agWrap(bub, key, gl, s) {
  const on = st.agFlip.has(key);
  const w = h("div", "m ai ag-flip ag-" + gl.status + (on ? " on" : ""));
  w.dataset.fig = key;
  w.dataset.ag = key;
  w._agN = gl.agents.length;
  const now = Date.now();
  w.style.setProperty("--ag-bd", -(now % 2400) + "ms"); // so the breathing and sweep-light phases continue across a redraw
  w.style.setProperty("--ag-sd", -(now % 5000) + "ms");
  delete bub.dataset.fig;
  bub.replaceWith(w);
  bub.classList.add("ag-face", "ag-front");
  bub.prepend(agGlowLayer());
  if (!bub.classList.contains("ph-bub")) bub.append(h("div", "ag-hint", t("ag.tapHint"))); // not added to the placeholder bubble
  const inner = h("div", "ag-in");
  inner.append(bub, agBack(gl, key, w, s));
  w.append(inner);
  w.addEventListener("click", (e) => {
    if (w.classList.contains("on") || e.target.closest("a, button, .ag-back")) return;
    agToggle(w, key);
  });
  return w;
}
function agBack(gl, key, w, s) {
  const now = Date.now() / 1000;
  const bk = h("div", "ag-face ag-back");
  const hd = h("div", "ag-hd");
  const bt = agentBackTitle(gl.agents, now);
  const el = h("span", "ag-el", bt.rest);
  agData.set(el, gl.agents);
  hd.append(h("b", null, bt.n), el);
  const list = h("div", "ag-list");
  for (const a of gl.agents) {
    const k = a.state === "running" ? "r" : a.state === "failed" ? "f" : a.state === "gone" ? "g" : "d";
    const card = h("div", "ag-card ag-" + k);
    const tt = h("span", "ag-tt", agentCardTime(a, now));
    if (a.state === "running") tt.dataset.start = String(isoToSec(a.startedAt) || now);
    card.append(h("span", "ag-nm", a.description || t("c.subagent")), h("span", "ag-mdl", modelLabel(a.model)), tt,
      h("span", "ag-task", a.task || ""), h("div", "ag-r3", null));
    card.lastChild.append(h("span", "ag-stp", a.lastStep || ""), h("span", "ag-tok", agentTok(a.tokens)));
    card.append(h("span", "ag-go", "›")); // guests can also enter the read-only sub-agent page of the bound session
    card.addEventListener("click", (e) => { e.stopPropagation(); if (w.classList.contains("on")) openAgent(s, a); });
    list.append(card);
  }
  bk.append(agGlowLayer(), hd, list, h("div", "ag-ft", t("ag.tapBack")));
  // tapping anywhere on the back that isn't a card flips it back (title, blank area, bottom); with more than 5 cards the list is a scroll area and doesn't flip
  bk.addEventListener("click", (e) => {
    if (!w.classList.contains("on")) return;
    if (e.target.closest("a, button")) return;
    const kind = e.target.closest(".ag-card") ? "card" : e.target.closest(".ag-hd") ? "head" : e.target.closest(".ag-list") ? "list" : "back";
    e.stopPropagation();
    if (agentBackFlips(kind, gl.agents.length)) agToggle(w, key);
  });
  return bk;
}
// back height = title + measured height of min(N,5) cards (independent of the front height)
function agBackHeight(w) {
  const bk = w.querySelector(":scope > .ag-in > .ag-back");
  const hd = bk && bk.querySelector(".ag-hd"), c = bk && bk.querySelector(".ag-card");
  const ft = bk && bk.querySelector(".ag-ft");
  const m = hd && c ? { hd: hd.offsetHeight, card: c.offsetHeight || 66, ft: (ft && ft.offsetHeight) || 28 } : null;
  return agentBackH(w._agN || 1, m);
}
// flip: 420ms 3D flip + height transition; figures are not re-laid-out during the transition
function agToggle(w, key) {
  const inner = w.querySelector(":scope > .ag-in");
  const front = inner && inner.querySelector(":scope > .ag-front");
  if (!front) return;
  const fh = front.offsetHeight, bh = agBackHeight(w);
  const on = !w.classList.contains("on");
  if (on) st.agFlip.add(key); else st.agFlip.delete(key);
  const ms = agReduce() ? 0 : AG_FLIP_MS + 40;
  holdLayout(ms);
  inner.style.height = (on ? fh : bh) + "px";
  void inner.offsetHeight; // set the start state before transitioning
  w.classList.toggle("on", on);
  inner.style.height = (on ? bh : fh) + "px";
  if (!on) setTimeout(() => { if (!w.classList.contains("on")) inner.style.height = ""; }, ms);
}
// before a redraw remember how far the flipped back is scrolled; after the redraw restore the flipped height (no transition) and the scroll position
function agScrollOf(list) {
  const m = new Map();
  for (const w of list.querySelectorAll(".ag-flip.on")) { const l = w.querySelector(".ag-list"); if (l) m.set(w.dataset.ag, l.scrollTop); }
  return m;
}
function agSettle(list, scroll) {
  for (const w of list.querySelectorAll(".ag-flip.on")) {
    const inner = w.querySelector(":scope > .ag-in");
    const front = inner.querySelector(":scope > .ag-front");
    inner.style.height = agBackHeight(w) + "px";
    const l = w.querySelector(".ag-list");
    if (l && scroll && scroll.has(w.dataset.ag)) l.scrollTop = scroll.get(w.dataset.ag);
  }
}
// every second (hooked on tickLive): the running card's "running 12:34", the back title's "ran N min", the sub-agent page header
function tickAgents() {
  const list = $("#list");
  const now = Date.now() / 1000;
  for (const el of list.querySelectorAll(".ag-tt[data-start]")) setText(el, t("ag.running", { t: agentClock(now - Number(el.dataset.start)) }));
  for (const el of list.querySelectorAll(".ag-el")) {
    const ags = agData.get(el);
    if (ags && ags.some((a) => a.state === "running")) setText(el, agentBackTitle(ags, now).rest);
  }
  if (st.agentView && st.agentView.a) agHeader(st.agentView.a, now);
}

// ---------- (3) read-only sub-agent chat page (same #detail, st.agentView) ----------
// header "back + name" + small text "dot model, elapsed/duration"; content same as the main chat (sub-agent = gray-blue robot; dispatches and main-session messages are on the left as "main session");
// read-only: no input box, no question/approval cards, no figure layer, no flipping; the back arrow returns to the main chat's original position (no history stacking); polls every 3 seconds while running
const AG_DOT = { running: "#6fb6ff", done: "#07c160", failed: "#fa5151", gone: "#6b717c" };
function agHeader(a, now) {
  setText($("#d-name"), a.description || t("c.subagent"));
  $("#d-name").classList.remove("lead");
  renderStat(null); // the sub-agent page doesn't show the main session's counts
  $("#d-zone").style.background = AG_DOT[a.state] || AG_DOT.gone;
  // "running 12:34" on the card becomes "ran 12:34" in the header
  const tm = a.state === "running" ? t("ag.ranFor", { t: agentClock(now - (isoToSec(a.startedAt) || now)) }) : agentCardTime(a, now);
  setText($("#d-sub"), modelLabel(a.model) + " · " + tm);
}
function openAgent(s, a) {
  if (!st.detailId || !a || !a.id) return;
  const msgs = $("#msgs");
  diag("agent-open", { id: st.detailId, agent: a.id });
  st.agentView = { sid: s.id || st.detailId, agentId: a.id, a, name: plateOf(s) || "", top: msgs.scrollTop,
    items: [], next: null, token: ++st.agToken, loading: false };
  resetFigures(null); // the sub-agent page has no figure layer; on return realign once (finished ones just park, no replay)
  $("#detail").classList.add("ag-view");
  setNewCount(0);
  agHeader(a, Date.now() / 1000);
  $("#older").replaceChildren();
  const sk = h("div", "skeleton");
  for (let i = 0; i < 5; i++) sk.append(h("i"));
  $("#list").replaceChildren(sk);
  loadAgent(null);
  if (st.agTimer) clearInterval(st.agTimer);
  st.agTimer = setInterval(() => {
    const v = st.agentView;
    if (v && !document.hidden && !v.loading && v.a && v.a.state === "running") loadAgent(null, true);
  }, DETAIL_POLL_MS);
}
function closeAgent(restore) {
  const v = st.agentView;
  if (!v) return;
  st.agentView = null;
  st.agToken++;
  if (st.agTimer) clearInterval(st.agTimer);
  st.agTimer = null;
  $("#detail").classList.remove("ag-view");
  if (!restore || !st.detailId) return;
  diag("agent-close", { id: st.detailId, agent: v.agentId });
  const s = st.detailOff ? offAsSession(st.detailOff) : (st.byId.get(st.detailId) || {});
  if (st.detailOff) fillOffHeader(st.detailOff); else fillDetailHeader(s, false);
  st.sig = null;
  renderList(s, "keep");
  renderOlder();
  $("#msgs").scrollTop = v.top; // return to the position before entering
  setNewCount(0);
  pollDetail();
}
async function loadAgent(before, quiet) {
  const v = st.agentView;
  if (!v || v.loading) return;
  const token = v.token;
  v.loading = true;
  if (before != null) $("#older").replaceChildren(h("span", null, t("c.loading")));
  let data = null;
  const sid = v.sid;
  try {
    const res = await api("/api/session/" + encodeURIComponent(sid) + "/agent/" + encodeURIComponent(v.agentId) +
      (before != null ? "?before=" + before : ""), null, FETCH_TIMEOUT_MS);
    if (res.ok) data = await res.json();
  } catch (e) {
    if (e.message === "auth") return;
  } finally {
    v.loading = false;
  }
  if (!st.agentView || st.agentView.token !== token) return;
  const msgs = $("#msgs");
  if (!data) {
    if (quiet) return;
    if (before == null) $("#list").replaceChildren(detailMessage(t("c.loadFail"), t("ag.loadFailSub"), null));
    else { agOlder(); toast(t("c.loadFail")); }
    return;
  }
  if (data.agent) v.a = data.agent;
  agHeader(v.a, Date.now() / 1000);
  const items = data.items || [];
  if (before != null) {
    const h0 = msgs.scrollHeight, t0 = msgs.scrollTop;
    v.items = items.concat(v.items);
    v.next = data.next;
    renderAgent();
    msgs.scrollTop = t0 + (msgs.scrollHeight - h0);
  } else if (quiet) {
    const away = awayFromBottom(msgs.scrollHeight, msgs.scrollTop, msgs.clientHeight);
    const t0 = msgs.scrollTop;
    const m = mergeItems(v.items, items);
    const same = JSON.stringify(m.items) === JSON.stringify(v.items);
    v.items = m.items;
    if (m.reset) v.next = data.next;
    if (same) return;
    renderAgent();
    msgs.scrollTop = away ? t0 : msgs.scrollHeight;
  } else {
    v.items = items;
    v.next = data.next;
    renderAgent();
    msgs.scrollTop = msgs.scrollHeight;
  }
  agOlder();
}
function agOlder() {
  const v = st.agentView;
  const older = $("#older");
  if (!v) return;
  if (v.next == null) { older.replaceChildren(h("span", null, t("dt.earliest"))); return; }
  const b = h("button", null, t("dt.older"));
  b.type = "button";
  b.onclick = () => loadAgent(v.next);
  older.replaceChildren(b);
}
function renderAgent() {
  const v = st.agentView;
  if (!v) return;
  const items = v.items;
  const s = st.byId.get(st.detailId) || {};
  const ctx = chatCtx(s);
  const main = speakerOf(s.name, ctx.self, ctx.dir, ctx.zones, st.guest);
  const tasks = taskStates(items);
  const nowSec = Date.now() / 1000;
  const frag = document.createDocumentFragment();
  let firstUser = true;
  for (const b of agentPagePlan(items)) {
    if (b.t === "time") { frag.append(h("div", "tm", chatStamp(b.sec, nowSec))); continue; }
    if (b.t === "sys") { frag.append(h("div", "tm" + (b.cls ? " " + b.cls : ""), b.text)); continue; } // system hints (context compacted / API error)
    if (b.t !== "group") continue; // sub-agents have no question/approval cards
    let col = null;
    const row = () => {
      const g = h("div", "cg ag");
      const c = h("div", "cg-col");
      const w = h("div", "cg-who");
      if (b.who === "main") {
        g.style.setProperty("--zc", main.color);
        w.append(h("span", "nm", t("ag.main", { name: main.plate || v.name })));
        g.append(chatAvatar(main), c);
      } else {
        w.append(h("span", "nm", v.a.description || t("c.subagent")));
        g.append(botAvatar(), c);
      }
      c.append(w);
      frag.append(g);
      return c;
    };
    for (const p of b.parts) {
      if (p.t === "tools") { // no figure to attach: keep the tag (the "keep tag when no anchor" case)
        const tg = toolGroup(p.idx.map((i) => items[i]), false, toolMark(p.idx, items, tasks), (p.hand || []).map((i) => items[i]), {});
        if (col) col.append(tg); else { tg.classList.add("solo"); frag.append(tg); }
        continue;
      }
      if (p.t !== "msg") continue;
      const it = items[p.i];
      col = row();
      const text = it.text || "";
      const el = h("div", "m ai md-on");
      el.append(mdNode(text));
      msgText.set(el, text);
      if (it.role === "user" && firstUser) { firstUser = false; el.classList.add("x"); peerFold(el, "ag:" + v.agentId, text); } // the dispatch text is folded to two lines by default
      col.append(el);
    }
  }
  mdSweep();
  if (!items.length) frag.append(detailMessage(t("ag.noRecord"), null, null));
  frag.append(h("div", "ag-ro", t("ag.readOnly", { name: main.plate || v.name || t("ag.mainDefault") })));
  $("#list").replaceChildren(frag);
  fitPeerFolds($("#list"));
}

// question card / approval card: treated as a message sent by this session, with avatar and name row, same width as an Agent bubble
function agentCard(s, ctx, card) {
  const sp = speakerOf(s.name, ctx.self, ctx.dir, ctx.zones, st.guest);
  const g = h("div", "cg ag cardrow");
  g.style.setProperty("--zc", sp.color);
  const c = h("div", "cg-col");
  c.append(whoLine(sp, "self"), card);
  g.append(chatAvatar(sp), c);
  return g;
}
// cross-session messages show at most two lines by default, with "expand" / "collapse" at the end; if it really doesn't exceed two lines, fitPeerFolds removes the button after drawing
// fold preview uses plain text: strip Markdown symbols and extra whitespace (.md isn't shown when folded, so list/paragraph line heights don't clip half a line)
function mdPlain(t) {
  return String(t || "")
    .replace(/```[^\n]*\n?/g, " ")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/^\s*>\s?/gm, "")
    .replace(/^\s*(?:[-*+]|\d+[.)])\s+/gm, "")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__|~~|`)/g, "")
    .replace(/(^|[\s(])[*_]+([^*_\n]+)[*_]+(?=$|[\s).,\uFF0C\u3002])/g, "$1$2") // may be followed by Chinese commas and full stops
    .replace(/\s+/g, " ")
    .trim();
}
function peerFold(el, key, text) {
  const open = st.peerOpen.has(key);
  el.classList.add("fold");
  if (!open) el.classList.add("clamp");
  el.insertBefore(h("div", "x-prev", mdPlain(text)), el.firstChild);
  const b = h("button", "x-more", open ? t("c.collapse") : t("c.expand"));
  b.type = "button";
  b.onclick = (e) => {
    e.stopPropagation();
    const now = !st.peerOpen.has(key);
    if (now) st.peerOpen.add(key); else st.peerOpen.delete(key);
    el.classList.toggle("clamp", !now);
    b.textContent = now ? t("c.collapse") : t("c.expand");
  };
  el.append(b);
}
function fitPeerFolds(root) {
  for (const el of root.querySelectorAll(".m.x.fold.clamp")) {
    const pv = el.querySelector(".x-prev");
    if (pv && pv.clientHeight > 0 && pv.scrollHeight <= pv.clientHeight + 2) { // fits within two lines: no fold, no button (can't measure while invisible, leave it for now)
      el.classList.remove("fold", "clamp");
      const b = el.querySelector(".x-more");
      if (b) b.remove();
    }
  }
}

const msgText = new WeakMap(); // bubble element -> plain text (for long-press copy / quote)
const msgMeta = new WeakMap(); // bubble element -> { who, name (speaker when quoting), receipt, raw (original text for recall), pend }
const OUTGOING_MS = 60000;
const userCount = (items) => items.reduce((n, it) => n + (it.role === "user" ? 1 : 0), 0);
function renderItems(items, s, keepCache) {
  const frag = document.createDocumentFragment();
  const waiting = s.status === "waiting";
  const target = waiting ? approveTarget(items) : null;
  const askIdx = waiting ? liveAskIndex(items) : -1;
  if (target || askIdx >= 0) diagCardShown(st.detailId, target ? "approve" : "ask");
  const liveKeys = new Set();
  const ctx = chatCtx(s);
  const tasks = taskStates(items);
  // text just sent and not yet in the transcript: drawn last (dimmed); no longer drawn once the transcript has more user messages or 60 seconds pass
  const users = userCount(items);
  const now = Date.now();
  const norm = (t) => String(t || "").replace(/\s+/g, "").slice(0, 40);
  const recent = items.slice(-12).filter((it) => it.role === "user").map((it) => norm(it.text));
  const prevN = (st.outgoing.get(st.detailId) || []).length;
  const out = (st.outgoing.get(st.detailId) || []).filter((p) =>
    p.failed || p.q || (users <= p.n0 && now - p.at < OUTGOING_MS && !recent.includes(norm(p.text)))); // the red ! for undelivered stays until the user dismisses it; queued/uploading attachments stay
  for (const p of st.outgoing.get(st.detailId) || []) if (!out.includes(p)) { carryFrom(p, items, st.detailId); pendFree(p); } // a pending bubble leaving: transfer its image to the transcript entry, release the remaining local previews
  if (out.length) st.outgoing.set(st.detailId, out); else st.outgoing.delete(st.detailId);
  if (out.length !== prevN) outboxSave();
  ctx.carry = items === st.items ? carryMap(items, st.detailId) : null; // which user entry the transferred local preview images hang on this round
  // when busy draw the reply placeholder bubble at the end; with an optimistic pend bubble the placeholder goes after the pend (without tools), otherwise chatPlan's ph carries the trailing tool string
  const phOn = s.status === "busy" && !st.detailOff;
  const busy = phOn && !out.length;
  const nowSec = Date.now() / 1000;
  const blocks = chatPlan(items, { approveIdx: target ? target.idx : -1, guest: st.guest, busy: busy });
  st.figBlocks = blocks;
  st.figPlan = figurePlan(items, tasks, nowSec, blocks, bgLiveIds(items, s)); // don't let figures the snapshot says are still running in the background be misjudged as finished by "a turn has passed"
  ctx.figKeys = new Map(st.figPlan.flatMap((e) => e.parts.map((p) => [p, e.key]))); // consecutive tool tags under the same bubble share one key
  ctx.figIds = new Map(st.figPlan.flatMap((e) => e.idx.map((i, k) => [i, items[i].toolUseId || "i:" + k]))); // detail row <-> figure id (same as figurePlan)
  ctx.agGlow = agentGlowPlan(items, st.figPlan); // which bubbles carry the sub-agent light effect (anchor same as the figure)
  for (const b of blocks) {
    if (b.t === "time") frag.append(h("div", "tm", chatStamp(b.sec, nowSec)));
    else if (b.t === "sys") frag.append(h("div", "tm" + (b.cls ? " " + b.cls : ""), b.text)); // system hint (context compacted): centered gray text, same as the time divider
    else if (b.t === "ask") {
      const it = items[b.i];
      if (b.i === askIdx) liveKeys.add(it.toolUseId || "");
      frag.append(agentCard(s, ctx, askBox(s, it, b.i === askIdx)));
    } else if (b.t === "approve") {
      // waiting for approval: among the trailing tools, the earliest one without a result yet (Claude Code asks in order) -> the approval bubble follows
      const it = items[b.i];
      liveKeys.add(it.toolUseId || "");
      frag.append(agentCard(s, ctx, approveBox(s, it, target.more)));
    } else frag.append(chatGroup(b, items, s, ctx, waiting, tasks));
  }
  if (!keepCache) mdSweep(); // segments before a window switch (chFrag) don't each clear; the last segment clears for all, so images in the previous window are reused even when the whole segment is redrawn
  pruneSent(st.sent, liveKeys); // for a prompt already answered / no longer awaiting approval, clear the "sent" record
  let prevSec = 0;
  for (const p of out) { // one row per entry, same as "me" in the transcript
    frag.append(pendFrag(p, s, items, prevSec));
    prevSec = p.at / 1000;
  }
  if (phOn && out.length) frag.append(chatGroup({ t: "group", key: "self", who: "self", parts: [{ t: "ph" }] }, items, s, ctx, false, tasks));
  return frag;
}

// A pending bubble (text/attachments): the same structure as my bubble in the transcript (name row + right avatar + receipt), so the swap to the real record is visually seamless;
// whether a time divider comes first follows chatPlan (pendNeedsStamp). Shared by the renderItems redraw and the incremental appendPend
function pendFrag(p, s, items, prevSec) {
  const frag = document.createDocumentFragment();
  if (pendNeedsStamp(items, p.at / 1000, prevSec)) {
    const tm = h("div", "tm", chatStamp(p.at / 1000, Date.now() / 1000));
    tm.dataset.pend = "1";
    frag.append(tm);
  }
  const { g, c: col } = meGroup(); // same structure as "me" in the transcript (name row + right avatar)
  const raw = st.guest ? stripGuestTag(p.text) : p.text; // a guest's pending text carries the prefix only to match the transcript; remove it for display
  const qd = parseQuoted(raw);
  const text = qd ? qd.body : raw;
  const lf = Array.isArray(p.files) && p.files.length ? p.files : null; // attachments being sent use a local preview (URL.createObjectURL); after it appears in the transcript swap to the real message's ref
  // The layout is identical to the final entry in the transcript: no text (only the "[attachments xN]" left) = attachment-only bubble .at-only (image drawn in the bubble, receipt at the image's bottom-right);
  // with text = text in the bubble, attachment block under the bubble. There is no "[1 attachments]" text bubble anymore
  const typed = lf ? text.replace(attachTailRe(), "") : text;
  const onlyAt = !!lf && !typed.trim();
  const shown = lf ? typed : text;
  p.atw = lf ? atNode(lf, 0, s.id) : null; // when it appears in the transcript the <img> in this block is transferred as is (carryFrom)
  const el = h("div", "m me pend" + (onlyAt ? " at-only" : "") + (p.failed ? " rc-fail" : ""), onlyAt ? "" : p.up || shown); // attachments with text: queue/upload progress temporarily replaces the body text
  p.el = el;
  msgText.set(el, onlyAt ? "" : text);
  const rc = receiptOf({ pend: true, failed: p.failed, stage: p.stage });
  msgMeta.set(el, { who: "me", name: t("c.me"), receipt: rc, pend: p });
  col.append(el);
  if (onlyAt) {
    el.append(p.atw);
    if (p.up) el.append(h("span", "up-tip", p.up)); // with no text, progress sits at the image's bottom-left and takes no layout space
  }
  if (qd) col.append(h("div", "rc-qt", qd.quote));
  el.append(rcMark(rc, el));
  if (p.atw && !onlyAt) col.append(p.atw);
  frag.append(g);
  return frag;
}
// On send: no full redraw, just append this one to the end of the list (before the reply placeholder bubble if there is one, same order as renderItems) and scroll to bottom.
// If it can't be incremental (sub-agent page open, the chat is empty and showing the empty-state text, session switched) fall back to a full redraw.
function appendPend(s, pend) {
  const list = $("#list");
  const msgs = $("#msgs");
  if (st.agentView || st.detailId !== s.id || !list || !st.items.length) {
    st.sig = null;
    renderList(s, "bottom");
    return;
  }
  const mine = st.outgoing.get(s.id) || [];
  const k = mine.indexOf(pend);
  const before = k > 0 ? mine[k - 1] : null;
  const prevSec = before ? before.at / 1000 : 0; // renderItems chains entries using the previous entry's `at` as well
  if (pend.el && pend.el.isConnected) { // resend: first remove the old red ! bubble (together with its own time divider)
    const og = pend.el.closest(".cg");
    const pv = og && og.previousElementSibling;
    if (pv && pv.dataset && pv.dataset.pend === "1") pv.remove();
    if (og) og.remove();
  }
  const frag = pendFrag(pend, s, st.items, prevSec);
  const ph = list.querySelector(":scope > .cg .ph-bub");
  const phRow = ph ? ph.closest(".cg") : null;
  // when the placeholder bubble carries a trailing tool string/figure: in a full redraw the tool string would join the previous reply and my bubble would come after it, so an incremental insert would make the tool string jump next round; in that case fall back to a full redraw
  if (phRow && (ph.dataset.fig || phRow.querySelector(".tools"))) {
    st.sig = null;
    renderList(s, "bottom");
    return;
  }
  if (phRow && phRow.parentNode === list) list.insertBefore(frag, phRow); else list.append(frag);
  st.sig = listSig(s);
  msgs.scrollTop = msgs.scrollHeight;
  setNewCount(0);
}
// Send the body out; buttons/input in box are disabled during sending and the clicked button spins. Returns whether it was delivered.
// pend: pending bubble for text/attachments - doesn't lock buttons or mark sending (order is handled by sendChain), only swaps the receipt by stage: got requestId = sent, typed into the terminal = delivered
async function submitSend(s, body, box, clicked, label, key, pend) {
  const card = !pend; // question/approval card answers: still hold st.sending to prevent duplicates
  if (card && st.sending) return false;
  const list = $("#list");
  // bubble answer/approval: show "sent" first, send in the background; if it wasn't sent put the buttons back
  // draw before marking sending: renderList doesn't redraw during sending
  const rerender = () => {
    if (st.detailId !== s.id) return;
    if (list.contains(document.activeElement)) document.activeElement.blur();
    st.sig = null;
    renderList(st.byId.get(s.id) || s, "keep");
  };
  if (key != null) {
    st.sent.set(key, {});
    rerender();
  }
  if (card) st.sending = true;
  const ctrls = box ? Array.from(box.querySelectorAll("button, input")) : [];
  const was = ctrls.map((c) => c.disabled);
  ctrls.forEach((c) => { c.disabled = true; });
  if (box) box.classList.add("sending");
  const orig = clicked ? Array.from(clicked.childNodes) : null;
  if (clicked) {
    clicked.classList.add("busy");
    clicked.replaceChildren(h("span", "spinner"), document.createTextNode(label || ""));
  }
  let r;
  try {
    r = await runRequest(sendUrl(sessionPath(s.id, "send"), body, lang()), body, pend ? () => pendStage(pend, "sent") : null);
  } catch (e) {
    r = null; // login expired, redirected
    if (e.message !== "auth") diagErr("submitSend", e); // other exceptions are code bugs, don't swallow them as login expiry
  }
  if (card) st.sending = false;
  if (box) box.classList.remove("sending");
  if (clicked) {
    clicked.classList.remove("busy");
    clicked.replaceChildren(...orig);
  }
  if (!r) {
    if (key != null) { st.sent.delete(key); rerender(); }
    ctrls.forEach((c, i) => { c.disabled = was[i]; });
    return false;
  }
  // bubble keys: after delivery don't restore buttons until the chat confirms it was handled; if only part of the steps was sent, resending is not allowed either
  const partial = r.status !== "done" && r.sentSteps ? r.sentSteps : 0;
  if (key != null && partial) {
    st.sent.set(key, { partial });
    rerender();
  } else if (key != null && r.status !== "done") {
    st.sent.delete(key); // not a single step was sent: put the buttons back, earlier choices are still in st.ask
    rerender();
  } else if (key == null) {
    ctrls.forEach((c, i) => { c.disabled = was[i]; });
  }
  if (r.status === "done") {
    if (pend) pendStage(pend, "delivered");
    afterSent(s.id, body);
    return true;
  }
  st.sendErr = r.error || ""; // sendText uses this to decide whether to remove the optimistic bubble or mark it red
  toast(partial ? partialFailText(partial) : failReason(r.error), 4000);
  return false;
}

// hint that replaces the buttons when sent / partly failed
function sentNote(sent) {
  return h("div", "hint", sent.partial ? partialFailText(sent.partial) : t("chat.sentWait"));
}

function approveBox(s, it, more) {
  const box = h("div", "approve");
  box.append(h("div", "lb", st.guest ? t("ask.adminApprove") : t("ask.youApprove")), h("div", "cmd", it.text || ""));
  if (more > 0) box.append(h("div", "hint", t("ask.more", { n: more })));
  if (st.guest) { box.append(h("div", "hint", t("ask.guestApprove"))); return box; }
  const key = it.toolUseId || "";
  const sent = st.sent.get(key);
  if (sent) {
    box.classList.add("sent"); // sent and awaiting confirmation = the gray answered style
    box.append(sentNote(sent));
    return box;
  }
  const row = h("div", "ap-btns");
  for (const [choice, label, cls] of approveDefs(it.text)) {
    const b = h("button", cls, label);
    b.type = "button";
    b.onclick = () => submitSend(s, { steps: approveSteps(choice) }, box, b, label, key);
    row.append(b);
  }
  box.append(row);
  return box;
}

function askBox(s, it, live) {
  const qs = Array.isArray(it.questions) ? it.questions : [];
  const box = h("div", "ask");
  if (it.answered) {
    box.classList.add("done");
    box.append(h("div", "lb", t("ask.answered")));
    // one small gray line per question title, then a line with the answer (options as small rounded tags, user-typed ones in white text), multi-select separated by a Chinese enumeration comma
    // the note written on a preview question (it.notes) goes on its own gray line "Note: ..."
    const rows = answeredRows(qs, it.answers, it.notes);
    if (!rows.length) { box.append(h("div", "ask-sum", it.text || "")); return box; }
    const ul = h("div", "ans");
    for (const r of rows) {
      const row = h("div", "ans-row");
      row.append(h("div", "aq", r.q));
      const av = h("div", "av");
      r.parts.filter((p) => p.t !== "note").forEach((p, k) => {
        if (k) av.append(h("span", "sep", isEn() ? ", " : "\u3001"));
        av.append(h("span", p.t === "opt" ? "a-tag" : "a-ot", p.text));
      });
      if (av.childNodes.length) row.append(av);
      for (const p of r.parts) if (p.t === "note") row.append(h("div", "a-nt", t("ask.note") + p.text));
      ul.append(row);
    }
    box.append(ul);
    return box;
  }
  const head = h("div", "lb", st.guest ? t("ask.askAdmin") : t("ask.askYou"));
  box.append(head);
  if (st.guest) { // guest is read-only: no option buttons
    box.append(h("div", "ask-sum", it.text || ""));
    if (live) {
      box.classList.add("live");
      box.append(h("div", "hint", t("ask.guestAnswer")));
    }
    return box;
  }
  const sentState = live ? st.sent.get(it.toolUseId || "") : null;
  if (!live || !qs.length || sentState || !askAnswerable(qs)) {
    box.append(h("div", "ask-sum", it.text || ""));
    if (sentState) box.append(sentNote(sentState));
    else if (live && qs.length) box.append(h("div", "hint", t("ask.tooMany")));
    if (sentState) box.classList.add("sent"); // sent and awaiting confirmation = the gray answered style
    else if (live) box.classList.add("live");
    return box;
  }
  box.classList.add("live");
  if (qs.length > 1) head.append(h("span", "ask-n", t("ask.nq", { n: qs.length })));
  const key = it.toolUseId || "";
  if (!st.ask.has(key)) st.ask.set(key, { sel: [], txt: [], multi: qs.map(() => []), note: [], ownOn: [] });
  const state = st.ask.get(key);
  const single = qs.length === 1 && !qs[0].multiSelect;
  // all question cards: tick first, then press submit; no tap-to-send anymore
  const picksOf = () => qs.map((q, i) => {
    if (q.multiSelect) return { multi: state.multi[i], text: state.ownOn[i] ? state.txt[i] || "" : "" }; // an unticked "other" row is not sent
    if (isPreviewQ(q)) return { pick: state.sel[i], note: state.note[i] || "" };
    return state.sel[i] === "custom" ? { text: state.txt[i] || "" } : state.sel[i];
  });
  const done = (q, i) => (q.multiSelect ? state.multi[i].length > 0 || (!!state.ownOn[i] && !!cleanReplyText(state.txt[i])) : state.sel[i] != null);
  const sendNow = (clicked, label) => {
    const steps = buildAskSteps(qs, picksOf());
    if (steps) submitSend(s, { steps }, box, clicked, label, key).then((ok) => { if (ok) st.ask.delete(key); });
  };
  const submit = h("button", "go", t("ask.submit"));
  submit.type = "button";
  // the submit button is always shown
  const submitRow = h("div", "ask-go");
  const sync = () => {
    const n = qs.filter(done).length;
    submit.disabled = !buildAskSteps(qs, picksOf());
    submit.textContent = n < qs.length && qs.length > 1 ? t("ask.submitN", { n, total: qs.length }) : t("ask.submit");
  };
  qs.forEach((q, qi) => {
    const g = h("div", "q");
    const qt = h("div", "qt", q.question || "");
    if (q.multiSelect) qt.append(h("span", "q-multi", t("ask.multi")));
    if (q.header) g.append(h("div", "qh", q.header));
    g.append(qt);
    const grp = h("div", "opts" + (q.multiSelect ? " multi" : ""));
    const rows = [];
    const pv = isPreviewQ(q);
    // preview question: a note row is always shown at the end of the option group (fixed position; the DOM isn't reinserted while typing, to avoid iOS losing focus)
    const noteRow = h("label", "opt own-row note-row");
    const noteInp = h("input", "own");
    const paint = () => {
      rows.forEach((r, oi) => r.classList.toggle("on", q.multiSelect ? state.multi[qi].includes(oi + 1) : state.sel[qi] === oi + 1));
      own.classList.toggle("on", q.multiSelect ? !!state.ownOn[qi] : state.sel[qi] === "custom");
      if (!pv) return;
      noteRow.classList.toggle("on", !!cleanReplyText(state.note[qi]));
    };
    (q.options || []).forEach((label, oi) => {
      const b = h("button", "opt");
      b.type = "button";
      const tx = h("span", "o-tx");
      tx.append(h("span", "o-lb", String(label)));
      const d = Array.isArray(q.descs) ? q.descs[oi] : "";
      if (d) tx.append(h("span", "o-ds", d));
      b.append(tx);
      b.append(h("i", "o-mk"));
      b.onclick = () => {
        if (q.multiSelect) {
          const m = state.multi[qi];
          const at = m.indexOf(oi + 1);
          if (at >= 0) m.splice(at, 1); else m.push(oi + 1);
        } else {
          state.sel[qi] = oi + 1;
        }
        paint();
        sync();
      };
      rows.push(b);
      grp.append(b);
    });
    const own = h("label", "opt own-row");
    const inp = h("input", "own");
    inp.type = "text";
    inp.maxLength = 500;
    inp.placeholder = q.multiSelect ? t("ask.addMore") : t("ask.own");
    inp.enterKeyHint = single ? "send" : "done";
    inp.value = state.txt[qi] || "";
    inp.addEventListener("input", () => {
      state.txt[qi] = inp.value;
      if (q.multiSelect) state.ownOn[qi] = !!cleanReplyText(inp.value);
      else {
        if (cleanReplyText(inp.value)) state.sel[qi] = "custom";
        else if (state.sel[qi] === "custom") state.sel[qi] = undefined;
      }
      paint();
      sync();
    });
    inp.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;
      e.preventDefault();
      if (single && !submit.disabled) sendNow(submit, "");
      else inp.blur();
    });
    own.append(svgEl(PEN_SVG), inp, h("i", "o-mk"));
    // tapping the row (check mark / pen / padding) ticks "other" like an option and focuses the input; multi-select toggles it.
    // A tap on the label fires two clicks (the tapped child, then the label activation on the input): preventDefault stops the second one so the toggle runs once
    own.addEventListener("click", (e) => {
      if (e.target === inp) {
        if (q.multiSelect) state.ownOn[qi] = true; else state.sel[qi] = "custom";
      } else {
        e.preventDefault();
        let on = true;
        if (q.multiSelect) on = state.ownOn[qi] = !state.ownOn[qi];
        else state.sel[qi] = "custom";
        if (on) inp.focus(); else inp.blur();
      }
      paint();
      sync();
    });
    if (askHasOwn(q)) grp.append(own); // preview question (list on the left, preview on the right) has no "type your own" row
    if (pv) {
      grp.append(noteRow);
      noteInp.type = "text";
      noteInp.maxLength = 500;
      noteInp.placeholder = t("ask.notePh");
      noteInp.enterKeyHint = single ? "send" : "done";
      noteInp.value = state.note[qi] || "";
      noteInp.addEventListener("input", () => {
        state.note[qi] = noteInp.value;
        paint();
        sync();
      });
      noteInp.addEventListener("keydown", (e) => {
        if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;
        e.preventDefault();
        if (single && !submit.disabled) sendNow(submit, "");
        else noteInp.blur();
      });
      noteRow.append(svgEl(PEN_SVG), noteInp);
    }
    paint();
    g.append(grp);
    box.append(g);
  });
  submit.onclick = () => sendNow(submit, "");
  submitRow.append(submit);
  box.append(submitRow);
  sync();
  return box;
}

// go to Orca: in the same click write the clipboard and then navigate (iOS requires it inside a user gesture)
function copyFallback(text) {
  const ta = h("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.cssText = "position:fixed;top:0;left:0;opacity:0";
  document.body.append(ta);
  ta.select();
  ta.setSelectionRange(0, text.length);
  let ok = false;
  try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
  ta.remove();
  return ok;
}
function goOrca() {
  const s = st.byId.get(st.detailId);
  if (!s) return;
  const name = s.name;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(name).catch(() => copyFallback(name));
    } else {
      copyFallback(name);
    }
  } catch (e) {
    copyFallback(name);
  }
  location.href = "orca://";
  setTimeout(() => {
    if (document.visibilityState === "visible") toast(t("orca.copied", { name }), 4000);
  }, 1500);
}

// ---------- reply: text / button steps ----------
// Flow: POST to get requestId -> poll /api/requests/<rid> (every 0.3 s for the first 3 seconds, then every 0.7 s); at most 35 seconds from the tap on send (including each request's timeout).
// How each result is judged is decided by nextPollAction in logic.js.
// Returns { status: "done" | "failed", error?, lines? }; only login expiry throws (already redirected to the login page).
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// onAccepted: called once when the server accepts (requestId obtained), to switch the pending bubble to "sent out"
async function runRequest(path, body, onAccepted) {
  const t0 = Date.now();
  const left = () => REQ_MAX_MS - (Date.now() - t0);
  let res;
  try {
    res = await post(path, body, FETCH_TIMEOUT_MS);
  } catch (e) {
    if (e.message === "auth") throw e;
    // a POST aborted by timeout may already have reached the server: it can't be called a failure
    return { status: "failed", error: e.name === "AbortError" ? "unknown-status" : "network" };
  }
  if (!res.ok) {
    let code = "";
    try { code = String((await res.json()).error || ""); } catch (e) { code = ""; }
    if (code === "not-claude" || code === "helper-restarted") return { status: "failed", error: code };
    if (res.status === 404) return { status: "failed", error: "session-gone" };
    return { status: "failed", error: code || "http-" + res.status };
  }
  let data = null;
  try { data = await res.json(); } catch (e) { data = null; }
  const rid = data && data.requestId;
  // for a recall the server returns mode (interrupted = Esc enqueued; answered / processing = no key sent, no requestId, counts as success directly)
  const mode = data && typeof data.mode === "string" ? data.mode : "";
  if (!rid) return mode ? { status: "done", mode } : { status: "failed", error: "bad-response" };
  if (onAccepted) onAccepted();
  const r = await pollRequest(rid, t0);
  return mode ? Object.assign({}, r, { mode }) : r;
}
// poll /api/requests/<rid>, t0 = timing start (ms)
async function pollRequest(rid, t0) {
  const left = () => REQ_MAX_MS - (Date.now() - t0);
  for (;;) {
    await sleep(Math.max(0, Math.min(pollDelayMs(Date.now() - t0), left())));
    let code = 0;
    let data = null;
    const wait = left();
    if (wait > 0) {
      try {
        const r = await api("/api/requests/" + encodeURIComponent(rid), null, Math.min(FETCH_TIMEOUT_MS, wait));
        code = r.status;
        if (r.ok) data = await r.json();
      } catch (e) {
        if (e.message === "auth") throw e;
        code = 0; // network blip / timeout: leave it to nextPollAction
      }
    }
    const next = nextPollAction(code, data, Date.now() - t0);
    if (next.status !== "pending") return next;
  }
}

// ---------- sending images / files ----------
// Raw bytes POSTed to /api/uploads?name= (only stores the file, returns { file }; the old /api/sessions/<id>/upload returns { requestId }).
// Only XHR gives upload progress. Returns { file } / { rid } or { status: "failed", error }; login expiry throws auth.
function uploadBlob(path, blob, onProgress) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open("POST", path);
    x.withCredentials = true;
    x.timeout = 180000;
    x.setRequestHeader("Content-Type", blob.type || "application/octet-stream");
    x.upload.onprogress = (e) => { if (e.lengthComputable) onProgress(e.loaded / e.total); };
    x.onerror = () => resolve({ status: "failed", error: "network" });
    x.ontimeout = () => resolve({ status: "failed", error: "unknown-status" });
    x.onload = () => {
      if (x.status === 401) { goLogin(); reject(new Error("auth")); return; }
      let data = null;
      try { data = JSON.parse(x.responseText); } catch (e) { data = null; }
      if (x.status === 413) { resolve({ status: "failed", error: "too-large" }); return; }
      if (x.status < 200 || x.status >= 300) {
        const code = data && data.error ? String(data.error) : "";
        resolve({ status: "failed", error: code === "not-claude" || code === "helper-restarted" ? code : (x.status === 404 ? "session-gone" : code || "http-" + x.status) });
        return;
      }
      if (data && data.file) { resolve({ file: data.file }); return; }
      if (!data || !data.requestId) { resolve({ status: "failed", error: "bad-response" }); return; }
      resolve({ rid: data.requestId });
    };
    x.send(blob);
  });
}

// Images: longest edge scaled to 2000px; GIF/PNG keep their format (scaled only when huge), others converted to JPEG 0.85. If decoding fails send as is.
async function prepareImage(file) {
  const fallback = { blob: file, name: file.name || t("c.image") };
  let bmp;
  try { bmp = await createImageBitmap(file); } catch (e) { return fallback; }
  try {
    const plan = imagePlan(file.type, bmp.width, bmp.height);
    const name = uploadName(file.name || t("c.image"), plan.type);
    if (plan.mode === "keep") return { blob: file, name };
    const cv = document.createElement("canvas");
    cv.width = plan.w;
    cv.height = plan.h;
    const g = cv.getContext("2d");
    if (plan.type === "image/jpeg") { g.fillStyle = "#fff"; g.fillRect(0, 0, plan.w, plan.h); }
    g.drawImage(bmp, 0, 0, plan.w, plan.h);
    const blob = await new Promise((r) => cv.toBlob(r, plan.type, JPEG_QUALITY));
    return blob ? { blob, name } : fallback;
  } catch (e) {
    diagErr("prepareImage", e); // if compression fails send the original anyway, but we need to know why
    return fallback;
  } finally {
    if (bmp.close) bmp.close();
  }
}

// ---------- attachment bar: put in first, send together with the text ----------
function addToTray(files) {
  const picked = Array.from(files || []).filter(Boolean);
  if (!picked.length) return;
  let over = 0;
  let big = 0;
  for (const f of picked) {
    const r = addAttachments(st.tray.map((t) => t.file), [f]);
    over += r.overLimit;
    big += r.tooBig;
    if (r.list.length > st.tray.length) {
      const isImg = /^image\//.test(f.type);
      st.tray.push({ id: ++trayId, file: f, isImg, url: isImg ? URL.createObjectURL(f) : "", saved: null });
    }
  }
  if (big) toast(t("up.tooBig", { n: big }));
  else if (over) toast(t("up.tooMany", { n: over }));
  renderTray();
}
let trayId = 0;
function removeFromTray(id) { // can delete while sending (the one being sent has already taken its attachments)
  const i = st.tray.findIndex((t) => t.id === id);
  if (i < 0) return;
  if (st.tray[i].url) URL.revokeObjectURL(st.tray[i].url);
  st.tray.splice(i, 1);
  renderTray();
}
function clearTray() {
  for (const t of st.tray) if (t.url) URL.revokeObjectURL(t.url);
  st.tray = [];
  renderTray();
}
// there is no send button in the attachment bar: with attachments only and no typing, the IME keyboard's "Send" (Enter -> onSend) works too
function renderTray() {
  const box = $("#tray");
  if (!box) return;
  box.hidden = !st.tray.length;
  box.replaceChildren(...st.tray.map((tr) => {
    const it = h("div", "tray-it" + (tr.isImg ? "" : " doc"));
    if (tr.isImg) {
      const im = h("img");
      im.src = tr.url;
      im.alt = tr.file.name || t("c.image");
      it.append(im);
    } else {
      it.append(h("span", "tray-nm", tr.file.name || t("c.file")));
    }
    const x = h("button", "tray-x", "✕");
    x.type = "button";
    x.setAttribute("aria-label", t("up.remove"));
    x.onclick = () => removeFromTray(tr.id);
    it.append(x);
    return it;
  }));
  autosizeReply();
}

// with attachments: upload one by one (overall progress "uploading 2/3"), send one message after all succeed; if any fails stop and mark the bubble red ! (already uploaded ones aren't uploaded again on resend)
// queued into sendChain like text and sent in order (queued when busy, no message is lost);
// at the moment of pressing, move the attachment bar and the input text into this message's own queue and clear them, so the next message's attachments can be added
function sendWithTray() {
  const s = st.byId.get(st.detailId);
  if (!s || !st.tray.length) return;
  const sid = s.id;
  const raw = $("#reply").value;
  const input = cleanReplyText(raw);
  const quote = st.quote;
  const items = st.tray;
  st.tray = []; // only moved: the preview image URLs are released after sending finishes (or this message is deleted)
  renderTray();
  closePlus();
  closeClip();
  $("#reply").blur();
  const body = buildSendBody(input, []);
  if (quote) body.quote = quote; // the quote reply is assembled by the server
  preCleared.add(body);
  st.drafts.delete(sid);
  setQuote("");
  $("#reply").value = "";
  autosizeReply();
  // first draw a "sending" bubble (queue / upload progress is also written on it); it disappears automatically once it appears in the transcript
  const shown = (input ? buildQuoteText(quote, input) + "\n" : "") + t("chat.attachN", { n: items.length });
  const list0 = st.outgoing.get(sid) || [];
  const pend = { text: st.guest ? withGuestTag(shown) : shown, n0: userCount(st.items) + list0.filter((p) => !p.failed).length, at: Date.now(), q: true, stage: "clock", body, raw, quote, input, items };
  // in the bubble use the attachment bar's local preview image first (lo = local, can't be opened or long-pressed)
  // the preview URL is owned by this pend, released by pendFree when the pend leaves st.outgoing
  pend.files = items.map((tr) => ({ kind: tr.isImg ? "image" : kindByName(tr.file.name), name: tr.file.name || (tr.isImg ? t("c.image") : t("c.file")), size: tr.file.size, lo: 1, local: tr.isImg ? URL.createObjectURL(tr.file) : "" }));
  st.outgoing.set(sid, list0.concat([pend]));
  queueTray(s, pend); // queue first (fix the "queued" label) then draw
  appendPend(s, pend);
}
// this attachment message is queued into the send queue (shared by first send and "resend")
function queueTray(s, pend) {
  const sid = s.id;
  const items = pend.items;
  const total = items.length;
  if (sendQ > 0) pend.up = t("up.queued");
  const label = (x) => {
    pend.up = x;
    const el = pend.el;
    const tip = el && el.querySelector(":scope > .up-tip"); // attachment-only bubble: progress is a small strip on the image
    if (el && el.classList.contains("at-only")) {
      if (tip) tip.textContent = x; else el.insertBefore(h("span", "up-tip", x), el.querySelector(":scope > .rc-mk"));
    } else if (tip) tip.textContent = x;
    else if (el && el.isConnected && el.firstChild && el.firstChild.nodeType === 3) el.firstChild.nodeValue = x;
  };
  const job = () => waitSendIdle().then(async () => {
    let err = null;
    try {
      for (let i = 0; i < total && !err; i++) {
        const tr = items[i];
        if (tr.saved) continue; // already uploaded last time
        const lb = (x) => label(uploadProgressText(i, total) + (isEn() ? "  " : "\u3000") + x);
        lb(t("up.processing"));
        const prep = tr.isImg ? await prepareImage(tr.file) : { blob: tr.file, name: tr.file.name || t("c.file") };
        if (prep.blob.size > MAX_UPLOAD) { err = "too-large"; break; }
        lb("0%");
        const up = await uploadBlob(plainUploadPath(prep.name), prep.blob, (f) => lb(Math.round(f * 100) + "%"));
        if (up.file) tr.saved = up.file; else err = up.error || "network";
      }
    } catch (e) {
      if (e.message !== "auth") diagErr("sendWithTray", e); // code exceptions in upload/compression are still marked red ! but must be reported
      return false; // login expired, redirected
    }
    if (err) {
      toast(t("up.failed", { why: failReason(err) }), 4500);
      return false;
    }
    Object.assign(pend.body, buildSendBody(pend.input, items.map((x) => x.saved)));
    pend.q = false;
    pend.at = Date.now();
    delete pend.up;
    if (st.detailId === sid) { st.sig = null; renderList(st.byId.get(sid) || s, "keep"); } // progress text switched back to the original text
    return submitSend(st.byId.get(sid) || s, pend.body, null, null, "", null, pend);
  });
  sendQ++;
  sendChain = sendChain.then(job, job);
  sendChain.then((ok) => {
    sendQ--;
    if (ok) { for (const x of items) if (x.url) URL.revokeObjectURL(x.url); return; }
    // not sent: the bubble stays marked red ! (tap to resend / delete); attachments and original text are not put back into the attachment bar / input box automatically
    delete pend.up;
    pend.q = false;
    pend.failed = true;
    pendMark(pend);
    if (st.detailId === sid) { st.sig = null; renderList(st.byId.get(sid) || s, "keep"); }
  });
}

function onSend() {
  if (st.tray.length) sendWithTray(); else sendText();
}

async function readClipImage() {
  try {
    if (!navigator.clipboard || !navigator.clipboard.read) return null;
    const items = await navigator.clipboard.read();
    for (const it of items) {
      const t = it.types.find((x) => x.startsWith("image/"));
      if (t) {
        const b = await it.getType(t);
        return new File([b], "clipboard." + (t.split("/")[1] || "png").replace(/[^a-z0-9]/gi, ""), { type: t });
      }
    }
  } catch (e) { /* no permission / no content: treat as none */ }
  return null;
}
function openClip(file) {
  closeClip();
  st.clipBlob = file;
  st.clipUrl = URL.createObjectURL(file);
  $("#clip-img").src = st.clipUrl;
  $("#clip-card").hidden = false;
}
function closeClip() {
  if (st.clipUrl) URL.revokeObjectURL(st.clipUrl);
  st.clipUrl = "";
  st.clipBlob = null;
  const c = $("#clip-card");
  if (c) c.hidden = true;
}
function closePlus() {
  const p = $("#plus-panel");
  if (!p) return;
  p.hidden = true;
  $("#btn-plus").classList.remove("on");
  $("#btn-plus").setAttribute("aria-expanded", "false");
}
function openPlus() {
  closeClip();
  $("#reply").blur();
  $("#plus-panel").hidden = false;
  $("#btn-plus").classList.add("on");
  $("#btn-plus").setAttribute("aria-expanded", "true");
}
let plusBusy = false;
async function onPlus() {
  if (!$("#plus-panel").hidden) { closePlus(); return; }
  if (!$("#clip-card").hidden) { closeClip(); return; }
  if (plusBusy) return; // can open the plus menu while sending to add the next message's attachments
  openPlus(); // no more automatic clipboard reads (iOS pops up a "Paste" bubble each time); to paste, tap "Paste image" in the panel
}
async function onPastePanel() {
  const f = await readClipImage();
  if (!f) { toast(t("up.noClip"), 5000); return; }
  closePlus();
  openClip(f);
}
function bindPlus() {
  $("#btn-plus").onclick = onPlus;
  $("#clip-x").onclick = closeClip;
  $("#clip-send").onclick = () => { const f = st.clipBlob; if (f) { addToTray([f]); closeClip(); } };
  const inputs = { photo: $("#in-photo"), camera: $("#in-camera"), file: $("#in-file"), pick: $("#in-pick") };
  $("#btn-pick").onclick = () => { if (canAttach()) inputs.pick.click(); }; // "Choose file" in the desktop input area: any type, multi-select
  for (const el of Object.values(inputs)) {
    el.addEventListener("change", () => {
      const fs = Array.from(el.files || []);
      el.value = "";
      if (fs.length) { closePlus(); addToTray(fs); }
    });
  }
  $("#plus-panel").addEventListener("click", (e) => {
    const c = e.target.closest(".pp-cell");
    if (!c) return;
    if (c.dataset.act === "paste") onPastePanel(); else inputs[c.dataset.act].click();
  });
  $("#reply").addEventListener("focus", closePlus);
  $("#msgs").addEventListener("pointerdown", () => { closePlus(); });
}

// ---------- desktop: Ctrl/Cmd+V paste, dragged-in images and files -> attachment bar (same pipeline as the plus menu: max 9, image compression, sent with the text) ----------
// attachments can be added: chat page open, not an off-duty session, reply bar usable (also while sending)
function canAttach() {
  return !!st.detailId && !st.detailOff && !$("#composer").hidden && !$("#btn-plus").hidden; // can be added while sending
}
function clipFiles(dt) {
  const fs = Array.from((dt && dt.files) || []);
  if (fs.length) return fs;
  return Array.from((dt && dt.items) || []).filter((i) => i.kind === "file").map((i) => i.getAsFile()).filter(Boolean);
}
const hasFiles = (dt) => !!dt && Array.from(dt.types || []).includes("Files");
function bindDesktopFiles() {
  document.addEventListener("paste", (e) => {
    if (!canAttach()) return;
    const t = e.target;
    // only handles paste inside the chat page (reply box, bubble area) or with no focus; search boxes etc. behave as usual
    if (!(t === document.body || t === document.documentElement || (t.closest && t.closest("#detail")))) return;
    if (t !== $("#reply") && t.closest && t.closest("#msgs") && listInput()) return; // the "type your own..." box in a bubble: paste text as usual
    const cd = e.clipboardData;
    const files = clipFiles(cd);
    if (pasteKind(Array.from((cd && cd.types) || []), files, cd ? cd.getData("text/plain") : "") !== "files") return; // text: goes into the input box as is
    e.preventDefault();
    addToTray(files);
  });
  // drag and drop: overlay a translucent hint on the chat page, dropping puts the files in the attachment bar. A depth counter prevents flicker when passing over child elements
  const d = $("#detail");
  const hint = $("#drop-hint");
  let depth = 0;
  const off = () => { depth = 0; hint.hidden = true; };
  d.addEventListener("dragenter", (e) => {
    if (!hasFiles(e.dataTransfer) || !canAttach()) return;
    e.preventDefault();
    depth++;
    hint.hidden = false;
  });
  d.addEventListener("dragover", (e) => {
    if (!hasFiles(e.dataTransfer) || !canAttach()) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
  });
  d.addEventListener("dragleave", () => { if (depth && --depth === 0) hint.hidden = true; });
  d.addEventListener("drop", (e) => {
    if (!hasFiles(e.dataTransfer)) return;
    e.preventDefault();
    off();
    if (!canAttach()) return;
    const files = clipFiles(e.dataTransfer);
    if (files.length) { closePlus(); addToTray(files); }
  });
  // dropped elsewhere on the page: the browser would open the file directly and leave the app; block it
  for (const ev of ["dragover", "drop"]) {
    addEventListener(ev, (e) => { if (hasFiles(e.dataTransfer)) { e.preventDefault(); if (ev === "drop") off(); } });
  }
  addEventListener("dragend", off);
}

// ---------- chat bubbles: long press -> copy / quote reply ----------
function setQuote(text) {
  st.quote = text || "";
  $("#quote-bar").hidden = !st.quote;
  setText($("#quote-tx"), quotePreview(st.quote));
}
async function copyText(text) {
  let ok = false;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) { await navigator.clipboard.writeText(text); ok = true; }
  } catch (e) { ok = false; }
  if (!ok) ok = copyFallback(text);
  toast(ok ? t("c.copied") : t("c.copyFailAlt"));
}
// ---------- popup menu next to a bubble (dark gray rounded, icon + small text per row), read receipts, recall, forward ----------
// the menu sits above the bubble (below if no room) and closes on tapping blank space or scrolling; bubbles do not use the bottom actionSheet.
const BM_ICONS = { // hard-coded constant, contains no conversation content
  select: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4h6M9 20h6M12 4v16"/></svg>', // text cursor (I-beam)
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>',
  quote: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9 7H6a2 2 0 0 0-2 2v3h5V7zM9 12c0 3-1.5 5-4 5.5M20 7h-3a2 2 0 0 0-2 2v3h5V7zM20 12c0 3-1.5 5-4 5.5"/></svg>',
  forward: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M14 5l7 7-7 7M21 12H9a5 5 0 0 0-5 5v2"/></svg>',
  recall: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12M8 11l4 4 4-4"/><path d="M5 19h14"/></svg>', // download (down arrow over a line)
  share: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15V3M8 7l4-4 4 4"/><path d="M5 11v8a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-8"/></svg>', // share (box with an arrow)
  copypath: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/></svg>', // copy path (chain link)
};
const BM_LABEL = new Proxy({}, { get: (_, k) => t("bm." + String(k)) }); // menu items are looked up by bm.<item>
const BM_GUARD_MS = 350; // the click from the finger lifting onto the menu right after it pops up doesn't count
let bmState = null;      // { el (bubble), pop, at }
function closeBubbleMenu() {
  if (!bmState) return;
  bmState.el.classList.remove("bm-on");
  bmState.pop.remove();
  bmState = null;
}
// pop up a small floating layer next to a bubble: content is the node inside (a row of menu buttons / recall confirmation)
function openBubblePop(el, content, cls, box) { // box: the visible frame, defaulting to the chat area (list-row menus pass the viewport)
  closeBubbleMenu();
  const pop = h("div", "bm-pop" + (cls ? " " + cls : ""));
  pop.setAttribute("role", "menu");
  const arrow = h("i", "bm-arrow");
  pop.append(content, arrow);
  document.body.append(pop);
  const r = el.getBoundingClientRect();
  const b = box || $("#msgs").getBoundingClientRect();
  const pl = menuPlace(r, pop.offsetWidth, pop.offsetHeight, { top: b.top, bottom: b.bottom, left: b.left, right: b.right });
  pop.style.left = pl.x + "px";
  pop.style.top = pl.y + "px";
  pop.classList.toggle("below", pl.below);
  arrow.style.left = Math.max(14, Math.min(pop.offsetWidth - 14, pl.ax)) + "px";
  el.classList.add("bm-on");
  bmState = { el, pop, at: Date.now() };
  return pop;
}
function bmButton(label, cls, run, iconSvg) {
  const b = h("button", "bm-it" + (cls ? " " + cls : ""));
  b.type = "button";
  b.setAttribute("role", "menuitem");
  if (iconSvg) {
    const ic = h("span", "bm-ic");
    ic.innerHTML = iconSvg;
    b.append(ic);
  }
  b.append(h("span", "bm-tx", label));
  b.addEventListener("click", (e) => {
    e.stopPropagation();
    if (!bmState || Date.now() - bmState.at < BM_GUARD_MS) return;
    closeBubbleMenu();
    run();
  });
  return b;
}
// text selected with the mouse inside a bubble (only counts if the selection lies entirely in that bubble); returns "" if none
function bubbleSelection(el) {
  const g = window.getSelection ? window.getSelection() : null;
  if (!g || g.isCollapsed || !g.rangeCount) return "";
  if (!el.contains(g.anchorNode) || !el.contains(g.focusNode)) return "";
  return String(g.toString() || "").trim();
}
function openBubbleMenu(el) {
  if (el.dataset && el.dataset.f) { openAttMenu(el); return; } // the long press is on an attachment
  if (el.classList.contains("at-only")) { openAttMenu(null, el); return; } // blank area of an attachment-only bubble: only quote/recall
  const text = msgText.get(el);
  if (!text) return;
  const meta = msgMeta.get(el) || {};
  const wide = isWide();
  const selTx = wide ? bubbleSelection(el) : "";
  const row = h("div", "bm-row");
  for (const k of bubbleActs({ who: meta.who, receipt: meta.receipt, pend: !!meta.pend, guest: st.guest, detailOff: st.detailOff, wide, sel: !!selTx })) {
    const lock = k === "recall" && recallLock(meta.receipt, meta.ts, nowSec()); // grayed out, tapping only shows a hint; uses the 2-minute window instead
    const bt = bmButton(BM_LABEL[k], k === "recall" ? (lock ? "bm-warn bm-off" : "bm-warn") : "", () => (lock ? toast(recallLockToast()) : bubbleAct(k, el, k === "copysel" ? selTx : text, meta)), BM_ICONS[k === "copysel" ? "copy" : k]);
    if (lock) bt.setAttribute("aria-disabled", "true");
    row.append(bt);
  }
  openBubblePop(el, row);
}
function bubbleAct(k, el, text, meta) {
  if (k === "copy" || k === "copysel") copyText(text);
  else if (k === "select") openSelectText(text);
  else if (k === "quote") {
    setQuote(quoteHead(meta.name, text));
    $("#reply").focus(); // focus synchronously in the same click: iOS only honors focus inside a user gesture, so the keyboard can appear
  } else if (k === "forward") openForward(text);
  else if (k === "recall") {
    const s = st.byId.get(st.detailId);
    if (recallAsk(meta.receipt, s && s.status, st.guest)) confirmRecall(el, meta, RECALL_ASK); // this will interrupt its current turn, ask first
    else doRecall(meta);
  }
}

// phone "select text": a fullscreen sub-page (reusing #fs) holding only this message's plain text, pick a range with the system handles; a "Copy all" button at the bottom
function openSelectText(text) {
  openFs("seltx", t("sel.title"));
  $("#fs-x").onclick = closeFs;
  const pg = h("div", "sel-page");
  pg.append(h("div", "sel-tx", text));
  const bar = h("div", "sel-bar");
  const b = h("button", "sel-copy", t("sel.copyAll"));
  b.type = "button";
  b.onclick = () => copyText(text);
  bar.append(b);
  pg.append(bar);
  $("#fs-body").replaceChildren(pg);
}

// attachment: text/Markdown reader page (reusing #fs). First shows "Loading...", and on return compares FS.kind with this call's mark; if it was closed or the page changed, don't write back
function openReader(f, sid) {
  openFs("fread", attName(f) || t("c.file"));
  $("#fs-x").onclick = closeFs;
  const body = $("#fs-body");
  const tag = (FS.sig = "fread:" + Math.random().toString(36).slice(2));
  const alive = () => FS.kind === "fread" && FS.sig === tag;
  const note = (msg) => { const d = h("div", "at-note", msg); body.replaceChildren(d); };
  note(t("at.loading"));
  // fetch failure and render failure are handled separately (one .catch must not swallow everything and always write "file no longer exists"): can't fetch -> by status code say "file no longer exists" / "load failed"; fetched but Markdown can't render -> fall back to plain text + report
  fetch(fileUrl(f, sid, "full"), { credentials: "same-origin" })
    .then(async (res) => {
      if (!res.ok) return { fail: fileFailKey(res.status) };
      const text = await res.text();
      return { text, cut: res.headers.get("X-Truncated") === "1" };
    }, () => ({ fail: "c.loadFail" })) // network down
    .then(({ fail, text, cut }) => {
      if (!alive()) return;
      if (fail) { note(t(fail)); return; }
      const wrap = h("div", "at-read");
      if (cut) wrap.append(h("div", "at-note at-cut", t("at.cut")));
      let md = null;
      if (f.kind === "md") {
        try {
          md = h("div", "at-md");
          mdBlocks(md, parseMarkdown(text));
        } catch (e) { md = null; diagErr("reader.md", e); }
      }
      wrap.append(md || h("pre", "at-pre", text));
      body.replaceChildren(wrap);
    })
    .catch((e) => { diagErr("reader", e); if (alive()) note(t("c.loadFail")); });
}

// attachment: web page. The sandbox gives only allow-scripts (no same-origin), so scripts in the page can't reach the dashboard's login state; the title bar has no room for buttons, so the button goes in a thin bar above the iframe
function openHtml(f, sid) {
  openFs("fhtml", attName(f) || t("c.webpage"));
  $("#fs-x").onclick = closeFs;
  const url = fileUrl(f, sid, "full");
  const bar = h("div", "at-bar");
  const nb = h("button", "at-newtab", t("at.newTab"));
  nb.type = "button";
  nb.onclick = () => window.open(url, "_blank", "noopener");
  if (isDesktopPointer()) bar.append(nb); // a view newly opened in the phone home-screen app has no login state and goes black, so only desktop keeps this button
  const fr = h("iframe", "at-frame");
  fr.setAttribute("sandbox", "allow-scripts");
  fr.src = url;
  const wrap = h("div", "at-htmlwrap");
  if (isDesktopPointer()) wrap.append(bar, fr); else wrap.append(fr); // no empty bar on phones
  $("#fs-body").replaceChildren(wrap);
}

// ---------- attachments in bubbles (thumbnail grid / file cards) ----------
// Structure (after the bubble body, a sibling node in the column): <div class="at-wrap at-single|at-grid|at-cards" data-cols>
//   image <button class="at-img"><img loading="lazy" decoding="async" src=thumb></button>
//   file <button class="at-card" data-kind><i class="at-ic"></i><b>name</b><small>size</small></button>
//   missing <div class="at-card at-gone">(missing-file text)</div>; with `more`, the last cell is overlaid with +N
// The render cache uses cloneNode (listeners aren't carried over), so open / broken image / load-complete all go through a delegated listener on #list (bindAttach);
// file info is in data-f (JSON), session id in data-sid. All via createElement/textContent, no innerHTML concatenation
const atCache = new Map();
let atUsed = new Set();
// broken-image record: attachment (path/ref/tok + version v) -> time of failure. After the first failure retry on the next redraw, afterwards retry the same attachment at most once per 30 seconds
// (rules in logic.js atBrokenNext / atRetryDue); delete the record on successful load. Keep at most AT_BROKEN_CAP entries
const atBroken = new Map();
const AT_BROKEN_CAP = 500;
const atBkey = (f) => (f.path || f.ref || f.tok || "") + "|" + (f.v || "");
let atSeq = 0; // each attachment block gets a number (data-ak, carried by clones) used to find it on a broken image and delete its cache key
function atFilesOf(it) {
  return it && Array.isArray(it.files) && (it.files.length || Number(it.more) > 0) ? it.files : null;
}
// when a pending bubble leaves (replaced by the real message on success / removed after failure), release its own local preview URLs
function pendFree(p) {
  for (const f of (p && p.files) || []) if (f.local) { URL.revokeObjectURL(f.local); f.local = ""; }
}
// ---------- no flicker when sending images: the pending bubble's local previews are "transferred" to the transcript entry ----------
// When the record arrives and the pending bubble leaves, creating a new <img> from the server URL would re-request and re-decode and flicker; the queued record has only "[Image #N]" and no files,
// so the image would disappear first and reappear once read (the official row carries files). So: when the pending bubble leaves, hand its attachment block (p.atw) with the blob previews to the n0-th user entry in the transcript (carryTarget);
// if that entry has no files yet (queued) hang the whole block under it as is; when the entry with files arrives (carryPlan recognizes that the queued one was replaced by the official row), move these <img> nodes in image order
// into the newly built attachment block (atTake); src stays the local blob and the server thumbnail is not requested. The blob follows that block's cache entry: released only when atCache deletes the key (atEvict)
let atTake = null; // when atBuild creates images it first uses these ready-made <img> nodes (in image order)
const carries = new Map(); // session id -> [{ wrap, imgs, urls, n, key, txt, ts, lost }]
const CARRY_LOST_MS = 30000; // if the entry it hangs on isn't found for this long (recalled / transcript changed): let go
function atEvict(k) {
  const n = atCache.get(k);
  if (n && n._blobs) for (const u of n._blobs) URL.revokeObjectURL(u);
  atCache.delete(k);
}
function carryFree(c) {
  for (const u of c.urls) URL.revokeObjectURL(u);
}
function carryFrom(p, items, sid) {
  const w = p && p.atw;
  if (!w || !sid) return;
  const imgs = [...w.querySelectorAll(".at-img img")];
  const urls = (p.files || []).filter((f) => f.local).map((f) => f.local);
  if (!imgs.length || imgs.length !== urls.length) return;
  const i = carryTarget(items, p.n0, imgs.length);
  if (i < 0) return;
  for (const f of p.files) f.local = ""; // transferred: pendFree no longer releases
  const it = items[i];
  const list = carries.get(sid) || [];
  list.push({ wrap: w, imgs, urls, n: imgs.length, key: carryKey(it), txt: carryText(it), ts: it.ts, lost: 0 });
  carries.set(sid, list);
}
// this round: item -> the transfer on it (Map); ones left by other sessions and not found for too long are let go
function carryMap(items, sid) {
  const m = new Map();
  for (const [k, l] of carries) if (k !== sid) { for (const c of l) carryFree(c); carries.delete(k); }
  const list = carries.get(sid);
  if (!list) return m;
  const plan = carryPlan(list, items);
  const now = Date.now();
  const keep = [];
  list.forEach((c, k) => {
    const it = plan[k] >= 0 ? items[plan[k]] : null;
    if (it) { Object.assign(c, { key: carryKey(it), txt: carryText(it), ts: it.ts, lost: 0 }); m.set(it, c); keep.push(c); }
    else if (!c.lost || now - c.lost < CARRY_LOST_MS) { c.lost = c.lost || now; keep.push(c); }
    else carryFree(c);
  });
  if (keep.length) carries.set(sid, keep); else carries.delete(sid);
  return m;
}
// attachment block of my entry in the transcript: with a transfer and a matching count = build from the transferred <img> (afterwards the block goes into the cache and owns the blob); no files yet = hang the transferred block as is
function userAt(files, more, sid, cy) {
  const n = files ? files.filter((f) => f.kind === "image").length : 0;
  if (!cy) return atNode(files, more, sid);
  if (!files || n !== cy.n) {
    if (!files) return cy.wrap;
    const fr = document.createDocumentFragment();
    fr.append(atNode(files, more, sid), cy.wrap);
    return fr;
  }
  const key = atKey(files, more, sid, "");
  const old = atCache.get(key);
  if (old && !old.contains(cy.imgs[0])) atEvict(key);
  atTake = cy.imgs.slice();
  let node;
  try { node = atNode(files, more, sid); } finally { atTake = null; }
  const cached = atCache.get(key);
  if (cached) cached._blobs = (cached._blobs || []).concat(cy.urls); else carryFree(cy);
  const list = carries.get(st.detailId) || [];
  const rest = list.filter((c) => c !== cy);
  if (rest.length) carries.set(st.detailId, rest); else carries.delete(st.detailId);
  return node;
}
function atParse(b) {
  try { return JSON.parse(b.dataset.f || "{}"); } catch (e) { return {}; }
}
function atTag(b, f, sid) {
  if (f.lo) return; // local preview while sending: no server URL yet, can't be opened or long-pressed
  b.dataset.fkey = f.path || f.ref || f.tok || "";
  b.dataset.f = JSON.stringify(f);
  b.dataset.sid = sid || "";
}
function atImg(f, sid, cls) {
  const b = h("button", "at-img at-loading" + (cls ? " " + cls : ""));
  b.type = "button";
  atTag(b, f, sid);
  // a transferred <img> (the local preview from the pending bubble) is moved in as is - no new node, no src change, no re-request and no flicker
  const kept = !f.lo && atTake && atTake.length ? atTake.shift() : null;
  const im = kept || h("img");
  if (!kept) {
    im.setAttribute("loading", "lazy");
    im.setAttribute("decoding", "async");
  }
  im.alt = attName(f) || t("c.image");
  im.draggable = false;
  // attach onload/onerror directly on the original node (still caught if it finishes loading / errors while in a DocumentFragment); cloned cache nodes rely on bindAttach's capture listener
  im.onload = () => { b.classList.remove("at-loading"); atFit(b, im); atLoaded(b); };
  im.onerror = () => atGone(b); // broken image -> .at-gone (missing-file card)
  if (!kept) im.src = f.lo ? f.local || "" : fileUrl(f, sid, "thumb");
  else if (im.complete && im.naturalWidth) { b.classList.remove("at-loading"); b._fit = im; } // already loaded: load won't fire again, so set the frame after atBuild places it
  b.append(im);
  return b;
}
function atCard(f, sid) {
  const b = h("button", "at-card");
  b.type = "button";
  b.dataset.kind = f.kind || "";
  atTag(b, f, sid);
  const nm = attName(f);
  const m = /\.([A-Za-z0-9]{1,5})$/.exec(nm);
  const sz = f.size == null ? NaN : Number(f.size);
  const sub = [KIND_LABEL[f.kind] || (f.kind === "image" ? t("c.image") : ""), Number.isFinite(sz) && sz >= 0 ? fmtSize(sz) : ""].filter(Boolean).join(" · ");
  b.append(h("i", "at-ic", m ? m[1].toUpperCase() : t("c.file")), h("b", null, nm || t("c.file")));
  if (sub) b.append(h("small", null, sub));
  b.append(h("span", "at-go", "›"));
  return b;
}
// file-name tag in the body (inline button). data-f / data-sid same as attachment cards; open, long press and right-click all go through the same delegated listener
const CHIP_IMG_SVG = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><rect x="2" y="3" width="12" height="10" rx="1.8"/><circle cx="5.8" cy="6.6" r="1.2" fill="currentColor" stroke="none"/><path d="M3 12l3.6-3.4 2.4 2.2 1.8-1.6L13.5 12"/></svg>';
const CHIP_DOC_SVG = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><path d="M4 1.8h5.2L12.5 5v9.2H4z"/><path d="M9 2v3.3h3.3M6 8.5h4.5M6 11h4.5" stroke-linecap="round"/></svg>';
function atChip(f, sid) {
  const b = h("button", "at-chip");
  b.type = "button";
  b.dataset.kind = f.kind || "";
  atTag(b, f, sid);
  const ic = h("i", "at-chip-ic");
  ic.append(svgEl(f.kind === "image" ? CHIP_IMG_SVG : CHIP_DOC_SVG)); // hard-coded constant
  b.append(ic, h("span", "at-chip-nm", attName(f) || t("c.file")));
  b.title = f.path || "";
  return b;
}
// single image loaded: set the frame by the original aspect ratio (max 260 high, 68vw wide, see singleFit in logic.js); only .at-single, the grid stays square-cropped
function atFit(b, im) {
  const w = b.parentNode;
  if (!w || !w.classList || !w.classList.contains("at-single") || w.classList.contains("at-tool")) return;
  const fit = singleFit(im.naturalWidth, im.naturalHeight);
  if (!fit) return;
  b.style.aspectRatio = String(fit.ratio);
  b.style.height = "";
  b.style.width = fit.width;
}
function atLoaded(b) {
  if (atBroken.size && b.dataset.f) atBroken.delete(atBkey(atParse(b)));
}
// one cell of the grid / single image: if it broke recently and the retry time hasn't come, draw the missing-file card directly (no img, so no request is made); once the time has come this build is the retry
function atCell(f, sid) {
  if (atTake && atTake.length && !f.lo) return atImg(f, sid); // transferred image: use directly (it is already displayed)
  const tb = f.lo ? undefined : atBroken.get(atBkey(f));
  if (tb !== undefined) {
    const now = Date.now();
    if (!atRetryDue(tb, now)) {
      const nm = attName(f);
      const g = h("div", "at-card at-gone", nm ? t("at.goneName", { name: nm }) : t("c.fileGone"));
      g.dataset.fkey = f.path || f.ref || f.tok || "";
      return g;
    }
    atBroken.set(atBkey(f), now); // this redraw is the retry: no further retry within 30 seconds
  }
  return atImg(f, sid);
}
// title: the tool entry's "opened a file" mini card, always drawn as a file card
function atBuild(files, more, sid, title) {
  const plan = attachPlan(files);
  const mode = title ? "cards" : plan.mode === "none" ? "cards" : plan.mode;
  const w = h("div", "at-wrap at-" + mode + (title ? " at-tool" : ""));
  w.dataset.cols = String(plan.cols);
  w.dataset.ak = String(++atSeq);
  if (title) w.append(h("div", "at-tt", title));
  const imgs = title ? [] : plan.imgs;
  const cells = imgs.map((f) => {
    const b = atCell(f, sid);
    if (mode === "single" && b.classList.contains("at-img")) { // single image: with width and height set the height by ratio (<=260), otherwise a 4:3 placeholder, so space is reserved and nothing shifts after load
      const bx = singleBox(Number(f.w), Number(f.h));
      const mw = "min(100%, " + Math.round(bx.wPct * 100) + "vw)";
      b.style.maxWidth = mw;
      b.style.aspectRatio = String(bx.ratio);
      if (bx.h) b.style.height = bx.h + "px";
      else b.style.width = "min(" + Math.round(bx.wPct * 100) + "vw, " + Math.round(260 * bx.ratio) + "px)"; // no percentages: in a shrink-wrapped container a percentage width collapses first and then jumps
    }
    w.append(b);
    if (b._fit) { atFit(b, b._fit); b._fit = null; }
    return b;
  });
  for (const f of title ? files : plan.cards) w.append(atCard(f, sid));
  const n = Number(more) || 0;
  if (n > 0) {
    if (cells.length) cells[cells.length - 1].append(h("span", "at-more", "+" + n));
    else w.append(h("div", "at-card at-morec", t("at.moreN", { n })));
  }
  return w;
}
const atKey = (files, more, sid, title) => JSON.stringify([sid || "", title || "", Number(more) || 0, files]);
function atNode(files, more, sid, title) {
  const key = atKey(files, more, sid, title);
  let node = atCache.get(key);
  if (node && atBroken.size && !title) { // a broken image whose retry time has come: drop the cache and rebuild (that cell is requested again on rebuild)
    const now = Date.now();
    if (files.some((f) => f.kind === "image" && !f.lo && atRetryDue(atBroken.get(atBkey(f)), now))) { atEvict(key); node = null; }
  }
  if (!node) {
    node = atBuild(files, more, sid, title);
    atCache.set(key, node);
    atUsed.add(key);
    return node;
  }
  if (atUsed.has(key)) return node.cloneNode(true);
  atUsed.add(key);
  return node;
}
// image can't be opened (expired/deleted): this cell becomes the missing-file card, the +N badge stays; record the failure and delete the cache key of the attachment block it belongs to,
// the next redraw decides by the atBroken rules whether to retry or draw the missing-file card directly (the cached node itself must not be changed: with the key unchanged it would never retry)
function atGone(b) {
  if (!b.parentNode || !b.classList.contains("at-img")) return; // already swapped (both listeners may fire)
  const f = atParse(b);
  if (b.dataset.f) {
    const bk = atBkey(f);
    const prev = atBroken.get(bk);
    atBroken.delete(bk); // reinsert: a Map keeps insertion order, delete the oldest when over the limit
    atBroken.set(bk, atBrokenNext(prev, Date.now()));
    while (atBroken.size > AT_BROKEN_CAP) atBroken.delete(atBroken.keys().next().value);
  }
  const wrap = b.closest(".at-wrap");
  const ak = wrap && wrap.dataset.ak;
  if (ak) for (const [k, n] of atCache) if (n.dataset.ak === ak) { atCache.delete(k); break; }
  const im = b.querySelector("img");
  const nm = attName(f) || (im && im.alt) || "";
  const g = h("div", "at-card at-gone", nm ? t("at.goneName", { name: nm }) : t("c.fileGone"));
  if (b.dataset.fkey) g.dataset.fkey = b.dataset.fkey; // still identifies which image it is after a redraw (an inline image isn't repeated at the end)
  if (b.classList.contains("at-inl")) g.classList.add("at-inl");
  const mo = b.querySelector(".at-more");
  if (mo) g.append(mo);
  b.replaceWith(g);
}
// open: image -> fullscreen viewer (images in the same message switch in display order); files by kind: PDF/Office go to the browser, text/Markdown reader page, web sandbox page
function atOpen(b) {
  const f = atParse(b);
  const sid = b.dataset.sid || "";
  if (f.kind === "image" && b.classList.contains("at-chip")) { // image tag = tap the thumbnail at the bottom (same left/right swipe); if that one is broken/not found, view only this one
    const col = b.closest(".cg-col");
    const fk = b.dataset.fkey;
    const twin = col && [...col.querySelectorAll(".at-img[data-f], .at-card[data-f][data-kind=image]")].find((x) => x.dataset.fkey === fk && !x.closest(".at-tool"));
    if (twin) atOpen(twin);
    else openViewer(imgRefsOf([f]), 0, sid);
    return;
  }
  if (f.kind === "image") {
    const tool = b.closest(".at-tool");
    const scope = tool || b.closest(".cg-col") || b.closest(".at-wrap") || b.parentNode;
    const list = [...scope.querySelectorAll(".at-img[data-f], .at-card[data-f][data-kind=image]")].filter((x) => x.closest(".at-tool") === tool);
    const imgs = imgRefsOf(list.map(atParse));
    openViewer(imgs, Math.max(0, list.indexOf(b)), sid);
    return;
  }
  const how = fileTapAction(f.kind, isDesktopPointer());
  if (how === "download") downloadFile(f, sid); // on desktop Word/Excel/PPT download directly
  // share: PDF / Office on phones -> fetch the file in-page + system share sheet (no new tab: it goes black in the home-screen app); the card breathes while fetching, to prevent repeated taps
  else if (how === "share") {
    if (b.classList.contains("at-loading")) return;
    b.classList.add("at-loading");
    shareFile(f, sid, toast).finally(() => b.classList.remove("at-loading"));
  }
  else if (how === "html") openHtml(f, sid);
  else openReader(f, sid);
}
function bindAttach() {
  const list = $("#list");
  // load / error don't bubble: catch them in the capture phase (cloned cache nodes are covered too)
  list.addEventListener("load", (e) => {
    const b = e.target && e.target.tagName === "IMG" && e.target.parentNode;
    if (b && b.classList && b.classList.contains("at-img")) { b.classList.remove("at-loading"); atFit(b, e.target); atLoaded(b); }
  }, true);
  list.addEventListener("error", (e) => {
    const b = e.target && e.target.tagName === "IMG" && e.target.parentNode;
    if (b && b.classList && b.classList.contains("at-img")) atGone(b); // .at-img → .at-gone
  }, true);
  list.addEventListener("click", (e) => {
    if (e.defaultPrevented) return; // the click after lifting from a long press has already been swallowed
    const b = e.target.closest && e.target.closest(".at-img[data-f], .at-card[data-f], .at-chip[data-f]"); // body tag
    if (!b) return;
    e.stopPropagation();
    atOpen(b);
  });
}
// menu for long-pressing an attachment: save/share, forward (path goes into the forward draft), copy path
// el: the attachment pressed (null = pressed in the blank area of an attachment-only bubble); bub: the attachment-only bubble it is in (.m.at-only), if present append quote / recall
function openAttMenu(el, bub) {
  bub = bub || (el && el.closest(".m.at-only"));
  const row = h("div", "bm-row");
  if (el) {
    const f = atParse(el);
    const sid = el.dataset.sid || "";
    for (const k of bubbleActs({ files: [f], guest: st.guest, desktop: isDesktopPointer() })) {
      row.append(bmButton(BM_LABEL[k], "", () => {
        if (k === "download") downloadFile(f, sid);
        else if (k === "share") shareFile(f, sid, toast); // viewer.js: fetch the original file -> system share sheet, falling back to an invisible download
        else if (k === "forward") openForward(f.path || "");
        else if (k === "copypath") copyText(f.path || "");
      }, BM_ICONS[k]));
    }
  }
  if (bub) {
    const meta = msgMeta.get(bub) || {};
    for (const k of bubbleActs({ who: meta.who, receipt: meta.receipt, pend: !!meta.pend, guest: st.guest, detailOff: st.detailOff })) {
      if (k !== "quote" && k !== "recall") continue;
      const lock = k === "recall" && recallLock(meta.receipt, meta.ts, nowSec());
      const bt = bmButton(BM_LABEL[k], k === "recall" ? (lock ? "bm-warn bm-off" : "bm-warn") : "", () => (lock ? toast(recallLockToast()) : bubbleAct(k, bub, t("chat.imgRaw"), meta)), BM_ICONS[k]);
      if (lock) bt.setAttribute("aria-disabled", "true");
      row.append(bt);
    }
  }
  if (!row.childNodes.length) return;
  openBubblePop(el || bub, row);
}
// Read receipts: small clock = sending; sent / delivered bright yellow single check = sent, not read (including queued); read white 60% double check = read;
// failed red ! = could not be sent, drawn outside the bubble's left edge, vertically centered (tap it for "resend / delete"); in an attachment-only bubble the checks are drawn on a dark rounded backing at the image's bottom-right
const RC_CHECK1 = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>';
const RC_ICONS = { // hard-coded constant
  clock: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.6"/><path d="M8 4.9V8l2.1 1.4"/></svg>',
  failed: '<svg viewBox="0 0 16 16"><path d="M8 3.6v5.2" stroke="#fff" stroke-width="1.9" stroke-linecap="round"/><circle cx="8" cy="12" r="1.1" fill="#fff"/></svg>',
  sent: RC_CHECK1,
  delivered: RC_CHECK1,
  read: '<svg viewBox="0 0 20 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 8.5l3 3 6-7M8.5 11.5l.5.5 6-8"/></svg>',
};
const RC_LABEL = new Proxy({}, { get: (_, k) => tCode("rcl.", String(k), undefined) }); // receipt explanations are looked up by rcl.<receipt>
// drawn inside the blue bubble at the bottom-right: .rc-mk is a 22x12 inline placeholder at the end of the body (stays on the last line if it fits, otherwise wraps), and the icon .rc-ic is absolutely positioned at the bubble's bottom-right
function rcMark(rc, el) {
  const m = h("span", "rc-mk rc-" + rc);
  const ic = h("i", "rc-ic");
  ic.innerHTML = RC_ICONS[rc] || "";
  m.append(ic);
  m.setAttribute("aria-label", RC_LABEL[rc] || "");
  m.title = RC_LABEL[rc] || "";
  // all tappable: only a small 2-second text tooltip; recall goes only through the long-press menu; exception: undelivered (red !) opens a small menu next to the bubble, "resend / delete"
  if (RC_LABEL[rc]) {
    m.classList.add("rc-tap");
    m.setAttribute("role", "button");
    m.addEventListener("click", (e) => {
      e.stopPropagation();
      const meta = msgMeta.get(el) || {};
      if (rc === "failed") { failMenu(el, meta.pend); return; }
      rcTip(ic, rcTipText(rc));
    });
  }
  return m;
}
// pending bubble switches send stage: only swap that bottom-right icon (and the receipt in msgMeta), no full list redraw
function pendStage(pend, stage) {
  if (!pend || pend.failed) return;
  pend.stage = stage;
  pendMark(pend);
}
function pendMark(pend) {
  const el = pend && pend.el;
  if (!el || !el.isConnected) return;
  const rc = receiptOf({ pend: true, failed: pend.failed, stage: pend.stage });
  const meta = msgMeta.get(el);
  if (meta) meta.receipt = rc;
  el.classList.toggle("rc-fail", !!pend.failed);
  const old = el.querySelector(":scope > .rc-mk");
  const mk = rcMark(rc, el);
  if (old) old.replaceWith(mk); else el.append(mk);
}
// red ! for undelivered: small menu next to the bubble (same shell as the recall confirmation) - resend = queue it again as is into the send queue; delete = remove the bubble
function failMenu(el, pend) {
  if (!pend) return;
  const box = h("div", "bm-ask");
  box.append(h("div", "bm-q", t("rc.failed")));
  const row = h("div", "bm-row");
  row.append(bmButton(t("bm.resend"), "", () => resendPend(pend)), bmButton(t("bm.delete"), "bm-warn", () => dropFailed(pend)));
  box.append(row);
  openBubblePop(el, box, "bm-confirm");
  bmState.at = 0; // not opened by a long press, so no guard against accidental taps on finger lift
}
// receipt tooltip: a small toast-like label above the check mark that disappears after 2 seconds; only one at a time
let rcTipEl = null;
function rcTip(anchor, text) {
  if (rcTipEl) { clearTimeout(rcTipEl._t); rcTipEl.remove(); rcTipEl = null; }
  if (!text || !anchor) return;
  const tip = h("div", "jr-tip", text);
  document.body.append(tip);
  const r = anchor.getBoundingClientRect();
  tip.style.left = Math.round(Math.max(8 + tip.offsetWidth / 2, Math.min(innerWidth - 8 - tip.offsetWidth / 2, r.left + r.width / 2))) + "px";
  tip.style.top = Math.round(r.top - 6) + "px";
  tip._t = setTimeout(() => { tip.remove(); if (rcTipEl === tip) rcTipEl = null; }, 2000);
  rcTipEl = tip;
}
function dropFailed(pend) {
  const sid = st.detailId;
  if (!sid || !pend) return;
  const all = st.outgoing.get(sid) || [];
  const rest = all.filter((p) => p !== pend && (p.text !== pend.text || p.at !== pend.at));
  for (const p of all) if (!rest.includes(p)) pendFree(p); // release the local preview of the removed one
  for (const x of pend.items || []) if (x.url) URL.revokeObjectURL(x.url); // attachment entry: also release the preview of the original image in the attachment bar
  if (rest.length) st.outgoing.set(sid, rest); else st.outgoing.delete(sid);
  outboxSave();
  st.sig = null;
  const s = st.byId.get(sid);
  if (s) renderList(s, "keep");
}
// resend: move the bubble to the end, back to the clock, and queue it into the send queue as is (text or attachments; already uploaded attachments aren't uploaded again)
function resendPend(pend) {
  const sid = st.detailId;
  const s = st.byId.get(sid);
  if (!s || !pend || !pend.failed) return;
  const rest = (st.outgoing.get(sid) || []).filter((p) => p !== pend);
  pend.failed = false;
  pend.stage = "clock";
  pend.at = Date.now();
  pend.n0 = userCount(st.items) + rest.filter((p) => !p.failed).length;
  if (pend.items) pend.q = true; // attachment entry: not removed on "appeared in the transcript" until the upload finishes
  pend.done = false;
  st.outgoing.set(sid, rest.concat([pend]));
  outboxSave();
  if (pend.items) queueTray(s, pend); else queueText(s, pend); // attachment entry: queue first (fix the "queued" label) then draw
  appendPend(s, pend);
}
// tap on the status mark: ask "Recall?" next to the bubble; if ask is given, replace the question and confirm button (confirmation to interrupt for read + busy)
function confirmRecall(el, meta, ask) {
  const box = h("div", "bm-ask");
  box.append(h("div", "bm-q", ask ? ask.q : t("recall.ask"))); // state the status in the confirmation box
  const row = h("div", "bm-row");
  row.append(bmButton(t("c.cancel"), "bm-cancel", () => {}), bmButton(ask ? ask.ok : t("bm.recall"), "bm-warn", () => doRecall(meta)));
  box.append(row);
  openBubblePop(el, box, "bm-confirm");
  bmState.at = 0; // not opened by a long press, so no guard against accidental taps on finger lift
}
// Recall: the helper presses Up in the terminal to pull the queued message back into the input box, clears it, and sends the rest back to the queue as is (does not interrupt the running turn).
// On success the original text returns to the phone input box, and that entry in the transcript becomes "you recalled a message"
// 2-minute window. For read ones the server decides: busy and last = press Esc to interrupt (interrupted); finished (answered) /
// more messages behind (processing) = no key is sent. In these three cases that entry in the transcript doesn't become "recalled"; the original text is just put back into the input box
async function doRecall(meta) {
  const s = st.byId.get(st.detailId);
  if (!s || !meta || !meta.raw) return;
  if (recallLock(meta.receipt, meta.ts, nowSec())) { toast(recallLockToast()); return; } // 2 minutes passed while the confirmation box was open
  toast(t("recall.going"), 6000);
  let r;
  try {
    r = await runRequest(sessionPath(s.id, "send"), { recall: meta.raw });
  } catch (e) {
    if (e.message !== "auth") { diagErr("doRecall", e); toast(t("c.opFail")); } // if it isn't login expiry don't pretend all is well
    return; // login expired, redirected
  }
  if (r.status !== "done") {
    toast(recallFailText(r.error), 4000);
    pollDetail();
    return;
  }
  if (st.detailId === s.id) putBack(st.guest ? stripGuestTag(meta.raw) : meta.raw); // a guest's original text carries the prefix, strip it before putting it back
  toast(recallDoneText(r.mode, st.guest), r.mode ? 3500 : undefined);
  pollDetail();
}
// recall / re-edit: the original text goes back to the input box (a quote reply's quote goes back to the quote strip); if the box already has text, append after it
function putBack(raw) {
  const qd = parseQuoted(raw);
  const back = qd ? qd.body : String(raw || "");
  const ta = $("#reply");
  ta.value = ta.value ? ta.value + " " + back : back;
  if (qd && !st.quote) setQuote(qd.quote);
  if (st.detailId) st.drafts.set(st.detailId, ta.value);
  autosizeReply();
}
// recalled: one centered gray line (mine can be "re-edited")
function rcRecalledLine(it, who) {
  const d = h("div", "rc-recalled");
  d.append(document.createTextNode(who === "me" ? t("recall.mine") : t("recall.theirs", { name: who === "guest" ? guestProfileView(st.guestProfile).name : t("recall.other") })));
  if (who === "me" && !st.detailOff) {
    const b = h("button", "rc-redo", t("recall.redo"));
    b.type = "button";
    b.addEventListener("click", (e) => {
      e.stopPropagation();
      putBack(st.guest ? stripGuestTag(it.text) : it.text);
      $("#reply").focus();
    });
    d.append(b);
  }
  return d;
}

// Forward: a forward card (search on top, avatar + name + small zone label, tap to select). Selecting does not send -
// it appends "[forwarded from this session name] original text" to the target session's draft and jumps to the target chat page, where the input box is pre-filled with the cursor at the end, and the person composes it before sending
function openForward(text) {
  const cur = st.byId.get(st.detailId);
  const from = cur ? cur.name : "";
  const body = forwardText(from, text);
  const box = h("div", "as-group fwd-card");
  const head = h("div", "fwd-hd");
  head.append(h("div", "fwd-ttl", t("fwd.title")));
  const inp = h("input", "fwd-q");
  inp.type = "search";
  inp.placeholder = t("c.search");
  inp.setAttribute("enterkeyhint", "search");
  head.append(inp);
  const list = h("div", "fwd-list");
  box.append(head, list);
  const fill = () => {
    const all = forwardTargets((st.raw && st.raw.sessions) || [], st.detailId, inp.value, (st.snap && st.snap.zones) || []);
    if (!all.length) { list.replaceChildren(h("div", "fwd-empty", inp.value.trim() ? t("fwd.noMatch") : t("fwd.none"))); return; }
    list.replaceChildren(...all.map((x) => {
      const s = st.byId.get(x.id) || x;
      const b = h("button", "fwd-it");
      b.type = "button";
      const av = h("div", "fwd-av");
      if (avatarPick(s, petName(s), st.petsKnown).kind !== "ini") {
        const pet = h("div", "pet");
        setPet(pet, s);
        av.append(pet);
      } else {
        av.classList.add("fwd-ini");
        av.textContent = initials(x.plate || x.name);
      }
      const zn = h("span", "fwd-zn", x.zoneName);
      zn.style.setProperty("--zc", x.zoneColor);
      const nm = h("span", "fwd-nm", x.plate || x.name);
      b.append(av, nm, zn);
      b.onclick = () => fwdPick(x.id, body);
      return b;
    }));
  };
  inp.oninput = fill;
  fill();
  const cg = h("div", "as-group");
  const cancel = h("button", "as-btn cancel", t("c.cancel"));
  cancel.type = "button";
  cancel.onclick = closeSheet;
  cg.append(cancel);
  openSheet([box, cg], false);
}
// on select: append to the target session's draft (an existing draft isn't overwritten, appended after a line break) -> jump there; focus synchronously inside the click so iOS shows the keyboard
function fwdPick(id, body) {
  closeSheet();
  st.drafts.set(id, draftMerge(st.drafts.get(id), body));
  openDetail(id, undefined, "forward");
  if (st.detailId !== id) return; // the session is gone / a just-finished swipe-back swallowed it
  const ta = $("#reply");
  ta.value = st.drafts.get(id) || "";
  autosizeReply();
  try { ta.focus({ preventScroll: true }); } catch (e) { ta.focus(); }
  const n = ta.value.length;
  ta.setSelectionRange(n, n);
  ta.scrollTop = ta.scrollHeight;
}
function bindBubblePress() {
  const list = $("#list");
  let p = null;
  const cancel = () => { if (p && !p.fired) { clearTimeout(p.t); p = null; } };
  const pick = (t) => {
    if (t.closest(".md-cp") || t.closest(".rc-mk")) return null; // code-block copy button, read-state mark: don't count as a long press on the whole entry
    const at = t.closest(".at-img[data-f], .at-card[data-f], .at-chip[data-f]"); // long-press attachment -> attachment menu (save/share, forward, copy path); same for body tags
    if (at) return at;
    const el = t.closest(".m.me, .m.ai, .m.gst, .m.adm, .hb");
    if (!el || el.classList.contains("ph-bub") || el.classList.contains("up") || el.classList.contains("ag-flip")) return null; // the flip shell / back isn't body text
    return el;
  };
  list.addEventListener("pointerdown", (e) => {
    // clear the "pending swallowed click" left by the last long press once it expires (iOS often doesn't fire a click after a long press; a stale pending swallow would eat the next real tap in the chat area)
    if (p && p.fired && !pressSwallow(p, Date.now())) p = null;
    cancel();
    if (e.button === 2) return; // desktop right-click goes through contextmenu
    const el = pick(e.target);
    if (!el) return;
    const me = { el, x: e.clientX, y: e.clientY, fired: false, at: 0, t: 0, mv: e.pointerType === "mouse" ? 4 : 10 }; // mouse drag-selection beyond 4px cancels the long press
    me.t = setTimeout(() => {
      if (p !== me) return;
      me.fired = true;
      me.at = Date.now();
      if (navigator.vibrate) navigator.vibrate(10);
      openBubbleMenu(el);
    }, LONG_PRESS_MS);
    p = me;
  });
  list.addEventListener("pointermove", (e) => {
    if (p && !p.fired && Math.hypot(e.clientX - p.x, e.clientY - p.y) > p.mv) cancel();
  });
  for (const t of ["pointerup", "pointercancel", "pointerleave"]) list.addEventListener(t, cancel);
  $("#msgs").addEventListener("scroll", () => { cancel(); closeBubbleMenu(); }, { passive: true });
  // desktop right-click = long press
  list.addEventListener("contextmenu", (e) => {
    if (!e.target.closest(".m, .at-wrap")) return;
    e.preventDefault();
    const el = pick(e.target);
    if (el) openBubbleMenu(el);
  });
  // lifting after a long press opens the menu fires one click (it would expand a folded bubble); swallow only the one that follows immediately
  list.addEventListener("click", (e) => {
    if (pressSwallow(p, Date.now())) { e.stopPropagation(); e.preventDefault(); }
    if (p && p.fired) p = null;
  }, true);
  // click anywhere outside the menu, or window changes: close the menu
  document.addEventListener("pointerdown", (e) => {
    if (bmState && !bmState.pop.contains(e.target)) closeBubbleMenu();
  }, true);
  addEventListener("resize", closeBubbleMenu);
}

// ---------- wake ----------
// Tapping "Wake" sends at once: POST -> poll /api/requests/<rid> (every 0.3 s for the first 3 seconds, then every 1 s, at most 150 seconds).
// Returns { status: "done" } | { status: "failed", error, message? } | null (user has left); only login expiry throws.
async function runWake(sid, token) {
  return runJob("/api/offduty/" + encodeURIComponent(sid) + "/wake", () => token === st.dToken);
}
// shared by wake and sending off duty: POST to get requestId, then poll for the result; if alive() is false (user left) return null
async function runJob(url, alive, maxMs, timeoutErr) {
  const t0 = Date.now();
  let res;
  try {
    res = await post(url, null, FETCH_TIMEOUT_MS);
  } catch (e) {
    if (e.message === "auth") throw e;
    // a POST aborted by timeout may already have reached the server: don't call it a failure
    return { status: "failed", error: e.name === "AbortError" ? "unknown-status" : "network", message: e.name === "AbortError" ? "" : t("c.netDown") };
  }
  if (!res.ok) {
    let code = "";
    try { code = String((await res.json()).error || ""); } catch (e) { code = ""; }
    return { status: "failed", error: code || "http-" + res.status };
  }
  let rid = null;
  try { rid = (await res.json()).requestId; } catch (e) { rid = null; }
  if (!rid) return { status: "failed", error: "bad-response" };
  for (;;) {
    await sleep(offPollDelayMs(Date.now() - t0));
    if (!alive()) return null;
    let code = 0;
    let data = null;
    try {
      const r = await api("/api/requests/" + encodeURIComponent(rid), null, FETCH_TIMEOUT_MS);
      code = r.status;
      if (r.ok) data = await r.json();
    } catch (e) {
      if (e.message === "auth") throw e;
      code = 0; // network blip / timeout: leave it to nextWakeAction
    }
    const next = maxMs ? nextWakeAction(code, data, Date.now() - t0, maxMs, timeoutErr) : nextWakeAction(code, data, Date.now() - t0);
    if (next.status !== "pending") return next;
  }
}

async function wake() {
  const o = st.detailOff;
  if (!o || st.waking) return;
  const token = st.dToken;
  st.waking = true;
  const b = $("#btn-wake");
  const m = $("#wake-msg");
  m.hidden = true;
  b.disabled = true;
  b.classList.add("busy");
  b.replaceChildren(h("span", "spinner"), document.createTextNode(t("wake.going")));
  let r;
  try {
    r = await runWake(o.sid, token);
  } catch (e) {
    r = null; // login expired, redirected
    if (e.message !== "auth") diagErr("wake", e);
  }
  if (token !== st.dToken) return;
  if (!r) { resetWakeUI(); return; }
  if (r.status !== "done") {
    resetWakeUI();
    m.textContent = wakeFailText(r);
    m.hidden = false;
    return;
  }
  // success: wait until a session with the same name appears in the snapshot (up to 15 more seconds), then switch to its normal chat page
  b.replaceChildren(h("span", "spinner"), document.createTextNode(t("wake.entering")));
  const t0 = Date.now();
  let awake = null;
  for (;;) {
    await refresh();
    if (token !== st.dToken) return;
    awake = findAwake(st.snap, o.name);
    if (awake || Date.now() - t0 >= AWAKE_WAIT_MS) break;
    await sleep(1000);
    if (token !== st.dToken) return;
  }
  if (awake) {
    history.replaceState({ d: awake.id }, "", "#s/" + encodeURIComponent(awake.id));
    openDetail(awake.id, false, "wake");
  } else {
    resetWakeUI();
    m.textContent = t("wake.notYet");
    m.hidden = false;
  }
}

function sessionPath(id, what) {
  return "/api/sessions/" + encodeURIComponent(id) + "/" + what;
}

// when opening the chat page: restore the draft
function resetReplyUI(id) {
  const ta = $("#reply");
  ta.value = st.drafts.get(id) || "";
  autosizeReply();
}

// called on every snapshot: idempotent
function syncReplyUI(s) {
  // guest: can't send while the session sits at a question/approval menu (text with Enter would land on the menu), and the server rejects it too
  const hold = st.guest && s.status === "waiting";
  const claude = s.kind === "claude" && !hold;
  $("#composer").hidden = !claude;
  $("#no-reply").hidden = claude;
  // WorkBuddy error / aborted / paused: put the same status tag before "replies not supported"
  const wb = !hold && wbState(s) ? chatRow(s, [], nowSec()).tag.text + " " : "";
  setText($("#no-reply"), hold ? t("fail.session-waiting") : wb + t("fail.not-claude"));
  $("#btn-plus").hidden = !claude;
  if (!claude) closePlus();
  syncOrcaUI();
}
// Orca not running: a yellow line above the input area (messages queue and are typed in once it opens); wake on the off-duty page needs Orca to open a terminal, so the button is grayed out with an explanation
function syncOrcaUI() {
  const down = orcaDown(st.snap);
  const s = st.detailId && !st.detailOff ? st.byId.get(st.detailId) : null;
  const off = !!st.detailOff;
  const show = down && (off || (!!s && s.kind === "claude"));
  const hint = $("#orca-hint");
  hint.hidden = !show;
  if (show) setText(hint, off ? t("wake.orcaDown") : t("orca.downHint"));
  if (!st.waking) $("#btn-wake").disabled = off && down;
}

function autosizeReply() {
  const ta = $("#reply");
  if (isWide()) { ta.style.height = ""; $("#btn-send").disabled = !canSend(ta.value, st.tray.length); return; } // the desktop input area has a fixed height, handled by CSS
  ta.style.height = "auto";
  // can't measure the height while the chat page is hidden; leave it to the CSS default of one line
  if (ta.scrollHeight) ta.style.height = Math.min(ta.scrollHeight, REPLY_MAX_H) + "px";
  else ta.style.height = "";
  $("#btn-send").disabled = !canSend(ta.value, st.tray.length);
}

function sendText() {
  const s = st.byId.get(st.detailId);
  const input = cleanReplyText($("#reply").value);
  // while the previous message (or attachments, bubble answers) is still sending don't block this one - it is queued into sendChain and sent in order in the background; the send button doesn't spin and the input isn't locked, so you can keep sending
  if (!s || !input) return;
  // a guest can only send the slash commands the server allows (GUEST_SLASH_COMMANDS, default none); other slash commands aren't sent and show the "Mac only" hint, with the text left in the input box (the server also rejects them as slash-forbidden)
  if (st.guest && guestSlashBlocked(st.quote, input)) { diag("slash-blocked", { id: s.id }); toast(t("fail.slash-forbidden")); return; }
  const text = buildQuoteText(st.quote, input); // keep the keyboard open after sending so typing can continue (only used to draw the "sending" bubble; the real assembly happens on the server)
  // clear the input box as soon as it is pressed, without waiting for delivery; an undelivered bubble is marked red !, tap for "resend / delete"
  const sid = s.id;
  const quote = st.quote;
  const raw = $("#reply").value;
  const body = { text: input, enter: true };
  if (quote) body.quote = quote; // quote reply: "> name: original" + blank line + body is assembled by the server (line breaks rely on the helper's paste)
  preCleared.add(body);
  st.drafts.delete(sid);
  setQuote("");
  $("#reply").value = "";
  autosizeReply();
  // first draw this text into the chat, starting with the small clock
  const list0 = st.outgoing.get(sid) || [];
  // the server adds a prefix to a guest's text: the one drawn first carries it too, so it matches the transcript once it appears there and isn't duplicated
  const pend = { text: st.guest ? guestPendText(quote, input) : text, n0: userCount(st.items) + list0.filter((p) => !p.failed).length, at: Date.now(), stage: "clock", body, raw, quote };
  st.outgoing.set(sid, list0.concat([pend]));
  outboxSave();
  appendPend(s, pend);
  queueText(s, pend);
}
// text is queued into the send queue (shared by first send and "resend")
function queueText(s, pend) {
  const sid = s.id;
  const job = () => waitSendIdle().then(() => { st.sendErr = ""; return submitSend(st.byId.get(sid) || s, pend.body, null, null, "", null, pend); });
  sendQ++;
  sendChain = sendChain.then(job, job);
  sendChain.then((ok) => {
    sendQ--;
    if (ok) { pend.done = true; outboxSave(); return; } // delivered: the persisted copy is no longer needed
    // rejected by the server while sitting at a question/approval menu (at-menu) = nothing was sent: remove the bubble directly, show only the hint, and put the original text back into the input box (if the box is empty)
    const drop = dropOnFail(st.sendErr);
    if (!drop) { // undelivered: the bubble stays with a red ! at its bottom-right (tap for resend / delete), and the original text is not put back into the input box automatically
      pend.failed = true;
      outboxSave();
      pendMark(pend);
      if (st.detailId === sid) { st.sig = null; renderList(st.byId.get(sid) || s, "keep"); }
      return;
    }
    diag("send-at-menu", { id: sid, why: st.sendErr });
    const all = st.outgoing.get(sid) || [];
    const rest = all.filter((p) => p !== pend);
    if (rest.length) st.outgoing.set(sid, rest); else st.outgoing.delete(sid);
    outboxSave();
    if (st.detailId === sid) { st.sig = null; renderList(st.byId.get(sid) || s, "keep"); }
    if (st.detailId !== sid || $("#reply").value) return;
    $("#reply").value = pend.raw;
    st.drafts.set(sid, pend.raw);
    setQuote(pend.quote);
    autosizeReply();
  });
}
const preCleared = new WeakSet(); // for a send where the input box was cleared on press: don't clear again after delivery (the user may already be typing the next sentence)
let sendChain = Promise.resolve(true); // text/attachment sends are queued: one finishes before the next, order is kept
let sendQ = 0; // number of messages in the queue not yet sent (attachment bubbles use it to show "queued")
// wait for the bubble answer/approval to finish, at most REQ_MAX_MS
async function waitSendIdle() {
  const t0 = Date.now();
  while (st.sending && Date.now() - t0 < REQ_MAX_MS) await sleep(150);
}

// after delivery (no toast, the receipt becomes gray double check): clear the draft, show busy optimistically, and refresh chat and snapshot at 0.5/1.5/3/5 seconds
function afterSent(sid, body) {
  if (body.text != null && !preCleared.has(body)) {
    st.drafts.delete(sid);
    if (st.detailId === sid) {
      setQuote("");
      $("#reply").value = "";
      autosizeReply();
    }
  }
  const cur = st.byId.get(sid);
  if (st.raw && cur) {
    st.pending.set(sid, { at: Date.now(), baseGen: st.raw.generatedAt || 0, orig: (st.raw.sessions.find((x) => x.id === sid) || cur).status });
    applySnapshot(st.raw);
  }
  refresh();
  const token = st.dToken;
  for (const ms of AFTER_SENT_MS) {
    setTimeout(() => {
      if (token !== st.dToken) return;
      refresh();
      pollDetail();
    }, ms);
  }
}

// things the chat page can do (used by the lower half of the context panel): normal session: mark seen / refresh chat / go to Orca; guest and off-duty page: only refresh chat
function detailActs() {
  const refresh = { label: t("dm.refresh"), run: () => { if (!st.loading) loadPage(st.dToken, null); } };
  if (st.detailOff) return [refresh];
  const s = st.byId.get(st.detailId);
  if (!s || st.guest) return [refresh]; // refresh must work even when the session has vanished from the snapshot (e.g. a temporary claude -p process)
  return [{ label: t("dm.seen"), run: () => markSeen(s, true) }, refresh, { label: t("dm.orca"), run: goOrca }];
}

// when the iOS keyboard rises the layout viewport stays the same and only visualViewport shrinks: fit the chat page to the visible area so the reply bar sits above the keyboard
function bindViewport() {
  const vv = window.visualViewport;
  if (!vv) return;
  const d = $("#detail");
  const m = $("#msgs");
  let full = vv.height;
  const fit = () => {
    if (isWide()) { // desktop has no soft keyboard: a shorter window must not be taken as a keyboard rising
      full = vv.height;
      if (d.classList.contains("kb")) { d.classList.remove("kb"); d.style.height = ""; d.style.top = ""; }
      return;
    }
    // remember the screen's original maximum height; a clearly shorter one means the keyboard is up (on newer iOS innerHeight also changes when the keyboard rises, so it can't be compared)
    full = Math.max(full, vv.height);
    const kb = full - vv.height > 120;
    if (kb !== d.classList.contains("kb")) diag("kb", { on: kb, full, vvH: vv.height, vvTop: vv.offsetTop, innerH: innerHeight });
    d.classList.toggle("kb", kb);
    d.style.height = kb ? vv.height + "px" : "";
    d.style.top = kb ? vv.offsetTop + "px" : "";
    if (kb) d.scrollTop = 0; // when iOS focuses the input it scrolls the whole chat page up and the header gets pushed off screen
    if (st.pinBottomUntil > Date.now()) m.scrollTop = m.scrollHeight; // stay pinned to the last message throughout the keyboard rise
    if (st.revealUntil > Date.now()) reveal();
  };
  // input box inside a bubble (type your own...): keep it at the bottom of the chat area just above the keyboard throughout the keyboard rise, don't let it be moved away
  const reveal = () => {
    const a = listInput();
    if (!a) return;
    m.scrollTop += a.getBoundingClientRect().bottom - (m.getBoundingClientRect().bottom - 24);
  };
  m.addEventListener("focusin", () => {
    if (!listInput()) return;
    st.revealUntil = Date.now() + 1000;
    reveal();
    [100, 300, 600, 900].forEach((t) => setTimeout(() => { if (st.revealUntil > Date.now()) reveal(); }, t));
  });
  // if the user was already viewing the last few entries when tapping the input, stay pinned to the bottom for the next second (keyboard animation)
  $("#reply").addEventListener("focus", () => {
    if (m.scrollHeight - m.scrollTop - m.clientHeight < 160) {
      st.pinBottomUntil = Date.now() + 1000;
      m.scrollTop = m.scrollHeight;
      [100, 300, 600].forEach((t) => setTimeout(() => { if (st.pinBottomUntil > Date.now()) m.scrollTop = m.scrollHeight; }, t));
    }
  });
  vv.addEventListener("resize", fit);
  vv.addEventListener("scroll", fit);
  d.addEventListener("scroll", () => { if (d.scrollTop) d.scrollTop = 0; });
}

// returns the input box when typing in a bubble input, otherwise null
function listInput() {
  const a = document.activeElement;
  return a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA") && $("#msgs").contains(a) ? a : null;
}

// when the chat area gets shorter (input grows, keyboard rises), whatever was at the very bottom stays pinned, so the newest message isn't covered
// don't stick to the bottom while typing in a bubble input; reveal positions it
function bindStickToBottom() {
  const m = $("#msgs");
  let stick = true;
  m.addEventListener("scroll", () => { stick = m.scrollHeight - m.scrollTop - m.clientHeight < 40; }, { passive: true });
  if (!("ResizeObserver" in window)) return;
  new ResizeObserver(() => { if (stick && !listInput()) m.scrollTop = m.scrollHeight; }).observe(m);
}

function bindReply() {
  const ta = $("#reply");
  ta.addEventListener("input", () => {
    if (st.detailId) {
      if (ta.value) st.drafts.set(st.detailId, ta.value); else st.drafts.delete(st.detailId);
    }
    autosizeReply();
  });
  // Enter = send (a line break would be sent as a space anyway); Enter used to pick an IME candidate doesn't count
  ta.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.shiftKey || e.isComposing || e.keyCode === 229) return;
    e.preventDefault();
    onSend();
  });
  $("#btn-send").onclick = onSend;
  bindViewport();
  bindStickToBottom();
}

// ---------- gesture: swipe right from the chat page's left edge to go back ----------
function bindEdgeSwipe() {
  const d = $("#detail");
  let x0 = null;
  let y0 = 0;
  let dx = 0;
  let t0 = 0;
  let locked = false;
  d.addEventListener("touchstart", (e) => {
    const t = e.touches[0];
    if (t.clientX > 28) { x0 = null; return; }
    x0 = t.clientX; y0 = t.clientY; dx = 0; t0 = Date.now(); locked = false;
  }, { passive: true });
  d.addEventListener("touchmove", (e) => {
    if (x0 == null) return;
    const t = e.touches[0];
    dx = Math.max(0, t.clientX - x0);
    if (!locked) {
      if (Math.abs(t.clientY - y0) > 12 && Math.abs(t.clientY - y0) > dx) { x0 = null; return; }
      if (dx > 8) { locked = true; d.classList.add("drag"); document.body.classList.add("swiping"); }
    }
    if (locked) d.style.transform = "translateX(" + dx + "px)";
  }, { passive: true });
  d.addEventListener("touchend", (e) => {
    if (x0 == null || !locked) { x0 = null; return; }
    x0 = null;
    e.preventDefault(); // don't let lifting the finger turn into a click that lands on a home row
    d.classList.remove("drag");
    document.body.classList.remove("swiping");
    const fast = dx > 60 && Date.now() - t0 < 250;
    if ((dx > window.innerWidth * 0.33 || fast) && st.agentView) { // swipe right on the sub-agent page: back to the main chat; the chat page itself doesn't slide away
      d.style.transform = "";
      st.backAt = Date.now();
      goBack();
    } else if (dx > window.innerWidth * 0.33 || fast) {
      d.style.transform = "translateX(100%)";
      st.backAt = Date.now();
      goBack();
    } else {
      d.style.transform = "";
    }
  }, { passive: false });
}

// ---------- pull to refresh ----------
function bindPullToRefresh() {
  const ptr = $("#ptr");
  let y0 = null;
  let pull = 0;
  let busy = false;
  const show = (p) => {
    ptr.classList.remove("go");
    const k = Math.min(1, p / PULL_TRIGGER);
    ptr.style.opacity = String(k);
    ptr.style.transform = "translateY(" + (Math.min(p, 110) * 0.6 - 40) + "px) rotate(" + p * 4 + "deg) scale(" + (0.6 + 0.4 * k) + ")";
  };
  const hide = () => {
    ptr.classList.add("go");
    ptr.classList.remove("spin");
    ptr.style.opacity = "";
    ptr.style.transform = "";
  };
  addEventListener("touchstart", (e) => {
    y0 = null;
    if (busy || st.detailId || !$("#sheet-wrap").hidden || window.scrollY > 0) return;
    y0 = e.touches[0].clientY;
    pull = 0;
  }, { passive: true });
  addEventListener("touchmove", (e) => {
    if (y0 == null) return;
    const dy = e.touches[0].clientY - y0;
    if (dy <= 0 || window.scrollY > 0) { pull = 0; show(0); return; }
    pull = dy * 0.6;
    show(pull);
  }, { passive: true });
  addEventListener("touchend", async () => {
    if (y0 == null) return;
    y0 = null;
    if (pull < PULL_TRIGGER) { hide(); return; }
    busy = true;
    ptr.classList.add("go", "spin");
    ptr.style.opacity = "1";
    ptr.style.transform = "translateY(10px)";
    const t = Date.now();
    await refresh();
    setTimeout(() => { hide(); busy = false; }, Math.max(0, 500 - (Date.now() - t)));
  });
}

// ---------- foreground mini banner: iOS shows no web push while the app is in the foreground, so a banner slides down from the top here ----------
// Rules in bannerStep of logic.js: newly waiting for you / finished and unread (only user-initiated turns count), and not currently viewing that session;
// the first snapshot after just opening, just returning from the background, or after offline / stale data only records state and shows nothing. Several are queued and shown one by one, auto-collapse after about 4 seconds, and can be dismissed by swiping up.
const BANNER_SHOW_MS = 4000;
const BANNER_GAP_MS = 300;   // after one collapses, wait a moment before sliding down the next
const BN = { state: newBannerState(), queue: [], cur: null, timer: 0, gap: false, el: null, y0: null, dy: 0 };

function bannerEl() {
  if (BN.el) return BN.el;
  const wrap = h("div", "bn");
  wrap.setAttribute("role", "status");
  const btn = h("button", "bn-in");
  btn.type = "button";
  const av = makeAv();
  const tx = h("div", "bn-tx");
  const t = h("b", "bn-t");
  const b = h("span", "bn-b");
  tx.append(t, b);
  btn.append(av, tx);
  wrap.append(btn);
  wrap._p = { av, t, b };
  // swipe up to dismiss; without a swipe it is a tap -> open the chat page
  btn.addEventListener("touchstart", (e) => {
    BN.y0 = e.touches[0].clientY; BN.dy = 0;
    clearTimeout(BN.timer);
    wrap.classList.add("drag");
  }, { passive: true });
  btn.addEventListener("touchmove", (e) => {
    if (BN.y0 == null) return;
    BN.dy = e.touches[0].clientY - BN.y0;
    wrap.style.transform = BN.dy < 0 ? "translateY(" + BN.dy + "px)" : "";
  }, { passive: true });
  const end = () => {
    if (BN.y0 == null) return;
    BN.y0 = null;
    wrap.classList.remove("drag");
    wrap.style.transform = "";
    if (BN.dy < -24) hideBanner();
    else if (BN.cur) BN.timer = setTimeout(hideBanner, BANNER_SHOW_MS);
  };
  btn.addEventListener("touchend", end);
  btn.addEventListener("touchcancel", end);
  btn.addEventListener("click", () => {
    if (Math.abs(BN.dy) > 8 || !BN.cur) return;
    const id = BN.cur.id;
    hideBanner();
    openDetail(id, undefined, "banner");
  });
  document.body.append(wrap);
  BN.el = wrap;
  return wrap;
}
function showBanner(f, s) {
  const el = bannerEl();
  const p = el._p;
  const txt = bannerText(s, f.kind);
  fillAv(p.av, s, { color: zoneOf(s.zone).color, plate: plateOf(s) });
  setText(p.t, txt.title);
  setText(p.b, txt.body);
  BN.cur = f;
  BN.dy = 0;
  seenMark(f.id, f.kind); // a banner shown = delivered inside the app; the next snapshot request reports it to the server
  void el.offsetWidth;
  el.classList.add("show");
  clearTimeout(BN.timer);
  BN.timer = setTimeout(hideBanner, BANNER_SHOW_MS);
}
function hideBanner(now) {
  clearTimeout(BN.timer);
  if (!BN.cur) return;
  BN.cur = null;
  if (BN.el) BN.el.classList.remove("show");
  BN.gap = !now;
  if (!now) BN.timer = setTimeout(() => { BN.gap = false; nextBanner(); }, BANNER_GAP_MS + 300); // wait for the collapse animation (0.3 s) to finish
}
function nextBanner() {
  if (BN.cur || document.hidden) return;
  while (BN.queue.length) {
    const f = BN.queue.shift();
    const s = st.byId.get(f.id);
    if (!bannerStill(s, f.kind) || st.detailId === f.id) continue; // already handled / already tapped into while queued
    showBanner(f, s);
    return;
  }
}
function resetBanner() {
  BN.state = newBannerState();
  BN.queue = [];
  hideBanner(true);
  clearTimeout(BN.timer);
  BN.gap = false;
}
function runBanner(snap) {
  if (document.hidden || st.offline || snap.stale) { resetBanner(); return; } // afterwards the first good snapshot is used as the baseline again
  const viewing = st.detailId && !st.detailOff ? st.detailId : null;
  const r = bannerStep(BN.state, snap.sessions || [], Date.now(), viewing);
  BN.state = r.state;
  for (const x of r.seen) seenMark(x.id, x.kind); // currently viewing that session: no banner, but it counts as seen
  for (const f of r.fire) {
    if (BN.cur && BN.cur.id === f.id) continue;
    BN.queue = BN.queue.filter((q) => q.id !== f.id);
    BN.queue.push(f);
  }
  // if the one on display no longer holds (handled / tapped in and viewed), collapse it early
  if (BN.cur && (st.detailId === BN.cur.id || !bannerStill(st.byId.get(BN.cur.id), BN.cur.kind))) hideBanner();
  if (!BN.cur && !BN.gap) nextBanner();
}

// ---------- diagnostic log ----------
// Keyboard/scroll/swipe-back problems unique to the iOS home-screen version can't be reproduced on a desktop: after enabling "Me -> Diagnostic log", the device sends key values in batches to /api/diag,
// view them with tools/diag.sh. When off, no listeners are registered and diag() returns immediately.
const DIAG_KEY = "zbs.diag";
const DIAG_FLUSH_MS = 2000;
const DIAG_BATCH = 200;     // send immediately once this many entries are reached
const DIAG_MAX = 1000;      // keep at most this many in memory; drop the oldest if they can't be sent
const DIAG_GAP = 100;       // consecutive events of the same kind within 100 ms are recorded once (the last is kept)
const DIAG_BEACON = 150;    // sendBeacon has a 64KB limit, so send only the last this many entries
let D = null;               // when on: { sid, buf, ac, timer, thr, cnt, get, touchAt, scrollAt, rseq, ph, fig }

function diagOn() {
  if (st.guest) return false;
  try { return localStorage.getItem(DIAG_KEY) === "1"; } catch (e) { return false; }
}

function diag(k, data) {
  if (!D) return;
  D.buf.push({ t: Date.now(), k, ...data });
  diagCap(D.buf, DIAG_MAX);
  if (D.buf.length >= DIAG_BATCH) diagFlush();
}

// throttling per event kind: get is evaluated only when actually recording, and a catch-up record uses the get from the last call in the window (= the latest value at window end)
// gap: window in ms; tk: throttle key (defaults to the event name; fig is throttled separately like fig:rise but recorded under the same k);
// when add > 0 count occurrences, and attach cnt when one is written (how many were merged in the window)
// for timing: the first time the session turns waiting in the snapshot (wait-seen) and the first time the question/approval card is drawn (card-shown);
// bash tools/diag.sh last 500 | grep -E 'wait-seen|card-shown' to compute seconds. Clear the mark when no longer waiting so the next round counts afresh
function diagWaitSeen(oldById, snap) {
  if (!D) return;
  if (!D.cards) D.cards = new Set();
  for (const s of snap.sessions || []) {
    if (s.status !== "waiting") { D.cards.delete(s.id); continue; }
    const o = oldById.get(s.id);
    if (o && o.status !== "waiting") diag("wait-seen", { id: s.id, gen: snap.generatedAt, at: Date.now(), from: o.status });
  }
}
function diagCardShown(id, kind) {
  if (!D) return;
  if (!D.cards) D.cards = new Set();
  if (D.cards.has(id)) return;
  D.cards.add(id);
  diag("card-shown", { id, kind, at: Date.now() });
}
function diagThrottled(k, get, gap = DIAG_GAP, tk = k, add = 0) {
  if (!D) return;
  if (add) D.cnt.set(tk, (D.cnt.get(tk) || 0) + add);
  D.get.set(tk, get);
  const emit = () => {
    const data = { ...D.get.get(tk)() };
    if (add) { data.cnt = D.cnt.get(tk) || 1; D.cnt.delete(tk); }
    diag(k, data);
  };
  const r = throttleStep(D.thr.get(tk) || { last: -1e9, pending: false }, performance.now(), gap);
  D.thr.set(tk, r.s);
  if (r.act === "now") emit();
  else if (r.act === "later") {
    const mine = D;
    setTimeout(() => {
      if (D !== mine) return; // closed midway
      D.thr.set(tk, { last: performance.now(), pending: false });
      emit();
    }, r.delay);
  }
}

// ---- notification tap -> chat page path (transition / insert / scroll / placeholder / figures) ----
// the following are pure predicates (tests slice them from the source and run them); diagRender / diagFig / diagOpenFrom check D first and return immediately when off
const DIAG_MERGE_MS = 1000; // render / fig events within 1 second are merged into one (with cnt)

// counts as a "jump" only if #msgs scrollTop changed by more than 40px after the redraw and the user wasn't scrolling
function diagScrollJump(a, b, user) {
  if (user || Math.abs(b - a) <= 40) return null;
  const from = Math.round(a), to = Math.round(b);
  return { from, to, d: to - from };
}

// a touch / #msgs scroll within 200 ms counts as the user scrolling
function diagUserBusy(now, touchAt, scrollAt) {
  return now - touchAt < 200 || now - scrollAt < 200;
}

// placeholder bubble: show appears / gone disappears (became a real reply or no longer busy)
function diagPhStep(prev, has) {
  return prev === has ? null : has ? "show" : "gone";
}

// figures: prev / cur are both Map<group key, { a: anchor id, ids: Map<tool id, state> }> (only groups whose anchor can be found in the DOM, same as figures.js)
function diagFigDiff(prev, cur) {
  const out = [];
  for (const [key, c] of cur) {
    const p = prev.get(key);
    if (p && p.a !== c.a) out.push({ ev: "reanchor", key, from: p.a, to: c.a });
    for (const [tu, state] of c.ids) if (!p || !p.ids.has(tu)) out.push({ ev: "rise", key, tu, state });
  }
  for (const [key, p] of prev) {
    const c = cur.get(key);
    for (const tu of p.ids.keys()) if (!c || !c.ids.has(tu)) out.push({ ev: "destroy", key, tu, why: c ? "gone" : "group-gone" });
  }
  return out;
}

// events of the same kind (ev) merge into one: take the data of the last one, cnt = count
function diagFold(evs) {
  const m = new Map();
  for (const e of evs) { const p = m.get(e.ev); m.set(e.ev, { ...e, cnt: (p ? p.cnt : 0) + 1 }); }
  return [...m.values()];
}

// called after renderList actually redraws: render (1-second merge), scroll-jump (checked at the redraw and again 300 ms later), ph
// t0 / h0 = scrollTop / scrollHeight before the redraw; ub = whether the user was scrolling in the 200 ms before the redraw
function diagRender(mode, t0, h0, away, added, ub) {
  if (!D) return;
  const msgs = $("#msgs"), list = $("#list");
  const id = st.detailId, items = st.items.length;
  const t1 = msgs.scrollTop, h1 = msgs.scrollHeight;
  const data = { id, mode, items, added, away, t0: Math.round(t0), h0, t1: Math.round(t1), h1, nc: st.newCount };
  diagThrottled("render", () => data, DIAG_MERGE_MS, "render", 1);
  const j = diagScrollJump(t0, t1, ub);
  if (j) diag("scroll-jump", { ...j, at: "render", mode, id });
  const has = !!list.querySelector(".ph-bub");
  const ev = diagPhStep(D.ph, has);
  D.ph = has;
  if (ev) diag("ph", { ev, id, items, added });
  // late jumps after a redraw (images growing taller, figure layer, iOS moving things itself): check again after 300 ms; not counted if another redraw happens or the user touches the screen meanwhile
  const mine = D, seq = ++D.rseq, t = performance.now();
  setTimeout(() => {
    if (D !== mine || D.rseq !== seq || st.detailId !== id || D.touchAt > t) return;
    const j2 = diagScrollJump(t1, msgs.scrollTop, false);
    if (j2) diag("scroll-jump", { ...j2, at: "late", mode, id });
  }, 300);
}

// called after reconcileFigures: compares with last time to get rise (newly appeared) / reanchor (anchor bubble changed) / destroy (gone from the plan).
// figures.js is untouched; this infers from outside by the same rule (find anchors via .m[data-fig] in the DOM); anchor id = ph (placeholder bubble) or m + its index among the .m in #list
// rise records "newly appeared"; among them old finished calls are drawn by figures.js straight as parked at the bottom (no entrance), tell them apart by state / instant
function diagFig(plan, instant) {
  if (!D) return;
  const list = $("#list");
  const ms = [...list.querySelectorAll(".m")];
  const anchors = new Map();
  for (const el of ms) if (el.dataset.fig) anchors.set(el.dataset.fig, el.classList.contains("ph-bub") ? "ph" : "m" + ms.indexOf(el));
  const cur = new Map();
  for (const e of plan || []) {
    const a = anchors.get(e.key);
    if (a == null) continue;
    cur.set(e.key, { a, ids: new Map(e.figs.map((f) => [f.id, f.state])) });
  }
  const evs = diagFigDiff(D.fig, cur);
  D.fig = cur;
  const id = st.detailId;
  for (const e of diagFold(evs)) {
    const { cnt, ...rest } = e;
    diagThrottled("fig", () => ({ ...rest, id, instant: !!instant }), DIAG_MERGE_MS, "fig:" + e.ev, cnt);
  }
}

// a jump to some session because of a notification / URL hash: record which page we were on
function diagOpenFrom(id, from) {
  if (!D) return;
  diag("open-from-notify", { id, from, page: st.detailId ? "detail" : "list", cur: st.detailId || null, tab: st.tab,
    fs: FS.kind || null, vis: document.visibilityState });
}

function diagEl(el) {
  if (!el) return null;
  if (el.nodeType !== 1) return el === document ? "document" : el === window ? "window" : "?";
  return diagDesc(el.tagName, el.id, el.getAttribute("class"), el.getAttribute("placeholder"));
}

function diagFlush(beacon) {
  if (!D || !D.buf.length) return;
  const events = beacon ? D.buf.slice(-DIAG_BEACON) : D.buf.slice();
  D.buf.length = 0;
  for (let i = 0; i < events.length; i += DIAG_BATCH) { // at most 200 entries per POST, to stay under the server's 256KB limit
    const body = JSON.stringify({ session: D.sid, events: events.slice(i, i + DIAG_BATCH) });
    if (beacon && navigator.sendBeacon) { navigator.sendBeacon("/api/diag", body); continue; }
    // drop it if it can't be sent, no retry, no piling up
    fetch("/api/diag", { method: "POST", credentials: "same-origin", keepalive: !!beacon,
      headers: { "Content-Type": "application/json" }, body }).catch(() => {});
  }
}

function diagStart() {
  if (D) return;
  D = { sid: Math.random().toString(36).slice(2, 10), buf: [], ac: new AbortController(), timer: 0, thr: new Map(),
    cnt: new Map(), get: new Map(), touchAt: -1e9, scrollAt: -1e9, rseq: 0, ph: false, fig: new Map() };
  const sig = D.ac.signal;
  const on = (t, type, fn, opt) => t.addEventListener(type, fn, { ...opt, signal: sig });
  const vv = window.visualViewport;
  const m = $("#msgs");
  const d = $("#detail");
  // a group of viewport-related values: visualViewport + innerHeight + page scroll + body classes (in-detail/covered/swiping...)
  const view = () => ({
    vvH: vv ? Math.round(vv.height) : null, vvTop: vv ? Math.round(vv.offsetTop) : null, vvPageTop: vv ? Math.round(vv.pageTop) : null,
    innerH: innerHeight, scrollY: Math.round(window.scrollY), body: document.body.className,
  });
  const pt = (e) => {
    const p = (e.changedTouches && e.changedTouches[0]) || e;
    return { x: Math.round(p.clientX), y: Math.round(p.clientY) };
  };
  // once at startup: environment info; the sw version is taken from the cache name zbs-shell-vNN
  const boot = {
    ua: navigator.userAgent, standalone: navigator.standalone === true,
    displayStandalone: matchMedia("(display-mode: standalone)").matches,
    innerW: innerWidth, innerH: innerHeight, screenW: screen.width, screenH: screen.height, dpr: devicePixelRatio,
    launch: location.hash || null, // on a cold start from a notification (openWindow) it is #s/<id>
    ...view(),
  };
  const gotSw = (sw) => diag("boot", { ...boot, sw });
  if (window.caches) caches.keys().then((ks) => gotSw((ks.find((x) => x.startsWith("zbs-shell-")) || "").slice(10) || null), () => gotSw(null));
  else gotSw(null);
  if (vv) {
    on(vv, "resize", () => diagThrottled("vv.resize", view));
    on(vv, "scroll", () => diagThrottled("vv.scroll", view));
  }
  on(document, "focusin", (e) => diag("focusin", { el: diagEl(e.target), ...view() }), { capture: true });
  on(document, "focusout", (e) => diag("focusout", { el: diagEl(e.target), to: diagEl(e.relatedTarget), ...view() }), { capture: true });
  on(document, "touchstart", (e) => { D.touchAt = performance.now(); diag("touchstart", { ...pt(e), n: e.touches.length, el: diagEl(e.target) }); }, { capture: true, passive: true });
  on(m, "touchmove", () => { D.touchAt = performance.now(); }, { passive: true });
  on(document, "touchend", (e) => diag("touchend", { ...pt(e), el: diagEl(e.target) }), { capture: true, passive: true });
  on(document, "click", (e) => diag("click", { ...pt(e), el: diagEl(e.target) }), { capture: true, passive: true });
  on(window, "scroll", () => diagThrottled("win.scroll", () => ({ scrollY: Math.round(window.scrollY) })), { passive: true });
  // chat page: #msgs is where the message list really scrolls; #detail itself shouldn't scroll (iOS scrolls it up on focus, and the code pulls it back to 0)
  on(m, "scroll", () => { D.scrollAt = performance.now(); diagThrottled("msgs.scroll", () => ({ top: Math.round(m.scrollTop), h: m.scrollHeight, ch: m.clientHeight })); }, { passive: true });
  on(d, "scroll", () => diagThrottled("detail.scroll", () => ({ top: Math.round(d.scrollTop) })), { passive: true });
  on(window, "popstate", (e) => diag("popstate", { state: e.state, hash: location.hash }));
  on(window, "pageshow", (e) => diag("pageshow", { persisted: e.persisted }));
  on(window, "pagehide", (e) => { diag("pagehide", { persisted: e.persisted }); diagFlush(true); });
  // the iOS home-screen app often fires only visibilitychange without pagehide when going to the background, so flush here too
  on(document, "visibilitychange", () => { diag("visibility", { state: document.visibilityState }); if (document.hidden) diagFlush(true); });
  on(window, "error", (e) => diag("error", { msg: String(e.message).slice(0, 300), src: e.filename, line: e.lineno, col: e.colno }));
  on(window, "unhandledrejection", (e) => diag("rejection", { reason: String(e.reason && (e.reason.stack || e.reason)).slice(0, 300) }));
  D.timer = setInterval(() => diagFlush(), DIAG_FLUSH_MS);
}

function diagStop() {
  if (!D) return;
  diag("diag-off", {});
  diagFlush();
  D.ac.abort(); // remove all listeners at once
  clearInterval(D.timer);
  D = null;
}

function toggleDiag() {
  const on = !diagOn();
  try { localStorage.setItem(DIAG_KEY, on ? "1" : "0"); } catch (e) { /* can't store: only effective this time */ }
  if (on) diagStart(); else diagStop();
  st.crSig.me = "";
  renderMe();
  toast(on ? t("diag.on") : t("diag.off"));
}

// ---------- startup ----------
// identify the account: if not admin enter guest mode (the guest account is named guest; the old API and an old name in old caches also count as guest). If unavailable (offline) use the last remembered one
// also decides the guest prefix (the tag of /api/auth/me, see pickGuestTag in logic.js) and the guest's read-state key name (store)
async function loadAccount() {
  let acc = null;
  let guests = [];
  let tag = null;
  let store = null;
  let slash = [];
  let old = null;
  try { old = JSON.parse(localStorage.getItem(ACCOUNT_KEY) || "null"); } catch (e) { old = null; }
  try {
    const res = await api("/api/auth/me", null, FETCH_TIMEOUT_MS);
    if (res.ok) {
      const me = await res.json();
      acc = me.account || me.user || "admin";
      st.bound = typeof me.session === "string" ? me.session : "";
      tag = pickGuestTag(me, old && old.tag, acc);
      store = typeof me.store === "string" ? me.store : acc;
      guests = Array.isArray(me.guests) ? me.guests.filter((g) => g && typeof g.account === "string") : [];
      slash = Array.isArray(me.slash) ? me.slash : []; // guest only: slash commands the server allows (GUEST_SLASH_COMMANDS)
      try { localStorage.setItem(ACCOUNT_KEY, JSON.stringify({ account: acc, session: st.bound, tag, store, guests, slash })); } catch (e) { /* doesn't matter */ }
    }
  } catch (e) {
    if (e.message === "auth") throw e;
  }
  if (!acc && old && old.account) {
    acc = old.account; st.bound = old.session || "";
    tag = pickGuestTag(null, old.tag, acc);
    store = old.store || acc;
    guests = Array.isArray(old.guests) ? old.guests : [];
    slash = Array.isArray(old.slash) ? old.slash : [];
  }
  st.account = acc || "";
  initAccountStores(st.account);
  setGuestTag(tag);
  st.guests = acc === "admin" ? guests : []; // a guest recognizes only their own prefix; the admin recognizes all guests' (multi-guest)
  setGuestTags(st.guests.map((g) => g.tag));
  setGuestSlashCommands(slash);
  if (/^[a-z0-9]{1,16}$/.test(String(store || ""))) guestSeenKey = "zbs." + store + "Seen";
  st.guest = !!acc && acc !== "admin";
  document.body.classList.toggle("guest", st.guest);
  errAccountReady();
}

// sign out: first unsubscribe this device's push subscription (so the next person to log in doesn't receive it), then clear the cookie and return to the login page
async function guestLogout() {
  try {
    if ("serviceWorker" in navigator) {
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      if (sub) await sub.unsubscribe();
    }
  } catch (e) { /* continue signing out even if unsubscribing fails */ }
  try { await post("/api/auth/logout", {}, FETCH_TIMEOUT_MS); } catch (e) { /* return to the login page anyway */ }
  clearAccountStores();
  try { localStorage.removeItem(ACCOUNT_KEY); localStorage.removeItem("zbs.pushLang"); } catch (e) { /* doesn't matter */ }
  try { if (window.caches) await caches.delete("zbs-data-v2"); } catch (e) { /* offline snapshot cache; fine if it can't be deleted */ }
  goLogin();
}

// ---------- init stages / null guards / shell version gate ----------
function initStep(name, fn) {
  try { fn(); } catch (e) {
    diag("init-error", { step: name, msg: String((e && e.message) || e).slice(0, 200) });
    diagErr("init." + name, e); // report even when the diagnostic log is off (diagErr has console.error)
  }
}
// bind onclick only if the element is found; an old shell (old index.html when the sw isn't upgraded) lacks the new elements and is skipped
function bindOn(sel, fn) {
  const el = $(sel);
  if (!el) { diag("init-missing", { sel }); return null; }
  el.onclick = fn;
  return el;
}
const SHELL_GATE_KEY = "zbs.shellReload";
// report this page's index.html shell version (<meta name="zbs-shell">) to the sw; the sw compares with VERSION and, on mismatch (shell-mismatch), reloads once
function shellCheck() {
  const sw = navigator.serviceWorker;
  if (!sw || !sw.controller) return; // on first install there is no controller: the page was fetched from the network anyway
  const meta = document.querySelector('meta[name="zbs-shell"]');
  const v = meta ? meta.getAttribute("content") || "" : "";
  sw.addEventListener("message", (e) => {
    const d = e.data;
    if (!d || (d.type !== "shell-ok" && d.type !== "shell-mismatch")) return;
    let gate = null;
    try { gate = sessionStorage.getItem(SHELL_GATE_KEY); } catch (e2) { gate = null; }
    const r = shellGate(d, gate);
    try { if (r.gate == null) sessionStorage.removeItem(SHELL_GATE_KEY); else sessionStorage.setItem(SHELL_GATE_KEY, r.gate); } catch (e2) { /* private mode */ }
    if (d.type !== "shell-mismatch") return;
    diag("shell-mismatch", { page: v || null, sw: d.v || null, reload: r.reload });
    if (!r.reload) return;
    diagFlush(true);
    // bypass the HTTP cache and fetch / once (the sw has already deleted the old cached shell), then reload the whole page
    fetch("/", { credentials: "same-origin", cache: "reload" }).catch(() => {}).finally(() => location.reload());
  });
  sw.controller.postMessage({ type: "shell", v: v });
}

async function init() {
  applyI18n(); // replace the static data-i18n text in index.html with the current language, and update <html lang> accordingly
  try { await loadAccount(); } catch (e) { return; } // not logged in: already redirected to the login page
  if (diagOn()) diagStart(); // start recording as early as possible so startup is visible too
  // init is split into independent small steps (an exception in one initStep is only logged to diag, and doesn't drag down later steps or the hash/notification entry);
  // #id bindings go through bindOn, skipped with an init-missing record when an old shell lacks the element
  initStep("profile", loadProfile); // my nickname and avatar (a guest fetches their own)
  initStep("pushLang", () => { syncPush().catch(() => { /* if it can't be filled in now, fill it in at the next launch */ }); }); // push language and device info are registered along with it
  initStep("edgeSwipe", bindEdgeSwipe);
  initStep("pull", bindPullToRefresh);
  initStep("splitDrag", initSplitDrag);
  // bottom tabs: remember the last one used (default "Messages" the first time); the contents of the home "..." menu moved to "Me"
  try {
    const saved = localStorage.getItem("zbs.tab");
    st.tab = st.guest ? guestTab(saved) : chatTab(saved);
  } catch (e) { st.tab = "msg"; }
  initStep("chat", bindChat);
  initStep("tab", applyTab);
  initStep("buttons", () => {
    bindOn(".sheet-backdrop", () => { if (!st.sending) closeSheet(); });
    bindOn("#back", goBack);
    bindOn("#d-ctx", openCtxPanel);
    bindOn("#d-stat", openHelperSheet); // header helper pill
    bindOn("#d-more", openChatInfo);
    bindOn("#quote-x", () => setQuote(""));
    bindOn("#new-btn", () => {
      const m = $("#msgs");
      m.scrollTo({ top: m.scrollHeight, behavior: "smooth" });
      setNewCount(0);
    });
    bindOn("#btn-wake", wake);
  });
  initStep("plus", bindPlus);
  initStep("deskFiles", bindDesktopFiles);
  initStep("mdCopy", bindMdCopy);
  initStep("quoteDock", bindQuoteDock);
  initStep("bubblePress", bindBubblePress);
  initStep("attach", bindAttach); // bubble attachments: open, broken image, load complete
  // window switching between wide and narrow (resizing): a guest may need to auto-open the session; redraw the list's selection mark
  if (WIDE.addEventListener) WIDE.addEventListener("change", () => { deskAuto(); renderChat(); });
  initStep("reply", bindReply);
  initStep("msgsScroll", () => {
    const m0 = $("#msgs");
    if (!m0) { diag("init-missing", { sel: "#msgs" }); return; }
    m0.addEventListener("scroll", () => {
      const m = $("#msgs");
      if (st.newCount && !awayFromBottom(m.scrollHeight, m.scrollTop, m.clientHeight)) setNewCount(0);
      if (st.agentView) { if (m.scrollTop < 80 && st.agentView.next != null && !st.agentView.loading) loadAgent(st.agentView.next); return; }
      if (m.scrollTop < 80 && st.next != null && !st.loading) loadPage(st.dToken, st.next);
    }, { passive: true });
  });
  addEventListener("popstate", (e) => {
    const d = e.state && e.state.d;
    const o = e.state && e.state.o;
    if (d) { if (d !== st.detailId || st.detailOff) openDetail(d, false, "popstate"); }
    else if (o) { if (o !== st.detailOff) openOffDetail(o, false, "popstate"); }
    else closeDetail();
  });
  initPresence();
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { stopPolling(); resetBanner(); presenceBeacon(); } // the first snapshot after returning to the foreground is used only as the baseline and does not replay banners from the background period
    else { startPolling(); pollDetail(); }
  });
  if ("serviceWorker" in navigator) {
    // when a new SW takes over refresh once so the page and shell files are the same version (no refresh on first install)
    const hadController = !!navigator.serviceWorker.controller;
    let reloaded = false;
    navigator.serviceWorker.addEventListener("controllerchange", () => {
      if (!hadController || reloaded) return;
      reloaded = true;
      location.reload();
    });
    navigator.serviceWorker.register("/sw.js").catch(() => {});
    initStep("shellCheck", shellCheck); // if the shell index.html and the sw version differ, reload once
  }

  // the pet manifest and snapshot are fetched in parallel; if the manifest arrives late draw again (so the manifest doesn't delay the "offline" hint)
  const pets = loadPets().then(render);
  if (document.hidden) refresh(); else startPolling();
  await Promise.all([pets, st.inflight]);
  openFromHash(location.hash, "launch");
  // tapping a notification while the app is in the background: the sw sends a message, or only the hash in the URL changed
  addEventListener("hashchange", () => openFromHash(location.hash, "hashchange"));
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.addEventListener("message", (e) => {
      if (e.data && e.data.type === "open" && typeof e.data.url === "string") {
        diag("notify-click", { url: e.data.url, tag: e.data.tag || null, hadClient: e.data.hadClient !== false, vis: document.visibilityState });
        openFromHash(new URL(e.data.url, location.origin).hash, "notify");
      }
    });
  }
}

// open the chat page by hash (#s/<sid> online, #o/<sid> off duty), then clear the hash
// from: launch = cold start with a hash / notify = notification click relayed by the sw / hashchange = only the hash changed
// deep-link hash routes: first match wins; the handler opens the session (#s/<id>) or the off-duty one (#o/<sid>)
const HASH_ROUTES = [
  [/^#s\/(.+)$/, (id, from) => openDetail(id, undefined, from)],
  [/^#o\/(.+)$/, (id, from) => openOffDetail(id, undefined, from)],
];
function openFromHash(hash, from) {
  for (const [re, open] of HASH_ROUTES) {
    const m = hash.match(re);
    if (!m) continue;
    const id = decodeURIComponent(m[1]);
    diagOpenFrom(id, from);
    history.replaceState(null, "", location.pathname + location.search);
    open(id, from);
    return;
  }
}

init();

// ---------- chat page "..." chat info, search in chat, do-not-disturb/pin, history before window switch ----------
// State lives in st.ch and is invalidated by dToken + session (automatically void after switching sessions or closing the chat page):
//   wins: previous-window chain (undefined = not asked / null = asking / array); segs: attached previous-window segments (near to far, {sid, at, via, items, next});
//   base: the bottom window (null = this window; when jumping to a search result in a previous window it is that window's id); jumped: viewing a jump target (pauses the 3-second poll, shows "back to latest")
function chState() {
  if (!st.ch || st.ch.token !== st.dToken || st.ch.sid !== st.detailId) {
    st.ch = { token: st.dToken, sid: st.detailId, wins: undefined, segs: [], base: null, jumped: false, fromInfo: false };
  }
  return st.ch;
}
const chLive = () => !!(st.ch && st.ch.token === st.dToken && st.ch.sid === st.detailId);
const chSess = () => (st.detailOff ? offAsSession(st.detailOff) : (st.byId.get(st.detailId) || {}));
// used by loadPage: pass from when the bottom window is a previous window
function chBaseFrom() { return chLive() && st.ch.base ? st.ch.base : null; }
// used by pollDetail: don't fetch the first page while viewing a jump target; if the user sends a message meanwhile, return to latest automatically
function chPaused() {
  if (!chLive() || !st.ch.jumped) return false;
  if ((st.outgoing.get(st.detailId) || []).length) { chBackToLatest(); return true; }
  return true;
}
// used by renderList: draw each previous-window segment (far to near) with its divider, then the bottom window; read-only segments are always drawn as idle, without optimistic bubbles
function chFrag(s) {
  if (!chLive() || (!st.ch.segs.length && !st.ch.base)) return renderItems(st.items, s);
  const c = st.ch;
  const frag = document.createDocumentFragment();
  const idle = Object.assign({}, s, { status: "idle" });
  const out = st.outgoing.get(st.detailId);
  if (out) st.outgoing.delete(st.detailId);
  for (let i = c.segs.length - 1; i >= 0; i--) {
    frag.append(renderItems(c.segs[i].items, idle, true));
    const sep = h("div", "ch-sep", chSepText(c.segs[i], nowSec()));
    sep.dataset.sid = c.segs[i].sid;
    frag.append(sep);
  }
  if (out && !c.base) st.outgoing.set(st.detailId, out);
  frag.append(renderItems(st.items, c.base ? idle : s));
  if (out && c.base) st.outgoing.set(st.detailId, out);
  return frag;
}
// used by renderOlder: after this window is exhausted, continue into the previous window; returns true if the button was drawn here
function chOlder() {
  const more = $("#d-more");
  if (more) more.hidden = !!st.detailOff; // guests have "..." too (chat info keeps only search) and the history before window switch
  if (st.detailOff || !st.detailId) return false;
  const c = chState();
  const plan = chOlderPlan(c, st.next, c.wins);
  if (plan.kind === "base") return false;
  if (plan.kind === "end") {
    if (c.wins === undefined) chLoadWins();
    if (!c.segs.length && !c.base) return false;
    $("#older").replaceChildren(h("span", null, t("dt.earliest")));
    return true;
  }
  const b = h("button", null, plan.kind === "win" ? (plan.win.via === "continued" ? t("older.continued") : t("older.prev")) : t("dt.older"));
  b.type = "button";
  b.onclick = () => chLoadOlder(plan);
  $("#older").replaceChildren(b);
  return true;
}
async function chLoadWins() {
  const c = chState();
  c.wins = null;
  let wins = [];
  try {
    const res = await api("/api/session/" + encodeURIComponent(c.sid) + "/lineage", null, FETCH_TIMEOUT_MS);
    if (res.ok) wins = ((await res.json()).windows) || [];
  } catch (e) { /* if unavailable treat as having no previous window */ }
  if (!chLive() || st.ch !== c) return;
  c.wins = wins;
  if (wins.length) renderOlder(); // only swap the button inside #older; no paging of this window is in progress at that time (the lineage is asked only after this window is exhausted)
}
async function chLoadOlder(plan) {
  if (st.loading) return;
  const c = chState();
  const token = st.dToken;
  st.loading = true;
  $("#older").replaceChildren(h("span", null, t("c.loading")));
  let data = null;
  try {
    const from = plan.kind === "win" ? plan.win.sid : plan.sid;
    const res = await api("/api/sessions/" + encodeURIComponent(st.detailId) + "/transcript" + chQuery(plan.kind === "seg" ? plan.before : null, from), null, FETCH_TIMEOUT_MS);
    if (res.ok) data = await res.json();
  } catch (e) {
    if (e.message === "auth") return;
  } finally {
    if (token === st.dToken) st.loading = false;
  }
  if (token !== st.dToken || st.ch !== c) return;
  if (!data) { toast(t("c.loadFail")); renderOlder(); return; }
  if (plan.kind === "win") c.segs.push({ sid: plan.win.sid, at: plan.win.at, via: plan.win.via, items: data.items || [], next: data.next });
  else {
    const sg = c.segs[c.segs.length - 1];
    sg.items = (data.items || []).concat(sg.items);
    sg.next = data.next;
  }
  renderList(chSess(), "prepend");
  renderOlder();
}

// jump to a search result: if already drawn scroll to it; otherwise fetch the page containing that row (around), replace the chat area and enter jump viewing ("back to latest" returns)
async function chJump(hit) {
  const c = chState();
  if (chScrollTo(hit)) return;
  if (st.loading) { toast(t("toast.loadingWait")); return; }
  const token = st.dToken;
  const from = hit.sid && hit.sid !== st.detailId ? hit.sid : null;
  st.loading = true;
  let data = null;
  try {
    const res = await api("/api/sessions/" + encodeURIComponent(st.detailId) + "/transcript" + chQuery(null, from, hit.seq), null, FETCH_TIMEOUT_MS);
    if (res.ok) data = await res.json();
  } catch (e) {
    if (e.message === "auth") return;
  } finally {
    if (token === st.dToken) st.loading = false;
  }
  if (token !== st.dToken || st.ch !== c) return;
  if (!data) { toast(t("toast.jumpFail")); return; }
  c.segs = [];
  c.base = from;
  c.jumped = true;
  st.items = data.items || [];
  st.next = data.next;
  renderList(chSess(), "bottom");
  renderOlder();
  chLatestBtn(true);
  requestAnimationFrame(() => { if (!chScrollTo(hit)) toast(t("toast.hitGone")); });
}
// the bubble in the chat area for a hit: partition by window (cut by dividers), find the index within the partition by role+ts+original text, then match to the bubble by order of identical text
function chScrollTo(hit) {
  if (!chLive()) return false;
  const c = st.ch;
  const baseSid = c.base || st.detailId;
  let items = null;
  let region = -1;
  if ((hit.sid || st.detailId) === baseSid) { items = st.items; region = c.segs.length; }
  else {
    const i = c.segs.findIndex((sg) => sg.sid === hit.sid);
    if (i >= 0) { items = c.segs[i].items; region = c.segs.length - 1 - i; }
  }
  if (!items) return false;
  const idx = chHitIndex(items, hit);
  if (idx < 0) return false;
  const raw = items[idx].text || "";
  const same = (it) => (it.role === "user" || it.role === "assistant" || it.role === "peer") && String(it.text || "").replace(/\s+/g, "") === raw.replace(/\s+/g, "");
  let k = 0;
  for (let j = 0; j < idx; j++) if (same(items[j])) k++;
  const bubs = [];
  let r = 0;
  for (const el of $("#list").children) {
    if (el.classList.contains("ch-sep")) { r++; continue; }
    if (r !== region) continue;
    for (const m of (el.matches(".m") ? [el] : el.querySelectorAll(".m"))) {
      if (msgText.has(m) && chSameText(raw, msgText.get(m))) bubs.push(m);
    }
  }
  const el = bubs[k] || bubs[bubs.length - 1];
  if (!el) return false;
  el.scrollIntoView({ block: "center" });
  el.classList.remove("ch-hl");
  void el.offsetWidth;
  el.classList.add("ch-hl");
  setTimeout(() => el.classList.remove("ch-hl"), 1500);
  return true;
}
function chLatestBtn(on) {
  let b = $("#ch-latest");
  if (!b && on) {
    b = h("button", "ch-latest", t("ch.latest"));
    b.id = "ch-latest";
    b.type = "button";
    b.onclick = chBackToLatest;
    $("#new-btn").parentNode.append(b);
  }
  if (b) b.hidden = !on;
}
function chBackToLatest() {
  if (chLive()) { st.ch.segs = []; st.ch.base = null; st.ch.jumped = false; }
  chLatestBtn(false);
  st.loading = false;
  loadPage(st.dToken, null);
}

// chat info page (reusing the #fs fullscreen shell): avatar + name; search in chat >; two toggles, mute messages and pin chat
function openChatInfo() {
  if (st.detailOff) { toast(t("toast.offNoInfo")); return; }
  const s = st.byId.get(st.detailId);
  if (!s) { toast(t("toast.noSession")); return; }
  chState().fromInfo = false;
  openFs("cinfo", t("ch.info"));
  $("#fs-x").onclick = chFsX;
  renderChatInfo(s);
}
function chFsX() {
  if (FS.kind === "csearch" && chLive() && st.ch.fromInfo) { openChatInfo(); return; }
  closeFs();
}
function renderChatInfo(s) {
  const head = h("div", "ch-head");
  const mini = h("div", "mini ch-hav");
  const pet = h("div", "pet");
  setPet(pet, s);
  mini.append(pet);
  const z = zoneOf(s.zone);
  const nm = h("div", "ch-hnm");
  nm.append(h("b", null, plateOf(s) || ""), h("small", null, (z.name || "") + (s.project ? " · " + s.project : "")));
  head.append(mini, nm);
  const meBox = h("div", "pf-chme"); // me among the members
  meBox.append(myAvatar("pf-chav"), h("small", null, st.guest ? guestProfileView(st.profile).name : profileView(st.profile).name));
  head.append(meBox);
  const g1 = h("div", "ch-grp");
  const find = h("button", "ch-row");
  find.type = "button";
  find.append(h("span", "ch-k", t("ch.find")), svgEl(CHEV_SVG));
  find.onclick = () => { chState().fromInfo = true; openChatSearch(); };
  g1.append(find);
  if (st.guest) { $("#fs-body").replaceChildren(head, g1); return; } // guests keep only "search in chat"; do-not-disturb / pin affect the admin's list and are not offered
  const g2 = h("div", "ch-grp");
  g2.append(chSwitch(t("ch.mute"), !!s.muted, (on) => chSetMute(s, on)),
    chSwitch(t("ch.top"), !!s.topped, (on) => setTop(s, on))); // switches the permanent pin directly, not through pinBlock
  $("#fs-body").replaceChildren(head, g1, g2);
}
function chSwitch(label, on, onChange) {
  const row = h("label", "ch-row ch-swr");
  const inp = h("input", "ch-tg");
  inp.type = "checkbox";
  inp.setAttribute("role", "switch");
  inp.checked = on;
  inp.onchange = () => { if (onChange(inp.checked) === false) inp.checked = !inp.checked; }; // if blocked, flip the toggle back
  row.append(h("span", "ch-k", label), inp);
  return row;
}
// permanent pin: api top.json, not synced to the dashboard, not removed when working, placed first right after "waiting for you"
async function setTop(s, on) {
  s.topped = on;
  render();
  try {
    const res = await post("/api/sessions/" + encodeURIComponent(s.id) + "/top", { on });
    if (!res.ok) throw new Error();
    toast(on ? t("toast.topped") : t("toast.untopped"));
  } catch (e) {
    if (e.message !== "auth") toast(t("c.opFail"));
  }
  refresh();
}
async function chSetMute(s, on) {
  s.muted = on;
  render();
  try {
    const res = await post("/api/sessions/" + encodeURIComponent(s.id) + "/mute", { on });
    if (!res.ok) throw new Error();
    toast(on ? t("toast.muted") : t("toast.unmuted"));
  } catch (e) {
    if (e.message !== "auth") toast(t("c.opFail"));
  }
  refresh();
}

// search in chat: the search box focuses automatically, searches after 350 ms of idle typing or on Enter (this window plus up to 3 previous windows), tapping a result jumps back to the chat
function openChatSearch(q0) {
  const s = st.byId.get(st.detailId);
  if (!s) return;
  openFs("csearch", t("ch.find"));
  $("#fs-x").onclick = chFsX;
  const bar = h("div", "ch-sbar");
  const inp = h("input", "ch-sinp");
  inp.type = "search";
  inp.placeholder = t("c.search");
  inp.enterKeyHint = "search";
  inp.autocomplete = "off";
  inp.setAttribute("autocapitalize", "off");
  const res = h("div", "ch-sres");
  bar.append(inp);
  $("#fs-body").replaceChildren(bar, res);
  let timer = 0;
  let seq = 0;
  const run = async () => {
    const q = inp.value.trim();
    const my = ++seq;
    if (!q) { res.replaceChildren(); return; }
    res.replaceChildren(h("div", "ch-note", t("ch.searching")));
    let data = null;
    try {
      const r = await api("/api/session/" + encodeURIComponent(s.id) + "/search?q=" + encodeURIComponent(q) + "&limit=50", null, 30000);
      if (r.ok) data = await r.json();
    } catch (e) { /* hinted uniformly below */ }
    if (my !== seq || FS.kind !== "csearch") return;
    if (!data) { res.replaceChildren(h("div", "ch-note", t("ch.searchFail"))); return; }
    chRenderHits(res, data, q, s);
  };
  inp.oninput = () => { clearTimeout(timer); timer = setTimeout(run, 350); };
  inp.onkeydown = (e) => { if (e.key === "Enter") { e.preventDefault(); clearTimeout(timer); run(); } };
  inp.focus(); // focus synchronously inside the click callback so iOS shows the keyboard
  if (typeof q0 === "string" && q0.trim()) { inp.value = q0.trim(); run(); } // coming from the outer search: carry the keyword and search right away
}
function chRenderHits(box, data, q, s) {
  const hits = data.results || [];
  if (!hits.length) { box.replaceChildren(h("div", "ch-note", t("ch.none", { q }))); return; }
  const now = nowSec();
  const prev = hits.filter((x) => x.sid && x.sid !== s.id).length;
  const rows = [h("div", "ch-note ch-cnt", t("ch.count", { n: hits.length }) + (prev ? (isEn() ? " " : "") + t("ch.countPrev", { n: prev }) : "") + (hits.length >= 50 ? t("ch.count50") : ""))];
  for (const x of hits) {
    const row = h("button", "ch-hit");
    row.type = "button";
    let av;
    if (x.role === "assistant") {
      av = h("div", "mini ch-av");
      const pet = h("div", "pet");
      setPet(pet, s);
      av.append(pet);
    } else if (x.role === "peer") av = h("div", "ch-av ch-avt ch-avp", speakerInitials(x.from));
    else if (chHitGuest(x) ? !st.guest : st.guest) av = h("div", "ch-av ch-avt ch-avp", st.guest ? t("c.adminInitial") : guestInitials(st.guestTagCur || undefined)); // guest viewing the admin's words / admin viewing the guest's words
    else av = myAvatar("ch-av"); // my avatar (blue square with the "me" letter if none is set)
    const col = h("div", "ch-hc");
    const top = h("div", "ch-ht");
    const meName = st.guest ? guestProfileView(st.profile).name : profileView(st.profile).name;
    top.append(h("span", "ch-hw", chWho(x, s, meName, { guest: st.guest, guestName: guestProfileView(st.guestProfile).name })), h("span", "ch-hd", (x.sid && x.sid !== s.id ? t("ch.prevTag") + " " : "") + chTime(x.ts, now)));
    const sn = h("div", "ch-hs");
    hlInto(sn, chHitText(x.snippet || ""), q); // strip the leading guest prefix
    col.append(top, sn);
    row.append(av, col);
    row.onclick = () => { closeFs(); chJump(x); };
    rows.push(row);
  }
  box.replaceChildren(...rows);
}

// ---------- my nickname and avatar (profile editing on the Me page; used on the right of my bubbles, search results, chat info, the Me page card) ----------
// st.profile = result of GET /api/profile; st.profileUrl = local blob URL of the avatar (fetched once so every redraw doesn't request it)
let pfToken = 0;
async function loadProfile() {
  if (!st.guest) loadGuestProfile(); // the admin also fetches the guest's profile (guest bubble avatar and nickname); a guest fetches their own
  const my = ++pfToken;
  let p = null;
  try {
    const r = await api("/api/profile", null, FETCH_TIMEOUT_MS);
    if (r.ok) p = await r.json();
  } catch (e) { return; }
  if (!p || my !== pfToken) return;
  let url = st.profileUrl || "";
  const key = p.avatar ? String(p.v) : "";
  if (key !== (st.profileKey || "")) {
    url = "";
    if (p.avatar) {
      try {
        const r = await api(profileView(p).url, null, FETCH_TIMEOUT_MS);
        if (r.ok) url = URL.createObjectURL(await r.blob());
      } catch (e) { url = ""; }
      if (my !== pfToken) return;
    }
    if (st.profileUrl) URL.revokeObjectURL(st.profileUrl);
    st.profileKey = url ? key : "";
  }
  st.profile = p;
  st.profileUrl = url;
  st.crSig.me = null;
  if (st.snap) render();
  if (st.detailId && !st.agentView) { st.sig = null; const s = st.byId.get(st.detailId); if (s) renderList(s, "keep"); }
}
// guest nickname and avatar used when the admin views a guest's bubbles (GET /api/profile?account=<guest>, avatar /api/avatar?account=<guest>&v=).
// one per guest (st.gpf[account]); whichever guest's session the current chat page belongs to is used (syncGuestCur -> st.guestProfile / st.guestProfileUrl)
let gpfToken = 0;
async function loadGuestProfile() {
  const my = ++gpfToken;
  const accs = (st.guests && st.guests.length ? st.guests.map((g) => g.account) : ["guest"]);
  for (const acc of accs) {
    let p = null;
    try {
      const r = await api("/api/profile?account=" + encodeURIComponent(acc), null, FETCH_TIMEOUT_MS);
      if (r.ok) p = await r.json();
    } catch (e) { return; }
    if (!p || my !== gpfToken) return;
    const old = st.gpf[acc] || {};
    const key = p.avatar ? String(p.v) : "";
    let url = old.url || "";
    if (key !== (old.key || "")) {
      url = "";
      if (p.avatar) {
        try {
          const r = await api(guestProfileView(p, acc).url, null, FETCH_TIMEOUT_MS);
          if (r.ok) url = URL.createObjectURL(await r.blob());
        } catch (e) { url = ""; }
        if (my !== gpfToken) return;
      }
      if (old.url) URL.revokeObjectURL(old.url);
    }
    st.gpf[acc] = { p, url, key: url ? key : "" };
  }
  const was = [st.guestProfile, st.guestProfileUrl];
  syncGuestCur(st.detailId && !st.detailOff ? st.byId.get(st.detailId) : null);
  const same = JSON.stringify(was[0] || null) === JSON.stringify(st.guestProfile || null) && was[1] === st.guestProfileUrl;
  if (!same && st.detailId && !st.agentView) { st.sig = null; const s = st.byId.get(st.detailId); if (s) renderList(s, "keep"); }
}
// admin: the guest bound to the current session (a session with no binding uses the first guest, "guest", as in older versions) -> st.guestProfile / st.guestProfileUrl / st.guestTagCur
function syncGuestCur(s) {
  if (st.guest) return;
  const g = guestFor(s, st.guests);
  const acc = g ? g.account : "guest";
  const e = st.gpf[acc] || {};
  st.guestProfile = e.p || null;
  st.guestProfileUrl = e.url || "";
  st.guestTagCur = g ? g.tag : "";
}
// cls: cav (40px in the chat), ch-av (36px in search results), me-av (profile card), pf-chav, pf-big
function myAvatar(cls) {
  const box = h("div", "pf-av " + cls);
  const clip = h("div", "pf-clip" + (cls === "cav" ? " cav-clip" : ""));
  if (st.profileUrl) {
    const im = h("img");
    im.src = st.profileUrl;
    im.alt = "";
    im.draggable = false;
    clip.append(im);
  } else {
    box.classList.add("pf-none");
    clip.append(h("span", "pf-ini", st.guest ? guestInitials() : t("c.me"))); // guest with no avatar: the guest letter (taken from the prefix)
  }
  box.append(clip);
  return box;
}
// pick image -> center-crop to a square -> 160x160 JPEG -> base64 (without the data: prefix)
async function pfCompress(file) {
  const bmp = await createImageBitmap(file);
  try {
    const c = avatarCrop(bmp.width, bmp.height, 160);
    const cv = document.createElement("canvas");
    cv.width = c.size;
    cv.height = c.size;
    const g = cv.getContext("2d");
    g.fillStyle = "#fff";
    g.fillRect(0, 0, c.size, c.size);
    g.drawImage(bmp, c.sx, c.sy, c.sw, c.sh, 0, 0, c.size, c.size);
    for (const q of [0.85, 0.7, 0.5]) { // the first tier is usually enough (40KB limit)
      const url = cv.toDataURL("image/jpeg", q);
      const b64 = url.slice(url.indexOf(",") + 1);
      if (b64.length * 3 / 4 < 38 * 1024) return { b64, url };
    }
    throw new Error("too big");
  } finally {
    if (bmp.close) bmp.close();
  }
}
function openProfileEdit() {
  openFs("pf", t("pf.title"));
  const dflt = st.guest ? guestDefaultName(st.profile) : t("c.me"); // guests can edit their own too (stored in the server's guest profile); the default nickname comes from the `default` of the endpoint
  const pv = st.guest ? guestProfileView(st.profile) : profileView(st.profile);
  let pick = null;    // { b64, url } newly picked avatar
  let clear = false;  // "Remove avatar" was tapped
  const top = h("div", "pf-top");
  const prev = h("div", "pf-prev");
  const paint = () => {
    prev.replaceChildren();
    if (pick) { const im = h("img"); im.src = pick.url; im.alt = ""; prev.append(im); }
    else if (!clear && st.profileUrl) prev.append(myAvatar("pf-big"));
    else { const d = h("div", "pf-av pf-big pf-none"); const c = h("div", "pf-clip"); c.append(h("span", "pf-ini", st.guest ? guestInitials() : t("c.me"))); d.append(c); prev.append(d); }
    rm.hidden = !(pick || (!clear && st.profileUrl));
  };
  const file = h("input");
  file.type = "file";
  file.accept = "image/*";
  file.hidden = true;
  const chg = h("button", "pf-btn", t("pf.change"));
  chg.type = "button";
  chg.onclick = () => file.click();
  const rm = h("button", "pf-btn pf-rm", t("pf.remove"));
  rm.type = "button";
  rm.onclick = () => { pick = null; clear = true; paint(); };
  file.onchange = async () => {
    const f = file.files && file.files[0];
    file.value = "";
    if (!f) return;
    try { pick = await pfCompress(f); clear = false; paint(); } catch (e) { toast(t("pf.badImg")); }
  };
  const btns = h("div", "pf-btns");
  btns.append(chg, rm);
  top.append(prev, btns, file);
  const grp = h("div", "ch-grp pf-grp2");
  const row = h("label", "ch-row pf-row");
  const inp = h("input", "pf-name");
  inp.type = "text";
  inp.maxLength = 20;
  inp.placeholder = dflt;
  inp.value = pv.name === dflt ? "" : pv.name;
  row.append(h("span", "ch-k", t("pf.name")), inp);
  grp.append(row);
  const save = h("button", "pf-save", t("c.save"));
  save.type = "button";
  save.onclick = async () => {
    const body = { name: inp.value.trim() };
    if (pick) body.avatar = pick.b64;
    else if (clear) body.avatar = null;
    save.disabled = true;
    try {
      const r = await post("/api/profile", body, 15000);
      if (!r.ok) throw new Error(String(r.status));
      await loadProfile();
      toast(t("c.saved"));
      if (FS.kind === "pf") closeFs();
    } catch (e) {
      if (e.message !== "auth") toast(t("pf.saveFail"));
    } finally { save.disabled = false; }
  };
  $("#fs-body").replaceChildren(top, grp, h("div", "pf-note", st.guest ? t("pf.noteGuest") : t("pf.note", { guest: guestDefaultName(st.guestProfile) })), save);
  paint();
}
