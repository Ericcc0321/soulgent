// Push banners: banner text matches the push text (short-name title, body "[event] content") and honors do-not-disturb;
// subscriptions carry device info dev / plat / standalone; sw sets timestamp / renotify and converts session avatars to data URLs on Chromium-based browsers; test notification entry;
// also: the context ring on message list rows turns gray when meta is stale (same metaStale check as the chat page top bar)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import * as L from "../logic.js";
import { setLang, t } from "../i18n.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");
const sw = rd("sw.js");
const css = rd("style.css");
const fnBody = (src, name) => { const i = src.indexOf(name); return src.slice(i, src.indexOf("\n}\n", i)); };

// ---------- 1. banner text ----------
const W = (o = {}) => ({ id: "a", name: "Ops-demo-calc", plate: "demo-calc", zone: "Ops", status: "waiting", since: 100, ...o });
const D = (o = {}) => W({ status: "idle", unread: true, ...o });

test("bannerText: title = short name (with zone-colored avatar), waiting body \"[waiting] content\", three languages", () => {
  const s = W({ summary: "问你：要不要挪？", summaryCode: "wait.ask", summaryArgs: { question: "要不要挪？" } });
  const want = { en: "[Waiting for you] Asks: 要不要挪？", hans: "[在等你] 问你：要不要挪？", hant: "[在等你] 問你：要不要挪？" };
  for (const lg of ["en", "hans", "hant"]) {
    setLang(lg);
    assert.deepEqual(L.bannerText(s, "wait"), { title: "demo-calc", body: want[lg] }, lg);
  }
  setLang("hans");
});
test("bannerText: waiting with no content -> generic \"needs your decision\" body; waitingFor also gets the label", () => {
  setLang("hans");
  assert.equal(L.bannerText(W(), "wait").body, "[在等你] 有事要你定");
  assert.equal(L.bannerText(W({ waitingFor: "批准 Bash" }), "wait").body, "[在等你] 批准 Bash");
  setLang("en");
  assert.equal(L.bannerText(W(), "wait").body, "[Waiting for you] Needs your decision");
  setLang("hant");
  assert.equal(L.bannerText(W(), "wait").body, "[在等你] 有事要你決定");
  setLang("hans");
});
test("bannerText: done has no label, and with no content only the full word is written; error / stopped (WorkBuddy summaries are equivalent) also write only the full word", () => {
  setLang("hans");
  assert.deepEqual(L.bannerText(D({ summary: "补完了 4 月" }), "done"), { title: "demo-calc", body: "补完了 4 月" });
  const words = { en: ["Done", "Error", "Stopped"], hans: ["干完了", "出错了", "已中止"], hant: ["完成了", "出錯了", "已中止"] };
  for (const lg of ["en", "hans", "hant"]) {
    setLang(lg);
    assert.equal(L.bannerText(D(), "done").body, words[lg][0], lg);
    assert.equal(L.bannerText(D({ summary: "出错", summaryCode: "state.error" }), "err").body, words[lg][1], lg);
    assert.equal(L.bannerText(D({ summary: "已中止", summaryCode: "state.stopped" }), "stopped").body, words[lg][2], lg);
  }
  setLang("hans");
});
test("bannerText: unnamed per language", () => {
  setLang("en");
  assert.equal(L.bannerText(W({ nameUntitled: true }), "wait").title, "Untitled");
  setLang("hans");
});

