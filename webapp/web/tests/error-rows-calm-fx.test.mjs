// Errors become centered system rows, unexpected exits are not pushed to guests (no banner either), and zone effects drop to a calm tier while background tasks run
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as L from "../logic.js";
import { setLang } from "../i18n.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const each = (fn) => { for (const l of ["en", "hans", "hant"]) { setLang(l); fn(l); } setLang("hans"); };
const T0 = Date.parse("2026-10-24T10:00:00Z") / 1000;

test("1 apiError system row: quota exhausted amber, error brick red, sign-in required a fixed sentence; text uses Claude Code's original wording (API Error: prefix stripped)", () => {
  const items = [
    { role: "user", text: "hi", ts: "2026-10-24T10:00:00Z" },
    { role: "notice", code: "apiError", kind: "rate_limit", text: "You've hit your limit · resets 1pm", ts: "2026-10-24T10:00:01Z" },
    { role: "notice", code: "apiError", kind: "api", text: "529 Overloaded", ts: "2026-10-24T10:00:02Z" },
    { role: "notice", code: "apiError", kind: "auth", text: "Failed to authenticate", ts: "2026-10-24T10:00:03Z" },
  ];
  const sys = L.chatPlan(items, {}).filter((b) => b.t === "sys");
  assert.deepEqual(sys.map((b) => [b.i, b.cls]), [[1, "limit"], [2, "err"], [3, "err"]]);
  assert.equal(sys[0].text, "You've hit your limit · resets 1pm");
  assert.equal(sys[1].text, "529 Overloaded");
  each((l) => {
    const want = { en: "Needs sign-in again", hans: "要重新登录", hant: "需要重新登入" }[l];
    assert.equal(L.sysLineText(items[3]), want);
  });
  // the compaction notice carries no cls
  assert.equal(L.chatPlan([{ role: "notice", code: "compacted", ts: "2026-10-24T10:00:00Z" }], {}).find((b) => b.t === "sys").cls, undefined);
  assert.equal(L.isSysLine(items[1]), true);
});

test("2 both places that draw system rows carry cls; styles have .tm.limit / .tm.err", () => {
  const a = rd("app.js"), c = rd("style.css");
  assert.equal((a.match(/h\("div", "tm" \+ \(b\.cls/g) || []).length, 2, "both the main chat page and the sub-agent page carry cls");
  assert.match(c, /\.tm\.err\s*\{[^}]*var\(--err\)/);
  assert.match(c, /\.tm\.limit\s*\{[^}]*var\(--orange\)/);
});

test("3 guest snapshots show no unexpected-exit banner; the admin still does", () => {
  const GONE = { id: "s1", name: "W-x", zone: "W", status: "idle", since: T0 - 600, kind: "claude", disconnected: true, disconnectedSince: T0 - 100 };
  const fire = (sessions) => {
    const s0 = L.bannerStep(L.newBannerState(), [], 0, null).state;
    const s1 = L.bannerStep(s0, sessions, 1000, null).state;
    return L.bannerStep(s1, sessions, 21000, null).fire;
  };
  assert.deepEqual(fire([GONE]), [{ id: "s1", kind: "lost" }]);
  const g = L.guestSnapshot({ sessions: [GONE] }, T0 - 1000).snap.sessions[0];
  assert.deepEqual(fire([g]), []);
});

test("4 zone effects drop to the calm tier while background tasks run (idle + bgTasks>0 + not bgStale); busy / stuck are unaffected", () => {
  const Zs = [{ code: "B", fx: "halo" }];
  const base = { id: "s1", zone: "B", status: "idle", bgTasks: 1, bgStale: false };
  const bg = L.busyFx(base, null, Zs, null, "none");
  assert.equal(bg.kind, "halo");
  assert.equal(L.fxCalm(bg), true);
  assert.equal(L.fxCalm(L.busyFx({ ...base, status: "busy" }, null, Zs, null, "none")), false); // busy + background: strong tier
  assert.equal(L.busyFx({ ...base, bgStale: true }, null, Zs, null, "none"), null); // stuck: no effect
  assert.equal(L.fxCalm(L.busyFx(base, "x", [], { walk: true }, "ok")), false); // unassigned zone, walking: already standing still, no need to drop a tier
  assert.equal(L.fxCalm(null), false);
  const a = rd("app.js"), c = rd("style.css");
  assert.match(a, /fx-calm/);
  assert.match(c, /\.fx-calm\b/);
});
