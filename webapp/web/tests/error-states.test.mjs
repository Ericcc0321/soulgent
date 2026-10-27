// Error / retrying / unexpected-exit states (errorKind … compactedAt) + header list: agent rows jump to the subagent plate first
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { chatRow, summaryText, sortChat } from "../logic.js";
import { setLang, table } from "../i18n.js";
setLang("hans");

const T0 = Date.parse("2026-10-24T10:00:00Z") / 1000;
const Z = [{ code: "W", name: "Web", color: "#fff" }];
const S = (o) => ({ id: "s1", name: "W-x", zone: "W", status: "idle", since: T0 - 600, summary: "好了", kind: "claude", ...o });
const API = { errorKind: "api", errorStatus: 529, errorText: "API Error: 529 Overloaded", errorSince: T0 - 60,
  summaryCode: "state.apiError", summaryArgs: { kind: "api", status: 529, text: "Overloaded" } };
const LIMIT = { errorKind: "rate_limit", errorStatus: 429, errorText: "You've hit your limit · resets 1pm", errorSince: T0 - 60,
  summaryCode: "state.apiError", summaryArgs: { kind: "rate_limit", status: 429, text: "You've hit your limit · resets 1pm" } };
const GONE = { disconnected: true, disconnectedSince: T0 - 120, summaryCode: "state.disconnected", summaryArgs: {} };
const RETRY = { status: "busy", retryAttempt: 3, retryMax: 10, summaryCode: "state.retrying", summaryArgs: { attempt: 3, max: 10 } };

test("summaryText：the three codes follow the Simplified template (three languages)", () => {
  const r = (o, lang) => { setLang(lang); const v = summaryText(S(o)); setLang("hans"); return v; };
  assert.equal(r(API, "hans"), "API 出错 529：Overloaded");
  assert.equal(r({ ...API, summaryArgs: { kind: "api", status: null, text: "Connection error." } }, "hans"), "API 出错：Connection error.");
  assert.equal(r(LIMIT, "en"), "You've hit your limit · resets 1pm");
  assert.equal(r({ summaryCode: "state.apiError", summaryArgs: { kind: "auth", status: 401 } }, "hans"), "要重新登录");
  assert.equal(r({ summaryCode: "state.apiError", summaryArgs: { kind: "api", status: 500 } }, "hans"), "好了"); // missing text falls back to the original summary
  assert.equal(r(RETRY, "hans"), "正在重试 3/10");
  assert.equal(r({ summaryCode: "state.retrying", summaryArgs: { max: 10 } }, "hans"), "好了");
  assert.equal(r(GONE, "hans"), "意外退出");
  assert.equal(r(GONE, "hant"), "意外結束");
  assert.equal(r(GONE, "en"), "Exited unexpectedly");
});

test("list row: API error shows a red error tag + rendered summary; unread gets a red dot", () => {
  const r = chatRow(S({ ...API, unread: true }), Z, T0);
  assert.deepEqual(r.tag, { cls: "e", text: "[出错]" });
  assert.equal(r.text, "API 出错 529：Overloaded");
  assert.equal(r.badge, "dot");
  assert.equal(r.kind, "u");
  // already seen: tag stays, no red dot
  const seen = chatRow(S(API), Z, T0);
  assert.deepEqual(seen.tag, { cls: "e", text: "[出错]" });
  assert.equal(seen.badge, "");
  // auth: needs re-login
  assert.equal(chatRow(S({ errorKind: "auth", summaryCode: "state.apiError", summaryArgs: { kind: "auth" } }), Z, T0).text, "要重新登录");
});

test("list row: quota-exhausted amber tag + original CC text; falls back to errorText when there is no code", () => {
  const r = chatRow(S({ ...LIMIT, unread: true }), Z, T0);
  assert.deepEqual(r.tag, { cls: "a", text: "[额度用完]" });
  assert.equal(r.text, "You've hit your limit · resets 1pm");
  const old = chatRow(S({ errorKind: "rate_limit", errorText: "limit · resets 3pm" }), Z, T0);
  assert.equal(old.text, "limit · resets 3pm");
});

