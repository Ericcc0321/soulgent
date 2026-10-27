"""Reads Claude Code transcripts (JSONL) backwards: pages from the end of the file and returns only the conversation, not tool output."""
import json
import os
import re
import threading
import time
from collections import OrderedDict
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    from api import files
    from api.cc_format import (  # noqa: F401  (some names are re-exported for callers and tests)
        ANSWERS_CAP, INDEX_CAP, LINE_CAP, MAX_AGENT_NAME, _API_ERR_MAX, _API_ERR_PREFIX, _IS_ERROR, _QUEUE_ENQ,
        _SKIP_PREFIXES, _TS, _ask_questions, _ask_text, _index_line, _qkey, _queue_line, _scan_result, _scan_tokens,
        _summarize_tool, check_line, format_warn,
    )
except ImportError:  # in the container the contents of api/ sit directly in the working directory
    import files  # type: ignore
    from cc_format import (  # type: ignore  # noqa: F401
        ANSWERS_CAP, INDEX_CAP, LINE_CAP, MAX_AGENT_NAME, _API_ERR_MAX, _API_ERR_PREFIX, _IS_ERROR, _QUEUE_ENQ,
        _SKIP_PREFIXES, _TS, _ask_questions, _ask_text, _index_line, _qkey, _queue_line, _scan_result, _scan_tokens,
        _summarize_tool, check_line, format_warn,
    )

CHUNK = 64 * 1024


_DROP_PREFIXES = ("<bash-stdout", "<bash-stderr", "<local-command-stdout",
                  "<local-command-stderr")
_PEER_PREFIX = "Another Claude session sent a message:"
_PEER_TAG = "<cross-session-message"
# System notices the harness injects into the session (not something a person said): match at the start, or _NOTICE_ANY within the first 800 chars
_NOTICE_PREFIXES = ("[Cross-session", "<channel ", "[Artifact comment", "[SYSTEM NOTIFICATION",
                    "<system-reminder>", "<local-command-caveat>", "<user-prompt-submit-hook>", "[Request interrupted by user")
_NOTICE_ANY = "This is an automated notice"
_AGENT_PREFIXES = ("<agent-message", "<task-notification")
_PEER_BODY = re.compile(r"<cross-session-message\b[^>]*>(.*?)</cross-session-message>", re.S)
_PEER_NAME = re.compile(r"<cross-session-message\b[^>]*?\bfrom-name=\"([^\"]*)\"")
_AGENT_BODY = re.compile(r"<agent-message\b[^>]*>(.*?)(?:</agent-message>|$)", re.S)
_TAG = re.compile(r"</?[A-Za-z][\w-]*[^>]*>")
_CMD_NAME = re.compile(r"<command-name>\s*(.*?)\s*</command-name>", re.S)
_CMD_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.S)
MAX_ARGS = 80
# Subagent hand-back: the from of agent-message and the task-id of task-notification are the subagent id (agentId)
_AGENT_FROM = re.compile(r"<agent-message\b[^>]*?\bfrom=\"([^\"]*)\"")
_TASK_ID = re.compile(r"<task-id>\s*(.*?)\s*</task-id>", re.S)
_TASK_AGENT = re.compile(r"<summary>\s*Agent \"(.*?)\"", re.S)
_TASK_SUMMARY = re.compile(r"<summary>(.*?)</summary>", re.S)
# Dispatching tool id and state in a task notification (completed / failed / killed / stopped / running)
_TASK_TOOL = re.compile(r"<tool-use-id>\s*(.*?)\s*</tool-use-id>", re.S)
_TASK_STATUS = re.compile(r"<status>\s*([A-Za-z_]+)\s*</status>")
# The outer frame of a hand-back ("[Subagent hand-back] ... The report follows:"); body lines are indented two spaces
_HANDBACK = "[Subagent hand-back]"
_HANDBACK_END = "The report follows:"


def classify_user_text(text: str):
    """User string message -> (origin, peer, body). origin: user / peer / agent / notice.
    Decision order (only user records whose content is a string, after stripping leading whitespace): contains <agent-message or starts with <task-notification -> agent
    (subagent hand-backs also start with the inter-session prefix, so agent is checked first); system notice -> notice; starts with the inter-session prefix or contains <cross-session-message -> peer
    (peer = the from-name value, empty if unavailable); everything else (including text sent from the phone) -> user. isSidechain records are skipped by the caller, isMeta records only count as agent/peer.
    The turn origin is that of the last such record; when the session is waiting it counts as waiting for you first, regardless of origin.
    body is the text with the outer tag removed (returned unchanged for user)."""
    t = text.lstrip()
    if "<agent-message" in text or t.startswith("<task-notification"):
        b = _AGENT_BODY.search(t) if "<agent-message" in t else None
        body = b.group(1) if b else _TAG.sub("\n", t)
        return "agent", None, re.sub(r"\n\s*\n+", "\n", body).strip()
    if not t.startswith(_PEER_PREFIX) and (t.startswith(_NOTICE_PREFIXES) or _NOTICE_ANY in t[:800]):
        return "notice", None, t  # system notice: not a user, no bubble, not unread
    if t.startswith(_PEER_PREFIX) or _PEER_TAG in text:
        m = _PEER_NAME.search(text)
        peer = m.group(1).strip() if m and m.group(1).strip() else None
        b = _PEER_BODY.search(text)
        if b:
            body = b.group(1)
        else:
            body = t[len(_PEER_PREFIX):] if t.startswith(_PEER_PREFIX) else t
            body = _TAG.sub("", body)
        return "peer", peer, body.strip()
    return "user", None, text


def _strip_handback(body: str) -> str:
    """Strip the subagent hand-back frame text and the two-space indent of each body line; returned unchanged if not in this format."""
    if not body.startswith(_HANDBACK):
        return body
    i = body.find(_HANDBACK_END)
    if i < 0:
        return body
    rest = body[i + len(_HANDBACK_END):].lstrip("\n")
    return "\n".join(ln[2:] if ln.startswith("  ") else ln for ln in rest.split("\n")).strip()


