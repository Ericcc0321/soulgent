import test from "node:test";
import assert from "node:assert/strict";
import { buildLanes, petState, usageColor, relTime, isoToSec, failReason, cleanReplyText, nextPollAction, REQ_MAX_MS, askAnswerable, buildAskSteps, approveSteps, pollDelayMs, mergeItems, approveDefs, approveTarget, liveAskIndex, pruneSent, partialFailText, offLine, offHeader, offPollDelayMs, WAKE_MAX_MS, nextWakeAction, wakeFailText, findAwake, applyOptimistic, busyClock } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const zones = [
  { code: "Web", name: "Web", color: "#111111", order: 2, lead: "Web-lead" },
  { code: "Docs", name: "Docs", color: "#E0A040", order: 1, lead: "Docs-lead" },
  { code: "Empty", name: "Empty", color: "#222222", order: 3, lead: "x" },
];
const S = (id, o = {}) => ({ id, name: id, zone: "Docs", status: "idle", since: 100, unread: false, pinned: false, rest: false, ...o });
const snap = (sessions) => ({ zones, sessions });
const ids = (l) => l.cards.map((s) => s.id);

test("zones follow order, unzoned last, empty zones omitted", () => {
  const lanes = buildLanes(snap([S("a", { zone: null }), S("b", { zone: "Web" }), S("c", { zone: "Docs" })]));
  assert.deepEqual(lanes.map((l) => l.code), ["Docs", "Web", null]);
  assert.equal(lanes[2].name, "未分区");
  assert.equal(lanes[2].color, "#8A8F98");
  assert.equal(lanes[0].color, "#E0A040");
});

test("unknown zone code goes to unzoned lane", () => {
  const lanes = buildLanes(snap([S("a", { zone: "Nope" })]));
  assert.deepEqual(lanes.map((l) => l.code), [null]);
});

test("card ordering: pinned > waiting > unread > busy > other, then since desc", () => {
  const lanes = buildLanes(snap([
    S("idle-new", { since: 900 }),
    S("busy", { status: "busy", since: 500 }),
    S("unread", { unread: true, since: 400 }),
    S("waiting", { status: "waiting", since: 300 }),
    S("pinned-read", { pinned: true, since: 1 }),
    S("waiting-old", { status: "waiting", since: 10 }),
  ]));
  assert.deepEqual(ids(lanes[0]), ["pinned-read", "waiting", "waiting-old", "unread", "busy", "idle-new"]);
});

test("lead goes first within the same group", () => {
  const lanes = buildLanes(snap([
    S("new", { status: "busy", since: 900 }),
    S("Docs-lead", { status: "busy", since: 1 }),
    S("waiting", { status: "waiting", since: 1 }),
  ]));
  assert.deepEqual(ids(lanes[0]), ["waiting", "Docs-lead", "new"]);
});

test("rest sessions go to rest, not cards; lane with only rest still appears", () => {
  const lanes = buildLanes(snap([S("a"), S("r", { rest: true }), S("r2", { rest: true, zone: "Web" })]));
  assert.deepEqual(ids(lanes[0]), ["a"]);
  assert.deepEqual(lanes[0].rest.map((s) => s.id), ["r"]);
  assert.equal(lanes[1].code, "Web");
  assert.equal(lanes[1].cards.length, 0);
  assert.equal(lanes[1].rest.length, 1);
});

test("counts are exclusive (waiting > unread > busy) and skip rest", () => {
  const sessions = [
    S("w", { status: "waiting", unread: true }),
    S("u", { unread: true }),
    S("b", { status: "busy" }),
    S("b2", { status: "busy", unread: true }),
    S("i"),
    S("r", { rest: true, unread: true }),
  ];
  assert.deepEqual(buildLanes(snap(sessions))[0].counts, { waiting: 1, unread: 2, busy: 1 });
});

test("petState mapping", () => {
  assert.equal(petState(S("a", { status: "waiting" })), "waiting");
  assert.equal(petState(S("a", { status: "busy" })), "running");
  assert.equal(petState(S("a", { unread: true })), "waving");
  assert.equal(petState(S("a", { rest: true, unread: true })), "rest");
  assert.equal(petState(S("a")), "idle");
});

