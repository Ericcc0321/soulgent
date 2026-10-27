"""Claude Code transcript (JSONL) format knowledge: line prefixes, raw keys (type / message / content / toolUseResult / usage ...)
and the parsers that read them directly. transcript.py imports these names; this module never imports transcript.py.

_convert, _user_text and queue_item stay in transcript.py on purpose: they mix format reading with the turn-origin rules
(classify_user_text), so moving them here would need a circular import."""
import json
import os
import re
from collections import OrderedDict
from typing import Any, Dict, List, Optional, Tuple

MAX_SUMMARY = 80
_SKIP_PREFIXES = tuple(
    b'{"type":"' + t for t in (
        b"api-request", b"attachment", b"system", b"file-history-snapshot",
        b'mode"', b'permission-mode"', b'last-prompt"', b'custom-title"',
        b'agent-name"', b'atis-latch"', b'queue-operation"',
    )
)
MAX_RESULT_PARSE = 256 * 1024  # tool_result lines larger than this are not parsed; only the id is taken
_RESULT_ID = re.compile(rb'"tool_use_id": ?"([^"]+)"')
_IS_ERROR = b'"is_error":true'
MAX_AGENT_NAME = 60
LINE_CAP = MAX_RESULT_PARSE
INDEX_CAP = 2000
ANSWERS_CAP = 200
MAX_ANSWER_Q = 300
MAX_ANSWER = 1000
_NOTE_HEAD = re.compile(rb'"(?:content|prompt)": ?"<task-notification>')
_NOTE_TASK = re.compile(rb"<task-id>\s*([^<]*?)\s*</task-id>")
_NOTE_TOOL = re.compile(rb"<tool-use-id>\s*([^<]*?)\s*</tool-use-id>")
_NOTE_STATUS = re.compile(rb"<status>\s*([A-Za-z_]+)\s*</status>")
_QUEUE_ENQ = b'{"type":"queue-operation","operation":"enqueue"'
# ---------- Fate of queued messages (read receipt / recall) ----------
# Observed in a test terminal (Claude Code 2.1.308): a message sent while the session is busy is first logged as queue-operation enqueue (with the original text). Afterwards:
#   remove (reason=absorbed_mid_turn / delivered_to_agent / none) = absorbed mid-turn, no regular user line will follow -> read
#   dequeue (no original text, FIFO) = handled after the turn ends, a regular user line follows -> the queued copy is no longer shown
#   popAll (with original text, one per line) = pulled back to the input box with Up for editing (our "recall") -> recalled; if the same text is sent back later (re-queued or as a regular user line) it counts as never recalled and the old copy is hidden
# qpend: [enqueue line start, text key] still in the queue; qfate: enqueue line start -> sent / read / dequeued / recalled / hidden; qback: the most recently pulled-back [start, text key]
QUEUE_PEND_CAP = 200
QUEUE_BACK_CAP = 20
_QUEUE_OP = b'{"type":"queue-operation"'
_API_ERR_PREFIX = re.compile(r"^\s*API Error:\s*", re.I)
_API_ERR_MAX = 300
TOK_TAIL = 16 * 1024
_TS = re.compile(rb'"timestamp": ?"([^"]+)"')
_ROLE_ASST = re.compile(rb'"role": ?"assistant"')
_MSG_ID = re.compile(rb'"message": ?\{[^{}]*?"id": ?"([^"]+)"')
_USAGE = re.compile(rb'"usage": ?\{"input_tokens": ?(\d+)[^{}]*?"output_tokens": ?(\d+)')



def _put(d: "OrderedDict", k: str, v: Any, cap: int = 0) -> None:
    d[k] = v
    d.move_to_end(k)
    while len(d) > (cap or INDEX_CAP):
        d.popitem(last=False)


def _qkey(text: Any) -> str:
    return str(text or "")[:200]


