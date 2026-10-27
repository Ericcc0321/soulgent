"""Reply request outbox: the api only validates requests and writes request files; the host helper executes them. Nothing is executed here."""
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import time
import uuid
from typing import Any, Dict, List, Optional

MAX_TEXT = 4000
HELPER_TIMEOUT = 30
CLAIM_TIMEOUT = 60
WAKE_HELPER_TIMEOUT = 150   # wake request: helper kills the process after ~120 s, plus margin
OFF_HELPER_TIMEOUT = 90     # off-duty request: helper kills the process after 60 s, plus margin
CONTEXT_HELPER_TIMEOUT = 90  # context detail: helper runs one at a time (20 s max each), so queued ones wait longer
MAX_STEPS = 24
# "n" opens the notes box on preview questions; it is the only letter accepted
KEY_WHITELIST = ("1", "2", "3", "4", "5", "6", "7", "8", "9", "enter", "esc", "up", "down", "tab", "right", "n")
RID_RE = re.compile(r"\A[0-9a-f]{32}\Z")
_CTRL_RE = re.compile("[\x00-\x1f\x7f-\x9f]")
_NEWLINE_RE = re.compile("[\r\n  ]+")


def clean_text(s: Any) -> Optional[str]:
    """Newlines to spaces, strip control chars and surrounding whitespace; None if empty or over 4000 chars."""
    if not isinstance(s, str):
        return None
    s = _NEWLINE_RE.sub(" ", s)
    s = _CTRL_RE.sub("", s).strip()
    if not s or len(s) > MAX_TEXT:
        return None
    return s


def clean_lines(s: Any) -> Optional[str]:
    """For recall: keep newlines (normalized to \\n; quoted replies are multi-line), strip other control chars and surrounding whitespace; None if empty or too long."""
    if not isinstance(s, str):
        return None
    s = s.replace("\r\n", "\n").replace("\r", "\n").replace(" ", "\n").replace(" ", "\n")
    s = re.sub("[\x00-\x09\x0b-\x1f\x7f-\x9f]", "", s).strip()
    if not s or len(s) > MAX_TEXT:
        return None
    return s


LANGS = ("en", "hans", "hant")  # UI language (same names as the frontend i18n.js); the helper picks the prompt wording from it


def clean_lang(v: Any) -> Optional[str]:
    """Return a known language unchanged; anything else (including missing) gives None, and the payload carries no lang (helper assumes Simplified Chinese)."""
    return v if isinstance(v, str) and v in LANGS else None


def with_lang(payload: Dict[str, Any], lang: Optional[str]) -> Dict[str, Any]:
    if lang:
        payload["lang"] = lang
    return payload


MAX_QUOTE = 300


def with_quote(quote: Any, text: str) -> Optional[str]:
    """Quoted reply: "> name: text" (single line, truncated to 300 chars) + blank line + body. None if quote is not a string; an empty quote returns the body unchanged.
    When the request carries lines=true the helper pastes the whole block, so newlines are not taken as submit."""
    if quote is None:
        return text
    if not isinstance(quote, str):
        return None
    q = clean_text(quote[:MAX_TEXT])
    if not q:
        return text
    if len(q) > MAX_QUOTE:
        q = q[:MAX_QUOTE] + "…"
    out = "> " + q + ("\n\n" + text if text else "")
    return out if len(out) <= MAX_TEXT else None


def clean_steps(steps: Any) -> Optional[List[Dict[str, str]]]:
    """steps form: 1-24 steps, each exactly {key} or {text}; None if any step is invalid."""
    if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_STEPS:
        return None
    out = []  # type: List[Dict[str, str]]
    for st in steps:
        if not isinstance(st, dict) or len(st) != 1:
            return None
        if "key" in st:
            if not isinstance(st["key"], str) or st["key"] not in KEY_WHITELIST:
                return None
            out.append({"key": st["key"]})
        elif "text" in st:
            text = clean_text(st["text"])
            if text is None:
                return None
            out.append({"text": text})
        else:
            return None
    return out


