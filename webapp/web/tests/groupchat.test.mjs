// Group-chat style chat page: speaker identity, zone inference, grouping and tool-row relocation
import { test } from "node:test";
import assert from "node:assert/strict";
import { zoneOfName, speakerDir, speakerOf, speakerKey, speakerInitials, stripGuestTag, chatPlan, toolMark, taskStates, turnAfter, chatStamp, stripFrom, isNotice, isHandback, whoTags } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const ZONES = [
  { code: "Docs", name: "Docs", color: "#E0A040", lead: "Docs-Wiki-app" },
  { code: "Web", name: "WEB", color: "#40B0A0", lead: "Web-UI-refactor" },
  { code: "Infra", name: "基础设施", short: "通用", color: "#5080D0", lead: "Infra-AI-Router" },
  { code: "Lab", name: "个人", color: "#A070D0", lead: "Lab-Settings" },
];
const SNAP = {
  zones: ZONES,
  sessions: [
    { id: "s1", name: "Web-guest-demo", plate: "guest-demo", zone: "Web", pet: "whaley" },
    { id: "s2", name: "Web-UI-refactor", plate: "UI-refactor", zone: "Web", pet: "pet-fe" },
    { id: "s3", name: "Web-Landing", plate: "Landing", zone: "Web", pet: null },
    { id: "s4", name: "Docs-Wiki-app", plate: "Wiki-app", zone: "Docs", pet: "boxcat" },
    { id: "s5", name: "Infra-bot", plate: "bot", zone: "Infra", pet: "red-panda" },
  ],
  offduty: [{ name: "Docs-Tools", sid: "off1", zone: "Docs" }, { name: "示例卡", sid: "off2", zone: "未分区" }],
};
const SELF = { name: "Web-guest-demo", zone: "Web", pet: "whaley", id: "s1" };
const who = (name, snap = SNAP, guest = false, self = SELF) =>
  speakerOf(name, self, speakerDir(snap, guest), snap.zones, guest);

test("zone inference: by prefix, only known zone codes, longest wins", () => {
  assert.equal(zoneOfName("Web-UI-refactor", ZONES), "Web");
  assert.equal(zoneOfName("Docs-Dash-Mobile", ZONES), "Docs");
  assert.equal(zoneOfName("top", ZONES), null);
  assert.equal(zoneOfName("Web", ZONES), null);           // prefix only, no name
  assert.equal(zoneOfName("Foo-bar", ZONES), null);      // unknown prefix
  assert.equal(zoneOfName("Web-X-y", [{ code: "Web" }, { code: "Web-X" }]), "Web-X");
});

test("identity: self / teammate / team lead / cross-team / other team's lead", () => {
  let s = who("Web-guest-demo");
  assert.deepEqual([s.role, s.plate, s.zone, s.cross, s.lead], ["self", "guest-demo", "Web", false, false]);
  assert.deepEqual(s.pet, { pet: "whaley", id: "s1" });
  s = who("Web-Landing");
  assert.deepEqual([s.role, s.cross, s.lead, s.color, s.zoneName], ["mate", false, false, "#40B0A0", "WEB"]);
  assert.deepEqual(s.pet, { pet: null, id: "s3" }); // no pet specified: petName picks one by id
  s = who("Web-UI-refactor");
  assert.deepEqual([s.role, s.lead, s.cross], ["lead", true, false]);
  s = who("Infra-bot");
  assert.deepEqual([s.role, s.cross, s.short, s.color, s.zoneName], ["cross", true, "通用", "#5080D0", "基础设施"]);
  s = who("Docs-Wiki-app");
  assert.deepEqual([s.role, s.cross, s.lead, s.short], ["crossLead", true, true, "Docs"]);
});

test("badge short name: snapshot zones[].short, else the zone name, else the code", () => {
  const zs = [{ code: "Infra", name: "基础设施", short: "通用" }, { code: "Web", name: "前端组" }, { code: "Ops", name: "" }];
  const sp = (n) => speakerOf(n, SELF, speakerDir({ zones: zs, sessions: [] }, false), zs, false).short;
  assert.equal(sp("Infra-x"), "通用");
  assert.equal(sp("Web-x"), "前端组");
  assert.equal(sp("Ops-x"), "Ops");
  assert.equal(sp("没前缀"), "其他");
});

