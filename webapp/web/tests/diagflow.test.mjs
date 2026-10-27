// Diagnostic log: notification tap -> transition / insert / scroll events along the path into the chat page
// These predicate functions live in app.js, so they are sliced out of the source by function name and run on their own
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const app = read("../app.js");
const sw = read("../sw.js");

// Slice a top-level function out of the source (by brace matching) and return its body
function pick(name) {
  const i = app.indexOf("\nfunction " + name + "(");
  assert.ok(i >= 0, "function " + name + " not found in app.js");
  let j = app.indexOf("{", i), depth = 0;
  for (; j < app.length; j++) {
    if (app[j] === "{") depth++;
    else if (app[j] === "}" && --depth === 0) break;
  }
  return new Function("return (" + app.slice(i + 1, j + 1) + ")")();
}
const body = (name) => {
  const i = app.indexOf("\nfunction " + name + "(");
  return app.slice(i, app.indexOf("\n}\n", i));
};

test("diagScrollJump: a change over 40px while the user is not scrolling counts as a jump", () => {
  const f = pick("diagScrollJump");
  assert.deepEqual(f(100, 300, false), { from: 100, to: 300, d: 200 });
  assert.deepEqual(f(300, 100, false), { from: 300, to: 100, d: -200 });
  assert.equal(f(100, 140, false), null);   // exactly 40 does not count
  assert.equal(f(100, 141.4, true), null);   // the user is scrolling
  assert.deepEqual(f(100.4, 141.6, false), { from: 100, to: 142, d: 42 });
});

test("diagUserBusy: a touch / scroll within 200ms counts as the user scrolling", () => {
  const f = pick("diagUserBusy");
  assert.equal(f(1000, 900, 0), true);
  assert.equal(f(1000, 0, 850), true);
  assert.equal(f(1000, 700, 790), false);
  assert.equal(f(1000, 0, 0), false);
});

test("diagPhStep: logs only when a placeholder bubble appears / disappears", () => {
  const f = pick("diagPhStep");
  assert.equal(f(false, true), "show");
  assert.equal(f(true, false), "gone");
  assert.equal(f(true, true), null);
  assert.equal(f(false, false), null);
});

test("diagFigDiff: newly appeared, changed anchor, gone from the plan", () => {
  const f = pick("diagFigDiff");
  const m = (o) => new Map(Object.entries(o).map(([k, v]) => [k, { a: v.a, ids: new Map(Object.entries(v.ids)) }]));
  const prev = m({ k1: { a: "ph", ids: { t1: "working", t2: "working" } }, k2: { a: "m3", ids: { t9: "done" } } });
  const cur = m({ k1: { a: "m5", ids: { t1: "done", t3: "working" } } });
  const ev = f(prev, cur);
  assert.deepEqual(ev, [
    { ev: "reanchor", key: "k1", from: "ph", to: "m5" },
    { ev: "rise", key: "k1", tu: "t3", state: "working" },
    { ev: "destroy", key: "k1", tu: "t2", why: "gone" },
    { ev: "destroy", key: "k2", tu: "t9", why: "group-gone" },
  ]);
  assert.deepEqual(f(new Map(), new Map()), []);
  assert.deepEqual(f(cur, cur), []);
});

test("diagFold: events of the same kind merge into one, counts add up, data comes from the last one", () => {
  const f = pick("diagFold");
  assert.deepEqual(f([{ ev: "rise", key: "a", tu: "1" }, { ev: "rise", key: "a", tu: "2" }, { ev: "destroy", key: "b", tu: "3" }]), [
    { ev: "rise", key: "a", tu: "2", cnt: 2 },
    { ev: "destroy", key: "b", tu: "3", cnt: 1 },
  ]);
});

test("zero overhead when off: the diagnostic functions check D on entry, and listeners are registered only in diagStart", () => {
  assert.match(body("diag"), /^\nfunction diag\(k, data\) \{\n  if \(!D\) return;/);
  for (const n of ["diagRender", "diagFig", "diagOpenFrom"]) assert.match(body(n), new RegExp("^\\nfunction " + n + "\\([^)]*\\) \\{\\n  if \\(!D\\) return;"), n);
  // the user-is-scrolling timestamp is updated only in diagStart's listeners
  assert.match(body("diagStart"), /D\.touchAt = /);
  assert.match(body("diagStart"), /D\.scrollAt = /);
  assert.doesNotMatch(app.replace(body("diagStart"), ""), /D\.touchAt = |D\.scrollAt = /);
  // Only two places send requests: diagFlush (batched, when the switch is on) and errSend (error reporting not gated by the switch, with a throttle cap)
  assert.equal(app.split('fetch("/api/diag"').length, 3);
  assert.match(body("diagFlush"), /fetch\("\/api\/diag"/);
  assert.match(body("errSend"), /fetch\("\/api\/diag"/);
});

test("event wiring: render / ph / fig / scroll-jump / detail-open from / notify-click / boot launch", () => {
  assert.match(body("renderList"), /diagRender\(/);
  assert.match(body("diagRender"), /"render"/);
  assert.match(body("diagRender"), /"scroll-jump"/);
  assert.match(body("diagRender"), /"ph"/);
  assert.match(body("diagFig"), /diagThrottled\("fig"/);
  assert.match(body("tickFig"), /diagFig\(/);
  assert.match(body("showDetail"), /diag\("detail-open", \{[^}]*from/);
  assert.match(body("diagStart"), /launch: /);
  assert.match(app, /diag\("notify-click"/);
  assert.match(app, /diag\("open-from-notify"/);
});

test("sw: notificationclick passes the tag and whether the app is open to the page", () => {
  assert.match(sw, /const VERSION = "v142";/);
  assert.match(sw, /postMessage\(\{ type: "open", url, tag[^}]*hadClient/);
});
