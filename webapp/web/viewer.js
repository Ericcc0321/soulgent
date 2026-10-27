// Full-screen image viewer: thumb first, then full; pinch zoom 1–4×, double-tap 1×↔2×, swipe left/right to change image, swipe down to close.
// Open/close use only history.replaceState and never push history (the iOS home-screen app's swipe-back would go to the wrong page).
import { fileUrl, vwNext, vwScale, vwTapAction, fileFailKey, attName, shareFailPlan } from "./logic.js";
import { t } from "./i18n.js"; // three languages

// Swallowed exceptions are handed to diagErr in app.js (it listens for sg-err; this module cannot import app.js)
function reportErr(where, err) {
  try { globalThis.dispatchEvent(new CustomEvent("sg-err", { detail: { where, err } })); } catch (e) { /* ignore */ }
}

const SWIPE_X = 50;   // horizontal swipe threshold to switch images, px
const SWIPE_Y = 80;   // swipe-down-to-close threshold, px
const TAP_MOVE = 10;  // movement below this counts as a tap
const DBL_MS = 300;   // double-tap interval

const st = { imgs: [], idx: 0, sid: "", s: 1, tx: 0, ty: 0, open: false, gen: 0 };
let root = null, stage = null, img = null, dots = null, prevState = null;
const g = { mode: "", x0: 0, y0: 0, tx0: 0, ty0: 0, d0: 0, s0: 1, moved: 0, lastTap: 0, dx: 0, dy: 0 };

const reduced = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

function build() {
  if (root) return;
  root = document.getElementById("vw");
  if (!root) { root = document.createElement("div"); root.id = "vw"; root.className = "vw"; root.hidden = true; document.body.appendChild(root); }
  root.innerHTML = '<div class="vw-stage"><img class="vw-img" alt="" draggable="false"></div>' +
    '<div class="vw-dots"></div>' +
    '<button class="vw-share" type="button" aria-label="' + t("vw.share") + '">' +
    '<svg viewBox="0 0 24 24" width="22" height="22"><path d="M12 3v12M8 7l4-4 4 4M5 12v8h14v-8" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button>' +
    '<button class="vw-close" type="button" aria-label="' + t("c.close") + '">' +
    '<svg viewBox="0 0 24 24" width="22" height="22"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg></button>';
  stage = root.querySelector(".vw-stage");
  img = root.querySelector(".vw-img");
  dots = root.querySelector(".vw-dots");
  root.querySelector(".vw-close").addEventListener("click", closeViewer);
  root.querySelector(".vw-share").addEventListener("click", share);
  root.addEventListener("touchstart", onStart, { passive: false });
  root.addEventListener("touchmove", onMove, { passive: false });
  root.addEventListener("touchend", onEnd);
  root.addEventListener("touchcancel", onEnd);
  root.addEventListener("wheel", onWheel, { passive: false });
  root.addEventListener("dblclick", (e) => { if (e.target === img) toggleZoom(); });
  root.addEventListener("click", (e) => { if (e.target === root || e.target === stage) closeViewer(); });
}

function apply(anim) {
  img.style.transition = anim && !reduced() ? "transform .2s ease" : "none";
  img.style.transform = `translate(${st.tx}px,${st.ty}px) scale(${st.s})`;
}
function setBg(a) { root.style.background = `rgba(0,0,0,${a})`; }
function resetView(anim) { st.s = 1; st.tx = 0; st.ty = 0; setBg(1); apply(anim); }

function renderDots() {
  const n = st.imgs.length;
  dots.hidden = n < 2;
  dots.innerHTML = n < 2 ? "" : st.imgs.map((_, i) => `<i${i === st.idx ? ' class="on"' : ""}></i>`).join("");
}

