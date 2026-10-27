// On wide screens the divider between the list column and the chat column is draggable
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { clampListW } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
const logic = readFileSync(new URL("../logic.js", import.meta.url), "utf8");

test("clampListW: minimum 280, maximum min(560, 45% of the window), a too-small window uses the minimum", () => {
  assert.equal(clampListW(100, 1600), 280);
  assert.equal(clampListW(370, 1600), 370);
  assert.equal(clampListW(900, 1600), 560);
  assert.equal(clampListW(900, 1000), 450);
  assert.equal(clampListW(400, 500), 280);
  assert.equal(clampListW("abc", 1600), 370);
  assert.equal(clampListW(undefined, 1600), 370);
});

test("source: constants and storage key", () => {
  assert.match(logic, /LISTW_MIN = 280/);
  assert.match(logic, /LISTW_MAX = 560/);
  assert.match(app, /zbs\.listw/);
  assert.match(app, /split-h/);
  assert.match(app, /setPointerCapture/);
  assert.match(app, /dblclick/);
});

test("CSS: split-h 6px, col-resize, text selection disabled while dragging", () => {
  const m = css.match(/body\.split \.split-h \{([^}]*)\}/);
  assert.ok(m, "missing .split-h");
  assert.match(m[1], /width: 6px/);
  assert.match(m[1], /col-resize/);
  assert.match(css, /\.split-h:hover::after, \.split-h\.drag::after/);
  assert.match(css, /body\.split-drag/);
  assert.match(css, /--lw: var\(--lwu,/);
});