test("unmatched names: look up a unique session by short name, then infer the zone from the prefix, else unzoned (badge says other)", () => {
  let s = who("bot"); // legacy short name -> Infra-bot
  assert.deepEqual([s.name, s.zone, s.role], ["Infra-bot", "Infra", "cross"]);
  s = who("Lab-gone-away");
  assert.deepEqual([s.zone, s.role, s.short, s.pet, s.plate], ["Lab", "cross", "个人", null, "gone-away"]);
  s = who("top");
  assert.deepEqual([s.zone, s.zoneName, s.short, s.color, s.role, s.pet], [null, "未分区", "其他", "#8A8F98", "cross", null]);
  s = who("Web-API-newcomer");
  assert.deepEqual([s.zone, s.role], ["Web", "mate"]);
  s = who("Infra-AI-Router"); // off duty but a lead: still gets the gold frame
  assert.deepEqual([s.role, s.lead], ["crossLead", true]);
});

test("off-duty sessions are also resolved: zone and pet seed use sid; non-code zones are inferred by name", () => {
  let s = who("Docs-Tools");
  assert.deepEqual([s.zone, s.role, s.pet], ["Docs", "cross", { pet: null, id: "off1" }]);
  s = who("示例卡");
  assert.deepEqual([s.zone, s.short, s.pet], [null, "其他", { pet: null, id: "off2" }]);
});

test("when self is the lead: gold frame without a badge; when self is unzoned, other unzoned sessions are not cross-team", () => {
  const self = { name: "Web-UI-refactor", zone: "Web", pet: "pet-fe", id: "s2" };
  const s = who("Web-UI-refactor", SNAP, false, self);
  assert.deepEqual([s.role, s.lead, s.cross], ["self", true, false]);
  const lone = { name: "top", zone: null, id: "x" };
  assert.equal(who("示例卡", SNAP, false, lone).cross, false);
  assert.equal(who("Web-Landing", SNAP, false, lone).cross, true);
});

test("guest view: the roster only gives name, zone and lead flag; other sessions have no pet, own pet is kept", () => {
  const g = {
    zones: ZONES.map(({ lead, ...z }) => z), // guest zones have no lead
    sessions: [{ id: "s1", name: "Web-guest-demo", plate: "guest-demo", zone: "Web", pet: "whaley" }],
    roster: [
      { name: "Web-guest-demo", zone: "Web", lead: false },
      { name: "Web-UI-refactor", zone: "Web", lead: true },
      { name: "Docs-Wiki-app", zone: "Docs", lead: true },
      { name: "Docs-Tools", zone: "Docs", lead: false },
      { name: "示例卡", zone: null, lead: false },
    ],
  };
  let s = who("Web-guest-demo", g, true);
  assert.deepEqual([s.role, s.pet], ["self", { pet: "whaley", id: "s1" }]);
  s = who("Web-UI-refactor", g, true);
  assert.deepEqual([s.role, s.pet], ["lead", null]);
  s = who("Docs-Wiki-app", g, true);
  assert.deepEqual([s.role, s.pet, s.color], ["crossLead", null, "#E0A040"]);
  s = who("Docs-Tools", g, true);
  assert.deepEqual([s.role, s.pet], ["cross", null]);
  s = who("示例卡", g, true);
  assert.deepEqual([s.zone, s.short], [null, "其他"]);
  s = who("top", g, true);
  assert.deepEqual([s.role, s.pet], ["cross", null]);
});

test("guest view (roster has bound sessions only): names outside the roster do not throw; falls back to a zone-colored initial avatar", () => {
  const g = {
    zones: ZONES.map(({ lead, ...z }) => z),
    sessions: [{ id: "s1", name: "Web-guest-demo", plate: "guest-demo", zone: "Web", pet: "whaley" }],
    roster: [{ name: "Web-guest-demo", zone: "Web", lead: false }],
  };
  let s = who("Web-guest-demo", g, true);
  assert.deepEqual([s.role, s.pet], ["self", { pet: "whaley", id: "s1" }]);
  s = who("Web-UI-refactor", g, true);
  assert.equal(s.pet, null);
  assert.equal(s.zone, "Web");
  s = who("示例卡", g, true);
  assert.equal(s.pet, null);
  s = who("totally-unknown", g, true);
  assert.equal(s.pet, null);
  assert.doesNotThrow(() => speakerDir({ zones: g.zones, sessions: g.sessions }, true)); // backend without a roster field
});

