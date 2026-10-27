import test from "node:test";
import assert from "node:assert/strict";
import { fileUrl, attachPlan, singleBox, KIND_LABEL, kindOpen, fmtSize, imgRefsOf, vwNext, vwScale, vwTapAction } from "../logic.js";

const img = (i) => ({ path: `/a/${i}.png`, name: `${i}.png`, kind: "image", size: 1 });
const imgs = (n) => Array.from({ length: n }, (_, i) => img(i));
const pdf = { path: "/a/x.pdf", name: "x.pdf", kind: "pdf", size: 10 };

test("fileUrl three sources", () => {
  assert.equal(fileUrl({ path: "/Users/demo b/中.png" }, "s1"), "/api/file?p=" + encodeURIComponent("/Users/demo b/中.png") + "&t=full");
  assert.equal(fileUrl({ path: "/x.png" }, "s1", "thumb"), "/api/file?p=%2Fx.png&t=thumb");
  assert.equal(fileUrl({ ref: "12:0" }, "sid/1"), "/api/file?sid=sid%2F1&ref=12%3A0&t=full");
  assert.equal(fileUrl({ ref: "12:0" }, "s1", "thumb"), "/api/file?sid=s1&ref=12%3A0&t=thumb");
  assert.equal(fileUrl({ tok: "a b" }, "s1"), "/api/file?tok=a%20b&t=full");
  assert.equal(fileUrl({ tok: "tk" }, "s1", "thumb"), "/api/file?tok=tk&t=thumb");
});

test("attachPlan image count and mode", () => {
  assert.deepEqual(attachPlan([]), { mode: "none", imgs: [], cards: [], cols: 1 });
  assert.deepEqual(attachPlan(undefined), { mode: "none", imgs: [], cards: [], cols: 1 });
  let p = attachPlan(imgs(1));
  assert.equal(p.mode, "single"); assert.equal(p.cols, 1); assert.equal(p.imgs.length, 1);
  for (const n of [2, 3, 4]) { p = attachPlan(imgs(n)); assert.equal(p.mode, "grid"); assert.equal(p.cols, 2); }
  for (const n of [5, 9]) { p = attachPlan(imgs(n)); assert.equal(p.mode, "grid"); assert.equal(p.cols, 3); assert.equal(p.imgs.length, n); }
  p = attachPlan([pdf]);
  assert.equal(p.mode, "cards"); assert.deepEqual(p.cards, [pdf]); assert.deepEqual(p.imgs, []);
});

test("attachPlan mixed: images go to imgs, the rest to cards, order preserved", () => {
  const a = img(0), b = img(1);
  const md = { path: "/m.md", name: "m.md", kind: "md" };
  const p = attachPlan([pdf, a, md, b]);
  assert.equal(p.mode, "grid"); assert.equal(p.cols, 2);
  assert.deepEqual(p.imgs, [a, b]); assert.deepEqual(p.cards, [pdf, md]);
  const q = attachPlan([a, pdf]);
  assert.equal(q.mode, "single"); assert.deepEqual(q.cards, [pdf]);
});

test("singleBox", () => {
  assert.deepEqual(singleBox(740, 720), { wPct: 0.68, h: 260, ratio: 740 / 720 });
  assert.deepEqual(singleBox(100, 80), { wPct: 0.68, h: 80, ratio: 1.25 });
  assert.deepEqual(singleBox(740, 720, 0.5, 100), { wPct: 0.5, h: 100, ratio: 740 / 720 });
  assert.deepEqual(singleBox(0, 0), { wPct: 0.68, h: 0, ratio: 4 / 3 });
  assert.deepEqual(singleBox(), { wPct: 0.68, h: 0, ratio: 4 / 3 });
  assert.deepEqual(singleBox(null, 50), { wPct: 0.68, h: 0, ratio: 4 / 3 });
});

test("KIND_LABEL / kindOpen full table", () => {
  assert.deepEqual(KIND_LABEL, { pdf: "PDF", doc: "Word", sheet: "表格", slide: "PPT", md: "Markdown", text: "文本", html: "网页", data: "数据" });
  for (const k of ["pdf", "doc", "sheet", "slide"]) assert.equal(kindOpen(k), "native");
  for (const k of ["md", "text", "data"]) assert.equal(kindOpen(k), "reader");
  assert.equal(kindOpen("html"), "html");
});

