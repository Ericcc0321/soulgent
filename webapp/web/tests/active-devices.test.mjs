// Active-device registration: foreground snapshot polling carries X-Zbs-Dev / X-Zbs-Act / X-Zbs-Seen;
// a desktop is "active" = visible + (window focused or acted within 60s), a phone only needs to be visible; leaving (hidden / pagehide / desktop blur) fires sendBeacon /api/presence;
// a banner shown / the session being viewed -> reported once; notification settings list this account's devices (type, last active, this device) and allow deletion (deleting this device stops push and unsubscribes)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { setLang, t } from "../i18n.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");
const fnBody = (src, name) => { const i = src.indexOf(name); assert.ok(i >= 0, name); return src.slice(i, src.indexOf("\n}\n", i)); };

// ---------- 1. active detection ----------
test("actNow: phone / tablet only need visibility; desktop needs focus or an action within 60s", () => {
  const now = 1_000_000;
  for (const p of ["iphone", "ipad", "android"]) {
    assert.equal(L.actNow(p, true, false, 0, now), true, p);
    assert.equal(L.actNow(p, false, true, now, now), false, p);
  }
  for (const p of ["mac", "windows", "other", undefined]) {
    assert.equal(L.actNow(p, true, true, 0, now), true, p);
    assert.equal(L.actNow(p, true, false, 0, now), false, p + " no focus, no action");
    assert.equal(L.actNow(p, true, false, now - 59_000, now), true, p + " acted 59s ago");
    assert.equal(L.actNow(p, true, false, now - 61_000, now), false, p + " acted 61s ago");
    assert.equal(L.actNow(p, false, true, now, now), false, p + " not visible");
  }
  assert.equal(L.ACT_INPUT_MS, 60000);
});

// ---------- 2. request headers, reports ----------
test("presenceHeaders: device id, active 1/0; X-Zbs-Seen only when there is a report", () => {
  assert.deepEqual(L.presenceHeaders("devAAAA11112222", true, []), { "X-Zbs-Dev": "devAAAA11112222", "X-Zbs-Act": "1" });
  assert.deepEqual(L.presenceHeaders("devAAAA11112222", false, ["s-a:wait", "s-b:done"]),
    { "X-Zbs-Dev": "devAAAA11112222", "X-Zbs-Act": "0", "X-Zbs-Seen": "s-a:wait,s-b:done" });
});
test("seenAdd: s-<encoded id>:<event>, deduplicated, at most 20 entries, does not mutate the input", () => {
  const a = [];
  const b = L.seenAdd(a, "会话 1", "wait");
  assert.deepEqual(a, []);
  assert.deepEqual(b, ["s-" + encodeURIComponent("会话 1") + ":wait"]);
  assert.equal(L.seenAdd(b, "会话 1", "wait").length, 1);
  assert.deepEqual(L.seenAdd(b, "会话 1", "done").length, 2);
  let c = [];
  for (let i = 0; i < 30; i++) c = L.seenAdd(c, "x" + i, "wait");
  assert.equal(c.length, 20);
  assert.equal(c[19], "s-x29:wait"); // keeps the newest
  for (const k of c) assert.match(k, /^s-[^\s:,]+:(wait|done|err|stopped)$/);
});
test("presenceBody: the beacon body is a JSON string (sendBeacon sends text/plain), act 0/1", () => {
  assert.deepEqual(JSON.parse(L.presenceBody("devAAAA11112222", false, ["s-a:wait"])), { dev: "devAAAA11112222", act: 0, seen: ["s-a:wait"] });
  assert.equal(JSON.parse(L.presenceBody("devAAAA11112222", true, [])).act, 1);
});
test("bannerStep: a session being viewed reports seen (no banner); banners shown go through fire", () => {
  const W = (o) => ({ id: "a", status: "busy", since: 1, ...o });
  let r = L.bannerStep(L.newBannerState(), [W(), W({ id: "b" })], 0, null);
  r = L.bannerStep(r.state, [W({ status: "waiting", since: 5 }), W({ id: "b", status: "waiting", since: 6 })], 1000, "a");
  assert.deepEqual(r.seen, [{ id: "a", kind: "wait" }]);
  assert.deepEqual(r.fire, []);
  r = L.bannerStep(r.state, [W({ status: "waiting", since: 5 }), W({ id: "b", status: "waiting", since: 6 })], 1000 + L.BANNER_WAIT_MS, "a");
  assert.deepEqual(r.fire, [{ id: "b", kind: "wait" }]);
  assert.deepEqual(r.seen, []); // reported only once
});

