// Sub-agent flip bubble + read-only sub-agent conversation page
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { figurePlan, taskStates, chatPlan, agentGlowPlan, agentStatus, agentSort, agentBackTitle, agentCardTime,
  agentTok, modelLabel, agentBackH, agentBackFlips, agentPagePlan } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const T0 = Date.parse("2026-10-21T01:00:00Z") / 1000;
const at = (s) => new Date((T0 + s) * 1000).toISOString();
const U = (text, s) => ({ role: "user", text, ts: at(s) });
const A = (text, s) => ({ role: "assistant", text, ts: at(s) });
const TL = (name, id, s, extra) => Object.assign({ role: "tool", name, text: name, toolUseId: id, ts: at(s), pending: false }, extra || {});
const AG = (id, state, extra) => Object.assign({ id, description: "子代理 " + id, model: "sonnet", agentType: "general-purpose",
  task: "做点事。", state, startedAt: at(10), lastAt: T0 + 100, endedAt: state === "running" ? null : at(70),
  lastStep: "Bash 跑测试", tokens: 1200 }, extra || {});

test("agentGlowPlan: an Agent call with an agent field -> the bubble it anchors to (same key as figurePlan) glows; without meta it does not", () => {
  const items = [U("派活", 0), A("派两个", 1), TL("Agent", "a1", 2, { bg: true, agent: AG("aaaaaaaa", "running") }),
    TL("Agent", "a2", 3, { bg: true }), TL("Bash", "b1", 4)];
  const plan = figurePlan(items, taskStates(items), T0 + 5);
  const glow = agentGlowPlan(items, plan);
  assert.equal(glow.size, 1);
  const g = glow.get(plan[0].key);
  assert.equal(g.status, "run");
  assert.deepEqual(g.agents.map((a) => a.id), ["aaaaaaaa"]);
  const none = [U("派活", 0), A("派", 1), TL("Agent", "a2", 2, { bg: true })];
  assert.equal(agentGlowPlan(none, figurePlan(none, null, T0 + 5)).size, 0);
});

test("agentGlowPlan: the placeholder bubble glows, and when the reply arrives the glow moves to the new bubble (key stays the same)", () => {
  const before = [U("派活", 0), TL("Agent", "a1", 2, { bg: true, agent: AG("aaaaaaaa", "running") })];
  const pb = figurePlan(before, null, T0 + 5, chatPlan(before, { busy: true }));
  const kb = [...agentGlowPlan(before, pb).keys()];
  const after = before.concat([A("派出去了", 6)]);
  const pa = figurePlan(after, null, T0 + 7, chatPlan(after, {}));
  const ka = [...agentGlowPlan(after, pa).keys()];
  assert.deepEqual(kb, ["t:a1"]);
  assert.deepEqual(ka, kb);
});

test("agentStatus: any failed -> fail; else any running -> run; all finished -> done (gone counts as finished)", () => {
  assert.equal(agentStatus([AG("1", "done"), AG("2", "running")]), "run");
  assert.equal(agentStatus([AG("1", "done"), AG("2", "failed"), AG("3", "running")]), "fail");
  assert.equal(agentStatus([AG("1", "done"), AG("2", "done")]), "done");
  assert.equal(agentStatus([AG("1", "done"), AG("2", "gone")]), "done");
});

test("agentSort: failed -> running -> gone -> done, ties ordered by dispatch time", () => {
  const list = [AG("d1", "done"), AG("r1", "running"), AG("f1", "failed"), AG("g1", "gone"),
    AG("r0", "running", { startedAt: at(5) })];
  assert.deepEqual(agentSort(list).map((a) => a.id), ["f1", "r0", "r1", "g1", "d1"]);
});

