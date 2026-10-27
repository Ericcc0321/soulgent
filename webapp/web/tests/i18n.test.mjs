// Three languages (en / hans Simplified / hant Traditional, Taiwan usage): language detection, lookup fallback, all three columns filled, scan for leftover Chinese in the UI, all keys exist in the table
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { detectLang, setLang, lang, t, tCode, table, LANGS, fmtMD, fmtYMD } from "../i18n.js";
import { chatRow, relTime, chatTime, chatStamp, offHeader, fmtTokens, failReason, quotaCaption, summaryText, waitingForText, profileView, KIND_LABEL, RECALL_ASK } from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const CJK = /[㐀-鿿豈-﫿　-〿！-～]/;

test("language detection: the first entry of navigator.languages wins", () => {
  for (const l of ["zh-TW", "zh-HK", "zh-MO", "zh-Hant", "zh-Hant-TW", "zh_TW", "ZH-tw"]) assert.equal(detectLang([l]), "hant", l);
  for (const l of ["zh", "zh-CN", "zh-SG", "zh-Hans", "zh-Hans-HK", "zh-Hans-CN"]) assert.equal(detectLang([l]), "hans", l);
  for (const l of ["en-US", "en", "ja-JP", "fr", "", undefined]) assert.equal(detectLang([l]), "en", String(l));
  assert.equal(detectLang([]), "en");
  assert.equal(detectLang(["en-US", "zh-TW"]), "en");
  assert.equal(detectLang(["zh-TW", "en-US"]), "hant");
  assert.equal(detectLang("zh-CN"), "hans");
});

test("setLang: the three known values are applied, anything else falls back to system detection (node is en-US)", () => {
  assert.equal(setLang("hant"), "hant");
  assert.equal(lang(), "hant");
  assert.equal(setLang("xx"), "en");
  setLang("hans");
});

test("t: placeholder substitution; missing key returns the key; tCode falls back when the table has no entry", () => {
  setLang("hans");
  assert.equal(t("send.partial", { n: 3 }), "已发到第 3 步后失败，请到 Orca 处理");
  assert.equal(t("no.such.key"), "no.such.key");
  assert.equal(tCode("fail.", "nope", "原文"), "原文");
  assert.equal(tCode("fail.", "session-gone", "x"), "会话已结束");
  setLang("en");
  assert.equal(t("send.partial", { n: 3 }), "Failed after step 3; handle it in Orca");
  setLang("hant");
  assert.equal(t("fail.session-gone"), "會話已結束");
  setLang("hans");
});

test("table: every key has text in all three columns (en / hans / hant); Traditional uses Taiwan wording (glossary: 会话 = 會話, 批准 = 核准)", () => {
  assert.deepEqual(LANGS, ["en", "hans", "hant"]);
  const T = table();
  assert.ok(Object.keys(T).length > 500);
  for (const [k, v] of Object.entries(T)) {
    assert.equal(v.length, 3, k);
    for (const x of v) assert.ok(typeof x === "string" && x.trim(), k);
    assert.ok(!/批准/.test(v[2]), "Traditional must use the Taiwan wording 核准: " + k);
    if (v[1].includes("会话")) assert.ok(v[2].includes("會話"), "Traditional uses 會話 for 会话: " + k);
  }
  // bottom tab bar
  const tab = (k) => T[k];
  assert.deepEqual(tab("tab.chat"), ["SoulChat", "SoulChat", "SoulChat"]);
  assert.deepEqual(tab("tab.agents"), ["Agents", "Agents", "Agents"]);
  assert.deepEqual(tab("tab.zones"), ["Dashboard", "看板", "看板"]);
  assert.deepEqual(tab("tab.me"), ["Me", "我", "我"]);
});

