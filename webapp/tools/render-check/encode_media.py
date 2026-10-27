"""Encode the frames written by `run.mjs --record <dir>` into gif + mp4 and finish the stills.
python3 -I encode_media.py <dir> [lang folder ...]      (default: every language folder under <dir>)
For <dir>/<lang>/frames/<name>/f0001.png...: soulchat-<name>.gif (width 400, or 1200 for desktop; palettegen stats_mode=diff + bayer dither,
fps / colours reduced until the file is <= 3 MB) and soulchat-<name>.mp4 (h264, yuv420p, source size). *.raw.png stills -> soulchat-*.png (desktop 1200 px wide, iphone as is).
Frame rates: read from the frame count / duration table below (must match REC_SCEN in run.mjs)."""
import os
import subprocess
import sys

# name: (fps, seconds, gif width, mp4 width or 0 = source size)
SPEC = {"knock": (15, 6, 400, 0), "reply": (15, 8, 400, 0), "tools": (15, 8, 400, 0), "desktop": (12, 8, 1200, 0),
        "knock-close": (15, 3, 600, 600), "tools-close": (15, 4.1, 600, 600)}
# Short clips as animated WebP (lossy, loop) + poster jpg: name: (fps, poster position 0..1 = the clearest action frame). 800x450, the frames are fitted inside and padded with the page background #111111
WEBP = {"knock-close": (15, 0.2), "tools-close": (15, 0.45), "zone-fx": (15, 0.5), "agents-flip": (15, 0.55)}
WEBP_W, WEBP_H, WEBP_BG, WEBP_MAX, POSTER_MAX = 800, 450, "0x111111", 1024 * 1024, 150 * 1024
# env ENCODE_ONLY=knock-close,tools-close: only (re)encode these frame folders, leave the other media untouched
ONLY = [x for x in os.environ.get("ENCODE_ONLY", "").split(",") if x]
MAX = 3 * 1024 * 1024


def ff(*a):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *a], check=True)


def gif(frames, out, src_fps, width, tmp):
    for fps, colors in ((src_fps, 128), (src_fps, 64), (12, 64), (10, 48), (8, 32)):
        pal = os.path.join(tmp, "pal.png")
        vf = "fps=%d,scale=%d:-1:flags=lanczos" % (fps, width)
        ff("-framerate", str(src_fps), "-i", frames + "/f%04d.png", "-vf", vf + ",palettegen=stats_mode=diff:max_colors=%d" % colors, pal)
        ff("-framerate", str(src_fps), "-i", frames + "/f%04d.png", "-i", pal, "-lavfi",
           vf + "[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle", "-loop", "0", out)
        size = os.path.getsize(out)
        print("  %s fps=%d colors=%d -> %.2f MB" % (os.path.basename(out), fps, colors, size / 1048576))
        if size <= MAX:
            return fps
    return fps


def webp_clip(frames, out, fps, pos, tmp):
    """frames/f%04d.png -> out (animated WebP, q 80, lowered until <= 1 MB) + same-name .poster.jpg (<= 150 KB)."""
    import glob
    import shutil
    wd = os.path.join(tmp, "webp-tmp")
    shutil.rmtree(wd, ignore_errors=True)
    os.makedirs(wd)
    vf = "scale=%d:%d:force_original_aspect_ratio=decrease:flags=lanczos,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=%s" % (WEBP_W, WEBP_H, WEBP_W, WEBP_H, WEBP_BG)
    ff("-framerate", str(fps), "-i", frames + "/f%04d.png", "-vf", vf, os.path.join(wd, "p%04d.png"))
    fl = sorted(glob.glob(os.path.join(wd, "p*.png")))
    for q in (80, 70, 60, 50):
        subprocess.run(["img2webp", "-loop", "0", "-lossy", "-q", str(q), "-d", str(round(1000 / fps)), *fl, "-o", out], check=True, capture_output=True)
        size = os.path.getsize(out)
        print("  %s q=%d %d frames -> %d KB" % (os.path.basename(out), q, len(fl), size // 1024))
        if size <= WEBP_MAX:
            break
    poster = out[:-5] + ".poster.jpg"
    src = fl[min(len(fl) - 1, int(len(fl) * pos))]
    for jq in (3, 5, 8, 12):
        ff("-i", src, "-q:v", str(jq), "-update", "1", poster)
        if os.path.getsize(poster) <= POSTER_MAX:
            break
    shutil.rmtree(wd, ignore_errors=True)


def main():
    root = os.path.abspath(sys.argv[1])
    langs = sys.argv[2:] or [d for d in sorted(os.listdir(root)) if os.path.isdir(os.path.join(root, d))]
    for lang in langs:
        base = os.path.join(root, lang)
        fr = os.path.join(base, "frames")
        for name in sorted(os.listdir(fr)) if os.path.isdir(fr) else []:
            if ONLY and name not in ONLY:
                continue
            src = os.path.join(fr, name)
            if name in WEBP:
                print(lang, name)
                webp_clip(src, os.path.join(base, "soulchat-%s.webp" % name), WEBP[name][0], WEBP[name][1], base)
                continue
            fps, dur, width, mw = SPEC[name]
            print(lang, name)
            gif(src, os.path.join(base, "soulchat-%s.gif" % name), fps, width, base)
            ff("-framerate", str(fps), "-i", src + "/f%04d.png", "-vf", ("scale=%d:-2:flags=lanczos" % mw) if mw else "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
               "-crf", "18", "-movflags", "+faststart", os.path.join(base, "soulchat-%s.mp4" % name))
        pal = os.path.join(base, "pal.png")
        if os.path.exists(pal):
            os.remove(pal)
        for f in sorted(os.listdir(base)):
            if f.endswith(".raw.png"):
                dst = os.path.join(base, f.replace(".raw.png", ".png"))
                if "desktop" in f:
                    ff("-i", os.path.join(base, f), "-vf", "scale=1200:-1:flags=lanczos", dst)
                else:
                    os.replace(os.path.join(base, f), dst)
                    continue
                os.remove(os.path.join(base, f))


main()
