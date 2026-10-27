// Me page "signed-in devices" (login tokens, /api/auth/devices): row building, sign-out confirm text, and the wiring in app.js
// (this device signs out through the same path as logout, so push is unsubscribed and the offline snapshot cache is cleared)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loginRows, loginRevokeAsk } from "../logic.js";
import { setLang } from "../i18n.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");
const fnBody = (src, name) => { const i = src.indexOf(name); assert.ok(i >= 0, name); return src.slice(i, src.indexOf("\n}\n", i)); };
const NOW = 1_800_000_000;

test("loginRows: this device first, others newest first; relative last-used time; this device says in use", () => {
  setLang("en");
  const rows = loginRows([
    { id: "aaaaaaaaaaaa", desc: "Mac Chrome", lastSeen: NOW - 3 * 86400, self: false },
    { id: "bbbbbbbbbbbb", desc: "iPhone Safari", lastSeen: NOW - 10, self: true },
    { id: "cccccccccccc", desc: "Windows Edge", lastSeen: NOW - 7200, self: false },
  ], NOW);
  assert.deepEqual(rows.map((r) => [r.id, r.label, r.self, r.last]), [
    ["bbbbbbbbbbbb", "iPhone Safari", true, "Using it now"],
    ["cccccccccccc", "Windows Edge", false, "Last used: 2 h ago"],
    ["aaaaaaaaaaaa", "Mac Chrome", false, "Last used: 3 days ago"],
  ]);
  setLang("hans");
  assert.equal(loginRows([{ id: "aaaaaaaaaaaa", desc: "Mac Chrome", lastSeen: NOW - 120 }], NOW)[0].last, "最后使用：2 分钟前");
  setLang("en");
});

test("loginRows: drops entries without a valid id; odd or missing descriptions show as unknown device", () => {
  setLang("en");
  const rows = loginRows([
    null, { desc: "x" }, { id: "../etc", desc: "Mac Chrome" },
    { id: "dddddddddddd", desc: "<img src=x>", lastSeen: NOW },
    { id: "eeeeeeeeeeee", lastSeen: "bad" },
    { id: "ffffffffffff", desc: "Unknown device", lastSeen: 0 },
  ], NOW);
  assert.deepEqual(rows.map((r) => [r.id, r.label, r.last]), [
    ["dddddddddddd", "Unknown device", "Last used: just now"],
    ["eeeeeeeeeeee", "Unknown device", ""],
    ["ffffffffffff", "Unknown device", ""],
  ]);
  assert.deepEqual(loginRows(undefined, NOW), []);
});

test("loginRevokeAsk: this device vs another device", () => {
  setLang("en");
  assert.deepEqual(loginRevokeAsk({ self: true, label: "iPhone Safari" }),
    { title: "Sign out this device?", hint: "You'll go back to the login page and need the key to come back in." });
  assert.deepEqual(loginRevokeAsk({ self: false, label: "Mac Chrome" }),
    { title: "Sign out Mac Chrome?", hint: "That device will need the key to sign in again." });
  setLang("hant");
  assert.equal(loginRevokeAsk({ self: false, label: "Mac Chrome" }).title, "讓「Mac Chrome」登出？");
  setLang("en");
});

test("Me page: both admin and guest get the signed-in devices row; this device signs out via the logout path", () => {
  assert.match(fnBody(app, "function renderGuestMe("), /meRow\("logins", t\("me\.logins"\)\)/);
  assert.match(fnBody(app, "function renderMe("), /meRow\("logins", t\("me\.logins"\)\)/);
  const click = app.indexOf('else if (k === "logins") openLoginsSheet();');
  assert.ok(click > 0 && click < app.indexOf("else if (st.guest && !["), "logins handled before the guest early return");
  const rev = fnBody(app, "async function revokeLogin(");
  assert.match(rev, /if \(row\.self\) \{ guestLogout\(\); return; \}/);
  assert.match(rev, /post\("\/api\/auth\/devices\/revoke", \{ id: row\.id \}/);
  const out = fnBody(app, "async function guestLogout(");
  assert.match(out, /post\("\/api\/auth\/logout"/);
  assert.match(out, /caches\.delete\("zbs-data-v2"\)/);
  assert.match(rd("sw.js"), /p === "\/api\/auth\/logout"/); // the sw also drops the offline snapshot cache on logout
  assert.match(fnBody(app, "async function openLoginsSheet("), /api\("\/api\/auth\/devices"/);
});
