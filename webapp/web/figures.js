// Tool figure layer.
// Sizes / spacing live in logic.js FIG (covered by tests).
// Structure: the first child of #msgs is a zero-height overlay .figs (outside #list, so renderList replacing content can't kill it) that scrolls with the list.
// Figure DOM persists; state lives in bots (key = tool label key + ":" + tool call id, one figure per call). After each renderList, reconcile once:
// re-find the anchor bubble and reposition, without resetting state or replaying the entrance; anything already final on first sight is drawn parked.
// State machine: rising → working → celebrate → walk → descend → (arrive) → parked / error (no separate waiting pose; long runs just roam at half speed)
// Animation uses only transform / opacity / clip-path; sprite frames are also transform (hold keyframes, see holdFrames in logic.js).
// Performance: dozens to hundreds of calls per turn are common. Bot DOM is created on demand (mount): parked history figures beyond the
// visible cap get no DOM and only count toward +N; figures pushed past the cap fade out and get display:none (fg-gx), so their wiggle stops.
import { FIG, FIG_BUILTIN, FIG_WAIT_SEC, holdFrames, figureGeom, setFigGeom, figBand, figTopCap, figTopShown, figLane, figQCap, figQStep, figQX, figCrowd, figRoam, figRoamRange, figDrift, figGlide } from "./logic.js";

const { CW, CH, QSTEP } = FIG;
// The figure (sprite directory + geometry) is not hardcoded: app.js calls setFigure after reading the pet manifest; until then the figure layer is not built (reconcile only records).
// Sprite directory: the pet selected in the manifest -> /pets/<name>/; no pet installed -> the built-in Soulgent flame FIG_BUILTIN (ships its own figure.json)
const FIGC = { base: "", geom: null, key: "" };
const FRAME_MS = 150;   // change frame every 150ms
const RISE_MS = 300;    // entrance: rises from behind the top edge of the bubble
const POP_MS = 520;     // pops up with the ✓ then starts walking
const REDUCE_MQ = window.matchMedia ? matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
const reduce = () => REDUCE_MQ.matches;
const rand = (a, b) => a + Math.random() * (b - a);

/* ---------- 6 kinds of tool badges (as on the Mac board), viewBox 16x16 ---------- */
const KINDS = {
  terminal: '<path d="M3.5 4.5 7 8l-3.5 3.5"/><path d="M8.5 11.5h4"/>',
  pencil: '<path d="M10.5 2.8 13.2 5.5 6 12.7l-3.3.6.6-3.3z"/><path d="M9 4.3l2.7 2.7"/>',
  magnifier: '<circle cx="7" cy="7" r="3.8"/><path d="M9.8 9.8 13.3 13.3"/>',
  globe: '<circle cx="8" cy="8" r="5.5"/><ellipse cx="8" cy="8" rx="2.3" ry="5.5"/><path d="M2.5 8h11"/>',
  agents: '<circle cx="5.5" cy="6" r="2"/><circle cx="11" cy="6" r="2"/><path d="M2 13c0-2 1.6-3.4 3.5-3.4S9 11 9 13"/><path d="M9.6 9.8c.4-.1.9-.2 1.4-.2 1.9 0 3.5 1.4 3.5 3.4"/>',
  thinking: '<circle class="fg-f" cx="3.8" cy="8" r="1.6"/><circle class="fg-f" cx="8" cy="8" r="1.6"/><circle class="fg-f" cx="12.2" cy="8" r="1.6"/>',
};

/* ---------- sprite: frame count = naturalWidth / 96; hidden until read ---------- */
const strips = {};
function strip(name) {
  if (!strips[name]) {
    const s = strips[name] = { name, url: FIGC.base + name + ".webp", n: 0, wait: new Set() };
    const im = new Image();
    im.onload = () => { s.n = Math.max(1, Math.round(im.naturalWidth / FIGC.geom.fw)); for (const b of s.wait) b.paint(); s.wait.clear(); };
    im.src = s.url;
  }
  return strips[name];
}

const S = { id: null, layer: null, list: null, onTap: null, groups: new Map(), bots: new Map(), ro: null, hold: 0, holdT: 0, dbT: 0, frozen: false };

