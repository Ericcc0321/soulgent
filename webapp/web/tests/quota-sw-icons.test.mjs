// On mobile, when the list top row is too narrow the countdown is shortened so "Orca ✓" stays complete; sw compares icons together with ?v= and serves them cache-first
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { quotaLeftC, quotaRings, FLAME_AV_V } from "../logic.js";
import { setLang } from "../i18n.js";

const WEB = new URL("../", import.meta.url);
const rd = (f) => readFileSync(new URL(f, WEB), "utf8");
const T = 1_800_000_000;
const M = 60, H = 3600, D = 86400;

test("quotaLeftC: keeps only the largest unit, rounded, three languages", () => {
  setLang("hans");
  assert.equal(quotaLeftC(T + 58 * M, T), "58分");
  assert.equal(quotaLeftC(T + 30, T), "1分");
  assert.equal(quotaLeftC(T + 60 * M, T), "1时");
  assert.equal(quotaLeftC(T + H + 59 * M, T), "2时");
  assert.equal(quotaLeftC(T + H + 20 * M, T), "1时");
  assert.equal(quotaLeftC(T + 23 * H + 40 * M, T), "1天"); // rounding to 24 hours carries over to 1 day
  assert.equal(quotaLeftC(T + 3 * D + 23 * H, T), "4天");
  assert.equal(quotaLeftC(T + D + 2 * H, T), "1天");
  assert.equal(quotaLeftC(T - 5, T), "");
  assert.equal(quotaLeftC(null, T), "");
  setLang("hant");
  assert.equal(quotaLeftC(T + H + 59 * M, T), "2時");
  assert.equal(quotaLeftC(T + 3 * D + 23 * H, T), "4天");
  setLang("en");
  assert.equal(quotaLeftC(T + H + 59 * M, T), "2h");
  assert.equal(quotaLeftC(T + 3 * D + 23 * H, T), "4d");
  assert.equal(quotaLeftC(T + 58 * M, T), "58m");
  setLang("hans");
});

test("quotaRings carries both the full and the shortened countdown", () => {
  setLang("hans");
  const r = quotaRings({ fiveHour: { pct: 42, resetsAt: T + H + 59 * M }, sevenDay: { pct: 23, resetsAt: T + 3 * D + 23 * H } }, T);
  assert.deepEqual(r.map((q) => [q.left, q.leftC]), [["1时59分", "2时"], ["3天23时", "4天"]]);
});

test("list top row: when too narrow, shrink the Orca text first, then switch to the short countdown; both forms are rendered and CSS shows only one", () => {
  const app = rd("app.js"), css = rd("style.css");
  assert.match(app, /h\("span", "cr-qt cr-qtc", q\.leftC\)/);
  assert.match(app, /classList\.add\("qt-c"\)/);
  assert.match(app, /classList\.remove\("qt-c"\)/);
  assert.match(css, /\.cr-mac:not\(\.qt-c\) \.cr-qtc, \.cr-mac\.qt-c \.cr-qt:not\(\.cr-qtc\) \{ display: none; \}/);
});

// run sw.js in a sandbox to obtain its isShellIcon and SHELL_ICONS
function loadSw() {
  const ctx = { self: { addEventListener() {}, location: { origin: "https://x" } }, caches: {}, URL, console };
  vm.createContext(ctx);
  vm.runInContext(rd("sw.js") + "\n;globalThis.__sw = { isShellIcon, SHELL_ICONS };", ctx);
  return ctx.__sw;
}

test("sw: icons are compared together with ?v=, every icon in the list is cache-first, a different v or no v does not match", () => {
  const { isShellIcon, SHELL_ICONS } = loadSw();
  const u = (s) => new URL(s, "https://x");
  const hits = SHELL_ICONS.filter((s) => isShellIcon(u(s)));
  assert.equal(hits.length, SHELL_ICONS.length);
  // a path-only comparison would match only the two without ?v=
  const before = SHELL_ICONS.filter((s) => SHELL_ICONS.includes(u(s).pathname));
  assert.deepEqual([...before], ["/icons/term-glyph.png", "/icons/term-180.png"]);
  assert.equal(isShellIcon(u("/icons/tab-me-on.svg?v=1")), false); // different version
  assert.equal(isShellIcon(u("/icons/tab-me-on.svg")), false);
  assert.equal(isShellIcon(u("/icons/tab-me-on.svg?v=2")), true);
  assert.doesNotMatch(rd("sw.js"), /SHELL_ICONS\.includes\(p\)/);
});

test("sw: icons referenced by the page (tab bar, built-in avatar, favicon, login page, desktop icons) are all in the cache-first list with matching ?v=", () => {
  const { SHELL_ICONS } = loadSw();
  const refs = new Set();
  for (const f of ["index.html", "login.html", "style.css", "app.js", "manifest.webmanifest"]) {
    for (const m of rd(f).matchAll(/\/icons\/[\w.-]+\.(?:png|svg)(?:\?v=\d+)?/g)) refs.add(m[0]);
  }
  for (const face of ["idle", "busy", "wait", "done", "rest"]) refs.add("/icons/mascot-av-" + face + ".png?v=" + FLAME_AV_V);
  const missing = [...refs].filter((r) => !r.startsWith("/icons/splash-") && !SHELL_ICONS.includes(r)); // splash images are fetched by iOS itself when adding to the home screen, so they are not in the list
  assert.deepEqual(missing, []);
  for (const need of ["/icons/favicon.svg?v=1", "/icons/mascot-idle.png?v=1", "/icons/tab-soulchat-on.svg?v=1"]) assert.ok(SHELL_ICONS.includes(need), need);
});

test("version numbers in sync", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
