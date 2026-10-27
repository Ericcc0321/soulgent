#!/usr/bin/env python3
"""Show Claude Code session info on project folders in Finder.

For every project folder this writes two pieces of Finder metadata, leaving
folder names and paths untouched:
  * tags (coloured dots): status of the sessions open in that folder, or
    a "stale" tag when nothing has happened there for STALE_DAYS
  * comment: last-used date, open sessions, recently closed sessions

Project folders are the direct subfolders of each --root. A root that sits
directly inside another root is a container, not a project: its own
subfolders are the projects. Without --root the roots are those of ~/Projects,
~/Developer and ~/code that exist.

Its data (scan caches, the original comments for --restore, the log) lives in
~/Library/Application Support/Soulgent/, shared with Soulgent.app.

Usage:
  finder_sessions.py [--root DIR]... [--only NAME[,NAME...]] [--lang LANG] [--dry-run] [--restore]

Language (--lang en | zh-Hans | zh-Hant; zh-TW/HK/MO mean zh-Hant, any other zh-* zh-Hans; default zh-Hans) picks the tag names and the
words in the comment. A launchd job has no LANG to go by, so it is always an explicit argument. The tag names of the other
language are retired: they come off the folders on the next run and the new ones take their place (same colours), and
--restore takes both off. Tags of your own are never touched.
"""
import argparse
import fcntl
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