// ---------- leftover scan ----------
// Strip JS comments (strings, templates and regexes are kept; line numbers unchanged)
function stripJs(src) {
  let out = "", i = 0, last = "";
  const n = src.length, stack = [];
  const regexCtx = () => !last || /[(,=:\[!&|?{};+\-*%<>~^]$/.test(last) || /\b(return|typeof|case|in|of|delete|void|throw|new)$/.test(last);
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === "/" && d === "/") { while (i < n && src[i] !== "\n") i++; continue; }
    if (c === "/" && d === "*") { const e = src.indexOf("*/", i + 2); out += src.slice(i, e < 0 ? n : e + 2).replace(/[^\n]/g, ""); i = e < 0 ? n : e + 2; continue; }
    if (c === "'" || c === '"') { let j = i + 1; while (j < n && src[j] !== c) { if (src[j] === "\\") j++; j++; } out += src.slice(i, j + 1); i = j + 1; last = "s"; continue; }
    if (c === "`" || (c === "}" && stack.length && stack[stack.length - 1] === 0)) {
      if (c === "}") stack.pop();
      let j = i + 1;
      while (j < n && src[j] !== "`") { if (src[j] === "\\") { j += 2; continue; } if (src[j] === "$" && src[j + 1] === "{") { j += 2; stack.push(0); break; } j++; }
      if (src[j] === "`") { out += src.slice(i, j + 1); i = j + 1; last = "s"; continue; }
      out += src.slice(i, j); i = j; last = "("; continue;
    }
    if (c === "{" && stack.length) stack[stack.length - 1]++;
    if (c === "}" && stack.length) stack[stack.length - 1]--;
    if (c === "/" && regexCtx()) { let j = i + 1, cls = false; while (j < n && src[j] !== "\n") { if (src[j] === "\\") { j += 2; continue; } if (src[j] === "[") cls = true; else if (src[j] === "]") cls = false; else if (src[j] === "/" && !cls) break; j++; } j++; while (/[a-z]/.test(src[j] || "")) j++; out += src.slice(i, j); i = j; last = "s"; continue; }
    out += c;
    if (!/\s/.test(c)) last = (/[\w$]/.test(c) ? (last.match(/[\w$]*$/)?.[0] || "") + c : c).slice(-10);
    i++;
  }
  return out;
}
const JS = readdirSync(new URL("../", import.meta.url)).filter((f) => f.endsWith(".js"));

test("leftover scan: in web/*.js with comments stripped, Chinese (incl. full-width punctuation) may only appear in i18n.js", () => {
  assert.ok(JS.includes("app.js") && JS.includes("i18n.js"));
  const bad = [];
  for (const f of JS) {
    if (f === "i18n.js") continue;
    stripJs(rd(f)).split("\n").forEach((l, k) => { if (CJK.test(l)) bad.push(f + ":" + (k + 1) + " " + l.trim().slice(0, 80)); });
  }
  assert.deepEqual(bad, []);
});

// HTML: after stripping comments and <script>/<style>, text nodes and attribute values must contain no Chinese (English by default, swapped via data-i18n at startup)
function htmlVisible(src) {
  return src.replace(/<!--[\s\S]*?-->/g, "").replace(/<script[\s\S]*?<\/script>/g, "").replace(/<style[\s\S]*?<\/style>/g, "");
}
test("leftover scan: index.html / login.html text nodes and attributes have no Chinese; <html lang> defaults to en", () => {
  for (const f of ["index.html", "login.html"]) {
    const v = htmlVisible(rd(f));
    const bad = v.split("\n").filter((l) => CJK.test(l));
    assert.deepEqual(bad, [], f);
    assert.match(rd(f), /<html lang="en">/, f);
  }
});

