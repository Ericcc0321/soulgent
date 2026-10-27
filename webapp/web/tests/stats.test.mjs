import test from "node:test";
import assert from "node:assert/strict";
import { fmtTokens, fmtHours, fmtUsd, fmtBytes, heatLevel, heatGrid, meStats, shortDay, pressureInfo, diskInfo, loadInfo, swapInfo, memInfo, batteryInfo, monitorStale, freshText, zoneBoard, DISK_WARN, DISK_BAD } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

test("fmtTokens uses the Chinese unit suffixes", () => {
  assert.equal(fmtTokens(0), "0");
  assert.equal(fmtTokens(9999), "9999");
  assert.equal(fmtTokens(12345), "1.2 万");
  assert.equal(fmtTokens(610600751), "6.11 亿");
  assert.equal(fmtTokens(32759471236), "328 亿");
  assert.equal(fmtTokens(null), "0");
});

test("fmtHours / fmtUsd / fmtBytes", () => {
  assert.deepEqual(fmtHours(6156204423), { n: "1,710", unit: "小时" });
  assert.deepEqual(fmtHours(30 * 60000), { n: "30", unit: "分钟" });
  assert.equal(fmtUsd(22338.27), "$22,338");
  assert.equal(fmtUsd(12.345), "$12.35");
  assert.equal(fmtBytes(37.5e9), "37.5 GB");
  assert.equal(fmtBytes(627458048), "627 MB");
  assert.equal(fmtBytes(994e9), "994 GB");
  assert.equal(fmtBytes(34359738368, true), "32.0 GB"); // memory uses base 1024
  assert.equal(fmtBytes(830 * 1024 * 1024, true), "830 MB");
});

test("heatLevel: 0 when none, 1-4 by share of max", () => {
  assert.equal(heatLevel(0, 100), 0);
  assert.equal(heatLevel(5, 0), 0);
  assert.equal(heatLevel(1, 100), 1);
  assert.equal(heatLevel(25, 100), 1);
  assert.equal(heatLevel(26, 100), 2);
  assert.equal(heatLevel(75, 100), 3);
  assert.equal(heatLevel(76, 100), 4);
  assert.equal(heatLevel(100, 100), 4);
});

function days(n, lastDay) {
  const out = [];
  const [y, m, d] = lastDay.split("-").map(Number);
  for (let i = n - 1; i >= 0; i--) {
    const x = new Date(y, m - 1, d - i);
    out.push({ day: x.getFullYear() + "-" + String(x.getMonth() + 1).padStart(2, "0") + "-" + String(x.getDate()).padStart(2, "0"), tokens: i });
  }
  return out;
}

test("heatGrid: 6 weekly rows Mon..Sun, today in its weekday column, future null", () => {
  // Tuesday
  const g = heatGrid(days(42, "2026-10-20"));
  assert.equal(g.rows.length, 6);
  for (const r of g.rows) assert.equal(r.length, 7);
  const last = g.rows[5];
  assert.equal(last[1].day, "2026-10-20");
  assert.equal(last[0].day, "2026-10-19");
  assert.deepEqual(last.slice(2), [null, null, null, null, null]);
  assert.equal(g.rows[0][0].day, "2026-09-14"); // starts on Monday
  assert.equal(g.max, 36);
  assert.equal(g.rows[0][0].level, 4);
  assert.equal(last[1].level, 0);
});

test("heatGrid: Sunday today fills the last row; short input padded in front", () => {
  const g = heatGrid(days(42, "2026-10-25"));
  assert.equal(g.rows.length, 6);
  assert.equal(g.rows[5][6].day, "2026-10-25");
  const s = heatGrid(days(3, "2026-10-21")); // Wednesday, only 3 days
  assert.equal(s.rows.length, 1);
  assert.deepEqual(s.rows[0].map((c) => c && c.day), ["2026-10-19", "2026-10-20", "2026-10-21", null, null, null, null]);
  assert.deepEqual(heatGrid([]), { rows: [], max: 0 });
});

test("meStats formats orcaStats, null when missing", () => {
  assert.equal(meStats({}), null);
  const m = meStats({ orcaStats: { agents: 7, agentTimeMs: 7200000, usage: { todayTokens: 20000, totalTokens: 3e9, costUsd: 5, unpricedTokens: 0, activeDays: 4, peakDay: { day: "2026-09-09", tokens: 1e9 }, days: [], byModel: [] } } });
  assert.equal(m.agents, 7);
  assert.deepEqual(m.hours, { n: "2", unit: "小时" });
  assert.equal(m.today, "2.0 万");
  assert.equal(m.total, "30.00 亿");
  assert.equal(m.peak.tokens, "10.00 亿");
  assert.equal(m.costNote, "");
  assert.equal(meStats({ orcaStats: { agents: 1 } }).today, "—");
  assert.equal(shortDay("2026-09-09"), "9月9日");
});

