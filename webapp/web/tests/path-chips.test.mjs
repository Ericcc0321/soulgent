// Paths in body text become clickable file-name chips; de-duplication at the bottom; recalling an in-progress message needs confirmation
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathChips, chipFiles, atBottom, recallAsk, RECALL_ASK } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const png = { path: "/tmp/soulgent/faces3.png", name: "faces3.png", kind: "image", src: "text" };
const pdf = { path: "~/Desktop/报告.pdf", name: "报告.pdf", kind: "pdf", src: "text" };
const opn = { path: "/tmp/o.pdf", name: "o.pdf", kind: "pdf", src: "open" };
const up = { kind: "image", src: "upload", ref: "3:0", name: "图片 1" };

test("pathChips: only replaces paths whose file has src=text, the rest stays as is", () => {
  const s = "图在 /tmp/soulgent/faces3.png ，报告 ~/Desktop/报告.pdf 。另有 /tmp/x.png 和 /tmp/o.pdf";
  const r = pathChips(s, [png, pdf, opn]);
  assert.deepEqual(r, [
    { t: "text", text: "图在 " },
    { t: "chip", text: "/tmp/soulgent/faces3.png", f: png },
    { t: "text", text: " ，报告 " },
    { t: "chip", text: "~/Desktop/报告.pdf", f: pdf },
    { t: "text", text: " 。另有 /tmp/x.png 和 /tmp/o.pdf" },
  ]);
  assert.equal(r.map((x) => x.text).join(""), s); // joining the parts gives back the original text
});

test("pathChips: returns null when nothing to replace; bad input does not throw", () => {
  assert.equal(pathChips("没有路径", [png]), null);
  assert.equal(pathChips("/tmp/soulgent/faces3.png", []), null);
  assert.equal(pathChips("/tmp/soulgent/faces3.png", null), null);
  assert.equal(pathChips("", [png]), null);
  assert.equal(pathChips(null, [png]), null);
  assert.equal(pathChips("/tmp/soulgent/faces3.png", [up, { kind: "pdf" }, null]), null); // guest: only uploads
});

test("pathChips: boundaries match the server regex (no letter or / directly before or after)", () => {
  assert.equal(pathChips("a/tmp/soulgent/faces3.png", [png]), null);
  assert.equal(pathChips("/tmp/soulgent/faces3.pngx", [png]), null);
  assert.equal(pathChips("x/Users/demo/tmp/soulgent/faces3.png", [png]), null);
  // CJK characters, punctuation and backticks directly adjacent count as boundaries
  const r = pathChips("见`/tmp/soulgent/faces3.png`。", [png]);
  assert.equal(r[1].t, "chip");
  assert.equal(r[1].text, "/tmp/soulgent/faces3.png");
  // trailing period: a "." right after .png is still recognized (same as the server)
  assert.equal(pathChips("看 /tmp/soulgent/faces3.png.", [png])[1].t, "chip");
});

test("pathChips: /private/tmp is equivalent to /tmp; every occurrence of the same path is replaced", () => {
  const r = pathChips("/private/tmp/soulgent/faces3.png 和 /tmp/soulgent/faces3.png", [png]);
  assert.equal(r.filter((x) => x.t === "chip").length, 2);
  assert.equal(r[0].text, "/private/tmp/soulgent/faces3.png"); // the chip keeps the original text; copying the path still uses f.path
  assert.equal(r[0].f, png);
});

test("pathChips: a path wrapped in parentheses is cut at the parenthesis", () => {
  const f = { path: "/Users/demo/out/a.md", name: "a.md", kind: "md", src: "text" };
  const r = pathChips("(/Users/demo/out/a.md)", [f]);
  assert.deepEqual(r.map((x) => x.t), ["text", "chip", "text"]);
});

test("chipFiles: only picks src=text entries that have a path", () => {
  assert.deepEqual(chipFiles([png, pdf, opn, up]), [png, pdf]);
  assert.deepEqual(chipFiles(undefined), []);
});

test("atBottom: images stay (except inline Markdown images); non-image files that already have a chip in the body get no card", () => {
  const md = { path: "/tmp/m.png", name: "m.png", kind: "image", src: "md" };
  const files = [png, pdf, opn, md];
  const inl = new Set(["/tmp/m.png"]);
  const chip = new Set([png.path, pdf.path]);
  assert.deepEqual(atBottom(files, inl, chip), [png, opn]);
  assert.deepEqual(atBottom(files, new Set(), new Set()), files);
  assert.deepEqual(atBottom(undefined, inl, chip), []);
  assert.deepEqual(atBottom([up], inl, chip), [up]); // uploaded images without a path are unaffected
});

test("recallAsk: confirmation only when read + busy + admin", () => {
  assert.equal(recallAsk("read", "busy", false), true);
  assert.equal(recallAsk("read", "busy", true), false); // guests are not asked
  assert.equal(recallAsk("sent", "busy", false), false);
  assert.equal(recallAsk("read", "idle", false), false);
  assert.equal(recallAsk("read", "waiting", false), false);
  assert.equal(recallAsk(undefined, undefined, false), false);
  assert.equal(RECALL_ASK.q, "它正在处理这条，撤回会打断它这一轮。继续？");
  assert.equal(RECALL_ASK.ok, "打断并撤回");
});

test("app.js wiring: chips are in the delegated click / long-press selector, the bottom uses atBottom, recall uses recallAsk", () => {
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  assert.match(app, /\.at-chip\[data-f\]/);
  assert.match(app, /atBottom\(/);
  assert.match(app, /recallAsk\(/);
  assert.match(app, /pathChips\(/);
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  assert.match(css, /\.md \.at-chip\s*\{[^}]*var\(--brand\)/);
});
