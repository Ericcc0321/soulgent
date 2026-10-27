// Soulgent service worker: the shell opens offline, pet images are cache-first, the snapshot is network-first (falls back to the last cached copy).
// Shell files are network-first too (3.5 s timeout, then cache), so after a deploy the phone gets the new version on next open; VERSION only clears old caches.
const VERSION = "v142";
const SHELL_CACHE = "zbs-shell-" + VERSION;
const PET_CACHE = "zbs-pets-v1";
const DATA_CACHE = "zbs-data-v2"; // offline snapshots are keyed per account; on rename, activate drops the old unkeyed cache
const KEEP = [SHELL_CACHE, PET_CACHE, DATA_CACHE];
const TIMEOUT_MS = 3500;
// Text shell: network-first
const SHELL_TEXT = ["/", "/index.html", "/style.css", "/app.js", "/logic.js", "/md.js", "/figures.js", "/viewer.js", "/i18n.js", "/manifest.webmanifest"]; // i18n.js is imported by app/logic/viewer; without it the offline shell is blank
// Icons: cache-first. The list includes ?v= and lookups compare with ?v= too (same path with a different v is a different resource, so bumping v fetches the new image)
const SHELL_ICONS = ["/icons/icon-180.png?v=4", "/icons/icon-192.png?v=4", "/icons/icon-512.png?v=4", "/icons/tab-soulchat-off.svg?v=1", "/icons/tab-soulchat-on.svg?v=1", "/icons/tab-agents-off.svg?v=1", "/icons/tab-agents-on.svg?v=1", "/icons/tab-zone-off.svg?v=1", "/icons/tab-zone-on.svg?v=1", "/icons/tab-me-off.svg?v=2", "/icons/tab-me-on.svg?v=2", "/icons/term-glyph.png", "/icons/term-180.png", "/icons/mascot-av-idle.png?v=1", "/icons/mascot-av-busy.png?v=1", "/icons/mascot-av-wait.png?v=1", "/icons/mascot-av-done.png?v=1", "/icons/mascot-av-rest.png?v=1", "/icons/favicon.svg?v=1", "/icons/mascot-idle.png?v=1"];
const SLOW = Symbol("slow");
// Whether the request is a listed icon: compare path + query string as a whole
function isShellIcon(url) {
  return SHELL_ICONS.includes(url.pathname + url.search);
}

// Only cache real 200 pages: when not logged in the request is redirected to the login page, which must not be stored as the shell
function cacheable(res) {
  return res && res.ok && !res.redirected && res.type === "basic";
}

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    await Promise.all(SHELL_TEXT.filter((u) => u !== "/index.html").concat(SHELL_ICONS).map(async (url) => {
      try {
        const res = await fetch(url, { credentials: "same-origin", cache: "no-cache" });
        if (cacheable(res)) await cache.put(url, res);
      } catch (e) { /* offline install: skip, retry next time */ }
    }));
    try { // also store the pet manifest, so pets are not all missing on an offline start
      const res = await fetch("/pets/manifest.json", { credentials: "same-origin", cache: "no-cache" });
      if (cacheable(res)) await (await caches.open(PET_CACHE)).put("/pets/manifest.json", res);
    } catch (e) { /* ignore */ }
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter((n) => n.startsWith("zbs-") && !KEEP.includes(n)).map((n) => caches.delete(n)));
    await self.clients.claim();
  })());
});

function offlineCopy(hit) {
  return hit.blob().then((body) => {
    const headers = new Headers(hit.headers);
    headers.set("X-Zbs-Cache", "1");
    return new Response(body, { status: 200, statusText: "OK", headers });
  });
}

// Network-first, waiting at most TIMEOUT_MS; on timeout or error fall back to the cache. With no cache, keep waiting on the network (or hand the error to the page).
// opt: { cacheName, key, store, markOffline, init }
//   when init is non-empty use an AbortController (navigation requests cannot take init; they only race)
// After one timeout/error, other requests within DOWN_MS use the cache directly instead of each file waiting 3.5 s
const DOWN_MS = 8000;
let downUntil = 0;

