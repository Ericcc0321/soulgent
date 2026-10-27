"""Guest accounts config (each guest sees only its own bound session): key, bound session, message tag, admin-only proxy prefixes.

All names live in .env. First guest (account "guest"): GUEST_KEY, GUEST_SESSION, GUEST_TAG,
GUEST_NAME, and GUEST_LEGACY_ACCOUNT (optional: that guest's old internal name on older deployments; unset = no legacy handling).
More guests: GUESTn_ID / GUESTn_KEY / GUESTn_SESSION / GUESTn_TAG / GUESTn_NAME for n = 2..MAX_GUESTS (see load_guests).
ADMIN_ONLY_PREFIXES: admin-only proxy prefixes. GUEST_SLASH_COMMANDS: slash commands guests may send (see slash_commands)."""
import json
import os
import re
import sys
from typing import Dict, List, Mapping, Optional, Tuple

ACCOUNT = "guest"          # guest account name (the cookie is derived from the key only, not the account name; see server._token)
DEFAULT_TAG = "[Guest]"    # prefix the server adds before each guest message (when GUEST_TAG is unset)
TAG_MAX = 24
MAX_GUESTS = 9             # GUEST2_* ... GUEST9_* (the first guest uses the unnumbered GUEST_*)
KEY_MIN = 24               # minimum guest key length (same as WEBAPP_KEY)
ID_RE = re.compile(r"[a-z0-9]{1,16}")  # guest id from the second guest on = account name = storage name (the frontend's local read-marker keys accept only this charset)
_IMG = r"(?:\[Image #\d+\]\s*)*"  # Claude Code turns a pasted image into "[Image #N] " placed before the prefix
_LEGACY_RE = re.compile(r"[A-Za-z0-9_-]{1,32}")


def env(name: str, environ: Optional[Mapping[str, str]] = None) -> str:
    """Read a .env field, stripped of surrounding whitespace."""
    environ = os.environ if environ is None else environ
    return (environ.get(name) or "").strip()


def legacy_account(environ: Optional[Mapping[str, str]] = None) -> str:
    """GUEST_LEGACY_ACCOUNT: the legacy guest account name (state volume profile-<name>.json / avatar-<name>.jpg,
    the account in push.json subscriptions, and ?account= from older frontends). If unset, no legacy-name handling is done.
    It goes into file names, so only letters, digits, underscore and hyphen are accepted, and it cannot be guest / admin (admin would make the administrator a guest); an invalid value counts as unset."""
    v = env("GUEST_LEGACY_ACCOUNT", environ)
    if not _LEGACY_RE.fullmatch(v) or v in (ACCOUNT, "admin"):
        return ""
    return v


ROSTER_MODES = ("all", "bound")


def roster_mode(environ: Optional[Mapping[str, str]] = None) -> str:
    """GUEST_ROSTER: how much of the roster a guest snapshot carries. all = the whole roster (minus sessions bound to other guests); bound = only the guest's own bound session.
    Unset or any other value means bound."""
    v = env("GUEST_ROSTER", environ).lower()
    return v if v in ROSTER_MODES else "bound"


def normalize_account(acc: object, environ: Optional[Mapping[str, str]] = None) -> object:
    """If a legacy account name is configured, treat it as the guest (old push.json subscriptions, ?account= from older frontends); otherwise return it unchanged."""
    legacy = legacy_account(environ)
    return ACCOUNT if legacy and acc == legacy else acc


def clean_tag(v: object) -> str:
    """GUEST_TAG: stripped; empty, too long, or containing inner whitespace or control characters falls back to the default (the prefix is always followed by one space, so it cannot contain any)."""
    if not isinstance(v, str):
        return DEFAULT_TAG
    v = v.strip()
    if not v or len(v) > TAG_MAX or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in v):
        return DEFAULT_TAG
    return v


def tag(environ: Optional[Mapping[str, str]] = None) -> str:
    """GUEST_TAG; unset or invalid falls back to the default."""
    return clean_tag(env("GUEST_TAG", environ))


def own_re(t: str) -> "re.Pattern[str]":
    """A guest's own message: the prefix (after any [Image #N]) followed by a space or end of text (attachment-only messages are just the prefix). Used for recall and queue counts."""
    return re.compile(_IMG + re.escape(t) + r"(?: |$)")


def said_by_guest(text: str, t: str) -> bool:
    """Search from-tagging: starts with the prefix plus a space (optionally after [Image #N]), or the whole message is just the prefix (attachment only)."""
    return bool(re.match(_IMG + re.escape(t) + " ", text)) or text.strip() == t


def admin_only_prefixes(environ: Optional[Mapping[str, str]] = None) -> Tuple[str, ...]:
    """ADMIN_ONLY_PREFIXES: comma-separated path prefixes (e.g. /docs,/tools); guests get 403, admin passes (for private reverse proxies).
    Each must start with /, have no trailing slash and already be a canonical path; invalid ones are dropped."""
    environ = os.environ if environ is None else environ
    out = []
    for p in (environ.get("ADMIN_ONLY_PREFIXES") or "").split(","):
        p = p.strip().rstrip("/")
        if not p.startswith("/") or "//" in p or "\\" in p or "%" in p or any(ord(c) < 33 for c in p):
            continue
        if any(seg in (".", "..") for seg in p.split("/")[1:]):
            continue
        if p not in out:
            out.append(p)
    return tuple(out)


