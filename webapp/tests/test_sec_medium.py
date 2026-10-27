"""Reproduction cases for medium-severity security findings (api side): request-id ownership, guessed previous windows, attachment cache headers, guest upload quota, login CSRF."""
import http.client
import json
import os
import sys
import threading
import time
import unittest
from unittest import mock
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import _sig  # noqa: E402
from tests import test_file_api as tfa  # noqa: E402  borrow only setUp, do not re-run its test cases
from api import server  # noqa: E402

ADMIN_COOKIE, BOUND, GUEST, GUEST_COOKIE = tfa.ADMIN_COOKIE, tfa.BOUND, tfa.GUEST, tfa.GUEST_COOKIE
RID = "d" * 32
GUESS = "0bbbbbbb-1111-4111-8111-111111111111"


class MediumApiTest(unittest.TestCase):
    setUp = tfa.FileApiTest.setUp
    _write = staticmethod(tfa.FileApiTest._write)

    def call(self, method, path, cookie=ADMIN_COOKIE, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Cookie": cookie} if cookie else {}
        h.update(headers or {})
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        try:
            js = json.loads(out) if out else None
        except ValueError:
            js = None
        return r.status, {k.lower(): v for k, v in r.getheaders()}, js

    def write_res(self, rid, obj):
        ob = os.path.join(self.tmp.name, "ob")
        os.makedirs(ob, exist_ok=True)
        with open(os.path.join(ob, rid + ".res.json"), "w") as f:
            json.dump(_sig.res(dict(obj, id=rid)), f)

    # ---- request/upload ownership: no record means denied by default (guest); guest results carry no terminal lines ----
    def test_guest_cannot_poll_unrecorded_request(self):
        self.write_res(RID, {"status": "done", "lines": ["管理员终端第一行"]})
        self.assertEqual(self.call("GET", "/api/requests/" + RID, GUEST_COOKIE)[0], 404)
        st, _, js = self.call("GET", "/api/requests/" + RID)
        self.assertEqual((st, js["lines"]), (200, ["管理员终端第一行"]))  # admin unchanged

    def test_guest_own_request_result_has_no_lines(self):
        os.makedirs(os.path.join(self.tmp.name, "ob"), exist_ok=True)
        st, _, js = self.call("POST", "/api/sessions/c1/send", GUEST_COOKIE, {"text": "hi"})
        self.assertEqual(st, 202)
        rid = js["requestId"]
        self.write_res(rid, {"status": "done", "lines": ["x"]})
        st, _, js = self.call("GET", "/api/requests/" + rid, GUEST_COOKIE)
        self.assertEqual((st, js), (200, {"status": "done"}))

    # ---- guessed previous windows (via=guess) are not exposed to guests ----
    def test_guessed_window_not_for_guest(self):
        path = os.path.join(os.path.dirname(self.c1), GUESS + ".jsonl")
        with open(path, "w") as f:
            f.write(json.dumps({"type": "user", "timestamp": "2026-10-20T01:00:00Z",
                                "message": {"role": "user", "content": "别人的旧会话"}}) + "\n")
        win = [{"sid": GUESS, "path": os.path.realpath(path), "at": 1.0, "via": "guess", "name": BOUND}]
        with mock.patch.object(server.App, "windows", lambda app, s: win):
            self.assertEqual(self.call("GET", "/api/sessions/c1/transcript?from=" + GUESS, GUEST_COOKIE)[0], 403)
            self.assertEqual(self.call("GET", "/api/sessions/c1/transcript?from=" + GUESS)[0], 200)
            self.assertEqual(self.httpd.app.guest_sids(self.httpd.app.guests["guest"]), ["c1"])

    # ---- attachment cache: permissions are re-checked on the server every time (an ETag hit returns 304, no extra transfer) ----
    def test_file_cache_revalidates(self):
        st, h, _ = self.call("GET", "/api/file?p=" + quote("/private/tmp/g/x.png", safe=""))
        self.assertEqual(st, 200)
        self.assertEqual(h["cache-control"], "private, no-cache")
        st, h2, _ = self.call("GET", "/api/file?p=" + quote("/private/tmp/g/x.png", safe=""),
                              headers={"If-None-Match": h["etag"]})
        self.assertEqual((st, h2["cache-control"]), (304, "private, no-cache"))

    # ---- guest upload: needs a bound session that is on duty; rate- and total-limited per account ----
    def upload(self, cookie=GUEST_COOKIE, size=10):
        return self.call("POST", "/api/uploads?name=a.txt", cookie, b"x" * size,
                         {"Content-Type": "application/octet-stream"})[0]

    def test_guest_upload_needs_bound_session(self):
        with mock.patch.object(server.App, "find_guest_session", lambda app, g=None: None):
            self.assertEqual(self.upload(), 403)
        self.assertEqual(self.upload(), 200)

    def test_guest_upload_rate_and_total_limits(self):
        with mock.patch.object(server, "GUEST_UPLOAD_RATE", 3):  # setUp already recorded a guest upload a.pdf
            self.assertEqual([self.upload(), self.upload(), self.upload()], [200, 200, 429])
            for _ in range(4):
                self.assertEqual(self.upload(ADMIN_COOKIE), 200)  # the admin is unlimited
        with mock.patch.object(server, "GUEST_UPLOAD_TOTAL", 25):
            self.assertEqual(self.upload(size=10), 429)  # 2x10 bytes already exist, another 10 exceeds 25

    # ---- guest uploads reserve first and settle afterwards: concurrent in-flight uploads count toward the total, rate and free disk space ----
    def reserve_many(self, n, size):
        """n threads reserve `size` bytes at once; returns [(token, why)]."""
        app = self.httpd.app
        bar = threading.Barrier(n)
        out = [None] * n

        def go(i):
            bar.wait()
            out[i] = app.upload_reserve("guest", size)

        ts = [threading.Thread(target=go, args=(i,)) for i in range(n)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        return out

    def test_concurrent_reserve_respects_total(self):
        mib = 1024 * 1024
        with mock.patch.object(server.shutil, "disk_usage", lambda p: mock.Mock(free=1 << 50)):
            res = self.reserve_many(100, 20 * mib)
        ok = [tok for tok, why in res if tok]
        self.assertEqual(len(ok), server.GUEST_UPLOAD_TOTAL // (20 * mib))  # 200 MiB / 20 MiB = 10 slots
        self.assertTrue(all(why == (429, "upload quota") for tok, why in res if not tok))
        app = self.httpd.app
        for tok in ok:
            app.upload_release(tok)
        tok, why = app.upload_reserve("guest", 20 * mib)  # the slot comes back after release
        self.assertIsNotNone(tok)
        app.upload_release(tok)

    def test_concurrent_reserve_respects_rate(self):
        with mock.patch.object(server, "GUEST_UPLOAD_RATE", 5):  # setUp already recorded a guest upload a.pdf
            res = self.reserve_many(20, 10)
        self.assertEqual(sum(1 for tok, _ in res if tok), 4)

    def test_concurrent_reserve_respects_disk_free(self):
        mib = 1024 * 1024
        with mock.patch.object(server.shutil, "disk_usage",
                               lambda p: mock.Mock(free=server.GUEST_UPLOAD_MIN_FREE + 50 * mib)):
            res = self.reserve_many(10, 20 * mib)
        self.assertEqual(sum(1 for tok, _ in res if tok), 2)
        self.assertTrue(all(why == (507, "disk full") for tok, why in res if not tok))

    def test_inflight_upload_counts_and_is_released(self):
        import socket
        with mock.patch.object(server, "GUEST_UPLOAD_TOTAL", 25):
            s = socket.create_connection(("127.0.0.1", self.port), timeout=10)
            s.sendall(b"POST /api/uploads?name=a.txt HTTP/1.1\r\nHost: x\r\nCookie: " + GUEST_COOKIE.encode() +
                      b"\r\nContent-Type: application/octet-stream\r\nContent-Length: 20\r\n\r\n" + b"x" * 5)
            deadline = time.time() + 5
            while not self.httpd.app._up_held and time.time() < deadline:
                time.sleep(0.02)
            self.assertEqual(len(self.httpd.app._up_held), 1)  # the first upload is still in progress: 20 bytes reserved
            self.assertEqual(self.upload(size=10), 429)  # 20 in flight + 10 exceeds 25
            s.close()  # disconnect midway: upload fails, reservation released
            deadline = time.time() + 5
            while self.httpd.app._up_held and time.time() < deadline:
                time.sleep(0.02)
            self.assertEqual(self.httpd.app._up_held, {})
            self.assertEqual(self.upload(size=10), 200)

    # ---- login CSRF: a legacy ?key= GET never logs in or switches identity (the #k= auto POST gets 409 instead); cross-site POST /api/auth is rejected ----
    def check(self, uri, cookie=None):
        h = {"X-Forwarded-Uri": uri, "Accept": "text/html", "X-Forwarded-For": "10.0.0.9"}
        return self.call("GET", "/api/auth/check", cookie, headers=h)

    def test_key_link_does_not_switch_logged_in_user(self):
        for cookie in (ADMIN_COOKIE, None, GUEST_COOKIE):  # other identity, logged out, same identity: never a cookie from the GET
            st, h, _ = self.check("/?key=" + quote(GUEST), cookie)
            self.assertEqual(st, 302)
            self.assertNotIn("set-cookie", h)
            self.assertEqual(h["location"], "/login.html#k=%s&legacy=1" % quote(GUEST, safe=""))

    def test_cross_site_login_post_rejected(self):
        host = "127.0.0.1:%d" % self.port
        st, h, _ = self.call("POST", "/api/auth", None, {"key": GUEST},
                             {"Origin": "https://evil.example", "Host": host})
        self.assertEqual(st, 403)
        self.assertNotIn("set-cookie", h)
        st, h, _ = self.call("POST", "/api/auth", None, {"key": GUEST}, {"Origin": "https://" + host, "Host": host})
        self.assertEqual(st, 200)
        st, _, _ = self.call("POST", "/api/auth", None, {"key": GUEST})  # no Origin (non-browser, e.g. dev_proxy): as before
        self.assertEqual(st, 200)


if __name__ == "__main__":
    unittest.main()
