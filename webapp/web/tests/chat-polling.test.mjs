// Chat page polls every second while busy, re-fetches the waiting card, and records diagnostic timing events
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";

const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
const body = (name) => {
  const i = app.indexOf("\nfunction " + name + "(");
  assert.ok(i >= 0, name);
  return app.slice(i, app.indexOf("\n}\n", i));
};

test("detailPollMs: 1s when busy / waiting and the page is visible, otherwise 3s", () => {
  assert.equal(L.detailPollMs("busy", true), 1000);
  assert.equal(L.detailPollMs("waiting", true), 1000);
  assert.equal(L.detailPollMs("idle", true), 3000);
  assert.equal(L.detailPollMs(undefined, true), 3000);
  assert.equal(L.detailPollMs("busy", false), 3000);
  assert.equal(L.detailPollMs("waiting", false), 3000);
});

test("cardChaseDone: stops only once the card is fetched, no longer waiting, and 3 seconds have passed", () => {
  const pend = [{ role: "user", text: "x" }, { role: "tool", pending: true, name: "Bash" }];
  const plain = [{ role: "user", text: "x" }, { role: "assistant", text: "y" }];
  const ask = [{ role: "user", text: "x" }, { role: "ask", answered: false }];
  assert.equal(L.cardChaseDone("waiting", plain, 500), false);
  assert.equal(L.cardChaseDone("waiting", pend, 500), true);
  assert.equal(L.cardChaseDone("waiting", ask, 500), true);
  assert.equal(L.cardChaseDone("busy", plain, 500), true);
  assert.equal(L.cardChaseDone("waiting", plain, 3000), true);
  assert.equal(L.cardChaseDone("waiting", plain, 2999), false);
  assert.equal(L.cardChaseDone("waiting", null, 100), false);
});

test("pollDetail queues instead of dropping when loading; loadPage re-polls once when it finishes; polling reschedules itself by state", () => {
  assert.match(body("pollDetail"), /if \(st\.loading\) \{ st\.pollQueued = true; return; \}/);
  assert.doesNotMatch(body("pollDetail"), /st\.loading \|\|/);
  assert.match(app, /if \(st\.pollQueued && token === st\.dToken\) \{ st\.pollQueued = false; setTimeout\(pollDetail, 0\); \}/);
  assert.match(body("startDetailPolling"), /detailPollMs\(/);
  assert.match(body("startDetailPolling"), /setTimeout\(tick/);
  assert.doesNotMatch(body("startDetailPolling"), /setInterval/);
  assert.match(app, /if \(prev && prev\.status !== s\.status\) chaseCard\(\);/);
  assert.match(body("chaseCard"), /cardChaseDone\(/);
  assert.match(body("chaseCard"), /CARD_CHASE_STEP_MS/);
});

test("diagnostic timing: wait-seen / card-shown are recorded only while diagnostics are on", () => {
  assert.match(body("diagWaitSeen"), /^\nfunction diagWaitSeen\(oldById, snap\) \{\n  if \(!D\) return;/);
  assert.match(body("diagWaitSeen"), /diag\("wait-seen", \{[^}]*gen: snap\.generatedAt[^}]*at: Date\.now\(\)/);
  assert.match(body("diagCardShown"), /^\nfunction diagCardShown\(id, kind\) \{\n  if \(!D\) return;/);
  assert.match(body("diagCardShown"), /diag\("card-shown", \{ id,/);
  assert.match(body("renderItems"), /diagCardShown\(st\.detailId/);
  assert.match(body("applySnapshot"), /diagWaitSeen\(oldById, snap\)/);
});

test("the sw version matches the shell", () => {
  assert.match(readFileSync(new URL("../sw.js", import.meta.url), "utf8"), /const VERSION = "v142";/);
  assert.match(readFileSync(new URL("../index.html", import.meta.url), "utf8"), /name="zbs-shell" content="v142"/);
});
