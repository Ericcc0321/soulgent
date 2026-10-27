"""Bubble attachments: thumbnails (WebP, longest side 640) and extraction of images embedded in transcripts.

Memory guards (api container capped at 96MB):
- Pillow is imported lazily, so the service doesn't pay for it at startup;
- 40-megapixel limit, checked from width / height ourselves (Pillow's own limit only errors at 2x);
- JPEG uses draft downscaling; one image at a time (a global lock, shared with embedded-image decoding);
- source files above THUMB_SKIP are skipped and left for the phone to scale.
All failures return None so the caller falls back to the original image; nothing raises.
"""
import base64
import binascii
import io
import json
import os
import threading
import uuid
import warnings
from typing import Any, Optional, Tuple

try:
    from api import files
except ImportError:  # in the container, api/ contents sit directly in the working directory
    import files  # type: ignore

MAX_PIXELS = 40000000  # pixel limit for JPEG (draft mode downsamples first, so decode memory stays small)
MAX_PIXELS_OTHER = 10000000  # other formats are fully decoded (a 6300x6300 PNG peaked at 190MB), so the limit is lowered to 10 million
THUMB_EDGE = 640
THUMB_QUALITY = 80
JPEG_DRAFT = (1280, 1280)
CACHE_LIMIT = 300 * 2**20
PRUNE_EVERY = 50  # prune the cache after this many thumbnails written
LINE_MAX = 16 * 2**20  # max length of a line holding an embedded image (json.loads peaks at about 2-3x; the container has only 96MB)
_USER_TAGS = (b'"type":"user"', b'"type": "user"')
_IMAGE_TAGS = (b'"type":"image"', b'"type": "image"')
EMBED_MIME = ("image/png", "image/jpeg", "image/gif", "image/webp")  # only these types; media_type in transcripts is external data

_lock = threading.Lock()  # generate only one thumbnail / decode only one embedded-image line at a time
_writes = [0]
_pil = [None]  # type: list


def _image():  # type: () -> Any
    """Lazily load PIL.Image; returns None if unavailable (callers fall back to the original image)."""
    if _pil[0] is None:
        try:
            from PIL import Image  # type: ignore
            Image.MAX_IMAGE_PIXELS = MAX_PIXELS
            _pil[0] = Image
        except Exception:
            _pil[0] = False
    return _pil[0] or None


def make(src, cache_dir, key, data=None):  # type: (Any, str, str, Optional[bytes]) -> Optional[str]
    """Generate (or hit) a thumbnail and return the cached webp path. src may be a path or an open binary file object;
    if data is given, generate from those in-memory bytes (embedded image). Returns None if the source exceeds THUMB_SKIP or the pixel limit, or Pillow cannot decode it."""
    out = os.path.join(cache_dir, key + ".webp")
    if _touch(out):
        return out
    try:
        if data is not None:
            size = len(data)
        elif hasattr(src, "fileno"):
            size = os.fstat(src.fileno()).st_size
        else:
            size = os.path.getsize(src)
        if size > files.THUMB_SKIP:
            return None
    except OSError:
        return None
    Image = _image()
    if Image is None:
        return None
    tmp = None
    with _lock:
        if _touch(out):  # another request generated it while we waited for the lock
            return out
        try:
            with warnings.catch_warnings():  # we check the pixel limit ourselves; keep Pillow's warning out of the log
                warnings.simplefilter("ignore", Image.DecompressionBombWarning)
                im = Image.open(io.BytesIO(data) if data is not None else src)  # reads only the header, no decoding yet
            try:
                w, h = im.size
                jpeg = im.format == "JPEG"
                if w <= 0 or h <= 0 or w * h > (MAX_PIXELS if jpeg else MAX_PIXELS_OTHER):
                    return None  # no decode, no cache; the caller serves the original
                if jpeg:
                    im.draft("RGB", JPEG_DRAFT)
                im.thumbnail((THUMB_EDGE, THUMB_EDGE))  # gif: first frame only
                if im.mode not in ("RGB", "RGBA"):
                    im = im.convert("RGBA" if (im.mode in ("P", "LA", "PA") or "transparency" in im.info) else "RGB")
                os.makedirs(cache_dir, exist_ok=True)
                tmp = os.path.join(cache_dir, ".tmp-" + uuid.uuid4().hex)
                im.save(tmp, "WEBP", quality=THUMB_QUALITY)
            finally:
                im.close()
            os.replace(tmp, out)
            tmp = None
        except Exception:  # decode failure, over pixel limit, write failure: all fall back to the original
            return None
        finally:
            if tmp:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
        _writes[0] += 1
        due = _writes[0] % PRUNE_EVERY == 0
    if due:
        prune(cache_dir)
    return out


