"""Local server for render-check: serves the --web directory statically and hands /api/* to the repo's api/server.py (fed with the fake data produced by gen.py),
attaching the login cookie automatically (--account admin|guest|guest2; the second guest, guest2, is bound to Web-receipts with prefix [GB]). Binds 127.0.0.1 only and never writes into the repo (no __pycache__).
python3 -I serve.py --data <gen output dir> --web <web dir> --port N [--account guest|guest2] [--pets <pets dir>]
--pets (or env RC_PETS_DIR): output directory of build_pets.py (<id>/<row>.webp + still.webp), served through the product's /pets/ API (manifest and images);
only ids in the DEMO_PETS list are served (others 404 and stay out of the manifest even if present on disk); soulflame comes from web/figures/soulflame/. Without it every /pets/ request returns 404 (avatars use the built-in soulflame)."""
import os
import sys
import time

sys.dont_write_bytecode = True
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO)


def arg(name, default=""):
    a = sys.argv[1:]
    return a[a.index(name) + 1] if name in a else default


DATA = os.path.abspath(arg("--data"))
WEB = os.path.realpath(arg("--web", os.path.join(REPO, "web")))
PORT = int(arg("--port", "18990"))
ACCOUNT = arg("--account", "admin")
PETS = os.path.realpath(arg("--pets", os.environ.get("RC_PETS_DIR", ""))) if (arg("--pets") or os.environ.get("RC_PETS_DIR")) else ""
# demo pet list (only these ids are served)
DEMO_PETS = ("soulflame", "little-deer", "blue-boba-axolotl", "milk-tea-koala", "whaley", "byte-bunny", "boxcat",
             "prompt-penguin", "scarf-hamster", "octopus", "penguin-chick", "terminal-ghost-2", "red-panda",
             "acorn-squirrel", "wave-whale", "cloudlet", "cream-cat", "lint-sprout", "sea-lion", "cloudy")
# demo pets that can really walk (row 7 is a side-view running cycle): their manifest entry reports caps {"walk": true} (reproducible, nothing is written into the pets dir)
DEMO_CAPS = {"cream-cat": {"walk": True}}
os.environ["HOST_HOME"] = "/Users/demo"
os.environ.setdefault("GUEST_NAME", "Guest")
os.environ.setdefault("OUTBOX_SECRET", "render-check-outbox-secret-0123456789")  # test harness: requests must be signed to be written

from api import server as S  # noqa: E402
from api import files as F  # noqa: E402
from api import guestcfg as G  # noqa: E402

KEY = "render-check-admin-key-0123456789"
GKEY = "render-check-guest-key-0123456789"
ZKEY = "render-check-guest2-key-0123456789ab"
GUESTS = [G.Guest("guest", GKEY, "Web-render-demo", G.DEFAULT_TAG, "Guest"),
          G.Guest("guest2", ZKEY, "Web-receipts", "[GB]", "GB Demo")]

_orig = S.App.load_snapshot


def _fresh(self):  # the snapshot is always "just generated" so the "data is stale" notice never appears
    snap = _orig(self)
    if isinstance(snap, dict):
        snap = dict(snap)
        snap["generatedAt"] = time.time()
    return snap


S.App.load_snapshot = _fresh

TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".json": "application/json", ".webmanifest": "application/manifest+json",
         ".png": "image/png", ".webp": "image/webp", ".svg": "image/svg+xml", ".jpg": "image/jpeg"}


