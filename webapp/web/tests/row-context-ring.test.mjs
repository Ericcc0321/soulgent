// Context ring on message-list rows: the logic lives in logic.js, app.js only draws it, styles are in style.css
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const css = rd("style.css");
const app = rd("app.js");

// ---------- 1. rowCtx: pure function ----------
// rowCtx(s, now) includes the staleness check (metaStale); a fresh meta.at is supplied here
const R = (pct) => L.rowCtx({ meta: { ctxPct: pct, at: 1000 } }, 1000);
test("rowCtx: a ring only when meta.ctxPct is a number, levels match ctxLevel (<50 ok / 50-69 warn / >=70 bad)", () => {
  assert.equal(typeof L.rowCtx, "function");
  assert.deepEqual(R(9), { pct: 9, lv: "ok", text: "9%", stale: false });
  assert.deepEqual(R(49), { pct: 49, lv: "ok", text: "49%", stale: false });
  assert.deepEqual(R(50), { pct: 50, lv: "warn", text: "50%", stale: false });
  assert.deepEqual(R(69), { pct: 69, lv: "warn", text: "69%", stale: false });
  assert.deepEqual(R(70), { pct: 70, lv: "bad", text: "70%", stale: false });
  assert.deepEqual(R(100), { pct: 100, lv: "bad", text: "100%", stale: false });
});
test("rowCtx: no ring without meta, with a non-numeric ctxPct, or for resting rows", () => {
  for (const s of [null, undefined, {}, { meta: null }, { meta: {} }, { meta: { ctxPct: null } }, { meta: { ctxPct: "58" } },
    { meta: { ctxPct: NaN } }, { meta: { ctxPct: Infinity } }, { meta: "x" }, { meta: { ctxPct: 58 }, rest: true }]) {
    assert.equal(L.rowCtx(s), null, JSON.stringify(s));
  }
});
test("rowCtx: rounded and clamped to 0-100", () => {
  assert.equal(R(57.6).pct, 58);
  assert.equal(R(-3).pct, 0);
  assert.equal(R(130).pct, 100);
});
test("guest snapshot passes meta through: guestSnapshot keeps meta, rowCtx still gives a ring; the server guest whitelist includes meta", () => {
  const raw = { sessions: [{ id: "a", name: "Web-x", status: "idle", since: 1, meta: { ctxPct: 61, at: 1000 } }] };
  const g = L.guestSnapshot(raw, 0, null, null);
  assert.equal(L.rowCtx(g.snap.sessions[0], 1000).lv, "warn");
  assert.match(readFileSync(new URL("../../api/server.py", import.meta.url), "utf8"), /GUEST_SESSION_FIELDS = \([^)]*"meta"/s);
});

// ---------- 2. app.js only draws ----------
test("app.js: fillMsgLi uses rowCtx, the ring uses ringSvg(...,15,2), nodes hang on li._p for incremental updates", () => {
  assert.match(app, /rowCtx/);
  assert.match(app, /ringSvg\([^)]*,\s*15,\s*2\)/);
  const i = app.indexOf("function fillMsgLi");
  const body = app.slice(i, app.indexOf("\n}\n", i));
  assert.match(body, /rowCtx\(s, nowSec\(\)\)/);
  assert.match(app, /"cr-cx /); // class cr-cx + level
});
test("app.js: the ring update runs before the second-line sig early return (a changed number does not rebuild the row)", () => {
  const i = app.indexOf("function fillMsgLi");
  const body = app.slice(i, app.indexOf("\n}\n", i));
  const a = body.search(/fillCtx\(/);
  const b = body.indexOf("if (li._sig === sig) return;");
  assert.ok(a > 0 && b > 0 && a < b, "fillCtx must come before the sig early return");
});

// ---------- 3. styles ----------
test("style.css: .cr-cx number is 3ch wide, three level colors, ring stroke overrides .w/.d .rg-f", () => {
  assert.match(css, /\.cr-cx b\s*\{[^}]*min-width:\s*3ch/);
  assert.match(css, /\.cr-cx b\s*\{[^}]*text-align:\s*right/);
  assert.match(css, /\.cr-cx\.warn\s*\{[^}]*#ff9a1f/);
  assert.match(css, /\.cr-cx\.bad\s*\{[^}]*#fa5151/);
  assert.match(css, /\.cr-cx\.ok\b[^{]*\{[^}]*opacity/);
  assert.match(css, /\.cr-row \.cr-cx \.rg-f\s*\{[^}]*stroke:\s*var\(--cx\)/);
  assert.match(css, /\.cr-cx\s*\{[^}]*flex:\s*none/);
});
test("the quota ring warning color is unified to #ff9a1f (--rg-w)", () => {
  assert.match(css, /--rg-w:\s*#ff9a1f/);
  assert.doesNotMatch(css, /#ffc53d/);
});

// ---------- 4. version ----------
test("sw and shell version", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
