"""Helper outbox worker: takes data/outbox/*.req.json, executes them with orca terminal send/read, writes back *.res.json.

Only runs orca send/read, with arguments passed as a list, never through a shell. Looks up session -> pid -> terminal handle
fresh before every run; nothing is cached.
"""

import glob
import hashlib
import hmac
import json
import math
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime
from typing import Dict, List, Optional

from helper import settings
from helper.cc_screen import (_ANSI_RE, _MENU_HINTS, _MENU_OPT_RE, MENU_TAIL, input_box,  # noqa: F401  (re-exported)
                              menu_on_screen, strip_ansi)
from helper import cc_screen
from helper.orca_cli import ORCA_BIN, ORCA_PATHS, ORCA_TIMEOUT, _orca_json  # noqa: F401  (re-exported)
from helper import orca_cli

REQUEST_TTL = 30        # requests older than this are discarded (the api has already judged helper-timeout)
RESULT_TTL = 600        # how long result files are kept
MAX_TEXT = 4000
MAX_STEPS = 24
UPLOAD_TTL = 7 * 86400  # files in data/uploads are kept for 7 days
IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".bmp")
STEP_DELAY = 0.15       # pause between steps and between text and Enter (0.15 s leaves a safety margin so consecutive answers are not dropped)
PASTE_DELAY = 0.35      # image sending: pause between paste chunks, giving Claude Code time to turn a paste into [Image #N]
SCREEN_LINES = 30
WAKE_TIMEOUT = 120      # max wait for the wake command before killing it (the api-side WAKE_HELPER_TIMEOUT = 150 must be longer)
HOME = os.path.expanduser("~")
WEBAPP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_CLAUDE = settings.claude_paths()  # session registry, transcripts and roster live under ~/.claude (each overridable by env var)
ROSTER_PATH = _CLAUDE["roster"]
OFFDUTY_DEFAULT = ""  # optional extension: without it there is no wake/off-duty


def offduty_script(env=None, webapp: str = WEBAPP) -> str:
    """Path of the wake/off-duty script (optional extension, supplied by the user, not in this repo).
    In order: env SOULGENT_OFFDUTY -> SOULGENT_OFFDUTY in webapp/.env -> empty (disabled). Read once at helper startup."""
    return settings.path_setting("SOULGENT_OFFDUTY", OFFDUTY_DEFAULT, env, webapp)


WAKE_CMD = ["/usr/bin/python3", offduty_script(), "--wake"] if offduty_script() else []  # empty = no script configured
OFF_TIMEOUT = 60        # max wait for off-duty: offduty.py sends /exit, waits up to 20 s for exit, then closes the tab (the api-side OFF_HELPER_TIMEOUT = 90 must be longer)
OFF_CMD = WAKE_CMD[:-1] + ["--off"] if WAKE_CMD else []

KEYS = {
    "1": "1", "2": "2", "3": "3", "4": "4", "5": "5", "6": "6", "7": "7", "8": "8", "9": "9",
    "enter": "\r", "esc": "\x1b", "up": "\x1b[A", "down": "\x1b[B", "tab": "\t", "right": "\x1b[C",
    "n": "n",  # preview questions open the notes box with n; only this one letter is allowed
}

_CTRL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_HANDLE_RE = re.compile(r"(?:^|\s)ORCA_TERMINAL_HANDLE=(\S+)")


def find_orca() -> List[str]:
    return orca_cli.find_orca(ORCA_BIN, ORCA_PATHS)  # reads this module's ORCA_BIN / ORCA_PATHS so overrides here take effect


def menu_gate(item: dict, handle: str, orca_cmd: List[str]) -> Optional[str]:
    return cc_screen.menu_gate(item, handle, orca_cmd, _orca_json)  # passes this module's _orca_json so overrides here take effect


def _screen_input(orca_cmd: List[str], handle: str) -> Optional[str]:
    return cc_screen._screen_input(orca_cmd, handle, _orca_json)


def clean_text(text) -> Optional[str]:
    """Newlines become spaces, control characters and surrounding whitespace are removed; None if empty or too long."""
    if not isinstance(text, str):
        return None
    for nl in ("\r\n", "\n", "\r", "\u2028", "\u2029"):
        text = text.replace(nl, " ")
    text = _CTRL_RE.sub("", text)
    text = text.strip()
    if not text or len(text) > MAX_TEXT:
        return None
    return text


def clean_lines(text) -> Optional[str]:
    """Quote reply: keeps newlines (normalized to \\n), otherwise like clean_text. Only for text of requests with lines=true, delivered to the input box as one paste."""
    if not isinstance(text, str):
        return None
    for nl in ("\r\n", "\r", " ", " "):
        text = text.replace(nl, "\n")
    text = re.sub(r"[\x00-\x09\x0b-\x1f\x7f-\x9f]", "", text).strip()
    if not text or len(text) > MAX_TEXT:
        return None
    return text


def proc_comm(pid: int) -> Optional[str]:
    try:
        out = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=ORCA_TIMEOUT).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    return out.strip() or None


def is_claude_comm(comm: Optional[str]) -> bool:
    """Process name is claude, or a forked clone whose name is .../claude/versions/x.y.z."""
    return bool(comm) and (os.path.basename(comm) == "claude" or "/claude/versions/" in comm)


