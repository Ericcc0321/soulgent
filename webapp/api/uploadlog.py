"""Upload records: who uploaded each saved file and which sessions it was sent to. Persisted in the state volume
(/state/uploads.json) so ownership survives api restarts. Guests may only get links to uploads whose record says
they (or the admin) own them and that were sent to a session the guest is allowed to see; chat text is never proof."""
import json
import os
import threading
import time
import uuid
from typing import Any, Dict, Iterable, List, Optional

TTL = 8 * 86400   # the helper deletes uploads after 7 days; records are kept one day longer
CAP = 5000        # max records kept; the oldest are dropped when full


class UploadLog:
    def __init__(self, path: str) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._data = None  # type: Optional[Dict[str, Dict[str, Any]]]
        self._stamp = None  # type: Optional[Any]

    def _file_stamp(self) -> Optional[Any]:
        try:
            st = os.stat(self.path)
            return (st.st_mtime_ns, st.st_size)
        except OSError:
            return None

    def _load(self) -> Dict[str, Dict[str, Any]]:
        # if another process changed the file (size or mtime), re-read it so this process's stale cache doesn't overwrite it on the next write
        if self._data is not None and self._file_stamp() != self._stamp:
            self._data = None
        if self._data is None:
            self._stamp = self._file_stamp()
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    raw = json.load(f)
            except (OSError, ValueError):
                raw = {}
            self._data = {k: v for k, v in raw.items()
                          if isinstance(k, str) and isinstance(v, dict) and isinstance(v.get("account"), str)} \
                if isinstance(raw, dict) else {}
        return self._data

    def _save(self, now: float) -> None:
        data = self._load()
        for k in [k for k, v in data.items() if now - float(v.get("at") or 0) > TTL]:
            del data[k]
        while len(data) > CAP:
            oldest = min(data, key=lambda k: float(data[k].get("at") or 0))
            del data[oldest]
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        tmp = self.path + ".tmp-" + uuid.uuid4().hex
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, self.path)
            self._stamp = self._file_stamp()
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def add(self, name: str, account: str, sid: Optional[str] = None, now: Optional[float] = None,
            size: int = 0) -> None:
        """Record an upload when saved: saved name -> uploading account, byte count (uploads with a sid also record the session). Raises OSError if it cannot be written."""
        t = time.time() if now is None else now
        with self._lock:
            data = self._load()
            data[name] = {"account": account, "sids": [sid] if sid else [], "at": t, "size": int(size)}
            self._save(t)

    def by_account(self, account: str, now: Optional[float] = None) -> List[Dict[str, Any]]:
        """This account's upload records still within retention (used for the guest upload quota)."""
        t = time.time() if now is None else now
        with self._lock:
            return [dict(r) for r in self._load().values()
                    if r.get("account") == account and t - float(r.get("at") or 0) <= TTL]

    def sent(self, names: Iterable[str], sid: str, now: Optional[float] = None) -> None:
        """An attachment was sent into a session: record the session (only fills in existing records; records are never created here, to prevent claiming later)."""
        t = time.time() if now is None else now
        with self._lock:
            data = self._load()
            changed = False
            for n in names:
                r = data.get(n)
                if r is None:
                    continue
                sids = r.setdefault("sids", [])
                if sid not in sids:
                    sids.append(sid)
                    changed = True
            if changed:
                self._save(t)

    def get(self, name: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            r = self._load().get(name)
            return dict(r, sids=list(r.get("sids") or [])) if r else None

    def owner(self, name: str) -> Optional[str]:
        r = self.get(name)
        return r["account"] if r else None

    def guest_may_see(self, name: str, account: str, sids: List[str]) -> bool:
        """Whether a guest may fetch this upload: a record exists, the uploader is the guest or an admin, and it was sent into a session the guest can see (the bound session or one of its previous windows)."""
        r = self.get(name)
        if r is None or r["account"] not in (account, "admin"):
            return False
        return any(s in sids for s in r["sids"])
