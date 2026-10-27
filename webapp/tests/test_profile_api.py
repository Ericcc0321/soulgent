"""My nickname and avatar: GET/POST /api/profile, GET /api/avatar (stored in the state volume as profile.json / avatar.jpg; guests can neither view nor change them)."""
import base64
import hashlib
import hmac
import http.client
import json
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import server
from tests._guests import guests_for  # noqa: E402

KEY = "secret-key-123-abcdefghijklmn"
GUEST = "guest-key-0123456789abcdef"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GUEST_COOKIE = "zbs=" + hmac.new(GUEST.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
JPEG = b"\xff\xd8\xff\xe0" + b"\x00\x10JFIF" + b"x" * 2000 + b"\xff\xd9"


class ProfileApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        snap = os.path.join(self.tmp.name, "snapshot.json")
        with open(snap, "w") as f:
            json.dump({"generatedAt": time.time(), "usage": {}, "zones": [], "sessions": []}, f)
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.stdir = os.path.join(self.tmp.name, "st")
        self.start()

    def start(self):
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=os.path.join(self.tmp.name, "snapshot.json"),
                                        projects=self.tmp.name, state=os.path.join(self.stdir, "state.json"),
                                        guests=guests_for(KEY, GUEST, "Web-guest-demo"))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def req(self, method, path, body=None, cookie=COOKIE):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Content-Type": "application/json"}
        if cookie:
            h["Cookie"] = cookie
        c.request(method, path, body=None if body is None else json.dumps(body), headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r, out

    def test_default_profile(self):
        r, out = self.req("GET", "/api/profile")
        self.assertEqual(r.status, 200)
        self.assertEqual(json.loads(out), {"name": "", "avatar": False, "v": 0, "default": ""})
        r, _ = self.req("GET", "/api/avatar")
        self.assertEqual(r.status, 404)

    def test_set_name_and_avatar_persist(self):
        b64 = base64.b64encode(JPEG).decode()
        r, out = self.req("POST", "/api/profile", {"name": "  Sam ", "avatar": b64})
        self.assertEqual(r.status, 200, out)
        res = json.loads(out)
        self.assertEqual(res["name"], "Sam")
        self.assertTrue(res["avatar"])
        self.assertGreater(res["v"], 0)
        r, out = self.req("GET", "/api/avatar")
        self.assertEqual(r.status, 200)
        self.assertEqual(r.getheader("Content-Type"), "image/jpeg")
        self.assertEqual(out, JPEG)
        with open(os.path.join(self.stdir, "avatar.jpg"), "rb") as f:
            self.assertEqual(f.read(), JPEG)
        with open(os.path.join(self.stdir, "profile.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["name"], "Sam")
        # survives a restart
        self.httpd.shutdown()
        self.httpd.server_close()
        self.start()
        r, out = self.req("GET", "/api/profile")
        self.assertEqual(json.loads(out)["name"], "Sam")
        self.assertTrue(json.loads(out)["avatar"])

    def test_name_only_keeps_avatar_and_null_clears(self):
        self.req("POST", "/api/profile", {"avatar": base64.b64encode(JPEG).decode()})
        r, out = self.req("POST", "/api/profile", {"name": "小王"})
        self.assertEqual(r.status, 200)
        self.assertTrue(json.loads(out)["avatar"])
        r, out = self.req("POST", "/api/profile", {"avatar": None})
        self.assertEqual(r.status, 200)
        self.assertFalse(json.loads(out)["avatar"])
        self.assertEqual(json.loads(out)["name"], "小王")
        self.assertEqual(self.req("GET", "/api/avatar")[0].status, 404)
        # an empty nickname reverts to the default (an empty string; the frontend shows "我 / Me" by language)
        r, out = self.req("POST", "/api/profile", {"name": "   "})
        self.assertEqual(json.loads(out)["name"], "")

    def test_guest_name_from_env(self):
        """The default guest nickname is not hard-coded; it comes from the GUEST_NAME environment variable (.env); unset or invalid falls back to "访客"."""
        from api import profile
        self.assertEqual(profile.guest_name({}), "访客")
        self.assertEqual(profile.guest_name({"GUEST_NAME": "  Alex "}), "Alex")
        self.assertEqual(profile.guest_name({"GUEST_NAME": "   "}), "访客")
        self.assertEqual(profile.guest_name({"GUEST_NAME": "a\nb"}), "访客")
        self.assertEqual(profile.guest_name({"GUEST_NAME": "x" * 21}), "访客")
        with mock.patch.dict(os.environ, {"GUEST_NAME": "Alex"}):
            self.httpd.shutdown()
            self.httpd.server_close()
            self.start()
        p = json.loads(self.req("GET", "/api/profile", cookie=GUEST_COOKIE)[1])
        self.assertEqual((p["name"], p["default"]), ("Alex", "Alex"))
        # the admin reading the guest's profile also gets default (used for guest bubbles in the conversation and the profile-page hint)
        self.assertEqual(json.loads(self.req("GET", "/api/profile?account=guest")[1])["default"], "Alex")
        self.assertEqual(json.loads(self.req("GET", "/api/profile")[1])["default"], "")

    def test_bad_input(self):
        for body in ({"name": 3}, {"name": "x" * 21}, {"name": "a\nb"}, {"avatar": "不是base64!!"},
                     {"avatar": base64.b64encode(b"GIF89a....").decode()},  # not a JPEG
                     {"avatar": base64.b64encode(b"\xff\xd8\xff" + b"x" * 50000).decode()}):  # over 40KB
            r, _ = self.req("POST", "/api/profile", body)
            self.assertEqual(r.status, 400, body)
        self.assertFalse(os.path.exists(os.path.join(self.stdir, "avatar.jpg")))

    def test_auth(self):
        for m, p, b in (("GET", "/api/profile", None), ("GET", "/api/avatar", None), ("POST", "/api/profile", {"name": "x"})):
            self.assertEqual(self.req(m, p, b, cookie=None)[0].status, 401, p)
        # the guest has its own copy (profile-guest.json / avatar-guest.jpg); changing it leaves the admin's untouched
        self.assertEqual(json.loads(self.req("GET", "/api/profile", cookie=GUEST_COOKIE)[1])["name"], "访客")
        self.assertEqual(self.req("GET", "/api/avatar", cookie=GUEST_COOKIE)[0].status, 404)
        r, out = self.req("POST", "/api/profile", {"name": "访客2", "avatar": base64.b64encode(JPEG).decode()},
                          cookie=GUEST_COOKIE)
        self.assertEqual((r.status, json.loads(out)["name"]), (200, "访客2"))
        self.assertEqual(json.loads(self.req("GET", "/api/profile")[1]), {"name": "", "avatar": False, "v": 0, "default": ""})
        self.assertFalse(os.path.exists(os.path.join(self.stdir, "avatar.jpg")))
        self.assertTrue(os.path.isfile(os.path.join(self.stdir, "avatar-guest.jpg")))
        self.assertEqual(json.loads(self.req("GET", "/api/profile?account=guest")[1])["name"], "访客2")
        self.assertEqual(self.req("GET", "/api/avatar?account=guest")[1], JPEG)
        self.assertEqual(self.req("GET", "/api/profile?account=bad")[0].status, 400)


if __name__ == "__main__":
    unittest.main()
