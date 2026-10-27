// Me-page seen / profile icon colors fit the other icons on the page (same palette, no blue clash, all distinct); the hint when a guest's recall is blocked by an admin queue
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { recallFailText } from "../logic.js";

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const block = app.slice(app.indexOf("const ME_IC = {"), app.indexOf("function meIcon"));
const color = (k) => { const m = block.match(new RegExp("\\n\\s*" + k + ': \\["(#[0-9a-fA-F]{6})"')); assert.ok(m, "missing " + k); return m[1].toLowerCase(); };
const isBlue = (c) => { const [r, g, b] = [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16)); return b > r + 40 && b >= g - 20; };

test("seen / profile avoid green, avoid blue, and differ from every other icon color", () => {
  const keys = ["mon", "push", "seen", "refresh", "diag", "profile", "logout"];
  const cs = Object.fromEntries(keys.map((k) => [k, color(k)]));
  for (const k of ["seen", "profile"]) {
    assert.notEqual(cs[k], "#07c160", k + " still uses the legacy green");
    assert.ok(!isBlue(cs[k]), k + " clashes with blue " + cs[k]);
    for (const o of keys) if (o !== k) assert.notEqual(cs[k], cs[o], k + " has the same color as " + o);
  }
  assert.notEqual(cs.seen, cs.profile);
});

test("hint when a guest's recall is blocked by the admin queue", () => {
  assert.equal(recallFailText("admin-queued"), "管理员有排队消息，暂不能撤回");
});

import { canSend } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified
const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
const tableShellCss = () => { const i = css.indexOf(".md-cb.md-cb-t {"); assert.ok(i > 0, "missing CSS block for the table shell"); return css.slice(i); };

test("table shell md-cb is as wide as the table: fit-content capped at 100%, the table scrolls horizontally itself; the code-block shell is not narrowed", () => {
  assert.match(app, /h\("div", "md-cb" \+ \(inner\.classList\.contains\("md-tbl"\) \? " md-cb-t" : ""\)\)/);
  assert.match(tableShellCss(), /\.md-cb\.md-cb-t\s*\{[^}]*width:\s*fit-content[^}]*max-width:\s*100%/);
  assert.match(css, /\.md-tbl\s*\{[^}]*overflow-x:\s*auto/);
  assert.doesNotMatch(tableShellCss(), /\.md-cb\s*\{[^}]*width:\s*fit-content/); // the non -t variant (code blocks) is not narrowed
});

test("the attachment tray has no send button (at any size); with attachments only, keyboard send is enabled", () => {
  assert.doesNotMatch(tableShellCss(), /tray-send/);
  assert.doesNotMatch(app, /tray-send|traySendBtn/);
  assert.equal(canSend("", 1), true);
  assert.equal(canSend("  ", 0), false);
  assert.match(app, /\$\("#btn-send"\)\.disabled = !canSend\(ta\.value, st\.tray\.length\)/);
});
