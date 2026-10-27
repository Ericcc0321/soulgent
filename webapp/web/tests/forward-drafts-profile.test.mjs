// Forward fills a draft, draft persistence and list preview, own avatar and nickname, roaming figure keeps walking
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const { chatRow } = L;
const src = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

// ---------- 1. drafts / forward ----------
test("draftsParse / draftsDump: round trip, drops empty values and bad data", () => {
  const m = L.draftsParse(JSON.stringify({ a: "你好", b: "", c: 3, d: "  " }));
  assert.ok(m instanceof Map);
  assert.deepEqual([...m.entries()], [["a", "你好"]]);
  assert.deepEqual(L.draftsParse("坏 json").size, 0);
  assert.deepEqual(L.draftsParse(null).size, 0);
  assert.deepEqual(L.draftsParse("[1,2]").size, 0);
  const back = L.draftsParse(L.draftsDump(new Map([["x", "草稿一"], ["y", ""]])));
  assert.deepEqual([...back.entries()], [["x", "草稿一"]]);
  const big = new Map();
  for (let i = 0; i < 150; i++) big.set("s" + i, "t" + i);
  assert.ok(L.draftsParse(L.draftsDump(big)).size <= 100); // keeps at most 100 sessions
  assert.ok(L.draftsDump(new Map([["z", "字".repeat(9000)]])).length < 9000); // a single entry is truncated
});

test("draftPreview: single line, first few characters", () => {
  assert.equal(L.draftPreview("  第一行\n第二行  "), "第一行 第二行");
  const p = L.draftPreview("长".repeat(80));
  assert.ok(p.length <= 41 && p.endsWith("…"));
  assert.equal(L.draftPreview(""), "");
});

test("draftMerge: appends on a new line to an existing draft, never overwrites", () => {
  assert.equal(L.draftMerge("", "[转发自 A] x"), "[转发自 A] x");
  assert.equal(L.draftMerge(undefined, "x"), "x");
  assert.equal(L.draftMerge("我打的字", "[转发自 A] x"), "我打的字\n[转发自 A] x");
  assert.equal(L.draftMerge("   ", "x"), "x");
});

test("chatRow: with a draft the preview shows a red [draft] tag plus the first characters; waiting takes priority; no draft leaves the row plain", () => {
  const zones = [{ code: "Infra", name: "Infra", color: "#3b82f6", order: 1 }];
  const s = { id: "s1", name: "Infra-board", zone: "Infra", status: "idle", summary: "上次的摘要", since: 0 };
  const r0 = chatRow(s, zones, 100);
  assert.equal(r0.text, "上次的摘要");
  const r = chatRow(s, zones, 100, "帮我看看\n这段");
  assert.deepEqual(r.tag, { cls: "dr", text: "[草稿]" });
  assert.equal(r.text, "帮我看看 这段");
  const busy = chatRow(Object.assign({}, s, { status: "busy" }), zones, 100, "草稿");
  assert.equal(busy.tag.cls, "dr"); // draft is shown while busy too
  const w = chatRow(Object.assign({}, s, { status: "waiting" }), zones, 100, "草稿");
  assert.equal(w.tag.cls, "w"); // waiting outranks the draft
  assert.equal(chatRow(s, zones, 100, "   ").text, "上次的摘要");
});

