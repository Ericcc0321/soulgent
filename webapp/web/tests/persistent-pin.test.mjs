// Persistent pin-to-top (topped, stored in api top.json, separate from the dashboard's "pin awaiting reply" pinned); the row context menu offers combinations by state
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { rowMenuActs, sortChat, chatRow } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const fnBody = (name, len = 1500) => { const i = app.indexOf("function " + name); assert.ok(i > 0, "missing " + name); return app.slice(i, i + len); };
const ks = (s) => rowMenuActs(s, false).map((a) => (a.sep ? "|" : a.key + ":" + a.label + (a.danger ? "!" : "")));

const base = { id: "a", kind: "claude", status: "idle", origin: "user", unread: false, rest: false, muted: false, topped: false };
const busy = { ...base, status: "busy" };
const waiting = { ...base, status: "waiting" };
const idle = base;
const resting = { ...base, rest: true };

test("O menu matrix: busy = pin / mute | clock out", () => {
  assert.deepEqual(ks(busy), ["top:置顶", "mute:消息免打扰", "|", "off:下班!"]);
  assert.deepEqual(ks({ ...busy, topped: true, muted: true }), ["untop:取消置顶", "unmute:取消免打扰", "|", "off:下班!"]);
});

test("O menu matrix: waiting = pin / mute | clock out", () => {
  assert.deepEqual(ks(waiting), ["top:置顶", "mute:消息免打扰", "|", "off:下班!"]);
  assert.deepEqual(ks({ ...waiting, topped: true }), ["untop:取消置顶", "mute:消息免打扰", "|", "off:下班!"]);
});

test("O menu matrix: idle/done = pin / unread-read / mute | rest / clock out", () => {
  assert.deepEqual(ks(idle), ["top:置顶", "unseen:标为未读", "mute:消息免打扰", "|", "rest:休息", "off:下班!"]);
  assert.deepEqual(ks({ ...idle, topped: true, unread: true }), ["untop:取消置顶", "seen:标为已读", "mute:消息免打扰", "|", "rest:休息", "off:下班!"]);
  // idle sessions from correspondence / sub-agent reports get the same five items
  assert.deepEqual(ks({ ...idle, origin: "agent" }), ["top:置顶", "unseen:标为未读", "mute:消息免打扰", "|", "rest:休息", "off:下班!"]);
});

test("O menu matrix: resting = pin / mute | come back / clock out (no unread/read)", () => {
  assert.deepEqual(ks(resting), ["top:置顶", "mute:消息免打扰", "|", "back:回来", "off:下班!"]);
  assert.deepEqual(ks({ ...resting, topped: true, muted: true, unread: true }), ["untop:取消置顶", "unmute:取消免打扰", "|", "back:回来", "off:下班!"]);
});

test("O menu: dashboard pin (pinned) does not decide the menu's pin item; non-Claude sessions get no clock-out; empty for guests", () => {
  assert.deepEqual(ks({ ...idle, pinned: true }).slice(0, 1), ["top:置顶"]);
  assert.deepEqual(ks({ ...idle, kind: "shell" }), ["top:置顶", "unseen:标为未读", "mute:消息免打扰", "|", "rest:休息"]);
  assert.deepEqual(rowMenuActs(idle, true), []);
  assert.deepEqual(rowMenuActs(null, false), []);
});

const S = (id, o = {}) => ({ id, name: "Docs-" + id, plate: id, zone: "Docs", status: "idle", since: 100, unread: false, pinned: false, topped: false, rest: false, ...o });
test("O ordering: waiting -> topped -> pinned -> replied -> busy -> rest", () => {
  const out = sortChat([
    S("idle", { since: 999 }),
    S("busy", { status: "busy", since: 500 }),
    S("unread", { unread: true, since: 400 }),
    S("pin", { pinned: true, since: 300 }),
    S("top-busy", { topped: true, status: "busy", since: 20 }),
    S("top-idle", { topped: true, since: 10 }),
    S("w", { status: "waiting", since: 50 }),
    S("w-top", { status: "waiting", topped: true, since: 60 }),
  ]);
  assert.deepEqual(out.map((s) => s.id), ["w", "w-top", "top-busy", "top-idle", "pin", "unread", "busy", "idle"]);
});

test("O chatRow carries topped; row styles for topped and pinned both use .pin (--row-pin background)", () => {
  assert.equal(chatRow(S("x", { topped: true }), [], 1000).topped, true);
  assert.equal(chatRow(S("x"), [], 1000).topped, false);
  assert.match(fnBody("fillMsgLi(", 600), /if \(r\.pinned \|\| r\.topped\) cls \+= " pin"/);
});

test("O menu and chat info page pinning use the top API (setTop) and do not go through pinBlock", () => {
  const run = fnBody("rowMenuRun(", 700);
  const tbl = app.slice(app.indexOf("const ROW_MENU_RUN = {"), app.indexOf("function rowMenuRun("));
  assert.match(tbl, /top: \(s\) => setTop\(s, true\), untop: \(s\) => setTop\(s, false\)/);
  assert.doesNotMatch(run + tbl, /setPin\(/);
  const b = fnBody("setTop(", 600);
  assert.match(b, /\/top", \{ on \}/);
  assert.match(b, /s\.topped = on/);
  assert.doesNotMatch(b, /pinBlock/);
  assert.match(app, /chSwitch\(t\("ch.top"\), !!s\.topped, \(on\) => setTop\(s, on\)\)/);
});
