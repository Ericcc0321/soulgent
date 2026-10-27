// List-row long-press menu, swipe-left "mark unread" conditions, spacing between own bubble and next row, four receipt states + tooltip, two-line quote bar, theme blue --brand
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { swipeActions, rowMenuActs, rcTipText } from "../logic.js";
import { setLang, t as tr } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../style.css");
const app = read("../app.js");
const html = read("../index.html");
const login = read("../login.html");
const fnBody = (name, len = 1500) => { const i = app.indexOf("function " + name); assert.ok(i > 0, "missing " + name); return app.slice(i, i + len); };
const jBlock = () => { const i = css.indexOf(":root { --brand:"); assert.ok(i > 0, "missing CSS block with --brand"); return css.slice(i); };
const rule = (src, sel) => { const i = src.indexOf(sel + " {"); assert.ok(i >= 0, "missing " + sel); return src.slice(i, src.indexOf("}", i)); };

// ---------- swipe-left "mark unread": typical states ----------
// Many idle sessions have origin peer (session-to-session traffic) or agent (handled a sub-agent report);
// they must still be offered "mark unread"
const real = {
  peerIdle: { kind: "claude", status: "idle", origin: "peer", unread: false, rest: false },       // Web-UI-refactor
  peerRest: { kind: "claude", status: "idle", origin: "peer", unread: false, rest: true },        // Docs-Layout-typesetting (resting)
  agentIdle: { kind: "claude", status: "idle", origin: "agent", unread: false, rest: false },     // Ops-demo-maintenance
  userIdle: { kind: "claude", status: "idle", origin: "user", unread: false, rest: false },       // Scratch-pad
  userDot: { kind: "claude", status: "idle", origin: "user", unread: true, rest: false },
  peerDot: { kind: "claude", status: "idle", origin: "peer", unread: true, rest: false },         // peer session manually marked unread
  busy: { kind: "claude", status: "busy", origin: "agent", unread: false, rest: false },          // Docs-Dash-Desktop
  waiting: { kind: "claude", status: "waiting", origin: "user", unread: false, rest: false },
};
const rd = (s) => swipeActions(s).map((a) => a.key).find((k) => k === "seen" || k === "unseen") || null;

test("idle seen sessions without a dot (including peer traffic / sub-agent reports) offer \"mark unread\"; those with a dot offer \"mark read\"", () => {
  for (const k of ["peerIdle", "peerRest", "agentIdle", "userIdle"]) assert.equal(rd(real[k]), "unseen", k);
  for (const k of ["userDot", "peerDot"]) assert.equal(rd(real[k]), "seen", k);
  // busy / waiting: there is no "finished reading" (waiting counts as a dot by itself), so neither is offered
  assert.equal(rd(real.busy), null);
  assert.equal(rd(real.waiting), null);
});

// ---------- list-row long-press menu ----------
test("rowMenuActs: pin / unread-read / mute, separator, rest / back, off-duty (red, Claude only); empty for guests", () => {
  const ks = (s, g) => rowMenuActs(s, g).map((a) => (a.sep ? "|" : a.key + ":" + a.label + (a.danger ? "!" : "")));
  // A state-based matrix; pinning goes through top/untop (persistent pin)
  assert.deepEqual(ks(real.userIdle), ["top:置顶", "unseen:标为未读", "mute:消息免打扰", "|", "rest:休息", "off:下班!"]);
  assert.deepEqual(ks({ ...real.userDot, topped: true, muted: true, rest: true }),
    ["untop:取消置顶", "unmute:取消免打扰", "|", "back:回来", "off:下班!"]);
  assert.deepEqual(ks(real.busy), ["top:置顶", "mute:消息免打扰", "|", "off:下班!"]);
  assert.deepEqual(ks({ ...real.userIdle, kind: "shell" }), ["top:置顶", "unseen:标为未读", "mute:消息免打扰", "|", "rest:休息"]);
  assert.deepEqual(rowMenuActs(real.userIdle, true), []);
  assert.deepEqual(rowMenuActs(null, false), []);
  assert.ok(!ks(real.userIdle).some((x) => x.includes("查看对话")));
});