_NAME_BAD_RE = re.compile(r"[^0-9A-Za-z\u4e00-\u9fff._-]")
MAX_NAME = 80
# Filesystem limit is 255 bytes: the saved-name prefix "YYYYMMDD-HHMMSS-xxxxxx-" takes 23, so the original-name part gets at most 200 UTF-8 bytes (with margin)
MAX_NAME_BYTES = 200


def _cut_bytes(s: str, limit: int) -> str:
    """Truncate by UTF-8 bytes without splitting a character."""
    b = s.encode("utf-8")
    return s if len(b) <= limit else b[:limit].decode("utf-8", "ignore")


def clean_filename(name: Any) -> str:
    """Sanitize an uploaded filename: drop the directory part, keep only letters, digits, CJK, . - _ (others become _), strip leading dots, max 80 (keeping the extension)."""
    if not isinstance(name, str):
        name = ""
    name = re.split(r"[/\\]", name)[-1]
    name = _NAME_BAD_RE.sub("_", name).lstrip(".")
    if len(name) > MAX_NAME or len(name.encode("utf-8")) > MAX_NAME_BYTES:
        stem, dot, ext = name.rpartition(".")
        if dot and stem and len(ext) <= 10:
            stem = _cut_bytes(stem[:MAX_NAME - len(ext) - 1], MAX_NAME_BYTES - len(ext.encode("utf-8")) - 1)
            name = stem + "." + ext
        else:
            name = _cut_bytes(name[:MAX_NAME], MAX_NAME_BYTES)
    return name or "file"


def upload_name(orig: Any, now: float) -> str:
    """Saved name: YYYYMMDD-HHMMSS-<6 random chars>-<sanitized original name>."""
    return "%s-%s-%s" % (time.strftime("%Y%m%d-%H%M%S", time.localtime(now)), secrets.token_hex(3),
                         clean_filename(orig))


MAX_FILES = 9
_SAVED_RE = re.compile(r"\A\d{8}-\d{6}-[0-9a-f]{6}-[0-9A-Za-z\u4e00-\u9fff._-]{1,80}\Z")


def clean_files(files: Any, uploads_dir: str) -> Optional[List[str]]:
    """Files of a message: 1-9 saved names, matching upload_name format and being real files (not symlinks) in uploads."""
    if not isinstance(files, list) or not 1 <= len(files) <= MAX_FILES:
        return None
    for f in files:
        # The saved-name format has no "/", and ".." can only appear mid-name (v1..txt), so it cannot escape the directory; a bare . or .. fails the format
        if not isinstance(f, str) or not _SAVED_RE.match(f) or f != os.path.basename(f):
            return None
        p = os.path.join(uploads_dir, f)
        if os.path.islink(p) or not os.path.isfile(p):
            return None
    return list(files)


# ---------- Request/result signing (api and helper share OUTBOX_SECRET from .env; helper/outbox.py has the same code) ----------
# signature = HMAC-SHA256(secret, domain + "\n" + compact JSON with the sig key removed, sorted by key); domain is req (written by api) / res (written by helper),
# so a request file cannot pass as a result; the signature covers the id, so a renamed file under another request id fails verification
SECRET_MIN = 32
SECRET_ENV = "OUTBOX_SECRET"


class SecretMissing(OSError):
    """OUTBOX_SECRET not set (or too short): no request file is written; callers return 500 "outbox unavailable"."""


def secret() -> bytes:
    """Read the env var each time (container env_file: .env); returns b"" if unset or shorter than 32 chars."""
    s = (os.environ.get(SECRET_ENV) or "").strip()
    return s.encode("utf-8") if len(s) >= SECRET_MIN else b""


def _canon(domain: str, obj: Dict[str, Any]) -> bytes:
    body = {k: v for k, v in obj.items() if k != "sig"}
    return (domain + "\n" + json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(",", ":"))).encode("utf-8")


def sign(domain: str, obj: Dict[str, Any], key: bytes) -> str:
    return hmac.new(key, _canon(domain, obj), hashlib.sha256).hexdigest()


def verify(domain: str, obj: Any, key: bytes) -> bool:
    if not key or not isinstance(obj, dict) or not isinstance(obj.get("sig"), str):
        return False
    return hmac.compare_digest(obj["sig"], sign(domain, obj, key))


_warned = [0.0]