def proc_lstart(pid: int) -> Optional[str]:
    """Process start time (UTC, whitespace normalized), compared with procStart in the session file."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=ORCA_TIMEOUT,
                             env=dict(os.environ, TZ="UTC")).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    return " ".join(out.split()) or None


def pid_for(session_id: str, sessions_dir: str) -> Optional[int]:
    """Session id -> pid of a live process that really is claude (guards against pid reuse); when several files share an id, the one that passes validation wins."""
    for path in sorted(glob.glob(os.path.join(glob.escape(sessions_dir), "*.json"))):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict) or data.get("sessionId") != session_id:
                continue
            pid = int(os.path.basename(path)[:-5])
        except (OSError, ValueError):
            continue
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        if not is_claude_comm(proc_comm(pid)):
            continue
        start = data.get("procStart")
        if start is not None and " ".join(str(start).split()) != proc_lstart(pid):
            continue
        return pid
    return None


def terminal_handle(pid: int) -> Optional[str]:
    try:
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=ORCA_TIMEOUT).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    m = _HANDLE_RE.search(out)
    return m.group(1) if m else None


# ---------- Request/result signing (same as in api/outbox.py)----------
# The api signs every request with OUTBOX_SECRET from .env (domain req); requests that fail verification here or whose id does not match the file name are dropped unexecuted.
# Result files are signed too (domain res) and the api accepts only signed ones. Without a secret nothing is executed and helper.log reports it once a minute.
SECRET_MIN = 32
SECRET_ENV = "OUTBOX_SECRET"


class SecretMissing(OSError):
    pass


def secret(env=None) -> bytes:
    """Env var, then OUTBOX_SECRET in webapp/.env (read each time; the launchd-started helper does not load .env); b"" if unset or shorter than 32 chars."""
    s = settings.setting(SECRET_ENV, "", env)
    return s.encode("utf-8") if len(s) >= SECRET_MIN else b""


def _canon(domain: str, obj: dict) -> bytes:
    body = {k: v for k, v in obj.items() if k != "sig"}
    return (domain + "\n" + json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(",", ":"))).encode("utf-8")


def sign(domain: str, obj: dict, key: bytes) -> str:
    return hmac.new(key, _canon(domain, obj), hashlib.sha256).hexdigest()


def verify(domain: str, obj, key: bytes) -> bool:
    if not key or not isinstance(obj, dict) or not isinstance(obj.get("sig"), str):
        return False
    return hmac.compare_digest(obj["sig"], sign(domain, obj, key))


_warned = {}  # type: Dict[str, float]


def _warn_every(tag: str, msg: str, gap: float = 60.0) -> None:
    now = time.time()
    if now - _warned.get(tag, 0.0) >= gap:
        _warned[tag] = now
        _warn(msg)


def _write_atomic(path: str, obj: dict) -> None:
    """Result file: written after signing (res domain), mode 0600 for the current user only (the container can still read it through the Docker Desktop fakeowner mount)."""
    key = secret()
    if not key:
        raise SecretMissing("OUTBOX_SECRET missing")
    obj = dict(obj)
    obj["sig"] = sign("res", obj, key)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".res-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _log(log_path: str, now: float, name: str, typ: str, content: str, result: str) -> None:
    def clean(s: str) -> str:
        return _CTRL_RE.sub(" ", s)
    line = "\t".join([datetime.fromtimestamp(now).isoformat(timespec="seconds"), clean(name), clean(typ),
                      clean(content)[:200], result])
    os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def _pause(delay: float = STEP_DELAY) -> None:
    time.sleep(delay)


def _steps_payloads(steps):
    """Validate steps and return [(content to send, log summary)]; None if any step is invalid."""
    if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_STEPS:
        return None
    out = []
    for st in steps:
        if not isinstance(st, dict) or len(st) != 1:
            return None
        if "key" in st:
            key = st["key"]
            if not isinstance(key, str) or key not in KEYS:
                return None
            out.append((KEYS[key], "⏎" if key == "enter" else key, "enter" if key == "enter" else "key"))
        elif "text" in st:
            text = clean_text(st["text"])
            if text is None:
                return None
            out.append((text, text, "text"))
        else:
            return None
    return out


def _steps_summary(parts) -> str:
    """Text follows the previous step, the Enter after text follows the text, the rest are separated by " | ", e.g. `2 | 3 mango ⏎ | 1`."""
    text = ""
    prev_text = False
    for i, (_, label, kind) in enumerate(parts):
        is_text = kind == "text"
        if i == 0:
            sep = ""
        elif is_text or (kind == "enter" and prev_text):
            sep = " "
        else:
            sep = " | "
        text += sep + label
        prev_text = is_text
    return text


def _upload_path(name, uploads_dir: Optional[str]) -> Optional[str]:
    """Validate a file name under uploads and return the absolute host path; None if unsafe or not a regular file."""
    if (not uploads_dir or not isinstance(name, str) or not name or name.startswith(".")
            or name != os.path.basename(name) or "\\" in name or "\x00" in name):
        return None
    root = os.path.realpath(uploads_dir)
    full = os.path.join(root, name)
    if os.path.islink(full) or os.path.realpath(full) != full or not os.path.isfile(full):
        return None
    return full


# The prompt typed into the agent's input box when sending images/files follows the UI language of the sending phone (lang in the request: en / hans / hant);
# a missing or unknown lang falls back to Simplified Chinese. Keep tests/test_upload.py in sync when editing; api/transcript.py recognizes attachments by upload directory path,
# independent of the prompt language. The guest prefix (GUEST_TAG) is prepended by the api and is unaffected
PROMPTS = {
    "hans": {"img": "请看我从手机发来的图片：", "imgs": "请看我从手机发来的图片：",
             "file": "请看我从手机发来的文件：", "files": "请看我从手机发来的文件：",
             "att": "（附件：%s）", "cap": " （说明：%s）", "sep": "；"},
    "hant": {"img": "請看我從手機傳來的圖片：", "imgs": "請看我從手機傳來的圖片：",
             "file": "請看我從手機傳來的檔案：", "files": "請看我從手機傳來的檔案：",
             "att": "（附件：%s）", "cap": " （說明：%s）", "sep": "；"},
    "en": {"img": "Please look at the image I sent from my phone: ", "imgs": "Please look at the images I sent from my phone: ",
           "file": "Please look at the file I sent from my phone: ", "files": "Please look at the files I sent from my phone: ",
           "att": "(Attachments: %s)", "cap": " (Note: %s)", "sep": "; "},
}


def prompts(req: dict) -> dict:
    lang = req.get("lang") if isinstance(req, dict) else None
    return PROMPTS.get(lang if isinstance(lang, str) else "", PROMPTS["hans"])


def file_sentence(req: dict, uploads_dir: Optional[str]) -> Optional[str]:
    """file request -> the sentence to send to the session; None if the file is not under uploads or is not a regular file."""
    name = req.get("file")
    full = _upload_path(name, uploads_dir)
    if full is None:
        return None
    P = prompts(req)
    head = P["img"] if name.lower().endswith(IMAGE_EXTS) else P["file"]
    text = head + (full if name.lower().endswith(IMAGE_EXTS) else upload_ref(full))
    cap = req.get("caption")
    if cap:
        cap = clean_text(cap)
        if cap is None:
            return None
        text += P["cap"] % cap  # no newline: a newline in the Claude Code input box may be taken as submit
    return text


MAX_FILES = 9


def message_sentence(req: dict, uploads_dir: Optional[str]) -> Optional[str]:
    """message request (optional text + 1-9 attachments) -> one line; None if any file fails validation."""
    files = req.get("files")
    if not isinstance(files, list) or not 1 <= len(files) <= MAX_FILES:
        return None
    paths = []
    for name in files:
        full = _upload_path(name, uploads_dir)
        if full is None:
            return None
        paths.append(full if name.lower().endswith(IMAGE_EXTS) else upload_ref(full))
    raw = req.get("text")
    text = None
    if raw:
        text = clean_text(raw)
        if text is None:
            return None
    P = prompts(req)
    joined = P["sep"].join(paths)
    if text:
        return text + " " + P["att"] % joined
    all_img = all(f.lower().endswith(IMAGE_EXTS) for f in files)
    n = "s" if len(paths) > 1 else ""
    return (P["img" + n] if all_img else P["file" + n]) + joined


PASTE_START, PASTE_END = "\x1b[200~", "\x1b[201~"


def upload_ref(full: str) -> str:
    """Reference to a non-image attachment in a message: when the path contains whitespace (e.g. the repo lives in a directory like "Phone App") it is written as a Markdown link
    "[saved name](path)" - the agent still sees the full path, the api's files.find_paths also recognizes paths with spaces, and the phone can restore it as an attachment card;
    paths without whitespace are written as bare paths."""
    if re.search(r"\s", full):
        return "[%s](%s)" % (os.path.basename(full), full)
    return full



def attach_parts(req: dict, uploads_dir: Optional[str]) -> Optional[List[str]]:
    """file / message request -> chunks to send in order (the caller appends Enter); None if validation fails.
    Images send the path by paste as Orca does, which Claude Code turns into an [Image #N] attachment; other files still get the path written."""
    if req.get("type") == "file":
        names, raw = [req.get("file")], req.get("caption")
    else:
        names, raw = req.get("files"), req.get("text")
        if not isinstance(names, list) or not 1 <= len(names) <= MAX_FILES:
            return None
    text = None
    if raw:
        text = clean_lines(raw) if req.get("lines") is True else clean_text(raw)
        if text is None:
            return None
    pastes, others = [], []
    for name in names:
        full = _upload_path(name, uploads_dir)
        if full is None:
            return None
        if name.lower().endswith(IMAGE_EXTS):
            pastes.append(full)
        else:
            others.append(upload_ref(full))
    parts = [PASTE_START + f + PASTE_END for f in pastes]
    tail = text or ""
    if others:
        P = prompts(req)
        joined = P["sep"].join(others)
        head = (P["files"] if len(others) > 1 else P["file"]) if not pastes else ""
        tail = (tail + " " + P["att"] % joined) if tail else head + joined
    if tail:
        tail = (" " if pastes else "") + tail
        parts.append(PASTE_START + tail + PASTE_END if "\n" in tail else tail)  # multi-line (quote) text must be pasted so newlines are not taken as submit
    return parts


def cleanup_uploads(uploads_dir: str, now: float, ttl: float = UPLOAD_TTL) -> int:
    """Delete files in uploads older than ttl seconds (does not follow symlinks or enter subdirectories). Returns the number deleted."""
    count = 0
    try:
        names = os.listdir(uploads_dir)
    except OSError:
        return 0
    for name in names:
        path = os.path.join(uploads_dir, name)
        try:
            st = os.lstat(path)
            if os.path.isdir(path) and not os.path.islink(path):
                continue
            if now - st.st_mtime > ttl:
                os.unlink(path)
                count += 1
        except OSError:
            continue
    return count


# ---------- Menu check before delivering plain messages (every account) ----------
# A plain message (text / attachments / recall) from any account, admin included, ends with Enter: landing on a question/approval menu would pick the first option / approve on the admin's behalf. Only explicit approval/answer requests (steps, key) may go into a menu and are not gated. The api checks the snapshot when enqueueing, but the snapshot lags by a few seconds,
# and the session may have just stopped at a menu while queued, so check again right before sending: if the snapshot state is waiting or the terminal screen shows a menu, never send
GUEST_TYPES = ("text", "message", "recall")
def _execute(req: dict, sessions: Dict[str, dict], sessions_dir: str, orca_cmd: List[str],
             uploads_dir: Optional[str] = None):
    """Returns (error|None, lines|None, log content, number of steps already sent successfully|None)."""
    typ = req.get("type")
    content = ""
    payload = None
    if typ == "text":
        payload = clean_lines(req.get("text")) if req.get("lines") is True else clean_text(req.get("text"))
        content = (payload or "").replace("\n", " ⏎ ")
        if payload and "\n" in payload:
            payload = PASTE_START + payload + PASTE_END  # quote replies are multi-line: pasted so newlines are not taken as submit
    elif typ == "recall":
        payload = clean_lines(req.get("text"))  # quote replies are multi-line; newlines must be kept to match the queue records
        content = "recall " + (payload or "").replace("\n", " ⏎ ")
    elif typ == "file":
        payload = attach_parts(req, uploads_dir)
        fname = req.get("file")
        cap = clean_text(req.get("caption")) if req.get("caption") else None
        content = ((os.path.basename(fname) if isinstance(fname, str) else "") + (" " + cap if cap else "")).strip()
    elif typ == "message":
        payload = attach_parts(req, uploads_dir)
        fl = req.get("files")
        names = [os.path.basename(f) for f in fl if isinstance(f, str)] if isinstance(fl, list) else []
        t = clean_text(req.get("text")) if req.get("text") else None
        content = ((t + " " if t else "") + "[" + ", ".join(names) + "]").strip()
    elif typ == "key":
        key = req.get("key")
        payload = KEYS.get(key) if isinstance(key, str) else None
        content = key if isinstance(key, str) else ""
    elif typ == "steps":
        parts = _steps_payloads(req.get("steps"))
        if parts is None:
            return "bad-request", None, "", None
        content = _steps_summary(parts)
        payload = ""  # placeholder: steps do not use the single-send path below
    elif typ != "screen":
        return "bad-request", None, "", None
    if typ == "text" and not isinstance(req.get("enter", True), bool):
        return "bad-request", None, content, None
    if typ != "screen" and payload is None:
        return "bad-request", None, content, None
    sid = req.get("sessionId")
    item = sessions.get(sid) if isinstance(sid, str) else None
    if item is None:
        return "session-gone", None, content, None
    if item.get("kind") != "claude":
        return "not-claude", None, content, None
    pid = pid_for(sid, sessions_dir)
    if pid is None:
        return "session-gone", None, content, None
    handle = terminal_handle(pid)
    if not handle:
        return "no-terminal", None, content, None
    if req.get("account") != "admin" and typ not in GUEST_TYPES:  # guest (a missing account counts as guest): only text/attachment messages/recall allowed
        return "forbidden", None, content, None
    if typ in ("text", "message", "file", "recall"):  # every account: re-check the menu before delivery; steps/key/screen are explicit and ungated
        why = menu_gate(item, handle, orca_cmd)
        if why:
            return why, None, content, None
    if typ == "screen":
        data = _orca_json(orca_cmd, ["terminal", "read", "--terminal", handle])
        terminal = ((data or {}).get("result") or {}).get("terminal") or {}
        tail = terminal.get("tail")
        if not isinstance(tail, list):
            return "orca-failed", None, content, None
        lines = []
        for ln in tail:
            lines.extend(strip_ansi(str(ln)).split("\n"))
        return None, lines[-SCREEN_LINES:], content, None
    if typ == "steps":
        for i, (data, _, _) in enumerate(parts):
            if i:
                _pause()
            res = _orca_json(orca_cmd, ["terminal", "send", "--terminal", handle, "--text", data])
            if (((res or {}).get("result") or {}).get("send") or {}).get("accepted") is not True:
                return "orca-failed", None, content, i
        return None, None, content, len(parts)
    if typ == "recall":
        return _recall(item, handle, orca_cmd, payload), None, content, None
    if typ in ("file", "message"):
        for i, data in enumerate(payload + ["\r"]):  # pause between chunks so Claude Code can turn the paste into an attachment
            if i:
                _pause(PASTE_DELAY)
                why = menu_gate(item, handle, orca_cmd)  # re-check the menu before sending each next chunk (including Enter)
                if why:
                    return _menu_abort(orca_cmd, handle, payload[:i], why), None, content, None
            res = _orca_json(orca_cmd, ["terminal", "send", "--terminal", handle, "--text", data])
            if (((res or {}).get("result") or {}).get("send") or {}).get("accepted") is not True:
                return "orca-failed", None, content, None
        return None, None, content, None
    # send Enter separately: orca's --enter waits for confirmation of submission (~1.8 s), while sending separately takes ~0.9 s
    chunks = [payload]
    if typ == "text" and req.get("enter", True) is True:
        chunks.append("\r")
    for i, data in enumerate(chunks):
        if i:
            _pause()
            why = menu_gate(item, handle, orca_cmd)  # re-check the menu before pressing Enter
            if why:
                return _menu_abort(orca_cmd, handle, chunks[:i], why), None, content, None
        res = _orca_json(orca_cmd, ["terminal", "send", "--terminal", handle, "--text", data])
        if (((res or {}).get("result") or {}).get("send") or {}).get("accepted") is not True:
            return "orca-failed", None, content, None
    return None, None, content, None


# ---------- Recalling queued messages (type: recall)----------
# Observed in a test terminal (Claude Code 2.1.308):
#   While the session is busy the input box shows "Press up to edit queued messages"; pressing Up pulls **all** queued messages back into the input box (one per line), and the transcript gets one line
#   queue-operation popAll (with the original text); the running turn is unaffected. Esc interrupts the turn, and queued messages are still dequeued and sent afterwards, so it cannot be used to recall.
#   Ctrl+U deletes only the line the cursor is on (by screen wrapping); sending Ctrl+U plus Backspace in pairs several times clears everything, and extra sends on an empty input box are harmless.
# Procedure: confirm the target is still queued -> note the transcript length -> send Up -> wait for popAll in the transcript -> clear the input box (verify on screen it is empty) -> re-send the other pulled-back messages unchanged.
# If the input box is not clean, stop without re-sending (report recall-uncertain so a human checks Orca); never press Enter while it is not empty.
RECALL_WAIT = 2.0       # max wait for popAll after sending Up
RECALL_POLL = 0.1
RECALL_SETTLE = 0.25    # wait a bit after the first popAll to collect the whole batch
RECALL_TAIL = 4 * 1024 * 1024  # how much of the transcript tail to read to decide "still queued": busy turns have large tool output, and too small a window pushes the enqueue line out (only queue-operation lines are parsed)
CLEAR_PAIR = "\x15\x7f"  # Ctrl+U (delete to line start) + Backspace (delete the newline)


def _jsonl_path(item: dict) -> Optional[str]:
    """Transcript path: use the snapshot entry's transcript if present; the helper gets the panel's raw dump (no such field), so it looks for <projects>/*/<id>.jsonl by session id."""
    rel = item.get("transcript")
    if not isinstance(rel, str) or not rel:
        sid = item.get("id")
        if not isinstance(sid, str) or not _UUID_RE.match(sid):
            return None
        hits = sorted(glob.glob(os.path.join(glob.escape(PROJECTS_DIR), "*", sid + ".jsonl")))
        if not hits:
            return None
        rel = os.path.relpath(hits[0], PROJECTS_DIR)
    root = os.path.realpath(PROJECTS_DIR)
    full = os.path.realpath(os.path.join(root, rel))
    if not full.startswith(root + os.sep) or not os.path.isfile(full):
        return None
    return full


def _queue_ops(path: str, start: int) -> List[dict]:
    """queue-operation lines of the transcript from start (from earlier if less than RECALL_TAIL)."""
    out = []
    try:
        with open(path, "rb") as f:
            if start > 0:
                f.seek(start - 1)
                f.readline()  # drop the partial line containing start (if start is exactly at a line start only the preceding newline is consumed)
            for line in f:
                if not line.startswith(b'{"type":"queue-operation"'):
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except OSError:
        pass
    return out


def queued_now(path: str) -> List[str]:
    """Infer the original texts still queued from the transcript tail (FIFO, same rule as qpend in api/transcript.py)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return []
    pend = []  # type: List[str]
    for obj in _queue_ops(path, size - RECALL_TAIL):
        op = obj.get("operation")
        c = obj.get("content")
        if op == "enqueue":
            pend.append(c if isinstance(c, str) else "")
        elif op == "dequeue":
            if pend:
                pend.pop(0)
        elif op in ("remove", "popAll") and c in pend:
            pend.remove(c)
    return pend


def _send_raw(orca_cmd: List[str], handle: str, data: str) -> bool:
    res = _orca_json(orca_cmd, ["terminal", "send", "--terminal", handle, "--text", data])
    return (((res or {}).get("result") or {}).get("send") or {}).get("accepted") is True


def _clear_input(orca_cmd: List[str], handle: str, texts: List[str]) -> bool:
    """Clear the input box and verify. The count is estimated assuming a worst case of 20 chars per wrapped line; extra sends are harmless; at most two rounds."""
    n = min(600, sum(len(t) // 20 + 2 for t in texts) + 8)
    for _ in range(2):
        if not _send_raw(orca_cmd, handle, CLEAR_PAIR * n):
            return False
        _pause(0.3)
        left = _screen_input(orca_cmd, handle)
        # empty, or only placeholder hint left (e.g. Press up to edit...): no beginning of the pulled-back text remains in it
        if left is not None and not any(t.split("\n")[0][:12] in left for t in texts if t.strip()):
            return True
        n = 600
    return False


def _menu_abort(orca_cmd: List[str], handle: str, typed: List[str], why: str) -> str:
    """A guest's text was typed into the input box but a menu (or an unreadable screen) was found before Enter: do not press Enter, clear what was typed with Ctrl+U + Backspace, and report the whole message as failed with why.
    Cleanup sends only delete keys (no Enter, no Esc), harmless on a menu; when a menu covers the input box it cannot be verified, so only one log line is written."""
    n = min(600, sum(len(t) // 20 + 2 for t in typed) + 8)
    if not _send_raw(orca_cmd, handle, CLEAR_PAIR * n):
        _warn("message stopped before Enter (%s); input box cleared, nothing sent" % why)
        return why
    _pause(0.3)
    left = _screen_input(orca_cmd, handle)
    if left is None or any(t.split("\n")[0][:12] in left for t in typed if t.strip()):
        _warn("message stopped before Enter (%s); could not verify the input box was cleared" % why)
    return why


def _recall(item: dict, handle: str, orca_cmd: List[str], target: str) -> Optional[str]:
    path = _jsonl_path(item)
    if path is None:
        return "no-transcript"
    if target not in queued_now(path):
        return "already-read"
    try:
        size0 = os.path.getsize(path)
    except OSError:
        return "no-transcript"
    if not _send_raw(orca_cmd, handle, KEYS["up"]):
        return "orca-failed"
    popped = []  # type: List[str]
    deadline = time.time() + RECALL_WAIT
    seen_at = None
    while time.time() < deadline:
        time.sleep(RECALL_POLL)
        popped = [o.get("content") for o in _queue_ops(path, size0)
                  if o.get("operation") == "popAll" and isinstance(o.get("content"), str)]
        if popped and seen_at is None:
            seen_at = time.time()
        if seen_at is not None and time.time() - seen_at >= RECALL_SETTLE:
            break
    # when Up pulls no queued message it recalls the previous history entry, which must be cleared too
    if not _clear_input(orca_cmd, handle, popped or [target]):
        return "recall-uncertain"
    rest = list(popped)
    hit = target in rest
    if hit:
        rest.remove(target)
    # if the target was consumed just before Up, other people's pulled-back messages are still sent back; the rest are re-queued unchanged (single lines typed, multi-line pasted)
    # re-check the screen both before typing and before Enter: a menu may have appeared, and a blind Enter would pick a menu item for someone else
    for i, t in enumerate(rest):
        data = PASTE_START + t + PASTE_END if "\n" in t else t
        why = menu_gate(item, handle, orca_cmd)
        if why is None:
            _pause(0.3)
            if not _send_raw(orca_cmd, handle, data):
                why = "orca-failed"
        if why is None:
            _pause()
            why = menu_gate(item, handle, orca_cmd)
            if why is not None:
                _menu_abort(orca_cmd, handle, [data], why)
            elif not _send_raw(orca_cmd, handle, "\r"):
                why = "orca-failed"
        if why is not None:
            # the target was recalled but others' messages were not re-sent; must report failure so a human checks Orca
            _warn("recall: re-sending other queued messages stopped (%s), %d not sent back" % (why, len(rest) - i))
            return why
    return None if hit else "already-read"


PANEL_DOMAIN = settings.panel_domain()
# Legacy domain: dual-written and read as fallback only if configured; otherwise only the new domain is used
PANEL_DOMAIN_LEGACY = settings.panel_domain_legacy()
# marker key written by the panel after it migrates the whole legacy domain into the new one; owned by the panel, the helper only reads it
MIGRATED_KEY = "legacyMigratedFrom"


def _legacy() -> str:
    return PANEL_DOMAIN_LEGACY if PANEL_DOMAIN_LEGACY and PANEL_DOMAIN_LEGACY != PANEL_DOMAIN else ""


def _export_domain(name: str) -> dict:
    # defaults export also exits 0 and exports an empty dict when the domain does not exist
    out = subprocess.run(["defaults", "export", name, "-"], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, timeout=5, check=True).stdout
    data = plistlib.loads(out)
    return data if isinstance(data, dict) else {}


def read_panel() -> dict:
    """Read the panel domain (shared by the helper snapshot and mark), merging old and new domains per key:
    if the panel has migrated (the new domain has legacyMigratedFrom), each key uses the new domain when present, else the old one;
    if not migrated, the old domain wins instead: an old panel writes only the old domain, and the new domain's seenAt covers only a few sessions written from the phone,
    so preferring it would hide read marks and pins from the panel. Without a legacy domain only the new one is read; a failed legacy read counts as empty. A failed new-domain read raises as usual."""
    data = _export_domain(PANEL_DOMAIN)
    legacy = _legacy()
    if not legacy:
        return data
    try:
        old = _export_domain(legacy)
    except Exception:
        old = {}
    if MIGRATED_KEY in data:
        return {**old, **data}
    return {**data, **old}


def _panel_write(args: List[str]) -> None:
    """The only write entry for the panel domain (new keys must go through it too). With a legacy domain configured it writes the legacy domain first, then the new one, writing both fully;
    a legacy write failure raises immediately without writing the new domain, so a value never exists in the new domain but not the old (on panel migration the old domain wins for same-named keys)."""
    if not args or args[0] == MIGRATED_KEY:
        raise ValueError("refusing to write %s" % MIGRATED_KEY)
    legacy = _legacy()
    for name in ([legacy] if legacy else []) + [PANEL_DOMAIN]:
        subprocess.run(["defaults", "write", name] + args,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)


def _valid_sid(sid) -> bool:
    return isinstance(sid, str) and bool(sid) and not sid.startswith("-")


def apply_mark(req: dict) -> None:
    """Write read marks/pins back to the panel's UserDefaults; only the seenAt and pinned keys are written. Failures go only to helper.log (stderr)."""
    try:
        domain = read_panel()
        seen = req.get("seen")
        if isinstance(seen, dict):
            cur = domain.get("seenAt")
            cur = cur if isinstance(cur, dict) else {}
            for sid, t in seen.items():
                if (not _valid_sid(sid) or isinstance(t, bool) or not isinstance(t, (int, float))
                        or not math.isfinite(t)):
                    continue
                old = cur.get(sid)
                if isinstance(old, (int, float)) and not isinstance(old, bool) and t <= old:
                    continue  # write only when the new value is larger
                # use plist syntax for values: -float stores single precision, which rounds time to 128 s steps and could hide a just-finished unread
                _panel_write(["seenAt", "-dict-add", sid, "<real>%r</real>" % float(t)])
        # mark as unread: write seenAt backwards (earlier than the session's last activity), not subject to "write only when larger"
        unseen = req.get("unseen")
        if isinstance(unseen, dict):
            for sid, t in unseen.items():
                if (not _valid_sid(sid) or isinstance(t, bool) or not isinstance(t, (int, float))
                        or not math.isfinite(t) or t < 0):
                    continue
                _panel_write(["seenAt", "-dict-add", sid, "<real>%r</real>" % float(t)])
        pin = req.get("pin")
        if isinstance(pin, dict):
            raw = domain.get("pinned")
            ids = [p for p in raw if isinstance(p, str)] if isinstance(raw, list) else []
            new = list(ids)
            valid = False
            for sid, value in pin.items():
                if not _valid_sid(sid) or not isinstance(value, bool):
                    continue
                valid = True
                if value and sid not in new:
                    new.append(sid)
                elif not value and sid in new:
                    new = [p for p in new if p != sid]
            # if there are valid items, write the whole set unconditionally: the merged ids may reflect only the old domain (an old panel edited it itself),
            # so write even when new == ids to bring pinned back in sync across both domains
            if valid:
                _panel_write(["pinned", "-array"] + new)
    except Exception as e:
        _warn("mark failed %s: %s" % (type(e).__name__, e))


def _warn(msg: str) -> None:
    """Write one line per message to stderr (launchd collects it into data/helper.log); each line is prefixed with local time YYYY-MM-DD HH:MM:SS, like snapshot.log()."""
    sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime()) + " " + msg.replace("\n", " ") + "\n")
    sys.stderr.flush()