test("initial avatar, strip the [Guest] prefix", () => {
  assert.equal(speakerInitials("UI-refactor"), "UI");
  assert.equal(speakerInitials("bot"), "BO");
  assert.equal(speakerInitials("示例卡"), "示");
  assert.equal(speakerInitials(""), "?");
  assert.equal(stripGuestTag("[Guest] 你好"), "你好");
  assert.equal(stripGuestTag("你好 [Guest] "), "你好 [Guest] ");
});

test("guest message with images: [Image #N] before [Guest] is still a guest; stripping keeps the image marker", () => {
  assert.equal(speakerKey({ role: "user", text: "[Image #1] [Guest] 你好" }), "guest");
  assert.equal(speakerKey({ role: "user", text: "[Image #1] [Image #2] [Guest] 你好" }), "guest");
  assert.equal(speakerKey({ role: "user", text: "[Image #1] 你好" }), "admin");
  assert.equal(stripGuestTag("[Image #1] [Guest] 这个是到货"), "[Image #1] 这个是到货");
  assert.equal(stripGuestTag("[Image #1] [Image #2] [Guest] x"), "[Image #1] [Image #2] x");
  assert.equal(stripGuestTag("[Image #1] 你好"), "[Image #1] 你好");
});

test("speaker key: humans split into guest and admin; agents into self, other sessions, subagents", () => {
  assert.equal(speakerKey({ role: "user", text: "[Guest] 003 补一句" }), "guest");
  assert.equal(speakerKey({ role: "user", text: "[Guest]没空格" }), "admin");
  assert.equal(speakerKey({ role: "user", text: "好" }), "admin");
  assert.equal(speakerKey({ role: "assistant", text: "x" }), "self");
  assert.equal(speakerKey({ role: "tool", text: "Bash" }), "self");
  assert.equal(speakerKey({ role: "peer", from: "Web-UI-refactor" }), "peer:Web-UI-refactor");
  assert.equal(speakerKey({ role: "agent", agentName: "核对" }), "agent:核对");
  assert.equal(speakerKey({ role: "ask" }), null);
});

const T = (m) => "2026-10-21T06:" + String(m).padStart(2, "0") + ":00Z";
const shape = (plan) => plan.map((b) => b.t !== "group" ? b.t + (b.i != null ? ":" + b.i : "")
  : b.who + "[" + b.parts.map((p) => p.t === "msg" ? p.i : "T" + p.idx.join(",") + (p.hand && p.hand.length ? "+h" + p.hand.join(",") : "") + (p.open ? "!" : "") + (p.trail ? "~" : "")).join(" ") + "]");

test("grouping: consecutive messages from one speaker merge; a gap over 5 minutes breaks the group; me vs. others by account", () => {
  const items = [
    { role: "user", text: "[Guest] 需求", ts: T(0) },
    { role: "assistant", text: "收到", ts: T(1) },
    { role: "assistant", text: "再说一句", ts: T(1) },
    { role: "peer", from: "Web-UI-refactor", text: "改好了", ts: T(2) },
    { role: "peer", from: "Web-UI-refactor", text: "还有", ts: T(2) },
    { role: "peer", from: "Infra-bot", text: "补充", ts: T(3) },
    { role: "user", text: "出一版", ts: T(4) },
    { role: "assistant", text: "好", ts: T(30) },
  ];
  assert.deepEqual(shape(chatPlan(items, {})),
    ["time", "guest[0]", "self[1 2]", "peer[3 4]", "peer[5]", "me[6]", "time", "self[7]"]);
  const g = chatPlan(items, {});
  assert.equal(g[3].from, "Web-UI-refactor");
  // guest view: own messages are "me", admin messages are admin
  assert.deepEqual(shape(chatPlan(items, { guest: true })).filter((x) => /^(me|admin|guest)/.test(x)), ["me[0]", "admin[6]"]);
});

