// Sending does not stall and bubbles do not jump: a pending bubble looks like a real record (not faded), sending appends exactly one item incrementally, and time dividers follow the same rules as real records
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
import { pendNeedsStamp, lastStampSec, chatPlan, STAMP_GAP_SEC } from "../logic.js";
setLang("hans");

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");
const css = rd("style.css");
const fnBody = (name, n = 3000) => { const i = app.indexOf("function " + name); assert.ok(i >= 0, "missing " + name); return app.slice(i, i + n); };
const iso = (sec) => new Date(sec * 1000).toISOString();

test("pend bubbles are not faded (identical to a real \"me\" record)", () => {
  assert.doesNotMatch(css, /\.m\.me\.pend\s*\{[^}]*opacity/);
  assert.doesNotMatch(css, /\.m\.me\.pend\.rc-fail\s*\{[^}]*opacity/);
});

test("pendNeedsStamp: same rule as chatPlan (empty record or a gap over 5 minutes needs a time divider, otherwise not)", () => {
  const T = 1_800_000_000;
  assert.equal(pendNeedsStamp([], T), true);
  const items = [{ role: "assistant", ts: iso(T - 60), text: "a" }];
  assert.equal(pendNeedsStamp(items, T), false);
  assert.equal(pendNeedsStamp(items, T - 60 + STAMP_GAP_SEC), false); // exactly 300 seconds: no divider
  assert.equal(pendNeedsStamp(items, T + STAMP_GAP_SEC + 120), true);
  // the previous item is another pending bubble: it decides
  assert.equal(pendNeedsStamp(items, T + 1000, T + 900), false);
  assert.equal(pendNeedsStamp(items, T + 1000, T + 600), true);
});

test("pendNeedsStamp and chatPlan agree on the same message", () => {
  const T = 1_800_000_000;
  for (const gap of [10, 299, 301, 4000]) {
    const base = [{ role: "assistant", ts: iso(T), text: "a" }];
    const real = base.concat([{ role: "user", ts: iso(T + gap), text: "q" }]);
    const hasTime = chatPlan(real, {}).filter((b) => b.t === "time").length === 2;
    assert.equal(pendNeedsStamp(base, T + gap), hasTime, "gap " + gap);
  }
});

test("lastStampSec: skips task notices and subagent reports; tool entries count", () => {
  const T = 1_800_000_000;
  const items = [
    { role: "assistant", ts: iso(T - 500), text: "a" },
    { role: "tool", ts: iso(T - 100), name: "Bash" },
    { role: "agent", notice: true, ts: iso(T), task: "x" },
    { role: "agent", ts: iso(T + 50), text: "report" },
  ];
  assert.equal(Math.round(lastStampSec(items)), T - 100);
  assert.equal(lastStampSec([]), 0);
});

test("drawing a single pending bubble is extracted into pendFrag, shared by renderItems and the incremental append", () => {
  assert.match(app, /function pendFrag\(/);
  const ri = app.slice(app.indexOf("function renderItems"), app.indexOf("function pendFrag"));
  assert.match(ri, /pendFrag\(/);
  assert.doesNotMatch(ri, /h\("div", "m me pend"/); // not duplicated here
  assert.match(fnBody("pendFrag"), /h\("div", "m me pend"/);
  assert.match(fnBody("pendFrag"), /pendNeedsStamp\(/);
});

test("sendText / resendPend / attachment send: no full redraw, use appendPend", () => {
  assert.match(app, /function appendPend\(/);
  const ap = fnBody("appendPend");
  assert.match(ap, /ph-bub/); // inserted before the reply placeholder when there is one
  assert.match(ap, /st\.sig = listSig\(/);
  assert.match(ap, /scrollTop = msgs\.scrollHeight|scrollTop = .*scrollHeight/);
  assert.match(ap, /renderList\(s, "bottom"\)/); // falls back when incremental append is not possible
  assert.match(fnBody("sendText"), /appendPend\(s, pend\)/);
  assert.doesNotMatch(fnBody("sendText"), /renderList\(s, "bottom"\)/);
  assert.match(fnBody("resendPend"), /appendPend\(s, pend\)/);
  assert.doesNotMatch(fnBody("resendPend"), /renderList\(s, "bottom"\)/);
  assert.match(fnBody("sendWithTray", 4000), /appendPend\(s, pend\)/);
});

test("the sw version matches the shell", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142"/);
  assert.match(rd("index.html"), /name="zbs-shell" content="v142"/);
});