def _queue_line(ent: Dict[str, Any], head: bytes, full: bool, start: int) -> None:
    if head.startswith(_QUEUE_OP):
        if not full:
            if head.startswith(_QUEUE_ENQ):  # over-long text: only occupies a queue slot (dequeue is FIFO and must count correctly)
                ent["qpend"].append([start, None])
                _put(ent["qfate"], str(start), "sent")
            return
        try:
            obj = json.loads(head)
        except ValueError:
            return
        if not isinstance(obj, dict):
            return
        op = obj.get("operation")
        key = _qkey(obj.get("content"))
        pend = ent["qpend"]
        if op == "enqueue":
            _queue_back_hit(ent, key)
            pend.append([start, key])
            del pend[:-QUEUE_PEND_CAP]
            _put(ent["qfate"], str(start), "sent")
        elif op == "dequeue":
            if pend:
                _put(ent["qfate"], str(pend.pop(0)[0]), "dequeued")
        elif op in ("remove", "popAll"):
            for i, (s, k) in enumerate(pend):
                if k == key:
                    pend.pop(i)
                    if op == "popAll":
                        _put(ent["qfate"], str(s), "recalled")
                        ent["qback"].append([s, key])
                        del ent["qback"][:-QUEUE_BACK_CAP]
                    else:
                        _put(ent["qfate"], str(s), "read")
                    break
        return
    if ent["qback"] and full and re.match(rb'\{[^{]*?"type": ?"user"', head) and b'"tool_result"' not in head:
        try:
            obj = json.loads(head)
        except ValueError:
            return
        msg = obj.get("message") if isinstance(obj, dict) else None
        if isinstance(msg, dict) and isinstance(msg.get("content"), str):
            _queue_back_hit(ent, _qkey(msg["content"]))


def _queue_back_hit(ent: Dict[str, Any], key: str) -> None:
    """The pulled-back text was sent again: the old copy does not count as recalled and is hidden."""
    for i, (s, k) in enumerate(ent["qback"]):
        if k == key:
            ent["qback"].pop(i)
            _put(ent["qfate"], str(s), "hidden")
            return


def _index_line(ent: Dict[str, Any], head: bytes, full: bool, err: bool) -> None:
    """One line -> update the index. Only tool-result lines and task-notification lines are looked at; nothing else is parsed."""
    if b'"tool_result"' in head:
        ids = _RESULT_ID.findall(head)
        if not ids:
            return
        if not full:  # large line not parsed: with a single tool, judge the error by the literal
            if len(ids) == 1 and err:
                k = ids[0].decode("utf-8", "replace")
                _put(ent["marks"], k, {"err": True, "bg": False})
            return
        try:
            obj = json.loads(head)
        except ValueError:
            return
        if not isinstance(obj, dict):
            return
        msg = obj.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        errs = set()
        for b in content if isinstance(content, list) else []:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error") is True:
                errs.add(str(b.get("tool_use_id", "")))
        tur = obj.get("toolUseResult")
        bg = False
        if isinstance(tur, dict) and len(ids) == 1:
            tid = ids[0].decode("utf-8", "replace")
            bg = tur.get("isAsync") is True or tur.get("status") == "async_launched" or bool(tur.get("backgroundTaskId"))
            if isinstance(tur.get("answers"), dict):
                _put(ent["answers"], tid, {str(k)[:MAX_ANSWER_Q]: str(v)[:MAX_ANSWER] for k, v in list(tur["answers"].items())[:8]},
                     ANSWERS_CAP)
                nt = _ask_notes(tur)
                if nt:
                    _put(ent["notes"], tid, nt, ANSWERS_CAP)
            if isinstance(tur.get("backgroundTaskId"), str):
                _put(ent["bgids"], tur["backgroundTaskId"], tid)
            if isinstance(tur.get("agentId"), str) and isinstance(tur.get("description"), str):
                _put(ent["names"], tur["agentId"], tur["description"].strip()[:MAX_AGENT_NAME])
                _put(ent["tools"], tur["agentId"], tid)
            # A background task stopped by the model via TaskStop has no task-notification, only the TaskStop result {task_id, task_type};
            # map it back through bgids (background commands) / tools (background subagents) to the tool call that started it and record stopped. A TaskStop that itself errored does not count
            if isinstance(tur.get("task_id"), str) and tur.get("task_type") and tid not in errs:
                target = ent["bgids"].get(tur["task_id"]) or ent["tools"].get(tur["task_id"])
                if target:
                    _put(ent["tasks"], target, "stopped")
        for raw in ids:
            k = raw.decode("utf-8", "replace")
            if k in errs or bg:
                _put(ent["marks"], k, {"err": k in errs, "bg": bg})
        return
    m = _NOTE_HEAD.search(head)
    if not m:
        return
    # Only two kinds of real notifications count: queue records (inserted while the session is busy; only enqueue is recorded, they do not become user messages) and user messages themselves
    if not (head.startswith(_QUEUE_ENQ) or re.search(rb'"type": ?"user"', head)):
        return
    seg = head[m.start():m.start() + 4096]
    st = _NOTE_STATUS.search(seg)
    if not st:
        return
    tt = _NOTE_TOOL.search(seg)
    tid = tt.group(1).decode("utf-8", "replace") if tt else ""
    if not tid:
        tk = _NOTE_TASK.search(seg)
        key = tk.group(1).decode("utf-8", "replace") if tk else ""
        tid = ent["bgids"].get(key) or ent["tools"].get(key) or ""
    if tid:
        _put(ent["tasks"], tid, st.group(1).decode("ascii", "replace").lower())