/* ---------- one figure ---------- */
class Bot {
  constructor(g, f) {
    this.g = g; this.cls = f.cls; this.id = f.id; this.key = g.key + ":" + f.id;
    this.phase = ""; this.t0 = 0; this.want = "working"; this.err = false;
    this.x = 0; this.y = 0; this.jy = 0; this.walking = false; this.moving = false;
    this.T = new Set(); this.anim = null; this.sname = ""; this.mode = "pose";
    this.el = null; this.goneT = 0;                               // DOM is built on demand (mount)
  }
  mount() {
    if (this.el) return;
    const el = this.el = document.createElement("div");
    el.className = "fg fg-hide";                                   // hidden until rise()
    el.innerHTML = '<div class="fg-wig"><div class="fg-hop"><span class="fg-spr"><span class="fg-fr"></span></span>' +
      '<span class="fg-bdg"><svg viewBox="0 0 16 16">' + KINDS[this.cls] + '</svg></span><i class="fg-ok">✓</i><i class="fg-bad">✗</i></div></div>';
    el.style.setProperty("--wd", (1 + Math.random()).toFixed(2) + "s");     // wiggle period 1-2 s
    el.style.setProperty("--wp", (-Math.random() * 2).toFixed(2) + "s");   // each has its own phase
    this.wig = el.firstChild; this.hop = this.wig.firstChild;
    this.spr = this.hop.querySelector(".fg-spr"); this.fr = this.spr.firstChild;
    el.addEventListener("click", (e) => {
      e.stopPropagation(); e.preventDefault();
      if (!S.onTap) return;
      // The tap target is 32px with only 10px spacing, so they overlap: pick the one closest to the finger (both the one working on top and those parked below count)
      let best = this, bd = Infinity;
      for (const q of this.g.workers.concat(this.g.queue)) {
        const c = q.el && q.el.classList;
        if (!c || c.contains("fg-gone") || c.contains("fg-hide") || c.contains("fg-off")) continue;
        const r = q.spr.getBoundingClientRect();
        const d = Math.abs(r.left + r.width / 2 - e.clientX) + Math.abs(r.top + r.height * 0.75 - e.clientY);
        if (d < bd) { bd = d; best = q; }
      }
      S.onTap(best.g.key, best.id);
    });
    el.addEventListener("contextmenu", (e) => e.preventDefault());
    S.layer.appendChild(el);
    if (this.phase === "parked" || this.phase === "error") {     // a history figure appearing for the first time: draw it directly as parked
      el.classList.remove("fg-hide");
      el.classList.add("fg-docked", "fg-landed", this.err ? "fg-err" : "fg-done");
      el.style.setProperty("--cd", "0ms");
      this.show("7", "pose");
    }
  }
  gone(on) {                                                    // pushed out past the visible cap: fade out, then display:none after the fade (stops the wiggle)
    const c = this.el.classList;
    if (on === c.contains("fg-gone")) return;
    c.toggle("fg-gone", on);
    clearTimeout(this.goneT); this.goneT = 0;
    if (on) this.goneT = setTimeout(() => { this.goneT = 0; if (this.el && this.el.classList.contains("fg-gone")) this.el.classList.add("fg-gx"); }, 320);
    else c.remove("fg-gx");
  }
  set(phase) { this.phase = phase; this.t0 = Date.now(); }
  later(fn, ms) { const id = setTimeout(() => { this.T.delete(id); fn(); }, ms); this.T.add(id); return id; }
  clearT() { this.T.forEach(clearTimeout); this.T.clear(); }
  // switch sprite / playback mode: loop cycles frames, once plays one pass (within ms), pose holds frame 1
  show(name, mode, ms) { this.sname = name; this.mode = mode; this.onceMs = ms || 0; this.paint(); }
  paint() {
    const s = strip(this.sname);
    if (!s.n) { this.spr.classList.remove("fg-ready"); s.wait.add(this); return; }
    if (this.anim) { this.anim.cancel(); this.anim = null; }
    const fr = this.fr;
    fr.style.backgroundImage = "url(" + s.url + ")";
    fr.style.width = s.n * CW + "px";
    fr.style.backgroundSize = s.n * CW + "px " + CH + "px";
    fr.style.top = FIGC.geom.shift(this.sname).toFixed(2) + "px";
    fr.style.transform = "none";
    this.spr.classList.add("fg-ready");
    if (this.mode === "pose" || s.n < 2 || reduce()) return;
    const once = this.mode === "once";
    this.anim = fr.animate(holdFrames(s.n, CW), { duration: once ? this.onceMs : s.n * FRAME_MS, iterations: once ? 1 : Infinity }); // hold keyframes, not steps(): see holdFrames
    if (document.hidden) this.anim.pause();
  }
  pos(x, y, ms, ease, delay) {
    if (reduce()) ms = 0;
    this.el.style.transition = ms ? `transform ${ms}ms ${ease || "linear"} ${delay || 0}ms, opacity .3s` : "opacity .3s";
    this.el.style.transform = `translate(${x}px, ${y}px)`;
    this.x = x; this.y = y;
  }
  freeze() { const m = new DOMMatrix(getComputedStyle(this.el).transform); this.pos(m.m41, m.m42, 0); }
  dock(ms) { this.el.style.setProperty("--cd", (reduce() ? 0 : ms) + "ms"); this.el.classList.add("fg-docked"); }
  undock() { this.el.style.setProperty("--cd", "0ms"); this.el.classList.remove("fg-docked", "fg-landed", "fg-done", "fg-err", "fg-pop", "fg-gone", "fg-gx"); }
  squash(delay, sx, dy) {                                       // bumped: squash 90ms -> stretch 90ms -> settle 150ms (origin at the feet), with a slight vertical shake
    if (reduce()) return;
    const sy = 2 - sx;
    this.hop.animate([
      { transform: "none", easing: "ease-out" },
      { transform: `translateY(${dy}px) scale(${sx}, ${sy})`, offset: 90 / 330, easing: "ease-in-out" },
      { transform: `translateY(${-dy / 2}px) scale(${1 - (sx - 1) / 3}, ${1 + (sx - 1) / 3})`, offset: 180 / 330, easing: "ease-in-out" },
      { transform: "none" },
    ], { duration: 330, delay, fill: "backwards" });
  }
  recoil(delay, d) {                                            // the one that bumps: recoil d px (ease-out 120ms) -> return (ease-in-out 120ms)
    if (reduce()) return;
    this.hop.animate([
      { transform: "none", easing: "ease-out" },
      { transform: `translateX(${d}px)`, offset: 0.5, easing: "ease-in-out" },
      { transform: "none" },
    ], { duration: 240, delay });
  }
  destroy() { this.clearT(); clearTimeout(this.goneT); if (this.anim) this.anim.cancel(); if (this.el) this.el.remove(); }
}

