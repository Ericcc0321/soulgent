"""Read and pin state: one JSON file with atomic writes, plus the unread / rest-area rules."""
import json
import os
import tempfile
import threading
import time
from typing import Any, Dict, Iterable, Optional, Set

REST_AFTER = 6 * 3600
PIN_HOLD = 15  # for this many seconds after the phone changes a pin, the phone wins


class State:
    def __init__(self, path: str) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._seen = {}  # type: Dict[str, float]
        self._pins = set()  # type: Set[str]
        self._pinned_at = {}  # type: Dict[str, float]
        self._pin_changed = {}  # type: Dict[str, float]
        self._rest = {}  # type: Dict[str, float]  manual rest: session id -> rest time
        self._unseen = {}  # type: Dict[str, float]  manually marked unread: session id -> mark time
        self.installed_at = time.time()
        if not self._load():
            self._save()

    def _load(self) -> bool:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            installed = float(data["installed_at"])
        except (OSError, ValueError, KeyError, TypeError):
            return False
        self.installed_at = installed
        seen = data.get("seen")
        if isinstance(seen, dict):
            for k, v in seen.items():
                try:
                    self._seen[str(k)] = float(v)
                except (TypeError, ValueError):
                    pass
        pins = data.get("pins")
        if isinstance(pins, list):
            self._pins = set(str(p) for p in pins)
        changed = data.get("pin_changed")
        if isinstance(changed, dict):
            for k, v in changed.items():
                try:
                    self._pin_changed[str(k)] = float(v)
                except (TypeError, ValueError):
                    pass
        for key, into in (("rest", self._rest), ("unseen", self._unseen)):
            d = data.get(key)
            if isinstance(d, dict):
                for k, v in d.items():
                    try:
                        into[str(k)] = float(v)
                    except (TypeError, ValueError):
                        pass
        stamps = data.get("pinned_at")
        for p in self._pins:
            try:
                self._pinned_at[p] = float(stamps[p])
            except (TypeError, ValueError, KeyError, IndexError):
                self._pinned_at[p] = time.time()  # legacy data has no timestamp: count from now
        return True

    def _save(self) -> None:
        d = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".state-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"installed_at": self.installed_at, "seen": self._seen,
                           "pins": sorted(self._pins), "pinned_at": self._pinned_at,
                           "pin_changed": self._pin_changed, "rest": self._rest, "unseen": self._unseen}, f, ensure_ascii=False)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def seen_at(self, sid: str) -> float:
        with self._lock:
            return self._seen.get(sid, 0.0)

    def mark_seen(self, sid: str, t: float) -> None:
        with self._lock:
            self._seen[sid] = t
            self._unseen.pop(sid, None)
            self._save()

    def mark_all_seen(self, ids: Iterable[str], t: float) -> None:
        with self._lock:
            for sid in ids:
                self._seen[sid] = t
                self._unseen.pop(sid, None)
            self._save()

    def mark_unseen(self, sid: str, seen_t: float, t: Optional[float] = None) -> None:
        """Mark as unread: write the own seen time back and record the mark time.
        The Mac panel merges the written-back seenAt with "max wins", so the red dot relies on this mark until the session is viewed again on the phone or Mac."""
        with self._lock:
            self._seen[sid] = seen_t
            self._unseen[sid] = time.time() if t is None else t
            self._save()

    def unseen_at(self, sid: str) -> float:
        with self._lock:
            return self._unseen.get(sid, 0.0)

    def clear_unseen(self, sid: str) -> None:
        with self._lock:
            if self._unseen.pop(sid, None) is not None:
                self._save()

    def pinned(self, sid: str) -> bool:
        with self._lock:
            return sid in self._pins

    def pinned_at(self, sid: str) -> float:
        with self._lock:
            return self._pinned_at.get(sid, 0.0)

    def pin_changed_at(self, sid: str) -> float:
        with self._lock:
            return self._pin_changed.get(sid, 0.0)

    def set_pin(self, sid: str, value: bool, t: Optional[float] = None, by_phone: bool = False) -> None:
        """by_phone: changed actively on the phone (pin and unpin both record the time, whether or not the value changed); auto-unpin and panel sync do not record."""
        with self._lock:
            if by_phone:
                self._pin_changed[sid] = time.time()
            if value == (sid in self._pins):
                if by_phone:
                    self._save()
                return
            if value:
                self._pins.add(sid)
                self._pinned_at[sid] = time.time() if t is None else t
            else:
                self._pins.discard(sid)
                self._pinned_at.pop(sid, None)
            self._save()


    def rest_at(self, sid: str) -> float:
        with self._lock:
            return self._rest.get(sid, 0.0)

    def set_rest(self, sid: str, on: bool, t: Optional[float] = None) -> None:
        """Manual rest (swipe left "Rest" / "Back")."""
        with self._lock:
            if on:
                self._rest[sid] = time.time() if t is None else t
            elif sid in self._rest:
                del self._rest[sid]
            else:
                return
            self._save()


