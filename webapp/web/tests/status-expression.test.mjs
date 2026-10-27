// Status expression: urgent shake while waiting (knock + reduced motion), whole page greyed when the snapshot is stale,
// WorkBuddy status tag, Orca-not-running hint, tool figures always roam (half speed when slow), no desk, only errand/carry effects (figures that cannot walk use a stand-in),
// Codex / WorkBuddy list badges
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { setLang, t } from "../i18n.js";
setLang("hans");

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const css = rd("style.css");

// ---------- 1. urgent shake while waiting ----------
test("urgent shake: neither the crnudge nor an overriding animation:none is present", () => {
  assert.doesNotMatch(css, /crnudge/);
  assert.doesNotMatch(css, /\.cr-row\.w \.cr-av\s*\{\s*animation:\s*none/);
});
test("urgent shake A (knock): attached to .cr-clip (the red dot does not shake), once every 3 s, ±6° decreasing each time, staggered by --nd", () => {
  const m = css.match(/\.cr-row\.w \.cr-av > \.cr-clip\s*\{([^}]*)\}/);
  assert.ok(m, "a .cr-row.w .cr-av > .cr-clip rule is required");
  assert.match(m[1], /animation:\s*cr-knock 3s/);
  assert.match(m[1], /animation-delay:\s*var\(--nd/);
  assert.match(m[1], /transform-origin:\s*50% 85%/);
  const k = css.slice(css.indexOf("@keyframes cr-knock"), css.indexOf("@keyframes cr-knock") + 400);
  for (const d of ["-6deg", "5deg", "-3deg", "1.5deg"]) assert.ok(k.includes("rotate(" + d + ")"), d);
  assert.match(k, /15%,\s*100%\s*\{\s*transform:\s*none/); // 0.45 s = 15% of 3 s, still afterwards
});
test("reduced motion: after the global reduce rule, the waiting avatar outline fades in and out every 2 s (opacity only, !important overrides the global rule)", () => {
  const g = css.indexOf("*, *::before, *::after { animation: none !important;");
  assert.ok(g > 0);
  const i = css.indexOf(".cr-row.w .cr-av::before", g);
  assert.ok(i > g, "the reduced-motion rule must come after the global reduce rule");
  const blk = css.slice(css.lastIndexOf("@media (prefers-reduced-motion: reduce)", i), css.indexOf("}\n}", i) + 3);
  assert.match(blk, /animation:\s*cr-r3 2s[^;]*!important/);
  const k = css.slice(css.indexOf("@keyframes cr-r3"), css.indexOf("@keyframes cr-r3") + 120);
  assert.match(k, /opacity/);
  assert.doesNotMatch(k, /transform/);
});
test("urgent shake: stops inside the chat page and when the Mac is disconnected", () => {
  assert.match(css, /body\.in-detail \.cr-row \.cr-av > \.cr-clip/);
  assert.match(css, /body\.mac-down [^{]*\*[^{]*\{[^}]*animation-play-state:\s*paused !important/);
});
test("urgent shake: app.js sets --nd on avatars to stagger them", () => {
  assert.match(rd("app.js"), /setProperty\("--nd"/);
});

// ---------- 2. whole page greyed when the snapshot is stale ----------
test("macDown: offline, server says stale, or over 30 s all count as disconnected", () => {
  assert.equal(L.macDown({ generatedAt: 100, stale: false }, false, 120), false);
  assert.equal(L.macDown({ generatedAt: 100, stale: false }, false, 131), true);
  assert.equal(L.macDown({ generatedAt: 100, stale: true }, false, 101), true);
  assert.equal(L.macDown({ generatedAt: 100 }, true, 101), true);
  assert.equal(L.macDown(null, false, 0), false);
});
test("macLine: when stale, the heartbeat reason says whether the helper stopped or the board is unresponsive; offline (phone cannot connect) keeps its own text", () => {
  const at = "10:05";
  assert.equal(L.macLine({ down: { reason: "helper" } }, { stale: true, at }).text, t("mac.helperDown", { at }));
  assert.equal(L.macLine({ down: { reason: "panel" } }, { stale: true, at }).text, t("mac.panelDown", { at }));
  assert.equal(L.macLine({ down: { reason: "helper" } }, { stale: true, at }).short, t("mac.helperDownShort", { at })); // the short form used when the status line is too narrow carries the reason too
  assert.equal(L.macLine({ down: { reason: "panel" } }, { stale: true, at }).short, t("mac.panelDownShort", { at }));
  assert.equal(L.macLine({ down: { reason: "x" } }, { stale: true, at }).text, t("mac.disconnected", { at }));
  assert.equal(L.macLine({ down: { reason: "helper" } }, { offline: true, at }).text, t("mac.disconnected", { at }));
  assert.equal(L.macLine({}, { stale: true, at }).dot, "off");
});
test("whole-page grey styles: rows grey out, animations all stop, tab bar red dot turns grey", () => {
  assert.match(css, /body\.mac-down \.cr-list \.cr-row[^{]*\{[^}]*filter:\s*grayscale\(1\)[^}]*opacity:\s*\.5/);
  assert.match(css, /body\.mac-down \.cr-tb\s*\{[^}]*background:\s*#5e5e5e/);
});
test("app.js: when disconnected the timer freezes at the disconnect moment (tickLive does not advance, fillMsgLi uses downAt)", () => {
  const a = rd("app.js");
  assert.match(a, /classList\.toggle\("mac-down"/);
  assert.match(a, /function liveNow\(\)/);
  const tl = a.slice(a.indexOf("function tickLive()"), a.indexOf("setInterval(tickLive"));
  assert.match(tl, /liveNow\(\)/);
});

// ---------- 3. WorkBuddy status tag ----------
const WB = (code, o = {}) => ({ id: "w1", kind: "workbuddy", name: "Docs-wb", zone: "Docs", status: "idle", since: 100,
  summary: { "state.error": "出错", "state.stopped": "已中止", "state.paused": "已暂停" }[code] || "", summaryCode: code, summaryArgs: {}, ...o });
test("wbState: only recognizes state.error / stopped / paused", () => {
  assert.equal(L.wbState(WB("state.error")), "error");
  assert.equal(L.wbState(WB("state.stopped")), "stopped");
  assert.equal(L.wbState(WB("state.paused")), "paused");
  assert.equal(L.wbState(WB("text")), null);
  assert.equal(L.wbState(null), null);
});
test("chatRow: WorkBuddy status becomes a tag (error red, stopped/paused grey), the summary is not repeated", () => {
  const e = L.chatRow(WB("state.error"), [], 200);
  assert.deepEqual(e.tag, { cls: "e", text: t("row.tagErr") });
  assert.equal(e.text, "");
  assert.deepEqual(L.chatRow(WB("state.stopped"), [], 200).tag, { cls: "h", text: t("row.tagStopped") });
  assert.deepEqual(L.chatRow(WB("state.paused"), [], 200).tag, { cls: "h", text: t("row.tagPaused") });
  // with a red dot it is still a u row and the tag is still given; waiting / busy do not override it
  const u = L.chatRow(WB("state.error", { unread: true }), [], 200);
  assert.equal(u.kind, "u");
  assert.equal(u.tag.cls, "e");
  assert.equal(L.chatRow(WB("state.error", { status: "busy" }), [], 200).tag.cls, "g");
  // a draft still overrides it
  assert.equal(L.chatRow(WB("state.error"), [], 200, "草稿").tag.cls, "dr");
});
test("styles: error in red text, stopped/paused in grey text", () => {
  assert.match(css, /\.cr-pt\.e\s*\{[^}]*color:\s*var\(--err\)/); // all error states use the brick red --err
  assert.match(css, /\.cr-pt\.h\s*\{[^}]*color:\s*var\(--c-t2\)/);
});

// ---------- 4. Orca not running ----------
test("orcaDown: only an explicit running=false counts (a snapshot without the field is treated as online)", () => {
  assert.equal(L.orcaDown({ orca: { running: false } }), true);
  assert.equal(L.orcaDown({ orca: { running: true } }), false);
  assert.equal(L.orcaDown({}), false);
  assert.equal(L.orcaDown(null), false);
});
test("the chat page has an Orca hint row above the input; the wake button is greyed out when Orca is not running", () => {
  assert.match(rd("index.html"), /id="orca-hint"/);
  const a = rd("app.js");
  assert.match(a, /t\("orca\.downHint"\)/);
  assert.match(a, /t\("wake\.orcaDown"\)/);
});

// ---------- 5. tool figures always roam ----------
test("figurePlan: anything still running is working, waiting is not produced", () => {
  const T0 = 1_700_000_000;
  const at = (s) => new Date((T0 + s) * 1000).toISOString();
  const items = [
    { role: "assistant", text: "先跑", ts: at(0) },
    { role: "tool", name: "Bash", text: "Bash sleep", toolUseId: "b1", pending: true, ts: at(1) },
  ];
  const p = L.figurePlan(items, null, T0 + 1 + L.FIG_WAIT_SEC + 100);
  assert.equal(p[0].figs[0].state, "working");
});
test("figRoam: when slow only the speed halves, still plays row 7, never stands still", () => {
  const r0 = () => 0;
  const k = L.figRoam("working", 10, [10, 40], [10, 200], r0);
  const s = L.figRoam("working", 10, [10, 40], [10, 200], r0, true);
  assert.equal(s.ms, k.ms * 2);
  assert.equal(s.strip, "7");
  assert.equal(s.rest, "7");
  assert.equal(s.pause, k.pause);
  assert.equal(L.figRoam("waiting", 10, [10, 40], [10, 200], r0), null); // there is no waiting pose
});
test("figures.js: no row-6 waiting pose any more; half speed when slow, judged from since", () => {
  const f = rd("figures.js");
  assert.doesNotMatch(f, /WAIT_STRIP/);
  assert.match(f, /FIG_WAIT_SEC/);
});

// ---------- 6. no desk ----------
const ZS = [{ code: "Docs", fx: "marquee" }, { code: "Plain" }];
const B = (o = {}) => ({ id: "s1", status: "busy", zone: null, ...o });
test("busyFx: never returns a desk; pets that can walk leave the frame themselves, those that cannot use the built-in stand-in", () => {
  for (const caps of [null, {}, { unsure: true }, { deskOwn: true }, { walk: "yes" }]) {
    const f = L.busyFx(B(), "pet-plain", ZS, caps);
    assert.equal(f.kind, "walk");
    assert.ok(f.mode === "run" || f.mode === "carry", JSON.stringify(caps));
    assert.deepEqual(f.actor, { type: "flame" });
  }
  assert.deepEqual(L.busyFx(B(), "pet-walker", ZS, { walk: true }).actor, { type: "pet", name: "pet-walker" });
});
test("busyFx: with no pet installed (petsKnown=none) the built-in figure leaves the frame; before the pet list is known nothing leaves the frame", () => {
  assert.deepEqual(L.busyFx(B(), null, ZS, null, "none").actor, { type: "flame" });
  assert.equal(L.busyFx(B(), null, ZS, null), null);
  assert.equal(L.busyFx(B({ zone: "Docs" }), null, ZS, null).kind, "marquee"); // zone effects stay as configured
});
test("walkFit: does not fall back to a desk; if it does not fit it stays inside the avatar", () => {
  assert.equal(L.FX_TRACK_MIN.desk, undefined);
  assert.equal(L.walkFit("run", 96), "run");
  assert.equal(L.walkFit("carry", 95), null);
  assert.equal(L.walkFit("run", 80), null);
});
test("built-in figure assets: FLAME_ROWS row 7 has 6 frames", () => {
  assert.equal(L.FLAME_ROWS["7"], 6);
});
test("there are no desk styles or drawing code", () => {
  for (const k of ["fxw-desk", "fxw-chair", "fxw-lid", "fxw-light", "fxw-bit", "fxw-type"]) assert.ok(!css.includes(k), k);
  const a = rd("app.js");
  assert.doesNotMatch(a, /FX_CHAIR|FX_LAPTOP|fxw-desk/);
});

// ---------- 7. Codex / WorkBuddy badges ----------
test("kindTag: codex / codexApp -> Codex, workbuddy -> WorkBuddy, claude gets none, unknown kinds are capitalized", () => {
  assert.equal(L.kindTag("codex"), t("kind.codex"));
  assert.equal(L.kindTag("codexApp"), t("kind.codex"));
  assert.equal(L.kindTag("workbuddy"), t("kind.workbuddy"));
  assert.equal(L.kindTag("claude"), null);
  assert.equal(L.kindTag(undefined), null);
  assert.equal(L.kindTag("gemini"), "Gemini");
  assert.equal(L.chatRow({ id: "c", kind: "codex", status: "idle", since: 1 }, [], 2).kindTag, "Codex");
  assert.equal(L.chatRow({ id: "c", kind: "claude", status: "idle", since: 1 }, [], 2).kindTag, null);
});
test("badge styles: grey outline, drawn in both list rows and the contacts list", () => {
  assert.match(css, /\.cr-kind\s*\{[^}]*box-shadow:\s*inset 0 0 0 \.5px/);
  const a = rd("app.js");
  assert.ok((a.match(/"cr-kind"/g) || []).length >= 2, "fillMsgLi and contactRow must both draw the badge");
});

// ---------- version ----------
test("sw VERSION matches index.html zbs-shell", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
