// Figure re-layout fallback (re-lays out automatically when geometry drifts) and group glide (a row of little crabs drifts over after a flip)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const figs = readFileSync(new URL("../figures.js", import.meta.url), "utf8");
const r0 = () => 0, r1 = () => 0.999, rh = () => 0.5;

test("figDrift: bubble geometry counts as drifted only beyond 1px; a missing side does not count", () => {
  const a = { l: 10, r: 300, t: 50, b: 120 };
  assert.equal(L.figDrift(a, { ...a }), false);
  assert.equal(L.figDrift(a, { ...a, b: 120.8 }), false);
  assert.equal(L.figDrift(a, { ...a, b: 121.5 }), true);
  assert.equal(L.figDrift(a, { ...a, l: 8 }), true);
  assert.equal(L.figDrift(null, a), false);
  assert.equal(L.figDrift(a, null), false);
});

test("figures.js: ResizeObserver also watches #msgs, resize/observer callbacks trigger one debounced re-layout, a per-second tick checks geometry drift", () => {
  assert.match(figs, /S\.ro\.observe\(list\);\s*S\.ro\.observe\(msgs\)/);
  assert.match(figs, /function layoutSoon\(/);
  assert.match(figs, /new ResizeObserver\(\(\) => layoutSoon\(\)\)/);
  assert.match(figs, /addEventListener\("resize", layoutSoon\)/);
  const hold = figs.slice(figs.indexOf("export function holdLayout"));
  assert.match(hold.slice(0, 400), /layoutAll\(\);\s*layoutSoon\(\)/);   // one more pass after the flip hold expires
  const tick = figs.slice(figs.indexOf("export function tickFigures"));
  assert.match(tick, /figDrift\(/);
});

test("figGlide: near ones do not move; each takes 320-520ms with overshoot 1.3-1.8, staggered 30-80ms by queue position", () => {
  assert.equal(L.figGlide(3, 4, 0, r0), null);                    // distance 5 <= 6
  const g = L.figGlide(0, 40, 0, r0);
  assert.equal(g.ms, 320); assert.equal(g.delay, 0);
  assert.equal(L.figGlide(0, 40, 0, r1).ms > 519, true);
  assert.equal(g.over, "1.30"); assert.equal(L.figGlide(0, 40, 0, r1).over, "1.80");
  const g3 = L.figGlide(0, 40, 3, r0);
  assert.equal(g3.delay, 90);                                     // 3 positions x 30ms
  assert.equal(L.figGlide(0, 40, 3, r1).delay <= 240, true);      // 3 × 80
  assert.equal(L.figGlide(0, 40, 50, r1).delay <= 6 * 80, true);  // position is capped so a long queue does not drag on for seconds
});

test("figGlide: horizontal movement over 12px uses walk frames (right 1, left 2), otherwise only squash; rest frame 7 on arrival", () => {
  const right = L.figGlide(30, 5, 0, rh), left = L.figGlide(-30, 5, 0, rh), small = L.figGlide(8, 20, 0, rh);
  assert.equal(right.walk, true); assert.equal(right.strip, "1");
  assert.equal(left.walk, true); assert.equal(left.strip, "2");
  assert.equal(small.walk, false); assert.equal(small.strip, "");
  assert.equal(right.rest, "7");
});

test("Group.layout: only parked queue figures glide as a group, the busy ones on top stay put, reduced motion still gives 0ms", () => {
  const lay = figs.slice(figs.indexOf("  layout(pre) {"), figs.indexOf("  destroy() { this.moreTop"));
  const workers = lay.slice(0, lay.indexOf("const over"));
  assert.doesNotMatch(workers, /figGlide|glide\(/);
  assert.match(lay, /figGlide\(/);
  assert.match(figs, /function glideOk\(b\)[\s\S]{0,400}reduce\(\)/);
  assert.match(figs, /b\.phase === "parked" \|\| b\.phase === "error"/);
  assert.match(figs, /function glide\([\s\S]{0,900}b\.moving = true[\s\S]{0,900}b\.moving = false[\s\S]{0,200}layout\(\)/);
  assert.match(figs, /b\.show\("7", "pose"\)/);
});

// ---------- top bar: context ring on the left, "..." at the far right ----------
test("chat page top bar: #d-ctx comes before #d-more (... at the far right); the title is flex:1 and can shrink, both buttons are flex:none and are not squeezed out", () => {
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
  const nav = html.slice(html.indexOf('<header class="d-nav">'), html.indexOf("</header>", html.indexOf('<header class="d-nav">')));
  assert.ok(nav.indexOf('id="d-ctx"') > 0 && nav.indexOf('id="d-more"') > nav.indexOf('id="d-ctx"'), "d-ctx must come before d-more");
  assert.match(css, /\.d-title\s*\{[^}]*min-width:\s*0;[^}]*flex:\s*1/);
  assert.match(css, /\.d-more\s*\{[^}]*flex:\s*none/);
  assert.match(css, /\.d-ctx\s*\{[^}]*flex:\s*none/);
});
