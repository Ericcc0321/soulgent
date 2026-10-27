import test from "node:test";
import assert from "node:assert/strict";
import { toolClass, figurePlan, FIG_WAIT_SEC, taskStates, chatPlan } from "../logic.js";
import { FIG, figBand, figTopCap, figTopShown, figLane, figQCap, figQStep, figQX, figCrowd } from "../logic.js";

test("toolClass: 6 class mapping, MCP and unknown map to thinking, AskUserQuestion is not drawn", () => {
  const cases = {
    Bash: "terminal", BashOutput: "terminal", KillShell: "terminal", PowerShell: "terminal", Monitor: "terminal", TaskStop: "terminal",
    Edit: "pencil", Write: "pencil", MultiEdit: "pencil", NotebookEdit: "pencil", Artifact: "pencil",
    Read: "magnifier", Grep: "magnifier", Glob: "magnifier", LS: "magnifier", ToolSearch: "magnifier",
    ListMcpResourcesTool: "magnifier", ReadMcpResourceTool: "magnifier",
    WebFetch: "globe", WebSearch: "globe",
    Agent: "agents", Task: "agents", SendMessage: "agents", ListAgents: "agents", Workflow: "agents",
    Skill: "thinking", TaskCreate: "thinking", TaskUpdate: "thinking", CronCreate: "thinking", EnterPlanMode: "thinking",
    "mcp__claude-in-chrome__computer": "thinking", mcp__netbox__netbox_get_objects: "thinking",
  };
  for (const [n, c] of Object.entries(cases)) assert.equal(toolClass(n), c, n);
  assert.equal(toolClass("AskUserQuestion"), null);
  assert.equal(toolClass(""), null);
});

const T0 = Date.parse("2026-10-21T10:00:00Z") / 1000;
const at = (s) => new Date((T0 + s) * 1000).toISOString();
const A = (text, s) => ({ role: "assistant", text, ts: at(s) });
const U = (text, s) => ({ role: "user", text, ts: at(s) });
const TL = (name, id, s, o = {}) => ({ role: "tool", name, text: name + " x", toolUseId: id, ts: at(s), pending: false, ...o });
const N = (forTool, task, s) => ({ role: "agent", notice: true, forTool, task, ts: at(s) });

test("figurePlan: one figure per call, working / waiting / done / error", () => {
  const items = [
    A("先跑测试", 0),
    TL("Bash", "b1", 1),
    TL("Bash", "b2", 2, { pending: true }),
    TL("Read", "r1", 3),
    TL("Grep", "g1", 4, { isError: true }),
    TL("Edit", "e1", 5, { pending: true }),
    TL("AskUserQuestion", "q1", 6),
  ];
  const p = figurePlan(items, null, T0 + 10);
  assert.equal(p.length, 1);
  assert.equal(p[0].key, "t:b1");
  assert.deepEqual(p[0].idx, [1, 2, 3, 4, 5, 6]);
  assert.deepEqual(p[0].figs, [
    { id: "b1", cls: "terminal", state: "done", since: T0 + 1 },
    { id: "b2", cls: "terminal", state: "working", since: T0 + 2 },
    { id: "r1", cls: "magnifier", state: "done", since: T0 + 3 },
    { id: "g1", cls: "magnifier", state: "error", since: T0 + 4 },
    { id: "e1", cls: "pencil", state: "working", since: T0 + 5 },
  ]);
  const later = figurePlan(items, null, T0 + 2 + FIG_WAIT_SEC + 1);
  assert.equal(later[0].figs[1].state, "working"); // running long still just roams (half speed is decided by figures.js from since)
  assert.equal(later[0].figs[4].state, "working"); // e1 has only been running for 28 s
});

test("figurePlan: two calls of the same kind are two figures; 12 calls -> 12 figures (at most 10 shown below, remainder +2)", () => {
  const two = [A("跑两条", 0), TL("Bash", "b1", 1), TL("Bash", "b2", 2)];
  const f2 = figurePlan(two, null, T0 + 5)[0].figs;
  assert.deepEqual(f2.map((f) => f.id + ":" + f.cls), ["b1:terminal", "b2:terminal"]);
  const many = [A("跑 12 条", 0)];
  for (let k = 0; k < 12; k++) many.push(TL("Bash", "e" + k, 1 + k));
  const f12 = figurePlan(many, null, T0 + 30)[0].figs;
  assert.equal(f12.length, 12);
  assert.equal(new Set(f12.map((f) => f.id)).size, 12);
  assert.ok(f12.every((f) => !("count" in f)));
  assert.equal(figQCap(300), 10);
  assert.equal(f12.length - figQCap(300), 2);
});

