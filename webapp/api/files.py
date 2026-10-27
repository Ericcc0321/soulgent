"""Bubble attachments: path allow-list policy, file type detection, signed file URLs.

Leaf module: standard library only, imports nothing else from the project.
Every check fails closed by returning None / empty, never by raising.
"""
import base64
import binascii
import hashlib
import hmac
import mimetypes
import os
import re
import shlex
from typing import Dict, List, Optional, Tuple

# Size limits (bytes)
IMG_MAX = 30 * 2**20  # images
DOC_MAX = 80 * 2**20  # other documents
THUMB_SKIP = 12 * 2**20  # images larger than this get no thumbnail

# extension -> kind
KIND_BY_EXT = {
    "png": "image", "jpg": "image", "jpeg": "image", "webp": "image", "gif": "image", "svg": "image",
    "pdf": "pdf",
    "doc": "doc", "docx": "doc",
    "xls": "sheet", "xlsx": "sheet",
    "ppt": "slide", "pptx": "slide",
    "md": "md",
    "txt": "text",
    "htm": "html", "html": "html",
    "json": "data", "csv": "data",  # data: the in-app reader shows plain text (truncated at 2 MB)
}  # type: Dict[str, str]

# json is recognized only in Markdown link/image syntax, not as a bare path
_LINK_ONLY_EXT = ("json",)

_CT = {
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
    "gif": "image/gif", "svg": "image/svg+xml", "pdf": "application/pdf",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "csv": "text/csv", "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "md": "text/markdown", "txt": "text/plain", "htm": "text/html", "html": "text/html",
    "json": "application/json",
}  # type: Dict[str, str]


def _ext(name):  # type: (str) -> str
    return os.path.splitext(name or "")[1].lstrip(".").lower()


def classify(name, in_link=False):  # type: (str, bool) -> Optional[str]
    """Return the kind for an extension; None if unknown. json is recognized only when in_link=True."""
    if not isinstance(name, str):
        return None
    e = _ext(name)
    if e in _LINK_ONLY_EXT and not in_link:
        return None
    return KIND_BY_EXT.get(e)


def content_type(name):  # type: (str) -> str
    if not isinstance(name, str):
        return "application/octet-stream"
    e = _ext(name)
    return _CT.get(e) or mimetypes.guess_type("x." + e)[0] or "application/octet-stream"


def content_disposition(name, attach=False):  # type: (str, bool) -> str
    """Content-Disposition: attachment (download) or inline; filename*=UTF-8'' percent-encoding preserves CJK names,
    and attachment adds an ASCII fallback filename (non-ASCII/quotes/backslashes/percent signs become _), so the header never contains non-ASCII or newlines."""
    from urllib.parse import quote
    star = "filename*=UTF-8''" + quote(name, safe="")
    if not attach:
        return "inline; " + star
    fb = "".join(c if 0x20 <= ord(c) < 0x7f and c not in '"\\%;' else "_" for c in name) or "download"
    return 'attachment; filename="%s"; %s' % (fb, star)


# ---------------------------------------------------------------- path allowlist

