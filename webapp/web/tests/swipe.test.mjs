import test from "node:test";
import assert from "node:assert/strict";
import { swipeDecide, swipeSettle, swipeActions, applyFlagOpt, FLAG_OPT_MS, offFailText, nextDot, quotaRings, quotaLeft, resetClock, quotaCaption } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

// ---------- quota countdown ----------
const T = new Date(2026, 9, 20, 19, 2, 0).getTime() / 1000; // local time 10-20 (Tuesday) 19:02
const at = (d, h, m) => new Date(2026, 9, d, h, m, 0).getTime() / 1000;

test("quotaLeft: <1h shows minutes, <1d shows hours+minutes / hours, >=1d shows days+hours; expired or missing data is empty", () => {
  assert.equal(quotaLeft(T + 58 * 60, T), "58分");
  assert.equal(quotaLeft(T + 30, T), "1分");
  assert.equal(quotaLeft(T + 3 * 3600 + 12 * 60, T), "3时12分");
  assert.equal(quotaLeft(T + 3 * 3600, T), "3时");
  assert.equal(quotaLeft(T + 42 * 3600 + 59, T), "1天18时");
  assert.equal(quotaLeft(T + 48 * 3600, T), "2天");
  assert.equal(quotaLeft(T - 1, T), "");
  assert.equal(quotaLeft(T, T), "");
  assert.equal(quotaLeft(null, T), "");
  assert.equal(quotaLeft(undefined, T), "");
});

test("quotaRings adds left when now is given; without now the output has no left value", () => {
  const u = { fiveHour: { pct: 8, resetsAt: T + 58 * 60 }, sevenDay: { pct: 60, resetsAt: T + 42 * 3600 } };
  assert.deepEqual(quotaRings(u, T), [{ label: "5H", pct: 8, lv: "n", left: "58分", leftC: "58分" }, { label: "7D", pct: 60, lv: "w", left: "1天18时", leftC: "2天" }]);
  assert.deepEqual(quotaRings({ fiveHour: { pct: 8 } }, T), [{ label: "5H", pct: 8, lv: "n", left: "", leftC: "" }]);
  assert.deepEqual(quotaRings(u), [{ label: "5H", pct: 8, lv: "n" }, { label: "7D", pct: 60, lv: "w" }]);
});

test("resetClock: today shows the clock only, tomorrow shows a tomorrow label, later shows the weekday", () => {
  assert.equal(resetClock(at(20, 20, 0), T), "20:00");
  assert.equal(resetClock(at(21, 1, 5), T), "明天 01:05");
  assert.equal(resetClock(at(22, 10, 0), T), "周四 10:00");
});

test("quotaCaption: 5H says recover, 7D says reset, with clock time; expired shows used only", () => {
  assert.equal(quotaCaption({ pct: 8, resetsAt: at(20, 20, 0) }, "5H", T), "已用 8% · 58 分钟后恢复（20:00）");
  assert.equal(quotaCaption({ pct: 60, resetsAt: at(22, 13, 2) }, "7D", T), "已用 60% · 1 天 18 小时后重置（周四 13:02）");
  assert.equal(quotaCaption({ pct: 33.4, resetsAt: at(20, 22, 30) }, "5H", T), "已用 33% · 3 小时 28 分钟后恢复（22:30）");
  assert.equal(quotaCaption({ pct: 50, resetsAt: at(22, 19, 2) }, "7D", T), "已用 50% · 2 天后重置（周四 19:02）");
  assert.equal(quotaCaption({ pct: 8, resetsAt: T - 5 }, "5H", T), "已用 8%");
  assert.equal(quotaCaption({ pct: 8 }, "5H", T), "已用 8%");
});

// ---------- swipe ----------
test("swipeDecide: takes over only when mostly horizontal and past the threshold; vertical goes to scrolling; undecided until enough movement", () => {
  assert.equal(swipeDecide(-5, 2, 200, false), "");
  assert.equal(swipeDecide(-20, 4, 200, false), "h");
  assert.equal(swipeDecide(-14, 10, 200, false), ""); // diagonal: wait and see
  assert.equal(swipeDecide(-16, 15, 200, false), "v");
  assert.equal(swipeDecide(3, 30, 200, false), "v");
  assert.equal(swipeDecide(-40, 20, 200, false), "h");
  // a closed row ignores rightward swipes (no clash with the iOS swipe-back gesture)
  assert.equal(swipeDecide(30, 2, 10, false), "v");
  assert.equal(swipeDecide(30, 2, 200, false), "v");
  // rightward swipe on an open row closes it; but starting from the left screen edge still yields to the system
  assert.equal(swipeDecide(30, 2, 200, true), "h");
  assert.equal(swipeDecide(30, 2, 10, true), "v");
});

