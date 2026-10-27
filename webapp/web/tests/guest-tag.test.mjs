// The guest message prefix is not hard-coded (server .env GUEST_TAG, passed to the frontend as the tag of /api/auth/me); a deployment configured with a custom prefix behaves byte-for-byte like the default one
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  setGuestTag, guestTag, withGuestTag, pickGuestTag, guestInitials, cleanGuestTag, DEFAULT_GUEST_TAG,
  isGuestText, stripGuestTag, parseQuoted, speakerKey, chatPlan, chHitGuest, chHitText, chWho, guestProfileView,
} from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
// A legacy deployment's prefix is "[LEGACY ACCOUNT NAME UPPERCASE]"; a fictional three-letter legacy name is used here (avatar initials are kept as-is up to three characters)
const LEGACY = "[OLD]";
const app = read("../app.js");
const logic = read("../logic.js");

test("default prefix [Guest]; an invalid setGuestTag falls back to the default", () => {
  assert.equal(guestTag(), DEFAULT_GUEST_TAG);
  assert.equal(setGuestTag("  [Ab] "), "[Ab]");
  for (const bad of ["", "  ", "[a b]", "a\nb", "x".repeat(25), null, 3]) assert.equal(setGuestTag(bad), "[Guest]", String(bad));
  assert.equal(cleanGuestTag("x".repeat(24)), "x".repeat(24));
});

test("custom prefix: recognizes guest, strips prefix, quotes, images, byte-for-byte identical to the default behavior", () => {
  setGuestTag(LEGACY);
  const L = LEGACY;
  assert.equal(withGuestTag("你好"), L + " 你好");
  assert.equal(speakerKey({ role: "user", text: L + " 003 补一句" }), "guest");
  assert.equal(speakerKey({ role: "user", text: L + "没空格" }), "admin");
  assert.equal(speakerKey({ role: "user", text: "[Image #1] [Image #2] " + L + " 你好" }), "guest");
  assert.equal(speakerKey({ role: "user", text: "[Guest] 你好" }), "admin"); // not the prefix configured on this machine
  assert.equal(stripGuestTag(L + " 你好"), "你好");
  assert.equal(stripGuestTag("你好 " + L + " "), "你好 " + L + " ");
  assert.equal(stripGuestTag("[Image #1] " + L + " 这个是到货"), "[Image #1] 这个是到货");
  assert.equal(stripGuestTag(L), ""); // the message that carries only an attachment
  assert.deepEqual(parseQuoted(L + " > API: 原文\n\n好"), { tag: L + " ", quote: "API: 原文", body: "好" });
  assert.deepEqual(parseQuoted("> 看板: 原文\n\n正文"), { tag: "", quote: "看板: 原文", body: "正文" });
  assert.ok(chHitGuest({ role: "user", snippet: L + " 看报表" }));
  assert.ok(chHitGuest({ role: "user", from: "guest", snippet: "…中段" }));
  assert.equal(chHitText(L + " 看报表"), "看报表");
  assert.equal(chWho({ role: "user", snippet: L + " 看报表" }, {}, "我", { guestName: "访客2" }), "访客2");
  const items = [{ role: "user", text: L + " 需求", ts: "2026-10-21T06:00:00Z" }, { role: "user", text: "出一版", ts: "2026-10-21T06:01:00Z" }];
  assert.deepEqual(chatPlan(items, {}).filter((b) => b.t === "group").map((b) => b.who), ["guest", "me"]);
  assert.deepEqual(chatPlan(items, { guest: true }).filter((b) => b.t === "group").map((b) => b.who), ["me", "admin"]);
  assert.equal(guestInitials(), LEGACY.slice(1, -1)); // avatar initials = prefix without brackets
  setGuestTag(null);
});

test("regex characters in the prefix are escaped", () => {
  setGuestTag("(a+)");
  assert.ok(isGuestText("(a+) x"));
  assert.ok(!isGuestText("aa x"));
  assert.equal(stripGuestTag("[Image #1] (a+) y"), "[Image #1] y");
  setGuestTag(null);
});

test("guestInitials: strips outer brackets, keeps up to three characters as-is, takes the first character when longer", () => {
  assert.equal(guestInitials("[Guest]"), "G");
  assert.equal(guestInitials("[访客B]"), "访客B");
  assert.equal(guestInitials("【客】"), "客");
  assert.equal(guestInitials("ABC"), "ABC");
});

test("pickGuestTag: from the API -> remembered -> legacy API inferred from the account name -> default", () => {
  assert.equal(pickGuestTag({ tag: LEGACY }, null, "guest"), LEGACY);
  assert.equal(pickGuestTag({ tag: "bad tag" }, LEGACY, "guest"), LEGACY);
  // an API that gives no tag: the guest account name is the name inside the legacy prefix
  const oldAcc = LEGACY.slice(1, -1).toLowerCase();
  assert.equal(pickGuestTag({ user: oldAcc, account: oldAcc, session: "x" }, null, oldAcc), LEGACY);
  assert.equal(pickGuestTag(null, null, oldAcc), LEGACY); // offline, stale cache
  assert.equal(pickGuestTag({ user: "admin", account: "admin" }, null, "admin"), DEFAULT_GUEST_TAG);
  assert.equal(pickGuestTag({ user: "guest", tag: "[Guest]" }, LEGACY, "guest"), "[Guest]");
});

test("avatar uses account=guest (the server also accepts the legacy name)", () => {
  assert.equal(guestProfileView({ avatar: true, v: 2 }).url, "/api/avatar?account=guest&v=2");
});

test("app.js: prefix, avatar initials and guest detection are all not hard-coded", () => {
  assert.doesNotMatch(app + logic, /\[Guest\] "|"\[Guest\]"(?!;)/, "the prefix only comes from DEFAULT_GUEST_TAG");
  assert.match(app, /st\.guest = !!acc && acc !== "admin";/, "anyone who is not admin is a guest (including legacy account names in a stale cache)");
  const la = app.slice(app.indexOf("async function loadAccount"), app.indexOf("async function guestLogout"));
  assert.match(la, /pickGuestTag\(me, old && old\.tag, acc\)/);
  assert.match(la, /setGuestTag\(tag\)/);
  assert.match(la, /guestSeenKey = "zbs\." \+ store \+ "Seen"/, "the read-marker key follows the server storage name so legacy deployments keep their read state");
  assert.match(app, /guestPendText\(quote, input\)/); // plain text sending goes through guestPendText (slash commands get no prefix)
  assert.match(app, /withGuestTag\(shown\)/);
  assert.match(app, /personAvatar\(guestInitials\(st\.guestTagCur \|\| undefined\)\)/); // the initials come from the prefix of the guest of the current session
  assert.match(app, /t\("me.guestFoot", \{ tag: guestTag\(\) \}\)/);
  assert.match(app, /\.m\.gst, \.m\.adm/);
  assert.match(read("../style.css"), /\.m\.gst \{/);
});

test("sw.js: takes over shell navigation only; other pages (private reverse proxies etc.) pass straight through", () => {
  const sw = read("../sw.js");
  assert.match(sw, /if \(p !== "\/" && p !== "\/index\.html"\) return;/);
});