test("usageColor boundaries", () => {
  assert.equal(usageColor(0), "ok");
  assert.equal(usageColor(49), "ok");
  assert.equal(usageColor(50), "warn");
  assert.equal(usageColor(69), "warn");
  assert.equal(usageColor(70), "high");
  assert.equal(usageColor(89), "high");
  assert.equal(usageColor(90), "max");
  assert.equal(usageColor(100), "max");
});

test("relTime boundaries", () => {
  const now = 1_000_000;
  assert.equal(relTime(now, now), "刚刚");
  assert.equal(relTime(now - 59, now), "刚刚");
  assert.equal(relTime(now + 30, now), "刚刚");
  assert.equal(relTime(now - 60, now), "1 分钟");
  assert.equal(relTime(now - 180, now), "3 分钟");
  assert.equal(relTime(now - 3599, now), "59 分钟");
  assert.equal(relTime(now - 3600, now), "1 小时");
  assert.equal(relTime(now - 7200, now), "2 小时");
  assert.equal(relTime(now - 86399, now), "23 小时");
  assert.equal(relTime(now - 86400, now), "昨天");
  assert.equal(relTime(now - 172799, now), "昨天");
  assert.equal(relTime(now - 172800, now), "2 天");
  assert.equal(relTime(now - 3 * 86400 - 5, now), "3 天");
});

test("isoToSec converts ISO strings to seconds, bad input to 0", () => {
  assert.equal(isoToSec("2026-10-19T01:00:00Z"), 1792371600);
  assert.equal(isoToSec("2026-10-19T01:00:00.500Z"), 1792371600.5);
  assert.equal(isoToSec(""), 0);
  assert.equal(isoToSec(undefined), 0);
  assert.equal(isoToSec("garbage"), 0);
});

test("failReason maps helper errors to Chinese", () => {
  assert.equal(failReason("helper-timeout"), "Mac 小帮手没响应");
  assert.equal(failReason("no-terminal"), "找不到这个会话的 Orca 终端");
  assert.equal(failReason("session-gone"), "会话已结束");
  assert.equal(failReason("orca-failed"), "Orca 没接收");
  assert.equal(failReason("bad-request"), "发送失败");
  assert.equal(failReason(undefined), "发送失败");
  assert.equal(failReason("whatever", "读取失败"), "读取失败");
  assert.equal(failReason("no-terminal", "读取失败"), "找不到这个会话的 Orca 终端");
});

test("cleanReplyText mirrors the server rule (control chars out, newlines to spaces, trim)", () => {
  assert.equal(cleanReplyText("  hi\nthere\r\n "), "hi there");
  assert.equal(cleanReplyText("a\x00b\x1bc\x7fd\te"), "abcde");
  assert.equal(cleanReplyText(" \n\t "), "");
  assert.equal(cleanReplyText("中文 ok"), "中文 ok");
  assert.equal(cleanReplyText(undefined), "");
});

test("failReason covers server-side codes added in review", () => {
  assert.equal(failReason("not-claude"), "此类会话暂不支持回复");
  assert.equal(failReason("helper-restarted"), "Mac 小帮手重启过，请确认后重发");
  assert.equal(failReason("unknown-status"), "状态未知，请稍后查看对话再决定是否重发");
});

test("nextPollAction: 404 is pending during the first 8 s", () => {
  assert.deepEqual(nextPollAction(404, null, 0), { status: "pending" });
  assert.deepEqual(nextPollAction(404, null, 7999), { status: "pending" });
});

test("nextPollAction: 404 after 8 s → unknown status (not a delivery failure)", () => {
  assert.deepEqual(nextPollAction(404, null, 8000), { status: "failed", error: "unknown-status" });
});

test("nextPollAction: 400 fails immediately", () => {
  assert.deepEqual(nextPollAction(400, { error: "bad rid" }, 100), { status: "failed", error: "bad-request" });
});