test("figurePlan: items without toolUseId get an id from their index in the run", () => {
  const items = [A("旧记录", 0), { role: "tool", text: "Bash ls", ts: at(1) }, { role: "tool", text: "Read a", ts: at(2) }];
  assert.deepEqual(figurePlan(items, null, T0 + 5)[0].figs.map((f) => f.id), ["i:0", "i:1"]);
});

const shape = (g) => g.parts.map((p) => p.t === "msg" ? "m" + p.i : p.t === "ph" ? "PH" : "T" + p.idx.join(","));
const selfGroups = (blocks) => blocks.filter((b) => b.t === "group" && b.who === "self");

test("chatPlan busy: user just sent and the Agent runs tools directly -> separate self group [ph][tools], figures anchored to the placeholder bubble", () => {
  const items = [U("开始", 0), TL("Bash", "b1", 1, { pending: true })];
  const blocks = chatPlan(items, { busy: true });
  const gs = selfGroups(blocks);
  assert.equal(gs.length, 1);
  assert.deepEqual(shape(gs[0]), ["PH", "T1"]);
  const p = figurePlan(items, null, T0 + 3, blocks);
  assert.deepEqual(p.map((x) => x.key), ["t:b1"]);
  assert.equal(p[0].figs[0].state, "working");
  // reply arrived (not busy any more): tools move under the real reply, keys unchanged -> figures do not replay
  const after = items.concat([A("跑完了", 5)]);
  after[1] = { ...after[1], pending: false };
  const b2 = chatPlan(after, {});
  assert.deepEqual(shape(selfGroups(b2)[0]), ["m2", "T1"]);
  assert.deepEqual(figurePlan(after, null, T0 + 6, b2).map((x) => x.key), ["t:b1"]);
});

test("chatPlan busy: running again after a reply -> [msg][moved tools][ph][trailing tools]; the trailing keys are unchanged before and after the reply arrives", () => {
  const items = [U("改", 0), A("看看", 1), TL("Read", "r1", 2), A("开始改", 3), TL("Edit", "e1", 4, { pending: true })];
  const blocks = chatPlan(items, { busy: true });
  assert.deepEqual(shape(selfGroups(blocks)[0]), ["m1", "m3", "T2", "PH", "T4"]);
  const p = figurePlan(items, null, T0 + 5, blocks);
  assert.deepEqual(p.map((x) => x.key), ["t:r1", "t:e1"]);
  const after = items.concat([A("改好了", 6)]);
  const b2 = chatPlan(after, {});
  assert.deepEqual(shape(selfGroups(b2)[0]), ["m1", "m3", "T2", "m5", "T4"]);
  assert.deepEqual(figurePlan(after, null, T0 + 7, b2).map((x) => x.key), ["t:r1", "t:e1"]);
});

test("chatPlan busy: tools moved under the real reply and still busy -> [msg][tools][ph]; last item is the user -> lone [ph]", () => {
  const items = [U("hi", 0), TL("Bash", "b1", 1), A("好了", 2)];
  assert.deepEqual(shape(selfGroups(chatPlan(items, { busy: true }))[0]), ["m2", "T1", "PH"]);
  const u = [A("在", 0), U("再来", 1)];
  const bs = chatPlan(u, { busy: true });
  const last = bs[bs.length - 1];
  assert.equal(last.who, "self");
  assert.deepEqual(shape(last), ["PH"]);
  // not busy: no ph
  assert.ok(!JSON.stringify(chatPlan(u, {})).includes('"ph"'));
});

test("chatPlan busy does not break the trail check (trail is only for waiting; when busy ph must not count as the last item)", () => {
  const items = [A("跑", 0), TL("Bash", "b1", 1, { pending: true })];
  const w = chatPlan(items, {});
  assert.equal(selfGroups(w)[0].parts.find((p) => p.t === "tools").trail, true);
  const b = chatPlan(items, { busy: true });
  assert.equal(selfGroups(b)[0].parts.find((p) => p.t === "tools").trail, true);
});

