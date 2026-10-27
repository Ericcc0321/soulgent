"""Soulgent API: merges read/pin state into the snapshot, pages transcripts, and serves the cookie gate (for Caddy forward_auth).

Accounts: admin (WEBAPP_KEY, everything) and guests (guest mode: each sees only its own bound session). The first guest is
account "guest" (GUEST_KEY); more guests via GUESTn_* (account = their id), see guestcfg.load_guests.
Cookie value = a per-device random token (api/devices.py: issued at login, revocable one by one, invalid once that account's key changes).
The legacy cookie value hmac(account key, 'zbs-v1') is still accepted for a transition and upgraded to a device token (LEGACY_HMAC_COOKIE_REMOVE_AFTER).
A guest's bound session is looked up by name (GUEST_SESSION / GUESTn_SESSION in .env, the full session name); only endpoints in the GUEST_API
allow-list are open, everything else is 403. Guests never see each other's session, messages, profile, devices, presence or requests.
Guest config and the optional legacy account name for older deployments (GUEST_LEGACY_ACCOUNT): see guestcfg.py."""
import hashlib
import hmac
import json
import os
import posixpath
import re
import shutil
import sys
import threading
import time
import uuid
from collections import deque
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, quote, unquote, urlsplit

try:
    from api import notify, outbox, presence, push, transcript
    from api.state import State, bg_live, finished_at, flags_for, origin_counts
    from api.state import error_finished, error_kind, is_gone  # error / unexpected exit
    from api import history  # in-session search / window-switch lineage
    from api import textsearch  # global search (outside a session)
    from api.state import MuteStore, TopStore
    from api import profile  # my nickname and avatar
    from api import files, thumbs  # bubble attachments: file whitelist, thumbnails
    from api import guestcfg  # guest config (prefix, admin-only proxy prefixes, legacy name handling)
    from api import devices  # per-device login tokens (devices.json)
    from api.uploadlog import UploadLog  # upload log (who uploaded, which sessions it was sent to), persisted in the state volume
except ImportError:  # in the container, api/ contents sit directly in the working directory
    from uploadlog import UploadLog  # type: ignore
    import files  # type: ignore
    import guestcfg  # type: ignore
    import devices  # type: ignore
    import thumbs  # type: ignore
    import history  # type: ignore
    import textsearch  # type: ignore
    from state import MuteStore, TopStore  # type: ignore
    import profile  # type: ignore
    import notify  # type: ignore
    import outbox  # type: ignore
    import presence  # type: ignore
    import push  # type: ignore
    import transcript  # type: ignore
    from state import State, bg_live, finished_at, flags_for, origin_counts  # type: ignore
    from state import error_finished, error_kind, is_gone  # type: ignore

COOKIE_NAME = "zbs"
COOKIE_MAX_AGE = 34560000
CLEAR_COOKIE = "%s=; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=0" % COOKIE_NAME
STALE_AFTER = 30
NOTIFY_POLL = 1.0  # the notify thread recomputes every this many seconds (timers depend on it, not just the snapshot mtime)
WAKE_GAP = 3 * NOTIFY_POLL + 5  # a gap this long between two notify rounds means the server itself slept (Mac lid closed); this round does not count as a disconnect
PUBLIC_EXACT = ("/login.html", "/i18n.js", "/manifest.webmanifest", "/sw.js", "/ca.crt", "/api/auth")  # i18n.js is public (the login page uses it directly; it holds only UI text)
PUBLIC_PREFIX = ("/icons/",)
# Legacy ?key= links (Handler._legacy_key_redirect), remove after 2026-12-26. Informational only: nothing checks this date.
LEGACY_KEY_LINKS_REMOVE_AFTER = "2026-12-26"
# Legacy cookie value hmac(key, 'zbs-v1') (App.token_user), still accepted and upgraded to a device token; remove after 2026-11-26. Informational only: nothing checks this date.
LEGACY_HMAC_COOKIE_REMOVE_AFTER = "2026-11-26"
# A legacy cookie is upgraded only on these browser-facing GETs (the app calls them at startup); requests arriving together reuse one new token for this long
LEGACY_UPGRADE_PATHS = ("/api/auth/me", "/api/snapshot", "/api/auth/devices")
LEGACY_UPGRADE_REUSE = 300
# No renewal / upgrade Set-Cookie on these: forward_auth drops Set-Cookie of a 2xx check; login and logout set their own; revoke may clear it
NO_COOKIE_REFRESH = ("/api/auth/check", "/api/auth", "/api/auth/logout", "/api/auth/devices/revoke")
GUEST = guestcfg.ACCOUNT      # account name of the first guest (other guests' account name = id; see App.guests)
OWNER_MAX = 4096              # request ids / upload ownership for guests are kept in memory only, at most this many (oldest dropped when full)
LAB_PREFIX = "/lab"           # preview pages directory (may contain real session names): login required, admin only, 403 for guests
# Private reverse-proxy prefixes (.env ADMIN_ONLY_PREFIXES) are admin only (403 for guests); the prefix before each guest message (.env GUEST_TAG): both live on App
# Snapshot response header: which account this snapshot belongs to (the sw keys its offline snapshot by it, so a changed identity never reads another account's)
SNAP_ACCOUNT_HDR = "X-Zbs-Account"
ACCOUNT_API = ("/api/auth/me", "/api/auth/logout", "/api/auth/devices", "/api/auth/devices/revoke")  # identity endpoints usable by both account types
# Guest snapshot whitelist: top-level fields and session fields (no transcript path, cwd, peer, read/pin state or other admin state; never formatWarn / formatWarnings)
GUEST_SNAP_FIELDS = ("generatedAt", "stale", "serverNow", "sessions", "zones", "bound", "roster")
GUEST_SESSION_FIELDS = ("id", "kind", "name", "plate", "zone", "status", "since", "summary", "waitingFor", "model",  # model: lets Fable sessions without status-bar meta still draw the flame
                      "pet", "meta", "origin", "agents",  # number of running subagents
                      "summaryCode", "summaryArgs", "nameUntitled",  # summary code, args, unnamed marker
                      "bgTasks", "bgAgents", "bgSince", "bgStale", "bgEndedAt", "bgOwned", "bgList",  # the six background-task fields, background list
                      "errorKind", "errorStatus", "errorText", "errorSince", "retryAttempt", "retryMax",
                      "disconnected", "disconnectedSince", "compactedAt", "helpers")  # error / disconnect fields, merged helper count
