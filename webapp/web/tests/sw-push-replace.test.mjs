// sw push: iOS does not replace notifications by tag, so the sw closes same-tag notifications before showing the new one,
// and every push still calls showNotification (iOS revokes the subscription after 3 pushes without a notification).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const sw = readFileSync(new URL("../sw.js", import.meta.url), "utf8");

// Fake registration: shown notifications live in `list`; every call is appended to `log` in order
function loadSw({ getFails = false, ignoreFilter = false } = {}) {
  const log = [];
  const list = [];
  const note = (tag, title) => {
    const n = { tag, title, close() { log.push("close " + tag + " " + title); const i = list.indexOf(n); if (i >= 0) list.splice(i, 1); } };
    return n;
  };
  const registration = {
    async getNotifications(filter) {
      log.push("get " + (filter && filter.tag ? filter.tag : "*"));
      if (getFails) throw new Error("boom");
      const tag = filter && filter.tag;
      return list.filter((n) => ignoreFilter || !tag || n.tag === tag);
    },
    async showNotification(title, opts) {
      log.push("show " + opts.tag + " " + title);
      list.push(note(opts.tag, title));
    },
  };
  const ctx = {
    self: { addEventListener() {}, location: { origin: "https://x" }, registration, navigator: {} },
    caches: {}, URL, console, btoa, Uint8Array, String, Number, Object, encodeURIComponent, Promise, setTimeout, clearTimeout,
    fetch: () => Promise.reject(new Error("offline")), // closeStaleLocal finds no snapshot and leaves other tags alone
  };
  vm.createContext(ctx);
  vm.runInContext(sw + "\n;globalThis.__sw = { onPush };", ctx);
  const push = (msg) => ctx.__sw.onPush({ data: { json: () => msg } });
  return { push, log, list, note };
}

test("sw push: same-tag notifications are closed before the new one is shown; other tags stay", async () => {
  const { push, log, list, note } = loadSw();
  list.push(note("s-a", "old wait"), note("s-b", "other session"));
  await push({ kind: "show", tag: "s-a", title: "new done", body: "b", url: "/#s/a" });
  const iClose = log.indexOf("close s-a old wait");
  const iShow = log.indexOf("show s-a new done");
  assert.ok(iClose >= 0, "old s-a closed: " + log.join(" | "));
  assert.ok(iShow > iClose, "closed before show: " + log.join(" | "));
  assert.ok(log.indexOf("get s-a") < iClose, "looked up by tag first");
  assert.deepEqual(list.map((n) => n.tag + " " + n.title), ["s-b other session", "s-a new done"]);
});

test("sw push: a browser ignoring the tag filter still only closes the same tag", async () => {
  const { push, list, note } = loadSw({ ignoreFilter: true });
  list.push(note("s-a", "old"), note("s-b", "keep"), note("mac-link", "keep too"));
  await push({ kind: "show", tag: "s-a", title: "new", body: "" });
  assert.deepEqual(list.map((n) => n.tag + " " + n.title), ["s-b keep", "mac-link keep too", "s-a new"]);
});

test("sw push: showNotification is always called, even if getNotifications fails", async () => {
  const { push, log } = loadSw({ getFails: true });
  await push({ kind: "show", tag: "s-a", title: "t1", body: "" });
  await push({ kind: "show", tag: "s-a", title: "t2", body: "" });
  await push({}); // empty payload: default title and tag
  assert.deepEqual(log.filter((l) => l.startsWith("show ")), ["show s-a t1", "show s-a t2", "show zbs Soulgent"]);
});

test("sw push: one session keeps only its latest notification across several pushes", async () => {
  const { push, log, list } = loadSw();
  for (const t of ["wait", "done", "wait again"]) await push({ kind: "show", tag: "s-a", title: t, body: "" });
  assert.deepEqual(list.map((n) => n.title), ["wait again"]);
  assert.equal(log.filter((l) => l.startsWith("show ")).length, 3);
});
