// Bubble attachments: version parameter, single-image ratio, broken-image retry, viewer sharing, noopener
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileUrl, singleFit, atBrokenNext, atRetryDue, AT_RETRY_MS } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const rd = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const APP_SRC = rd("../app.js");
const VW_SRC = rd("../viewer.js");
const CSS_SRC = rd("../style.css");

test("fileUrl: appends &v= when v is set, otherwise not", () => {
  assert.equal(fileUrl({ path: "/x.png", v: "1700000000123000000" }, "s1", "thumb"), "/api/file?p=%2Fx.png&t=thumb&v=1700000000123000000");
  assert.equal(fileUrl({ path: "/x.png", v: "a b" }, "s1"), "/api/file?p=%2Fx.png&t=full&v=a%20b");
  assert.equal(fileUrl({ tok: "tk", v: "9" }, "s1", "thumb"), "/api/file?tok=tk&t=thumb&v=9");
  assert.equal(fileUrl({ path: "/x.png" }, "s1"), "/api/file?p=%2Fx.png&t=full");
  assert.equal(fileUrl({ path: "/x.png", v: "" }, "s1"), "/api/file?p=%2Fx.png&t=full");
});

test("singleFit: keeps the original ratio, max height 260, max width 68vw; invalid sizes return null", () => {
  assert.deepEqual(singleFit(800, 600), { ratio: 800 / 600, width: "min(68vw, 347px)" });
  assert.deepEqual(singleFit(500, 1000), { ratio: 0.5, width: "min(68vw, 130px)" }); // portrait image: height 260
  assert.deepEqual(singleFit(100, 50), { ratio: 2, width: "min(68vw, 100px)" }); // small images are not enlarged
  assert.deepEqual(singleFit(3000, 500), { ratio: 6, width: "min(68vw, 1560px)" }); // wide image: limited by 68vw, height shrinks proportionally
  assert.equal(singleFit(0, 10), null);
  assert.equal(singleFit(NaN, 10), null);
});

test("broken-image retry: retry on the next redraw after the first failure, then at most once per 30 seconds per attachment", () => {
  assert.equal(AT_RETRY_MS, 30000);
  const t1 = atBrokenNext(undefined, 5000);
  assert.equal(t1, 5000 - AT_RETRY_MS);
  assert.equal(atRetryDue(t1, 7000), true); // first failure: retry immediately on the next redraw (about 2 seconds later)
  const t2 = atBrokenNext(t1, 7000);
  assert.equal(t2, 7000);
  assert.equal(atRetryDue(t2, 7000 + 29999), false);
  assert.equal(atRetryDue(t2, 7000 + 30000), true);
  assert.equal(atRetryDue(undefined, 1), false);
});

