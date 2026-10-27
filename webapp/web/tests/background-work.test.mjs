// Background work display: background task state and header helper counts
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { figurePlan, chatRow, busyFx, headStat } from "../logic.js";
import { setLang, table } from "../i18n.js";
setLang("hans");

const T0 = Date.parse("2026-10-24T10:00:00Z") / 1000;
const at = (s) => new Date((T0 + s) * 1000).toISOString();
const A = (text, s) => ({ role: "assistant", text, ts: at(s) });
const U = (text, s) => ({ role: "user", text, ts: at(s) });
const TL = (name, id, s, o = {}) => ({ role: "tool", name, text: name + " x", toolUseId: id, ts: at(s), pending: false, ...o });
const N = (forTool, task, s) => ({ role: "agent", notice: true, forTool, task, ts: at(s) });
const Z = [{ code: "W", name: "Web", color: "#fff" }];
const S = (o) => ({ id: "s1", name: "W-x", zone: "W", status: "idle", since: T0 - 3600, summary: "好了", ...o });

test("bgActive / bgRun / bgStaleRow：bgTasks>0 and not stuck counts as running; busy and waiting rows are not counted separately", () => {
  assert.equal(L.bgActive(S({ bgTasks: 2 })), true);
  assert.equal(L.bgActive(S({ bgTasks: 0 })), false);
  assert.equal(L.bgActive(S({})), false);
  assert.equal(L.bgActive(S({ bgTasks: 1, bgStale: true })), false);
  assert.equal(L.bgActive(null), false);
  assert.equal(L.bgRun(S({ bgTasks: 2 })), true);
  assert.equal(L.bgRun(S({ bgTasks: 2, status: "busy" })), false);
  assert.equal(L.bgRun(S({ bgTasks: 2, status: "waiting" })), false);
  assert.equal(L.bgStaleRow(S({ bgTasks: 1, bgStale: true })), true);
  assert.equal(L.bgStaleRow(S({ bgTasks: 0, bgStale: true })), false);
});

test("list row: green background-running (N) tag, timer from bgSince, no red dot", () => {
  const r = chatRow(S({ bgTasks: 2, bgSince: T0 - 600 }), Z, T0);
  assert.deepEqual(r.tag, { cls: "g", text: "后台在跑 (2)" });
  assert.equal(r.bgRun, true);
  assert.equal(r.liveSince, T0 - 600);
  assert.equal(r.badge, "");
  assert.equal(r.kind, "d");
  // bgSince missing: fall back to since
  assert.equal(chatRow(S({ bgTasks: 1 }), Z, T0).liveSince, T0 - 3600);
  // the red dot follows the snapshot's unread: absent unless the server sets it (the frontend never adds it)
  assert.equal(chatRow(S({ bgTasks: 1, unread: true }), Z, T0).badge, "dot");
  assert.equal(chatRow(S({ bgTasks: 1, unread: true }), Z, T0).tag, null);
});

test("list row: bgStale shows a grey \"possibly stuck\" label without a timer; busy rows keep their normal display", () => {
  const r = chatRow(S({ bgTasks: 1, bgStale: true }), Z, T0);
  assert.deepEqual(r.tag, { cls: "h", text: "后台任务疑似挂住" });
  assert.equal(r.bgRun, false);
  assert.equal(r.liveSince, 0);
  const b = chatRow(S({ status: "busy", bgTasks: 1, bgSince: T0 - 5, since: T0 - 60 }), Z, T0);
  assert.equal(b.kind, "g");
  assert.equal(b.liveSince, T0 - 60);
  assert.deepEqual(b.tag, { cls: "g", text: "正在干活" });
});

test("busyFx: idle rows with background work also wander out of the frame; stuck / no-background rows stay put", () => {
  const caps = { walk: true };
  assert.equal(busyFx(S({ bgTasks: 1 }), "pet", Z, caps, "ok").kind, "walk");
  assert.equal(busyFx(S({ bgTasks: 1 }), "pet", Z, caps, "ok").actor.name, "pet");
  assert.equal(busyFx(S({ bgTasks: 1 }), null, Z, null, "none").actor.type, "flame");
  assert.equal(busyFx(S({ bgTasks: 1, bgStale: true }), "pet", Z, caps, "ok"), null);
  assert.equal(busyFx(S({}), "pet", Z, caps, "ok"), null);
});