test("task notices are hidden; subagent reports attach to the tool tag that spawned them without breaking the group", () => {
  const items = [
    { role: "assistant", text: "派两个", ts: T(0) },
    { role: "tool", text: "Agent alice", toolUseId: "t1", ts: T(0), bg: true },
    { role: "tool", text: "Agent bob", toolUseId: "t2", ts: T(0), bg: true },
    { role: "assistant", text: "等它们", ts: T(1) },
    { role: "tool", text: "Bash x", toolUseId: "t3", ts: T(1) },
    { role: "agent", agentName: "bob", text: "bob done", forTool: "t2", ts: T(2) },
    { role: "agent", notice: true, forTool: "t2", task: "completed", text: 'Agent "bob" finished', ts: T(2) },
    { role: "agent", agentName: "", text: "没对上", forTool: "", ts: T(2) },
    { role: "assistant", text: "汇总", ts: T(3) },
  ];
  // tools move below the reply; report 5 goes into t2's tag (T1,2), the unmatched 7 goes into the nearest tag (T4); notice 6 does not appear
  assert.deepEqual(shape(chatPlan(items, {})), ["time", "self[0 3 T1,2+h5 8 T4+h7]"]);
});

test("a report with no preceding tool tag starts its own empty tag", () => {
  const items = [
    { role: "user", text: "在吗", ts: T(0) },
    { role: "agent", agentName: "alice", text: "alice done", forTool: "tX", ts: T(1) },
    { role: "assistant", text: "收到", ts: T(1) },
  ];
  assert.deepEqual(shape(chatPlan(items, {})), ["time", "me[0]", "self[2 T+h1]"]); // same relocation below the reply
});

test("only task notices: hidden entries do not trigger a time divider", () => {
  const items = [
    { role: "assistant", text: "a", ts: T(0) },
    { role: "agent", notice: true, forTool: "t", task: "completed", text: "x", ts: T(20) },
    { role: "assistant", text: "b", ts: T(2) },
  ];
  assert.deepEqual(shape(chatPlan(items, {})), ["time", "self[0 2]"]);
  assert.equal(isNotice(items[1]), true);
  assert.equal(isHandback(items[1]), false);
  assert.equal(isHandback({ role: "agent", text: "r" }), true);
});

test("tool mark: all done without error shows a check, any error shows a cross, unfinished shows no mark", () => {
  const it = (o) => Object.assign({ role: "tool", text: "Bash" }, o);
  let items = [it({ toolUseId: "a" }), it({ toolUseId: "b" })];
  assert.equal(toolMark([0, 1], items), "ok");
  items = [it({ toolUseId: "a" }), it({ toolUseId: "b", isError: true })];
  assert.equal(toolMark([0, 1], items), "err");
  items = [it({ toolUseId: "a", pending: true }), it({ toolUseId: "b" })];
  assert.equal(toolMark([0, 1], items), null);
  // error takes precedence over unfinished
  items = [it({ toolUseId: "a", pending: true }), it({ toolUseId: "b", isError: true })];
  assert.equal(toolMark([0, 1], items), "err");
  assert.equal(toolMark([], items), null);
});

test("tool mark: background launches (subagent / background command) follow the task notices", () => {
  const ag = { role: "tool", text: "Agent alice", toolUseId: "t1", bg: true };
  const n = (task) => ({ role: "agent", notice: true, forTool: "t1", task, text: "x" });
  assert.equal(toolMark([0], [ag]), null);                        // no notice yet
  assert.equal(toolMark([0], [ag, n("running")]), null);
  assert.equal(toolMark([0], [ag, n("completed")]), "ok");
  assert.equal(toolMark([0], [ag, n("failed")]), "err");
  assert.equal(toolMark([0], [ag, n("killed")]), "err");
  assert.equal(toolMark([0], [ag, n("stopped")]), "ok");          // deliberately stopped is not an error
  assert.equal(toolMark([0], [ag, n("failed"), n("completed")]), "ok"); // multiple notices for one task: the latest wins
  assert.deepEqual(Array.from(taskStates([ag, n("completed")])), [["t1", "completed"]]);
  // synchronous Agent (no bg): a result means done
  assert.equal(toolMark([0], [{ role: "tool", text: "Agent", toolUseId: "t9" }]), "ok");
});

