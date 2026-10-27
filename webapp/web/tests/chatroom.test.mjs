import test from "node:test";
import assert from "node:assert/strict";
import { sortChat, chatBadge, chatRow, chatTime, macLine, chatSearch, hlParts, zoneChips, msgModel, contactsModel, chatTab, CHAT_TABS } from "../logic.js";

const zones = [
  { code: "Web", name: "WEB", color: "#40B0A0", order: 2, lead: "Web-lead" },
  { code: "Docs", name: "Docs", color: "#E0A040", order: 1, lead: "Docs-lead" },
];
const S = (id, o = {}) => ({ id, name: "Docs-" + id, plate: id, zone: "Docs", status: "idle", since: 100, unread: false, pinned: false, rest: false, ...o });
const ids = (l) => l.map((s) => s.id);

test("sortChat: waiting (oldest first) > pinned > unread > busy > rest by time desc", () => {
  const out = sortChat([
    S("idle-new", { since: 900 }),
    S("busy", { status: "busy", since: 500 }),
    S("unread-old", { unread: true, since: 50 }),
    S("unread-new", { unread: true, since: 400 }),
    S("w-new", { status: "waiting", since: 300 }),
    S("pin-old", { pinned: true, since: 1 }),
    S("pin-new", { pinned: true, since: 2 }),
    S("w-old", { status: "waiting", since: 10 }),
    S("quiet", { originTag: { kind: "peer", peer: "X" }, since: 950 }),
  ]);
  assert.deepEqual(ids(out), ["w-old", "w-new", "pin-new", "pin-old", "unread-new", "unread-old", "busy", "quiet", "idle-new"]);
});

test("sortChat: busy sessions newest-started first, always above idle ones", () => {
  const out = sortChat([S("idle", { since: 999 }), S("b-old", { status: "busy", since: 10 }), S("b-new", { status: "busy", since: 20 })]);
  assert.deepEqual(ids(out), ["b-new", "b-old", "idle"]);
});

test("sortChat: waiting beats pinned, pinned+unread counts as pinned", () => {
  const out = sortChat([S("pu", { pinned: true, unread: true, since: 5 }), S("pw", { pinned: true, status: "waiting", since: 9 }), S("u", { unread: true, since: 99 })]);
  assert.deepEqual(ids(out), ["pw", "pu", "u"]);
});

test("sortChat does not mutate input", () => {
  const list = [S("a", { since: 1 }), S("b", { since: 2 })];
  sortChat(list);
  assert.deepEqual(ids(list), ["a", "b"]);
});

test("chatBadge = waiting + unread, rest excluded", () => {
  const snap = { sessions: [S("a", { status: "waiting" }), S("b", { unread: true }), S("c", { status: "busy" }), S("d", { unread: true, rest: true }), S("e")] };
  assert.equal(chatBadge(snap), 2);
  assert.equal(chatBadge({}), 0);
});

test("chatTab validates stored value, default msg", () => {
  assert.deepEqual(CHAT_TABS, ["msg", "contacts", "zones", "me"]);
  assert.equal(chatTab(null), "msg");
  assert.equal(chatTab("bogus"), "msg");
  assert.equal(chatTab("board"), "zones"); // the legacy lanes tab is not remembered as the default tab
  assert.equal(chatTab("zones"), "zones");
  assert.equal(chatTab("me"), "me");
});