GUEST_ZONE_FIELDS = ("code", "name", "color", "order", "short", "fx")  # short name, avatar effect (display only)
RECALL_WINDOW = 120  # recall window (seconds), measured from the ts in that message's record
RECALL_GRACE = 10    # the frontend greys out after 120 s; the server allows 10 s more to absorb network latency between tap and request arrival
# Slim roster for guest chat-page group avatars: only session name, zone code and whether it is the lead (no pet, summary, status or anything else)
GUEST_ROSTER_FIELDS = ("name", "zone", "lead")
LOGIN_MAX_FAIL = 5            # failures from one source IP within the window before lockout
LOGIN_WINDOW = 600            # window of 10 minutes counted from the first failure; locked until the window ends
MAX_BODY = 64 * 1024
MAX_UPLOAD = 20 * 1024 * 1024
# Guest upload quota (admin unlimited): max files per 10 minutes, max total bytes per 7 days, minimum free disk to leave
GUEST_UPLOAD_RATE = 30
GUEST_UPLOAD_WINDOW = 600
GUEST_UPLOAD_TOTAL = 200 * 1024 * 1024
GUEST_UPLOAD_MIN_FREE = 1024 * 1024 * 1024
# Attachment responses: the browser may store them, but must revalidate with the ETag before each use (304 sends nothing) - the server rechecks permissions every time,
# so after an account change / logout a stale cache is never used directly
FILE_CACHE = "private, no-cache"
UPLOAD_CHUNK = 64 * 1024
DIAG_PATH = "/api/diag"
DIAG_MAX_BODY = 256 * 1024       # request body limit for one batch of phone diagnostic logs
DIAG_MAX_BYTES = 5 * 1024 * 1024  # when diag.jsonl exceeds this size it is renamed to .1 (only one old copy kept)
# Guests may only write error records (k:"err", as emitted by the frontend diagErr, including uncaught global exceptions): keep only these fields (strings, each truncated to this length),
# drop all other fields (they may carry chat content); the server adds ua (request header) and account=guest
GUEST_ERR_FIELDS = {"where": 60, "name": 40, "msg": 300, "stack": 800, "shell": 16, "lang": 8, "path": 80}
GUEST_ERR_GAP = 60   # the same source, place and message is recorded only once within this many seconds
GUEST_ERR_RATE = 20  # max records per source per minute; extras are dropped silently (no error)
_SESSION_RE = re.compile(r"^/api/sessions/([^/]+)/(seen|pin|transcript|unseen|rest|offduty)$")
_SEND_RE = re.compile(r"^/api/sessions/([^/]+)/(send|screen)$")
_OFFDUTY_RE = re.compile(r"^/api/offduty/([^/]+)/(wake|transcript)$")
_PLAIN_UPLOAD = "/api/uploads"
_UPLOAD_RE = re.compile(r"^/api/sessions/([^/]+)/upload$")
_REQUEST_RE = re.compile(r"^/api/requests/([^/]+)$")
_CONTEXT_RE = re.compile(r"^/api/session/([^/]+)/context$")
_AGENT_RE = re.compile(r"^/api/session/([^/]+)/agent/([^/]+)$")  # subagent read-only conversation page (guests limited to the bound session)
_HIST_RE = re.compile(r"^/api/session/([^/]+)/(search|lineage)$")  # in-session search / previous-window chain (guests limited to the bound session and same-name chain)
_MUTE_RE = re.compile(r"^/api/sessions/([^/]+)/mute$")  # do-not-disturb (admin)
_TOP_RE = re.compile(r"^/api/sessions/([^/]+)/top$")  # pin to top (persistent, separate from the board pin) (admin)
PROFILE_PATH = "/api/profile"  # my nickname and avatar (admin; GET reads / POST changes)
AVATAR_PATH = "/api/avatar"
_UUID_RE = re.compile(r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
CONTEXT_CACHE_TTL = 120  # context detail cache for 2 minutes
_TASKBOARD_RE = re.compile(r"^/api/zone/([A-Za-z0-9_-]{1,32})/taskboard$")
FILE_PATH = "/api/file"  # bubble attachment fetch (admin: p / sid+ref / tok; guest: bound-session sid+ref, uploads tok)
FILE_RATE = 600  # max requests per account per FILE_WINDOW seconds
FILE_WINDOW = 60.0
FILE_CHUNK = 1024 * 1024  # streaming chunk size
TEXT_MAX = 2 * 2**20  # text-type full responses are capped at this size; beyond it they are truncated with X-Truncated: 1
TEXT_EXTS = ("md", "txt", "csv", "json")
THUMB_EXTS = ("png", "jpg", "jpeg", "webp", "gif")  # types that can be thumbnailed (svg is not; the original file is served)
GUEST_FILE_LOG_MAX = 2**20  # the guest file-fetch log is rotated to .1 beyond 1MB
TOK_TTL = 86400  # rounding unit for the validity of guest upload links (one day)
_REF_RE = re.compile(r"\A(\d{1,15}):(\d{1,3}):([0-9a-f]{8})\Z")  # line start offset:image index:line fingerprint
_RANGE_RE = re.compile(r"\Abytes=(\d*)-(\d*)\Z")


class GuestErrLimiter:
    """Rate limit for guest error reports (by source IP; guests share one cookie, so people cannot be told apart): the same where+msg is deduplicated for 60 s, plus a per-minute cap.
    In memory only, cleared on api restart; the number of sources is capped, and the least recently active is evicted first."""

    def __init__(self, gap: float = GUEST_ERR_GAP, rate: int = GUEST_ERR_RATE, max_src: int = 256) -> None:
        self.gap, self.rate, self.max_src = gap, rate, max_src
        self._lock = threading.Lock()
        self._src = {}  # type: Dict[str, Dict[str, Any]]  # ip -> {"t0": start of this minute, "n": count this minute, "seen": {key: time}, "at": last time}

    def allow(self, ip: str, key: str, now: float) -> bool:
        with self._lock:
            e = self._src.get(ip)
            if e is None:
                if len(self._src) >= self.max_src:
                    del self._src[min(self._src, key=lambda k: self._src[k]["at"])]
                e = self._src[ip] = {"t0": now, "n": 0, "seen": {}, "at": now}
            e["at"] = now
            if now - e["t0"] >= 60:
                e["t0"], e["n"] = now, 0
            seen = e["seen"]
            for k in [k for k, t in seen.items() if now - t >= self.gap]:
                del seen[k]
            if key in seen or e["n"] >= self.rate:
                return False
            seen[key] = now
            e["n"] += 1
            return True


def guest_err_event(ev: Any, ua: str, account: str = GUEST) -> Optional[Dict[str, Any]]:
    """A guest diagnostic record -> an error record with whitelisted fields only; returns None (dropped) unless it is k:"err"."""
    if not isinstance(ev, dict) or ev.get("k") != "err":
        return None
    row = {"k": "err"}  # type: Dict[str, Any]
    t = ev.get("t")
    if isinstance(t, (int, float)) and not isinstance(t, bool):
        row["t"] = t
    for k, n in GUEST_ERR_FIELDS.items():
        v = ev.get(k)
        if isinstance(v, str):
            row[k] = v[:n]
    row["ua"] = ua[:300]
    row["account"] = account
    return row


class LoginLimiter:
    """Count login failures per source IP: after LOGIN_MAX_FAIL failures in the window, answer 429 until the window ends; success resets. In memory only, cleared on api restart."""

    def __init__(self, max_fail: int = LOGIN_MAX_FAIL, window: float = LOGIN_WINDOW) -> None:
        self.max_fail = max_fail
        self.window = window
        self._lock = threading.Lock()
        self._fails = {}  # type: Dict[str, Tuple[float, int]]  # ip -> (time of first failure, count)

    def _prune(self, now: float) -> None:
        for ip in [k for k, (t0, _) in self._fails.items() if now - t0 >= self.window]:
            del self._fails[ip]

    def blocked(self, ip: str, now: Optional[float] = None) -> bool:
        t = time.time() if now is None else now
        with self._lock:
            self._prune(t)
            entry = self._fails.get(ip)
            return entry is not None and entry[1] >= self.max_fail

    def fail(self, ip: str, now: Optional[float] = None) -> None:
        t = time.time() if now is None else now
        with self._lock:
            self._prune(t)
            t0, n = self._fails.get(ip, (t, 0))
            self._fails[ip] = (t0, n + 1)

    def ok(self, ip: str) -> None:
        with self._lock:
            self._fails.pop(ip, None)


def _token(key: str) -> str:
    return hmac.new(key.encode("utf-8"), b"zbs-v1", hashlib.sha256).hexdigest()


def push_fp(key: str, session: Optional[str] = None) -> str:
    """Push subscription fingerprint: first 16 hex chars of sha256(login key[+bound session]). With session None (admin) only the key is used."""
    raw = "push-fp\0" + key + ("" if session is None else "\0session\0" + session)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


class App:
    def __init__(self, key: str, snapshot: str, projects: str, state: str,
                 outbox_dir: str = "/outbox", uploads_dir: str = "/uploads",
                 file_roots: Optional["files.Roots"] = None,
                 admin_only: Tuple[str, ...] = (), guests: Optional[list] = None,
                 guest_slash: Tuple[str, ...] = ()) -> None:
        self.key = key
        state_dir = os.path.dirname(os.path.abspath(state))
        # Guest list: main reads it from .env via guestcfg.load_guests (no guests = guest mode off)
        guests = guests or []
        self.guests = {}  # type: Dict[str, guestcfg.Guest]  # account name -> guest (ordered; the first is normally guest)
        for g in guests:
            if not g.key or g.key == key or g.account in self.guests or g.account == "admin" \
                    or any(o.key == g.key or o.tag == g.tag for o in self.guests.values()):
                continue  # a guest whose key or prefix collides with admin / an earlier guest is not enabled (load_guests already filtered; this is a second guard)
            if g.account == GUEST:  # the first guest's profile/subscriptions are stored under the storage name (a legacy name is kept if legacy-named data exists; nothing is migrated)
                g.store = guestcfg.store_id(state_dir)
            self.guests[g.account] = g
        g0 = self.guests.get(GUEST)
        # Legacy field (the first guest; the default value when unset; admin ?account=guest still reads that profile)
        self.guest_session = g0.session if g0 else ""  # full name of the guest's bound session
        # Prefix the server adds before each guest message (the frontend cannot bypass it); recall and queue counts use it to recognize guests' own messages ([Image #N] may precede it)
        self.guest_tag = g0.tag if g0 else guestcfg.clean_tag(guestcfg.DEFAULT_TAG)
        self.guest_own_re = guestcfg.own_re(self.guest_tag)
        self.guest_slash = tuple(guest_slash)  # slash commands guests may send (GUEST_SLASH_COMMANDS); empty = none
        self.admin_only = tuple(admin_only)  # path prefixes served to admin only (private reverse proxy); 403 for guests
        # account -> key
        self.keys = {"admin": key}  # type: Dict[str, str]
        for acc, g in self.guests.items():
            self.keys[acc] = g.key
        self.tokens = {name: _token(k) for name, k in self.keys.items()}  # legacy cookie values (LEGACY_HMAC_COOKIE_REMOVE_AFTER)
        # Per-device login tokens: valid only while the token's key fingerprint equals the account's current one
        self.kfps = {name: devices.key_fp(k) for name, k in self.keys.items()}
        self.devices = devices.DeviceStore(os.path.join(state_dir, "devices.json"))
        self._upg_lock = threading.Lock()
        self._upgrades = {}  # type: Dict[str, Tuple[str, float]]  # sha256(legacy value, desc) -> (new raw token, time); memory only
        # Which guest each request id belongs to (memory only): another guest using it always gets 404
        self._owner_lock = threading.Lock()
        self.rid_owner = {}  # type: Dict[str, str]
        # Upload log (persistent, state volume uploads.json): guest attachment sending and upload-link fetching both check ownership against it; chat text does not count
        self.uploadlog = UploadLog(os.path.join(state_dir, "uploads.json"))
        # Reservations for in-flight guest uploads (memory only): token -> (account, bytes). The quota check and the reservation happen under one lock, so concurrent uploads cannot all pass the check
        self._up_lock = threading.Lock()
        self._up_held = {}  # type: Dict[str, Tuple[str, int]]
        self.limiter = LoginLimiter()
        self.outbox = outbox_dir
        self.uploads = uploads_dir
        self.snapshot_path = snapshot
        self.projects = projects
        self.state = State(state)
        # Guest subscriptions/profile are stored under the storage name (a legacy name is kept if legacy-named data exists; nothing is migrated)
        self.guest_store = g0.store if g0 else guestcfg.store_id(state_dir)
        labels = {GUEST: self.guest_store}
        labels.update({acc: g.store for acc, g in self.guests.items()})
        # Push subscription fingerprint: admin = login key, guest = login key + bound session. After changing WEBAPP_KEY / GUESTn_KEY or rebinding the session,
        # old devices' subscriptions stop receiving pushes (push.Push._live); the frontend re-registers on every start and gets the new fingerprint
        fps = {acc: push_fp(k, self.guests[acc].session if acc in self.guests else None) for acc, k in self.keys.items()}
        self.push = push.Push(os.path.join(state_dir, "push.json"), labels=labels,
                              accounts=["admin", GUEST] + list(self.guests), fps=fps)
        self.diag_path = os.path.join(os.path.dirname(os.path.abspath(state)), "diag.jsonl")
        self._diag_lock = threading.Lock()
        # Guest file-fetch access log (state volume, not the code directory): one line per fetch, rotated to .1 beyond 1MB (one copy kept)
        self.guest_file_log = os.path.join(state_dir, "guest-file.log")
        self._gfl_lock = threading.Lock()
        self.guest_err = GuestErrLimiter()
        self.token = self.tokens["admin"]
        self._cache_lock = threading.Lock()
        self._cache = None  # type: Optional[Tuple[float, Dict[str, Any]]]
        self._notify_state = notify.new_state()
        # Each guest has separate push state (only their bound session, only the finished notification)
        self._notify_g = {acc: notify.new_state() for acc in self.guests}  # type: Dict[str, Dict[str, Any]]
        self.context_dir = os.path.join(os.path.dirname(os.path.abspath(state)), "context")
        self._ctx_lock = threading.Lock()
        self._ctx_pending = {}  # type: Dict[str, str]  # session id -> rid of the unfinished context request
        # Do-not-disturb (state volume mute.json); window-switch lineage (copied by the helper to data/lineage.jsonl)
        self.mute = MuteStore(os.path.join(os.path.dirname(os.path.abspath(state)), "mute.json"))
        self.top = TopStore(os.path.join(os.path.dirname(os.path.abspath(state)), "top.json"))
        self.lineage_file = os.path.join(os.path.dirname(os.path.abspath(snapshot)), "lineage.jsonl")
        # Helper heartbeat (written every round whether or not the dump succeeded): tells "board not responding" from "helper stopped"; state for the disconnect push
        self.beat_file = os.path.join(os.path.dirname(os.path.abspath(snapshot)), "helper-beat.json")
        # Title emoji for session pushes: installed pets (data/pets/manifest.json) and the optional private override data/pet-emoji.json ({petId: emoji})
        self.pet_manifest = os.path.join(os.path.dirname(os.path.abspath(snapshot)), "pets", "manifest.json")
        self.pet_emoji_file = os.path.join(os.path.dirname(os.path.abspath(snapshot)), "pet-emoji.json")
        self._json_cache = {}  # type: Dict[str, Tuple[float, Any]]
        self._link = notify.new_link()
        self._last_round = None  # type: Optional[float]
        # Which devices are in use (memory only), the in-use gate for the Mac-disconnect push, and the last time dead-subscription cleanup ran (daily)
        self.presence = presence.Presence()
        self._link_gate = notify.new_link_gate()
        self._prune_at = None  # type: Optional[float]
        self.profile = profile.ProfileStore(os.path.dirname(os.path.abspath(state)))
        # Guest's own nickname and avatar (profile-<store name>.json / avatar-<store name>.jpg); the admin also uses these when viewing guest bubbles
        # The default nickname comes from GUEST_NAME / GUESTn_NAME in .env (the default when unset is "访客")
        self.profile_guest = profile.ProfileStore(state_dir, "-" + self.guest_store,
                                                  profile.guest_name_of(g0.name) if g0 else profile.guest_name())
        self.profiles = {GUEST: self.profile_guest}  # type: Dict[str, profile.ProfileStore]
        for acc, g in self.guests.items():
            if acc != GUEST:
                self.profiles[acc] = profile.ProfileStore(state_dir, "-" + g.store, profile.guest_name_of(g.name))
        # Bubble attachments: host path -> container path mapping (compose FILE_ROOTS), guest link signing key, thumbnail cache, per-account rate limit
        self.file_roots = file_roots if file_roots is not None else files.Roots.from_spec(os.environ.get("FILE_ROOTS", ""))
        self.file_secret = files.file_secret(key)
        self.thumb_dir = os.path.join(os.path.dirname(os.path.abspath(state)), "thumbs")
        self.file_rate = {}  # type: Dict[str, deque]
        self._rate_lock = threading.Lock()

    def file_secret_for(self, account: str) -> bytes:
        """Signing key for guest attachment links (tok): admin and the first guest use the original key (old links cached on phones keep working);
        each other guest gets a derived key - one guest's link fails verification (404) in another's hands."""
        if account in ("admin", GUEST):
            return self.file_secret
        return hmac.new(self.file_secret, ("guest:" + account).encode("utf-8"), hashlib.sha256).digest()

    def file_allow(self, account: str, now: Optional[float] = None) -> bool:
        """/api/file rate limit: at most FILE_RATE requests per account per FILE_WINDOW seconds (all IPs look the same behind Caddy, so it can only be per account)."""
        t = time.time() if now is None else now
        with self._rate_lock:
            q = self.file_rate.setdefault(account, deque())
            while q and t - q[0] >= FILE_WINDOW:
                q.popleft()
            if len(q) >= FILE_RATE:
                return False
            q.append(t)
            return True

    def load_snapshot(self) -> Dict[str, Any]:
        try:
            mtime = os.stat(self.snapshot_path).st_mtime
        except OSError:
            return {"generatedAt": 0, "usage": {}, "zones": [], "sessions": []}
        with self._cache_lock:
            if self._cache is not None and self._cache[0] == mtime:
                return self._cache[1]
            try:
                with open(self.snapshot_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except (OSError, ValueError):
                data = None
            if not isinstance(data, dict):  # half-written or corrupt: keep the old cache
                if self._cache is not None:
                    return self._cache[1]
                return {"generatedAt": 0, "usage": {}, "zones": [], "sessions": []}
            self._cache = (mtime, data)
            return data

    def context_cached(self, sid: str, now: float) -> Optional[Dict[str, Any]]:
        """/state/context/<sid>.json: {"at", "data"}, valid within CONTEXT_CACHE_TTL. sid must already be validated as a uuid."""
        try:
            with open(os.path.join(self.context_dir, sid + ".json"), "r", encoding="utf-8") as f:
                c = json.load(f)
        except (OSError, ValueError):
            return None
        if not isinstance(c, dict) or not isinstance(c.get("data"), dict):
            return None
        at = c.get("at")
        if not isinstance(at, (int, float)) or isinstance(at, bool) or not 0 <= now - at <= CONTEXT_CACHE_TTL:
            return None
        return c

    def context_store(self, sid: str, data: Dict[str, Any], at: float) -> None:
        if not _UUID_RE.match(sid):
            return
        try:
            os.makedirs(self.context_dir, exist_ok=True)
            tmp = os.path.join(self.context_dir, ".tmp-" + uuid.uuid4().hex)
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"at": at, "data": data}, f, ensure_ascii=False)
            os.replace(tmp, os.path.join(self.context_dir, sid + ".json"))
        except OSError as e:
            sys.stderr.write("context cache write failed %s\n" % type(e).__name__)

    def context_request(self, sid: str, now: float) -> Dict[str, Any]:
        """Return a valid cache directly; otherwise reuse the session's unfinished request, or enqueue a new one."""
        c = self.context_cached(sid, now)
        if c is not None:
            return {"status": "done", "data": c["data"], "at": c["at"]}
        with self._ctx_lock:
            rid = self._ctx_pending.get(sid)
            if rid is not None:
                st = outbox.request_status(self.outbox, rid, now)
                if st is not None and st.get("status") == "pending":
                    return {"status": "pending", "rid": rid}
                if st is not None and st.get("status") == "done" and isinstance(st.get("data"), dict):
                    at = st.get("at") if isinstance(st.get("at"), (int, float)) else now
                    self.context_store(sid, st["data"], at)
                    del self._ctx_pending[sid]
                    return {"status": "done", "data": st["data"], "at": at}
            rid = outbox.enqueue_context(self.outbox, sid)
            self._ctx_pending[sid] = rid
            return {"status": "pending", "rid": rid}

    def find_session(self, sid: str) -> Optional[Dict[str, Any]]:
        for s in self.load_snapshot().get("sessions") or []:
            if isinstance(s, dict) and s.get("id") == sid:
                return s
        return None

    def _g(self, g: Optional["guestcfg.Guest"]) -> Optional["guestcfg.Guest"]:
        """No guest specified = the first one (guest), for compatibility with old callers."""
        return g if g is not None else self.guests.get(GUEST)

    def own_by_any_guest(self, text: str) -> bool:
        """Whether this message was said by some guest (recognized by each guest's prefix). Used for the admin's queue count."""
        return any(g.own_re.match(text) for g in self.guests.values()) or (
            not self.guests and bool(self.guest_own_re.match(text)))

    def guest_tags(self) -> list:
        """Prefixes of all guests (used to tag from=guest in in-session search); with no guest configured, the default prefix is used."""
        return [g.tag for g in self.guests.values()] or [self.guest_tag]

    def remember(self, table: Dict[str, str], key: str, account: str) -> None:
        """Record which guest a request id / uploaded file belongs to (memory only; oldest dropped when full)."""
        with self._owner_lock:
            table.pop(key, None)
            table[key] = account
            while len(table) > OWNER_MAX:
                del table[next(iter(table))]

    def owned_by(self, table: Dict[str, str], key: str, account: str) -> bool:
        """Counts only if the record explicitly belongs to this account (for guests: anything without a record - sent by others, by admin, or before an api restart - is never granted)."""
        with self._owner_lock:
            return table.get(key) == account

    def owned_by_other(self, table: Dict[str, str], key: str, account: str) -> bool:
        """A record belonging to another account means no access (without a record it is allowed: memory is cleared on api restart, and queued requests must not all fail)."""
        with self._owner_lock:
            who = table.get(key)
        return who is not None and who != account

    @staticmethod
    def _names(s: Dict[str, Any]) -> set:
        names = {s.get("name")}
        if s.get("zone") and s.get("plate"):
            names.add("%s-%s" % (s.get("zone"), s.get("plate")))
        return names

    def find_guest_session(self, g: Optional["guestcfg.Guest"] = None) -> Optional[Dict[str, Any]]:
        """The guest's bound session: found by name (the id changes after a session restart/clone). The snapshot name is the full name; if only a short name exists, match again by "zone-plate".
        Among same-name entries take the most recently active; returns None if unset or not on duty. g omitted = the first guest."""
        g = self._g(g)
        want = g.session if g is not None else ""
        if not want:
            return None
        best = None
        for s in self.load_snapshot().get("sessions") or []:
            if not isinstance(s, dict) or s.get("kind") != "claude":
                continue
            if want not in self._names(s):
                continue
            try:
                since = float(s.get("since") or 0)
            except (TypeError, ValueError):
                since = 0.0
            if best is None or since > best[0]:
                best = (since, s)
        return best[1] if best else None

    def guest_sids(self, g: Optional["guestcfg.Guest"]) -> list:
        """Sids of the transcripts a guest may see: the bound session plus its reachable previous windows (guest_windows). Empty when not on duty."""
        s = self.find_guest_session(g) if g is not None else None
        if s is None or not s.get("id"):
            return []
        return [str(s.get("id"))] + [w["sid"] for w in self.guest_windows(s, g)]

    def guest_bound_id(self, g: Optional["guestcfg.Guest"] = None) -> Optional[str]:
        s = self.find_guest_session(g)
        return str(s.get("id")) if s and s.get("id") else None

    def upload_reserve(self, account: str, n: int) -> Tuple[Optional[str], Optional[Tuple[int, str]]]:
        """Before a guest upload, check the quota under the lock and reserve n bytes; returns (token, None) or (None, (status code, error)).
        Completed records (uploads.json) and in-flight reservations are counted together: file count in 10 minutes, total bytes in 7 days; free disk space is further reduced by all in-flight reservations.
        A successful reservation must be released with upload_release (on success, failure and interruption)."""
        g = self.guests.get(account)
        if g is None or self.guest_bound_id(g) is None:
            return None, (403, "forbidden")
        with self._up_lock:
            now = time.time()
            recs = self.uploadlog.by_account(account)
            mine = [b for a, b in self._up_held.values() if a == account]
            if sum(1 for r in recs if now - float(r.get("at") or 0) < GUEST_UPLOAD_WINDOW) + len(mine) >= GUEST_UPLOAD_RATE:
                return None, (429, "upload quota")
            if sum(int(r.get("size") or 0) for r in recs) + sum(mine) + n > GUEST_UPLOAD_TOTAL:
                return None, (429, "upload quota")
            try:
                free = shutil.disk_usage(self.uploads).free
            except OSError:
                free = None
            if free is not None and free - sum(b for _, b in self._up_held.values()) - n < GUEST_UPLOAD_MIN_FREE:
                return None, (507, "disk full")
            token = os.urandom(8).hex()
            self._up_held[token] = (account, n)
            return token, None

    def upload_release(self, token: str) -> None:
        with self._up_lock:
            self._up_held.pop(token, None)

    def find_offduty(self, sid: str) -> Optional[Dict[str, Any]]:
        for s in self.load_snapshot().get("offduty") or []:
            if isinstance(s, dict) and s.get("sid") == sid:
                return s
        return None

    @staticmethod
    def _match(value: Any, table: Dict[str, str]) -> Optional[str]:
        """Compare in constant time against every account (all are compared, no early exit); returns the matching account name."""
        if not isinstance(value, str):
            return None
        got = None
        raw = value.encode("utf-8")
        for name, want in table.items():
            if hmac.compare_digest(raw, want.encode("utf-8")) and got is None:
                got = name
        return got

    def token_user(self, value: str) -> Optional[str]:
        return self._match(value, self.tokens)

    def token_ok(self, value: str) -> bool:
        return self.token_user(value) == "admin"

    def key_user(self, value: Any) -> Optional[str]:
        return self._match(value, self.keys)

    def key_ok(self, value: Any) -> bool:
        return self.key_user(value) == "admin"

    @staticmethod
    def cookie_header(value: str) -> str:
        return "%s=%s; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=%d" % (COOKIE_NAME, value, COOKIE_MAX_AGE)

    def kfp_of(self, account: str) -> Optional[str]:
        return self.kfps.get(account)

    def issue_device(self, account: str, desc: str) -> str:
        return self.devices.issue(account, desc, self.kfps[account])

    def resolve_cookie(self, value: Any) -> Optional[Dict[str, Any]]:
        """Cookie value -> {account, kind: device|legacy, raw, entry}; None if unknown, revoked, expired or from a changed key."""
        if not isinstance(value, str):
            return None
        e = self.devices.lookup(value, self.kfp_of)
        if e is not None:
            return {"account": e["account"], "kind": "device", "raw": value, "entry": e}
        acc = self.token_user(value)
        if acc is not None:
            return {"account": acc, "kind": "legacy", "raw": value, "entry": None}
        return None

    def legacy_upgrade(self, account: str, legacy: str, desc: str) -> Tuple[str, bool]:
        """New device token for a legacy cookie; requests arriving together (same cookie and device) share one. Returns (raw token, newly issued)."""
        k = hashlib.sha256(("upg\0" + legacy + "\0" + desc).encode("utf-8")).hexdigest()
        now = time.time()
        with self._upg_lock:
            for old in [x for x, (_, t) in self._upgrades.items() if now - t > LEGACY_UPGRADE_REUSE]:
                del self._upgrades[old]
            hit = self._upgrades.get(k)
            if hit is not None and self.devices.has(hit[0]):
                return hit[0], False
            raw = self.issue_device(account, desc)
            self._upgrades[k] = (raw, now)
            return raw, True

    def snapshot_view(self) -> Dict[str, Any]:
        snap = self.load_snapshot()
        now = time.time()
        # pins and do-not-disturb are per session id and a window switch starts a new id: move both along the lineage first,
        # otherwise they silently drop on every device after a switch (lineage map is cached by file mtime)
        try:
            prev_of = {k: v.get("prev", "") for k, v in history._lineage_map(self.lineage_file).items()}
            self.top.follow(prev_of)
            self.mute.follow(prev_of)
        except OSError:
            pass
        sessions = []
        for s in snap.get("sessions") or []:
            if not isinstance(s, dict):
                continue
            item = dict(s)
            item.update(flags_for(self.state, s, now, snap.get("panel"), topped=self.top.has(str(s.get("id")))))
            item["muted"] = self.mute.has(str(s.get("id")))
            item["topped"] = self.top.has(str(s.get("id")))  # persistent pin to top (does not sync to the board; not removed while working)
            sessions.append(item)
        out = dict(snap)
        out["sessions"] = sessions
        try:
            gen = float(snap.get("generatedAt") or 0)
        except (TypeError, ValueError):
            gen = 0.0
        out["stale"] = now - gen > STALE_AFTER
        out["serverNow"] = now
        if out["stale"]:  # gives the frontend header the reason (admin only; not in the guest whitelist)
            out["down"] = {"reason": notify.down_reason(self.read_beat(), now), "at": gen}
        return out

    def read_beat(self) -> Optional[Dict[str, Any]]:
        try:
            with open(self.beat_file, "r", encoding="utf-8") as f:
                b = json.load(f)
        except (OSError, ValueError):
            return None
        return b if isinstance(b, dict) else None

    def _read_json_cached(self, path: str) -> Any:
        """Small JSON file re-read only when its mtime changes; missing or invalid -> None."""
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            self._json_cache.pop(path, None)
            return None
        hit = self._json_cache.get(path)
        if hit is not None and hit[0] == mtime:
            return hit[1]
        try:
            with open(path, "r", encoding="utf-8") as f:
                val = json.load(f)
        except (OSError, ValueError):
            val = None
        self._json_cache[path] = (mtime, val)
        return val

    def pet_info(self) -> Dict[str, Any]:
        """For notify.session_emoji: sorted installed pet ids (None if the manifest is unreadable) and the emoji override map."""
        man = self._read_json_cached(self.pet_manifest)
        over = self._read_json_cached(self.pet_emoji_file)
        return {"names": sorted(k for k in man if isinstance(k, str)) if isinstance(man, dict) else None,
                "emoji": over if isinstance(over, dict) else None}

    def beat_clock(self, at: float, beat: Optional[Dict[str, Any]]) -> str:
        """"Data as of hh:mm": computed with the Mac timezone offset the helper writes into its heartbeat (the container is usually UTC); falls back to container local time."""
        tz = beat.get("tz") if isinstance(beat, dict) else None
        if isinstance(tz, int) and not isinstance(tz, bool) and -14 * 3600 <= tz <= 14 * 3600:
            return time.strftime("%H:%M", time.gmtime(at + tz))
        return time.strftime("%H:%M", time.localtime(at))

    def snapshot_view_guest(self, g: Optional["guestcfg.Guest"] = None) -> Dict[str, Any]:
        """Guest snapshot: output only whitelisted fields, and only the guest's own bound session (empty list and bound.online=false when not on duty).
        Does not call flags_for (it would modify the admin's read/pin records); a guest's read state lives only on the phone.
        The roster follows GUEST_ROSTER: bound (default) contains only the guest's own bound session; all is the whole roster minus session names bound to other guests (guests cannot see each other's sessions)."""
        g = self._g(g)
        snap = self.load_snapshot()
        now = time.time()
        s = self.find_guest_session(g)
        sessions = []
        zones = []
        roster = []
        if s is not None:
            item = {k: s[k] for k in GUEST_SESSION_FIELDS if k in s}
            item.update({"unread": False, "pinned": False, "rest": False, "originNote": "", "originTag": None})
            sessions.append(item)
            # Give all zones (only code, name, color, order): the group-chat avatar's zone color and badge need them
            zones = [{k: z[k] for k in GUEST_ZONE_FIELDS if k in z} for z in snap.get("zones") or [] if isinstance(z, dict)]
            if guestcfg.roster_mode() == "bound":  # only the bound session (the frontend degrades names outside the roster to a zone-colored initial avatar)
                mine = self._names(s)
                roster = [r for r in guest_roster(snap) if r["name"] in mine]
            else:
                others = {o.session for o in self.guests.values() if g is None or o.account != g.account} - {""}
                roster = [r for r in guest_roster(snap) if not self._other_bound(r["name"], snap, others)]
        try:
            gen = float(snap.get("generatedAt") or 0)
        except (TypeError, ValueError):
            gen = 0.0
        out = {"generatedAt": gen, "stale": now - gen > STALE_AFTER, "serverNow": now, "sessions": sessions,
               "zones": zones, "bound": {"name": g.session if g else "", "online": s is not None}, "roster": roster}
        return {k: out[k] for k in GUEST_SNAP_FIELDS}

    def _other_bound(self, name: str, snap: Dict[str, Any], others: set) -> bool:
        """Whether this roster name is a session bound to another guest (full name, or matching the snapshot entry's "zone-plate" short name)."""
        if not others:
            return False
        if name in others:
            return True
        for s in list(snap.get("sessions") or []) + list(snap.get("offduty") or []):
            if isinstance(s, dict) and s.get("name") == name and self._names(s) & others:
                return True
        return False

    def guest_notify_sessions(self, g: Optional["guestcfg.Guest"] = None) -> list:
        """Session table for guest pushes: only the bound session; "finished" ignores anyone's read state and requires only that this turn was human-initiated (not session-to-session / subagent;
        a subagent turn with a bgOwned background wrap-up counts), stopped, and no background work running (same as state.flags_for); the round key is finishedAt.
        "Waiting for you" is not pushed (guests cannot answer): the status is set to busy so notify does not trigger."""
        s = self.find_guest_session(g)
        if s is None:
            return []
        finished = error_finished(s, finished_at(s))  # an errored round follows errorSince
        item = dict(s)
        status = s.get("status")
        item["status"] = "busy" if status == "waiting" else status
        # An unexpected exit does not count as unread (a single "unexpected exit" push is handled by notify._trigger); with errorKind the turn origin and background state are ignored
        item["unread"] = (status == "idle" and not is_gone(s)
                          and (error_kind(s) is not None or (not bg_live(s) and origin_counts(s)))
                          and finished > self.state.installed_at)
        item["finishedAt"] = finished
        item["manualUnread"] = False
        item["disconnected"] = False  # "unexpected exit" is pushed to admin only, not to guests (so notify._trigger never emits lost)
        return [item]

    def _notify_body(self, session: Dict[str, Any], kind: str) -> str:
        # WorkBuddy error / aborted, API error / quota exhausted / unexpected exit: the body uses the status summary (three languages), no transcript read, no "finished" fallback
        if kind in ("err", "stopped", "limit", "lost"):
            return notify.wait_body(session, [])
        if kind == "wait" and notify.sum_body(session, "hans"):  # if the summary renders something from summaryCode, the transcript need not be read (none = empty)
            return notify.wait_body(session, [])
        items = []  # type: list
        full = self.transcript_path(session) if session.get("kind") == "claude" else None
        if full:
            items = transcript.read_page(full, None)["items"]
        return notify.wait_body(session, items) if kind == "wait" else notify.done_body(items)

    def notify_round(self, now: Optional[float] = None) -> list:
        """Compute one notify round and send; returns the actions sent. When the snapshot is stale (the helper is not writing), session pushes are skipped for the whole round and state is left unchanged;
        after 90 s of staleness, admin gets one "Mac disconnected" push; on recovery after 5 minutes of disconnection, "Mac recovered" is pushed (notify.link_step).
        The first round after recovery is computed from the snapshot at that moment: still-waiting / still-unread items push as usual; events that began and ended during the disconnection are dropped (expected)."""
        t = time.time() if now is None else now
        woke = self._last_round is None or t - self._last_round > WAKE_GAP
        self._last_round = t
        view = self.snapshot_view()
        try:
            gen = float(view.get("generatedAt") or 0)
        except (TypeError, ValueError):
            gen = 0.0
        stale = t - gen > STALE_AFTER
        self.prune_daily(t)
        self._link, ev = notify.link_step(self._link, t, stale, woke)
        act = None
        if ev:
            beat = self.read_beat()
            act = notify.link_action(ev, notify.down_reason(beat, t), self.beat_clock(gen, beat) if ev == "down" else None)
        # If an admin device is in use, hold the disconnect push back (the whole page is greyed in the app) and push when they have left while still disconnected; recovery is pushed only if the disconnect was actually pushed and nobody is using it
        self._link_gate, link = notify.link_gate(self._link_gate, ev, act, stale, bool(self._link.get("pushed")),
                                                 self.presence.active("admin", t))
        admin_sessions = [s for s in view["sessions"] if isinstance(s, dict)]
        self._push_out(notify.with_badge(link, admin_sessions), "admin")  # the payload carries the badge count
        if stale:
            return link
        pets = self.pet_info()
        self._notify_state, actions = notify.step(
            self._notify_state, [s for s in view["sessions"] if isinstance(s, dict)], t, self._notify_body,
            view.get("zones") if isinstance(view.get("zones"), list) else None,
            self.presence.active("admin", t), self.presence.seen("admin", t), pets=pets)
        self._push_out(notify.with_badge(actions, admin_sessions), "admin")
        for acc, g in self.guests.items():  # each guest is pushed only their own bound session; subscriptions are sent separately per account
            self._notify_g[acc], guest_actions = notify.step(
                self._notify_g[acc], self.guest_notify_sessions(g), t, self._notify_body,
                view.get("zones") if isinstance(view.get("zones"), list) else None,
                self.presence.active(acc, t), self.presence.seen(acc, t), pets=pets)
            # No recall: the server cannot know whether the guest has seen it, and a recall when the session starts working again would make them miss it
            guest_actions = [a for a in guest_actions if a.get("kind") == "show"]
            # Guest pushes carry a badge too, from the guest push table (only the bound session; waiting is mapped to busy = adminWait, which the guest badge does not count)
            self._push_out(notify.with_badge(guest_actions, self.guest_notify_sessions(g)), acc)
            actions = actions + [dict(a, account=acc) for a in guest_actions]
        return link + actions

    def prune_daily(self, now: float) -> None:
        """Dead-subscription cleanup runs once a day (the first round after api start runs it first: the first time only records the starting point pruneSince, saved in push.json, not reset by restarts)."""
        if self._prune_at is not None and now - self._prune_at < 86400:
            return
        self._prune_at = now
        try:
            n = self.push.prune_dead(now)
            if n:
                sys.stderr.write("push prune removed=%d\n" % n)
        except OSError as e:
            sys.stderr.write("push prune error %s\n" % type(e).__name__)

    def device_list(self, account: str, dev: Optional[str], now: float) -> list:
        """"Notification settings" device list: push.devices + whether it is this device (request header X-Zbs-Dev), in use right now, last active (in-memory in-use time, else last registration time)."""
        out = []
        for d in self.push.devices(account):
            x = dict(d)
            dv = d.get("dev")
            x["self"] = bool(dv and dev and dv == dev)
            x["active"] = bool(dv and self.presence.active_dev(account, dv, now))
            last = self.presence.last(account, dv) if dv else None
            at = d.get("at") if isinstance(d.get("at"), (int, float)) else None
            cand = [v for v in (last, at) if v is not None]
            x["lastActive"] = int(max(cand)) if cand else None
            out.append(x)
        return out

    def _push_out(self, actions: list, account: str) -> None:
        """Send this round's pushes to one account's subscriptions."""
        if not actions or not self.push.public_key():
            return
        for a in actions:
            try:
                r = self.push.send_all(a, account)
                # log one line per push (account, kind, session, title, delivered count), for debugging "notification not received"
                sys.stderr.write("push %s %s %s %s sent=%d/%d failed=%d removed=%d\n" % (
                    account, a.get("kind"), a.get("tag"), a.get("title", ""), r.get("sent", 0),
                    r.get("subscriptions", 0), r.get("failed", 0), r.get("removed", 0)))
            except Exception as e:  # no retry on send failure, and later ones are unaffected
                sys.stderr.write("push %s %s %s error %s\n" % (account, a.get("kind"), a.get("tag"), type(e).__name__))

    def notify_loop(self, stop: threading.Event) -> None:
        while not stop.is_set():
            try:
                self.notify_round()
            except Exception as e:  # the background thread must not die
                sys.stderr.write("notify round error %s: %s\n" % (type(e).__name__, e))
            stop.wait(NOTIFY_POLL)

    def append_diag(self, sid: str, events: list, now: Optional[float] = None) -> int:
        """Phone diagnostic log: one JSON line per event (with session id `session` and server receive time `srv`); rotates first when over the limit. Returns the number of lines written."""
        t = time.time() if now is None else now
        lines = []
        for ev in events:
            if not isinstance(ev, dict):
                continue
            row = dict(ev)
            row["session"] = sid
            row["srv"] = round(t, 3)
            lines.append(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
        if not lines:
            return 0
        with self._diag_lock:
            os.makedirs(os.path.dirname(self.diag_path), exist_ok=True)
            try:
                if os.path.getsize(self.diag_path) > DIAG_MAX_BYTES:
                    os.replace(self.diag_path, self.diag_path + ".1")
            except OSError:  # no file yet
                pass
            with open(self.diag_path, "a", encoding="utf-8") as f:
                f.write("".join(lines))
        return len(lines)

    def log_guest_file(self, account: str, sid: str, name: str, result: str, t: str, dl: bool) -> None:
        """Log one line per guest file fetch: time, account, session, file name (basename only), result, t/dl. A write failure does not affect the fetch."""
        clean = lambda x: "".join(c if c.isprintable() and c != "\t" else "_" for c in str(x or "-"))[:200] or "-"  # noqa: E731
        line = "\t".join([time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), clean(account), clean(sid),
                          clean(os.path.basename(name or "") or "-"), clean(result), "t=" + clean(t),
                          "dl=" + ("1" if dl else "0")]) + "\n"
        with self._gfl_lock:
            try:
                os.makedirs(os.path.dirname(self.guest_file_log), exist_ok=True)
                try:
                    if os.path.getsize(self.guest_file_log) > GUEST_FILE_LOG_MAX:
                        os.replace(self.guest_file_log, self.guest_file_log + ".1")
                except OSError:  # no file yet
                    pass
                with open(self.guest_file_log, "a", encoding="utf-8") as f:
                    f.write(line)
            except OSError:
                pass

    def taskboard(self, code: str) -> Optional[Dict[str, Any]]:
        """Zone task board (read-only): the zone code must be in the snapshot zones and flagged as having a task board; the file is read only from <snapshot dir>/taskboards/<code>.md.
        The helper copies the original per the taskboard path in workzones.json (the api container cannot see the original path)."""
        zone = next((z for z in self.load_snapshot().get("zones") or []
                     if isinstance(z, dict) and z.get("code") == code), None)
        meta = zone.get("taskboard") if zone else None
        if not isinstance(meta, dict):
            return None
        path = os.path.join(os.path.dirname(os.path.abspath(self.snapshot_path)), "taskboards", code + ".md")
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read(64 * 1024)
        except OSError:
            return None
        return {"code": code, "name": zone.get("name") or code, "text": text,
                "mtime": meta.get("mtime"), "truncated": bool(meta.get("truncated"))}

    def windows(self, session: Dict[str, Any]) -> list:
        """Previous-window chain (at most 3, nearest first): [{sid, path, at, via}]; path is used server-side only."""
        full = self.transcript_path(session)
        if not full:
            return []
        root = os.path.realpath(self.projects)
        out = []
        for w in history.chain(str(session.get("id")), full, root, str(session.get("name") or ""), self.lineage_file):
            p = os.path.realpath(w["path"])
            if p.startswith(root + os.sep) and os.path.isfile(p):
                out.append(dict(w, path=p))
        return out

    def guest_windows(self, session: Dict[str, Any], g: Optional["guestcfg.Guest"] = None) -> list:
        """Previous windows a guest may page back through: walk back via windows(), truncating at the first window whose name in the lineage file is not the bound session name (later links of the chain depend on it; no skipping).
        A compaction continuation (continued) is the same window continued; a guess (guess, based only on same directory and name) is not given to guests and truncates there."""
        g = self._g(g)
        want = g.session if g is not None else self.guest_session
        out = []
        for w in self.windows(session):
            if w.get("via") == "guess":
                break  # a guess based only on same directory and name is not an inheritance relation; not given to guests (admin can still page back)
            if w.get("via") != "continued" and w.get("name") != want:
                break
            out.append(w)
        return out

    def jsonl_by_sid(self, sid: str) -> Optional[str]:
        """projects/<any project>/<sid>.jsonl (sid must be a uuid; realpath must be inside the projects root). Used by admin to fetch embedded images from previous windows."""
        if not isinstance(sid, str) or not _UUID_RE.match(sid):
            return None
        root = os.path.realpath(self.projects)
        try:
            dirs = os.listdir(root)
        except OSError:
            return None
        for d in dirs:
            p = os.path.realpath(os.path.join(root, d, sid + ".jsonl"))
            if p.startswith(root + os.sep) and os.path.isfile(p):
                return p
        return None

    def transcript_path(self, session: Dict[str, Any]) -> Optional[str]:
        rel = session.get("transcript")
        if not isinstance(rel, str) or not rel:
            return None
        try:
            root = os.path.realpath(self.projects)
            full = os.path.realpath(os.path.join(root, rel))
            if not full.startswith(root + os.sep) or not os.path.isfile(full):
                return None
        except (ValueError, OSError):
            return None
        return full

    def at_menu(self, session: Dict[str, Any]) -> bool:
        """The session is stopped at a question / approval menu = status waiting (same check as the guest path) and the transcript ends with an unanswered question or a tool call without a result.
        Plain text (with Enter) would then be taken as a key press selecting a menu item. If the transcript cannot be read, assume it is at a menu (better to block than to let it through)."""
        if session.get("status") != "waiting":
            return False
        full = self.transcript_path(session)
        if full is None:
            return True
        try:
            items = transcript.read_page(full, None, limit=5)["items"]
        except (OSError, ValueError):
            return True
        return transcript.menu_pending(items)