def warn_secret() -> None:
    """Report a missing secret (stderr goes to docker logs), at most once a minute."""
    if time.time() - _warned[0] >= 60:
        _warned[0] = time.time()
        sys.stderr.write("outbox: %s is unset or shorter than %d chars; refusing to write requests or trust results (see .env.example)\n"
                         % (SECRET_ENV, SECRET_MIN))
        sys.stderr.flush()


def _write_atomic(path: str, obj: Dict[str, Any]) -> None:
    """Request file: sign, then write; directory and file are accessible only to the host user (0700 / 0600).
    Under Docker Desktop's fakeowner mount the container uid 10001 can still read and write; other host accounts can neither read nor forge."""
    key = secret()
    if not key:
        warn_secret()
        raise SecretMissing("OUTBOX_SECRET missing")
    obj = dict(obj)
    obj["sig"] = sign("req", obj, key)
    tmp = os.path.join(os.path.dirname(path), ".tmp-" + uuid.uuid4().hex)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.chmod(tmp, 0o600)  # independent of umask
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def enqueue(outbox_dir: str, session_id: str, payload: Dict[str, Any], account: Optional[str] = None) -> str:
    """payload is validated: type=text(text, enter) / key(key) / steps(steps) / file(file, caption) / screen. Returns rid.
    account = the initiating account (admin / guest account name), signed into the request; the helper treats any non-admin (including missing) as a guest:
    it checks just before delivery whether the session is stopped at a question/approval menu, and does not send if so."""
    rid = uuid.uuid4().hex
    req = {"id": rid, "sessionId": session_id, "type": payload["type"],
           "createdAt": time.time()}  # type: Dict[str, Any]
    if isinstance(account, str) and account:
        req["account"] = account
    if payload["type"] == "text":
        req["text"] = payload["text"]
        req["enter"] = bool(payload.get("enter", True))
    elif payload["type"] == "message":
        req["text"] = payload.get("text") or ""
        req["files"] = payload["files"]
    elif payload["type"] == "recall":  # recall a queued message: helper presses Up to pull the queue back, clears the input box, and resends the rest
        req["text"] = payload["text"]
    if payload.get("lines"):
        req["lines"] = True
    elif payload["type"] == "key":
        req["key"] = payload["key"]
    elif payload["type"] == "steps":
        req["steps"] = payload["steps"]
    elif payload["type"] == "file":
        req["file"] = payload["file"]
        req["caption"] = payload.get("caption") or ""
    if payload["type"] in ("message", "file") and clean_lang(payload.get("lang")):
        req["lang"] = payload["lang"]  # helper picks the prompt wording from it
    _write_atomic(os.path.join(outbox_dir, rid + ".req.json"), req)
    return rid


def enqueue_mark(outbox_dir: str, seen: Optional[Dict[str, float]] = None,
                 pin: Optional[Dict[str, bool]] = None, unseen: Optional[Dict[str, float]] = None) -> str:
    """Read-state / pin sync request (the helper writes the panel): {"type": "mark", "seen": {...}} or {"type": "mark", "pin": {...}}."""
    rid = uuid.uuid4().hex
    req = {"id": rid, "type": "mark", "createdAt": time.time()}  # type: Dict[str, Any]
    if seen is not None:
        req["seen"] = seen
    if pin is not None:
        req["pin"] = pin
    if unseen is not None:  # mark as unread: write seenAt back
        req["unseen"] = unseen
    _write_atomic(os.path.join(outbox_dir, rid + ".req.json"), req)
    return rid


def enqueue_wake(outbox_dir: str, session_id: str, name: str) -> str:
    """Wake an off-duty session: {"type": "wake", "name": session name}; sessionId is the sid from the roster."""
    rid = uuid.uuid4().hex
    req = {"id": rid, "sessionId": session_id, "type": "wake", "name": name, "createdAt": time.time()}
    _write_atomic(os.path.join(outbox_dir, rid + ".req.json"), req)
    return rid