test("chatTime: chat-style format (today: period h:mm / yesterday: period h:mm / weekday / month-day / year-month-day)", () => {
  const now = new Date(2026, 9, 20, 23, 0).getTime() / 1000; // Tuesday
  const at = (...a) => new Date(...a).getTime() / 1000;
  assert.equal(chatTime(0, now), "");
  assert.equal(chatTime(now - 30, now), "晚上 10:59");
  assert.equal(chatTime(at(2026, 9, 20, 0, 0), now), "凌晨 12:00");
  assert.equal(chatTime(at(2026, 9, 20, 5, 53), now), "凌晨 5:53");
  assert.equal(chatTime(at(2026, 9, 20, 6, 5), now), "早上 6:05");
  assert.equal(chatTime(at(2026, 9, 20, 8, 59), now), "早上 8:59");
  assert.equal(chatTime(at(2026, 9, 20, 9, 0), now), "上午 9:00");
  assert.equal(chatTime(at(2026, 9, 20, 11, 30), now), "上午 11:30");
  assert.equal(chatTime(at(2026, 9, 20, 12, 15), now), "中午 12:15");
  assert.equal(chatTime(at(2026, 9, 20, 13, 42), now), "下午 1:42");
  assert.equal(chatTime(at(2026, 9, 20, 17, 59), now), "下午 5:59");
  assert.equal(chatTime(at(2026, 9, 20, 18, 0), now), "晚上 6:00");
  assert.equal(chatTime(at(2026, 9, 20, 22, 49), now), "晚上 10:49");
  assert.equal(chatTime(at(2026, 9, 19, 22, 49), now), "昨天 晚上10:49");
  assert.equal(chatTime(at(2026, 9, 19, 0, 1), now), "昨天 凌晨12:01");
  assert.equal(chatTime(at(2026, 9, 18, 12, 0), now), "星期日");
  assert.equal(chatTime(at(2026, 9, 16, 12, 0), now), "星期五");
  assert.equal(chatTime(at(2026, 9, 14, 12, 0), now), "星期三");
  assert.equal(chatTime(at(2026, 9, 13, 12, 0), now), "10月13日"); // 7 days ago -> date
  assert.equal(chatTime(at(2026, 0, 2, 12, 0), now), "1月2日");
  assert.equal(chatTime(at(2025, 9, 12, 12, 0), now), "2025年10月12日");
  assert.equal(chatTime(now + 60, now), "晚上 11:01"); // clock slightly fast: treated as today
});

test("macLine: status line at the top of the messages page", () => {
  const on = { orca: { running: true } };
  assert.deepEqual(macLine(on, { at: "09:05" }), { text: "Mac · Orca 在线", short: "Orca ✓", off: false, dot: "on" });
  assert.deepEqual(macLine({}, { at: "09:05" }), { text: "Mac · Orca 在线", short: "Orca ✓", off: false, dot: "on" }); // old snapshots lack this field: treat as online
  assert.deepEqual(macLine({ orca: { running: false } }, { at: "09:05" }), { text: "Mac · Orca 未运行", short: "Orca 未运行", off: false, dot: "warn" });
  assert.deepEqual(macLine(on, { stale: true, at: "09:05" }), { text: "Mac 已断开，数据截至 09:05", short: "已断开 09:05", off: true, dot: "off" });
  assert.deepEqual(macLine({ orca: { running: false } }, { offline: true, at: "23:59" }), { text: "Mac 已断开，数据截至 23:59", short: "已断开 23:59", off: true, dot: "off" });
});

test("chatRow: waiting preview, lead, zone", () => {
  const r = chatRow(S("lead", { name: "Docs-lead", status: "waiting", summary: "要不要映射？" }), zones, 1000);
  assert.equal(r.kind, "w");
  assert.equal(r.lead, true);
  assert.equal(r.zoneName, "Docs");
  assert.equal(r.zoneColor, "#E0A040");
  assert.deepEqual(r.tag, { cls: "w", text: "[在等你]" });
  assert.equal(r.text, "要不要映射？");
  assert.equal(r.badge, "wait");
  assert.equal(r.quiet, false);
});

test("chatRow: waiting without summary falls back", () => {
  const r = chatRow(S("a", { status: "waiting", summary: "", waitingFor: "" }), zones, 1000);
  assert.equal(r.text, "需要你回答或批准");
});

test("chatRow: unread red dot, busy green, quiet uses originTag", () => {
  assert.equal(chatRow(S("a", { unread: true }), zones, 0).badge, "dot");
  assert.equal(chatRow(S("a", { unread: true }), zones, 0).kind, "u");
  const b = chatRow(S("a", { status: "busy", summary: "干活" }), zones, 0);
  assert.equal(b.badge, "live");
  assert.deepEqual(b.tag, { cls: "g", text: "正在干活" });
  const q = chatRow(S("a", { originTag: { kind: "peer", peer: "Web-QS" }, summary: "对上了" }), zones, 0);
  assert.equal(q.quiet, true);
  assert.equal(q.badge, "");
  assert.deepEqual(q.tag, { cls: "p", text: "↔ 与 Web-QS 往来：" });
  assert.equal(q.text, "对上了");
});

test("chatRow: plate falls back to name minus zone prefix; unknown zone is the unassigned label", () => {
  const r = chatRow({ id: "x", name: "Lab-temp", zone: "Lab", status: "idle", since: 1 }, zones, 10);
  assert.equal(r.plate, "temp");
  assert.equal(r.zoneName, "未分区");
  const r2 = chatRow({ id: "y", name: "Web-UI-refactor", zone: "Web", status: "idle", since: 1 }, zones, 10);
  assert.equal(r2.plate, "UI-refactor");
});

