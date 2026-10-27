// Guest and admin looks are aligned: card avatar, login-page wording, manifest tagline, background color, admin copy goes through i18n
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { meCardAvatarKind, fireLevel } from "../logic.js";
import { table } from "../i18n.js";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const T = table();

test("meCardAvatarKind: a set avatar is always used; unset - guests get an initial tile, admins the Orca icon", () => {
  assert.equal(meCardAvatarKind(true, true), "photo");
  assert.equal(meCardAvatarKind(false, true), "photo");
  assert.equal(meCardAvatarKind(true, false), "initial");
  assert.equal(meCardAvatarKind(false, false), "orca");
});

test("guest cards do not use the orca icon; admin cards decide via meCardAvatarKind", () => {
  const app = read("../app.js");
  const guestMe = app.slice(app.indexOf("function renderGuestMe"), app.indexOf("function renderMe()"));
  assert.ok(guestMe.length > 100);
  assert.ok(!guestMe.includes("term-180"));
  assert.ok(guestMe.includes('myAvatar("me-av")'));
  assert.ok(app.includes('meCardAvatarKind(false, !!st.profileUrl) === "photo"'));
});

test("fireLevel: a top-level model alone (as allowed in guest snapshots) also lights the fire", () => {
  assert.equal(fireLevel({ model: "claude-fable-5-1", status: "busy" }), "strong");
});

test("login page: no mention of .env / WEBAPP_KEY; the three languages say \"No key? Ask your admin.\"", () => {
  assert.ok(!read("../login.html").includes("WEBAPP_KEY"));
  const h = T["login.hint1"];
  for (const v of h) assert.ok(!/WEBAPP_KEY|\.env/.test(v));
  assert.deepEqual(h, ["No key? Ask your admin.", "没有密钥？请向管理员索取。", "沒有金鑰？請向管理員索取。"]);
});

test("login.html background is unified to #111, no more #0b0c10", () => {
  const l = read("../login.html");
  assert.ok(!l.includes("#0b0c10"));
  assert.ok(/html, body \{[^}]*background: #111;/.test(l));
});

test("the manifest description is a neutral tagline, registered in i18n for all three languages", () => {
  const m = JSON.parse(read("../manifest.webmanifest"));
  assert.equal(m.description, "给你的 Agent 一个灵魂。");
  assert.equal(m.lang, "zh-CN");
  assert.deepEqual(T["app.tagline"], ["Give your agents a soul.", "给你的 Agent 一个灵魂。", "給你的 Agent 一個靈魂。"]);
});

test("the admin card's admin / Soulgent ID labels go through i18n instead of being hardcoded", () => {
  const app = read("../app.js");
  assert.ok(!app.includes('"Soulgent ID: admin"'));
  assert.ok(app.includes('t("me.adminName")') && app.includes('t("me.adminId")'));
  assert.equal(T["me.adminName"].length, 3);
  assert.equal(T["me.adminId"].length, 3);
});
