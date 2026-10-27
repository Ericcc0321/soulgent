// Code-block header bar, read-receipt placement, subagent back/front hints, back-side column width
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { agentBackH } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const block = (src, re) => { const m = src.match(re); assert.ok(m, "missing " + re); return m[1]; };

test("code blocks / tables get a 26px header bar: language name on the left, copy on the right; the code area keeps no right padding", () => {
  assert.match(app, /function mdCopyWrap\(inner, lang\)/);
  assert.match(app, /h\("div", "md-ch"\)/);
  assert.match(app, /h\("span", "md-lang"/);
  assert.match(app, /mdCopyWrap\(pre, b\.lang\)/);
  assert.match(app, /mdCopyText\(btn\.closest\("\.md-cb"\)\)/);
  assert.match(block(css, /\.md-ch\s*\{([^}]*)\}/), /height:\s*26px/);
  assert.doesNotMatch(block(css, /\.md-cp\s*\{([^}]*)\}/), /position:\s*absolute/);
  assert.doesNotMatch(css, /\.md-cb > pre\s*\{[^}]*padding-right/);
  assert.doesNotMatch(css, /\.md-cb > \.md-tbl\s*\{[^}]*padding-right/);
  assert.doesNotMatch(css, /\.md-cb:hover \.md-cp/, "the header bar is always visible, not hover-dependent");
  assert.match(app, /t\("c.copied"\)/);
});

test("read receipt: drawn inside my bubble (bottom right), not on a separate line below it; the grey quote bar still hangs below the bubble", () => {
  assert.equal((app.match(/el\.append\(rcMark\(rc, el\)\)/g) || []).length, 2, "two places (my transcript bubbles / my pending bubbles)");
  assert.doesNotMatch(app, /col\.append\(rcMark\(rc, el\)\)/);
  assert.equal((app.match(/col\.append\(h\("div", "rc-qt", qd\.quote\)\);/g) || []).length, 2);
});

test("back side: no top-right return arrow; a 28px tap-to-flip-back bar at the bottom, its height included in the back side; column width follows the content", () => {
  assert.doesNotMatch(app, /ag-ret/);
  assert.doesNotMatch(css, /\.ag-ret/);
  assert.match(app, /h\("div", "ag-ft", t\("ag.tapBack"\)\)/);
  assert.match(block(css, /\.ag-ft\s*\{([^}]*)\}/), /height:\s*28px/);
  assert.equal(agentBackH(1), 8 + 28 + 16 + 66 + 28);
  assert.equal(agentBackH(3), 8 + 28 + 16 + 3 * 66 + 2 * 6 + 28);
  assert.equal(agentBackH(2, { hd: 30, card: 70, gap: 4, ft: 28 }), 8 + 30 + 16 + 2 * 70 + 4 + 28);
  assert.match(block(css, /\.ag-card\s*\{([^}]*)\}/), /grid-template-columns:\s*minmax\(0, max-content\) auto 1fr auto/);
});

test("front bubble that spawned a subagent: a 22px view-subagent bar at the bottom; placeholder bubbles do not get it", () => {
  assert.match(app, /h\("div", "ag-hint", t\("ag.tapHint"\)\)/);
  assert.match(app, /!bub\.classList\.contains\("ph-bub"\)\)[^\n]*ag-hint/);
  assert.match(block(css, /\.ag-hint\s*\{([^}]*)\}/), /height:\s*22px/);
});
