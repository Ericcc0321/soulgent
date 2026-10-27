"""Which devices are in use right now. Memory only: after an api restart every device counts as not in use, so pushes still go out (better to over-push than miss one).
Sources: the foreground snapshot poll request headers X-Zbs-Dev (device id) / X-Zbs-Act (1 = in use; the frontend computes it from visible + focus or activity within 60 s) / X-Zbs-Seen (reports that a banner was shown / being viewed,
s-<session id>:<event>, session id via encodeURIComponent); on leaving, sendBeacon /api/presence {dev, act, seen}. Accounts are tracked separately."""
import re
import threading
from collections import deque
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import unquote

ACTIVE_TTL = 8      # seconds: a device that hasn't polled a snapshot for this long counts as gone (the foreground polls every 2 s, so about 4 misses; a fallback for when iOS freezes JS in the background)
SEEN_KEEP = 300     # seconds: reports are kept this long (notify.step only honors reports after the current round; expired ones are purged so the map doesn't grow)
MAX_SEEN = 20       # max reports accepted per request
MAX_DEVS = 64       # max devices tracked in memory (by account + device id); the least recently seen is dropped when full
RATE_MAX = 30       # /api/presence allows this many calls per account per RATE_WINDOW seconds (leaving the page fires up to three: hidden + pagehide + blur)
RATE_WINDOW = 60
DEV_RE = re.compile(r"^[A-Za-z0-9_-]{8,40}$")  # same as push._DEV_RE
_SEEN_RE = re.compile(r"^s-([^\s:,]{1,300}):(wait|done|err|stopped|limit)$")


def clean_dev(v: Any) -> Optional[str]:
    return v if isinstance(v, str) and DEV_RE.match(v) else None


def parse_seen(raw: Any) -> List[str]:
    """Report list: a comma-separated string in the request header, an array in the beacon body. Only s-<id>:<event> is accepted; after percent-decoding the id must contain no control characters, colons, commas or whitespace."""
    if isinstance(raw, str):
        items = raw.split(",")
    elif isinstance(raw, list):
        items = [x for x in raw if isinstance(x, str)]
    else:
        return []
    out = []  # type: List[str]
    for it in items:
        m = _SEEN_RE.match(it.strip())
        if not m:
            continue
        sid = unquote(m.group(1))
        if not sid or len(sid) > 200 or any(ord(c) < 32 or ord(c) == 127 or c in ":," or c.isspace() for c in sid):
            continue
        key = "s-%s:%s" % (sid, m.group(2))
        if key not in out:
            out.append(key)
        if len(out) >= MAX_SEEN:
            break
    return out


class Presence:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._dev = {}  # type: Dict[Tuple[str, str], Dict[str, Any]]  # (account, device id) -> {seen: last request, act, last: last time act=1}
        self._seen = {}  # type: Dict[str, Dict[str, float]]  # account -> {s-<id>:<event>: report time}
        self._rate = {}  # type: Dict[str, deque]

    def touch(self, account: str, dev: str, act: bool, now: float) -> None:
        with self._lock:
            d = self._dev.get((account, dev))
            if d is None:
                if len(self._dev) >= MAX_DEVS:
                    oldest = min(self._dev, key=lambda k: self._dev[k]["seen"])
                    del self._dev[oldest]
                d = self._dev[(account, dev)] = {"seen": now, "act": False, "last": None}
            d["seen"] = now
            d["act"] = bool(act)
            if act:
                d["last"] = now

    def leave(self, account: str, dev: str, now: float) -> None:
        self.touch(account, dev, False, now)

    def active(self, account: str, now: float) -> bool:
        with self._lock:
            return any(acc == account and d["act"] and now - d["seen"] <= ACTIVE_TTL
                       for (acc, _dev), d in self._dev.items())

    def active_dev(self, account: str, dev: str, now: float) -> bool:
        with self._lock:
            d = self._dev.get((account, dev))
            return bool(d and d["act"] and now - d["seen"] <= ACTIVE_TTL)

    def last(self, account: str, dev: str) -> Optional[float]:
        """When this device was last "in use" (in memory only; None after a restart)."""
        with self._lock:
            d = self._dev.get((account, dev))
            return d["last"] if d else None

    def report(self, account: str, keys: List[str], now: float) -> None:
        if not keys:
            return
        with self._lock:
            m = self._seen.setdefault(account, {})
            for k in keys:
                m[k] = now

    def seen(self, account: str, now: float) -> Dict[str, float]:
        with self._lock:
            m = self._seen.get(account) or {}
            for k in [k for k, t in m.items() if now - t > SEEN_KEEP]:
                del m[k]
            return dict(m)

    def allow(self, account: str, now: float) -> bool:
        with self._lock:
            q = self._rate.setdefault(account, deque())
            while q and now - q[0] > RATE_WINDOW:
                q.popleft()
            if len(q) >= RATE_MAX:
                return False
            q.append(now)
            return True