def _agent_ref(text: str):
    """Raw subagent hand-back -> (id, the task name carried in the hand-back); empty strings if unavailable."""
    m = _AGENT_FROM.search(text) or _TASK_ID.search(text)
    n = _TASK_AGENT.search(text)
    return (m.group(1).strip() if m else ""), (n.group(1).strip()[:MAX_AGENT_NAME] if n else "")


# ---------- Cross-page small index (incremental only; the whole record is never read into memory, so a big record cannot blow up the container) ----------
# One index per record, reading line by line from the last scanned position (at most LINE_CAP bytes of a line kept in memory), keeping a few small tables of at most INDEX_CAP entries each (FIFO):
#   names  subagent id -> dispatch description        tools  subagent id -> id of the tool call that dispatched it
#   marks  tool call id -> {err, bg} (only errored and background-dispatched ones; normal completions are not recorded)
#   tasks  tool call id -> latest task state (completed / failed / killed / stopped / running)
#   bgids  background task id (backgroundTaskId) -> tool call id (maps back when the notification has only a task-id)
#   answers  question tool call id -> the user's answer (the "answered" card on an old page shows it; at most ANSWERS_CAP entries, each truncated)
# At most INDEX_FILES indexes; beyond that the least recently used is dropped. Shared by threads (phone paging and push polling), so locked.
INDEX_FILES = 16
_index = OrderedDict()  # type: OrderedDict
_index_lock = threading.Lock()


def _new_index() -> Dict[str, Any]:
    return {"pos": 0, "names": OrderedDict(), "tools": OrderedDict(), "marks": OrderedDict(),
            "tasks": OrderedDict(), "bgids": OrderedDict(), "answers": OrderedDict(), "notes": OrderedDict(),
            "qpend": [], "qfate": OrderedDict(), "qback": []}


def queued_texts(path: str) -> List[str]:
    """Text keys (first 200 chars) of messages still queued (not yet read by Claude Code), in enqueue order."""
    return [k for _, k in file_index(path)["qpend"] if k is not None]


def recall_lookup(path: str, key: str, norm: Callable[[Any], str], limit: int = 30) -> Optional[Dict[str, Any]]:
    """Find the user message to recall on the last page (the normalized first 200 chars match; take the most recent).
    norm is supplied by the caller (the server uses outbox.clean_lines, the same basis as the text sent by the frontend).
    Returns {ts, last (no user message after it)}; None if not found on the last page (a message within 2 minutes is always on the last page, so not found counts as timed out)."""
    items = read_page(path, None, limit=limit)["items"]
    later = False
    for it in reversed(items):
        if it.get("role") != "user" or it.get("recalled"):  # already-recalled ones do not count as "something after"
            continue
        if _qkey(norm(it.get("text"))) == key[:200]:
            return {"ts": str(it.get("ts") or ""), "last": not later}
        later = True
    return None


def menu_pending(items: List[Dict[str, Any]]) -> bool:
    """The last item of the read_page last page is an unanswered question, or the trailing run of tool calls has one without a result (approval menu).
    Same criterion as the frontend liveAskIndex / approveTarget."""
    if not items:
        return False
    last = items[-1]
    if last.get("role") == "ask":
        return not last.get("answered")
    i = len(items)
    while i > 0 and items[i - 1].get("role") == "tool":
        i -= 1
        if items[i].get("pending"):
            return True
    return False