function show() {
  const f = st.imgs[st.idx];
  if (!f) return;
  const gen = ++st.gen;
  resetView(false);
  img.src = fileUrl(f, st.sid, "thumb");
  renderDots();
  const full = fileUrl(f, st.sid, "full");
  const big = new Image();
  big.onload = () => { if (gen === st.gen && st.open) img.src = full; };
  big.src = full;
}

function go(delta) {
  const j = vwNext(st.idx, delta, st.imgs.length);
  if (j === st.idx) { resetView(true); return; }
  st.idx = j;
  show();
}

function toggleZoom() {
  if (st.s > 1.01) resetView(true);
  else { st.s = 2; st.tx = 0; st.ty = 0; apply(true); }
}

function share() {
  const f = st.imgs[st.idx];
  if (!f) return;
  shareFile(f, st.sid);
}

// Download via an invisible <a download> (?dl=1 makes the server reply with attachment, no new tab; shared by desktop file-card clicks and the share fallback)
export function downloadFile(f, sid) {
  const a = document.createElement("a");
  a.href = fileUrl(f, sid, "full", true);
  a.download = attName(f) || "";
  a.rel = "noopener";
  a.hidden = true;
  document.body.append(a);
  a.click();
  a.remove();
}

// Save/share (shared by the viewer's top-right button, the app.js long-press menu, and phone file-card taps): fetch the original file -> File -> system share sheet (iOS offers "Save Image" / save to Files);
// if sharing files is unsupported or errors, fall back to the invisible <a download>; never window.open (a new view from a home-screen app has no login state and goes black).
// Sharing only the URL is useless: it requires login and other apps cannot open it. This lives here rather than in logic.js because it needs fetch / navigator / window. onMsg: optional hint callback (app.js passes toast)
// If a large fetch takes long, the user gesture expires and share throws NotAllowedError: cache this File (only the latest per url), prompt to tap again, and the next tap on the same one shares directly
let pendShare = null; // { url, file }
export async function shareFile(f, sid, onMsg) {
  const url = new URL(fileUrl(f, sid, "full", true), location.href).href; // ?dl=1: the server sends the whole original file (a preview is cut at 2 MiB)
  let file = pendShare && pendShare.url === url ? pendShare.file : null;
  try {
    if (!file) {
      const r = await fetch(url, { credentials: "same-origin" });
      if (!r.ok) { if (onMsg) onMsg(t(fileFailKey(r.status))); return; } // 429/5xx do not say "file is gone"; only show a hint, do not open
      if (r.headers.get("X-Truncated")) { if (onMsg) onMsg(t("c.loadFail")); return; } // a truncated body is not the original file: never save/share it
      const blob = await r.blob();
      let name = attName(f) || t("c.file");
      if (!/\.[A-Za-z0-9]{1,5}$/.test(name) && blob.type) name += "." + (blob.type.split("/")[1] || "bin").replace(/\W.*$/, "");
      file = new File([blob], name, { type: blob.type || f.mime || "" });
    }
    if (navigator.canShare && navigator.share && navigator.canShare({ files: [file] })) {
      await navigator.share({ files: [file] });
      pendShare = null;
      return;
    }
  } catch (e) {
    const plan = shareFailPlan(e && e.name);
    if (plan === "none") return; // the user dismissed the share sheet
    if (plan === "retry" && file) {
      pendShare = { url, file };
      if (onMsg) onMsg(t("at.retryTap"));
      return;
    }
    reportErr("shareFile", e); // other errors must be reported
  }
  downloadFile(f, sid);
}

const dist = (t) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);

function onStart(e) {
  if (e.target.closest && e.target.closest("button")) return;
  const t = e.touches;
  if (t.length >= 2) {
    g.mode = "pinch"; g.d0 = dist(t) || 1; g.s0 = st.s; g.moved = 99;
    e.preventDefault();
  } else {
    g.mode = "one"; g.x0 = t[0].clientX; g.y0 = t[0].clientY; g.tx0 = st.tx; g.ty0 = st.ty;
    g.moved = 0; g.dx = 0; g.dy = 0; g.axis = ""; g.t0 = Date.now();
  }
}