def slash_commands(environ: Optional[Mapping[str, str]] = None) -> Tuple[str, ...]:
    """GUEST_SLASH_COMMANDS: comma-separated slash commands guests may send (e.g. /compact,/foo; arguments allowed when sending).
    Each entry is stripped; entries that do not start with / or contain whitespace are dropped. Unset or empty = guests cannot send any slash command."""
    out = []
    for c in env("GUEST_SLASH_COMMANDS", environ).split(","):
        c = c.strip()
        if not c.startswith("/") or len(c) < 2 or any(ch.isspace() for ch in c):
            continue
        if c not in out:
            out.append(c)
    return tuple(out)


def store_id(state_dir: str, environ: Optional[Mapping[str, str]] = None) -> str:
    """Which name the guest's profile / push subscriptions use in the state volume. If a legacy account name is configured and legacy-named data exists (and no new-named data),
    keep using the legacy name: nothing is migrated or rewritten, so rolling back still reads it; with no legacy name or a fresh deployment, use the generic name."""
    def has(acc: str) -> bool:
        return any(os.path.isfile(os.path.join(state_dir, f % acc)) for f in ("profile-%s.json", "avatar-%s.jpg"))
    if has(ACCOUNT):
        return ACCOUNT
    legacy = legacy_account(environ)
    if legacy and (has(legacy) or _push_has(os.path.join(state_dir, "push.json"), legacy)):
        return legacy
    return ACCOUNT


def _push_has(path: str, acc: str) -> bool:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    subs = data.get("subscriptions") if isinstance(data, dict) else None
    return any(isinstance(s, dict) and s.get("account") == acc for s in subs or [])


def labels(state_dir: str, environ: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """Account name -> storage name (the account in push.json, the profile file suffix)."""
    return {ACCOUNT: store_id(state_dir, environ)}


class Guest:
    """One guest: account (account name; the first is always guest, the rest = id), key, session (full name of the bound session), tag (prefix), name (default nickname),
    store (name used for profile / push subscriptions in the state volume; the first guest follows store_id and may keep the legacy name, the rest = account name)."""

    def __init__(self, account: str, key: str, session: str = "", tag: str = DEFAULT_TAG, name: str = "",
                 store: str = "") -> None:
        self.account = account
        self.key = key
        self.session = (session or "").strip()
        self.tag = clean_tag(tag)
        self.own_re = own_re(self.tag)
        self.name = name
        self.store = store or account

    def __repr__(self) -> str:  # never print the key
        return "Guest(%s, %s, %s)" % (self.account, self.session, self.tag)


def _warn(msg: str) -> None:
    sys.stderr.write(msg + "\n")


def load_guests(admin_key: str, environ: Optional[Mapping[str, str]] = None,
                name_of=None) -> List["Guest"]:
    """.env -> guest list (in order; the first is GUEST_*, account name guest). A guest that fails validation is disabled entirely (the reason goes to stderr, never the key):
    key shorter than 24 or equal to WEBAPP_KEY or an earlier guest's key; id not 1-16 lowercase alphanumerics, equal to guest / admin / the legacy account name, or duplicated;
    prefix equal to an earlier guest's (the prefix is the only way to tell who spoke: recall, queue counts and search labels all rely on it).
    GUESTn_TAG defaults to "[ID uppercased]"; GUESTn_NAME defaults to name_of (profile.guest_name_of). Gaps in the numbering are skipped."""
    environ = os.environ if environ is None else environ
    name_of = name_of or (lambda v: v)
    out = []  # type: List[Guest]
    legacy = legacy_account(environ)

    def ok_key(k: str, label: str) -> bool:
        if len(k) < KEY_MIN or k == admin_key:
            _warn("%s is too short or equals WEBAPP_KEY; this guest is disabled" % label)
            return False
        if any(g.key == k for g in out):
            _warn("%s equals an earlier guest key; this guest is disabled" % label)
            return False
        return True

    def ok_tag(t: str, label: str) -> bool:
        if any(g.tag == t for g in out):
            _warn("%s equals an earlier guest prefix; this guest is disabled" % label)
            return False
        return True

    k = env("GUEST_KEY", environ)
    if k and ok_key(k, "GUEST_KEY"):
        out.append(Guest(ACCOUNT, k, env("GUEST_SESSION", environ), tag(environ), name_of(env("GUEST_NAME", environ))))
    for n in range(2, MAX_GUESTS + 1):
        pre = "GUEST%d_" % n
        k = env(pre + "KEY", environ)
        if not k:
            continue
        gid = env(pre + "ID", environ)
        if not ID_RE.fullmatch(gid) or gid in (ACCOUNT, "admin") or (legacy and gid == legacy) \
                or any(g.account == gid for g in out):
            _warn("%s ID is invalid (1-16 lowercase alphanumerics, not guest / admin / the legacy account name, no duplicates); this guest is disabled" % pre)
            continue
        if not ok_key(k, pre + "KEY"):
            continue
        raw_tag = env(pre + "TAG", environ)
        t = clean_tag(raw_tag) if raw_tag else clean_tag("[%s]" % gid.upper())
        if not ok_tag(t, pre + "TAG"):
            continue
        out.append(Guest(gid, k, env(pre + "SESSION", environ), t, name_of(env(pre + "NAME", environ))))
    return out