def _stamp_refs(page: Dict[str, Any], src: Optional[str]) -> None:
    """Previous-window page: stamp each embedded-image (ref) item with the session id of the transcript it actually lives in, which the frontend uses to fetch the image instead of the current session id. Items of this window are untouched."""
    if not src:
        return
    for it in page.get("items") or []:
        for f in (it.get("files") or []) if isinstance(it, dict) else []:
            if isinstance(f, dict) and "ref" in f:
                f["sid"] = src


def _jsonl_cwd(path: str) -> Optional[str]:
    """First cwd field in a transcript (host path; Claude Code writes it on every line); reads only the first 200 lines / 2MB, returns None if not found."""
    try:
        with open(path, "rb") as f:
            budget = 2 * 2**20
            for _ in range(200):
                line = f.readline(budget)  # when the budget is used up readline(0) returns empty, which ends the loop
                if not line:
                    break
                budget -= len(line)
                if b'"cwd"' not in line:
                    continue
                try:
                    cwd = json.loads(line).get("cwd")
                except (ValueError, AttributeError):
                    continue
                if isinstance(cwd, str) and cwd.startswith("/"):
                    return cwd
    except OSError:
        pass
    return None


def _guest_ctx(out: Dict[str, Any]) -> Dict[str, Any]:
    """Context detail for a guest: keep only the category bar, drop details (admin's memory file paths, skills, MCP tools, subagent types)."""
    data = out.get("data")
    if isinstance(data, dict) and "details" in data:
        out = dict(out, data={k: v for k, v in data.items() if k != "details"})
    return out


