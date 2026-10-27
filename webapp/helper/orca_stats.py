"""Helper: Orca stats, system monitor, zone task boards.

- Orca stats: reads ~/Library/Application Support/orca/orca-stats.json (aggregates) and orca-claude-usage.json
  (dailyAggregates) and summarizes them into the snapshot's orcaStats field. Both files are 0.5-2MB; re-read only when
  mtime changed and at least 30 s have passed.
- Monitor: every 10 s a background thread samples `orca diagnostics memory --json` and Mac health (memory pressure, swap,
  load, disk, battery); results stay in memory and the snapshot just copies them, so the main snapshot isn't slowed down.
  Each subprocess gets at most 3 s; failures give None.
- Task boards: reads only the taskboard path of each zone in workzones.json (max 20KB) and copies it to
  data/taskboards/<code>.md for the api; the snapshot only carries "exists, size, modified".

Read-only throughout: never writes to Orca or the zone file.
"""

import json
import os
import re
import subprocess
import tempfile
import threading
import time
from typing import Dict, List, Optional

from helper import settings

ORCA_DIR = settings.orca_stats_dir()  # default ~/Library/Application Support/orca; override with SOULGENT_ORCA_STATS_DIR
STATS_FILE = "orca-stats.json"
USAGE_FILE = "orca-claude-usage.json"
STATS_MIN_GAP = 30.0      # the stats file changes constantly (events keep being appended); re-read at most every 30 s
MONITOR_EVERY = 10.0      # sample monitoring every 10 s
SUB_TIMEOUT = 3           # subprocess timeout (seconds)
HEAT_DAYS = 42            # intensity grid: last 6 weeks
TOP_PROJECTS = 6          # today's top N projects
TOP_WORKTREES = 8         # top N terminals on the monitor page (by memory)
TASKBOARD_MAX = 20 * 1024

# ---------- Pricing ----------
# Source: official Anthropic API pricing (price table cached by Claude Code's built-in claude-api skill), USD per million tokens.
# in = input, out = output, read = cache read; cache writes are the input price times a multiplier: 1.25x for 5 minutes, 2x for 1 hour (official prompt caching docs).
# Cache reads are normally 0.1x the input price; Opus 5.5 is $0.20 and Fable 5.1 is $0.25 (official special prices, listed separately).
# Haiku 5.5's $0.10/$0.50 is the price for prompts up to 100k tokens ($0.50/$2.50 beyond that); everything here is priced as a short prompt.
# All past days are priced with today's table, not the price at the time.
PRICES = {
    "claude-fable-5-1": {"in": 10.0, "out": 50.0, "read": 0.25},
    "claude-fable-5": {"in": 10.0, "out": 50.0, "read": 1.0},
    "claude-opus-5-5": {"in": 4.0, "out": 20.0, "read": 0.20},
    "claude-opus-5": {"in": 5.0, "out": 25.0, "read": 0.50},
    "claude-opus-4-8": {"in": 5.0, "out": 25.0, "read": 0.50},
    "claude-opus-4-7": {"in": 5.0, "out": 25.0, "read": 0.50},
    "claude-opus-4-6": {"in": 5.0, "out": 25.0, "read": 0.50},
    "claude-sonnet-5-5": {"in": 2.0, "out": 10.0, "read": 0.20},
    "claude-sonnet-5": {"in": 2.0, "out": 10.0, "read": 0.20},
    "claude-sonnet-4-6": {"in": 3.0, "out": 15.0, "read": 0.30},
    "claude-haiku-5-5": {"in": 0.10, "out": 0.50, "read": 0.01},
    "claude-haiku-4-5": {"in": 1.0, "out": 5.0, "read": 0.10},
}
WRITE_5M = 1.25
WRITE_1H = 2.0
# Models missing from the table: estimated at the current generation's price for the same family (fable/opus/sonnet/haiku), assuming old and new cost the same;
# models whose family is unrecognized get no cost (priced=False), and the page marks them as unpriced.
FAMILY_DEFAULT = {"fable": "claude-fable-5-1", "mythos": "claude-fable-5-1", "opus": "claude-opus-5-5",
                  "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"}


