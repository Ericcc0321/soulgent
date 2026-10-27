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

from api import server
from tests import _sig  # noqa: E402,F401  sets OUTBOX_SECRET (sending requires a signature)

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.projects = os.path.join(self.tmp.name, "projects")
        os.makedirs(self.projects)
        self.snap_path = os.path.join(self.tmp.name, "snapshot.json")
        self.now = time.time()
        self.write_snapshot(self.now, [
            {"id": "c1", "kind": "claude", "status": "idle", "since": self.now + 5,
             "transcript": "p/c1.jsonl"},
            {"id": "x1", "kind": "codex", "status": "busy", "since": self.now, "transcript": None},
            {"id": "evil", "kind": "claude", "status": "idle", "since": self.now,
             "transcript": "../../etc/passwd"},
        ])
        os.makedirs(os.path.join(self.projects, "p"))
        with open(os.path.join(self.projects, "p", "c1.jsonl"), "w") as f:
            f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "hi"},
                                "timestamp": "2026-10-19T01:00:00Z"}) + "\n")
        patcher = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap_path,
                                        projects=self.projects,
                                        state=os.path.join(self.tmp.name, "st", "state.json"))
        self.port = self.httpd.server_address[1]
        t = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        t.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def write_snapshot(self, generated, sessions):
        with open(self.snap_path, "w") as f:
            json.dump({"generatedAt": generated, "usage": {}, "zones": [], "sessions": sessions}, f)
        os.utime(self.snap_path, (time.time() + 1, time.time() + 1))

    def req(self, method, path, headers=None, body=None, auth=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        if auth and "Cookie" not in h and path not in ("/api/auth", "/api/auth/check"):
            h["Cookie"] = COOKIE
        data = None
        if body is not None:
            data = json.dumps(body)
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        raw = r.read()
        c.close()
        return r, raw

    def check(self, uri, accept="*/*", cookie=None):
        h = {"X-Forwarded-Uri": uri, "X-Forwarded-Method": "GET", "Accept": accept}
        if cookie:
            h["Cookie"] = cookie
        return self.req("GET", "/api/auth/check", h)

    def test_taskboard_whitelisted_by_snapshot_zones(self):
        with open(self.snap_path, "w") as f:
            json.dump({"generatedAt": self.now, "sessions": [], "zones": [
                {"code": "Web", "name": "WEB", "taskboard": {"mtime": 5, "truncated": False}},
                {"code": "Lab", "name": "个人", "taskboard": None}]}, f)
        os.utime(self.snap_path, (time.time() + 2, time.time() + 2))
        tb = os.path.join(self.tmp.name, "taskboards")
        os.makedirs(tb)
        for code in ("Web", "Lab"):
            with open(os.path.join(tb, code + ".md"), "w", encoding="utf-8") as f:
                f.write("# " + code + " 任务板")
        r, raw = self.req("GET", "/api/zone/Web/taskboard")
        self.assertEqual(r.status, 200)
        body = json.loads(raw)
        self.assertEqual((body["name"], body["text"], body["mtime"]), ("WEB", "# Web 任务板", 5))
        for path in ("/api/zone/Lab/taskboard", "/api/zone/XX/taskboard", "/api/zone/..%2Fsnapshot/taskboard"):
            r, _ = self.req("GET", path)
            self.assertEqual(r.status, 404, path)
        r, _ = self.req("GET", "/api/zone/Web/taskboard", auth=False)
        self.assertEqual(r.status, 401)

    def test_auth_check_public_paths(self):
        for uri in ("/login.html", "/i18n.js", "/ca.crt", "/icons/a.png", "/sw.js",
                    "/manifest.webmanifest", "/api/auth"):
            r, _ = self.check(uri)
            self.assertEqual(r.status, 200, uri)

    def test_auth_check_redirects_html_to_login(self):
        r, _ = self.check("/", accept="text/html,application/xhtml+xml")
        self.assertEqual(r.status, 302)
        self.assertEqual(r.getheader("Location"), "/login.html")

    def test_auth_check_api_without_cookie_401(self):
        r, _ = self.check("/api/snapshot")
        self.assertEqual(r.status, 401)

    def test_auth_check_valid_cookie_200(self):
        r, _ = self.check("/api/snapshot", cookie="a=b; " + COOKIE)
        self.assertEqual(r.status, 200)

    def test_legacy_key_in_url_redirects_to_fragment_without_login(self):
        for uri in ("/?key=%s&x=1" % KEY, "/?key=%s" % KEY, "/login.html?key=%s" % KEY, "/icons/a.png?key=%s" % KEY):
            with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
                r, _ = self.check(uri, accept="text/html")
            self.assertEqual(r.status, 302, uri)
            self.assertEqual(r.getheader("Location"), "/login.html#k=%s&legacy=1" % quote(KEY, safe=""), uri)
            self.assertIsNone(r.getheader("Set-Cookie"), uri)
            self.assertEqual(r.getheader("Cache-Control"), "no-store")
            self.assertEqual(r.getheader("Referrer-Policy"), "no-referrer")
            log = err.getvalue()
            self.assertIn("legacy ?key= link used account=admin", log)
            self.assertNotIn(KEY, log)
            self.assertNotIn(quote(KEY, safe=""), log)

    def test_legacy_key_fragment_is_encoded(self):
        r, _ = self.check("/?key=a%26b%23c%20d", accept="text/html")
        self.assertEqual(r.getheader("Location"), "/login.html#k=a%26b%23c%20d&legacy=1")

    def test_wrong_key_rejected(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            r, _ = self.check("/?key=nope")
        self.assertEqual(r.status, 302)  # same answer as a valid key: the GET says nothing about validity
        self.assertEqual(r.getheader("Location"), "/login.html#k=nope&legacy=1")
        self.assertIsNone(r.getheader("Set-Cookie"))
        self.assertIn("account=unknown", err.getvalue())
        self.assertNotIn("nope", err.getvalue())
        r, _ = self.check("/api/snapshot", cookie="zbs=deadbeef")
        self.assertEqual(r.status, 401)
        r, _ = self.req("POST", "/api/auth", body={"key": "nope"})
        self.assertEqual(r.status, 401)
        self.assertIsNone(r.getheader("Set-Cookie"))

    def test_post_auth_sets_cookie(self):
        r, _ = self.req("POST", "/api/auth", body={"key": KEY})
        self.assertEqual(r.status, 204)
        self.assertRegex(r.getheader("Set-Cookie"), r"^zbs=[0-9a-f]{64}; ")  # a new per-device token
        self.assertFalse(r.getheader("Set-Cookie").startswith(COOKIE))

    def test_snapshot_adds_flags_and_stale(self):
        self.write_snapshot(time.time() - 31, [
            {"id": "c1", "kind": "claude", "status": "idle", "since": time.time()},
            {"id": "old", "kind": "claude", "status": "idle", "since": time.time() - 7 * 3600},
        ])
        r, raw = self.req("GET", "/api/snapshot")
        d = json.loads(raw)
        self.assertTrue(d["stale"])
        self.assertIn("serverNow", d)
        by = {s["id"]: s for s in d["sessions"]}
        self.assertTrue(by["c1"]["unread"])
        self.assertFalse(by["c1"]["pinned"])
        self.assertFalse(by["c1"]["rest"])
        self.assertFalse(by["old"]["unread"])  # earlier than installed_at
        self.assertTrue(by["old"]["rest"])

    def test_snapshot_fresh_not_stale_and_missing_file(self):
        d = json.loads(self.req("GET", "/api/snapshot")[1])
        self.assertFalse(d["stale"])
        os.unlink(self.snap_path)
        d = json.loads(self.req("GET", "/api/snapshot")[1])
        self.assertTrue(d["stale"])
        self.assertEqual(d["sessions"], [])

    def test_seen_pin_and_seen_all(self):
        t = time.time()
        self.write_snapshot(t, [
            {"id": "c1", "kind": "claude", "status": "idle", "since": t},
            {"id": "d1", "kind": "claude", "status": "idle", "since": t},
        ])
        by = {s["id"]: s for s in json.loads(self.req("GET", "/api/snapshot")[1])["sessions"]}
        self.assertTrue(by["c1"]["unread"])
        time.sleep(0.02)
        r, raw = self.req("POST", "/api/sessions/c1/seen")
        self.assertEqual(json.loads(raw), {"ok": True})
        by = {s["id"]: s for s in json.loads(self.req("GET", "/api/snapshot")[1])["sessions"]}
        self.assertFalse(by["c1"]["unread"])
        self.assertTrue(by["d1"]["unread"])
        r, raw = self.req("POST", "/api/sessions/c1/pin", body={"pinned": True})
        self.assertEqual(json.loads(raw), {"ok": True})
        by = {s["id"]: s for s in json.loads(self.req("GET", "/api/snapshot")[1])["sessions"]}
        self.assertTrue(by["c1"]["pinned"])
        r, raw = self.req("POST", "/api/seen-all")
        self.assertEqual(json.loads(raw), {"ok": True})
        by = {s["id"]: s for s in json.loads(self.req("GET", "/api/snapshot")[1])["sessions"]}
        self.assertFalse(by["c1"]["unread"])
        self.assertFalse(by["d1"]["unread"])

    def outbox_reqs(self):
        d = os.path.join(self.tmp.name, "ob")
        out = []
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if f.endswith(".req.json"):
                with open(os.path.join(d, f)) as fh:
                    out.append(json.load(fh))
        return out

    def test_seen_pin_enqueue_mark_requests(self):
        os.makedirs(os.path.join(self.tmp.name, "ob"))
        self.httpd.app.outbox = os.path.join(self.tmp.name, "ob")
        self.req("POST", "/api/sessions/c1/seen")
        self.req("POST", "/api/sessions/c1/pin", body={"pinned": True})
        self.req("POST", "/api/seen-all")
        reqs = self.outbox_reqs()
        self.assertTrue(all(r["type"] == "mark" for r in reqs))
        seens = [r["seen"] for r in reqs if "seen" in r]
        self.assertEqual(len(seens), 2)
        self.assertEqual(sorted(seens, key=len)[0].keys(), {"c1"})
        self.assertEqual(set(sorted(seens, key=len)[1]), {"c1", "x1", "evil"})
        self.assertEqual([r["pin"] for r in reqs if "pin" in r], [{"c1": True}])

    def test_panel_in_snapshot_merges_seen_and_pins(self):
        t = time.time()
        with open(self.snap_path, "w") as f:
            json.dump({"generatedAt": t, "usage": {}, "zones": [],
                       "sessions": [{"id": "c1", "kind": "claude", "status": "idle", "since": t}],
                       "panel": {"seenAt": {"c1": t + 1}, "pinned": ["c1"]}}, f)
        os.utime(self.snap_path, (time.time() + 2, time.time() + 2))
        by = {s["id"]: s for s in json.loads(self.req("GET", "/api/snapshot")[1])["sessions"]}
        self.assertFalse(by["c1"]["unread"])
        self.assertTrue(by["c1"]["pinned"])

    def test_pin_cleared_when_busy(self):
        self.req("POST", "/api/sessions/x1/pin", body={"pinned": True})
        by = {s["id"]: s for s in json.loads(self.req("GET", "/api/snapshot")[1])["sessions"]}
        self.assertFalse(by["x1"]["pinned"])

    def test_seen_unknown_id_404(self):
        r, _ = self.req("POST", "/api/sessions/nope/seen")
        self.assertEqual(r.status, 404)

    def test_transcript_unknown_id_404_and_codex_unsupported(self):
        r, _ = self.req("GET", "/api/sessions/nope/transcript")
        self.assertEqual(r.status, 404)
        r, raw = self.req("GET", "/api/sessions/x1/transcript")
        self.assertEqual(json.loads(raw), {"supported": False})

    def test_transcript_ok(self):
        r, raw = self.req("GET", "/api/sessions/c1/transcript")
        self.assertEqual(r.status, 200)
        d = json.loads(raw)
        self.assertEqual(len(d["items"]), 1)
        self.assertIsNone(d["next"])
        r, _ = self.req("GET", "/api/sessions/c1/transcript?before=abc")
        self.assertEqual(r.status, 400)

    def test_transcript_path_cannot_escape_projects(self):
        r, _ = self.req("GET", "/api/sessions/evil/transcript")
        self.assertEqual(r.status, 404)

    def test_transcript_symlink_and_dotdot_escape(self):
        secret = os.path.join(self.tmp.name, "secret.jsonl")
        with open(secret, "w") as f:
            f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "S"},
                                "timestamp": "2026-10-19T01:00:00Z"}) + "\n")
        os.symlink(secret, os.path.join(self.projects, "link.jsonl"))
        self.write_snapshot(self.now, [
            {"id": "dd", "kind": "claude", "status": "idle", "since": 1, "transcript": "../secret.jsonl"},
            {"id": "ln", "kind": "claude", "status": "idle", "since": 1, "transcript": "link.jsonl"},
            {"id": "nul", "kind": "claude", "status": "idle", "since": 1, "transcript": "a\x00b"},
        ])
        for sid in ("dd", "ln", "nul"):
            r, _ = self.req("GET", "/api/sessions/%s/transcript" % sid)
            self.assertEqual(r.status, 404, sid)

    def test_api_requires_cookie(self):
        for m, p, b in (("GET", "/api/snapshot", None),
                        ("GET", "/api/sessions/c1/transcript", None),
                        ("POST", "/api/sessions/c1/seen", None),
                        ("POST", "/api/sessions/c1/pin", {"pinned": True}),
                        ("POST", "/api/seen-all", None),
                        ("GET", "/api/whatever", None)):
            r, _ = self.req(m, p, body=b, auth=False)
            self.assertEqual(r.status, 401, p)
        r, _ = self.req("GET", "/api/snapshot", {"Cookie": "zbs=bad"}, auth=False)
        self.assertEqual(r.status, 401)

    def raw(self, data):
        import socket
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        s.sendall(data)
        out = b""
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                out += chunk
        except socket.timeout:
            pass
        s.close()
        return out

    def test_smuggled_request_not_executed(self):
        smuggled = (b"POST /api/seen-all HTTP/1.1\r\nHost: x\r\nCookie: " + COOKIE.encode()
                    + b"\r\nContent-Length: 0\r\n\r\n")
        before = self.server_seen()
        # GET with a request body
        self.raw(b"GET /api/auth/check HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % len(smuggled)
                 + smuggled)
        # malformed POST /api/auth (Content-Length over the limit, the body is not read)
        self.raw(b"POST /api/auth HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999\r\n\r\n" + smuggled)
        self.raw(b"POST /api/auth HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n" + smuggled)
        self.raw(b"POST /api/auth HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" + smuggled)
        self.assertEqual(self.server_seen(), before)

    def server_seen(self):
        st = self.httpd.app.state
        return (dict(st._seen), set(st._pins))

    def test_public_prefix_not_fooled_by_unnormalized_path(self):
        for uri in ("/icons/../api/snapshot", "/icons/%2e%2e/x", "/login.html/../x",
                    "//login.html", "/login.html.evil", "/icons/a\\b", "/icons/%252e", "/icons/a%00"):
            r, _ = self.check(uri)
            self.assertEqual(r.status, 401, uri)

    def test_redirect_location_is_local(self):
        want = "/login.html#k=%s&legacy=1" % quote(KEY, safe="")
        for uri in ("//evil.com/x?key=%s" % KEY, "/\\evil.com?key=%s" % KEY, "/a\\b?key=%s" % KEY):
            r, _ = self.check(uri)
            self.assertEqual(r.getheader("Location"), want, uri)
        r, _ = self.check("/?key=%0d%0aSet-Cookie:%20x=1")  # CR/LF stay percent-encoded inside the fragment
        self.assertEqual(r.getheader("Location"), "/login.html#k=%0D%0ASet-Cookie%3A%20x%3D1&legacy=1")
        self.assertIsNone(r.getheader("Set-Cookie"))

    def test_wrong_key_no_cookie_and_html_goes_to_login(self):
        r, _ = self.check("/?key=nope", accept="text/html")
        self.assertEqual(r.status, 302)
        self.assertEqual(r.getheader("Location"), "/login.html#k=nope&legacy=1")
        self.assertIsNone(r.getheader("Set-Cookie"))

    def test_unknown_route_404(self):
        r, _ = self.req("GET", "/api/whatever")
        self.assertEqual(r.status, 404)


if __name__ == "__main__":
    unittest.main()
