// Without an installed pet the avatar uses the spirit flame (expression follows session state); the short Orca status is unified across three languages
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, statSync } from "node:fs";
import * as L from "../logic.js";
import { table } from "../i18n.js";

const WEB = new URL("../", import.meta.url);
const rd = (f) => readFileSync(new URL(f, WEB), "utf8");

test("spirit-flame expression is chosen by session state", () => {
  const face = (s) => L.flameAvatarSrc(s).match(/mascot-av-(\w+)\.png/)[1];
  assert.equal(face({ status: "waiting" }), "wait");
  assert.equal(face({ status: "busy" }), "busy");
  assert.equal(face({ status: "idle", rest: true }), "rest");
  assert.equal(face({ status: "idle", unread: true }), "done");
  assert.equal(face({ status: "idle" }), "idle");
  assert.equal(face(null), "idle");
  // waiting takes priority over unread/rest, using the same logic as the pet action (petState)
  assert.equal(face({ status: "waiting", unread: true, rest: true }), "wait");
  assert.match(L.flameAvatarSrc({}), /\?v=\d+$/);
});

test("avatar choice: use the pet if there is one, use the spirit flame only once the list is confirmed empty, show the first character if the list has not arrived", () => {
  const s = { id: "a", status: "busy" };
  assert.deepEqual(L.avatarPick(s, "boba", "some"), { kind: "pet", name: "boba" });
  assert.deepEqual(L.avatarPick(s, "boba", "none"), { kind: "pet", name: "boba" });
  assert.deepEqual(L.avatarPick(s, null, "none"), { kind: "flame", src: L.flameAvatarSrc(s) });
  assert.deepEqual(L.avatarPick(s, null, ""), { kind: "ini" });
  assert.deepEqual(L.avatarPick(s, null, "some"), { kind: "ini" });
});

test("avatar images for all five expressions exist, are size-bounded, and are in the shell precache", () => {
  const sw = rd("sw.js");
  for (const f of Object.values(L.FLAME_FACE)) {
    const u = new URL("icons/mascot-av-" + f + ".png", WEB);
    assert.ok(existsSync(u), "missing " + f);
    assert.ok(statSync(u).size < 20000, f + " too large");
    assert.ok(sw.includes('"/icons/mascot-av-' + f + ".png?v=" + L.FLAME_AV_V + '"'), "sw does not precache " + f);
  }
});

test("app.js: the avatar fallback uses the same criterion as the tool figure (decided only once the list response arrives)", () => {
  const a = rd("app.js");
  assert.match(a, /if \(res\) st\.petsKnown = st\.petNames\.length \? "some" : "none";/);
  assert.match(a, /avatarPick\(s, name, st\.petsKnown\)/); // setPet
  assert.ok(rd("style.css").includes(".pet.pet-flame"));
});

test("short Orca status is unified as Orca ✓ in three languages; the long form is kept", () => {
  assert.deepEqual(table()["mac.orcaOnShort"], ["Orca ✓", "Orca ✓", "Orca ✓"]);
  assert.deepEqual(table()["mac.orcaOn"], ["Mac · Orca online", "Mac · Orca 在线", "Mac · Orca 在線上"]);
});

test("version sync", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
