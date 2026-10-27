// Zones without a task board configured show no hint: no toast on tap, no "No task board" label, and the card is not announced as a button
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { table } from "../i18n.js";
const T = table();

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const body = (sig, len = 1600) => { const i = app.indexOf(sig); assert.ok(i >= 0, "missing " + sig); return app.slice(i, i + len); };

test("openTaskboard returns silently when the zone has no task board", () => {
  const b = body("async function openTaskboard(", 300);
  assert.match(b, /if \(!z\.taskboard\) return;/);
  assert.doesNotMatch(b, /toast\(/);
});

test("zone card: no label and no button role without a task board; the hint keys are gone", () => {
  assert.doesNotMatch(app, /zb\.noTb|tb\.none/);
  assert.match(app, /h\("span", "zc-tb", z\.code != null && z\.taskboard \? t\("zb\.tb"\) : ""\)/);
  assert.match(app, /if \(z\.code != null && z\.taskboard\) \{\n\s+c\.setAttribute\("role", "button"\);/);
  assert.equal(T["tb.none"], undefined);
  assert.equal(T["zb.noTb"], undefined);
});
