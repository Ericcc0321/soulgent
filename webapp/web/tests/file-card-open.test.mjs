// File card: on desktop a tap downloads directly (?dl=1), on phones it hands off to the system preview; the long-press menu offers Download on desktop and Save/Share on phones
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { setLang, t } from "../i18n.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");

test("isDesktopPointer: only accepts (hover: hover) and (pointer: fine)", () => {
  const seen = [];
  const mm = (on) => (q) => { seen.push(q); return { matches: on }; };
  assert.equal(L.isDesktopPointer(mm(true)), true);
  assert.equal(seen[0], "(hover: hover) and (pointer: fine)");
  assert.equal(L.isDesktopPointer(mm(false)), false);
  assert.equal(L.isDesktopPointer(null), false);
  assert.equal(L.isDesktopPointer(() => { throw new Error("x"); }), false);
});
test("fileOpenHow: on desktop Word/Excel/PPT download; PDF still opens in a new tab; the in-app reader still applies; phones use the system preview", () => {
  for (const k of ["doc", "sheet", "slide"]) {
    assert.equal(L.fileOpenHow(k, true), "download", k);
    assert.equal(L.fileOpenHow(k, false), "native", k);
  }
  assert.equal(L.fileOpenHow("pdf", true), "native");
  assert.equal(L.fileOpenHow("pdf", false), "native");
  for (const d of [true, false]) {
    assert.equal(L.fileOpenHow("md", d), "reader");
    assert.equal(L.fileOpenHow("text", d), "reader");
    assert.equal(L.fileOpenHow("data", d), "reader");
    assert.equal(L.fileOpenHow("html", d), "html");
  }
});
test("fileUrl: the dl parameter is carried for all three sources and omitted by default; v is still present", () => {
  assert.equal(L.fileUrl({ path: "/a/报表.xlsx" }, "s"), "/api/file?p=%2Fa%2F%E6%8A%A5%E8%A1%A8.xlsx&t=full");
  assert.equal(L.fileUrl({ path: "/a/b.xlsx", v: "9" }, "s", "full", true), "/api/file?p=%2Fa%2Fb.xlsx&t=full&dl=1&v=9");
  assert.match(L.fileUrl({ tok: "T" }, "s", "full", true), /^\/api\/file\?tok=T&t=full&dl=1$/);
  assert.match(L.fileUrl({ ref: "1:1:ab" }, "sid", "full", true), /&dl=1$/);
});
test("bubbleActs: the attachment menu offers Download on desktop and Save/Share on phones; forward and copy-path are offered; guests get only the first item", () => {
  const f = [{ path: "/a/b.xlsx" }];
  assert.deepEqual(L.bubbleActs({ files: f, desktop: true }), ["download", "forward", "copypath"]);
  assert.deepEqual(L.bubbleActs({ files: f, desktop: false }), ["share", "forward", "copypath"]);
  assert.deepEqual(L.bubbleActs({ files: f }), ["share", "forward", "copypath"]);
  assert.deepEqual(L.bubbleActs({ files: [{ tok: "x" }], guest: true, desktop: true }), ["download"]);
});
test("bm.download in three languages", () => {
  for (const [lg, w] of [["en", "Download"], ["hans", "下载"], ["hant", "下載"]]) { setLang(lg); assert.equal(t("bm.download"), w, lg); }
  setLang("hans");
});
test("app.js wiring: taps go through fileOpenHow, downloads use <a download>, plus the menu download item", () => {
  assert.match(app, /fileTapAction\(f\.kind, isDesktopPointer\(\)\)/); // fileOpenHow is wrapped by fileTapAction
  assert.match(rd("viewer.js"), /fileUrl\(f, sid, "full", true\)/); // downloadFile lives in viewer.js
  assert.match(app, /if \(k === "download"\) downloadFile\(f, sid\)/);
  assert.match(app, /desktop: isDesktopPointer\(\)/);
});
test("service worker and shell version", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