def price_for(model: str) -> Optional[dict]:
    """Model -> price. First match by longest prefix (claude-haiku-4-5-20251001 -> claude-haiku-4-5), then fall back to the family."""
    m = str(model or "").lower()
    best = None
    for key in PRICES:
        if (m == key or m.startswith(key + "-")) and (best is None or len(key) > len(best)):
            best = key
    if best:
        return PRICES[best]
    for fam, key in FAMILY_DEFAULT.items():
        if fam in m:
            return PRICES[key]
    return None


def _n(v) -> int:
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0 else 0


def row_tokens(r: dict) -> int:
    """Total tokens of a row: input + output + cache read + cache write (same basis as Orca's stats page; cache reads dominate)."""
    return _n(r.get("inputTokens")) + _n(r.get("outputTokens")) + _n(r.get("cacheReadTokens")) + _n(r.get("cacheWriteTokens"))


def row_cost(r: dict) -> Optional[float]:
    """Estimated cost of a row (USD); None for an unrecognized model. 1-hour cache writes are 2x, other cache writes 1.25x."""
    p = price_for(r.get("model"))
    if p is None:
        return None
    write = _n(r.get("cacheWriteTokens"))
    w1h = min(_n(r.get("cacheWrite1hTokens")), write)
    usd = (_n(r.get("inputTokens")) * p["in"] + _n(r.get("outputTokens")) * p["out"]
           + _n(r.get("cacheReadTokens")) * p["read"]
           + w1h * p["in"] * WRITE_1H + (write - w1h) * p["in"] * WRITE_5M)
    return usd / 1e6


def project_path(key: str) -> Optional[str]:
    """projectKey -> directory: worktree:<repoId>::<path>[::workspace:<id>] or cwd:<path>."""
    key = str(key or "")
    if key.startswith("cwd:"):
        path = key[4:]
    elif key.startswith("worktree:") and "::" in key:
        path = key.split("::", 1)[1].split("::", 1)[0]
    else:
        return None
    return path or None


def _day_list(today: str, n: int) -> List[str]:
    t = time.mktime(time.strptime(today, "%Y-%m-%d")) + 12 * 3600  # use noon to avoid DST boundaries
    return [time.strftime("%Y-%m-%d", time.localtime(t - 86400 * i)) for i in range(n - 1, -1, -1)]


def summarize_usage(rows: list, today: str) -> dict:
    """dailyAggregates -> the summary the page needs. today is the local date YYYY-MM-DD."""
    by_day = {}      # type: Dict[str, int]
    by_model = {}    # type: Dict[str, dict]
    today_proj = {}  # type: Dict[str, dict]
    total = 0
    cost = 0.0
    unpriced = 0
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not isinstance(r.get("day"), str):
            continue
        tok = row_tokens(r)
        total += tok
        by_day[r["day"]] = by_day.get(r["day"], 0) + tok
        model = str(r.get("model") or "")  # empty string when the model is missing (the frontend localizes the label)
        m = by_model.setdefault(model, {"model": model, "tokens": 0, "usd": 0.0, "priced": True})
        m["tokens"] += tok
        usd = row_cost(r)
        if usd is None:
            m["priced"] = False
            unpriced += tok
        else:
            m["usd"] += usd
            cost += usd
        if r["day"] == today:
            key = str(r.get("projectKey") or "")
            p = today_proj.setdefault(key, {"label": str(r.get("projectLabel") or key), "path": project_path(key), "tokens": 0})
            p["tokens"] += tok
    active = [d for d, t in by_day.items() if t > 0]
    peak = max(active, key=lambda d: (by_day[d], d)) if active else None
    models = sorted(by_model.values(), key=lambda m: -m["usd"])
    for m in models:
        m["usd"] = round(m["usd"], 2)
    projects = sorted(today_proj.values(), key=lambda p: -p["tokens"])
    return {
        "totalTokens": total,
        "costUsd": round(cost, 2),
        "unpricedTokens": unpriced,
        "activeDays": len(active),
        "firstDay": min(active) if active else None,
        "peakDay": {"day": peak, "tokens": by_day[peak]} if peak else None,
        "days": [{"day": d, "tokens": by_day.get(d, 0)} for d in _day_list(today, HEAT_DAYS)],
        "byModel": models,
        "todayTokens": by_day.get(today, 0),
        "todayByProject": projects,
    }