function keysIn(src) {
  const ks = new Set();
  for (const m of src.matchAll(/data-i18n="([^"]+)"/g)) ks.add(m[1]);
  for (const m of src.matchAll(/data-i18n-attr="([^"]+)"/g)) for (const p of m[1].split(";")) ks.add(p.split(":")[1].trim());
  return ks;
}
test("data-i18n / data-i18n-attr keys all exist in the table (all three columns)", () => {
  const T = table();
  for (const f of ["index.html", "login.html"]) {
    const ks = keysIn(rd(f));
    assert.ok(ks.size > 5, f);
    for (const k of ks) assert.ok(T[k] && T[k].every((x) => x), f + " " + k);
  }
});

test("literal t(\"key\") calls in code all exist in the table; tCode prefixes have entries in the table", () => {
  const T = table();
  const miss = [];
  for (const f of ["app.js", "logic.js", "viewer.js"]) {
    const s = stripJs(rd(f));
    for (const m of s.matchAll(/(?<![\w$.])t\(\s*"([^"]+)"\s*[,)]/g)) if (!T[m[1]]) miss.push(f + " " + m[1]);
    for (const m of s.matchAll(/tCode\(\s*"([^"]+)"/g)) if (!Object.keys(T).some((k) => k.startsWith(m[1]))) miss.push(f + " tCode " + m[1]);
    for (const m of s.matchAll(/t\(\s*([a-z]+) \? "([^"]+)" : "([^"]+)"/g)) for (const k of [m[2], m[3]]) if (!T[k]) miss.push(f + " " + k);
  }
  for (const k of ["ctx.g.mcpTools", "ctx.g.agents", "ctx.g.memory", "ctx.g.skills"]) if (!T[k]) miss.push(k);
  for (const k of ["copy", "copysel", "select", "quote", "forward", "recall", "share", "download", "copypath"]) if (!T["bm." + k]) miss.push("bm." + k);
  for (const k of ["clock", "failed", "sent", "delivered", "read"]) { if (!T["rc." + k]) miss.push("rc." + k); if (!T["rcl." + k]) miss.push("rcl." + k); }
  assert.deepEqual(miss, []);
});

test("login.html imports /i18n.js directly (public through the gate), has no inline mini table; all keys it uses exist in the table", () => {
  const T = table();
  const src = rd("login.html");
  assert.match(src, /import\("\/i18n\.js"\)/);
  assert.doesNotMatch(src, /await import/); // no top-level await (older Safari fails to parse the whole script, leaving the login page hidden and unusable)
  assert.doesNotMatch(src, /var L = \{/);
  assert.match(src, /t\("login\.server", \{ n: res\.status \}\)/);
  const used = [...keysIn(src), ...[...src.matchAll(/\bt\("([^"]+)"/g)].map((m) => m[1])];
  assert.ok(used.includes("login.bad"));
  for (const k of used) assert.ok(k.startsWith("login.") && T[k], k);
});

test("sw precaches i18n.js; index.html preloads i18n.js", () => {
  assert.match(rd("sw.js"), /"\/i18n\.js"/);
  assert.match(rd("index.html"), /<link rel="modulepreload" href="\/i18n\.js">/);
});

test("Me page language switch: four options, saves zbs.lang then reloads; guests get it too", () => {
  const a = rd("app.js");
  assert.match(a, /meRow\("lang", t\("me.lang"\), langText\(\)\)/);
  assert.equal((a.match(/meRow\("lang"/g) || []).length, 2);
  assert.match(a, /else if \(k === "lang"\) openLangSheet\(\);[^\n]*\n\s*else if \(st\.guest/);
  assert.match(a, /saveLangPref\(p\);\s*location\.reload\(\);/);
  assert.match(rd("i18n.js"), /export const LANG_NAMES = \{ hans: "简体中文", hant: "繁體中文", en: "English" \};/);
});

// ---------- English / Traditional output (logic-layer spot checks) ----------
const NOW = Date.parse("2026-10-23T05:00:00Z") / 1000;
test("English: status words, times, tokens, failure reasons and quota text contain no Chinese", () => {
  setLang("en");
  const s = { id: "a", name: "W-x", zone: "W", status: "busy", helpers: 2, since: NOW - 300 };
  const r = chatRow(s, [{ code: "W", name: "Web", color: "#fff" }], NOW, "");
  assert.equal(r.tag.text, "Delegating (2)");
  assert.equal(chatRow({ ...s, status: "waiting", helpers: 0 }, [], NOW).tag.text, "[Waiting for you]");
  assert.equal(chatRow({ ...s, status: "idle", summary: "" }, [], NOW).text, "(No summary)");
  assert.equal(relTime(NOW - 10, NOW), "Just now");
  assert.equal(relTime(NOW - 7200, NOW), "2 h");
  assert.equal(offHeader(NOW - 7200, NOW), "Off duty · 2 h ago");
  assert.equal(fmtTokens(123456), "123K");
  assert.equal(fmtTokens(2.5e6), "2.5M");
  assert.equal(failReason("session-gone"), "Session has ended");
  assert.equal(failReason("zzz"), "Send failed");
  const d = new Date(2026, 9, 12, 13, 42);
  assert.equal(fmtMD(d), "Oct 12");
  assert.equal(fmtYMD(d), "Oct 12, 2025".replace("2025", "2026"));
  for (const x of [chatTime(NOW - 30, NOW), chatTime(NOW - 86400 * 3, NOW), chatStamp(NOW - 86400 * 40, NOW), quotaCaption({ pct: 8, resetsAt: NOW + 3500 }, "5H", NOW)]) assert.ok(!CJK.test(x), x);
  assert.equal(profileView({ name: "我" }).name, "Me"); // the server's default name is displayed per language
  assert.equal(KIND_LABEL.sheet, "Spreadsheet");
  assert.equal(RECALL_ASK.ok, "Interrupt and unsend"); // glossary: recall = Unsend
  setLang("hans");
});

test("Traditional: Taiwan wording spot checks; time format is the same as Simplified", () => {
  setLang("hant");
  assert.equal(chatRow({ id: "a", name: "x", status: "busy", agents: 0 }, [], NOW).tag.text, "正在工作");
  assert.equal(failReason("fail.network".slice(5)), "網路不通，請稍後再試");
  assert.equal(fmtTokens(123456), "12 萬");
  assert.equal(t("me.logout"), "登出");
  assert.equal(t("c.search"), "搜尋");
  setLang("hans");
  assert.equal(fmtTokens(123456), "12 万");
});

// ---------- summaryCode / waitingFor from the Mac-side --dump (docs/dump-summary-codes.md) ----------
test("summaryText: without a code the summary is shown as-is; for known codes the Simplified rendering matches the original summary verbatim", () => {
  setLang("hans");
  assert.equal(summaryText({ summary: "测试全部通过" }), "测试全部通过");
  const cases = [
    ["wait.ask", { question: "要不要先备份数据库？", count: 2 }, "问你：要不要先备份数据库？（共 2 个问题）"],
    ["wait.ask", { question: "先备份？", count: 1 }, "问你：先备份？"],
    ["wait.ask.generic", {}, "在等你回答问题"],
    ["wait.plan", {}, "计划写好了，等你批准"],
    ["wait.approve.run", { command: "Run the unit tests" }, "等你批准运行：Run the unit tests"],
    ["wait.approve.edit", { file: "config.yaml" }, "等你批准修改：config.yaml"],
    ["wait.approve.tool", { tool: "WebFetch" }, "等你批准使用 WebFetch"],
    ["wait.approve", {}, "等你批准"],
    ["wait.answer", { options: 3 }, "等你回答（3 个选项）"],
    ["wait.answer", { options: null }, "等你回答"],
    ["state.paused", {}, "已暂停"], ["state.stopped", {}, "已中止"], ["state.error", {}, "出错"],
    ["prompt.you", { text: "把按钮改成蓝色" }, "你：把按钮改成蓝色"],
    ["relay.agent", {}, "处理子代理回报…"], ["relay.peer", {}, "处理其他会话的消息…"],
    ["relay.from", { peer: "docs-writer" }, "处理 docs-writer 的回报…"],
  ];
  for (const [code, args, want] of cases) assert.equal(summaryText({ summary: want, summaryCode: code, summaryArgs: args }), want, code);
  // The final format only has text (args.kind distinguishes reply / progress / recap / raw); draft codes like reply are not recognized and fall back to summary
  for (const kind of ["reply", "progress", "recap", "raw"]) assert.equal(summaryText({ summary: "原文", summaryCode: "text", summaryArgs: { text: "原文 A", kind } }), "原文 A");
  for (const code of ["reply", "progress", "recap"]) assert.equal(summaryText({ summary: "原文", summaryCode: code, summaryArgs: { text: "原文 A" } }), "原文");
  assert.equal(summaryText({ summary: "", summaryCode: "none", summaryArgs: {} }), "");
  assert.equal(summaryText({ summary: "旧看板原文", summaryCode: "future.code", summaryArgs: {} }), "旧看板原文");
  // file null / "" render the same; intentionally differs from the dashboard original, so it is not in the verbatim-match list
  for (const file of [null, ""]) assert.equal(summaryText({ summary: "x", summaryCode: "wait.approve.edit", summaryArgs: { file } }), "等你批准修改文件");
  setLang("en");
  assert.equal(summaryText({ summary: "x", summaryCode: "wait.approve.run", summaryArgs: { command: "ls" } }), "Approve to run: ls");
  assert.equal(summaryText({ summary: "x", summaryCode: "wait.approve.edit", summaryArgs: {} }), "Approve a file edit");
  setLang("hant");
  assert.equal(summaryText({ summary: "x", summaryCode: "relay.peer", summaryArgs: {} }), "處理其他會話的訊息…");
  setLang("hans");
});

test("waitingFor: known English machine values are translated per language, unknown ones kept as-is; list rows show summary first, then waitingFor", () => {
  setLang("hans");
  assert.equal(waitingForText("permission prompt"), "等你批准");
  assert.equal(waitingForText("input needed"), "等你回答");
  assert.equal(waitingForText("x"), "x");
  assert.equal(waitingForText(""), "");
  assert.equal(chatRow({ id: "a", name: "n", status: "waiting", waitingFor: "permission prompt", summary: "" }, [], NOW).text, "等你批准");
  assert.equal(chatRow({ id: "a", name: "n", status: "waiting", waitingFor: "permission prompt", summary: "问你：要吗？" }, [], NOW).text, "问你：要吗？");
  assert.doesNotMatch(rd("app.js"), /s\.waitingFor \|\| s\.summary/);
  setLang("en");
  assert.equal(waitingForText("permission request"), "Needs permission");
  setLang("hans");
});

test("every meRow on the Me page has an icon (a missing icon breaks the whole page)", () => {
  const a = rd("app.js");
  const ic = a.slice(a.indexOf("const ME_IC = {"), a.indexOf("function meIcon("));
  const keys = new Set([...a.matchAll(/meRow\("([a-z]+)"/g)].map((m) => m[1]));
  assert.ok(keys.has("lang"));
  for (const k of keys) assert.match(ic, new RegExp("\\n  " + k + ": \\["), k);
});

test("anti-flash: data-i18n text is hidden until switched to the current language; applyI18n / login inline script set a marker when done", () => {
  assert.match(rd("index.html"), /html:not\(\[data-i18n-done\]\) \[data-i18n\]\{visibility:hidden\}/);
  assert.match(rd("login.html"), /html:not\(\[data-i18n-done\]\) \[data-i18n\] \{ visibility: hidden; \}/);
  assert.match(rd("login.html"), /setAttribute\("data-i18n-done", "1"\)/);
  assert.match(rd("i18n.js"), /setAttribute\("data-i18n-done", "1"\)/);
});
