// Own message rows mirror Agent rows, receipts are drawn in the bubble's bottom-right corner, the Me-page card edits the profile directly, default label of code block / table headers
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang, t } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const fnBody = (name, len = 1500) => { const i = app.indexOf("function " + name); assert.ok(i > 0, "missing " + name); return app.slice(i, i + len); };
const iBlock = () => { const i = css.indexOf(".cg.hu { padding-left"); assert.ok(i > 0, "missing CSS block: own row mirrors Agent row"); return css.slice(i); };
const rule = (src, sel) => { const i = src.indexOf(sel + " {"); assert.ok(i >= 0, "missing " + sel); return src.slice(i, src.indexOf("}", i)); };

test("own row: meGroup builds the name row + right-side avatar, used in both places (record / pending)", () => {
  const b = fnBody("meGroup(", 700);
  assert.match(b, /"cg hu me"/);
  assert.match(b, /h\("div", "cg-who"\)/);
  assert.match(b, /profileView\(st\.profile\)\.name/);
  assert.match(b, /myAvatar\("cav"\)/);
  assert.equal((app.match(/"cg hu me"/g) || []).length, 1, "built only inside meGroup");
  assert.ok((app.match(/meGroup\(\)/g) || []).length >= 2);
  const c = iBlock();
  assert.match(rule(c, ".cg.hu"), /padding-left:\s*var\(--agr\)/);
  assert.match(rule(c, ".cg.hu .cg-who"), /justify-content:\s*flex-end/);
  assert.match(c, /\.list \.cg\.hu\.me \.cg-col > \.m[^{]*\{[^}]*max-width:\s*100%/);
});

test("receipt drawn in the bottom-right of the blue bubble: 28×15 placeholder, absolutely positioned icon, white 75% tone (single tick bright yellow, read white 60%, see receipt-styles), tap area >= 28px", () => {
  assert.equal((app.match(/el\.append\(rcMark\(rc, el\)\)/g) || []).length, 2);
  assert.doesNotMatch(app, /col\.append\(rcMark\(/);
  assert.match(fnBody("rcMark(", 900), /h\("i", "rc-ic"\)/);
  const c = iBlock();
  const mk = rule(c, ".rc-mk");
  assert.match(mk, /display:\s*inline-block/);
  assert.match(mk, /width:\s*28px/);
  assert.match(mk, /height:\s*15px/);
  const ic = rule(c, ".rc-mk .rc-ic");
  assert.match(ic, /position:\s*absolute/);
  assert.match(ic, /right:/);
  assert.match(ic, /bottom:/);
  assert.match(ic, /rgba\(255, 255, 255, \.75\)/);
  assert.match(rule(c, ".rc-mk.rc-read .rc-ic"), /rgba\(255, 255, 255, \.6\)/);
  assert.match(rule(c, ".rc-mk.rc-tap .rc-ic::after"), /inset:\s*-8px/);
});

test("Me page: tapping the card edits the profile directly and there is no edit-profile row; the monitor page is still reached from the Messages status row", () => {
  const me = fnBody("renderMe()", 2200);
  assert.doesNotMatch(me, /"编辑资料"/);
  assert.match(app, /k === "card" \|\| k === "profile"\) openProfileEdit\(\)/);
  assert.doesNotMatch(app, /k === "card" \|\| k === "mon"/);
  assert.match(app, /\$\("#cr-mac"\)\.onclick = [^\n]*openMonitor\(\)/);
});

test("a code block header without a language name reads the default code label, a table reads the default table label", () => {
  assert.match(fnBody("mdCopyWrap(", 400), /h\("span", "md-lang", lang \|\| t\("md.code"\)\)/);
  assert.match(app, /mdCopyWrap\(wrap, t\("md.table"\)\)/);
  assert.equal(t("md.code"), "代码"); assert.equal(t("md.table"), "表格");
});
