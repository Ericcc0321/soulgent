"""Small chat-text index (for the global search).

A helper background thread, every EVERY seconds: for each session in the snapshot (on duty + off-duty roster) and its
lineage windows (up to 3), reads newly appended complete lines of the transcript jsonl, keeps only the plain text of
user / assistant / peer (Markdown stripped, cut to MAX_TEXT chars), and appends to data/textidx/<sid>.jsonl, one
{seq, ts, role, from, text} per line (seq = byte offset of the source line, same as in-session search).
Messages longer than MAX_TEXT are split into parts of <=MAX_TEXT chars (preferably at sentence ends / newlines), one line
each, sharing seq/ts, with part (from 0), at most MAX_PARTS parts; api/textsearch de-duplicates by seq. Short messages have no part.
data/textidx/_state.json holds {v, files: {sid: {path, ino, offset, size}}, owners: {sid: current session id}, at, pending};
if v (FORMAT) doesn't match, everything is rebuilt (still throttled by BUDGET / PER_FILE).

- Transcript shrank / file replaced (inode changed) -> rebuild; a session index above IDX_MAX keeps only the last IDX_KEEP.
- Each round reads at most BUDGET bytes and at most PER_FILE per file; the first full build spreads over many rounds so the Mac stays responsive.
- Tool output, task notifications and sub-agent side chains are never indexed (reuses api/transcript._convert, then filters by role).
- The api container mounts data/ read-only, so files and directories written here must be readable by other users.
"""
import json
import os
import re
import tempfile
import time
from typing import Any, Dict, List, Optional, Tuple

from api import history
from api import transcript as _tr

EVERY = 15.0
BUDGET = 20 * 1024 * 1024
PER_FILE = 5 * 1024 * 1024
IDX_MAX = 5 * 1024 * 1024
IDX_KEEP = 4 * 1024 * 1024
MAX_TEXT = 400
MAX_PARTS = 30     # max chunks per message (~12000 chars); keeps huge replies from flooding the index
FORMAT = 2         # index format version (2 = long messages split into chunks); rebuild if _state.json lacks it or differs
DEPTH = 3
LINE_CAP = _tr.LINE_CAP
ROLES = ("user", "assistant", "peer")
STATE = "_state.json"
_UUID = re.compile(r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")

_MD = [
    (re.compile(r"```[^\n]*"), " "),                     # code fence (with language name)
    (re.compile(r"!\[([^\]]*)\]\([^)]*\)"), r"\1"),       # image -> alt
    (re.compile(r"\[([^\]]+)\]\([^)]*\)"), r"\1"),        # link -> text
    (re.compile(r"(?m)^\s{0,3}#{1,6}\s+"), ""),          # heading
    (re.compile(r"(?m)^\s{0,3}>\s?"), ""),               # blockquote
    (re.compile(r"(?m)^\s*[-*+]\s+(\[[ xX]\]\s+)?"), ""), # list item, checkbox
    (re.compile(r"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"), " "),  # table separator row
    (re.compile(r"\*+|__+|~~|`+"), ""),                   # bold / italic / strikethrough / inline code
    (re.compile(r"\|"), " "),                             # table pipe
]


def _strip_md(s: str) -> str:
    """Strip Markdown markup, keeping newlines (needed for chunking)."""
    t = str(s or "")
    for rx, rep in _MD:
        t = rx.sub(rep, t)
    return t


def clean_text(s: str) -> str:
    """Strip Markdown markup, collapse to one line, truncate to MAX_TEXT chars."""
    return " ".join(_strip_md(s).split())[:MAX_TEXT]


_BREAK = re.compile(r"[。！？；!?;\n]")
_SOFT = re.compile(r"[，、,：:\s]")


def split_text(s: str) -> List[str]:
    """Strip Markdown, then split into chunks of at most MAX_TEXT chars (before collapsing to one line): prefer ending a chunk at a sentence end or newline,
    then a comma or whitespace, else cut hard; each chunk is then collapsed to one line. At most MAX_PARTS chunks."""
    t = _strip_md(s)
    out = []  # type: List[str]
    pos, n = 0, len(t)
    while pos < n and len(out) < MAX_PARTS:
        end = min(n, pos + MAX_TEXT)
        if end < n:
            win = t[pos:end]
            cut = -1
            for m in _BREAK.finditer(win):
                cut = m.end()
            if cut < MAX_TEXT // 2:  # sentence end is too early: fall back to breaking at a comma or whitespace
                for m in _SOFT.finditer(win):
                    if m.end() > cut:
                        cut = m.end()
            if cut >= MAX_TEXT // 4:
                end = pos + cut
        seg = " ".join(t[pos:end].split())
        if seg:
            out.append(seg[:MAX_TEXT])
        pos = end
    return out


def _row(raw: bytes, seq: int) -> List[Dict[str, Any]]:
    """One raw record -> index rows (multiple text parts in one record are first joined with newlines, then split by MAX_TEXT); returns [] if it should not be indexed."""
    role, frm, parts, ts = None, "", [], ""
    for it in _tr._convert(raw):
        r = it.get("role")
        if r not in ROLES or (role and r != role):
            continue
        raw_text = str(it.get("text") or "")
        text = clean_text(raw_text)
        if not text:  # compaction notices have role=notice (not in ROLES), so no text-based filtering is needed
            continue
        role, frm, ts = r, it.get("from") or frm, it.get("ts") or ts
        parts.append(raw_text)
    if not role:
        return []
    segs = split_text("\n".join(parts))
    if len(segs) == 1:
        return [{"seq": seq, "ts": ts, "role": role, "from": frm, "text": segs[0]}]
    return [{"seq": seq, "ts": ts, "role": role, "from": frm, "text": x, "part": k} for k, x in enumerate(segs)]


def _write_atomic(path: str, data: bytes) -> None:
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".ti-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _ensure_dir(d: str) -> None:
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o755)
    except OSError:
        pass


