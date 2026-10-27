import test from "node:test";
import assert from "node:assert/strict";
import { pushStatus, urlB64ToBytes } from "../logic.js";

const ok = { sw: true, push: true, notif: true, standalone: true, permission: "default", subscribed: false };

test("pushStatus: unsupported, denied, subscribed, off", () => {
  assert.equal(pushStatus({ ...ok, push: false }).state, "unsupported");
  assert.equal(pushStatus({ ...ok, sw: false }).state, "unsupported");
  assert.equal(pushStatus({ ...ok, permission: "denied" }).state, "denied");
  assert.equal(pushStatus({ ...ok, permission: "granted", subscribed: true }).state, "subscribed");
  assert.equal(pushStatus({ ...ok, permission: "granted", subscribed: false }).state, "off");
  assert.equal(pushStatus(ok).state, "off");
});

test("pushStatus: hint only when not installed", () => {
  assert.equal(pushStatus(ok).hint, "");
  assert.match(pushStatus({ ...ok, standalone: false }).hint, /主屏幕/);
  // iOS browser tabs have no PushManager: unsupported, but still hint to add to the home screen
  const r = pushStatus({ ...ok, standalone: false, push: false });
  assert.equal(r.state, "unsupported");
  assert.match(r.hint, /主屏幕/);
});

test("urlB64ToBytes decodes base64url without padding", () => {
  assert.deepEqual(Array.from(urlB64ToBytes("AQID")), [1, 2, 3]);
  assert.deepEqual(Array.from(urlB64ToBytes("-_8")), [251, 255]);
  assert.equal(urlB64ToBytes("").length, 0);
});

import { staleTags } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

test("staleTags: only s-<id> tags of sessions that are not waiting/unread", () => {
  const sessions = [
    { id: "a", status: "waiting", unread: false },
    { id: "b", status: "idle", unread: true },
    { id: "c", status: "idle", unread: false },
    { id: "d", status: "busy", unread: false },
  ];
  assert.deepEqual(staleTags(["s-a", "s-b", "s-c", "s-d", "s-gone", "zbs-test", "x"], sessions), ["s-c", "s-d", "s-gone"]);
  assert.deepEqual(staleTags([], sessions), []);
  assert.deepEqual(staleTags(["s-a"], null), ["s-a"]);
});