/* ---------- one tool tag (anchored to the bubble above it) ---------- */
class Group {
  constructor(key) {
    this.key = key; this.bub = null; this.workers = []; this.queue = []; this.nextNudge = 0;
    this.moreTop = document.createElement("span"); this.moreTop.className = "fg-more";
    this.moreQ = document.createElement("span"); this.moreQ.className = "fg-more";
    S.layer.append(this.moreTop, this.moreQ);
  }
  geo(L) {
    L = L || S.layer.getBoundingClientRect();
    const b = this.bub.getBoundingClientRect();
    const who = this.bub.parentElement && this.bub.parentElement.querySelector(".cg-who");
    const last = who && who.lastElementChild ? who.lastElementChild.getBoundingClientRect() : null;
    return (this.geo0 = { l: b.left - L.left, r: b.right - L.left, t: b.top - L.top, b: b.bottom - L.top, nameR: (last ? last.right : b.left) - L.left });
  }
  live() { return !!this.bub && this.bub.isConnected; }
  topY(g) { return g.t - FIG.FOOT; }                                // feet on the bubble's top edge
  band(g) { return figBand(g.nameR, g.r); }
  shown(g) { const [lo, hi] = this.band(g); return figTopShown(this.workers.length, figTopCap(lo, hi)); }
  lane(i, k, g) { const [lo, hi] = this.band(g); return figLane(i, k, lo, hi); }
  w(g) { return g.r - g.l; }
  cap(g) { return figQCap(this.w(g)); }
  qN(g) { return Math.min(this.queue.length, this.cap(g)); }
  qX(i, n, g) { return figQX(i, n, g.r, this.w(g)); }
  qY(g) { return g.b - FIG.TOP; }                               // top of the visible body = bubble bottom (distance 0)
  layout(pre) {                                                 // pre: geometry measured first by layoutAll (read before write, to avoid forced reflow back and forth)
    const on = this.live();
    for (const b of this.workers.concat(this.queue)) if (b.el) b.el.classList.toggle("fg-off", !on);
    this.moreTop.classList.toggle("fg-off", !on); this.moreQ.classList.toggle("fg-off", !on);
    if (!on) return;
    const g = pre || this.geo(), k = this.shown(g);
    this.workers.forEach((b, i) => {
      b.el.classList.toggle("fg-hide", i >= k);
      if (i >= k) return;
      const [lo, hi] = figRoamRange(this.lane(i, k, g), this.band(g)); // when the segment is too narrow, roam the whole band instead of snapping back into the segment
      if (!b.walking) b.pos(Math.min(hi, Math.max(lo, b.x || lo)), this.topY(g), 0);
    });
    const over = this.workers.length - k;
    this.moreTop.classList.toggle("fg-on", over > 0);
    this.moreTop.textContent = "+" + over;
    this.moreTop.style.left = (this.lane(k, Math.max(1, k), g)[0] + 2) + "px";
    this.moreTop.style.top = (g.t - 14) + "px";
    const cap = this.cap(g), n = this.qN(g);
    const wa = (reduce() ? 0 : 0.3 + 0.7 * figCrowd(n, this.w(g))).toFixed(2) + "px";   // the more crowded, the stronger the wiggle
    this.queue.forEach((b, i) => {
      if (!b.el) { if (i >= cap) return; b.mount(); }           // history figures beyond the visible cap get no DOM
      b.gone(i >= cap);
      if (!b.moving) {
        const tx = this.qX(Math.min(i, cap), n, g), ty = this.qY(g) + b.jy;
        const gl = b.placed && glideOk(b) ? figGlide(tx - b.x, ty - b.y, i) : null;   // parked ones that change position glide over as a group, no teleporting
        if (gl) glide(b, tx, ty, gl); else b.pos(tx, ty, 0);
        b.placed = true;
      }
      b.el.style.setProperty("--wa", wa);
    });
    const extra = this.queue.length - n;
    this.moreQ.classList.toggle("fg-on", extra > 0);
    this.moreQ.textContent = "+" + extra;
    this.moreQ.style.left = (this.qX(Math.max(0, n - 1), n, g) - 17) + "px";
    this.moreQ.style.top = (g.b + 1) + "px";
  }
  destroy() { this.moreTop.remove(); this.moreQ.remove(); }
}

