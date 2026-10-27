// Looping animations must stay off Safari's main thread.
// Measured in a WKWebView (26-row list): one infinite animation that uses steps() / step-end, animation-direction: reverse or background-position
// makes WebKit re-run style + the compositing walk for the whole page every frame (~20-30% CPU each); transform / opacity "hold" keyframes stay on the compositor.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { holdFrames } from "../logic.js";

const css = readFileSync(new URL("../style.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const figures = readFileSync(new URL("../figures.js", import.meta.url), "utf8");

// value of a steps(n) jump-end animation from translateX(0) to translateX(-n*w) at progress p in [0, 1)
const stepsAt = (n, w, p) => 0 - Math.floor(p * n) * w + 0; // + 0: no -0
// linear interpolation of WAAPI-style keyframes [{transform: "translateX(Npx)", offset}] at progress p
function kfAt(kf, p) {
  const x = (k) => Number(/translateX\((-?[\d.]+)px\)/.exec(k.transform)[1]);
  for (let i = 0; i < kf.length - 1; i++) {
    const a = kf[i], b = kf[i + 1];
    if (p >= a.offset && p <= b.offset) return b.offset === a.offset ? x(b) : x(a) + (x(b) - x(a)) * (p - a.offset) / (b.offset - a.offset);
  }
  return x(kf[kf.length - 1]);
}
// parse "@keyframes name { 0%, 16.66% { transform: translateX(0px); } ... }" into the same keyframe shape
function cssKf(name) {
  const m = new RegExp("@keyframes " + name + " \\{(.*)\\}\\s*$", "m").exec(css);
  assert.ok(m, "missing @keyframes " + name);
  const out = [];
  for (const [, sel, tf] of m[1].matchAll(/([\d.%, ]+)\{ transform: (translateX\([^)]*\)); \}/g)) {
    for (const o of sel.split(",")) out.push({ transform: tf, offset: parseFloat(o) / 100 });
  }
  return out;
}

test("holdFrames: same frame as steps(n) everywhere except the 0.0001% jump, frames held, ends on the last frame", () => {
  for (const n of [2, 3, 6, 8, 12]) {
    const kf = holdFrames(n, 18);
    assert.equal(kf.length, 2 * n);
    assert.equal(kf[0].offset, 0);
    assert.equal(kf[kf.length - 1].offset, 1);
    for (let i = 1; i < kf.length; i++) assert.ok(kf[i].offset > kf[i - 1].offset, "offsets increase");
    for (const k of kf) assert.equal(k.easing, undefined, "no per-keyframe easing (linear between holds)");
    for (let p = 0; p < 1; p += 0.0137) {
      const edge = Math.abs(p * n - Math.round(p * n)) < 0.002; // at a frame boundary (inside the jump)
      if (!edge) assert.equal(kfAt(kf, p), stepsAt(n, 18, p), "n=" + n + " p=" + p.toFixed(4));
    }
  }
});

test("figures.js: sprite frames use holdFrames, no steps() easing", () => {
  assert.match(figures, /fr\.animate\(holdFrames\(s\.n, CW\)/);
  assert.doesNotMatch(figures, /easing:\s*["'`]?steps|"steps\("/);
});

test("style.css: pet frames are hold keyframes on .pet[data-n]::before matching steps(n) on a 48px strip", () => {
  for (let n = 2; n <= 8; n++) {
    assert.match(css, new RegExp('\\.pet\\[data-n="' + n + '"\\]::before \\{ width: ' + 48 * n + "px; animation-name: pf" + n + "; \\}"));
    const kf = cssKf("pf" + n);
    for (let p = 0; p < 1; p += 0.0113) {
      if (Math.abs(p * n - Math.round(p * n)) < 0.002) continue;
      assert.equal(kfAt(kf, p), stepsAt(n, 48, p), "pf" + n + " p=" + p.toFixed(4));
    }
  }
  // .pet keeps only the duration (inline per-sprite durations still apply) and the strip inherits duration + play-state, so pausing .pet pauses the frames
  assert.match(css, /\.pet\[data-n\]::before \{[^}]*background-image: inherit;[^}]*animation-duration: inherit;[^}]*animation-play-state: inherit;/);
  assert.match(css, /\.cr-row:not\(\.g\) \.cr-av \.pet, \.cr-row:not\(\.g\) \.cr-av \.pet::before \{ animation: none; \}/);
});

test("style.css: no looping animation uses steps() / step-end / reverse, and looping keyframes animate only transform / opacity", () => {
  const decls = [...css.matchAll(/animation(?:-[a-z-]+)?\s*:\s*([^;}]*)/g)].map((m) => m[0]);
  const loops = decls.filter((d) => /infinite/.test(d));
  assert.ok(loops.length > 40, "found the looping animations");
  for (const d of loops) {
    assert.doesNotMatch(d, /steps\(|step-end|step-start/, d);
    assert.doesNotMatch(d, /\breverse\b/, d);
  }
  for (const d of decls) assert.doesNotMatch(d, /animation-timing-function:\s*(steps|step-)|animation-direction:\s*(alternate-)?reverse/, d);
  // names used by looping shorthands (+ names set via animation-name on rules whose loops come from longhands, e.g. .pet / .fx-fire strips)
  const names = new Set();
  for (const d of loops) for (const w of d.replace(/^animation\s*:\s*/, "").split(/[\s,]+/)) if (/^[a-z][\w-]*$/i.test(w)) names.add(w);
  for (const m of css.matchAll(/animation-name:\s*([\w-]+)/g)) names.add(m[1]);
  let checked = 0;
  for (const m of css.matchAll(/@keyframes ([\w-]+) \{([\s\S]*?\})\s*\}/g)) {
    if (!names.has(m[1])) continue;
    checked++;
    // only transform / opacity: anything else (background, background-position, box-shadow, filter...) is resolved on Safari's main thread every frame
    const props = [...m[2].matchAll(/([a-z-]+)\s*:/g)].map((x) => x[1]).filter((p) => p !== "animation-timing-function");
    for (const p of props) assert.ok(p === "transform" || p === "opacity", "@keyframes " + m[1] + " animates " + p);
  }
  assert.ok(checked > 40, "checked the looping keyframes");
});

test("busy label shine: two masked, counter-moving copies of the label, only transform animated", () => {
  assert.match(css, /\.cr-shn \{[^}]*width: 260%;[^}]*mask-image: linear-gradient\(100deg, transparent 32%, #000 50%, transparent 68%\);[^}]*animation: crshine 2\.6s/);
  assert.match(css, /\.cr-shn\.b \{[^}]*mask-image: linear-gradient\(100deg, #000 32%, transparent 50%, #000 68%\);/);
  assert.match(css, /\.cr-shn::before \{[^}]*content: attr\(data-t\);[^}]*width: calc\(100% \/ 2\.6\);[^}]*animation: crshine-t 2\.6s/);
  // copy aligned by its text edge, not by line-height: lands on the label's baseline for fallback fonts too (Chinese labels render in PingFang)
  assert.match(css, /\.cr-shn::before \{[^}]*text-box: trim-both text;/);
  assert.match(css, /\.cr-shn \{[^}]*top: 0; bottom: 0; width: 260%;/);
  // window slides -160% of the label (= -61.5385% of its 260% width) -> 0, the copy slides back +160% -> 0 on the same timing, so the copy stays on the text
  assert.match(css, /@keyframes crshine \{ 0% \{ transform: translateX\(-61\.5385%\); \} 65%, 100% \{ transform: translateX\(0\); \} \}/);
  assert.match(css, /@keyframes crshine-t \{ 0% \{ transform: translateX\(160%\); \} 65%, 100% \{ transform: translateX\(0\); \} \}/);
  assert.match(css, /\.cr-row\.g \.cr-pt\.g \{ position: relative; color: transparent; \}/);
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  assert.match(app, /\["cr-shn b", "cr-shn"\]\.map\(\(c\) => \{ const e = h\("span", c\); e\.dataset\.t = r\.tag\.text;/);
});

test("two-column chat: off-screen list rows stay paused (the split 'running' override must not reach li.off)", () => {
  const run = css.indexOf("body.split.in-detail #home *, body.split.in-detail #home *::before");
  const off = css.indexOf("body.split.in-detail #home li.off *");
  assert.ok(run >= 0 && off > run, "li.off pause rule must come after the split running rule");
  assert.match(css.slice(off, css.indexOf("}", off)), /animation-play-state:\s*paused\s*!important/);
});

test("attachment loading breath: opacity of a #333 layer over #262626, under the content (lazy thumbnails far up stay loading for good)", () => {
  assert.match(css, /\.at-loading \{ position: relative; isolation: isolate; \}/);
  assert.match(css, /\.at-loading::before, \.at-loading::after \{[^}]*z-index: -1;[^}]*background: #262626;/);
  assert.match(css, /\.at-loading::after \{ background: #333; opacity: 0; animation: at-breathe 1\.4s ease-in-out infinite; \}/);
  assert.match(css, /@keyframes at-breathe \{ 0%, 100% \{ opacity: 0; \} 50% \{ opacity: 1; \} \}/);
});