test("swipeSettle: dragging past min(60, 30%) opens / closes", () => {
  assert.equal(swipeSettle(0, -50, 228), false);
  assert.equal(swipeSettle(0, -61, 228), true);
  assert.equal(swipeSettle(-228, 30, 228), true); // dragging back a little while open: stays open
  assert.equal(swipeSettle(-228, 80, 228), false);
  assert.equal(swipeSettle(0, -40, 120), true); // two buttons: 36 is enough
});

test("swipeActions: button labels and colors follow the session state", () => {
  const keys = (s) => swipeActions(s).map((a) => a.key + ":" + a.label);
  assert.deepEqual(keys({ status: "idle", kind: "claude" }), ["unseen:标为未读", "rest:休息", "off:下班"]);
  assert.deepEqual(keys({ status: "idle", kind: "claude", unread: true }), ["seen:标为已读", "rest:休息", "off:下班"]);
  assert.deepEqual(keys({ status: "idle", kind: "claude", rest: true }), ["unseen:标为未读", "back:回来", "off:下班"]);
  // waiting / busy: cannot be marked unread, so no such button; peer messages can be marked
  assert.deepEqual(keys({ status: "waiting", kind: "claude" }), ["rest:休息", "off:下班"]);
  assert.deepEqual(keys({ status: "busy", kind: "claude" }), ["rest:休息", "off:下班"]);
  assert.deepEqual(keys({ status: "idle", kind: "claude", origin: "peer" }), ["unseen:标为未读", "rest:休息", "off:下班"]);
  // not a Claude session: cannot go off duty
  assert.deepEqual(keys({ status: "idle", kind: "shell" }), ["unseen:标为未读", "rest:休息"]);
  const a = swipeActions({ status: "idle", kind: "claude" });
  assert.deepEqual(a.map((x) => x.color), ["#1E6FD9", "#C87A2E", "#FA5151"]);
});

test("applyFlagOpt: optimistic red dot / rest; released once the snapshot catches up or times out", () => {
  const snap = (over) => ({ generatedAt: 1, sessions: [{ id: "a", status: "idle", unread: false, rest: false, ...over }] });
  const opt = new Map([["a", { at: 1000, unread: true }]]);
  let r = applyFlagOpt(snap({}), opt, 2000);
  assert.equal(r.snap.sessions[0].unread, true);
  assert.equal("at" in r.snap.sessions[0], false);
  assert.equal(r.opt.size, 1);
  r = applyFlagOpt(snap({ unread: true }), opt, 2000); // server caught up
  assert.equal(r.opt.size, 0);
  r = applyFlagOpt(snap({}), opt, 1000 + FLAG_OPT_MS); // timeout
  assert.equal(r.snap.sessions[0].unread, false);
  assert.equal(r.opt.size, 0);
  r = applyFlagOpt(snap({ status: "busy" }), opt, 2000); // busy again: do not force the red dot
  assert.equal(r.snap.sessions[0].unread, false);
  const ro = new Map([["a", { at: 1000, rest: true }]]);
  r = applyFlagOpt(snap({}), ro, 2000);
  assert.equal(r.snap.sessions[0].rest, true);
  r = applyFlagOpt(snap({ status: "waiting" }), ro, 2000); // waiting: rest is lifted automatically, not forced
  assert.equal(r.snap.sessions[0].rest, false);
  r = applyFlagOpt({ generatedAt: 1, sessions: [] }, ro, 2000);
  assert.equal(r.opt.size, 0);
});

test("offFailText: prefers the reason reported back by the host", () => {
  assert.equal(offFailText({ error: "offduty-failed", message: "Lab-a 状态是 waiting，不是空闲" }), "Lab-a 状态是 waiting，不是空闲");
  assert.equal(offFailText({ error: "offduty-failed", message: "ZBS-OFF 状态是 busy，不是空闲，不送（加 --force 强制）" }), "ZBS-OFF 状态是 busy，不是空闲，不送");
  assert.equal(offFailText({ error: "offduty-timeout" }), "下班超时：它可能停在 Mac 上的确认框");
  assert.equal(offFailText({ error: "zzz" }), "下班失败");
});

// ---------- double tap ----------
test("nextDot: finds the next red dot downward and wraps around; does not stick on one row when the page cannot scroll", () => {
  const rows = [{ id: "a", top: 0 }, { id: "b", top: 300 }, { id: "c", top: 900 }];
  assert.equal(nextDot([], 0, null), -1);
  assert.equal(nextDot(rows, 0, null), 1);
  assert.equal(nextDot(rows, 300, "b"), 2);
  assert.equal(nextDot(rows, 700, "c"), 0); // c is at the page bottom and cannot scroll to 900, so it stops at 700: the next call wraps to the first
  assert.equal(nextDot(rows, 2000, null), 0);
  assert.equal(nextDot([{ id: "a", top: 500 }], 0, "a"), 0);
  assert.equal(nextDot(rows, 0, "b"), 2); // just jumped to b and back at the top: skip b
});
