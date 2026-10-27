// The server sends codes / empty values / structures instead of Chinese text and the frontend translates by language; legacy server payloads still display correctly
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
import { buildLanes, chatPlan, chatRow, originText, sysLineText, wakeFailText, offFailText, sendUrl, pushSubBody, profileView } from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const each = (fn) => { for (const l of ["en", "hans", "hant"]) { setLang(l); fn(l); } setLang("hans"); };

test("1 off-duty list: an empty zone or the legacy unzoned label both map to the unzoned lane, named by language", () => {
  const snap = { zones: [{ code: "Web", name: "Web", color: "#f00", order: 1 }], sessions: [],
    offduty: [{ name: "A", sid: "a", zone: "" }, { name: "B", sid: "b", zone: "未分区" }] };
  each((l) => {
    const lanes = buildLanes(snap);
    assert.equal(lanes.length, 1);
    assert.equal(lanes[0].code, null);
    assert.equal(lanes[0].off.length, 2);
    assert.equal(lanes[0].name, { en: "No zone", hans: "未分区", hant: "未分區" }[l]);
  });
});

test("3 compaction notice: the {role:notice, code} form and the legacy user bubble both render as a centered line, by language", () => {
  const items = [
    { role: "user", text: "你好", ts: "2026-10-23T01:00:00Z" },
    { role: "notice", code: "compacted", ts: "2026-10-23T01:00:01Z" },
    { role: "user", text: "（上下文已压缩）", ts: "2026-10-23T01:00:02Z" },
    { role: "notice", code: "unknown-x", ts: "2026-10-23T01:00:03Z" }, // unknown and no text: not rendered
  ];
  each((l) => {
    const sys = chatPlan(items, {}).filter((b) => b.t === "sys");
    const want = { en: "Context compacted", hans: "上下文已压缩", hant: "上下文已壓縮" }[l];
    assert.deepEqual(sys.map((b) => [b.i, b.text]), [[1, want], [2, want]]);
  });
  assert.equal(sysLineText({ role: "notice", code: "zzz", text: "raw" }), "raw");
  const a = rd("app.js");
  assert.equal((a.match(/b\.t === "sys"/g) || []).length, 2, "both the main chat page and the subagent page render system notices");
});

test("4 peer note: originTag is composed by language; objects are never treated as strings", () => {
  each((l) => {
    assert.equal(originText({ originTag: { kind: "peer", peer: "Web-QS" } }), { en: "↔ Talking with Web-QS", hans: "↔ 与 Web-QS 往来", hant: "↔ 與 Web-QS 往來" }[l]);
    assert.equal(originText({ originTag: { kind: "peer", peer: "" } }), { en: "↔ Between sessions", hans: "↔ 会话间往来", hant: "↔ 會話間往來" }[l]);
    assert.equal(originText({ originTag: { kind: "agent" } }), { en: "⚙ Handled a subagent report", hans: "⚙ 处理了子代理回报", hant: "⚙ 處理了子代理回報" }[l]);
  });
  assert.equal(originText({ originTag: null }), "");
  setLang("en");
  const r = chatRow({ id: "a", name: "a", status: "idle", since: 1, originNote: "", originTag: { kind: "agent" } }, [], 10);
  assert.deepEqual(r.tag, { cls: "p", text: "⚙ Handled a subagent report:" });
  setLang("hans");
});

test("6 nickname: empty or the legacy \"me\" value are both displayed by language", () => {
  each((l) => {
    const me = { en: "Me", hans: "我", hant: "我" }[l];
    assert.equal(profileView({ name: "" }).name, me);
    assert.equal(profileView({ name: "我" }).name, me);
    assert.equal(profileView({ name: "Guest A" }).name, "Guest A");
  });
});

test("7 wake / off-duty failure: translate by code first; codes missing from the table use the original text (legacy helper); otherwise the generic sentence", () => {
  setLang("en");
  assert.equal(offFailText({ error: "offduty-not-idle" }), "It isn't idle, so it wasn't sent off duty");
  assert.equal(offFailText({ error: "offduty-restarting", message: "Mac 上正在重启会话，稍后再试" }), "The Mac is restarting sessions; try again later");
  assert.equal(offFailText({ error: "offduty-failed", message: "Lab 状态是 busy，不是空闲，不送（加 --force 强制）" }), "Lab 状态是 busy，不是空闲，不送");
  assert.equal(offFailText({ error: "offduty-failed" }), "Couldn't go off duty");
  assert.equal(wakeFailText({ error: "wake-already-awake" }), "It's already awake");
  assert.equal(wakeFailText({ error: "wake-failed", message: "OSError: x" }), "OSError: x");
  assert.equal(wakeFailText({ error: "wake-failed" }), "Couldn't wake it up");
  setLang("hans");
});

test("8 sends with attachments carry ?lang= in the URL; plain text, answers and recalls do not", () => {
  const p = "/api/sessions/a/send";
  assert.equal(sendUrl(p, { text: "", files: ["x.png"] }, "en"), p + "?lang=en");
  assert.equal(sendUrl(p, { text: "hi", enter: true }, "en"), p);
  assert.equal(sendUrl(p, { recall: "x" }, "hant"), p);
  assert.equal(sendUrl(p, { files: [] }, "hant"), p);
  assert.match(rd("app.js"), /runRequest\(sendUrl\(sessionPath\(s\.id, "send"\), body, lang\(\)\), body[,)]/);
});

test("5 push subscriptions carry the UI language (re-registered at every launch together with device info)", () => {
  assert.deepEqual(pushSubBody({ endpoint: "https://x", keys: { a: 1 } }, "en"), { endpoint: "https://x", keys: { a: 1 }, lang: "en" });
  const a = rd("app.js");
  assert.match(a, /post\("\/api\/push\/subscribe", pushSubBody\(sub\.toJSON\(\), lang\(\), devInfo\(\)\)/);
  assert.match(a, /initStep\("pushLang"/);
});