test("list row: error takes precedence over background-running; a draft still overrides", () => {
  assert.equal(chatRow(S({ ...API, bgTasks: 1 }), Z, T0).tag.cls, "e");
  assert.equal(chatRow(S(API), Z, T0, "草稿内容").tag.cls, "dr");
});

test("list row: retrying still counts as working; the amber retry tag replaces the working tag; retryMax defaults to 10", () => {
  const r = chatRow(S(RETRY), Z, T0);
  assert.equal(r.kind, "g");
  assert.deepEqual(r.tag, { cls: "a", text: "正在重试 3/10" });
  assert.equal(r.text, "");
  assert.equal(r.badge, "live");
  assert.equal(chatRow(S({ status: "busy", retryAttempt: 2 }), Z, T0).tag.text, "正在重试 2/10");
  assert.equal(chatRow(S({ status: "busy" }), Z, T0).tag.text, "正在干活");
  // idle with retryAttempt (stale data) does not show retry
  assert.notEqual((chatRow(S({ retryAttempt: 2 }), Z, T0).tag || {}).cls, "a");
});

test("list row: unexpected exit greys the row, time is the exit time, no red dot, not counted", () => {
  const r = chatRow(S({ ...GONE, unread: true }), Z, T0); // a backend wrongly sending unread still gets no red dot
  assert.equal(r.gone, true);
  assert.deepEqual(r.tag, { cls: "h", text: "意外退出" });
  assert.equal(r.text, "");
  assert.equal(r.badge, "");
  assert.equal(r.kind, "d");
  assert.equal(r.time, L.chatTime(T0 - 120, T0));
  assert.equal(chatRow(S({}), Z, T0).gone, false);
  assert.equal(L.chatBadge({ sessions: [S({ ...GONE, unread: true })] }), 0);
});

test("sorting: unexpected exits go after busy and before plain idle, newest exit first", () => {
  const a = S({ id: "idle", since: T0 - 10 });
  const g1 = S({ id: "g1", ...GONE, disconnectedSince: T0 - 300, since: T0 - 9000 });
  const g2 = S({ id: "g2", ...GONE, disconnectedSince: T0 - 100, since: T0 - 9999 });
  const b = S({ id: "busy", status: "busy" });
  assert.deepEqual(sortChat([a, g1, b, g2]).map((s) => s.id), ["busy", "g2", "g1", "idle"]);
});

test("swipe / long-press: unexpected exits have no read/unread and no rest actions", () => {
  const keys = L.swipeActions(S(GONE)).map((a) => a.key);
  assert.deepEqual(keys, ["off"]);
  const m = L.rowMenuActs(S(GONE), false).map((a) => a.key);
  assert.ok(!m.includes("seen") && !m.includes("unseen") && !m.includes("rest"), m.join(","));
});

test("WorkBuddy: wbState reads errorKind wb_error / wb_stopped first, then falls back to summaryCode", () => {
  assert.equal(L.wbState(S({ kind: "workbuddy", errorKind: "wb_error", summary: "出错" })), "error");
  assert.equal(L.wbState(S({ kind: "workbuddy", errorKind: "wb_stopped", summaryCode: "state.error" })), "stopped");
  assert.equal(L.wbState(S({ kind: "workbuddy", summaryCode: "state.paused" })), "paused");
  assert.equal(L.wbState(S({ kind: "workbuddy", summaryCode: "state.error" })), "error");
  assert.equal(L.wbState(S({ errorKind: "api" })), null);
  const r = chatRow(S({ kind: "workbuddy", errorKind: "wb_error", summary: "出错" }), Z, T0);
  assert.deepEqual(r.tag, { cls: "e", text: "[出错]" });
  assert.equal(r.text, "");
});