test("nextPollAction: done / failed / pending bodies", () => {
  assert.deepEqual(nextPollAction(200, { status: "done" }, 900), { status: "done" });
  assert.deepEqual(nextPollAction(200, { status: "done", lines: ["a"] }, 900), { status: "done", lines: ["a"] });
  assert.deepEqual(nextPollAction(200, { status: "failed", error: "no-terminal" }, 900), { status: "failed", error: "no-terminal" });
  assert.deepEqual(nextPollAction(200, { status: "pending" }, 900), { status: "pending" });
});

test("nextPollAction: timeout at 35 s whatever the response", () => {
  assert.deepEqual(nextPollAction(200, { status: "pending" }, 35000), { status: "failed", error: "helper-timeout" });
  assert.deepEqual(nextPollAction(0, null, 35000), { status: "failed", error: "helper-timeout" });
  assert.deepEqual(nextPollAction(503, null, 1000), { status: "pending" }); // transient server error: keep waiting
  assert.deepEqual(nextPollAction(0, null, 1000), { status: "pending" }); // network error
  // a result that has already arrived is used even at the deadline
  assert.deepEqual(nextPollAction(200, { status: "done" }, 36000), { status: "done" });
});

const Q = (n, o = {}) => ({ question: "q", header: "h", multiSelect: false, options: Array.from({ length: n }, (_, i) => "o" + i), ...o });

test("askAnswerable: single and multi select supported, key range must suffice", () => {
  assert.equal(askAnswerable([Q(3)]), true);
  assert.equal(askAnswerable([Q(3), Q(2)]), true);
  assert.equal(askAnswerable([Q(3, { multiSelect: true })]), true);
  assert.equal(askAnswerable([Q(3), Q(2, { multiSelect: true })]), true);
  assert.equal(askAnswerable([Q(9, { multiSelect: true })]), false);
  assert.equal(askAnswerable([Q(8)]), true);   // custom entry = 9
  assert.equal(askAnswerable([Q(9)]), false);  // custom entry = 10, beyond 1..9
  assert.equal(askAnswerable([]), false);
  assert.equal(askAnswerable(null), false);
  // 5 questions all options = 5 steps + submit = 6; 4 questions all custom = 12 + 1 = 13 steps, over 12
  assert.equal(askAnswerable([Q(2), Q(2), Q(2), Q(2)]), true);
});

test("buildAskSteps: single question option is one step", () => {
  assert.deepEqual(buildAskSteps([Q(3)], [2]), [{ key: "2" }]);
});

test("buildAskSteps: single question custom entry = n+1, text, enter", () => {
  assert.deepEqual(buildAskSteps([Q(3)], [{ text: "芒果" }]),
    [{ key: "4" }, { text: "芒果" }, { key: "enter" }]);
});

test("buildAskSteps: multiple questions one key each, plus 1 to submit", () => {
  assert.deepEqual(buildAskSteps([Q(3), Q(2)], [1, 2]), [{ key: "1" }, { key: "2" }, { key: "1" }]);
});

test("buildAskSteps: multiple questions with mixed custom entries", () => {
  assert.deepEqual(buildAskSteps([Q(3), Q(2)], [{ text: "x" }, 1]),
    [{ key: "4" }, { text: "x" }, { key: "enter" }, { key: "1" }, { key: "1" }]);
});

test("buildAskSteps: text cleaned by cleanReplyText; empty text / missing choice / out of range / over 12 steps / multi-select returns null", () => {
  assert.deepEqual(buildAskSteps([Q(2)], [{ text: " a\nb " }]), [{ key: "3" }, { text: "a b" }, { key: "enter" }]);
  assert.equal(buildAskSteps([Q(2)], [{ text: "  " }]), null);
  assert.equal(buildAskSteps([Q(2), Q(2)], [1]), null);
  assert.equal(buildAskSteps([Q(2), Q(2)], [1, undefined]), null);
  assert.equal(buildAskSteps([Q(2)], [3]), null);
  assert.equal(buildAskSteps([Q(2)], [0]), null);
  assert.equal(buildAskSteps([Q(2, { multiSelect: true })], [1]), null); // multi-select needs { multi }
  const many = Array.from({ length: 9 }, () => Q(2));
  assert.equal(buildAskSteps(many, many.map(() => ({ text: "a" }))), null); // 9×3+1 = 28 steps, over 24
});

