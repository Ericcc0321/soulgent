// Zone names and guest names are not hardcoded in the front end (zone short names/effects come from the snapshot zones; the default guest nickname comes from default in /api/profile)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { busyFx, FX_KINDS, guestDefaultName, guestProfileView, guestBoundLabel, zoneOfName } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const logic = rd("logic.js");
const app = rd("app.js");
const css = rd("style.css");

// The real word list lives outside the repo (data/leak-words.txt is not published); skip when the file is missing, so no real words appear in the repo
const wordsFile = new URL("../../data/leak-words.txt", import.meta.url);
const words = existsSync(wordsFile)
  ? readFileSync(wordsFile, "utf8").split("\n").filter((l) => l.trim() && !l.startsWith("#")).map((l) => l.split("\t").pop().trim()).filter(Boolean)
  : [];
test("front-end code contains none of the private word list", { skip: words.length === 0 && "no private word list data/leak-words.txt" }, () => {
  const esc = (w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  for (const [name, src] of [["logic.js", logic], ["app.js", app], ["style.css", css]]) {
    for (const w of words) {
      const rx = /^[\x00-\x7f]+$/.test(w) ? new RegExp("\\b" + esc(w) + "\\b", "i") : new RegExp(esc(w));
      assert.doesNotMatch(src, rx, name + " contains a private word-list entry");
    }
  }
  assert.doesNotMatch(logic, /FX_ZONE|ZONE_SHORT/);
});

test("effect styles have neutral names, and app.js dispatch table matches the stylesheet", () => {
  assert.deepEqual(FX_KINDS, ["marquee", "circuit", "halo", "orbit"]);
  for (const k of FX_KINDS) {
    assert.match(css, new RegExp("\\.fx-" + k + " \\{"), k);
    assert.match(css, new RegExp("\\.fxt\\." + k + " \\.mv"), k);
    assert.match(css, new RegExp("\\.fxt-" + k + " \\.cr-tm\\.live"), k);
  }
  assert.match(app, /\(\{ marquee: fxMarquee, circuit: fxCircuit, halo: fxHalo, orbit: fxOrbit \}\)\[want\.kind\]/);
});

test("busyFx picks the style by snapshot zones[].fx, whatever the zone code is called", () => {
  const zs = [{ code: "Alpha", fx: "halo" }, { code: "Beta" }];
  assert.equal(busyFx({ id: "a", status: "busy", zone: "Alpha" }, null, zs).kind, "halo");
  assert.equal(busyFx({ id: "a", status: "busy", zone: "Beta" }, "pet-walker", zs).kind, "walk");
});

test("session name prefixes are recognized only by the snapshot zones' codes", () => {
  const zs = [{ code: "Alpha" }];
  assert.equal(zoneOfName("Alpha-x", zs), "Alpha");
  assert.equal(zoneOfName("Zed-x", zs), null);
  assert.equal(guestBoundLabel("Alpha-x-y", zs), "x-y");
  assert.equal(guestBoundLabel("Zed-x-y", zs), "Zed-x-y");
});

test("default guest nickname: API default -> the default guest label; an API without a default keeps the name it gives", () => {
  assert.equal(guestDefaultName(null), "访客");
  assert.equal(guestDefaultName({ name: "x" }), "访客");
  assert.equal(guestDefaultName({ default: "  Alex " }), "Alex");
  assert.equal(guestProfileView({ name: "Alex" }).name, "Alex");
});

test("profile page: the guest edit-box placeholder and the admin hint both use the guest default nickname from the API", () => {
  const i = app.indexOf("function openProfileEdit");
  const body = app.slice(i, i + 4000);
  assert.match(body, /const dflt = st\.guest \? guestDefaultName\(st\.profile\) : t\("c.me"\);/);
  assert.match(body, /t\("pf.note", \{ guest: guestDefaultName\(st\.guestProfile\) \}\)/);
});

test("version sync: sw VERSION matches zbs-shell", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});

// a default equal to the built-in guest label (or empty) is displayed per current language; other values are kept as-is
test("default guest nickname per language: built-in default or empty -> Guest / 訪客 / 访客; a custom value is kept as-is", () => {
  for (const [lang, want] of [["en", "Guest"], ["hant", "訪客"], ["hans", "访客"]]) {
    setLang(lang);
    assert.equal(guestDefaultName({ default: "访客" }), want);
    assert.equal(guestDefaultName({ default: "" }), want);
    assert.equal(guestDefaultName(null), want);
    assert.equal(guestProfileView({ name: "", default: "访客" }).name, want);
    assert.equal(guestDefaultName({ default: "访客B" }), "访客B");
    assert.equal(guestProfileView({ name: "", default: "访客B" }).name, "访客B");
  }
  setLang("hans");
});