test("agentBackTitle: running shows elapsed time, all finished shows total time, tokens summed in k", () => {
  const run = agentBackTitle([AG("1", "running", { tokens: 52000 }), AG("2", "done", { tokens: 44000 })], T0 + 10 + 12 * 60 + 5);
  assert.equal(run.n, "2 个子代理");
  assert.equal(run.rest, "· 已跑 12 分 · 共 96k");
  const done = agentBackTitle([AG("1", "done", { endedAt: at(10 + 14 * 60) }), AG("2", "done")], T0 + 9999);
  assert.equal(done.rest, "· 共用时 14 分 · 共 2.4k");
});

test("agentCardTime: running m:ss, finished duration, failed, lost contact", () => {
  assert.equal(agentCardTime(AG("1", "running"), T0 + 10 + 12 * 60 + 34), "在跑 12:34");
  assert.equal(agentCardTime(AG("1", "running"), T0 + 10 + 3600 + 61), "在跑 1:01:01");
  assert.equal(agentCardTime(AG("1", "done", { endedAt: at(10 + 8 * 60 + 12) }), T0), "用时 8 分");
  assert.equal(agentCardTime(AG("1", "done", { endedAt: at(30) }), T0), "用时不到 1 分");
  assert.equal(agentCardTime(AG("1", "failed", { endedAt: at(10 + 3 * 60 + 9) }), T0), "失败 · 3 分");
  assert.match(agentCardTime(AG("1", "gone"), T0 + 5000), /^没动静/);
});

test("agentTok / modelLabel / agentBackH", () => {
  assert.equal(agentTok(96000), "96k");
  assert.equal(agentTok(1250), "1.3k");
  assert.equal(agentTok(400), "0.4k");
  assert.equal(agentTok(0), "0k");
  assert.equal(modelLabel("opus"), "Opus");
  assert.equal(modelLabel("claude-sonnet-4-5"), "Sonnet");
  assert.equal(modelLabel("haiku"), "Haiku");
  assert.equal(modelLabel(""), "默认");
  assert.equal(agentBackH(3), 8 + 28 + 16 + 3 * 66 + 2 * 6 + 28);
  assert.equal(agentBackH(7), agentBackH(5));
});

test("agentPagePlan: on the sub-agent page, user -> main session (left side), assistant/tool -> the sub-agent itself; tool runs still group", () => {
  const items = [U("闪电加强样稿：加两级分叉。", 0), A("先读代码", 2), TL("Read", "r1", 3), TL("Bash", "b1", 4), A("改完了", 9)];
  const plan = agentPagePlan(items);
  const groups = plan.filter((b) => b.t === "group");
  assert.deepEqual(groups.map((g) => g.who), ["main", "bot"]);
  const parts = groups[1].parts.map((p) => p.t);
  assert.deepEqual(parts, ["msg", "msg", "tools"]); // same as the main conversation: the tool run moves under the reply that follows it
});

// ---------- guards: styles and wiring ----------
const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const sw = read("../sw.js");

test("back-face mini cards use a grid with fixed column widths: name column / fixed-width model column / status-time right-aligned (Sonnet and haiku must line up in one column)", () => {
  const m = css.match(/\.ag-card\s*\{([^}]*)\}/);
  assert.ok(m, "missing .ag-card rule");
  assert.match(m[1], /display\s*:\s*grid/);
  assert.match(m[1], /grid-template-columns\s*:\s*minmax\(0, max-content\) auto 1fr auto/, "name column sized to content, model column auto right after the name");
  assert.match(css, /\.ag-tt\s*\{[^}]*(text-align\s*:\s*right|justify-self\s*:\s*end)/);
});