def _write_result(outbox_dir: str, rid: str, err: Optional[str], lines, now: float, sent=None,
                  message: Optional[str] = None, extra: Optional[dict] = None) -> None:
    res = {"id": rid, "status": "failed" if err else "done", "finishedAt": now}
    if extra:
        res.update(extra)
    if message:
        res["message"] = message
    if err and sent:  # steps failed midway: number of steps already sent; the frontend uses it to forbid re-sending
        res["sentSteps"] = sent
    if err:
        res["error"] = err
    if lines is not None:
        res["lines"] = lines
    _write_atomic(os.path.join(outbox_dir, rid + ".res.json"), res)


def _mtime(path: str) -> Optional[float]:
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


_WAKES = {}  # session name -> {"proc", "err", "started"(monotonic), "reqs": [(rid, claimed path, time for the log)]}
_OFFS = {}   # off-duty, same structure


def _read_roster(path: Optional[str]) -> dict:
    try:
        with open(path or ROSTER_PATH or os.devnull, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _is_awake(name: str, sessions: Dict[str, dict], sessions_dir: str) -> bool:
    """The name is already among current sessions (dump or registry file)."""
    if any(isinstance(i, dict) and i.get("name") == name for i in sessions.values()):
        return True
    for path in glob.glob(os.path.join(glob.escape(sessions_dir), "*.json")):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and data.get("name") == name:
            return True
    return False


def _last_line(f) -> str:
    try:
        f.seek(0)
        lines = [ln.strip() for ln in f.read().decode("utf-8", "replace").splitlines() if ln.strip()]
    except (OSError, ValueError):
        return ""
    return _CTRL_RE.sub(" ", lines[-1])[:200] if lines else ""


def _wake_start(name, rid, claimed, t, sessions, sessions_dir, roster_path, wake_cmd):
    """Register a wake request. Returns (err, message) when the result is immediate; None means it moved to background waiting."""
    if name in _WAKES:
        _WAKES[name]["reqs"].append((rid, claimed, t))
        return None
    if name not in _read_roster(roster_path):
        if _is_awake(name, sessions, sessions_dir):
            return None, None
        return "not-offduty", None
    if not (wake_cmd or WAKE_CMD):
        return "wake-failed", "wake script not configured (SOULGENT_OFFDUTY)"
    err_file = tempfile.TemporaryFile()
    try:
        proc = subprocess.Popen((wake_cmd or WAKE_CMD) + [name], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=err_file,
                                env={"HOME": HOME, "PATH": "/usr/bin:/bin"})
    except OSError as e:
        err_file.close()
        return "wake-failed", ("%s: %s" % (type(e).__name__, e))[:200]
    _WAKES[name] = {"proc": proc, "err": err_file, "started": time.monotonic(), "reqs": [(rid, claimed, t)]}
    return None


def _off_start(name, rid, claimed, t, off_cmd):
    """Register an off-duty request (the name has been verified as a live session in the snapshot). Returns (err, message) when the result is immediate; None means it moved to the background."""
    if name in _OFFS:
        _OFFS[name]["reqs"].append((rid, claimed, t))
        return None
    if not (off_cmd or OFF_CMD):
        return "offduty-failed", "off-duty script not configured (SOULGENT_OFFDUTY)"
    err_file = tempfile.TemporaryFile()
    try:
        # argument list, no shell; the session name was verified against the snapshot and does not start with -
        proc = subprocess.Popen((off_cmd or OFF_CMD) + [name], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=err_file,
                                env={"HOME": HOME, "PATH": "/usr/bin:/bin"})
    except OSError as e:
        err_file.close()
        return "offduty-failed", ("%s: %s" % (type(e).__name__, e))[:200]
    _OFFS[name] = {"proc": proc, "err": err_file, "started": time.monotonic(), "reqs": [(rid, claimed, t)]}
    return None


def _jobs_poll(jobs, typ, timeout, outbox_dir, sessions, sessions_dir, log_path, now) -> int:
    """Check background wake/off-duty processes and write results for finished ones. Returns the number of results written.
    On timeout: kill the process; wake counts as success if the name is already awake, off-duty if the name is no longer among live sessions."""
    count = 0
    for name in list(jobs):
        w = jobs[name]
        proc = w["proc"]
        rc = proc.poll()
        err, message = None, None
        if rc is None:
            if time.monotonic() - w["started"] <= timeout:
                continue
            try:
                proc.kill()
                proc.wait(timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass
            awake = _is_awake(name, sessions, sessions_dir)
            if typ == "wake" and not awake:
                err = "wake-timeout"
            elif typ == "offduty" and awake:
                err = "offduty-timeout"
        elif rc != 0:
            # only the error code is returned (the frontend translates it); the script's original message (Chinese) goes only to helper.log
            line = _last_line(w["err"])
            err = job_fail_code(typ, rc, line)
            if line:
                _warn("%s %s failed (exit code %d -> %s): %s" % (typ, name, rc, err, line))
        del jobs[name]
        w["err"].close()
        for rid, claimed, _t in w["reqs"]:
            _finish(outbox_dir, rid, claimed, err, None, now, name, typ, name, message=message,
                    log_path=log_path)
            count += 1
    return count


# Original messages of the wake / off-duty script (offduty.py, not in this repo) on failure -> error code. Unrecognized ones map to wake-failed / offduty-failed.
# The frontend's wakefail.* / offfail.* in web/i18n.js use the same codes
_JOB_FAIL = {
    "wake": [("名册里没有", "not-offduty"), ("已经醒着", "wake-already-awake"), ("Orca 没开出终端", "wake-no-terminal"),
             ("秒没注册", "wake-timeout")],
    "offduty": [("没有醒着的", "session-gone"), ("不是空闲", "offduty-not-idle"), ("后台子代理在跑", "offduty-agents-running")],
}


def job_fail_code(typ: str, rc: int, line: str) -> str:
    if typ == "offduty" and rc == 3:
        return "offduty-restarting"  # offduty.py exits with code 3 and prints no reason when it cannot get restart.lock (the restart script is running)
    for frag, code in _JOB_FAIL.get(typ, []):
        if frag in (line or ""):
            return code
    return typ + "-failed"


def _wake_poll(outbox_dir, sessions, sessions_dir, log_path, now) -> int:
    return _jobs_poll(_WAKES, "wake", WAKE_TIMEOUT, outbox_dir, sessions, sessions_dir, log_path, now)


def _finish(outbox_dir, rid, claimed, err, lines, t, name, typ, content, sent=None, message=None, log_path=None):
    try:
        _log(log_path, t, name, typ, content,
             "failed:" + err + (" sent=%d" % sent if sent else "") if err else "done")
    except OSError as e:
        _warn("send.log write failed %s: %s" % (type(e).__name__, e))
    try:
        _write_result(outbox_dir, rid, err, lines, t, sent, message)
        os.unlink(claimed)
    except OSError as e:
        _warn("outbox result write failed %s: %s" % (type(e).__name__, e))  # keep .claimed; the next round judges helper-restarted


def process_once(outbox_dir: str, sessions: Dict[str, dict], sessions_dir: str, orca_cmd: List[str],
                 log_path: str, now: float, roster_path: Optional[str] = None,
                 wake_cmd: Optional[List[str]] = None, uploads_dir: Optional[str] = None,
                 off_cmd: Optional[List[str]] = None) -> int:
    """At-most-once delivery: rename req to .claimed before executing; a .claimed file is never re-run."""
    count = 0
    t0 = time.time()
    # Claims left unfinished last time (crash or failed result write): only write a failure result, never re-send. Without a secret the result cannot be signed, so do not finalize yet (avoids an error every second)
    for cpath in sorted(glob.glob(os.path.join(glob.escape(outbox_dir), "*.claimed"))) if secret() else []:
        rid = os.path.basename(cpath)[:-len(".claimed")]
        if any(r[0] == rid for j in (_WAKES, _OFFS) for w in j.values() for r in w["reqs"]):
            continue  # wake/off-duty still running in the background, not a leftover
        if _ctx_has(rid):
            continue  # context detail is running or queued
        try:
            _write_result(outbox_dir, rid, "helper-restarted", None, now)
            os.unlink(cpath)
            count += 1
        except OSError as e:
            _warn("outbox finalize failed %s: %s" % (type(e).__name__, e))
    reqs = []
    key = secret()
    for path in glob.glob(os.path.join(glob.escape(outbox_dir), "*.req.json")):
        mtime = _mtime(path)
        if mtime is None:
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                req = json.load(f)
        except OSError:
            continue
        except ValueError:
            req = None
        rid = os.path.basename(path)[:-len(".req.json")]
        if not key or not verify("req", req, key) or req.get("id") != rid:
            # no secret / bad signature / renamed: do not execute and do not write a result (it could not be signed or should not be), and delete it to avoid re-checking every second
            if not key:
                _warn_every("secret", "outbox: %s unset or shorter than %d chars, discarding all requests (see .env.example)"
                            % (SECRET_ENV, SECRET_MIN))
            else:
                _warn("outbox: request %s has a bad signature or mismatched id, discarding" % rid[:40])
            try:
                os.unlink(path)
            except OSError:
                pass
            continue
        created = req.get("createdAt") if isinstance(req, dict) else None
        if (isinstance(created, bool) or not isinstance(created, (int, float)) or not math.isfinite(created)
                or created > now + 5):
            created = mtime
        reqs.append((created, path, req))
    reqs.sort(key=lambda r: (r[0], r[1]))
    for created, path, req in reqs:
        rid = os.path.basename(path)[:-len(".req.json")]
        claimed = os.path.join(outbox_dir, rid + ".claimed")
        try:
            os.replace(path, claimed)
        except OSError:
            continue
        if isinstance(req, dict) and req.get("type") == "mark":  # does not use orca, check sessions, write send.log or write a result
            apply_mark(req)
            try:
                os.unlink(claimed)
            except OSError:
                pass
            count += 1
            continue
        t = now + (time.time() - t0)  # re-read the time per request (now can be injected for tests)
        if not isinstance(req, dict):
            req = {}
        sid = req.get("sessionId")
        item = sessions.get(sid) if isinstance(sid, str) else None
        if t - created > REQUEST_TTL:
            err, lines, content, sent = "helper-timeout", None, "", None
        elif req.get("type") == "wake":
            name = req.get("name")
            if not isinstance(name, str) or not name or name.startswith("-") or "\x00" in name:
                err, lines, content, sent = "bad-request", None, "", None
            else:
                try:
                    early = _wake_start(name, rid, claimed, t, sessions, sessions_dir, roster_path, wake_cmd)
                except Exception as e:
                    _warn("wake error %s: %s" % (type(e).__name__, e))
                    early = ("wake-failed", None)
                if early is None:
                    count += 1
                    continue  # waits in the background; the result is written by _wake_poll
                _finish(outbox_dir, rid, claimed, early[0], None, t, name, "wake", name, message=early[1],
                        log_path=log_path)
                count += 1
                continue
        elif req.get("type") == "context":
            try:
                early = _ctx_add(sid, item, rid, claimed, t)
            except Exception as e:
                _warn("context error %s: %s" % (type(e).__name__, e))
                early = "context-failed"
            if early is not None:
                _ctx_write(outbox_dir, rid, claimed, early, None, t, sid)
                _warn("context %s failed:%s" % ((item or {}).get("name") or sid, early))
            count += 1
            continue
        elif req.get("type") == "offduty":
            # only live sessions in the snapshot count: look up the name by sessionId; the name in the request must match it
            name = (item or {}).get("name") if isinstance(item, dict) else None
            if not isinstance(name, str) or not name:
                err, lines, content, sent = "session-gone", None, "", None
            elif (req.get("name") != name or name.startswith("-") or "\x00" in name
                  or any(c in name for c in "\r\n")):
                err, lines, content, sent = "bad-request", None, "", None
            else:
                try:
                    early = _off_start(name, rid, claimed, t, off_cmd)
                except Exception as e:
                    _warn("offduty error %s: %s" % (type(e).__name__, e))
                    early = ("offduty-failed", None)
                if early is None:
                    count += 1
                    continue  # waits in the background; the result is written by _jobs_poll
                _finish(outbox_dir, rid, claimed, early[0], None, t, name, "offduty", name, message=early[1],
                        log_path=log_path)
                count += 1
                continue
        else:
            try:
                err, lines, content, sent = _execute(req, sessions, sessions_dir, orca_cmd, uploads_dir)
            except Exception as e:
                _warn("outbox execution error %s: %s" % (type(e).__name__, e))
                err, lines, content, sent = "orca-failed", None, "", None
        _finish(outbox_dir, rid, claimed, err, lines, t, (item or {}).get("name") or "",
                str(req.get("type", "?")), content, sent, log_path=log_path)
        count += 1
    count += _wake_poll(outbox_dir, sessions, sessions_dir, log_path, now + (time.time() - t0))
    count += _jobs_poll(_OFFS, "offduty", OFF_TIMEOUT, outbox_dir, sessions, sessions_dir, log_path,
                        now + (time.time() - t0))
    count += _ctx_poll(outbox_dir, sessions_dir, now + (time.time() - t0))
    now = now + (time.time() - t0)
    for path in glob.glob(os.path.join(glob.escape(outbox_dir), "*.res.json")):
        m = _mtime(path)
        if m is not None and now - m > RESULT_TTL:
            try:
                os.unlink(path)
            except OSError:
                pass
    return count


# ---------- Context detail (type: context)----------
# Run `claude -p --resume <sid> --fork-session --session-id <new uuid> --output-format json "/context"` in the session's start directory;
# it takes ~5 s and calls no model, and leaves a fork transcript <new uuid>.jsonl under ~/.claude/projects/<dir>/, which is deleted by uuid afterwards.
# Peak memory is ~700MB, so only one runs at a time; requests for the same session are merged into one and the rest are queued.
CONTEXT_TIMEOUT = 20
CLAUDE_EXTRA_PATHS = [os.path.join(HOME, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin"]
CLAUDE_BIN = settings.claude_bin()  # SOULGENT_CLAUDE_BIN if set, only it is used
PROJECTS_DIR = _CLAUDE["projects_dir"]
# Claude config directory for the /context subprocess: if SOULGENT_CLAUDE_DIR points elsewhere, pass CLAUDE_CONFIG_DIR explicitly (it cannot simply be removed,
# otherwise the subprocess falls back to ~/.claude and can neither resume the session nor see that login); with the default ~/.claude do not set it (if set, Claude Code looks for
# a .claude.json inside that directory). A CLAUDE_CONFIG_DIR already in the environment is not inherited, so it cannot disagree with the directory the helper reads
CLAUDE_DIR = settings.claude_dir()
# Only strip the nested-session marker (in case the helper was started from a Claude Code session); other CLAUDE_* settings (Bedrock, proxy, etc.) pass through
NESTED_MARKERS = ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_SESSION_ID")
SESSIONS_DIR = _CLAUDE["sessions_dir"]
FORK_HIDE_AFTER = 10    # keep hiding the fork from the snapshot this long after it ends (the panel dump may still include it)
_UUID_RE = re.compile(r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")

_CTX_RUN = None     # running: {"sid","name","cwd","fork","proc","out","err","started","reqs"}
_CTX_QUEUE = []     # queued: {"sid","name","reqs"}
_FORKS = {}         # fork uuid -> end time (None = still running)
_FORKS_LOCK = threading.Lock()


def active_forks(now: Optional[float] = None) -> set:
    """Fork ids that are running (or ended less than FORK_HIDE_AFTER seconds ago): the snapshot hides them."""
    t = time.time() if now is None else now
    with _FORKS_LOCK:
        for k in [k for k, v in _FORKS.items() if v is not None and t - v > FORK_HIDE_AFTER]:
            del _FORKS[k]
        return set(_FORKS)


def _parse_tokens(s) -> Optional[int]:
    """'6k' / '649' / '1.2k' / '191.2k' / '1m' / '~60' / '< 20' -> integer; None if not recognized."""
    if not isinstance(s, str):
        return None
    t = s.strip().lower().replace(",", "").lstrip("~<>≈ ").strip()
    m = re.match(r"\A(\d+(?:\.\d+)?)\s*([km]?)\Z", t)
    if not m:
        return None
    v = float(m.group(1)) * {"": 1, "k": 1e3, "m": 1e6}[m.group(2)]
    return int(round(v))


def _parse_pct(s) -> Optional[float]:
    m = re.match(r"\A\s*(\d+(?:\.\d+)?)\s*%\s*\Z", s or "")
    return float(m.group(1)) if m else None


def _md_tables(text: str) -> Dict[str, List[Dict[str, str]]]:
    """### section heading -> table rows (columns taken by header)."""
    out = {}
    title, header = None, None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("#"):
            title = line.lstrip("#").strip() if line.startswith("###") else None
            header = None
            continue
        if not title or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if header is None:
            header = cells
            out.setdefault(title, [])
            continue
        if all(re.match(r"\A:?-+:?\Z", c) for c in cells if c):
            continue
        out.setdefault(title, []).append(dict(zip(header, cells)))
    return out


# detail section -> (result key, name column, second column -> field name)
_DETAIL_SECTIONS = {
    "MCP Tools": ("mcpTools", "Tool", ("Server", "server")),
    "Custom Agents": ("agents", "Agent Type", ("Source", "source")),
    "Memory Files": ("memory", "Path", ("Type", "type")),
    "Skills": ("skills", "Skill", ("Source", "source")),
}


def parse_context_md(text) -> dict:
    """/context markdown -> {model, used, window, pct, categories, details}; raises ValueError if there is no category table."""
    if not isinstance(text, str):
        raise ValueError("no text")
    model = None
    m = re.search(r"\*\*Model:\*\*\s*(.+)", text)
    if m:
        model = m.group(1).strip() or None
    used = window = pct = None
    m = re.search(r"\*\*Tokens:\*\*\s*([^/\n]+?)\s*/\s*([^\s(]+)\s*(?:\((\d+(?:\.\d+)?)%\))?", text)
    if m:
        used, window = _parse_tokens(m.group(1)), _parse_tokens(m.group(2))
        pct = float(m.group(3)) if m.group(3) else None
    tables = _md_tables(text)
    cats = []
    for title, rows in tables.items():
        if title.lower().startswith("estimated usage by category"):
            for r in rows:
                name = r.get("Category")
                tok = _parse_tokens(r.get("Tokens"))
                if not name or tok is None:
                    continue
                cats.append({"name": name, "tokens": tok, "pct": _parse_pct(r.get("Percentage"))})
    if not cats:
        raise ValueError("no categories")
    details = {}
    for title, (key, ncol, (ocol, ofield)) in _DETAIL_SECTIONS.items():
        rows = []
        for r in tables.get(title, []):
            name = r.get(ncol)
            if not name:
                continue
            rows.append({"name": name, ofield: r.get(ocol) or "", "tokens": _parse_tokens(r.get("Tokens")),
                         "label": r.get("Tokens") or ""})
        details[key] = rows
    if pct is None and used is not None and window:
        pct = round(used * 100.0 / window, 1)
    return {"model": model, "used": used, "window": window, "pct": pct, "categories": cats, "details": details}


def find_claude() -> Optional[str]:
    if CLAUDE_BIN:
        return CLAUDE_BIN if os.path.isfile(CLAUDE_BIN) else None
    path = os.pathsep.join(CLAUDE_EXTRA_PATHS + [os.environ.get("PATH", "/usr/bin:/bin")])
    return shutil.which("claude", path=path)


def _cwd_for(sid: str, sessions_dir: str) -> Optional[str]:
    """~/.claude/sessions/<pid>.json registers the start directory of that session."""
    for path in glob.glob(os.path.join(glob.escape(sessions_dir), "*.json")):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and data.get("sessionId") == sid and isinstance(data.get("cwd"), str):
            return data["cwd"]
    return None


def _ctx_has(rid: str) -> bool:
    jobs = ([_CTX_RUN] if _CTX_RUN else []) + _CTX_QUEUE
    return any(r[0] == rid for j in jobs for r in j["reqs"])


def _ctx_add(sid, item, rid, claimed, t) -> Optional[str]:
    """Register a context request; returning an error code means immediate failure, None means it is queued (merged per session)."""
    if not isinstance(sid, str) or not _UUID_RE.match(sid):
        return "bad-request"
    if not isinstance(item, dict) or item.get("kind") != "claude":
        return "session-gone"
    for job in ([_CTX_RUN] if _CTX_RUN else []) + _CTX_QUEUE:
        if job["sid"] == sid:
            job["reqs"].append((rid, claimed, t))
            return None
    _CTX_QUEUE.append({"sid": sid, "name": item.get("name") or "", "reqs": [(rid, claimed, t)]})
    return None


def _ctx_write(outbox_dir, rid, claimed, err, data, t, sid) -> None:
    extra = {"type": "context", "sessionId": sid}
    if data is not None:
        extra["data"] = data
    try:
        _write_result(outbox_dir, rid, err, None, t, extra=extra)
        os.unlink(claimed)
    except OSError as e:
        _warn("outbox result write failed %s: %s" % (type(e).__name__, e))


def _remove_fork(fork: str, projects_dir: str) -> int:
    """Delete the fork transcripts by the pre-generated uuid (not trusting session_id in the result); returns how many were deleted."""
    n = 0
    for path in glob.glob(os.path.join(glob.escape(projects_dir), "*", fork + ".jsonl")):
        try:
            os.unlink(path)
            n += 1
        except OSError as e:
            _warn("cannot delete fork transcript %s: %s" % (path, e))
    for path in glob.glob(os.path.join(glob.escape(projects_dir), "*", fork)):
        if os.path.isdir(path):
            _warn("fork left a directory (not deleted): %s" % path)
    return n


def _ctx_start(job, sessions_dir, claude=None, projects_dir=None) -> Optional[str]:
    """Start the subprocess; returning an error code means it did not start."""
    global _CTX_RUN
    cwd = _cwd_for(job["sid"], sessions_dir)
    if not cwd or not os.path.isdir(cwd):
        return "cwd-missing"
    exe = claude or find_claude()
    if not exe:
        return "claude-not-found"
    fork = str(uuid.uuid4())
    env = {k: v for k, v in os.environ.items()
           if k not in NESTED_MARKERS and k != "CLAUDE_CONFIG_DIR" and not k.startswith("ORCA_")}
    if os.path.normpath(CLAUDE_DIR) != os.path.join(HOME, ".claude"):
        env["CLAUDE_CONFIG_DIR"] = CLAUDE_DIR  # the same directory the helper reads sessions from (SOULGENT_CLAUDE_DIR)
    env["HOME"] = HOME
    env["PATH"] = os.pathsep.join([os.path.dirname(exe)] + CLAUDE_EXTRA_PATHS + ["/usr/bin", "/bin"])
    out_f, err_f = tempfile.TemporaryFile(), tempfile.TemporaryFile()
    with _FORKS_LOCK:
        _FORKS[fork] = None
    try:
        proc = subprocess.Popen([exe, "-p", "--resume", job["sid"], "--fork-session", "--session-id", fork,
                                 "--output-format", "json", "/context"],
                                cwd=cwd, stdin=subprocess.DEVNULL, stdout=out_f, stderr=err_f, env=env)
    except OSError as e:
        out_f.close()
        err_f.close()
        with _FORKS_LOCK:
            _FORKS[fork] = time.time()
        _warn("context failed to start %s: %s" % (type(e).__name__, e))
        return "claude-not-found" if isinstance(e, FileNotFoundError) else "context-failed"
    _CTX_RUN = dict(job, cwd=cwd, fork=fork, proc=proc, out=out_f, err=err_f, started=time.monotonic(),
                    projects=projects_dir or PROJECTS_DIR)
    return None


def _ctx_result(out_f) -> tuple:
    """Read the subprocess stdout JSON -> (err, data)."""
    try:
        out_f.seek(0)
        raw = out_f.read().decode("utf-8", "replace")
        doc = json.loads(raw)
    except (OSError, ValueError):
        return "context-parse", None
    if not isinstance(doc, dict) or doc.get("is_error") or not isinstance(doc.get("result"), str):
        return "context-failed", None
    try:
        return None, parse_context_md(doc["result"])
    except ValueError:
        return "context-parse", None


def _ctx_poll(outbox_dir, sessions_dir, now, claude=None, projects_dir=None) -> int:
    """Finalize the running job (finished or timed out), then start the next from the queue. Returns the number of results written."""
    global _CTX_RUN
    count = 0
    if _CTX_RUN is not None:
        job = _CTX_RUN
        proc = job["proc"]
        rc = proc.poll()
        elapsed = time.monotonic() - job["started"]
        if rc is None and elapsed <= CONTEXT_TIMEOUT:
            return 0
        err, data = None, None
        if rc is None:  # timeout: terminate first, then kill
            err = "context-timeout"
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    proc.kill()
                    proc.wait(timeout=5)
                except (OSError, subprocess.SubprocessError):
                    pass
            except OSError:
                pass
        elif rc != 0:
            err = "context-failed"
            _warn("context exit code %d: %s" % (rc, _last_line(job["err"])))
        else:
            err, data = _ctx_result(job["out"])
        _CTX_RUN = None
        job["out"].close()
        job["err"].close()
        # when killed, claude gets no chance to delete its own registry file
        stale = os.path.join(sessions_dir, "%d.json" % proc.pid)
        if rc is None and os.path.exists(stale):
            try:
                os.unlink(stale)
            except OSError:
                pass
        removed = _remove_fork(job["fork"], job["projects"])
        with _FORKS_LOCK:
            _FORKS[job["fork"]] = time.time()
        _warn("context %s %s %.1fs fork=%s removed=%d reqs=%d" % (
            job["name"] or job["sid"], ("failed:" + err) if err else "done", elapsed, job["fork"], removed,
            len(job["reqs"])))
        for rid, claimed, _t in job["reqs"]:
            _ctx_write(outbox_dir, rid, claimed, err, data, now, job["sid"])
            count += 1
    while _CTX_RUN is None and _CTX_QUEUE:
        job = _CTX_QUEUE.pop(0)
        try:
            err = _ctx_start(job, sessions_dir, claude, projects_dir)
        except Exception as e:
            _warn("context error %s: %s" % (type(e).__name__, e))
            err = "context-failed"
        if err:
            _warn("context %s failed:%s" % (job["name"] or job["sid"], err))
            for rid, claimed, _t in job["reqs"]:
                _ctx_write(outbox_dir, rid, claimed, err, None, now, job["sid"])
                count += 1
    return count