//   read:false skips the cache read (network only); saveKey(res), if given, picks which key to store under from the response; an empty return means do not store
async function networkFirst(req, opt) {
  const cache = await caches.open(opt.cacheName);
  const key = opt.key || req;
  const lookup = () => (opt.read === false ? Promise.resolve(undefined) : cache.match(key));
  if (Date.now() < downUntil) {
    const hit = await lookup();
    if (hit) return opt.markOffline ? offlineCopy(hit) : hit;
  }
  const ctl = opt.init ? new AbortController() : null;
  const net = (ctl ? fetch(req, Object.assign({}, opt.init, { signal: ctl.signal })) : fetch(req))
    .then((res) => {
      downUntil = 0;
      const put = opt.saveKey ? opt.saveKey(res) : key;
      if (opt.store !== false && put && cacheable(res)) cache.put(put, res.clone());
      return res; // 401 / 302 are passed to the page as is
    });
  let timer = 0;
  const slow = new Promise((resolve) => { timer = setTimeout(resolve, TIMEOUT_MS, SLOW); });
  try {
    const first = await Promise.race([net, slow]);
    if (first !== SLOW) return first;
  } catch (e) {
    /* network error -> fall back to cache */
  } finally {
    clearTimeout(timer);
  }
  downUntil = Date.now() + DOWN_MS;
  const hit = await lookup();
  if (!hit) return net;
  if (ctl) ctl.abort();
  net.catch(() => {});
  return opt.markOffline ? offlineCopy(hit) : hit;
}

async function cacheFirst(req, cacheName) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (cacheable(res)) cache.put(req, res.clone());
  return res;
}

// Identity-switching requests (login page, login/logout endpoints): clear the offline snapshot cache first,
// so a new identity (e.g. guest) offline or timing out is not served the previous account's (admin's) snapshot.
// A #k= login link never shows here (the fragment is not part of the request URL): it always goes through /login.html and POST /api/auth.
// Legacy ?key= links (remove after 2026-12-26): the server redirects them to /login.html#k=..., a navigation still caught here as a precaution.
function identityChange(req, url) {
  const p = url.pathname;
  if (p === "/api/auth" || p === "/api/auth/logout" || p === "/login.html") return true;
  return req.mode === "navigate" && url.searchParams.has("key");
}

// Offline snapshots are keyed per account: on store, use the server response header X-Zbs-Account (who the snapshot actually belongs to),
// on read, use the page request header X-Zbs-Acct (the account the page is logged in as); if either is missing, neither store nor read.
// Identity generation: bumped on every identity switch; a snapshot sent before the switch but returned after it is not stored (a stale page's polling cannot write into the new cache)
const ACCT_RE = /^[A-Za-z0-9_-]{1,64}$/;
let idEpoch = 0;
function snapAcct(headers, name) {
  const v = headers && typeof headers.get === "function" ? headers.get(name) : null;
  return typeof v === "string" && ACCT_RE.test(v) ? v : "";
}
function snapKey(acct) {
  return acct ? "/api/snapshot?acct=" + acct : "";
}
function snapOpts(req) {
  const want = snapKey(snapAcct(req.headers, "X-Zbs-Acct"));
  const epoch = idEpoch;
  return {
    cacheName: DATA_CACHE, key: want || "/api/snapshot", read: !!want, markOffline: true,
    saveKey: (res) => (epoch === idEpoch ? snapKey(snapAcct(res.headers, "X-Zbs-Account")) : ""),
    init: { credentials: "same-origin", cache: "no-store" },
  };
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (identityChange(req, url)) {
    idEpoch++;
    event.waitUntil(caches.delete(DATA_CACHE).catch(() => {}));
  }
  if (req.method !== "GET") return;
  const p = url.pathname;

  if (p === "/api/snapshot") {
    event.respondWith(networkFirst(req, snapOpts(req)));
    return;
  }
  if (p.startsWith("/api/")) return; // conversations, reply results (/api/requests/*) and terminal screens are network-only, never cached
  if (p === "/login.html") return;

  if (req.mode === "navigate") {
    // Only handle navigations of the app shell (/, /index.html); other pages (e.g. another app behind the same reverse proxy) pass through, uncached and unrewritten
    if (p !== "/" && p !== "/index.html") return;
    // Page navigation: network-first (login redirects still work); on timeout/offline fall back to the shell
    event.respondWith(networkFirst(req, {
      cacheName: SHELL_CACHE, key: "/", store: p === "/" || p === "/index.html",
    }));
    return;
  }
  if (p === "/pets/manifest.json") {
    event.respondWith(networkFirst(req, {
      cacheName: PET_CACHE, init: { credentials: "same-origin", cache: "no-cache" },
    }));
    return;
  }
  // Built-in tool figures (/figures/, Soulgent flame) follow the shell: cache-first, replaced together with the shell cache on a version bump
  if (p.startsWith("/pets/") || p.startsWith("/figures/") || isShellIcon(url)) {
    event.respondWith(cacheFirst(req, p.startsWith("/pets/") ? PET_CACHE : SHELL_CACHE));
    return;
  }
  if (SHELL_TEXT.includes(p)) {
    event.respondWith(networkFirst(req, {
      cacheName: SHELL_CACHE, key: p === "/index.html" ? "/" : p,
      init: { credentials: "same-origin", cache: "no-cache" },
    }));
  }
});

