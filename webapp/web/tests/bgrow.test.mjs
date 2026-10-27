import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { sortChat } from "../logic.js";

const css = readFileSync(new URL("../style.css", import.meta.url), "utf8");
const S = (id, o = {}) => ({ id, name: "Docs-" + id, plate: id, zone: "Docs", status: "idle", since: 100, unread: false, pinned: false, rest: false, ...o });
const ids = (l) => l.map((s) => s.id);

test("sortChat: idle + background running ranks with busy, ahead of plain idle even if older", () => {
  const out = sortChat([
    S("plain", { since: 500 }),
    S("bg", { since: 50, bgTasks: 2, bgStale: false }),
    S("busy", { status: "busy", since: 20 }),
  ]);
  assert.deepEqual(ids(out), ["bg", "busy", "plain"]); // tier 4 sorted by since desc: bg(50) before busy(20)
});

test("sortChat: stuck background (bgStale) stays with plain idle", () => {
  const out = sortChat([
    S("stale", { since: 50, bgTasks: 1, bgStale: true }),
    S("plain", { since: 500 }),
    S("busy", { status: "busy", since: 20 }),
  ]);
  assert.deepEqual(ids(out), ["busy", "plain", "stale"]);
});

test("sortChat: bg-running ranks below unread and above disconnected", () => {
  const out = sortChat([
    S("bg", { bgTasks: 1, bgStale: false }),
    S("gone", { disconnected: true, disconnectedSince: 900 }),
    S("unread", { unread: true, since: 1 }),
  ]);
  assert.deepEqual(ids(out), ["unread", "bg", "gone"]);
});

test("css: fx-calm stops the avatar (.cr-pin) animation from zone effects", () => {
  const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].filter(
    (m) => m[1].split(",").some((s) => /^\s*\.fx-calm\s+\.cr-pin\s*$/.test(s)) && /animation\s*:\s*none/.test(m[2])
  );
  assert.ok(rules.length >= 1, ".fx-calm .cr-pin { animation: none } missing");
  // it must come after the zone rules it overrides (equal specificity -> later wins)
  const at = css.search(/\.fx-calm\s+\.cr-pin\s*\{/);
  for (const z of ["marquee", "circuit", "orbit"]) assert.ok(css.indexOf(".fx-" + z + " .cr-pin") < at, z + " rule must precede the calm override");
});