test("approveSteps: approve=1, approve and don't ask again=2, reject=esc", () => {
  assert.deepEqual(approveSteps("approve"), [{ key: "1" }]);
  assert.deepEqual(approveSteps("always"), [{ key: "2" }]);
  assert.deepEqual(approveSteps("deny"), [{ key: "esc" }]);
  assert.equal(approveSteps("x"), null);
});

test("pollDelayMs: 300ms for the first 3 s, then 700ms", () => {
  assert.equal(pollDelayMs(0), 300);
  assert.equal(pollDelayMs(2999), 300);
  assert.equal(pollDelayMs(3000), 700);
  assert.equal(pollDelayMs(20000), 700);
});

const I = (role, text, extra = {}) => ({ role, text, ts: "2026-10-19T10:00:00Z", ...extra });

test("mergeItems: new first page overlaps old items -> keep the earlier ones, append the new", () => {
  const old = [I("user", "a"), I("assistant", "b"), I("user", "c")];
  const fresh = [I("assistant", "b"), I("user", "c"), I("assistant", "d")];
  const r = mergeItems(old, fresh);
  assert.deepEqual(r.items.map((x) => x.text), ["a", "b", "c", "d"]);
  assert.equal(r.reset, false);
});

test("mergeItems: old ask became answered -> replace with new data", () => {
  const ask = (answered) => I("ask", "q?", { toolUseId: "t1", answered });
  const old = [I("user", "a"), ask(false)];
  const r = mergeItems(old, [I("user", "a"), ask(true)]);
  assert.equal(r.items.length, 2);
  assert.equal(r.items[1].answered, true);
});

test("mergeItems: no overlap at all (more than a page added) -> new page wins and reset", () => {
  const r = mergeItems([I("user", "a")], [I("user", "x"), I("user", "y")]);
  assert.deepEqual(r.items.map((x) => x.text), ["x", "y"]);
  assert.equal(r.reset, true);
});

test("mergeItems: old empty or new empty", () => {
  assert.deepEqual(mergeItems([], [I("user", "a")]).items.map((x) => x.text), ["a"]);
  assert.equal(mergeItems([], [I("user", "a")]).reset, true);
  assert.deepEqual(mergeItems([I("user", "a")], []).items.map((x) => x.text), ["a"]);
});

test("approveTarget: several trailing pending picks the earliest and reports the remaining count", () => {
  const t = (p) => ({ role: "tool", pending: p });
  assert.deepEqual(approveTarget([{ role: "ai" }, t(false), t(true), t(true)]), { idx: 2, more: 1 });
  assert.deepEqual(approveTarget([{ role: "ai" }, t(true)]), { idx: 1, more: 0 });
  assert.deepEqual(approveTarget([t(true), t(false), t(true)]), { idx: 0, more: 1 });
  assert.equal(approveTarget([t(false), t(false)]), null);
  assert.equal(approveTarget([t(true), { role: "ai" }]), null); // last item is not a tool
  assert.equal(approveTarget([]), null);
});

test("liveAskIndex: only counts when the last item is an unanswered ask", () => {
  assert.equal(liveAskIndex([{ role: "ai" }, { role: "ask", answered: false }]), 1);
  assert.equal(liveAskIndex([{ role: "ask", answered: false }, { role: "tool", pending: true }]), -1);
  assert.equal(liveAskIndex([{ role: "ask", answered: false }, { role: "ai" }]), -1);
  assert.equal(liveAskIndex([{ role: "ask", answered: true }]), -1);
  assert.equal(liveAskIndex([]), -1);
});

test("pruneSent: keep only prompts that are still live", () => {
  const m = new Map([["a", {}], ["b", { partial: 2 }]]);
  pruneSent(m, new Set(["b"]));
  assert.deepEqual(Array.from(m.keys()), ["b"]);
});

