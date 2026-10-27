// Guest gets the in-session features of the bound session (search, pre-window-switch history, chat info with search only, sub-agent page, context details, recalling own messages, own avatar and nickname)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { bubbleActs, chWho, guestProfileView, chHitText } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const app = read("../app.js");
const fnBody = (name, len = 1500) => { const i = app.indexOf("function " + name); assert.ok(i > 0, "missing " + name); return app.slice(i, i + len); };

test("bubbleActs: a guest's own still-queued messages can be recalled; forward is still not offered", () => {
  assert.deepEqual(bubbleActs({ who: "me", receipt: "delivered", guest: true }), ["copy", "quote", "recall"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "read", guest: true }), ["copy", "quote", "recall"]);
  assert.deepEqual(bubbleActs({ who: "admin", receipt: null, guest: true }), ["copy", "quote"]);
  assert.deepEqual(bubbleActs({ who: "self", guest: true }), ["copy", "quote"]);
});

test("guestProfileView: the guest's default comes from the API's default, else the built-in guest label; the avatar uses account=guest", () => {
  assert.deepEqual(guestProfileView(null), { name: "访客", url: "" });
  assert.deepEqual(guestProfileView({ name: "", avatar: false }), { name: "访客", url: "" });
  assert.deepEqual(guestProfileView({ name: "", avatar: false, default: "Alex" }), { name: "Alex", url: "" });
  assert.deepEqual(guestProfileView({ name: "访客A", avatar: true, v: 9 }), { name: "访客A", url: "/api/avatar?account=guest&v=9" });
});

test("chWho: a user hit tagged [Guest] is me to the guest and anything else is the admin; to the admin, [Guest] is the guest nickname", () => {
  const s = { plate: "guest-demo" };
  assert.equal(chWho({ role: "user", snippet: "[Guest] 看报表" }, s, "访客A", { guest: true }), "访客A");
  assert.equal(chWho({ role: "user", snippet: "管理员的话" }, s, "访客A", { guest: true }), "管理员");
  assert.equal(chWho({ role: "user", snippet: "[Guest] 看报表" }, s, "我", { guestName: "访客2" }), "访客2");
  assert.equal(chWho({ role: "user", snippet: "[Guest] 看报表" }, s, "我", {}), "访客");
  assert.equal(chWho({ role: "user", snippet: "自己的" }, s, "Guest A"), "Guest A");
  assert.equal(chWho({ role: "assistant" }, s, "x", { guest: true }), "guest-demo");
  assert.equal(chWho({ role: "user", from: "guest", snippet: "…中段命中，开头被切掉" }, s, "访客A", { guest: true }), "访客A");
  assert.equal(chWho({ role: "user", from: "guest", snippet: "…中段命中" }, s, "我", { guestName: "访客2" }), "访客2");
  assert.equal(chHitText("[Guest] 看报表"), "看报表");
  assert.equal(chHitText("…前面 [Guest] 不是开头"), "…前面 [Guest] 不是开头");
});

test("frontend drops the guest gate: pre-window-switch history, chat info, sub-agent card, context details, profile, recall", () => {
  assert.doesNotMatch(fnBody("chOlder(", 400), /st\.guest/, "pre-window-switch history is available to guests");
  assert.doesNotMatch(fnBody("openChatInfo(", 200), /st\.guest\) return/, "chat info is available to guests");
  const ci = fnBody("renderChatInfo(", 1400);
  assert.match(ci, /if \(st\.guest\) \{ \$\("#fs-body"\)\.replaceChildren\(head, g1\); return; \}/, "guest chat info has search only, no mute/pin");
  assert.ok(ci.indexOf("if (st.guest)") < ci.indexOf('t("ch.mute")'), "the guest branch returns before the mute switch");
  assert.doesNotMatch(fnBody("agBack(", 2000), /if \(!st\.guest\) \{/, "sub-agent card is available to guests");
  assert.doesNotMatch(fnBody("openCtxPanel(", 2400), /s\.kind === "claude" && !st\.guest/, "context details are available to guests");
  assert.doesNotMatch(fnBody("loadProfile(", 200), /if \(st\.guest\) return/);
  assert.doesNotMatch(fnBody("openProfileEdit(", 200), /if \(st\.guest\) return/);
  assert.doesNotMatch(fnBody("rcMark(", 1400), /rc === "sent" && !st\.guest/, "guests can recall by tapping the grey tick");
  assert.match(fnBody("doRecall(", 900), /putBack\(st\.guest \? stripGuestTag\(meta\.raw\) : meta\.raw\)/, "a guest recall strips [Guest] from the original before putting it back");
});

test("guest Me page: the card opens profile editing and shows the guest's own avatar and nickname", () => {
  const b = fnBody("renderGuestMe(", 1600);
  assert.match(b, /dataset\.me = "card"/);
  assert.match(b, /guestProfileView\(st\.profile\)\.name/);
  assert.match(b, /myAvatar\("me-av"\)/);
  assert.match(app, /st\.guest && !\["push", "card", "profile"\]\.includes\(k\)/);
});

test("bubble avatar and nickname: a guest uses their own; the admin sees the guest's bubbles with the guest's", () => {
  const me = fnBody("meGroup(", 320);
  assert.doesNotMatch(me, /personAvatar\("/);
  assert.match(me, /myAvatar\("cav"\)/);
  const g = fnBody("chatGroup(", 2600);
  assert.match(g, /guestAvatar\(\)/);
  assert.match(g, /guestProfileView\(st\.guestProfile\)\.name/);
  assert.match(fnBody("loadProfile(", 300), /if \(!st\.guest\) loadGuestProfile\(\)/);
  assert.match(fnBody("loadGuestProfile(", 400), /\/api\/profile\?account=" \+ encodeURIComponent\(acc\)/); // one per guest
});

test("still not offered to guests: forward, the chat-history section of global search, row long-press menu, mute/pin switches", () => {
  assert.match(app, /if \(st\.guest \|\| !g \|\| !gsReady\(q\)\) return \[\];/);
  assert.match(app, /if \(st\.guest\) \{ crLp = null; return; \}/);
  assert.match(fnBody("openRowMenu(", 300), /st\.guest/);
});

test("CSS: guests keep the ··· button", () => {
  assert.doesNotMatch(read("../style.css"), /body\.guest \.d-more\s*\{\s*display:\s*none/);
});
