// Dashboard page: when the Mac is disconnected, the counts get an "(as of hh:mm)" suffix
import test from "node:test";
import assert from "node:assert/strict";
import { boardAsOf } from "../logic.js";
import { setLang } from "../i18n.js";

const GEN = Math.floor(new Date(2026, 9, 24, 9, 5, 0).getTime() / 1000); // local time 09:05
const snap = (extra) => Object.assign({ generatedAt: GEN, sessions: [] }, extra || {});

test("not disconnected: empty string", () => {
  setLang("hans");
  assert.equal(boardAsOf(snap(), false, GEN + 5), "");
});
test("no snapshot: empty string", () => {
  assert.equal(boardAsOf(null, true, GEN), "");
});
test("no update for over 30 seconds: Simplified Chinese", () => {
  setLang("hans");
  assert.equal(boardAsOf(snap(), false, GEN + 40), "（截至 09:05）");
});
test("server marks stale: Traditional Chinese", () => {
  setLang("hant");
  assert.equal(boardAsOf(snap({ stale: true }), false, GEN + 5), "（截至 09:05）");
});
test("phone offline: English half-width parentheses with a leading space", () => {
  setLang("en");
  assert.equal(boardAsOf(snap(), true, GEN + 5), " (as of 09:05)");
});
test("invalid generatedAt: empty string (does not show 00:00)", () => {
  setLang("hans");
  assert.equal(boardAsOf({ stale: true }, false, GEN), "");
});
test("24-hour clock: 21:07", () => {
  setLang("hans");
  const g = Math.floor(new Date(2026, 9, 24, 21, 7, 0).getTime() / 1000);
  assert.equal(boardAsOf({ generatedAt: g }, true, g), "（截至 21:07）");
});