test("chatRow: rest preview mentions rest", () => {
  const r = chatRow(S("a", { rest: true, since: 0, summary: "完" }), zones, 7 * 3600);
  assert.equal(r.text, "休息 7 小时：完");
  assert.equal(r.rest, true);
});

test("zoneChips: the \"all\" chip first, zone order, hot when waiting/unread", () => {
  const snap = { zones, sessions: [S("a", { status: "waiting" }), S("b", { zone: "Web" }), S("c", { zone: "Nope", unread: true })] };
  const c = zoneChips(snap);
  assert.deepEqual(c.map((x) => [x.key, x.name, x.count, x.hot]), [["all", "全部", 3, true], ["Docs", "Docs", 1, true], ["Web", "WEB", 1, false], ["_", "未分区", 1, true]]);
});

test("msgModel: filters by zone, splits rest (newest first)", () => {
  const snap = { zones, sessions: [
    S("a", { status: "waiting" }), S("r1", { rest: true, since: 5 }), S("r2", { rest: true, since: 9 }),
    S("e", { zone: "Web", since: 3 }), S("n", { zone: "Nope", since: 50 }),
  ] };
  const all = msgModel(snap, "all");
  assert.deepEqual(ids(all.active), ["a", "n", "e"]);
  assert.deepEqual(ids(all.rest), ["r2", "r1"]);
  assert.deepEqual(ids(msgModel(snap, "Web").active), ["e"]);
  assert.deepEqual(ids(msgModel(snap, "_").active), ["n"]);
  assert.deepEqual(ids(msgModel(snap, "Docs").rest), ["r2", "r1"]);
});

test("contactsModel: zone sections, lead first then name, offduty sorted, status", () => {
  const snap = {
    zones,
    sessions: [S("bob", { name: "Docs-bob", unread: true }), S("lead", { name: "Docs-lead", status: "busy" }), S("alice", { name: "Docs-alice", rest: true }), S("w", { name: "Web-w", zone: "Web", status: "waiting" })],
    offduty: [{ name: "Docs-older", sid: "o1", zone: "Docs", offAt: 5 }, { name: "Docs-newer", sid: "o2", zone: "Docs", offAt: 9 }, { name: "X-orphan", sid: "o3", zone: "X", offAt: 1 }],
  };
  const m = contactsModel(snap);
  assert.deepEqual(m.counts, { waiting: 1, pinned: 0, off: 3 });
  assert.deepEqual(m.sections.map((x) => x.key), ["Docs", "Web", "_"]);
  const a = m.sections[0];
  assert.equal(a.members[0].s.id, "lead");
  assert.equal(a.members[0].lead, true);
  assert.deepEqual(a.members.map((x) => x.status), [{ cls: "g", text: "干活中" }, { cls: "d", text: "休息" }, { cls: "u", text: "回复你" }]);
  assert.deepEqual(a.off.map((o) => o.sid), ["o2", "o1"]);
  assert.equal(a.off[1].plate, "older");
  assert.equal(m.sections[1].members[0].status.text, "在等你");
  assert.equal(m.sections[2].members.length, 0);
  assert.equal(m.sections[2].off[0].plate, "orphan");
});

test("chatSearch: names, zone, peer, then summary, then offduty", () => {
  const snap = {
    zones,
    sessions: [
      S("Router", { name: "Docs-Router" }),
      S("CCTV", { peer: "Infra-AI-Router", summary: "x" }),
      S("HR", { summary: "转到 router 路由" }),
      S("API", { zone: "Web", summary: "nothing" }),
    ],
    offduty: [{ name: "Web-router-old", sid: "o1", zone: "Web", offAt: 1 }, { name: "Docs-other", sid: "o2", zone: "Docs" }],
  };
  const r = chatSearch(snap, "  Router ");
  assert.deepEqual(ids(r.byName), ["Router", "CCTV"]);
  assert.deepEqual(ids(r.bySummary), ["HR"]);
  assert.deepEqual(r.off.map((o) => o.sid), ["o1"]);
  const z = chatSearch(snap, "web");
  assert.deepEqual(ids(z.byName), ["API"]);
  assert.deepEqual(z.off.map((o) => o.sid), ["o1"]);
  const e = chatSearch(snap, "   ");
  assert.deepEqual([e.byName, e.bySummary, e.off], [[], [], []]);
});

test("chatSearch: does not search transcript-ish fields", () => {
  const snap = { zones, sessions: [S("a", { project: "/Users/demo/needle", cwd: "/needle" })] };
  assert.equal(chatSearch(snap, "needle").byName.length, 0);
});

