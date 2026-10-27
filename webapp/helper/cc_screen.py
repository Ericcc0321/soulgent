"""Claude Code terminal-screen adapter: recognizes menus and the input box on the screen text read through orca."""

import re
from typing import List, Optional

from helper import orca_cli
from helper.orca_cli import _orca_json

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")


def strip_ansi(s: str) -> str:
    return _ANSI_RE.sub("", s)


_MENU_OPT_RE = re.compile(r"^[\s│|]*❯\s*\d+[.)]\s")  # selected numbered option: "❯ 1. Yes"
_MENU_HINTS = ("Esc to cancel", "Enter to select", "to navigate", "Do you want to proceed",
               "Do you want to make this edit", "Do you want to create", "Would you like to proceed")
MENU_TAIL = 40


def menu_on_screen(tail) -> bool:
    """The session counts as stopped at a menu if the last MENU_TAIL screen lines look like one (a selected numbered item or the menu footer hint). Prefer blocking."""
    lines = [strip_ansi(str(x)) for x in (tail or [])][-MENU_TAIL:]
    for ln in lines:
        if _MENU_OPT_RE.match(ln) or any(h in ln for h in _MENU_HINTS):
            return True
    return False


def menu_gate(item: dict, handle: str, orca_cmd: List[str], orca_json=_orca_json) -> Optional[str]:
    """Whether a plain (non-steps/key) request may be sent: session waiting or a menu on screen -> session-waiting; screen unreadable -> orca-failed (never send blind)."""
    if item.get("status") == "waiting":
        return "session-waiting"
    data = orca_json(orca_cmd, ["terminal", "read", "--terminal", handle, "--screen"])
    tail = (((data or {}).get("result") or {}).get("terminal") or {}).get("tail")
    if not isinstance(tail, list):
        if data is not None:  # orca answered ok but the screen JSON has no tail: a structural change, not a failure to run
            miss = orca_cli.missing_key(data, ["result", "terminal", "tail"])
            orca_cli.note_format_warn(item.get("id"), "orca: terminal read JSON missing '%s'" % (miss or "tail"))
        return "orca-failed"
    orca_cli.clear_format_warn(item.get("id"))
    return "session-waiting" if menu_on_screen(tail) else None


def input_box(tail) -> Optional[str]:
    """The input box of Claude Code sits between the last two horizontal rules (─) on screen: return its content without the ❯ (lines joined by spaces), None if not found."""
    lines = [strip_ansi(str(x)) for x in (tail or [])]
    borders = [i for i, ln in enumerate(lines) if ln.strip().startswith("─") and ln.strip().count("─") >= 4]
    if len(borders) < 2:
        return None
    a, b = borders[-2], borders[-1]
    body = [ln.strip() for ln in lines[a + 1:b]]
    if body and body[0].startswith("❯"):
        body[0] = body[0][1:].strip()
    return " ".join(x for x in body if x).strip()


def _screen_input(orca_cmd: List[str], handle: str, orca_json=_orca_json) -> Optional[str]:
    data = orca_json(orca_cmd, ["terminal", "read", "--terminal", handle, "--screen"])
    tail = (((data or {}).get("result") or {}).get("terminal") or {}).get("tail")
    return input_box(tail) if isinstance(tail, list) else None