test("glow parameters: #6fb6ff three-layer inner halo, failure tinted red, breathing 2.4s, sweep 5s, idle .6; no animation under reduced motion", () => {
  assert.match(css, /--ag-gl:\s*111,\s*182,\s*255/);
  assert.match(css, /--ag-red:\s*255,\s*107,\s*107/);
  assert.match(css, /inset 0 0 0 1px rgba\(var\(--ag-gl\), \.62\), inset 0 0 3px 0 rgba\(var\(--ag-gl\), \.4\), inset 0 0 32px 2px rgba\(var\(--ag-gl\), \.3\)/);
  assert.match(css, /ag-breathe 2\.4s/);
  assert.match(css, /ag-sweep 5s/);
  assert.match(css, /\.ag-flip\.ag-done [^{]*\{[^}]*opacity:\s*\.6/);
  assert.match(css, /prefers-reduced-motion[\s\S]*\.ag-flip \.ag-in\s*\{\s*transition:\s*none/);
});

test("new class names all carry the ag- prefix and do not collide with existing rules (the stylesheet has no bare .flip/.face/.card-ag)", () => {
  assert.doesNotMatch(css, /\.flip\b|\.face\b|\.card-ag\b|\.bk-hd\b/);
});

test("wiring: flip state stored in st (by bubble key), back face excluded from long-press copy, running timer hooked to tickLive, sub-agent page uses st.agentView", () => {
  assert.match(app, /agFlip: new Set\(\)/);
  assert.match(app, /agentView: null/);
  assert.match(app, /function tickLive\(\)[\s\S]{0,200}tickAgents\(\)/);
  assert.match(app, /\/api\/session\/" \+ encodeURIComponent\(sid\) \+ "\/agent\/"/);
  assert.match(app, /ag-flip/);
});

test("sw VERSION constant format", () => {
  assert.match(sw, /const VERSION = "v142";/);
});

test("extra: when the last group of this session has a running sub-agent and a bubble above it, busy does not append a placeholder bubble; once the sub-agent finishes or there is no bubble to attach to, the placeholder stays", () => {
  const hasPh = (items) => chatPlan(items, { busy: true }).some((b) => b.t === "group" && b.parts.some((p) => p.t === "ph"));
  const running = [U("派活", 0), TL("Agent", "a1", 2, { bg: true, agent: AG("aaaaaaaa", "running") }), A("已派出去改", 6)];
  assert.equal(hasPh(running), false);
  const done = [U("派活", 0), TL("Agent", "a1", 2, { bg: true, agent: AG("aaaaaaaa", "done") }), A("已派出去改", 6)];
  assert.equal(hasPh(done), true);
  const noBubble = [U("派活", 0), TL("Agent", "a1", 2, { bg: true, agent: AG("aaaaaaaa", "running") })];
  assert.equal(hasPh(noBubble), true);
  const after = [U("派活", 0), TL("Agent", "a1", 2, { bg: true, agent: AG("aaaaaaaa", "running") }), A("已派出去改", 6), TL("Bash", "b1", 8, { pending: true })];
  assert.equal(hasPh(after), false);
});

// ---------- clicking anywhere on the back face other than a mini card flips back; back height = title + cards, independent of the front ----------
test("agentBackFlips: a mini card does not flip (opens the sub-agent page); title / blank / shell all flip; the scroll area does not flip beyond 5 cards", () => {
  assert.equal(agentBackFlips("card", 3), false);
  assert.equal(agentBackFlips("card", 9), false);
  assert.equal(agentBackFlips("head", 3), true);
  assert.equal(agentBackFlips("head", 9), true);
  assert.equal(agentBackFlips("list", 3), true);   // gaps between cards, list margins
  assert.equal(agentBackFlips("list", 5), true);
  assert.equal(agentBackFlips("list", 6), false);  // scroll area
  assert.equal(agentBackFlips("back", 9), true);   // bottom padding
});

test("agentBackH accepts measured title/card heights; with 1 card it is much shorter than with 5", () => {
  assert.equal(agentBackH(2, { hd: 30, card: 70, gap: 4 }), 8 + 30 + 16 + 2 * 70 + 4 + 28);
  assert.ok(agentBackH(1) < agentBackH(5) - 4 * 66);
});

test("wiring: flip height does not take the larger of the front; the whole back face flips on click, mini cards stopPropagation", () => {
  assert.doesNotMatch(app, /Math\.max\([a-z.]*offsetHeight, agentBackH/);
  assert.match(app, /agentBackFlips\(/);
  assert.match(app, /bk\.addEventListener\("click"/);
});