def stats_from(data) -> Optional[dict]:
    """aggregates of orca-stats.json -> {agents, agentTimeMs, prs, firstEventAt (seconds)}."""
    agg = data.get("aggregates") if isinstance(data, dict) else None
    if not isinstance(agg, dict):
        return None
    first = agg.get("firstEventAt")
    return {
        "agents": _n(agg.get("totalAgentsSpawned")),
        "agentTimeMs": _n(agg.get("totalAgentTimeMs")),
        "prs": _n(agg.get("totalPRsCreated")),
        "firstEventAt": first / 1000.0 if isinstance(first, (int, float)) and first > 0 else None,
    }


def zone_tokens_today(projects: list, sessions: list, resolve) -> dict:
    """Today's tokens aggregated by zone: if a project directory has on-duty sessions and they all belong to one zone, attribute to that zone;
    if it has no sessions, use the zones file's directory rules (resolve(path)); if sessions span several zones or none match, do not attribute and count it as unmatched."""
    zones = {}  # type: Dict[str, int]
    unmatched = 0
    for p in projects or []:
        path = p.get("path")
        tok = _n(p.get("tokens"))
        code = None
        if path:
            base = path.rstrip("/") + "/"
            hit = {s.get("zone") for s in sessions or []
                   if isinstance(s.get("cwd"), str) and (s["cwd"] == path or s["cwd"].startswith(base))}
            if len(hit) == 1:
                code = next(iter(hit))
            elif not hit:
                code = resolve(path)
        if code:
            zones[code] = zones.get(code, 0) + tok
        else:
            unmatched += tok
    return {"byZone": zones, "unmatched": unmatched}


class StatsReader:
    """Read cache for the two stats files: reuse the old result if mtime is unchanged or less than STATS_MIN_GAP has passed since the last read."""

    def __init__(self, folder: str = ORCA_DIR) -> None:
        self.folder = folder
        self.stamp = {}   # type: Dict[str, tuple]
        self.read_at = {}  # type: Dict[str, float]
        self.data = {}    # type: Dict[str, object]

    def _load(self, name: str, now: float, parse):
        path = os.path.join(self.folder, name)
        try:
            stt = os.stat(path)
        except OSError:
            self.data[name] = None
            return None
        stamp = (stt.st_mtime_ns, stt.st_size)
        if name in self.data and (self.stamp.get(name) == stamp or now - self.read_at.get(name, 0) < STATS_MIN_GAP):
            return self.data[name]
        try:
            with open(path, "r", encoding="utf-8") as f:
                val = parse(json.load(f))
        except (OSError, ValueError):
            val = self.data.get(name)  # caught a half-written file: keep the previous value
        self.stamp[name] = stamp
        self.read_at[name] = now
        self.data[name] = val
        return val

    def read(self, now: float, today: str) -> Optional[dict]:
        stats = self._load(STATS_FILE, now, stats_from)
        usage = self._load(USAGE_FILE, now, lambda d: d.get("dailyAggregates") if isinstance(d, dict) else None)
        if stats is None and usage is None:
            return None
        out = dict(stats or {})
        # recompute when the date changes, so the summary is cached by (file stamp, today)
        key = (self.stamp.get(USAGE_FILE), today)
        if getattr(self, "_sum_key", None) != key:
            self._sum_key = key
            self._sum = summarize_usage(usage, today) if isinstance(usage, list) else None
        out["usage"] = self._sum
        return out


# ---------- Monitoring ----------
def _run(cmd: List[str]) -> Optional[str]:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=SUB_TIMEOUT)
    except Exception:
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode("utf-8", "replace")


