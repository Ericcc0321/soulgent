import test from "node:test";
import assert from "node:assert/strict";
import { formatAlert } from "../logic.js";
import { setLang, t } from "../i18n.js";
setLang("en");

const LINE = { cls: "h", text: "Some messages may not display: unrecognized Claude Code format" };

test("formatAlert: gray line from page formatWarn or session formatWarn / formatWarnings; never for guests", () => {
  assert.equal(formatAlert(false, "", { id: "a" }), null);
  assert.equal(formatAlert(false, "", null), null);
  assert.equal(formatAlert(false, "", { formatWarnings: [] }), null);
  assert.deepEqual(formatAlert(false, "1 line(s) not understood", { id: "a" }), LINE);
  assert.deepEqual(formatAlert(false, "", { formatWarn: "unknown type" }), LINE);
  assert.deepEqual(formatAlert(false, "", { formatWarnings: ["x"] }), LINE);
  assert.equal(formatAlert(true, "1 line(s) not understood", { formatWarn: "x", formatWarnings: ["x"] }), null);
});

test("formatAlert text exists in all languages", () => {
  for (const lang of ["en", "hans", "hant"]) {
    setLang(lang);
    assert.notEqual(t("dt.fmtWarn"), "dt.fmtWarn");
  }
  setLang("en");
});