def enqueue_offduty(outbox_dir: str, session_id: str, name: str) -> str:
    """Send off duty: {"type": "offduty", "sessionId", "name"}; the helper re-checks the name against the snapshot, then runs offduty.py --off."""
    rid = uuid.uuid4().hex
    req = {"id": rid, "sessionId": session_id, "type": "offduty", "name": name, "createdAt": time.time()}
    _write_atomic(os.path.join(outbox_dir, rid + ".req.json"), req)
    return rid


def enqueue_context(outbox_dir: str, session_id: str, account: Optional[str] = None) -> str:
    """Context detail: {"type": "context", "sessionId"}; the helper runs claude -p --fork-session "/context" in the session directory."""
    rid = uuid.uuid4().hex
    req = {"id": rid, "sessionId": session_id, "type": "context", "createdAt": time.time()}  # type: Dict[str, Any]
    if isinstance(account, str) and account:
        req["account"] = account
    _write_atomic(os.path.join(outbox_dir, rid + ".req.json"), req)
    return rid


def _read_json(path: str) -> Optional[Dict[str, Any]]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _result(outbox_dir: str, rid: str) -> Optional[Dict[str, Any]]:
    """The result file must be signed by the helper (res domain) and its id must be this request id; otherwise treated as absent (later reported as helper-timeout)."""
    res = _read_json(os.path.join(outbox_dir, rid + ".res.json"))
    if res is None:
        return None
    key = secret()
    if not key:
        warn_secret()
        return None
    if res.get("id") != rid or not verify("res", res, key):
        return None
    out = {"status": "failed" if res.get("status") == "failed" else "done"}  # type: Dict[str, Any]
    if res.get("error"):
        out["error"] = res["error"]
    if isinstance(res.get("message"), str) and res["message"]:
        out["message"] = res["message"]
    sent = res.get("sentSteps")
    if isinstance(sent, int) and not isinstance(sent, bool) and sent > 0:
        out["sentSteps"] = sent
    if isinstance(res.get("lines"), list):
        out["lines"] = res["lines"]
    if res.get("type") == "context":  # context detail: parsed data and session id (api writes its cache from these)
        if isinstance(res.get("data"), dict):
            out["data"] = res["data"]
        if isinstance(res.get("sessionId"), str):
            out["sessionId"] = res["sessionId"]
        if isinstance(res.get("finishedAt"), (int, float)) and not isinstance(res.get("finishedAt"), bool):
            out["at"] = res["finishedAt"]
    return out


def _age_failed(path: str, now: float, limit: float, wake_limit: Optional[float] = None) -> Optional[bool]:
    """If the file exists, return whether it is older than limit seconds (wake requests use wake_limit; by createdAt, falling back to mtime); None if it does not exist."""
    try:
        created = os.stat(path).st_mtime
    except OSError:
        return None
    req = _read_json(path)
    if wake_limit is not None and req and req.get("type") == "wake":
        limit = wake_limit
    elif wake_limit is not None and req and req.get("type") == "offduty":
        limit = OFF_HELPER_TIMEOUT
    elif wake_limit is not None and req and req.get("type") == "context" and path.endswith(".claimed"):
        limit = CONTEXT_HELPER_TIMEOUT  # once claimed, it queues inside the helper; unclaimed ones still use 30 s
    try:
        created = float(req["createdAt"]) if req else created
    except (KeyError, TypeError, ValueError):
        pass
    return now - created > limit


def request_status(outbox_dir: str, rid: str, now: float) -> Optional[Dict[str, Any]]:
    """rid must already be validated as 32 hex chars. Priority: result file > claim file (60 s) > request file (30 s) > None; wake requests use 150 s for both."""
    out = _result(outbox_dir, rid)
    if out is not None:
        return out
    timeout = {"status": "failed", "error": "helper-timeout"}
    old = _age_failed(os.path.join(outbox_dir, rid + ".claimed"), now, CLAIM_TIMEOUT, WAKE_HELPER_TIMEOUT)
    if old is not None:
        return timeout if old else {"status": "pending"}
    old = _age_failed(os.path.join(outbox_dir, rid + ".req.json"), now, HELPER_TIMEOUT, WAKE_HELPER_TIMEOUT)
    if old is not None:
        return timeout if old else {"status": "pending"}
    # the helper may have just written the result and removed the claim/request during the check
    return _result(outbox_dir, rid)