def queue_item(line: bytes, start: int, ent: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """enqueue line -> user message item (with read / queued / recalled); None if it should not be shown. Only the user's own words (inter-session messages go through peer)."""
    fate = ent["qfate"].get(str(start), "sent")
    if fate in ("dequeued", "hidden"):
        return None
    try:
        obj = json.loads(line)
    except ValueError:
        return None
    content = obj.get("content") if isinstance(obj, dict) else None
    if not isinstance(content, str):
        return None
    ts = str(obj.get("timestamp") or "")
    if classify_user_text(content)[0] != "user":  # inter-session messages, subagent/task notifications and harness system notices (notice) are not emitted here when queued (notices have their own index)
        return None
    text = _user_text(content)
    if not text:
        return None
    it = {"role": "user", "text": text, "ts": ts, "read": fate == "read"}  # type: Dict[str, Any]
    if fate == "recalled":
        it["recalled"] = True
    elif fate == "sent":
        it["queued"] = True
    return it


def _iter_lines(f, end: int):
    """Read line by line from the current position to end. Each line yields (head bytes, whether complete, whether it contains the is_error literal, end position);
    lines over LINE_CAP keep only the head and drop the rest while reading. A trailing half-line without newline is not yielded (wait for next time)."""
    pos = f.tell()
    while pos < end:
        piece = f.readline(min(LINE_CAP, end - pos))
        if not piece:
            return
        head = piece
        full = piece.endswith(b"\n")
        n = len(piece)
        err = _IS_ERROR in piece
        tail = piece[-32:]
        while not piece.endswith(b"\n") and pos + n < end:
            piece = f.readline(min(LINE_CAP, end - pos - n))
            if not piece:
                break
            err = err or _IS_ERROR in (tail + piece)
            tail = piece[-32:]
            n += len(piece)
        if not piece.endswith(b"\n"):
            return  # half-line: leave for next time
        pos += n
        yield head, full, err, pos


def file_index(path: str) -> Dict[str, Any]:
    """Get the index of a record and scan the newly written part. If the file got shorter (replaced), scan from the start."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return _new_index()
    with _index_lock:
        ent = _index.pop(path, None)
        if ent is None or size < ent["pos"]:
            ent = _new_index()
        if size > ent["pos"]:
            try:
                with open(path, "rb") as f:
                    f.seek(ent["pos"])
                    for head, full, err, end in _iter_lines(f, size):
                        _index_line(ent, head, full, err)
                        _queue_line(ent, head, full, ent["pos"])
                        ent["pos"] = end
            except OSError:
                pass
        _index[path] = ent  # move to most recent; when over capacity drop the least recently used
        while len(_index) > INDEX_FILES:
            _index.popitem(last=False)
        return ent


def agent_names(path: str) -> Dict[str, str]:
    """Subagent id -> dispatch description (from the index, at most INDEX_CAP entries)."""
    return dict(file_index(path)["names"])


def agent_tools(path: str) -> Dict[str, str]:
    """Subagent id -> id of the tool call that dispatched it (toolUseId)."""
    return dict(file_index(path)["tools"])


def _dropped(text: str) -> bool:
    return text.lstrip().startswith(_DROP_PREFIXES)


def _user_text(content: Any) -> str:
    """User message -> displayable text; command output and tool results never appear. An empty string means do not send."""
    if isinstance(content, str):
        if _dropped(content) or classify_user_text(content)[0] == "notice":
            return ""
        m = _CMD_NAME.search(content)
        if m:
            name = m.group(1).strip()
            if name and not name.startswith("/"):
                name = "/" + name
            args = _CMD_ARGS.search(content)
            extra = args.group(1).strip() if args else ""
            if extra and len(extra) <= MAX_ARGS:
                name += " " + extra
            return name
        return content
    if isinstance(content, list):
        texts = []
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                t = str(b.get("text", ""))
                if t.strip() and not _dropped(t) and not t.lstrip().startswith("<task-notification") \
                        and not t.lstrip().startswith(_NOTICE_PREFIXES):
                    texts.append(t)
        out = "\n".join(texts)
        if classify_user_text(out)[0] == "notice":
            return ""
        return out.strip()  # no "[image]" text is appended for inline images: _convert attaches files (ref)
    return ""


# ---------- Bubble attachments (files): body paths / Bash open / user inline images / phone uploads ----------
FILES_CAP = 9  # at most this many attached per message
STAT_TTL = 60.0  # existing files: stat result cached for 60 s
STAT_TTL_MISS = 10.0  # missing / not allowed: cached only 10 s (so a file written shortly after is not invisible for a whole minute)
STAT_CAP = 2000
UPLOAD_MARK = "/data/uploads/"  # directory where phone uploads land (only such paths in user messages are attached)
_stat_cache = OrderedDict()  # type: OrderedDict  # host path -> (time, (size, mtime_ns) or None)
_stat_lock = threading.Lock()


def _file_entry(path: str, src: str, in_link: bool = False) -> Optional[Dict[str, Any]]:
    name = os.path.basename(path)
    kind = files.classify(name, in_link=in_link)
    if not kind:
        return None
    return {"path": path, "name": name, "kind": kind, "src": src}


def _text_files(text: str) -> List[Dict[str, Any]]:
    out = []  # type: List[Dict[str, Any]]
    for path, src in files.find_paths(text):
        e = _file_entry(path, src, in_link=(src == "md"))
        if e:
            out.append(e)
    return out


def _upload_files(text: str) -> List[Dict[str, Any]]:
    """Paths of phone-uploaded files in a user message (only the upload directory counts)."""
    out = []  # type: List[Dict[str, Any]]
    for path, _ in files.find_paths(text):
        if UPLOAD_MARK in path:
            e = _file_entry(path, "upload", in_link=True)
            if e:
                out.append(e)
    return out


def _merge_files(it: Dict[str, Any], extra: List[Dict[str, Any]]) -> None:
    cur = it.setdefault("files", [])
    for e in extra:
        for c in cur:
            if c.get("path") == e["path"]:
                c["src"] = e["src"]
                break
        else:
            cur.append(e)


def attach_open_files(items: List[Dict[str, Any]]) -> None:
    """Attach Bash open files to the last assistant text of this turn (items is a page in forward order).
    In real records an assistant record has only one content block, with text and tool_use on different lines, so attribution must go by turn, not by line.
    Turn boundary = a user / peer item; if this turn has no text on this page, it stays on the tool item itself (the frontend draws a small "opened a file" card).
    The _open marker is cleared after use."""
    turn = []  # type: List[Dict[str, Any]]

    def flush() -> None:
        last = None
        for it in turn:
            if it.get("role") == "assistant":
                last = it
        for it in turn:
            paths = it.pop("_open", None)
            if not paths:
                continue
            ents = [e for e in (_file_entry(p, "open", in_link=True) for p in paths) if e]
            if ents:
                _merge_files(last if last is not None else it, ents)

    for it in items:
        if it.get("role") in ("user", "peer"):
            flush()
            turn = []
        turn.append(it)
    flush()


# ---------- Agent-reply files a guest may fetch: the page allowlist and the /api/file recheck share one rule ----------
def msg_text_paths(text: Any) -> set:
    """File paths appearing in one assistant text (raw strings, `~/` not expanded)."""
    return {p for p, _ in files.find_paths(text)} if isinstance(text, str) and "/" in text else set()


def guest_msg_file(it: Dict[str, Any], f: Dict[str, Any]) -> bool:
    """Whether a guest may see this attachment: only assistant items, and the path must really be written in this reply text.
    src of md/text satisfies this naturally; open (opened on the Mac) counts only if the reply also writes the path (_merge_files rewrites the src of the same path to open);
    open cards on tool items, and open-only paths not written in the reply, never count."""
    if not isinstance(it, dict) or it.get("role") != "assistant" or not isinstance(f, dict):
        return False
    p = f.get("path")
    return isinstance(p, str) and bool(p) and p in msg_text_paths(it.get("text"))


_ASST_CAP = 32
_ASST_SCAN_BYTES = 64 * 2**20  # bytes one call may scan; the rest is picked up by the next call (the offset is cached)
_ASST_PATHS_CAP = 5000  # paths remembered per record; further ones are dropped (the attachment re-check then denies them)
_asst_cache = OrderedDict()  # type: OrderedDict  # real record path -> (dev, ino, bytes scanned, path set)
_asst_lock = threading.Lock()


def assistant_paths(path: str) -> set:
    """File paths appearing in all assistant reply text in the record (excluding subagent sidechain lines).
    Files are identified by (dev, ino); only newly appended complete lines are scanned incrementally; if the file got shorter or the inode changed, scan from the start. Returns an empty set if unreadable."""
    try:
        st = os.stat(path)
    except OSError:
        return set()
    with _asst_lock:
        hit = _asst_cache.get(path)
        if hit and hit[0] == st.st_dev and hit[1] == st.st_ino and hit[2] <= st.st_size:
            off, acc = hit[2], set(hit[3])
        else:
            off, acc = 0, set()
    if off < st.st_size:
        try:
            with open(path, "rb") as f:  # bounded reads: a line over LINE_CAP (base64 images, huge output) is skipped without being held in memory
                f.seek(off)
                start = off
                for head, full, _err, pos in _iter_lines(f, st.st_size):
                    off = pos
                    if full and b'"assistant"' in head:
                        for it in _convert(head):
                            if it.get("role") == "assistant":
                                for p in msg_text_paths(it.get("text")):
                                    if len(acc) >= _ASST_PATHS_CAP:
                                        break
                                    acc.add(p)
                    if pos - start >= _ASST_SCAN_BYTES:  # per-call budget: stop here, continue next time
                        break
        except OSError:
            return set()
    with _asst_lock:
        _asst_cache[path] = (st.st_dev, st.st_ino, off, frozenset(acc))
        _asst_cache.move_to_end(path)
        while len(_asst_cache) > _ASST_CAP:
            _asst_cache.popitem(last=False)
    return acc


def _real_stat(roots: "files.Roots", host_path: str) -> Optional[Tuple[int, int]]:
    """(size, mtime_ns) of a real file inside the allowlist; None if outside the allowlist / missing.
    Existing results are cached for STAT_TTL (60 s), missing ones only for STAT_TTL_MISS (10 s); at most STAT_CAP entries."""
    now = time.time()
    with _stat_lock:
        hit = _stat_cache.get(host_path)
        if hit and now - hit[0] < (STAT_TTL if hit[1] is not None else STAT_TTL_MISS):
            return hit[1]
    res = None  # type: Optional[Tuple[int, int]]
    real = roots.resolve(host_path)
    if real:
        try:
            stt = os.stat(real)
            res = (stt.st_size, stt.st_mtime_ns)
        except OSError:
            res = None
    with _stat_lock:
        _stat_cache[host_path] = (now, res)
        _stat_cache.move_to_end(host_path)
        while len(_stat_cache) > STAT_CAP:
            _stat_cache.popitem(last=False)
    return res


def _finish_files(items: List[Dict[str, Any]], roots: Optional["files.Roots"] = None,
                  stat: Optional[Callable[[str], Any]] = None) -> None:
    """Finish: stat the path items (only when roots or stat is given; missing / oversized ones are dropped), then cut to FILES_CAP and record more.
    stat returns size (int) or (size, mtime_ns); with mtime_ns the output has v (a string) that the frontend appends to the URL, so an overwritten file at the same path does not hit the old cache.
    Also removes any leftover server-internal keys (starting with _)."""
    fn = stat
    if fn is None and roots is not None:
        fn = lambda p: _real_stat(roots, p)  # noqa: E731
    for it in items:
        for k in [k for k in it if k.startswith("_")]:
            it.pop(k, None)
        fl = it.get("files")
        if not fl:
            continue
        keep = []  # type: List[Dict[str, Any]]
        for f in fl:
            if "path" in f and fn is not None:
                res = fn(f["path"])
                size, mt = res if isinstance(res, tuple) else (res, None)
                if size is None or size > (files.IMG_MAX if f.get("kind") == "image" else files.DOC_MAX):
                    continue
                f["size"] = size
                if mt is not None:
                    f["v"] = str(mt)
            keep.append(f)
        if not keep:
            it.pop("files", None)
            continue
        if len(keep) > FILES_CAP:
            it["more"] = len(keep) - FILES_CAP
            keep = keep[:FILES_CAP]
        it["files"] = keep


def _convert(line: bytes, side: bool = False, bad: Optional[List[Tuple[str, str]]] = None) -> List[Dict[str, Any]]:
    """One line -> zero or more items. Bad lines and irrelevant types give an empty list. side=True reads a subagent's own record (all lines carry isSidechain).
    bad, when given, collects (reason, CC version) for lines whose structure is not understood (cc_format.check_line)."""
    line = line.strip()
    if not line.startswith(b"{") or line.startswith(_SKIP_PREFIXES):
        return []
    if b'"type":"tool_result"' in line:  # tool output line: do not parse the big JSON
        return []
    try:
        obj = json.loads(line)
    except ValueError:
        return []
    if bad is not None:
        why = check_line(obj)
        if why:
            bad.append((why, str(obj.get("version") or "")[:20]))
    if not isinstance(obj, dict) or (obj.get("isSidechain") and not side):
        return []
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return []
    ts = str(obj.get("timestamp") or "")
    kind = obj.get("type")
    content = msg.get("content")
    if kind == "user":
        if obj.get("isMeta") and not (isinstance(content, str) and classify_user_text(content)[0] not in ("user", "notice")):
            return []  # meta records let only inter-session/subagent messages through
        if obj.get("isCompactSummary"):
            return [{"role": "notice", "code": "compacted", "ts": ts}]  # system prompts give only a code, which the frontend shows per language (not shown as a user bubble)
        if isinstance(content, str):
            origin, peer, body = classify_user_text(content)
            if origin == "notice":
                return []
            if origin == "peer":
                return [{"role": "peer", "from": peer or "", "text": body, "ts": ts}]
            if origin == "agent":
                aid, tname = _agent_ref(content)
                extra = {}  # type: Dict[str, Any]
                if content.lstrip().startswith("<task-notification"):  # a task notification keeps only one summary sentence, without ids or temp file paths
                    sm = _TASK_SUMMARY.search(content)
                    body = sm.group(1).strip() if sm and sm.group(1).strip() else body
                    # The notification is not shown on its own; the frontend uses it to decide whether a dispatched tool (subagent / background command) finished and succeeded
                    tt = _TASK_TOOL.search(content)
                    ss = _TASK_STATUS.search(content)
                    extra = {"notice": True, "forTool": tt.group(1) if tt else "",
                             "task": ss.group(1).lower() if ss else ""}
                # _aid/_tname are used only on the server: replaced by agentName when read_page finishes (the hand-back then adds forTool)
                return [dict({"role": "agent", "text": _strip_handback(body), "ts": ts, "_aid": aid, "_tname": tname}, **extra)]
        text = _user_text(content)
        imgs = []  # type: List[Any]
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "image":
                    src = b.get("source") if isinstance(b.get("source"), dict) else {}
                    mime = str(src.get("media_type") or "image/png")
                    imgs.append((len(imgs) + 1, mime if mime.startswith("image/") else "image/png"))
        if not text and not imgs:
            return []
        it = {"role": "user", "text": text, "ts": ts}  # type: Dict[str, Any]
        if imgs:
            it["_img"] = imgs  # once read_page has the line-start offsets, replaced by a ref in files
        up = _upload_files(text) if text else []
        if up:
            it["files"] = up
        return [it]
    if kind != "assistant" or not isinstance(content, list):
        return []
    if obj.get("isApiErrorMessage") is True:  # CC-synthesized API error / limit reached -> centered system line, not a reply bubble
        txt = " ".join(str(b.get("text", "")) for b in content if isinstance(b, dict) and b.get("type") == "text").strip()
        txt = _API_ERR_PREFIX.sub("", txt)[:_API_ERR_MAX].strip()
        if not txt:
            return []
        err = str(obj.get("error") or "")
        k = ("rate_limit" if err == "rate_limit" or "hit your limit" in txt.lower()
             else "auth" if err in ("authentication_failed", "oauth_org_not_allowed") else "api")
        return [{"role": "notice", "code": "apiError", "kind": k, "text": txt, "ts": ts}]
    items = []
    for b in content:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            t = str(b.get("text", ""))
            it = {"role": "assistant", "text": t, "ts": ts}  # type: Dict[str, Any]
            fl = _text_files(t) if "/" in t else []
            if fl:
                it["files"] = fl
            items.append(it)
        elif b.get("type") == "tool_use":
            name = str(b.get("name", ""))
            if name == "AskUserQuestion":
                items.append({"role": "ask", "text": _ask_text(b.get("input")), "ts": ts,
                              "toolUseId": str(b.get("id", "")), "questions": _ask_questions(b.get("input")),
                              "answered": True, "answers": None})
            else:
                it = {"role": "tool", "text": _summarize_tool(name, b.get("input")), "ts": ts,
                      "toolUseId": str(b.get("id", "")), "pending": False, "name": name}
                if name in AGENT_TOOLS:  # dispatching a subagent: the input is used only on the server (replaced by the agent field when read_page finishes)
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    it["_agent"] = {"description": str(inp.get("description") or "")[:MAX_AGENT_NAME],
                                    "model": str(inp.get("model") or ""),
                                    "agentType": str(inp.get("subagent_type") or ""),
                                    "task": first_sentence(inp.get("prompt"))}
                if name == "Bash":
                    cmd = b.get("input", {}).get("command") if isinstance(b.get("input"), dict) else None
                    op = files.open_targets(cmd) if isinstance(cmd, str) else []
                    if op:
                        it["_open"] = op  # only a marker: read_page attributes by turn (attach_open_files), not attached here
                items.append(it)
    return items


def _name_agents(ent: Dict[str, Any], items: List[Dict[str, Any]]) -> None:
    """Add agentName to a subagent hand-back: match the dispatch description by id, else use the task name carried in the hand-back, else an empty string (the frontend shows "Subagent")."""
    agents = [it for it in items if it.get("role") == "agent"]
    names = ent["names"]
    tools = ent["tools"]
    for it in agents:
        aid = it.pop("_aid", "")
        tname = it.pop("_tname", "")
        it["agentName"] = names.get(aid) or tname or ""
        if not it.get("notice"):  # subagent hand-back: match the tool call that dispatched it; an empty string if none (the frontend attaches the nearest tool label)
            it["forTool"] = tools.get(aid, "")


# Over-long lines when paging: a line with an inline large image can be tens of MiB, and json.loads of the whole line would parse the base64 into a Python string too,
# a memory peak several times the line length (the container has only 96 MiB). For lines over BIG_LINE, "data":"<base64>" is first replaced with an empty string before parsing (text, image count,
# and line fingerprint stay as is - the fingerprint is computed on the original line); lines over PAGE_LINE_MAX are neither joined nor emitted (dropped while reading)
BIG_LINE = 1 * 2**20
PAGE_LINE_MAX = 16 * 2**20  # peak of joining is about 2x; the 96 MiB container needs margin
_B64_DATA_RE = re.compile(rb'"data"\s*:\s*"[A-Za-z0-9+/=\\]{256,}"')


def _slim(line: bytes) -> bytes:
    return _B64_DATA_RE.sub(b'"data":""', line) if len(line) > BIG_LINE and b'"data"' in line else line


def read_page(path: str, before: Optional[int], limit: int = 30, closed: bool = False, side: bool = False,
              roots: Optional["files.Roots"] = None, stat: Optional[Callable[[str], Any]] = None) -> dict:
    """Read one page backwards. With closed=True (session exited) every ask is answered and no tool is pending. before is a byte offset (exclusive), None means end of file; the returned next is the start offset of this page."""
    collected = []  # type: List[Dict[str, Any]]  # reverse order
    seen = {}  # type: Dict[str, Optional[Dict[str, str]]]  # tool_results seen while reading backwards (answers are used only on the first page)
    notes = {}  # type: Dict[str, Dict[str, str]]  # notes of questions (toolUseResult.annotations[question].notes)
    bad = []  # type: List[Tuple[str, str]]  # lines whose structure is not understood (formatWarn)
    marks = {}  # type: Dict[str, Dict[str, bool]]  # tool result errored / dispatched in background, scanned on every page (pairs across page boundaries are missed)
    counted = 0
    next_cursor = None  # type: Optional[int]
    ent = file_index(path)  # cross-page small index (scanned first; reading a page only looks up tables)
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        pos = size if before is None else max(0, min(before, size))
        pending = []  # type: List[bytes]  # fragments before the line start is found (reversed); a long line is joined once, after its start is found
        pend_n = 0  # cumulative bytes of pending; beyond PAGE_LINE_MAX stop collecting and drop this whole line
        over = False
        done = False
        while pos > 0 and not done:
            start = max(0, pos - CHUNK)
            f.seek(start)
            data = f.read(pos - start)
            pos = start
            pieces = data.split(b"\n")
            if len(pieces) == 1 and start > 0:
                pend_n += len(data)
                if pend_n > PAGE_LINE_MAX:
                    over, pending = True, []
                elif not over:
                    pending.append(data)  # the whole chunk lies in the middle of one line
                continue
            offsets = []
            off = start
            for p in pieces:
                offsets.append(off)
                off += len(p) + 1
            last = len(pieces) - 1
            for idx in range(last, 0 if start > 0 else -1, -1):
                line = pieces[idx]
                if idx == last and (pending or over):
                    if over or len(line) + pend_n > PAGE_LINE_MAX:
                        line = b""  # over-long line is not emitted at all
                    elif line.startswith(_SKIP_PREFIXES) and not line.startswith(_QUEUE_ENQ):
                        line = b""  # long lines of skipped types are not joined (queued messages are shown, so they are joined)
                    else:
                        pending.append(line)
                        pending.reverse()
                        line = b"".join(pending)  # join once (join first then + would make an extra copy of the whole line)
                    pending, pend_n, over = [], 0, False
                fp_line = line[:files.FP_HEAD] if len(line) > BIG_LINE else line  # line fingerprint is over the original line head
                line = _slim(line)
                if b'"type":"tool_result"' in line:
                    _scan_result(line, seen, marks, notes)
                if not side and line.startswith(_QUEUE_ENQ):  # queued message (read receipt / recall)
                    qi = queue_item(line, offsets[idx], ent)
                    items = [qi] if qi else []
                else:
                    items = _convert(line, side, bad)
                    if not side:
                        for it in items:
                            if it["role"] == "user":
                                it["read"] = True  # a regular user line = Claude Code has read it
                if not items:
                    continue
                for it in items:  # user inline images: ref = line-start offset:image index:line fingerprint
                    imgs = it.pop("_img", None) or []
                    fp = files.line_fp(fp_line) if imgs else ""
                    for i, mime in imgs:
                        # n = image index; the frontend composes the label per UI language ("Image N" etc.); name keeps the Simplified wording as a fallback
                        it.setdefault("files", []).insert(i - 1, {
                            "ref": "%d:%d:%s" % (offsets[idx], i, fp), "n": i, "name": "图片 %d" % i,
                            "kind": "image", "src": "upload", "mime": mime})
                for it in items:  # tool label badge: result errored, background dispatch waits for the task notification; if not on this page, look up the cross-page index
                    if it["role"] != "tool":
                        continue
                    tid = it.get("toolUseId") or ""
                    mk = marks.get(tid) or ent["marks"].get(tid)
                    if mk:
                        if mk["err"]:
                            it["isError"] = True
                        if mk["bg"]:
                            it["bg"] = True
                    task = ent["tasks"].get(tid)
                    if task:
                        it["task"] = task  # latest background task state (the notification may be on another page, or recorded only in the queue record)
                if before is not None or closed:  # old page / off duty: all count as answered; find the answer on this page or in the index
                    for it in items:
                        if it["role"] == "ask":
                            tid = it.get("toolUseId") or ""
                            it["answers"] = seen.get(tid) or ent["answers"].get(tid)
                            nt = notes.get(tid) or ent["notes"].get(tid)
                            if nt:
                                it["notes"] = nt
                if before is None and not closed:
                    for it in items:
                        tid = it.get("toolUseId")
                        if it["role"] == "ask":
                            it["answered"] = tid in seen
                            it["answers"] = seen.get(tid)
                            if tid in notes:
                                it["notes"] = notes[tid]
                        elif it["role"] == "tool":
                            it["pending"] = bool(tid) and tid not in seen
                collected.extend(reversed(items))
                counted += sum(1 for i in items if i["role"] != "tool")
                if counted >= limit:
                    next_cursor = offsets[idx]
                    done = True
                    break
            if not done and start > 0:
                pending = [pieces[0]]  # the first piece may be a half-line
                pend_n = len(pieces[0])
    if next_cursor == 0:
        next_cursor = None
    collected.reverse()
    attach_open_files(collected)  # open files are attached by turn to the last text of this turn
    _name_agents(ent, collected)
    _attach_agents(path, ent, collected)
    _finish_files(collected, roots, stat)
    page = {"items": collected, "next": next_cursor}  # type: Dict[str, Any]
    warn = format_warn(bad)
    if warn:
        page["formatWarn"] = warn  # admin only: the server drops it for guests (_guest_files)
    return page


# ---------- Subagents: Agent tool items carry an agent field ----------
# Sources: <record-named dir>/subagents/agent-<id>.meta.json (toolUseId maps back to the dispatching tool call) and agent-<id>.jsonl (the subagent's own record).
# All streamed, memory bounded: the meta directory is cached per record for 10 s (at most META_FILES); a subagent record is read only at the head of its first line (dispatch time, task) and the last
# TAIL bytes (last step, end time); tokens are scanned incrementally per file (_agent_cache, at most AGENT_CACHE).
AGENT_TOOLS = ("Agent", "Task")
AGENT_ID_RE = re.compile(r"^[0-9a-f]{8,32}$")
META_TTL = 10.0
META_FILES = 16
META_MAX = 16 * 1024
AGENT_CACHE = 200
TAIL = 6 * 1024
TAIL_MAX = 64 * 1024
HEAD_MAX = 64 * 1024
GONE_SEC = 30 * 60
MAX_TASK = 80
MAX_STEP = 60
_meta_cache = OrderedDict()  # type: OrderedDict  # record path -> (time, {toolUseId: meta+id})
_agent_cache = OrderedDict()  # type: OrderedDict  # subagent record path -> {offset, size, sums, last, head}
_agent_lock = threading.Lock()
_SENT_END = re.compile(r"[。！？!?\n]|\.(?:\s|$)")
_TASK_DONE = {"completed": "done", "stopped": "done", "failed": "failed", "killed": "failed", "error": "failed",
              "running": "running"}


_MD_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
_MD_LEAD = re.compile(r"(?m)^[ \t]*(?:#{1,6}[ \t]*|>+[ \t]*|[-*+][ \t]+)")
# skip boilerplate lead-in sentences such as a project header or a "read X first" line
_TASK_SKIP = ("项目：", "项目:", "规矩", "先读")
_TASK_MIN = 8


def strip_md(text: Any) -> str:
    """Strip common Markdown marks (bold **, backticks, leading # > list markers, link syntax keeping only the text) and collapse whitespace."""
    t = str(text or "")
    t = _MD_LINK.sub(r"\1", t)
    t = _MD_LEAD.sub("", t)
    t = t.replace("**", "").replace("`", "")
    return " ".join(t.split())


def _sentences(t: str) -> List[str]:
    out, pos = [], 0
    for m in _SENT_END.finditer(t):
        seg = t[pos:m.end()].strip()
        if seg:
            out.append(seg)
        pos = m.end()
    tail = t[pos:].strip()
    if tail:
        out.append(tail)
    return out


def first_sentence(text: Any) -> str:
    """The "one-sentence task" of a dispatch prompt: strip Markdown first, then take the first sentence that does not start with a _TASK_SKIP prefix and has length >= 8 (including its end punctuation);
    if none, use the original first sentence; at most MAX_TASK chars. A newline also ends a sentence, so split by line first and then by punctuation."""
    raw = str(text or "").strip()
    if not raw:
        return ""
    sents = []  # type: List[str]
    for ln in raw.split("\n"):
        sents.extend(_sentences(strip_md(ln)))
    if not sents:
        return ""
    for s in sents:
        if len(s) >= _TASK_MIN and not s.startswith(_TASK_SKIP):
            return s[:MAX_TASK]
    return sents[0][:MAX_TASK]


def subagent_dir(path: str) -> str:
    base = path[:-6] if path.endswith(".jsonl") else path
    return os.path.join(base, "subagents")


def agent_metas(path: str, now: Optional[float] = None) -> Dict[str, Dict[str, Any]]:
    """toolUseId -> meta (with id = agentId). One listdir, cached per record for META_TTL seconds."""
    now = time.time() if now is None else now
    with _agent_lock:
        hit = _meta_cache.get(path)
        if hit and now - hit[0] < META_TTL:
            return hit[1]
    d = subagent_dir(path)
    out = {}  # type: Dict[str, Dict[str, Any]]
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    for n in names:
        if not (n.startswith("agent-") and n.endswith(".meta.json")):
            continue
        aid = n[6:-10]
        if not AGENT_ID_RE.match(aid):
            continue
        try:
            with open(os.path.join(d, n), "rb") as f:
                raw = f.read(META_MAX + 1)
            if len(raw) > META_MAX:
                continue
            m = json.loads(raw)
        except (OSError, ValueError):
            continue
        if isinstance(m, dict) and isinstance(m.get("toolUseId"), str):
            m["id"] = aid
            out[m["toolUseId"]] = m
    with _agent_lock:
        _meta_cache[path] = (now, out)
        _meta_cache.move_to_end(path)
        while len(_meta_cache) > META_FILES:
            _meta_cache.popitem(last=False)
    return out


def _agent_ent(apath: str) -> Dict[str, Any]:
    ent = _agent_cache.pop(apath, None)
    if ent is None:
        ent = {"offset": 0, "size": 0, "sums": 0, "last": None, "head": None}
    _agent_cache[apath] = ent
    while len(_agent_cache) > AGENT_CACHE:
        _agent_cache.popitem(last=False)
    return ent


def agent_tokens(apath: str) -> int:
    """Cumulative tokens of a subagent record (input + output). If the file grew, read only the new part; if it shrank, rescan."""
    try:
        size = os.path.getsize(apath)
    except OSError:
        return 0
    with _agent_lock:
        ent = _agent_ent(apath)
        if size < ent["size"] or size < ent["offset"]:
            ent.update(offset=0, sums=0, last=None, head=None)
        ent["size"] = size
        if size > ent["offset"]:
            try:
                with open(apath, "rb") as f:
                    _scan_tokens(f, ent, size)
            except OSError:
                pass
        return ent["sums"]


def _agent_head(apath: str) -> Dict[str, str]:
    """First line (the task at dispatch): startedAt and the first sentence of the task. Reads only the head HEAD_MAX bytes, result cached (the first line never changes)."""
    with _agent_lock:
        ent = _agent_ent(apath)
        if ent.get("head") is not None:
            return ent["head"]
    out = {"startedAt": "", "task": ""}
    try:
        with open(apath, "rb") as f:
            raw = f.readline(HEAD_MAX)
    except OSError:
        raw = b""
    if raw.endswith(b"\n"):
        try:
            obj = json.loads(raw)
        except ValueError:
            obj = None
        if isinstance(obj, dict):
            out["startedAt"] = str(obj.get("timestamp") or "")
            msg = obj.get("message")
            c = msg.get("content") if isinstance(msg, dict) else None
            out["task"] = first_sentence(c if isinstance(c, str) else _user_text(c))
    elif raw:
        m = _TS.search(raw)
        out["startedAt"] = m.group(1).decode("utf-8", "replace") if m else ""
    if raw:
        with _agent_lock:
            _agent_ent(apath)["head"] = out
    return out


def _tail_objs(apath: str, size: int, want: int) -> List[Dict[str, Any]]:
    """Read the complete lines within the last want bytes (from back to front)."""
    start = max(0, size - want)
    try:
        with open(apath, "rb") as f:
            f.seek(start)
            data = f.read(size - start)
    except OSError:
        return []
    lines = data.split(b"\n")
    if start > 0:
        lines = lines[1:]  # the first piece is a half-line
    out = []
    for ln in reversed(lines):
        ln = ln.strip()
        if not ln.startswith(b"{"):
            continue
        try:
            obj = json.loads(ln)
        except ValueError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def _step_of(obj: Dict[str, Any]) -> Optional[str]:
    """assistant line -> latest step: the summary of the tool_use if there is one, otherwise the first MAX_STEP chars of text."""
    msg = obj.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        return None
    for b in reversed(content):
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_use":
            return _summarize_tool(str(b.get("name", "")), b.get("input"))
        if b.get("type") == "text" and str(b.get("text", "")).strip():
            return strip_md(b["text"])[:MAX_STEP]
    return None


def _agent_tail(apath: str, size: int) -> Dict[str, Any]:
    """Tail: latest step, SubagentStop time, last-line time. Read TAIL first; if no assistant line is found, enlarge to TAIL_MAX."""
    out = {"lastStep": "", "stopAt": "", "lastTs": ""}  # type: Dict[str, Any]
    for want in (TAIL, TAIL_MAX):
        objs = _tail_objs(apath, size, want)
        out["lastTs"] = str(objs[0].get("timestamp") or "") if objs else ""
        for o in objs:
            a = o.get("attachment")
            if not out["stopAt"] and isinstance(a, dict) and a.get("hookName") == "SubagentStop":
                out["stopAt"] = str(o.get("timestamp") or "")
            if o.get("type") == "assistant":
                step = _step_of(o)
                if step:
                    out["lastStep"] = step
                    return out
        if size <= want:
            break
    return out


def agent_info(path: str, meta: Dict[str, Any], inp: Optional[Dict[str, str]] = None,
               task_state: str = "", note: str = "", now: Optional[float] = None) -> Optional[Dict[str, Any]]:
    """Info header of one subagent. state: the task notification first, then meta.finished, otherwise running; running but idle for 30 minutes counts as gone."""
    aid = str(meta.get("id") or "")
    if not AGENT_ID_RE.match(aid):
        return None
    now = time.time() if now is None else now
    inp = inp or {}
    apath = os.path.join(subagent_dir(path), "agent-%s.jsonl" % aid)
    try:
        stt = os.stat(apath)
        size, mtime = stt.st_size, stt.st_mtime
    except OSError:
        size, mtime = 0, None
    head = _agent_head(apath) if size else {"startedAt": "", "task": ""}
    tail = _agent_tail(apath, size) if size else {"lastStep": "", "stopAt": "", "lastTs": ""}
    state = _TASK_DONE.get(task_state or "")
    if state is None or state == "running":
        state = "done" if meta.get("finished") is True and state is None else "running"
    if state == "running" and mtime is not None and now - mtime > GONE_SEC:
        state = "gone"
    ended = None
    if state in ("done", "failed"):
        ended = tail["stopAt"] or tail["lastTs"] or None
    step = tail["lastStep"]
    if state == "failed" and note:
        step = strip_md(note)[:MAX_STEP]
    return {
        "id": aid,
        "description": str(meta.get("description") or inp.get("description") or "")[:MAX_AGENT_NAME],
        "model": str(meta.get("model") or inp.get("model") or ""),
        "agentType": str(meta.get("agentType") or inp.get("agentType") or ""),
        "task": inp.get("task") or head["task"],
        "state": state,
        "startedAt": head["startedAt"] or None,
        "lastAt": mtime,
        "endedAt": ended,
        "lastStep": step,
        "tokens": agent_tokens(apath) if size else 0,
    }


def _attach_agents(path: str, ent: Dict[str, Any], items: List[Dict[str, Any]]) -> None:
    """Agent/Task tool items: add the agent field if toolUseId matches a meta; the _agent input is always removed."""
    calls = [it for it in items if it.get("role") == "tool" and "_agent" in it]
    if not calls:
        return
    metas = agent_metas(path)
    notes = {}  # type: Dict[str, str]
    states = {}  # type: Dict[str, str]
    for it in items:
        if it.get("notice") and it.get("forTool"):
            notes[it["forTool"]] = it.get("text") or ""
            states[it["forTool"]] = it.get("task") or ""
    for it in calls:
        inp = it.pop("_agent")
        tid = it.get("toolUseId") or ""
        meta = metas.get(tid)
        if not meta:
            continue
        task = it.get("task") or ent["tasks"].get(tid) or states.get(tid) or ""
        info = agent_info(path, meta, inp, task, notes.get(tid, ""))
        if info:
            it["agent"] = info


def agent_page(path: str, aid: str, before: Optional[int], limit: int = 30,
               roots: Optional["files.Roots"] = None) -> Optional[dict]:
    """Page through a subagent's own record like read_page, plus the agent info header; returns None if agentId is invalid or the file is not under sid/subagents."""
    if not isinstance(aid, str) or not AGENT_ID_RE.match(aid):
        return None
    d = os.path.realpath(subagent_dir(path))
    apath = os.path.realpath(os.path.join(d, "agent-%s.jsonl" % aid))
    if not apath.startswith(d + os.sep) or not os.path.isfile(apath):
        return None
    meta = None
    for m in agent_metas(path).values():
        if m.get("id") == aid:
            meta = m
            break
    if meta is None:
        meta = {"id": aid}
        try:
            with open(os.path.join(d, "agent-%s.meta.json" % aid), "rb") as f:
                raw = f.read(META_MAX + 1)
            if len(raw) <= META_MAX:
                m = json.loads(raw)
                if isinstance(m, dict):
                    meta = dict(m, id=aid)
        except (OSError, ValueError):
            pass
    tid = str(meta.get("toolUseId") or "")
    task = file_index(path)["tasks"].get(tid, "") if tid else ""
    info = agent_info(path, meta, None, task)
    page = read_page(apath, before, limit, closed=bool(info and info["state"] != "running"), side=True, roots=roots)
    page["agent"] = info
    return page
