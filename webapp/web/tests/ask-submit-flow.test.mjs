// Every question card is "select first, then tap submit"; the preview note row is always shown and there is no attach-note switch.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { table } from "../i18n.js";
const I18N = table();
import * as logic from "../logic.js";

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const pq = (n) => ({ question: "pq", preview: true, multiSelect: false,
  options: Array.from({ length: n }, (_, i) => "o" + (i + 1)), previews: Array.from({ length: n }, () => "p") });

test("app.js: no quick() tap-to-send, note-sw, ask.withNote or noteOn", () => {
  const app = rd("app.js");
  assert.doesNotMatch(app, /\bquick\(/);
  assert.doesNotMatch(app, /note-sw|noteSw/);
  assert.doesNotMatch(app, /ask\.withNote/);
  assert.doesNotMatch(app, /noteOn/);
});

test("the submit button is always shown: submitRow is created unconditionally and never hidden", () => {
  const app = rd("app.js");
  assert.match(app, /const submitRow = h\("div", "ask-go"\);/);
  assert.doesNotMatch(app, /submitRow\.hidden/);
  assert.doesNotMatch(app, /if \(submitRow\)/);
  assert.match(app, /submit\.disabled = !buildAskSteps\(qs, picksOf\(\)\)/);
});

test("tapping an option only selects it: the option onclick does not call sendNow", () => {
  const app = rd("app.js");
  const i = app.indexOf("b.onclick = () => {\n        if (q.multiSelect)");
  assert.ok(i > 0);
  const body = app.slice(i, app.indexOf("rows.push(b)", i));
  assert.doesNotMatch(body, /sendNow/);
});

test("preview question picksOf is always { pick, note }; the note row is always shown and never hidden", () => {
  const app = rd("app.js");
  assert.match(app, /if \(isPreviewQ\(q\)\) return \{ pick: state\.sel\[i\], note: state\.note\[i\] \|\| "" \}/);
  assert.doesNotMatch(app, /noteRow\.hidden/);
  assert.match(app, /grp\.append\(noteRow\)/);
});

test("Enter: submits only for a single question with submit enabled, otherwise blurs", () => {
  const app = rd("app.js");
  assert.match(app, /if \(single && !submit\.disabled\) sendNow\(submit, ""\);\n\s+else inp\.blur\(\);/);
  assert.match(app, /if \(single && !submit\.disabled\) sendNow\(submit, ""\);\n\s+else noteInp\.blur\(\);/);
});

test("style.css has no note-sw; the three-language ask.notePh reads as optional", () => {
  assert.doesNotMatch(rd("style.css"), /note-sw/);
  assert.deepEqual(I18N["ask.notePh"], ["Add a note…", "附带备注…", "附帶備註…"]);
  assert.equal(I18N["ask.withNote"], undefined);
});

test("buildAskSteps: an empty note on a preview question falls back to [k, enter], with a note the key sequence is the plain one; nothing selected = null", () => {
  assert.deepEqual(logic.buildAskSteps([pq(2)], [{ pick: 2, note: "" }]), [{ key: "2" }, { key: "enter" }]);
  assert.deepEqual(logic.buildAskSteps([pq(2)], [{ pick: 2, note: "hi" }]),
    [{ key: "1" }, { key: "2" }, { key: "n" }, { text: "hi" }, { key: "enter" }]);
  assert.equal(logic.buildAskSteps([pq(2)], [{ pick: undefined, note: "" }]), null);
});

test("sw version matches the shell", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