// ---------- 2. banners honor do-not-disturb; error / stopped follow the same rules as push ----------
const step = (st, ss, ms) => L.bannerStep(st, ss, ms, null);
test("bannerStep: sessions with do-not-disturb show no banner for waiting or done", () => {
  let st = step(L.newBannerState(), [W({ status: "busy", muted: true }), D({ id: "b", unread: false, muted: true })], 0).state;
  let r = step(st, [W({ muted: true }), D({ id: "b", muted: true, since: 200 })], 1000);
  r = step(r.state, [W({ muted: true }), D({ id: "b", muted: true, since: 200 })], 60000);
  assert.deepEqual(r.fire, []);
  // the same session without do-not-disturb does show a banner
  st = step(L.newBannerState(), [W({ status: "busy" })], 0).state;
  r = step(st, [W()], 1000);
  r = step(r.state, [W()], 1000 + L.BANNER_WAIT_MS);
  assert.deepEqual(r.fire, [{ id: "a", kind: "wait" }]);
});
test("bannerStill: sessions set to do-not-disturb while queued show no banner", () => {
  assert.equal(L.bannerStill(W(), "wait"), true);
  assert.equal(L.bannerStill(W({ muted: true }), "wait"), false);
  assert.equal(L.bannerStill(D({ muted: true }), "done"), false);
  assert.equal(L.bannerStill(D({ summaryCode: "state.error" }), "err"), true);
});
test("bannerStep: WorkBuddy errors pop as errors (3 s), stops pop \"stopped\" after 10 s", () => {
  let st = step(L.newBannerState(), [D({ unread: false }), D({ id: "b", unread: false })], 0).state;
  const ss = [D({ summaryCode: "state.error", since: 300 }), D({ id: "b", summaryCode: "state.stopped", since: 300 })];
  let r = step(st, ss, 1000);
  r = step(r.state, ss, 1000 + L.BANNER_WAIT_MS);
  assert.deepEqual(r.fire, [{ id: "a", kind: "err" }]);
  r = step(r.state, ss, 1000 + L.BANNER_DONE_MS);
  assert.deepEqual(r.fire, [{ id: "b", kind: "stopped" }]);
});

// ---------- 3. device info ----------
const UA = {
  iphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
  ipad: "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
  mac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
  win: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0",
  android: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36",
  linux: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36",
};
test("devPlat: iPhone / iPad / iPad posing as Mac (touch points > 1) / Mac / Windows / Android / other", () => {
  assert.equal(L.devPlat(UA.iphone, 5), "iphone");
  assert.equal(L.devPlat(UA.ipad, 5), "ipad");
  assert.equal(L.devPlat(UA.mac, 5), "ipad");
  assert.equal(L.devPlat(UA.mac, 0), "mac");
  assert.equal(L.devPlat(UA.mac, undefined), "mac");
  assert.equal(L.devPlat(UA.win, 0), "windows");
  assert.equal(L.devPlat(UA.android, 5), "android");
  assert.equal(L.devPlat(UA.linux, 0), "other");
  assert.equal(L.devPlat("", 0), "other");
});
test("newDevId: 16 chars, only server-whitelisted characters, different random sources give different results", () => {
  const a = L.newDevId(Uint8Array.from({ length: 16 }, (_, i) => i * 17));
  const b = L.newDevId(Uint8Array.from({ length: 16 }, (_, i) => 255 - i));
  assert.match(a, /^[A-Za-z0-9_-]{16}$/);
  assert.match(b, /^[A-Za-z0-9_-]{16}$/);
  assert.notEqual(a, b);
});
test("pushSubBody: browser subscription JSON + language + device info", () => {
  const sub = { endpoint: "https://x/1", keys: { p256dh: "p", auth: "a" } };
  const dev = { dev: "abcDEF0123456789", plat: "iphone", standalone: true };
  assert.deepEqual(L.pushSubBody(sub, "hant", dev), { ...sub, lang: "hant", ...dev });
  assert.deepEqual(L.pushSubBody(sub, "hant"), { ...sub, lang: "hant" });
});
test("devLabel / pushDevLine: \"this device: iPhone home-screen app, notifications on, N devices on this account\" in three languages", () => {
  setLang("hans");
  assert.equal(L.devLabel("iphone", true), "iPhone 主屏 App");
  assert.equal(L.devLabel("iphone", false), "iPhone 浏览器");
  assert.equal(L.devLabel("mac", true), "Mac 程序坞 App");
  assert.equal(L.devLabel("mac", false), "Mac 浏览器");
  assert.equal(L.devLabel("windows", false), "Windows 浏览器");
  assert.equal(L.devLabel("other", false), "这台设备");
  assert.equal(L.pushDevLine({ plat: "iphone", standalone: true }, "通知已开启", 4), "本机：iPhone 主屏 App · 通知已开启 · 这个账户共 4 台");
  assert.equal(L.pushDevLine({ plat: "iphone", standalone: true }, "通知已开启", null), "本机：iPhone 主屏 App · 通知已开启");
  setLang("en");
  assert.equal(L.pushDevLine({ plat: "mac", standalone: true }, "Notifications on", 2), "This device: Mac Dock app · Notifications on · 2 on this account");
  setLang("hant");
  assert.equal(L.pushDevLine({ plat: "iphone", standalone: true }, "通知已開啟", 1), "本機：iPhone 主畫面 App · 通知已開啟 · 這個帳號共 1 台");
  setLang("hans");
});