def _f(v) -> Optional[float]:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def parse_diag(text: Optional[str]) -> Optional[dict]:
    """orca diagnostics memory --json -> Orca itself, per-project terminals (top 8 by memory), totals, host memory/load."""
    if not text:
        return None
    try:
        res = json.loads(text).get("result")
    except (ValueError, AttributeError):
        return None
    if not isinstance(res, dict):
        return None
    app = res.get("app") if isinstance(res.get("app"), dict) else {}
    wts = []
    for w in res.get("worktrees") or []:
        if not isinstance(w, dict):
            continue
        wts.append({"name": str(w.get("worktreeName") or w.get("repoName") or "?"),
                    "repo": str(w.get("repoName") or ""),
                    "cpu": _f(w.get("cpu")) or 0.0, "memory": _f(w.get("memory")) or 0.0,
                    "terminals": len(w.get("sessions") or [])})
    wts.sort(key=lambda w: -w["memory"])
    host = res.get("host") if isinstance(res.get("host"), dict) else {}
    return {
        "app": {"cpu": _f(app.get("cpu")), "memory": _f(app.get("memory"))},
        "worktrees": wts[:TOP_WORKTREES],
        "worktreeCount": len(wts),
        "worktreeMemory": sum(w["memory"] for w in wts),
        "worktreeCpu": sum(w["cpu"] for w in wts),
        "totalCpu": _f(res.get("totalCpu")),
        "totalMemory": _f(res.get("totalMemory")),
        "host": {"total": _f(host.get("totalMemory")), "available": _f(host.get("availableMemory")),
                 "cores": _f(host.get("cpuCoreCount"))},
    }


PRESSURE = {1: "normal", 2: "warn", 4: "critical"}


def parse_pressure(text: Optional[str]) -> Optional[str]:
    """sysctl -n kern.memorystatus_vm_pressure_level: 1 normal / 2 warning / 4 critical."""
    try:
        return PRESSURE.get(int(str(text).strip()))
    except (TypeError, ValueError):
        return None


_SWAP_RE = re.compile(r"total = ([\d.]+)M\s+used = ([\d.]+)M")


def parse_swap(text: Optional[str]) -> Optional[dict]:
    """sysctl vm.swapusage → {total, used}(bytes)."""
    m = _SWAP_RE.search(text or "")
    if not m:
        return None
    mb = 1024 * 1024
    return {"total": float(m.group(1)) * mb, "used": float(m.group(2)) * mb}


_PAGE_RE = re.compile(r"page size of (\d+) bytes")
_VM_LINE_RE = re.compile(r'^"?([^:"]+)"?:\s+(\d+)\.?\s*$')


def parse_vm_stat(text: Optional[str]) -> Optional[dict]:
    """vm_stat -> Activity Monitor basis (bytes): {app, wired, compressed, cached}.
    app = Anonymous − purgeable(without an Anonymous line: active+inactive+speculative - file-backed - purgeable);
    wired = wired down; compressed = occupied by compressor; cached = file-backed + purgeable."""
    if not text:
        return None
    m = _PAGE_RE.search(text)
    page = int(m.group(1)) if m else 16384
    v: Dict[str, int] = {}
    for line in text.splitlines():
        lm = _VM_LINE_RE.match(line.strip())
        if lm:
            v[lm.group(1).strip()] = int(lm.group(2))
    need = ("Pages wired down", "Pages occupied by compressor", "File-backed pages")
    if any(k not in v for k in need):
        return None
    purg = v.get("Pages purgeable", 0)
    if "Anonymous pages" in v:
        app = v["Anonymous pages"] - purg
    else:
        app = (v.get("Pages active", 0) + v.get("Pages inactive", 0) + v.get("Pages speculative", 0)
               - v["File-backed pages"] - purg)
    return {"app": max(0, app) * page, "wired": v["Pages wired down"] * page,
            "compressed": v["Pages occupied by compressor"] * page,
            "cached": (v["File-backed pages"] + purg) * page}


