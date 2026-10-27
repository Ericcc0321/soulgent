// Inline images get a three-language name built from sequence number n; guest errors are reported too
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { setLang, table } from "../i18n.js";

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const app = rd("app.js");
const body = (name) => { // body of a top-level function (up to the next top-level function)
  let a = app.indexOf("\nfunction " + name + "(");
  if (a < 0) a = app.indexOf("\nasync function " + name + "(");
  assert.ok(a >= 0, name);
  const b = app.slice(a + 1).search(/\n(?:async )?function /);
  return app.slice(a, b < 0 ? undefined : a + 1 + b);
};

test("attName: with sequence number n, builds the localized \"Image N\" label (图片 N / 圖片 N / Image N) per language; without n (legacy backend) shows name as-is", () => {
  const f = { ref: "3:1:ab", n: 1, name: "图片 1", kind: "image", src: "upload" };
  try {
    setLang("en"); assert.equal(L.attName(f), "Image 1");
    setLang("hans"); assert.equal(L.attName(f), "图片 1");
    setLang("hant"); assert.equal(L.attName({ ...f, n: 2 }), "圖片 2");
    setLang("en");
    assert.equal(L.attName({ ref: "3:1:ab", name: "图片 1", kind: "image" }), "图片 1"); // legacy backend: does not interpret Chinese in name
    assert.equal(L.attName({ path: "/a/b.md", name: "b.md" }), "b.md");
    for (const bad of [0, -1, 1.5, "1", null]) assert.equal(L.attName({ n: bad, name: "x.png" }), "x.png", String(bad));
    assert.equal(L.attName({}), "");
    assert.equal(L.attName(null), "");
  } finally { setLang("hans"); }
});

test("at.imageN has all three columns", () => {
  assert.deepEqual(table()["at.imageN"], ["Image {n}", "图片 {n}", "圖片 {n}"]);
});

test("attachment names always go through attName: attachment card, file-name label, thumbnail alt, \"file is gone · name\", reader/web page title, share file name", () => {
  for (const fn of ["openReader", "openHtml", "atImg", "atCard", "atChip", "atCell", "atGone"]) assert.match(body(fn), /attName\(f\)/, fn);
  assert.doesNotMatch(app, /\bf\.name\b/); // the attachment object's name is not read directly
  assert.match(rd("viewer.js"), /let name = attName\(f\)/);
  assert.doesNotMatch(rd("logic.js") + app, /\/[^/\n]*(图片|圖片)[^/\n]*\/[gimsuy]*\.(test|exec)\(/); // never match the Chinese word for "image" with a regex
});

test("guest errors are reported as usual: errSend does not block by account; the diagnostic stream (diagOn) is still admin-only", () => {
  const s = body("errSend");
  assert.doesNotMatch(s, /st\.guest/);
  assert.match(s, /fetch\("\/api\/diag"/);
  assert.match(body("diagOn"), /if \(st\.guest\) return false/);
  assert.match(body("loadAccount"), /errAccountReady\(\)/);
});