def manual_rest(state: State, sid: str, status: Any, since: float) -> bool:
    """Whether a manual rest is still in effect; new activity in the session (waiting for you, or last activity after the rest time) cancels it and deletes the record."""
    t = state.rest_at(sid)
    if not t:
        return False
    if status == "waiting" or since > t:
        state.set_rest(sid, False)
        return False
    return True


def _num(v: Any) -> float:
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    try:
        return float(v) if isinstance(v, str) else 0.0
    except ValueError:
        return 0.0


def bg_live(session: dict) -> bool:
    """Background running and not stuck: counts as working (no red dot, no "finished" push, no auto-rest). bgStale ones follow the ordinary idle path."""
    n = session.get("bgTasks")
    return isinstance(n, int) and not isinstance(n, bool) and n > 0 and session.get("bgStale") is not True


def finished_at(session: dict) -> float:
    """Completion time finishedAt = max(since, bgEndedAt) (shared rule on both ends). Killing the last background task via /tasks starts no new turn, so bgEndedAt refreshes it."""
    return max(_num(session.get("since")), _num(session.get("bgEndedAt")))


ERROR_KINDS = ("api", "rate_limit", "auth", "wb_error", "wb_stopped")


def error_kind(session: dict) -> Optional[str]:
    """errorKind (only whitelisted values count; others are treated as absent)."""
    k = session.get("errorKind")
    return k if isinstance(k, str) and k in ERROR_KINDS else None


def is_gone(session: dict) -> bool:
    """disconnected: the session process exited unexpectedly (grey card kept for 10 minutes). Not unread, not rest, no "finished" push."""
    return session.get("disconnected") is True


def error_finished(session: dict, finished: float) -> float:
    """With an errorKind, the unread / push time point is max(finishedAt, errorSince) (an error after the user has looked must light the dot again)."""
    return max(finished, _num(session.get("errorSince"))) if error_kind(session) else finished


def origin_counts(session: dict) -> bool:
    """Whether the turn origin counts for automatic red dot / push: started by user; or by agent but bgOwned (the user put work in the background this round, i.e. the background wrap-up turn). peer never counts."""
    origin = session.get("origin")
    return origin not in ("peer", "agent") or (origin == "agent" and session.get("bgOwned") is True)