/* ---------- state machine ---------- */
// Whether a group shift is possible: parked (parked / error) with the DOM present and visible; always 0ms under reduced motion
function glideOk(b) {
  if (reduce() || !b.el || (b.phase !== "parked" && b.phase !== "error")) return false;
  const c = b.el.classList;
  return !(c.contains("fg-hide") || c.contains("fg-gone") || c.contains("fg-gx") || c.contains("fg-off"));
}
function glide(b, tx, ty, gl) {
  b.moving = true;
  b.pos(tx, ty, gl.ms, `cubic-bezier(.34,${gl.over},.64,1)`, gl.delay);
  if (gl.walk) b.show(gl.strip, "loop"); else b.squash(gl.delay, rand(1.08, 1.2), rand(-2, 2) || 1);
  b.later(() => {                                               // arrived: return to the held pose and measure once more to correct (now <6px from target -> 0ms placement, no recursion)
    b.moving = false;
    if (gl.walk) b.show("7", "pose");
    b.g.layout();
  }, gl.delay + gl.ms + 30);
}
const terminal = (w) => w === "done" || w === "error";

function rise(b) {                                              // entrance: rises from behind the bubble's top edge (clip below the top edge, translate upward)
  const g = b.g;
  b.mount();
  b.undock(); b.err = false; b.el.classList.remove("fg-hide");
  if (!g.workers.includes(b)) g.workers.push(b);
  b.set("rising"); b.show("7", "loop");
  b.x = 0; g.layout();
  if (reduce()) { toWork(b); return; }
  b.el.classList.add("fg-rising");
  b.wig.animate([{ transform: `translateY(${FIG.FOOT}px)` }, { transform: "none" }], { duration: RISE_MS, easing: "ease-out" });
  b.later(() => { b.el.classList.remove("fg-rising"); toWork(b); }, RISE_MS);
}
function toWork(b) {
  if (terminal(b.want)) {                                       // already finished on first appearance (finished between two refreshes): work a short while first, then wrap up (900ms)
    b.set("working"); b.show("7", "loop");
    b.finishing = true;
    b.later(() => finish(b), 900);
    return;
  }
  b.set("working");
  b.show("7", "loop");                                          // working uses 7.webp; there is only the roaming pose (when running long it is just half speed, see roam)
  roam(b);
}
function roam(b) {                                              // walk back and forth on the top edge; if the segment is too narrow, roam randomly across the whole band; half speed after FIG_WAIT_SEC seconds
  if (reduce()) return;
  const g = b.g;
  const loop = () => {
    if (b.phase !== "working" || !g.workers.includes(b)) return;  // finished/error is taken over by finish
    if (document.hidden || S.frozen || !g.live()) { b.later(loop, 1500); return; }          // hidden / Mac disconnected (frozen) / anchor missing: look again shortly, keeping the chain alive
    const gg = g.geo(), k = g.shown(gg), i = g.workers.indexOf(b);
    if (i >= k) { b.later(loop, 1500); return; }
    const slow = !!b.since && Date.now() / 1000 - b.since > FIG_WAIT_SEC;
    const m = figRoam(b.phase, b.x, g.lane(i, k, gg), g.band(gg), Math.random, slow);
    b.walking = true; b.pos(m.tx, g.topY(gg), m.ms);
    b.later(() => {
      b.walking = false;
      b.later(loop, m.pause);
    }, m.ms);
  };
  b.later(loop, 400 + Math.random() * 800);
}
function finish(b) {                                            // done / error: pop up ✓ (✗) with a hop
  const g = b.g;
  b.clearT(); b.finishing = false;
  const i = g.workers.indexOf(b);
  if (i >= 0) g.workers.splice(i, 1);
  b.el.classList.remove("fg-hide"); b.walking = false;
  if (g.live()) b.freeze();
  b.err = b.want === "error";
  b.set("celebrate");
  b.el.classList.add(b.err ? "fg-err" : "fg-done", "fg-pop");
  if (b.err) { b.el.classList.add("fg-hopping"); b.show("7", "pose"); }   // error: hop, hold frame 1
  else b.show("4", "once", POP_MS);                             // done: 4.webp celebration jump (the frames include the jump themselves, no extra CSS hop)
  g.layout();
  if (reduce() || !g.live()) { b.dock(0); arrive(b, true); return; }
  b.later(() => walk(b), POP_MS);
}
function walk(b) {                                              // (1) walk along the top edge to the top-right corner (1.webp, walking right)
  const g = b.g;
  if (!g.live()) { b.dock(0); arrive(b, true); return; }
  b.el.classList.remove("fg-pop", "fg-hopping");
  b.set("walk"); b.show("1", "loop");
  const gg = g.geo(), side = gg.r - 3;                          // body sits just outside the bubble's right edge, overlapping by 3px
  const ms1 = Math.max(150, Math.abs(side - b.x) / 60 * 1000);
  b.walking = true; b.pos(side, g.topY(gg), ms1);
  b.later(() => descend(b), ms1);
}
function descend(b) {                                           // (2) walk down along the right edge at constant speed, while the screen gradually clips and the badge moves to the head
  const g = b.g;
  if (!g.live()) { b.dock(0); arrive(b, true); return; }
  b.set("descend"); b.show("7", "loop");
  const gg = g.geo(), side = gg.r - 3;
  const n = g.qN(gg) + 1;
  b.jy = figQStep(n, g.w(gg)) < QSTEP ? (Math.random() < 0.5 ? 1 : 0) : 0;  // when standing crowded, randomly offset down by 0 or 1px
  const y1 = g.qY(gg) + b.jy;
  const ms2 = Math.min(900, Math.max(600, Math.abs(y1 - b.y) / 90 * 1000));
  b.pos(side, y1, ms2);
  b.dock(ms2);
  b.later(() => arrive(b, false), ms2);
}
function arrive(b, instant) {                                   // (3) one step left into slot 0; if someone is there, chain-push them aside
  const g = b.g;
  const live = g.live();
  const gg = live ? g.geo() : null;
  const APPROACH = instant ? 0 : 300;                           // decelerating approach
  const CONTACT = 40;                                           // the first step already touches the previous one
  const SLIDE = 330;
  const old = g.queue.filter((q) => q !== b);
  const cap = gg ? g.cap(gg) : 1;
  const bumped = !instant && old.length > 0;
  g.queue = [b].concat(old);
  b.set("arrive");
  if (!live) { settle(b); return; }
  const n = g.qN(gg), y = g.qY(gg);
  b.moving = true;
  b.pos(g.qX(0, n, gg), y + b.jy, APPROACH, "cubic-bezier(.15,.6,.3,1)");
  if (bumped) {
    b.recoil(CONTACT, rand(2, 6));                              // recoil distance random 2-6px
    let delay = CONTACT;
    old.forEach((q, i) => {
      if (i >= cap) return;                                     // those already folded into +N
      q.mount();
      if (i > 0) delay += rand(40, 90);                         // chain interval random 40-90ms
      const d = delay;
      const over = rand(1.3, 1.8).toFixed(2);                   // overshoot amount random
      q.moving = true;
      q.pos(g.qX(i + 1, n, gg), y + q.jy, SLIDE, `cubic-bezier(.34,${over},.64,1)`, d);
      q.squash(d, rand(1.08, 1.2), rand(-2, 2) || 1);           // squash 1.08-1.2, random vertical shake of +/-1-2px
      q.later(() => { q.moving = false; g.layout(); }, d + SLIDE + 20);   // the one pushed out of the last slot: fades out in layout and folds into +N
    });
  }
  if (instant) settle(b); else b.later(() => settle(b), Math.max(APPROACH, bumped ? CONTACT + 240 : 0));
}
function settle(b) {
  b.moving = false; b.walking = false;
  b.el.classList.remove("fg-pop", "fg-hopping");
  b.el.classList.add("fg-docked", "fg-landed", b.err ? "fg-err" : "fg-done");
  b.set(b.err ? "error" : "parked");
  b.show("7", "pose");                                          // hold frame 1 of 7.webp, completely still
  b.g.layout();
  sync(b);
}
function park(b) {                                              // first seen already in a terminal state: park at the bottom directly, no transition
  b.err = b.want === "error";                                   // no DOM built: layout only mounts those within the visible cap (mount draws them as parked)
  b.set(b.err ? "error" : "parked");
  b.g.queue.unshift(b);                                         // placed into slot 0 in call order: the newest is rightmost, the oldest folds into +N first
}
function sync(b, delay) {                                       // only transition by want in stable states; during a transition wait for it to end first
  const w = b.want;
  if (b.finishing) return;
  if (b.phase === "working") {
    if (terminal(w)) {                                          // several finishing in the same round: stagger the departure a bit so they do not all crowd to the bottom at once
      if (!delay) { finish(b); return; }
      b.finishing = true; b.clearT(); b.walking = false;
      b.later(() => finish(b), delay);
    }
    else if (w !== b.phase) { b.clearT(); if (b.walking && b.g.live()) b.freeze(); b.walking = false; toWork(b); b.g.layout(); }
  } else if (b.phase === "parked" || b.phase === "error") {
    // one figure maps to one call and a terminal state never reverts; only error / done may swap
    if (terminal(w) && (w === "error") !== b.err) {
      b.err = w === "error";
      b.phase = b.err ? "error" : "parked";
      if (b.el) { b.el.classList.toggle("fg-err", b.err); b.el.classList.toggle("fg-done", !b.err); }
    }
  }
}

