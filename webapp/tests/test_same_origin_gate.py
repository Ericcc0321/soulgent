"""Same-origin gate: every state-changing (POST) request is checked once before routing.
Origin present -> must match Host; else Referer present -> its scheme+host+port must match; neither -> non-browser, allowed. GET is unaffected."""
import http.client
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import test_file_api as tfa  # noqa: E402  borrow only setUp, do not re-run its test cases

ADMIN_COOKIE = tfa.ADMIN_COOKIE
EVIL = "https://evil.example"


class SameOriginGateTest(unittest.TestCase):
    setUp = tfa.FileApiTest.setUp
    _write = staticmethod(tfa.FileApiTest._write)

    def call(self, method, path, body=None, headers=None, ctype="application/json"):
        host = "127.0.0.1:%d" % self.port
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Cookie": ADMIN_COOKIE, "Host": host}
        h.update(headers or {})
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            h.setdefault("Content-Type", ctype)
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        try:
            js = json.loads(out) if out else None
        except ValueError:
            js = None
        return r.status, js

    @property
    def me(self):
        return "http://127.0.0.1:%d" % self.port

    def test_cross_site_origin_blocked_on_state_changing_endpoints(self):
        cases = [("/api/sessions/c1/send", {"text": "hi"}),
                 ("/api/sessions/c1/upload?name=a.txt", b"hello"),
                 ("/api/uploads?name=a.txt", b"hello"),
                 ("/api/presence", {"dev": "devAAAA11112222", "act": 0}),
                 ("/api/push/subscribe", {"endpoint": "https://fcm.googleapis.com/x", "keys": {"p256dh": "P", "auth": "A"}}),
                 ("/api/seen-all", {}), ("/api/auth/logout", {})]
        for path, body in cases:
            st, js = self.call("POST", path, body, {"Origin": EVIL})
            self.assertEqual((path, st), (path, 403))
            self.assertIn("error", js)

    def test_origin_null_blocked(self):
        self.assertEqual(self.call("POST", "/api/seen-all", {}, {"Origin": "null"})[0], 403)

    def test_same_origin_passes(self):
        self.assertEqual(self.call("POST", "/api/seen-all", {}, {"Origin": self.me})[0], 200)
        st, _ = self.call("POST", "/api/presence", {"dev": "devAAAA11112222", "act": 0}, {"Origin": self.me},
                          ctype="text/plain")
        self.assertNotEqual(st, 403)

    def test_referer_checked_when_origin_absent(self):
        self.assertEqual(self.call("POST", "/api/seen-all", {}, {"Referer": EVIL + "/page"})[0], 403)
        self.assertEqual(self.call("POST", "/api/seen-all", {}, {"Referer": self.me + "/s/c1?x=1"})[0], 200)
        # same host with another port is cross-origin
        self.assertEqual(self.call("POST", "/api/seen-all", {}, {"Referer": "http://127.0.0.1:1/p"})[0], 403)
        # the scheme is not compared: behind the TLS proxy the server itself only sees http while the browser says https

    def test_origin_wins_over_referer(self):
        self.assertEqual(self.call("POST", "/api/seen-all", {}, {"Origin": EVIL, "Referer": self.me + "/"})[0], 403)

    def test_neither_header_allowed(self):
        self.assertEqual(self.call("POST", "/api/seen-all", {})[0], 200)

    def test_get_unaffected(self):
        self.assertEqual(self.call("GET", "/api/auth/me", None, {"Origin": EVIL})[0], 200)
        self.assertEqual(self.call("GET", "/api/auth/me", None, {"Referer": EVIL + "/x"})[0], 200)

    # ---- JSON Content-Type is required where the body is parsed as JSON; uploads, the presence beacon, diag and bodiless POSTs are exempt ----
    def test_json_endpoints_require_json_content_type(self):
        for path in ("/api/sessions/c1/send", "/api/sessions/c1/pin", "/api/sessions/c1/mute", "/api/sessions/c1/top",
                     "/api/push/subscribe", "/api/push/test", "/api/push/devices/delete", "/api/profile", "/api/auth"):
            for ctype in ("text/plain", "application/x-www-form-urlencoded", "application/jsonx", "application/octet-stream"):
                st, js = self.call("POST", path, b'{"on": true}', ctype=ctype)
                self.assertEqual((path, ctype, st), (path, ctype, 415))
                self.assertIn("error", js)
        st, _ = self.call("POST", "/api/sessions/c1/send", b'{"text":"x"}', ctype="application/json; charset=utf-8")
        self.assertNotEqual(st, 415)
        st, _ = self.call("POST", "/api/sessions/c1/send", b'{"text":"x"}', ctype="Application/JSON")
        self.assertNotEqual(st, 415)

    def test_content_type_exemptions(self):
        st, _ = self.call("POST", "/api/presence", {"dev": "devAAAA11112222", "act": 0}, ctype="text/plain;charset=UTF-8")
        self.assertEqual(st, 200)  # sendBeacon with a string body
        st, _ = self.call("POST", "/api/diag", b'{"session":"x","events":[]}', ctype="text/plain;charset=UTF-8")
        self.assertNotEqual(st, 415)  # diag also goes out through sendBeacon
        st, _ = self.call("POST", "/api/uploads?name=a.txt", b"hello", ctype="application/octet-stream")
        self.assertEqual(st, 200)
        self.assertEqual(self.call("POST", "/api/seen-all")[0], 200)  # no body: nothing parsed, no Content-Type needed
        self.assertEqual(self.call("POST", "/api/sessions/c1/seen")[0], 200)

    def test_multipart_upload_same_origin_works(self):
        body = b"--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n\r\nhello\r\n--b--\r\n"
        st, js = self.call("POST", "/api/uploads?name=a.txt", body, {"Origin": self.me},
                           ctype="multipart/form-data; boundary=b")
        self.assertEqual(st, 200)
        self.assertIn("file", js)


if __name__ == "__main__":
    unittest.main()
