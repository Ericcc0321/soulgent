// The "other" row of a question card (multi-select "Type something", single-select "type your own") must tick on tap and focus its input.
// Runs the real askBox from app.js against a minimal fake DOM; a tap is replayed the way iOS Safari fires it (seen in the phone diag log):
// a click on the tapped child (check mark / pen / padding) bubbling to the <label>, then the label-activation click on the input, unless the first was preventDefault-ed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as logic from "../logic.js";

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const fn = (name) => { const i = app.indexOf("function " + name + "("); return app.slice(i, app.indexOf("\n}\n", i) + 3); };

let active = null;
class El {
  constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.parent = null; this.cls = new Set(); this.ls = []; this.value = ""; this.disabled = false; this.textContent = ""; }
  set className(v) { this.cls = new Set(String(v).split(/\s+/).filter(Boolean)); }
  get classList() {
    const c = this.cls;
    return { add: (...a) => a.forEach((x) => c.add(x)), remove: (...a) => a.forEach((x) => c.delete(x)),
      contains: (x) => c.has(x), toggle: (x, on) => { if (on === undefined) on = !c.has(x); if (on) c.add(x); else c.delete(x); return on; } };
  }
  append(...xs) { for (const x of xs) { if (typeof x === "string") continue; x.parent = this; this.children.push(x); } }
  addEventListener(type, f) { this.ls.push([type, f]); }
  focus() { if (active && active !== this) active.blur(); active = this; }
  blur() { if (active === this) active = null; }
  all(pred, out = []) { for (const c of this.children) { if (pred(c)) out.push(c); c.all(pred, out); } return out; }
  find(cls) { return this.all((e) => e.cls.has(cls)); }
}
function dispatch(target, type, init = {}) {
  const ev = Object.assign({ type, target, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } }, init);
  for (let el = target; el; el = el.parent) {
    for (const [t, f] of el.ls) if (t === type) f(ev);
    if (type === "click" && el.onclick) el.onclick(ev);
  }
  return ev;
}
// one finger tap as iOS delivers it inside a <label>
function tap(target) {
  const ev = dispatch(target, "click");
  if (target.tagName === "INPUT") { target.focus(); return; }
  let lab = target;
  while (lab && lab.tagName !== "LABEL") lab = lab.parent;
  if (!lab || ev.defaultPrevented) return;
  const ctl = lab.all((e) => e.tagName === "INPUT")[0];
  if (ctl) { ctl.focus(); dispatch(ctl, "click"); }
}
function type(inp, v) { inp.value = v; dispatch(inp, "input"); }

const env = {
  h(tag, cls, text) { const e = new El(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; },
  svgEl: () => new El("svg"), PEN_SVG: "", t: (k) => k, isEn: () => true,
  st: { guest: false, sent: new Map(), ask: new Map() },
  cleanReplyText: logic.cleanReplyText, buildAskSteps: logic.buildAskSteps, isPreviewQ: logic.isPreviewQ,
  askHasOwn: logic.askHasOwn, askAnswerable: logic.askAnswerable, answeredRows: () => [], sentNote: () => new El("div"),
  submitSend: async () => true,
};
const askBox = new Function(...Object.keys(env), fn("askBox") + "\nreturn askBox;")(...Object.values(env));

// Real AskUserQuestion from the bug report (labels shortened): one multi-select question, 4 options, "Type something" is row 5
const multiQ = { question: "Q178", header: "h", multiSelect: true, options: ["A", "B", "C", "D"], descs: ["", "", "", ""] };
const singleQ = { question: "q", header: "h", multiSelect: false, options: ["A", "B", "C"], descs: ["", "", ""] };
const render = (q, id) => {
  active = null;
  const box = askBox({}, { toolUseId: id, questions: [q], text: "" }, true);
  const own = box.find("own-row")[0];
  return { box, own, inp: own.all((e) => e.tagName === "INPUT")[0], mk: own.find("o-mk")[0], submit: box.find("go")[0], state: env.st.ask.get(id) };
};
const picks = (q, state) => (q.multiSelect ? [{ multi: state.multi[0], text: state.ownOn[0] ? state.txt[0] : "" }] : [state.sel[0] === "custom" ? { text: state.txt[0] } : state.sel[0]]);

test("multi-select: tapping the check mark of the Type something row ticks it and focuses the input (once per tap, not toggled twice)", () => {
  const r = render(multiQ, "m1");
  tap(r.mk);
  assert.equal(r.own.classList.contains("on"), true);
  assert.equal(active, r.inp);
  assert.equal(r.submit.disabled, true); // ticked but nothing typed yet
  type(r.inp, "补充一条");
  assert.equal(r.own.classList.contains("on"), true);
  assert.equal(r.submit.disabled, false);
  // Unverified on a live terminal (taken from the existing multi-select branch of buildAskSteps, no Claude Code source cited there):
  // key n+1 toggles "Type something" without moving the cursor; the cursor sits on row 1 so n x down lands on that row;
  // typed text goes into that row; tab moves to Submit and enter confirms; the trailing 1 picks "Submit answers" on the review page.
  const down = Array.from({ length: 4 }, () => ({ key: "down" }));
  assert.deepEqual(logic.buildAskSteps([multiQ], picks(multiQ, r.state)),
    [{ key: "5" }, ...down, { text: "补充一条" }, { key: "tab" }, { key: "enter" }, { key: "1" }]);
});

test("multi-select: tapping the row again unticks it and the leftover text is not sent", () => {
  const r = render(multiQ, "m2");
  tap(r.mk);
  type(r.inp, "x");
  tap(r.box.find("opt")[0]); // tick option 1 as well
  tap(r.mk);
  assert.equal(r.own.classList.contains("on"), false);
  assert.equal(active, null);
  assert.deepEqual(logic.buildAskSteps([multiQ], picks(multiQ, r.state)), [{ key: "1" }, { key: "right" }, { key: "1" }]);
});

test("multi-select: tapping straight into the input and typing also ticks the row", () => {
  const r = render(multiQ, "m3");
  tap(r.inp);
  assert.equal(r.own.classList.contains("on"), true);
  type(r.inp, "y");
  assert.equal(r.submit.disabled, false);
});

test("single-select: tapping the own row selects it, unticks other options and focuses the input; submit waits for text", () => {
  const r = render(singleQ, "s1");
  tap(r.box.find("opt")[1]);
  tap(r.mk);
  assert.equal(r.own.classList.contains("on"), true);
  assert.equal(r.box.find("opt")[1].classList.contains("on"), false);
  assert.equal(active, r.inp);
  assert.equal(r.submit.disabled, true);
  type(r.inp, "自己的");
  assert.equal(r.submit.disabled, false);
  assert.deepEqual(logic.buildAskSteps([singleQ], picks(singleQ, r.state)), [{ key: "4" }, { text: "自己的" }, { key: "enter" }]);
});