function onMove(e) {
  if (!g.mode) return;
  e.preventDefault();
  const t = e.touches;
  if (g.mode === "pinch" && t.length >= 2) {
    st.s = vwScale(g.s0, dist(t) / g.d0);
    if (st.s === 1) { st.tx = 0; st.ty = 0; }
    apply(false);
    return;
  }
  if (g.mode !== "one" || t.length !== 1) return;
  g.dx = t[0].clientX - g.x0; g.dy = t[0].clientY - g.y0;
  g.moved = Math.max(g.moved, Math.hypot(g.dx, g.dy));
  if (st.s > 1.01) { st.tx = g.tx0 + g.dx; st.ty = g.ty0 + g.dy; apply(false); return; }
  if (!g.axis && g.moved > TAP_MOVE) g.axis = Math.abs(g.dx) >= Math.abs(g.dy) ? "x" : "y";
  if (g.axis === "x" && st.imgs.length > 1) { st.tx = g.dx; st.ty = 0; apply(false); }
  else if (g.axis === "y" && g.dy > 0) { st.tx = g.dx * 0.3; st.ty = g.dy; setBg(Math.max(0.2, 1 - g.dy / 400)); apply(false); }
}

function onEnd(e) {
  if (!g.mode) return;
  if (e.touches && e.touches.length > 0) { // one of two fingers lifted: stop tracking, to avoid jumping
    if (g.mode === "pinch") { g.mode = "one"; g.x0 = e.touches[0].clientX; g.y0 = e.touches[0].clientY; g.tx0 = st.tx; g.ty0 = st.ty; g.moved = 99; g.dx = 0; g.dy = 0; g.axis = ""; }
    return;
  }
  const mode = g.mode; g.mode = "";
  if (mode === "pinch") { if (st.s < 1.05) resetView(true); return; }
  const now = Date.now();
  const act = vwTapAction({ moved: g.moved, dt: now - g.t0, sinceLastTap: now - g.lastTap, scale: st.s, dy: g.dy, dx: g.dx, n: st.imgs.length });
  if (act === "double") { g.lastTap = 0; toggleZoom(); return; }
  if (act === "tap") { g.lastTap = now; return; }
  g.lastTap = 0;
  if (act === "next") go(1);
  else if (act === "prev") go(-1);
  else if (act === "close") closeViewer();
  else if (st.s <= 1.01) resetView(true);
}

function onWheel(e) {
  e.preventDefault();
  st.s = vwScale(st.s, e.deltaY < 0 ? 1.1 : 1 / 1.1);
  if (st.s === 1) { st.tx = 0; st.ty = 0; }
  apply(false);
}

function onKey(e) {
  if (!st.open) return;
  if (e.key === "Escape") { e.preventDefault(); closeViewer(); }
  else if (e.key === "ArrowLeft") { e.preventDefault(); go(-1); }
  else if (e.key === "ArrowRight") { e.preventDefault(); go(1); }
}

export function openViewer(imgs, index, sid) {
  if (!Array.isArray(imgs) || !imgs.length) return;
  build();
  st.imgs = imgs; st.sid = sid || ""; st.idx = vwNext(index | 0, 0, imgs.length);
  if (!st.open) {
    st.open = true;
    prevState = history.state;
    try { history.replaceState(Object.assign({}, prevState, { vw: 1 }), ""); } catch (e) { /* ignore */ }
    document.addEventListener("keydown", onKey);
  }
  root.hidden = false;
  document.body.classList.add("vw-open");
  show();
}

export function closeViewer() {
  if (!st.open) return;
  st.open = false; st.gen++;
  document.removeEventListener("keydown", onKey);
  root.hidden = true;
  img.removeAttribute("src");
  document.body.classList.remove("vw-open");
  try { history.replaceState(prevState, ""); } catch (e) { /* ignore */ }
  prevState = null;
}