test("approveDefs: ExitPlanMode uses matching labels, the rest stay approve/don't ask again/reject", () => {
  const plan = approveDefs("ExitPlanMode 计划");
  assert.deepEqual(plan.map((d) => d[1]), ["批准（自动接受编辑）", "批准（手动确认编辑）", "继续规划"]);
  assert.deepEqual(plan.map((d) => approveSteps(d[0])[0].key), ["1", "2", "esc"]);
  assert.deepEqual(approveDefs("Bash ls").map((d) => d[1]), ["批准", "批准且不再问", "拒绝"]);
});

test("nextPollAction: failed result carries sentSteps; partialFailText", () => {
  assert.deepEqual(nextPollAction(200, { status: "failed", error: "orca-failed", sentSteps: 2 }, 100),
    { status: "failed", error: "orca-failed", sentSteps: 2 });
  assert.deepEqual(nextPollAction(200, { status: "failed", error: "orca-failed" }, 100),
    { status: "failed", error: "orca-failed" });
  assert.equal(partialFailText(2), "已发到第 2 步后失败，请到 Orca 处理");
});

// ---------- off duty ----------
const O = (name, o = {}) => ({ name, sid: "sid-" + name, zone: "Docs", lastActive: 1000, offAt: 5000, transcript: "/t/" + name, ...o });
const osnap = (off, sessions = []) => ({ zones, sessions, offduty: off });

test("offduty groups into lanes by zone, sorted by offAt desc", () => {
  const lanes = buildLanes(osnap([O("a", { offAt: 100 }), O("b", { offAt: 300 }), O("c", { zone: "Web", offAt: 200 })], [S("x")]));
  assert.deepEqual(lanes.map((l) => l.code), ["Docs", "Web"]);
  assert.deepEqual(lanes[0].off.map((o) => o.name), ["b", "a"]);
  assert.deepEqual(lanes[1].off.map((o) => o.name), ["c"]);
});

test("lane without offduty has empty off list", () => {
  assert.deepEqual(buildLanes(snap([S("a")]))[0].off, []);
});

test("offduty with unknown or missing zone goes to unzoned lane, created if absent", () => {
  const lanes = buildLanes(osnap([O("a", { zone: "未分区" }), O("b", { zone: null }), O("c", { zone: "Nope" })], [S("x")]));
  assert.deepEqual(lanes.map((l) => l.code), ["Docs", null]);
  assert.equal(lanes[1].name, "未分区");
  assert.equal(lanes[1].cards.length, 0);
  assert.equal(lanes[1].off.length, 3);
});

test("offduty-only known zone gets its own lane; zone with nothing stays hidden", () => {
  const lanes = buildLanes(osnap([O("a", { zone: "Web" })]));
  assert.deepEqual(lanes.map((l) => l.code), ["Web"]);
  assert.deepEqual(lanes[0].counts, { waiting: 0, unread: 0, busy: 0 });
});

test("snapshot without offduty field still works", () => {
  assert.equal(buildLanes(snap([S("a")])).length, 1);
});

test("offLine / offHeader formatting", () => {
  assert.equal(offLine(1000, 1010), "刚下班");
  assert.equal(offLine(1000, 1000 + 600), "下班 10 分钟");
  assert.equal(offLine(1000, 1000 + 3 * 3600 + 5), "下班 3 小时");
  assert.equal(offLine(1000, 1000 + 86400), "下班 1 天");
  assert.equal(offLine(1000, 1000 + 3 * 86400 + 5), "下班 3 天");
  assert.equal(offHeader(1000, 1000 + 3 * 3600), "已下班 · 3 小时前");
  assert.equal(offHeader(1000, 1005), "已下班 · 刚刚");
  assert.equal(offHeader(1000, 1000 + 2 * 86400), "已下班 · 2 天前");
  assert.equal(offLine(0, 100), "下班时间未知");
  assert.equal(offHeader(undefined, 100), "已下班");
  assert.equal(offLine(2000, 1000), "刚下班"); // clock skew never yields a negative
});

