// An answered preview question must not stay shown as waiting (sample record):
// A single-choice question with previews is a "list on the left, preview on the right" UI in Claude Code 2.1.310: digit keys only move the cursor, Enter selects, and there is no free-text row.
// The WebApp sent only [1] as for a normal single-choice question; the terminal cursor moved but nothing was answered, so the card stayed pending (and reappeared after closing and reopening the app).
// The server marks such questions preview: true; notes in the answer (annotations.notes) are carried to it.notes and shown on the answered card.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { askAnswerable, askHasOwn, buildAskSteps, liveAskIndex, answeredRows, cardChaseDone } from "../logic.js";

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const QPV = "手册整体结构怎么排？";
// the entry read_page produces for the sample record tests/fixtures/ask_preview_notes.jsonl (tests/test_ask_question_preview.py checks the same one)
const qPv = { question: QPV, header: "手册结构", multiSelect: false, preview: true,
  options: ["概览在前，背景介绍在后（推荐）", "背景介绍当开篇"], descs: ["d1", "d2"] };
const qPvLive = { role: "ask", toolUseId: "toolu_01DemoAskNotes0000000001", questions: [qPv], answered: false, answers: null };
const qPvDone = Object.assign({}, qPvLive, { answered: true, answers: { [QPV]: "背景介绍当开篇" },
  notes: { [QPV]: "背景部分放前面也行，但默认折叠起来，需要时再展开。" } });
const Q = (n, extra) => Object.assign({ question: "q" + n, options: Array.from({ length: n }, (_, i) => "o" + (i + 1)) }, extra || {});
const parts = (rows) => rows.map((r) => [r.q, r.parts.map((p) => p.t + ":" + p.text).join("/")]);

test("preview question: choosing option k = digit key k moves the cursor + Enter selects (Enter submits for a single question)", () => {
  assert.deepEqual(buildAskSteps([qPv], [2]), [{ key: "2" }, { key: "enter" }]);
  assert.deepEqual(buildAskSteps([qPv], [1]), [{ key: "1" }, { key: "enter" }]);
});

test("preview question: no free-text row, free text is not sent (returns null), and the card shows no free-text input", () => {
  assert.equal(buildAskSteps([qPv], [{ text: "我自己写" }]), null);
  assert.equal(askHasOwn(qPv), false);
  assert.equal(askHasOwn(Q(3)), true);
  assert.equal(askHasOwn(Q(3, { multiSelect: true })), true);
  assert.equal(askAnswerable([qPv]), true);
});

test("preview question mixed among several questions: each follows its own rule, a trailing 1 is still appended to submit", () => {
  assert.deepEqual(buildAskSteps([qPv, Q(3)], [2, 3]), [{ key: "2" }, { key: "enter" }, { key: "3" }, { key: "1" }]);
  assert.deepEqual(buildAskSteps([Q(2), qPv], [{ text: "x" }, 1]),
    [{ key: "3" }, { text: "x" }, { key: "enter" }, { key: "1" }, { key: "enter" }, { key: "1" }]);
});

test("keystrokes for normal single / multi choice and free text keep their key sequence", () => {
  assert.deepEqual(buildAskSteps([Q(2)], [2]), [{ key: "2" }]);
  assert.deepEqual(buildAskSteps([Q(2)], [{ text: "芒果" }]), [{ key: "3" }, { text: "芒果" }, { key: "enter" }]);
  assert.deepEqual(buildAskSteps([Q(3, { multiSelect: true })], [{ multi: [1, 3] }]),
    [{ key: "1" }, { key: "3" }, { key: "right" }, { key: "1" }]);
  // Claude Code ignores a preview flag on multiSelect (the preview UI is single-choice only), so send as multi-select
  assert.deepEqual(buildAskSteps([Q(2, { multiSelect: true, preview: true })], [{ multi: [2] }]),
    [{ key: "2" }, { key: "right" }, { key: "1" }]);
});

test("sample record: once answered (with preview + notes) it is not waiting on you", () => {
  assert.equal(liveAskIndex([qPvLive]), 0);
  assert.equal(liveAskIndex([qPvDone]), -1);
  assert.equal(cardChaseDone("waiting", [qPvDone], 0), false); // a refetch does not treat the answered card as answerable
});

test("answered card: shows the chosen option + notes", () => {
  assert.deepEqual(parts(answeredRows([qPv], qPvDone.answers, qPvDone.notes)),
    [[QPV, "opt:背景介绍当开篇/note:背景部分放前面也行，但默认折叠起来，需要时再展开。"]]);
});

test("answered card: notes only, no option (answers is \"(notes only)\") shows only the notes", () => {
  const q = Object.assign({}, qPv, { question: "排版？" });
  assert.deepEqual(parts(answeredRows([q], { "排版？": "(notes only)" }, { "排版？": "两个都不好" })),
    [["排版？", "note:两个都不好"]]);
  // "(notes only)" without notes is not shown as answer text
  assert.deepEqual(answeredRows([q], { "排版？": "(notes only)" }), []);
});

test("answered card: single / multi choice / multiple questions / free text, notes argument optional", () => {
  const qs = [Q(3, { question: "一", multiSelect: true, options: ["A", "B", "C"] }), Q(2, { question: "二", options: ["X", "Y"] }),
    Q(2, { question: "三", options: ["X", "Y"] })];
  assert.deepEqual(parts(answeredRows(qs, { "一": "A, C, 我加的", "二": "Y", "三": "都不要" })),
    [["一", "opt:A/opt:C/txt:我加的"], ["二", "opt:Y"], ["三", "txt:都不要"]]);
  assert.deepEqual(parts(answeredRows(qs, { "二": "X" }, null)), [["二", "opt:X"]]);
});

test("answered card renders notes; preview questions show no free-text row", () => {
  const app = rd("app.js");
  assert.match(app, /answeredRows\(qs, it\.answers, it\.notes\)/);
  assert.match(app, /askHasOwn\(q\)/);
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
