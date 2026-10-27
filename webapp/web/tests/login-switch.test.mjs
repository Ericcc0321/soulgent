// Login page: a #k= link auto-submits as "auto" by POST and strips the fragment; a 409 (already logged in as someone else) must not switch,
// the key is prefilled for a deliberate submit. index.html forwards /#k= to the login page. Keys never go into a URL query.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const html = readFileSync(new URL("../login.html", import.meta.url), "utf8");
const src = html.match(/<script>([\s\S]*?)<\/script>/)[1].replace('import("/i18n.js")', "Promise.reject(new Error('x'))");

function run(hash, status, search = "") {
  const calls = [];
  const el = () => ({ value: "", textContent: "", disabled: false, hidden: true, classList: { add() {}, remove() {} }, offsetWidth: 0,
    addEventListener(ev, fn) { this[ev] = fn; }, focus() { this.focused = true; } });
  const els = { f: el(), k: el(), b: el(), e: el(), n: el() };
  const location = { hash, search, pathname: "/login.html", replace: (u) => calls.push(["replace", u]) };
  const ctx = {
    document: { getElementById: (id) => els[id], documentElement: { setAttribute() {} } },
    location,
    history: { replaceState: (s, t, u) => { calls.push(["replaceState", u]); location.hash = ""; } },
    localStorage: { removeItem() {} },
    fetch: (url, o) => { calls.push(["fetch", url, JSON.parse(o.body)]); return Promise.resolve({ ok: status < 300, status, json: () => Promise.resolve({}) }); },
    setTimeout: (fn, ms) => { calls.push(["timeout", ms]); fn(); },
    decodeURIComponent, JSON, Promise,
  };
  vm.runInNewContext(src, ctx);
  return { calls, els };
}
const settle = () => new Promise((r) => setTimeout(r, 20));

test("#k= link posts with auto flag and strips the fragment before submitting", async () => {
  const { calls } = run("#k=abc", 204);
  await settle();
  const i = calls.findIndex((c) => c[0] === "fetch");
  const f = calls[i];
  assert.equal(f[1], "/api/auth");
  assert.equal(f[2].key, "abc");
  assert.equal(f[2].auto, true);
  const rs = calls.findIndex((c) => c[0] === "replaceState");
  assert.ok(rs >= 0 && rs < i, "fragment removed before the POST");
  assert.equal(calls[rs][1], "/login.html");
  assert.ok(!calls[rs][1].includes("#") && !calls[rs][1].includes("?"));
  assert.deepEqual(calls.find((c) => c[0] === "replace"), ["replace", "/"]);
});

test("#k= value is percent-decoded; other fragment params are ignored", async () => {
  const { calls } = run("#x=1&k=a%26b%2Bc", 204);
  await settle();
  assert.equal(calls.find((c) => c[0] === "fetch")[2].key, "a&b+c");
});

test("legacy=1 shows the outdated-link notice and still logs in", async () => {
  const { calls, els } = run("#k=abc&legacy=1", 204);
  await settle();
  assert.equal(els.n.hidden, false);
  assert.equal(els.n.textContent, "login.legacy");
  assert.equal(calls.find((c) => c[0] === "fetch")[2].auto, true);
  assert.ok(calls.some((c) => c[0] === "timeout"), "navigation is delayed so the notice can be read");
  assert.deepEqual(calls.find((c) => c[0] === "replace"), ["replace", "/"]);
});

test("no legacy flag: no notice, no delay", async () => {
  const { calls, els } = run("#k=abc", 204);
  await settle();
  assert.equal(els.n.hidden, true);
  assert.equal(calls.some((c) => c[0] === "timeout"), false);
});

test("409 (already logged in): no redirect, key prefilled, message shown", async () => {
  const { calls, els } = run("#k=abc", 409);
  await settle();
  assert.equal(calls.some((c) => c[0] === "replace"), false);
  assert.equal(els.k.value, "abc");
  assert.ok(els.e.textContent.length > 0);
});

test("a ?key= query on the login page is not read (the server redirects legacy links to #k=)", async () => {
  const { calls } = run("", 204, "?key=abc");
  await settle();
  assert.equal(calls.some((c) => c[0] === "fetch"), false);
});

test("manual submit has no auto flag", async () => {
  const { calls, els } = run("", 204);
  els.k.value = "zzz";
  els.f.submit({ preventDefault() {} });
  await settle();
  const f = calls.find((c) => c[0] === "fetch");
  assert.equal(f[2].key, "zzz");
  assert.notEqual(f[2].auto, true);
});

test("login page never puts the key into a URL", () => {
  const code = src.replace(/\/\/.*$/gm, ""); // comments may mention the legacy ?key= form
  assert.doesNotMatch(code, /[?&]key=/);
  assert.doesNotMatch(code, /location\.search/);
});

// ---------- index.html: /#k= is forwarded to the login page before any module runs ----------
const index = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const fwd = index.match(/<script>([\s\S]*?)<\/script>/);

function runIndex(hash) {
  const calls = [];
  const location = { hash, search: "", pathname: "/", replace: (u) => calls.push(["replace", u]) };
  const ctx = { location, history: { replaceState: (s, t, u) => { calls.push(["replaceState", u]); location.hash = ""; } } };
  vm.runInNewContext(fwd[1], ctx);
  return calls;
}

test("index.html: the forwarder is a classic inline script placed before the module scripts", () => {
  assert.ok(fwd, "inline script present");
  assert.ok(index.indexOf(fwd[0]) < index.indexOf('<script type="module"'));
});

test("index.html: /#k= goes to /login.html#k= and leaves no key in this history entry", () => {
  const calls = runIndex("#k=abc&legacy=1");
  assert.deepEqual(calls, [["replaceState", "/"], ["replace", "/login.html#k=abc&legacy=1"]]);
});

test("index.html: other fragments (notification deep links #s/<id>) are left alone", () => {
  assert.deepEqual(runIndex("#s/abc"), []);
  assert.deepEqual(runIndex(""), []);
});
