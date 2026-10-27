#!/usr/bin/env python3
"""Pre-slice pet spritesheets into small per-row strips (Python 3.9 compatible).

Besides per-row frame counts, each pet entry in the manifest may carry
  caps   -- data/pets/<name>/caps.json verbatim ({"walk": true} can walk / {"deskOwn": true} brings its own computer /
            {"unsure": true}), used by the chat list;
  figure -- only on the pet chosen as the tool figure: data/pets/<name>/figure.json (figure config, {} if missing).
Pick the tool figure with --figure <name> (--figure "" clears it); without it, the pet carrying figure in the old manifest is kept.
If no pet carries figure the phone picks one itself (the first complete pet); with no pets at all it uses the built-in flame.
"""
import argparse
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from helper import settings  # noqa: E402

SRC_FRAME_W, SRC_FRAME_H = 192, 208
OUT_FRAME_W, OUT_FRAME_H = 96, 104
COLS = 8
ROWS = (0, 1, 2, 3, 4, 6, 7)  # idle, run-right, run-left, waving, jumping, waiting, running
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC = [
    os.path.join(ROOT, "..", "app", "pets"),
    settings.petdex_dir(),  # default ~/.petdex/pets; override with SOULGENT_PETDEX_DIR
]
DEFAULT_OUT = os.path.join(ROOT, "data", "pets")
STAMP = ".src_mtime"


def _frame(sheet, row, col):
    x, y = col * SRC_FRAME_W, row * SRC_FRAME_H
    return sheet.crop((x, y, x + SRC_FRAME_W, y + SRC_FRAME_H))


def count_frames(sheet, row):
    """Frames from the left up to the first fully transparent one (at least 1)."""
    sheet = sheet.convert("RGBA")
    n = 0
    for col in range(COLS):
        if _frame(sheet, row, col).getchannel("A").getbbox() is None:
            break
        n += 1
    return max(n, 1)


def _find_sources(src_dirs):
    found = {}
    for d in src_dirs:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name in found:
                continue
            for ext in ("webp", "png"):
                sheet = os.path.join(d, name, "spritesheet." + ext)
                if os.path.isfile(sheet):
                    found[name] = sheet
                    break
    return found


def _outputs_ok(pet_out, counts):
    return all(os.path.isfile(os.path.join(pet_out, "%s.webp" % r)) for r in counts) \
        and os.path.isfile(os.path.join(pet_out, "still.webp"))


def _build_pet(sheet_path, pet_out, rows):
    sheet = Image.open(sheet_path).convert("RGBA")
    os.makedirs(pet_out, exist_ok=True)
    counts = {}
    for row in rows:
        n = count_frames(sheet, row)
        strip = Image.new("RGBA", (n * OUT_FRAME_W, OUT_FRAME_H), (0, 0, 0, 0))
        for col in range(n):
            small = _frame(sheet, row, col).resize((OUT_FRAME_W, OUT_FRAME_H), Image.LANCZOS)
            strip.paste(small, (col * OUT_FRAME_W, 0))
        strip.save(os.path.join(pet_out, "%d.webp" % row), "WEBP", quality=80, method=6)
        counts[str(row)] = n
        if row == rows[0]:
            strip.crop((0, 0, OUT_FRAME_W, OUT_FRAME_H)).save(
                os.path.join(pet_out, "still.webp"), "WEBP", quality=80, method=6)
    return counts


def _read_json(path):
    try:
        with open(path) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


def _old_figure(old):
    for name in sorted(old):
        if isinstance(old[name], dict) and "figure" in old[name]:
            return name
    return None


def _decorate(manifest, out_dir, figure):
    """Attach caps / figure to the entry (read from caps.json and figure.json in each pet directory)."""
    for name, entry in manifest.items():
        caps = _read_json(os.path.join(out_dir, name, "caps.json"))
        if caps:
            entry["caps"] = caps
        if figure and name == figure:
            entry["figure"] = _read_json(os.path.join(out_dir, name, "figure.json")) or {}


def build(src_dirs, out_dir, rows=ROWS, figure=None):
    """figure: None keeps the choice from the old manifest; "" clears it; anything else is a pet name."""
    os.makedirs(out_dir, exist_ok=True)
    manifest_path = os.path.join(out_dir, "manifest.json")
    old = {}
    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path) as f:
                old = json.load(f)
        except ValueError:
            old = {}
    if figure is None:
        figure = _old_figure(old)
    row_keys = set(str(r) for r in rows)
    manifest = {}
    for name, sheet_path in _find_sources(src_dirs).items():
        pet_out = os.path.join(out_dir, name)
        stamp_path = os.path.join(pet_out, STAMP)
        mtime = repr(os.stat(sheet_path).st_mtime)
        prev = old.get(name)
        if isinstance(prev, dict):  # compare only per-row frame counts (caps / figure are re-read every time)
            prev = {k: v for k, v in prev.items() if k in row_keys}
        if prev and set(prev) == row_keys and _outputs_ok(pet_out, prev) \
                and os.path.isfile(stamp_path) and open(stamp_path).read() == mtime:
            manifest[name] = prev
            continue
        manifest[name] = _build_pet(sheet_path, pet_out, rows)
        with open(stamp_path, "w") as f:
            f.write(mtime)
    _decorate(manifest, out_dir, figure)
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, sort_keys=True)
    return manifest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--src", action="append", help="source dir (repeatable); default app/pets then ~/.petdex/pets (SOULGENT_PETDEX_DIR)")
    ap.add_argument("--figure", default=None,
                    help='pet used as the chat tool figure (kept from the old manifest if omitted; "" = none)')
    args = ap.parse_args()
    m = build(args.src or DEFAULT_SRC, args.out, figure=args.figure)
    print("%d pets -> %s" % (len(m), args.out))


if __name__ == "__main__":
    main()
