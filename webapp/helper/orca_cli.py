"""Orca CLI adapter: locating the orca binary and running `orca ... --json` (the only place the helper builds orca commands)."""

import json
import os
import subprocess
import threading
import time
from typing import Dict, List, Optional

from helper import settings

ORCA_TIMEOUT = 10
ORCA_PATHS = ["/usr/local/bin/orca", "/Applications/Orca.app/Contents/Resources/bin/orca"]
ORCA_BIN = settings.orca_bin()  # SOULGENT_ORCA_BIN if set, only it is used


def find_orca(orca_bin=ORCA_BIN, orca_paths=ORCA_PATHS) -> List[str]:
    if orca_bin:
        return [orca_bin]
    for p in orca_paths:
        if os.path.exists(p):
            return [p]
    return [orca_paths[0]]


def _orca_json(orca_cmd: List[str], args: List[str]) -> Optional[dict]:
    try:
        proc = subprocess.run(orca_cmd + args + ["--json"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=ORCA_TIMEOUT)
        if proc.returncode != 0:
            return None
        data = json.loads(proc.stdout.decode("utf-8"))
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return data if isinstance(data, dict) and data.get("ok") is True else None


# ---------- Structural format warnings (per session, shown as formatWarn in snapshot.json) ----------
# Recorded only when orca answered ok but the JSON lacks a key the helper relies on; an unfamiliar version alone never warns.
FORMAT_WARN_TTL = 600
_warns = {}  # type: Dict[str, tuple]
_warns_lock = threading.Lock()


def note_format_warn(sid, reason: str, now: Optional[float] = None) -> None:
    if isinstance(sid, str) and sid:
        with _warns_lock:
            _warns[sid] = (reason[:200], time.time() if now is None else now)


def clear_format_warn(sid) -> None:
    with _warns_lock:
        _warns.pop(sid, None)


def format_warns(now: Optional[float] = None) -> Dict[str, str]:
    """Live warnings {sessionId: reason}; entries older than FORMAT_WARN_TTL are dropped."""
    now = time.time() if now is None else now
    with _warns_lock:
        for k in [k for k, (_, at) in _warns.items() if not 0 <= now - at < FORMAT_WARN_TTL]:
            del _warns[k]
        return {k: v[0] for k, v in _warns.items()}


def missing_key(data, path: List[str]) -> Optional[str]:
    """First key of path that is absent or not a container in an ok orca JSON object, else None."""
    cur = data
    for i, k in enumerate(path):
        if not isinstance(cur, dict) or k not in cur:
            return k
        cur = cur[k]
    return None
