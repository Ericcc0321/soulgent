// Desktop input area (multi-row composer with a toolbar), Markdown code block / table copy buttons
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { WIDE_MQ } from "../logic.js";
import { setLang, t } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const html = read("../index.html");
const wide = css.slice(css.indexOf("@media " + WIDE_MQ + " {"));

test("input area: the composer has a pick-files button and a multi-file input", () => {
  const comp = html.slice(html.indexOf('id="composer"'), html.indexOf('id="btn-plus"'));
  assert.match(comp, /id="btn-pick"/);
  assert.match(html, /id="in-pick"[^>]*multiple/);
  assert.doesNotMatch(comp, /选文件<\/span>|>选文件</, "the button must not carry the pick-files text, icon only");
  assert.match(comp, /id="btn-pick"[^>]*aria-label="Choose files"[^>]*title="Choose files"[^>]*data-i18n-attr="aria-label:html.pick;title:html.pick"/);
  assert.equal(t("html.pick"), "选文件");
});

test("input area: the pick-files button is hidden on mobile; shown only on wide screens, which also hide ➕, use a fixed height of max(120px,22vh) and a theme-colored send button", () => {
  assert.match(css, /\.pc-pick\s*\{\s*display:\s*none/);
  const w = wide.slice(0, wide.indexOf("\n}\n"));
  assert.match(w, /\.pc-pick\s*\{[^}]*display:\s*(inline-)?flex/);
  assert.match(w, /\.pc-bar\s*\{[^}]*grid-row:\s*3/, "toolbar row is at the bottom");
  assert.match(w, /\.composer textarea\s*\{[^}]*grid-row:\s*1/);
  assert.match(w, /\.composer\s*\{[^}]*border-radius:\s*8px/);
  assert.match(w, /\.composer:focus-within\s*\{[^}]*rgba\(255, 255, 255/, "no blue highlight on focus");
  assert.match(w, /\.composer \.send-btn:disabled\s*\{[^}]*background:\s*#2b2b2b/);
  assert.match(w, /#btn-plus\s*\{\s*display:\s*none/);
  assert.match(w, /\.composer\s*\{[^}]*min-height:\s*120px/);
  assert.match(w, /grid-template-rows:\s*max\(74px, calc\(22vh - 46px\)\) auto auto/, "the text box row height is fixed, the whole area grows when there is a quote");
  assert.match(w, /\.composer \.send-btn\s*\{[^}]*display:\s*block !important/); // the mobile .send-btn{display:none!important} must be overridden on wide screens
  assert.match(w, /\.composer \.send-btn:not\(:disabled\)\s*\{[^}]*var\(--brand\)/); // theme blue
});

test("the pick-files button is wired into the attachment bar; the input height is not changed by autosize on wide screens", () => {
  assert.match(app, /\$\("#btn-pick"\)\.onclick/);
  assert.match(app, /inputs\.pick|\$\("#in-pick"\)/);
  assert.match(app, /isWide\(\)\)\s*\{\s*ta\.style\.height = ""/);
});

test("code blocks and tables have copy buttons; the button does not trigger the whole-message long press; copy has an execCommand fallback", () => {
  assert.match(app, /md-cp/);
  assert.match(app, /stopPropagation/);
  assert.match(app, /closest\("\.md-cp"\)[^;\n]*return/); // the long-press check may combine other exceptions (such as the read-status marker .rc-mk)
  assert.match(app, /navigator\.clipboard\.writeText/);
  assert.match(css, /\.md-cb\s*\{[^}]*overflow:\s*hidden/);
  assert.match(css, /\.md-cp\s*\{/);
  assert.match(app, /t\("c.copied"\)/);
  assert.match(css, /\.md-ch\s*\{[^}]*height:\s*26px/, "header strip is 26px, the button does not cover the code area");
});

test("wide-screen quote bar: JS only moves #quote-bar into the input area (does not touch setQuote), styled as an inline quote strip", () => {
  assert.match(app, /function bindQuoteDock/);
  assert.match(app, /\$\("#composer"\)\.insertBefore\(q, /);
  assert.match(app, /\$\("#tray"\)\.after\(q\)/);
  assert.match(app, /bindQuoteDock\(\);|initStep\("\w+", bindQuoteDock\)/); // after the init split it goes through initStep
  assert.match(wide, /\.composer > \.quote-bar\s*\{[^}]*grid-row:\s*2[^}]*border-left:\s*2px solid/);
  assert.match(wide, /\.composer > \.quote-bar \.quote-tx\s*\{[^}]*-webkit-line-clamp:\s*2/);
  assert.match(wide, /\.composer > \.quote-bar \.quote-x\s*\{[^}]*border-radius:\s*50%/);
  assert.match(wide, /\.pc-bar\s*\{[^}]*grid-row:\s*3/);
});