test("tool mark: the task from the server index wins; a background task with no notice counts as done after a full later turn", () => {
  // Setup: a tool group has two background Bash calls whose completion notices exist only in the queue records;
  // the server writes the state onto the tool via the index (it.task); all other tools have results
  const t = (id, o) => Object.assign({ role: "tool", text: "Bash x", toolUseId: id }, o);
  let items = [t("a"), t("b", { bg: true, task: "failed" }), t("c"), t("d", { bg: true, task: "completed" }),
    { role: "tool", text: "ToolSearch", toolUseId: "e" }, { role: "assistant", text: "好了" }];
  assert.equal(toolMark([0, 1, 2, 3, 4], items), "err"); // the first relay did fail
  items[1].task = "completed";
  assert.equal(toolMark([0, 1, 2, 3, 4], items), "ok");
  // this page's notice says running, the index says completed: the index wins
  const n = { role: "agent", notice: true, forTool: "d", task: "running", text: "x" };
  assert.equal(toolMark([0, 1, 2, 3, 4], items.concat([n])), "ok");
  // moved to background on timeout, never notified: still in the current turn -> unknown, no mark
  items = [t("a"), t("b", { bg: true }), { role: "assistant", text: "等等" }];
  assert.equal(toolMark([0, 1], items), null);
  assert.equal(turnAfter(items, 1), false);
  // the user spoke again and the Agent replied: counts as done
  items.push({ role: "user", text: "然后呢" }, { role: "tool", text: "Read", toolUseId: "z" }, { role: "assistant", text: "好" });
  assert.equal(turnAfter(items, 1), true);
  assert.equal(toolMark([0, 1], items), "ok");
  // only the user spoke, no Agent reply yet: not done
  assert.equal(toolMark([0, 1], items.slice(0, 4)), null);
  // a later turn must not turn an error into a check
  items[1].task = "killed";
  assert.equal(toolMark([0, 1], items), "err");
});

test("chat time dividers: day label plus clock time, always with the clock", () => {
  const at = (y, mo, d, h, mi) => new Date(y, mo - 1, d, h, mi).getTime() / 1000;
  const now = at(2026, 10, 21, 15, 0); // Wednesday
  assert.equal(chatStamp(at(2026, 10, 21, 11, 45), now), "上午11:45");
  assert.equal(chatStamp(at(2026, 10, 21, 0, 5), now), "凌晨12:05");
  assert.equal(chatStamp(at(2026, 10, 20, 22, 49), now), "昨天 晚上10:49");
  assert.equal(chatStamp(at(2026, 10, 19, 8, 3), now), "星期一 早上8:03");
  assert.equal(chatStamp(at(2026, 9, 4, 11, 45), now), "9月4日 上午11:45");
  assert.equal(chatStamp(at(2025, 9, 4, 13, 5), now), "2025年9月4日 下午1:05");
  assert.equal(chatStamp(0, now), "");
});

test("peer messages drop the leading \"from X:\" prefix", () => {
  assert.equal(stripFrom("来自 Web-UI-refactor：改好了"), "改好了");
  assert.equal(stripFrom("来自Web-UI-refactor: 改好了"), "改好了");
  assert.equal(stripFrom("Web-UI-refactor (lead)：改好了"), "Web-UI-refactor (lead)：改好了");
  assert.equal(stripFrom("说一下，来自 X：y"), "说一下，来自 X：y");
});

test("within the self group a run of tools moves below the reply that follows; trailing tools without a reply stay put", () => {
  const items = [
    { role: "peer", from: "Docs-Wiki-app", text: "问", ts: T(0) },
    { role: "tool", text: "Read a", ts: T(0) },
    { role: "tool", text: "Edit a", ts: T(0) },
    { role: "assistant", text: "答 1", ts: T(1) },
    { role: "tool", text: "Bash x", ts: T(1) },
    { role: "assistant", text: "答 2", ts: T(1) },
    { role: "assistant", text: "答 3", ts: T(1) },
    { role: "tool", text: "Bash y", ts: T(1) },
  ];
  assert.deepEqual(shape(chatPlan(items, {})), ["time", "peer[0]", "self[3 T1,2 5 T4 6 T7~]"]);
});