def _summarize_tool(name: str, inp: Any) -> str:
    inp = inp if isinstance(inp, dict) else {}
    detail = ""
    if name == "Bash":
        detail = str(inp.get("description") or "")
        if not detail:
            detail = (str(inp.get("command") or "").strip().splitlines() or [""])[0]
    elif name in ("Read", "Edit", "Write"):
        detail = os.path.basename(str(inp.get("file_path") or ""))
    elif name in ("Agent", "Task"):  # dispatching a subagent: carry the task name, so the expanded tool label shows who was dispatched
        detail = str(inp.get("description") or "")
    text = (name + " " + detail).strip() if detail else name
    return text[:MAX_SUMMARY]


def _ask_text(inp: Any) -> str:
    parts = []  # type: List[str]
    questions = inp.get("questions") if isinstance(inp, dict) else None
    for q in questions if isinstance(questions, list) else []:
        if not isinstance(q, dict):
            continue
        labels = [str(o.get("label", "")) for o in q.get("options") or [] if isinstance(o, dict)]
        line = str(q.get("question", ""))
        if labels:
            line += "（" + " / ".join(labels) + "）"
        parts.append(line)
    return "\n".join(parts)


def _ask_questions(inp: Any) -> List[Dict[str, Any]]:
    out = []  # type: List[Dict[str, Any]]
    questions = inp.get("questions") if isinstance(inp, dict) else None
    for q in questions if isinstance(questions, list) else []:
        if not isinstance(q, dict):
            continue
        opts = [o for o in q.get("options") or [] if isinstance(o, dict)]
        it = {
            "question": str(q.get("question", "")),
            "header": str(q.get("header", "")),
            "multiSelect": q.get("multiSelect") is True,
            "options": [str(o.get("label", "")) for o in opts],
            "descs": [str(o.get("description", ""))[:300] for o in opts],
        }  # type: Dict[str, Any]
        # For a single-choice question where any option has a preview, Claude Code (verified in the 2.1.310 source) switches to a "list on the left, preview on the right" UI:
        # number keys only move the cursor, Enter selects, and there is no line to fill in yourself (n writes a note). The frontend changes its keys accordingly; the preview text is not sent out.
        if not it["multiSelect"] and any("preview" in o for o in opts):
            it["preview"] = True
        out.append(it)
    return out


def _ask_notes(tur: Dict[str, Any]) -> Optional[Dict[str, str]]:
    """toolUseResult.annotations -> {question: note} (the note the user wrote with n on a preview question). None if there are no notes."""
    raw = tur.get("annotations")
    if not isinstance(raw, dict):
        return None
    out = {}  # type: Dict[str, str]
    for k, v in list(raw.items())[:8]:
        n = v.get("notes") if isinstance(v, dict) else None
        if isinstance(n, str) and n.strip():
            out[str(k)[:MAX_ANSWER_Q]] = n.strip()[:MAX_ANSWER]
    return out or None


