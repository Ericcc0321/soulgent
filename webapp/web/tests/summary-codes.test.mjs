// Session status text is rendered per summaryCode in three languages; nameUntitled shows the localized "untitled" label.
// The code table follows the host-side --dump summaryCode table (17 entries). All fixtures are fictional.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { summaryText, chatRow, bannerText, plateOf, chatSearch, speakerDir } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans");

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const NOW = 1792750000;

// [code, args, board summary (Simplified, verbatim), Traditional, English]
const CASES = [
  ["wait.ask", { question: "要不要先备份数据库？", count: 1 }, "问你：要不要先备份数据库？", "問你：要不要先备份数据库？", "Asks: 要不要先备份数据库？"],
  ["wait.ask", { question: "Deploy now?", count: 3 }, "问你：Deploy now?（共 3 个问题）", "問你：Deploy now?（共 3 個問題）", "Asks: Deploy now? (3 questions)"],
  ["wait.ask", { question: "", count: 1 }, "问你：", "問你：", "Asks: "],
  ["wait.ask.generic", {}, "在等你回答问题", "在等你回答問題", "Has a question for you"],
  ["wait.plan", {}, "计划写好了，等你批准", "計畫寫好了，等你核准", "Plan ready for approval"],
  ["wait.approve.run", { command: "npm test -- --watch=false" }, "等你批准运行：npm test -- --watch=false", "等你核准執行：npm test -- --watch=false", "Approve to run: npm test -- --watch=false"],
  ["wait.approve.edit", { file: "src/demo/config.yaml" }, "等你批准修改：src/demo/config.yaml", "等你核准修改：src/demo/config.yaml", "Approve edit: src/demo/config.yaml"],
  ["wait.approve.edit", { file: "" }, "等你批准修改文件", "等你核准修改檔案", "Approve a file edit"], // file "" and null render the same way, without a trailing colon
  ["wait.approve.edit", { file: null }, "等你批准修改文件", "等你核准修改檔案", "Approve a file edit"],
  ["wait.approve.tool", { tool: "WebFetch" }, "等你批准使用 WebFetch", "等你核准使用 WebFetch", "Approve tool: WebFetch"],
  ["wait.approve", {}, "等你批准", "等你核准", "Needs approval"],
  ["wait.answer", { options: 3 }, "等你回答（3 个选项）", "等你回答（3 個選項）", "Needs your answer (3 options)"],
  ["wait.answer", { options: 1 }, "等你回答（1 个选项）", "等你回答（1 個選項）", "Needs your answer (1 option)"],
  ["wait.answer", { options: null }, "等你回答", "等你回答", "Needs your answer"],
  ["state.paused", {}, "已暂停", "已暫停", "Paused"],
  ["state.stopped", {}, "已中止", "已中止", "Stopped"],
  ["state.error", {}, "出错", "出錯", "Error"],
  ["prompt.you", { text: "把按钮改成蓝色" }, "你：把按钮改成蓝色", "你：把按钮改成蓝色", "You: 把按钮改成蓝色"],
  ["relay.agent", {}, "处理子代理回报…", "處理子代理回報…", "Handling a subagent report…"],
  ["relay.peer", {}, "处理其他会话的消息…", "處理其他會話的訊息…", "Handling a message from another session…"],
  ["relay.from", { peer: "Demo-docs" }, "处理 Demo-docs 的回报…", "處理 Demo-docs 的回報…", "Handling Demo-docs's report…"],
  ["text", { text: "README 的安装步骤补好了，共 4 步。", kind: "reply" }, "README 的安装步骤补好了，共 4 步。", "README 的安装步骤补好了，共 4 步。", "README 的安装步骤补好了，共 4 步。"],
  ["text", { text: "正在跑测试", kind: "progress" }, "正在跑测试", "正在跑测试", "正在跑测试"],
  ["text", { text: "上次做到第 3 步", kind: "recap" }, "上次做到第 3 步", "上次做到第 3 步", "上次做到第 3 步"],
  ["text", { text: "Some raw line", kind: "raw" }, "Some raw line", "Some raw line", "Some raw line"],
  ["none", {}, "", "", ""],
];

test("summaryText: all 17 codes covered; Simplified matches the board summary verbatim; Traditional / English follow templates", () => {
  const codes = new Set(CASES.map((c) => c[0]));
  assert.equal(codes.size, 17);
  for (const [code, args, hans, hant, en] of CASES) {
    // For wait.approve.edit with file "" / null the output intentionally differs from the board's original summary (trailing colon), so it is excluded from the verbatim check; the summary field holds the board original while the assertion expects the final wording
    const boardDiff = code === "wait.approve.edit" && (args.file === "" || args.file === null);
    const s = { summary: boardDiff ? "等你批准修改：" + (args.file === null ? "文件" : "") : hans, summaryCode: code, summaryArgs: JSON.parse(JSON.stringify(args)) };
    setLang("hans"); assert.equal(summaryText(s), hans, "hans " + code + JSON.stringify(args));
    setLang("hant"); assert.equal(summaryText(s), hant, "hant " + code + JSON.stringify(args));
    setLang("en"); assert.equal(summaryText(s), en, "en " + code + JSON.stringify(args));
  }
  setLang("hans");
});