test("helperCounts: M = max(0, bgTasks - bgAgents), N = helpers - M; without helpers falls back to bgAgents + M", () => {
  assert.deepEqual(L.helperCounts(S({ helpers: 3, bgTasks: 2, bgAgents: 1 })), { n: 2, m: 1, total: 3 });
  assert.deepEqual(L.helperCounts(S({ helpers: 4, bgTasks: 1, bgAgents: 1 })), { n: 4, m: 0, total: 4 }); // foreground subagents are also counted in helpers
  assert.deepEqual(L.helperCounts(S({ bgTasks: 3, bgAgents: 1 })), { n: 1, m: 2, total: 3 });
  assert.deepEqual(L.helperCounts(S({})), { n: 0, m: 0, total: 0 });
  assert.deepEqual(L.helperCounts(S({ helpers: 1, bgTasks: 3, bgAgents: 0 })), { n: 0, m: 3, total: 3 }); // never negative
  assert.deepEqual(L.helperCounts(S({ agents: 5 })), { n: 0, m: 0, total: 0 }); // the phone does not read the legacy agents field
});

test("header pill: \"SA N · BG M\" is identical in all three languages; a zero segment shows only the other; no queue count or elapsed-minutes text", () => {
  for (const lang of ["en", "hans", "hant"]) {
    setLang(lang);
    assert.equal(headStat(S({ helpers: 3, bgTasks: 1, bgAgents: 0 })).top, "SA 2 · BG 1", lang);
    assert.equal(headStat(S({ helpers: 2, bgTasks: 0 })).top, "SA 2", lang);
    assert.equal(headStat(S({ helpers: 1, bgTasks: 1 })).top, "BG 1", lang);
    assert.equal(headStat(S({ status: "busy", since: 1 })).top, "", lang);
    assert.equal(headStat(S({ status: "busy", since: 1, helpers: 1 })).bottom, "", lang);
  }
  setLang("hans");
  for (const k of ["head.agents", "head.bgCmds", "head.helperList"]) for (const c of table()[k]) assert.match(String(c), /^(SA|BG) \{/);
  assert.equal(L.helperLabel(0, 0), "");
});

test("helper list: with bgList, list by it (subagents first, newest on top, commands after); more counts entries without details", () => {
  const s = S({
    helpers: 4, bgTasks: 3, bgAgents: 2,
    bgList: [
      { kind: "cmd", desc: "npm run dev", since: T0 - 720, id: "bx1", toolUseId: "tu_cmd" },
      { kind: "agent", desc: "check API", since: T0 - 100, id: "ag1", toolUseId: "tu_a1" },
      { kind: "agent", desc: "review i18n", since: T0 - 75, id: "ag2", toolUseId: "tu_a2" },
    ],
  });
  const v = L.helperSheet(s, T0);
  assert.equal(v.title, "SA 3 · BG 1");
  assert.equal(v.has, true);
  assert.deepEqual(v.rows.map((r) => r.id), ["ag2", "ag1", "bx1"]);
  assert.deepEqual(v.rows.map((r) => r.time), ["1:15", "1:40", "12 分"]);
  assert.equal(v.more, 1); // helpers 4, list has 3 rows: 1 more (a foreground subagent)
  assert.equal(v.cmdOnly, 0);
  assert.deepEqual(v.rows.map((r) => r.toolUseId), ["tu_a2", "tu_a1", "tu_cmd"]);
});

test("helper list: without bgList show a single background-commands x M row; no row when M is 0", () => {
  const v = L.helperSheet(S({ helpers: 3, bgTasks: 2, bgAgents: 0 }), T0);
  assert.equal(v.has, false);
  assert.deepEqual(v.rows, []);
  assert.equal(v.cmdOnly, 2);
  assert.equal(v.title, "SA 1 · BG 2");
  assert.equal(L.helperSheet(S({ helpers: 2 }), T0).cmdOnly, 0);
  assert.equal(L.helperSheet(S({ helpers: 2, bgList: [] }), T0).has, true); // an empty bgList means the host reports no background tasks; do not fall back
});

const ITEMS = [U("起个服务", 0), A("好", 1), TL("Bash", "b1", 2, { bg: true }), A("起好了", 3), U("再聊一句", 10), A("收到", 11)];

test("fallback: after a full turn, if the snapshot says background work is still running, the background Bash figure stays working; stuck / no background reverts to the plain judgement (done)", () => {
  assert.equal(figurePlan(ITEMS, null, T0 + 12)[0].figs[0].state, "done"); // no background work: plain result
  const live = L.bgLiveIds(ITEMS, S({ bgTasks: 1, bgAgents: 0, helpers: 1 }));
  assert.deepEqual([...live], ["b1"]);
  assert.equal(figurePlan(ITEMS, null, T0 + 12, undefined, live)[0].figs[0].state, "working");
  assert.equal(L.bgLiveIds(ITEMS, S({ bgTasks: 1, bgStale: true })).size, 0);
  assert.equal(L.bgLiveIds(ITEMS, S({ bgTasks: 0 })).size, 0);
  assert.equal(figurePlan(ITEMS, null, T0 + 12, undefined, L.bgLiveIds(ITEMS, S({ bgTasks: 0 })))[0].figs[0].state, "done");
});

test("fallback: tasks with a (finished) notice are not pulled back to working; errors stay error", () => {
  const done = ITEMS.concat([N("b1", "completed", 30)]);
  assert.equal(figurePlan(done, null, T0 + 40, undefined, new Set(["b1"]))[0].figs[0].state, "done");
  const bad = [U("跑", 0), A("好", 1), TL("Bash", "b1", 2, { bg: true, isError: true }), A("嗯", 3)];
  assert.equal(figurePlan(bad, null, T0 + 5, undefined, new Set(["b1"]))[0].figs[0].state, "error");
});

test("fallback (no bgList): only the newest M unfinished background Bash calls are pulled back; earlier ones still count as done", () => {
  const items = [U("起两个", 0), A("好", 1), TL("Bash", "b1", 2, { bg: true }), TL("Bash", "b2", 3, { bg: true }), A("起好了", 4), U("再说", 10), A("收", 11)];
  const live = L.bgLiveIds(items, S({ bgTasks: 1, bgAgents: 0 }));
  assert.deepEqual([...live], ["b2"]);
  const figs = figurePlan(items, null, T0 + 12, undefined, live)[0].figs;
  assert.deepEqual(figs.map((f) => f.id + ":" + f.state), ["b1:done", "b2:working"]);
});

test("fallback (with bgList): by bgList toolUseId; a subagent's id never pulls back other figures", () => {
  const s = S({ bgTasks: 2, bgAgents: 1, helpers: 2, bgList: [{ kind: "cmd", desc: "d", since: T0, id: "x", toolUseId: "b1" }, { kind: "agent", desc: "a", since: T0, id: "y", toolUseId: "ag9" }] });
  assert.deepEqual([...L.bgLiveIds(ITEMS, s)].sort(), ["ag9", "b1"]);
  assert.equal(figurePlan(ITEMS, null, T0 + 12, undefined, L.bgLiveIds(ITEMS, s))[0].figs[0].state, "working");
});

test("jump target of a list row: with bgList use its own toolUseId; otherwise the newest unfinished background Bash; otherwise empty", () => {
  assert.equal(L.bgJumpTu({ toolUseId: "tu1" }, ITEMS), "tu1");
  assert.equal(L.bgJumpTu({}, ITEMS), "b1");
  assert.equal(L.bgJumpTu(null, ITEMS), "b1");
  const two = ITEMS.concat([TL("Bash", "b2", 20, { bg: true })]);
  assert.equal(L.bgJumpTu({}, two), "b2");
  assert.equal(L.bgJumpTu({}, two.concat([N("b2", "killed", 30)])), "b1");
  assert.equal(L.bgJumpTu({}, [U("x", 0)]), "");
  assert.deepEqual(L.bgOpenCmds([TL("Bash", "f1", 1), TL("Agent", "a1", 2, { bg: true })]), []); // non-background Bash and subagents do not count
});

test("shell: app wires the list / fallback / row timer, the pill is clickable, all three languages have the description and BG subtitle", () => {
  const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
  const app = rd("app.js"), html = rd("index.html"), css = rd("style.css");
  assert.match(app, /bgLiveIds\(items, s\)/);
  assert.match(app, /bindOn\("#d-stat", openHelperSheet\)/);
  assert.match(app, /r\.liveSince/);
  assert.match(html, /id="d-stat"[^>]*role="button"/);
  assert.match(css, /\.bg-flash/);
  const T = table();
  for (const k of ["head.helperTip", "head.helperBgN", "head.helperMore", "row.bgRun", "row.bgStale", "head.helperGone", "head.helperAria"]) {
    assert.equal(T[k].length, 3, k);
    assert.ok(T[k].every((x) => x && x.length), k);
  }
  assert.deepEqual(T["head.helperBg"], ["BG", "BG", "BG"]);
  assert.doesNotMatch(app, /head\.queued|head\.busyMin/);
});