/* ---------- public ---------- */
// The figure geometry is written into CSS variables of the figure layer (style.css supplies the var() fallback values)
function figVars() {
  if (!S.layer || !FIGC.geom) return;
  const g = FIGC.geom, st = S.layer.style;
  st.setProperty("--fg-rise", (CH - g.foot).toFixed(2) + "px");     // at entrance, clip below the feet (the bubble's top edge)
  st.setProperty("--fg-clip", g.clip + "px");                       // how much to clip at the top once parked
  st.setProperty("--fg-dy", g.bdgDy + "px");                        // how far the badge moves up once parked
}
// pick = pickFigure(pet manifest) from logic.js: { name, cfg } uses /pets/<name>/; null uses the built-in Soulgent flame (reads its figure.json).
// Repeated calls with the same figure do nothing; if the figure changes (e.g. the manifest only arrives after an offline start), the built figures are cleared and re-reconciled with the new figure.
export async function setFigure(pick) {
  const key = pick ? "p:" + pick.name + ":" + JSON.stringify(pick.cfg || null) : "b";
  if (key === FIGC.key) return;
  FIGC.key = key;
  let base, cfg;
  if (pick) { base = "/pets/" + encodeURIComponent(pick.name) + "/"; cfg = pick.cfg; }
  else {
    base = FIG_BUILTIN; cfg = null;
    try { const r = await fetch(base + "figure.json", { credentials: "same-origin" }); if (r.ok) cfg = await r.json(); } catch (e) { /* unreadable: use default geometry */ }
    if (FIGC.key !== key) return;                                // changed again while waiting
  }
  const had = !!FIGC.geom;
  FIGC.base = base; FIGC.geom = figureGeom(cfg); setFigGeom(FIGC.geom);
  for (const k of Object.keys(strips)) delete strips[k];
  figVars();
  const w = S.wait || (had && S.last);
  if (had) resetFigures(S.id);
  if (w) reconcileFigures(w[0], w[1], w[2]);
}
function ensureLayer(msgs, list) {
  if (S.layer && S.layer.isConnected) return;
  const layer = document.createElement("div");
  layer.className = "figs";
  layer.setAttribute("aria-hidden", "true");
  msgs.insertBefore(layer, msgs.firstChild);
  S.layer = layer; S.list = list;
  figVars();
  if (window.ResizeObserver) { S.ro = new ResizeObserver(() => layoutSoon()); S.ro.observe(list); S.ro.observe(msgs); }  // #msgs (including #older) size changes also need a re-layout
  addEventListener("resize", layoutSoon);
  document.addEventListener("visibilitychange", () => {
    if (!S.layer) return;
    for (const a of S.layer.getAnimations ? S.layer.getAnimations({ subtree: true }) : []) {
      if (document.hidden) a.pause(); else if (a.playState === "paused") a.play();
    }
  });
}
// Mac disconnected (snapshot expired): figures stay put and stop roaming (frame animation is paused by CSS body.mac-down); after recovery they walk as usual in the next round
export function setFrozen(on) { S.frozen = !!on; }
export function layoutAll() {
  if (!S.layer || (S.hold && performance.now() < S.hold)) return;
  const L = S.layer.getBoundingClientRect();
  const gs = [...S.groups.values()];
  const geos = gs.map((g) => (g.live() ? g.geo(L) : null));    // measure everything first
  gs.forEach((g, i) => g.layout(geos[i]));                      // then write positions together
}

