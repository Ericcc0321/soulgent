// The "chat history" section of the outer global search
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { gsReady, gsUrl, gsRows, GS_DELAY } from "../logic.js";
import { setLang, t } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");

test("gsReady: chat history is searched only with at least 2 characters after trimming; 400ms debounce", () => {
  assert.equal(gsReady(""), false);
  assert.equal(gsReady(" 模 "), false);
  assert.equal(gsReady("模拟"), true);
  assert.equal(gsReady("ab"), true);
  assert.equal(GS_DELAY, 400);
});

test("gsUrl: encodes the keyword, limit=60", () => {
  assert.equal(gsUrl("模拟 器"), "/api/search?q=" + encodeURIComponent("模拟 器") + "&limit=60");
});

test("gsRows: rows follow the server order, with short name, N related, latest snippet and a before-window-switch marker", () => {
  const snap = { zones: [{ code: "Web", name: "前端", color: "#f00" }], sessions: [{ id: "a", name: "Web-API-spec", zone: "Web", kind: "claude" }],
    offduty: [{ sid: "o", name: "Lab-offduty", zone: "Lab" }] };
  const data = { results: [
    { sid: "a", name: "Web-API-spec", zone: "Web", off: false, count: 3, last: "2026-10-22T03:00:00Z",
      hits: [{ sid: "p1", seq: 5, ts: "2026-10-22T03:00:00Z", role: "user", snippet: "…打开模拟器" }, { sid: "a", seq: 1, ts: "x", snippet: "y" }] },
    { sid: "o", name: "Lab-offduty", zone: "Lab", off: true, count: 1, last: "2026-10-21T01:00:00Z", hits: [{ sid: "o", seq: 2, ts: "t", snippet: "模拟器" }] },
    { sid: "gone", name: "已走", zone: "Infra", off: false, count: 1, hits: [{ sid: "gone", snippet: "z" }] },
  ] };
  const rows = gsRows(data, snap);
  assert.deepEqual(rows.map((r) => r.sid), ["a", "o"]); // sessions missing from the snapshot are dropped
  assert.equal(rows[0].plate, "API-spec");
  assert.equal(rows[0].countText, "3 条相关");
  assert.equal(rows[0].snippet, "…打开模拟器");
  assert.equal(rows[0].prev, true); // the latest hit is from before the window switch
  assert.equal(rows[0].off, false);
  assert.equal(rows[1].off, true);
  assert.equal(rows[1].prev, false);
  assert.deepEqual(gsRows(null, snap), []);
  assert.deepEqual(gsRows({ results: "bad" }, snap), []);
});

test("app.js: the search page has a chat-history section, requests /api/search after typing stops, and tapping a row opens the in-session chat search page with the keyword", () => {
  assert.match(app, /function gsSchedule\(/);
  assert.match(app, /setTimeout\([^]*?GS_DELAY\)/);
  assert.match(app, /gsUrl\(/);
  assert.match(app, /t\("gs.head"\)/); // the section title goes through the i18n table
  assert.equal(t("gs.head"), "聊天记录");
  assert.match(app, /function openChatSearch\(q0\)/); // the in-session search page accepts an initial keyword
  assert.match(app, /openChatSearch\(r\.q\)|openChatSearch\(q\)/);
  // guests do not get the chat-history section
  assert.match(app, /function gsSchedule\([^)]*\)\s*\{\s*if \(st\.guest/);
  // cleared when the search ends
  assert.match(app, /function endSearch\(\)\s*\{[^}]*gsReset\(\)/);
});

test("style.css: gs- prefixed rules", () => {
  assert.match(css, /\.gs-cnt\s*\{/);
});