def sample_mem() -> Optional[dict]:
    """Memory (Activity Monitor basis): total + each vm_stat item + used = app + wired + compressed."""
    vm = parse_vm_stat(_run(["vm_stat"]))
    if vm is None:
        return None
    try:
        total = int(str(_run(["sysctl", "-n", "hw.memsize"])).strip())
    except ValueError:
        total = None
    return {"total": total, **vm, "used": vm["app"] + vm["wired"] + vm["compressed"]}


def parse_load(text: Optional[str]) -> Optional[List[float]]:
    """sysctl -n vm.loadavg → [1 min, 5 min, 15 min]."""
    nums = re.findall(r"\d+(?:\.\d+)?", text or "")
    return [float(x) for x in nums[:3]] if len(nums) >= 3 else None


_BATT_RE = re.compile(r"(\d+)%;\s*([^;]+);")


def parse_batt(text: Optional[str]) -> Optional[dict]:
    """pmset -g batt → {pct, charging, ac}; None if there is no battery (desktop)."""
    m = _BATT_RE.search(text or "")
    if not m:
        return None
    state = m.group(2).strip().lower()
    ac = "AC Power" in (text or "")
    return {"pct": int(m.group(1)), "charging": state == "charging", "ac": ac or state in ("charged", "ac attached")}


def disk_free(path: str = "/") -> Optional[dict]:
    try:
        s = os.statvfs(path)
    except OSError:
        return None
    return {"free": float(s.f_bavail * s.f_frsize), "total": float(s.f_blocks * s.f_frsize)}


_computer_name = []  # computer name is looked up only once


def computer_name() -> Optional[str]:
    """The line under "signed-in devices" on the monitor page: computer name (scutil --get ComputerName), looked up once."""
    if not _computer_name:
        name = (_run(["scutil", "--get", "ComputerName"]) or "").strip()
        _computer_name.append(name or None)
    return _computer_name[0]