// Lay out immediately, then once more 250ms after changes stop (catches the last frame's line wrap while drag-resizing, a flip hold that just expired, etc.)
function layoutSoon() {
  layoutAll();
  clearTimeout(S.dbT);
  S.dbT = setTimeout(function again() {
    if (S.hold && performance.now() < S.hold) { S.dbT = setTimeout(again, S.hold - performance.now() + 40); return; }  // still in hold: wait for it to expire, then re-run
    S.dbT = 0; layoutAll();
  }, 250);
}

// While a bubble flips its height is transitioning: do not re-layout the figures meanwhile (avoids jumping); lay out once with layoutAll afterwards
export function holdLayout(ms) {
  clearTimeout(S.holdT);
  S.hold = performance.now() + ms;
  S.holdT = setTimeout(() => { S.hold = 0; layoutAll(); layoutSoon(); }, ms);
}

// switch conversation / close the chat page: clear
export function resetFigures(id) {
  for (const b of S.bots.values()) b.destroy();
  for (const g of S.groups.values()) g.destroy();
  S.bots.clear(); S.groups.clear();
  S.id = id === undefined ? null : id;
  S.seeded = false;
}

// plan = result of figurePlan(...); anchor bubbles in the DOM carry data-fig=key (set by chatGroup in app.js).
// opts.instant: for things like page-load / just-opened chat page, newly appearing finished tools are drawn directly as parked;
// also the first call after a conversation switch, or tools finished more than HIST_SEC seconds ago, are parked directly. The transition plays only for tools that finish while the chat page is open.
const HIST_SEC = 60;
export function reconcileFigures(plan, id, opts) {
  const msgs = document.getElementById("msgs"), list = document.getElementById("list");
  if (!msgs || !list) return;
  if (!FIGC.geom) { S.wait = [plan, id, opts]; return; }       // figure not set yet: come back once it is (setFigure re-runs it)
  S.wait = null;
  ensureLayer(msgs, list);
  if (opts && opts.onTap) S.onTap = opts.onTap;
  S.last = [plan, id, opts && opts.onTap ? { onTap: opts.onTap } : null];
  if (id !== S.id) resetFigures(id);
  const first = !S.seeded; S.seeded = true;
  const instant = first || !!(opts && opts.instant);
  const nowSec = Date.now() / 1000;
  const anchors = new Map();
  for (const el of list.querySelectorAll(".m[data-fig]")) anchors.set(el.dataset.fig, el);
  const live = new Set();
  const fresh = [];
  let stag = 0;
  for (const e of plan || []) {
    const bub = anchors.get(e.key);
    if (!bub) continue;
    let g = S.groups.get(e.key);
    if (!g) { g = new Group(e.key); S.groups.set(e.key, g); }
    g.bub = bub;                                                // anchor changed: layout below teleports there, state is kept
    for (const f of e.figs) {
      const k = e.key + ":" + f.id;
      live.add(k);
      let b = S.bots.get(k);
      const isNew = !b;
      if (!b) { b = new Bot(g, f); S.bots.set(k, b); }
      b.want = f.state; b.since = f.since;
      if (isNew) {
        b.hist = terminal(f.state) && (instant || !f.since || nowSec - f.since > HIST_SEC);
        fresh.push(b);
      } else if (!b.finishing && b.phase === "working" && terminal(f.state)) {
        sync(b, stag); stag += rand(250, 450);
      } else sync(b);
    }
  }
  for (const [k, b] of S.bots) {                                // those gone from the plan (the tool tag is gone)
    if (live.has(k)) continue;
    const g = b.g;
    g.workers = g.workers.filter((x) => x !== b); g.queue = g.queue.filter((x) => x !== b);
    b.destroy(); S.bots.delete(k);
  }
  for (const [key, g] of S.groups) if (!g.workers.length && !g.queue.length && ![...S.bots.values()].some((b) => b.g === g)) { g.destroy(); S.groups.delete(key); }
  for (const b of fresh) { if (b.hist) park(b); }
  layoutAll();
  for (const b of fresh) {
    if (b.hist) continue;
    if (!stag) rise(b); else { b.set("queued"); b.later(() => rise(b), stag); }
    stag += rand(250, 450);
  }
}

