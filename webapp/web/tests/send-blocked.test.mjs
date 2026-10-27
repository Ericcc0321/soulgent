// Admin send blocked by the menu, silent returns when opening a session are logged, search result / banner avatars drop the gray background
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const app = read("../app.js");
const css = read("../style.css");
const fnBody = (name) => {
  const i = app.search(new RegExp("\\n(async )?function " + name + "\\("));
  assert.ok(i >= 0, "function " + name + " not found in app.js");
  return app.slice(i, app.indexOf("\n}\n", i));
};

test("sendText: when at-menu rejects, the optimistic bubble is removed (dropOnFail) and the original text goes back into the input box", () => {
  const b = fnBody("sendText") + fnBody("queueText"); // the queuing part lives in queueText (shared with resend)
  assert.match(b, /dropOnFail\(st\.sendErr\)/);
  assert.match(b, /\$\("#reply"\)\.value = pend\.raw;/);
  assert.match(fnBody("submitSend"), /st\.sendErr = r\.error/);
});

test("both silent returns in openDetail log diag open-skipped {id, why}", () => {
  const b = fnBody("openDetail");
  assert.match(b, /diag\("open-skipped", \{ id, why: "gone" \}\)/);
  assert.match(b, /diag\("open-skipped", \{ id, why: "already-open" \}\)/);
});

test("#cr-sout and .bn avatars drop the gray square, initials get a dark gray rounded backing", () => {
  const i = css.indexOf("#cr-sout .cr-av, #cr-sout .cr-av.off");
  assert.ok(i >= 0);
  const blk = css.slice(i);
  assert.match(blk, /#cr-sout \.cr-av, #cr-sout \.cr-av\.off, #cr-sout \.cr-av\.lead,\s*\.bn \.cr-av, \.bn \.cr-av\.off, \.bn \.cr-av\.lead \{ background: none; box-shadow: none; \}/);
  assert.match(blk, /#cr-sout \.cr-ini \{ background: #2a2a2a;/);
  assert.match(blk, /\.bn \.cr-ini \{ background: #2a2a2a;/);
});