test("summaryText fallback: no code / unknown code / missing required args -> original summary", () => {
  setLang("en");
  assert.equal(summaryText({ summary: "旧看板原文" }), "旧看板原文");
  assert.equal(summaryText({ summary: "旧看板原文", summaryCode: "future.code", summaryArgs: {} }), "旧看板原文");
  assert.equal(summaryText({ summary: "等你批准运行：ls", summaryCode: "wait.approve.run", summaryArgs: {} }), "等你批准运行：ls");
  assert.equal(summaryText({ summary: "问你：x", summaryCode: "wait.ask" }), "问你：x");
  assert.equal(summaryText({ summary: "原文", summaryCode: "text", summaryArgs: { kind: "reply" } }), "原文");
  assert.equal(summaryText({ summary: "原文", summaryCode: "reply", summaryArgs: { text: "x" } }), "原文"); // the draft code is not recognized
  assert.equal(summaryText(null), "");
  // args are not truncated: long commands go to the display as-is, clipped by row width (CSS ellipsis)
  const long = "x".repeat(300);
  assert.equal(summaryText({ summary: "", summaryCode: "wait.approve.run", summaryArgs: { command: long } }), "Approve to run: " + long);
  setLang("hans");
});

test("list row / banner: go through summaryText; none shows an empty summary; waitingFor comes after the summary", () => {
  setLang("en");
  const w = (code, args, wf) => ({ id: "w", name: "Demo-a", status: "waiting", summary: "中文原文", summaryCode: code, summaryArgs: args, waitingFor: wf || "", nameUntitled: false });
  assert.equal(chatRow(w("wait.approve.run", { command: "make" }, "permission prompt"), [], NOW).text, "Approve to run: make");
  assert.equal(chatRow(w("none", {}, "permission prompt"), [], NOW).text, "Needs permission");
  assert.equal(chatRow(w("none", {}, ""), [], NOW).text.length > 0, true);
  assert.equal(bannerText(w("wait.approve.edit", { file: "" }), "wait").body, "[Waiting for you] Approve a file edit");
  assert.equal(bannerText(w("wait.approve.edit", { file: null }), "wait").body, "[Waiting for you] Approve a file edit");
  const idle = { id: "d", name: "Demo-b", status: "idle", summary: "", summaryCode: "none", summaryArgs: {} };
  setLang("hans");
  assert.equal(chatRow(idle, [], NOW).text, chatRow({ id: "d", name: "Demo-b", status: "idle", summary: "" }, [], NOW).text);
});

test("nameUntitled: true shows the localized untitled label; false keeps the original name", () => {
  const s = { id: "u", name: "未命名", plate: "未命名", zone: "", status: "idle", summary: "", nameUntitled: true };
  setLang("en"); assert.equal(plateOf(s), "Untitled"); assert.equal(chatRow(s, [], NOW).plate, "Untitled");
  assert.match(bannerText({ ...s, status: "waiting" }, "wait").title, /Untitled/);
  setLang("hant"); assert.equal(plateOf(s), "未命名");
  setLang("hans"); assert.equal(plateOf(s), "未命名");
  setLang("en");
  assert.equal(plateOf({ ...s, nameUntitled: false }), "未命名"); // a user-chosen name that happens to read "untitled" is not translated
  const dir = speakerDir({ sessions: [s], zones: [] }, false);
  assert.equal(dir.get("未命名").plate, "Untitled");
  setLang("hans");
});

test("search: the summary group matches both the displayed text and the original", () => {
  setLang("en");
  const snap = { zones: [], sessions: [{ id: "a", name: "Demo-a", status: "waiting", summary: "等你批准运行：make", summaryCode: "wait.approve.run", summaryArgs: { command: "make" } }] };
  assert.equal(chatSearch(snap, "approve").bySummary.length, 1);
  assert.equal(chatSearch(snap, "批准").bySummary.length, 1);
  setLang("hans");
});

test("display sites: session names go through plateOf, summaries through summaryText", () => {
  const app = rd("app.js");
  assert.doesNotMatch(app, /s\.plate \|\| s\.name/);
  assert.doesNotMatch(app, /snippetOf\(s\.summary/);
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
