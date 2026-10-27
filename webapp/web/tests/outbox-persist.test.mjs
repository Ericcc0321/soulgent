// Pending/failed outgoing text survives a reload, per account, restored as failed (never auto-resent)
import { test } from "node:test";
import assert from "node:assert/strict";
import { outboxDump, outboxRestore } from "../logic.js";

const pend = (o) => ({ text: "hi", raw: "hi", quote: "", at: 5, n0: 2, stage: "clock", body: { text: "hi", enter: true }, el: {}, ...o });

test("dump keeps unconfirmed text pends only", () => {
  const m = new Map([
    ["c1", [pend({}), pend({ done: true, text: "sent" }), pend({ items: [{}], text: "att" })]],
    ["c2", [pend({ failed: true, text: "bad" })]],
  ]);
  const o = JSON.parse(outboxDump(m));
  assert.deepEqual(Object.keys(o).sort(), ["c1", "c2"]);
  assert.equal(o.c1.length, 1);
  assert.equal(o.c1[0].text, "hi");
  assert.equal(o.c1[0].el, undefined);
  assert.equal(o.c2[0].text, "bad");
});

test("restore returns failed pends with the send body intact", () => {
  const m = new Map([["c1", [pend({ quote: "q" })]]]);
  const r = outboxRestore(outboxDump(m));
  const p = r.get("c1")[0];
  assert.equal(p.failed, true);
  assert.equal(p.text, "hi");
  assert.equal(p.quote, "q");
  assert.deepEqual(p.body, { text: "hi", enter: true });
});

test("restore tolerates garbage", () => {
  assert.equal(outboxRestore("not json").size, 0);
  assert.equal(outboxRestore(null).size, 0);
  assert.equal(outboxRestore('{"c1":[{"text":5}]}').size, 0);
});

test("empty dump when nothing pending", () => {
  assert.equal(outboxDump(new Map([["c1", [pend({ done: true })]]])), "{}");
});
