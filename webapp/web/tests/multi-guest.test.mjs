// Multiple guests + GB channel: guest slash commands only allow the configured list (GUEST_SLASH_COMMANDS via /api/auth/me; others are blocked in the front end with a three-language hint, text stays in the input box);
// the admin recognizes every guest's prefix and looks up a guest's nickname/avatar by session; a guest only recognizes their own prefix.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang, t } from "../i18n.js";
import {
  setGuestTag, setGuestTags, guestFor, guestSlashBlocked, guestPendText, setGuestSlashCommands, guestSlashCommands, isGuestText, stripGuestTag,
  parseQuoted, chHitGuest, speakerKey, guestProfileView, dropOnFail, failReason, guestInitials,
} from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

test("guestSlashBlocked: default empty list blocks every slash command, /window included", () => {
  setGuestSlashCommands([]);
  assert.deepEqual(guestSlashCommands(), []);
  for (const s of ["/window", "/window x", "/model"]) assert.equal(guestSlashBlocked("", s), true, s);
  for (const s of ["/tmp/a.png 看", "hi"]) assert.equal(guestSlashBlocked("", s), false, s);
  setGuestSlashCommands(undefined);
  assert.deepEqual(guestSlashCommands(), []);
});

test("setGuestSlashCommands keeps only strings that start with / and have no whitespace", () => {
  setGuestSlashCommands(["/window", "foo", "/a b", 3, null, "/", "/x:y"]);
  assert.deepEqual(guestSlashCommands(), ["/window", "/x:y"]);
  setGuestSlashCommands([]);
});

test("guestSlashBlocked: with [\"/window\"] only /window (with arguments allowed) passes, other slash commands are blocked; paths, quoted text, and a slash not at the start are not commands", () => {
  setGuestSlashCommands(["/window"]);
  for (const s of ["/model opus", "/clear", "/compact 留重点", "/windows", "/Window", "  /exit  "]) assert.equal(guestSlashBlocked("", s), true, s);
  for (const s of ["/window", "/window 换窗", "  /window  ", "/tmp/a.png 看", "说 /model", "/window/x", "hi"]) assert.equal(guestSlashBlocked("", s), false, s);
  assert.equal(guestSlashBlocked("demo: 原文", "/model"), false); // with a quote: what is sent starts with "> quote", so it is not a command
  assert.equal(guestSlashBlocked("   ", "/model"), true); // a blank quote counts as no quote
});

test("guestPendText: the allowed /window gets no prefix, everything else does", () => {
  setGuestTag("[GB]");
  setGuestSlashCommands(["/window"]);
  assert.equal(guestPendText("", "/window 换个窗"), "/window 换个窗");
  assert.equal(guestPendText("", "hi"), "[GB] hi");
  assert.equal(guestPendText("", "/model"), "[GB] /model");
});

test("three-language hint and rejection code: slash-forbidden goes through dropOnFail (bubble removed, original text put back)", () => {
  const want = { en: "This command can only be entered on the Mac", hans: "这个命令只能在 Mac 上输入", hant: "這個命令只能在 Mac 上輸入" };
  for (const [l, s] of Object.entries(want)) { setLang(l); assert.equal(t("fail.slash-forbidden"), s); assert.equal(failReason("slash-forbidden"), s); }
  setLang("hans");
  assert.equal(dropOnFail("slash-forbidden"), true);
});

test("sendText: a guest's slash command is blocked first (hint shown, input not cleared, no bubble drawn); the admin is not blocked", () => {
  const app = rd("app.js");
  const i = app.indexOf("function sendText");
  const body = app.slice(i, i + 1600);
  const at = body.indexOf("guestSlashBlocked(st.quote, input)");
  assert.ok(at > 0);
  assert.match(body, /if \(st\.guest && guestSlashBlocked\(st\.quote, input\)\) \{.*toast\(t\("fail\.slash-forbidden"\)\); return; \}/);
  assert.ok(at < body.indexOf('$("#reply").value = ""'), "the block happens before the input box is cleared");
});

