// Dashboard tab icon: the four tabs use the spirit-flame icon (the flame peeks out from the top edge of the dashboard)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified
const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
const i = html.indexOf('data-tab="zones"');
const btn = html.slice(i, html.indexOf("</button>", i));
test("Dashboard icon: uses tab-zone-off/on.svg", () => {
  assert.ok(i > 0);
  assert.match(btn, /class="ti ti-img ti-zone"/);
  assert.match(btn, /src="\/icons\/tab-zone-on\.svg\?v=1"/);
  assert.match(css, /\.ti-zone \{ --ti-off: url\(\/icons\/tab-zone-off\.svg\?v=1\); \}/);
});
test("P selected state: the selected tab text color is brand", () => {
  assert.match(css, /\.cr-tab\.on \{ color: var\(--brand\); \}/);
});
