// Message actions (bubble menu, quote with sender, read receipts, recall, forward)
import { test } from "node:test";
import assert from "node:assert/strict";
import { quoteHead, quotePreview, buildQuoteText, parseQuoted, receiptOf, bubbleActs, menuPlace, forwardText, recallFailText, QUOTE_MAX, pressSwallow, PRESS_SWALLOW_MS } from "../logic.js";

test("quoteHead: \"name: text\" on a single line", () => {
  assert.equal(quoteHead("Dash-Mobile", "第一行\n第二行"), "Dash-Mobile: 第一行 第二行");
  assert.equal(quoteHead("", "原文"), "原文");
  assert.equal(quoteHead("我", "  "), "");
});

test("buildQuoteText follows the server rule: \"> name: text (cut at 300)\" + blank line + body", () => {
  assert.equal(buildQuoteText("我: 原文", " 正文 "), "> 我: 原文\n\n正文");
  assert.equal(buildQuoteText("", "正文"), "正文");
  assert.equal(buildQuoteText("我: q", ""), "> 我: q");
  const long = buildQuoteText("x".repeat(400), "y");
  assert.equal(QUOTE_MAX, 300);
  assert.equal(long, "> " + "x".repeat(300) + "…\n\ny");
});

test("quotePreview for the quote bar: single line, at most 120 chars (CSS clamps to two lines)", () => {
  assert.equal(quotePreview("a\nb"), "a b");
  assert.equal(quotePreview("x".repeat(130)), "x".repeat(120) + "…");
});

test("parseQuoted: recognizes quoted replies (including the guest [Guest] prefix); plain messages return null", () => {
  assert.deepEqual(parseQuoted("> 看板: 原文\n\n正文\n第二行"), { tag: "", quote: "看板: 原文", body: "正文\n第二行" });
  assert.deepEqual(parseQuoted("[Guest] > API: 原文\n\n好"), { tag: "[Guest] ", quote: "API: 原文", body: "好" });
  assert.equal(parseQuoted("普通消息"), null);
  assert.equal(parseQuoted("> 只有引用没有空行"), null);
  assert.equal(parseQuoted(null), null);
});

test("receiptOf: read / queued (grey double tick) / recalled from the record; optimistic bubble clock / undelivered", () => {
  assert.equal(receiptOf({ role: "user", read: true }), "read");
  assert.equal(receiptOf({ role: "user", read: false, queued: true }), "delivered");
  assert.equal(receiptOf({ role: "user", read: false, recalled: true }), "recalled");
  assert.equal(receiptOf({ role: "user" }), null); // legacy data has no read field: draw nothing
  assert.equal(receiptOf({ role: "assistant", read: true }), null);
  assert.equal(receiptOf({ pend: true }), "clock");
  assert.equal(receiptOf({ pend: true, failed: true }), "failed");
});

test("bubbleActs: recall offered for own messages (greyed once read); guests get no forward (can recall their own); off-duty gets no quote", () => {
  assert.deepEqual(bubbleActs({ who: "self" }), ["copy", "quote", "forward"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "read" }), ["copy", "quote", "forward", "recall"]); // greyed once read
  assert.deepEqual(bubbleActs({ who: "me", receipt: "delivered" }), ["copy", "quote", "forward", "recall"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "delivered", guest: true }), ["copy", "quote", "recall"]); // guests can recall their own
  assert.deepEqual(bubbleActs({ who: "self", detailOff: true }), ["copy", "forward"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "clock", pend: true }), ["copy", "quote", "forward"]);
});

test("menuPlace: prefers above the bubble, falls back to below, centered horizontally but kept inside bounds", () => {
  const box = { top: 50, bottom: 800, left: 0, right: 400 };
  // enough room above: arrow points down
  assert.deepEqual(menuPlace({ top: 300, bottom: 360, left: 100, right: 300 }, 200, 56, box),
    { x: 100, y: 300 - 8 - 56, below: false, ax: 100 });
  // not enough room above: place below
  assert.deepEqual(menuPlace({ top: 80, bottom: 140, left: 100, right: 300 }, 200, 56, box),
    { x: 100, y: 148, below: true, ax: 100 });
  // near the right edge: x is clamped into the box, arrow still points at the bubble center
  const r = menuPlace({ top: 300, bottom: 360, left: 300, right: 396 }, 200, 56, box);
  assert.equal(r.x, 400 - 8 - 200);
  assert.equal(r.ax, 348 - r.x);
  // very tall bubble, no room above or below: stick to the top of the viewport
  const t = menuPlace({ top: 10, bottom: 900, left: 0, right: 300 }, 200, 56, box);
  assert.equal(t.y, 50 + 8);
});

test("forwardText and recallFailText", () => {
  assert.equal(forwardText("Dash-Mobile", " 原文\n第二行 "), "[转发自 Dash-Mobile] 原文\n第二行");
  assert.ok(forwardText("x", "y".repeat(5000)).length <= 3900);
  assert.match(recallFailText("already-read"), /已经读/);
  assert.match(recallFailText("admin-queued"), /管理员有排队消息，暂不能撤回/);
  assert.equal(recallFailText("at-menu"), "会话在等你作答/批准，先在卡片里答完再撤回");
  assert.match(recallFailText("recall-uncertain"), /Orca/);
  assert.equal(recallFailText("helper-timeout"), "Mac 小帮手没响应");
});

