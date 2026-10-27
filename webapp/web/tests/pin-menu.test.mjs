// Pinning a busy session sticks; peer-traffic rows draw no bell (the bell is only for real mute)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { rowMenuActs } from "../logic.js";
import { setLang, t } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const fnBody = (name, len = 1500) => { const i = app.indexOf("function " + name); assert.ok(i > 0, "missing " + name); return app.slice(i, i + len); };

// Tapping "pin" on Docs-Dash-Mobile (busy): the api records it, then the next snapshot removes it
// (state.flags_for: busy auto-unpins; dashboard unpinAnswered: non-idle unpins). The pushpin means "pin awaiting reply" and only works for finished sessions
const idle = { id: "a", kind: "claude", status: "idle", origin: "agent", unread: false, rest: false };
const busy = { ...idle, status: "busy" };
const waiting = { ...idle, status: "waiting" };

// The menu's "pin" is a persistent pin (topped, stored in the api), offered in any state; the dashboard pin does not appear in the menu
test("menu: \"pin\" (top) in every state, \"unpin\" (untop) once pinned; dashboard pin/unpin not offered", () => {
  const keys = (s) => rowMenuActs(s, false).map((a) => a.key).filter(Boolean);
  for (const s of [idle, busy, waiting]) {
    assert.ok(keys(s).includes("top"));
    assert.ok(keys({ ...s, topped: true }).includes("untop"));
    assert.ok(!keys({ ...s, pinned: true }).some((k) => k === "pin" || k === "unpin"));
  }
});

test("the chat-info switch bounces back when its handler returns false", () => {
  const sw = fnBody("chSwitch(", 500);
  assert.match(sw, /onChange\(inp\.checked\) === false/);
});

test("the second-line bell depends on s.muted only; peer-traffic (quiet) rows draw no bell", () => {
  const b = fnBody("fillMsgLi(", 6000);
  const line = b.split("\n").find((l) => l.includes("MUTE_SVG"));
  assert.ok(line, "missing the bell line");
  assert.ok(!/r\.quiet/.test(line), "peer-traffic rows must not draw a bell: " + line);
  assert.match(line, /s\.muted/);
  assert.match(app, /const MUTE_SVG = [^\n]*aria-label="' \+ t\("svg.mute"\) \+ '"/);
  assert.equal(t("svg.mute"), "消息免打扰");
});