test("offPollDelayMs: 0.3s for first 3s then 1s; WAKE_MAX_MS is 150s", () => {
  assert.equal(offPollDelayMs(0), 300);
  assert.equal(offPollDelayMs(2999), 300);
  assert.equal(offPollDelayMs(3000), 1000);
  assert.equal(offPollDelayMs(100000), 1000);
  assert.equal(WAKE_MAX_MS, 150000);
});

test("nextWakeAction maps request statuses", () => {
  assert.deepEqual(nextWakeAction(200, { status: "done" }, 5000), { status: "done" });
  assert.deepEqual(nextWakeAction(200, { status: "pending" }, 5000), { status: "pending" });
  assert.deepEqual(nextWakeAction(0, null, 5000), { status: "pending" });
  assert.deepEqual(nextWakeAction(200, { status: "wake-failed", message: "boom" }, 5000), { status: "failed", error: "wake-failed", message: "boom" });
  assert.deepEqual(nextWakeAction(200, { status: "failed", error: "wake-failed", message: "boom" }, 5000), { status: "failed", error: "wake-failed", message: "boom" });
  assert.equal(nextWakeAction(200, { status: "wake-timeout" }, 5000).error, "wake-timeout");
  assert.equal(nextWakeAction(200, { status: "not-offduty" }, 5000).error, "not-offduty");
  assert.equal(nextWakeAction(200, { status: "failed", error: "helper-restarted" }, 5000).error, "helper-restarted");
  assert.equal(nextWakeAction(400, null, 5000).error, "bad-request");
});

test("nextWakeAction: 404 grace, then 150s overall limit", () => {
  assert.equal(nextWakeAction(404, null, 3000).status, "pending");
  assert.equal(nextWakeAction(404, null, 9000).error, "unknown-status");
  assert.equal(nextWakeAction(200, { status: "pending" }, 149999).status, "pending");
  assert.equal(nextWakeAction(200, { status: "pending" }, 150000).error, "wake-timeout");
  assert.equal(nextWakeAction(0, null, 150000).error, "wake-timeout");
});

test("wakeFailText prefers message, else known text", () => {
  assert.equal(wakeFailText({ error: "wake-failed", message: "boom" }), "boom");
  assert.equal(wakeFailText({ error: "wake-timeout" }), "唤醒超时，可能停在 Mac 上的确认框");
  assert.equal(wakeFailText({ error: "wake-failed" }), "唤醒失败");
  assert.equal(wakeFailText({ error: "not-offduty" }), "它已经不在下班名单里了");
  assert.equal(wakeFailText({ error: "helper-timeout" }), "Mac 小帮手没响应");
  assert.equal(wakeFailText({ error: "weird" }), "唤醒失败");
});

test("findAwake finds a live session by name", () => {
  const sn = { sessions: [S("a", { name: "Lab-x" }), S("b", { name: "Web-y" })] };
  assert.equal(findAwake(sn, "Web-y").id, "b");
  assert.equal(findAwake(sn, "nope"), null);
  assert.equal(findAwake({}, "x"), null);
});

test("buildLanes exposes zone lead", () => {
  const l = buildLanes(snap([S("a")])).find((x) => x.code === "Docs");
  assert.equal(l.lead, "Docs-lead");
});

