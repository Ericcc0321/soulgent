// No flicker after sending an image: the pending bubble's local preview is transferred to the matching record entry, so the same <img> is used from sent, single tick and queued through to read
// The matching rules live in logic.js (carryTarget / carryPlan) and app.js only moves nodes; node identity in a real browser is covered by render-check's imgflash scenario
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");
const fn = (name) => { const i = app.indexOf("function " + name + "("); assert.ok(i >= 0, name); return app.slice(i, app.indexOf("\n}\n", i)); };

const U = (text, extra) => Object.assign({ role: "user", text, ts: "2026-10-24T03:00:00.000Z" }, extra);
const IMG = (n) => Array.from({ length: n }, (_, i) => ({ ref: "10:" + (i + 1) + ":ab", kind: "image", n: i + 1 }));

test("imageMarkCount: counts [Image #N] markers", () => {
  assert.equal(L.imageMarkCount("[Image #4] 另外还有"), 1);
  assert.equal(L.imageMarkCount("[Image #1][Image #2] x"), 2);
  assert.equal(L.imageMarkCount("no image"), 0);
  assert.equal(L.imageMarkCount(null), 0);
});

test("carryTarget: the n0-th user entry with the same number of images (went straight to read) -> claimed", () => {
  const items = [U("a"), { role: "assistant", text: "ok" }, U("b"), U("[Image #1]", { read: true, files: IMG(1) })];
  assert.equal(L.carryTarget(items, 2, 1), 3);
});
test("carryTarget: the queued copy has only [Image #N] markers and no files (real enqueue shape) -> also claimed", () => {
  const items = [U("a"), U("[Image #10] 这个打光太高了", { read: false, queued: true })];
  assert.equal(L.carryTarget(items, 1, 1), 1);
});
test("carryTarget: image count mismatch / recalled / not arrived yet / no images -> -1", () => {
  assert.equal(L.carryTarget([U("a"), U("x", { files: IMG(2) })], 1, 1), -1);
  assert.equal(L.carryTarget([U("a"), U("[Image #1]", { recalled: true })], 1, 1), -1);
  assert.equal(L.carryTarget([U("a")], 1, 1), -1);
  assert.equal(L.carryTarget([U("a"), U("plain text")], 1, 1), -1);
  assert.equal(L.carryTarget([U("a"), U("[Image #1]")], 1, 0), -1);
});

test("carryPlan: if the original entry is still there, attach to it", () => {
  const q = U("[Image #1] hi", { read: false, queued: true });
  const items = [U("a"), q];
  const c = { key: L.carryKey(q), txt: L.carryText(q), ts: q.ts, n: 1 };
  assert.deepEqual(L.carryPlan([c], items), [1]);
});
test("carryPlan: when the queued copy is replaced by the official row (later ts, same text, has images) -> reattach to the official row", () => {
  const q = U("[Image #1] hi", { read: false, queued: true });
  const c = { key: L.carryKey(q), txt: L.carryText(q), ts: q.ts, n: 1 };
  const formal = U("[Image #1] hi", { ts: "2026-10-24T03:00:05.000Z", read: true, files: IMG(1) });
  assert.deepEqual(L.carryPlan([c], [U("a"), formal]), [1]);
  // an earlier entry with the same text is not accepted; different text is not accepted; different image count is not accepted
  assert.deepEqual(L.carryPlan([c], [U("[Image #1] hi", { ts: "2026-10-24T02:00:00.000Z", files: IMG(1) })]), [-1]);
  assert.deepEqual(L.carryPlan([c], [U("[Image #1] other", { ts: "2026-10-24T03:00:05.000Z", files: IMG(1) })]), [-1]);
  assert.deepEqual(L.carryPlan([c], [U("[Image #1] hi", { ts: "2026-10-24T03:00:05.000Z", files: IMG(2) })]), [-1]);
});
test("carryPlan: two transfers each claim their own entry and do not fight over the same one", () => {
  const q1 = U("[Image #1]", { ts: "2026-10-24T03:00:01.000Z" });
  const q2 = U("[Image #1]", { ts: "2026-10-24T03:00:02.000Z" });
  const c1 = { key: L.carryKey(q1), txt: L.carryText(q1), ts: q1.ts, n: 1 };
  const c2 = { key: L.carryKey(q2), txt: L.carryText(q2), ts: q2.ts, n: 1 };
  const f1 = U("[Image #1]", { ts: "2026-10-24T03:00:03.000Z", files: IMG(1) });
  const f2 = U("[Image #1]", { ts: "2026-10-24T03:00:04.000Z", files: IMG(1) });
  assert.deepEqual(L.carryPlan([c1, c2], [f1, f2]), [0, 1]);
  assert.deepEqual(L.carryPlan([c1, c2], [q1, f2]), [0, 1]);
});

// ---------- app.js only moves nodes ----------
test("renderItems: a pending bubble that is finishing tries a transfer first (carryTarget); a local preview that was transferred is not released", () => {
  const b = fn("renderItems");
  assert.match(b, /carryFrom\(p, items, st\.detailId\); pendFree\(p\)/);
  assert.match(b, /carryMap\(items, st\.detailId\)/);
  assert.match(fn("carryFrom"), /carryTarget\(items, p\.n0/);
  assert.match(fn("carryFrom"), /f\.local = ""/);
  assert.match(fn("carryMap"), /carryPlan\(list, items\)/);
});
test("atImg: uses a transferred <img> if there is one, without creating another one or changing src", () => {
  const b = fn("atImg");
  assert.match(b, /atTake/);
});
test("atCache key deletion goes through atEvict (which also releases the transferred blob preview)", () => {
  assert.match(fn("mdSweep"), /atEvict\(/);
  assert.match(fn("atEvict"), /revokeObjectURL/);
});
test("chFrag: earlier window segments do not clear the cache individually (only the last does), and images in earlier windows are reused when a whole segment is redrawn", () => {
  const b = fn("chFrag");
  assert.match(b, /renderItems\(c\.segs\[i\]\.items, idle, true\)/);
});
test("PEND_SIG_SKIP without atw would put the node into the signature: atw must be skipped", () => {
  assert.match(app, /PEND_SIG_SKIP = new Set\(\[[^\]]*"atw"/);
});

test("sw and shell version", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
