import test from "node:test";
import assert from "node:assert/strict";
import { meterLevel, quotaRings, fmtCtx, agoText, metaView, ctxPanel, META_STALE_SEC } from "../logic.js";

test("meterLevel: <60 grey / 60-79 yellow / >=80 red; missing value counts as grey", () => {
  assert.equal(meterLevel(0), "n");
  assert.equal(meterLevel(59), "n");
  assert.equal(meterLevel(60), "w");
  assert.equal(meterLevel(79), "w");
  assert.equal(meterLevel(80), "d");
  assert.equal(meterLevel(100), "d");
  assert.equal(meterLevel(null), "n");
  assert.equal(meterLevel(undefined), "n");
  assert.equal(meterLevel("x"), "n");
});

test("quotaRings: 5H / 7D, missing entries skipped, clamped to 0-100", () => {
  assert.deepEqual(quotaRings({ fiveHour: { pct: 3 }, sevenDay: { pct: 59.6 } }),
    [{ label: "5H", pct: 3, lv: "n" }, { label: "7D", pct: 60, lv: "w" }]);
  assert.deepEqual(quotaRings({ sevenDay: { pct: 120 } }), [{ label: "7D", pct: 100, lv: "d" }]);
  assert.deepEqual(quotaRings(null), []);
  assert.deepEqual(quotaRings({ fiveHour: { pct: null } }), []);
});

test("fmtCtx / agoText", () => {
  assert.equal(fmtCtx(414432), "414k");
  assert.equal(fmtCtx(1000000), "1M");
  assert.equal(fmtCtx(1500000), "1.5M");
  assert.equal(fmtCtx(200000), "200k");
  assert.equal(fmtCtx(512), "512");
  assert.equal(agoText(12), "12 秒前");
  assert.equal(agoText(185), "3 分钟前");
  assert.equal(agoText(7300), "2 小时前");
});

test("metaView: model line, context ring, t/s, tooltip", () => {
  const meta = { model: "Opus 5.5", effort: "XHigh", fast: false, ctxPct: 41, ctxUsed: 414432, ctxWindow: 1000000, tps: 60.8, at: 1000 };
  assert.deepEqual(metaView(meta, 1012), {
    line: "Opus 5.5 · xhigh",
    ring: { pct: 41, lv: "n", cl: "ok", stale: false, tip: "上下文 414k / 1M · 61 t/s · 数据 12 秒前" },
    tps: "61 t/s",
  });
  assert.equal(metaView({ ...meta, fast: true }, 1012).line, "Opus 5.5 ⚡ · xhigh");
  assert.equal(metaView({ ...meta, effort: null }, 1012).line, "Opus 5.5");
  assert.equal(metaView({ ...meta, ctxPct: 85 }, 1012).ring.lv, "d");
  assert.equal(metaView({ ...meta, ctxPct: 65 }, 1012).ring.lv, "w");
});

test("metaView: stale data turns grey, missing fields degrade", () => {
  const meta = { model: "Opus 5.5", ctxPct: 85, ctxUsed: 850000, ctxWindow: 1000000, tps: null, at: 1000 };
  const old = metaView(meta, 1000 + META_STALE_SEC + 1);
  assert.equal(old.ring.stale, true);
  assert.equal(old.ring.lv, "n");
  assert.equal(old.tps, "");
  assert.equal(old.ring.tip, "上下文 850k / 1M · 数据 5 分钟前");
  assert.equal(metaView(meta, 1000 + META_STALE_SEC).ring.stale, false);
  assert.equal(metaView({ ctxPct: 10 }, 5).line, null); // no model: the page falls back to "zone · project"
  assert.equal(metaView({ ctxPct: 10 }, 5).ring.stale, true); // no timestamp counts as stale
  assert.equal(metaView({ model: "Opus" }, 5).ring, null);
  assert.equal(metaView(null, 5), null);
});

test("ctxPanel: with data -> percent, level, usage / window, t/s, data age", () => {
  const meta = { ctxPct: 61.4, ctxUsed: 120000, ctxWindow: 200000, tps: 42.2, at: 1000 };
  const p = ctxPanel(meta, 1030);
  assert.equal(p.has, true);
  assert.equal(p.pct, 61);
  assert.equal(p.lv, "w");
  assert.equal(p.stale, false);
  assert.equal(p.used, "120k");
  assert.equal(p.window, "200k");
  assert.equal(p.usage, "上下文 120k / 200k");
  assert.equal(p.tps, "42 t/s");
  assert.equal(p.ageText, "数据 30 秒前");
  assert.equal(ctxPanel({ ctxPct: 30, at: 1000 }, 1000).usage, "上下文 30%"); // no used value: show the percentage
});

test("ctxPanel: no data -> has=false and the \"no context data\" text", () => {
  for (const m of [null, undefined, {}, { model: "Opus", tps: 50, at: 1 }]) {
    const p = ctxPanel(m, 5);
    assert.equal(p.has, false);
    assert.equal(p.usage, "没有上下文数据");
    assert.equal(p.pct, 0);
    assert.equal(p.ageText, "");
  }
});

test("ctxPanel: expired -> stale, color turns grey, age is still shown", () => {
  const p = ctxPanel({ ctxPct: 90, at: 1000 }, 1000 + META_STALE_SEC + 60);
  assert.equal(p.has, true);
  assert.equal(p.stale, true);
  assert.equal(p.lv, "n");
  assert.equal(p.ageText, "数据 6 分钟前");
  assert.equal(ctxPanel({ ctxPct: 90 }, 5).ageText, "数据时间不明");
});

import { ctxLevel, CTX_WARN, CTX_BAD } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese
test("ctxLevel: <50 ok / 50-69 warn / >=70 bad; ctxPanel/metaView carry cl, stale turns grey n", () => {
  assert.equal(CTX_WARN, 50); assert.equal(CTX_BAD, 70);
  assert.equal(ctxLevel(0), "ok"); assert.equal(ctxLevel(49), "ok");
  assert.equal(ctxLevel(50), "warn"); assert.equal(ctxLevel(69), "warn");
  assert.equal(ctxLevel(70), "bad"); assert.equal(ctxLevel(100), "bad");
  assert.equal(ctxLevel(null), "ok");
  const now = 1000;
  assert.equal(ctxPanel({ ctxPct: 55, at: now }, now).cl, "warn");
  assert.equal(ctxPanel({ ctxPct: 75, at: now }, now).cl, "bad");
  assert.equal(ctxPanel({ ctxPct: 55, at: now - 99999 }, now).cl, "n");
});