// ---------- 4. front-end wiring ----------
test("app.js: subscribe / startup re-register both carry device info, re-registered on every startup (existing subscriptions also get dev)", () => {
  assert.match(fnBody(app, "async function enablePush"), /pushSubBody\(sub\.toJSON\(\), lang\(\), devInfo\(\)\)/);
  const sync = fnBody(app, "async function syncPush(");
  assert.match(sync, /pushSubBody\(sub\.toJSON\(\), lang\(\), devInfo\(\)\)/);
  assert.doesNotMatch(sync, /PUSH_LANG_KEY/); // not skipped based on a language marker
  assert.match(app, /localStorage\.getItem\("zbs\.dev"\)/);
});
test("app.js: opening a session immediately clears this device's notifications for that session", () => {
  assert.match(fnBody(app, "function showDetail("), /closeSessionNotifs\(id\)/);
  assert.match(fnBody(app, "async function closeSessionNotifs"), /getNotifications\(\{ tag: "s-" \+ id \}\)/);
});
test("app.js: notification settings have a this-device row and a test button (hidden for guests); no icon-test button", () => {
  const sheet = fnBody(app, "async function openPushSheet");
  assert.match(sheet, /test\.hidden = st\.guest/);
  assert.doesNotMatch(sheet, /icons: true|push\.iconTest/);
  assert.match(sheet, /\/api\/push\/devices/);
  assert.match(sheet, /pushDevLine\(/);
});
test("i18n: push.sent does not say the notification is withdrawn after 8 seconds (test notifications are not withdrawn)", () => {
  for (const lg of ["en", "hans", "hant"]) {
    setLang(lg);
    const s = t("push.sent", { a: 1, b: 2 });
    assert.doesNotMatch(s, /8|撤回|收回|withdraw/i, lg);
    assert.match(s, /1\/2/);
  }
  setLang("hans");
});

// ---------- 5. sw ----------
function loadSw() {
  const ctx = { self: { addEventListener() {}, location: { origin: "https://x" } }, caches: {}, URL, console, btoa, Uint8Array, String, Number, Object, encodeURIComponent };
  vm.createContext(ctx);
  vm.runInContext(sw + "\n;globalThis.__sw = { swHash, avatarPath, notifOptions, bytesToB64 };", ctx);
  return ctx.__sw;
}
test("sw: swHash is identical to the hash app.js uses to pick the pet (list and notification avatars match)", () => {
  const { swHash } = loadSw();
  const appHash = new Function("return " + fnBody(app, "function hash(str)") + "\n}")();
  for (const id of ["a", "zbs-test", "3f2c9a1e-77b0-4c1d-9e1a-0b5f2c8d7e6a", "中文会话", ""]) assert.equal(swHash(id), appHash(id), id);
});
test("sw: avatarPath with a specified pet -> hash-picked pet still.webp -> default spirit-flame expression", () => {
  const { avatarPath, swHash } = loadSw();
  const pets = { Boba: {}, Mochi: {}, Taro: {} };
  assert.equal(avatarPath({ id: "a", pet: "Mochi", st: "wait" }, pets), "/pets/Mochi/still.webp");
  const names = Object.keys(pets).sort();
  assert.equal(avatarPath({ id: "a", st: "wait" }, pets), "/pets/" + names[swHash("a") % 3] + "/still.webp");
  assert.equal(avatarPath({ id: "a", pet: "Gone", st: "wait" }, pets), "/pets/" + names[swHash("a") % 3] + "/still.webp");
  assert.equal(avatarPath({ id: "a", st: "wait" }, {}), "/icons/mascot-av-wait.png?v=1");
  assert.equal(avatarPath({ id: "a", st: "done" }, null), "/icons/mascot-av-done.png?v=1");
  assert.equal(avatarPath({ id: "a", st: "<x>" }, null), "/icons/mascot-av-idle.png?v=1");
  assert.equal(avatarPath({ id: "a", st: "wait" }, { "a b": {} }), "/pets/a%20b/still.webp");
  assert.equal(avatarPath(null, pets), "");
});
test("sw: notifOptions carries tag / timestamp / renotify / icon, omitting those not given", () => {
  const { notifOptions } = loadSw();
  const o = notifOptions({ tag: "s-a", body: "b", url: "/#s/a", timestamp: 1700000000500 }, "data:image/png;base64,AA");
  assert.equal(o.tag, "s-a");
  assert.equal(o.body, "b");
  assert.equal(o.timestamp, 1700000000500);
  assert.equal(o.renotify, true);
  assert.equal(o.icon, "data:image/png;base64,AA");
  assert.equal(o.data.url, "/#s/a");
  const p = notifOptions({}, "");
  assert.equal(p.tag, "zbs");
  assert.equal("icon" in p, false);
  assert.equal("timestamp" in p, false);
  assert.equal(notifOptions({ timestamp: "x" }, "").timestamp, undefined);
});
test("sw: bytesToB64 encodes in chunks (large images do not overflow the stack)", () => {
  const { bytesToB64 } = loadSw();
  assert.equal(bytesToB64(Uint8Array.from([1, 2, 3])), "AQID");
  const big = new Uint8Array(200000).fill(65);
  assert.equal(bytesToB64(big), Buffer.from(big).toString("base64"));
});
test("sw: onPush image fetch has a timeout and still calls showNotification on error; the icon is always embedded as a data URL", () => {
  const body = fnBody(sw, "async function onPush");
  assert.match(body, /withTimeout\(/);
  assert.match(body, /showNotification\(msg\.title \|\| DEFAULT_TITLE, notifOptions\(msg, icon\)\)/);
  assert.doesNotMatch(fnBody(sw, "async function pushIcon"), /iconMode/);
});

// ---------- 6. extra: row ring turns gray when stale ----------
test("metaStale: no timestamp or older than META_STALE_SEC counts as stale; both ctxPanel and rowCtx use it", () => {
  assert.equal(L.metaStale({ at: 1000 }, 1000 + L.META_STALE_SEC), false);
  assert.equal(L.metaStale({ at: 1000 }, 1000 + L.META_STALE_SEC + 1), true);
  assert.equal(L.metaStale({}, 1000), true);
  assert.equal(L.metaStale(null, 1000), true);
  const lg = rd("logic.js");
  assert.match(fnBody(lg, "export function ctxPanel"), /metaStale\(/);
  assert.match(fnBody(lg, "export function rowCtx"), /metaStale\(/);
  assert.doesNotMatch(fnBody(lg, "export function ctxPanel"), /age > META_STALE_SEC/);
});
test("rowCtx: stale meta -> gray tier n (regardless of percentage), fresh meta uses the three tiers", () => {
  const now = 10000;
  assert.deepEqual(L.rowCtx({ meta: { ctxPct: 83, at: now - 10 } }, now), { pct: 83, lv: "bad", text: "83%", stale: false });
  assert.deepEqual(L.rowCtx({ meta: { ctxPct: 83, at: now - L.META_STALE_SEC - 1 } }, now), { pct: 83, lv: "n", text: "83%", stale: true });
  assert.deepEqual(L.rowCtx({ meta: { ctxPct: 58 } }, now), { pct: 58, lv: "n", text: "58%", stale: true });
});
test("app.js / style.css: the row ring passes nowSec(), and gray tier .cr-cx.n is dimmed like the top bar", () => {
  assert.match(fnBody(app, "function fillMsgLi"), /rowCtx\(s, nowSec\(\)\)/);
  assert.match(css, /\.cr-cx\.n\s*\{[^}]*--cx:\s*var\(--rg-n\)/);
  assert.match(css, /\.cr-cx\.n\s*\{[^}]*opacity:\s*\.42/);
});

// ---------- 7. version ----------
test("sw and shell version", () => {
  assert.match(sw, /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
