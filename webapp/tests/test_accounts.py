"""Multi-account (admin / guest) gating, a full-route walk of the guest allowlist, guest snapshot/send/push, login rate limiting and cookie forgery."""
import hashlib
import hmac
import http.client
import io
import json
import os
import re
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.parse import quote

from api import server
from tests._guests import guests_for  # noqa: E402
from tests import _sig  # noqa: E402,F401  sets OUTBOX_SECRET (sending requires a signature)

KEY = "admin-key-0123456789abcdef"
GUEST = "guest-key-0123456789abcdef"
ADMIN_COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GUEST_COOKIE = "zbs=" + hmac.new(GUEST.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
BOUND = "Web-guest-demo"
SERVER_SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "api", "server.py")

# One example per /api route of the panel (method, path, body, whether guest is allowed); c1 is the session bound to guest, c2 is not.
# test_route_table_covers_server reminds you to add new routes; guest is denied by default (allowlist)
ROUTES = [
    ("GET", "/api/snapshot", None, True),
    ("GET", "/api/push/key", None, True),
    ("GET", "/api/push/devices", None, True),  # only returns this account's sanitized device list
    ("GET", "/api/auth/devices", None, True),  # own signed-in devices (login tokens), details in test_devices
    ("POST", "/api/auth/devices/revoke", {"id": "000000000000"}, True),  # signs out only an own device (another's id gives 404)
    ("GET", "/api/requests/abc", None, True),
    ("GET", "/api/zone/Web/taskboard", None, False),
    ("GET", "/api/session/c1/context", None, True),  # the bound session's context panel, sub-agent page, in-session search and previous-window chain are open to guests
    ("GET", "/api/session/c2/context", None, False),
    ("GET", "/api/session/c1/agent/abcdef12", None, True),
    ("GET", "/api/session/c2/agent/abcdef12", None, False),
    ("GET", "/api/session/c1/search?q=a", None, True),
    ("GET", "/api/session/c2/search?q=a", None, False),
    ("GET", "/api/session/c1/lineage", None, True),
    ("GET", "/api/session/c2/lineage", None, False),
    ("GET", "/api/search?q=ab", None, False),  # global search outside the session (403 for guests)
    ("GET", "/api/file?sid=c1&ref=0:1", None, True),  # bubble attachments: guests may only fetch the bound session's inline images / uploads tok / m. tok of files from the bound session's agent replies (details in test_file_api)
    ("GET", "/api/sessions/c1/transcript?from=8bbbbbbb-2222-4222-8222-222222222222", None, False),
    ("GET", "/api/sessions/c1/transcript", None, True),
    ("GET", "/api/sessions/c2/transcript", None, False),
    ("GET", "/api/offduty/c1/transcript", None, False),
    ("GET", "/api/nonexistent", None, False),
    ("POST", "/api/seen-all", {}, False),
    ("POST", "/api/push/subscribe", {"endpoint": "https://web.push.apple.com/x", "keys": {"p256dh": "a", "auth": "b"}}, True),
    ("POST", "/api/push/test", {}, False),
    ("POST", "/api/presence", {"dev": "devAAAA11112222", "act": 0}, True),  # in-use beacon sent when switching away; only affects this account
    ("POST", "/api/push/devices/delete", {"key": "0123456789abcdef"}, True),  # only deletes this account's (no match gives 404)
    ("POST", "/api/offduty/c1/wake", {}, False),
    ("POST", "/api/sessions/c1/send", {"text": "hi"}, True),
    ("POST", "/api/sessions/c2/send", {"text": "hi"}, False),
    ("POST", "/api/sessions/c1/send", {"steps": [{"key": "1"}]}, False),
    ("POST", "/api/sessions/c1/send", {"key": "esc"}, False),
    ("POST", "/api/sessions/c1/send", {"recall": "[Guest] x"}, True),  # guest recalls their own (not queued -> 409, nothing queued)
    ("POST", "/api/sessions/c1/send", {"recall": "x"}, False),  # text without [Guest] is admin's
    ("POST", "/api/sessions/c1/screen", {}, False),
    ("POST", "/api/sessions/c1/seen", {}, False),
    ("POST", "/api/sessions/c1/pin", {"pinned": True}, False),
    ("POST", "/api/sessions/c1/unseen", {}, False),
    ("POST", "/api/sessions/c1/rest", {"on": True}, False),
    ("POST", "/api/sessions/c1/mute", {"on": True}, False),
    ("POST", "/api/sessions/c1/top", {"on": True}, False),  # pin permanently
    ("GET", "/api/profile", None, True),  # my nickname and avatar; the guest has their own copy (profile-guest.json)
    ("GET", "/api/avatar", None, True),
    ("POST", "/api/profile", {"name": "x"}, True),
    ("POST", "/api/sessions/c1/offduty", {}, False),
    ("POST", "/api/sessions/c1/upload?name=a.png", "RAW", False),
    ("POST", "/api/uploads?name=a.png", "RAW", True),
    ("POST", "/api/diag", {"session": "s", "events": [{"t": 1}]}, True),  # guests only accept k:"err"; this one is not, so it is allowed but not written to disk
    ("POST", "/api/nonexistent", {}, False),
]


class AccountsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        projects = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(projects, "p"))
        for c in ("c1", "c2"):
            with open(os.path.join(projects, "p", c + ".jsonl"), "w") as f:
                f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "hi " + c},
                                    "timestamp": "2026-10-19T01:00:00Z"}) + "\n")
        self.snap = os.path.join(self.tmp.name, "snapshot.json")
        self.write_snap()
        self.outbox = os.path.join(self.tmp.name, "outbox")
        self.uploads = os.path.join(self.tmp.name, "uploads")
        os.makedirs(self.outbox)
        os.makedirs(self.uploads)
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap, projects=projects,
                                        state=os.path.join(self.tmp.name, "st", "state.json"),
                                        outbox_dir=self.outbox, uploads_dir=self.uploads, guests=guests_for(KEY, GUEST, BOUND), admin_only=("/docs",))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def write_snap(self, bound=True):
        now = time.time()
        sessions = [{"id": "c2", "kind": "claude", "name": "Web-ui-demo", "plate": "UI-refactor", "zone": "Web",
                     "status": "idle", "since": now, "transcript": "p/c2.jsonl", "cwd": "/x", "summary": "别的",
                     "agents": 7}]
        if bound:
            sessions.insert(0, {"id": "c1", "kind": "claude", "name": BOUND, "plate": "guest-demo", "zone": "Web",
                                "project": "Guest-collab", "cwd": "/Users/x/Guest", "status": "idle", "since": now,
                                "summary": "在做需求", "waitingFor": "", "pet": "p1", "origin": "peer",
                                "peer": "Web-ui-demo", "transcript": "p/c1.jsonl",
                                "model": "claude-fable-5-1", "meta": {"model": "Opus", "ctxPct": 30}, "agents": 2,
                                "summaryCode": "tool.edit", "summaryArgs": {"file": "a.py"}, "nameUntitled": False,  # number of running sub-agents
                                "bgTasks": 2, "bgAgents": 1, "bgSince": 1700000000.5, "bgStale": False,
                                "bgEndedAt": None, "bgOwned": True,
                                "bgList": [{"kind": "cmd", "desc": "跑测试", "since": 1700000000.5, "id": "b1", "toolUseId": "tu1"}],
                                "errorKind": "api", "errorStatus": 529, "errorText": "API Error: 529", "errorSince": 1700000001.5,
                                "retryAttempt": 2, "retryMax": 10, "disconnected": True, "disconnectedSince": 1700000002,
                                "compactedAt": None, "helpers": 3})
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": now, "usage": {"fiveHour": {"pct": 1}}, "monitor": {"cpu": 1},
                       "orcaStats": {"x": 1}, "zoneTokens": {"byZone": {}}, "orca": {"running": True},
                       "panel": {"seenAt": {}, "pinned": []},
                       "zones": [{"code": "Web", "name": "WEB", "color": "#40B0A0", "order": 2, "lead": "Web-ui-demo",
                                  "taskboard": {"mtime": 1}, "short": "FE", "fx": "circuit"},
                                 {"code": "Lab", "name": "个人", "color": "#A070D0", "order": 4, "lead": None,
                                  "short": None, "fx": None}],
                       "sessions": sessions,
                       "offduty": [{"sid": "c1", "name": "c1", "transcript": "p/c1.jsonl"}]}, f)
        os.utime(self.snap, (now + len(sessions), now + len(sessions)))  # the snapshot is only re-read when mtime changes

    def req(self, method, path, headers=None, body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        data = None
        if body == "RAW":
            data = b"\x89PNG fake"
            h["Content-Type"] = "application/octet-stream"
        elif body is not None:
            data = json.dumps(body)
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        raw = r.read()
        c.close()
        return r, raw

    def check(self, uri, cookie=None, accept="*/*", ip=None):
        h = {"X-Forwarded-Uri": uri, "Accept": accept}
        if cookie:
            h["Cookie"] = cookie
        if ip:
            h["X-Forwarded-For"] = ip
        return self.req("GET", "/api/auth/check", h)

    def login(self, key, ip="10.0.0.1"):
        return self.req("POST", "/api/auth", {"X-Forwarded-For": ip}, {"key": key})

    # ---- account identification ----
    def test_login_identifies_account(self):
        r, raw = self.login(KEY)
        self.assertEqual(r.status, 204)  # admin unchanged
        admin = r.getheader("Set-Cookie").split(";")[0]
        self.assertRegex(admin, r"^zbs=[0-9a-f]{64}$")  # a per-device token, not the legacy hmac value
        self.assertNotEqual(admin, ADMIN_COOKIE)
        r, raw = self.login(GUEST)
        self.assertEqual(r.status, 200)
        self.assertEqual(json.loads(raw), {"user": "guest", "next": "/"})  # guest mode is the app itself
        guest = r.getheader("Set-Cookie").split(";")[0]
        self.assertRegex(guest, r"^zbs=[0-9a-f]{64}$")
        self.assertNotIn(guest, (admin, GUEST_COOKIE))
        for c, acc in ((admin, "admin"), (guest, "guest")):
            r, raw = self.req("GET", "/api/auth/me", {"Cookie": c})
            self.assertEqual((r.status, json.loads(raw)["account"]), (200, acc))

    def test_whoami(self):
        # both accounts get the tag (the guest message prefix; admin also needs it to recognize guest bubbles)
        # admin additionally gets the guest list (account, prefix, bound session name; no key); the guest gets its allowed slash commands (default none)
        for cookie, want in ((ADMIN_COOKIE, {"user": "admin", "account": "admin", "tag": "[Guest]",
                                             "guests": [{"account": "guest", "tag": "[Guest]", "session": BOUND}]}),
                             (GUEST_COOKIE, {"user": "guest", "account": "guest", "session": BOUND, "tag": "[Guest]",
                                            "store": "guest", "slash": []})):
            r, raw = self.req("GET", "/api/auth/me", {"Cookie": cookie})
            self.assertEqual((r.status, json.loads(raw)), (200, want))
        r, _ = self.req("GET", "/api/auth/me")
        self.assertEqual(r.status, 401)

    def test_logout_clears_cookie(self):
        r, _ = self.req("POST", "/api/auth/logout", {"Cookie": GUEST_COOKIE}, {})
        self.assertEqual(r.status, 204)
        self.assertIn("Max-Age=0", r.getheader("Set-Cookie"))

    def test_legacy_key_in_url_per_account(self):
        # Legacy ?key= links no longer log in from the GET: every account is moved to the login page fragment; the log names the account, never the key
        for k, acc in ((GUEST, "guest"), (KEY, "admin")):
            with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
                r, _ = self.check("/?key=%s&x=1" % k, accept="text/html")
            self.assertEqual((r.status, r.getheader("Location")), (302, "/login.html#k=%s&legacy=1" % quote(k, safe="")))
            self.assertIsNone(r.getheader("Set-Cookie"))
            self.assertIn("legacy ?key= link used account=%s" % acc, err.getvalue())
            self.assertNotIn(k, err.getvalue())
        # a logged-in different identity is not switched either (the login page's auto POST gets 409)
        r, _ = self.check("/?key=%s" % GUEST, cookie=ADMIN_COOKIE, accept="text/html")
        self.assertEqual(r.status, 302)
        self.assertIsNone(r.getheader("Set-Cookie"))

    def test_guest_disabled_when_no_key_or_same_as_admin(self):
        for yk in ("", KEY):
            app = server.App(KEY, self.snap, self.tmp.name, os.path.join(self.tmp.name, "s2", "state.json"),
                             guests=guests_for(KEY, yk))
            self.assertEqual(list(app.keys), ["admin"])
            self.assertIsNone(app.key_user(GUEST))

    # ---- caddy gate (forward_auth) ----
    def test_check_admin_everything_and_header(self):
        for uri in ("/", "/api/snapshot", "/pets/a.png", "/docs/", "/docs/x?y=1", "/lab/busy.html", "/lab/"):
            r, _ = self.check(uri, ADMIN_COOKIE)
            self.assertEqual(r.status, 200, uri)
            self.assertEqual(r.getheader("X-ZBS-User"), "admin", uri)

    def test_check_guest_policy(self):
        # page shell, pet images and allowlisted /api pass (whether the session is the bound one is checked again by the endpoint)
        for uri in ("/", "/index.html", "/app.js", "/logic.js", "/md.js", "/style.css", "/pets/manifest.json",
                    "/docsx", "/api/auth/me", "/api/auth/logout", "/api/snapshot", "/api/sessions/c1/transcript",
                    "/api/sessions/c1/send", "/api/push/key", "/api/push/subscribe", "/api/push/devices", "/api/uploads",
                    "/api/requests/" + "a" * 32, "/api/session/c1/search", "/api/session/c1/lineage",
                    "/api/session/c1/context", "/api/session/c1/agent/abcdef12", "/api/profile", "/api/avatar",
                    "/api/diag",  # guest error reporting (only k:"err" is accepted)
                    "/api/presence", "/api/push/devices/delete"):
            r, _ = self.check(uri, GUEST_COOKIE, accept="text/html")
            self.assertEqual(r.status, 200, uri)
            self.assertEqual(r.getheader("X-ZBS-User"), "guest", uri)
        # admin-only reverse-proxy prefixes (/docs/) are denied to guests; non-allowlisted /api gets 403; non-canonical paths get 403
        for uri in ("/docs", "/docs/", "/docs/static/a.js?v=1", "/api/zone/Web/taskboard", "/api",
                    "/api/seen-all", "/api/push/test", "/api/search", "/api/sessions/c1/mute", "/api/sessions/c1/top",
                    "/api/session/c1/agent", "/api/session/c1/foo", "/api/sessions/c1/screen", "/api/sessions/c1/upload",
                    "/api/sessions/c1/seen", "/api/offduty/c1/transcript", "/api/offduty/c1/wake",
                    "/docs/../api/snapshot", "/docs%2F..%2Fapi/snapshot", "/api/sessions/c1/../../diag",
                    # the preview page index may contain real session names; guests may not see it
                    "/lab", "/lab/", "/lab/busy.html", "/lab/busy.html?x=1", "/lab/../api/snapshot", "/lab%2Fchat.html"):
            r, _ = self.check(uri, GUEST_COOKIE, accept="text/html")
            self.assertEqual(r.status, 403, uri)
            self.assertIsNone(r.getheader("X-ZBS-User"), uri)

    def test_check_guest_unauthenticated_goes_login(self):
        r, _ = self.check("/docs/", accept="text/html")
        self.assertEqual((r.status, r.getheader("Location")), (302, "/login.html"))
        r, _ = self.check("/docs/api/x")
        self.assertEqual(r.status, 401)
        self.assertIsNone(r.getheader("X-ZBS-User"))

    def test_check_lab_needs_login(self):
        # /lab/* is not public: unauthenticated pages redirect to login, non-pages get 401
        r, _ = self.check("/lab/busy.html", accept="text/html")
        self.assertEqual((r.status, r.getheader("Location")), (302, "/login.html"))
        r, _ = self.check("/lab/busy.html")
        self.assertEqual(r.status, 401)
        self.assertIsNone(r.getheader("X-ZBS-User"))

    # ---- guest access to the panel api: allowlist ----
    def test_route_table_covers_server(self):
        """Every literal /api path and route regex in server.py must have an example in ROUTES."""
        with open(SERVER_SRC, encoding="utf-8") as f:
            src = f.read()
        literals = set(re.findall(r'"(/api/[A-Za-z0-9_/-]+)"', src))
        literals |= {getattr(server, n) for n in ("DIAG_PATH", "_PLAIN_UPLOAD")}
        exempt = {"/api/auth", "/api/auth/check", "/api/auth/me", "/api/auth/logout"}
        paths = [p.split("?")[0] for _, p, _, _ in ROUTES]
        for lit in literals - exempt:
            self.assertIn(lit, paths, "ROUTES missing %s" % lit)
        for name in re.findall(r"^(_[A-Z_]+_RE) = re\.compile", src, re.M):
            rx = getattr(server, name)
            if not rx.pattern.startswith("^/api/"):
                continue
            self.assertTrue(any(rx.match(p) for p in paths), "ROUTES missing an example for %s" % name)
        for name, rx in (("_SESSION_RE", server._SESSION_RE), ("_SEND_RE", server._SEND_RE),
                         ("_OFFDUTY_RE", server._OFFDUTY_RE)):
            verbs = re.search(r"\(([a-z|]+)\)\$$", rx.pattern).group(1).split("|")
            for v in verbs:
                self.assertTrue(any(p.endswith("/" + v) for p in paths), "%s missing /%s" % (name, v))

    def test_guest_route_whitelist(self):
        for method, path, body, allowed in ROUTES:
            r, raw = self.req(method, path, {"Cookie": GUEST_COOKIE}, body)
            if allowed:
                self.assertNotIn(r.status, (401, 403), "%s %s" % (method, path))
            else:
                self.assertEqual(r.status, 403, "%s %s %s" % (method, path, body))
                self.assertEqual(json.loads(raw), {"error": "forbidden"})
        # the outbox holds only that one text sent to the bound session; the uploads directory holds only the /api/uploads file; no diagnostics log (not an error record) and no read marker was written
        reqs = self.outbox_reqs()
        self.assertEqual([(q["sessionId"], q["type"], q["text"]) for q in reqs], [("c1", "text", "[Guest] hi")])
        self.assertEqual(len(os.listdir(self.uploads)), 1)
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "st", "diag.jsonl")))
        st = self.httpd.app.state
        self.assertEqual((st.seen_at("c1"), st.pinned("c1"), st.rest_at("c1"), st.unseen_at("c1")), (0, False, 0, 0))

    def test_admin_not_403_on_api_routes(self):
        for method, path, body, _ in ROUTES:
            r, _ = self.req(method, path, {"Cookie": ADMIN_COOKIE}, body)
            self.assertNotIn(r.status, (401, 403), "%s %s" % (method, path))

    def test_no_cookie_still_401(self):
        for method, path, body, _ in ROUTES:
            r, _ = self.req(method, path, None, body)
            self.assertEqual(r.status, 401, "%s %s" % (method, path))

    # ---- cookie forgery ----
    def test_forged_cookies_rejected(self):
        forged = [
            "zbs=" + GUEST,  # use the key itself as the cookie
            "zbs=" + KEY,
            "zbs=admin",
            "zbs=" + hmac.new(GUEST.encode(), b"zbs-v2", hashlib.sha256).hexdigest(),
            "zbs=" + hmac.new(b"guess", b"zbs-v1", hashlib.sha256).hexdigest(),
            "zbs=" + GUEST_COOKIE[4:].upper(),
            "zbs=" + GUEST_COOKIE[4:-1],
            "zbs=",
        ]
        for c in forged:
            r, _ = self.req("GET", "/api/snapshot", {"Cookie": c})
            self.assertEqual(r.status, 401, c)
            r, _ = self.check("/docs/", c)
            self.assertEqual(r.status, 401, c)
        # an X-ZBS-User header does not count either: the account depends on the cookie only (guest still gets the guest snapshot)
        r, raw = self.req("GET", "/api/snapshot", {"Cookie": GUEST_COOKIE, "X-ZBS-User": "admin"})
        self.assertEqual((r.status, sorted(json.loads(raw))), (200, sorted(server.GUEST_SNAP_FIELDS)))
        r, _ = self.req("GET", "/api/zone/Web/taskboard", {"Cookie": GUEST_COOKIE, "X-ZBS-User": "admin"})
        self.assertEqual(r.status, 403)
        r, _ = self.check("/docs/", None)
        r2, _ = self.req("GET", "/api/auth/check", {"X-Forwarded-Uri": "/docs/", "X-ZBS-User": "admin",
                                                    "X-ZBS-Proxy-Secret": "x"})
        self.assertEqual((r.status, r2.status), (401, 401))

    # ---- guest snapshot ----
    def guest(self, method, path, body=None):
        r, raw = self.req(method, path, {"Cookie": GUEST_COOKIE}, body)
        return r.status, (json.loads(raw) if raw else None)

    @mock.patch.dict(os.environ, {"GUEST_ROSTER": "all"})
    def test_guest_snapshot_whitelist(self):
        code, snap = self.guest("GET", "/api/snapshot")
        self.assertEqual(code, 200)
        self.assertEqual(set(snap), {"generatedAt", "stale", "serverNow", "sessions", "zones", "bound", "roster"})
        self.assertEqual(snap["bound"], {"name": BOUND, "online": True})
        self.assertEqual([s["id"] for s in snap["sessions"]], ["c1"])
        s = snap["sessions"][0]
        self.assertEqual(set(s), set(server.GUEST_SESSION_FIELDS) | {"unread", "pinned", "rest", "originNote", "originTag"})
        for k in ("transcript", "cwd", "peer", "project"):
            self.assertNotIn(k, s)
        self.assertEqual(s["model"], "claude-fable-5-1")  # model is allowed through: a Fable session without status-line meta still shows the flame for guests
        self.assertEqual((s["unread"], s["pinned"], s["rest"]), (False, False, False))
        self.assertEqual((s["summaryCode"], s["summaryArgs"], s["nameUntitled"]),  # guests get the three summary-code fields
                         ("tool.edit", {"file": "a.py"}, False))
        self.assertEqual((s["bgTasks"], s["bgAgents"], s["bgSince"], s["bgStale"], s["bgEndedAt"], s["bgOwned"]),
                         (2, 1, 1700000000.5, False, None, True))  # guests can see the 6 background-task fields
        self.assertEqual(s["bgList"], [{"kind": "cmd", "desc": "跑测试", "since": 1700000000.5, "id": "b1",
                                         "toolUseId": "tu1"}])  # guests can see the background task list
        self.assertEqual((s["errorKind"], s["errorStatus"], s["errorText"], s["errorSince"], s["retryAttempt"], s["retryMax"]),
                         ("api", 529, "API Error: 529", 1700000001.5, 2, 10))  # guests can see the error/disconnect fields
        self.assertEqual((s["disconnected"], s["disconnectedSince"], s["compactedAt"], s["helpers"]), (True, 1700000002, None, 3))
        self.assertEqual(s["agents"], 2)  # the bound session's own dispatch count; other sessions (7) do not appear
        self.assertNotIn('"agents": 7', json.dumps(snap))
        # all zones are given, but only code, name, color, order, short name and avatar effect (no lead, no task board)
        self.assertEqual(snap["zones"], [{"code": "Web", "name": "WEB", "color": "#40B0A0", "order": 2, "short": "FE", "fx": "circuit"},
                                         {"code": "Lab", "name": "个人", "color": "#A070D0", "order": 4, "short": None, "fx": None}])
        # slim roster: on-duty + off-duty session names, zone code, whether lead; no other field
        self.assertEqual(snap["roster"], [{"name": BOUND, "zone": "Web", "lead": False},
                                          {"name": "Web-ui-demo", "zone": "Web", "lead": True},
                                          {"name": "c1", "zone": None, "lead": False}])
        raw = json.dumps(snap, ensure_ascii=False)
        self.assertEqual(raw.count("Web-ui-demo"), 1)  # other sessions only appear by name in the roster
        for leak in ("别的", "p/c2.jsonl", "/x", "taskboard", "SECRET"):
            self.assertNotIn(leak, raw)
        self.assertEqual(raw.count('"pet"'), 1)  # only the bound session's own pet is included
        # not on duty: empty list + offline marker; conversation and send for the bound session both give 403
        self.write_snap(bound=False)
        code, snap = self.guest("GET", "/api/snapshot")
        self.assertEqual((code, snap["sessions"], snap["bound"], snap["zones"], snap["roster"]),
                         (200, [], {"name": BOUND, "online": False}, [], []))
        self.assertEqual(self.guest("GET", "/api/sessions/c1/transcript")[0], 403)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": "hi"})[0], 403)

    def test_guest_roster_bound_is_default(self):
        """A missing (or invalid) roster setting is treated as bound: only the guest's own bound session, no other admin session names; only all gives the full list."""
        env = {k: v for k, v in os.environ.items() if k != "GUEST_ROSTER"}
        for val in (None, "", "bogus", "BOUND", " bound "):
            e = dict(env, **({} if val is None else {"GUEST_ROSTER": val}))
            with mock.patch.dict(os.environ, e, clear=True):
                code, snap = self.guest("GET", "/api/snapshot")
                self.assertEqual(code, 200)
                self.assertEqual(snap["roster"], [{"name": BOUND, "zone": "Web", "lead": False}], val)
                raw = json.dumps(snap, ensure_ascii=False)
                self.assertNotIn("Web-ui-demo", raw)
                self.assertNotIn('"c1"', json.dumps(snap["roster"]))
        with mock.patch.dict(os.environ, dict(env, GUEST_ROSTER="all"), clear=True):
            code, snap = self.guest("GET", "/api/snapshot")
            self.assertEqual([r["name"] for r in snap["roster"]], [BOUND, "Web-ui-demo", "c1"])

    def test_guest_bound_by_name_follows_new_id(self):
        """After a session restart its id changes: it is followed by name to the new id, and the old id gets 403."""
        with open(self.snap) as f:
            d = json.load(f)
        d["sessions"][0]["id"] = "c1new"
        with open(self.snap, "w") as f:
            json.dump(d, f)
        os.utime(self.snap, (time.time() + 9, time.time() + 9))
        code, snap = self.guest("GET", "/api/snapshot")
        self.assertEqual([s["id"] for s in snap["sessions"]], ["c1new"])
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": "x"})[0], 403)
        self.assertEqual(self.guest("POST", "/api/sessions/c1new/send", {"text": "x"})[0], 202)

    def test_guest_short_name_matches_zone_plate(self):
        app = self.httpd.app
        with open(self.snap) as f:
            d = json.load(f)
        d["sessions"][0]["name"] = "guest-demo"  # in case the snapshot only gives the short name
        with open(self.snap, "w") as f:
            json.dump(d, f)
        os.utime(self.snap, (time.time() + 9, time.time() + 9))
        self.assertEqual(app.guest_bound_id(), "c1")

    def test_guest_transcript(self):
        code, page = self.guest("GET", "/api/sessions/c1/transcript")
        self.assertEqual(code, 200)
        self.assertIn("hi c1", json.dumps(page, ensure_ascii=False))
        for path in ("/api/sessions/c2/transcript", "/api/offduty/c1/transcript", "/api/sessions/c1%2F..%2Fc2/transcript"):
            self.assertEqual(self.guest("GET", path)[0], 403, path)

    def test_format_warn_admin_only(self):
        # A message line with an unknown type: admin page carries formatWarn, the guest page never does
        with open(os.path.join(self.tmp.name, "projects", "p", "c1.jsonl"), "a") as f:
            f.write(json.dumps({"type": "human", "version": "9.9.9", "message": {"content": "x"}}) + "\n")
        r, raw = self.req("GET", "/api/sessions/c1/transcript", {"Cookie": ADMIN_COOKIE})
        self.assertEqual(r.status, 200)
        self.assertIn("Claude Code 9.9.9", json.loads(raw)["formatWarn"])
        code, page = self.guest("GET", "/api/sessions/c1/transcript")
        self.assertEqual(code, 200)
        self.assertIn("hi c1", json.dumps(page, ensure_ascii=False))
        self.assertNotIn("formatWarn", page)
        self.assertNotIn("formatWarnings", page)

    def test_format_warnings_never_in_guest_snapshot(self):
        with open(self.snap) as f:
            d = json.load(f)
        d["formatWarnings"] = ["top-level reason"]
        for s in d["sessions"]:
            s["formatWarn"] = "session reason"
            s["formatWarnings"] = ["session reason"]
        with open(self.snap, "w") as f:
            json.dump(d, f)
        os.utime(self.snap, (time.time() + 9, time.time() + 9))
        self.assertNotIn("formatWarn", server.GUEST_SESSION_FIELDS)
        self.assertNotIn("formatWarnings", server.GUEST_SESSION_FIELDS)
        code, snap = self.guest("GET", "/api/snapshot")
        self.assertEqual(code, 200)
        self.assertNotIn("formatWarn", json.dumps(snap))
        # admin snapshot passes them through untouched
        r, raw = self.req("GET", "/api/snapshot", {"Cookie": ADMIN_COOKIE})
        admin = json.loads(raw)
        self.assertEqual(admin["formatWarnings"], ["top-level reason"])
        s = next(x for x in admin["sessions"] if x["id"] == "c1")
        self.assertEqual((s["formatWarn"], s["formatWarnings"]), ("session reason", ["session reason"]))

    # ---- guest send ----
    def outbox_reqs(self):
        out = []
        for n in sorted(os.listdir(self.outbox)):
            with open(os.path.join(self.outbox, n)) as f:
                out.append(json.load(f))
        return out

    def test_guest_send_prefix_and_shapes(self):
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": "  看一下\n报表 ", "enter": True})[0], 202)
        q = self.outbox_reqs()[0]
        self.assertEqual((q["type"], q["text"], q["enter"]), ("text", "[Guest] 看一下 报表", True))
        # even if the frontend wrote [Guest] itself it is added again (so it cannot be used to impersonate an unprefixed message)
        self.guest("POST", "/api/sessions/c1/send", {"text": "[Guest] x"})
        self.assertIn("[Guest] [Guest] x", [r["text"] for r in self.outbox_reqs()])
        # attachments: upload first, then send; the text gets the prefix, and [Guest] is added even with no text
        code, up = self.req("POST", "/api/uploads?name=a.png", {"Cookie": GUEST_COOKIE}, "RAW")[0].status, None
        self.assertEqual(code, 200)
        saved = os.listdir(self.uploads)[0]
        for text, want in (("看图", "[Guest] 看图"), ("", "[Guest]"), (None, "[Guest]")):
            body = {"files": [saved]}
            if text is not None:
                body["text"] = text
            self.assertEqual(self.guest("POST", "/api/sessions/c1/send", body)[0], 202, text)
            q = [r for r in self.outbox_reqs() if r["type"] == "message"]
            self.assertIn(want, [r["text"] for r in q])

    def test_guest_send_files_lang_query(self):
        """Guest send with attachments also honors ?lang= (put on the URL, the body allowlist is unchanged); the guest prefix stays first."""
        self.assertEqual(self.req("POST", "/api/uploads?name=a.png", {"Cookie": GUEST_COOKIE}, "RAW")[0].status, 200)
        saved = os.listdir(self.uploads)[0]
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send?lang=en", {"files": [saved], "text": "hi"})[0], 202)
        q = [r for r in self.outbox_reqs() if r["type"] == "message"][-1]
        self.assertEqual((q["text"], q.get("lang")), ("[Guest] hi", "en"))
        # putting lang in the request body still gives 403 (the allowlist was not widened)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"files": [saved], "lang": "en"})[0], 403)

    def test_guest_send_quote_and_no_recall(self):
        """Guests may quote-reply ([Guest] stays first) but cannot recall."""
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": "好", "quote": "demo: 原文"})[0], 202)
        q = self.outbox_reqs()[0]
        self.assertEqual((q["text"], q.get("lines")), ("[Guest] > demo: 原文\n\n好", True))
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "好"})[0], 403)  # without [Guest]: admin's text

    def queue(self, *texts, op="enqueue", sec=20):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - sec)) + ".000Z"  # recall checks the 2-minute window
        with open(os.path.join(self.tmp.name, "projects", "p", "c1.jsonl"), "a") as f:
            for t in texts:
                ln = {"type": "queue-operation", "operation": op, "timestamp": ts, "content": t}
                if op == "remove":
                    ln["reason"] = "absorbed_mid_turn"
                f.write(json.dumps(ln, ensure_ascii=False, separators=(",", ":")) + "\n")

    def set_status(self, status, sid="c1"):
        with open(self.snap) as f:
            snap = json.load(f)
        for x in snap["sessions"]:
            if x["id"] == sid:
                x["status"] = status
        with open(self.snap, "w") as f:
            json.dump(snap, f)
        os.utime(self.snap, (time.time() + 60, time.time() + 60))

    def test_guest_recall_read_answered_or_processing(self):
        """A message the guest has already read: if the session is idle it answers answered; if busy it still does not send Esc (guests must not interrupt the admin's turn) and answers processing."""
        self.queue("[Guest] 读过的")
        self.queue("[Guest] 读过的", op="remove")
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 读过的"}), (200, {"mode": "answered"}))
        self.set_status("busy")
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 读过的"}), (200, {"mode": "processing"}))
        self.assertEqual(self.outbox_reqs(), [])

    def test_guest_recall_too_old(self):
        self.queue("[Guest] 老话", sec=300)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 老话"}), (409, {"error": "too-old"}))
        self.assertEqual(self.outbox_reqs(), [])

    def test_guest_transcript_queued_counts_own_only(self):
        """The queue count a guest sees only counts their own [Guest] messages."""
        self.queue("[Guest] 一", "管理员的", "[Image #1] [Guest] 二")
        code, page = self.guest("GET", "/api/sessions/c1/transcript")
        self.assertEqual((code, page.get("queued")), (200, 2))

    def test_guest_recall_own_queued_only(self):
        """Guests can only recall their own messages (original text carries [Guest]) that are still queued; queued admin text cannot be recalled; extra fields give 403; while waiting on you it gives 409."""
        self.queue("[Guest] 访客的话", "[Guest]")
        code, body = self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 访客的话"})
        self.assertEqual(code, 202, body)
        q = self.outbox_reqs()
        self.assertEqual([(r["sessionId"], r["type"], r["text"]) for r in q], [("c1", "recall", "[Guest] 访客的话")])
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest]"})[0], 202)  # the attachment-only message
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "管理员的话"})[0], 403)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 没排队"})[0], 409)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 访客的话", "text": "x"})[0], 403)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": 3})[0], 400)
        self.assertEqual(self.guest("POST", "/api/sessions/c2/send", {"recall": "[Guest] 访客的话"})[0], 403)
        self.assertEqual(len(self.outbox_reqs()), 2)
        with open(self.snap) as f:
            snap = json.load(f)
        snap["sessions"][0]["status"] = "waiting"
        with open(self.snap, "w") as f:
            json.dump(snap, f)
        os.utime(self.snap, (time.time() + 50, time.time() + 50))
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 访客的话"})[0], 409)
        self.assertEqual(len(self.outbox_reqs()), 2)

    def test_guest_recall_with_image_prefix(self):
        """A queued attachment message reads "[Image #1] [Guest] ..." and the guest can still recall it; "[Image #1] <admin text>" still gives 403."""
        self.queue("[Image #1] [Guest] 图和字")
        code, body = self.guest("POST", "/api/sessions/c1/send", {"recall": "[Image #1] [Guest] 图和字"})
        self.assertEqual(code, 202, body)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Image #1] 管理员的话"})[0], 403)

    def test_guest_recall_blocked_by_admin_queue(self):
        """A guest cannot recall while admin messages are queued (409 admin-queued); once only the guest's own remain, it is allowed."""
        self.queue("[Guest] 访客的话", "管理员的话")
        code, body = self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 访客的话"})
        self.assertEqual(code, 409, body)
        self.assertEqual(body.get("error"), "admin-queued")
        self.assertEqual(len(self.outbox_reqs()), 0)

    def test_guest_profile_separate(self):
        """The guest's own nickname and avatar are stored in profile-guest.json / avatar-guest.jpg, independent of the admin's.
        The default nickname comes from GUEST_NAME in .env (the localized word for "guest" when unset); GET includes default for the frontend as a placeholder."""
        code, p = self.guest("GET", "/api/profile")
        self.assertEqual((code, p), (200, {"name": "访客", "avatar": False, "v": 0, "default": "访客"}))
        jpeg = b"\xff\xd8\xff\xe0" + b"y" * 100
        import base64
        code, p = self.guest("POST", "/api/profile", {"name": "小明", "avatar": base64.b64encode(jpeg).decode()})
        self.assertEqual((code, p["name"], p["avatar"]), (200, "小明", True))
        stdir = os.path.join(self.tmp.name, "st")
        self.assertTrue(os.path.isfile(os.path.join(stdir, "profile-guest.json")))
        self.assertTrue(os.path.isfile(os.path.join(stdir, "avatar-guest.jpg")))
        self.assertFalse(os.path.exists(os.path.join(stdir, "avatar.jpg")))
        r, raw = self.req("GET", "/api/avatar", {"Cookie": GUEST_COOKIE})
        self.assertEqual((r.status, raw), (200, jpeg))
        # a guest passing account=admin still only gets their own
        r, raw = self.req("GET", "/api/avatar?account=admin", {"Cookie": GUEST_COOKIE})
        self.assertEqual((r.status, raw), (200, jpeg))
        code, p = self.guest("GET", "/api/profile?account=admin")
        self.assertEqual(p["name"], "小明")
        # admin: their own is still the default (empty string); account=guest reads the guest's (used for GUEST bubbles in the conversation)
        r, raw = self.req("GET", "/api/profile", {"Cookie": ADMIN_COOKIE})
        self.assertEqual(json.loads(raw)["name"], "")
        r, raw = self.req("GET", "/api/profile?account=guest", {"Cookie": ADMIN_COOKIE})
        self.assertEqual(json.loads(raw)["name"], "小明")
        r, raw = self.req("GET", "/api/avatar?account=guest&v=1", {"Cookie": ADMIN_COOKIE})
        self.assertEqual((r.status, raw), (200, jpeg))
        self.assertEqual(self.req("GET", "/api/avatar", {"Cookie": ADMIN_COOKIE})[0].status, 404)
        # an empty nickname reverts to the guest default
        code, p = self.guest("POST", "/api/profile", {"name": "  "})
        self.assertEqual(p["name"], "访客")

    def test_guest_send_rejects_keys_steps(self):
        for body in ({"steps": [{"key": "1"}]}, {"key": "esc"}, {"key": "1"}, {"text": "hi", "enter": False},
                     {"text": "hi", "steps": [{"key": "2"}]}, {"text": "hi", "key": "enter"},
                     {"steps": [{"text": "x"}, {"key": "enter"}]}, {"text": "hi", "x": 1}):
            self.assertEqual(self.guest("POST", "/api/sessions/c1/send", body)[0], 403, body)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/screen", {})[0], 403)
        self.assertEqual(self.guest("POST", "/api/sessions/c2/send", {"text": "hi"})[0], 403)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": ""})[0], 400)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": "x" * 3999})[0], 400)  # too long once the prefix is added
        self.assertEqual(self.outbox_reqs(), [])

    def test_guest_send_blocked_while_waiting(self):
        """When the session sits at a question/approval menu, text plus Enter would answer on the admin's behalf: guest always gets 409 and nothing is queued."""
        with open(self.snap) as f:
            d = json.load(f)
        d["sessions"][0]["status"] = "waiting"
        with open(self.snap, "w") as f:
            json.dump(d, f)
        os.utime(self.snap, (time.time() + 9, time.time() + 9))
        code, body = self.guest("POST", "/api/sessions/c1/send", {"text": "hi"})
        self.assertEqual((code, body), (409, {"error": "session-waiting"}))
        self.assertEqual(self.outbox_reqs(), [])

    # ---- push per account ----
    def test_push_subscriptions_by_account(self):
        sub = lambda n: {"endpoint": "https://web.push.apple.com/" + n, "keys": {"p256dh": "a", "auth": "b"}}
        self.assertEqual(self.req("POST", "/api/push/subscribe", {"Cookie": ADMIN_COOKIE}, sub("a"))[0].status, 200)
        self.assertEqual(self.guest("POST", "/api/push/subscribe", sub("y"))[0], 200)
        stored = self.httpd.app.push.subscriptions()
        self.assertEqual({s["endpoint"][-1]: s["account"] for s in stored}, {"a": "admin", "y": "guest"})
        got = []
        self.httpd.app.push.sender = lambda s, payload, *a: got.append(s["endpoint"][-1]) or 201
        with mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUB"}):
            self.assertEqual(self.httpd.app.push.send_all({"kind": "show"}, "guest")["sent"], 1)
            self.assertEqual(got, ["y"])
            got.clear()
            self.httpd.app.push.send_all({"kind": "show"})  # defaults to admin; old subscriptions without an account also count as admin
            self.assertEqual(got, ["a"])
        # the same device subscribing again after logging in as another account: it belongs to the new account
        self.req("POST", "/api/push/subscribe", {"Cookie": ADMIN_COOKIE}, sub("y"))
        self.assertEqual({s["endpoint"][-1]: s["account"] for s in self.httpd.app.push.subscriptions()},
                         {"a": "admin", "y": "admin"})

    def test_notify_guest_only_bound_done(self):
        app = self.httpd.app
        sent = []
        app.push.send_all = lambda payload, account="admin": sent.append((account, payload)) or {}
        app.state.installed_at = 0
        t0 = time.time()

        def snap(c1, c2):
            with open(self.snap, "w") as f:
                json.dump({"generatedAt": t0 + 100, "zones": [], "sessions": [
                    dict({"id": "c1", "kind": "claude", "name": BOUND, "zone": "Web", "plate": "guest-demo"}, **c1),
                    dict({"id": "c2", "kind": "claude", "name": "Web-ui-demo", "zone": "Web"}, **c2)]}, f)
            app._cache = None  # consecutive writes in a test may share the same mtime, so clear the cache directly

        def tick(t):  # keep the snapshot time moving so the round is not skipped as stale
            with open(self.snap) as f:
                d = json.load(f)
            d["generatedAt"] = t
            with open(self.snap, "w") as f:
                json.dump(d, f)
            app._cache = None
            app.notify_round(t)

        with mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUB"}):
            snap({"status": "busy", "since": 1}, {"status": "busy", "since": 1})
            tick(t0 + 100)  # the first round is only a baseline
            # c1 waiting on you, c2 finished: guest should receive neither (waiting-on-you is not pushed; c2 is not the bound session)
            snap({"status": "waiting", "since": 2}, {"status": "idle", "since": 2})
            tick(t0 + 101)
            tick(t0 + 115)
            self.assertFalse([a for acc, a in sent if acc == "guest"])
            self.assertTrue([a for acc, a in sent if acc == "admin" and a["kind"] == "show"])
            # c1 turn started by a human finished: guest receives "done" (regardless of admin read state)
            app.state.mark_seen("c1", t0 + 999)
            snap({"status": "idle", "since": 3, "origin": "user"}, {"status": "idle", "since": 2})
            tick(t0 + 120)
            tick(t0 + 131)
            guest = [a for acc, a in sent if acc == "guest" and a["kind"] == "show"]
            self.assertEqual(len(guest), 1)
            self.assertEqual((guest[0]["ev"], guest[0]["title"]), ("done", "🔥 " + BOUND))  # title = emoji + session name (no pet: flame)
            self.assertEqual(guest[0]["tag"], "s-c1")
            # turn between sessions finished: no push
            snap({"status": "idle", "since": 4, "origin": "peer"}, {"status": "idle", "since": 2})
            tick(t0 + 140)
            tick(t0 + 151)
            self.assertEqual(len([a for acc, a in sent if acc == "guest" and a["kind"] == "show"]), 1)
            self.assertEqual([a for acc, a in sent if acc == "guest" and a["kind"] != "show"], [])  # guest never retracts

    # ---- login rate limiting ----
    def test_rate_limit_after_five_failures(self):
        for i in range(5):
            r, _ = self.login("wrong-%d" % i, ip="10.0.0.9")
            self.assertEqual(r.status, 401, i)
        r, _ = self.login("wrong-6", ip="10.0.0.9")
        self.assertEqual(r.status, 429)
        r, _ = self.login(KEY, ip="10.0.0.9")  # while locked out, even the correct key fails
        self.assertEqual(r.status, 429)
        r, _ = self.check("/?key=%s" % KEY, accept="text/html", ip="10.0.0.9")  # a legacy ?key= GET only redirects; the POST it leads to is limited
        self.assertEqual((r.status, r.getheader("Set-Cookie")), (302, None))
        r, _ = self.login(KEY, ip="10.0.0.10")  # other IPs are unaffected
        self.assertEqual(r.status, 204)

    def test_rate_limit_success_resets_and_url_key_counts(self):
        for i in range(4):
            self.login("wrong", ip="10.0.0.7")
        self.assertEqual(self.login(GUEST, ip="10.0.0.7")[0].status, 200)
        for i in range(4):
            self.assertEqual(self.login("wrong", ip="10.0.0.7")[0].status, 401)
        r, _ = self.check("/?key=bad", accept="text/html", ip="10.0.0.7")  # a legacy ?key= GET checks nothing, so it is not counted
        self.assertEqual(r.status, 302)
        self.assertEqual(self.login("wrong", ip="10.0.0.7")[0].status, 401)  # the fifth failure, counted at the POST
        self.assertEqual(self.login("wrong", ip="10.0.0.7")[0].status, 429)

    def test_limiter_window_expires(self):
        lim = server.LoginLimiter(max_fail=5, window=600)
        for i in range(5):
            lim.fail("1.2.3.4", now=1000 + i)
        self.assertTrue(lim.blocked("1.2.3.4", now=1004))
        self.assertTrue(lim.blocked("1.2.3.4", now=1599))
        self.assertFalse(lim.blocked("1.2.3.4", now=1600))
        lim.fail("1.2.3.4", now=1601)
        self.assertFalse(lim.blocked("1.2.3.4", now=1602))
        lim.ok("1.2.3.4")
        self.assertFalse(lim.blocked("1.2.3.4", now=1602))


if __name__ == "__main__":
    unittest.main()
