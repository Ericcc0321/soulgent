"""Per-device login tokens (cookie `zbs`), persisted in the state volume as devices.json.

Each login issues 32 random bytes (hex) as the cookie value. Only sha256(token) is stored, never the token itself, together with
the account, issue time, last use, a short device description derived from the User-Agent (fixed vocabulary, no raw UA) and a
fingerprint of that account's key at issue time. A token is valid only while the account's current key fingerprint matches
(changing a key, or removing a guest, signs out all of that account's devices) and while it was used within IDLE_MAX seconds.
lastSeen is updated in memory on every request and written to disk at most every FLUSH_GAP seconds."""
import hashlib
import json
import os
import re
import secrets
import threading
import time
import uuid
from typing import Any, Callable, Dict, List, Optional

IDLE_MAX = 90 * 86400      # unused this long -> invalid and pruned
RENEW_AFTER = 7 * 86400    # re-send Set-Cookie (same token, fresh Max-Age) when the last one is older than this
FLUSH_GAP = 300            # persist lastSeen-only changes at most this often (seconds)
PER_ACCOUNT_MAX = 50       # cap per account; issuing beyond it drops that account's least recently used token
DESC_MAX = 60
_TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
_ID_RE = re.compile(r"^[0-9a-f]{12}$")


def token_hash(raw: str) -> str:
    return hashlib.sha256(("zbs-dev\0" + raw).encode("utf-8")).hexdigest()


def key_fp(key: str) -> str:
    """Short fingerprint of an account key (not reversible; only compared for equality)."""
    return hashlib.sha256(("zbs-kfp\0" + key).encode("utf-8")).hexdigest()[:16]


def looks_like_token(value: Any) -> bool:
    return isinstance(value, str) and bool(_TOKEN_RE.match(value))


def describe(ua: Optional[str]) -> str:
    """Short device description from a User-Agent, built only from a fixed vocabulary (e.g. "iPhone Safari", "Mac Chrome")."""
    s = ua or ""
    if "iPhone" in s or "iPod" in s:
        dev = "iPhone"
    elif "iPad" in s:
        dev = "iPad"
    elif "Android" in s:
        dev = "Android"
    elif "Macintosh" in s or "Mac OS X" in s:
        dev = "Mac"
    elif "Windows" in s:
        dev = "Windows"
    elif "CrOS" in s:
        dev = "ChromeOS"
    elif "Linux" in s:
        dev = "Linux"
    else:
        dev = ""
    if "Edg/" in s or "EdgiOS" in s or "EdgA/" in s:
        app = "Edge"
    elif "Firefox/" in s or "FxiOS" in s:
        app = "Firefox"
    elif "Chrome/" in s or "CriOS" in s:
        app = "Chrome"
    elif "Safari/" in s:
        app = "Safari"
    elif dev in ("iPhone", "iPad") and "AppleWebKit" in s:
        app = "App"  # Home Screen web app: WebKit without the Safari token
    else:
        app = ""
    if not dev:
        return "Unknown device" if not app else app
    return (dev + " " + app).strip()[:DESC_MAX]


