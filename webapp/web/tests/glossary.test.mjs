// Three-language glossary: the Traditional Chinese and English columns of i18n.js must not contain rejected wordings.
// Only the text values are checked (keys containing e.g. "recall" do not count). Keep this in sync with the glossary.
import { test } from "node:test";
import assert from "node:assert/strict";
import { table } from "../i18n.js";

const T = table();
const rows = Object.entries(T);

// Traditional Chinese: rejected wordings (the right side is what the glossary prescribes)
const HANT_BANNED = [
  ["置頂", "釘選"], ["撤回", "收回"], ["派活", "派工"], ["工區", "工作區"], ["免打擾", "勿擾"],
  ["頭像", "大頭貼"], ["昵稱", "暱稱"], ["昵称", "暱稱"], ["在班", "值班"], ["已看過", "標為已看"],
  ["已登錄", "已登入"], ["登錄", "登入"], ["批准", "核准"], ["工作階段", "會話"],
];
// English: rejected wordings
const EN_BANNED = [
  [/\brecall/i, "Unsend"], [/pin(ned)? to top/i, "Pin"], [/clock(ed|ing)?[- ]?out/i, "Off duty"],
];

test("glossary: Traditional Chinese column has no rejected wordings", () => {
  const bad = [];
  for (const [k, [, , ht]] of rows) for (const [w, ok] of HANT_BANNED) if ((ht || "").includes(w)) bad.push(`${k}: 「${w}」→「${ok}」 ${ht}`);
  assert.deepEqual(bad, []);
});

test("glossary: English column has no rejected wordings", () => {
  const bad = [];
  for (const [k, [en]] of rows) for (const [re, ok] of EN_BANNED) if (re.test(en || "")) bad.push(`${k}: ${re} → ${ok} | ${en}`);
  assert.deepEqual(bad, []);
});

test("glossary: key entries match the glossary", () => {
  const col = (k) => T[k] || [];
  assert.deepEqual(col("bm.recall"), ["Unsend", "撤回", "收回"]);
  assert.equal(col("act.top")[0], "Pin");
  assert.equal(col("act.top")[2], "釘選");
  assert.equal(col("act.mute")[0], "Mute");
  assert.equal(col("pf.name")[0], "Nickname");
  assert.equal(col("pf.name")[2], "暱稱");
  assert.equal(col("pf.change")[2], "更換大頭貼");
  assert.equal(col("zb.on")[0], "On duty");
  assert.equal(col("zb.on")[2], "值班");
  assert.equal(col("off.head")[0], "Off duty");
  assert.equal(col("me.devices")[0], "Signed-in devices");
  assert.equal(col("me.devices")[2], "已登入裝置");
  assert.equal(col("dm.seen")[0], "Mark as seen");
  assert.equal(col("dm.seen")[2], "標為已看");
  assert.match(col("row.agents")[0], /^Delegating/);
  assert.match(col("row.agents")[2], /派工/);
  assert.deepEqual(col("head.agents"), ["SA {n}", "SA {n}", "SA {n}"]); // SA/BG are not translated in any language
  assert.deepEqual(col("tab.zones"), ["Dashboard", "看板", "看板"]);
  assert.equal(col("html.paneZones")[0], "Zones");
  assert.equal(col("html.paneZones")[2], "工作區");
  assert.equal(col("appr.approve")[2], "核准");
  assert.equal(col("list.restN")[0], "{n} resting");
});

// "reply later" is the label for the dashboard pinned feature; "pin to top" (top.json) is a separate feature
test("glossary: \"reply later\" (pinned feature) in all three languages, rejected wording absent; pin-to-top separate", () => {
  const PINNED_KEYS = ["svg.pinned", "ct.pinned", "toast.pinOrder"];
  assert.deepEqual(T["svg.pinned"], ["Reply later", "稍后回复", "稍後回覆"]);
  assert.deepEqual(T["ct.pinned"], ["Reply later", "稍后回复", "稍後回覆"]);
  for (const k of PINNED_KEYS) {
    const [en, hs, ht] = T[k];
    assert.ok(!/钉住/.test(hs) && !/釘選/.test(ht) && !/Pin|pinned/i.test(en), k);
  }
  assert.deepEqual(T["act.top"], ["Pin", "置顶", "釘選"]);
  assert.deepEqual(T["act.untop"], ["Unpin", "取消置顶", "取消釘選"]);
  assert.ok(!rows.some(([, [en, hs, ht]]) => /钉住/.test(hs || "") || /Pin until replied/.test(en || "") || /釘選待回覆/.test(ht || "")));
});
// The bottom bar and page title have fixed Chinese labels and are called "Dashboard" in English (rejected wording must not appear)
test("glossary: bottom bar in three languages, en = SoulChat/Agents/Dashboard/Me, zh = SoulChat/Agents/看板/我; rejected wording absent", () => {
  const bar = (i) => ["tab.chat", "tab.agents", "tab.zones", "tab.me"].map((k) => T[k][i]);
  assert.deepEqual(bar(0), ["SoulChat", "Agents", "Dashboard", "Me"]);
  assert.deepEqual(bar(1), ["SoulChat", "Agents", "看板", "我"]);
  assert.deepEqual(bar(2), ["SoulChat", "Agents", "看板", "我"]);
  assert.ok(!rows.some(([, v]) => v.some((x) => /灵域|靈域/.test(x || ""))));
});
