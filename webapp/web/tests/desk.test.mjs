// Desktop wide layout: detection, columns, tab switching, guest auto-open; paste content classification
import { test } from "node:test";
import assert from "node:assert/strict";
import { WIDE_MQ, wideMatch, wideSplit, keepDetailOnTab, guestAutoOpen, pasteKind } from "../logic.js";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

test("wide detection: only wide enough with a mouse pointer counts", () => {
  assert.equal(wideMatch(1280, true, true), true);
  assert.equal(wideMatch(700, true, true), true);
  assert.equal(wideMatch(699, true, true), false);
  assert.equal(wideMatch(1024, false, false), false); // iPad landscape (touch)
  assert.equal(wideMatch(402, false, false), false);  // iPhone
  assert.equal(wideMatch(1280, true, false), false);
});

test("the CSS media query matches WIDE_MQ", () => {
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  assert.ok(css.includes("@media " + WIDE_MQ + " {"), "style.css must contain @media " + WIDE_MQ);
});

test("columns: admin messages and contacts get two columns; guests and other tabs do not", () => {
  assert.equal(wideSplit("msg", false), true);
  assert.equal(wideSplit("contacts", false), true);
  assert.equal(wideSplit("me", false), false);
  assert.equal(wideSplit("zones", false), false);
  assert.equal(wideSplit("board", false), false);
  assert.equal(wideSplit("msg", true), false);
});

test("tab switching: the chat page stays open between the two-column tabs; others are closed", () => {
  assert.equal(keepDetailOnTab("msg", "contacts", false), true);
  assert.equal(keepDetailOnTab("contacts", "msg", false), true);
  assert.equal(keepDetailOnTab("msg", "me", false), false);
  assert.equal(keepDetailOnTab("zones", "msg", false), false);
  assert.equal(keepDetailOnTab("msg", "me", true), false);
});

test("a wide guest view auto-opens the bound session", () => {
  const base = { wide: true, guest: true, tab: "msg", detailId: null, searching: false, sessions: [{ id: "c1" }] };
  assert.equal(guestAutoOpen(base), "c1");
  assert.equal(guestAutoOpen({ ...base, wide: false }), null);   // phones do not auto-open
  assert.equal(guestAutoOpen({ ...base, guest: false }), null);  // admins do not auto-open
  assert.equal(guestAutoOpen({ ...base, tab: "me" }), null);
  assert.equal(guestAutoOpen({ ...base, detailId: "c1" }), null); // already open
  assert.equal(guestAutoOpen({ ...base, sessions: [] }), null);   // session offline: stay on the list to see the hint
  assert.equal(guestAutoOpen(null), null);
});

test("paste classification", () => {
  const png = { type: "image/png" };
  const pdf = { type: "application/pdf" };
  assert.equal(pasteKind(["text/plain"], [], "你好"), "text");                    // plain text
  assert.equal(pasteKind(["Files"], [png], ""), "files");                         // screenshot
  assert.equal(pasteKind(["text/html", "Files"], [png], ""), "files");            // "copy image" on a web page
  assert.equal(pasteKind(["text/plain", "Files"], [pdf], "a.pdf"), "files");      // copying a file in the file manager
  assert.equal(pasteKind(["text/plain", "Files"], [png], "a.png"), "files");      // copying an image file in the file manager
  assert.equal(pasteKind(["text/plain", "text/html", "text/rtf", "Files"], [png], "A1\tB1"), "text"); // copying a spreadsheet range
  assert.equal(pasteKind(["text/plain", "text/html", "Files"], [png, pdf], "x"), "files"); // mixed with non-images: treated as attachments
  assert.equal(pasteKind(["text/html", "Files"], [png], "  "), "files");
  assert.equal(pasteKind(null, null, null), "text");
});

// ===== wide layout fills the window (no centered 1100/860 column with side margins) =====
const wideCss = () => {
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  const i = css.indexOf("@media " + WIDE_MQ + " {");
  return css.slice(i);
};
test("wide fill: the whole block is not width-limited or centered; rail 80px, list column 370-420px", () => {
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  const i = css.indexOf("@media " + WIDE_MQ + " {");
  const blk = css.slice(i, css.indexOf("\n}\n", i));
  assert.doesNotMatch(blk, /--fw:\s*min\(1100px/);
  assert.match(blk, /--fw:\s*100vw/);
  assert.match(blk, /--fx:\s*0px/);
  assert.match(blk, /--rw:\s*80px/);
  assert.match(blk, /--lw:\s*var\(--lwu,\s*clamp\(370px,[^)]*,\s*420px\)\)/);
});
test("chat content: no 860px centering; bubbles 72% / max 980px", () => {
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  const i = css.indexOf("@media " + WIDE_MQ + " {");
  const blk = css.slice(i, css.indexOf("\n}\n", i));
  assert.doesNotMatch(blk, /860px/);
  assert.match(blk, /\.older,\s*\.list\s*\{[^}]*max-width:\s*none/);
  const all = wideCss();
  assert.match(all, /--bw:\s*min\(calc\(var\(--dw\)\s*\*\s*\.72\),\s*980px\)/);
  assert.match(all, /\.list\s*\{[^}]*--bmax:\s*var\(--bw\)/);
  assert.match(all, /\.list \.cg\.ag \.cg-col > \.m[^{]*\{[^}]*max-width:\s*min\(100%,\s*980px\)/);
  assert.match(all, /\.list \.cg\.hu\.me \.cg-col > \.m[^{]*\{[^}]*max-width:\s*min\(100%,\s*var\(--bw\)\)/);
});
test("the chat pane fills the remaining width (detail flush with the window's right edge; input area the same width)", () => {
  const blk = wideCss();
  assert.match(blk, /\.detail \{\s*left: calc\(var\(--cx\) \+ var\(--lw\)\); right: var\(--fx\);/);
  assert.match(blk, /\.fs \{ left: var\(--cx\); right: var\(--fx\); \}/);
  assert.match(blk, /--dw:\s*calc\(100vw - var\(--cx\) - var\(--lw\)\)/);
});