def sample_monitor(orca_cmd: List[str], now: Optional[float] = None) -> dict:
    """Take one sample. Available memory and core count come straight from diagnostics' host (computed by Orca from memory pressure), with no extra process;
    both are None when Orca is not running."""
    diag = parse_diag(_run(orca_cmd + ["diagnostics", "memory", "--json"]))
    host = (diag or {}).get("host") or {}
    mac = {
        "name": computer_name(),
        "pressure": parse_pressure(_run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"])),
        "memTotal": host.get("total"),
        "memAvailable": host.get("available"),
        "mem": sample_mem(),
        "cores": host.get("cores"),
        "swap": parse_swap(_run(["sysctl", "vm.swapusage"])),
        "load": parse_load(_run(["sysctl", "-n", "vm.loadavg"])),
        "disk": disk_free("/"),
        "battery": parse_batt(_run(["pmset", "-g", "batt"])),
    }
    if diag is not None:
        diag.pop("host", None)
    return {"at": time.time() if now is None else now, "orca": diag, "mac": mac}


# ---------- Task board ----------
def taskboard_paths(workzones: str, home: str) -> Dict[str, str]:
    """The taskboard of each zone in workzones.json (~ expanded). Only paths from here are used; nothing else is read."""
    try:
        with open(workzones, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    out = {}
    zones = data.get("zones") if isinstance(data, dict) else None
    for code, z in (zones or {}).items():
        p = z.get("taskboard") if isinstance(z, dict) else None
        if isinstance(p, str) and p.strip() and re.match(r"^[A-Za-z0-9_-]{1,32}$", code):
            p = p.strip()
            out[code] = home + p[1:] if p == "~" or p.startswith("~/") else p
    return out


def _write_atomic_text(path: str, text: str) -> None:
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tb-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def sync_taskboards(paths: Dict[str, str], out_dir: str, cache: dict) -> Dict[str, dict]:
    """Copy each zone's task board to out_dir/<code>.md (only when the source's mtime/size changed); returns the metadata for the snapshot.
    cache: code -> (source stamp, metadata). The copy is deleted when the source is gone."""
    meta = {}
    for code, src in paths.items():
        dst = os.path.join(out_dir, code + ".md")
        try:
            stt = os.stat(src)
        except OSError:
            cache.pop(code, None)
            try:
                os.unlink(dst)
            except OSError:
                pass
            continue
        stamp = (stt.st_mtime_ns, stt.st_size)
        hit = cache.get(code)
        if not hit or hit[0] != stamp or not os.path.exists(dst):
            try:
                with open(src, "rb") as f:
                    raw = f.read(TASKBOARD_MAX + 1)
            except OSError:
                continue
            cut = len(raw) > TASKBOARD_MAX
            text = raw[:TASKBOARD_MAX].decode("utf-8", "ignore")
            _write_atomic_text(dst, text)
            hit = (stamp, {"mtime": stt.st_mtime, "size": stt.st_size, "truncated": cut})
            cache[code] = hit
        meta[code] = hit[1]
    return meta


# ---------- Window-handoff lineage (optional extension, file given by SOULGENT_LINEAGE) -> data/lineage.jsonl ----------
# The api container mounts only ~/.claude/projects and data/ and cannot see the lineage source, so it is copied like the task boards (append-only file; when too large keep the tail's whole lines).
LINEAGE_MAX = 1024 * 1024


def sync_lineage(src: str, dst: str, cache: dict) -> Optional[dict]:
    """Copy only when the source's mtime/size changed; delete the copy and return None when the source is gone. cache holds the last (stamp, metadata)."""
    try:
        stt = os.stat(src)
    except OSError:
        cache.clear()
        try:
            os.unlink(dst)
        except OSError:
            pass
        return None
    stamp = (stt.st_mtime_ns, stt.st_size)
    if cache.get("stamp") != stamp or not os.path.exists(dst):
        with open(src, "rb") as f:
            cut = stt.st_size > LINEAGE_MAX
            if cut:
                f.seek(stt.st_size - LINEAGE_MAX)
            raw = f.read(LINEAGE_MAX)
        if cut:
            raw = raw[raw.find(b"\n") + 1:]
        _write_atomic_text(dst, raw.decode("utf-8", "ignore"))
        cache["stamp"] = stamp
        cache["meta"] = {"mtime": stt.st_mtime, "size": stt.st_size, "truncated": cut}
    return cache.get("meta")


# ---------- Background thread ----------
class Sidecar:
    """Background thread: samples monitoring every 10 s, reads the stats files, syncs task boards; the main snapshot only reads latest()."""

    def __init__(self, orca_cmd: List[str], workzones: str, home: str, taskboard_dir: str,
                 orca_dir: str = ORCA_DIR, lineage_src: Optional[str] = None) -> None:
        self.orca_cmd = orca_cmd
        self.workzones = workzones
        self.home = home
        self.taskboard_dir = taskboard_dir
        self.stats = StatsReader(orca_dir)
        self.tb_cache = {}  # type: dict
        self.lock = threading.Lock()
        self.state = {"monitor": None, "orcaStats": None, "taskboards": {}}
        # lineage copy (the api reads data/lineage.jsonl)
        self.lineage_src = lineage_src or ""  # empty = not configured, no sync
        self.lineage_dst = os.path.join(os.path.dirname(os.path.abspath(taskboard_dir)), "lineage.jsonl")
        self.lineage_cache = {}  # type: dict

    def tick(self, log=None) -> None:
        now = time.time()
        parts = {}
        for key, fn in (("monitor", lambda: sample_monitor(self.orca_cmd, now)),
                        ("orcaStats", lambda: self.stats.read(now, time.strftime("%Y-%m-%d", time.localtime(now)))),
                        ("taskboards", lambda: sync_taskboards(taskboard_paths(self.workzones, self.home),
                                                               self.taskboard_dir, self.tb_cache)),
                        ("lineage", lambda: sync_lineage(self.lineage_src, self.lineage_dst, self.lineage_cache))):
            try:
                parts[key] = fn()
            except Exception as e:  # one failing item does not affect the others
                if log:
                    log("%s failed: %s: %s" % (key, type(e).__name__, e))
        with self.lock:
            self.state.update(parts)

    def latest(self) -> dict:
        with self.lock:
            return dict(self.state)

    def loop(self, log=None) -> None:
        while True:
            self.tick(log)
            time.sleep(MONITOR_EVERY)
