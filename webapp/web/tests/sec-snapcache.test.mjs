// Security: the snapshot cache must not be shared across accounts. On an identity change (#k= login link via the login page, login-page sign-in, sign-out) the sw clears the offline snapshot cache;
// the guest frontend filters down to the top-level fields a guest snapshot should have, so a snapshot replayed into another account cannot expose private fields such as offduty
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { guestSnapshot } from "../logic.js";

test("guestSnapshot keeps only the top-level fields of a guest snapshot", () => {
  const raw = {
    generatedAt: 1, stale: false, serverNow: 2, sessions: [{ id: "a", name: "Web-x", status: "idle", since: 1 }],
    zones: [], bound: { name: "Web-x", online: true }, roster: [],
    offduty: [{ sid: "o1", name: "Admin-secret" }], usage: { pct: 50 }, agents: [{ id: "z" }],
  };
  const { snap } = guestSnapshot(raw, 0, null, "Web-x");
  assert.deepEqual(Object.keys(snap).sort(), ["bound", "generatedAt", "roster", "serverNow", "sessions", "stale", "zones"]);
  assert.equal(snap.sessions.length, 1);
});

test("sw: requests that change identity clear the offline snapshot cache first", () => {
  const src = readFileSync(new URL("../sw.js", import.meta.url), "utf8");
  assert.match(src, /function identityChange\(/);
  assert.match(src, /caches\.delete\(DATA_CACHE\)/);
  assert.match(src, /identityChange\(req, url\)/);
});

// ---------- offline snapshots are keyed per account: runs the real sw.js fetch handler (in-memory caches / fetch) ----------
function swHarness() {
  const store = new Map(); // cache name -> Map(URL -> Response)
  const href = (k) => (typeof k === "string" ? new URL(k, "https://x").href : k.url);
  const caches = {
    async open(name) {
      if (!store.has(name)) store.set(name, new Map());
      const m = store.get(name);
      return {
        async match(k) { const r = m.get(href(k)); return r ? r.clone() : undefined; },
        async put(k, r) { m.set(href(k), r); },
        async delete(k) { return m.delete(href(k)); },
      };
    },
    async delete(name) { return store.delete(name); },
    async keys() { return [...store.keys()]; },
    async match() { return undefined; },
  };
  const listeners = {};
  let net = null; // (req) => Promise<Response>
  const ctx = {
    self: { addEventListener(t, fn) { listeners[t] = fn; }, location: { origin: "https://x" } },
    caches, URL, Headers, Response, Request, AbortController, setTimeout, clearTimeout, console,
    fetch: (req) => net(req),
  };
  vm.createContext(ctx);
  vm.runInContext(readFileSync(new URL("../sw.js", import.meta.url), "utf8") + "\n;globalThis.__sw = { snapKey, snapAcct, DATA_CACHE };", ctx);
  const reply = (acct, body) => {
    const r = new Response(JSON.stringify(body), { headers: acct ? { "X-Zbs-Account": acct } : {} });
    Object.defineProperty(r, "type", { value: "basic" });
    return r;
  };
  // dispatch a fetch event and return the Promise given to respondWith (null if not handled)
  const fire = (url, init = {}) => {
    let p = null;
    const waits = [];
    listeners.fetch({ request: new Request("https://x" + url, init), respondWith(x) { p = x; }, waitUntil(x) { waits.push(x); } });
    return Promise.all(waits).then(() => p);
  };
  const snap = (acct) => fire("/api/snapshot", acct ? { headers: { "X-Zbs-Acct": acct } } : {});
  const settle = () => new Promise((ok) => setTimeout(ok, 5));
  const keys = () => [...(store.get(ctx.__sw.DATA_CACHE) || new Map()).keys()];
  return {
    store, keys, sw: ctx.__sw, fire, snap, reply, settle,
    online: (fn) => { net = fn; }, offline: () => { net = () => Promise.reject(new TypeError("offline")); },
  };
}

test("sw: the snapshot cache is keyed per account; a guest offline never reads the admin snapshot", async () => {
  const h = swHarness();
  assert.equal(h.sw.DATA_CACHE, "zbs-data-v2");
  // admin online: stored under the admin response header
  h.online(() => Promise.resolve(h.reply("admin", { who: "admin-secret" })));
  await (await h.snap("admin")).text();
  await h.settle();
  assert.deepEqual(h.keys(), ["https://x/api/snapshot?acct=admin"]);
  // admin offline: reads its own
  h.offline();
  assert.equal((await (await h.snap("admin")).json()).who, "admin-secret");
  // identity change (guest login): the whole cache is cleared
  h.online(() => Promise.resolve(new Response(null, { status: 204 })));
  await h.fire("/api/auth", { method: "POST", body: "{}" });
  assert.equal(h.store.has(h.sw.DATA_CACHE), false);
  // after clearing: another admin page's polling still writes back, but only under the admin key
  h.online(() => Promise.resolve(h.reply("admin", { who: "admin-secret" })));
  await (await h.snap("admin")).text();
  await h.settle();
  assert.deepEqual(h.keys(), ["https://x/api/snapshot?acct=admin"]);
  // guest offline: uses the guest key; if absent, hands over to the page (error) and never gets the admin copy
  h.offline();
  await assert.rejects(async () => (await h.snap("guest")).text());
  // no account header (legacy page) offline: never reads the cache
  await assert.rejects(async () => (await h.snap("")).text());
  // guest online gets its own, offline reads its own back
  h.online(() => Promise.resolve(h.reply("guest", { who: "guest-own" })));
  await (await h.snap("guest")).text();
  await h.settle();
  h.offline();
  assert.equal((await (await h.snap("guest")).json()).who, "guest-own");
});

test("sw: responses without an account header are not stored; snapshots sent before an identity change but returning after it are not stored", async () => {
  const h = swHarness();
  h.online(() => Promise.resolve(h.reply("", { who: "x" })));
  await (await h.snap("admin")).text();
  await h.settle();
  assert.deepEqual(h.keys(), []);
  let release;
  h.online(() => new Promise((ok) => { release = () => ok(h.reply("admin", { who: "admin-secret" })); }));
  const slow = h.snap("admin");
  await h.settle();
  h.online(() => Promise.resolve(new Response(null, { status: 204 })));
  await h.fire("/api/auth", { method: "POST", body: "{}" });
  release();
  await (await slow).text();
  await h.settle();
  assert.deepEqual(h.keys(), []);
});

test("sw: a #k= login link clears the snapshot cache through the login page alone (no ?key= needed in any URL)", async () => {
  const h = swHarness();
  h.online(() => Promise.resolve(h.reply("admin", { who: "admin-secret" })));
  await (await h.snap("admin")).text();
  await h.settle();
  assert.deepEqual(h.keys(), ["https://x/api/snapshot?acct=admin"]);
  // /#k= is forwarded to /login.html#k=...; the fragment is not part of the request, the path alone counts as an identity change
  h.online(() => Promise.resolve(new Response("<html>", { status: 200 })));
  await h.fire("/login.html#k=abc");
  assert.equal(h.store.has(h.sw.DATA_CACHE), false);
  // the auto-submit POST counts as well
  h.online(() => Promise.resolve(h.reply("admin", { who: "admin-secret" })));
  await (await h.snap("admin")).text();
  await h.settle();
  h.online(() => Promise.resolve(new Response(null, { status: 204 })));
  await h.fire("/api/auth", { method: "POST", body: JSON.stringify({ key: "abc", auto: true }) });
  assert.equal(h.store.has(h.sw.DATA_CACHE), false);
});

test("sw: the account header only accepts safe characters", () => {
  const { sw } = swHarness();
  assert.equal(sw.snapAcct(new Headers({ "X-Zbs-Account": "gb" }), "X-Zbs-Account"), "gb");
  assert.equal(sw.snapAcct(new Headers({ "X-Zbs-Account": "../x" }), "X-Zbs-Account"), "");
  assert.equal(sw.snapKey(""), "");
});

test("app.js: snapshot requests carry the current account header X-Zbs-Acct; sign-out clears the new cache name", () => {
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  assert.match(app, /if \(st\.account\) hd\["X-Zbs-Acct"\] = st\.account;/);
  assert.match(app, /st\.account = acc \|\| "";/);
  assert.match(app, /caches\.delete\("zbs-data-v2"\)/);
  assert.doesNotMatch(app, /zbs-data-v1/);
});