test("applyOptimistic: shows busy until newer non-waiting different state", () => {
  const p = () => new Map([["a", { at: 1000, baseGen: 50, orig: "waiting" }]]);
  const mk = (status, gen) => ({ generatedAt: gen, sessions: [S("a", { status, unread: true })] });
  // earlier snapshot still waiting: show busy, not unread
  let r = applyOptimistic(mk("waiting", 50), p(), 2000);
  assert.equal(r.snap.sessions[0].status, "busy");
  assert.equal(r.snap.sessions[0].unread, false);
  assert.equal(r.pending.size, 1);
  // later snapshot still waiting: stay busy
  assert.equal(applyOptimistic(mk("waiting", 51), p(), 2000).snap.sessions[0].status, "busy");
  // later snapshot idle (different and not waiting): drop the optimistic state
  r = applyOptimistic(mk("idle", 51), p(), 2000);
  assert.equal(r.snap.sessions[0].status, "idle");
  assert.equal(r.pending.size, 0);
  // earlier snapshot idle: not newer, stay busy
  assert.equal(applyOptimistic(mk("idle", 50), p(), 2000).snap.sessions[0].status, "busy");
  // 10 s elapsed: give up
  r = applyOptimistic(mk("waiting", 51), p(), 11000);
  assert.equal(r.snap.sessions[0].status, "waiting");
  assert.equal(r.pending.size, 0);
  // session not in the snapshot: discard
  assert.equal(applyOptimistic({ generatedAt: 60, sessions: [] }, p(), 2000).pending.size, 0);
  // the original snapshot is not mutated
  const orig = mk("waiting", 50);
  applyOptimistic(orig, p(), 2000);
  assert.equal(orig.sessions[0].status, "waiting");
});

test("applyOptimistic: busy starts at the moment of sending (timer starts at 0)", () => {
  const snap = { generatedAt: 50, sessions: [S("a", { status: "idle", since: 10 })] };
  const r = applyOptimistic(snap, new Map([["a", { at: 1000500, baseGen: 50, orig: "idle" }]]), 1001000);
  assert.equal(r.snap.sessions[0].since, 1000.5);
});

test("busyClock: m:ss under an hour, h:mm:ss after, never negative", () => {
  assert.equal(busyClock(100, 100), "0:00");
  assert.equal(busyClock(100, 165), "1:05");
  assert.equal(busyClock(0, 3599), "59:59");
  assert.equal(busyClock(0, 3600 + 62), "1:01:02");
  assert.equal(busyClock(200, 100), "0:00");
  assert.equal(busyClock(0, 0.9), "0:00");
});

// Multi-select: number keys toggle (cursor stays); without custom text press → to go to the next page; custom entry = toggle n+1, move cursor down n rows to that row, type, Tab to Next, Enter
// With multi-select questions the flow always ends on a review page, so a trailing 1 (Submit answers) is appended. Matches the Claude Code 2.1.x question UI.
test("buildAskSteps: single multi-select, only toggles options", () => {
  assert.deepEqual(buildAskSteps([Q(3, { multiSelect: true })], [{ multi: [3, 1] }]),
    [{ key: "1" }, { key: "3" }, { key: "right" }, { key: "1" }]);
});

test("buildAskSteps: custom entry inside multi-select", () => {
  assert.deepEqual(buildAskSteps([Q(3, { multiSelect: true })], [{ multi: [1], text: "紫" }]),
    [{ key: "1" }, { key: "4" }, { key: "down" }, { key: "down" }, { key: "down" }, { text: "紫" }, { key: "tab" }, { key: "enter" }, { key: "1" }]);
});

test("buildAskSteps: multi-select mixed with single-select", () => {
  assert.deepEqual(buildAskSteps([Q(3, { multiSelect: true }), Q(2)], [{ multi: [2] }, 2]),
    [{ key: "2" }, { key: "right" }, { key: "2" }, { key: "1" }]);
});

test("buildAskSteps: multi-select with nothing chosen or typed / out of range / duplicates returns null or dedupes", () => {
  const M = Q(3, { multiSelect: true });
  assert.equal(buildAskSteps([M], [{ multi: [] }]), null);
  assert.equal(buildAskSteps([M], [{ multi: [], text: "  " }]), null);
  assert.equal(buildAskSteps([M], [{ multi: [4] }]), null);
  assert.deepEqual(buildAskSteps([M], [{ multi: [2, 2] }]), [{ key: "2" }, { key: "right" }, { key: "1" }]);
  assert.deepEqual(buildAskSteps([M], [{ multi: [], text: "x" }]),
    [{ key: "4" }, { key: "down" }, { key: "down" }, { key: "down" }, { text: "x" }, { key: "tab" }, { key: "enter" }, { key: "1" }]);
});
