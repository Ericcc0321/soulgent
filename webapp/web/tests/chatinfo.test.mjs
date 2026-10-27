// Pure functions for the chat info page / in-session search / pre-window-switch history
import { test } from "node:test";
import assert from "node:assert/strict";
import { chTime, chSepText, chQuery, chOlderPlan, chSameText, chHitIndex, chWho } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

// timezone independent: built from local time
const loc = (y, mo, d, h, mi) => new Date(y, mo - 1, d, h, mi).toISOString();

test("chTime: today shows time only, this year shows month and day, earlier years include the year", () => {
  const now = new Date(2026, 9, 22, 15, 0).getTime() / 1000;
  assert.equal(chTime(loc(2026, 10, 22, 9, 5), now), "09:05");
  assert.equal(chTime(loc(2026, 10, 21, 14, 38), now), "10月21日 14:38");
  assert.equal(chTime(loc(2025, 12, 31, 23, 1), now), "2025年12月31日 23:01");
  assert.equal(chTime("", now), "");
  assert.equal(chTime("bad", now), "");
});

test("chSepText: window switch / compaction continuation / guessed", () => {
  const now = new Date(2026, 9, 22, 15, 0).getTime() / 1000;
  assert.equal(chSepText({ at: loc(2026, 10, 21, 14, 38), via: "window" }, now), "—— 换窗前（10月21日 14:38）——");
  assert.equal(chSepText({ at: loc(2026, 10, 22, 9, 0), via: "continued" }, now), "—— 压缩续接前（09:00）——");
  assert.equal(chSepText({ at: "", via: "guess" }, now), "—— 换窗前（推测）——");
  assert.equal(chSepText({ at: loc(2026, 10, 22, 9, 0), via: "guess" }, now), "—— 换窗前（09:00，推测）——");
});

test("chQuery: before / from / around build the query string", () => {
  assert.equal(chQuery(null, null), "");
  assert.equal(chQuery(120, null), "?before=120");
  assert.equal(chQuery(null, "a-b"), "?from=a-b");
  assert.equal(chQuery(5, "a-b"), "?before=5&from=a-b");
  assert.equal(chQuery(null, "a-b", 77), "?from=a-b&around=77");
});

test("chOlderPlan: page through the current window first; then the previous window; then the one before it; at most to the end of the chain", () => {
  const wins = [{ sid: "p1", at: "x", via: "window" }, { sid: "p2", at: "y", via: "backfill" }];
  assert.deepEqual(chOlderPlan({ segs: [], base: null }, 100, wins), { kind: "base" });
  assert.deepEqual(chOlderPlan({ segs: [], base: null }, null, null), { kind: "end" });
  assert.deepEqual(chOlderPlan({ segs: [], base: null }, null, []), { kind: "end" });
  assert.deepEqual(chOlderPlan({ segs: [], base: null }, null, wins), { kind: "win", win: wins[0] });
  assert.deepEqual(chOlderPlan({ segs: [{ sid: "p1", next: 50 }], base: null }, null, wins), { kind: "seg", sid: "p1", before: 50 });
  assert.deepEqual(chOlderPlan({ segs: [{ sid: "p1", next: null }], base: null }, null, wins), { kind: "win", win: wins[1] });
  assert.deepEqual(chOlderPlan({ segs: [{ sid: "p1", next: null }, { sid: "p2", next: null }], base: null }, null, wins), { kind: "end" });
  // jumped to previous window p1 for a search result (base = p1): after p1 comes p2
  assert.deepEqual(chOlderPlan({ segs: [], base: "p1" }, null, wins), { kind: "win", win: wins[1] });
  assert.deepEqual(chOlderPlan({ segs: [], base: "p2" }, null, wins), { kind: "end" });
  // lineage not fetched yet (null): treat as the earliest
  assert.deepEqual(chOlderPlan({ segs: [], base: null }, null, undefined), { kind: "end" });
});

test("chSameText: compares the text shown in the bubble (prefix removed) with the original record", () => {
  assert.ok(chSameText("[Guest] 你好 世界", "你好 世界"));
  assert.ok(chSameText("来自 Web：明天 开会", "明天 开会"));
  assert.ok(!chSameText("完全不同", "你好"));
  assert.ok(!chSameText("abc", ""));
});

test("chHitIndex: position of the hit among loaded items (matched by role+ts+original text)", () => {
  const items = [
    { role: "user", ts: "t1", text: "一" },
    { role: "assistant", ts: "t2", text: "二 关键词" },
    { role: "tool", ts: "t2", text: "Bash" },
    { role: "assistant", ts: "t3", text: "二 关键词" },
  ];
  assert.equal(chHitIndex(items, { role: "assistant", ts: "t3", snippet: "二 关键词" }), 3);
  assert.equal(chHitIndex(items, { role: "assistant", ts: "t2", snippet: "…二 关键词" }), 1);
  assert.equal(chHitIndex(items, { role: "user", ts: "t9", snippet: "一" }), -1);
});

test("chWho: speaker name of a search result", () => {
  const s = { name: "Docs-Dash-Mobile", plate: "Dash-Mobile" };
  assert.equal(chWho({ role: "assistant" }, s, false), "Dash-Mobile");
  assert.equal(chWho({ role: "user" }, s, false), "我");
  assert.equal(chWho({ role: "peer", from: "Web-API" }, s, false), "Web-API");
  assert.equal(chWho({ role: "peer", from: "" }, s, false), "会话间");
});