def _trim(idx: str) -> None:
    """Index exceeds IDX_MAX: keep only the complete lines within the last IDX_KEEP bytes."""
    try:
        size = os.path.getsize(idx)
    except OSError:
        return
    if size <= IDX_MAX:
        return
    with open(idx, "rb") as f:
        f.seek(size - IDX_KEEP)
        data = f.read()
    _write_atomic(idx, data[data.find(b"\n") + 1:])


def index_file(sid: str, path: str, out_dir: str, ent: Dict[str, Any], max_read: int) -> Tuple[Dict[str, Any], int]:
    """Index the complete lines added to path since ent["offset"] into out_dir/<sid>.jsonl, reading at most max_read bytes (at least one line).
    Returns (new ent, bytes read)."""
    stt = os.stat(path)
    _ensure_dir(out_dir)
    idx = os.path.join(out_dir, sid + ".jsonl")
    ent = dict(ent or {})
    if (ent.get("path") != path or ent.get("ino") != stt.st_ino or stt.st_size < int(ent.get("size") or 0)
            or stt.st_size < int(ent.get("offset") or 0) or not os.path.exists(idx)):
        ent = {"path": path, "ino": stt.st_ino, "offset": 0, "size": 0}
        _write_atomic(idx, b"")
    off = int(ent["offset"])
    if stt.st_size == off:
        ent["size"] = stt.st_size
        return ent, 0
    out = []  # type: List[bytes]
    pos = off
    with open(path, "rb") as f:
        f.seek(off)
        while pos - off < max_read or pos == off:
            piece = f.readline(LINE_CAP + 1)
            if not piece:
                break
            if not piece.endswith(b"\n"):
                if len(piece) <= LINE_CAP:
                    break  # partial last line: still being written, read next round
                n = len(piece)  # oversized line (tool output / image): skip to end of line without parsing
                while not piece.endswith(b"\n"):
                    piece = f.readline(1024 * 1024)
                    if not piece:
                        break
                    n += len(piece)
                if not piece.endswith(b"\n"):
                    break  # oversized partial line: retry next round
                pos += n
                continue
            for r in _row(piece, pos):
                out.append(json.dumps(r, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n")
            pos += len(piece)
    if out:
        with open(idx, "ab") as g:
            g.write(b"".join(out))
        _trim(idx)
    ent.update(offset=pos, size=stt.st_size)
    return ent, pos - off


class TextIndexer:
    """Background thread: ticks every EVERY seconds."""

    def __init__(self, snapshot: str, projects: str, lineage: str, out_dir: str,
                 budget: int = BUDGET, per_file: int = PER_FILE, depth: int = DEPTH) -> None:
        self.snapshot = snapshot
        self.projects = projects
        self.lineage = lineage
        self.out_dir = out_dir
        self.budget = budget
        self.per_file = per_file
        self.depth = depth
        self.files = {}  # type: Dict[str, Dict[str, Any]]
        self.started = time.time()
        self.done_logged = False
        try:
            with open(os.path.join(out_dir, STATE), "r", encoding="utf-8") as f:
                st = json.load(f)
            if isinstance(st, dict) and isinstance(st.get("files"), dict) and st.get("v") == FORMAT:  # old format: leave files empty so every file is rebuilt
                self.files = {k: v for k, v in st["files"].items() if isinstance(v, dict)}
                self.done_logged = not st.get("pending")
        except (OSError, ValueError):
            pass

    def _path(self, rel: Any) -> Optional[str]:
        if not isinstance(rel, str) or not rel:
            return None
        root = os.path.realpath(self.projects)
        full = os.path.realpath(os.path.join(root, rel))
        if not full.startswith(root + os.sep) or not os.path.isfile(full):
            return None
        return full

    def targets(self) -> Optional[Tuple[List[Tuple[str, str]], Dict[str, str]]]:
        """[(sid, path)] (on duty -> off duty -> previous window) and owners {sid: current session id}; None if the snapshot cannot be read."""
        try:
            with open(self.snapshot, "r", encoding="utf-8") as f:
                snap = json.load(f)
        except (OSError, ValueError):
            return None
        if not isinstance(snap, dict):
            return None
        heads = []  # type: List[Tuple[str, str, str]]
        for s in snap.get("sessions") or []:
            if isinstance(s, dict) and s.get("kind") == "claude":
                heads.append((str(s.get("id") or ""), s.get("transcript"), str(s.get("name") or "")))
        for o in snap.get("offduty") or []:
            if isinstance(o, dict):
                heads.append((str(o.get("sid") or ""), o.get("transcript"), str(o.get("name") or "")))
        out, owners, prev = [], {}, []  # type: List[Tuple[str, str]], Dict[str, str], List[Tuple[str, str]]
        root = os.path.realpath(self.projects)
        for sid, rel, name in heads:
            if not _UUID.match(sid) or sid in owners:
                continue
            path = self._path(rel)
            if not path:
                continue
            owners[sid] = sid
            out.append((sid, path))
            try:
                wins = history.chain(sid, path, root, name, self.lineage, self.depth)
            except Exception:
                wins = []
            for w in wins:
                p = os.path.realpath(w.get("path") or "")
                if _UUID.match(w.get("sid") or "") and p.startswith(root + os.sep) and os.path.isfile(p):
                    prev.append((w["sid"], p, sid))
        for wsid, p, owner in prev:
            if wsid not in owners:
                owners[wsid] = owner
                out.append((wsid, p))
        return out, owners

    def tick(self, log=None) -> Optional[dict]:
        got = self.targets()
        if got is None:
            return None
        targets, owners = got
        left = self.budget
        read = 0
        for sid, path in targets:
            if left <= 0:
                break
            try:
                ent, n = index_file(sid, path, self.out_dir, self.files.get(sid, {}), min(self.per_file, left))
            except OSError as e:
                if log:
                    log("textidx %s failed: %s" % (sid[:8], type(e).__name__))
                continue
            self.files[sid] = ent
            left -= n
            read += n
        if targets:  # do not prune when the snapshot has no sessions (most likely a bad snapshot)
            keep = {sid for sid, _ in targets}
            for sid in [k for k in self.files if k not in keep]:
                del self.files[sid]
                try:
                    os.unlink(os.path.join(self.out_dir, sid + ".jsonl"))
                except OSError:
                    pass
        pending = 0
        for sid, path in targets:
            ent = self.files.get(sid)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            pending += max(0, size - int((ent or {}).get("offset") or 0))
        _ensure_dir(self.out_dir)
        state = {"v": FORMAT, "files": self.files, "owners": owners, "at": time.time(), "pending": pending}
        _write_atomic(os.path.join(self.out_dir, STATE),
                      json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        if pending == 0 and not self.done_logged:
            self.done_logged = True
            if log:
                log("textidx initial build done: %d files, %.0f s" % (len(targets), time.time() - self.started))
        return {"read": read, "files": len(targets), "pending": pending}

    def loop(self, log=None) -> None:
        while True:
            try:
                self.tick(log)
            except Exception as e:  # a failed round is retried next round
                if log:
                    log("textidx failed: %s: %s" % (type(e).__name__, e))
            time.sleep(EVERY)