test("fmtSize", () => {
  assert.equal(fmtSize(0), "0 B");
  assert.equal(fmtSize(1023), "1023 B");
  assert.equal(fmtSize(1024), "1.0 KB");
  assert.equal(fmtSize(137293), "134.1 KB");
  assert.equal(fmtSize(1048576), "1.0 MB");
  assert.equal(fmtSize(1258291), "1.2 MB");
});

test("imgRefsOf", () => {
  const a = img(0);
  assert.deepEqual(imgRefsOf([pdf, a]), [a]);
  assert.deepEqual(imgRefsOf(undefined), []);
});

test("vwNext does not wrap around", () => {
  assert.equal(vwNext(0, -1, 3), 0);
  assert.equal(vwNext(2, 1, 3), 2);
  assert.equal(vwNext(0, 1, 3), 1);
  assert.equal(vwNext(1, -1, 3), 0);
  assert.equal(vwNext(0, 1, 0), 0);
});

test("vwScale clamps to 1-4", () => {
  assert.equal(vwScale(1, 5), 4);
  assert.equal(vwScale(2, 0.1), 1);
  assert.equal(vwScale(1, 2), 2);
});

test("viewer.js source and shell registration", async () => {
  const { readFileSync } = await import("node:fs");
  const rd = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
  const v = rd("../viewer.js");
  for (const k of ["touchstart", "touchmove", "replaceState", "navigator.share", "export function openViewer", "export function closeViewer", "vw-open", "prefers-reduced-motion"]) assert.ok(v.includes(k), k);
  assert.ok(!v.includes("pushState"));
  assert.match(rd("../sw.js"), /SHELL_TEXT = \[[^\]]*"\/viewer\.js"/);
  assert.match(rd("../../Caddyfile"), /@nocache path[^\n]*\/viewer\.js/);
  const html = rd("../index.html");
  assert.ok(html.includes("/viewer.js"));
  assert.ok(html.includes('id="vw"'));
  assert.match(rd("../style.css"), /body\.vw-open\s*\{\s*overflow:\s*hidden/);
});

test("vwTapAction touch classification", () => {
  const A = (o) => vwTapAction({ moved: 0, dt: 80, sinceLastTap: 1e9, scale: 1, dy: 0, dx: 0, n: 3, ...o });
  assert.equal(A({}), "tap");
  assert.equal(A({ sinceLastTap: 150 }), "double");
  assert.equal(A({ sinceLastTap: 150, scale: 2 }), "double");
  assert.equal(A({ scale: 2 }), "tap");
  assert.equal(A({ scale: 2, moved: 80, dx: 80 }), "none");
  assert.equal(A({ moved: 60, dx: -60 }), "next");
  assert.equal(A({ moved: 60, dx: 60 }), "prev");
  assert.equal(A({ moved: 60, dx: 60, n: 1 }), "none");
  assert.equal(A({ moved: 90, dy: 90 }), "close");
  assert.equal(A({ moved: 70, dy: 70 }), "none");
  assert.equal(A({ moved: 90, dy: 90, scale: 2 }), "none");
  assert.equal(A({ moved: 90, dy: -90 }), "none");
});

// ---- text/web reader page (source assertions) ----
import { readFileSync } from "node:fs";
const APP_SRC = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const CSS_SRC = readFileSync(new URL("../style.css", import.meta.url), "utf8");

test("reader page: openReader / openHtml go through #fs and carry the keywords", () => {
  assert.match(APP_SRC, /function openReader\(/);
  assert.match(APP_SRC, /function openHtml\(/);
  assert.ok(APP_SRC.includes('openFs("fread"'));
  assert.ok(APP_SRC.includes('openFs("fhtml"'));
  assert.ok(APP_SRC.includes("X-Truncated"));
  assert.ok(APP_SRC.includes('t("c.fileGone")')); // copy lives in the i18n table
  assert.ok(APP_SRC.includes('t("at.cut")'));
  assert.ok(APP_SRC.includes('class="at-pre"') || APP_SRC.includes('"at-pre"'));
});

test("web attachment iframe: sandbox has only allow-scripts, never allow-same-origin", () => {
  assert.ok(APP_SRC.includes('sandbox="allow-scripts"') || APP_SRC.includes('"sandbox", "allow-scripts"'));
  assert.ok(!APP_SRC.includes("allow-same-origin"));
});

test("reader page styles exist", () => {
  assert.ok(CSS_SRC.includes(".at-pre"));
  assert.ok(CSS_SRC.includes(".at-frame"));
});

// ---- attachments drawn inside bubbles ----
import { bubbleActs, stripImageMarks, mdImgMatch, kindByName } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

test("bubbleActs: with files it is the attachment menu (share / forward / copypath)", () => {
  const p = [{ path: "/tmp/a.png", name: "a.png", kind: "image" }];
  const a = bubbleActs({ who: "self", files: p });
  assert.ok(a.includes("share")); assert.ok(a.includes("copypath")); assert.ok(a.includes("forward"));
  assert.ok(!a.includes("copy")); assert.ok(!a.includes("quote")); assert.ok(!a.includes("recall"));
  assert.ok(!bubbleActs({ files: p, guest: true }).includes("forward")); // guests get no forward
  const r = bubbleActs({ files: [{ ref: "3:0", name: "图片 1", kind: "image" }] });
  assert.ok(r.includes("share")); assert.ok(!r.includes("copypath")); assert.ok(!r.includes("forward")); // no path: nothing to copy/forward
  assert.deepEqual(bubbleActs({ who: "self", wide: true, files: [] }), ["copy", "quote", "forward"]); // empty files adds nothing
  assert.deepEqual(bubbleActs({ who: "self", wide: true }), ["copy", "quote", "forward"]);
});

test("stripImageMarks removes [Image #N]", () => {
  assert.equal(stripImageMarks("看这个 [Image #1]"), "看这个");
  assert.equal(stripImageMarks("[Image #1] [Image #2]\n两张"), "两张");
  assert.equal(stripImageMarks("[Image #3]"), "");
  assert.equal(stripImageMarks("没有标记"), "没有标记");
  assert.equal(stripImageMarks(undefined), "");
});

test("mdImgMatch: Markdown image paths match files", () => {
  const f = { path: "/tmp/soulgent/中 文.png", name: "中 文.png", kind: "image" };
  const files = [{ path: "/a.pdf", kind: "pdf" }, f];
  assert.equal(mdImgMatch(files, "/tmp/soulgent/中 文.png"), f);
  assert.equal(mdImgMatch(files, "file:///tmp/soulgent/中 文.png"), f);
  assert.equal(mdImgMatch(files, "/tmp/soulgent/%E4%B8%AD%20%E6%96%87.png"), f);
  assert.equal(mdImgMatch(files, "/a.pdf"), null); // not an image
  assert.equal(mdImgMatch(files, "/nope.png"), null);
  assert.equal(mdImgMatch(undefined, "/x.png"), null);
  assert.equal(mdImgMatch(files, "%E0%A4%A"), null); // bad encoding does not throw
});

test("kindByName by extension", () => {
  assert.equal(kindByName("a.PDF"), "pdf");
  assert.equal(kindByName("a.docx"), "doc");
  assert.equal(kindByName("a.xlsx"), "sheet");
  assert.equal(kindByName("a.csv"), "sheet");
  assert.equal(kindByName("a.pptx"), "slide");
  assert.equal(kindByName("a.md"), "md");
  assert.equal(kindByName("a.html"), "html");
  assert.equal(kindByName("a.json"), "data");
  assert.equal(kindByName("a.jpg"), "image");
  assert.equal(kindByName("a.log"), "text");
  assert.equal(kindByName("noext"), "text");
});

test("bubble attachment source: structure, lazy loading, broken image, menu", () => {
  for (const k of ["at-wrap", "at-img", "at-card", "at-gone", 'loading="lazy"', "at-loading", "openViewer(", "fileTapAction(", "openReader(", "openHtml(", "createObjectURL", 't("chat.openedFiles")']) assert.ok(APP_SRC.includes(k), k);
  assert.match(APP_SRC, /import \{ openViewer[^}]*\} from "\.\/viewer\.js"/);
  // broken image: a capture-phase error listener (also works for cached cloned nodes) swaps .at-img for .at-gone
  assert.match(APP_SRC, /addEventListener\("error",[\s\S]{0,400}at-gone/);
  assert.ok(APP_SRC.includes('t("bm." + String(k))')); // menu labels such as save/share and copy path are looked up via bm.<item>
  assert.ok(readFileSync(new URL("../viewer.js", import.meta.url), "utf8").includes("navigator.share({ files")); // sharing lives in viewer.js shareFile
  assert.ok(!APP_SRC.includes('" [图片]"'));
  assert.ok(!/innerHTML\s*=\s*[^;]*(?:\.name|\.path)/.test(APP_SRC)); // never build innerHTML from file names/paths
});

test("bubble attachment styles", () => {
  assert.match(CSS_SRC, /\.at-wrap\s*\{/);
  assert.match(CSS_SRC, /\.at-img img\s*\{[^}]*object-fit:\s*cover/);
  assert.match(CSS_SRC, /\.at-single[^{]*\{[^}]*max-height:\s*260px/);
  assert.match(CSS_SRC, /\.at-grid[^{]*\.at-img[^{]*\{[^}]*aspect-ratio:\s*1/);
  assert.match(CSS_SRC, /\.at-loading::after \{[^}]*animation: at-breathe/);
});

// ---- edge cases ----
test("guests have no copypath; stripImageMarks preserves other whitespace", () => {
  const p = [{ path: "/tmp/a.png", name: "a.png", kind: "image" }];
  assert.deepEqual(bubbleActs({ files: p, guest: true }), ["share"]);
  assert.deepEqual(bubbleActs({ files: p }), ["share", "forward", "copypath"]);
  assert.equal(stripImageMarks("a  b [Image #1]\n  c "), "a  b\n  c ");
  assert.equal(stripImageMarks("[Image #1] x  y"), "x  y");
  assert.equal(stripImageMarks("  缩进\t保留  "), "  缩进\t保留  "); // no marker: returned as-is
});

test("card chevron, color, 56px, broken image shows name, image-only bubble, pend preview release, data-fkey", () => {
  assert.ok(APP_SRC.includes('h("span", "at-go", "›")'));
  assert.match(CSS_SRC, /\.at-card\[data-kind="html"\] \.at-ic \{ background: #8e5bd8/);
  assert.match(CSS_SRC, /\.at-card\[data-kind="data"\] \.at-ic \{ background: #1aa3a3/);
  assert.doesNotMatch(CSS_SRC, /\[data-kind="image"\] \.at-ic \{ background: #7a57d1/);
  assert.match(CSS_SRC, /\.at-card \{[^}]*height: 56px/);
  assert.ok(APP_SRC.includes('t("at.goneName", { name: nm })'));
  assert.ok(APP_SRC.includes('g.dataset.fkey = b.dataset.fkey'));
  assert.ok(APP_SRC.includes('.at-inl[data-fkey]'));
  // image-only user message: blue bubble .at-only, attachments drawn inside the bubble, receipt still drawn into the bubble
  assert.ok(APP_SRC.includes('(onlyAt ? " at-only" : "")'));
  assert.match(APP_SRC, /if \(onlyAt\) el\.append\(atn\);\n\s*if \(rc\) el\.append\(rcMark\(rc, el\)\)/); // atn = userAt (including images transferred over)
  assert.match(APP_SRC, /el\.classList\.contains\("at-only"\)\) \{ openAttMenu\(null, el\)/);
  // pend holds its own preview URL and releases it only at the end; the success path does not defer releasing the attachment bar's URL
  assert.ok(APP_SRC.includes("local: tr.isImg ? URL.createObjectURL(tr.file)")); // the loop variable is tr because t is the translate function
  assert.match(APP_SRC, /if \(!out\.includes\(p\)\) \{ carryFrom\(p, items, st\.detailId\); pendFree\(p\); \}/); // transfer first; URLs that were transferred are not released by pendFree
  assert.match(APP_SRC, /if \(!rest\.includes\(p\)\) pendFree\(p\)/);
  assert.ok(!APP_SRC.includes("OUTGOING_MS + 5000"));
});
