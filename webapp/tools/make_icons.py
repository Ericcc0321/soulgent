#!/usr/bin/env python3
"""Generate the web app home-screen icons: frame 0 of a pet spritesheet, centered on a rounded dark tile.

Usage: python3 tools/make_icons.py [pet name] [--src pet dir]
       python3 tools/make_icons.py --logo web/brand/app-icon-ios-1024.png (brand mode: scale the 1024 square image directly, no rounded corners)
       python3 tools/make_icons.py --logo web/brand/app-icon-ios-1024.png --splash-art web/brand/mascot-idle.png
           (splash screens use the transparent mascot on a dark vertical gradient; --splash-bg defaults to #2a3a55,#10151e)
       (default pet soulflame; the pet dir defaults to app/pets next to webapp/)
Output: web/icons/icon-180.png, icon-192.png, icon-512.png, plus iOS splash screens splash-<w>x<h>.png
Python 3.9 compatible; needs Pillow (with WebP support).
"""
import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
PETS = ROOT.parent / "app" / "pets"  # app/pets next to webapp/; pass --src when running from a worktree
OUT = ROOT / "web" / "icons"
BG = (11, 12, 16, 255)  # #0b0c10
FRAME = (0, 0, 192, 208)  # row 0, frame 0 (idle)


def load_frame(src, pet):
    sheet = Image.open(src / pet / "spritesheet.webp").convert("RGBA")
    frame = sheet.crop(FRAME)
    box = frame.getbbox()
    return frame.crop(box) if box else frame


def make_icon(frame, size, rounded):
    bg = Image.new("RGBA", (size, size), BG)
    if rounded:
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, size - 1, size - 1), radius=int(size * 0.225), fill=255)
        canvas.paste(bg, (0, 0), mask)
    else:
        canvas = bg  # apple-touch-icon: iOS rounds the corners itself, so fill the whole canvas
    target = int(size * 0.68)
    scale = min(target / frame.width, target / frame.height)
    pet = frame.resize((max(1, round(frame.width * scale)),
                        max(1, round(frame.height * scale))), Image.LANCZOS)
    canvas.alpha_composite(pet, ((size - pet.width) // 2, (size - pet.height) // 2))
    return canvas


# iOS splash images (apple-touch-startup-image), portrait 3x devices; match the media queries in index.html
SPLASH = ((1125, 2436), (1170, 2532), (1179, 2556), (1206, 2622),
          (1284, 2778), (1290, 2796), (1320, 2868))


def make_splash(frame, w, h):
    canvas = Image.new("RGBA", (w, h), BG)
    side = int(w * 0.3)
    scale = min(side / frame.width, side / frame.height)
    pet = frame.resize((round(frame.width * scale), round(frame.height * scale)), Image.LANCZOS)
    canvas.alpha_composite(pet, ((w - pet.width) // 2, (h - pet.height) // 2 - h // 20))
    return canvas.convert("RGB")


def logo_flame(logo):
    """Cut the flame out of the 1024 brand image: the top-left pixel is the background, pixels far from it are flame. Returns the flame with alpha (glow fades out)."""
    rgb = logo.convert("RGB")
    bg = Image.new("RGB", rgb.size, rgb.getpixel((0, 0)))
    diff = ImageChops.difference(rgb, bg)
    d = ImageChops.lighter(ImageChops.lighter(diff.getchannel("R"), diff.getchannel("G")), diff.getchannel("B"))
    box = d.point(lambda v: 255 if v > 24 else 0).getbbox() or (0, 0) + rgb.size
    flame = rgb.convert("RGBA").crop(box)
    flame.putalpha(d.crop(box).point(lambda v: min(255, v * 255 // 40)))  # difference >= 40 is fully opaque; the glow edge fades out
    return flame


def make_logo_splash(logo, w, h):
    flame = logo_flame(logo)
    target = int(w * 0.38)  # scale the whole flame proportionally to 38% of the width
    scale = target / flame.width
    f = flame.resize((round(flame.width * scale), round(flame.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", (w, h), (17, 17, 17, 255))
    canvas.alpha_composite(f, ((w - f.width) // 2, (h - f.height) // 2))
    return canvas.convert("RGB")


def hex_rgb(v):
    v = v.strip().lstrip("#")
    return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4))


def make_art_splash(art, w, h, top, bottom):
    """Scale the transparent-background figure (cropped to its opaque bounds) to 38% of the width and place it centered, slightly above middle, on a top-to-bottom vertical gradient."""
    box = art.getchannel("A").getbbox()
    a = art.crop(box) if box else art
    scale = int(w * 0.38) / a.width
    a = a.resize((round(a.width * scale), round(a.height * scale)), Image.LANCZOS)
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        col.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    canvas = col.resize((w, h)).convert("RGBA")
    canvas.alpha_composite(a, ((w - a.width) // 2, (h - a.height) // 2 - h // 20))
    return canvas.convert("RGB")


def run_logo(path, art_path=None, splash_bg="#2a3a55,#10151e"):
    logo = Image.open(path).convert("RGBA")
    if logo.width != logo.height:
        raise SystemExit("--logo needs a square image (1024x1024 recommended)")
    OUT.mkdir(parents=True, exist_ok=True)
    for size in (180, 192, 512):
        out = OUT / ("icon-%d.png" % size)
        logo.resize((size, size), Image.LANCZOS).convert("RGB").save(out, optimize=True)
        print("wrote", out)
    art = Image.open(art_path).convert("RGBA") if art_path else None
    top, bottom = (hex_rgb(c) for c in splash_bg.split(","))
    for w, h in SPLASH:
        out = OUT / ("splash-%dx%d.png" % (w, h))
        img = make_art_splash(art, w, h, top, bottom) if art else make_logo_splash(logo, w, h)
        img.save(out, optimize=True)
        print("wrote", out)


def main():
    ap = argparse.ArgumentParser(description="Generate Soulgent icons and splash images")
    ap.add_argument("pet", nargs="?", default="soulflame", help="pet name (default soulflame)")
    ap.add_argument("--src", type=Path, default=PETS, help="pet directory (default ../app/pets)")
    ap.add_argument("--logo", type=Path, help="1024 square brand image: scaled directly into icons; splash images get the flame centered (not used in pet mode)")
    ap.add_argument("--splash-art", type=Path, help="use this transparent PNG for splash images (do not cut the flame out of --logo)")
    ap.add_argument("--splash-bg", default="#2a3a55,#10151e", help="splash vertical gradient top,bottom (with --splash-art)")
    args = ap.parse_args()
    if args.logo:
        return run_logo(args.logo, args.splash_art, args.splash_bg)
    frame = load_frame(args.src, args.pet)
    OUT.mkdir(parents=True, exist_ok=True)
    for size in (180, 192, 512):
        path = OUT / ("icon-%d.png" % size)
        make_icon(frame, size, rounded=size != 180).save(path)
        print("wrote", path)
    for w, h in SPLASH:
        path = OUT / ("splash-%dx%d.png" % (w, h))
        make_splash(frame, w, h).save(path, optimize=True)
        print("wrote", path)


if __name__ == "__main__":
    main()
