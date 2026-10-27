import test from "node:test";
import assert from "node:assert/strict";
import { diagDesc, throttleStep, diagCap } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

test("diagDesc: tag, id, class trimmed to 40, placeholder", () => {
  assert.equal(diagDesc("TEXTAREA", "reply", "a  b", "说点什么"), "textarea#reply.a.b[说点什么]");
  assert.equal(diagDesc("DIV", "", "", ""), "div");
  assert.equal(diagDesc("", null, "x".repeat(60)), "?." + "x".repeat(40));
});

test("throttleStep: first now, then later once, skip while pending", () => {
  let s = { last: -1e9, pending: false };
  let r = throttleStep(s, 1000, 100);
  assert.equal(r.act, "now"); s = r.s;
  r = throttleStep(s, 1030, 100);
  assert.equal(r.act, "later"); assert.equal(r.delay, 70); s = r.s;
  assert.equal(throttleStep(s, 1060, 100).act, "skip");
  s = { last: 1100, pending: false }; // the catch-up record already landed at 1100
  assert.equal(throttleStep(s, 1250, 100).act, "now");
});

test("throttleStep: continuous 16ms burst still logs about every 100ms", () => {
  let s = { last: -1e9, pending: false };
  let timer = null;
  const fired = [];
  for (let t = 0; t <= 1000; t += 16) {
    if (timer != null && t >= timer) { fired.push(timer); s = { last: timer, pending: false }; timer = null; }
    const r = throttleStep(s, t, 100);
    s = r.s;
    if (r.act === "now") fired.push(t);
    else if (r.act === "later") timer = t + r.delay;
  }
  assert.ok(fired.length >= 9 && fired.length <= 12, String(fired));
});

test("diagCap drops oldest", () => {
  const b = [1, 2, 3, 4, 5];
  diagCap(b, 3);
  assert.deepEqual(b, [3, 4, 5]);
  assert.deepEqual(diagCap([1], 3), [1]);
});
