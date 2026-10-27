import test from "node:test";
import assert from "node:assert/strict";
import { ctxRows, ctxAgeText, failReason, ctxBreakdown, ctxSegOf } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const DATA = {
  model: "claude-fable-5-1", used: 191200, window: 1000000, pct: 19,
  categories: [
    { name: "System prompt", tokens: 6000, pct: 0.6 },
    { name: "Free space", tokens: 805800, pct: 80.6 },
    { name: "MCP tools", tokens: 649, pct: 0.0 },
    { name: "Messages", tokens: 169100, pct: 16.9 },
    { name: "Compact buffer", tokens: 1200, pct: null },
  ],
  details: {
    mcpTools: [{ name: "mcp__netbox__get", server: "netbox", tokens: 2000, label: "2k" }],
    agents: [],
    memory: [{ name: "/Users/x/.claude/CLAUDE.md", type: "User", tokens: 2600, label: "2.6k" }],
    skills: [{ name: "handoff", source: "User", tokens: 50, label: "~50" }, { name: "x", source: "Plugin", tokens: 20 }],
  },
};

test("ctxRows: keeps the original order, Free space moves to the end and is gray", () => {
  const r = ctxRows(DATA);
  assert.deepEqual(r.rows.map((x) => x.name), ["System prompt", "MCP tools", "Messages", "Compact buffer", "Free space"]);
  const last = r.rows[r.rows.length - 1];
  assert.equal(last.free, true);
  assert.equal(last.color, "free");
  assert.equal(r.rows[0].color, "c0");
  assert.equal(r.rows[2].color, "c2");
  assert.equal(r.rows[0].text, "6k");
  assert.equal(r.rows[1].text, "649");
  assert.equal(r.rows[1].pctText, "0.0%");
  assert.equal(r.rows[3].pct, 0.12); // missing pct is computed from the window
  assert.equal(r.rows[4].w, 80.6);
  assert.equal(r.head, "191k / 1M · 19%");
  assert.equal(r.model, "claude-fable-5-1");
});

test("ctxRows: detail groups, empty groups omitted, memory files show only the file name", () => {
  const g = ctxRows(DATA).groups;
  assert.deepEqual(g.map((x) => x.title), ["MCP 工具", "记忆文件", "技能"]);
  assert.deepEqual(g[1].items[0], { name: "CLAUDE.md", sub: "User · /Users/x/.claude/CLAUDE.md", text: "2.6k" });
  assert.equal(g[2].count, 2);
  assert.equal(g[2].sumText, "70");
  assert.equal(g[2].items[0].text, "~50");
  assert.equal(g[2].items[1].text, "20");
  assert.equal(g[0].items[0].sub, "netbox");
});

test("ctxRows: bad data does not blow up", () => {
  assert.deepEqual(ctxRows(null), { model: "", head: "", rows: [], groups: [] });
  assert.deepEqual(ctxRows({ categories: [null, { name: 3 }], details: { skills: "x" } }).rows, []);
});

test("ctxAgeText / failure text", () => {
  assert.equal(ctxAgeText(100, 112), "明细 12 秒前");
  assert.equal(ctxAgeText(null, 112), "");
  assert.equal(failReason("context-timeout"), "读取明细超时");
  assert.equal(failReason("cwd-missing"), "会话的启动目录已不存在");
});

// ---------- segmented bar / legend / merged "other" ----------
const REAL = {
  model: "claude-opus-4-7[1m]", used: 337000, window: 1000000, pct: 34,
  categories: [
    { name: "System prompt", tokens: 6000, pct: 0.6 }, { name: "System tools", tokens: 4000, pct: 0.4 },
    { name: "MCP tools", tokens: 647, pct: 0.06 }, { name: "MCP server instructions", tokens: 717, pct: 0.07 },
    { name: "MCP tools (deferred)", tokens: 5000, pct: 0.5 }, { name: "System tools (deferred)", tokens: 13000, pct: 1.3 },
    { name: "Custom agents", tokens: 85, pct: 0.01 }, { name: "Memory files", tokens: 3000, pct: 0.3 },
    { name: "Skills", tokens: 9000, pct: 0.9 }, { name: "Messages", tokens: 315000, pct: 31.5 },
    { name: "Compact buffer", tokens: 3000, pct: 0.3 }, { name: "Free space", tokens: 660000, pct: 66 },
  ],
};

test("ctxSegOf: Messages orange / system and tools gray-blue / other", () => {
  assert.equal(ctxSegOf("Messages"), "msg");
  for (const n of ["System prompt", "System tools", "System tools (deferred)", "MCP tools", "MCP tools (deferred)", "MCP server instructions"]) assert.equal(ctxSegOf(n), "sys", n);
  for (const n of ["Skills", "Memory files", "Custom agents", "Compact buffer"]) assert.equal(ctxSegOf(n), "oth", n);
  assert.equal(ctxSegOf("Free space"), "free");
});

test("ctxBreakdown: the four segment ratios are based on the total window, Free = window - used; the legend lists only >=1%, the rest merged into \"other\"", () => {
  const b = ctxBreakdown(REAL);
  assert.deepEqual(b.segs.map((x) => x.k), ["msg", "sys", "oth", "free"]);
  assert.equal(b.segs[0].tokens, 315000);
  assert.equal(b.segs[1].tokens, 6000 + 4000 + 647 + 717 + 5000 + 13000);
  assert.equal(b.segs[2].tokens, 85 + 3000 + 9000 + 3000);
  assert.equal(b.segs[3].tokens, 663000); // 1M - 337k
  assert.ok(Math.abs(b.segs.reduce((a, x) => a + x.w, 0) - 100) < 0.01);
  assert.deepEqual(b.big.map((r) => r.name).sort(), ["Free space", "Messages", "System tools (deferred)"]);
  assert.equal(b.small.length, 9);
  assert.equal(b.smallTitle, "其他（9 项）");
  assert.equal(b.smallText, "31k · 3.1%");
});

test("ctxBreakdown: only a total (no categories) -> used / Free two segments; no window -> empty", () => {
  const b = ctxBreakdown({ used: 337000, window: 1000000 });
  assert.deepEqual(b.segs.map((x) => x.k), ["used", "free"]);
  assert.equal(Math.round(b.segs[0].w), 34);
  assert.equal(b.big.length, 0);
  assert.deepEqual(ctxBreakdown(null).segs, []);
});
