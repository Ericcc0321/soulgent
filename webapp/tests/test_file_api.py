"""Message-attachment file endpoint /api/file: allowlist, thumbnails, Range, text truncation, inline images, guest rules, rate limiting, security headers."""
import base64
import hashlib
import hmac
import http.client
import io
import json
import os
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.parse import quote

from PIL import Image

from api import files, server, transcript
from tests._guests import guests_for  # noqa: E402

KEY = "admin-key-0123456789abcdef"
GUEST = "guest-key-0123456789abcdef"
ADMIN_COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GUEST_COOKIE = "zbs=" + hmac.new(GUEST.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
BOUND = "Web-guest-demo"
UP_HOST = "/Users/zbs-test/webapp/data/uploads"  # fake host uploads path used by the tests
CP_HOST = "/Users/zbs-test/projects"
PREV = "0aaaaaaa-1111-4111-8111-111111111111"  # previous window of the session bound to c1 (the transcript from before the window switch)


def _png(w, h, color=(200, 30, 30)):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, "PNG")
    return buf.getvalue()


class FileApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.host_root = os.path.join(t, "host", "tmp")  # fake host /private/tmp root
        self.host_tmp = os.path.join(self.host_root, "g")  # default project dir /private/tmp/g (cwd cannot be the root itself)
        self.secret = os.path.join(t, "host", "secret")
        self.uploads = os.path.join(t, "uploads")
        for d in (self.host_tmp, self.secret, self.uploads):
            os.makedirs(d)
        self.png = _png(100, 80)
        self._write(os.path.join(self.host_tmp, "x.png"), self.png)
        big = os.path.join(self.host_tmp, "big.png")
        self._write(big, self.png)
        os.truncate(big, 13 * 2**20)  # larger than THUMB_SKIP
        self._write(os.path.join(self.host_tmp, "n.txt"), b"a" * (3 * 2**20))
        self._write(os.path.join(self.host_tmp, "x.py"), b"print(1)")
        self._write(os.path.join(self.host_tmp, "page.html"), b"<script>alert(1)</script>")
        self._write(os.path.join(self.host_tmp, "pic.svg"), b"<svg xmlns='http://www.w3.org/2000/svg'/>")
        self._write(os.path.join(self.host_tmp, "r.pdf"), bytes(range(256)) * 4)
        self._write(os.path.join(self.host_tmp, "demo报表 2026.xlsx"), b"PK\x03\x04sheet")
        self._write(os.path.join(self.secret, ".env"), b"KEY=x")
        self._write(os.path.join(self.secret, "real.png"), self.png)
        os.symlink(os.path.join(self.secret, "real.png"), os.path.join(self.host_tmp, "link.png"))
        self._write(os.path.join(self.uploads, "a.pdf"), b"%PDF-1.4 upload")

        # transcripts: c1 (guest-bound) has an inline image, an assistant path attachment and an uploaded file; c2 is not bound
        projects = os.path.join(t, "projects")
        os.makedirs(os.path.join(projects, "p"))
        self.emb = _png(30, 20, (0, 90, 200))
        lines = [
            {"type": "user", "timestamp": "2026-10-23T01:00:00Z",
             "message": {"role": "user", "content": [
                 {"type": "text", "text": "看图"},
                 {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                              "data": base64.b64encode(self.emb).decode()}}]}},
            {"type": "assistant", "timestamp": "2026-10-23T01:00:01Z",
             "message": {"role": "assistant", "content": [
                 {"type": "text", "text": "图在 /private/tmp/g/x.png ，另一张 /private/tmp/g/missing.png 不存在"}]}},
            {"type": "user", "timestamp": "2026-10-23T01:00:02Z",
             "message": {"role": "user", "content": "请看我从手机发来的文件：%s/a.pdf" % UP_HOST}},
        ]
        self.c1 = os.path.join(projects, "p", "c1.jsonl")
        self.img_seq = 0
        with open(self.c1, "wb") as f:
            for ln in lines:
                f.write(json.dumps(ln, ensure_ascii=False).encode("utf-8") + b"\n")
        with open(os.path.join(projects, "p", "c2.jsonl"), "wb") as f:
            f.write(json.dumps(lines[0]).encode() + b"\n")

        self.snap = os.path.join(t, "snapshot.json")
        now = time.time()
        c1_cwd = getattr(self, "C1_CWD", "/private/tmp/g")  # project dir of the bound session c1 (host path); None = snapshot has no cwd
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": now, "usage": {}, "zones": [], "sessions": [
                {"id": "c1", "kind": "claude", "name": BOUND, "zone": "Web", "plate": "guest-demo",
                 "status": "idle", "since": now, "transcript": "p/c1.jsonl",
                 **({"cwd": c1_cwd} if c1_cwd else {})},
                {"id": "c2", "kind": "claude", "name": "Web-ui-demo", "zone": "Web", "plate": "UI-refactor",
                 "status": "idle", "since": now, "transcript": "p/c2.jsonl"},
            ]}, f)
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.cp = os.path.join(t, "host", "cp")  # fake host ~/projects (guest reply files are limited to the session cwd)
        os.makedirs(self.cp)
        self.roots = files.Roots([("/private/tmp", self.host_root), (UP_HOST, self.uploads), (CP_HOST, self.cp)],
                                 home="/Users/zbs-test")
        self.state_dir = os.path.join(t, "st")
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap, projects=projects,
                                        state=os.path.join(self.state_dir, "state.json"),
                                        outbox_dir=os.path.join(t, "ob"), uploads_dir=self.uploads,
                                        guests=guests_for(KEY, GUEST, BOUND), file_roots=self.roots)
        self.port = self.httpd.server_address[1]
        # upload log: a.pdf was uploaded by the guest and sent into the bound session c1 (a guest needs a log entry to fetch an upload)
        self.httpd.app.uploadlog.add("a.pdf", "guest", "c1")
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    @staticmethod
    def _write(path, data):
        with open(path, "wb") as f:
            f.write(data)

    def req(self, path, cookie=ADMIN_COOKIE, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Cookie": cookie} if cookie else {}
        h.update(headers or {})
        c.request("GET", path, headers=h)
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, {k.lower(): v for k, v in r.getheaders()}, body

    def ref(self, seq, i=1, path=None):
        """The ref of the line at seq (with line fingerprint)."""
        with open(path or self.c1, "rb") as fh:
            fh.seek(seq)
            head = fh.read(256).split(b"\n", 1)[0]
        return "%d:%d:%s" % (seq, i, files.line_fp(head))

    def f(self, p, t="full", **kw):
        return self.req("/api/file?p=%s&t=%s" % (quote(p, safe=""), t), **kw)

    def thumbs(self):
        d = os.path.join(self.state_dir, "thumbs")
        return sorted(x for x in os.listdir(d) if x.endswith(".webp")) if os.path.isdir(d) else []

    # ---- tests ----
    def test_full_png(self):
        st, h, body = self.f("/private/tmp/g/x.png")
        self.assertEqual(st, 200)
        self.assertEqual(h["content-type"], "image/png")
        self.assertEqual(body, self.png)
        s = os.stat(os.path.join(self.host_tmp, "x.png"))
        self.assertEqual(h["etag"], '"%d-%d"' % (s.st_size, s.st_mtime_ns))
        self.assertTrue(h["content-disposition"].startswith("inline; filename*=UTF-8''x.png"))
        self.assertEqual(h["cache-control"], "private, no-cache")  # revalidate permissions on every use (ETag hit returns 304)
        self.assertEqual(h["x-content-type-options"], "nosniff")
        st, h, body = self.f("/private/tmp/g/x.png", headers={"If-None-Match": h["etag"]})
        self.assertEqual(st, 304)
        self.assertEqual(body, b"")
        self.assertEqual(h["x-content-type-options"], "nosniff")
        st, _, body = self.f("/tmp/g/x.png")  # /tmp and /private/tmp are equivalent
        self.assertEqual((st, body), (200, self.png))
        self.assertEqual(self.f("/private/tmp/g/x.png", cookie=None)[0], 401)

    def test_thumb_png_is_webp_and_cached(self):
        st, h, body = self.f("/private/tmp/g/x.png", t="thumb")
        self.assertEqual(st, 200)
        self.assertEqual(h["content-type"], "image/webp")
        self.assertEqual(body[:4], b"RIFF")
        self.assertEqual(Image.open(io.BytesIO(body)).size, (100, 80))  # no upscaling
        names = self.thumbs()
        self.assertEqual(len(names), 1)
        self._write(os.path.join(self.state_dir, "thumbs", names[0]), b"CACHED")  # the second request must be served from cache
        st, h, body = self.f("/private/tmp/g/x.png", t="thumb")
        self.assertEqual((st, h["content-type"], body), (200, "image/webp", b"CACHED"))

    def test_thumb_skips_big_file(self):
        st, h, body = self.f("/private/tmp/g/big.png", t="thumb")
        self.assertEqual(st, 200)
        self.assertEqual(h["content-type"], "image/png")
        self.assertEqual(len(body), 13 * 2**20)
        self.assertEqual(self.thumbs(), [])

    def test_thumb_large_png_not_decoded(self):
        p = os.path.join(self.host_tmp, "wide.png")
        Image.new("1", (6300, 6300)).save(p, "PNG")  # 39.69 megapixels, tiny file; decoding it whole would eat ~200MB
        self.assertLess(os.path.getsize(p), 2**20)
        st, h, body = self.f("/private/tmp/g/wide.png", t="thumb")
        self.assertEqual((st, h["content-type"]), (200, "image/png"))
        self.assertEqual(len(body), os.path.getsize(p))
        self.assertEqual(self.thumbs(), [])

    def test_stream_inode_mismatch_404(self):
        # simulate the file being swapped after stat: inode at open differs from resolve time -> 404
        real = os.path.realpath(os.path.join(self.host_tmp, "r.pdf"))
        orig = os.fstat

        class Fake:
            def __init__(self, s):
                self._s = s

            def __getattr__(self, k):
                return self._s.st_ino + 1 if k == "st_ino" else getattr(self._s, k)

        def fake(fd):
            s = orig(fd)
            return Fake(s) if s.st_size == os.stat(real).st_size and s.st_ino == os.stat(real).st_ino else s
        with mock.patch.object(server.os, "fstat", side_effect=fake):
            self.assertEqual(self.f("/private/tmp/g/r.pdf")[0], 404)
        self.assertEqual(self.f("/private/tmp/g/r.pdf")[0], 200)

    def test_thumb_bad_image_falls_back(self):
        self._write(os.path.join(self.host_tmp, "bad.png"), b"not a png at all")
        st, h, body = self.f("/private/tmp/g/bad.png", t="thumb")
        self.assertEqual((st, h["content-type"], body), (200, "image/png", b"not a png at all"))
        self.assertEqual(self.thumbs(), [])

    def test_range(self):
        data = bytes(range(256)) * 4
        st, h, body = self.f("/private/tmp/g/r.pdf", headers={"Range": "bytes=0-9"})
        self.assertEqual(st, 206)
        self.assertEqual(h["content-range"], "bytes 0-9/%d" % len(data))
        self.assertEqual(body, data[:10])
        st, h, body = self.f("/private/tmp/g/r.pdf", headers={"Range": "bytes=-4"})
        self.assertEqual((st, body), (206, data[-4:]))
        st, h, body = self.f("/private/tmp/g/r.pdf", headers={"Range": "bytes=1000-"})
        self.assertEqual((st, body), (206, data[1000:]))
        for bad in ("bytes=5-2", "bytes=0-1,4-5", "items=0-1", "bytes=99999-"):  # invalid ranges are ignored; serve the full body
            st, h, body = self.f("/private/tmp/g/r.pdf", headers={"Range": bad})
            self.assertEqual((st, body), (200, data), bad)
        self.assertEqual(h["accept-ranges"], "bytes")

    def test_text_truncated(self):
        st, h, body = self.f("/private/tmp/g/n.txt")
        self.assertEqual(st, 200)
        self.assertEqual(len(body), 2 * 2**20)
        self.assertEqual(h["x-truncated"], "1")
        self.assertTrue(h["content-type"].startswith("text/plain"))
        self._write(os.path.join(self.host_tmp, "s.txt"), b"short")
        st, h, body = self.f("/private/tmp/g/s.txt")
        self.assertEqual((st, body), (200, b"short"))
        self.assertNotIn("x-truncated", h)

    def test_escape_404(self):
        for p in ("/private/tmp/g/../secret/.env", "/etc/passwd", "/private/tmp/g/x.py",
                  "/private/tmp/g/link.png", "/private/tmp/g/nope.png", "~root/x.png", "relative/x.png"):
            st, h, _ = self.f(p)
            self.assertEqual(st, 404, p)
            self.assertEqual(h["x-content-type-options"], "nosniff")
        self.assertEqual(self.req("/api/file?p=/private/tmp/g/x.png&t=huge")[0], 400)
        self.assertEqual(self.req("/api/file")[0], 400)
        self.assertEqual(self.req("/api/file?sid=c1&ref=abc")[0], 400)
        self.assertEqual(self.req("/api/file?p=/private/tmp/g/x.png&tok=x")[0], 400)

    def test_security_headers(self):
        st, h, _ = self.f("/private/tmp/g/page.html")
        self.assertEqual(st, 200)
        self.assertEqual(h["content-security-policy"], "sandbox allow-scripts")
        self.assertEqual(h["x-content-type-options"], "nosniff")
        st, h, _ = self.f("/private/tmp/g/pic.svg")
        self.assertEqual(st, 200)
        self.assertEqual(h["content-type"], "image/svg+xml")
        self.assertEqual(h["content-security-policy"], "sandbox")
        st, h, _ = self.f("/private/tmp/g/pic.svg", t="thumb")  # no thumbnail for svg; still sandboxed
        self.assertEqual((st, h["content-security-policy"]), (200, "sandbox"))
        st, h, _ = self.f("/private/tmp/g/x.png")
        self.assertNotIn("content-security-policy", h)

    def test_embedded_ref(self):
        st, h, body = self.req("/api/file?sid=c1&ref=" + self.ref(self.img_seq))
        self.assertEqual(st, 200)
        self.assertEqual(h["content-type"], "image/png")
        self.assertEqual(body, self.emb)
        self.assertEqual(h["x-content-type-options"], "nosniff")
        st, h, body = self.req("/api/file?sid=c1&t=thumb&ref=" + self.ref(self.img_seq))
        self.assertEqual((st, h["content-type"]), (200, "image/webp"))
        self.assertEqual(self.req("/api/file?sid=c1&ref=" + self.ref(self.img_seq, 2))[0], 404)  # out of range
        self.assertEqual(self.req("/api/file?sid=c1&ref=" + self.ref(5))[0], 404)  # not at a line start
        self.assertEqual(self.req("/api/file?sid=c1&ref=99999999:1:00000000")[0], 404)
        self.assertEqual(self.req("/api/file?sid=nope&ref=" + self.ref(0))[0], 404)
        self.assertEqual(self.req("/api/file?sid=c1&ref=0:1:deadbeef")[0], 404)  # fingerprint mismatch
        self.assertEqual(self.req("/api/file?sid=c1&ref=0:1")[0], 400)  # old two-part format

    def test_embedded_fp_blocks_other_file(self):
        # line 0 of c2 and line 0 of c1 share an offset; fetching c1 with c2's ref (fingerprint) -> 404
        other = os.path.join(os.path.dirname(self.c1), "c2.jsonl")
        line = {"type": "user", "message": {"role": "user", "content": [
            {"type": "text", "text": "别的记录，不一样的开头"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                         "data": base64.b64encode(self.png).decode()}}]}}
        with open(other, "wb") as fh:
            fh.write(json.dumps(line, ensure_ascii=False).encode() + b"\n")
        r2 = self.ref(0, path=other)
        self.assertNotEqual(r2, self.ref(0))
        self.assertEqual(self.req("/api/file?sid=c1&ref=" + r2)[0], 404)
        st, _, body = self.req("/api/file?sid=c2&ref=" + r2)
        self.assertEqual((st, body), (200, self.png))

    def _append(self, obj_bytes):
        seq = os.path.getsize(self.c1)
        with open(self.c1, "ab") as fh:
            fh.write(obj_bytes + b"\n")
        return seq

    def test_embedded_rejects_tool_result_and_long_line(self):
        tr = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "x" * 200000}]}}
        seq = self._append(json.dumps(tr).encode())
        self.assertEqual(self.req("/api/file?sid=c1&ref=" + self.ref(seq))[0], 404)
        big = {"type": "user", "message": {"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                         "data": "A" * (17 * 2**20)}}]}}
        seq = self._append(json.dumps(big).encode())
        self.assertEqual(self.req("/api/file?sid=c1&ref=" + self.ref(seq))[0], 404)

    def test_embedded_bad_mime_404(self):
        line = {"type": "user", "message": {"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "text/html",
                                         "data": base64.b64encode(b"<script>1</script>").decode()}}]}}
        seq = self._append(json.dumps(line).encode())
        self.assertEqual(self.req("/api/file?sid=c1&ref=" + self.ref(seq))[0], 404)

    def test_download_disposition(self):
        """dl=1 returns attachment; non-ASCII names use filename*=UTF-8'' percent-encoding plus an ASCII fallback; without dl it stays inline."""
        p = "/private/tmp/g/" + "demo报表 2026.xlsx"
        st, h, body = self.req("/api/file?p=%s&t=full&dl=1" % quote(p, safe=""))
        self.assertEqual((st, body), (200, b"PK\x03\x04sheet"))
        cd = h["content-disposition"]
        self.assertTrue(cd.startswith("attachment;"), cd)
        self.assertIn("filename*=UTF-8''" + quote("demo报表 2026.xlsx", safe=""), cd)
        self.assertIn('filename="', cd)
        fallback = cd.split('filename="', 1)[1].split('"', 1)[0]
        self.assertTrue(fallback.isascii() and fallback.endswith(".xlsx") and "2026" in fallback, fallback)
        cd.encode("ascii")  # headers must be ASCII only
        st, h, _ = self.req("/api/file?p=%s&t=full" % quote(p, safe=""))
        self.assertTrue(h["content-disposition"].startswith("inline;"))
        st, h, _ = self.req("/api/file?p=%s&t=full&dl=1" % quote("/private/tmp/g/r.pdf", safe=""),
                            headers={"Range": "bytes=0-9"})
        self.assertEqual(st, 206)
        self.assertTrue(h["content-disposition"].startswith("attachment;"))

    def test_download_bad_param_and_thumb(self):
        p = quote("/private/tmp/g/x.png", safe="")
        self.assertEqual(self.req("/api/file?p=%s&t=full&dl=2" % p)[0], 400)
        self.assertEqual(self.req("/api/file?p=%s&t=full&dl=1&dl=1" % p)[0], 400)
        st, h, _ = self.req("/api/file?p=%s&t=thumb&dl=1" % p)  # thumbnails are not downloaded
        self.assertEqual(st, 200)
        self.assertTrue(h["content-disposition"].startswith("inline;"))

    def test_download_guest_rules(self):
        """dl=1 does not relax guest rules: by-path stays 404; an upload tok can be downloaded as attachment; forged signature -> 404."""
        p = quote("/private/tmp/g/x.png", safe="")
        self.assertEqual(self.req("/api/file?p=%s&dl=1" % p, cookie=GUEST_COOKIE)[0], 404)
        sec = files.file_secret(KEY)
        now = int(time.time())
        tok = files.sign(UP_HOST + "/a.pdf", now + 600, sec)
        st, h, body = self.req("/api/file?tok=%s&dl=1" % quote(tok, safe=""), cookie=GUEST_COOKIE)
        self.assertEqual((st, body), (200, b"%PDF-1.4 upload"))
        self.assertTrue(h["content-disposition"].startswith("attachment;"))
        forged = files.sign(UP_HOST + "/a.pdf", now + 600, b"wrong")
        self.assertEqual(self.req("/api/file?tok=%s&dl=1" % quote(forged, safe=""), cookie=GUEST_COOKIE)[0], 404)
        self.assertEqual(self.req("/api/file?sid=c2&ref=%s&dl=1" % self.ref(0), cookie=GUEST_COOKIE)[0], 404)
        self.assertEqual(self.req("/api/file?p=%s&dl=1" % p, cookie=None)[0], 401)

    def test_guest_file_rules(self):
        st, _, _ = self.f("/private/tmp/g/x.png", cookie=GUEST_COOKIE)
        self.assertEqual(st, 404)  # a guest passing p always gets 404
        self.assertEqual(self.f(UP_HOST + "/a.pdf", cookie=GUEST_COOKIE)[0], 404)
        self.assertEqual(self.req("/api/file?sid=c2&ref=" + self.ref(0), cookie=GUEST_COOKIE)[0], 404)  # not the bound session
        self.assertEqual(self.req("/api/file?p=", cookie=GUEST_COOKIE)[0], 404)  # a guest passing p (empty value) also gets 404
        st, _, body = self.req("/api/file?sid=c1&ref=" + self.ref(0), cookie=GUEST_COOKIE)
        self.assertEqual((st, body), (200, self.emb))
        sec = files.file_secret(KEY)
        now = int(time.time())
        tok = files.sign(UP_HOST + "/a.pdf", now + 600, sec)
        st, h, body = self.req("/api/file?tok=" + quote(tok, safe=""), cookie=GUEST_COOKIE)
        self.assertEqual((st, body), (200, b"%PDF-1.4 upload"))
        self.assertEqual(h["content-type"], "application/pdf")
        old = files.sign(UP_HOST + "/a.pdf", now - 10, sec)
        self.assertEqual(self.req("/api/file?tok=" + quote(old, safe=""), cookie=GUEST_COOKIE)[0], 404)
        outside = files.sign("/private/tmp/g/x.png", now + 600, sec)  # valid signature but not under uploads
        self.assertEqual(self.req("/api/file?tok=" + quote(outside, safe=""), cookie=GUEST_COOKIE)[0], 404)
        forged = files.sign(UP_HOST + "/a.pdf", now + 600, b"wrong")
        self.assertEqual(self.req("/api/file?tok=" + quote(forged, safe=""), cookie=GUEST_COOKIE)[0], 404)
        # the coarse gate lets /api/file through
        self.assertTrue(server.guest_api_path("/api/file"))

    def test_rate_limit(self):
        for i in range(600):
            st = self.f("/private/tmp/g/nope.png")[0]
            self.assertEqual(st, 404, i)
        st, h, _ = self.f("/private/tmp/g/x.png")
        self.assertEqual(st, 429)
        self.assertEqual(h["x-content-type-options"], "nosniff")
        self.assertEqual(self.req("/api/file?sid=c1&ref=" + self.ref(0), cookie=GUEST_COOKIE)[0], 200)  # counted per account

    def _transcript(self, cookie):
        st, _, body = self.req("/api/sessions/c1/transcript", cookie=cookie)
        self.assertEqual(st, 200)
        return json.loads(body)["items"]

    def test_transcript_roots_wired(self):
        items = self._transcript(ADMIN_COOKIE)
        asst = [i for i in items if i["role"] == "assistant"][0]
        paths = [x.get("path") for x in asst.get("files") or []]
        self.assertEqual(paths, ["/private/tmp/g/x.png"])  # the nonexistent missing.png is dropped
        self.assertEqual(asst["files"][0]["size"], len(self.png))
        up = [i for i in items if i["role"] == "user" and "手机" in i["text"]][0]
        self.assertEqual(up["files"][0]["path"], UP_HOST + "/a.pdf")

    def test_transcript_guest_filter(self):
        items = self._transcript(GUEST_COOKIE)
        asst = [i for i in items if i["role"] == "assistant"][0]
        # files mentioned in assistant replies are also shown to the guest, without a path, only a signed tok carrying the session sid
        self.assertEqual([x["name"] for x in asst["files"]], ["x.png"])
        self.assertNotIn("path", asst["files"][0])
        self.assertEqual(files.verify_msg(asst["files"][0]["tok"], files.file_secret(KEY), int(time.time())),
                         ("c1", "/private/tmp/g/x.png"))
        up = [i for i in items if i["role"] == "user" and "手机" in i["text"]][0]
        f = up["files"][0]
        self.assertNotIn("path", f)
        self.assertEqual(files.verify(f["tok"], files.file_secret(KEY), int(time.time())), UP_HOST + "/a.pdf")
        self.assertGreater(files.verify(f["tok"], files.file_secret(KEY), int(time.time()) + 86000) or "", "")
        img = [i for i in items if i["role"] == "user" and i.get("files") and "ref" in i["files"][0]][0]
        self.assertEqual(img["files"][0]["ref"], self.ref(0))  # inline image kept (with line fingerprint)
        st, _, body = self.req("/api/file?tok=" + quote(f["tok"], safe=""), cookie=GUEST_COOKIE)
        self.assertEqual((st, body), (200, b"%PDF-1.4 upload"))
        # admin still sees the path
        up_admin = [i for i in self._transcript(ADMIN_COOKIE) if i["role"] == "user" and "手机" in i["text"]][0]
        self.assertIn("path", up_admin["files"][0])


    def test_transcript_files_carry_version(self):
        transcript._stat_cache.clear()  # same host path but different temp dirs per test: clear the cache left by other tests
        items = self._transcript(ADMIN_COOKIE)
        asst = [i for i in items if i["role"] == "assistant"][0]
        s = os.stat(os.path.join(self.host_tmp, "x.png"))
        self.assertEqual(asst["files"][0]["v"], str(s.st_mtime_ns))
        up = [i for i in self._transcript(GUEST_COOKIE) if i["role"] == "user" and "手机" in i["text"]][0]
        su = os.stat(os.path.join(self.uploads, "a.pdf"))
        self.assertEqual(up["files"][0]["v"], str(su.st_mtime_ns))  # guest tok entries also carry v
        self.assertIn("tok", up["files"][0])

    def test_version_param_ignored(self):
        st, _, body = self.req("/api/file?p=" + quote("/private/tmp/g/x.png", safe="") + "&t=full&v=123")
        self.assertEqual((st, body), (200, self.png))

    def test_guest_tok_stable_within_day(self):
        day = (int(time.time()) // 86400) * 86400
        toks = []
        for t in (day + 100, day + 5000):  # different seconds within the same day
            with mock.patch.object(server.time, "time", return_value=float(t)):
                up = [i for i in self._transcript(GUEST_COOKIE) if i["role"] == "user" and "手机" in i["text"]][0]
            toks.append(up["files"][0]["tok"])
        self.assertEqual(toks[0], toks[1])
        exp = int(toks[0].split(".")[1])
        self.assertEqual(exp, day + 2 * 86400)

class UploadOwnerTest(unittest.TestCase):
    """High risk: an upload-dir path typed in user text must not count as upload authorization. A guest may only fetch files that the upload log proves were uploaded by themselves (or an admin)
    and sent into a session they can see; the log persists on the state volume across restarts; old uploads with no log entry are never served to guests."""
    setUp = FileApiTest.setUp
    req = FileApiTest.req
    _write = staticmethod(FileApiTest._write)

    def page(self, cookie=GUEST_COOKIE):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("GET", "/api/sessions/c1/transcript", headers={"Cookie": cookie})
        r = c.getresponse()
        d = json.loads(r.read())
        c.close()
        return d["items"]

    def forge(self, name):
        """A guest sends the full path of someone else's upload as plain text in their own session (appended to the c1 transcript)."""
        line = {"type": "user", "timestamp": "2026-10-23T01:00:09Z",
                "message": {"role": "user", "content": "[Guest] 看这个 %s/%s" % (UP_HOST, name)}}
        with open(self.c1, "ab") as f:
            f.write(json.dumps(line, ensure_ascii=False).encode("utf-8") + b"\n")

    def guest_files(self, name):
        return [f for i in self.page() for f in i.get("files") or [] if f.get("name") == name]

    def test_forged_path_of_admin_upload_elsewhere_gets_no_tok(self):
        self._write(os.path.join(self.uploads, "20261023-010000-abcdef-salary.pdf"), b"%PDF secret")
        self.httpd.app.uploadlog.add("20261023-010000-abcdef-salary.pdf", "admin", "c2")  # sent by an admin in c2
        self.forge("20261023-010000-abcdef-salary.pdf")
        self.assertEqual(self.guest_files("20261023-010000-abcdef-salary.pdf"), [])
        # a signed tok directly (first guest and admin share one tok secret) does not work either
        tok = files.sign(UP_HOST + "/20261023-010000-abcdef-salary.pdf", int(time.time()) + 600, files.file_secret(KEY))
        self.assertEqual(self.req("/api/file?tok=" + quote(tok, safe=""), cookie=GUEST_COOKIE)[0], 404)
        # admin still sees the card (by path)
        adm = [f for i in self.page(ADMIN_COOKIE) for f in i.get("files") or []
               if f.get("name") == "20261023-010000-abcdef-salary.pdf"]
        self.assertEqual(len(adm), 1)
        self.assertIn("path", adm[0])

    def test_forged_path_of_other_guest_upload_gets_no_tok(self):
        self._write(os.path.join(self.uploads, "20261023-010000-abcdef-b.pdf"), b"%PDF b")
        self.httpd.app.uploadlog.add("20261023-010000-abcdef-b.pdf", "carol", "c1")  # uploaded by another guest
        self.forge("20261023-010000-abcdef-b.pdf")
        self.assertEqual(self.guest_files("20261023-010000-abcdef-b.pdf"), [])

    def test_unrecorded_old_upload_denied_for_guest(self):
        self._write(os.path.join(self.uploads, "20261023-010000-abcdef-old.pdf"), b"%PDF old")
        self.forge("20261023-010000-abcdef-old.pdf")
        self.assertEqual(self.guest_files("20261023-010000-abcdef-old.pdf"), [])
        tok = files.sign(UP_HOST + "/20261023-010000-abcdef-old.pdf", int(time.time()) + 600, files.file_secret(KEY))
        self.assertEqual(self.req("/api/file?tok=" + quote(tok, safe=""), cookie=GUEST_COOKIE)[0], 404)

    def test_own_upload_and_admin_upload_in_bound_session_ok(self):
        self.assertEqual(len(self.guest_files("a.pdf")), 1)  # recorded in setUp: uploaded by the guest, sent in c1
        self._write(os.path.join(self.uploads, "20261023-010000-abcdef-plan.pdf"), b"%PDF plan")
        self.httpd.app.uploadlog.add("20261023-010000-abcdef-plan.pdf", "admin", "c1")  # admin sent into the guest session
        self.forge("20261023-010000-abcdef-plan.pdf")
        f = self.guest_files("20261023-010000-abcdef-plan.pdf")
        self.assertEqual(len(f), 1)
        st, _, body = self.req("/api/file?tok=" + quote(f[0]["tok"], safe=""), cookie=GUEST_COOKIE)
        self.assertEqual((st, body), (200, b"%PDF plan"))

    def test_record_persists_across_restart(self):
        from api.uploadlog import UploadLog
        again = UploadLog(os.path.join(self.state_dir, "uploads.json"))
        self.assertEqual(again.get("a.pdf")["account"], "guest")
        self.assertTrue(again.guest_may_see("a.pdf", "guest", ["c1"]))
        self.assertFalse(again.guest_may_see("a.pdf", "guest", ["c2"]))
        self.assertFalse(again.guest_may_see("a.pdf", "carol", ["c1"]))


class PrevWindowImageTest(unittest.TestCase):
    """Medium risk: for inline images in a previous-window transcript, the page ref items carry the previous window sid and the image is read from that transcript;
    guests only accept the bound session and the previous windows they can page back to, admin accepts any previous window (transcripts under projects)."""
    setUp0 = FileApiTest.setUp
    req = FileApiTest.req
    ref = FileApiTest.ref
    _write = staticmethod(FileApiTest._write)

    def setUp(self):
        self.setUp0()
        self.c0 = os.path.join(os.path.dirname(self.c1), "%s.jsonl" % PREV)
        self.prev_img = _png(12, 9, (10, 200, 10))
        line = {"type": "user", "timestamp": "2026-10-22T01:00:00Z", "message": {"role": "user", "content": [
            {"type": "text", "text": "前窗的图"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                         "data": base64.b64encode(self.prev_img).decode()}}]}}
        with open(self.c0, "wb") as f:
            f.write(json.dumps(line, ensure_ascii=False).encode("utf-8") + b"\n")
        win = [{"sid": PREV, "path": os.path.realpath(self.c0), "at": 1.0, "via": "lineage", "name": BOUND}]
        p = mock.patch.object(server.App, "windows", lambda app, s: win if s.get("id") == "c1" else [])
        p.start()
        self.addCleanup(p.stop)

    def page(self, cookie):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("GET", "/api/sessions/c1/transcript?from=" + PREV, headers={"Cookie": cookie})
        r = c.getresponse()
        d = json.loads(r.read())
        c.close()
        return d["items"]

    def test_prev_window_ref_carries_sid_and_loads(self):
        for cookie in (ADMIN_COOKIE, GUEST_COOKIE):
            f = [f for i in self.page(cookie) for f in i.get("files") or [] if "ref" in f][0]
            self.assertEqual(f["sid"], PREV)
            self.assertEqual(f["ref"], self.ref(0, path=self.c0))
            st, _, body = self.req("/api/file?sid=%s&ref=%s" % (PREV, quote(f["ref"], safe="")), cookie=cookie)
            self.assertEqual((st, body), (200, self.prev_img), cookie[:8])

    def test_guest_cannot_use_unrelated_window(self):
        """A transcript outside the guest previous-window chain (c2) always gets 404 by sid; admin is allowed."""
        st, _, _ = self.req("/api/file?sid=c2&ref=" + self.ref(0, path=os.path.join(os.path.dirname(self.c1), "c2.jsonl")),
                            cookie=GUEST_COOKIE)
        self.assertEqual(st, 404)
        with mock.patch.object(server.App, "windows", lambda app, s: []):
            ref = self.ref(0, path=self.c0)
            self.assertEqual(self.req("/api/file?sid=%s&ref=%s" % (PREV, quote(ref, safe="")),
                                      cookie=GUEST_COOKIE)[0], 404)
            st, _, body = self.req("/api/file?sid=%s&ref=%s" % (PREV, quote(ref, safe="")))  # admin: locate the transcript under projects
            self.assertEqual((st, body), (200, self.prev_img))