test("long-press / right-click on a row goes through openRowMenu (no bottom sheet any more)", () => {
  const bind = app.slice(app.indexOf("let crLp = null;"), app.indexOf("// ---------- bottom sheet ----------"));
  assert.match(bind, /openRowMenu\(r\.dataset\.id, r, crLp\.x\)/);
  assert.match(bind, /openRowMenu\(r\.dataset\.id, r, e\.clientX\)/);
  assert.doesNotMatch(app, /function openActions\(/); // the classic-lanes card sheet is gone
  const b = fnBody("openRowMenu(", 1400);
  assert.match(b, /rowMenuActs\(s, st\.guest\)/);
  assert.match(b, /openBubblePop\(row, [^)]*jr-pop/);
  assert.match(b, /h\("div", "jr-sep"\)/);
  const run = fnBody("rowMenuRun(", 700);
  const tbl = app.slice(app.indexOf("const ROW_MENU_RUN = {"), app.indexOf("function rowMenuRun("));
  assert.match(tbl, /setTop\(s, /); // the menu's pin goes through the persistent pin
  assert.match(tbl, /chSetMute\(s, /);
  assert.match(run, /swipeAct\(k, x\)/); // unread / read / rest / back / off-duty (off-duty goes through confirmOff)
  // scrolling the list page closes the menu (the list scrolls on window)
  assert.match(app, /addEventListener\("scroll", \(\) => \{ if \(bmState && bmState\.row\) closeBubbleMenu\(\); \}/);
  // openBubblePop accepts its own visible box (the list page has no #msgs)
  assert.match(fnBody("openBubblePop(", 500), /function openBubblePop\(el, content, cls, box\)/);
  const c = jBlock();
  assert.match(rule(c, ".jr-pop .bm-it"), /flex-direction:\s*row/);
  assert.match(rule(c, ".jr-pop .jr-danger"), /#fa5151/i);
  assert.match(rule(c, ".jr-sep"), /height:\s*\.5px|height:\s*1px/);
});

// ---------- own bubble and the next row ----------
test("a group starting with a standalone tools row after my bubble is not pulled up 8px (uniform 16px)", () => {
  assert.match(css, /\.tools\.solo \{ margin: -8px 0 16px/); // agent after agent still sticks to the previous row
  assert.match(rule(jBlock(), ".cg.hu + .tools.solo"), /margin-top:\s*0/);
});

// ---------- receipt states ----------
test("five receipt levels: 12px clock / red-background white ! for undelivered / bright-yellow single tick (sent / delivered) / white 60% double tick for read", () => {
  const c = jBlock();
  const sd = rule(c, ".rc-mk.rc-clock .rc-ic");
  assert.match(sd, /width:\s*12px/);
  assert.match(sd, /height:\s*12px/);
  assert.match(rule(c, ".rc-mk.rc-sent .rc-ic, .rc-mk.rc-delivered .rc-ic"), /#ffd60a/i);
  assert.match(rule(c, ".rc-mk.rc-read .rc-ic"), /rgba\(255, 255, 255, \.6\)/);
  assert.ok(!/rc-sending|rc-spin/.test(css), "the receipt uses a clock, not a spinner");
  assert.match(rule(c, ".rc-mk.rc-failed"), /#fa5151/i);
  assert.match(app, /failed: '<svg viewBox="0 0 16 16"><path d="M8 3\.6v5\.2" stroke="#fff"/); // white ! (the red circle is in CSS .rc-mk.rc-failed)
});

test("tapping a receipt shows a 2-second small tooltip; tapping a tick only shows the hint, no recall confirmation any more", () => {
  assert.equal(rcTipText("read"), "已读");
  assert.equal(rcTipText("sent"), "已送到，它忙完会读");
  assert.equal(rcTipText("failed"), "未送达");
  assert.equal(rcTipText("clock"), "发送中");
  assert.equal(rcTipText("delivered"), "已送到，它忙完会读");
  assert.equal(rcTipText("sending"), "");
  assert.equal(rcTipText("x"), "");
  const m = fnBody("rcMark(", 1200);
  assert.match(m, /m\.classList\.add\("rc-tap"\)/);
  assert.doesNotMatch(m, /if \(\(rc === "sent" && !st\.guest\) \|\| rc === "failed"\) \{\s*m\.classList\.add/); // all four states are tappable
  assert.match(m, /rcTip\(/);
  const t = fnBody("rcTip(", 700);
  assert.match(t, /h\("div", "jr-tip"/);
  assert.match(t, /2000/);
  assert.match(fnBody("confirmRecall(", 500), /t\("recall.ask"\)/);
  assert.match(tr("recall.ask"), /已送达，Agent 还没读/);
  const c = jBlock();
  const tip = rule(c, ".jr-tip");
  assert.match(tip, /position:\s*fixed/);
  assert.match(tip, /font-size:\s*12px/);
  assert.match(tip, /pointer-events:\s*none/);
});

// ---------- quote bar: real two lines ----------
test("quote bar: outer flex item .jq-wrap only holds the space, inner #quote-tx is a block carrying the 2-line clamp and takes no padding", () => {
  assert.match(html, /<div class="jq-wrap"><div id="quote-tx" class="quote-tx"><\/div><\/div>/);
  const c = jBlock();
  const w = rule(c, ".quote-bar > .jq-wrap");
  assert.match(w, /flex:\s*1/);
  assert.match(w, /min-width:\s*0/);
  const q = rule(c, ".quote-bar > .jq-wrap > .quote-tx");
  assert.match(q, /display:\s*-webkit-box/);
  assert.match(q, /-webkit-line-clamp:\s*2/);
  assert.match(q, /-webkit-box-orient:\s*vertical/);
  assert.match(q, /overflow:\s*hidden/);
  assert.match(q, /padding:\s*0/);
  assert.match(q, /white-space:\s*normal/);
});

// ---------- theme blue ----------
test("--brand: #1f8fff; brand uses are not green, semantic green is kept", () => {
  assert.match(rule(jBlock(), ":root"), /--brand:\s*#1f8fff/i);
  const brand = [
    ".cr-cancel", ".cr-wake", ".ch-tg:checked", ".ch-hs mark", ".pf-save",
    ".ask .opt.on .o-mk", ".ask .own-row.on .o-pen", ".approve .ok", ".mon-act.on .mon-circle", ".drop-box", ".md-cp.done",
  ];
  // The same selector may be written in several places (base rule + later override): none may use the previous green, at least one must use the theme blue
  const allRules = (sel) => { const out = []; let i = -1; while ((i = css.indexOf(sel + " {", i + 1)) >= 0) out.push(css.slice(i, css.indexOf("}", i))); assert.ok(out.length, "missing " + sel); return out; };
  for (const sel of brand) {
    const rs = allRules(sel);
    for (const r of rs) assert.doesNotMatch(r, /07c160|7, 193, 96/i, sel);
    assert.ok(rs.some((r) => /var\(--brand[,)]|31, 143, 255/.test(r)), sel);
  }
  assert.match(css, /\.cr-tab\.on \{ color: var\(--brand\); \}/); // selected state of the bottom bar / wide-screen side rail (the logo square fill follows currentColor)
  assert.match(css, /\.cr-search input \{[^}]*caret-color: var\(--brand\)/);
  assert.match(css, /\.cr-pv mark, \.cr-nm mark \{ color: var\(--brand\)/);
  assert.match(css, /\.composer \.send-btn:not\(:disabled\) \{ background: var\(--brand\)/);
  assert.match(css, /\.ask \.q-multi \{[^}]*color: var\(--brand\)/);
  assert.match(css, /\.ask \.opt\.on \{ background: rgba\(31, 143, 255, \.1\)/);
  // semantic colors stay green: busy, Mac connected, on duty, tool-done tick, sub-agent done
  assert.match(css, /\.cr-shn\.b::before \{ color: #07c160; \}/); // busy label: the green copy under the light sweep (the sweep layers are in the "Working row" block)
  assert.match(css, /\.cr-tm\.live \{ color: var\(--c-green\)/);
  assert.match(css, /\.cr-macdot\.on \{ background: #07c160/);
  assert.match(css, /\.zc-ls\.on \{ color: var\(--c-green\)/);
  assert.match(css, /\.mon-hv\.ok i \{ background: var\(--c-green\)/);
  // login page button
  assert.match(login, /button \{[^}]*background: #1f8fff; color: #fff;/);
});