test("a tool run is not split by time dividers; ask / approval cards break the group, and an approval card follows its tool run expanded", () => {
  const items = [
    { role: "assistant", text: "开始", ts: T(0) },
    { role: "ask", text: "选哪个", ts: T(1) },
    { role: "assistant", text: "好", ts: T(2) },
    { role: "tool", text: "Bash a", ts: T(40) },
    { role: "tool", text: "Bash b", ts: T(40), pending: true },
    { role: "tool", text: "Bash c", ts: T(40), pending: true },
  ];
  assert.deepEqual(shape(chatPlan(items, { approveIdx: 4 })),
    ["time", "self[0]", "ask:1", "self[2 T3,4!]", "approve:4", "self[T5~]"]);
  // not awaiting approval: the trailing tool run is marked trail (expanded while waiting)
  assert.deepEqual(shape(chatPlan(items, {})), ["time", "self[0]", "ask:1", "self[2 T3,4,5~]"]);
});

test("empty chat and unknown roles produce no group", () => {
  assert.deepEqual(chatPlan([], {}), []);
  assert.deepEqual(chatPlan([{ role: "weird", text: "x" }], {}), []);
});

test("answered: the answer splits into option tags and free text; multi-select splits on \", \" but only where it matches options", async () => {
  const { answerParts, answeredRows } = await import("../logic.js");
  assert.deepEqual(answerParts("alice", ["alice", "bob"], false), [{ t: "opt", text: "alice" }]);
  assert.deepEqual(answerParts("my own words", ["alice", "bob"], false), [{ t: "txt", text: "my own words" }]);
  assert.deepEqual(answerParts("Orca 占用（推荐）, Mac 健康（推荐）", ["Orca 占用（推荐）", "Mac 健康（推荐）", "别的"], true),
    [{ t: "opt", text: "Orca 占用（推荐）" }, { t: "opt", text: "Mac 健康（推荐）" }]);
  // free text goes last; commas inside it are not split
  assert.deepEqual(answerParts("A, B, 还要, 再想想", ["A", "B"], true),
    [{ t: "opt", text: "A" }, { t: "opt", text: "B" }, { t: "txt", text: "还要, 再想想" }]);
  // an option itself contains ", ": take the longest match
  assert.deepEqual(answerParts("x, y, z", ["x", "x, y", "z"], true), [{ t: "opt", text: "x, y" }, { t: "opt", text: "z" }]);
  assert.deepEqual(answerParts("", ["A"], true), []);
  const qs = [{ question: "二", options: ["B"], multiSelect: false }, { question: "一", options: ["A", "C"], multiSelect: true }];
  assert.deepEqual(answeredRows(qs, { "一": "A, C", "二": "B", "三": "多出来的" }).map((r) => [r.q, r.parts.map((p) => p.t + ":" + p.text).join("/")]),
    [["二", "opt:B"], ["一", "opt:A/opt:C"], ["三", "txt:多出来的"]]);
  assert.deepEqual(answeredRows(qs, null), []);
});

test("name-row tags: other sessions always get a zone badge (short name + speaker zone color), teammates included; self gets none; leads keep a star", () => {
  const mate = whoTags(who("Web-Landing"), "peer");           // teammate
  assert.deepEqual(mate, { star: false, zone: { short: "WEB", color: "#40B0A0" } });
  const lead = whoTags(who("Web-UI-refactor"), "peer");          // team lead
  assert.deepEqual(lead, { star: true, zone: { short: "WEB", color: "#40B0A0" } });
  const cross = whoTags(who("Infra-bot"), "peer");           // cross-team
  assert.deepEqual(cross, { star: false, zone: { short: "通用", color: "#5080D0" } });
  const xl = whoTags(who("Docs-Wiki-app"), "peer");       // other team's lead
  assert.deepEqual(xl, { star: true, zone: { short: "Docs", color: "#E0A040" } });
  const lost = whoTags(who("没前缀的会话"), "peer");         // unzoned still has a short name and color
  assert.deepEqual(lost.zone, { short: "其他", color: "#8A8F98" });
  assert.deepEqual(whoTags(who("Web-guest-demo"), "self"), { star: false, zone: null }); // self replies get no badge
  assert.deepEqual(whoTags(who("Web-UI-refactor", SNAP, false, { ...SELF, name: "Web-UI-refactor", id: "s2" }), "self"), { star: true, zone: null }); // self is the lead: star kept, no badge
});