def flags_for(state: State, session: dict, now: float, panel: Optional[dict] = None, topped: bool = False) -> dict:
    """Return unread / pinned / rest. Busy sessions also get their pin removed automatically.

    panel: {"seenAt", "pinned"} from the snapshot (the Mac panel's record). Seen time takes the larger of the two;
    for pins, the phone wins within PIN_HOLD seconds of a phone change, otherwise follow the panel if there is one."""
    sid = str(session.get("id"))
    status = session.get("status")
    try:
        since = float(session.get("since") or 0)
    except (TypeError, ValueError):
        since = 0.0
    finished = error_finished(session, max(since, finished_at(session)))  # an errored turn follows errorSince
    live = bg_live(session)
    gone = is_gone(session)
    err = error_kind(session) is not None
    own_seen = seen_at = state.seen_at(sid)
    panel_seen = 0.0
    if isinstance(panel, dict):
        pseen = panel.get("seenAt")
        try:
            panel_seen = float(pseen[sid])
            seen_at = max(seen_at, panel_seen)
        except (TypeError, ValueError, KeyError, IndexError):
            pass
        ppins = panel.get("pinned")
        if isinstance(ppins, list) and now - state.pin_changed_at(sid) >= PIN_HOLD:
            want = sid in ppins
            if want != state.pinned(sid):
                state.set_pin(sid, want, t=now)  # sync into the api's own record; not counted as a phone change
    # Manual unread expires once the session is viewed later on the Mac (panel seenAt newer than the mark) or on the phone (mark_seen clears it)
    manual_unread = False
    mark_t = state.unseen_at(sid)
    if mark_t:
        if panel_seen > mark_t or own_seen >= finished:
            state.clear_unseen(sid)
        else:
            manual_unread = True
    # Remove the pin if the session worked after being pinned: it is busy now, or the phone missed a short busy turn between polls (since is later than the pin time and not waiting for a reply)
    if state.pinned(sid) and (status == "busy" or (status != "waiting" and since > state.pinned_at(sid))):
        state.set_pin(sid, False)
    pinned = state.pinned(sid)
    idle = status == "idle"
    origin = session.get("origin")
    # Automatic red dot ignores inter-session / subagent turns (an agent turn with bgOwned = background wrap-up does count); manual unread ignores origin (otherwise peer/agent sessions could never show a dot)
    # Completion time is finishedAt = max(since, bgEndedAt); while a background task runs (bg_live; stuck ones do not count) even manual unread is suppressed, and the dot appears once it finishes
    # errorKind raises the red dot (takes priority over turn origin and running background); disconnected is never unread (not even when marked manually)
    fresh = finished > max(seen_at, state.installed_at)
    natural = (err or origin_counts(session)) and fresh
    unread = idle and not gone and (err and fresh or not live and (natural or manual_unread))
    # A top-pinned session is exempt from auto-rest; running background does not enter rest (stuck ones do, so a loop cannot keep a session in "working" forever); the 6 hours count from finishedAt
    # Unexpectedly exited grey cards do not enter rest (nor manual rest; they stay in the active list for 10 minutes)
    rest = not gone and (manual_rest(state, sid, status, finished) or (
        idle and not unread and not pinned and not topped and not live and now - finished > REST_AFTER))
    # The interaction note carries structure only (the frontend composes the text per language, e.g. "<-> with X", "handled subagent report"); originNote is a legacy field, always an empty string
    # (old frontends draw no note on an empty string, so an object is never shown as text)
    tag = None  # type: Optional[Dict[str, Any]]
    if idle and origin == "peer":
        peer = session.get("peer")
        tag = {"kind": "peer", "peer": peer if isinstance(peer, str) else ""}
    elif idle and origin == "agent" and session.get("bgOwned") is not True:  # bgOwned is just an ordinary completion: no note
        tag = {"kind": "agent"}
    # finishedAt: push turn key (notify._trigger) and the frontend time slot
    out = {"unread": unread, "pinned": pinned, "rest": rest, "originNote": "", "originTag": tag, "finishedAt": finished}
    if unread and manual_unread and not natural:
        out["manualUnread"] = True  # manually marked red dot: only a reminder to oneself, no "finished" push
    return out


class MuteStore:
    """Do not disturb: a set of session ids, stored separately in mute.json (atomic write). Muted sessions get no "waiting for you / finished" push; the red dot stays.
    Keyed by session id; follow() moves it to the new id after a window switch."""

    KEY = "muted"     # field name in the file
    PREFIX = ".mute-"  # temp-file prefix for atomic writes

    def __init__(self, path: str) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._ids = set()  # type: Set[str]
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data.get(self.KEY), list):
                self._ids = set(str(x) for x in data[self.KEY])
        except (OSError, ValueError, AttributeError):
            pass

    def has(self, sid: str) -> bool:
        with self._lock:
            return sid in self._ids

    def set(self, sid: str, on: bool) -> None:
        with self._lock:
            if on == (sid in self._ids):
                return
            if on:
                self._ids.add(sid)
            else:
                self._ids.discard(sid)
            self._save()

    def follow(self, prev_of: Dict[str, str]) -> bool:
        """Carry the set across window switches (do-not-disturb and pins alike): prev_of maps new session id -> previous window id (lineage).
        A listed previous id is replaced by its successor (repeatedly, so a chain of switches lands on the newest id);
        True if the set changed and was written."""
        nxt = {}  # type: Dict[str, str]
        for new, prev in prev_of.items():
            if new and prev and new != prev:
                nxt[prev] = new
        with self._lock:
            changed = False
            for sid in list(self._ids):
                cur, hops = sid, 0
                while cur in nxt and hops < 50:  # guard against a cyclic lineage file
                    cur, hops = nxt[cur], hops + 1
                if cur != sid:
                    self._ids.discard(sid)
                    self._ids.add(cur)
                    changed = True
            if changed:
                self._save()
            return changed

    def _save(self) -> None:
        """Atomic write of the current set; the caller holds the lock."""
        d = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=self.PREFIX)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({self.KEY: sorted(self._ids)}, f)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


class TopStore(MuteStore):
    """Pin to top (persistent, separate from the panel's reply-later pin): a set of session ids, stored in top.json. Differs from the panel pin (pinned):
    not synced to the panel and not removed when the session works; keyed by session id, and follow() moves it to the new id after a window switch (same as do-not-disturb)."""

    KEY = "topped"
    PREFIX = ".top-"
