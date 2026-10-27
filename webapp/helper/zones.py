"""Zone rules, ported from ../app/ZoneModel.swift (resolve / plate / prefix).

Reads ~/.claude/workzones.json (read-only; maintained elsewhere). Which zone a session belongs to:
name prefix first -> directory (longest match) -> default -> none.

Each zone may carry two display-only fields (used by the phone, ignored by the Mac panel):
  short  short name on cross-team badges (falls back to name)
  fx     "working" avatar effect in the chat list: marquee / circuit / halo / orbit (none = the pet walks out of the frame)
They can live in the zone entries of workzones.json, or in a private local style file (default webapp/data/zone-style.json,
format {"<zone code>": {"short": "...", "fx": "..."}}); the style file wins.
"""

import json
import math
import os
import sys
from typing import Dict, List, Optional

_HEX_DIGITS = set("0123456789abcdefABCDEF")
FX_KINDS = ("marquee", "circuit", "halo", "orbit")  # zone avatar effects (neutral names, unrelated to zone codes)
SHORT_MAX = 12


def _valid_color(text: object) -> Optional[str]:
    if not isinstance(text, str):
        return None
    digits = text[1:] if text.startswith("#") else text
    if len(digits) == 6 and set(digits) <= _HEX_DIGITS:
        return text
    return None


def _short(v: object) -> Optional[str]:
    if not isinstance(v, str):
        return None
    v = v.strip()
    return v[:SHORT_MAX] if v else None


def _fx(v: object) -> Optional[str]:
    return v if isinstance(v, str) and v in FX_KINDS else None


def _expand(folder: str, home: str) -> str:
    if folder == "~":
        return home
    if folder.startswith("~/"):
        return home + folder[1:]
    return folder


class ZoneConfig:
    def __init__(self, zones: Optional[List[dict]] = None, dirs: Optional[Dict[str, str]] = None,
                 fallback: Optional[str] = None) -> None:
        self.zones = zones or []      # zones sorted by order
        self.dirs = dirs or {}        # directory (~ expanded) -> zone code
        self.fallback = fallback      # default zone; None if not a known zone

    @classmethod
    def parse(cls, data: dict, home: str, style: Optional[dict] = None) -> "ZoneConfig":
        """style: local private {code: {short, fx}}, overriding same-named fields in workzones.json entries."""
        style = style if isinstance(style, dict) else {}
        zones = []
        raw_zones = data.get("zones")
        if not isinstance(raw_zones, dict):
            raw_zones = {}
        for code, entry in raw_zones.items():
            entry = entry if isinstance(entry, dict) else {}
            extra = style.get(code) if isinstance(style.get(code), dict) else {}
            order = entry.get("order")
            if isinstance(order, bool) or not isinstance(order, (int, float)) \
                    or (isinstance(order, float) and not math.isfinite(order)):
                order = sys.maxsize
            zones.append({
                "code": code,
                "name": entry.get("name") if isinstance(entry.get("name"), str) else code,
                "color": _valid_color(entry.get("color")),
                "order": int(order),
                "lead": entry.get("lead") if isinstance(entry.get("lead"), str) else None,
                "short": _short(extra.get("short")) or _short(entry.get("short")),
                "fx": _fx(extra.get("fx")) or _fx(entry.get("fx")),
            })
        zones.sort(key=lambda z: (z["order"], z["code"]))

        dirs = {}
        raw_dirs = data.get("dirs")
        if not isinstance(raw_dirs, dict):
            raw_dirs = {}
        for folder, code in raw_dirs.items():
            if isinstance(code, str):
                dirs[_expand(folder, home)] = code

        fallback = data.get("default")
        known = {z["code"] for z in zones}
        if not (isinstance(fallback, str) and fallback in known):
            fallback = None
        return cls(zones, dirs, fallback)

    def _zone(self, code: str) -> Optional[dict]:
        for z in self.zones:
            if z["code"] == code:
                return z
        return None

    def _prefix(self, name: str) -> Optional[str]:
        """The part of the name before the first '-', if it is a known zone code."""
        if "-" not in name:
            return None
        head = name.split("-", 1)[0]
        return head if self._zone(head) is not None else None

    def resolve(self, name: str, cwd: Optional[str]) -> Optional[str]:
        """Return the zone code, or None."""
        code = self._prefix(name)
        if code is not None:
            return code
        best_len = -1
        best_code = None
        if cwd:
            for folder, dir_code in self.dirs.items():
                if self._zone(dir_code) is None:
                    continue
                boundary = folder if folder.endswith("/") else folder + "/"
                holds = cwd == folder or cwd.startswith(boundary)
                if holds and len(folder) > best_len:
                    best_len = len(folder)
                    best_code = dir_code
        return best_code if best_code is not None else self.fallback

    def plate(self, name: str) -> str:
        """Name with the zone prefix removed, e.g. Docs-wiki-tracker -> wiki-tracker."""
        code = self._prefix(name)
        if code is None:
            return name
        rest = name[len(code) + 1:]
        return rest if rest else name

    def zones_public(self) -> List[dict]:
        return [{k: z[k] for k in ("code", "name", "color", "order", "lead", "short", "fx")} for z in self.zones]


_cache = {}  # (path, style_path) -> ((stamp, style_stamp), ZoneConfig)


def _stamp(path: Optional[str]):
    if not path:
        return None
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime, st.st_size)


def _load_style(path: Optional[str]) -> dict:
    """Private style file; missing or corrupt counts as absent."""
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError, RecursionError):
        return {}
    return data if isinstance(data, dict) else {}


def load_zone_config(path: str, home: str, style_path: Optional[str] = None) -> ZoneConfig:
    """Cached by the mtime+size of workzones.json and the style file; returns an empty config if workzones.json is missing or unparsable."""
    stamp = _stamp(path)
    if stamp is None:
        return ZoneConfig()
    key = (path, style_path)
    stamps = (stamp, _stamp(style_path))
    cached = _cache.get(key)
    if cached is not None and cached[0] == stamps:
        return cached[1]
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        config = ZoneConfig.parse(data if isinstance(data, dict) else {}, home, _load_style(style_path))
    except (OSError, ValueError, RecursionError):
        config = ZoneConfig()
    _cache[key] = (stamps, config)
    return config