HOME = Path.home()
DEFAULT_ROOTS = [p for p in (HOME / "Projects", HOME / "Developer", HOME / "code") if p.is_dir()]  # without --root
TRANSCRIPTS = HOME / ".claude" / "projects"
HISTORY = HOME / ".claude" / "history.jsonl"  # every prompt typed, kept after transcripts are cleaned up
SESSION_REGISTRY = HOME / ".claude" / "sessions"  # one <pid>.json per running session
STATE_DIR = HOME / "Library" / "Application Support" / "Soulgent"  # shared with Soulgent.app
STATE_FILE = STATE_DIR / "state.json"
ORIGINALS_FILE = STATE_DIR / "original-metadata.json"
LOG_FILE = STATE_DIR / "launchd.log"
CLAUDE_FALLBACKS = [HOME / ".local/bin/claude", Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude")]

STALE_DAYS = 90
CLOSED_SHOWN = 3  # closed session names listed per folder
GONE_SHOWN = 2  # cleaned-up sessions listed per folder, by their first prompt
MONO_DIGITS = {ord("0") + i: 0x1D7F6 + i for i in range(10)}  # 𝟶-𝟿, all the same width
FIGURE_SPACE = " "  # as wide as one digit
PASTE_MARK = re.compile(r"\[(?:Pasted text|Image)[^\]]*\]")
NAME_MAX = 24
FILE_SCAN_EVERY = 3600  # seconds between "newest file" scans of a folder
FILE_SCAN_DEPTH = 4
FILE_SCAN_LIMIT = 20000
PRUNE = {".git", "node_modules", ".venv", "venv", "__pycache__", ".cache"}

# What the language chooses: the four tag names (colours and glyphs do not change with it) and the comment's words.
LANGS = {
    "zh-Hans": {
        "tags": {"waiting": "CC-等你处理", "busy": "CC-在用", "idle": "CC-空闲", "stale": "CC-久未使用"},
        "untitled": "未命名",
        "closed": lambda n, names: f"已关闭 {n} 个" + ("：" + "、".join(names) if names else ""),
        "gone": lambda n, texts: f"已清理 {n} 个：" + "、".join(texts),
    },
    "zh-Hant": {
        "tags": {"waiting": "CC-等你處理", "busy": "CC-使用中", "idle": "CC-閒置", "stale": "CC-久未使用"},
        "untitled": "未命名",
        "closed": lambda n, names: f"已關閉 {n} 個" + ("：" + "、".join(names) if names else ""),
        "gone": lambda n, texts: f"已清理 {n} 個：" + "、".join(texts),
    },
    "en": {
        "tags": {"waiting": "CC-Waiting", "busy": "CC-Working", "idle": "CC-Idle", "stale": "CC-Stale"},
        "untitled": "Untitled",
        "closed": lambda n, names: f"{n} closed" + (": " + ", ".join(names) if names else ""),
        "gone": lambda n, texts: f"{n} cleaned up: " + ", ".join(texts),
    },
}
DEFAULT_LANG = "zh-Hans"  # what a run without --lang uses
# status -> (tag name, Finder colour index, glyph used in the comment); set by set_lang
STATUS = {}
STATUS_ORDER = ["waiting", "busy", "idle"]
STALE_TAG = ("", 7)
RETIRED_TAGS = set()  # the other languages' names and the old ones: still stripped from folders
MANAGED = set()  # every tag name this tool owns: replaced on a folder, taken off by --restore
WORDS = LANGS[DEFAULT_LANG]


def normalize_lang(code):
    """'en' -> en; Chinese by its script when it names one ('zh-Hans-HK' is simplified), else by its region: 'zh-Hant',
    'zh-TW', 'zh-HK', 'zh-MO' -> zh-Hant; any other 'zh' ('zh', 'zh-CN', 'zh_SG' ...) -> zh-Hans. None for anything else."""
    c = str(code).replace("_", "-").lower()
    if c == "en" or c.startswith("en-"):
        return "en"
    if not c.startswith("zh"):
        return None
    parts = c.split("-")[1:]
    if "hans" in parts or "hant" in parts:
        return "zh-Hant" if "hant" in parts else "zh-Hans"
    return "zh-Hant" if any(part in ("tw", "hk", "mo") for part in parts) else "zh-Hans"


def set_lang(lang):
    """Chooses the tag names and words. The names of every other language join the retired ones, so a change of language
    swaps the tags on the next run (the colours stay) and a folder never keeps both."""
    global STATUS, STALE_TAG, RETIRED_TAGS, MANAGED, WORDS
    WORDS = LANGS[lang]
    names = WORDS["tags"]
    STATUS = {"waiting": (names["waiting"], 6, "🔴"), "busy": (names["busy"], 2, "🟢"), "idle": (names["idle"], 1, "⚪")}
    STALE_TAG = (names["stale"], 7)
    # The two Chinese share the stale tag: a name of this language is never retired.
    RETIRED_TAGS = {n for other, w in LANGS.items() if other != lang for n in w["tags"].values()} - set(names.values())
    MANAGED = {t[0] for t in STATUS.values()} | {STALE_TAG[0]} | RETIRED_TAGS


set_lang(DEFAULT_LANG)
TAG_XATTR = "com.apple.metadata:_kMDItemUserTags"

GET_COMMENTS = """
on run argv
    set out to {}
    tell application "Finder"
        repeat with p in argv
            set end of out to (comment of ((POSIX file (contents of p)) as alias))
        end repeat
    end tell
    set AppleScript's text item delimiters to (character id 30)
    return out as text
end run"""

SET_COMMENTS = """
on run argv
    tell application "Finder"
        repeat with i from 1 to (count of argv) by 2
            set comment of ((POSIX file (item i of argv)) as alias) to (item (i + 1) of argv)
        end repeat
    end tell
end run"""

# Finder does not always redraw the dots after an xattr change.
UPDATE_ITEMS = """
on run argv
    tell application "Finder"
        repeat with p in argv
            try
                update ((POSIX file (contents of p)) as alias)
            end try
        end repeat
    end tell
end run"""


def nfc(s):
    return unicodedata.normalize("NFC", s)


def short(name):
    name = " ".join(str(name).split())
    return name if len(name) <= NAME_MAX else name[:NAME_MAX] + "…"


def osa(script, args):
    r = subprocess.run(["/usr/bin/osascript", "-e", script, *args], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout


def project_folders(roots):
    """The direct subfolders of each root, except those that are roots themselves (containers). A missing root is skipped."""
    roots = [Path(os.path.expanduser(str(r))).resolve() for r in roots]
    containers = {nfc(str(r)) for r in roots}
    out, seen = [], set()
    for root in roots:
        if not root.is_dir():
            continue
        for p in sorted(root.iterdir()):
            if not p.is_dir() or p.name.startswith(".") or nfc(str(p)) in containers or nfc(str(p)) in seen:
                continue
            seen.add(nfc(str(p)))
            out.append(p)
    return out


class NoClaudeCode(RuntimeError):
    """Claude Code is not on this Mac (no claude command, no session registry): there are no sessions to show."""


NO_CLAUDE_NOTE = STATE_DIR / "finder-no-claude-code"  # there: the log has said so once


def live_sessions():
    """Open sessions as [{sessionId, cwd, name, status, ...}]."""
    claude = shutil.which("claude") or next((str(p) for p in CLAUDE_FALLBACKS if os.access(p, os.X_OK)), None)
    if claude:
        try:
            r = subprocess.run([claude, "agents", "--json"], capture_output=True, text=True, timeout=15, cwd="/tmp")
            if r.returncode == 0:
                return json.loads(r.stdout)
        except (subprocess.TimeoutExpired, ValueError, OSError):
            pass
    # The command normally takes under a second but now and then hangs for minutes.
    # The per-process registry it reads from holds the same fields.
    if not SESSION_REGISTRY.is_dir():
        if not claude:
            raise NoClaudeCode("Claude Code is not installed (no claude command, no session registry)")
        raise RuntimeError("no way to list open sessions: claude agents --json failed and no session registry")
    out = []
    for f in SESSION_REGISTRY.glob("*.json"):
        try:
            s = json.loads(f.read_text())
            os.kill(int(s["pid"]), 0)  # skip entries left behind by dead processes
        except (OSError, ValueError, KeyError, TypeError):
            continue
        out.append(s)
    return out


def scan_transcripts(cache):
    """Keep cwd / titles / mtime per transcript. Files are append-only, so only the new tail is read."""
    seen = set()
    for f in TRANSCRIPTS.glob("*/*.jsonl"):
        key = str(f)
        seen.add(key)
        try:
            st = f.stat()
        except OSError:
            continue
        c = cache.get(key)
        if c and c["size"] == st.st_size and c["mtime"] == st.st_mtime:
            continue
        if not c or st.st_size < c["scanned"]:
            c = {"cwd": None, "custom": None, "ai": None, "scanned": 0}
        with open(f, "rb") as fh:
            fh.seek(c["scanned"])
            data = fh.read()
        end = data.rfind(b"\n") + 1  # complete lines only
        for raw in data[:end].splitlines():
            want_cwd = c["cwd"] is None and b'"cwd":"' in raw
            if not (want_cwd or b'"type":"custom-title"' in raw or b'"type":"ai-title"' in raw):
                continue
            try:
                obj = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            if want_cwd and isinstance(obj.get("cwd"), str):
                c["cwd"] = obj["cwd"]
            if obj.get("type") == "custom-title" and obj.get("customTitle"):
                c["custom"] = obj["customTitle"]
            elif obj.get("type") == "ai-title" and obj.get("aiTitle"):
                c["ai"] = obj["aiTitle"]
        c["scanned"] += end
        c["size"], c["mtime"] = st.st_size, st.st_mtime
        cache[key] = c
    for key in set(cache) - seen:
        del cache[key]


def scan_history(cache):
    """Sessions seen in the prompt history, which outlives cleaned-up transcripts.

    -> {session id: {"proj": cwd, "last": epoch, "text": first real prompt}}
    The file is append-only, so only the new tail is read.
    """
    try:
        size = HISTORY.stat().st_size
    except OSError:
        return cache.setdefault("sessions", {})
    if cache.get("scanned", 0) > size:
        cache.clear()
    sessions = cache.setdefault("sessions", {})
    with open(HISTORY, "rb") as fh:
        fh.seek(cache.get("scanned", 0))
        data = fh.read()
    end = data.rfind(b"\n") + 1
    for raw in data[:end].splitlines():
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        sid, ts = e.get("sessionId"), e.get("timestamp")
        if not sid or not isinstance(ts, (int, float)):
            continue
        s = sessions.setdefault(sid, {"proj": e.get("project"), "last": 0, "text": ""})
        s["last"] = max(s["last"], ts / 1000)
        if not s["text"]:
            text = " ".join(PASTE_MARK.sub("", str(e.get("display") or "")).split())
            if text and text[0] not in "/!":  # slash and shell commands say nothing about the task
                s["text"] = text[:80]
    cache["scanned"] = cache.get("scanned", 0) + end
    return sessions


def mono(n):
    """Digits as fixed-width glyphs: the system font draws "1" narrower, which breaks column alignment."""
    return str(n).translate(MONO_DIGITS)


def newest_file_mtime(folder):
    newest, count = 0.0, 0
    base = str(folder).rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(folder):
        depth = dirpath.count(os.sep) - base
        if depth >= FILE_SCAN_DEPTH - 1:
            dirnames[:] = []
        else:
            dirnames[:] = [d for d in dirnames if d not in PRUNE and Path(dirpath, d) != STATE_DIR]
        for name in filenames:
            if name == ".DS_Store":  # Finder rewrites it when comments change
                continue
            count += 1
            try:
                newest = max(newest, os.lstat(os.path.join(dirpath, name)).st_mtime)
            except OSError:
                pass
        if count >= FILE_SCAN_LIMIT:
            break
    return newest or folder.stat().st_mtime


def read_tags(path):
    """Returns the folder's tag list, [] if it has none, None if unreadable."""
    r = subprocess.run(["/usr/bin/xattr", "-px", TAG_XATTR, str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        return []
    try:
        return [str(t) for t in plistlib.loads(bytes.fromhex("".join(r.stdout.split())))]
    except Exception:
        return None


def write_tags(path, tags):
    if tags:
        data = plistlib.dumps(tags, fmt=plistlib.FMT_BINARY).hex()
        subprocess.run(["/usr/bin/xattr", "-wx", TAG_XATTR, data, str(path)], check=True, capture_output=True)
    else:
        subprocess.run(["/usr/bin/xattr", "-d", TAG_XATTR, str(path)], capture_output=True)


def merge_tags(current, managed):
    """Keep the user's own tags, replace only the ones this tool manages."""
    kept = [t for t in current if t.split("\n")[0] not in MANAGED]
    return kept + [f"{name}\n{colour}" for name, colour in managed]


BACKUP_KEYS = ("written", "orig", "orphans")  # what --dry-run never changes on disk
ORPHANS_KEY = "(not found where they were)"


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state, keep_backups=False):
    """keep_backups (--dry-run): only the scan caches are saved, the backups on disk stay as they were."""
    if keep_backups:
        on_disk = load_state()
        state = {**state, **{k: on_disk[k] for k in BACKUP_KEYS if k in on_disk}}
        state = {k: v for k, v in state.items() if k not in BACKUP_KEYS or k in on_disk}
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False))
    os.replace(tmp, STATE_FILE)
    if not keep_backups:
        originals = dict(state.get("orig", {}))
        if state.get("orphans"):  # backups of folders not found where they were, kept under a key no path can have
            originals[ORPHANS_KEY] = state["orphans"]
        ORIGINALS_FILE.write_text(json.dumps(originals, ensure_ascii=False, indent=2))


VOLUMES = "/Volumes"  # where removable and network volumes are mounted: a folder there may only be unmounted
is_mount = os.path.ismount


def forget_gone(state, known):
    """Set aside the records of folders that are gone, keep the backups of the others where they are.

    The scan cache ("files") only keeps this run's folders. A backup ("orig", and "written", which says what --restore
    has to undo) leaves its path only for a folder confirmed gone (`confirmed_gone`): moved where this run does not look,
    or deleted. It goes to "orphans", from where `relink` gives it back to the folder when it turns up again (same
    identity) and `apply` to a folder that carries the comment this tool wrote there. A folder outside this run's roots,
    one that cannot be read for whatever reason, or one on a volume that is not mounted keeps it in place, so --restore
    can still put it back.
    """
    for p in [p for p in state.get("files", {}) if p not in known]:
        del state["files"][p]
    written, orig = state.get("written", {}), state.get("orig", {})
    for p in sorted({p for p in (*written, *orig) if p not in known and confirmed_gone(p)}):
        state.setdefault("orphans", []).append({"path": p, "orig": orig.pop(p, {}), "written": written.pop(p, {})})


def folder_id(p):
    """A folder's identity, which a rename or a move on the same volume keeps: [device, inode]. None if unreadable."""
    try:
        st = os.stat(p)
    except OSError:
        return None
    return [st.st_dev, st.st_ino]


def relink(state, folders):
    """Moves the records of folders that were renamed or moved to their new paths, by identity, before anything is
    decided about the old paths. A record goes to the scanned folder whose identity it holds, when that folder is not at
    the record's path; an orphan goes back to its folder the same way. A record already at the new path without that
    identity is set aside as an orphan. Records without an identity stay where they are.
    """
    orig, written = state.setdefault("orig", {}), state.setdefault("written", {})
    orphans = state.setdefault("orphans", [])
    by_id = {}
    for f in folders:
        i = folder_id(str(f))
        if i:
            by_id[tuple(i)] = str(f)
    moves = []
    for p in list(orig):
        i = orig[p].get("id")
        q = by_id.get(tuple(i)) if i else None
        if q and q != p:
            moves.append((p, {"orig": orig.pop(p), "written": written.pop(p, {})}))
    for o in list(orphans):
        i = (o.get("orig") or {}).get("id")
        if i and tuple(i) in by_id:
            orphans.remove(o)
            moves.append((o["path"], {"orig": o.get("orig") or {}, "written": o.get("written") or {}}))
    for p, rec in moves:
        q = by_id[tuple(rec["orig"]["id"])]
        if q in orig or q in written:  # what was recorded there belongs to no folder this identity knows
            orphans.append({"path": q, "orig": orig.pop(q, {}), "written": written.pop(q, {})})
        orig[q] = rec["orig"]
        if rec["written"]:
            written[q] = rec["written"]


def confirmed_gone(p):
    """Whether a folder is known not to be there: looking it up says it does not exist (not that it may not be looked
    at), its parent can be listed and has nothing of that name, and it is not on a volume under VOLUMES that is not
    mounted (an unmounted volume's folder in VOLUMES goes with it, so its root looks deleted from a readable parent).
    """
    try:
        os.lstat(p)
        return False  # something is there
    except FileNotFoundError:
        pass
    except OSError:
        return False  # not allowed to look, or the disk did not answer: not known to be gone
    parent, name = os.path.split(p)
    try:
        names = {nfc(n) for n in os.listdir(parent)}
    except OSError:
        return False
    if nfc(name) in names:
        return False
    rel = os.path.relpath(p, VOLUMES)
    if rel != "." and not rel.startswith(".."):
        volume = os.path.join(VOLUMES, rel.split(os.sep)[0])
        if not is_mount(volume):
            return False
    return True


def describe(folders, all_folders, live, transcripts, history, files, now):
    """-> {folder path: (comment, [(tag name, colour), ...])}"""
    index = sorted(((nfc(str(f)), str(f)) for f in all_folders), key=lambda x: -len(x[0]))

    def owner(cwd):
        cwd = nfc(cwd or "")
        return next((p for key, p in index if cwd == key or cwd.startswith(key + "/")), None)

    info = {str(f): {"live": [], "closed": [], "gone": [], "last": files[str(f)]["newest"]} for f in folders}
    by_id = {Path(k).stem: v for k, v in transcripts.items()}
    live_ids = set()
    for s in live:
        sid = s.get("sessionId")
        live_ids.add(sid)
        d = info.get(owner(s.get("cwd")))
        if d is None:
            continue
        t = by_id.get(sid, {})
        status = s.get("status") if s.get("status") in STATUS else "idle"
        d["live"].append((status, t.get("custom") or t.get("ai") or s.get("name") or WORDS["untitled"]))
        d["last"] = max(d["last"], t.get("mtime", 0), (s.get("startedAt") or 0) / 1000)
    for key, t in transcripts.items():
        d = info.get(owner(t.get("cwd")))
        if d is None:
            continue
        d["last"] = max(d["last"], t["mtime"])
        if Path(key).stem not in live_ids:
            d["closed"].append((t["mtime"], t.get("custom") or t.get("ai") or ""))
    for sid, h in history.items():
        d = info.get(owner(h.get("proj")))
        if d is None:
            continue
        d["last"] = max(d["last"], h["last"])
        # In the prompt history but no transcript left: the session was cleaned up.
        if sid not in live_ids and sid not in by_id and h["text"]:
            d["gone"].append((h["last"], h["text"]))

    out = {}
    for path, d in info.items():
        # "𝟸𝟼/𝟷𝟶/𝟶𝟻 │𝟹/𝟿 │ ⚪ a  ⚪ b  ⚪ c │ 4 closed: x, y │ 2 cleaned up: z"  (English; the Chinese forms differ in wording)
        # date, open/total sessions, then the sessions themselves
        total = len(d["live"]) + len(d["closed"]) + len(d["gone"])
        pad = FIGURE_SPACE if total < 10 else ""
        head = f"{mono(datetime.fromtimestamp(d['last']).strftime('%y/%m/%d'))} │{mono(len(d['live']))}/{mono(total)}{pad}│"
        parts = []
        if d["live"]:
            live_sorted = sorted(d["live"], key=lambda x: (STATUS_ORDER.index(x[0]), x[1]))
            parts.append("  ".join(f"{STATUS[s][2]} {short(n)}" for s, n in live_sorted))
        if d["closed"]:
            names = [short(n) for _, n in sorted(d["closed"], reverse=True) if n][:CLOSED_SHOWN]
            parts.append(WORDS["closed"](len(d["closed"]), names))
        if d["gone"]:
            texts = [short(t) for _, t in sorted(d["gone"], reverse=True)][:GONE_SHOWN]
            parts.append(WORDS["gone"](len(d["gone"]), texts))
        tags = [STATUS[s][:2] for s in STATUS_ORDER if any(x[0] == s for x in d["live"])]
        if not d["live"] and now - d["last"] > STALE_DAYS * 86400:
            tags.append(STALE_TAG)
        out[path] = (head + (" " + " │ ".join(parts) if parts else ""), tags)
    return out


# The head of every comment this tool writes (see describe): date and session counts in fixed-width digits.
_MONO = "[" + "".join(chr(c) for c in MONO_DIGITS.values()) + "]"
TOOL_COMMENT = re.compile(f"^{_MONO}{{2}}/{_MONO}{{2}}/{_MONO}{{2}} │{_MONO}+/{_MONO}+{FIGURE_SPACE}?│")


def original_comment(state, p, comment):
    """What to back up as a folder's original, given the comment it has now. A comment this tool wrote is never one: it
    is taken as the sign of a backup set aside for a folder that moved and is given that backup's comment, when exactly
    one orphan wrote it; otherwise, when it has this tool's form, the original is taken to be empty."""
    orphans = state.get("orphans", [])
    hits = [o for o in orphans if comment in ((o.get("written") or {}).get("comment"), (o.get("written") or {}).get("pending"))
            and "comment" in (o.get("orig") or {})]
    if comment and len(hits) == 1:
        orphans.remove(hits[0])
        return hits[0]["orig"]["comment"]
    if TOOL_COMMENT.match(comment):
        return ""
    return comment


def apply(state, wanted, persist=None):
    """Write only what changed. Returns (comments written, tag sets written, ok).

    Tags are plain xattrs; comments need Finder (AppleScript) and can fail on
    their own, e.g. when the Automation permission is missing. Each part is
    recorded separately so a failed part is retried on the next run.

    Before a batch of comments is written, the backups and the comments about to be written ("pending") are saved
    (`persist`), so a batch that stops part way leaves --restore a record of every folder it may have changed. After a
    failure the comments are read back: those that came through count as written.
    """
    written = state.setdefault("written", {})
    orig = state.setdefault("orig", {})  # what each folder had before this tool first touched it
    n_tags, retag, ok = 0, [], True

    for p in wanted:  # the identity relink follows; a record with the same inode takes a device number that changed
        stored, i = orig.get(p, {}).get("id"), folder_id(p)
        if i and (stored is None or (stored != i and stored[1] == i[1])):
            orig.setdefault(p, {})["id"] = i

    for p, (_, tags) in wanted.items():
        w = written.setdefault(p, {})
        as_lists = [list(t) for t in tags]
        if w.get("tags") == as_lists:
            continue
        current = read_tags(p)
        if current is None:
            print(f"skip tags (unreadable): {p}", file=sys.stderr)
            ok = False
            continue
        orig.setdefault(p, {}).setdefault("tags", merge_tags(current, []))
        merged = merge_tags(current, tags)
        if merged != current:
            write_tags(p, merged)
            retag.append(p)
            n_tags += 1
        w["tags"] = as_lists

    todo = [p for p, (comment, _) in wanted.items() if written[p].get("comment") != comment]
    n_comments = 0
    if todo:
        try:
            new = [p for p in todo if "comment" not in orig.get(p, {})]
            if new:
                for p, comment in zip(new, osa(GET_COMMENTS, new).split(chr(30))):
                    orig.setdefault(p, {})["comment"] = original_comment(state, p, comment)
            for p in todo:
                written[p]["pending"] = wanted[p][0]
            if persist:
                persist()
            try:
                osa(SET_COMMENTS, [x for p in todo for x in (p, wanted[p][0])])
                done = todo
            except (RuntimeError, subprocess.TimeoutExpired):
                try:
                    now = osa(GET_COMMENTS, todo).split(chr(30))
                    done = [p for p, c in zip(todo, now) if c == wanted[p][0]]
                except (RuntimeError, subprocess.TimeoutExpired):
                    done = []  # not known: the pending comments stay for --restore to check
                for p in done:
                    written[p]["comment"] = written[p].pop("pending")
                raise
            for p in done:
                written[p]["comment"] = written[p].pop("pending")
            n_comments = len(todo)
        except (RuntimeError, subprocess.TimeoutExpired) as e:
            print(f"{datetime.now():%m-%d %H:%M:%S} comments not updated: {e}", file=sys.stderr)
            ok = False
    if retag:
        try:
            osa(UPDATE_ITEMS, retag)
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
    return n_comments, n_tags, ok


def trim_log():
    """The launchd job appends to LOG_FILE forever; keep the tail."""
    try:
        if LOG_FILE.stat().st_size > 512 * 1024:
            LOG_FILE.write_text("".join(LOG_FILE.read_text(errors="replace").splitlines(True)[-500:]))
    except OSError:
        pass


def restore_paths(state, folders, only=None):
    """The folders --restore works on: of `folders` (this run's scan), those this tool wrote to; folders None (no --root),
    every folder it wrote to that is there now, wherever it is. `only`: folder names to keep."""
    written = state.get("written", {})
    if folders is None:
        paths = sorted(p for p in written if os.path.isdir(p))
    else:
        paths = [str(f) for f in folders if str(f) in written]
    if only is not None:
        paths = [p for p in paths if nfc(os.path.basename(p)) in only]
    return paths


def restore(state, paths):
    """Remove this tool's tags and put the original comments back. Returns the number of folders restored.

    A comment goes back only where it was backed up and then changed by this tool: one never read (the Automation
    permission was missing then) or never written stays as it is now. A comment that was about to be written when a
    batch stopped ("pending") goes back when the folder has it now, or when the folders cannot be read to tell: writing
    the backup over a comment the batch never reached puts back what is there already.

    A folder restored in full ends its backup: its records go, so a later run backs up the comment it has then. A folder
    whose tags or comment could not be put back keeps its records. The first such failure is raised after the others
    are done.
    """
    written, orig = state.get("written", {}), state.get("orig", {})
    paths = [p for p in paths if p in written]
    backed = [p for p in paths if "comment" in orig.get(p, {})]
    comments = [p for p in backed if "comment" in written[p]]
    pending = [p for p in backed if "pending" in written[p] and "comment" not in written[p]]
    if pending:
        try:
            now = osa(GET_COMMENTS, pending).split(chr(30))
            pending = [p for p, c in zip(pending, now) if c == written[p]["pending"]]
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
    failed, error = set(), None
    for p in paths:
        try:
            current = read_tags(p)
            if current is not None:
                merged = merge_tags(current, [])
                if merged != current:
                    write_tags(p, merged)
        except (OSError, subprocess.CalledProcessError) as e:
            failed.add(p); error = error or e
    for p in comments + pending:  # one at a time: a folder that fails leaves the others restored
        try:
            osa(SET_COMMENTS, [p, orig[p]["comment"]])
        except (RuntimeError, subprocess.TimeoutExpired) as e:
            failed.add(p); error = error or e
    if paths:
        try:
            osa(UPDATE_ITEMS, paths)
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
    done = [p for p in paths if p not in failed]
    for p in done:
        del written[p]
        orig.pop(p, None)
    if error is not None:
        raise RuntimeError(f"{len(failed)} of {len(paths)} folders not restored: {error}")
    return len(done)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", action="append", metavar="DIR",
                    help="a folder whose subfolders are projects; repeat for more (default: those of ~/Projects, ~/Developer and ~/code that exist)")
    ap.add_argument("--only", help="comma-separated folder names to limit the run to")
    ap.add_argument("--lang", default=DEFAULT_LANG, metavar="LANG",
                    help="en, zh-Hans or zh-Hant: the tag names and the words in the comment (default: zh-Hans). The other language's tags are replaced on the next run")
    ap.add_argument("--dry-run", action="store_true", help="print what would be written, change nothing")
    ap.add_argument("--restore", action="store_true", help="remove this tool's tags and comments")
    args = ap.parse_args()
    lang = normalize_lang(args.lang)
    if lang is None:
        ap.error(f"--lang: no tags in {args.lang!r} (have: {', '.join(LANGS)})")
    set_lang(lang)

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    trim_log()
    lock = open(STATE_DIR / "lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # another run is in progress

    state = load_state()
    all_folders = project_folders(args.root or DEFAULT_ROOTS)
    relink(state, all_folders)  # follow folders that were renamed or moved, by identity
    forget_gone(state, {str(f) for f in all_folders})  # set aside the records of folders that were moved away or deleted
    folders = all_folders
    only = None
    if args.only:
        only = {nfc(n.strip()) for n in args.only.split(",")}
        folders = [f for f in all_folders if nfc(f.name) in only]

    if args.restore:  # without --root: every folder it wrote to, also those under roots of another run
        try:
            n = restore(state, restore_paths(state, folders if args.root else None, only))
        finally:
            save_state(state)  # the folders restored lose their records, the others keep them
        print(f"restored {n} folders")
        return 0

    now = time.time()
    live = live_sessions()
    NO_CLAUDE_NOTE.unlink(missing_ok=True)  # it is here (again): say so again if it goes
    transcripts = state.setdefault("transcripts", {})
    scan_transcripts(transcripts)
    files = state.setdefault("files", {})
    for f in folders:
        if now - files.get(str(f), {}).get("at", 0) > FILE_SCAN_EVERY:
            files[str(f)] = {"newest": newest_file_mtime(f), "at": now}

    history = scan_history(state.setdefault("history", {}))
    wanted = describe(folders, all_folders, live, transcripts, history, files, now)
    if args.dry_run:
        for p, (comment, tags) in sorted(wanted.items()):
            print(f"{Path(p).name}\t{','.join(t[0] for t in tags) or '-'}\t{comment}")
        save_state(state, keep_backups=True)  # keeps the scan caches, changes no backup
        return 0

    try:
        n_comments, n_tags, ok = apply(state, wanted, persist=lambda: save_state(state))
    finally:
        save_state(state)
    if n_comments or n_tags:  # stay quiet when nothing changed, the log is appended every minute
        print(f"{datetime.now():%m-%d %H:%M:%S} comments {n_comments}, tags {n_tags}, folders {len(folders)}")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except NoClaudeCode as e:  # a Mac without Claude Code: said once in the log, then nothing every minute
        if not NO_CLAUDE_NOTE.exists():
            print(f"{datetime.now():%m-%d %H:%M:%S} note: {e}; nothing to tag until it is (said once)", file=sys.stderr)
            try:
                STATE_DIR.mkdir(parents=True, exist_ok=True)
                NO_CLAUDE_NOTE.touch()
            except OSError:
                pass
        sys.exit(0)
    except Exception as e:  # one line in the launchd log instead of a traceback every minute
        print(f"{datetime.now():%m-%d %H:%M:%S} error: {e!r}", file=sys.stderr)
        sys.exit(1)