test("forwardTargets: lists only other claude sessions, filters by name/zone, carries zone name and color", () => {
  const zones = [{ code: "Web", name: "前端", color: "#f59e0b", order: 1 }];
  const ss = [
    { id: "a", kind: "claude", name: "Web-API-report", plate: "API-report", zone: "Web" },
    { id: "b", kind: "claude", name: "Lab-HA-lights", plate: "HA-lights", zone: "Lab" },
    { id: "c", kind: "shell", name: "zsh" },
    { id: "cur", kind: "claude", name: "Infra-board", zone: "Infra" },
    { id: "d", kind: "claude", name: "" },
  ];
  const all = L.forwardTargets(ss, "cur", "", zones);
  assert.deepEqual(all.map((x) => x.id), ["a", "b"]);
  assert.equal(all[0].zoneName, "前端");
  assert.equal(all[0].zoneColor, "#f59e0b");
  assert.equal(all[0].plate, "API-report");
  assert.deepEqual(L.forwardTargets(ss, "cur", "lights", zones).map((x) => x.id), ["b"]);
  assert.deepEqual(L.forwardTargets(ss, "cur", "前端", zones).map((x) => x.id), ["a"]);
  assert.deepEqual(L.forwardTargets(ss, "cur", "api", zones).map((x) => x.id), ["a"]);
});