test("pressSwallow: after a long-press menu, swallow only the click that immediately follows (iOS often sends no click after a long press, so the swallow flag must not wait for a later tap)", () => {
  assert.equal(pressSwallow({ fired: true, at: 1000 }, 1000 + 100), true);
  assert.equal(pressSwallow({ fired: true, at: 1000 }, 1000 + PRESS_SWALLOW_MS + 1), false);
  assert.equal(pressSwallow({ fired: false, at: 1000 }, 1001), false);
  assert.equal(pressSwallow(null, 1001), false);
});

test("sendText does not silently drop a message just because the previous one is still sending (st.sending)", async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  const body = src.slice(src.indexOf("function sendText()"), src.indexOf("const preCleared"));
  assert.ok(body.length > 100);
  assert.doesNotMatch(body, /st\.sending\)\s*return/);
  assert.match(body, /sendChain/);
});

// ===== Own messages that are read / recalled: the "recall" menu item is still shown but greyed =====
import { recallLock, recallLockToast } from "../logic.js";
import { readFileSync } from "node:fs";
test("bubbleActs: read messages still get the recall item; recalled ones do not; same rule for guests", () => {
  assert.deepEqual(bubbleActs({ who: "me", receipt: "read" }), ["copy", "quote", "forward", "recall"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "recalled" }), ["copy", "quote", "forward"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "read", guest: true }), ["copy", "quote", "recall"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "delivered" }), ["copy", "quote", "forward", "recall"]);
});
test("recallLock: depends on the time window only, being read does not grey it; toast text", () => {
  const ts = new Date(1000 * 1000).toISOString();
  assert.equal(recallLock("read", ts, 1030), false);
  assert.equal(recallLock("delivered", ts, 1030), false);
  assert.equal(recallLockToast(), "超过 2 分钟，撤不回了");
});
test("app/css: greyed item has opacity .4, tapping shows a toast", () => {
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  assert.match(css, /\.bm-it\.bm-off\s*\{[^}]*opacity:\s*\.4/);
  assert.match(app, /recallLock\(/);
  assert.match(app, /recallLockToast\(\)/);
});

// ===== Copy the selected text inside a bubble =====
test("bubbleActs: on wide screens with a selection the first item becomes \"copy selection\"; on phones an extra \"select text\" item; without wide nothing changes", () => {
  assert.deepEqual(bubbleActs({ who: "self", wide: true, sel: true }), ["copysel", "quote", "forward"]);
  assert.deepEqual(bubbleActs({ who: "self", wide: true, sel: false }), ["copy", "quote", "forward"]);
  assert.deepEqual(bubbleActs({ who: "self", wide: false }), ["copy", "select", "quote", "forward"]);
  assert.deepEqual(bubbleActs({ who: "self", wide: false, detailOff: true }), ["copy", "select", "forward"]);
  assert.deepEqual(bubbleActs({ who: "self" }), ["copy", "quote", "forward"]);
});
test("source: wide-screen body text is draggable-selectable, copy selection, select-text page, mouse moving 4px cancels long press", () => {
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  const tail = css.slice(css.lastIndexOf("/* =====", css.indexOf(".sel-tx, .sel-tx")));
  assert.match(tail, /\.m[^{]*\{[^}]*user-select:\s*text/);
  assert.match(tail, /\.md-cp[^{]*\{[^}]*user-select:\s*none/);
  assert.match(tail, /\.sel-tx[^{]*\{[^}]*user-select:\s*text/);
  assert.match(tail, /-webkit-touch-callout:\s*default/);
  assert.match(app, /BM_LABEL = new Proxy\(\{\}, \{ get: \(_, k\) => t\("bm\." \+ String\(k\)\) \}\)/); // looks up bm.<item>
  assert.equal(t("bm.copysel"), "复制所选");
  assert.match(app, /getSelection\(\)/);
  assert.match(app, /openSelectText\(/);
  assert.match(app, /openFs\("seltx", t\("sel.title"\)\)/);
  assert.match(app, /t\("sel\.copyAll"\)/);
  assert.match(app, /pointerType === "mouse" \? 4 : 10/);
});

// A normal admin send that lands on an ask/approve menu gets a 409 at-menu from the server: show a toast (input text is kept, the optimistic bubble leaves no red !)
import { failReason as failReasonFn, dropOnFail as dropOnFailFn } from "../logic.js";
import { setLang, t } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese
test("at-menu toast text; this kind of failure removes the optimistic bubble", () => {
  assert.equal(failReasonFn("at-menu"), "会话在等你作答/批准，请在上面的卡片里答，或先在 Orca 里处理");
  assert.equal(dropOnFailFn("at-menu"), true);
  assert.equal(dropOnFailFn("session-waiting"), true);
  assert.equal(dropOnFailFn("helper-timeout"), false);
  assert.equal(dropOnFailFn(""), false);
});