// ---------- shell version gate ----------
// The page reports the <meta name="zbs-shell" content="vNN"> from its own index.html; a mismatch with VERSION means an old shell paired with a new app.js:
// delete the cached "/" (so a reload does not fetch the old shell again) and reply shell-mismatch so the page reloads once (the page has a reload-once guard)
self.addEventListener("message", (event) => {
  const d = event.data;
  if (!d || d.type !== "shell" || !event.source) return;
  event.waitUntil((async () => {
    if (d.v === VERSION) { event.source.postMessage({ type: "shell-ok", v: VERSION }); return; }
    try { await (await caches.open(SHELL_CACHE)).delete("/"); } catch (e) { /* ignore */ }
    event.source.postMessage({ type: "shell-mismatch", v: VERSION });
  })());
});

// ---------- push notifications ----------
// Payload: {kind:"show", tag, title, body, url, timestamp?, av?}. Recall notifications are not pushed;
// timestamp = event time, renotify (a new event with the same tag sounds again; Apple ignores it); av = conversation avatar (the server sends it only to Chrome / Edge / Android,
// Apple ignores icon). The sw picks the image by the same rules as the list, fetches it and converts it to a data URL before showNotification (the system fetching the image may not carry the login cookie);
// Stale notifications are closed locally: on a new push the sw takes a snapshot and closes notifications of conversations not in "waiting for you / unread"; app.js also closes them while the page is in the foreground.
// iOS requires every push to call showNotification, so we always show first and clean up after; never "close without showing".
// iOS does not replace notifications by tag, so before showing, the sw closes the ones with the same tag itself (one conversation keeps only its latest notification).
const DEFAULT_TITLE = "Soulgent";

// Close notifications with this tag before showing the new one; any error is ignored so showNotification still runs
async function closeSameTag(tag) {
  try {
    const list = await self.registration.getNotifications({ tag });
    for (const n of list || []) if (n && n.tag === tag) n.close();
  } catch (e) { /* ignore: showing the new one matters more */ }
}

async function closeStaleLocal(keepTag) {
  try {
    const r = await fetch("/api/snapshot", { credentials: "same-origin", cache: "no-cache" });
    if (!r.ok) return;
    const snap = await r.json();
    if (!snap || snap.stale || !Array.isArray(snap.sessions)) return;
    const live = new Set();
    for (const s of snap.sessions) if (s.status === "waiting" || s.unread) live.add("s-" + s.id);
    const list = await self.registration.getNotifications();
    for (const n of list) {
      if (n.tag !== keepTag && typeof n.tag === "string" && n.tag.startsWith("s-") && !live.has(n.tag)) n.close();
    }
  } catch (e) { /* no snapshot: leave them, the page clears them when in the foreground */ }
}