test("hlParts splits on first case-insensitive hit", () => {
  assert.deepEqual(hlParts("AI-Router", "router"), [{ t: "AI-", hit: false }, { t: "Router", hit: true }]);
  assert.deepEqual(hlParts("abc", "x"), [{ t: "abc", hit: false }]);
  assert.deepEqual(hlParts("abc", ""), [{ t: "abc", hit: false }]);
  assert.deepEqual(hlParts("abc", "abc"), [{ t: "abc", hit: true }]);
});

// ---------- busy effects / foreground banner ----------
import { busyFx, walkFit, FX_TRACK_MIN, bannerStep, newBannerState, bannerStill, bannerText, BANNER_WAIT_MS, BANNER_DONE_MS } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

// The effect style comes from the snapshot's zones[].fx (the helper reads it from workzones.json / a private local zone-style.json); the code does not know zone codes
const ZS = [{ code: "Docs", fx: "marquee" }, { code: "Web", fx: "circuit" }, { code: "Infra", fx: "halo" }, { code: "Lab", fx: "orbit" }, { code: "Plain" }, { code: "Odd", fx: "fireworks" }];
const B = (o = {}) => ({ id: "s1", status: "busy", zone: null, ...o });
const WALK = { walk: true }; // this pet's caps in the pet manifest

test("busyFx: zone picks the effect; not busy → null", () => {
  assert.equal(busyFx(B({ zone: "Docs" }), "pet-walker", ZS).kind, "marquee");
  assert.equal(busyFx(B({ zone: "Web" }), "pet-walker", ZS).kind, "circuit");
  assert.equal(busyFx(B({ zone: "Infra" }), null, ZS).kind, "halo");
  assert.equal(busyFx(B({ zone: "Lab" }), "pet-plain", ZS).kind, "orbit");
  assert.equal(busyFx(B({ zone: "Lab", status: "idle" }), "pet-plain", ZS), null);
  assert.equal(busyFx(B({ zone: "Lab", status: "waiting" }), "pet-plain", ZS), null);
});

test("busyFx: unzoned (no zone, or code missing from zone table) walks out", () => {
  assert.equal(busyFx(B(), "pet-walker", ZS).kind, "walk");
  assert.equal(busyFx(B({ zone: "Docs" }), "pet-walker", []).kind, "walk"); // not in the zone table -> unassigned
  assert.equal(busyFx(B({ zone: "Gone" }), "pet-walker", ZS).kind, "walk");
  assert.equal(busyFx(B(), null, ZS), null); // pet manifest not loaded yet: no pet out of the frame
  assert.deepEqual(busyFx(B(), null, ZS, null, "none").actor, { type: "flame" }); // no pet installed: the flame stand-in appears
});

test("busyFx: zone without fx (or unknown fx) falls back to the pet walk-out", () => {
  assert.equal(busyFx(B({ zone: "Plain" }), "pet-walker", ZS).kind, "walk");
  assert.equal(busyFx(B({ zone: "Odd" }), "pet-walker", ZS).kind, "walk");
  assert.equal(busyFx(B({ zone: "Plain" }), null, ZS), null);
});

test("busyFx: walkers get run/carry stably by session id; both modes occur", () => {
  const modes = new Set();
  for (let i = 0; i < 40; i++) {
    const s = B({ id: "sess-" + i });
    const a = busyFx(s, "pet-walker", ZS, WALK).mode;
    assert.equal(busyFx(s, "pet-walker", ZS, WALK).mode, a); // stable
    assert.ok(a === "run" || a === "carry");
    modes.add(a);
  }
  assert.deepEqual([...modes].sort(), ["carry", "run"]);
});

test("busyFx: capabilities come from the pet list caps; pets that can walk leave the frame on their own, all others (no caps / unsure / deskOwn / non-true) use the flame stand-in, there is no desk", () => {
  for (const caps of [undefined, null, { unsure: true }, { deskOwn: true }, { walk: "yes" }]) {
    const f = busyFx(B(), "pet-plain", ZS, caps);
    assert.equal(f.kind, "walk");
    assert.notEqual(f.mode, "desk");
    assert.deepEqual(f.actor, { type: "flame" });
  }
  assert.deepEqual(busyFx(B(), "pet-walker", ZS, WALK).actor, { type: "pet", name: "pet-walker" });
  assert.equal(busyFx(B({ zone: "Docs" }), "pet-walker", ZS, WALK).kind, "marquee"); // zone effect takes priority
});

