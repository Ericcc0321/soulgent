// Notification pipeline and robustness
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { openSwallowed, OPEN_SWALLOW_MS, shellGate, bannerStep, newBannerState, bannerStill, BANNER_DONE_MS, applyFlagOpt } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const app = read("../app.js");
const sw = read("../sw.js");
const html = read("../index.html");
const fnBody = (name) => {
  const i = app.search(new RegExp("\\n(async )?function " + name + "\\("));
  assert.ok(i >= 0, "function " + name + " not found in app.js");
  return app.slice(i, app.indexOf("\n}\n", i));
};

// ===== the 600ms mis-tap guard after swipe-back does not swallow notifications / cold start / hash entry =====
test("openSwallowed: notify / launch / hashchange are never swallowed; other sources are swallowed within 600ms", () => {
  assert.equal(OPEN_SWALLOW_MS, 600);
  for (const f of ["notify", "launch", "hashchange"]) assert.equal(openSwallowed(f, 10), false, f);
  for (const f of ["list", "card", "banner", "search", undefined, null]) assert.equal(openSwallowed(f, 10), true, String(f));
  assert.equal(openSwallowed("list", 600), false);
  assert.equal(openSwallowed("list", 5000), false);
});

test("openDetail / openOffDetail use openSwallowed; when swallowed they log diag open-swallowed {id, from}", () => {
  for (const name of ["openDetail", "openOffDetail"]) {
    const b = fnBody(name);
    assert.doesNotMatch(b, /st\.backAt < 600/, name + " must not hardcode the 600ms check");
    assert.match(b, /openSwallowed\(from, Date\.now\(\) - st\.backAt\)/, name);
    assert.match(b, /diag\("open-swallowed", \{ id(: \w+)?, from: from \|\| null \}\)/, name);
  }
});

