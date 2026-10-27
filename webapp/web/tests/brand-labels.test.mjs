import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { setLang, t } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese
const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");

test("index has no OrcaChat; bottom bar labels are SoulChat/Agents/Dashboard/Me", () => {
  const i = rd("index.html");
  assert.doesNotMatch(i, /OrcaChat/);
  const nav = i.slice(i.indexOf('<nav id="tabbar"'), i.indexOf("</nav>", i.indexOf('<nav id="tabbar"')));
  const labels = [...nav.matchAll(/<span(?: data-i18n="[^"]+")?>([^<]+)<\/span>/g)].map((m) => m[1]);
  assert.deepEqual(labels, ["SoulChat", "Agents", "Dashboard", "Me"]); // HTML defaults to English and is swapped by language at startup (tab.zones / tab.me have fixed Simplified Chinese labels)
  assert.deepEqual([t("tab.chat"), t("tab.agents"), t("tab.zones"), t("tab.me")], ["SoulChat", "Agents", "看板", "我"]);
  assert.match(i, /apple-mobile-web-app-title" content="Soulgent"/);
  assert.match(i, /<title>Soulgent<\/title>/);
});
test("no .ti-orca remains (the flame tab image is used)", () => {
  const css = rd("style.css"), i = rd("index.html");
  assert.match(i, /ti-soulchat/);
  assert.doesNotMatch(css + i, /ti-orca/);
});
test("Dashboard tab: uses the flame image (not a separate svg icon); its label follows tab.zones", () => {
  const i = rd("index.html");
  assert.match(i, /ti-zone/);
  assert.match(i, /<span data-i18n="tab.zones">Dashboard<\/span>/); // English label is Dashboard
});
test("manifest / login / sw are named Soulgent, icon references carry ?v=4 (splash images still ?v=3)", () => {
  const m = JSON.parse(rd("manifest.webmanifest"));
  assert.equal(m.name, "Soulgent");
  assert.equal(m.short_name, "Soulgent");
  for (const ic of m.icons) assert.match(ic.src, /\?v=4$/);
  const i = rd("index.html"), l = rd("login.html"), s = rd("sw.js");
  for (const h of [i, l]) {
    assert.match(h, /apple-touch-icon" href="\/icons\/icon-180\.png\?v=4"/);
    assert.doesNotMatch(h, /OrcaChat/);
  }
  const splash = [...i.matchAll(/startup-image"[^>]*href="([^"]+)"/g)].map((x) => x[1]);
  assert.equal(splash.length, 7);
  for (const u of splash) assert.match(u, /\.png\?v=3$/);
  assert.match(s, /DEFAULT_TITLE = "Soulgent"/);
  assert.match(s, /icon-180\.png\?v=4/);
});
test("app.js TAB_TITLE: msg is Soulgent, zones follows tab.zones", () => {
  const a = rd("app.js");
  assert.match(a, /const TAB_TITLE = \{ msg: "Soulgent", get contacts\(\) \{ return t\("tab.agents"\); \}, get zones\(\) \{ return t\("tab.zones"\); \}, get me\(\) \{ return t\("tab.me"\); \}/);
  assert.match(a, /"Soulgent · " \+ zoneName\(\)/);
  assert.doesNotMatch(a, /OrcaChat/);
});