class GuestMsgFileTest(unittest.TestCase):
    """A guest can view/download files mentioned in Agent replies of their bound session; the signature carries the session sid, the server re-reads the transcript to verify; access is logged."""
    setUp = FileApiTest.setUp
    _write = staticmethod(FileApiTest._write)
    req = FileApiTest.req
    _transcript = FileApiTest._transcript

    def _append(self, *rows, path=None):
        with open(path or self.c1, "ab") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False).encode("utf-8") + b"\n")

    def _asst(self, text, path=None):
        self._append({"type": "assistant", "timestamp": "2026-10-23T02:00:00Z",
                      "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}, path=path)

    def _bash(self, cmd):
        self._append({"type": "assistant", "timestamp": "2026-10-23T02:00:01Z",
                      "message": {"role": "assistant", "content": [
                          {"type": "tool_use", "id": "tu%d" % len(cmd), "name": "Bash", "input": {"command": cmd}}]}})

    def _tok(self, sid, host, exp=None):
        return files.sign_msg(sid, host, exp or int(time.time()) + 600, files.file_secret(KEY))

    def get(self, tok, extra="", cookie=GUEST_COOKIE):
        return self.req("/api/file?tok=" + quote(tok, safe="") + extra, cookie=cookie)

    def _guest_asst_files(self):
        return [(i["text"], f) for i in self._transcript(GUEST_COOKIE) if i["role"] == "assistant"
                for f in i.get("files") or []]

    def log_lines(self):
        p = os.path.join(self.state_dir, "guest-file.log")
        with open(p, encoding="utf-8") as f:
            return [ln.rstrip("\n").split("\t") for ln in f]

    def test_page_keeps_assistant_files_without_path(self):
        self._asst("报表做好了：/private/tmp/g/r.pdf")
        got = self._guest_asst_files()
        names = [f["name"] for _, f in got]
        self.assertEqual(names, ["x.png", "r.pdf"])
        for _, f in got:
            self.assertNotIn("path", f)
            self.assertTrue(f["tok"].startswith("m."))
        tok = [f for _, f in got if f["name"] == "r.pdf"][0]["tok"]
        st, h, body = self.get(tok)
        self.assertEqual((st, body), (200, bytes(range(256)) * 4))
        self.assertTrue(h["content-disposition"].startswith("inline;"))
        st, h, body = self.get(tok, "&t=full&dl=1")  # a Windows guest clicking the card goes through download
        self.assertEqual(st, 200)
        self.assertTrue(h["content-disposition"].startswith("attachment;"))
        st, h, _ = self.get([f for _, f in got if f["name"] == "x.png"][0]["tok"], "&t=thumb")
        self.assertEqual((st, h["content-type"]), (200, "image/webp"))
        # uploads still use the old 3-part tok and can still be fetched
        up = [i for i in self._transcript(GUEST_COOKIE) if i["role"] == "user" and "手机" in i["text"]][0]["files"][0]
        self.assertEqual(up["tok"].count("."), 2)
        self.assertEqual(self.get(up["tok"])[0], 200)
        # admin page still uses path, no tok
        adm = [f for i in self._transcript(ADMIN_COOKIE) if i["role"] == "assistant" for f in i.get("files") or []]
        self.assertTrue(all("path" in f and "tok" not in f for f in adm))
        # admin using a guest reply tok: 404 (admin only uses p=)
        self.assertEqual(self.get(tok, cookie=ADMIN_COOKIE)[0], 404)

    def test_open_only_not_given_open_and_mentioned_given(self):
        self._asst("我先打开看看")
        self._bash("open /private/tmp/g/r.pdf")  # only opened on the Mac, path not written in the reply: not given to the guest
        self.assertNotIn("r.pdf", [f["name"] for _, f in self._guest_asst_files()])
        adm = [f for i in self._transcript(ADMIN_COOKIE) for f in i.get("files") or [] if f.get("name") == "r.pdf"]
        self.assertEqual(len(adm), 1)  # admin still sees it
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/r.pdf"))[0], 404)
        # written in the reply and also opened in the same turn (src overwritten to open): counts as a reply file, served
        self._append({"type": "user", "timestamp": "2026-10-23T03:00:00Z", "message": {"role": "user", "content": "再来"}})
        self._bash("open /private/tmp/g/demo报表2.pdf")
        self._asst("另一份在 /private/tmp/g/x.png")
        self._bash("open /private/tmp/g/x.png")
        got = [f for t, f in self._guest_asst_files() if "另一份" in t]
        self.assertEqual([(f["name"], f["src"]) for f in got], [("x.png", "open")])
        self.assertEqual(self.get(got[0]["tok"])[0], 200)

    def test_cross_session_and_tamper_404(self):
        # c2 is not the guest-bound session: even if the c2 reply mentions it and the signature is valid, always 404
        self._asst("见 /private/tmp/g/r.pdf", path=os.path.join(os.path.dirname(self.c1), "c2.jsonl"))
        self.assertEqual(self.get(self._tok("c2", "/private/tmp/g/r.pdf"))[0], 404)
        # tamper with the sid segment (mac mismatch)
        good = self._tok("c1", "/private/tmp/g/x.png")
        self.assertEqual(self.get(good)[0], 200)
        parts = good.split(".")
        parts[1] = files._b64(b"c2")
        self.assertEqual(self.get(".".join(parts))[0], 404)
        parts = good.split(".")
        parts[2] = files._b64(b"/private/tmp/g/r.pdf")  # tamper with the path segment
        self.assertEqual(self.get(".".join(parts))[0], 404)
        # signed with a different secret
        self.assertEqual(self.get(files.sign_msg("c1", "/private/tmp/g/x.png", int(time.time()) + 600, b"x" * 32))[0], 404)
        # reply tok posing as upload tok / upload tok posing as reply tok
        up = files.sign("/private/tmp/g/x.png", int(time.time()) + 600, files.file_secret(KEY))
        self.assertEqual(self.get(up)[0], 404)  # the old 3-part format only accepts uploads
        self.assertIsNone(files.verify_msg(up, files.file_secret(KEY), int(time.time())))
        self.assertIsNone(files.verify(good, files.file_secret(KEY), int(time.time())))

    def test_not_in_message_404(self):
        # inside an allowlisted root and the file exists, but never mentioned in a reply
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/r.pdf"))[0], 404)
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/n.txt"))[0], 404)
        # appearing only in user messages (not the upload dir) does not count either
        self._append({"type": "user", "timestamp": "2026-10-23T03:00:00Z",
                      "message": {"role": "user", "content": "帮我看 /private/tmp/g/r.pdf"}})
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/r.pdf"))[0], 404)
        # mentions in subagent (sidechain) lines do not count either
        self._append({"type": "assistant", "isSidechain": True, "timestamp": "2026-10-23T03:00:01Z",
                      "message": {"role": "assistant", "content": [{"type": "text", "text": "/private/tmp/g/r.pdf"}]}})
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/r.pdf"))[0], 404)
        # only allowed after a reply mentions it (incremental scan of newly appended lines)
        self._asst("在这 /private/tmp/g/r.pdf")
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/r.pdf"))[0], 200)

    def test_dir_symlink_escape_404(self):
        os.makedirs(os.path.join(self.host_tmp, "sub.pdf"))
        self._asst("见 /private/tmp/g/sub.pdf 和 /private/tmp/g/link.png 和 /private/tmp/g/../secret/real.png")
        for host in ("/private/tmp/g/sub.pdf", "/private/tmp/g/link.png", "/private/tmp/g/../secret/real.png"):
            self.assertEqual(self.get(self._tok("c1", host))[0], 404, host)
        self.assertNotIn("link.png", [f["name"] for _, f in self._guest_asst_files()])

    def test_expired_404(self):
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/x.png", int(time.time()) - 5))[0], 404)

    def test_access_log(self):
        tok = self._tok("c1", "/private/tmp/g/x.png")
        self.assertEqual(self.get(tok, "&dl=1")[0], 200)
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/r.pdf"))[0], 404)
        self.assertEqual(self.get("m.a.b.1.c")[0], 404)
        self.assertEqual(self.req("/api/file?p=" + quote("/private/tmp/g/x.png", safe=""), cookie=GUEST_COOKIE)[0], 404)
        self.assertEqual(self.req("/api/file?p=" + quote("/private/tmp/g/x.png", safe=""))[0], 200)  # admin is not logged
        rows = self.log_lines()
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0][1:], ["guest", "c1", "x.png", "200:ok", "t=full", "dl=1"])
        self.assertEqual(rows[1][1:], ["guest", "c1", "r.pdf", "404:deny:not-in-msg", "t=full", "dl=0"])
        self.assertEqual(rows[2][1:4], ["guest", "-", "-"])
        self.assertTrue(rows[2][4].startswith("404"))
        self.assertTrue(rows[3][4].startswith("404"))
        with open(os.path.join(self.state_dir, "guest-file.log"), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("/private/tmp", raw)  # log only the file name, not the host path
        # rotate to .1 when over the limit
        with mock.patch.object(server, "GUEST_FILE_LOG_MAX", 10):
            self.get(tok)
        self.assertTrue(os.path.exists(os.path.join(self.state_dir, "guest-file.log.1")))
        self.assertEqual(len(self.log_lines()), 1)

    def test_assistant_paths_incremental(self):
        transcript._asst_cache.clear()
        self.assertEqual(transcript.assistant_paths(self.c1), {"/private/tmp/g/x.png", "/private/tmp/g/missing.png"})
        with open(self.c1, "ab") as f:  # partial line: not counted yet
            f.write(b'{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"/private/tmp/g/r.pdf"}]}}')
        self.assertNotIn("/private/tmp/g/r.pdf", transcript.assistant_paths(self.c1))
        with open(self.c1, "ab") as f:
            f.write(b"\n")
        self.assertIn("/private/tmp/g/r.pdf", transcript.assistant_paths(self.c1))
        self.assertEqual(transcript.assistant_paths(os.path.join(self.tmp.name, "nope.jsonl")), set())


PROJ = CP_HOST + "/demo-group/demo-proj"  # project dir of the bound session (host path), shaped like real data
REAL = "002_SQ台账时间对Aconex核对/交付/SQ台账及对工期的影响-20261024_对Aconex核对_v4.xlsx"
W1 = "11111111-1111-4111-8111-111111111111"  # previous-window sid (transcript?from= only accepts a UUID)
W2 = "22222222-2222-4222-8222-222222222222"


class GuestFileLimitTest(unittest.TestCase):
    """Three extra limits for guests fetching files from Agent replies: only under the bound session cwd, no path segment starting with . and no sensitive word in the file name, and an extension allowlist.
    They apply both when the page builds cards and when an old tok is re-checked on fetch; admin is unaffected."""
    C1_CWD = PROJ
    _write = staticmethod(FileApiTest._write)
    req = FileApiTest.req
    _transcript = FileApiTest._transcript
    _append = GuestMsgFileTest._append
    _asst = GuestMsgFileTest._asst
    _tok = GuestMsgFileTest._tok
    get = GuestMsgFileTest.get
    _guest_asst_files = GuestMsgFileTest._guest_asst_files
    log_lines = GuestMsgFileTest.log_lines

    def setUp(self):
        FileApiTest.setUp(self)
        self.proj = os.path.join(self.cp, "demo-group", "demo-proj")
        self.other = os.path.join(self.cp, "别的项目")
        for rel in (REAL, "monkey.xlsx", "sub/ok.pdf", ".env", ".git/x.xlsx", "secret.xlsx", "my-token.xlsx",
                    "key.xlsx", "api_key.txt", "secret-notes.md", "a.py", "a.json", "a.sh", "a.zip"):
            self.put(os.path.join(self.proj, rel))
        self.put(os.path.join(self.other, "b.xlsx"))
        self.put(os.path.join(self.cp, "前窗项目", "w.xlsx"))
        os.symlink(os.path.join(self.other, "b.xlsx"), os.path.join(self.proj, "out.xlsx"))  # symlink inside cwd pointing to another project

    def put(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._write(path, b"PK\x03\x04 " + os.path.basename(path).encode("utf-8"))

    def h(self, rel):
        return PROJ + "/" + rel

    def names(self):
        return [f["name"] for _, f in self._guest_asst_files()]

    def test_same_project_ok_incl_dl(self):
        self._asst("交付在 %s ，另 %s 和 %s" % (self.h(REAL), self.h("monkey.xlsx"), self.h("sub/ok.pdf")))
        got = {f["name"]: f for _, f in self._guest_asst_files()}
        self.assertEqual(set(got), {os.path.basename(REAL), "monkey.xlsx", "ok.pdf"})  # monkey is not caught by the key word
        st, h, body = self.get(got[os.path.basename(REAL)]["tok"], "&t=full&dl=1")
        self.assertEqual((st, body), (200, b"PK\x03\x04 " + os.path.basename(REAL).encode("utf-8")))
        self.assertTrue(h["content-disposition"].startswith("attachment;"))
        self.assertEqual(self.get(got["monkey.xlsx"]["tok"])[0], 200)
        self.assertEqual(self.get(got["ok.pdf"]["tok"])[0], 200)

    BAD = [
        (CP_HOST + "/别的项目/b.xlsx", "deny:cwd"),        # another project dir
        ("out.xlsx", "deny:cwd"),                          # symlink from cwd pointing outside
        (".env", "deny:dot"),
        (".git/x.xlsx", "deny:dot"),
        ("sub/../.env", "deny:dot"),
        ("secret.xlsx", "deny:name"),
        ("my-token.xlsx", "deny:name"),
        ("key.xlsx", "deny:name"),
        ("api_key.txt", "deny:name"),
        ("secret-notes.md", "deny:name"),
        ("a.py", "deny:ext"),
        ("a.json", "deny:ext"),
        ("a.sh", "deny:ext"),
    ]

    def test_denied_page_and_tok(self):
        hosts = [(b if b.startswith("/") else self.h(b), why) for b, why in self.BAD]
        # mention everything in the reply (.json via md link; bare paths are not recognized)
        self._asst(" ".join(x for x, _ in hosts) + " [j](%s)" % self.h("a.json"))
        self.assertEqual(self.names(), [])  # no card at all
        for host, why in hosts:
            self.assertEqual(self.get(self._tok("c1", host))[0], 404, host)
        rows = self.log_lines()
        self.assertEqual([r[4] for r in rows], ["404:" + why for _, why in hosts])
        # admin can still fetch the same paths (known types)
        for host in (CP_HOST + "/别的项目/b.xlsx", self.h("out.xlsx"), self.h(".git/x.xlsx"), self.h("secret.xlsx"),
                     self.h("api_key.txt"), self.h("secret-notes.md")):
            self.assertEqual(self.req("/api/file?p=" + quote(host, safe=""))[0], 200, host)
        adm = [f["name"] for i in self._transcript(ADMIN_COOKIE) if i["role"] == "assistant" for f in i.get("files") or []]
        self.assertIn("b.xlsx", adm)
        self.assertIn("secret.xlsx", adm)

    def test_old_tok_rechecked(self):
        """A tok issued earlier on the page (signed before the rules tightened) is still checked against the three limits on fetch."""
        self._asst("见 %s" % self.h("secret.xlsx"))
        self.assertEqual(self.get(self._tok("c1", self.h("secret.xlsx")))[0], 404)
        self.assertEqual(self.log_lines()[-1][4], "404:deny:name")

    def _windows(self, *wins):
        return mock.patch.object(self.httpd.app, "guest_windows", lambda s, g=None: [dict(w) for w in wins])

    def _window_file(self, sid, cwd, text):
        path = os.path.join(os.path.dirname(self.c1), sid + ".jsonl")
        row = {"type": "assistant", "timestamp": "2026-10-20T01:00:00Z",
               "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}
        if cwd:
            row["cwd"] = cwd
        with open(path, "wb") as f:
            f.write(json.dumps(row, ensure_ascii=False).encode("utf-8") + b"\n")
        return {"sid": sid, "path": path, "at": "", "via": "window", "name": BOUND}

    def test_prev_window_uses_its_own_cwd(self):
        wfile = CP_HOST + "/前窗项目/w.xlsx"
        w1 = self._window_file(W1, CP_HOST + "/前窗项目", "前窗做的表 %s ，还有 %s" % (wfile, self.h("monkey.xlsx")))
        with self._windows(w1):
            st, _, body = self.req("/api/sessions/c1/transcript?from=" + W1, cookie=GUEST_COOKIE)
            self.assertEqual(st, 200)
            fl = [f for i in json.loads(body)["items"] for f in i.get("files") or []]
            self.assertEqual([f["name"] for f in fl], ["w.xlsx"])  # the previous window uses its own cwd: monkey from this window's project is not under it
            self.assertEqual(files.verify_msg(fl[0]["tok"], files.file_secret(KEY), int(time.time()))[0], W1)
            self.assertEqual(self.get(fl[0]["tok"], "&dl=1")[0], 200)
            # cross-session: the same file signed for the bound session / a previous window not in the chain always gets 404
            self.assertEqual(self.get(self._tok("c1", wfile))[0], 404)
            self.assertEqual(self.get(self._tok(W2, wfile))[0], 404)
            self.assertEqual(self.get(self._tok(W1, self.h("monkey.xlsx")))[0], 404)
        self.assertEqual([r[4] for r in self.log_lines()], ["200:ok", "404:deny:cwd", "404:deny:sid", "404:deny:cwd"])

    def test_prev_window_without_cwd_falls_back_to_bound(self):
        w1 = self._window_file(W1, None, "见 %s 和 %s" % (self.h("monkey.xlsx"), CP_HOST + "/前窗项目/w.xlsx"))
        with self._windows(w1):
            st, _, body = self.req("/api/sessions/c1/transcript?from=" + W1, cookie=GUEST_COOKIE)
            fl = [f for i in json.loads(body)["items"] for f in i.get("files") or []]
            self.assertEqual([f["name"] for f in fl], ["monkey.xlsx"])
            self.assertEqual(self.get(fl[0]["tok"])[0], 200)
            self.assertEqual(self.get(self._tok(W1, CP_HOST + "/前窗项目/w.xlsx"))[0], 404)

    def test_guest_file_ok_unit(self):
        r = self.roots
        ok = lambda p, cwd=PROJ: files.guest_file_ok(p, cwd, r)  # noqa: E731
        self.assertIsNone(ok(self.h(REAL)))
        self.assertIsNone(ok(self.h("monkey.xlsx")))
        self.assertIsNone(ok("~/projects/demo-group/demo-proj/monkey.xlsx"))  # ~/ expands against the host home
        self.assertEqual(ok(self.h("api_key.txt")), "name")
        self.assertEqual(ok(self.h("apiKey.xlsx")), "name")
        self.assertEqual(ok(self.h("Credentials.PDF")), "name")
        self.assertEqual(ok(self.h("SECRET.xlsx")), "name")
        self.assertEqual(ok(self.h("a.ZIP")), "ext")  # zip is not on the allowlist
        self.assertEqual(ok(self.h("a.py")), "ext")
        self.assertEqual(ok(self.h("noext")), "ext")
        self.assertEqual(ok(self.h(".git/x.xlsx")), "dot")
        self.assertEqual(ok(self.h("monkey.xlsx"), None), "cwd")
        self.assertEqual(ok(self.h("monkey.xlsx"), ""), "cwd")
        self.assertEqual(ok(self.h("monkey.xlsx"), "relative/dir"), "cwd")
        self.assertEqual(ok(self.h("monkey.xlsx"), "/Users/zz/proj"), "cwd")  # cwd is not under any root
        self.assertEqual(ok(CP_HOST + "/别的项目/b.xlsx"), "cwd")
        self.put(self.proj + "x/monkey.xlsx")
        self.assertEqual(ok(PROJ + "x/monkey.xlsx"), "cwd")  # a sibling dir with the same prefix is not a subdirectory
        self.assertEqual(ok(None), "path")

    def test_dot_only_below_cwd(self):
        wt = os.path.join(self.cp, "wt", ".claude", "worktrees", "x")
        for rel in ("a.xlsx", ".git/a.xlsx", "sub/.hidden/a.xlsx", ".env"):
            self.put(os.path.join(wt, rel))
        os.symlink(os.path.join(wt, ".env"), os.path.join(wt, "link.xlsx"))  # symlink inside cwd pointing to .env
        self.put(os.path.join(self.cp, "wt", ".claude", "worktrees", "外部.xlsx"))
        cwd = CP_HOST + "/wt/.claude/worktrees/x"
        ok = lambda rel: files.guest_file_ok(cwd + "/" + rel, cwd, self.roots)  # noqa: E731
        self.assertIsNone(ok("a.xlsx"))  # dot segments in the cwd's own path are allowed
        self.assertEqual(ok(".git/a.xlsx"), "dot")
        self.assertEqual(ok("sub/.hidden/a.xlsx"), "dot")
        self.assertIsNotNone(ok("link.xlsx"))
        self.assertEqual(ok("sub/../../外部.xlsx"), "dot")
        self.assertEqual(ok("../外部.xlsx"), "dot")
        # dot segments are still rejected when the project dir itself is not under a dot segment
        self.assertEqual(files.guest_file_ok(self.h(".git/x.xlsx"), PROJ, self.roots), "dot")

    def test_name_words(self):
        for n in ("secretKey.xlsx", "apiToken.csv", "myPassword.txt", "APIKey.md", "系统密钥.xlsx", "数据库密码.txt",
                  "登录口令.md", "凭证清单.pdf", "令牌.txt"):
            self.assertEqual(files._name_why(n), "name", n)
        for n in ("monkey.xlsx", "keyboard_layout.pdf", "Monkey.xlsx", "Keynote.pptx"):
            self.assertIsNone(files._name_why(n), n)

    def test_zip_denied(self):
        self.assertEqual(files.guest_file_ok(self.h("a.zip"), PROJ, self.roots), "ext")
        self.assertIsNone(files.guest_file_ok(self.h("monkey.xlsx"), PROJ, self.roots))

    def test_cwd_too_wide(self):
        home = os.path.join(self.tmp.name, "home")
        os.makedirs(home)
        r = files.Roots([("/private/tmp", self.host_root), (CP_HOST, self.cp), ("/Users/zbs-test", home)],
                        home="/Users/zbs-test")
        self._write(os.path.join(home, "h.xlsx"), b"x")
        self._write(os.path.join(self.cp, "r.xlsx"), b"x")
        self._write(os.path.join(self.host_root, "t.xlsx"), b"x")
        self.assertEqual(files.guest_file_ok("/Users/zbs-test/h.xlsx", "/Users/zbs-test", r), "cwd")
        self.assertEqual(files.guest_file_ok("~/h.xlsx", "~/", r) if False else files.guest_file_ok("~/h.xlsx", "~", r), "cwd")
        self.assertEqual(files.guest_file_ok(CP_HOST + "/r.xlsx", CP_HOST, r), "cwd")
        self.assertEqual(files.guest_file_ok("/private/tmp/g/t.xlsx", "/private/tmp", r), "cwd")
        self.assertEqual(files.guest_file_ok("/tmp/t.xlsx", "/tmp", r), "cwd")
        self.assertIsNone(files.guest_file_ok(self.h(REAL), PROJ, r))  # subdirs under the root are allowed as usual
        self.assertIsNone(files.guest_file_ok(self.h("monkey.xlsx"), PROJ, self.roots))


class GuestFileNoCwdTest(unittest.TestCase):
    """The bound session has no cwd in the snapshot: files from replies are never served (no card on the page, tok -> 404). Uploads are unaffected."""
    C1_CWD = None
    setUp = FileApiTest.setUp
    _write = staticmethod(FileApiTest._write)
    req = FileApiTest.req
    _transcript = FileApiTest._transcript
    _tok = GuestMsgFileTest._tok
    get = GuestMsgFileTest.get
    _guest_asst_files = GuestMsgFileTest._guest_asst_files
    log_lines = GuestMsgFileTest.log_lines

    def test_no_cwd_denied(self):
        self.assertEqual(self._guest_asst_files(), [])
        self.assertEqual(self.get(self._tok("c1", "/private/tmp/g/x.png"))[0], 404)
        self.assertEqual(self.log_lines()[-1][4], "404:deny:cwd")
        up = [i for i in self._transcript(GUEST_COOKIE) if i["role"] == "user" and "手机" in i["text"]][0]["files"][0]
        self.assertEqual(self.get(up["tok"])[0], 200)  # uploads unaffected
        self.assertEqual(self.req("/api/file?p=" + quote("/private/tmp/g/x.png", safe=""))[0], 200)  # admin unaffected


class ThumbsUnitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_prune_keeps_under_limit(self):
        from api import thumbs
        d = os.path.join(self.tmp.name, "th")
        os.makedirs(d)
        for i in range(5):
            p = os.path.join(d, "%d.webp" % i)
            with open(p, "wb") as f:
                f.write(b"x" * 1000)
            os.utime(p, (1000 + i, 1000 + i))
        thumbs.prune(d, limit_bytes=2500)
        self.assertEqual(sorted(os.listdir(d)), ["3.webp", "4.webp"])  # the oldest is deleted

    def test_embedded_line_too_long(self):
        from api import thumbs
        p = os.path.join(self.tmp.name, "t.jsonl")
        with open(p, "wb") as f:
            f.write(b'{"x":"' + b"a" * 2000 + b'"}\n')
        with mock.patch.object(thumbs, "LINE_MAX", 1000):
            with open(p, "rb") as fh:
                fp = files.line_fp(fh.read(256))
            self.assertIsNone(thumbs.embedded(p, 0, 1, fp))

    def test_large_png_memory_bounded(self):
        import resource
        import sys as _sys
        from api import thumbs
        p = os.path.join(self.tmp.name, "w.png")
        Image.new("1", (6300, 6300)).save(p, "PNG")
        unit = 1 if _sys.platform == "darwin" else 1024  # ru_maxrss: bytes on mac, KB on Linux
        before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * unit
        self.assertIsNone(thumbs.make(p, os.path.join(self.tmp.name, "th"), "w"))
        after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * unit
        self.assertLess(after - before, 30 * 2**20)  # only the file header was read
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "th", "w.webp")))

    def test_huge_pixels_skipped(self):
        from api import thumbs
        p = os.path.join(self.tmp.name, "h.png")
        Image.new("1", (8000, 6000)).save(p, "PNG")  # 48 megapixels > 40 megapixels, tiny file
        self.assertIsNone(thumbs.make(p, os.path.join(self.tmp.name, "th"), "k"))


if __name__ == "__main__":
    unittest.main()
