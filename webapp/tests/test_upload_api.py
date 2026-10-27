import hashlib
import hmac
import http.client
import json
import os
import stat
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import outbox, server
from tests import _sig  # noqa: E402,F401  sets OUTBOX_SECRET (sending requires a signature)

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


class CleanFilenameTest(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(outbox.clean_filename("照片 1(最终).jpg"), "照片_1_最终_.jpg")
        self.assertEqual(outbox.clean_filename("../../etc/passwd"), "passwd")
        self.assertEqual(outbox.clean_filename("..\\..\\x.txt"), "x.txt")
        self.assertEqual(outbox.clean_filename(".bashrc"), "bashrc")
        self.assertEqual(outbox.clean_filename("..."), "file")
        self.assertEqual(outbox.clean_filename(""), "file")
        self.assertEqual(outbox.clean_filename(None), "file")
        self.assertEqual(outbox.clean_filename("a\x00b\nc.txt"), "a_b_c.txt")

    def test_max_80_keeps_extension(self):
        n = outbox.clean_filename("x" * 200 + ".pdf")
        self.assertEqual(len(n), 80)
        self.assertTrue(n.endswith(".pdf"))
        # CJK is limited by UTF-8 bytes (200), so the saved name with its prefix stays within the 255-byte filesystem limit
        self.assertEqual(len(outbox.clean_filename("中" * 200)), 66)

    def test_upload_name_format(self):
        n = outbox.upload_name("a b.png", 1792400000.0)
        self.assertRegex(n, r"^\d{8}-\d{6}-[0-9a-f]{6}-a_b\.png$")


class UploadApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.outbox = os.path.join(self.tmp.name, "outbox")
        self.uploads = os.path.join(self.tmp.name, "uploads")
        os.makedirs(self.outbox)
        os.makedirs(self.uploads)
        snap = os.path.join(self.tmp.name, "snapshot.json")
        now = time.time()
        with open(snap, "w") as f:
            json.dump({"generatedAt": now, "usage": {}, "zones": [], "sessions": [
                {"id": "c1", "kind": "claude", "status": "idle", "since": now},
                {"id": "x1", "kind": "codex", "status": "idle", "since": now},
            ]}, f)
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=snap, projects=self.tmp.name,
                                        state=os.path.join(self.tmp.name, "st", "state.json"),
                                        outbox_dir=self.outbox, uploads_dir=self.uploads)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, path, data, auth=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Content-Type": "application/json" if path.endswith("/send") else "image/jpeg"}  # JSON bodies need the JSON type
        if auth:
            h["Cookie"] = COOKIE
        c.request("POST", path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def test_upload_saves_and_enqueues(self):
        body = b"\xff\xd8abc" * 1000
        st, res = self.post("/api/sessions/c1/upload?name=%E7%85%A7%E7%89%87%201.jpg"
                            "&caption=%E7%9C%8B%E4%B8%8B%0A%E8%BF%99%E4%B8%AA", body)
        self.assertEqual(st, 202)
        rid = res["requestId"]
        self.assertRegex(rid, r"^[0-9a-f]{32}$")
        names = os.listdir(self.uploads)
        self.assertEqual(len(names), 1)
        self.assertRegex(names[0], r"^\d{8}-\d{6}-[0-9a-f]{6}-照片_1\.jpg$")
        path = os.path.join(self.uploads, names[0])
        with open(path, "rb") as f:
            self.assertEqual(f.read(), body)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)  # owner only
        with open(os.path.join(self.outbox, rid + ".req.json")) as f:
            d = json.load(f)
        self.assertEqual((d["type"], d["sessionId"], d["file"], d["caption"]),
                         ("file", "c1", names[0], "看下 这个"))

    def test_no_caption_and_no_name(self):
        st, res = self.post("/api/sessions/c1/upload", b"x")
        self.assertEqual(st, 202)
        with open(os.path.join(self.outbox, res["requestId"] + ".req.json")) as f:
            d = json.load(f)
        self.assertEqual(d["caption"], "")
        self.assertTrue(d["file"].endswith("-file"))

    def test_path_tricks_name(self):
        st, _ = self.post("/api/sessions/c1/upload?name=..%2F..%2Fetc%2Fpasswd", b"x")
        self.assertEqual(st, 202)
        names = os.listdir(self.uploads)
        self.assertEqual(len(names), 1)
        self.assertTrue(names[0].endswith("-passwd"))
        self.assertNotIn("passwd", os.listdir(self.tmp.name))

    def test_too_large_413_nothing_written(self):
        with mock.patch.object(server, "MAX_UPLOAD", 100):
            st, _ = self.post("/api/sessions/c1/upload?name=a.bin", b"x" * 101)
            self.assertEqual(st, 413)
            st, _ = self.post("/api/sessions/c1/upload?name=a.bin", b"x" * 100)
            self.assertEqual(st, 202)
        self.assertEqual(len(os.listdir(self.uploads)), 1)
        self.assertEqual(len(os.listdir(self.outbox)), 1)

    def test_limit_is_20mb(self):
        self.assertEqual(server.MAX_UPLOAD, 20 * 1024 * 1024)

    def test_oversize_rejected_without_reading_body(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.putrequest("POST", "/api/sessions/c1/upload?name=a")
        c.putheader("Cookie", COOKIE)
        c.putheader("Content-Length", str(server.MAX_UPLOAD + 1))
        c.endheaders()  # send no body; the server should answer 413 right away
        self.assertEqual(c.getresponse().status, 413)
        c.close()

    def test_unauthorized_unknown_and_unsupported(self):
        self.assertEqual(self.post("/api/sessions/c1/upload", b"x", auth=False)[0], 401)
        self.assertEqual(self.post("/api/sessions/nope/upload", b"x")[0], 404)
        self.assertEqual(self.post("/api/sessions/x1/upload", b"x")[0], 400)
        self.assertEqual(os.listdir(self.uploads), [])
        self.assertEqual(os.listdir(self.outbox), [])

    def test_empty_body_and_chunked_rejected(self):
        self.assertEqual(self.post("/api/sessions/c1/upload", b"")[0], 400)
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("POST", "/api/sessions/c1/upload", body=iter([b"abc"]),
                  headers={"Cookie": COOKIE}, encode_chunked=True)
        self.assertEqual(c.getresponse().status, 411)
        c.close()
        self.assertEqual(os.listdir(self.uploads), [])

    def test_truncated_body_leaves_nothing(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.putrequest("POST", "/api/sessions/c1/upload?name=a")
        c.putheader("Cookie", COOKIE)
        c.putheader("Content-Length", "100")
        c.endheaders(b"short")
        c.sock.shutdown(1)
        c.getresponse().read()
        c.close()
        self.assertEqual(os.listdir(self.uploads), [])
        self.assertEqual(os.listdir(self.outbox), [])


if __name__ == "__main__":
    unittest.main()


class TrayApiTest(UploadApiTest):
    """Attachment bar: /api/uploads only stores the file without queueing; send with files queues a message."""

    def up(self, name="a.png", data=b"\x89PNG"):
        st, res = self.post("/api/uploads?name=" + name, data)
        self.assertEqual(st, 200)
        return res["file"]

    def test_plain_upload_saves_no_enqueue(self):
        f = self.up("%E7%85%A7%E7%89%87.jpg", b"abc")
        self.assertRegex(f, r"^\d{8}-\d{6}-[0-9a-f]{6}-照片\.jpg$")
        self.assertEqual(os.listdir(self.uploads), [f])
        self.assertEqual(os.listdir(self.outbox), [])
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.uploads, f)).st_mode), 0o600)  # owner only

    def test_plain_upload_limits_and_auth(self):
        self.assertEqual(self.post("/api/uploads?name=a", b"x", auth=False)[0], 401)
        self.assertEqual(self.post("/api/uploads?name=a", b"")[0], 400)
        with mock.patch.object(server, "MAX_UPLOAD", 10):
            self.assertEqual(self.post("/api/uploads?name=a", b"x" * 11)[0], 413)
        self.assertEqual(os.listdir(self.uploads), [])

    def test_send_files_enqueues_message(self):
        a, b = self.up("a.png"), self.up("b.pdf")
        st, res = self.post("/api/sessions/c1/send", json.dumps({"text": "看看", "files": [a, b]}).encode())
        self.assertEqual(st, 202)
        with open(os.path.join(self.outbox, res["requestId"] + ".req.json")) as f:
            d = json.load(f)
        self.assertEqual((d["type"], d["sessionId"], d["text"], d["files"]), ("message", "c1", "看看", [a, b]))

    def test_send_files_without_text(self):
        a = self.up()
        st, res = self.post("/api/sessions/c1/send", json.dumps({"files": [a], "text": ""}).encode())
        self.assertEqual(st, 202)
        with open(os.path.join(self.outbox, res["requestId"] + ".req.json")) as f:
            self.assertEqual(json.load(f)["text"], "")

    def test_send_files_rejects_bad(self):
        a = self.up()
        link = "20260101-000000-abcdef-l.png"
        os.symlink("/etc/passwd", os.path.join(self.uploads, link))
        for files in ([], "x", [a] * 10, ["../x"], ["nope.png"], ["20260101-000000-abcdef-gone.png"],
                      [link], [5], [a, "../../etc/passwd"]):
            st, _ = self.post("/api/sessions/c1/send", json.dumps({"text": "t", "files": files}).encode())
            self.assertEqual(st, 400, files)
        st, _ = self.post("/api/sessions/c1/send", json.dumps({"text": 5, "files": [a]}).encode())
        self.assertEqual(st, 400)
        self.assertEqual(os.listdir(self.outbox), [])

    def test_send_nine_ok(self):
        fs = [self.up("f%d.png" % i) for i in range(9)]
        st, _ = self.post("/api/sessions/c1/send", json.dumps({"files": fs}).encode())
        self.assertEqual(st, 202)
