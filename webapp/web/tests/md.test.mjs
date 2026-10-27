import test from "node:test";
import assert from "node:assert/strict";
import { parseMarkdown } from "../md.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const T = (text) => ({ t: "text", text });
const para = (...c) => ({ type: "para", c });

test("headings levels 1-6; 7 # is not a heading", () => {
  for (let n = 1; n <= 6; n++) {
    assert.deepEqual(parseMarkdown("#".repeat(n) + " 标题"), [{ type: "heading", level: n, c: [T("标题")] }]);
  }
  assert.equal(parseMarkdown("####### x")[0].type, "para");
  assert.equal(parseMarkdown("#没空格")[0].type, "para");
  assert.deepEqual(parseMarkdown("## 带尾巴 ##"), [{ type: "heading", level: 2, c: [T("带尾巴")] }]);
});

test("paragraphs: blank line splits, single newline becomes br", () => {
  assert.deepEqual(parseMarkdown("a\nb\n\nc"), [para(T("a"), { t: "br" }, T("b")), para(T("c"))]);
});

test("bold / italic / strikethrough", () => {
  assert.deepEqual(parseMarkdown("**粗** __粗2__ *斜* _斜2_ ~~删~~")[0].c, [
    { t: "strong", c: [T("粗")] }, T(" "), { t: "strong", c: [T("粗2")] }, T(" "),
    { t: "em", c: [T("斜")] }, T(" "), { t: "em", c: [T("斜2")] }, T(" "), { t: "del", c: [T("删")] },
  ]);
  assert.deepEqual(parseMarkdown("***both***")[0].c, [{ t: "em", c: [{ t: "strong", c: [T("both")] }] }]);
  assert.deepEqual(parseMarkdown("**a *b* c**")[0].c, [{ t: "strong", c: [T("a "), { t: "em", c: [T("b")] }, T(" c")] }]);
});

test("snake_case and file names are not italic", () => {
  assert.deepEqual(parseMarkdown("use snake_case_name and file_names_like_this.py")[0].c, [T("use snake_case_name and file_names_like_this.py")]);
  assert.deepEqual(parseMarkdown("__init__.py 和 my_var_")[0].c.map((n) => n.t), ["strong", "text"]);
  assert.deepEqual(parseMarkdown("a * b * c")[0].c, [T("a * b * c")]);
  assert.deepEqual(parseMarkdown("2*3*4")[0].c.map((n) => n.t), ["text", "em", "text"]);
});

test("inline code: no formatting inside", () => {
  assert.deepEqual(parseMarkdown("用 `**x** _y_` 吧")[0].c, [T("用 "), { t: "code", text: "**x** _y_" }, T(" 吧")]);
  assert.deepEqual(parseMarkdown("``a`b``")[0].c, [{ t: "code", text: "a`b" }]);
  assert.deepEqual(parseMarkdown("未闭合 `abc")[0].c, [T("未闭合 `abc")]);
});

test("fenced code block: kept verbatim, with language", () => {
  const r = parseMarkdown("前\n```js\nconst a = **1**;\n\n# not heading\n```\n后");
  assert.deepEqual(r, [para(T("前")), { type: "code", lang: "js", text: "const a = **1**;\n\n# not heading" }, para(T("后"))]);
  assert.deepEqual(parseMarkdown("```\nx\n```"), [{ type: "code", lang: "", text: "x" }]);
  assert.deepEqual(parseMarkdown("~~~py\nx\n~~~")[0].lang, "py");
});

test("unclosed fence: code until the end", () => {
  assert.deepEqual(parseMarkdown("```sh\nls\n- a"), [{ type: "code", lang: "sh", text: "ls\n- a" }]);
});

test("unordered lists -, *, + and ordered lists", () => {
  for (const mk of ["-", "*", "+"]) {
    const r = parseMarkdown(`${mk} a\n${mk} b`);
    assert.equal(r.length, 1);
    assert.equal(r[0].type, "list");
    assert.equal(r[0].ordered, false);
    assert.deepEqual(r[0].items, [[para(T("a"))], [para(T("b"))]]);
  }
  const o = parseMarkdown("1. 一\n2. 二\n3) 三")[0];
  assert.equal(o.ordered, true);
  assert.equal(o.items.length, 3);
  assert.equal(parseMarkdown("3. x\n4. y")[0].start, 3);
});

