// Guest mode (guest account): local read state, only the bound session is kept, waiting on the admin is not a red dot, tab bar labels
import { test } from "node:test";
import assert from "node:assert/strict";
import { guestSnapshot, guestTab, guestBoundLabel, chatBadge, chatRow, bannerStep, newBannerState } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified Chinese

const B = "Web-guest-demo";
const s1 = (o) => ({ id: "c1", kind: "claude", name: B, plate: "guest-demo", zone: "Web", status: "idle", since: 100, origin: "user", ...o });

test("first open: current activity counts as seen, no red dot", () => {
  const g = guestSnapshot({ sessions: [s1()] }, null, null, B);
  assert.equal(g.seenAt, 100);
  assert.equal(g.snap.sessions[0].unread, false);
});

test("nothing recorded yet and the session is off duty: no baseline is recorded", () => {
  const g = guestSnapshot({ sessions: [] }, null, null, B);
  assert.equal(g.seenAt, null);
  assert.deepEqual(g.snap.sessions, []);
});

test("activity later than the local read mark: a reply to you; session-to-session / sub-agent turns do not count; the server's pinned/rest do not count", () => {
  let g = guestSnapshot({ sessions: [s1({ since: 200, pinned: true, rest: true, unread: false })] }, 100, null, B);
  const s = g.snap.sessions[0];
  assert.deepEqual([s.unread, s.pinned, s.rest, s.adminWait], [true, false, false, false]);
  assert.equal(chatBadge(g.snap), 1);
  g = guestSnapshot({ sessions: [s1({ since: 200, origin: "peer" })] }, 100, null, B);
  assert.equal(g.snap.sessions[0].unread, false);
  g = guestSnapshot({ sessions: [s1({ since: 200, status: "busy" })] }, 100, null, B);
  assert.equal(g.snap.sessions[0].unread, false);
});

test("the session being viewed counts as seen once it stops", () => {
  const g = guestSnapshot({ sessions: [s1({ since: 300 })] }, 100, "c1", B);
  assert.equal(g.seenAt, 300);
  assert.equal(g.snap.sessions[0].unread, false);
});

test("waiting on you means waiting on the admin for a guest: no red dot, no banner, the row says waiting for admin", () => {
  const g = guestSnapshot({ sessions: [s1({ status: "waiting", since: 500 })] }, 100, null, B);
  const s = g.snap.sessions[0];
  assert.equal(s.adminWait, true);
  assert.equal(chatBadge(g.snap), 0);
  const r = chatRow(s, [], 600);
  assert.equal(r.tag.text, "[等管理员]");
  assert.equal(r.badge, "");
  let b = bannerStep(newBannerState(), [], 0, null);
  b = bannerStep(b.state, g.snap.sessions, 1000, null);
  b = bannerStep(b.state, g.snap.sessions, 60000, null);
  assert.deepEqual(b.fire, []);
});

test("keeps only the bound session (snapshots of other accounts replayed offline are filtered out too); short names match by zone-plate", () => {
  const raw = { sessions: [s1(), { id: "c2", name: "Web-UI-refactor", plate: "UI-refactor", zone: "Web", status: "idle", since: 1 }] };
  assert.deepEqual(guestSnapshot(raw, 0, null, B).snap.sessions.map((s) => s.id), ["c1"]);
  const short = { sessions: [s1({ name: "guest-demo" })] };
  assert.deepEqual(guestSnapshot(short, 0, null, B).snap.sessions.map((s) => s.id), ["c1"]);
});

test("guest tab bar has only Messages and Me; the bound name drops the zone prefix", () => {
  assert.equal(guestTab("contacts"), "msg");
  assert.equal(guestTab("zones"), "msg");
  assert.equal(guestTab("board"), "msg");
  assert.equal(guestTab("me"), "me");
  assert.equal(guestTab(null), "msg");
  assert.equal(guestBoundLabel(B, [{ code: "Web" }]), "guest-demo");
  assert.equal(guestBoundLabel(B, []), "Web-guest-demo"); // strips the prefix using only the snapshot's zone codes, no hard-coded zones
  assert.equal(guestBoundLabel("", []), "");
});

test("admin rows are unaffected: waiting stays a red capsule", () => {
  const r = chatRow(s1({ status: "waiting" }), [], 600);
  assert.equal(r.tag.text, "[在等你]");
  assert.equal(r.badge, "wait");
});