test("banner: error / quota-exhausted fire after 3s; unexpected exit fires once after 3s; no \"finished\" banner", () => {
  const run = (s) => {
    let st = L.bannerStep(L.newBannerState(), [], 0).state;
    st = L.bannerStep(st, [s], 1000).state;
    const early = L.bannerStep(st, [s], 1000 + L.BANNER_WAIT_MS - 1);
    const fire = L.bannerStep(early.state, [s], 1000 + L.BANNER_WAIT_MS).fire;
    return { early: early.fire, fire };
  };
  assert.deepEqual(run(S({ ...API, unread: true })).fire, [{ id: "s1", kind: "err" }]);
  assert.deepEqual(run(S({ ...API, unread: true })).early, []);
  assert.deepEqual(run(S({ ...LIMIT, unread: true })).fire, [{ id: "s1", kind: "limit" }]);
  assert.deepEqual(run(S({ ...GONE })).fire, [{ id: "s1", kind: "lost" }]);
  assert.deepEqual(run(S({ kind: "workbuddy", errorKind: "wb_stopped", unread: true })).early, []);
  // text: error includes details, quota-exhausted includes the original CC text, unexpected exit uses the plain phrase
  assert.deepEqual(L.bannerText(S(API), "err"), { title: "x", body: "[出错了] API 出错 529：Overloaded" });
  assert.deepEqual(L.bannerText(S(LIMIT), "limit"), { title: "x", body: "[额度用完] You've hit your limit · resets 1pm" });
  assert.deepEqual(L.bannerText(S(GONE), "lost"), { title: "x", body: "意外退出" });
  assert.deepEqual(L.bannerText(S({ kind: "workbuddy", summaryCode: "state.error" }), "err"), { title: "x", body: "出错了" });
  assert.equal(L.bannerStill(S(GONE), "lost"), true);
  assert.equal(L.bannerStill(S({}), "lost"), false);
  assert.equal(L.bannerStill(S({ ...LIMIT, unread: true }), "limit"), true);
});

test("banner: an error after the session was seen (newer finishedAt) counts as a new round", () => {
  let st = L.bannerStep(L.newBannerState(), [S({ unread: true, finishedAt: T0 - 600 })], 0).state;
  st = L.bannerStep(st, [S({ unread: true, finishedAt: T0 - 600 })], 20000).state;
  const s2 = S({ ...API, unread: true, finishedAt: T0 - 60 });
  st = L.bannerStep(st, [s2], 21000).state;
  assert.deepEqual(L.bannerStep(st, [s2], 21000 + L.BANNER_WAIT_MS).fire, [{ id: "s1", kind: "err" }]);
});

test("guest local unread: unexpected exit stays non-red; errors turn red again by errorSince", () => {
  const raw = (o) => ({ sessions: [S({ origin: "user", ...o })] });
  assert.equal(L.guestSnapshot(raw({ ...GONE, since: T0 }), T0 - 100).snap.sessions[0].unread, false);
  assert.equal(L.guestSnapshot(raw({ since: T0 }), T0 - 100).snap.sessions[0].unread, true);
  assert.equal(L.guestSnapshot(raw({ ...API, since: T0 - 600, errorSince: T0 }), T0 - 100).snap.sessions[0].unread, true);
});

test("chat-page alert bar chatAlert: error red / quota amber / retry amber / unexpected exit grey / recently compacted (within 60s)", () => {
  assert.deepEqual(L.chatAlert(S(API), T0), { cls: "e", text: "出错：API 出错 529：Overloaded" });
  assert.deepEqual(L.chatAlert(S(LIMIT), T0), { cls: "a", text: "[额度用完] You've hit your limit · resets 1pm" });
  assert.deepEqual(L.chatAlert(S(RETRY), T0), { cls: "a", text: "正在重试 API（3/10）" });
  assert.deepEqual(L.chatAlert(S(GONE), T0), { cls: "h", text: "会话意外退出。" });
  assert.deepEqual(L.chatAlert(S({ compactedAt: T0 - 30 }), T0), { cls: "h", text: "刚压缩过上下文" });
  assert.equal(L.chatAlert(S({ compactedAt: T0 - 61 }), T0), null);
  assert.equal(L.chatAlert(S({}), T0), null);
  assert.equal(L.chatAlert(null, T0), null);
  // errors only count while idle (after a successful retry the host clears errorKind; busy never shows a stale error)
  assert.equal(L.chatAlert(S({ ...API, status: "busy" }), T0), null);
});