test("app.js: forward does not send directly; it writes a draft and jumps to the target session; drafts live in localStorage zbs.drafts", () => {
  const a = src("app.js");
  assert.ok(!/function doForward\b/.test(a), "doForward should be removed");
  const fw = a.slice(a.indexOf("function openForward"), a.indexOf("function openForward") + 3000);
  assert.ok(!/runRequest\(/.test(fw), "forward must not call the send API");
  assert.match(fw, /st\.drafts\.set\(/);
  assert.match(fw, /openDetail\(/);
  assert.match(a, /"zbs\.drafts"/);
  assert.match(a, /function fillMsgLi[\s\S]{0,400}chatRow\([\s\S]{0,120}st\.drafts\.get\(s\.id\)/);
  assert.match(src("logic.js"), /class DraftMap extends Map/); // lives in logic.js (per-account)
});

// ---------- 2. own avatar and nickname ----------
test("profileView: the default name has no avatar; an avatar carries a version to bust the cache", () => {
  assert.deepEqual(L.profileView(null), { name: "我", isDefault: true, url: "" });
  assert.deepEqual(L.profileView({ name: "", avatar: false, v: 0 }), { name: "我", isDefault: true, url: "" });
  assert.deepEqual(L.profileView({ name: "Guest A", avatar: true, v: 123 }), { name: "Guest A", isDefault: false, url: "/api/avatar?v=123" });
});

test("avatarCrop: center-crops a square, outputs 160", () => {
  assert.deepEqual(L.avatarCrop(400, 200), { sx: 100, sy: 0, sw: 200, sh: 200, size: 160 });
  assert.deepEqual(L.avatarCrop(300, 900), { sx: 0, sy: 300, sw: 300, sh: 300, size: 160 });
  assert.deepEqual(L.avatarCrop(100, 100, 64), { sx: 0, sy: 0, sw: 100, sh: 100, size: 64 });
});

test("chWho: own messages show the nickname (the default name when unset)", () => {
  assert.equal(L.chWho({ role: "user" }, {}), "我");
  assert.equal(L.chWho({ role: "user" }, {}, "Guest A"), "Guest A");
  assert.equal(L.chWho({ role: "assistant" }, { plate: "看板" }, "Guest A"), "看板");
});

test("app.js: own avatar is used beside bubbles, in search results, chat info and the Me-page card; an edit-profile page exists", () => {
  const a = src("app.js");
  assert.match(a, /function myAvatar\(/);
  // both .cg.hu.me spots (recorded and in-flight) carry the avatar via meGroup
  const mg = a.slice(a.indexOf("function meGroup("), a.indexOf("function meGroup(") + 700);
  assert.match(mg, /myAvatar\("cav"\)/);
  assert.ok((a.match(/meGroup\(\)/g) || []).length >= 2, "both cg hu me spots must carry myAvatar");
  const hits = a.slice(a.indexOf("function chRenderHits"), a.indexOf("function chRenderHits") + 2000);
  assert.match(hits, /myAvatar\(/);
  const info = a.slice(a.indexOf("function renderChatInfo"), a.indexOf("function renderChatInfo") + 1500);
  assert.match(info, /myAvatar\(/);
  const me = a.slice(a.indexOf("function renderMe()"), a.indexOf("function renderMe()") + 1800);
  assert.match(me, /myAvatar\(/);
  assert.match(a, /k === "card" \|\| k === "profile"\) openProfileEdit\(\)/); // tapping the card opens profile editing directly
  assert.match(a, /function openProfileEdit\(/);
  assert.match(a, /"\/api\/profile"/);
});

test("style.css: own bubbles get one notch narrower once the avatar column is added", () => {
  const css = src("style.css");
  const blk = css.slice(css.indexOf(".pf-av {"));
  assert.match(blk, /\.list \.cg\.hu\.me \.cg-col > \.m\s*\{[^}]*max-width:\s*7\d%/);
  assert.match(blk, /\.pf-av\b/);
});

// ---------- 3. roaming figure keeps walking until done ----------
const r0 = () => 0, r1 = () => 0.999, rh = () => 0.5;
test("figRoam: working walks back and forth within its own segment (7.webp, 12px/s)", () => {
  const m = L.figRoam("working", 10, [10, 40], [10, 200], r0);
  assert.equal(m.tx, 40);
  assert.equal(m.strip, "7");
  assert.equal(m.ms, Math.max(300, 30 / 12 * 1000));
  assert.equal(m.rest, "7");
  assert.ok(m.pause >= 1200 && m.pause <= 2800);
  assert.equal(L.figRoam("working", 40, [10, 40], [10, 200], r0).tx, 10);
});

test("figRoam: no waiting pose; when slow the speed halves, still row 7, pauses as usual", () => {
  const w = L.figRoam("working", 10, [10, 40], [10, 200], r0, true);
  const k = L.figRoam("working", 10, [10, 40], [10, 200], r0);
  assert.equal(w.tx, 40);
  assert.equal(w.strip, "7");
  assert.equal(w.ms, k.ms * 2);
  assert.equal(w.rest, "7");
  assert.equal(w.pause, k.pause);
  assert.equal(L.figRoam("waiting", 10, [10, 40], [10, 200], r0), null);
});

test("figRoam: a too-narrow segment (hi-lo<3) does not stand still; it walks randomly across the whole strip (may overlap peers)", () => {
  const CW = L.FIG.CW;
  for (const rnd of [r0, rh, r1]) {
    for (const slow of [false, true]) {
      const ph = "working" + (slow ? "/slow" : "");
      const m = L.figRoam("working", 50, [50, 51], [20, 200], rnd, slow);
      assert.ok(m, ph);
      assert.ok(m.tx >= 20 && m.tx <= 200 - CW, ph + " tx=" + m.tx);
      assert.ok(m.ms > 0);
    }
  }
  assert.deepEqual(L.figRoamRange([50, 51], [20, 200]), [20, 200 - CW]);
  assert.deepEqual(L.figRoamRange([10, 40], [10, 200]), [10, 40]);
});

test("figRoam: other phases do not walk", () => {
  for (const ph of ["rising", "celebrate", "walk", "parked", "queued", ""]) assert.equal(L.figRoam(ph, 0, [0, 30], [0, 100], r0), null);
});

test("figures.js: working schedules the next move (roaming only, half speed when slow); layout does not pull back a figure that roamed out of its segment", () => {
  const f = src("figures.js");
  const tw = f.slice(f.indexOf("function toWork"), f.indexOf("function roam"));
  assert.match(tw, /roam\(b\)/);
  const rm = f.slice(f.indexOf("function roam"), f.indexOf("function finish"));
  assert.match(rm, /figRoam\(/);
  assert.match(rm, /FIG_WAIT_SEC/);
  assert.match(rm, /b\.later\(loop/);
  const lay = f.slice(f.indexOf("  layout(pre)"), f.indexOf("  destroy() { this.moreTop"));
  assert.match(lay, /figRoamRange\(/);
});