test("figurePlan: a group that starts with a tool tag (no bubble above) is not drawn; other speakers are not drawn", () => {
  const items = [U("hi", 0), TL("Bash", "b1", 1), A("好了", 2)];
  // tools move under the reply -> attached to the reply bubble
  let p = figurePlan(items, null, T0 + 5);
  assert.deepEqual(p.map((x) => x.key), ["t:b1"]);
  const solo = [U("hi", 0), TL("Bash", "b1", 1)];
  assert.deepEqual(figurePlan(solo, null, T0 + 5), []);
});

test("figurePlan: key is unchanged when the anchor changes", () => {
  const before = [A("我看看", 0), TL("Bash", "b1", 1, { pending: true })];
  const after = before.concat([A("看完了", 3)]);
  assert.equal(figurePlan(before, null, T0 + 2)[0].key, "t:b1");
  assert.equal(figurePlan(after, null, T0 + 4)[0].key, "t:b1");
});

test("figurePlan: agents class follows task notifications (completed = done, failed/killed = error, no notification = running)", () => {
  const base = [A("派个子代理", 0), TL("Agent", "a1", 1, { bg: true })];
  assert.equal(figurePlan(base, null, T0 + 5)[0].figs[0].state, "working");
  const done = base.concat([N("a1", "completed", 50)]);
  assert.equal(figurePlan(done, taskStates(done), T0 + 60)[0].figs[0].state, "done");
  const fail = base.concat([N("a1", "killed", 50)]);
  assert.equal(figurePlan(fail, null, T0 + 60)[0].figs[0].state, "error");
  // it.task from the server index (notification on another page) counts too; a completed received on a follow-up also finishes this round
  const idx = [A("派个子代理", 0), TL("Agent", "a1", 1, { bg: true, task: "completed" })];
  assert.equal(figurePlan(idx, null, T0 + 60)[0].figs[0].state, "done");
  // sub-agent report arrived but no notification: still running (the report is not used as a criterion)
  const hand = base.concat([{ role: "agent", agentName: "x", forTool: "a1", text: "报告", ts: at(40) }]);
  assert.equal(figurePlan(hand, null, T0 + 45)[0].figs[0].state, "working");
});

test("figurePlan: a running background command is working, stopped is done", () => {
  const items = [A("起服务", 0), TL("Bash", "b1", 1, { bg: true })];
  assert.equal(figurePlan(items, null, T0 + 3)[0].figs[0].state, "working");
  const st = items.concat([N("b1", "stopped", 9)]);
  assert.equal(figurePlan(st, null, T0 + 10)[0].figs[0].state, "done");
});

test("figure geometry: constant values", () => {
  assert.deepEqual([FIG.CW, FIG.CH, FIG.FOOT, FIG.LANE, FIG.QSTEP, FIG.QMIN, FIG.QMAX], [18, 20, 18, 14, 10, 6.5, 10]);
  assert.deepEqual(figBand(100, 300), [106, 298]);
  assert.equal(figTopCap(106, 298), 13);
  assert.equal(figTopShown(3, 13), 3);
  assert.equal(figTopShown(5, 3), 2);
  assert.deepEqual(figLane(0, 2, 106, 298), [106, 184]);
  assert.equal(figQCap(300), 10);
  assert.equal(figQCap(60), 5);
  assert.equal(figQStep(1, 60), 10);
  assert.equal(figQStep(10, 300), 10);
  assert.equal(figQStep(10, 80), 6.5);
  assert.equal(figQX(2, 3, 300, 300), 262);
  assert.equal(figCrowd(10, 80), 1);
  assert.equal(figCrowd(2, 300), 0);
});

test("figurePlan: a sub-agent without notification counts as running even after a full turn (background commands still count as done once a turn has passed)", () => {
  const items = [A("派活", 0), TL("Agent", "a1", 1, { bg: true }), TL("Bash", "b1", 2, { bg: true }), A("派好了", 3), U("好", 10), A("收到", 11)];
  const figs = figurePlan(items, null, T0 + 12)[0].figs;
  assert.deepEqual(figs.map((f) => f.id + ":" + f.cls + ":" + f.state), ["a1:agents:working", "b1:terminal:done"]);
});