def _touch(path):  # type: (str) -> bool
    """On a cache hit, update mtime (used as LRU) and return whether it exists."""
    try:
        os.utime(path, None)
        return os.path.isfile(path)
    except OSError:
        return False


def prune(cache_dir, limit_bytes=CACHE_LIMIT):  # type: (str, int) -> None
    """When the cache exceeds its limit, delete oldest-mtime first until it is under the limit."""
    try:
        ents = []
        total = 0
        for name in os.listdir(cache_dir):
            if not name.endswith(".webp"):
                continue
            p = os.path.join(cache_dir, name)
            try:
                st = os.stat(p)
            except OSError:
                continue
            ents.append((st.st_mtime, st.st_size, p))
            total += st.st_size
        ents.sort()
        for _, size, p in ents:
            if total <= limit_bytes:
                break
            try:
                os.remove(p)
                total -= size
            except OSError:
                pass
    except OSError:
        pass


def embedded(jsonl_path, seq, index, fp):  # type: (str, int, int, str) -> Optional[Tuple[str, bytes]]
    """The index-th embedded image (1-based, counting only image blocks) in the line starting at byte seq (must be a line start) -> (mime, raw bytes).
    Returns None if the line fingerprint (files.line_fp) does not match, the line exceeds LINE_MAX, it is not a user line with images, seq is not a line start, the index is out of range, the mime is not whitelisted,
    or the decoded size exceeds IMG_MAX. Reads only the first 256 bytes to check the fingerprint, and the whole line only on a match; nothing is kept afterwards."""
    if not isinstance(seq, int) or not isinstance(index, int) or seq < 0 or index < 1 or not isinstance(fp, str):
        return None
    with _lock:
        try:
            with open(jsonl_path, "rb") as f:
                size = os.fstat(f.fileno()).st_size
                if seq >= size:
                    return None
                if seq > 0:
                    f.seek(seq - 1)
                    if f.read(1) != b"\n":
                        return None
                f.seek(seq)
                head = f.read(files.FP_HEAD).split(b"\n", 1)[0]
                if files.line_fp(head) != fp:
                    return None
                f.seek(seq)
                line = f.readline(LINE_MAX + 1)
            if len(line) > LINE_MAX:
                return None
            # coarse filter: must be a user line with image blocks (big tool_result lines etc. are not parsed)
            if not any(t in line for t in _USER_TAGS) or not any(t in line for t in _IMAGE_TAGS):
                return None
            obj = json.loads(line.decode("utf-8"))
            del line
            msg = obj.get("message") if isinstance(obj, dict) else None
            content = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(content, list):
                return None
            imgs = [b for b in content if isinstance(b, dict) and b.get("type") == "image"]
            del obj, msg, content
            if index > len(imgs):
                return None
            src = imgs[index - 1].get("source")
            del imgs
            if not isinstance(src, dict) or src.get("type", "base64") != "base64":
                return None
            mime = str(src.get("media_type") or "image/png").lower()
            b64 = src.get("data")
            if mime not in EMBED_MIME or not isinstance(b64, str) or len(b64) // 4 * 3 > files.IMG_MAX + 3:
                return None
            raw = base64.b64decode(b64)
            return (mime, raw) if len(raw) <= files.IMG_MAX else None
        except (OSError, ValueError, UnicodeError, binascii.Error):
            return None
