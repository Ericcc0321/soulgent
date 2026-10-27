import hashlib
import hmac
import http.client
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import push, server

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


def sub(n, **kw):
    d = {"endpoint": "https://fcm.googleapis.com/%s" % n, "keys": {"p256dh": "P" + n, "auth": "A" + n}}
    d.update(kw)
    return d


class PushApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        snap = os.path.join(t, "snapshot.json")
        with open(snap, "w") as f:
            json.dump({"generatedAt": time.time(), "sessions": []}, f)
        env = mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUBKEY", "VAPID_PRIVATE_KEY": "PRIV",
                                           "VAPID_SUBJECT": "mailto:x@example.com"})
        env.start()
        self.addCleanup(env.stop)
        lg = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        lg.start()
        self.addCleanup(lg.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=snap, projects=t,
                                        state=os.path.join(t, "st", "state.json"),
                                        outbox_dir=os.path.join(t, "ob"))
        self.calls = []
        self.codes = {}
        self.got_recall = threading.Event()

        def sender(s, payload, priv, subject):
            self.calls.append((s["endpoint"], payload, priv, subject))
            if payload["kind"] == "recall":
                self.got_recall.set()
            return self.codes.get(s["endpoint"], 201)

        self.httpd.app.push.sender = sender
        self.httpd.app.push.recall_delay = 0.05
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.store = os.path.join(t, "st", "push.json")

    def req(self, method, path, body=None, auth=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request(method, path, body=json.dumps(body) if body is not None else None,
                  headers=dict({"Cookie": COOKIE} if auth else {}, **{"Content-Type": "application/json"}))
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def stored(self):
        with open(self.store) as f:
            return json.load(f)["subscriptions"]

    def test_key(self):
        self.assertEqual(self.req("GET", "/api/push/key"), (200, {"key": "PUBKEY"}))

    def test_key_unconfigured_503(self):
        with mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": ""}):
            self.assertEqual(self.req("GET", "/api/push/key")[0], 503)
            self.assertEqual(self.req("POST", "/api/push/test")[0], 503)

    def test_needs_auth(self):
        self.assertEqual(self.req("GET", "/api/push/key", auth=False)[0], 401)
        self.assertEqual(self.req("POST", "/api/push/subscribe", sub("1"), auth=False)[0], 401)
        self.assertEqual(self.req("POST", "/api/push/test", auth=False)[0], 401)
        self.assertFalse(os.path.exists(self.store))

    def test_subscribe_dedupes_by_endpoint_and_strips_extras(self):
        self.assertEqual(self.req("POST", "/api/push/subscribe", sub("1", expirationTime=None))[0], 200)
        self.assertEqual(self.req("POST", "/api/push/subscribe", sub("2"))[0], 200)
        newer = sub("1")
        newer["keys"]["auth"] = "NEW"
        self.assertEqual(self.req("POST", "/api/push/subscribe", newer)[0], 200)
        subs = self.stored()
        self.assertEqual(sorted(s["endpoint"] for s in subs),
                         ["https://fcm.googleapis.com/1", "https://fcm.googleapis.com/2"])
        self.assertEqual([s["keys"]["auth"] for s in subs if s["endpoint"].endswith("/1")], ["NEW"])
        # the only extra stored fields are the account, registration time and login-key fingerprint (old subscriptions become invalid after a key change)
        self.assertTrue(all(set(s) == {"endpoint", "keys", "account", "at", "fp"} for s in subs))
        self.assertTrue(all(s["account"] == "admin" for s in subs))

    def test_subscribe_rejects_bad(self):
        for body in ({}, {"endpoint": "http://x/1", "keys": {"p256dh": "a", "auth": "b"}},
                     {"endpoint": "https://x/1"}, {"endpoint": "https://x/1", "keys": {"p256dh": "a"}},
                     {"endpoint": 5, "keys": {}}):
            self.assertEqual(self.req("POST", "/api/push/subscribe", body)[0], 400, body)
        self.assertFalse(os.path.exists(self.store))

    def test_subscribe_limit(self):
        for i in range(push.MAX_SUBS):
            self.assertEqual(self.req("POST", "/api/push/subscribe", sub(str(i)))[0], 200)
        self.assertEqual(self.req("POST", "/api/push/subscribe", sub("x"))[0], 409)
        self.assertEqual(self.req("POST", "/api/push/subscribe", sub("3"))[0], 200)  # an existing one can be updated

    def test_test_sends_show_only_no_recall(self):
        self.req("POST", "/api/push/subscribe", sub("1"))
        self.req("POST", "/api/push/subscribe", sub("2"))
        r, d = self.req("POST", "/api/push/test")
        self.assertEqual(r, 200)
        self.assertEqual((d["subscriptions"], d["sent"], d["failed"], d["removed"]), (2, 2, 0, 0))
        self.assertNotIn("recallInSec", d)
        shows = [c for c in self.calls if c[1]["kind"] == "show"]
        self.assertEqual(len(shows), 2)
        self.assertEqual(shows[0][1], {"kind": "show", "tag": "zbs-test", "title": "Soulgent 测试",
                                       "body": "这是一条测试通知", "url": "/"})  # old subscriptions have no language: Simplified Chinese; internal fields are not sent out
        self.assertEqual((shows[0][2], shows[0][3]), ("PRIV", "mailto:x@example.com"))
        self.assertFalse(self.got_recall.wait(0.4))  # no follow-up "handled" recall is sent
        self.assertEqual([c for c in self.calls if c[1]["kind"] == "recall"], [])

    def test_subscribe_lang_stored_and_test_push_follows(self):
        """A lang (en/hans/hant) in the subscribe request body is stored with the subscription and the test push uses it for its text; unknown values are not stored."""
        self.assertEqual(self.req("POST", "/api/push/subscribe", sub("1", lang="en"))[0], 200)
        self.assertEqual(self.req("POST", "/api/push/subscribe", sub("2", lang="xx"))[0], 200)
        self.assertEqual({s["endpoint"][-1]: s.get("lang") for s in self.stored()}, {"1": "en", "2": None})
        self.req("POST", "/api/push/test")
        self.assertEqual({c[0][-1]: c[1]["title"] for c in self.calls}, {"1": "Soulgent test", "2": "Soulgent 测试"})

    def test_test_title_is_soulgent(self):
        self.assertNotIn("值班室", push.TEST_SHOW["title"])
        self.assertIn("Soulgent", push.TEST_SHOW["title"])

    def test_gone_subscriptions_removed(self):
        for n in "123":
            self.req("POST", "/api/push/subscribe", sub(n))
        self.codes = {"https://fcm.googleapis.com/1": 410, "https://fcm.googleapis.com/2": 404,
                      "https://fcm.googleapis.com/3": 500}
        r, d = self.req("POST", "/api/push/test")
        self.assertEqual((d["subscriptions"], d["sent"], d["failed"], d["removed"]), (3, 0, 3, 2))
        self.assertEqual([s["endpoint"] for s in self.stored()], ["https://fcm.googleapis.com/3"])

    def test_no_subscriptions_no_recall(self):
        r, d = self.req("POST", "/api/push/test")
        self.assertEqual((r, d), (200, {"subscriptions": 0, "sent": 0, "failed": 0, "removed": 0}))
        time.sleep(0.2)
        self.assertEqual(self.calls, [])


class WebpushWrapperTest(unittest.TestCase):
    """How _webpush calls pywebpush (pywebpush is replaced by a fake module, so it need not be installed)."""

    def fake_module(self, webpush):
        class WebPushException(Exception):
            def __init__(self, msg, response=None):
                super().__init__(msg)
                self.response = response
        mod = mock.MagicMock()
        mod.WebPushException = WebPushException
        mod.webpush = webpush
        return mod

    def test_call_args_and_status(self):
        seen = {}

        def webpush(info, data, **kw):
            seen.update(info=info, data=data, kw=kw)
            return mock.Mock(status_code=201)
        with mock.patch.dict(sys.modules, {"pywebpush": self.fake_module(webpush)}):
            code = push._webpush(sub("1"), {"kind": "recall", "tag": "t"}, "PRIV", "mailto:a@b.c")
        self.assertEqual(code, 201)
        self.assertEqual(json.loads(seen["data"]), {"kind": "recall", "tag": "t"})
        self.assertEqual(seen["kw"]["ttl"], 60)
        self.assertEqual(seen["kw"]["headers"], {"Urgency": "high"})
        self.assertEqual(seen["kw"]["vapid_private_key"], "PRIV")
        self.assertEqual(seen["kw"]["vapid_claims"], {"sub": "mailto:a@b.c"})

    def test_exception_status(self):
        mod = self.fake_module(None)

        def boom(*a, **k):
            raise mod.WebPushException("gone", response=mock.Mock(status_code=410))

        def boom2(*a, **k):
            raise OSError("net")
        with mock.patch.dict(sys.modules, {"pywebpush": mod}):
            mod.webpush = boom
            self.assertEqual(push._webpush(sub("1"), {}, "k", "s"), 410)
            mod.webpush = boom2
            self.assertEqual(push._webpush(sub("1"), {}, "k", "s"), 0)


class SubjectDefaultTest(unittest.TestCase):
    def test_push_subject_env_or_placeholder(self):
        # without VAPID_SUBJECT a placeholder address is used, never a real one
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("VAPID_SUBJECT", None)
            self.assertEqual(push.Push._subject(), "mailto:admin@example.com")
            os.environ["VAPID_SUBJECT"] = "mailto:ops@demo.invalid"
            self.assertEqual(push.Push._subject(), "mailto:ops@demo.invalid")


class GenVapidTest(unittest.TestCase):
    SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "gen_vapid.py")

    def run_tool(self, path, subject="mailto:ops@demo.invalid"):
        # VAPID_SUBJECT comes from the environment (gen_vapid does not hard-code an address); subject=None = unset, falls back to the placeholder default
        env = {k: v for k, v in os.environ.items() if k != "VAPID_SUBJECT"}
        if subject is not None:
            env["VAPID_SUBJECT"] = subject
        return subprocess.run([sys.executable, self.SCRIPT, path], capture_output=True, text=True, env=env)

    def test_subject_default_placeholder(self):
        try:
            import cryptography  # noqa: F401
        except ImportError:
            self.skipTest("cryptography not installed")
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, ".env")
            r = self.run_tool(p, subject=None)
            self.assertEqual(r.returncode, 0)
            kv = dict(l.split("=", 1) for l in open(p).read().splitlines())
            self.assertEqual(kv["VAPID_SUBJECT"], "mailto:admin@example.com")

    def test_adds_once_and_never_prints_keys(self):
        try:
            import cryptography  # noqa: F401
        except ImportError:
            self.skipTest("cryptography not installed")
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, ".env")
            with open(p, "w") as f:
                f.write("WEBAPP_KEY=abc")  # no trailing newline
            r = self.run_tool(p)
            self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, "added", ""))
            text = open(p).read()
            kv = dict(l.split("=", 1) for l in text.splitlines())
            self.assertEqual(kv["WEBAPP_KEY"], "abc")
            self.assertEqual(kv["VAPID_SUBJECT"], "mailto:ops@demo.invalid")
            self.assertEqual(len(kv["VAPID_PUBLIC_KEY"]), 87)  # 65 bytes, base64url without padding
            self.assertTrue(kv["VAPID_PUBLIC_KEY"].startswith("B"))
            self.assertNotIn(kv["VAPID_PRIVATE_KEY"], r.stdout + r.stderr)
            self.assertNotIn(kv["VAPID_PUBLIC_KEY"], r.stdout + r.stderr)
            r2 = self.run_tool(p)
            self.assertEqual(r2.stdout.strip(), "already present")
            self.assertEqual(open(p).read(), text)


if __name__ == "__main__":
    unittest.main()