test("chat placeholder bubble: shows the retry line while retrying, otherwise the elapsed-minutes line", () => {
  assert.equal(L.busyLine(S({ ...RETRY, since: T0 - 300 }), T0), "正在重试 API（3/10）");
  assert.equal(L.busyLine(S({ status: "busy", since: T0 - 300 }), T0), "已干 5 分钟");
});

test("i18n: error-related entries exist in all three languages with consistent wording (\"exited unexpectedly\", not \"disconnected\")", () => {
  const T = table();
  for (const k of ["row.tagLimit", "head.err", "head.compacted", "busy.retry", "lost.banner", "pushmsg.limit", "pushmsg.lost",
    "sum.state.apiError", "sum.state.apiError.limit", "sum.state.apiError.auth", "sum.state.apiError.nostatus", "sum.state.retrying", "sum.state.disconnected"]) {
    assert.ok(Array.isArray(T[k]) && T[k].length === 3 && T[k].every((x) => typeof x === "string" && x), k);
  }
  assert.deepEqual(T["sum.state.disconnected"], ["Exited unexpectedly", "意外退出", "意外結束"]);
  assert.deepEqual(T["row.tagLimit"], ["[Limit reached]", "[额度用完]", "[額度用完]"]);
});

test("styles / wiring: amber tag, grey card, chat alert bar", () => {
  const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
  const app = rd("app.js"), html = rd("index.html"), css = rd("style.css");
  assert.match(css, /\.cr-pt\.a\s*\{[^}]*color/);
  assert.match(css, /\.cr-row\.gone/);
  assert.match(html, /id="d-alert"/);
  assert.match(app, /chatAlert\(/);
  assert.match(app, /busyLine\(/);
  assert.match(app, /r\.gone/);
});

test("header list: agent rows jump to the subagent plate .ag-flip first, then fall back to the tool tag; cmd rows try the tool tag first", () => {
  assert.deepEqual(L.helperJumpOrder("agent"), ["ag", "tu"]);
  assert.deepEqual(L.helperJumpOrder("cmd"), ["tu", "ag"]);
  assert.deepEqual(L.helperJumpOrder(undefined), ["tu", "ag"]);
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  assert.match(app, /helperJumpOrder\(/);
  assert.match(app, /helperJump\(tu, kind\)/);
});

test("error red is unified brick red #C4392B (CSS variable --err) for the error tag and chat alert; amber keeps its own color", () => {
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  assert.match(css, /--err:\s*#C4392B/i);
  assert.match(css, /\.cr-pt\.e\s*\{\s*color:\s*var\(--err\)/);
  assert.match(css, /\.d-alert\.e\s*\{\s*color:\s*var\(--err\)/);
  assert.match(css, /\.cr-pt\.a\s*\{\s*color:\s*var\(--orange\)/);
});

test("background tasks running while main turn is idle: avatar stands (idle frame / idle flame / weak fire level); only the out-of-frame pet wanders", () => {
  const bg = S({ bgTasks: 2, bgSince: T0 - 600, model: "claude-fable-5" });
  assert.equal(L.avatarPose(bg), "idle");
  assert.equal(L.petState(bg), "idle");
  assert.match(L.flameAvatarSrc(bg), /mascot-av-idle\.png/);
  assert.equal(L.fireLevel(bg), "weak");
  // the out-of-frame pet still wanders but is flagged bg: the avatar pet keeps standing, no errand plate, no shadow
  const fx = L.busyFx(bg, "pet", Z, { walk: true }, "ok");
  assert.equal(fx.kind, "walk");
  assert.equal(fx.bg, true);
  assert.equal(L.busyFx(bg, null, Z, null, "none").bg, true);
  // contrast: a busy main turn still uses the busy frame, without bg
  const busy = S({ status: "busy", bgTasks: 2 });
  assert.equal(L.avatarPose(busy), "running");
  assert.equal(L.busyFx(busy, "pet", Z, { walk: true }, "ok").bg, false);
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  assert.match(app, /fxw-bg/);
  assert.match(app, /avatarPose\(/);
});