// ---------- 3. device list ----------
test("deviceRows: this device first, then newest last-active first; active / last active / legacy subscription (unknown device)", () => {
  setLang("hans");
  const now = 1_000_000;
  const rows = L.deviceRows([
    { key: "k1", at: now - 7200, lastActive: now - 7200 },
    { key: "k2", dev: "d2", plat: "mac", standalone: true, lastActive: now - 300, active: false },
    { key: "k3", dev: "d3", plat: "iphone", standalone: true, lastActive: now - 5, active: true, self: true },
    { key: "k4", dev: "d4", plat: "windows", standalone: false, lastActive: now - 3 * 86400 },
    { dev: "bad" }, // no key: legacy API, cannot be deleted and is not listed
  ], now);
  assert.deepEqual(rows.map((r) => r.key), ["k3", "k2", "k1", "k4"]);
  assert.equal(rows[0].self, true);
  assert.equal(rows[0].label, "iPhone 主屏 App");
  assert.equal(rows[0].last, "正在用");
  assert.equal(rows[1].label, "Mac 程序坞 App");
  assert.equal(rows[1].last, "最后活跃：5 分钟前");
  assert.equal(rows[2].label, "未知设备（旧订阅）");
  assert.equal(rows[2].last, "最后活跃：2 小时前");
  assert.equal(rows[3].label, "Windows 浏览器");
  assert.equal(rows[3].last, "最后活跃：3 天前");
  assert.deepEqual(L.deviceRows(null, now), []);
});
test("devAgo: three languages", () => {
  const now = 10_000_000;
  const want = {
    en: ["just now", "5 min ago", "2 h ago", "3 days ago"],
    hans: ["刚刚", "5 分钟前", "2 小时前", "3 天前"],
    hant: ["剛剛", "5 分鐘前", "2 小時前", "3 天前"],
  };
  for (const lg of ["en", "hans", "hant"]) {
    setLang(lg);
    assert.deepEqual([now - 10, now - 300, now - 7200, now - 3 * 86400].map((s) => L.devAgo(s, now)), want[lg], lg);
  }
  setLang("hans");
});
test("deviceDelAsk: deleting this device warns that push stops; deleting another warns it re-registers when reopened", () => {
  for (const lg of ["en", "hans", "hant"]) {
    setLang(lg);
    const me = L.deviceDelAsk({ self: true, label: "X" });
    const other = L.deviceDelAsk({ self: false, label: "X" });
    assert.notEqual(me.hint, other.hint, lg);
    assert.match(me.hint, { en: /stop/i, hans: /停止本机/, hant: /停止本機/ }[lg]);
    assert.match(other.hint, { en: /again/i, hans: /重新登记/, hant: /重新登記/ }[lg]);
    assert.ok(me.title.includes("X"), lg);
  }
  setLang("hans");
});

// ---------- 4. app.js wiring ----------
test("app.js: snapshot requests carry the active headers; reports are cleared only after a real snapshot (not an offline copy) is received", () => {
  const r = fnBody(app, "function refresh()");
  assert.match(r, /presenceHeaders\(devId\(\), actApp\(\), sent\)/);
  assert.match(r, /if \(res\.ok && !st\.offline\) PR\.seen = PR\.seen\.filter/);
});
test("app.js: hidden / pagehide / desktop blur send the /api/presence beacon; blur clears the last-action time", () => {
  assert.match(fnBody(app, "function presenceBeacon("), /navigator\.sendBeacon\("\/api\/presence", presenceBody\(devId\(\), act, seen\)\)/);
  const vis = app.slice(app.indexOf('document.addEventListener("visibilitychange", () => {\n    if (document.hidden) { stopPolling();'));
  assert.match(vis.slice(0, 300), /presenceBeacon\(\)/);
  assert.match(app, /addEventListener\("pagehide", \(\) => presenceBeacon\(\)\)/);
  assert.match(fnBody(app, "function initPresence("), /addEventListener\("blur", \(\) => \{ PR\.lastInput = 0; presenceBeacon\(\); \}\)/);
  assert.match(fnBody(app, "function initPresence("), /pointerdown/);
  assert.match(fnBody(app, "function actApp("), /actNow\(devInfo\(\)\.plat, !document\.hidden, document\.hasFocus\(\), PR\.lastInput, Date\.now\(\)\)/);
});
test("app.js: banner shown / being viewed -> record a report", () => {
  assert.match(fnBody(app, "function showBanner("), /seenMark\(f\.id, f\.kind\)/);
  assert.match(fnBody(app, "function runBanner("), /for \(const x of r\.seen\) seenMark\(x\.id, x\.kind\)/);
});
test("app.js: the device list is fetched with this device id; deleting this device also unsubscribes its push", () => {
  const sheet = fnBody(app, "async function openPushSheet");
  assert.match(sheet, /api\("\/api\/push\/devices", \{ headers: \{ "X-Zbs-Dev": devId\(\) \} \}/);
  assert.match(sheet, /deviceRows\(/);
  const del = fnBody(app, "async function deleteDevice(");
  assert.match(del, /post\("\/api\/push\/devices\/delete", \{ key: row\.key \}/);
  assert.match(del, /if \(row\.self\)[\s\S]*unsubscribe\(\)/);
  assert.match(fnBody(app, "function askDeleteDevice("), /deviceDelAsk\(row\)/);
});
test("app.js: a fresh snapshot also clears the mac-link notice (once the host is back and a device returns to the foreground it does not linger)", () => {
  assert.match(fnBody(app, "async function closeStaleNotifs"), /staleTags\(list\.map\(\(n\) => n\.tag\), sessions, true\)/);
  assert.deepEqual(L.staleTags(["mac-link", "s-a", "x"], [{ id: "a", status: "waiting" }], true), ["mac-link"]);
  assert.deepEqual(L.staleTags(["mac-link"], [], false), []);
});
test("i18n: the device entries exist in all three languages", () => {
  for (const k of ["push.devList", "push.devSelf", "push.devActive", "push.devLast", "push.devUnknown", "push.devDel",
    "push.devDelTitle", "push.devDelSelf", "push.devDelOther", "push.devDeleted", "push.devNone",
    "push.agoNow", "push.agoMin", "push.agoHour", "push.agoDay"]) {
    for (const lg of ["en", "hans", "hant"]) { setLang(lg); assert.notEqual(t(k, { t: "x", n: 1, dev: "x" }), k, k + " " + lg); }
  }
  setLang("hans");
});
test("service worker and shell version", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