test("broken image: atGone records the failure and drops the cache key, atNode rebuilds when due, a successful load clears the record", () => {
  assert.match(APP_SRC, /const atBroken = new Map\(\)/);
  assert.match(APP_SRC, /function atGone\(b\) \{[\s\S]*?atBroken\.set\(/);
  assert.match(APP_SRC, /function atGone\(b\) \{[\s\S]*?atCache\.delete\(/);
  assert.match(APP_SRC, /function atNode\([\s\S]*?atRetryDue\(/);
  assert.match(APP_SRC, /atBroken\.delete\(/);
});

test("single image keeps its ratio after loading: atFit is called from onload and the capture listener, and only touches .at-single", () => {
  assert.match(APP_SRC, /function atFit\(b, im\) \{[\s\S]*?at-single[\s\S]*?singleFit\(im\.naturalWidth, im\.naturalHeight\)/);
  assert.match(APP_SRC, /im\.onload = \(\) => \{[^}]*atFit\(b, im\)/);
  assert.match(APP_SRC, /list\.addEventListener\("load", \(e\) => \{[\s\S]*?atFit\(b, e\.target\)/);
});

test("window.open always passes noopener", () => {
  const all = [...APP_SRC.matchAll(/window\.open\((.*)\);?$/gm), ...VW_SRC.matchAll(/window\.open\((.*)\);?$/gm)].map((m) => m[1]);
  assert.ok(all.length >= 1); // file cards and shareFile do not call window.open; only the desktop html "open in new tab" remains
  for (const a of all) assert.match(a, /"_blank", "noopener"\)?$/, a);
});

test("viewer: sharing goes through shareFile (shares the original file), .vw-img does not disable long press", () => {
  assert.match(VW_SRC, /export async function shareFile\(/);
  assert.match(VW_SRC, /function share\(\) \{[\s\S]*?shareFile\(/);
  assert.doesNotMatch(VW_SRC, /navigator\.share\(\{ title/);
  assert.match(APP_SRC, /import \{[^}]*shareFile[^}]*\} from "\.\/viewer\.js"/);
  assert.doesNotMatch(APP_SRC, /async function atShare\(/);
  assert.doesNotMatch(CSS_SRC, /\.vw-img \{[^}]*touch-callout/);
});

// shareFile behavior: fetch / navigator / window / location are replaced by stubs
async function withEnv(env, fn) {
  const keys = ["fetch", "navigator", "window", "location", "document"];
  const saved = keys.map((k) => Object.getOwnPropertyDescriptor(globalThis, k));
  for (const k of keys) Object.defineProperty(globalThis, k, { value: env[k], configurable: true, writable: true });
  try { return await fn(); } finally {
    keys.forEach((k, i) => { if (saved[i]) Object.defineProperty(globalThis, k, saved[i]); else delete globalThis[k]; });
  }
}
const { shareFile } = await import("../viewer.js");
const okFetch = async () => ({ ok: true, headers: new Headers(), blob: async () => new Blob(["x"], { type: "image/png" }) });

test("shareFile: shares the file when file sharing is supported", async () => {
  const shared = [], opened = [];
  await withEnv({
    fetch: okFetch, location: { href: "https://h/" },
    navigator: { canShare: () => true, share: async (d) => { shared.push(d); } },
    window: { open: (...a) => { opened.push(a); return null; } },
  }, () => shareFile({ path: "/x.png", name: "x.png", v: "7" }, "s1"));
  assert.equal(shared.length, 1);
  assert.equal(shared[0].files[0].name, "x.png");
  assert.equal(opened.length, 0);
});

// stub for an invisible <a download>
const fakeDoc = (clicks) => ({ createElement: () => { const a = { click() { clicks.push(a.href); }, remove() {} }; return a; }, body: { append() {} } });

test("shareFile: file sharing unsupported -> invisible download (?dl=1), no window.open", async () => {
  const opened = [], clicks = [];
  await withEnv({
    fetch: okFetch, location: { href: "https://h/" },
    navigator: { canShare: () => false },
    window: { open: (...a) => { opened.push(a); return null; } }, document: fakeDoc(clicks),
  }, () => shareFile({ path: "/x.png", name: "x.png", v: "7" }, "s1"));
  assert.deepEqual(clicks, ["/api/file?p=%2Fx.png&t=full&dl=1&v=7"]);
  assert.equal(opened.length, 0);
});

test("shareFile: NotAllowedError -> prompt to tap again and cache the File; tapping the same one again shares directly (no new fetch)", async () => {
  const msgs = [], clicks = [], shared = [];
  let fetches = 0, first = true;
  const env = () => ({
    fetch: async (...a) => { fetches++; return okFetch(...a); }, location: { href: "https://h/" },
    navigator: { canShare: () => true, share: async (d) => { if (first) { first = false; const e = new Error("x"); e.name = "NotAllowedError"; throw e; } shared.push(d); } },
    window: { open() { throw new Error("no open"); } }, document: fakeDoc(clicks),
  });
  const f = { path: "/y.pdf", name: "y.pdf" };
  await withEnv(env(), () => shareFile(f, "s1", (m) => msgs.push(m)));
  assert.deepEqual(msgs, ["文件已准备好，再点一次"]);
  assert.equal(clicks.length, 0);
  await withEnv(env(), () => shareFile(f, "s1", (m) => msgs.push(m)));
  assert.equal(fetches, 1);
  assert.equal(shared.length, 1);
  assert.equal(shared[0].files[0].name, "y.pdf");
});

test("shareFile: a missing file shows the \"file is gone\" message; user cancel does not fall back", async () => {
  const msgs = [], opened = [];
  await withEnv({
    fetch: async () => ({ ok: false, status: 404 }), location: { href: "https://h/" }, navigator: {},
    window: { open: (...a) => { opened.push(a); } },
  }, () => shareFile({ path: "/x.png", name: "x.png" }, "s1", (m) => msgs.push(m)));
  assert.deepEqual(msgs, ["文件已不在"]);
  // a 429 rate limit does not mean the file is gone
  await withEnv({
    fetch: async () => ({ ok: false, status: 429 }), location: { href: "https://h/" }, navigator: {},
    window: { open: (...a) => { opened.push(a); } },
  }, () => shareFile({ path: "/x.png", name: "x.png" }, "s1", (m) => msgs.push(m)));
  assert.deepEqual(msgs, ["文件已不在", "加载失败"]);
  await withEnv({
    fetch: okFetch, location: { href: "https://h/" },
    navigator: { canShare: () => true, share: async () => { const e = new Error("x"); e.name = "AbortError"; throw e; } },
    window: { open: (...a) => { opened.push(a); } },
  }, () => shareFile({ path: "/x.png", name: "x.png" }, "s1"));
  assert.equal(opened.length, 0);
});
