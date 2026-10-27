// Preview questions drop the per-option "add note" tag (there is no attach-note switch, the note row is always shown).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { table } from "../i18n.js";
const I18N = table();
import * as logic from "../logic.js";

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const pq = (n) => ({ question: "pq", preview: true, multiSelect: false,
  options: Array.from({ length: n }, (_, i) => "o" + (i + 1)), previews: Array.from({ length: n }, () => "p") });

test("there is no ask.addNote and no ask.withNote switch", () => {
  assert.equal(I18N["ask.addNote"], undefined);
  assert.equal(I18N["ask.withNote"], undefined);
});

test("app.js / style.css: no o-nb / addNote / noteRowMove / note-sw", () => {
  const app = rd("app.js");
  assert.doesNotMatch(app, /o-nb/);
  assert.doesNotMatch(app, /ask\.addNote/);
  assert.doesNotMatch(app, /noteRowMove/);
  assert.doesNotMatch(app, /note-sw/);
  assert.equal(logic.noteRowMove, undefined);
  assert.doesNotMatch(rd("style.css"), /o-nb/);
});

test("the note row is fixed at the end of the option group: no more after()/remove() moves and no hidden toggling", () => {
  const app = rd("app.js");
  assert.doesNotMatch(app, /\.after\(noteRow\)/);
  assert.doesNotMatch(app, /noteRow\.remove\(\)/);
  assert.doesNotMatch(app, /noteRow\.hidden/);
  assert.match(app, /grp\.append\(noteRow\)/);
});

test("buildAskSteps key sequence is the plain one; switch on with no option selected = null", () => {
  assert.equal(logic.buildAskSteps([pq(2)], [{ pick: undefined, note: "hi" }]), null);
  assert.deepEqual(logic.buildAskSteps([pq(2)], [{ pick: 2, note: "hi" }]),
    [{ key: "1" }, { key: "2" }, { key: "n" }, { text: "hi" }, { key: "enter" }]);
});