def guest_roster(snap: Dict[str, Any]) -> list:
    """On-duty + off-duty sessions -> [{name, zone, lead}], deduplicated by name; zone is None if it is not a known zone code."""
    zones = [z for z in snap.get("zones") or [] if isinstance(z, dict)]
    codes = {z.get("code") for z in zones if isinstance(z.get("code"), str)}
    leads = {z.get("lead") for z in zones if isinstance(z.get("lead"), str)}
    out, seen = [], set()
    for s in list(snap.get("sessions") or []) + list(snap.get("offduty") or []):
        name = s.get("name") if isinstance(s, dict) else None
        if not isinstance(name, str) or not name or name in seen:
            continue
        seen.add(name)
        zone = s.get("zone")
        out.append({"name": name, "zone": zone if zone in codes else None, "lead": name in leads})
    return [{k: r[k] for k in GUEST_ROSTER_FIELDS} for r in out]


_GUEST_API_EXACT = ("/api/auth/me", "/api/auth/logout", "/api/snapshot", "/api/push/key", "/api/push/subscribe",
                  "/api/push/devices",  # the device count in "Notification settings" for this account
                  "/api/push/devices/delete", "/api/presence",  # delete a device of own account; in-use beacon on leaving (touches own account only)
                  "/api/auth/devices", "/api/auth/devices/revoke",  # own signed-in devices (list / sign one out); never another account's
                  _PLAIN_UPLOAD, PROFILE_PATH, AVATAR_PATH, FILE_PATH,  # what a guest may fetch via /api/file is rechecked by _file
                  DIAG_PATH)  # guests may only write error records, filtered and rate-limited by _diag
# Give guests everything inside the bound session - in-session search, previous-window chain, context detail, subagent read-only page (whether it is the bound one is rechecked by the endpoint)
_GUEST_API_RE = re.compile(r"^/api/(requests/[^/]+|sessions/[^/]+/(transcript|send)"
                         r"|session/[^/]+/(search|lineage|context|agent/[^/]+))$")


def guest_api_path(clean: str) -> bool:
    """/api paths a guest may touch (coarse screening at the caddy gate; whether the session is the bound one is rechecked by the endpoint)."""
    return clean in _GUEST_API_EXACT or bool(_GUEST_API_RE.match(clean))


def _clean_path(path: str) -> Optional[str]:
    """After percent-decoding it must already be a canonical path, otherwise None (not treated as a public path)."""
    dec = unquote(path)
    if "%" in dec or "\\" in dec or "//" in dec or not dec.startswith("/"):
        return None
    if any(ord(c) < 32 or ord(c) == 127 for c in dec):
        return None
    # Allow a directory-style trailing slash (e.g. /docs/); everything else must already be canonical
    if posixpath.normpath(dec) != (dec[:-1] if len(dec) > 1 and dec.endswith("/") else dec):
        return None
    return dec


def _strip_key(query: str) -> Tuple[str, bool, Optional[str]]:
    kept = []
    found = None
    for part in query.split("&"):
        if part.startswith("key="):
            found = unquote(part[4:].replace("+", " "))
        elif part:
            kept.append(part)
    return "&".join(kept), found is not None, found


def _parse_range(value: Optional[str], size: int) -> Optional[Tuple[int, int]]:
    """Single-range Range (bytes=a-b / a- / -n) -> (start, end) closed interval; multi-range, malformed or unsatisfiable all give None (treated as absent, full response)."""
    if not value or size <= 0:
        return None
    m = _RANGE_RE.match(value.strip())
    if not m or (not m.group(1) and not m.group(2)):
        return None
    if not m.group(1):
        n = int(m.group(2))
        return (size - min(n, size), size - 1) if n > 0 else None
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else size - 1
    if start >= size or end < start:
        return None
    return start, min(end, size - 1)


def _utf8_cut(path: str, limit: int) -> int:
    """Back the first `limit` bytes off to a UTF-8 character boundary (at most 3 bytes); returns how many bytes to actually send."""
    try:
        with open(path, "rb") as f:
            f.seek(limit - 3)
            tail = f.read(4)  # the four bytes [limit-3, limit]; the last one is the first byte not sent
    except OSError:
        return limit
    cut = limit
    while cut > limit - 3 and len(tail) == 4 and 0x80 <= tail[cut - (limit - 3)] <= 0xBF:
        cut -= 1
    return cut


# Guest slash commands: a letter right after /, and no further / in the command name (/window and /compact x count; absolute paths like /tmp/... do not). Same as SLASH_CMD_RE in web/logic.js
_SLASH_CMD_RE = re.compile(r"/[A-Za-z][\w:.-]*(\s|$)")
# Guests may use only the commands in GUEST_SLASH_COMMANDS (.env, read once at startup: guestcfg.slash_commands; default none). Arguments allowed; sent as is, without the prefix.
# The server rejects other slash commands with 403 slash-forbidden. The same list reaches the frontend via /api/auth/me (slash) for web/logic.js guestSlashBlocked. Admin is unrestricted


def guest_slash(text: str, allowed: Tuple[str, ...] = ()) -> Optional[bool]:
    """Whether plain text is a slash command: returns None if not; otherwise whether it is allowed (command name is in `allowed`)."""
    if not _SLASH_CMD_RE.match(text):
        return None
    return text.split(None, 1)[0] in allowed


# ---- Admin route tables: (kind, pattern, adapter method name); first match wins, so the order is the old if/elif order.
# kind "exact" = path equality, "in" = path is one of the listed paths, "regex" = compiled pattern (ids in group 1). Adapters are the Handler._rt_* methods. ----
_SESSION_TRANSCRIPT_RE = re.compile(r"^/api/sessions/([^/]+)/transcript$")
_OFFDUTY_TRANSCRIPT_RE = re.compile(r"^/api/offduty/([^/]+)/transcript$")
_OFFDUTY_WAKE_RE = re.compile(r"^/api/offduty/([^/]+)/wake$")
_SESSION_UNSEEN_RE = re.compile(r"^/api/sessions/([^/]+)/unseen$")
_SESSION_REST_RE = re.compile(r"^/api/sessions/([^/]+)/rest$")
_SESSION_OFFDUTY_RE = re.compile(r"^/api/sessions/([^/]+)/offduty$")
_SESSION_SEEN_RE = re.compile(r"^/api/sessions/([^/]+)/seen$")
_SESSION_PIN_RE = re.compile(r"^/api/sessions/([^/]+)/pin$")
GET_ROUTES: List[Tuple[str, Any, str]] = [
    ("exact", "/api/snapshot", "_rt_snapshot"),
    ("exact", "/api/push/key", "_rt_push_key"),
    ("exact", "/api/push/devices", "_rt_push_devices"),
    ("in", (PROFILE_PATH, AVATAR_PATH), "_rt_profile_get"),
    ("regex", _REQUEST_RE, "_rt_request_status"),
    ("regex", _CONTEXT_RE, "_rt_context"),
    ("regex", _AGENT_RE, "_rt_agent"),
    ("regex", _HIST_RE, "_rt_history"),
    ("exact", FILE_PATH, "_rt_file"),
    ("exact", "/api/search", "_rt_gsearch"),
    ("regex", _TASKBOARD_RE, "_rt_taskboard"),
    ("regex", _SESSION_TRANSCRIPT_RE, "_rt_transcript"),
    ("regex", _OFFDUTY_TRANSCRIPT_RE, "_rt_offduty_transcript"),
]
POST_ROUTES: List[Tuple[str, Any, str]] = [
    ("exact", "/api/seen-all", "_rt_seen_all"),
    ("exact", "/api/push/subscribe", "_rt_push_subscribe"),
    ("exact", "/api/presence", "_rt_presence"),
    ("exact", "/api/push/devices/delete", "_rt_device_delete"),
    ("exact", "/api/push/test", "_rt_push_test"),
    ("regex", _MUTE_RE, "_rt_mute"),
    ("regex", _TOP_RE, "_rt_top"),
    ("exact", PROFILE_PATH, "_rt_profile_post"),
    ("regex", _OFFDUTY_WAKE_RE, "_rt_wake"),
    ("regex", _SEND_RE, "_rt_send_request"),
    ("regex", _SESSION_UNSEEN_RE, "_rt_unseen"),
    ("regex", _SESSION_REST_RE, "_rt_rest"),
    ("regex", _SESSION_OFFDUTY_RE, "_rt_offduty"),
    ("regex", _SESSION_SEEN_RE, "_rt_seen"),
    ("regex", _SESSION_PIN_RE, "_rt_pin"),
]


