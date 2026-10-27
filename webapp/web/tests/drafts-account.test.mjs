// Drafts are namespaced per account; legacy shared key is never handed to another identity
import { test } from "node:test";
import assert from "node:assert/strict";
import { DraftMap, acctKey, LEGACY_DRAFTS_KEY } from "../logic.js";

const store = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), m }; };

test("acctKey: namespaced per account, empty without an account", () => {
  assert.equal(acctKey("zbs.drafts", "admin"), "zbs.drafts:admin");
  assert.notEqual(acctKey("zbs.drafts", "admin"), acctKey("zbs.drafts", "guest"));
  assert.equal(acctKey("zbs.drafts", ""), "");
});

test("a guest does not see the admin's draft", () => {
  const s = store();
  const a = DraftMap.load(acctKey("zbs.drafts", "admin"), s);
  a.set("c1", "ADMIN PRIVATE");
  const g = DraftMap.load(acctKey("zbs.drafts", "guest"), s);
  assert.equal(g.get("c1"), undefined);
  assert.equal(DraftMap.load(acctKey("zbs.drafts", "admin"), s).get("c1"), "ADMIN PRIVATE");
});

test("legacy un-namespaced drafts are dropped, not migrated", () => {
  const s = store();
  s.setItem(LEGACY_DRAFTS_KEY, JSON.stringify({ c1: "old" }));
  const g = DraftMap.load(acctKey("zbs.drafts", "guest"), s, true);
  assert.equal(g.get("c1"), undefined);
  assert.equal(s.getItem(LEGACY_DRAFTS_KEY), null);
});

test("no account: memory only, nothing written", () => {
  const s = store();
  const m = DraftMap.load("", s);
  m.set("c1", "x");
  assert.equal(m.get("c1"), "x");
  assert.equal(s.m.size, 0);
});
