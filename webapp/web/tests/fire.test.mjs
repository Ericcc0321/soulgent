// Fable session avatars get a Blaze Mode flame overlay (flame only, no lightning)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fireLevel, guestSnapshot } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");

test("fireLevel: flame only when model or meta.model contains fable (case-insensitive); busy is the strong level, others weak", () => {
  assert.equal(fireLevel({ kind: "claude", model: "claude-fable-5-1", status: "busy" }), "strong");
  assert.equal(fireLevel({ kind: "claude", model: "claude-fable-5-1", status: "idle" }), "weak");
  assert.equal(fireLevel({ kind: "claude", model: "claude-fable-5-1", status: "waiting" }), "weak");
  assert.equal(fireLevel({ kind: "claude", model: "", meta: { model: "Fable 5.1" }, status: "busy" }), "strong");
  assert.equal(fireLevel({ kind: "claude", model: "FABLE", status: "idle", rest: true }), "weak");
  assert.equal(fireLevel({ kind: "claude", model: "claude-opus-5-5", meta: { model: "Opus 5.5" }, status: "busy" }), null);
  assert.equal(fireLevel({ kind: "claude", status: "busy" }), null);
  assert.equal(fireLevel({ kind: "claude", model: null, meta: null, status: "busy" }), null);
  assert.equal(fireLevel(null), null);
  assert.equal(fireLevel(undefined), null);
  assert.equal(fireLevel({ kind: "claude", model: 42, meta: { model: {} } }), null);
});

test("fireLevel: guest snapshots keep the flame (guestSnapshot preserves model)", () => {
  const raw = { sessions: [{ id: "a", name: "Web-guest-demo", kind: "claude", model: "claude-fable-5-1", status: "busy", since: 1 }] };
  const g = guestSnapshot(raw, 0, null, "Web-guest-demo");
  assert.equal(fireLevel(g.snap.sessions[0]), "strong");
});

test("app.js: list/Agents avatars (fillAv), chat bubble avatars (chatAvatar) and the top-bar #d-pet all attach the flame layer by fireLevel and are not rebuilt when nothing changed", () => {
  assert.match(app, /import \{ fireLevel \} from "\.\/logic\.js";/);
  assert.match(app, /function syncFire\(host, ref, level\)/);
  assert.match(app, /if \(host\._fireLv === lv\) return;/);
  const fill = app.slice(app.indexOf("function fillAv("), app.indexOf("function fillAv(") + 1400);
  assert.match(fill, /syncFire\(av, av\.firstChild, fireLevel\(s\)\)/);
  const cav = app.slice(app.indexOf("function chatAvatar("), app.indexOf("function chatAvatar(") + 1200);
  assert.match(cav, /syncFire\(/);
  assert.match(app, /syncFire\(\$\("#d-pet"\)\.parentNode, \$\("#d-pet"\), /);
  assert.match(app, /function syncChatFire\(/);
});

test("style.css: sprite flame block: busy/idle strips (incl. @2x), hold-keyframe frame switching on ::before, busy 1.08s ping-pong, idle 3s, reduced motion stops at frame 0, no CSS-drawn flame", () => {
  // Only real rules count: strip comments, then assert the flame rules across the whole stylesheet
  const blk = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const fireRules = [...blk.matchAll(/([^{}]*fx-fire[^{}]*)\{([^{}]*)\}/g)].map((m) => m[1] + "{" + m[2] + "}");
  assert.ok(fireRules.length >= 6, "missing flame style rules");
  for (const r of fireRules) assert.doesNotMatch(r, /mix-blend-mode|radial-gradient|mask-image|clip-path|conic-gradient/, "the flame must use sprites only, not CSS drawing: " + r);
  for (const f of ["busy.png", "busy@2x.png", "idle.png", "idle@2x.png"]) assert.ok(blk.includes("/fx/fire/" + f), "missing " + f);
  assert.match(blk, /image-set\(/);
  // frames: the ::before strip (busy 12 x 96px = 1152px, idle 6 x 96px = 576px) steps with transform hold keyframes; busy 1.08s ping-pong, idle 3s loop
  assert.match(blk, /\.fx-fire::before \{[^}]*background-image: inherit;[^}]*background-size: 100% 120px;[^}]*animation-iteration-count: infinite;[^}]*animation-play-state: inherit;/);
  assert.match(blk, /\.fx-fire-s::before \{ width: 1152px; animation-name: fx-fire-busy; animation-duration: 1\.08s; animation-direction: alternate; \}/);
  assert.match(blk, /\.fx-fire-w::before \{ width: 576px; animation-name: fx-fire-idle; animation-duration: 3s; \}/);
  assert.match(blk, /@keyframes fx-fire-busy \{ 0%, 8\.3332% \{ transform: translateX\(0px\); \}[^\n]* 91\.6667%, 100% \{ transform: translateX\(-1056px\); \} \}/);
  assert.match(blk, /@keyframes fx-fire-idle \{ 0%, 16\.6666% \{ transform: translateX\(0px\); \}[^\n]* 83\.3333%, 100% \{ transform: translateX\(-480px\); \} \}/);
  assert.doesNotMatch(blk, /@keyframes fx-fire-[^{]*\{[^\n]*background-position/); // background-position animations keep Safari on the main thread
  assert.match(blk, /transform-origin:\s*48px 112px/); // scales around the foot point
  assert.match(blk, /prefers-reduced-motion:\s*reduce\)\s*\{\s*\.fx-fire::before \{ animation: none !important; \}/);
  assert.doesNotMatch(blk, /fx-fire-tgs|fx-fire-egg/);
  assert.match(blk, /\.cr-av > \.fx-fire \{[^}]*--ff-k: 1;/);
  assert.match(blk, /\.cav-clip > \.fx-fire, \.mini > \.fx-fire \{[^}]*--ff-k: \.78;/);
});

test("app.js: the flame layer is a single div (fireNode), no more assembled tongues", () => {
  assert.match(app, /function fireNode\(\) \{\s*return h\("div", "fx-fire"\);\s*\}/);
  assert.doesNotMatch(app, /fireTongues|fx-fire-tgs|fx-fire-egg/);
  assert.match(app, /host\._fire\.className = "fx-fire " \+ \(lv === "strong" \? "fx-fire-s" : "fx-fire-w"\)/);
});

test("frame images in web/fx/fire/: the four sprite strips have the right dimensions", () => {
  const png = (f) => readFileSync(new URL("../fx/fire/" + f, import.meta.url));
  const dim = (b) => [b.readUInt32BE(16), b.readUInt32BE(20)];
  assert.deepEqual(dim(png("busy.png")), [1152, 120]);
  assert.deepEqual(dim(png("idle.png")), [576, 120]);
  assert.deepEqual(dim(png("busy@2x.png")), [2304, 240]);
  assert.deepEqual(dim(png("idle@2x.png")), [1152, 240]);
});
