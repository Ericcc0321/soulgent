// Error reporting (diagErr), attachment failures by status code, the reader page does not report render errors as "file is gone", whoLine temporal dead zone, nickname decided by field
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const app = rd("app.js");
const body = (name) => { // top-level function body (up to the next top-level function)
  let a = app.indexOf("\nfunction " + name + "(");
  if (a < 0) a = app.indexOf("\nasync function " + name + "(");
  assert.ok(a >= 0, name);
  const b = app.slice(a + 1).search(/\n(?:async )?function /);
  return app.slice(a, b < 0 ? undefined : a + 1 + b);
};

test("errGate: the same message from the same place is reported once per 60 s; at most 20 per page load", () => {
  const g = L.newErrGate();
  assert.equal(L.errGate(g, "a|x", 0), true);
  assert.equal(L.errGate(g, "a|x", 59999), false);
  assert.equal(L.errGate(g, "b|x", 1), true);
  assert.equal(L.errGate(g, "a|x", 60000), true);
  for (let i = 0; i < 30; i++) L.errGate(g, "k" + i, 2);
  assert.equal(g.n, L.ERR_MAX);
  assert.equal(L.errGate(g, "new", 3), false);
});

test("errEvent: k=err, message is the first line cut to 300, stack is the first 8 lines cut to 800; non-Error values can be reported too", () => {
  const e = new TypeError("t is not a function\nsecond line");
  e.stack = "TypeError: t is not a function\n" + Array.from({ length: 20 }, (_, i) => "    at f" + i + " (app.js:" + i + ")").join("\n");
  const ev = L.errEvent("reader.md", e, 5, { shell: "sh1" });
  assert.equal(ev.k, "err");
  assert.equal(ev.where, "reader.md");
  assert.equal(ev.name, "TypeError");
  assert.equal(ev.msg, "t is not a function");
  assert.equal(ev.stack.split("\n").length, 8);
  assert.equal(ev.shell, "sh1");
  assert.equal(L.errEvent("x", "boom", 1).msg, "boom");
  assert.equal(L.errEvent("x", null, 1).msg, "");
  assert.equal(L.errEvent("x", { message: "m".repeat(999) }, 1).msg.length, 300);
});

test("fileFailKey: only 404/403/410 mean 'file is gone'; rate limiting and server errors mean 'load failed'", () => {
  for (const s of [404, 403, 410]) assert.equal(L.fileFailKey(s), "c.fileGone", s);
  for (const s of [429, 500, 502, 0, undefined]) assert.equal(L.fileFailKey(s), "c.loadFail", s);
});

test("diagErr: not gated by the diagnostics switch and does not go through api(); global error/rejection/sg-err handlers are registered at top level", () => {
  const d = body("diagErr");
  assert.doesNotMatch(d, /if \(!D\) return/);
  assert.match(d, /console\.error/);
  assert.match(d, /errGate\(/);
  const s = body("errSend");
  assert.doesNotMatch(s, /st\.guest/); // guests report too (the server filters and rate-limits)
  assert.match(s, /fetch\("\/api\/diag"/);
  assert.doesNotMatch(s, /\bapi\(/);
  assert.match(app, /\naddEventListener\("error", /);
  assert.match(app, /\naddEventListener\("unhandledrejection", /);
  assert.match(app, /\naddEventListener\("sg-err", /);
  assert.match(body("loadAccount"), /errAccountReady\(\)/);
  assert.match(rd("viewer.js"), /CustomEvent\("sg-err"/);
  assert.match(rd("md.js"), /CustomEvent\("sg-err"/);
});

test("every swallowed-error site reports: reader page, Markdown cache, task board, snapshot rendering, init steps, send/recall/wake/off-duty/attachment send", () => {
  assert.match(body("openReader"), /diagErr\("reader\.md"/);
  assert.match(body("mdNode"), /diagErr\("mdNode"/);
  assert.match(body("initStep"), /diagErr\("init\." \+ name/);
  for (const [fn, where] of [["submitSend", "submitSend"], ["runOffduty", "runOffduty"], ["wake", "wake"], ["doRecall", "doRecall"], ["prepareImage", "prepareImage"]]) {
    assert.match(body(fn), new RegExp('diagErr\\("' + where + '"'), fn);
  }
  assert.match(app, /diagErr\("sendWithTray"/);
  assert.match(app, /diagErr\("taskboard\.md"/);
  assert.match(body("refresh"), /try \{ applySnapshot\(snap\); \} catch \(e\) \{ diagErr\("applySnapshot", e\); \}/);
  assert.match(body("loadPets"), /diagErr\("loadPets\.figure"/);
});

test("reader page: render errors fall back to plain text instead of 'file is gone'; file fetch failures are classified by status code", () => {
  const r = body("openReader");
  assert.match(r, /fileFailKey\(res\.status\)/);
  assert.doesNotMatch(r, /\.catch\(\(\) => \{ if \(alive\(\)\) note\(t\("c\.fileGone"\)\)/);
  assert.match(r, /wrap\.append\(md \|\| h\("pre", "at-pre", text\)\)/);
  assert.doesNotMatch(r, /\(t\) =>/); // the parameter of note is not named t
});

test("whoLine: no local variable named t (otherwise an unsigned session-to-session message hits a TDZ error here and the whole page fails to render)", () => {
  const w = body("whoLine");
  assert.match(w, /sp\.plate \|\| t\("c\.peer"\)/);
  assert.doesNotMatch(w.replace(/\/\/[^\n]*/g, ""), /\b(?:const|let|var) t\b/); // mentions inside comments do not count
});

test("profileView: the default nickname is decided by a field (isDefault); the Me page does not compare the display name with translated text", () => {
  assert.equal(L.profileView({ name: "" }).isDefault, true);
  assert.equal(L.profileView({ name: "我" }).isDefault, true);
  assert.equal(L.profileView({ name: "Me" }).isDefault, false); // a nickname that really is Me
  assert.doesNotMatch(app, /pv\.name === t\("c\.me"\)/);
  assert.match(app, /pv\.isDefault \? t\("me\.adminName"\) : pv\.name/);
});