def _webp_frames(path):  # row strip: 96 px per frame; read only the WebP header for the width (serve runs on the system python, no PIL)
    with open(path, "rb") as f:
        h = f.read(32)
    kind = h[12:16]
    if kind == b"VP8X":
        w = int.from_bytes(h[24:27], "little") + 1
    elif kind == b"VP8L":
        w = (int.from_bytes(h[21:25], "little") & 0x3FFF) + 1
    else:  # VP8
        w = int.from_bytes(h[26:28], "little") & 0x3FFF
    return max(1, w // 96)


class H(S.Handler):
    def _static(self):
        from urllib.parse import urlsplit
        p = urlsplit(self.path).path
        if p.startswith("/pets/"):  # no --pets: manifest 404s, so the frontend uses the built-in soulflame
            return self._pets(p[len("/pets/"):]) if PETS else self._raw(404, b"", "text/plain")
        if p in ("", "/"):
            p = "/index.html"
        full = os.path.realpath(os.path.join(WEB, p.lstrip("/")))
        if not full.startswith(WEB + os.sep) or not os.path.isfile(full):
            return self._raw(404, b"", "text/plain")
        with open(full, "rb") as f:
            body = f.read()
        self._raw(200, body, TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))

    def _pet_dir(self, name):
        if name == "soulflame":
            return os.path.join(WEB, "figures", "soulflame")
        return os.path.join(PETS, name) if name in DEMO_PETS else ""

    def _pets(self, rel):
        import json
        if rel == "manifest.json":  # list only ids that are in the list and really on disk; soulflame carries figure.json for the tool figure
            m = {}
            try:
                with open(os.path.join(PETS, "manifest.json")) as f:
                    src = json.load(f)
            except (OSError, ValueError):
                src = {}
            for name in DEMO_PETS:
                if name == "soulflame":
                    d = self._pet_dir(name)
                    ent = {}
                    for r in "0123467":
                        fp = os.path.join(d, r + ".webp")
                        if os.path.isfile(fp):
                            ent[r] = _webp_frames(fp)
                    try:
                        with open(os.path.join(d, "figure.json")) as f:
                            ent["figure"] = json.load(f)
                    except (OSError, ValueError):
                        pass
                    m[name] = ent
                elif isinstance(src.get(name), dict) and os.path.isdir(self._pet_dir(name)):
                    m[name] = {k: v for k, v in src[name].items() if k != "figure"}
                    if name in DEMO_CAPS:
                        m[name]["caps"] = DEMO_CAPS[name]
            return self._raw(200, json.dumps(m).encode(), "application/json")
        parts = rel.split("/")
        d = self._pet_dir(parts[0]) if len(parts) == 2 else ""
        fp = os.path.join(d, parts[1]) if d and parts[1].endswith(".webp") and "/" not in parts[1] else ""
        if not fp or not os.path.isfile(fp):
            return self._raw(404, b"", "text/plain")
        with open(fp, "rb") as f:
            return self._raw(200, f.read(), "image/webp")

    def _raw(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _with_cookie(self):
        tok = self.server.app.tokens[ACCOUNT if ACCOUNT in self.server.app.tokens else "admin"]
        del self.headers["Cookie"]
        self.headers["Cookie"] = "%s=%s" % (S.COOKIE_NAME, tok)

    def do_GET(self):
        if self.path.startswith("/api/"):
            self._with_cookie()
            return S.Handler.do_GET(self)
        return self._static()

    def do_POST(self):
        if self.path.startswith("/api/"):
            self._with_cookie()
            return S.Handler.do_POST(self)
        self._raw(404, b"", "text/plain")

    def log_message(self, *a):
        pass


# Chrome opens several concurrent connections for thumbnails; http.server's default listen backlog is 5 and macOS RSTs when it fills (false harness failures)
S.ThreadingHTTPServer.request_queue_size = 128
httpd = S.make_server("127.0.0.1", PORT, KEY, os.path.join(DATA, "data", "snapshot.json"),
                      os.path.join(DATA, "projects"), os.path.join(DATA, "state", "state.json"),
                      os.path.join(DATA, "outbox"), os.path.join(DATA, "uploads"),
                      guests=GUESTS,
                      guest_slash=("/window",),  # GUEST_SLASH_COMMANDS for the guest2-slash scenario (/window allowed, /model blocked)
                      file_roots=F.Roots.from_spec("/Users/demo/projects=" + os.path.join(DATA, "files") +
                                                    ":/Users/demo/app/data/uploads=" + os.path.join(DATA, "uploads")))
httpd.RequestHandlerClass = H
print("serving http://127.0.0.1:%d/ web=%s account=%s" % (PORT, WEB, ACCOUNT), flush=True)
httpd.serve_forever()