// Identical to app.js hash() character for character (checked by a test in web/tests): the list picks a pet per conversation with it, and the notification avatar must pick the same one
function swHash(str) {
  let x = 5381;
  for (let i = 0; i < str.length; i++) x = ((x << 5) + x + str.charCodeAt(i)) | 0;
  return Math.abs(x);
}
// Conversation avatar path: the specified pet (if in the manifest) -> the static frame still.webp of the pet picked by hash(id) -> with no pet installed, the Soulgent flame expression for the status (same as flameAvatarSrc in logic.js)
const FLAME_ST = ["idle", "busy", "wait", "done", "rest"];
function avatarPath(av, pets) {
  if (!av || typeof av.id !== "string") return "";
  const m = pets && typeof pets === "object" ? pets : {};
  const names = Object.keys(m).sort();
  const name = av.pet && m[av.pet] ? av.pet : names.length ? names[swHash(av.id) % names.length] : "";
  if (name) return "/pets/" + encodeURIComponent(name) + "/still.webp";
  return "/icons/mascot-av-" + (FLAME_ST.includes(av.st) ? av.st : "idle") + ".png?v=1";
}
// Bytes -> base64: concatenate in chunks (String.fromCharCode with too many at once overflows the stack); there is no FileReader in the sw
function bytesToB64(u8) {
  let bin = "";
  for (let i = 0; i < u8.length; i += 0x8000) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return btoa(bin);
}
function withTimeout(p, ms) {
  let timer = 0;
  return Promise.race([p, new Promise((ok) => { timer = setTimeout(ok, ms, ""); })]).finally(() => clearTimeout(timer));
}
async function cachedOrFetch(path) {
  const hit = await caches.match(path);
  if (hit) return hit;
  return fetch(path, { credentials: "same-origin" });
}
async function pushIcon(msg) {
  let pets = null;
  try {
    const r = await cachedOrFetch("/pets/manifest.json");
    if (r && r.ok) pets = await r.json();
  } catch (e) { /* no pet manifest: use Soulgent flame */ }
  const path = avatarPath(msg.av, pets);
  if (!path) return "";
  const res = await cachedOrFetch(path);
  if (!res || !res.ok) return "";
  const type = (res.headers.get("Content-Type") || "").split(";")[0] || (path.includes(".webp") ? "image/webp" : "image/png");
  return "data:" + type + ";base64," + bytesToB64(new Uint8Array(await res.arrayBuffer()));
}
function notifOptions(msg, icon) {
  const o = { body: msg.body || "", tag: typeof msg.tag === "string" && msg.tag ? msg.tag : "zbs",
    data: { url: typeof msg.url === "string" ? msg.url : "/" }, renotify: true };
  if (typeof msg.timestamp === "number" && Number.isFinite(msg.timestamp) && msg.timestamp > 0) o.timestamp = msg.timestamp;
  if (icon) o.icon = icon;
  return o;
}

// Badge: only update when the payload carries badge (computed by the server with the same rules as the tab-bar dots); 0 clears; if unsupported (no setAppBadge) skip. When the app opens it recomputes from the snapshot, leaving no stale count
function applyBadge(n) {
  try {
    const nav = self.navigator;
    if (!nav || typeof nav.setAppBadge !== "function") return Promise.resolve();
    if (n > 0 || typeof nav.clearAppBadge !== "function") return Promise.resolve(nav.setAppBadge(n)).catch(() => {});
    return Promise.resolve(nav.clearAppBadge()).catch(() => {});
  } catch (e) { return Promise.resolve(); }
}

async function onPush(event) {
  let msg = {};
  try { msg = event.data ? event.data.json() : {}; } catch (e) { msg = {}; }
  const tag = typeof msg.tag === "string" ? msg.tag : "zbs";
  if (msg.kind === "recall") { // legacy payload from an old server: only close locally
    const list = await self.registration.getNotifications({ tag });
    for (const n of list) n.close();
    return;
  }
  // Fetch the image for at most 2.5 s; on any error send no image, but always call showNotification (iOS revokes the subscription if pushes are not shown)
  let icon = "";
  if (msg.av) { try { icon = await withTimeout(pushIcon(msg).catch(() => ""), 2500); } catch (e) { icon = ""; } }
  const opts = notifOptions(msg, icon);
  await closeSameTag(opts.tag);
  try {
    await self.registration.showNotification(msg.title || DEFAULT_TITLE, notifOptions(msg, icon));
  } catch (e) { // in case a browser rejects the new options (renotify / timestamp / icon): fall back to the minimal form (without them) and show again
    await self.registration.showNotification(msg.title || DEFAULT_TITLE, { body: opts.body, tag: opts.tag, data: opts.data });
  }
  if (Number.isInteger(msg.badge) && msg.badge >= 0) await applyBadge(msg.badge);
  await closeStaleLocal(tag);
}

self.addEventListener("push", (event) => { event.waitUntil(onPush(event)); });

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || "/", self.location.origin).href;
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const tag = event.notification.tag || "";
    const hadClient = wins.some((w) => new URL(w.url).origin === self.location.origin);
    for (const w of wins) {
      if (new URL(w.url).origin === self.location.origin && "focus" in w) {
        // App already open: let it jump to the conversation itself; tag / hadClient go into the diagnostic log for notify-click
        w.postMessage({ type: "open", url, tag, hadClient });
        return w.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
