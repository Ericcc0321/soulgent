// Flame animation pauses when off-screen / page hidden, Agents page avatars without background square, little-figure edge cases
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { chatPlan, figurePlan, taskStates } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const blockOf = (head) => {
  const i = css.indexOf(head);
  assert.ok(i > 0, "missing style block " + head);
  const j = css.indexOf("/* =====", i + 10);
  return css.slice(i, j > 0 ? j : undefined);
};
const FIRE_SEL = ".fx-fire.fx-fire-off, .fx-hid .fx-fire {";

const T0 = Date.parse("2026-10-21T01:00:00Z") / 1000;
const at = (s) => new Date((T0 + s) * 1000).toISOString();
const U = (text, s) => ({ role: "user", text, ts: at(s) });
const A = (text, s) => ({ role: "assistant", text, ts: at(s) });
const TL = (name, id, s) => ({ role: "tool", name, text: name, toolUseId: id, ts: at(s), pending: false });
const shape = (plan) => plan.map((b) => b.t === "group"
  ? b.who + "[" + b.parts.map((p) => p.t === "msg" ? "m" + p.i : p.t === "ph" ? "ph" : "T" + p.idx.join(",")).join(" ") + "]"
  : b.t);

// ---------- 2 flame power use ----------
test("app.js: a fire layer is handed to IntersectionObserver once built and gets fx-fire-off when outside the viewport; unobserve when the layer is torn down; fx-hid toggles when the page is hidden", () => {
  assert.match(app, /new IntersectionObserver\(/);
  const sf = app.slice(app.indexOf("function syncFire("), app.indexOf("function syncFire(") + 900);
  assert.match(sf, /fireWatch\(host\._fire\)/);
  assert.match(sf, /fireUnwatch\(host\._fire\)/);
  assert.match(app, /classList\.toggle\("fx-fire-off", !e\.isIntersecting\)/);
  assert.match(app, /classList\.toggle\("fx-hid", document\.hidden\)/);
  assert.match(app, /addEventListener\("visibilitychange", fireVis\)/);
  // avatars torn down by a full redraw: sweep fire layers that left the document so the observed set does not keep growing
  assert.match(app, /function fireSweep\(/);
  assert.match(app, /isConnected/);
  const scf = app.slice(app.indexOf("function syncChatFire("), app.indexOf("function syncChatFire(") + 400);
  assert.match(scf, /fireSweep\(\)/);
});

test("style.css: in the off-screen pause block, fire layers under .fx-fire-off and .fx-hid have animation-play-state: paused", () => {
  const b = blockOf(FIRE_SEL);
  assert.match(b, /\.fx-fire\.fx-fire-off,\s*\.fx-hid \.fx-fire\s*\{[^}]*animation-play-state:\s*paused/);
});

// ---------- 3 Agents page avatars without background square ----------
test("style.css: Agents page (#cr-contacts) avatars drop the gray square, initials keep a rounded gray backing, pets are not clipped at the top; the shortcut area #cr-top is untouched", () => {
  const b = blockOf(FIRE_SEL);
  assert.match(b, /#cr-contacts \.cr-av, #cr-contacts \.cr-av\.off, #cr-contacts \.cr-av\.lead \{ background: none; box-shadow: none; \}/);
  assert.match(b, /#cr-contacts \.cr-ini \{ background: #2a2a2a; border-radius: 12px; \}/);
  assert.match(b, /#cr-contacts \.cr-clip \{ overflow: visible; \}/);
  assert.doesNotMatch(b.replace(/\/\*[\s\S]*?\*\//g, ""), /cr-top|cr-shortcuts|\.cr-c \.cr-av \{/); // look at rules only, not comments
});

// ---------- 4a the time divider does not split a "tool run + the reply right after it" ----------
test("chatPlan: when the reply comes more than 5 minutes after the last tool ends, the divider is still drawn, the tool run still moves under the reply, and the figure key is unchanged", () => {
  const busy = [U("干活", 0), TL("Bash", "b1", 10), TL("Read", "r1", 20)];
  const before = chatPlan(busy, { busy: true });
  assert.deepEqual(shape(before), ["time", "me[m0]", "self[ph T1,2]"]);
  const items = busy.concat([A("做完了", 20 + 400)]);
  const plan = chatPlan(items, {});
  assert.deepEqual(shape(plan), ["time", "me[m0]", "time", "self[m3 T1,2]"]);
  const kb = figurePlan(busy, taskStates(busy), T0 + 30, before).map((f) => f.key);
  const ka = figurePlan(items, taskStates(items), T0 + 430, plan).map((f) => f.key);
  assert.deepEqual(kb, ["t:b1"]);
  assert.deepEqual(ka, kb); // the figure neither disappears nor replays when the reply arrives
});

test("chatPlan: tools run after the previous reply, with a reply 5 minutes later -> tools belong to the new reply; without the timeout nothing changes", () => {
  const items = [U("问", 0), A("先看看", 5), TL("Bash", "b1", 10), A("结论", 10 + 400)];
  assert.deepEqual(shape(chatPlan(items, {})), ["time", "me[m0]", "self[m1]", "time", "self[m3 T2]"]);
  const near = [U("问", 0), A("先看看", 5), TL("Bash", "b1", 10), A("结论", 60)];
  assert.deepEqual(shape(chatPlan(near, {})), ["time", "me[m0]", "self[m1 m3 T2]"]);
  // the one speaking after the timeout is not this session (I sent another message): the tool run stays where it is
  const other = [U("问", 0), A("先看看", 5), TL("Bash", "b1", 10), U("还在吗", 10 + 400)];
  assert.deepEqual(shape(chatPlan(other, {})), ["time", "me[m0]", "self[m1 T2]", "time", "me[m3]"]);
});

// ---------- 4d the click area of the working figure on top does not extend down into the bubble ----------
test("style.css: the click area of the top (not yet landed) figure only extends up/sideways: top + height <= 18 (feet on the bubble top edge, FOOT=18), the body itself takes no clicks", () => {
  const b = blockOf(FIRE_SEL);
  const m = b.match(/\.fg:not\(\.fg-landed\):not\(\.fg-gone\):not\(\.fg-hide\):not\(\.fg-off\)::before \{([^}]*)\}/);
  assert.ok(m, "missing click-area rule for the not-yet-landed figure");
  const top = Number((m[1].match(/top:\s*(-?\d+)px/) || [])[1]);
  const hgt = Number((m[1].match(/height:\s*(\d+)px/) || [])[1]);
  assert.ok(top + hgt <= 18, "click area bottom edge " + (top + hgt) + " overlaps the bubble");
  assert.ok(hgt >= 28, "click area too small");
  assert.match(m[1], /width:\s*32px/);
  assert.match(b, /\.fg:not\(\.fg-landed\):not\(\.fg-gone\):not\(\.fg-hide\):not\(\.fg-off\) \{ pointer-events: none; \}/);
  assert.match(b, /::before \{[^}]*pointer-events: auto/);
});
