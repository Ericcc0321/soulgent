// Tapping a file card in the home-screen app on phones: native fetches the file in-page and opens a share sheet, with an invisible-download fallback, and never calls window.open
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");
const viewer = rd("viewer.js");
const fnBody = (src, re) => { const i = src.search(re); assert.ok(i >= 0, String(re)); const j = src.indexOf("\n}\n", i); return src.slice(i, j); };

test("fileTapAction: on phones pdf/doc/sheet/slide use share; on desktop Office files still download; pdf also uses share on desktop", () => {
  for (const k of ["pdf", "doc", "sheet", "slide"]) assert.equal(L.fileTapAction(k, false), "share", k);
  for (const k of ["doc", "sheet", "slide"]) assert.equal(L.fileTapAction(k, true), "download", k);
  assert.equal(L.fileTapAction("pdf", true), "share");
});
test("fileTapAction: html / reader are returned as-is and native is never returned", () => {
  assert.equal(L.fileTapAction("html", false), "html");
  assert.equal(L.fileTapAction("md", false), "reader");
  assert.equal(L.fileTapAction("text", true), "reader");
  for (const k of ["pdf", "doc", "sheet", "slide", "html", "md", "text", "data", "image"]) for (const d of [true, false]) assert.notEqual(L.fileTapAction(k, d), "native");
});
test("shareFailPlan: Abort does nothing, NotAllowed asks for another tap, anything else falls back to download; never open", () => {
  assert.equal(L.shareFailPlan("AbortError"), "none");
  assert.equal(L.shareFailPlan("NotAllowedError"), "retry");
  for (const n of [undefined, "", "TypeError", "NotSupportedError"]) assert.equal(L.shareFailPlan(n), "download");
});
test("source: atOpen and shareFile do not contain window.open", () => {
  assert.doesNotMatch(fnBody(app, /function atOpen\(/), /window\.open/);
  assert.doesNotMatch(fnBody(viewer, /export async function shareFile\(/), /window\.open/);
});
test("source: downloadFile lives only in viewer.js and app.js reuses it; downloads use ?dl=1", () => {
  assert.match(viewer, /export function downloadFile\(/);
  assert.doesNotMatch(app, /function downloadFile\(/);
  assert.match(app, /import \{[^}]*downloadFile[^}]*\} from "\.\/viewer\.js"/);
  assert.match(fnBody(viewer, /export function downloadFile\(/), /fileUrl\(f, sid, "full", true\)/);
});
test("source: shareFile sends same-origin credentials, a non-ok fetch only shows a hint, NotAllowed caches the File", () => {
  const b = fnBody(viewer, /export async function shareFile\(/);
  assert.match(b, /credentials: "same-origin"/);
  assert.match(b, /if \(!r\.ok\) \{[^}]*onMsg[^}]*return;/);
  assert.match(b, /pendShare = \{ url, file \}/);
  assert.match(b, /at\.retryTap/);
});
test("source: the atOpen share branch has an at-loading state and guards against repeated taps; the new-tab button is desktop only", () => {
  const b = fnBody(app, /function atOpen\(/);
  assert.match(b, /how === "share"/);
  assert.match(b, /classList\.contains\("at-loading"\)\) return/);
  assert.match(b, /classList\.remove\("at-loading"\)/);
  assert.match(fnBody(app, /function openHtml\(/), /if \(isDesktopPointer\(\)\) bar\.append\(nb\)/);
});