test("walkFit: enough track keeps the mode, else stay in avatar (no desk fallback)", () => {
  assert.equal(walkFit("run", FX_TRACK_MIN.run), "run");
  assert.equal(walkFit("carry", 200), "carry");
  assert.equal(walkFit("run", 64), null);
  assert.equal(walkFit("carry", FX_TRACK_MIN.run - 1), null);
  assert.equal(walkFit("desk", 200), null);
  assert.equal(walkFit("run", 10), null);
});

const W = (id, o = {}) => ({ id, status: "idle", since: 100, unread: false, ...o });

test("bannerStep: first snapshot only records, never fires", () => {
  const r = bannerStep(newBannerState(), [W("a", { status: "waiting" }), W("b", { unread: true })], 0, null);
  assert.deepEqual(r.fire, []);
  const r2 = bannerStep(r.state, [W("a", { status: "waiting" }), W("b", { unread: true })], 60000, null);
  assert.deepEqual(r2.fire, []); // sessions present from the start are not announced
});

test("bannerStep: new waiting fires after 3s, new unread after 10s, once", () => {
  let st = bannerStep(newBannerState(), [W("a", { status: "busy" }), W("b", { status: "busy" })], 0, null).state;
  let r = bannerStep(st, [W("a", { status: "waiting", since: 200 }), W("b", { unread: true, since: 210 })], 1000, null);
  assert.deepEqual(r.fire, []);
  r = bannerStep(r.state, [W("a", { status: "waiting", since: 200 }), W("b", { unread: true, since: 210 })], 1000 + BANNER_WAIT_MS, null);
  assert.deepEqual(r.fire, [{ id: "a", kind: "wait" }]);
  r = bannerStep(r.state, [W("a", { status: "waiting", since: 200 }), W("b", { unread: true, since: 210 })], 1000 + BANNER_DONE_MS, null);
  assert.deepEqual(r.fire, [{ id: "b", kind: "done" }]);
  r = bannerStep(r.state, [W("a", { status: "waiting", since: 200 }), W("b", { unread: true, since: 210 })], 99000, null);
  assert.deepEqual(r.fire, []);
});

test("bannerStep: a flash shorter than the delay never fires; a new round fires again", () => {
  let st = bannerStep(newBannerState(), [W("a", { status: "busy" })], 0, null).state;
  let r = bannerStep(st, [W("a", { status: "waiting", since: 5 })], 1000, null);
  r = bannerStep(r.state, [W("a", { status: "busy" })], 2000, null);
  r = bannerStep(r.state, [W("a", { status: "busy" })], 9000, null);
  assert.deepEqual(r.fire, []);
  r = bannerStep(r.state, [W("a", { status: "waiting", since: 6 })], 10000, null);
  r = bannerStep(r.state, [W("a", { status: "waiting", since: 6 })], 13000, null);
  assert.deepEqual(r.fire, [{ id: "a", kind: "wait" }]);
});

test("bannerStep: the session being viewed is skipped and stays skipped after leaving", () => {
  let st = bannerStep(newBannerState(), [W("a", { status: "busy" })], 0, null).state;
  let r = bannerStep(st, [W("a", { status: "waiting", since: 5 })], 1000, "a");
  r = bannerStep(r.state, [W("a", { status: "waiting", since: 5 })], 9000, null);
  assert.deepEqual(r.fire, []);
});

test("bannerStep: peer/agent rounds never fire (server leaves unread false)", () => {
  let st = bannerStep(newBannerState(), [W("a", { status: "busy" })], 0, null).state;
  const r = bannerStep(st, [W("a", { since: 50, unread: false, origin: "peer" })], 60000, null);
  assert.deepEqual(r.fire, []);
});

test("bannerStill / bannerText", () => {
  assert.equal(bannerStill(W("a", { status: "waiting" }), "wait"), true);
  assert.equal(bannerStill(W("a"), "wait"), false);
  assert.equal(bannerStill(W("a", { unread: true }), "done"), true);
  assert.equal(bannerStill(null, "done"), false);
  // title is just the short name, body is [event] content; no tag when done
  assert.deepEqual(bannerText({ name: "Web-UI-refactor", zone: "Web", summary: "问你\n一件事", status: "waiting" }, "wait"), { title: "UI-refactor", body: "[在等你] 问你 一件事" });
  assert.deepEqual(bannerText({ name: "X", plate: "X", waitingFor: "批准 Bash" }, "wait").body, "[在等你] 批准 Bash");
  assert.deepEqual(bannerText({ name: "X", plate: "X" }, "done"), { title: "X", body: "干完了" });
});
