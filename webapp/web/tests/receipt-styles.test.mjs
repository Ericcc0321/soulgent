// Receipt styling for my sent messages: clock / bright-yellow single tick / white 60% double tick / red ! outside the bubble's left side / dark-backed tick on image messages; tapping a tick only shows a hint
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { receiptOf, rcTipText } from "../logic.js";
import { setLang, t as tr } from "../i18n.js";
setLang("hans");

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const i18n = read("../i18n.js");
// Collect all declaration bodies of a selector (exact full-string match)
function rule(sel) {
  const re = new RegExp("(?:^|\\})\\s*" + sel.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}", "gm");
  let m, all = null;
  while ((m = re.exec(css))) all = (all || "") + m[1] + ";"; // declarations of the same selector in several places are merged
  assert.ok(all !== null, "rule not found: " + sel);
  return all;
}
function fnBody(name, n = 1400) { const i = app.indexOf("function " + name); assert.ok(i >= 0, name); return app.slice(i, i + n); }

test("receiptOf semantics: pend clock/failed, delivered/read from the record", () => {
  assert.equal(receiptOf({ pend: true }), "clock");
  assert.equal(receiptOf({ pend: true, failed: true }), "failed");
  assert.equal(receiptOf({ role: "user", read: false }), "delivered");
  assert.equal(receiptOf({ role: "user", read: true }), "read");
});

test("single tick bright yellow #ffd60a (sent and delivered share color and shape), double tick white 60%", () => {
  assert.match(rule(".rc-mk.rc-sent .rc-ic, .rc-mk.rc-delivered .rc-ic"), /color:\s*#ffd60a/i);
  assert.match(rule(".rc-mk.rc-read .rc-ic"), /color:\s*rgba\(255, 255, 255, \.6\)/);
  assert.match(app, /sent: RC_CHECK1,\s*\n\s*delivered: RC_CHECK1,/);
});

test("ticks scaled up 1.25x (20x15, double tick 25x15), stroke width 1.8", () => {
  const ic = rule(".rc-mk .rc-ic");
  assert.match(ic, /width:\s*20px/);
  assert.match(ic, /height:\s*15px/);
  assert.match(rule(".rc-mk.rc-read .rc-ic"), /width:\s*25px/);
  const a = app.slice(app.indexOf("const RC_CHECK1"), app.indexOf("const RC_LABEL"));
  assert.equal((a.match(/stroke-width="1\.8"/g) || []).length, 2); // single tick, double tick
  assert.doesNotMatch(a, /(sent|delivered|read): '[^']*stroke-width="1\.4"/);
});

test("red ! sits outside the bubble on the left, vertically centered; white ! on a red circle", () => {
  const r = rule(".rc-mk.rc-failed");
  assert.match(r, /position:\s*absolute/);
  assert.match(r, /right:\s*100%/);
  assert.match(r, /top:\s*50%/);
  assert.match(r, /margin:\s*-11px/); // half of the 22 height
  assert.match(r, /background:\s*#fa5151/i);
  assert.match(r, /border-radius:\s*50%/);
  assert.match(app, /failed: '<svg viewBox="0 0 16 16"><path d="M8 3\.6v5\.2" stroke="#fff"/);
});

test("tapping the red ! still opens \"resend / delete\" (reuses failMenu)", () => {
  const m = fnBody("rcMark(");
  assert.match(m, /rc === "failed"\) \{ failMenu\(el, meta\.pend\); return; \}/);
  assert.match(fnBody("failMenu(", 700), /bm\.resend[\s\S]*bm\.delete/);
});

test("tapping a tick only shows a hint: delivered does not ask for recall confirmation, recall is only in the long-press menu", () => {
  const m = fnBody("rcMark(");
  assert.doesNotMatch(m, /confirmRecall|canRecall|recallLock/);
  assert.match(m, /rcTip\(ic, rcTipText\(rc\)\)/);
  assert.match(app, /k === "recall" && recallLock\(meta\.receipt/); // recall in the long-press menu is still there
  assert.equal(rcTipText("delivered"), "已送到，它忙完会读");
  assert.equal(rcTipText("sent"), "已送到，它忙完会读");
  assert.equal(rcTipText("read"), "已读");
  assert.match(i18n, /"rcl\.delivered": \["Delivered — it'll read when free", "已送到，它忙完会读", "已送到，它忙完會讀"\]/);
  assert.equal(tr("rcl.delivered"), "已送到，它忙完会读");
  assert.equal(tr("rcl.read"), "已读");
});

test("attachment-only (image) bubble: tick drawn at the bottom-right on a rgba(0,0,0,.45) rounded dark background; the red ! gets no background", () => {
  const r = rule(".m.at-only > .rc-mk:not(.rc-failed)");
  assert.match(r, /position:\s*absolute/);
  assert.match(r, /right:\s*10px/);
  assert.match(r, /bottom:\s*10px/);
  assert.match(r, /background:\s*rgba\(0, 0, 0, \.45\)/);
  assert.match(r, /border-radius:\s*10px/);
  assert.match(rule(".m.at-only > .rc-mk:not(.rc-failed) .rc-ic"), /position:\s*relative/);
});