test("nested lists: 2 / 3 / 4 space indents, three levels", () => {
  for (const sp of ["  ", "   ", "    "]) {
    const r = parseMarkdown(`- a\n${sp}- b\n${sp}${sp}- c\n- d`);
    assert.equal(r.length, 1);
    const [a, d] = r[0].items;
    assert.equal(r[0].items.length, 2);
    assert.deepEqual(a[0], para(T("a")));
    assert.equal(a[1].type, "list");
    assert.deepEqual(a[1].items[0][0], para(T("b")));
    assert.equal(a[1].items[0][1].items[0][0].c[0].text, "c");
    assert.deepEqual(d, [para(T("d"))]);
  }
  const mix = parseMarkdown("1. 步骤\n   - 子项 **粗**\n2. 下一步")[0];
  assert.equal(mix.items[0][1].type, "list");
  assert.equal(mix.items[0][1].items[0][0].c[1].t, "strong");
  assert.equal(mix.items.length, 2);
});

test("blank lines between items keep one list; a list right after a paragraph", () => {
  assert.equal(parseMarkdown("- a\n\n- b")[0].items.length, 2);
  const r = parseMarkdown("如下：\n- a\n- b");
  assert.deepEqual(r.map((b) => b.type), ["para", "list"]);
});

test("inline formatting and code blocks inside list items", () => {
  const r = parseMarkdown("- 用 `x` 和 [链接](https://a.com)\n- ```\n  code\n  ```");
  assert.deepEqual(r[0].items[0][0].c.map((n) => n.t), ["text", "code", "text", "link"]);
  assert.equal(r[0].items[1][0].type, "code");
});

test("blockquote: may contain paragraphs and lists", () => {
  const r = parseMarkdown("> 引用 **粗**\n> - a\n> - b\n>\n> 第二段");
  assert.equal(r.length, 1);
  assert.equal(r[0].type, "quote");
  assert.deepEqual(r[0].blocks.map((b) => b.type), ["para", "list", "para"]);
  assert.equal(r[0].blocks[1].items.length, 2);
});

test("tables: alignment, inline formatting, short rows padded, long rows truncated", () => {
  const r = parseMarkdown("| 名称 | 值 | 备注 |\n|:--|--:|:-:|\n| **a** | 1 |\n| b | 2 | 说明 | 多余 |");
  assert.equal(r.length, 1);
  const t = r[0];
  assert.equal(t.type, "table");
  assert.deepEqual(t.align, ["left", "right", "center"]);
  assert.equal(t.head.length, 3);
  assert.equal(t.rows.length, 2);
  assert.equal(t.rows[0][0][0].t, "strong");
  assert.equal(t.rows[0].length, 3);
  assert.equal(t.rows[1].length, 3);
  const noPipes = parseMarkdown("a | b\n--- | ---\n1 | 2")[0];
  assert.equal(noPipes.type, "table");
  assert.deepEqual(noPipes.align, [null, null]);
});

test("tables: escaped pipes and pipes inside code", () => {
  const t = parseMarkdown("| a | b |\n|---|---|\n| x\\|y | `a|b` |")[0];
  assert.equal(t.rows[0][0][0].text, "x|y");
  assert.equal(t.rows[0][1][0].text, "a|b");
});

test("malformed tables fall back to paragraphs", () => {
  assert.equal(parseMarkdown("| a | b |\n|---|")[0].type, "para"); // column counts do not match
  assert.equal(parseMarkdown("| a | b |\n| x | y |")[0].type, "para"); // no separator row
  assert.equal(parseMarkdown("| a | b |")[0].type, "para");
  assert.equal(parseMarkdown("a | b\n---")[0].type, "para");
});

test("paragraph after a table", () => {
  const r = parseMarkdown("| a |\n|---|\n| 1 |\n\n后文");
  assert.deepEqual(r.map((b) => b.type), ["table", "para"]);
});

test("horizontal rule", () => {
  for (const s of ["---", "***", "___", "- - -", "-----"]) assert.deepEqual(parseMarkdown(s), [{ type: "hr" }], s);
  assert.deepEqual(parseMarkdown("a\n\n---\n\nb").map((b) => b.type), ["para", "hr", "para"]);
});

