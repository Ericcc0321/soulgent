// Recall uses a 2-minute time window; top bar dispatch / queued / done display; list row "dispatching (N)"
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { recallLock, recallLockToast, RECALL_WINDOW_SEC, recallFailText, recallDoneText, headStat, chatRow } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const iso = (sec) => new Date(sec * 1000).toISOString();

test("recallLock: tappable within 2 minutes, still tappable at exactly 120 s, greyed at 121 s", () => {
  assert.equal(RECALL_WINDOW_SEC, 120);
  const t = 1_700_000_000;
  assert.equal(recallLock("delivered", iso(t), t + 1), false);
  assert.equal(recallLock("read", iso(t), t + 119), false);
  assert.equal(recallLock("read", iso(t), t + 120), false);
  assert.equal(recallLock("read", iso(t), t + 121), true);
  assert.equal(recallLock("delivered", iso(t), t + 121), true); // queued messages follow the same time rule
});

test("recallLock: old data without ts and a bad ts count as timed out; millisecond-precision ts works as usual", () => {
  assert.equal(recallLock("read", "", 100), true);
  assert.equal(recallLock("read", undefined, 100), true);
  assert.equal(recallLock("read", "t", 100), true);
  assert.equal(recallLock("delivered", "2026-10-23T03:00:00.250Z", Date.parse("2026-10-23T03:01:00Z") / 1000), false);
  assert.equal(recallLockToast(), "超过 2 分钟，撤不回了");
});

test("recallFailText: code too-old, plus the existing codes", () => {
  assert.equal(recallFailText("too-old"), "超过 2 分钟，撤不回了");
  assert.equal(recallFailText("at-menu"), "会话在等你作答/批准，先在卡片里答完再撤回");
});

test("recallDoneText: message depends on the server mode", () => {
  assert.equal(recallDoneText("interrupted"), "已打断，原文已放回输入框");
  assert.equal(recallDoneText("answered"), "它已答完，原文已放回");
  assert.equal(recallDoneText("processing"), "它正在处理这条，后面的还在排队");
  assert.equal(recallDoneText("processing", true), "它正在处理这条，原文已放回");
  assert.equal(recallDoneText(undefined), "已撤回，原文放回输入框");
});

test("app: bubble meta carries ts, menu and status marker both use recallLock(receipt, ts, now); doRecall honors mode", () => {
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  assert.match(app, /receipt: rc, raw: it\.text \|\| "", ts: it\.ts/);
  assert.equal((app.match(/recallLock\(meta\.receipt, meta\.ts, nowSec\(\)\)/g) || []).length, 3); // long-press menu, attachment menu, doRecall fallback (tapping the status tick does not recall)
  assert.match(app, /recallDoneText\(/);
});

test("headStat: only the helper capsule 'SA N · BG M' remains, no queued or done-N-minutes", () => {
  assert.deepEqual(headStat({ status: "busy", since: 1, helpers: 3 }), { top: "SA 3", bottom: "" });
  assert.deepEqual(headStat({ status: "busy", since: 1 }), { top: "", bottom: "" });
  assert.deepEqual(headStat(null), { top: "", bottom: "" });
});

test("chatRow: while sub-agents run it shows 'dispatching (N)' in the same g class (typing dot and alignment as usual)", () => {
  const z = [{ code: "Lab", name: "个人", color: "#999" }];
  const s = { id: "a", name: "Lab-a", zone: "Lab", status: "busy", since: 1, summary: "x" };
  assert.deepEqual(chatRow({ ...s, helpers: 3 }, z, 10).tag, { cls: "g", text: "正在派活(3)" });
  assert.deepEqual(chatRow(s, z, 10).tag, { cls: "g", text: "正在干活" });
  assert.deepEqual(chatRow({ ...s, helpers: 0 }, z, 10).tag, { cls: "g", text: "正在干活" });
});

test("shell: the top bar has #d-stat, app uses headStat, the first detail page still records queued", () => {
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  assert.match(html, /id="d-stat"/);
  assert.match(app, /headStat\(/);
  assert.match(app, /data\.queued/);
  assert.match(css, /\.d-stat\s*\{[^}]*flex:\s*none/);
});