// Once a second (hooked on tickLive in app.js): once settled, every 3-8 s a random one nudges its neighbor
export function tickFigures() {
  if (document.hidden || !S.layer) return;
  if (!(S.hold && performance.now() < S.hold)) {                // fallback: if bubble geometry drifted from the last layout (displacement the RO cannot see), re-layout once
    const gs = [...S.groups.values()].filter((g) => g.live() && g.geo0);
    if (gs.length) {
      const L0 = S.layer.getBoundingClientRect();
      const cur = gs.map((g) => { const r = g.bub.getBoundingClientRect(); return { l: r.left - L0.left, r: r.right - L0.left, t: r.top - L0.top, b: r.bottom - L0.top }; });
      if (gs.some((g, i) => figDrift(g.geo0, cur[i]))) layoutAll();
    }
  }
  if (reduce()) return;
  const now = Date.now();
  for (const g of S.groups.values()) {
    const cap = g.live() && g.geo0 ? g.cap(g.geo0) : 0;          // use what the last layout measured, do not measure every second
    const vis = g.queue.slice(0, cap);
    if (vis.length < 2 || vis.some((q) => !q.el || q.moving || q.phase === "arrive")) continue;
    if (!g.nextNudge) { g.nextNudge = now + rand(3000, 8000); continue; }
    if (now < g.nextNudge) continue;
    g.nextNudge = now + rand(3000, 8000);
    const i = Math.floor(Math.random() * (vis.length - 1)), a = vis[i], nb = vis[i + 1];   // a pushes nb to the left
    a.hop.animate([{ transform: "none" }, { transform: "translateX(-2px) rotate(-6deg)", offset: 0.4 }, { transform: "none" }],
      { duration: 420, easing: "ease-in-out" });
    nb.squash(120, rand(1.05, 1.1), rand(-1, 1));
  }
}
