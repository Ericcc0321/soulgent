// Cross-session message folding uses a plain-text preview .x-prev (multi-paragraph Markdown is not cut mid-line)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
const fn = (name) => { const i = app.indexOf("function " + name + "("); return app.slice(i, app.indexOf("\n}\n", i)); };

test("peerFold generates a plain-text .x-prev preview, and callers pass the text", () => {
  assert.match(fn("peerFold"), /x-prev/);
  assert.match(fn("peerFold"), /mdPlain\(text\)/);
  assert.match(app, /peerFold\(el, peerKey\(it\), text\)/);
});

test("CSS: when folded .md is hidden and .x-prev uses line-clamp 2 on a single block element; when expanded .x-prev is hidden", () => {
  assert.match(css, /\.m\.x \.x-prev \{ display: none; \}/);
  assert.match(css, /\.m\.x\.clamp \.md \{ display: none; \}/);
  const m = css.match(/\.m\.x\.clamp \.x-prev \{([^}]*)\}/);
  assert.ok(m, "missing .x-prev rule under clamp");
  assert.match(m[1], /-webkit-line-clamp: 2/);
});

test("fitPeerFolds decides using the scrollHeight of .x-prev", () => {
  const f = fn("fitPeerFolds");
  assert.match(f, /\.x-prev/);
  assert.match(f, /pv\.scrollHeight/);
  assert.doesNotMatch(f, /md\.scrollHeight/);
});

test("mdPlain strips Markdown symbols and extra whitespace", () => {
  const src = fn("mdPlain");
  const mdPlain = new Function(src + "\n}; return mdPlain;")();
  assert.equal(mdPlain("结论如下：\n\n- **第一项** 很好\n- 第二项 `code`\n1. 三"), "结论如下： 第一项 很好 第二项 code 三");
  assert.equal(mdPlain("## 标题\n[链接](http://x.y) 文字"), "标题 链接 文字");
});