// ===== shell / app.js version gate =====
test("init is split into steps: each wrapped in initStep; init does not bind $(\"#...\").onclick directly", () => {
  const b = fnBody("init");
  assert.doesNotMatch(b, /\$\("#[^"]+"\)\.onclick\s*=/, "#id bindings in init must go through bindOn (null-guarded)");
  assert.doesNotMatch(b, /\$\("#msgs"\)\.addEventListener/, "the #msgs scroll listener also needs a null guard");
  for (const f of ["bindEdgeSwipe", "bindChat", "bindPlus", "bindDesktopFiles", "bindReply", "bindBubblePress"]) {
    assert.match(b, new RegExp("initStep\\(\"\\w+\", " + f + "\\)|initStep\\(\"\\w+\", \\(\\) => \\{[^]*?" + f + "\\(\\)"), f + " must be wrapped in initStep");
  }
  // the startup entry (opening via hash) must run after the snapshot arrives and must not be broken by earlier steps
  assert.ok(b.indexOf("await Promise.all([pets, st.inflight])") < b.indexOf('openFromHash(location.hash, "launch")'));
});

test("bindOn / initStep: a missing element logs init-missing; an error inside a step logs init-error and is not rethrown", () => {
  const on = fnBody("bindOn");
  assert.match(on, /diag\("init-missing", \{ sel \}\)/);
  const step = fnBody("initStep");
  assert.match(step, /try \{/);
  assert.match(step, /diag\("init-error", \{ step: name/);
});

test("the index.html shell version marker matches the sw VERSION (bump both together)", () => {
  const m = html.match(/<meta name="zbs-shell" content="(v\d+)">/);
  assert.ok(m, "index.html must have <meta name=\"zbs-shell\" content=\"vNN\">");
  const v = sw.match(/const VERSION = "(v\d+)";/)[1];
  assert.equal(m[1], v);
});

test("the sw receives the page's shell version; on mismatch it clears the cached / and replies shell-mismatch", () => {
  assert.match(sw, /addEventListener\("message"/);
  assert.match(sw, /type [!=]== "shell"/);
  assert.match(sw, /\.delete\("\/"\)/);
  assert.match(sw, /type: "shell-mismatch", v: VERSION/);
  assert.match(sw, /type: "shell-ok", v: VERSION/);
  assert.match(app, /postMessage\(\{ type: "shell", v: /);
});

test("shellGate: on mismatch reload only once (no reload if the gate for that version is already set); on match clear the gate", () => {
  assert.deepEqual(shellGate({ type: "shell-mismatch", v: "sh1" }, null), { reload: true, gate: "sh1" });
  assert.deepEqual(shellGate({ type: "shell-mismatch", v: "sh1" }, "sh1"), { reload: false, gate: "sh1" });
  assert.deepEqual(shellGate({ type: "shell-mismatch", v: "sh2" }, "sh1"), { reload: true, gate: "sh2" });
  assert.deepEqual(shellGate({ type: "shell-ok", v: "sh1" }, "sh1"), { reload: false, gate: null });
  assert.deepEqual(shellGate({ type: "other" }, "sh1"), { reload: false, gate: "sh1" });
  assert.deepEqual(shellGate(null, null), { reload: false, gate: null });
});

// ===== sending with attachments while busy is queued, not lost =====
test("sendWithTray: does not return early while sending; on press it moves the tray away and queues into sendChain", () => {
  const b = fnBody("sendWithTray") + fnBody("queueTray"); // the queueing part lives in queueTray (shared with resend)
  assert.doesNotMatch(b, /st\.sending \|\|/, "must not drop the send just because one is in progress");
  assert.match(b, /sendChain = sendChain\.then\(job, job\)/);
  assert.match(b, /st\.tray = \[\]/, "on press the tray is moved into this message's own queue");
  assert.match(b, /preCleared\.add\(body\)/, "clear the input on press so that after delivery the user's next draft is not cleared");
  assert.match(b, /waitSendIdle\(\)/);
});

test("while sending, attachments can still be added to / removed from the tray (the tray is not shared with the message in flight)", () => {
  assert.doesNotMatch(fnBody("canAttach"), /st\.sending/);
  assert.doesNotMatch(fnBody("removeFromTray"), /st\.sending/);
  assert.doesNotMatch(fnBody("onPlus"), /st\.sending/);
});

// ===== manually marking unread does not show the in-page banner =====
const W = (id, o = {}) => ({ id, status: "idle", since: 100, unread: false, ...o });
test("bannerStep: manually marked unread (manualUnread) shows no \"finished\" banner; genuinely finished sessions still do", () => {
  let st = bannerStep(newBannerState(), [W("a"), W("b")], 0, null).state;
  let r = bannerStep(st, [W("a", { unread: true, manualUnread: true }), W("b", { unread: true, since: 200 })], 1000, null);
  r = bannerStep(r.state, [W("a", { unread: true, manualUnread: true }), W("b", { unread: true, since: 200 })], 1000 + BANNER_DONE_MS, null);
  assert.deepEqual(r.fire, [{ id: "b", kind: "done" }]);
  assert.equal(bannerStill(W("a", { unread: true, manualUnread: true }), "done"), false);
  assert.equal(bannerStill(W("b", { unread: true }), "done"), true);
});

test("applyFlagOpt: optimistic mark-unread carries manualUnread (no banner even before the snapshot returns)", () => {
  const snap = { generatedAt: 1, sessions: [{ id: "a", status: "idle", unread: false, rest: false }] };
  const r = applyFlagOpt(snap, new Map([["a", { at: 1000, unread: true }]]), 2000);
  assert.equal(r.snap.sessions[0].unread, true);
  assert.equal(r.snap.sessions[0].manualUnread, true);
  const r2 = applyFlagOpt({ generatedAt: 1, sessions: [{ id: "a", status: "idle", unread: true, manualUnread: true }] }, new Map([["a", { at: 1000, unread: false }]]), 2000);
  assert.equal(r2.snap.sessions[0].unread, false);
  assert.equal(r2.snap.sessions[0].manualUnread, undefined);
});
