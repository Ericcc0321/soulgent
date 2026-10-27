// Plain text a guest sends that is an allowed slash command gets no guest prefix; the pending bubble follows the same rule as the server
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
import { setGuestTag, guestPendText, buildQuoteText, setGuestSlashCommands } from "../logic.js";
setLang("hans");
setGuestTag("[Guest]");
setGuestSlashCommands(["/window"]); // as if GUEST_SLASH_COMMANDS=/window

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

test("guestPendText: plain text starting with / gets no prefix", () => {
  assert.equal(guestPendText("", "/window"), "/window");
  assert.equal(guestPendText("", "/window 参数"), "/window 参数");
  assert.equal(guestPendText("   ", "/window"), "/window"); // a whitespace-only quote is the same as no quote
  // Other slash commands cannot be sent by a guest (sendText blocks them first, see the guest slash command tests); if one gets here anyway it is prefixed like normal text
  assert.equal(guestPendText("", "/model opus"), "[Guest] /model opus");
});

test("guestPendText: with an empty list even /window is prefixed", () => {
  setGuestSlashCommands([]);
  assert.equal(guestPendText("", "/window"), "[Guest] /window");
  setGuestSlashCommands(["/window"]);
});

test("guestPendText: everything else is prefixed (plain text, slash not first, with a quote)", () => {
  assert.equal(guestPendText("", "hi"), "[Guest] hi");
  assert.equal(guestPendText("", "hi /window"), "[Guest] hi /window");
  assert.equal(guestPendText("demo: 原文", "/x"), "[Guest] " + buildQuoteText("demo: 原文", "/x"));
});

test("sendText draws the pending bubble with guestPendText", () => {
  const app = rd("app.js");
  const i = app.indexOf("function sendText");
  assert.ok(i >= 0);
  assert.match(app.slice(i, i + 2500), /st\.guest \? guestPendText\(quote, input\) : text/);
});

test("server and client rule comments reference each other", () => {
  assert.match(rd("logic.js"), /_guest_send/);
  assert.match(readFileSync(new URL("../../api/server.py", import.meta.url), "utf8"), /guestPendText/);
});

test("sw version matches the shell", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142"/);
  assert.match(rd("index.html"), /name="zbs-shell" content="v142"/);
});

test("paths such as /tmp/... are not slash commands and are prefixed", async () => {
  const L = await import("../logic.js");
  assert.equal(L.guestPendText("", "/window"), "/window");
  assert.equal(L.guestPendText("", "/window 留重点"), "/window 留重点");
  assert.equal(L.guestPendText("", "/Users/demo/a.png 看这个"), L.withGuestTag("/Users/demo/a.png 看这个"));
  assert.equal(L.guestPendText("", "/ 斜杠开头"), L.withGuestTag("/ 斜杠开头"));
});
