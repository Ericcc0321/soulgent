import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese
const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");

test("manifest name is Soulgent", () => {
  const m = JSON.parse(rd("manifest.webmanifest"));
  assert.equal(m.name, "Soulgent");
  assert.equal(m.short_name, "Soulgent");
});
test("index/login titles and home-screen name do not contain the former product name", () => {
  const i = rd("index.html"), l = rd("login.html");
  assert.match(i, /<title>Soulgent<\/title>/);
  assert.match(i, /apple-mobile-web-app-title" content="Soulgent"/);
  assert.match(l, /<title data-i18n="login.title">Soulgent · Sign in<\/title>/); // defaults to English and is swapped by language at startup
  assert.match(l, /<h1>Soulgent<\/h1>/);
  assert.doesNotMatch(i + l, /值班室/);
});
test("sw: default title is Soulgent, no extra \"handled\" notification", () => {
  const s = rd("sw.js");
  assert.match(s, /DEFAULT_TITLE = "Soulgent"/);
  assert.doesNotMatch(s, /已处理|RECALL_REPLACE|RECALL_TITLE/);
  assert.match(s, /closeStaleLocal/);
});