test("links: [text](url) and bare URLs", () => {
  assert.deepEqual(parseMarkdown("看 [官网](https://a.com/x?y=1) 吧")[0].c, [
    T("看 "), { t: "link", href: "https://a.com/x?y=1", c: [T("官网")] }, T(" 吧"),
  ]);
  assert.deepEqual(parseMarkdown("见 https://a.com/p, 然后")[0].c, [
    T("见 "), { t: "link", href: "https://a.com/p", c: [T("https://a.com/p")] }, T(", 然后"),
  ]);
  assert.equal(parseMarkdown("(http://a.com/b)")[0].c[1].href, "http://a.com/b");
  assert.equal(parseMarkdown("https://a.com/这是中文")[0].c[0].href, "https://a.com/");
  assert.equal(parseMarkdown("https://en.wikipedia.org/wiki/A_(b)")[0].c[0].href, "https://en.wikipedia.org/wiki/A_(b)");
  // non-http hrefs are passed through by the parser; the renderer filters them
  assert.equal(parseMarkdown("[x](javascript:alert(1))")[0].c[0].href, "javascript:alert(1)");
  assert.deepEqual(parseMarkdown("[没有链接] 和 [a](")[0].c.map((n) => n.t), ["text"]);
});

test("Chinese text", () => {
  const r = parseMarkdown("## 总结\n\n这是**重点**内容，包含`代码`和~~删除~~。\n\n- 第一项：说明\n  - 子项");
  assert.equal(r[0].level, 2);
  assert.deepEqual(r[1].c.map((n) => n.t), ["text", "strong", "text", "code", "text", "del", "text"]);
  assert.equal(r[2].items[0][1].type, "list");
  assert.equal(parseMarkdown("中文_不是斜体_中文")[0].c.length, 1);
});

test("escapes", () => {
  assert.deepEqual(parseMarkdown("\\*不是斜体\\* \\# x")[0].c, [T("*不是斜体* # x")]);
});

test("CRLF and tabs", () => {
  assert.deepEqual(parseMarkdown("a\r\nb"), [para(T("a"), { t: "br" }, T("b"))]);
  assert.equal(parseMarkdown("- a\r\n\t- b")[0].items[0][1].type, "list");
});

test("empty and odd inputs never throw", () => {
  assert.deepEqual(parseMarkdown(""), []);
  assert.deepEqual(parseMarkdown("   \n\n  "), []);
  const weird = [null, undefined, 0, 12, {}, [], "\u0000", "*", "**", "***", "_", "__", "~~", "`", "```", "[", "](", "[]()", "[a](b", "> ", ">>>>", "-", "- ", "1.", "1. ", "#", "# ",
    "|", "||", "|-|", "| - |\n| - |", "**a", "a**", "*a**", "__a_", "~~a", "[[[[[", "((((", "<script>alert(1)</script>", "http://", "https://", "http://a", "\\", "\ud800",
    "- ".repeat(50), ">".repeat(100) + " x", "  ".repeat(30) + "- deep", "*".repeat(5000), "_".repeat(5000), "`".repeat(5001), "[".repeat(3000), "a ".repeat(20000) + "**"];
  let nest = "";
  for (let i = 0; i < 40; i++) nest += "  ".repeat(i) + "- n" + i + "\n";
  weird.push(nest);
  for (const w of weird) assert.doesNotThrow(() => parseMarkdown(w), JSON.stringify(String(w).slice(0, 20)));
  // random concatenation
  const parts = ["*", "_", "`", "~", "[", "]", "(", ")", "|", "-", ">", "#", "\n", " ", "  ", "a", "中", "1.", "http://x.y", "```", "---", ":"];
  let seed = 42;
  const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  for (let n = 0; n < 1500; n++) {
    let s = "";
    const len = 1 + Math.floor(rnd() * 40);
    for (let k = 0; k < len; k++) s += parts[Math.floor(rnd() * parts.length)];
    assert.doesNotThrow(() => parseMarkdown(s), JSON.stringify(s));
  }
});

test("plain text is kept verbatim (including <html> tags as text)", () => {
  assert.deepEqual(parseMarkdown("<b>hi</b> & <script>")[0].c, [T("<b>hi</b> & <script>")]);
});

test("tsvText: table copied as tab-separated, tabs and newlines inside cells collapse to spaces", async () => {
  const { tsvText } = await import("../md.js");
  assert.equal(tsvText([["a", "b"], ["1", "2"]]), "a\tb\n1\t2");
  assert.equal(tsvText([["x\ty", "m\nn"]]), "x y\tm n");
  assert.equal(tsvText([]), "");
});