test("a guest only recognizes their own prefix; the admin recognizes all guests' (prefix stripping, quotes, search hits, speaker)", () => {
  setGuestTag("[GB]"); // guest GB
  assert.equal(isGuestText("[GB] hi"), true);
  assert.equal(isGuestText("[GA] hi"), false);
  setGuestTag("[GA]"); // admin: the primary prefix is the first guest's, plus every one in the list
  assert.deepEqual(setGuestTags(["[GA]", "[GB]", "bad tag", ""]), ["[GA]", "[GB]"]);
  for (const s of ["[GA] hi", "[GB] hi", "[Image #1] [GB] hi"]) assert.equal(isGuestText(s), true, s);
  assert.equal(isGuestText("hi"), false);
  assert.equal(stripGuestTag("[GB] 你好"), "你好");
  assert.equal(stripGuestTag("[GA] 你好"), "你好");
  assert.equal(stripGuestTag("[Image #2] [GB] 图"), "[Image #2] 图");
  assert.deepEqual(parseQuoted("[GB] > 管理员: 原文\n\n正文"), { tag: "[GB] ", quote: "管理员: 原文", body: "正文" });
  assert.deepEqual(parseQuoted("> 管理员: 原文\n\n正文"), { tag: "", quote: "管理员: 原文", body: "正文" });
  assert.equal(chHitGuest({ role: "user", from: "", snippet: "[GB] 命中" }), true);
  assert.equal(speakerKey({ role: "user", text: "[GB] x" }), "guest");
  assert.equal(speakerKey({ role: "user", text: "x" }), "admin");
  assert.equal(guestInitials("[GB]"), "GB");
  setGuestTag("[GA]"); // setGuestTag resets the list to just itself
  assert.equal(isGuestText("[GB] hi"), false);
});

test("guestFor: finds the bound guest by full session name or \"zone-plate\"; returns null if none", () => {
  const gs = [{ account: "guest", tag: "[GA]", session: "Web-guest-demo" }, { account: "gb", tag: "[GB]", session: "Ops-demo-proj" }];
  assert.equal(guestFor({ name: "Ops-demo-proj" }, gs).account, "gb");
  assert.equal(guestFor({ name: "demo-proj", zone: "Ops", plate: "demo-proj" }, gs).account, "gb");
  assert.equal(guestFor({ name: "Web-guest-demo" }, gs).account, "guest");
  assert.equal(guestFor({ name: "Web-other" }, gs), null);
  assert.equal(guestFor(null, gs), null);
  assert.equal(guestFor({ name: "x" }, undefined), null);
});

test("guest display name and avatar URL per account: the nickname defaults to the API's default (GUEST2_NAME, e.g. a second guest label)", () => {
  setLang("hans");
  assert.deepEqual(guestProfileView({ name: "", avatar: false, default: "访客B" }, "gb"), { name: "访客B", url: "" });
  assert.equal(guestProfileView({ name: "", avatar: true, v: 3, default: "访客B" }, "gb").url, "/api/avatar?account=gb&v=3");
  assert.equal(guestProfileView({ avatar: true, v: 2 }).url, "/api/avatar?account=guest&v=2"); // no account given = first guest, same as the single-guest case
});

test("app.js: the admin reads guests from /api/auth/me, a guest only recognizes self; the chat page switches guest profile per session", () => {
  const app = rd("app.js");
  assert.match(app, /st\.guests = acc === "admin" \? guests : \[\];/);
  assert.match(app, /setGuestTags\(st\.guests\.map\(\(g\) => g\.tag\)\)/);
  assert.match(app, /syncGuestCur\(s\);/);
  assert.match(app, /const g = guestFor\(s, st\.guests\);/);
});

test("sw and shell version", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142"/);
  assert.match(rd("index.html"), /name="zbs-shell" content="v142"/);
});

test("app.js: loadAccount takes the guest slash list from /api/auth/me (slash), caches it for offline start, and hands it to setGuestSlashCommands", () => {
  const app = rd("app.js");
  const la = app.slice(app.indexOf("async function loadAccount"), app.indexOf("async function guestLogout"));
  assert.match(la, /Array\.isArray\(me\.slash\) \? me\.slash : \[\]/);
  assert.match(la, /guests, slash \}\)/);
  assert.match(la, /setGuestSlashCommands\(slash\)/);
});
