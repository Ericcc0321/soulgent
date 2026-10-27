"""Golden record of the HTTP routing: for a fixed list of (method, path, account) cases, the status code and which handler ran
(handlers are stubbed to record their name and plain arguments; auth / origin / content-type / guest gates stay real).
A routing refactor must leave tests/fixtures/routes_golden.json unchanged. Regenerate only on purpose: ROUTES_GOLDEN_UPDATE=1."""
import http.client
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from api import server  # noqa: E402
from tests import test_multiguest as tm  # noqa: E402

GOLDEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "routes_golden.json")
# every handler method a route can dispatch to; all are replaced by recording stubs
STUBBED = ["_auth_check", "_auth_me", "_auth_login", "_auth_logout", "_request_status", "_context", "_agent", "_history",
           "_file", "_gsearch", "_transcript", "_upload", "_diag", "_mute", "_top", "_profile_get", "_profile_post", "_wake",
           "_send_request", "_unseen", "_rest", "_offduty", "_guest_send", "_presence_post", "_device_delete", "_sub_reply"]
SID = tm.Y  # the session bound to the first guest
OTHER = tm.A
ACCOUNTS = ["admin", "guest", "guest2", "none"]

GET_PATHS = [
    "/api/auth/check", "/api/auth/me", "/api/snapshot", "/api/push/key", "/api/push/devices",
    "/api/profile", "/api/profile?account=gb", "/api/profile?account=nobody", "/api/avatar", "/api/avatar?account=guest",
    "/api/requests/r1", "/api/requests/r1/x", "/api/requests/",
    "/api/session/%s/context" % SID, "/api/session/%s/context" % OTHER, "/api/session/%s/context/x" % SID,
    "/api/session/%s/agent/a1" % SID, "/api/session/%s/agent/a1" % OTHER, "/api/session/%s/agent/a%%201" % SID,
    "/api/session/%s/search?q=hi" % SID, "/api/session/%s/lineage" % SID, "/api/session/%s/lineage" % OTHER,
    "/api/session/%s/other" % SID,
    "/api/file?p=/x", "/api/file", "/api/filex",
    "/api/search?q=a", "/api/search",
    "/api/zone/Web/taskboard", "/api/zone/bad%20zone/taskboard",
    "/api/sessions/%s/transcript" % SID, "/api/sessions/%s/transcript?n=5" % OTHER, "/api/sessions/%s/pin" % SID,
    "/api/offduty/%s/transcript" % SID, "/api/offduty/%s/wake" % SID,
    "/lab", "/lab/x", "/", "/api", "/api/nothing", "/index.html",
]
# (path, body, headers); body None = no body. Content type is application/json when a body is given (unless overridden)
POST_CASES = [
    ("/api/auth", {"key": "x"}, {}), ("/api/auth/logout", None, {}),
    ("/api/seen-all", {}, {}), ("/api/push/subscribe", {}, {}), ("/api/presence", {"dev": "devAAAA11112222", "act": 0}, {}),
    ("/api/presence", {"dev": "devAAAA11112222", "act": 0}, {"Content-Type": "text/plain"}),
    ("/api/push/devices/delete", {}, {}), ("/api/push/test", {}, {}),
    ("/api/sessions/%s/mute" % SID, {"muted": True}, {}), ("/api/sessions/%s/top" % SID, {"top": True}, {}),
    ("/api/profile", {"nickname": "n"}, {}),
    ("/api/offduty/%s/wake" % SID, {}, {}), ("/api/offduty/%s/transcript" % SID, {}, {}),
    ("/api/sessions/%s/send" % SID, {"text": "hi"}, {}), ("/api/sessions/%s/send" % OTHER, {"text": "hi"}, {}),
    ("/api/sessions/%s/screen" % SID, {}, {}),
    ("/api/sessions/%s/unseen" % SID, {}, {}), ("/api/sessions/%s/rest" % SID, {}, {}), ("/api/sessions/%s/offduty" % SID, {}, {}),
    ("/api/sessions/%s/seen" % SID, {}, {}), ("/api/sessions/nosuch/seen", {}, {}),
    ("/api/sessions/%s/pin" % SID, {"pinned": True}, {}), ("/api/sessions/%s/pin" % SID, {"pinned": "yes"}, {}),
    ("/api/sessions/nosuch/pin", {"pinned": True}, {}),
    ("/api/sessions/%s/transcript" % SID, {}, {}), ("/api/sessions/%s/upload?name=a.txt" % SID, b"hello", {}),
    ("/api/uploads?name=a.txt", b"hello", {}), ("/api/diag", b'{"lines":[]}', {}),
    ("/api/seen-all", {}, {"Origin": "https://evil.example"}), ("/api/auth", {"key": "x"}, {"Origin": "null"}),
    ("/api/sessions/%s/upload?name=a.txt" % SID, b"hello", {"Origin": "https://evil.example"}),
    ("/api/seen-all", {}, {"Content-Type": "text/plain"}), ("/api/sessions/%s/send" % SID, {"text": "hi"}, {"Content-Type": "text/plain"}),
    ("/api/nothing", {}, {}), ("/lab", {}, {}), ("/api/sessions/%s/bogus" % SID, {}, {}), ("/api/requests/r1", {}, {}),
    ("/api/file", {}, {}), ("/api/search", {}, {}),
]


