#!/usr/bin/env python3
"""Minimal Claude Code status line for the Soulgent helper (stdlib only).

Reads the status line JSON Claude Code pipes on stdin, writes
  $SOULGENT_STATUSLINE_DIR/meta.<session_id>.json   (default dir: /tmp/claude-statusline)
  $SOULGENT_STATUSLINE_DIR/shared.five_hour / shared.seven_day   (only if the input has rate_limits)
and prints one short line. Every field is optional; a missing one is simply left out.
"""
import json
import os
import re
import sys
import tempfile
import time


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def write_atomic(path, text):
    """Write via a temp file in the same directory, then rename, so the helper never reads half a file."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
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


def build_meta(d):
    """Map Claude Code's status line input to the fields helper/snapshot.py:meta_from reads."""
    model = d.get("model")
    if isinstance(model, dict):
        model = model.get("display_name") or model.get("id")
    cw = d.get("context_window") if isinstance(d.get("context_window"), dict) else {}
    window = num(cw.get("context_window_size"))
    pct = num(cw.get("used_percentage"))
    usage = cw.get("current_usage") if isinstance(cw.get("current_usage"), dict) else {}
    used = None
    parts = [num(usage.get(k)) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")]
    if any(p is not None for p in parts):
        used = sum(p for p in parts if p is not None)
    if pct is None and used is not None and window:
        pct = used * 100.0 / window
    if used is None and pct is not None and window:
        used = pct * window / 100.0
    effort = d.get("effort")
    if isinstance(effort, dict):
        effort = effort.get("level")
    meta = {
        "model": model if isinstance(model, str) else None,
        "effort": effort if isinstance(effort, str) else None,
        "fast": d.get("fast_mode") is True,
        "used_percentage": pct,
        "used_tokens": used,
        "window": window,
        "ts": int(time.time()),
        # "speed" (tokens/s) is not part of the input; left out, so t/s stays empty.
    }
    return {k: v for k, v in meta.items() if v is not None}


def write_quota(out_dir, d):
    """shared.<window> holds two whitespace-separated numbers: used percent, reset time (epoch seconds)."""
    rl = d.get("rate_limits") if isinstance(d.get("rate_limits"), dict) else {}
    for key in ("five_hour", "seven_day"):
        w = rl.get(key) if isinstance(rl.get(key), dict) else {}
        pct, resets = num(w.get("used_percentage")), num(w.get("resets_at"))
        if pct is not None and resets is not None:
            write_atomic(os.path.join(out_dir, "shared." + key), "%s\n%s\n" % (pct, int(resets)))


def main():
    try:
        d = json.load(sys.stdin)
    except ValueError:
        d = {}
    if not isinstance(d, dict):
        d = {}
    meta = build_meta(d)
    sid = d.get("session_id")
    out_dir = os.environ.get("SOULGENT_STATUSLINE_DIR") or "/tmp/claude-statusline"
    try:
        os.makedirs(out_dir, exist_ok=True)
        if isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9_-]+", sid):  # same charset the helper accepts
            write_atomic(os.path.join(out_dir, "meta.%s.json" % sid), json.dumps(meta))
        write_quota(out_dir, d)
    except OSError:
        pass  # never break the status line over a write failure
    bits = [meta.get("model") or "Claude"]
    if "used_percentage" in meta:
        bits.append("ctx %d%%" % round(meta["used_percentage"]))
    print(" | ".join(bits))


if __name__ == "__main__":
    main()