test("figurePlan: completed tools moved under the last reply plus trailing pending tools form one group anchored to the last bubble", () => {
  const items = [
    U("改一下", 0),
    A("我先看看", 1),
    TL("Read", "r1", 2), TL("Bash", "b1", 3),
    A("看完了，开始改", 4),
    TL("Edit", "e1", 5, { pending: true }), TL("Bash", "b2", 6, { pending: true }),
  ];
  const blocks = chatPlan(items, {});
  const g = blocks.find((b) => b.t === "group" && b.who === "self");
  // r1/b1 move under the second reply and the trailing e1/b2 follow -> two tool tags under the same bubble
  assert.deepEqual(g.parts.map((p) => p.t === "msg" ? "m" + p.i : "T" + p.idx.join(",")), ["m1", "m4", "T2,3", "T5,6"]);
  const p = figurePlan(items, null, T0 + 8, blocks);
  assert.equal(p.length, 1);
  assert.equal(p[0].key, "t:r1");
  assert.equal(p[0].parts.length, 2);
  assert.deepEqual(p[0].idx, [2, 3, 5, 6]);
  assert.deepEqual(p[0].figs.map((f) => f.id + ":" + f.cls + ":" + f.state), ["r1:magnifier:done", "b1:terminal:done", "e1:pencil:working", "b2:terminal:working"]);
  assert.equal(p[0].figs[3].since, T0 + 6);
});

// ---------- figure config ----------
import { pickFigure, figureGeom, setFigGeom, FIG_GEOM_DEFAULT, FIG_BUILTIN } from "../logic.js";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese
const ROWS7 = { 0: 6, 1: 8, 2: 8, 3: 4, 4: 5, 6: 6, 7: 6 };

test("pickFigure: the pet with a figure -> the first complete one -> null when there is no pet (use the built-in figure)", () => {
  const cfg = { top: 50 };
  assert.deepEqual(pickFigure({ "pet-b": { ...ROWS7 }, "pet-c": { ...ROWS7, figure: cfg } }), { name: "pet-c", cfg });
  assert.deepEqual(pickFigure({ "pet-b": { ...ROWS7 }, "pet-a": { 0: 6 } }), { name: "pet-b", cfg: null }); // pet-a is missing rows
  assert.deepEqual(pickFigure({ "pet-z": { ...ROWS7 }, "pet-y": { ...ROWS7, caps: { walk: true } } }), { name: "pet-y", cfg: null });
  assert.deepEqual(pickFigure({ "pet-a": { 0: 6, figure: cfg }, "pet-b": { ...ROWS7 } }), { name: "pet-b", cfg: null }); // the selected one lacks images -> fall back to the first complete one
  assert.equal(pickFigure({}), null);
  assert.equal(pickFigure(null), null);
  assert.equal(FIG_BUILTIN, "/figures/soulflame/");
});

test("figureGeom: config converts to display px; the default config reproduces the standard numbers exactly", () => {
  const g = figureGeom({ frame: [96, 104], foot: 18, footBase: 100, footRow: { 7: 100, 4: 100, 1: 82, 2: 82, 6: 78 }, top: 62, dockClip: 11 });
  assert.ok(Math.abs(g.top - 62 / 104 * 20) < 1e-9);
  assert.equal(g.clip, 11); assert.equal(g.foot, 18); assert.equal(g.bdgDy, -2.08); assert.equal(g.fw, 96);
  assert.equal(g.shift("7").toFixed(2), "0.00"); assert.equal(g.shift("1").toFixed(2), "3.46"); assert.equal(g.shift("6").toFixed(2), "4.23");
  assert.equal(g.shift("3"), 0); // unspecified row = base row
  setFigGeom(g);
  assert.deepEqual([FIG.FOOT, FIG.CLIP], [18, 11]);
  const d = figureGeom(null);
  assert.equal(d.clip, FIG_GEOM_DEFAULT.dockClip); assert.equal(d.foot, FIG_GEOM_DEFAULT.foot); assert.equal(d.shift("1"), 0);
  setFigGeom(d);
});

test("built-in figure: figure.json and all 8 sprite sheets exist, full frame height is not cropped", () => {
  const dir = new URL("../figures/soulflame/", import.meta.url);
  const cfg = JSON.parse(readFileSync(new URL("figure.json", dir), "utf8"));
  const g = figureGeom(cfg);
  assert.equal(g.clip, 0);
  assert.ok(g.top > 0 && g.top < 20);
  for (const n of ["0", "1", "2", "3", "4", "6", "7", "still"]) assert.ok(readFileSync(new URL(n + ".webp", dir)).length > 100, n);
});

