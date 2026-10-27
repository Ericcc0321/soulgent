// App icon badge: the number = waiting for you + has something to say, the same pure function as the tab-bar red dot
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const sw = rd("sw.js");
const app = rd("app.js");
const full = { setAppBadge() {}, clearAppBadge() {} };

test("appBadgeOps: n>0 -> set, n=0 -> clear, unsupported -> none", () => {
  assert.deepEqual(L.appBadgeOps(3, full), { op: "set", n: 3 });
  assert.deepEqual(L.appBadgeOps(0, full), { op: "clear" });
  assert.deepEqual(L.appBadgeOps(0, { setAppBadge() {} }), { op: "set", n: 0 });
  assert.deepEqual(L.appBadgeOps(2, {}), { op: "none" });
  assert.deepEqual(L.appBadgeOps(2, null), { op: "none" });
  assert.deepEqual(L.appBadgeOps(-1, full), { op: "clear" });
  assert.deepEqual(L.appBadgeOps(NaN, full), { op: "none" });
  assert.deepEqual(L.appBadgeOps(5, { clearAppBadge() {} }), { op: "none" });
});
test("badge semantics = chatBadge: resting sessions do not count, muted ones still count, manually marked unread still counts", () => {
  const snap = { sessions: [
    { id: "1", status: "waiting" }, { id: "2", status: "waiting", muted: true },
    { id: "3", status: "idle", unread: true }, { id: "4", status: "idle", unread: true, manualUnread: true },
    { id: "5", status: "idle", unread: true, rest: true }, { id: "6", status: "busy" }, { id: "7", status: "idle" },
  ] };
  assert.equal(L.chatBadge(snap), 4);
});
test("app.js: the badge is synced after every snapshot update (using chatBadge) and recomputed when the app opens", () => {
  assert.match(app, /function syncAppBadge/);
  assert.match(app, /function syncAppBadge[^]*?chatBadge\(snap\)[^]*?appBadgeOps\(/);
  assert.match(app, /setAppBadge/);
  assert.match(app, /clearAppBadge/);
  const apply = app.slice(app.indexOf("function applySnapshot"), app.indexOf("\n}\n", app.indexOf("function applySnapshot")));
  assert.match(apply, /\brender\(\)/, "every snapshot renders, and render syncs the badge via renderBadge");
});
test("app.js: the icon badge is synced wherever the tab number is drawn, so local mark-read reaches the icon without waiting for a poll", () => {
  const fn = (name) => { const i = app.indexOf("function " + name + "("); return app.slice(i, app.indexOf("\n}\n", i)); };
  assert.match(fn("renderBadge"), /syncAppBadge\(st\.snap\)/);
  assert.match(fn("renderChat"), /renderBadge\(\)/);
  assert.match(fn("render"), /renderChat\(\)/);
  // local mark-read paths only call render(): before this fix the icon kept the old count if the app went to the background before the next poll
  assert.match(fn("markSeen"), /s\.unread = false;[^]*render\(\)/);
  assert.match(fn("seenAll"), /s\.unread = false;[^]*render\(\)/);
});
test("sw.js: in push, the badge is set after showNotification; a missing badge leaves it alone, 0 clears it, unsupported is skipped", () => {
  assert.match(sw, /function applyBadge/);
  assert.match(sw, /self\.navigator/);
  assert.match(sw, /setAppBadge/);
  assert.match(sw, /clearAppBadge/);
  const body = sw.slice(sw.indexOf("async function onPush"), sw.indexOf('self.addEventListener("push"'));
  assert.ok(body.indexOf("showNotification") < body.indexOf("applyBadge("), "the badge is set after showNotification");
  assert.match(sw, /Number\.isInteger\(msg\.badge\)/);
});
test("sw and shell versions", () => {
  assert.match(sw, /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
