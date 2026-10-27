"""Phone diagnostic log POST /api/diag: access gate, size limit, line-by-line writes, rotation; guests may only write error records (whitelisted fields, rate-limited)."""
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

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GKEY = "guest-key-0123456789abcdef"
GCOOKIE = "zbs=" + hmac.new(GKEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


class DiagApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        snap = os.path.join(self.tmp.name, "snapshot.json")
        with open(snap, "w") as f:
            json.dump({"generatedAt": time.time(), "usage": {}, "zones": [], "sessions": []}, f)
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=snap, projects=self.tmp.name,
                                        state=os.path.join(self.tmp.name, "st", "state.json"),
                                        guests=guests_for(KEY, GKEY, "Web-guest-demo"))
        self.port = self.httpd.server_address[1]
        self.log = os.path.join(self.tmp.name, "st", "diag.jsonl")
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def post(self, body, auth=True, raw=None, cookie=COOKIE, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict({"Content-Type": "application/json"}, **(headers or {}))
        if auth:
            h["Cookie"] = cookie
        c.request("POST", "/api/diag", body=raw if raw is not None else json.dumps(body), headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def lines(self, path=None):
        with open(path or self.log, encoding="utf-8") as f:
            return [json.loads(x) for x in f.read().splitlines()]

    def test_writes_one_line_per_event_with_session_and_server_time(self):
        before = time.time()
        st, res = self.post({"session": "abc", "events": [{"t": 1, "k": "boot", "ua": "iPhone"},
                                                          {"t": 2, "k": "focusin", "el": "textarea#reply"}]})
        self.assertEqual(st, 200)
        self.assertEqual(res, {"ok": True, "written": 2})
        rows = self.lines()
        self.assertEqual([r["k"] for r in rows], ["boot", "focusin"])
        self.assertEqual({r["session"] for r in rows}, {"abc"})
        self.assertTrue(all(r["srv"] >= before - 1 for r in rows))
        self.post({"session": "abc", "events": [{"t": 3, "k": "click"}]})
        self.assertEqual(len(self.lines()), 3)  # appended, not overwritten

    def test_non_dict_events_skipped(self):
        st, res = self.post({"session": "s", "events": [1, "x", None, {"k": "ok"}]})
        self.assertEqual((st, res["written"]), (200, 1))

    def test_unauthorized(self):
        st, _ = self.post({"session": "s", "events": [{"k": "x"}]}, auth=False)
        self.assertEqual(st, 401)
        self.assertFalse(os.path.exists(self.log))

    def test_bad_bodies(self):
        for raw in ("not json", "[]", '{"session": 1, "events": []}', '{"session": "s", "events": {}}',
                    json.dumps({"session": "x" * 65, "events": []})):
            self.assertEqual(self.post(None, raw=raw)[0], 400, raw)
        self.assertEqual(self.post(None, raw="")[0], 400)

    def test_limit_is_256kb_and_oversize_413(self):
        self.assertEqual(server.DIAG_MAX_BODY, 256 * 1024)
        with mock.patch.object(server, "DIAG_MAX_BODY", 200):
            big = {"session": "s", "events": [{"k": "x", "pad": "y" * 300}]}
            self.assertEqual(self.post(big)[0], 413)
            self.assertEqual(self.post({"session": "s", "events": [{"k": "x"}]})[0], 200)
        self.assertEqual(len(self.lines()), 1)

    def test_oversize_rejected_without_reading_body(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.putrequest("POST", "/api/diag")
        c.putheader("Cookie", COOKIE)
        c.putheader("Content-Length", str(server.DIAG_MAX_BODY + 1))
        c.endheaders()  # no request body is sent; the server should answer 413 right away
        self.assertEqual(c.getresponse().status, 413)
        c.close()

    def test_rotates_when_over_limit_keeps_one_old(self):
        with mock.patch.object(server, "DIAG_MAX_BYTES", 300):
            for i in range(3):
                self.post({"session": "s", "events": [{"k": "a%d" % i, "pad": "z" * 400}]})
        self.assertEqual([r["k"] for r in self.lines()], ["a2"])
        self.assertEqual([r["k"] for r in self.lines(self.log + ".1")], ["a1"])  # only one old copy is kept
        names = [n for n in os.listdir(os.path.dirname(self.log)) if n.startswith("diag")]
        self.assertEqual(sorted(names), ["diag.jsonl", "diag.jsonl.1"])


    # ---- guest: error records only ----
    def gpost(self, events, ip="10.0.0.5", session="e1a2b3c4"):
        return self.post({"session": session, "events": events}, cookie=GCOOKIE,
                         headers={"User-Agent": "Mozilla/5.0 (iPhone) test", "X-Forwarded-For": ip})

    def err(self, where="reader", msg="t is not a function", **kw):
        return dict({"t": 1, "k": "err", "where": where, "name": "TypeError", "msg": msg,
                     "stack": "TypeError: x\n    at f", "shell": "v1", "lang": "en", "path": "#…"}, **kw)

    def test_guest_writes_err_only_with_whitelisted_fields(self):
        st, res = self.gpost([self.err(text="聊天正文", body="正文", reply="草稿", ua="伪造", account="admin", session="x"),
                              {"t": 2, "k": "boot", "ua": "iPhone"}, {"t": 3, "k": "focusin", "el": "textarea#reply"},
                              {"t": 4, "k": "error", "msg": "诊断流的 error 不收"}, "x", None])
        self.assertEqual((st, res), (200, {"ok": True, "written": 1}))
        rows = self.lines()
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual(set(r), {"t", "k", "where", "name", "msg", "stack", "shell", "lang", "path", "ua", "account",
                                  "session", "srv"})
        self.assertEqual((r["k"], r["account"], r["ua"], r["session"]), ("err", "guest", "Mozilla/5.0 (iPhone) test", "e1a2b3c4"))

    def test_guest_fields_truncated_and_non_strings_dropped(self):
        self.gpost([self.err(msg="m" * 999, stack="s" * 5000, where="w" * 100, name={"x": 1}, t="nope")])
        r = self.lines()[0]
        self.assertEqual((len(r["msg"]), len(r["stack"]), len(r["where"])), (300, 800, 60))
        self.assertNotIn("name", r)
        self.assertNotIn("t", r)

    def test_guest_dedup_same_where_msg_within_60s(self):
        self.assertEqual(self.gpost([self.err(), self.err(), self.err(msg="another")])[1]["written"], 2)
        self.assertEqual(self.gpost([self.err()])[1]["written"], 0)  # the same message in the next batch is still within 60 seconds
        self.assertEqual(self.gpost([self.err()], ip="10.0.0.6")[1]["written"], 1)  # other sources are counted separately

    def test_guest_rate_limit_per_minute_dropped_silently(self):
        st, res = self.gpost([self.err(msg="m%d" % i) for i in range(server.GUEST_ERR_RATE + 15)])
        self.assertEqual((st, res["written"]), (200, server.GUEST_ERR_RATE))
        st, res = self.gpost([self.err(msg="late")])
        self.assertEqual((st, res["written"]), (200, 0))
        self.assertEqual(len(self.lines()), server.GUEST_ERR_RATE)

    def test_guest_limiter_window_resets(self):
        lim = server.GuestErrLimiter(rate=2)
        self.assertEqual([lim.allow("ip", k, 0) for k in "abc"], [True, True, False])
        self.assertFalse(lim.allow("ip", "a", 59))
        self.assertTrue(lim.allow("ip", "a", 60))  # a minute later: counters reset, dedup expires

    def test_guest_odd_session_id_replaced(self):
        self.gpost([self.err()], session="问你：改不改")
        self.assertEqual(self.lines()[0]["session"], "guest")

    def test_admin_still_writes_everything(self):
        self.post({"session": "abc", "events": [{"k": "boot", "ua": "iPhone", "extra": 1}]})
        self.assertEqual(self.lines()[0]["extra"], 1)
        self.assertNotIn("account", self.lines()[0])


if __name__ == "__main__":
    unittest.main()
