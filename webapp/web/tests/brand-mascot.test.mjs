// Brand mascot integration: the four tab-bar labels use tab-<name>-off/on, the favicon uses the small mascot, the login page and the wide-screen blank page logo slot use the plush mascot
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese
const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const has = (p) => existsSync(new URL("../" + p, import.meta.url));

const TABS = [["msg", "soulchat"], ["contacts", "agents"], ["zones", "zone"], ["me", "me"]];
// The Me icon is a plain person, referenced as ?v=2; the others use ?v=1
const IV = { soulchat: 1, agents: 1, zone: 1, me: 2 };
test("tab bar's four labels: the unselected off image acts as a mask following currentColor, the selected on image is shown as-is without tinting, no svg/square/soul-glyph fallbacks remain", () => {
  const i = rd("index.html"), css = rd("style.css");
  const nav = i.slice(i.indexOf('<nav id="tabbar"'), i.indexOf("</nav>", i.indexOf('<nav id="tabbar"')));
  assert.doesNotMatch(nav, /<svg|<rect|class="og"/);
  for (const [tab, ico] of TABS) {
    const btn = nav.slice(nav.indexOf(`data-tab="${tab}"`), nav.indexOf("</button>", nav.indexOf(`data-tab="${tab}"`)));
    assert.match(btn, new RegExp(`<span class="ti ti-img ti-${ico}" aria-hidden="true"><i class="so-off"></i><img class="so-on" src="/icons/tab-${ico}-on\\.svg\\?v=${IV[ico]}" alt=""></span>`), tab);
    assert.match(css, new RegExp(`\\.ti-${ico} \\{ --ti-off: url\\(/icons/tab-${ico}-off\\.svg\\?v=${IV[ico]}\\); \\}`), ico);
    assert.ok(has(`icons/tab-${ico}-off.svg`) && has(`icons/tab-${ico}-on.svg`), ico);
    assert.match(rd(`icons/tab-${ico}-off.svg`), /currentColor/);
    assert.doesNotMatch(rd(`icons/tab-${ico}-on.svg`), /currentColor/);
  }
  assert.match(nav.slice(nav.indexOf('data-tab="msg"'), nav.indexOf('data-tab="contacts"')), /<b id="tb-msg" class="cr-tb" hidden><\/b>/);
  assert.doesNotMatch(css, /soul-glyph|\.ti-soul(?!chat)/);
  assert.match(css, /\.ti-img \.so-off \{ background: currentColor; -webkit-mask: var\(--ti-off\)/);
  assert.match(css, /\.cr-tab\.on \.ti-img \.so-on \{ display: block; \}/);
  assert.doesNotMatch(css, /\.so-on[^{]*\{[^}]*(filter|mask|background)/); // the selected state brings its own color
});

test("favicon: index and login both prefer SVG with a PNG fallback", () => {
  for (const p of ["index.html", "login.html"]) {
    const h = rd(p);
    const svg = h.indexOf('<link rel="icon" type="image/svg+xml" href="/icons/favicon.svg?v=1">');
    const png = h.indexOf('<link rel="icon" type="image/png" href="/icons/icon-192.png?v=4">');
    assert.ok(svg > 0 && png > svg, p);
  }
  assert.ok(has("icons/favicon.svg"));
});

test("logo slot: the login page and the wide-screen blank page use the plush mascot (under /icons/, reachable when logged out)", () => {
  assert.match(rd("login.html"), /<img src="\/icons\/mascot-idle\.png\?v=1" alt="">/);
  assert.match(rd("index.html"), /<img class="desk-glyph" src="\/icons\/mascot-idle\.png\?v=1" alt="">/);
  assert.doesNotMatch(rd("style.css"), /\.desk-glyph[^}]*term-glyph/);
  assert.ok(has("icons/mascot-idle.png"));
  assert.ok(has("brand/app-icon-ios-1024.png") && has("brand/mascot-idle.png"));
});

test("sw VERSION matches zbs-shell, and sw precaches the tab images", () => {
  const s = rd("sw.js");
  assert.match(s, /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
  for (const [, ico] of TABS) assert.match(s, new RegExp(`"/icons/tab-${ico}-off\\.svg\\?v=${IV[ico]}", "/icons/tab-${ico}-on\\.svg\\?v=${IV[ico]}"`));
});

test("Me icon: plain person, selected-state stroke #1f8fff, no colored fill, no small mascot", () => {
  const off = rd("icons/tab-me-off.svg"), on = rd("icons/tab-me-on.svg");
  assert.match(on, /stroke="#1f8fff"/);
  assert.doesNotMatch(on, /fill="(?!none)[^"]+"/);
  assert.equal((on.match(/#[0-9a-fA-F]{3,6}/g) || []).filter((c) => c.toLowerCase() !== "#1f8fff").length, 0);
  assert.doesNotMatch(off, /fill="(?!none)[^"]+"/);
});