class Handler(BaseHTTPRequestHandler):
    server_version = "zbs-api"
    protocol_version = "HTTP/1.1"

    @property
    def app(self) -> App:
        return self.server.app  # type: ignore

    def log_message(self, fmt: str, *args: Any) -> None:
        # log only method and status, not the path (the path may carry a key)
        sys.stderr.write("%s %s\n" % (self.command, args[1] if len(args) > 1 else ""))

    # ---- Output ----
    def _send(self, status: int, body: bytes = b"", ctype: str = "application/json",
              headers: Optional[Dict[str, str]] = None) -> None:
        refresh = self._cookie_refresh() if status != 401 else None
        if refresh and not any(k.lower() == "set-cookie" for k in (headers or {})):
            headers = dict(headers or {})
            headers["Set-Cookie"] = refresh
        self.send_response(status)
        if body or status not in (204, 302):
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.close_connection = True
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, obj: Any, status: int = 200, headers: Optional[Dict[str, str]] = None) -> None:
        self._send(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"), headers=headers)

    def _err(self, status: int, msg: str) -> None:
        self._json({"error": msg}, status)

    def send_error(self, *args: Any, **kwargs: Any) -> None:
        self.close_connection = True
        super().send_error(*args, **kwargs)

    def _take_body(self) -> None:
        """Read small request bodies first for every request; if one cannot be read, drop the whole connection so the next request cannot be smuggled in."""
        self._body = b""
        self._body_ok = True
        if self.headers.get("Transfer-Encoding"):
            self._body_ok = False
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._body_ok = False
            return
        if n < 0 or n > MAX_BODY:
            self._body_ok = False
            return
        if n:
            self._body = self.rfile.read(n)

    def _sub_reply(self, ok: bool, data: Dict[str, Any]) -> None:
        """Subscription reply: echoes the stored language and device id (the frontend uses it to confirm this device is registered with the current language and device info; an old api does not reply, and the frontend re-registers on next start)."""
        if not ok:
            return self._err(409, "too many subscriptions")
        return self._json({"ok": True, "lang": outbox.clean_lang(data.get("lang")),
                           "dev": push.clean_device(data).get("dev")})

    # ---- In-use registration ----
    def _hdr_dev(self) -> Optional[str]:
        return presence.clean_dev(self.headers.get("X-Zbs-Dev"))

    def _presence_hdr(self, account: str) -> None:
        """Foreground snapshot poll request headers: X-Zbs-Dev device id, X-Zbs-Act 1/0, X-Zbs-Seen reports. Without a device id (old frontend, the sw fetching on its own) it does not count."""
        dev = self._hdr_dev()
        if dev is None:
            return
        now = time.time()
        self.app.presence.touch(account, dev, self.headers.get("X-Zbs-Act") == "1", now)
        self.app.presence.report(account, presence.parse_seen(self.headers.get("X-Zbs-Seen")), now)

    def _presence_post(self, account: str) -> None:
        """Beacon on leaving (sendBeacon, text/plain JSON): {dev, act: 0/1, seen: [...]}; the account comes from the cookie only; rate-limited."""
        data = self._read_json()
        if data is None:
            return self._err(400, "bad body")
        dev = presence.clean_dev(data.get("dev"))
        if dev is None:
            return self._err(400, "bad dev")
        now = time.time()
        if not self.app.presence.allow(account, now):
            return self._err(429, "too many")
        self.app.presence.touch(account, dev, data.get("act") in (1, True), now)
        self.app.presence.report(account, presence.parse_seen(data.get("seen")), now)
        return self._json({"ok": True})

    def _device_delete(self, account: str) -> None:
        """"Notification settings" manual device delete: {key}; deletes only this account's (404 if it does not match)."""
        data = self._read_json()
        key = data.get("key") if isinstance(data, dict) else None
        if not isinstance(key, str) or not re.match(r"^[0-9a-f]{16}$", key):
            return self._err(400, "bad key")
        try:
            ok = self.app.push.remove_device(account, key)
        except OSError:
            return self._err(500, "state unavailable")
        return self._json({"ok": True}) if ok else self._err(404, "no such device")

    def _read_json(self) -> Optional[Dict[str, Any]]:
        if not self._body_ok:
            return None
        raw = self._body
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except ValueError:
            return None
        return data if isinstance(data, dict) else None

    # ---- Gate ----
    def _cookie_info(self) -> Optional[Dict[str, Any]]:
        """The request's login (App.resolve_cookie), resolved once per request. On browser-facing responses it also decides the
        Set-Cookie to add (see _cookie_refresh): a legacy hmac cookie on LEGACY_UPGRADE_PATHS is upgraded to a new device token;
        a device token whose cookie is older than devices.RENEW_AFTER is re-sent with a fresh Max-Age."""
        if getattr(self, "_ci_hdrs", None) is self.headers:
            return self._ci
        self._ci_hdrs = self.headers
        self._ci = None  # type: Optional[Dict[str, Any]]
        self._ci_set = None  # type: Optional[str]
        raw = self.headers.get("Cookie")
        if not raw:
            return None
        try:
            jar = SimpleCookie()
            jar.load(raw)
        except Exception:
            return None
        m = jar.get(COOKIE_NAME)
        info = self.app.resolve_cookie(m.value) if m is not None else None
        self._ci = info
        path = urlsplit(self.path).path
        if info is None or not path.startswith("/api/") or path in NO_COOKIE_REFRESH:
            return info
        if info["kind"] == "legacy":
            if self.command == "GET" and path in LEGACY_UPGRADE_PATHS:
                desc = devices.describe(self.headers.get("User-Agent"))
                tok, new = self.app.legacy_upgrade(info["account"], info["raw"], desc)
                if new:
                    sys.stderr.write("legacy cookie upgraded to device token account=%s device=%s\n" % (info["account"], desc))
                info["upgraded"] = devices.token_hash(tok)
                self._ci_set = self.app.cookie_header(tok)
        elif self.app.devices.needs_renew(info["entry"]):
            self.app.devices.mark_renewed(info["entry"]["hash"])
            self._ci_set = self.app.cookie_header(info["raw"])
        return info

    def _cookie_refresh(self) -> Optional[str]:
        """Pending renewal / upgrade Set-Cookie for this request (only if the cookie was looked at in this request)."""
        if getattr(self, "_ci_hdrs", None) is not self.headers:
            return None
        return self._ci_set

    def _cookie_user(self) -> Optional[str]:
        """Account for the cookie (admin / guest); None if absent, forged, revoked or expired."""
        info = self._cookie_info()
        return info["account"] if info is not None else None

    def _gate(self) -> Optional[str]:
        """Board endpoint: returns the account name; if not logged in, answers 401 first and returns None. What a guest may use is decided by each route's guest branch (default 403)."""
        user = self._cookie_user()
        if user is None:
            self._err(401, "unauthorized")
        return user

    def _forbid(self) -> None:
        self._err(403, "forbidden")

    def _client_ip(self) -> str:
        """Source IP: caddy rewrites X-Forwarded-For to the real client IP (a client-supplied value is not trusted); take the last segment."""
        xff = self.headers.get("X-Forwarded-For") or ""
        last = xff.split(",")[-1].strip()
        return last or self.client_address[0]

    def _auth_check(self) -> None:
        uri = self.headers.get("X-Forwarded-Uri") or "/"
        path, _, rest = uri.partition("?")
        query = rest.partition("#")[0]
        path = path.partition("#")[0]
        clean = _clean_path(path)
        query, has_key, given = _strip_key(query)
        if has_key:  # checked before the public paths, so /login.html?key= is redirected too
            return self._legacy_key_redirect(given or "")
        if clean is not None and (clean in PUBLIC_EXACT
                                  or any(clean.startswith(p) for p in PUBLIC_PREFIX)):
            return self._send(200)
        user = self._cookie_user()
        if user == "admin":
            return self._send(200, headers={"X-ZBS-User": "admin"})
        if user is not None:  # guest (any guest is the same for coarse screening; X-ZBS-User gives the account name, and private reverse proxies accept only admin)
            return self._guest_check(clean, user)
        if "text/html" in (self.headers.get("Accept") or ""):
            return self._send(302, headers={"Location": "/login.html"})
        self._send(401, b'{"error":"unauthorized"}')

    def _legacy_key_redirect(self, given: str) -> None:
        """Legacy ?key= links, remove after LEGACY_KEY_LINKS_REMOVE_AFTER. A GET no longer logs in (the query string lands in proxy logs, history
        and Referer): move the key into the fragment of the login page, which auto-submits it by POST (same rate limit and 409 anti login-CSRF rule).
        Any value is redirected the same way, so the response says nothing about whether the key is valid. The log line names the account only, never the key."""
        sys.stderr.write("legacy ?key= link used account=%s\n" % (self.app.key_user(given) or "unknown"))
        loc = "/login.html#k=%s&legacy=1" % quote(given, safe="")
        self._send(302, headers={"Location": loc, "Referrer-Policy": "no-referrer"})

    def _guest_check(self, clean: Optional[str], account: str = GUEST) -> None:
        """Guest accounts (the caddy-level coarse screening): the admin-only proxy prefixes (ADMIN_ONLY_PREFIXES) and everything under them give 403; /lab and /lab/* also 403;
        /api/* allows whitelisted paths only (whether a session is the bound one is rechecked by each endpoint); the page shell and pet images pass (guest mode is Soulgent itself)."""
        if clean is None or any(clean == p or clean.startswith(p + "/") for p in self.app.admin_only):
            return self._send(403, b'{"error":"forbidden"}')
        if clean == LAB_PREFIX or clean.startswith(LAB_PREFIX + "/"):
            return self._send(403, b'{"error":"forbidden"}')
        if (clean == "/api" or clean.startswith("/api/")) and not guest_api_path(clean):
            return self._send(403, b'{"error":"forbidden"}')
        self._send(200, headers={"X-ZBS-User": account})

    def _same_origin(self) -> bool:
        """CSRF check for state-changing requests. A browser sends Origin (or at least Referer): Origin wins when present, otherwise the Referer's scheme+host+port must match this site (Host).
        Neither header (curl, dev_proxy, the helper and other non-browsers) passes. "Origin: null" (sandboxed iframe, privacy redirect) has no host, so it is rejected."""
        host = (self.headers.get("Host") or "").lower()
        for name in ("Origin", "Referer"):
            val = self.headers.get(name)
            if not val:
                continue
            try:
                o = urlsplit(val)
                return o.scheme in ("https", "http") and bool(o.netloc) and o.netloc.lower() == host
            except ValueError:
                return False
        return True

    def _json_ctype(self) -> bool:
        """Content-Type is application/json (parameters such as charset are fine). Needed for bodies parsed as JSON: a cross-site simple request (form, text/plain) cannot carry it without a CORS preflight."""
        return (self.headers.get("Content-Type") or "").split(";")[0].strip().lower() == "application/json"

    def _auth_login(self) -> None:
        ip = self._client_ip()
        if self.app.limiter.blocked(ip):
            return self._err(429, "too many attempts")
        body = self._read_json()
        who = self.app.key_user(body.get("key")) if body is not None else None
        if who is None:
            self.app.limiter.fail(ip)
            return self._err(401, "unauthorized")
        self.app.limiter.ok(ip)
        cur = self._cookie_user()
        if body.get("auto") is True and cur is not None and cur != who:
            # Auto-submit from a #k= link on the login page must not replace a logged-in different identity (login CSRF); a deliberate manual submit may
            return self._err(409, "already logged in as another account")
        # Every login issues a new device token; the device token it replaces (if any) is deleted rather than left to expire
        info = self._cookie_info()
        if info is not None and info["kind"] == "device":
            self.app.devices.remove_token(info["raw"])
        cookie = self.app.cookie_header(self.app.issue_device(who, devices.describe(self.headers.get("User-Agent"))))
        if who == "admin":  # admin gets 204 as usual
            return self._send(204, headers={"Set-Cookie": cookie})
        body_out = json.dumps({"user": who, "next": "/"}).encode("utf-8")
        self._send(200, body_out, headers={"Set-Cookie": cookie})

    def _auth_me(self) -> None:
        user = self._cookie_user()
        if user is None:
            return self._err(401, "unauthorized")
        # tag = the guest message prefix (without the trailing space). Given to both sides: the admin also uses it to recognize guest bubbles
        g = self.app.guests.get(user)
        if g is not None:  # guest mode: the frontend switches the UI on this; only the guest's own data is given (who the other guests are, or how many, is not)
            # store: the storage name of the guest's data (a legacy name is kept for old deployments); the frontend uses it to key local read state so a version change does not lose it
            # slash: the slash commands guests may send (GUEST_SLASH_COMMANDS), so the frontend blocks the same ones the server rejects
            return self._json({"user": user, "account": user, "session": g.session, "tag": g.tag, "store": g.store,
                               "slash": list(self.app.guest_slash)})
        # Admin additionally gets the guest list (account, prefix, bound session name), to tell by session which guest a bubble belongs to and whose avatar/nickname to fetch; no keys
        self._json({"user": user, "account": user, "tag": self.app.guest_tag,
                    "guests": [{"account": a, "tag": x.tag, "session": x.session} for a, x in self.app.guests.items()]})

    def _auth_logout(self) -> None:
        """Sign out this device: its device token is deleted (a legacy cookie can only be cleared in the browser)."""
        info = self._cookie_info()
        if info is not None and info["kind"] == "device":
            self.app.devices.remove_token(info["raw"])
        self._send(204, headers={"Set-Cookie": CLEAR_COOKIE})

    def _auth_devices(self) -> None:
        """Signed-in devices of the caller's own account: [{id, desc, issuedAt, lastSeen, self}]. id is a short non-secret handle."""
        info = self._cookie_info()
        if info is None:
            return self._err(401, "unauthorized")
        acc = info["account"]
        mine = info.get("upgraded") or (info["entry"]["hash"] if info["entry"] else None)
        rows = self.app.devices.list(acc, self.app.kfp_of(acc))
        for r in rows:
            r["self"] = r.pop("_h") == mine
        self._json({"devices": rows})

    def _auth_revoke(self) -> None:
        """Sign out one of the caller's own devices: {id}. Another account's id is 404. Revoking this device also clears its cookie."""
        info = self._cookie_info()
        if info is None:
            return self._err(401, "unauthorized")
        body = self._read_json()
        tid = body.get("id") if body is not None else None
        if not isinstance(tid, str) or not re.match(r"^[0-9a-f]{12}$", tid):
            return self._err(400, "bad id")
        h = self.app.devices.revoke(info["account"], tid)
        if h is None:
            return self._err(404, "no such device")
        if info["entry"] is not None and h == info["entry"]["hash"]:
            return self._json({"ok": True, "self": True}, headers={"Set-Cookie": CLEAR_COOKIE})
        self._json({"ok": True, "self": False})

    # ---- Admin route adapters: each takes (match or None, urlsplit result); the tables GET_ROUTES / POST_ROUTES (module level) name them ----
    def _dispatch(self, table: List[Tuple[str, Any, str]], path: str, parts: Any) -> bool:
        """First matching row wins (table order = the old if/elif order); returns False when no row matches."""
        for kind, pat, name in table:
            if kind == "exact":
                if path == pat:
                    getattr(self, name)(None, parts)
                    return True
            elif kind == "in":  # one of several exact paths
                if path in pat:
                    getattr(self, name)(None, parts)
                    return True
            else:
                m = pat.match(path)
                if m:
                    getattr(self, name)(m, parts)
                    return True
        return False

    def _rt_snapshot(self, m: Any, parts: Any) -> None:
        self._presence_hdr("admin")
        self._json(self.app.snapshot_view(), headers={SNAP_ACCOUNT_HDR: "admin"})

    def _rt_push_key(self, m: Any, parts: Any) -> None:
        key = self.app.push.public_key()
        self._json({"key": key}) if key else self._err(503, "push not configured")

    def _rt_push_devices(self, m: Any, parts: Any) -> None:
        self._json({"devices": self.app.device_list("admin", self._hdr_dev(), time.time())})

    def _rt_profile_get(self, m: Any, parts: Any) -> None:
        # ?account=<guest account> reads that guest's profile (guest bubble avatar/nickname)
        acc = guestcfg.normalize_account((parse_qs(parts.query).get("account") or ["admin"])[0])  # the old name from older frontends is also accepted
        if acc != "admin" and acc not in self.app.profiles:
            return self._err(400, "bad account")
        self._profile_get(parts.path, self.app.profile if acc == "admin" else self.app.profiles[acc])

    def _rt_request_status(self, m: Any, parts: Any) -> None:
        self._request_status(unquote(m.group(1)))

    def _rt_context(self, m: Any, parts: Any) -> None:
        self._context(unquote(m.group(1)))

    def _rt_agent(self, m: Any, parts: Any) -> None:
        self._agent(unquote(m.group(1)), unquote(m.group(2)), parts.query)

    def _rt_history(self, m: Any, parts: Any) -> None:
        self._history(unquote(m.group(1)), m.group(2), parts.query)

    def _rt_file(self, m: Any, parts: Any) -> None:
        self._file(parts.query, "admin")

    def _rt_gsearch(self, m: Any, parts: Any) -> None:  # global search (admin; guests get 403 via _guest_get)
        self._gsearch(parts.query)

    def _rt_taskboard(self, m: Any, parts: Any) -> None:
        board = self.app.taskboard(m.group(1))
        self._json(board) if board else self._err(404, "no taskboard")

    def _rt_transcript(self, m: Any, parts: Any) -> None:
        self._transcript(unquote(m.group(1)), parts.query)

    def _rt_offduty_transcript(self, m: Any, parts: Any) -> None:
        self._transcript(unquote(m.group(1)), parts.query, offduty=True)

    def _rt_seen_all(self, m: Any, parts: Any) -> None:
        ids = [str(s.get("id")) for s in self.app.load_snapshot().get("sessions") or []
               if isinstance(s, dict)]
        t = time.time()
        self.app.state.mark_all_seen(ids, t)
        self._mark(seen={i: t for i in ids})
        self._json({"ok": True})

    def _rt_push_subscribe(self, m: Any, parts: Any) -> None:
        data = self._read_json()
        sub = push.clean_subscription(data)
        if sub is None:
            return self._err(400, "bad subscription")
        try:
            ok = self.app.push.subscribe(sub, "admin", data.get("lang"), data)  # store UI language, device info
        except OSError:
            return self._err(500, "state unavailable")
        self._sub_reply(ok, data)

    def _rt_presence(self, m: Any, parts: Any) -> None:
        self._presence_post("admin")

    def _rt_device_delete(self, m: Any, parts: Any) -> None:
        self._device_delete("admin")

    def _rt_push_test(self, m: Any, parts: Any) -> None:
        if not self.app.push.public_key():
            return self._err(503, "push not configured")
        self._read_json()  # the body is read (and ignored) as before
        try:
            self._json(self.app.push.send_test("admin"))
        except OSError:
            self._err(500, "state unavailable")

    def _rt_mute(self, m: Any, parts: Any) -> None:
        self._mute(unquote(m.group(1)))

    def _rt_top(self, m: Any, parts: Any) -> None:
        self._top(unquote(m.group(1)))

    def _rt_profile_post(self, m: Any, parts: Any) -> None:
        self._profile_post()

    def _rt_wake(self, m: Any, parts: Any) -> None:
        self._wake(unquote(m.group(1)))

    def _rt_send_request(self, m: Any, parts: Any) -> None:
        self._send_request(unquote(m.group(1)), m.group(2))

    def _rt_unseen(self, m: Any, parts: Any) -> None:
        self._unseen(unquote(m.group(1)))

    def _rt_rest(self, m: Any, parts: Any) -> None:
        self._rest(unquote(m.group(1)))

    def _rt_offduty(self, m: Any, parts: Any) -> None:
        self._offduty(unquote(m.group(1)))

    def _rt_seen(self, m: Any, parts: Any) -> None:
        sid = unquote(m.group(1))
        if self.app.find_session(sid) is None:
            return self._err(404, "unknown session")
        t = time.time()
        self.app.state.mark_seen(sid, t)
        self._mark(seen={sid: t})
        self._json({"ok": True})

    def _rt_pin(self, m: Any, parts: Any) -> None:
        sid = unquote(m.group(1))
        if self.app.find_session(sid) is None:
            return self._err(404, "unknown session")
        body = self._read_json()
        if body is None or not isinstance(body.get("pinned"), bool):
            return self._err(400, "bad body")
        self.app.state.set_pin(sid, body["pinned"], by_phone=True)
        self._mark(pin={sid: body["pinned"]})
        self._json({"ok": True})

    # ---- Routes ----
    def do_GET(self) -> None:
        self._take_body()
        parts = urlsplit(self.path)
        path = parts.path
        if path == "/api/auth/check":
            return self._auth_check()
        if path == "/api/auth/me":
            return self._auth_me()
        if path == "/api/auth/devices":
            return self._auth_devices()
        user = self._gate()
        if user is None:
            return
        if user != "admin":
            return self._guest_get(self.app.guests[user], path, parts.query)
        if not self._dispatch(GET_ROUTES, path, parts):
            self._err(404, "not found")

    def do_POST(self) -> None:
        if not self._same_origin():  # one gate for every state-changing request (CSRF, login CSRF included); uploads and the beacon need no JSON Content-Type
            self.close_connection = True  # the body (possibly an upload) is left unread
            return self._err(403, "forbidden")
        parts = urlsplit(self.path)
        path = parts.path
        mu = _UPLOAD_RE.match(path)
        if mu:  # the upload body can reach 20 MB; bypass _take_body, _upload reads it in streamed chunks
            self._body, self._body_ok = b"", False
            user = self._gate()
            if user != "admin":  # 403 for guests: this one is sent as is after upload, bypassing the guest prefix
                return self._forbid() if user else None
            return self._upload(unquote(mu.group(1)), parts.query)
        if path == _PLAIN_UPLOAD:  # attachment bar first: just store the file, no enqueue (guests can use it too)
            self._body, self._body_ok = b"", False
            user = self._gate()
            if user is None:
                return
            return self._upload(None, parts.query, user)
        if path == DIAG_PATH:  # a diagnostic log batch can reach 256 KB, over _take_body's 64 KB, so read it here
            self._body, self._body_ok = b"", False
            user = self._gate()
            if user is None:
                return None
            return self._diag(guest=user if user != "admin" else None)
        self._take_body()
        if self._body and path != "/api/presence" and not self._json_ctype():  # the beacon is text/plain by design (sendBeacon with a string)
            return self._err(415, "content-type must be application/json")
        if path == "/api/auth":
            return self._auth_login()
        if path == "/api/auth/logout":
            return self._auth_logout()
        if path == "/api/auth/devices/revoke":
            return self._auth_revoke()
        user = self._gate()
        if user is None:
            return
        if user != "admin":
            return self._guest_post(self.app.guests[user], path)
        if not self._dispatch(POST_ROUTES, path, parts):
            self._err(404, "not found")

    # ---- Guest mode: whitelisted routes, everything else 403. g = the guest identified by the cookie; everything is computed only from g's own bound session/account ----
    def _guest_get(self, g: "guestcfg.Guest", path: str, query: str) -> None:
        acc = g.account
        if path == "/api/snapshot":
            self._presence_hdr(acc)
            return self._json(self.app.snapshot_view_guest(g), headers={SNAP_ACCOUNT_HDR: acc})
        if path == "/api/push/key":
            key = self.app.push.public_key()
            return self._json({"key": key}) if key else self._err(503, "push not configured")
        if path == "/api/push/devices":
            return self._json({"devices": self.app.device_list(acc, self._hdr_dev(), time.time())})
        m = _REQUEST_RE.match(path)
        if m:  # poll for the result after sending: only requests recorded as sent by this guest (no record - admin's, other guests', from before an api restart - always 404)
            rid = unquote(m.group(1))
            if not self.app.owned_by(self.app.rid_owner, rid, acc):
                return self._err(404, "unknown request")
            return self._request_status(rid, guest=True)
        bound = self.app.guest_bound_id(g)
        m = _SESSION_RE.match(path)
        if m and m.group(2) == "transcript" and bound and unquote(m.group(1)) == bound:
            return self._transcript(bound, query, guest=g)
        if path in (PROFILE_PATH, AVATAR_PATH):  # only their own profile; ?account= is ignored
            return self._profile_get(path, self.app.profiles[acc])
        # Features inside the bound session - first check it is the bound one, then hand to the same handler as admin (403 for any non-bound session, not 400/404, so existence cannot be probed)
        m = _HIST_RE.match(path)
        if m and bound and unquote(m.group(1)) == bound:
            return self._history(bound, m.group(2), query, guest=g)
        m = _CONTEXT_RE.match(path)
        if m and bound and unquote(m.group(1)) == bound:
            return self._context(bound, guest=g)
        m = _AGENT_RE.match(path)
        if m and bound and unquote(m.group(1)) == bound:
            return self._agent(bound, unquote(m.group(2)), query, guest=acc)
        if path == FILE_PATH:  # guest: only embedded images of the bound session (sid+ref) and signed links of own uploads (tok); p= is always 404
            return self._file(query, acc)
        self._forbid()

    def _guest_post(self, g: "guestcfg.Guest", path: str) -> None:
        acc = g.account
        if path == "/api/push/subscribe":
            data = self._read_json()
            sub = push.clean_subscription(data)
            if sub is None:
                return self._err(400, "bad subscription")
            try:
                ok = self.app.push.subscribe(sub, acc, data.get("lang"), data)  # store UI language, device info
            except OSError:
                return self._err(500, "state unavailable")
            return self._sub_reply(ok, data)
        if path == "/api/presence":
            return self._presence_post(acc)
        if path == "/api/push/devices/delete":
            return self._device_delete(acc)
        if path == PROFILE_PATH:  # change own nickname/avatar
            return self._profile_post(self.app.profiles[acc])
        m = _SEND_RE.match(path)
        bound = self.app.guest_bound_id(g)
        if m and m.group(2) == "send" and bound and unquote(m.group(1)) == bound:
            return self._guest_send(g, bound)
        self._forbid()

    def _guest_send(self, g: "guestcfg.Guest", sid: str) -> None:
        """Accepts only {text, enter?} or {text?, files}; key presses, answer steps, approvals and esc are all 403; enter can only be true.
        The server prepends this guest's prefix (GUEST_TAG / GUESTn_TAG) to the text, also for attachment messages without text.
        Rejected while the session is waiting for you (question/approval menu): the helper's text carries an Enter, which would select the first option / approve on the menu on the admin's behalf.
        Attachments must be the guest's own uploads (403 if recorded as another guest's). Slash commands pass only if in GUEST_SLASH_COMMANDS; others get 403 slash-forbidden."""
        body = self._read_json()
        if body is None:
            return self._err(400, "bad body")
        recall = "recall" in body
        if recall and set(body) != {"recall"}:
            return self._forbid()
        if not recall and (set(body) - {"text", "files", "enter", "quote"} or body.get("enter", True) is not True):
            return self._forbid()
        s = self.app.find_guest_session(g)
        if s is None or str(s.get("id")) != sid:
            return self._forbid()
        if recall:
            return self._guest_recall(g, s, body.get("recall"))
        if s.get("status") == "waiting":
            return self._err(409, "session-waiting")
        raw = body.get("text")
        if "files" in body:
            files = outbox.clean_files(body["files"], self.app.uploads)
            text = outbox.clean_text(raw) if raw not in (None, "") else ""
            if files is None:
                return self._err(400, "bad files")
            if any(self.app.uploadlog.owner(f) != g.account for f in files):
                return self._forbid()  # may send only own uploads (by the persistent upload log; old uploads without a record are never allowed)
            if text is None:
                return self._err(400, "bad text")
            qt = outbox.with_quote(body.get("quote"), text)  # quoted reply: the guest prefix stays first (the frontend relies on it to recognize guests)
            if qt is None:
                return self._err(400, "bad quote")
            lines = qt != text
            text = (g.tag + " " + qt) if qt else g.tag
            payload = outbox.with_lang({"type": "message", "text": text, "files": files, "lines": lines},
                                       self._req_lang())  # type: Dict[str, Any]
        else:
            text = outbox.clean_text(raw)
            if text is None:
                return self._err(400, "bad text")
            qt = outbox.with_quote(body.get("quote"), text)
            if qt is None:
                return self._err(400, "bad quote")
            # Slash commands: plain text (no quote) starting with /. Allowed ones (GUEST_SLASH_COMMANDS) are sent as is without the prefix, which Claude Code requires; others are rejected.
            # Same rule as the frontend pending bubble: web/logic.js guestPendText / guestSlashBlocked; change both together.
            # Cost: text without the prefix counts as the admin's; the guest cannot recall it and it does not show as the guest's own in the conversation.
            slash = guest_slash(text, self.app.guest_slash) if qt == text else None
            if slash is False:
                return self._err(403, "slash-forbidden")
            out = text if slash else g.tag + " " + qt
            payload = {"type": "text", "text": out, "enter": True, "lines": qt != text}
            text = out
        if len(text) > outbox.MAX_TEXT:
            return self._err(400, "bad text")
        try:
            rid = outbox.enqueue(self.app.outbox, sid, payload, g.account)
        except OSError:
            return self._err(500, "outbox unavailable")
        self._uploads_sent(payload, sid)
        self.app.remember(self.app.rid_owner, rid, g.account)
        self._json({"requestId": rid}, 202)

    def _guest_recall(self, g: "guestcfg.Guest", s: Dict[str, Any], raw: Any) -> None:
        """Guest recall: accepts only {recall: original text}, which must be this guest's own (starting with "own prefix + space", or just the bare prefix for attachment-only).
        Rejected while the session is at a question/approval menu: the helper's recall presses up-arrow, which would move the menu selection.
        The same 2-minute window applies (409 too-old after that); a still-queued message is pulled back with up-arrow as usual; an already-read one gets no key press,
        and only mode (answered / processing) is returned so the frontend puts the text back - guests may not press Esc to interrupt the admin's session turn."""
        text = outbox.clean_lines(raw)
        if text is None:
            return self._err(400, "bad text")
        if not g.own_re.match(text):
            return self._forbid()
        if s.get("status") == "waiting":
            return self._err(409, "session-waiting")
        full = self.app.transcript_path(s)
        if full is None:
            return self._err(409, "no-transcript")
        hit = self._recall_hit(full, text)
        if hit is None:
            return self._err(409, "too-old")
        queued = transcript.queued_texts(full)
        if text[:200] not in queued:
            return self._json({"mode": "processing" if s.get("status") == "busy" else "answered"})
        if any(not g.own_re.match(k) for k in queued):
            return self._err(409, "admin-queued")  # the queue holds others' (admin's) messages; if the helper fails midway pulling back and resending, they would be lost, so it is not allowed
        try:
            rid = outbox.enqueue(self.app.outbox, str(s.get("id")), {"type": "recall", "text": text}, g.account)
        except OSError:
            return self._err(500, "outbox unavailable")
        self.app.remember(self.app.rid_owner, rid, g.account)
        self._json({"requestId": rid}, 202)

    def _recall_hit(self, full: str, text: str) -> Optional[Dict[str, Any]]:
        """Whether the message to recall is within the 2-minute window. Within it returns {ts, last}; not found, no timestamp (old data) or timed out all return None."""
        try:
            hit = transcript.recall_lookup(full, text, lambda t: outbox.clean_lines(t) or "")
        except (OSError, ValueError):
            return None
        if hit is None:
            return None
        at = history._iso_epoch(hit["ts"])
        if at is None or time.time() - at > RECALL_WINDOW + RECALL_GRACE:
            return None
        return hit

    def _mark(self, seen: Optional[Dict[str, float]] = None, pin: Optional[Dict[str, bool]] = None) -> None:
        """Put the read/pin sync request into the outbox; failing to enqueue does not affect the phone (the frontend does not wait for the result)."""
        if seen is not None and not seen:
            return
        try:
            outbox.enqueue_mark(self.app.outbox, seen=seen, pin=pin)
        except OSError:
            pass

    def _unseen(self, sid: str) -> None:
        """Mark as unread (swipe left): rewrites the read time to 1 second before the session's last activity, so both the phone and the Mac board show a red dot.
        Only effective for sessions that are "finished and could count as unread": idle, with activity after the api was installed.
        Turns from session-to-session traffic / subagent reports can also be marked manually (the automatic red dot still ignores them; see state.flags_for)."""
        s = self.app.find_session(sid)
        if s is None:
            return self._err(404, "unknown session")
        try:
            since = float(s.get("since") or 0)
        except (TypeError, ValueError):
            since = 0.0
        if s.get("status") != "idle" or since - 1 <= self.app.state.installed_at:
            return self._err(409, "not-markable")
        t = since - 1
        self.app.state.mark_unseen(sid, t)
        try:
            outbox.enqueue_mark(self.app.outbox, unseen={sid: t})
        except OSError:
            pass
        self._json({"ok": True, "seenAt": t})

    def _rest(self, sid: str) -> None:
        """Manual rest {on: true|false}: enter/leave the "Resting" section at the bottom of the list; new activity in the session clears it automatically (see state.manual_rest)."""
        if self.app.find_session(sid) is None:
            return self._err(404, "unknown session")
        body = self._read_json()
        if body is None or not isinstance(body.get("on"), bool):
            return self._err(400, "bad body")
        try:
            self.app.state.set_rest(sid, body["on"])
        except OSError:
            return self._err(500, "state unavailable")
        self._json({"ok": True})

    def _offduty(self, sid: str) -> None:
        """Send off duty: handed to the helper to run offduty.py --off <name>; the frontend polls /api/requests/<rid>."""
        s = self.app.find_session(sid)
        if s is None:
            return self._err(404, "unknown session")
        name = s.get("name")
        if s.get("kind") != "claude" or not isinstance(name, str) or not name or name.startswith("-"):
            return self._err(409, "not-offdutyable")
        try:
            rid = outbox.enqueue_offduty(self.app.outbox, sid, name)
        except OSError:
            return self._err(500, "outbox unavailable")
        self._json({"requestId": rid}, 202)

    def _req_lang(self) -> Optional[str]:
        """?lang=en|hans|hant on the send request URL (in the URL rather than the body: an old api does not accept extra keys in the body and guests would get 403,
        while an old api simply ignores URL parameters). Returns None if unrecognized."""
        q = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        return outbox.clean_lang((q.get("lang") or [""])[0])

    def _send_request(self, sid: str, action: str) -> None:
        session = self.app.find_session(sid)
        if session is None:
            return self._err(404, "unknown session")
        if session.get("kind") != "claude":
            return self._err(400, "unsupported session")
        payload = {"type": "screen"}  # type: Dict[str, Any]
        mode = ""  # returned to the frontend when recall interrupts with Esc
        if action == "send":
            body = self._read_json()
            if body is None:
                return self._err(400, "bad body")
            # plain text/attachment messages landing on a question/approval menu would select an option for you; answer cards and approval cards go through steps/key and are unaffected
            plain = "files" in body or not any(k in body for k in ("recall", "steps", "key"))
            if plain and self.app.at_menu(session):
                return self._err(409, "at-menu")
            if "files" in body:
                files = outbox.clean_files(body["files"], self.app.uploads)
                raw = body.get("text")
                text = outbox.clean_text(raw) if raw not in (None, "") else ""
                if files is None:
                    return self._err(400, "bad files")
                if text is None:
                    return self._err(400, "bad text")
                qt = outbox.with_quote(body.get("quote"), text)  # quoted reply
                if qt is None:
                    return self._err(400, "bad quote")
                payload = outbox.with_lang({"type": "message", "text": qt, "files": files, "lines": qt != text},
                                           self._req_lang())  # the hint text follows the phone language
            elif "recall" in body:  # recall; 2-minute window
                if self.app.at_menu(session):  # recall presses up-arrow / Esc, which would move the selection on a question/approval menu (blocked in every case first)
                    return self._err(409, "at-menu")
                text = outbox.clean_lines(body.get("recall"))
                if text is None:
                    return self._err(400, "bad text")
                full = self.app.transcript_path(session)
                if full is None:
                    return self._err(409, "no-transcript")
                hit = self._recall_hit(full, text)
                if hit is None:
                    return self._err(409, "too-old")
                busy = session.get("status") == "busy"
                if text[:200] in transcript.queued_texts(full):
                    payload = {"type": "recall", "text": text}  # still queued: pull back with up-arrow as usual
                elif busy and hit["last"]:
                    payload = {"type": "key", "key": "esc"}  # already read + busy + the last message: Esc interrupts this turn
                    mode = "interrupted"
                else:
                    # already read but answered (answered) / more messages follow and it is processing this one (processing): no key press, the frontend just puts the text back
                    return self._json({"mode": "processing" if busy else "answered"})
            elif "steps" in body:
                steps = outbox.clean_steps(body["steps"])
                if steps is None:
                    return self._err(400, "bad steps")
                payload = {"type": "steps", "steps": steps}
            elif "key" in body:
                if body["key"] not in outbox.KEY_WHITELIST:
                    return self._err(400, "bad key")
                payload = {"type": "key", "key": body["key"]}
            else:
                text = outbox.clean_text(body.get("text"))
                enter = body.get("enter", True)
                if text is None or not isinstance(enter, bool):
                    return self._err(400, "bad text")
                qt = outbox.with_quote(body.get("quote"), text)  # quoted reply
                if qt is None:
                    return self._err(400, "bad quote")
                payload = {"type": "text", "text": qt, "enter": enter, "lines": qt != text}
        try:
            rid = outbox.enqueue(self.app.outbox, sid, payload, "admin")
        except OSError:
            return self._err(500, "outbox unavailable")
        self._uploads_sent(payload, sid)
        self._json(dict({"requestId": rid}, **({"mode": mode} if mode else {})), 202)

    def _uploads_sent(self, payload: Dict[str, Any], sid: str) -> None:
        """An attachment message was sent: add this session to the upload record (whether a guest may get this file's link depends on it). A failure to record is only logged; the message is still sent."""
        if payload.get("type") == "message" and isinstance(payload.get("files"), list):
            try:
                self.app.uploadlog.sent(payload["files"], sid)
            except OSError as e:
                sys.stderr.write("failed to write uploads.json: %s\n" % e)

    def _upload(self, sid: Optional[str], query: str, account: str = "admin") -> None:
        """sid None: just save the file and return {"file"}, no enqueue (for the attachment bar). Guest uploads are recorded with their owner (another guest cannot send this file)."""
        if sid is not None:
            session = self.app.find_session(sid)
            if session is None:
                return self._err(404, "unknown session")
            if session.get("kind") != "claude":
                return self._err(400, "unsupported session")
        if self.headers.get("Transfer-Encoding"):
            return self._err(411, "length required")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self._err(400, "bad length")
        if n <= 0:
            return self._err(400, "empty body")
        if n > MAX_UPLOAD:  # do not read the body; close the connection after responding
            return self._err(413, "too large")
        if account == "admin":
            return self._upload_store(sid, query, account, n)
        # Guest (answered without reading the body): 403 if the bound session is not on duty; 429 if too many files in 10 minutes / total over 7 days exceeded; 507 if the disk is nearly full.
        # Reserve first; release after the upload completes (record persisted), fails or is interrupted
        token, why = self.app.upload_reserve(account, n)
        if why:
            return self._err(*why)
        try:
            return self._upload_store(sid, query, account, n)
        finally:
            self.app.upload_release(token)

    def _upload_store(self, sid: Optional[str], query: str, account: str, n: int) -> None:
        """Read the body to disk, record ownership, and enqueue for those with a sid."""
        q = parse_qs(query, keep_blank_values=True)
        raw_caption = (q.get("caption") or [""])[0]
        caption = outbox.clean_text(raw_caption[:1000]) or ""
        saved = outbox.upload_name((q.get("name") or [""])[0], time.time())
        tmp = os.path.join(self.app.uploads, ".tmp-" + os.urandom(8).hex())
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError:
            return self._err(500, "uploads unavailable")
        left = n
        try:
            with os.fdopen(fd, "wb") as f:
                while left:
                    chunk = self.rfile.read(min(UPLOAD_CHUNK, left))
                    if not chunk:
                        break
                    f.write(chunk)
                    left -= len(chunk)
            if left:
                raise EOFError
            os.chmod(tmp, 0o600)  # host user only (under Docker Desktop fakeowner mounts the container can still read/write)
            os.replace(tmp, os.path.join(self.app.uploads, saved))
        except (OSError, EOFError):
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return self._err(400, "upload failed")
        try:  # record who uploaded it (persistent); if recording fails, treat the upload as failed, so no ownerless file is left
            self.app.uploadlog.add(saved, account, sid, size=n)
        except OSError:
            try:
                os.unlink(os.path.join(self.app.uploads, saved))
            except OSError:
                pass
            return self._err(500, "state unavailable")
        if sid is None:
            return self._json({"file": saved})
        try:
            rid = outbox.enqueue(self.app.outbox, sid, outbox.with_lang({"type": "file", "file": saved, "caption": caption},
                                                                         outbox.clean_lang((q.get("lang") or [""])[0])), account)
        except OSError:
            return self._err(500, "outbox unavailable")
        self._json({"requestId": rid}, 202)

    def _diag(self, guest: Optional[str] = None) -> None:
        """guest = guest account name (accepts only error records, tagged account=<account name>); None = admin."""
        if self.headers.get("Transfer-Encoding"):
            return self._err(411, "length required")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self._err(400, "bad length")
        if n <= 0:
            return self._err(400, "empty body")
        if n > DIAG_MAX_BODY:  # do not read the body; close the connection after responding
            return self._err(413, "too large")
        try:
            data = json.loads(self.rfile.read(n).decode("utf-8"))
        except ValueError:
            return self._err(400, "bad body")
        if not isinstance(data, dict):
            return self._err(400, "bad body")
        sid, events = data.get("session"), data.get("events")
        if not isinstance(sid, str) or len(sid) > 64 or not isinstance(events, list):
            return self._err(400, "bad body")
        if guest:  # keep only whitelisted fields of error records, then rate-limit by source; dropped ones give no error
            ip, ua, t = self._client_ip(), str(self.headers.get("User-Agent") or ""), time.time()
            rows = [r for r in (guest_err_event(ev, ua, guest) for ev in events) if r is not None]
            events = [r for r in rows if self.app.guest_err.allow(ip, r.get("where", "") + "|" + r.get("msg", ""), t)]
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", sid):  # the page session id should only be a short random code; other forms are not written to disk
                sid = guest
        try:
            n_ok = self.app.append_diag(sid, events)
        except OSError:
            return self._err(500, "state unavailable")
        self._json({"ok": True, "written": n_ok})

    def _wake(self, sid: str) -> None:
        entry = self.app.find_offduty(sid)
        name = entry.get("name") if entry else None
        if not isinstance(name, str) or not name:
            return self._err(404, "not-offduty")
        try:
            rid = outbox.enqueue_wake(self.app.outbox, sid, name)
        except OSError:
            return self._err(500, "outbox unavailable")
        self._json({"requestId": rid}, 202)

    def _request_status(self, rid: str, guest: bool = False) -> None:
        if not outbox.RID_RE.match(rid):
            return self._err(400, "bad request id")
        st = outbox.request_status(self.app.outbox, rid, time.time())
        if st is None:
            return self._err(404, "unknown request")
        sid = st.pop("sessionId", None)
        if isinstance(sid, str) and isinstance(st.get("data"), dict):  # context detail: write the cache on the side
            self.app.context_store(sid, st["data"], st.get("at") or time.time())
        if guest:
            st = _guest_ctx(st)
            st.pop("lines", None)  # terminal screen only for admin
        self._json(st)

    def _context(self, sid: str, guest: Optional["guestcfg.Guest"] = None) -> None:
        """Context detail (admin; guests only for the bound session, with details removed): {status: done, data, at} or {status: pending, rid},
        the frontend then polls /api/requests/<rid>."""
        if not _UUID_RE.match(sid):
            return self._err(400, "bad session id")
        s = self.app.find_session(sid)
        if s is None:
            return self._err(404, "unknown session")
        if s.get("kind") != "claude":
            return self._err(409, "not-claude")
        try:
            out = self.app.context_request(sid, time.time())
        except OSError:
            return self._err(500, "outbox unavailable")
        if guest is not None and out.get("rid"):  # the guest will poll this rid later: record that it is theirs
            self.app.remember(self.app.rid_owner, out["rid"], guest.account)
        self._json(_guest_ctx(out) if guest else out)

    def _agent(self, sid: str, aid: str, query: str, guest: Any = False) -> None:
        """Subagent transcript (admin; guests limited to the bound session): paginated items like read_page + an agent info header; sid is validated like /context, agentId accepts only hex."""
        if not _UUID_RE.match(sid):
            return self._err(400, "bad session id")
        if not transcript.AGENT_ID_RE.match(aid):
            return self._err(400, "bad agent id")
        before = None  # type: Optional[int]
        for part in query.split("&"):
            if part.startswith("before="):
                try:
                    before = int(part[7:])
                except ValueError:
                    return self._err(400, "bad before")
                if before < 0:
                    return self._err(400, "bad before")
        s = self.app.find_session(sid)
        if s is None:
            return self._err(404, "unknown session")
        if s.get("kind") != "claude":
            return self._err(409, "not-claude")
        full = self.app.transcript_path(s)
        if full is None:
            return self._err(404, "transcript not found")
        page = transcript.agent_page(full, aid, before, roots=self.app.file_roots)
        if page is None:
            return self._err(404, "agent not found")
        # Subagent page: files live in the subagent's own transcript, and the /api/file recheck scans only the main transcript and previous windows, so only uploads are allowed here (reply-file tok is not signed)
        self._json(self._guest_files(page, guest if isinstance(guest, str) else GUEST) if guest else page)

    def _transcript(self, sid: str, query: str, offduty: bool = False, guest: Optional["guestcfg.Guest"] = None) -> None:
        session = self.app.find_offduty(sid) if offduty else self.app.find_session(sid)
        if session is None:
            return self._err(404, "not-offduty" if offduty else "unknown session")
        before = None  # type: Optional[int]
        around = None  # type: Optional[int]  # jump to a search result: the page containing that line
        src = ""  # previous window: from=<previous window id>, must be on this session's previous-window chain
        for part in query.split("&"):
            if part.startswith("before="):
                try:
                    before = int(part[7:])
                except ValueError:
                    return self._err(400, "bad before")
                if before < 0:
                    return self._err(400, "bad before")
            elif part.startswith("around="):
                try:
                    around = int(part[7:])
                except ValueError:
                    return self._err(400, "bad around")
            elif part.startswith("from="):
                src = unquote(part[5:])
        if src and not _UUID_RE.match(src):
            return self._forbid() if guest else self._err(400, "bad from")
        if not offduty and (session.get("kind") != "claude" or not session.get("transcript")):
            return self._json({"supported": False})
        full = self.app.transcript_path(session)
        if full is None:
            return self._err(404, "transcript not found")
        closed = offduty
        fcwd = session.get("cwd") if guest else None  # guest reply files are limited to the project directory of the session this transcript belongs to
        if src and src != sid:
            # A guest may page back only through the chain segment whose names match the bound session (guest_windows); otherwise 403
            wins = self.app.guest_windows(session, guest) if guest else self.app.windows(session)
            w = next((x for x in wins if x["sid"] == src), None)
            if w is None:
                return self._forbid() if guest else self._err(404, "unknown window")
            full, closed = w["path"], True
            if guest:
                fcwd = _jsonl_cwd(full) or fcwd  # a previous window uses its own cwd; if unavailable, the bound session's
        if around is not None:
            page = history.around(full, around, roots=self.app.file_roots)
            if page is None:
                return self._err(400, "bad around")
            _stamp_refs(page, src if src and src != sid else None)
            return self._json(self._guest_files(page, guest.account, src or sid, fcwd) if guest else page)
        page = transcript.read_page(full, before, closed=closed, roots=self.app.file_roots)
        _stamp_refs(page, src if src and src != sid else None)
        if before is None and not closed:
            # The header "Queued N" = the number of my still-queued messages (admin counts those without any guest prefix; a guest counts only their own)
            qs = transcript.queued_texts(full)
            page["queued"] = (sum(1 for k in qs if guest.own_re.match(k)) if guest
                              else sum(1 for k in qs if not self.app.own_by_any_guest(k)))
        self._json(self._guest_files(page, guest.account, src or sid, fcwd) if guest else page)

    # ---- Bubble attachments: file fetch (/api/file) ----
    # All decisions go through roots.resolve (whitelisted roots, .., symlinks, and the extension after realpath are all checked there);
    # every refusal is 404 (400 for a malformed parameter), without distinguishing "does not exist" from "not allowed".
    def _in_uploads(self, host_path: str) -> Optional[str]:
        """Host path -> real path in the container, which must lie within the uploads directory (guest tok accepts only this)."""
        real = self.app.file_roots.resolve(host_path)
        if not real:
            return None
        up = os.path.realpath(self.app.uploads)
        return real if real.startswith(up.rstrip("/") + "/") else None

    def _upload_key(self, host_path: str) -> str:
        """Upload record key: the file's relative path within the uploads directory (for a normal upload, the saved name); empty string if not within uploads."""
        real = self._in_uploads(host_path)
        if not real:
            return ""
        return os.path.relpath(real, os.path.realpath(self.app.uploads))

    def _guest_files(self, page: Dict[str, Any], account: str = GUEST, tok_sid: Optional[str] = None,
                     cwd: Optional[str] = None) -> Dict[str, Any]:
        """Page shown to a guest: files keep only (1) user uploads (src == upload, path must be in uploads) and (2) when tok_sid is given, files mentioned in the agent's reply text
        (transcript.guest_msg_file). Every item with a path is removed and replaced by a signed tok (upload: legacy 3-segment format; reply file: the m. format carrying the session sid),
        with one key per guest; embedded images (ref) are kept as is. Entries from which something was filtered lose `more` (so the number hidden is not leaked).
        tok_sid = the transcript this page actually came from (the bound session or its previous window); /api/file rereads that transcript to recheck.
        Reply files additionally pass the three files.guest_file_ok checks (cwd = project directory of the session that transcript belongs to; directory, dot-prefixed segments / sensitive file names, extension whitelist); those failing get no card."""
        # Expiry is rounded to the day (valid 24-48 hours): within one day the same file's tok is unchanged, so frontend polling does not see a change and redownload the thumbnail
        page.pop("formatWarn", None)  # transcript-format diagnostics are admin only
        page.pop("formatWarnings", None)
        exp = (int(time.time()) // TOK_TTL + 2) * TOK_TTL
        secret = self.app.file_secret_for(account)  # one key per guest; they cannot use each other's
        sids = None  # type: Optional[list]  # sessions the guest may see (computed only when an upload item is used)
        for it in page.get("items") or []:
            fl = it.get("files") if isinstance(it, dict) else None
            if not fl:
                continue
            keep = []
            for f in fl:
                if not isinstance(f, dict):
                    continue
                if f.get("src") == "upload":
                    f = dict(f)
                    if "path" in f:
                        host = f.pop("path")
                        if not isinstance(host, str) or self._in_uploads(host) is None:
                            continue
                        if sids is None:
                            sids = self.app.guest_sids(self.app.guests.get(account))
                        # A path to the uploads directory appearing in text does not count: an upload record must prove that he (or admin) uploaded it and that it was sent into a session he can see
                        if not self.app.uploadlog.guest_may_see(self._upload_key(host), account, sids):
                            continue
                        f["tok"] = files.sign(host, exp, secret)
                    elif "ref" not in f:
                        continue
                    keep.append(f)
                elif tok_sid and transcript.guest_msg_file(it, f) and \
                        files.guest_file_ok(f["path"], cwd, self.app.file_roots) is None:
                    f = dict(f)
                    host = f.pop("path")
                    f["tok"] = files.sign_msg(tok_sid, host, exp, secret)
                    keep.append(f)
            if len(keep) != len(fl):
                it.pop("more", None)
            if keep:
                it["files"] = keep
            else:
                it.pop("files", None)
        return page

    def _msg_file(self, tok: str, account: str) -> Tuple[Optional[str], str, str, str]:
        """Guest reply-file tok -> (real path in the container or None, result, sid, host path). Checked step by step; any failure returns None:
        signature/type/expiry -> sid is the guest's currently bound session or a previous window it can page back through -> the three files.guest_file_ok checks (under cwd, no dot segment/sensitive name, extension whitelist)
        -> path passes the whitelist (realpath, inside a root, regular file, extension)
        -> the path is actually written in an assistant reply text of that transcript (transcript.assistant_paths, incrementally cached by inode)."""
        got = files.verify_msg(tok, self.app.file_secret_for(account), int(time.time()))
        if not got:
            return None, "deny:sig", "-", "-"
        sid, host = got
        g = self.app.guests.get(account)
        bound = self.app.guest_bound_id(g) if g is not None else None
        session = self.app.find_session(bound) if bound else None
        if session is None:
            return None, "deny:sid", sid, host
        cwd = session.get("cwd")
        if sid == bound:
            full = self.app.transcript_path(session)
        else:
            w = next((x for x in self.app.guest_windows(session, g) if x.get("sid") == sid), None)
            full = w["path"] if w else None
            if full:
                cwd = _jsonl_cwd(full) or cwd  # a previous window uses its own cwd; if unavailable, the bound session's
        if not full:
            return None, "deny:sid", sid, host
        why = files.guest_file_ok(host, cwd, self.app.file_roots)  # the three limits (also rejects toks signed under looser rules)
        if why:
            return None, "deny:" + why, sid, host
        real = self.app.file_roots.resolve(host)
        if not real or not os.path.isfile(real):
            return None, "deny:path", sid, host
        if host not in transcript.assistant_paths(full):
            return None, "deny:not-in-msg", sid, host
        return real, "ok", sid, host

    def _ferr(self, status: int, msg: str) -> None:
        self._send(status, json.dumps({"error": msg}).encode("utf-8"),
                   headers={"X-Content-Type-Options": "nosniff"})

    _dl = False  # whether this /api/file response is an attachment download (?dl=1); one handler instance per request, reset at the start of _file

    _code = 0  # status code of this response (recorded by send_response), used by the guest file-fetch log
    _flog = None  # type: Optional[Dict[str, str]]

    def send_response(self, code: int, message: Optional[str] = None) -> None:
        self._code = code
        if self._flog is not None:  # guest file fetch: log once the status code is decided (before the headers are sent, so the log exists by the time the client receives them)
            self._file_log()
        super().send_response(code, message)

    def _file_log(self) -> None:
        lg, self._flog = self._flog, None
        if lg is None:
            return
        res = str(self._code or "-") + (":" + lg["why"] if lg["why"] else "")
        self.app.log_guest_file(lg["acc"], lg["sid"], lg["name"], res, lg["t"], self._dl)

    def _file(self, query: str, account: str) -> None:
        """Guest file fetch: handled as usual, one access-log line whether it succeeds or fails (_flog is filled by the branches below and written when the status is sent). Admin is not logged."""
        if account == "admin":
            return self._file_do(query, account)
        self._flog = {"acc": account, "sid": "-", "name": "-", "why": "", "t": "-"}
        self._code = 0
        try:
            self._file_do(query, account)
        finally:
            self._file_log()  # no response sent (exception): still log one line

    def _file_do(self, query: str, account: str) -> None:
        """GET /api/file?p=<host path> | sid=<session>&ref=<seq>:<image index>:<line fingerprint> | tok=<signature>, &t=thumb|full (default full)."""
        guest = account != "admin"
        self._dl = False
        if not self.app.file_allow(account):
            return self._ferr(429, "too many requests")
        qs = parse_qs(query, keep_blank_values=True)
        if any(len(v) != 1 for v in qs.values()):
            return self._ferr(400, "bad query")
        get = lambda k: qs[k][0] if k in qs else None  # noqa: E731
        t = get("t") or "full"
        dl = get("dl")
        if dl not in (None, "1"):
            return self._ferr(400, "bad query")
        self._dl = dl == "1" and t == "full"  # download applies to the original file only; thumbnails stay inline. Permission checks below are identical to the case without dl
        p, sid, ref, tok = get("p"), get("sid"), get("ref"), get("tok")
        if self._flog is not None:
            self._flog.update(t=t, sid=sid or "-", name=("ref-" + ref) if ref else "-")
        modes = (p is not None) + (sid is not None or ref is not None) + (tok is not None)
        if t not in ("thumb", "full") or modes != 1:
            return self._ferr(400, "bad query")
        if p is not None:
            if guest:  # guests cannot fetch by path (including empty)
                return self._ferr(404, "not found")
            if not p:
                return self._ferr(400, "bad query")
            real = self.app.file_roots.resolve(p)
            return self._file_path(real, t) if real else self._ferr(404, "not found")
        if tok is not None:
            if files.is_msg_tok(tok):  # files in an agent reply: given to guests only; admin using it always gets 404 (admin uses p=)
                if not guest:
                    return self._ferr(404, "not found")
                real, why, tsid, host = self._msg_file(tok, account)
                if self._flog is not None:
                    self._flog.update(sid=tsid, name=host, why=why)
                return self._file_path(real, t) if real else self._ferr(404, "not found")
            host = files.verify(tok, self.app.file_secret_for(account), int(time.time()))
            real = self._in_uploads(host) if host else None
            if real and guest and not self.app.uploadlog.guest_may_see(
                    self._upload_key(host), account, self.app.guest_sids(self.app.guests.get(account))):
                real = None  # the first guest and admin share the tok key, so even a valid signature requires rechecking the upload record
            if self._flog is not None:
                self._flog.update(name=host or "-", why="upload" if real else "deny:upload")
            return self._file_path(real, t) if real else self._ferr(404, "not found")
        m = _REF_RE.match(ref or "")
        if not sid or not m:
            return self._ferr(400, "bad query")
        return self._file_embedded(sid, int(m.group(1)), int(m.group(2)), m.group(3), t, guest, account)

    def _file_embedded(self, sid: str, seq: int, idx: int, fp: str, t: str, guest: bool, account: str = GUEST) -> None:
        """Images embedded in a transcript: a guest may use only the bound session and its reachable previous windows (guest_windows); admin accepts on-duty and off-duty sessions,
        and any transcript under projects (previous window: ref items in the page carry the sid of the transcript they actually live in)."""
        path = None  # type: Optional[str]
        if guest:
            g = self.app.guests.get(account)
            bound = self.app.guest_bound_id(g)
            session = self.app.find_session(bound) if bound else None
            if session is not None and sid == bound:
                path = self.app.transcript_path(session)
            elif session is not None:
                w = next((x for x in self.app.guest_windows(session, g) if x.get("sid") == sid), None)
                path = w["path"] if w else None
        else:
            session = self.app.find_session(sid) or self.app.find_offduty(sid)
            path = self.app.transcript_path(session) if session else self.app.jsonl_by_sid(sid)
        if path is None:
            return self._ferr(404, "not found")
        try:
            ino = os.stat(path).st_ino
        except OSError:
            return self._ferr(404, "not found")
        thumb = t == "thumb"
        etag = '"e%d-%d-%d-%s%s"' % (ino, seq, idx, fp, "t" if thumb else "")
        if self._etag_hit(etag):
            return self._file_304(etag)
        key = hashlib.sha1(("emb\0%s\0%d:%d:%s" % (path, seq, idx, fp)).encode("utf-8")).hexdigest()
        if thumb:
            hit = self._thumb_cached(key)
            if hit:  # on a cache hit, that line need not be decoded again
                return self._file_stream(hit, "image/webp", "image-%d.webp" % idx, etag)
        got = thumbs.embedded(path, seq, idx, fp)
        if got is None:
            return self._ferr(404, "not found")
        mime, data = got
        if thumb:
            out = thumbs.make("", self.app.thumb_dir, key, data=data)
            if out:
                del data
                return self._file_stream(out, "image/webp", "image-%d.webp" % idx, etag)
        name = "image-%d.%s" % (idx, mime.split("/")[1].replace("jpeg", "jpg"))
        try:
            self._file_head(200, mime, len(data), etag, name)
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _thumb_cached(self, key: str) -> Optional[str]:
        p = os.path.join(self.app.thumb_dir, key + ".webp")
        return p if thumbs._touch(p) else None

    def _file_path(self, real: str, t: str) -> None:
        """Real container path (already through roots.resolve) -> response: size limit, ETag/304, thumbnail, text truncation, Range, streaming."""
        name = os.path.basename(real)
        ext = os.path.splitext(name)[1].lstrip(".").lower()
        try:
            st = os.stat(real)
        except OSError:
            return self._ferr(404, "not found")
        size = st.st_size
        if size > (files.IMG_MAX if files.classify(name, in_link=True) == "image" else files.DOC_MAX):
            return self._ferr(404, "not found")
        etag = '"%d-%d"' % (size, st.st_mtime_ns)
        if self._etag_hit(etag):
            return self._file_304(etag)
        extra = {}  # type: Dict[str, str]
        if ext in ("html", "htm"):  # "open in new tab" treats it as a same-origin top-level page: scripts run in the sandbox but cannot get the board identity
            extra["Content-Security-Policy"] = "sandbox allow-scripts"
        elif ext == "svg":
            extra["Content-Security-Policy"] = "sandbox"
        ident = (st.st_dev, st.st_ino)  # check again after opening, in case the file was swapped between stat and open
        if t == "thumb" and ext in THUMB_EXTS and size <= files.THUMB_SKIP:
            key = hashlib.sha1(("%s\0%d\0%d" % (real, st.st_mtime_ns, size)).encode("utf-8")).hexdigest()
            try:
                with open(real, "rb") as src:
                    fs = os.fstat(src.fileno())
                    if (fs.st_dev, fs.st_ino) != ident:
                        return self._ferr(404, "not found")
                    out = thumbs.make(src, self.app.thumb_dir, key)
            except OSError:
                return self._ferr(404, "not found")
            if out:
                return self._file_stream(out, "image/webp", os.path.splitext(name)[0] + ".webp", etag)
        ctype = files.content_type(name)
        if ext in TEXT_EXTS:
            ctype += "; charset=utf-8"
            if size > TEXT_MAX and not self._dl:  # preview gives only the first 2MB (without cutting a UTF-8 character; ignores Range); a dl=1 download streams the whole file (still bounded by DOC_MAX above)
                extra["X-Truncated"] = "1"
                return self._file_stream(real, ctype, name, etag, 0, _utf8_cut(real, TEXT_MAX), extra=extra,
                                         ident=ident)
        rng = _parse_range(self.headers.get("Range"), size)
        if rng:
            extra["Content-Range"] = "bytes %d-%d/%d" % (rng[0], rng[1], size)
            return self._file_stream(real, ctype, name, etag, rng[0], rng[1] - rng[0] + 1, 206, extra, ident)
        return self._file_stream(real, ctype, name, etag, 0, size, extra=extra, ident=ident)

    def _etag_hit(self, etag: str) -> bool:
        inm = self.headers.get("If-None-Match")
        if not inm:
            return False
        tags = [x.strip() for x in inm.split(",")]
        return "*" in tags or etag in tags or ("W/" + etag) in tags

    def _file_304(self, etag: str) -> None:
        try:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", FILE_CACHE)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            return

    def _file_head(self, status: int, ctype: str, length: int, etag: str, name: str,
                   extra: Optional[Dict[str, str]] = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", FILE_CACHE)
        self.send_header("ETag", etag)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Disposition", files.content_disposition(name, self._dl))
        self.send_header("Connection", "close")
        self.close_connection = True
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()

    def _file_stream(self, path: str, ctype: str, name: str, etag: str, start: int = 0,
                     length: Optional[int] = None, status: int = 200,
                     extra: Optional[Dict[str, str]] = None, ident: Optional[Tuple[int, int]] = None) -> None:
        """Write in 1MB chunks, streaming; a client disconnecting midway ends silently. If ident=(st_dev, st_ino) is given, check that the opened file is the one stat saw."""
        try:
            f = open(path, "rb")
            fs = os.fstat(f.fileno())
        except OSError:
            return self._ferr(404, "not found")
        if ident is not None and (fs.st_dev, fs.st_ino) != ident:
            f.close()
            return self._ferr(404, "not found")
        try:
            with f:
                if length is None:
                    length = fs.st_size - start
                self._file_head(status, ctype, length, etag, name, extra)
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(FILE_CHUNK, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _history(self, sid: str, what: str, query: str, guest: Optional["guestcfg.Guest"] = None) -> None:
        """GET /api/session/<sid>/lineage -> {windows:[{sid, at, via}]};
        /search?q=&limit=50 -> {results:[{ts, role, from, snippet, seq, sid}], windows, ms} (this window + up to 3 previous windows, newest first)."""
        if not _UUID_RE.match(sid):
            return self._err(400, "bad session id")
        s = self.app.find_session(sid)
        if s is None:
            return self._err(404, "unknown session")
        if s.get("kind") != "claude":
            return self._err(409, "not-claude")
        full = self.app.transcript_path(s)
        if full is None:
            return self._err(404, "transcript not found")
        wins = self.app.guest_windows(s, guest) if guest else self.app.windows(s)  # a guest goes back only through windows whose name matches
        pub = [{"sid": w["sid"], "at": w["at"], "via": w["via"]} for w in wins]
        if what == "lineage":
            return self._json({"windows": pub})
        qs = parse_qs(query)
        q = " ".join(str((qs.get("q") or [""])[0]).split())
        if not q or len(q) > history.MAX_Q:
            return self._err(400, "bad q")
        try:
            limit = max(1, min(200, int((qs.get("limit") or ["50"])[0])))
        except ValueError:
            return self._err(400, "bad limit")
        t0 = time.time()
        results = []  # type: list
        for wsid, path in [(sid, full)] + [(w["sid"], w["path"]) for w in wins]:
            # Guest messages are tagged from=guest: a guest searching recognizes only their own prefix, while admin recognizes all guests'
            tags = [guest.tag] if guest else self.app.guest_tags()
            for r in history.search_file(path, q, limit - len(results), tags):
                r["sid"] = wsid
                results.append(r)
            if len(results) >= limit:
                break
        self._json({"results": results, "windows": pub, "ms": int((time.time() - t0) * 1000)})

    def _gsearch(self, query: str) -> None:
        """GET /api/search?q=&limit=60: reads only data/textidx/ built by the helper, grouped by session (previous windows are attributed to the current session)."""
        qs = parse_qs(query)
        q = " ".join(str((qs.get("q") or [""])[0]).split())
        if not q or len(q) > textsearch.MAX_Q:
            return self._err(400, "bad q")
        try:
            limit = max(1, min(200, int((qs.get("limit") or ["60"])[0])))
        except ValueError:
            return self._err(400, "bad limit")
        idx_dir = os.path.join(os.path.dirname(os.path.abspath(self.app.snapshot_path)), "textidx")
        self._json(textsearch.search(idx_dir, q, limit, self.app.load_snapshot()))

    def _profile_get(self, path: str, store: "profile.ProfileStore") -> None:
        if path == PROFILE_PATH:
            return self._json(store.get())
        pic = store.avatar()
        return self._send(200, pic, "image/jpeg") if pic else self._err(404, "no avatar")

    def _profile_post(self, store: Optional["profile.ProfileStore"] = None) -> None:
        """POST /api/profile {name?, avatar?: base64 JPEG | null}: change my nickname / avatar.
        A guest changes their own (store=profile_guest) and cannot touch the admin's."""
        body = self._read_json()
        if body is None:
            return self._err(400, "bad body")
        try:
            return self._json((store or self.app.profile).update(body, time.time()))
        except profile.BadInput as e:
            return self._err(400, str(e))
        except OSError:
            return self._err(500, "state unavailable")

    def _mute(self, sid: str) -> None:
        """POST /api/sessions/<id>/mute {on: bool}: do-not-disturb switch (no waiting/finished pushes; the red dot stays)."""
        if self.app.find_session(sid) is None:
            return self._err(404, "unknown session")
        body = self._read_json()
        if body is None or not isinstance(body.get("on"), bool):
            return self._err(400, "bad body")
        try:
            self.app.mute.set(sid, body["on"])
        except OSError:
            return self._err(500, "state unavailable")
        self._json({"ok": True, "muted": body["on"]})

    def _top(self, sid: str) -> None:
        """POST /api/sessions/<id>/top {on: bool}: pin to top (persistent, stored in top.json; separate from the board pin)."""
        if self.app.find_session(sid) is None:
            return self._err(404, "unknown session")
        body = self._read_json()
        if body is None or not isinstance(body.get("on"), bool):
            return self._err(400, "bad body")
        try:
            self.app.top.set(sid, body["on"])
        except OSError:
            return self._err(500, "state unavailable")
        self._json({"ok": True, "topped": body["on"]})


def make_server(host: str, port: int, key: str, snapshot: str, projects: str,
                state: str, outbox_dir: str = "/outbox", uploads_dir: str = "/uploads",
                file_roots: Optional["files.Roots"] = None,
                admin_only: Tuple[str, ...] = (), guests: Optional[list] = None,
                guest_slash: Tuple[str, ...] = ()) -> ThreadingHTTPServer:
    """Open the guests per the `guests` list (guestcfg.load_guests); none = guest mode off."""
    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.daemon_threads = True
    httpd.app = App(key, snapshot, projects, state, outbox_dir, uploads_dir,  # type: ignore
                    file_roots, admin_only, guests, guest_slash)
    return httpd


def main() -> None:
    key = os.environ.get("WEBAPP_KEY", "")
    if not key:
        sys.exit("WEBAPP_KEY is not set")
    if len(key) < 24:
        sys.exit("WEBAPP_KEY is too short (at least 24 characters)")
    guests = guestcfg.load_guests(key, name_of=profile.guest_name_of)  # GUEST_* + GUEST2_* ... (invalid ones are explained on stderr)
    if not outbox.secret():  # do not exit: the snapshot and chat history stay viewable, only sending fails (send returns 500 outbox unavailable)
        outbox.warn_secret()
    sys.stderr.write("guests %s\n" % ",".join("%s->%s" % (g.account, g.tag) for g in guests))  # never print keys or session names
    httpd = make_server("0.0.0.0", 8080, key,
                        os.environ.get("SNAPSHOT", "/data/snapshot.json"),
                        os.environ.get("PROJECTS", "/projects"),
                        os.environ.get("STATE", "/state/state.json"),
                        os.environ.get("OUTBOX", "/outbox"),
                        os.environ.get("UPLOADS", "/uploads"),
                        admin_only=guestcfg.admin_only_prefixes(), guests=guests,
                        guest_slash=guestcfg.slash_commands())
    threading.Thread(target=httpd.app.notify_loop, args=(threading.Event(),),  # type: ignore
                     name="notify", daemon=True).start()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
