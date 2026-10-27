// Guards: problems like style class-name collisions that unit tests cannot cover logically but that break the UI as soon as they change
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const html = read("../index.html");

// extract all declaration blocks of a selector (rules consisting of that selector alone)
function blocks(sel) {
  const re = new RegExp("(^|\\n)\\s*" + sel.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}", "g");
  return [...css.matchAll(re)].map((m) => m[2]);
}

test("avatar unread red dot .cr-dot: only at the avatar's top right, not overridden into a grey dot by the Mac status dot", () => {
  const bs = blocks(".cr-dot");
  assert.ok(bs.length >= 1);
  for (const b of bs) {
    assert.doesNotMatch(b, /\bleft\s*:/, ".cr-dot must not have left positioning");
    const bg = b.match(/background\s*:\s*([^;]+)/);
    if (bg) assert.match(bg[1], /cr-red/, ".cr-dot must be red");
  }
  assert.doesNotMatch(css, /\.cr-dot\.(on|warn)\b/, "status dot color tiers must not be attached to .cr-dot");
});

test("the Mac status dot uses its own class name cr-macdot", () => {
  assert.match(html, /id="cr-mac-dot" class="cr-macdot"/);
  assert.match(app, /\$\("#cr-mac-dot"\)\.className = "cr-macdot "/);
  assert.doesNotMatch(app, /"cr-dot "\s*\+/);
});

test("hint bar: no fit special case any more, width adapts to content", () => {
  assert.doesNotMatch(css, /\.toast\.fit/);
  assert.doesNotMatch(app, /classList\.toggle\("fit"/);
});

const figs = read("../figures.js");
const sw = read("../sw.js");

test("the bottom 'done N minutes' row does not exist; the placeholder bubble lives in #list (with a ph- prefix)", () => {
  assert.doesNotMatch(html, /id="busy"|busy-row|busy-t/);
  assert.doesNotMatch(css, /\.busy-row|\.m\.typing/);
  assert.doesNotMatch(app, /#busy|busy-t|classList\.contains\("typing"\)/);
  assert.match(app, /"m ai ph-bub"/);
  assert.match(css, /\.m\.ai\.ph-bub\s*\{[^}]*min-width:\s*60%/);
  assert.match(app, /busy:\s*busy/); // renderItems passes busy to chatPlan
});

test("one figure per call, no ×N badge or setCount", () => {
  assert.doesNotMatch(figs, /fg-cnt|setCount/);
  assert.doesNotMatch(css, /fg-cnt/);
  assert.match(figs, /g\.key \+ ":" \+ /);
  assert.doesNotMatch(app, /f\.cls \+ f\.state \+ f\.count/);
  // hidden ones (inside +N) stop animating: the animation stops when they fade out, then display:none
  assert.match(css, /\.fg\.fg-gone \.fg-wig\s*\{\s*animation:\s*none/);
  assert.match(css, /\.fg\.fg-gx\s*\{\s*display:\s*none/);
  assert.match(figs, /fg-gx/);
});

test("tool groups with figures draw no badge, tapping a figure expands a row by tool id, expanded state is stored in st", () => {
  assert.match(app, /function figTap\(key, tu\)/);
  assert.match(app, /dataset\.tu\s*=/);
  assert.match(app, /figOpen: new Map\(\)/);
  assert.match(css, /\.tools\.tl-one li:not\(\.fg-hl\)\s*\{[^}]*display:\s*none/);
});

test("sw VERSION matches the shell", () => {
  assert.match(sw, /const VERSION = "v142";/);
});

test("the small grey zone box / ★ after the name in list rows is lifted and vertically centered with the name", () => {
  assert.match(css, /\.cr-nm \.cr-zn, \.cr-nm \.cr-star \{ position: relative; top: -1\.5px; \}/);
});

test("cross-session message = zone-colored forward card: no dashed border, left bar plus zone-color blended background, badge uses whoTags", () => {
  assert.doesNotMatch(css, /\.m\.x[^{]*\{[^}]*dashed/);
  assert.doesNotMatch(css, /\.m\.ai\.x\s*\{[^}]*dashed/);
  assert.match(css, /\.cg-pr \.cg-col > \.m\.m-pr\s*\{[^}]*color-mix\(in srgb, var\(--zc\) 16%, #2c2c2c\)/);
  assert.match(css, /\.cg-pr \.cg-col > \.m\.m-pr\s*\{[^}]*inset 3px 0 0 var\(--zc\)/);
  assert.match(css, /\.cg-pr \.cg-col > \.m\.m-pr::before\s*\{[^}]*border-right-color: var\(--zc\)/);
  assert.match(css, /\.cg-who \.cg-zb\s*\{[^}]*height: 16px[^}]*border-radius: 4px/);
  assert.match(app, /whoTags\(sp, /);
  assert.match(app, /"cg ag" \+ \(b\.who === "peer" \? " cg-pr" : ""\)/);
});

test("chat page Agent avatar drops the zone-color background: transparent for pets, a #2a2a2a rounded square (radius 12) without a pet", () => {
  assert.match(app, /h\("div", "cav cav-ag"\)/);
  assert.match(css, /\.cav\.cav-ag \.cav-clip\s*\{[^}]*background: none[^}]*box-shadow: none/);
  assert.match(css, /\.cav\.cav-ag \.cav-ini\s*\{[^}]*background: #2a2a2a[^}]*border-radius: 12px/);
  const fn = app.slice(app.indexOf("function chatAvatar("), app.indexOf("function botAvatar("));
  assert.doesNotMatch(fn, /--zc/); // zone color is not applied to the avatar
  assert.doesNotMatch(fn, /lead|gold/); // the lead is not shown on the avatar
});