class DeviceStore:
    def __init__(self, path: str, now: Callable[[], float] = time.time) -> None:
        self.path = path
        self.now = now
        self._lock = threading.Lock()
        self._by_hash = {}  # type: Dict[str, Dict[str, Any]]
        self._flushed_at = 0.0
        self._dirty = False
        self._load()

    # ---- persistence ----
    def _load(self) -> None:
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = {}
        rows = data.get("tokens") if isinstance(data, dict) else None
        for r in rows if isinstance(rows, list) else []:
            if not isinstance(r, dict) or not isinstance(r.get("hash"), str) or not isinstance(r.get("account"), str):
                continue
            try:
                e = {"hash": r["hash"], "id": str(r.get("id") or "")[:12], "account": r["account"],
                     "issuedAt": float(r.get("issuedAt") or 0), "lastSeen": float(r.get("lastSeen") or 0),
                     "cookieAt": float(r.get("cookieAt") or r.get("issuedAt") or 0),
                     "desc": str(r.get("desc") or "")[:DESC_MAX], "kfp": str(r.get("kfp") or "")}
            except (TypeError, ValueError):
                continue
            if _ID_RE.match(e["id"]):
                self._by_hash[e["hash"]] = e
        self._flushed_at = self.now()

    def _write(self) -> None:
        """Atomic write, file mode 600 (caller holds the lock)."""
        d = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, ".devices-" + uuid.uuid4().hex)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"v": 1, "tokens": list(self._by_hash.values())}, f, ensure_ascii=False)
            os.chmod(tmp, 0o600)  # independent of umask
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        self._flushed_at = self.now()
        self._dirty = False

    def _save(self) -> None:
        try:
            self._write()
        except OSError:
            self._dirty = True  # memory stays authoritative; the next change retries

    def flush(self) -> None:
        with self._lock:
            if self._dirty:
                self._save()

    def _prune(self, t: float) -> bool:
        dead = [h for h, e in self._by_hash.items() if t - e["lastSeen"] > IDLE_MAX]
        for h in dead:
            del self._by_hash[h]
        return bool(dead)

    # ---- operations ----
    def issue(self, account: str, desc: str, kfp: str) -> str:
        """New token for this account; returns the raw token (only ever sent to the browser, never stored)."""
        raw = secrets.token_hex(32)
        t = self.now()
        with self._lock:
            self._prune(t)
            mine = sorted((e for e in self._by_hash.values() if e["account"] == account), key=lambda e: e["lastSeen"])
            for e in mine[:max(0, len(mine) - PER_ACCOUNT_MAX + 1)]:
                del self._by_hash[e["hash"]]
            ids = {e["id"] for e in self._by_hash.values()}
            tid = secrets.token_hex(6)
            while tid in ids:
                tid = secrets.token_hex(6)
            h = token_hash(raw)
            self._by_hash[h] = {"hash": h, "id": tid, "account": account, "issuedAt": t, "lastSeen": t, "cookieAt": t,
                                "desc": (desc or "")[:DESC_MAX], "kfp": kfp}
            self._save()
        return raw

    def lookup(self, raw: str, kfp_of: Callable[[str], Optional[str]]) -> Optional[Dict[str, Any]]:
        """Entry (a copy) for a valid token, else None. Invalid ones (key changed / account gone / idle too long) are removed.
        Touches lastSeen in memory; persists at most every FLUSH_GAP seconds."""
        if not looks_like_token(raw):
            return None
        h = token_hash(raw)
        t = self.now()
        with self._lock:
            e = self._by_hash.get(h)
            if e is None:
                return None
            cur = kfp_of(e["account"])
            if cur is None or cur != e["kfp"] or t - e["lastSeen"] > IDLE_MAX:
                del self._by_hash[h]
                self._save()
                return None
            e["lastSeen"] = t
            self._dirty = True
            if t - self._flushed_at >= FLUSH_GAP:
                self._prune(t)
                self._save()
            return dict(e)

    def has(self, raw: str) -> bool:
        with self._lock:
            return token_hash(raw) in self._by_hash

    def needs_renew(self, entry: Dict[str, Any]) -> bool:
        return self.now() - float(entry.get("cookieAt") or 0) >= RENEW_AFTER

    def mark_renewed(self, h: str) -> None:
        with self._lock:
            e = self._by_hash.get(h)
            if e is not None:
                e["cookieAt"] = self.now()
                self._dirty = True  # not urgent: losing it only means one more renewal

    def remove_token(self, raw: str) -> bool:
        if not looks_like_token(raw):
            return False
        with self._lock:
            if self._by_hash.pop(token_hash(raw), None) is None:
                return False
            self._save()
            return True

    def revoke(self, account: str, tid: str) -> Optional[str]:
        """Delete this account's token with short id tid; returns its hash (None if not this account's)."""
        if not isinstance(tid, str) or not _ID_RE.match(tid):
            return None
        with self._lock:
            for h, e in self._by_hash.items():
                if e["id"] == tid and e["account"] == account:
                    del self._by_hash[h]
                    self._save()
                    return h
        return None

    def list(self, account: str, kfp: Optional[str]) -> List[Dict[str, Any]]:
        """This account's valid tokens (no hashes): id, desc, issuedAt, lastSeen; newest use first."""
        t = self.now()
        with self._lock:
            rows = [{"id": e["id"], "desc": e["desc"], "issuedAt": int(e["issuedAt"]), "lastSeen": int(e["lastSeen"]), "_h": e["hash"]}
                    for e in self._by_hash.values()
                    if e["account"] == account and kfp is not None and e["kfp"] == kfp and t - e["lastSeen"] <= IDLE_MAX]
        rows.sort(key=lambda r: -r["lastSeen"])
        return rows