class Roots:
    """Mapping of host root -> container root. Only paths inside these roots can be fetched."""

    def __init__(self, pairs, home=None):  # type: (List[Tuple[str, str]], Optional[str]) -> None
        # longest prefix first, so a nested root is not shadowed by a shorter one
        self.pairs = sorted(pairs, key=lambda p: -len(p[0]))
        # host home: HOME inside the container is not the host's, so `~/` must expand against the host home
        self.home = home or os.environ.get("HOST_HOME") or os.path.expanduser("~")

    @classmethod
    def from_spec(cls, spec, home=None):  # type: (str, Optional[str]) -> Roots
        """Parse `host=container:host=container...`; an empty string or a bad entry means no such root."""
        pairs = []  # type: List[Tuple[str, str]]
        for item in (spec or "").split(":"):
            host, sep, cont = item.partition("=")
            host, cont = host.strip(), cont.strip()
            if not sep or not host.startswith("/") or not cont.startswith("/"):
                continue
            pairs.append((os.path.normpath(host), os.path.normpath(cont)))
        return cls(pairs, home)

    def expand(self, host_path):  # type: (str) -> Optional[str]
        """Expand `~/` in a host path (against the host home); it must be absolute; no normpath. Returns None if invalid."""
        if not isinstance(host_path, str) or not host_path:
            return None
        p = host_path
        if p.startswith("~"):  # only `~` and `~/...` are accepted; `~root/...` is always rejected
            if p != "~" and not p.startswith("~/"):
                return None
            p = self.home.rstrip("/") + p[1:]
        return p if p.startswith("/") else None

    def _match(self, host_path):  # type: (str) -> Optional[Tuple[str, str]]
        """Return (container root, container path); None if not inside any root."""
        try:
            p = self.expand(host_path)
            if p is None:
                return None
            p = os.path.normpath(p)
            if p == "/tmp" or p.startswith("/tmp/"):
                p = "/private" + p
            for host, cont in self.pairs:
                if p == host:
                    return cont, cont
                pre = host if host.endswith("/") else host + "/"
                if p.startswith(pre):
                    return cont, os.path.join(cont, p[len(pre):])
        except Exception:
            pass
        return None

    def to_container(self, host_path):  # type: (str) -> Optional[str]
        m = self._match(host_path)
        return m[1] if m else None

    def resolve(self, host_path):  # type: (str) -> Optional[str]
        """realpath after to_container; returned only if still inside the same container root and a regular file (blocks symlink escape)."""
        try:
            m = self._match(host_path)
            if not m:
                return None
            real = os.path.realpath(m[1])
            root = os.path.realpath(m[0])
            if not (real == root or real.startswith(root.rstrip("/") + "/")):
                return None
            # a symlink inside a root may point at something like .env: the target extension must also be a recognized type
            if classify(os.path.basename(real), in_link=True) is None:
                return None
            return real if os.path.isfile(real) else None
        except Exception:
            return None


# ---------------------------------------------------------------- Guests fetching files named in Agent replies: three restrictions

# Extension allowlist (case-insensitive). zip is excluded: the contents of an archive cannot be seen
GUEST_EXTS = frozenset(("xlsx", "xls", "csv", "docx", "doc", "pptx", "ppt", "pdf", "md", "txt",
                        "png", "jpg", "jpeg", "gif", "webp"))
# The filename is first split into segments on non-alphanumerics (ASCII), then into words by camel case; rejected if any word (case-insensitive) equals one of these. Word-based, not substring, so "monkey" is not caught
GUEST_BAD_WORDS = frozenset(("env", "secret", "secrets", "token", "tokens", "key", "keys", "apikey",
                             "credential", "credentials", "password", "passwd", "pem"))
# Chinese has no word boundaries: substring match on the whole filename
GUEST_BAD_CN = ("密钥", "密码", "口令", "凭证", "令牌")
_WORD_SPLIT = re.compile(r"[^A-Za-z0-9]+")
# camelCase: APIKey -> API,Key; secretKey -> secret,Key; digits form their own word
_CAMEL = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+")


def _bad_name(name):  # type: (str) -> bool
    name = name or ""
    if any(w in name for w in GUEST_BAD_CN):
        return True
    for frag in _WORD_SPLIT.split(name):
        if frag.lower() in GUEST_BAD_WORDS:
            return True
        if any(w.lower() in GUEST_BAD_WORDS for w in _CAMEL.findall(frag)):
            return True
    return False


def _name_why(name):  # type: (str) -> Optional[str]
    if _bad_name(name):
        return "name"
    if _ext(name) not in GUEST_EXTS:
        return "ext"
    return None


def _canon(p):  # type: (str) -> str
    p = os.path.normpath(p)
    return "/private" + p if p == "/tmp" or p.startswith("/tmp/") else p


def _cwd_too_wide(roots, cwd, croot):  # type: (Roots, str, str) -> bool
    """cwd is home or a mount root itself (too broad): checked on the host path and again after realpath."""
    host_wide = {_canon(roots.home)} | {_canon(h) for h, _ in roots.pairs}
    ecwd = roots.expand(cwd)
    if ecwd is not None and _canon(ecwd) in host_wide:
        return True
    wide = set()
    for h in [roots.home] + [h for h, _ in roots.pairs]:
        c = roots.to_container(h)
        if c:
            wide.add(os.path.realpath(c))
    wide.update(os.path.realpath(c) for _, c in roots.pairs)
    return croot in wide