def build_cases():
    cases = []
    for p in GET_PATHS:
        for a in ACCOUNTS:
            cases.append(("GET", p, a, None, {}))
    for p, b, h in POST_CASES:
        for a in ACCOUNTS:
            cases.append(("POST", p, a, b, h))
    return cases


def _plain(v):
    return v if isinstance(v, (str, int, float, bool, type(None))) else "<%s>" % type(v).__name__


class RoutesGoldenTest(tm.Base):
    def setUp(self):
        super().setUp()
        self.calls = []
        for name in STUBBED:
            p = mock.patch.object(server.Handler, name, self._stub(name))
            p.start()
            self.addCleanup(p.stop)

    def _stub(self, name):
        calls = self.calls

        def stub(handler, *args, **kw):
            calls.append([name] + [_plain(a) for a in args] + ["%s=%s" % (k, _plain(v)) for k, v in sorted(kw.items())])
            handler._send(200, b'{"stub":true}', headers={"Content-Type": "application/json"})
        return stub

    def run_case(self, method, path, acct, body, headers):
        ck = {"admin": tm.cookie(tm.KEY), "guest": tm.cookie(tm.YKEY), "guest2": tm.cookie(tm.ZKEY), "none": None}[acct]
        h = {"Host": "127.0.0.1:%d" % self.port}
        if ck:
            h["Cookie"] = ck
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        h.update(headers)
        del self.calls[:]
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        r.read()
        c.close()
        return {"status": r.status, "handlers": [list(x) for x in self.calls]}

    def test_golden(self):
        got = {}
        for method, path, acct, body, headers in build_cases():
            key = "%s %s [%s]%s%s" % (method, path, acct, (" " + json.dumps(headers, sort_keys=True)) if headers else "",
                                      (" body=" + body.decode() if isinstance(body, bytes) else " body=" + json.dumps(body, sort_keys=True))
                                      if body is not None and method == "POST" else "")
            self.assertNotIn(key, got, key)
            got[key] = self.run_case(method, path, acct, body, headers)
        if os.environ.get("ROUTES_GOLDEN_UPDATE") == "1":
            os.makedirs(os.path.dirname(GOLDEN), exist_ok=True)
            with open(GOLDEN, "w", encoding="utf-8") as f:
                json.dump(got, f, ensure_ascii=False, indent=1, sort_keys=True)
                f.write("\n")
        with open(GOLDEN, encoding="utf-8") as f:
            want = json.load(f)
        self.assertEqual(sorted(got), sorted(want))
        for k in sorted(want):
            self.assertEqual(got[k], want[k], k)
        self.assertGreaterEqual(len(want), 80)


if __name__ == "__main__":
    unittest.main()
