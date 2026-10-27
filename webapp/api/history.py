"""In-session search, fetching the page around a seq (jump to a search hit), and window lineage (chain of previous windows).

Memory is bounded (the api container has 96MB; transcripts can reach hundreds of MB):
- Search reads in SCAN_CHUNK blocks, locates hits with a byte search first (ASCII case-insensitive) and hands only the
  matching lines to transcript._convert. Lines longer than LINE_CAP (tool output, images) are skipped. seq = byte offset of the line start.
- Lineage: first window-lineage.jsonl (copied by the helper from the file named by SOULGENT_LINEAGE to data/lineage.jsonl, reading at most
  the last LINEAGE_MAX), then continued-in markers at the tail of transcripts in the same directory (compaction continuation);
  if neither exists, guess by "same directory, same name, ended before this window started, most recent" (via=guess).
  Each transcript file reads only the first HEAD and last TAIL bytes, cached by (path, mtime, size).
"""
import json
import os
import re
import threading
import time
from collections import OrderedDict, deque
from typing import Any, Dict, List, Optional

try:
    from api import guestcfg, transcript
except ImportError:  # in the container, api/ contents sit directly in the working directory
    import guestcfg  # type: ignore
    import transcript  # type: ignore

SCAN_CHUNK = 1024 * 1024
LINE_CAP = transcript.LINE_CAP
SEARCH_ROLES = ("user", "assistant", "peer")
SNIP_BEFORE = 24
SNIP_AFTER = 60
MAX_Q = 100
LINEAGE_MAX = 1024 * 1024
MAX_DEPTH = 3
HEAD = 16 * 1024
TAIL = 32 * 1024
FILE_CACHE = 512
CHAIN_TTL = 30.0
_UUID = re.compile(r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
_TITLE = re.compile(rb'"(?:customTitle|agentName)": ?"((?:[^"\\]|\\.)*)"')
_CONT = re.compile(rb'"type": ?"continued-in"[^\n]*?"continuedInSessionId": ?"([0-9a-f-]{36})"')
_CONT_TS = re.compile(rb'"timestamp": ?"([^"]+)"')
_lock = threading.Lock()
_files = OrderedDict()  # type: OrderedDict  # transcript path -> (mtime, size, {title, cont, contAt, start})
_lin = {"key": None, "map": {}}  # type: Dict[str, Any]
_chains = OrderedDict()  # type: OrderedDict  # (sid, path, name, lineage file) -> (time, result)


def _cache_clear() -> None:
    with _lock:
        _files.clear()
        _chains.clear()
        _lin.update(key=None, map={})


# ---------- Search ----------
def _scan(path: str, needle: bytes):
    """Yield (line start offset, line bytes) for lines that contain needle (ASCII case-insensitive) and are no longer than LINE_CAP."""
    with open(path, "rb") as f:
        off = 0       # offset of buf[0] in the file (always a line start)
        buf = b""
        skip = False  # discarding the rest of an over-long line
        while True:
            data = f.read(SCAN_CHUNK)
            if not data:
                return
            if skip:
                i = data.find(b"\n")
                if i < 0:
                    off += len(data)
                    continue
                skip = False
                off += i + 1
                data = data[i + 1:]
            buf += data
            cut = buf.rfind(b"\n") + 1
            if cut:
                block = buf[:cut]
                low = block.lower()
                i = low.find(needle)
                while i >= 0:
                    s = block.rfind(b"\n", 0, i) + 1
                    e = block.find(b"\n", i)
                    if e - s <= LINE_CAP:
                        yield off + s, block[s:e]
                    i = low.find(needle, e + 1)
                off += cut
                buf = buf[cut:]
            if len(buf) > LINE_CAP:
                off += len(buf)
                buf = b""
                skip = True


def _snippet(text: str, q: str) -> str:
    flat = " ".join(text.split())
    i = flat.lower().find(q.lower())
    if i < 0:
        return flat[:SNIP_BEFORE + SNIP_AFTER]
    s = max(0, i - SNIP_BEFORE)
    e = min(len(flat), i + len(q) + SNIP_AFTER)
    return ("…" if s > 0 else "") + flat[s:e] + ("…" if e < len(flat) else "")


def search_file(path: str, q: str, limit: int = 50, guest_tag: Any = guestcfg.DEFAULT_TAG) -> List[Dict[str, Any]]:
    """Search a transcript for q: only user / assistant / peer text; returns the newest `limit` hits (newest first).
    Guest messages are recognized by guest_tag (.env GUEST_TAG, the prefix the server adds before each guest message; may also be a list of prefixes) and tagged from=guest."""
    tags = [guest_tag] if isinstance(guest_tag, str) else [t for t in guest_tag or [] if isinstance(t, str)]
    q = " ".join(str(q or "").split())[:MAX_Q]
    if not q or limit <= 0:
        return []
    needle = q.encode("utf-8").lower()
    out = deque(maxlen=limit)  # type: deque
    try:
        for seq, raw in _scan(path, needle):
            for it in transcript._convert(raw):
                if it.get("role") not in SEARCH_ROLES:
                    continue
                text = str(it.get("text") or "")
                if needle not in text.encode("utf-8").lower():
                    continue
                frm = it.get("from") or ""
                if it["role"] == "user" and any(guestcfg.said_by_guest(text, t) for t in tags):
                    frm = guestcfg.ACCOUNT  # a guest message (the summary window may have cut off the leading prefix; the frontend relies on this to recognize it)
                out.append({"ts": it.get("ts") or "", "role": it["role"], "from": frm,
                            "snippet": _snippet(text, q), "seq": seq})
                break  # count a line once
    except OSError:
        return []
    return list(reversed(out))


AFTER = 8           # how many entries to include after the hit line on the jump page (so the hit can scroll to mid-screen)
AFTER_LINES = 400   # look at most this many lines forward
AFTER_BYTES = 4 * 1024 * 1024


def _after_end(f, end: int, want: int) -> (int, int):
    """From end (a line start), count forward `want` displayable entries (tool entries excluded); returns (new page-end offset, actual count). Over-long lines are skipped, not parsed."""
    f.seek(end)
    pos, got, lines = end, 0, 0
    while got < want and lines < AFTER_LINES and pos - end < AFTER_BYTES:
        piece = f.readline(LINE_CAP)
        if not piece:
            break
        n = len(piece)
        full = piece.endswith(b"\n")
        while not piece.endswith(b"\n"):
            piece = f.readline(LINE_CAP)
            if not piece:
                return pos, got  # partial line: not counted
            n += len(piece)
        lines += 1
        if full:
            got += sum(1 for it in transcript._convert(piece) if it.get("role") != "tool")
        pos += n
    return pos, got


def around(path: str, seq: int, limit: int = 30, after: int = AFTER, roots=None) -> Optional[dict]:
    """The page containing the line at seq, plus its next: `limit` entries before the hit line and at most `after` after it; returns None if seq is not a line start."""
    try:
        size = os.path.getsize(path)
        if not isinstance(seq, int) or seq < 0 or seq >= size:
            return None
        with open(path, "rb") as f:
            if seq > 0:
                f.seek(seq - 1)
                if f.read(1) != b"\n":
                    return None
            f.seek(seq)
            end = seq
            while True:
                piece = f.read(64 * 1024)
                if not piece:
                    break
                i = piece.find(b"\n")
                if i >= 0:
                    end += i + 1
                    break
                end += len(piece)
            end2, got = _after_end(f, end, after) if after > 0 else (end, 0)
    except OSError:
        return None
    page = transcript.read_page(path, end2, limit + got, roots=roots)  # roots: stat attachments and drop missing ones
    page["hit"] = seq
    return page


# ---------- Lineage ----------
def _lineage_map(lfile: str) -> Dict[str, Dict[str, str]]:
    """new_session_id -> its last record {prev, at, via, name}. Reads only the last LINEAGE_MAX bytes of the file; cached by mtime/size."""
    try:
        stt = os.stat(lfile)
    except OSError:
        return {}
    key = (lfile, stt.st_mtime_ns, stt.st_size, LINEAGE_MAX)
    with _lock:
        if _lin["key"] == key:
            return _lin["map"]
    out = {}  # type: Dict[str, Dict[str, str]]
    try:
        with open(lfile, "rb") as f:
            if stt.st_size > LINEAGE_MAX:
                f.seek(stt.st_size - LINEAGE_MAX)
                data = f.read(LINEAGE_MAX)
                data = data[data.find(b"\n") + 1:]
            else:
                data = f.read(LINEAGE_MAX)
    except OSError:
        data = b""
    for ln in data.split(b"\n"):
        ln = ln.strip()
        if not ln:
            continue
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        new, prev = str(o.get("new_session_id") or ""), str(o.get("prev_session_id") or "")
        if _UUID.match(new) and _UUID.match(prev) and new != prev:
            out[new] = {"prev": prev, "at": str(o.get("at") or ""), "via": str(o.get("via") or "window"),
                        "name": str(o.get("name") or "")}
    with _lock:
        _lin.update(key=key, map=out)
    return out


def _file_info(path: str) -> Optional[Dict[str, str]]:
    """Transcript head and tail info: title (last customTitle/agentName), cont (continued-in target), contAt, start (first timestamp)."""
    try:
        stt = os.stat(path)
    except OSError:
        return None
    with _lock:
        hit = _files.get(path)
        if hit and hit[0] == stt.st_mtime_ns and hit[1] == stt.st_size:
            _files.move_to_end(path)
            return hit[2]
    info = {"title": "", "cont": "", "contAt": "", "start": ""}
    try:
        with open(path, "rb") as f:
            head = f.read(HEAD)
            tail = b""
            if stt.st_size > HEAD:
                f.seek(max(HEAD, stt.st_size - TAIL))
                tail = f.read(TAIL)
    except OSError:
        return None
    titles = _TITLE.findall(tail) or _TITLE.findall(head)
    if titles:
        try:
            info["title"] = json.loads(b'"' + titles[-1] + b'"')
        except ValueError:
            info["title"] = titles[-1].decode("utf-8", "replace")
    for blob in (tail, head):
        m = None
        for m in _CONT.finditer(blob):
            pass
        if m:
            info["cont"] = m.group(1).decode("ascii")
            t = _CONT_TS.search(m.group(0))
            info["contAt"] = t.group(1).decode("utf-8", "replace") if t else ""
            break
    t = _CONT_TS.search(head)
    info["start"] = t.group(1).decode("utf-8", "replace") if t else ""
    with _lock:
        _files[path] = (stt.st_mtime_ns, stt.st_size, info)
        _files.move_to_end(path)
        while len(_files) > FILE_CACHE:
            _files.popitem(last=False)
    return info


def _iso_epoch(s: str) -> Optional[float]:
    s = (s or "").strip()
    if not s:
        return None
    from datetime import datetime
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _iso(t: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def _locate(sid: str, near: str, root: str) -> Optional[str]:
    """<sid>.jsonl: look in the near directory first, then in each project directory under root (one level only)."""
    name = sid + ".jsonl"
    p = os.path.join(near, name)
    if os.path.isfile(p):
        return p
    try:
        dirs = os.listdir(root)
    except OSError:
        return None
    for d in dirs:
        p = os.path.join(root, d, name)
        if os.path.isfile(p):
            return p
    return None


def _jsonls(d: str) -> List[str]:
    try:
        return [os.path.join(d, n) for n in os.listdir(d) if n.endswith(".jsonl") and _UUID.match(n[:-6])]
    except OSError:
        return []


def _continued_from(sid: str, path: str) -> Optional[Dict[str, str]]:
    for p in _jsonls(os.path.dirname(path)):
        if p == path:
            continue
        info = _file_info(p)
        if info and info["cont"] == sid:
            return {"sid": os.path.basename(p)[:-6], "path": p, "at": info["contAt"], "via": "continued"}
    return None


def _guess(sid: str, path: str, name: str, skip: set) -> Optional[Dict[str, str]]:
    """The most recent transcript in the same directory with the same name that was last modified before this window started."""
    if not name:
        return None
    me = _file_info(path)
    start = _iso_epoch(me["start"]) if me else None
    if start is None:
        try:
            start = os.stat(path).st_mtime
        except OSError:
            return None
    best = None
    for p in _jsonls(os.path.dirname(path)):
        s = os.path.basename(p)[:-6]
        if p == path or s in skip:
            continue
        try:
            mt = os.stat(p).st_mtime
        except OSError:
            continue
        if mt >= start or (best and mt <= best[0]):
            continue
        info = _file_info(p)
        if info and info["title"] == name:
            best = (mt, p, s)
    if not best:
        return None
    return {"sid": best[2], "path": best[1], "at": _iso(best[0]), "via": "guess"}


def chain(sid: str, path: str, root: str, name: str, lfile: str, depth: int = MAX_DEPTH) -> List[Dict[str, str]]:
    """Up to `depth` previous windows before this one: [{sid, path, at, via}] (nearest first).
    via: window / window-fallback / backfill (as in the lineage file), continued (compaction continuation), guess (guessed by name)."""
    key = (sid, path, name, lfile, depth)
    now = time.time()
    with _lock:
        hit = _chains.get(key)
        if hit and now - hit[0] < CHAIN_TTL:
            return [dict(x) for x in hit[1]]
    lmap = _lineage_map(lfile)
    out = []  # type: List[Dict[str, str]]
    seen = {sid}
    cur, cur_path = sid, path
    while len(out) < depth:
        nxt = None
        e = lmap.get(cur)
        if e and e["prev"] not in seen:
            p = _locate(e["prev"], os.path.dirname(cur_path), root)
            if p:
                nxt = {"sid": e["prev"], "path": p, "at": e["at"], "via": e["via"], "name": e["name"]}  # name: used to truncate for guests
        if nxt is None:
            nxt = _continued_from(cur, cur_path)
            if nxt and nxt["sid"] in seen:
                nxt = None
        if nxt is None:
            nxt = _guess(cur, cur_path, name, seen)
        if nxt is None:
            break
        seen.add(nxt["sid"])
        out.append(nxt)
        cur, cur_path = nxt["sid"], nxt["path"]
    with _lock:
        _chains[key] = (now, out)
        _chains.move_to_end(key)
        while len(_chains) > 64:
            _chains.popitem(last=False)
    return [dict(x) for x in out]