def guest_file_ok(host_path, cwd, roots):  # type: (str, Optional[str], Roots) -> Optional[str]
    """Whether a guest may fetch this "file named in an Agent reply": None if allowed, otherwise the rejection reason:
    dot (any segment below cwd starts with ., including ..) / name (filename contains a sensitive word) / ext (not in the allowlist) /
    cwd (no cwd, cwd too broad [home or a mount root itself], or the file is not under cwd) / path (cannot be fetched).
    host_path and cwd are host paths; they are mapped to the container by roots, then realpath prefixes are compared (blocks ../ and symlinks).
    Dot segments are checked only among the segments relative to cwd (a cwd that itself lies under .claude/worktrees/... is unaffected), both on the string and after realpath.
    Shared by the page allowlist and the /api/file recheck."""
    try:
        hp = roots.expand(host_path) if isinstance(host_path, str) else None
        if hp is None:
            return "path"
        if ".." in hp.split("/"):  # no .. allowed at string level
            return "dot"
        cn = roots.to_container(cwd) if isinstance(cwd, str) and cwd.startswith(("/", "~/")) else None
        if not cn:
            return "cwd"
        croot = os.path.realpath(cn)
        if not os.path.isdir(croot):
            return "cwd"
        if _cwd_too_wide(roots, cwd, croot):
            return "cwd"
        hcwd = _canon(roots.expand(cwd))
        nhp = _canon(hp)
        if nhp.startswith(hcwd.rstrip("/") + "/"):
            if any(seg.startswith(".") for seg in nhp[len(hcwd.rstrip("/")) + 1:].split("/")):
                return "dot"
        why = _name_why(os.path.basename(hp))
        if why:
            return why
        real = roots.resolve(host_path)
        if not real:
            return "path"
        pre = croot.rstrip("/") + "/"
        if not real.startswith(pre):
            return "cwd"
        if any(seg.startswith(".") for seg in real[len(pre):].split("/")):
            return "dot"
        return _name_why(os.path.basename(real))
    except Exception:
        return "path"


# ---------------------------------------------------------------- path recognition

_BARE_EXTS = "|".join(sorted((e for e in KIND_BY_EXT if e not in _LINK_ONLY_EXT), key=len, reverse=True))
_ALL_EXTS = "|".join(sorted(KIND_BY_EXT, key=len, reverse=True))
_HEAD = r"(?:/(?:Users|tmp|private|Volumes)|~)/"

PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_/])(" + _HEAD + r"[^\s\"'`<>()\[\]]+?\.(?:" + _BARE_EXTS + r"))(?![A-Za-z0-9_/])", re.I)
# Markdown link/image `[..](path)` / `![..](path)`; spaces allowed in the path; json is also recognized
_MD_RE = re.compile(
    r"!?\[[^\]\n]*\]\(\s*<?(" + _HEAD + r"[^)\n<>]+?\.(?:" + _ALL_EXTS + r"))>?\s*\)", re.I)


def find_paths(text):  # type: (str) -> List[Tuple[str, str]]
    """File paths in body text -> [(path, src)], src is "md" or "text"; deduplicated, order kept, `~/` left as is."""
    if not isinstance(text, str) or not text:
        return []
    hits = []  # type: List[Tuple[int, str, str]]
    spans = []  # type: List[Tuple[int, int]]
    for m in _MD_RE.finditer(text):
        hits.append((m.start(1), m.group(1), "md"))
        spans.append((m.start(), m.end()))
    for m in PATH_RE.finditer(text):
        if any(a <= m.start(1) < b for a, b in spans):  # already taken by md syntax
            continue
        hits.append((m.start(1), m.group(1), "text"))
    out = []  # type: List[Tuple[str, str]]
    seen = set()
    for _, path, src in sorted(hits):
        if path not in seen:
            seen.add(path)
            out.append((path, src))
    return out


_SEP_TOKEN = re.compile(r"^[;&|()]+$")
_REDIR = re.compile(r"^\d*>")  # redirection: `>`, `2>`, `>>`, `>/dev/null`
_REDIR_BARE = re.compile(r"^\d*>>?$")
_OPEN_VALUE_FLAGS = ("-a", "-b")  # open options that take an argument


def open_targets(command):  # type: (str) -> List[str]
    """Local paths in a Bash `open` command (skipping options, `-a App`, URLs, redirections).
    Split on && ; | || & and newlines, take all segments starting with open, deduplicated in order. Returns [] for non-open commands."""
    try:
        if not isinstance(command, str) or "open" not in command:
            return []
        lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        segs = [[]]  # type: List[List[str]]
        for t in lex:
            if _SEP_TOKEN.match(t):
                segs.append([])
            else:
                segs[-1].append(t)
        out = []  # type: List[str]
        for seg in segs:
            if not seg or os.path.basename(seg[0]) != "open":
                continue
            skip = False
            for a in seg[1:]:
                if skip:
                    skip = False
                elif a == "--args":
                    break
                elif _REDIR.match(a):
                    skip = bool(_REDIR_BARE.match(a))  # the target is in the next word
                elif a in _OPEN_VALUE_FLAGS:
                    skip = True
                elif a.startswith("-"):
                    continue
                elif (a.startswith("/") or a.startswith("~/")) and a not in out:
                    out.append(a)
        return out
    except Exception:
        return []


# ---------------------------------------------------------------- inline-image line fingerprint

FP_HEAD = 256  # fingerprint covers this many bytes at the line start


def line_fp(line):  # type: (bytes) -> str
    """Fingerprint of a line (without newline): first 8 hex chars of the sha1 of the first FP_HEAD bytes (the whole line if shorter).
    An inline-image ref carries it and it is recomputed when fetching the image, so an offset from another record file (previous window, subagent) cannot read the wrong image."""
    return hashlib.sha1(line[:FP_HEAD]).hexdigest()[:8]


# ---------------------------------------------------------------- signing

def file_secret(webapp_key):  # type: (str) -> bytes
    return hashlib.sha256(b"file:" + (webapp_key or "").encode("utf-8")).digest()


def _b64(b):  # type: (bytes) -> str
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def _mac(body, secret):  # type: (str, bytes) -> str
    return hmac.new(secret, body.encode("ascii"), hashlib.sha256).hexdigest()


def sign(path, exp, secret):  # type: (str, int, bytes) -> str
    """`base64url(path) . exp . hex(hmac)`"""
    body = "%s.%d" % (_b64(path.encode("utf-8")), exp)
    return body + "." + _mac(body, secret)


def verify(tok, secret, now):  # type: (str, bytes, int) -> Optional[str]
    """Return path if the signature is valid and unexpired, otherwise None."""
    try:
        if not isinstance(tok, str):
            return None
        parts = tok.split(".")
        if len(parts) != 3:
            return None
        b, e, mac = parts
        if not hmac.compare_digest(mac, _mac(b + "." + e, secret)):
            return None
        if now > int(e):
            return None
        return base64.urlsafe_b64decode(b + "=" * (-len(b) % 4)).decode("utf-8")
    except (ValueError, binascii.Error, UnicodeError):
        return None
    except Exception:
        return None


# Guests viewing files in Agent replies: a different tok that carries the session sid; its segment count differs from the upload tok (3 segments) and the signed content has an "m" prefix, so neither can impersonate the other
MSG_TAG = "m"


def sign_msg(sid, path, exp, secret):  # type: (str, str, int, bytes) -> str
    """`m . base64url(sid) . base64url(path) . exp . hex(hmac)`, hmac covers the first 4 segments."""
    body = "%s.%s.%s.%d" % (MSG_TAG, _b64(sid.encode("utf-8")), _b64(path.encode("utf-8")), exp)
    return body + "." + _mac(body, secret)


def is_msg_tok(tok):  # type: (str) -> bool
    return isinstance(tok, str) and tok.startswith(MSG_TAG + ".") and tok.count(".") == 4


def verify_msg(tok, secret, now):  # type: (str, bytes, int) -> Optional[Tuple[str, str]]
    """Return (sid, path) if the signature and type are valid and unexpired, otherwise None."""
    try:
        if not is_msg_tok(tok):
            return None
        tag, s, b, e, mac = tok.split(".")
        if not hmac.compare_digest(mac, _mac("%s.%s.%s.%s" % (tag, s, b, e), secret)):
            return None
        if now > int(e):
            return None
        dec = lambda x: base64.urlsafe_b64decode(x + "=" * (-len(x) % 4)).decode("utf-8")  # noqa: E731
        sid, path = dec(s), dec(b)
        return (sid, path) if sid and path else None
    except Exception:
        return None