test("monitor thresholds", () => {
  assert.deepEqual(pressureInfo("normal"), { text: "正常", cls: "ok" });
  assert.equal(pressureInfo("warn").cls, "warn");
  assert.equal(pressureInfo("critical").cls, "bad");
  assert.equal(pressureInfo(null).cls, "na");
  assert.equal(diskInfo({ free: DISK_WARN + 1 }).cls, "ok");
  assert.equal(diskInfo({ free: DISK_WARN - 1 }).cls, "warn");
  assert.equal(diskInfo({ free: DISK_BAD - 1 }).cls, "bad");
  assert.equal(diskInfo(null).cls, "na");
  assert.equal(loadInfo([5, 4, 3], 10).cls, "ok");
  assert.equal(loadInfo([15, 4, 3], 10).cls, "warn");
  assert.equal(loadInfo([262.7, 185.4, 122.7], 10).text, "263 / 185 / 123");
  assert.equal(loadInfo([262.7, 185.4, 122.7], 10).cls, "bad");
  assert.equal(loadInfo(null, 10).cls, "na");
  assert.equal(swapInfo({ total: 0, used: 0 }).text, "未使用");
  assert.equal(swapInfo({ total: 4e9, used: 3.5e9 }).cls, "bad");
  assert.equal(batteryInfo({ pct: 80, charging: false, ac: true }).text, "80% · 已接电源");
  assert.equal(batteryInfo({ pct: 15, charging: false, ac: false }).cls, "bad");
  assert.equal(batteryInfo(null).text, "无电池");
});

test("monitorStale after 30 s, freshText", () => {
  assert.equal(monitorStale(1000, 1030), "");
  assert.match(monitorStale(1000, 1031), /^数据截至 \d\d:\d\d$/);
  assert.equal(monitorStale(null, 1), "还没有监控数据");
  assert.equal(freshText(100, 103), "3 秒前");
  assert.equal(freshText(100, 400), "5 分钟前");
});

test("zoneBoard: per-zone counts, lead plate, tokens only when matched", () => {
  const snap = {
    zones: [{ code: "Web", name: "WEB", color: "#40B0A0", order: 2, lead: "Web-UI-refactor", taskboard: { size: 1 } },
      { code: "Docs", name: "Docs", color: "#E0A040", order: 1, lead: "Docs-Notes", taskboard: null }],
    sessions: [
      { id: "1", name: "Web-UI-refactor", zone: "Web", status: "busy" },
      { id: "2", name: "Web-b", zone: "Web", status: "waiting" },
      { id: "3", name: "Web-c", zone: "Web", status: "idle", unread: true },
      { id: "4", name: "Docs-x", zone: "Docs", status: "idle" },
    ],
    offduty: [{ name: "Web-z", zone: "Web" }],
    zoneTokens: { byZone: { Web: 5e8 }, unmatched: 1 },
  };
  const b = zoneBoard(snap);
  assert.deepEqual(b.map((z) => z.key), ["Docs", "Web"]); // an unassigned zone with nobody is not drawn
  const web = b[1];
  assert.equal(web.lead, "UI-refactor");
  assert.equal(web.leadOn, true);
  assert.deepEqual([web.onDuty, web.busy, web.waiting, web.unread, web.off], [3, 1, 1, 1, 1]);
  assert.equal(web.tokens, 5e8);
  assert.equal(web.taskboard, true);
  assert.equal(b[0].tokens, null);
  assert.equal(b[0].leadOn, false);
  assert.equal(b[0].taskboard, false);
  const withNone = zoneBoard({ ...snap, sessions: snap.sessions.concat([{ id: "9", name: "x", zone: null, status: "idle" }]) });
  assert.equal(withNone[withNone.length - 1].key, "_");
});

test("memInfo: used/total + compressed, color follows pressure", () => {
  const G = 1024 ** 3;
  const mem = { total: 32 * G, app: 12 * G, wired: 5 * G, compressed: 12.6 * G, cached: 1.2 * G, used: 29.6 * G };
  const m = memInfo(mem, "warn");
  assert.equal(m.text, "已用 29.6 / 32 GB · 压缩 12.6 GB（压缩偏高）");
  assert.equal(m.cls, "warn");
  assert.equal(m.cached.text, "1.2 GB");
  assert.equal(m.cached.cls, "na");
  assert.equal(memInfo(mem, "normal").cls, "ok");
  assert.equal(memInfo(mem, "critical").cls, "bad");
  assert.equal(memInfo(mem, null).cls, "na");
  const low = memInfo({ ...mem, compressed: 4 * G, used: 21 * G }, "normal");
  assert.equal(low.text, "已用 21 / 32 GB · 压缩 4 GB");
  assert.equal(memInfo(null, "warn").text, "—");
  assert.equal(memInfo(null, "warn").cls, "na");
  assert.equal(memInfo(null, "warn").cached.text, "—");
});

test("swapInfo with pressure: color from pressure, not ratio alone", () => {
  const s = { total: 6e9, used: 5e9 };
  assert.equal(swapInfo(s, "normal").cls, "ok");
  assert.equal(swapInfo(s, "warn").cls, "warn");
  assert.equal(swapInfo({ total: 6e9, used: 2e9 }, "warn").cls, "ok");
  assert.equal(swapInfo({ total: 6e9, used: 1e9 }, "critical").cls, "bad");
  assert.equal(swapInfo(s, "normal").text, swapInfo(s).text);
  assert.equal(swapInfo(s).cls, "bad"); // no pressure passed: plain rule
  assert.equal(swapInfo(null, "warn").cls, "na");
});
