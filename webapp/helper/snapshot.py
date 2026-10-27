"""Helper: runs the Mac app's --dump every 3 seconds, merges cwd / zone / pet / transcript path, and atomically writes snapshot.json.

Read-only: only runs the dump and defaults export; never writes ../app or touches the running Mac panel.
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from typing import Dict, List, Optional, Tuple

if __package__ in (None, ""):  # when run directly as python3 helper/snapshot.py
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from api import transcript as _tr
from helper import orca_cli, orca_stats, outbox
from helper import textidx  # chat text index
from helper import settings
from helper.zones import ZoneConfig, load_zone_config

WEBAPP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")
INTERVAL = 3
DUMP_TIMEOUT = 10

PANEL_EXE = "Soulgent"  # executable name inside Contents/MacOS
PANEL_SUB = os.path.join("Soulgent.app", "Contents", "MacOS", PANEL_EXE)  # fallback path shown when nothing is found


def _panel_exe_in(app_dir: str) -> Optional[str]:
    cand = os.path.join(app_dir, "Contents", "MacOS", PANEL_EXE)
    return cand if os.path.isfile(cand) else None


def panel_path(env=None, webapp: str = WEBAPP, home: str = HOME, apps_dir: str = "/Applications") -> str:
    """Path of the Mac app executable (Contents/MacOS/Soulgent). In order: env SOULGENT_PANEL ->
    SOULGENT_PANEL in webapp/.env -> app/Soulgent.app next to webapp/ (same repo) -> /Applications -> ~/Applications. If none exists,
    return the sibling path, and run_once reports it as missing in the log."""
    given = settings.path_setting("SOULGENT_PANEL", "", env, webapp)
    if given:
        # The README says to give the Soulgent.app path: for an .app directory append the executable inside it; a full executable path is used as is
        app = given.rstrip("/")
        if app.endswith(".app") or os.path.isdir(os.path.join(app, "Contents", "MacOS")):
            return _panel_exe_in(app) or os.path.join(app, "Contents", "MacOS", PANEL_EXE)
        return given
    repo = os.path.join(os.path.dirname(webapp), "app", PANEL_SUB)
    for app_dir in (os.path.join(os.path.dirname(webapp), "app", "Soulgent.app"),
                    os.path.join(apps_dir, "Soulgent.app"), os.path.join(home, "Applications", "Soulgent.app")):
        found = _panel_exe_in(app_dir)
        if found:
            return found
    return repo


def zone_style_path(env=None, webapp: str = WEBAPP) -> str:
    """Local private file for zone display style (short name, avatar effect). In order: env SOULGENT_ZONE_STYLE ->
    SOULGENT_ZONE_STYLE in webapp/.env -> webapp/data/zone-style.json (data/ is not in git). The file may be absent."""
    return settings.path_setting("SOULGENT_ZONE_STYLE", os.path.join(webapp, "data", "zone-style.json"), env, webapp)


_CLAUDE = settings.claude_paths()  # session registry, transcripts, zones file, roster and lineage under ~/.claude (each overridable by env var)

DEFAULT_PATHS = {
    "dump_cmd": [panel_path(), "--dump"],
    "sessions_dir": _CLAUDE["sessions_dir"],
    "projects_dir": _CLAUDE["projects_dir"],
    "workzones": _CLAUDE["workzones"],
    "zone_style": zone_style_path(),
    "roster": _CLAUDE["roster"],
    "usage_dir": settings.statusline_dir(),
    "out": os.path.join(WEBAPP, "data", "snapshot.json"),
    "outbox_dir": os.path.join(WEBAPP, "data", "outbox"),
    "uploads_dir": os.path.join(WEBAPP, "data", "uploads"),
    "send_log": os.path.join(WEBAPP, "data", "send.log"),
    "taskboard_dir": os.path.join(WEBAPP, "data", "taskboards"),
    "textidx_dir": os.path.join(WEBAPP, "data", "textidx"),  # index for global search (read-only for the api)
    "lineage_src": _CLAUDE["lineage_src"],
}

OUTBOX_INTERVAL = 0.15
CLEANUP_EVERY = 3600  # prune expired uploads hourly
CHECK_INTERVAL = 0.3  # the main loop checks the session registry directory for changes every 0.3 s
MIN_GAP = 0.5  # minimum 0.5 s between snapshots
_refresh_event = threading.Event()  # set after outbox handles a request; the main loop regenerates immediately
_latest_lock = threading.Lock()
_latest_sessions = {}  # latest dump: {id: item}, handed to the outbox thread for session validation

_last_logged = {}  # error message -> last logged time
_transcript_cache = {}  # (projects_dir, session_id) -> relative path


def log(msg: str) -> None:
    """Write one line per message to stderr (each prefixed with local time YYYY-MM-DD HH:MM:SS); the same error is logged at most once per 60 s."""
    now = time.time()
    if now - _last_logged.get(msg, 0) < 60:
        return
    _last_logged[msg] = now
    sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)) + " " + msg.replace("\n", " ") + "\n")
    sys.stderr.flush()


def read_session_files(sessions_dir: str) -> List[tuple]:
    """~/.claude/sessions/<pid>.json -> [(pid or None, data)]; only entries with a sessionId."""
    result = []
    for path in glob.glob(os.path.join(glob.escape(sessions_dir), "*.json")):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or not isinstance(data.get("sessionId"), str):
            continue
        try:
            pid = int(os.path.basename(path)[:-5])
        except ValueError:
            pid = None
        result.append((pid, data))
    return result


def cwds_from(files: List[tuple]) -> Dict[str, str]:
    return {d["sessionId"]: d["cwd"] for _, d in files if isinstance(d.get("cwd"), str)}


def read_cwds(sessions_dir: str) -> Dict[str, str]:
    return cwds_from(read_session_files(sessions_dir))


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    except OSError:
        return False
    return True


def hidden_sessions(files: List[tuple]) -> set:
    """Session ids to keep out of the snapshot: bg-spare standby processes, and original sessions that were forked into a background clone while the clone is still alive."""
    hidden = {d["sessionId"] for _, d in files if d.get("kind") == "bg" and d.get("spare") is True}
    parked = [(d["sessionId"], d["parkedJobId"]) for _, d in files if isinstance(d.get("parkedJobId"), str)]
    if parked:
        live_jobs = {(d["jobId"], d["sessionId"]) for pid, d in files
                     if isinstance(d.get("jobId"), str) and pid is not None and _alive(pid)}
        hidden.update(sid for sid, job in parked if any(j == job and s != sid for j, s in live_jobs))
    return hidden


def find_transcript(projects_dir: str, session_id: str) -> Optional[str]:
    key = (projects_dir, session_id)
    if key in _transcript_cache:
        return _transcript_cache[key]
    hits = glob.glob(os.path.join(glob.escape(projects_dir), "*", glob.escape(session_id) + ".jsonl"))
    if not hits:
        return None  # not cached when missing; the file may not exist yet right after a session starts
    rel = os.path.relpath(sorted(hits)[0], projects_dir)
    _transcript_cache[key] = rel
    return rel


TAIL_START = 512 * 1024
TAIL_MAX = 16 * 1024 * 1024
_origin_cache = {}  # file path -> (size, mtime_ns, (origin, peer))


def _origin_in(path: str, size: int) -> tuple:
    """Search backward from the end of the file for the last user record with string content; start with a 512KB window and double it until found (up to 16MB)."""
    window = TAIL_START
    with open(path, "rb") as f:
        while True:
            start = max(0, size - window)
            f.seek(start)
            data = f.read(size - start)
            lines = data.split(b"\n")
            if start > 0:
                lines = lines[1:]  # the first piece may be a partial line
            for line in reversed(lines):
                if b'"type":"user"' not in line or b'"type":"tool_result"' in line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(obj, dict) or obj.get("type") != "user" or obj.get("isSidechain"):
                    continue
                msg = obj.get("message")
                content = msg.get("content") if isinstance(msg, dict) else None
                if isinstance(content, str):
                    origin, peer, _ = _tr.classify_user_text(content)
                    if origin == "notice":
                        continue  # harness system notifications do not start a turn
                    if obj.get("isMeta") and origin == "user":
                        continue  # other meta records are system-injected, not user turns
                    return origin, peer
            if start == 0 or window >= TAIL_MAX:
                return "user", None
            window *= 2


def read_origin(projects_dir: str, rel: Optional[str]) -> tuple:
    """Who started this turn: (origin, peer). Reads only the file tail, cached by (size, mtime); a read failure counts as user."""
    if not rel:
        return "user", None
    path = os.path.join(projects_dir, rel)
    try:
        stt = os.stat(path)
        hit = _origin_cache.get(path)
        if hit and hit[0] == stt.st_size and hit[1] == stt.st_mtime_ns:
            return hit[2]
        res = _origin_in(path, stt.st_size)
    except OSError:
        return "user", None
    _origin_cache[path] = (stt.st_size, stt.st_mtime_ns, res)
    return res


def read_panel_domain() -> Optional[dict]:
    """Read the whole panel domain (old and new domains merged per key during migration, see outbox.read_panel); None on failure."""
    try:
        return outbox.read_panel()
    except Exception:
        return None


def pets_from(domain: Optional[dict]) -> dict:
    pets = (domain or {}).get("petBySession")
    return pets if isinstance(pets, dict) else {}


def panel_from(domain: Optional[dict], ids) -> Optional[dict]:
    """Extract seenAt / pinned, keeping only sessions present in the snapshot; None if the read failed (domain is None)."""
    if domain is None:
        return None
    ids = set(ids)
    seen_raw = domain.get("seenAt")
    seen = {}
    if isinstance(seen_raw, dict):
        for k, v in seen_raw.items():
            if k in ids and isinstance(v, (int, float)) and not isinstance(v, bool):
                seen[k] = float(v)
    pins_raw = domain.get("pinned")
    pins = [p for p in pins_raw if isinstance(p, str) and p in ids] if isinstance(pins_raw, list) else []
    return {"seenAt": seen, "pinned": pins}


def read_pets() -> dict:
    return pets_from(read_panel_domain())


def read_usage(dir: str) -> dict:
    result = {}
    for key, fname in (("fiveHour", "shared.five_hour"), ("sevenDay", "shared.seven_day")):
        try:
            with open(os.path.join(dir, fname), "r", encoding="utf-8") as f:
                lines = f.read().split()
            result[key] = {"pct": int(float(lines[0])), "resetsAt": int(float(lines[1]))}
        except (OSError, ValueError, IndexError, OverflowError):
            continue
    return result


_META_ID_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
_meta_cache = {}  # file path -> (mtime_ns, size, parsed result or None)


def meta_from(data) -> Optional[dict]:
    """meta.<id>.json written by the statusline -> slim fields for the phone; None if malformed."""
    if not isinstance(data, dict):
        return None
    model = data.get("model")
    effort = data.get("effort")
    pct, used, window = _num(data.get("used_percentage")), _num(data.get("used_tokens")), _num(data.get("window"))
    tps, at = _num(data.get("speed")), _num(data.get("ts"))
    return {
        "model": model if isinstance(model, str) and model else None,
        "effort": effort if isinstance(effort, str) and effort else None,
        "fast": data.get("fast") is True,
        "ctxPct": max(0, min(100, int(round(pct)))) if pct is not None else None,
        "ctxUsed": int(used) if used is not None else None,
        "ctxWindow": int(window) if window and window > 0 else None,
        "tps": round(tps, 1) if tps is not None and tps > 0 else None,
        "at": at,
    }


def read_meta(meta_dir: Optional[str], session_id: str) -> Optional[dict]:
    """Read <meta_dir>/meta.<id>.json; id may contain only alphanumerics, - and _; cached by (mtime, size); None if missing or unreadable."""
    if not meta_dir or not session_id or not set(session_id) <= _META_ID_OK:
        return None
    path = os.path.join(meta_dir, "meta.%s.json" % session_id)
    try:
        stt = os.stat(path)
    except OSError:
        _meta_cache.pop(path, None)
        return None
    hit = _meta_cache.get(path)
    if hit and hit[0] == stt.st_mtime_ns and hit[1] == stt.st_size:
        return hit[2]
    try:
        with open(path, "r", encoding="utf-8") as f:
            res = meta_from(json.load(f))
    except (OSError, ValueError):
        _meta_cache.pop(path, None)  # may be mid-write: do not cache, read again next round
        return None
    _meta_cache[path] = (stt.st_mtime_ns, stt.st_size, res)
    return res


def read_roster(path: Optional[str]) -> dict:
    """Off-duty roster {session name: {...}}; treated as empty if unreadable or malformed."""
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _num(v) -> Optional[float]:
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def offduty_from(roster: dict, dump: List[dict], projects_dir: str) -> List[dict]:
    """Off-duty sessions from the roster: excludes those whose sid or name is already in the current dump; sorted by offAt descending."""
    live_ids = {i.get("id") for i in dump if isinstance(i, dict)}
    live_names = {i.get("name") for i in dump if isinstance(i, dict) and i.get("name")}
    out = []
    for name, ent in roster.items():
        if not isinstance(name, str) or not isinstance(ent, dict):
            continue
        sid = ent.get("sid")
        if not isinstance(sid, str) or not sid or sid in live_ids or name in live_names:
            continue
        zone = ent.get("zone")
        out.append({
            "name": name,
            "sid": sid,
            "zone": zone if isinstance(zone, str) and zone else "",  # empty string when unzoned; the frontend shows the localized label
            "lastActive": _num(ent.get("lastActive")),
            "offAt": _num(ent.get("offAt")),
            "transcript": find_transcript(projects_dir, sid),
        })
    out.sort(key=lambda o: o["offAt"] or 0, reverse=True)
    return out


ORCA_CHECK_SEC = 10.0
_orca_cache = {"at": None, "running": True}


def orca_running(now: Optional[float] = None) -> bool:
    """Whether Orca is running (pgrep -x Orca exits 0). Snapshots run every 0.5-3 s; this checks at most once per 10 s, and if the check fails it assumes running to avoid false alarms."""
    now = time.time() if now is None else now
    at = _orca_cache["at"]
    if at is not None and 0 <= now - at < ORCA_CHECK_SEC:
        return _orca_cache["running"]
    try:
        running = subprocess.run(["pgrep", "-x", "Orca"], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, timeout=3).returncode == 0
    except Exception:
        running = True
    _orca_cache.update({"at": now, "running": running})
    return running


SUMMARY_ARGS_MAX = 4096  # max serialized size of summaryArgs (bytes); dropped entirely if exceeded


def summary_extras(item: dict) -> dict:
    """Pick summaryCode / summaryArgs / nameUntitled from a dump entry; omitted if missing or the wrong type (older panels)."""
    out = {}
    code = item.get("summaryCode")
    if isinstance(code, str) and code:
        out["summaryCode"] = code
    args = item.get("summaryArgs")
    if isinstance(args, dict):
        clean = {k: v for k, v in args.items()
                 if isinstance(k, str) and (v is None or isinstance(v, (str, int, float, bool)))}
        try:
            if len(json.dumps(clean, ensure_ascii=False).encode("utf-8")) <= SUMMARY_ARGS_MAX:
                out["summaryArgs"] = clean
        except (TypeError, ValueError):
            pass
    if isinstance(item.get("nameUntitled"), bool):
        out["nameUntitled"] = item["nameUntitled"]
    return out


def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def bg_extras(item: dict) -> dict:
    """Six background-task fields: bgTasks/bgAgents (int>=0), bgSince/bgEndedAt (number or null), bgStale/bgOwned (bool).
    Omitted if missing or the wrong type (older panels)."""
    out = {}
    for k in ("bgTasks", "bgAgents"):
        v = item.get(k)
        if isinstance(v, int) and not isinstance(v, bool) and v >= 0:
            out[k] = v
    for k in ("bgSince", "bgEndedAt"):
        if k in item and (item[k] is None or _is_num(item[k])):
            out[k] = item[k]
    for k in ("bgStale", "bgOwned"):
        if isinstance(item.get(k), bool):
            out[k] = item[k]
    lst = bg_list(item.get("bgList"))
    if lst is not None:
        out["bgList"] = lst
    return out


BG_LIST_MAX = 50   # max bgList items kept (guards against abnormal size)
BG_DESC_MAX = 80


def bg_list(v) -> Optional[list]:
    """Background list bgList: None (omitted) if not an array; items are validated one by one: kind must be cmd/agent, since a number, id a string;
    invalid items are dropped; desc is coerced to string, newlines become spaces, truncated to 80 chars; a non-string toolUseId becomes an empty string; only these five keys are kept, at most BG_LIST_MAX items."""
    if not isinstance(v, list):
        return None
    out = []
    for it in v:
        if len(out) >= BG_LIST_MAX:
            break
        if not isinstance(it, dict) or it.get("kind") not in ("cmd", "agent") or not _is_num(it.get("since")) \
                or not isinstance(it.get("id"), str):
            continue
        tu = it.get("toolUseId")
        if tu is not None and not isinstance(tu, str):
            continue
        desc = it.get("desc")
        desc = re.sub(r"[\r\n]+", " ", "" if desc is None else str(desc))[:BG_DESC_MAX]
        out.append({"kind": it["kind"], "desc": desc, "since": it["since"], "id": it["id"], "toolUseId": tu or ""})
    return out


ERR_KINDS = ("api", "rate_limit", "auth", "wb_error", "wb_stopped")
ERR_TEXT_MAX = 160


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def err_extras(item: dict) -> dict:
    """Error/disconnect fields: errorKind (allowlisted string or null), errorStatus (int or null), errorText (<=160 chars or null),
    errorSince/disconnectedSince/compactedAt (number or null), retryAttempt/retryMax (int>=0 or null), disconnected (bool),
    helpers (int>=0). Omitted if missing or the wrong type (older panels)."""
    out = {}
    if "errorKind" in item and (item["errorKind"] is None or item["errorKind"] in ERR_KINDS):
        out["errorKind"] = item["errorKind"]
    if "errorStatus" in item and (item["errorStatus"] is None or _is_int(item["errorStatus"])):
        out["errorStatus"] = item["errorStatus"]
    if "errorText" in item and (item["errorText"] is None or isinstance(item["errorText"], str)):
        t = item["errorText"]
        out["errorText"] = t[:ERR_TEXT_MAX] if t is not None else None
    for k in ("errorSince", "disconnectedSince", "compactedAt"):
        if k in item and (item[k] is None or _is_num(item[k])):
            out[k] = item[k]
    for k in ("retryAttempt", "retryMax"):
        if k in item and (item[k] is None or (_is_int(item[k]) and item[k] >= 0)):
            out[k] = item[k]
    if isinstance(item.get("disconnected"), bool):
        out["disconnected"] = item["disconnected"]
    if _is_int(item.get("helpers")) and item["helpers"] >= 0:
        out["helpers"] = item["helpers"]
    return out


FORMAT_WARNINGS_MAX = 20
FORMAT_REASON_MAX = 200
DUMP_REQUIRED = ("id", "kind", "status")


def clean_format_warnings(v) -> Optional[list]:
    """Validate a formatWarnings array from --dump: list only, at most 20 items, each a dict with string source/reason
    (reason cut to 200 chars). Malformed items are dropped, extra fields ignored. None if v is not a list."""
    if not isinstance(v, list):
        return None
    out = []
    for w in v[:FORMAT_WARNINGS_MAX]:
        if isinstance(w, dict) and isinstance(w.get("source"), str) and isinstance(w.get("reason"), str):
            out.append({"source": w["source"], "reason": w["reason"][:FORMAT_REASON_MAX]})
    return out


def dump_format_warn(item: dict) -> Optional[str]:
    """Structural problem in a --dump session entry (a required key is absent), else None."""
    for k in DUMP_REQUIRED:
        if k not in item:
            return "dump: session entry missing '%s'" % k
    return None


def agents_of(sess: dict) -> int:
    """Number of dispatched agents: taken from the Mac dump rather than counting the subagents directory. helpers (the panel's merged helper count) takes priority,
    falling back to bgAgents for older panels. Written to the legacy field agents so the frontend and guest allowlist read the same number unchanged."""
    for k in ("helpers", "bgAgents"):
        if k in sess:
            return sess[k]  # already type-checked by err_extras / bg_extras (int>=0)
    return 0


def build_snapshot(dump: List[dict], sessions_dir: str, projects_dir: str, zone_cfg: ZoneConfig,
                   pets: dict, usage: dict, now: float, panel: Optional[dict] = None,
                   roster: Optional[dict] = None, meta_dir: Optional[str] = None,
                   format_warnings=None) -> dict:
    files = read_session_files(sessions_dir)
    cwds = cwds_from(files)
    hidden = hidden_sessions(files) | outbox.active_forks()  # also hide temporary forks that are reading /context
    orca_warns = orca_cli.format_warns()
    sessions = []
    for item in dump:
        sid = item.get("id", "")
        name = item.get("name") or ""
        is_claude = item.get("kind") == "claude"
        if is_claude and sid in hidden:
            continue
        cwd = cwds.get(sid) if is_claude else None
        transcript = find_transcript(projects_dir, sid) if is_claude and sid else None
        pet = pets.get(sid)
        origin, peer = read_origin(projects_dir, transcript)
        sessions.append({
            "id": sid,
            "kind": item.get("kind"),
            "model": item.get("model", ""),
            "name": name,
            "plate": zone_cfg.plate(name),
            "project": item.get("project", ""),
            "cwd": cwd,
            "zone": zone_cfg.resolve(name, cwd),
            "status": item.get("status"),
            "since": item.get("since"),
            "summary": item.get("summary", ""),
            "waitingFor": item.get("waitingFor", ""),
            "pet": pet if isinstance(pet, str) else None,
            "transcript": transcript,
            "origin": origin,
            "peer": peer,
        })
        sessions[-1].update(bg_extras(item))  # six background-task fields; absent for older panels
        sessions[-1].update(err_extras(item))  # error/disconnect fields; absent for older panels
        sessions[-1].update(summary_extras(item))  # three summary-code fields; absent for older panels
        warn = dump_format_warn(item) or orca_warns.get(sid)
        if warn:
            sessions[-1]["formatWarn"] = warn
        fw = clean_format_warnings(item.get("formatWarnings"))
        if fw is not None:
            sessions[-1]["formatWarnings"] = fw  # per-session placement (the Mac side has not settled top-level vs per-session; both pass through)
        meta = read_meta(meta_dir, sid) if is_claude else None
        if meta:
            sessions[-1]["meta"] = meta
        agents = agents_of(sessions[-1])
        if agents:
            sessions[-1]["agents"] = agents  # omitted when 0; the frontend defaults to 0
    snap = {"generatedAt": now, "usage": usage, "zones": zone_cfg.zones_public(), "sessions": sessions,
            "offduty": offduty_from(roster or {}, dump, projects_dir)}
    if panel is not None:
        snap["panel"] = panel
    top = clean_format_warnings(format_warnings)
    if top is not None:
        snap["formatWarnings"] = top
    return snap


_sidecar = None  # orca_stats.Sidecar: started as a background thread in main(); None in tests, in which case the snapshot omits these items


def add_sidecar(snap: dict, side: Optional[dict], cfg: ZoneConfig) -> None:
    """Copy the background thread's latest results into the snapshot: orcaStats / monitor / zones[].taskboard / zoneTokens."""
    if not side:
        return
    stats = side.get("orcaStats")
    snap["orcaStats"] = stats
    snap["monitor"] = side.get("monitor")
    boards = side.get("taskboards") or {}
    for z in snap.get("zones") or []:
        meta = boards.get(z.get("code"))
        z["taskboard"] = dict(meta) if meta else None
    usage = (stats or {}).get("usage") or {}
    if usage.get("todayByProject") is not None:
        snap["zoneTokens"] = orca_stats.zone_tokens_today(
            usage["todayByProject"], snap.get("sessions") or [], lambda path: cfg.resolve("", path))


def write_atomic(path: str, obj: dict) -> None:
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".snapshot-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def beat_path(paths: dict) -> Optional[str]:
    """Heartbeat file: same directory as the snapshot (mounted read-only at /data in the api container); the api uses it to tell a non-responding panel from a stopped helper."""
    if paths.get("beat"):
        return paths["beat"]
    return os.path.join(os.path.dirname(paths["out"]) or ".", "helper-beat.json") if paths.get("out") else None


def write_beat(paths: dict, ok: bool, err: Optional[str]) -> None:
    """Written every round regardless of dump outcome: {at, ok, err, tz}; err is one of timeout / missing (panel executable not found) / exit:N / parse / error.
    tz = local (Mac) UTC offset in seconds; the api container is usually UTC, and the push body's "data as of hh:mm" is computed with it. A write failure is only logged and does not affect the snapshot."""
    now = time.time()
    path = beat_path(paths)
    if not path:
        return
    try:
        write_atomic(path, {"at": now, "ok": bool(ok), "err": err, "tz": int(time.localtime(now).tm_gmtoff)})
    except OSError as e:
        log("heartbeat write failed: %s" % type(e).__name__)


def _dump_once(paths: dict) -> Tuple[bool, Optional[str]]:
    try:
        proc = subprocess.run(paths["dump_cmd"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=DUMP_TIMEOUT)
        if proc.returncode != 0:
            log("dump failed: exit code %d" % proc.returncode)
            return False, "exit:%d" % proc.returncode
        try:
            dump = json.loads(proc.stdout.decode("utf-8"))
        except ValueError:
            log("dump output is not JSON")
            return False, "parse"
        if isinstance(dump, dict) and isinstance(dump.get("sessions"), list):
            pass  # unwrapped just below
        elif not isinstance(dump, list):
            log("dump output is not an array")
            return False, "parse"
        top_warnings = None
        if isinstance(dump, dict) and isinstance(dump.get("sessions"), list):  # top-level form: {"sessions": [...], "formatWarnings": [...]}
            top_warnings = dump.get("formatWarnings")
            dump = dump["sessions"]
        fresh = {i["id"]: i for i in dump if isinstance(i, dict) and isinstance(i.get("id"), str)}
        with _latest_lock:
            _latest_sessions.clear()
            _latest_sessions.update(fresh)
        cfg = load_zone_config(paths["workzones"], HOME, paths.get("zone_style"))
        domain = read_panel_domain()
        snap = build_snapshot(dump, paths["sessions_dir"], paths["projects_dir"], cfg,
                              pets_from(domain), read_usage(paths["usage_dir"]), time.time(),
                              panel_from(domain, fresh), read_roster(paths.get("roster")),
                              meta_dir=paths["usage_dir"], format_warnings=top_warnings)
        snap["orca"] = {"running": orca_running()}
        add_sidecar(snap, _sidecar.latest() if _sidecar else None, cfg)
        write_atomic(paths["out"], snap)
        return True, None
    except subprocess.TimeoutExpired:
        log("dump timed out (%d s)" % DUMP_TIMEOUT)
        return False, "timeout"
    except FileNotFoundError as e:  # panel executable missing; say where to configure it
        if e.filename == paths["dump_cmd"][0]:
            log("snapshot failed: Soulgent for Mac app not found at %s (install Soulgent.app, or set SOULGENT_PANEL in webapp/.env)" % e.filename)
            return False, "missing"
        log("snapshot failed: %s: %s" % (type(e).__name__, e))
    except Exception as e:
        log("snapshot failed: %s: %s" % (type(e).__name__, e))
    return False, "error"


def run_once(paths: dict) -> bool:
    ok, err = _dump_once(paths)
    write_beat(paths, ok, err)
    return ok


def sessions_signature(sessions_dir: str) -> tuple:
    """Fingerprint of the session registry directory: (name, mtime, size) of each *.json, via stat only."""
    sig = []
    try:
        with os.scandir(sessions_dir) as it:
            for e in it:
                if not e.name.endswith(".json"):
                    continue
                try:
                    stt = e.stat()
                except OSError:
                    continue
                sig.append((e.name, stt.st_mtime_ns, stt.st_size))
    except OSError:
        return ()
    return tuple(sorted(sig))


def should_refresh(now: float, last_run: float, sig: tuple, last_sig: tuple, forced: bool) -> bool:
    """Always refresh when INTERVAL elapses; refresh sooner when the registry directory changes or outbox acts, but no faster than MIN_GAP."""
    gap = now - last_run
    if gap < MIN_GAP:
        return False
    return gap >= INTERVAL or forced or sig != last_sig


def outbox_loop(paths: dict) -> None:
    orca_cmd = outbox.find_orca()
    ready = False
    last_cleanup = 0.0
    while True:
        try:
            if not ready:
                os.makedirs(paths["outbox_dir"], exist_ok=True)
                # owner-only: under the Docker Desktop fakeowner mount the api container (uid 10001) can still read and write, other local accounts cannot
                os.chmod(paths["outbox_dir"], 0o700)
                os.makedirs(paths["uploads_dir"], exist_ok=True)
                os.chmod(paths["uploads_dir"], 0o700)
                ready = True
            if time.time() - last_cleanup >= CLEANUP_EVERY:
                last_cleanup = time.time()
                outbox.cleanup_uploads(paths["uploads_dir"], time.time())
            with _latest_lock:
                sessions = dict(_latest_sessions)
            n = outbox.process_once(paths["outbox_dir"], sessions, paths["sessions_dir"], orca_cmd,
                                    paths["send_log"], time.time(), uploads_dir=paths["uploads_dir"])
            if n:
                _refresh_event.set()
        except Exception as e:
            log("outbox processing failed: %s: %s" % (type(e).__name__, e))
        time.sleep(OUTBOX_INTERVAL)


def main() -> None:
    global _sidecar
    threading.Thread(target=outbox_loop, args=(DEFAULT_PATHS,), daemon=True).start()
    _sidecar = orca_stats.Sidecar(outbox.find_orca(), DEFAULT_PATHS["workzones"], HOME, DEFAULT_PATHS["taskboard_dir"],
                                 lineage_src=DEFAULT_PATHS["lineage_src"])
    threading.Thread(target=_sidecar.loop, args=(log,), daemon=True).start()
    _ix = textidx.TextIndexer(DEFAULT_PATHS["out"], DEFAULT_PATHS["projects_dir"], DEFAULT_PATHS["lineage_src"],
                              DEFAULT_PATHS["textidx_dir"])
    threading.Thread(target=_ix.loop, args=(log,), daemon=True).start()  # incremental index build every 15 s
    last_run = 0.0
    last_sig = ()
    while True:
        now = time.time()
        sig = sessions_signature(DEFAULT_PATHS["sessions_dir"])
        forced = _refresh_event.is_set()
        if should_refresh(now, last_run, sig, last_sig, forced):
            _refresh_event.clear()
            last_sig = sig
            run_once(DEFAULT_PATHS)
            last_run = time.time()
        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
