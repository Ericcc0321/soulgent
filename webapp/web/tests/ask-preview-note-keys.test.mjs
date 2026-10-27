// Preview-question options with notes: on mobile, a single-choice question with a left list and right preview can submit an option together with a note.
// Based on the Claude Code 2.1.310 source, v9 component:
// - Number key k only moves the cursor to item k; the "moved" flag is set only when the cursor index really changed (pressing "1" while on item 1 does not count as moving);
// - n opens the note box (in note mode only Esc is recognized, other keys go into the input); Enter in the note box = onSubmit: with a note and moved -> select the cursor item and answer
//   (a single question submits, multiple questions advance to the next), not moved -> recorded as "(notes only)";
// - On every question the cursor returns to item 1 and the moved flag is cleared.
// So choosing item k with a note = press a digit other than k, then k (so the last press is a real move), n, text, Enter; no extra Enter afterwards.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildAskSteps, askAnswerable } from "../logic.js";
import { table } from "../i18n.js";
const I18N = table();

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const pq = (n, extra) => Object.assign({ question: "pq" + n, preview: true, multiSelect: false,
  options: Array.from({ length: n }, (_, i) => "p" + (i + 1)) }, extra || {});
const Q = (n, extra) => Object.assign({ question: "q" + n, options: Array.from({ length: n }, (_, i) => "o" + (i + 1)) }, extra || {});

test("preview question, item 1 with a note: press 2 then 1 (cursor really moves back to item 1), n, note, Enter", () => {
  assert.deepEqual(buildAskSteps([pq(2)], [{ pick: 1, note: "折叠起来" }]),
    [{ key: "2" }, { key: "1" }, { key: "n" }, { text: "折叠起来" }, { key: "enter" }]);
});

test("preview question, item 2 with a note: press 1 then 2, n, note, Enter (a single question submits on Enter, no extra key)", () => {
  assert.deepEqual(buildAskSteps([pq(3)], [{ pick: 2, note: " 我认为\n可以 " }]),
    [{ key: "1" }, { key: "2" }, { key: "n" }, { text: "我认为 可以" }, { key: "enter" }]);
  assert.deepEqual(buildAskSteps([pq(4)], [{ pick: 4, note: "x" }]),
    [{ key: "1" }, { key: "4" }, { key: "n" }, { text: "x" }, { key: "enter" }]);
});

test("first of several questions is a preview question with a note: Enter in the note advances to the next question, the rest behave as usual, a trailing 1 submits", () => {
  assert.deepEqual(buildAskSteps([pq(2), Q(3)], [{ pick: 1, note: "备注" }, 3]),
    [{ key: "2" }, { key: "1" }, { key: "n" }, { text: "备注" }, { key: "enter" }, { key: "3" }, { key: "1" }]);
  assert.deepEqual(buildAskSteps([Q(2), pq(2)], [{ text: "x" }, { pick: 2, note: "y" }]),
    [{ key: "3" }, { text: "x" }, { key: "enter" }, { key: "1" }, { key: "2" }, { key: "n" }, { text: "y" }, { key: "enter" }, { key: "1" }]);
  // four preview questions all with notes: 4×5+1 = 21 steps, within 24
  const four = [pq(2, { question: "a" }), pq(2, { question: "b" }), pq(2, { question: "c" }), pq(2, { question: "d" })];
  assert.equal(buildAskSteps(four, four.map(() => ({ pick: 1, note: "n" }))).length, 21);
});

test("an empty note (or only whitespace/backslash) falls back to [k, Enter]; a plain number stays a plain number", () => {
  assert.deepEqual(buildAskSteps([pq(2)], [{ pick: 2, note: "  " }]), [{ key: "2" }, { key: "enter" }]);
  assert.deepEqual(buildAskSteps([pq(2)], [{ pick: 1 }]), [{ key: "1" }, { key: "enter" }]);
  assert.deepEqual(buildAskSteps([pq(2)], [2]), [{ key: "2" }, { key: "enter" }]);
  // Trailing backslash in a note: in the Claude Code input, "\ + Enter" is a newline rather than a submit, so it is stripped
  assert.deepEqual(buildAskSteps([pq(2)], [{ pick: 2, note: "a\\\\" }]),
    [{ key: "1" }, { key: "2" }, { key: "n" }, { text: "a" }, { key: "enter" }]);
  assert.deepEqual(buildAskSteps([pq(2)], [{ pick: 2, note: "\\" }]), [{ key: "2" }, { key: "enter" }]);
});

test("a note without an option, an out-of-range option, or custom text: none are sent (null); a normal single-choice question ignores pick/note", () => {
  assert.equal(buildAskSteps([pq(2)], [{ note: "只有备注" }]), null);
  assert.equal(buildAskSteps([pq(2)], [{ pick: 3, note: "x" }]), null);
  assert.equal(buildAskSteps([pq(2)], [{ pick: 0, note: "x" }]), null);
  assert.equal(buildAskSteps([pq(2)], [{ text: "我自己写" }]), null);
  assert.equal(buildAskSteps([Q(2)], [{ pick: 1, note: "x" }]), null);
  // A preview question with only 1 option cannot move the cursor, so choosing it with a note would be recorded as notes only and is not sent; without a note it is sent as usual
  assert.equal(buildAskSteps([pq(1)], [{ pick: 1, note: "x" }]), null);
  assert.deepEqual(buildAskSteps([pq(1)], [1]), [{ key: "1" }, { key: "enter" }]);
  assert.equal(askAnswerable([pq(2)]), true);
});

test("three-language entries: add note / note to the Agent...", () => {
  assert.equal(I18N["ask.withNote"], undefined); // there is no note switch
  assert.equal(I18N["ask.notePh"][1], "附带备注…");
  assert.equal(I18N["ask.notePh"].length, 3);
});

test("question card: the preview note row is always shown and the note is submitted with the selected option; sw", () => {
  const app = rd("app.js");
  assert.doesNotMatch(app, /ask\.withNote/);
  assert.match(app, /t\("ask\.notePh"\)/);
  assert.match(app, /pick: state\.sel\[i\], note:/);
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
