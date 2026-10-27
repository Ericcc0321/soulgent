"""Global chat search. Reads only the helper-built data/textidx/ (<sid>.jsonl + _state.json), never the raw transcripts.

Each index file is <=5MB; read in chunks with a byte search first (ASCII case-insensitive), then only matching lines are parsed,
so memory stays bounded (api container 96MB). Hits in previous windows are attributed to the current session via owners in _state.json;
names / zones come from the snapshot (on duty + off-duty roster); sessions missing from the snapshot are dropped.
Long messages are indexed in parts (several lines sharing one seq, each with part); results are de-duplicated by seq per file:
counted once, snippet taken from the first matching part.
"""
import json
import os
import re
import time
from collections import deque
from typing import Any, Dict, List

CHUNK = 1024 * 1024
HITS_PER = 5          # max hits per session (count covers all)
MAX_Q = 100
SNIP_BEFORE = 24
SNIP_AFTER = 60
_UUID = re.compile(r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")


def _snippet(text: str, q: str) -> str:
    i = text.lower().find(q.lower())
    if i < 0:
        return text[:SNIP_BEFORE + SNIP_AFTER]
    s = max(0, i - SNIP_BEFORE)
    e = min(len(text), i + len(q) + SNIP_AFTER)
    return ("…" if s > 0 else "") + text[s:e] + ("…" if e < len(text) else "")


def _lines(path: str, needle: bytes):
    """Yield complete lines containing needle (ASCII case-insensitive); a trailing partial line without a newline is skipped."""
    with open(path, "rb") as f:
        buf = b""
        while True:
            data = f.read(CHUNK)
            if not data:
                return
            buf += data
            cut = buf.rfind(b"\n") + 1
            if not cut:
                continue
            block, buf = buf[:cut], buf[cut:]
            low = block.lower()
            i = low.find(needle)
            while i >= 0:
                s = block.rfind(b"\n", 0, i) + 1
                e = block.find(b"\n", i)
                yield block[s:e]
                i = low.find(needle, e + 1)


def _owners(idx_dir: str) -> Dict[str, str]:
    try:
        with open(os.path.join(idx_dir, "_state.json"), "r", encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        return {}
    own = st.get("owners") if isinstance(st, dict) else None
    return {k: v for k, v in own.items() if isinstance(k, str) and isinstance(v, str)} if isinstance(own, dict) else {}


def search(idx_dir: str, q: str, limit: int, snap: Dict[str, Any]) -> Dict[str, Any]:
    """→ {results: [{sid, name, zone, off, count, last, hits: [{sid, seq, ts, role, from, snippet}]}], ms}
    results are ordered by most recent hit, newest first; hits are newest first, at most HITS_PER per group and at most `limit` hits in total."""
    t0 = time.time()
    q = " ".join(str(q or "").split())[:MAX_Q]
    info = {}  # type: Dict[str, Dict[str, Any]]
    for s in snap.get("sessions") or []:
        if isinstance(s, dict) and s.get("kind") == "claude" and isinstance(s.get("id"), str):
            info.setdefault(s["id"], {"name": s.get("name") or "", "zone": s.get("zone") or "", "off": False})
    for o in snap.get("offduty") or []:
        if isinstance(o, dict) and isinstance(o.get("sid"), str):
            info.setdefault(o["sid"], {"name": o.get("name") or "", "zone": o.get("zone") or "", "off": True})
    try:
        names = sorted(n for n in os.listdir(idx_dir) if n.endswith(".jsonl") and _UUID.match(n[:-6]))
    except OSError:
        names = []
    if not q or not names:
        return {"results": [], "ms": int((time.time() - t0) * 1000)}
    owners = _owners(idx_dir)
    needle = q.encode("utf-8").lower()
    ql = q.lower()
    groups = {}  # type: Dict[str, Dict[str, Any]]
    for n in names:
        wsid = n[:-6]
        owner = owners.get(wsid, wsid)
        meta = info.get(owner)
        if meta is None:
            continue
        g = groups.get(owner)
        if g is None:
            g = groups[owner] = {"sid": owner, "name": meta["name"], "zone": meta["zone"], "off": meta["off"],
                                 "count": 0, "last": "", "hits": deque(maxlen=HITS_PER)}
        seen = set()  # seqs already counted for this file (multiple chunks of one message are reported once)
        try:
            for raw in _lines(os.path.join(idx_dir, n), needle):
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                text = str(r.get("text") or "") if isinstance(r, dict) else ""
                if ql not in text.lower():
                    continue
                seq = r.get("seq")
                if isinstance(seq, (int, str)):
                    if seq in seen:
                        continue
                    seen.add(seq)
                ts = str(r.get("ts") or "")
                g["count"] += 1
                hit = {"sid": wsid, "seq": r.get("seq"), "ts": ts, "role": r.get("role") or "",
                       "from": r.get("from") or "", "snippet": _snippet(text, q)}
                # keep only the newest HITS_PER per group, ordered by ts (also correct when previous and current windows interleave)
                hs = g["hits"]
                if len(hs) < HITS_PER or ts >= hs[0]["ts"]:
                    items = sorted(list(hs) + [hit], key=lambda x: x["ts"])[-HITS_PER:]
                    hs.clear()
                    hs.extend(items)
                if ts > g["last"]:
                    g["last"] = ts
        except OSError:
            continue
    res = [g for g in groups.values() if g["count"]]
    res.sort(key=lambda g: g["last"], reverse=True)
    out = []  # type: List[Dict[str, Any]]
    left = max(1, int(limit))
    for g in res:
        if left <= 0:
            break
        hits = list(reversed(list(g["hits"])))[:left]
        left -= len(hits)
        out.append(dict(g, hits=hits))
    return {"results": out, "ms": int((time.time() - t0) * 1000)}
