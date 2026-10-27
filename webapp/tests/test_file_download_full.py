"""/api/file: dl=1 on text types streams the whole original file; preview (no dl) still truncates with X-Truncated."""
import hashlib
import hmac
import http.client
import os
import tempfile
import threading
import unittest
from unittest import mock

from api import files, server

KEY = "admin-key-0123456789abcdef"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
SIZE = 3 * 2**20 + 7


class FileDownloadFullTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.host_root = os.path.join(t, "host", "tmp")
        d = os.path.join(self.host_root, "g")
        os.makedirs(d)
        self.data = (b"0123456789abcdef" * (SIZE // 16 + 1))[:SIZE]
        for n in ("report.csv", "d.json", "n.md", "n.txt"):
            with open(os.path.join(d, n), "wb") as f:
                f.write(self.data)
        snap = os.path.join(t, "snapshot.json")
        with open(snap, "w") as f:
            f.write('{"generatedAt": 1, "usage": {}, "zones": [], "sessions": []}')
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        roots = files.Roots([("/private/tmp", self.host_root)], home="/Users/zbs-test")
        os.makedirs(os.path.join(t, "projects"))
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=snap, projects=os.path.join(t, "projects"),
                                        state=os.path.join(t, "st", "state.json"), outbox_dir=os.path.join(t, "ob"),
                                        uploads_dir=os.path.join(t, "up"), file_roots=roots)
        self.port = self.httpd.server_address[1]
        th = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        th.start()
        self.addCleanup(lambda: (self.httpd.shutdown(), self.httpd.server_close()))

    def fetch(self, name, extra=""):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("GET", "/api/file?p=/private/tmp/g/" + name + "&t=full" + extra, headers={"Cookie": COOKIE})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, {k.lower(): v for k, v in r.getheaders()}, body

    def test_download_is_full_for_text_types(self):
        for n in ("report.csv", "d.json", "n.md", "n.txt"):
            st, h, body = self.fetch(n, "&dl=1")
            self.assertEqual(st, 200, n)
            self.assertEqual(body, self.data, n)
            self.assertNotIn("x-truncated", h, n)
            self.assertTrue(h["content-disposition"].startswith("attachment;"), n)

    def test_preview_still_truncated(self):
        st, h, body = self.fetch("report.csv")
        self.assertEqual(st, 200)
        self.assertEqual(len(body), 2 * 2**20)
        self.assertEqual(h["x-truncated"], "1")

    def test_download_respects_overall_cap(self):
        with mock.patch.object(files, "DOC_MAX", 1024):
            self.assertEqual(self.fetch("report.csv", "&dl=1")[0], 404)


if __name__ == "__main__":
    unittest.main()