def _scan_result(line: bytes, seen: Dict[str, Optional[Dict[str, str]]], marks: Dict[str, Dict[str, bool]],
                 notes: Optional[Dict[str, Dict[str, str]]] = None) -> None:
    """tool_result line: take tool_use_id by regex; toolUseResult.answers is parsed only for small lines, nothing else is taken.
    marks records per tool: err = the result has is_error; bg = dispatched in background (async subagent / background command), which only counts as done after the task notification."""
    ids = _RESULT_ID.findall(line)
    if not ids:
        return
    answers = None  # type: Optional[Dict[str, str]]
    errs = set()  # type: set
    bg = False
    if len(line) < MAX_RESULT_PARSE:
        try:
            obj = json.loads(line)
        except ValueError:
            obj = None
        content = obj.get("message", {}).get("content") if isinstance(obj, dict) and isinstance(obj.get("message"), dict) else None
        for b in content if isinstance(content, list) else []:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error") is True:
                errs.add(str(b.get("tool_use_id", "")))
        tur = obj.get("toolUseResult") if isinstance(obj, dict) else None
        if isinstance(tur, dict) and len(ids) == 1:
            raw = tur.get("answers")
            if isinstance(raw, dict):
                answers = {str(k): str(v) for k, v in raw.items()}
                nt = _ask_notes(tur)
                if nt and notes is not None:
                    notes[ids[0].decode("utf-8", "replace")] = nt
            bg = tur.get("isAsync") is True or tur.get("status") == "async_launched" or bool(tur.get("backgroundTaskId"))
    elif len(ids) == 1 and _IS_ERROR in line:  # large line not parsed: with a single tool, judge the error by the literal
        errs.add(ids[0].decode("utf-8", "replace"))
    for tid in ids:
        k = tid.decode("utf-8", "replace")
        seen[k] = answers
        marks[k] = {"err": k in errs, "bg": bg}


def _scan_tokens(f, ent: Dict[str, Any], end: int) -> None:
    """Scan line by line from ent.offset to end: for assistant lines accumulate usage.input_tokens + output_tokens (cache excluded).
    The line head (<= LINE_CAP) decides the role and message id; usage is looked for in the last TOK_TAIL bytes of the line (works for huge lines too); a message split into several lines counts only the last copy."""
    f.seek(ent["offset"])
    pos = ent["offset"]
    while pos < end:
        piece = f.readline(min(LINE_CAP, end - pos))
        if not piece:
            return
        head = piece[:2048]
        tail = piece[-TOK_TAIL:]
        n = len(piece)
        while not piece.endswith(b"\n") and pos + n < end:
            piece = f.readline(min(LINE_CAP, end - pos - n))
            if not piece:
                break
            tail = (tail + piece)[-TOK_TAIL:]
            n += len(piece)
        if not piece.endswith(b"\n"):
            return  # half-line: read next time
        pos += n
        ent["offset"] = pos
        if not _ROLE_ASST.search(head):
            continue
        um = _USAGE.search(tail)
        if not um:
            continue
        val = int(um.group(1)) + int(um.group(2))
        mm = _MSG_ID.search(head)
        mid = mm.group(1) if mm else None
        last = ent["last"]
        if mid and last and last[0] == mid:
            ent["sums"] -= last[1]
        ent["sums"] += val
        ent["last"] = (mid, val)


# ---------- Structural check: does this line still look like the format we read? ----------
# Only structure counts, never the version string: a new CC version with the same shape is fine.
# A "content-bearing" line is one that carries a message object; metadata lines (attachment, mode, ai-title ...) have none,
# and new metadata types appear often, so they are never counted.
CONTENT_TYPES = ("user", "assistant")
MAX_WARN = 160


def check_line(obj: Any) -> Optional[str]:
    """Parsed JSONL line -> short English reason if its structure is not understood, else None."""
    if not isinstance(obj, dict) or "message" not in obj:
        return None
    kind = obj.get("type")
    if kind not in CONTENT_TYPES:
        return "unknown type %r on a message line" % (str(kind)[:40],)
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return "%s line without a message object" % kind
    if "content" not in msg:
        return "%s message without content" % kind
    content = msg["content"]
    if kind == "assistant" and not isinstance(content, list):
        return "assistant content is not a list"
    if not isinstance(content, (str, list)):
        return "user content is neither text nor a list"
    if isinstance(content, list) and any(not isinstance(b, dict) or not isinstance(b.get("type"), str) for b in content):
        return "%s content block without a type" % kind
    return None


def format_warn(bad: List[Tuple[str, str]]) -> Optional[str]:
    """[(reason, version)] collected on one page -> one short English line for the client, None when empty."""
    if not bad:
        return None
    reason, ver = bad[0]
    s = "%d line(s) not understood, e.g. %s" % (len(bad), reason)
    if ver:
        s += " (Claude Code %s)" % ver
    return s[:MAX_WARN]
