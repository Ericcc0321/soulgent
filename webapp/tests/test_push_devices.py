"""Subscriptions store device info dev / plat / standalone (whitelisted, overlong values dropped) and replace it when the same endpoint is overwritten;
Apple endpoints carry no avatar; the device list (sanitised); dead-subscription pruning rules (a method only, not run automatically)."""
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

from api import push, server

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
DAY = 86400


def SUB(n, host="fcm.googleapis.com"):
    return {"endpoint": "https://%s/%s" % (host, n), "keys": {"p256dh": "P" + n, "auth": "A" + n}}


DEV = {"dev": "abcDEF0123456789", "plat": "iphone", "standalone": True}


class DeviceStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sent = []
        self.p = push.Push(os.path.join(self.tmp.name, "push.json"),
                           sender=lambda s, payload, k, sub: self.sent.append((s["endpoint"], payload)) or 201)

    def subs(self):
        return {s["endpoint"].rsplit("/", 1)[1]: s for s in self.p.subscriptions()}

    def test_clean_device_whitelist(self):
        self.assertEqual(push.clean_device(DEV), DEV)
        self.assertEqual(push.clean_device({"dev": "x" * 41, "plat": "iphone"}), {"plat": "iphone"})  # overlong value dropped
        self.assertEqual(push.clean_device({"dev": "short", "plat": "beos", "standalone": "yes"}), {})
        self.assertEqual(push.clean_device({"dev": "abc def 0123456789"}), {})  # contains spaces
        self.assertEqual(push.clean_device({"dev": "<script>alert(1)"}), {})
        self.assertEqual(push.clean_device({"standalone": False}), {"standalone": False})
        for p in ("iphone", "ipad", "mac", "windows", "android", "other"):
            self.assertEqual(push.clean_device({"plat": p}), {"plat": p})
        self.assertEqual(push.clean_device(None), {})
        self.assertEqual(push.clean_device("x"), {})

    def test_subscribe_stores_device_and_time(self):
        self.assertTrue(self.p.subscribe(SUB("1"), "admin", "en", DEV, now=1000))
        s = self.subs()["1"]
        self.assertEqual((s["dev"], s["plat"], s["standalone"], s["at"], s["lang"]),
                         ("abcDEF0123456789", "iphone", True, 1000, "en"))

    def test_resubscribe_same_endpoint_replaces_device(self):
        self.p.subscribe(SUB("1"), "admin", "en", DEV, now=1000)
        self.p.subscribe(SUB("1"), "admin", "en", {"dev": "zzzzzzzz00000000", "plat": "mac", "standalone": False}, now=2000)
        s = self.subs()["1"]
        self.assertEqual((s["dev"], s["plat"], s["standalone"], s["at"]), ("zzzzzzzz00000000", "mac", False, 2000))
        self.p.subscribe(SUB("1"), "admin", "en", None, now=3000)  # legacy frontend re-registers: device info is cleared (the newest wins)
        self.assertNotIn("dev", self.subs()["1"])

    def test_old_subscription_without_device_still_sent(self):
        with open(self.p.path, "w") as f:
            json.dump({"subscriptions": [dict(SUB("9"), account="admin")]}, f)
        r = self.p.send_test("admin")
        self.assertEqual((r["sent"], r["subscriptions"]), (1, 1))

    def test_apple_endpoint_gets_no_avatar(self):
        self.p.subscribe(SUB("a", "web.push.apple.com"), "admin")
        self.p.subscribe(SUB("f", "fcm.googleapis.com"), "admin")
        self.p.send_all({"kind": "show", "tag": "s-x", "title": "N", "body": "b", "url": "/", "ev": "done",
                         "name": "N", "text": "b", "fb": False, "av": {"id": "x", "st": "done"}})
        got = {ep.rsplit("/", 1)[1]: pl for ep, pl in self.sent}
        self.assertNotIn("av", got["a"])
        self.assertEqual(got["f"]["av"], {"id": "x", "st": "done"})

    def test_is_apple(self):
        self.assertTrue(push.is_apple("https://web.push.apple.com/abc"))
        self.assertFalse(push.is_apple("https://fcm.googleapis.com/fcm/send/x"))
        self.assertFalse(push.is_apple("https://evil.example/web.push.apple.com"))

    def test_devices_list_is_sanitized(self):
        self.p.subscribe(SUB("1"), "admin", "en", DEV, now=1000)
        self.p.subscribe(SUB("2"), "admin", None, None, now=2000)
        self.p.subscribe(SUB("3"), push.ACCOUNTS[1], None, DEV, now=3000)
        d = self.p.devices("admin")
        self.assertEqual(d, [{"dev": "abcDEF0123456789", "plat": "iphone", "standalone": True, "at": 1000,
                              "key": push.device_key(SUB("1")["endpoint"])},
                             {"at": 2000, "key": push.device_key(SUB("2")["endpoint"])}])  # key is an opaque id used for deletion
        for x in d:
            self.assertNotIn("endpoint", x)
            self.assertNotIn("keys", x)


class PruneTest(unittest.TestCase):
    """Subscriptions that still have no device info (no dev) 14 days after rollout (the first run of the new code) are deleted; those with dev are left alone."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p = push.Push(os.path.join(self.tmp.name, "push.json"), sender=lambda *a: 201)
        with open(self.p.path, "w") as f:
            json.dump({"subscriptions": [dict(SUB("old"), account="admin"), dict(SUB("new"), account="admin", dev="abcDEF0123456789")]}, f)

    def eps(self):
        return sorted(s["endpoint"].rsplit("/", 1)[1] for s in self.p.subscriptions())

    def test_first_run_only_marks_start(self):
        self.assertEqual(self.p.prune_dead(now=1000), 0)
        self.assertEqual(self.eps(), ["new", "old"])
        with open(self.p.path) as f:
            self.assertEqual(json.load(f)["pruneSince"], 1000)  # the baseline is the first pruning run (when the wiring went live)

    def test_before_14_days_keeps(self):
        self.p.prune_dead(now=1000)
        self.assertEqual(self.p.prune_dead(now=1000 + 14 * DAY - 1), 0)
        self.assertEqual(self.eps(), ["new", "old"])

    def test_after_14_days_removes_unregistered_only(self):
        self.p.prune_dead(now=1000)
        self.assertEqual(self.p.prune_dead(now=1000 + 14 * DAY), 1)
        self.assertEqual(self.eps(), ["new"])

    def test_subscribe_marker_not_used_as_start(self):
        """The recorded devSince (the moment of the first subscription) is kept as before but is not used as the baseline; the 14 days count from when the pruning was wired up."""
        self.p.subscribe(SUB("x"), "admin", None, DEV, now=500)
        self.p.subscribe(SUB("y"), "admin", None, DEV, now=900)
        with open(self.p.path) as f:
            self.assertEqual(json.load(f)["devSince"], 500)  # not overwritten by later ones
        self.assertEqual(self.p.prune_dead(now=500 + 14 * DAY), 0)  # first run: only records pruneSince
        self.assertEqual(self.p.prune_dead(now=500 + 28 * DAY - 1), 0)
        self.assertEqual(self.p.prune_dead(now=500 + 28 * DAY), 1)
        self.assertEqual(self.eps(), ["new", "x", "y"])
        with open(self.p.path) as f:
            doc = json.load(f)
        self.assertEqual((doc["devSince"], doc["pruneSince"]), (500, 500 + 14 * DAY))  # both timestamps are retained when subscriptions are deleted

    def test_reregistered_old_survives(self):
        self.p.prune_dead(now=1000)
        self.p.subscribe(SUB("old"), "admin", "hans", DEV, now=2000)  # re-registration at startup
        self.assertEqual(self.p.prune_dead(now=1000 + 30 * DAY), 0)
        self.assertEqual(self.eps(), ["new", "old"])

    def test_not_called_by_notify_or_send(self):
        """Sending / subscribing never prunes as a side effect (only notify_round calls it, once a day)."""
        self.p.prune_dead(now=1000)
        with mock.patch("time.time", return_value=1000 + 100 * DAY):
            self.p.send_test("admin")
            self.p.subscribe(SUB("z"), "admin")
        self.assertEqual(self.eps(), ["new", "old", "z"])


class DeviceApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        snap = os.path.join(t, "snapshot.json")
        with open(snap, "w") as f:
            json.dump({"generatedAt": time.time(), "sessions": []}, f)
        env = mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUBKEY", "VAPID_PRIVATE_KEY": "PRIV"})
        env.start()
        self.addCleanup(env.stop)
        lg = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        lg.start()
        self.addCleanup(lg.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=snap, projects=t,
                                        state=os.path.join(t, "st", "state.json"), outbox_dir=os.path.join(t, "ob"))
        self.calls = []
        self.httpd.app.push.sender = lambda s, payload, priv, subject: self.calls.append((s["endpoint"], payload)) or 201
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.store = os.path.join(t, "st", "push.json")

    def req(self, method, path, body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request(method, path, body=json.dumps(body) if body is not None else None, headers={"Cookie": COOKIE, "Content-Type": "application/json"})
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def test_subscribe_with_device_echoes_dev(self):
        r, d = self.req("POST", "/api/push/subscribe", dict(SUB("1"), lang="hant", **DEV))
        self.assertEqual(r, 200)
        self.assertEqual((d["lang"], d["dev"]), ("hant", "abcDEF0123456789"))
        with open(self.store) as f:
            s = json.load(f)["subscriptions"][0]
        self.assertEqual((s["dev"], s["plat"], s["standalone"]), ("abcDEF0123456789", "iphone", True))

    def test_subscribe_bad_device_still_ok(self):
        r, d = self.req("POST", "/api/push/subscribe", dict(SUB("1"), dev="x", plat="beos"))
        self.assertEqual(r, 200)
        self.assertIsNone(d.get("dev"))

    def test_devices_endpoint(self):
        self.req("POST", "/api/push/subscribe", dict(SUB("1"), **DEV))
        self.req("POST", "/api/push/subscribe", SUB("2"))
        r, d = self.req("GET", "/api/push/devices")
        self.assertEqual(r, 200)
        self.assertEqual(len(d["devices"]), 2)
        self.assertEqual(d["devices"][0]["plat"], "iphone")
        self.assertNotIn("endpoint", json.dumps(d))

    def test_push_test_endpoint_sends_one_test(self):
        # the icon test is gone: {"icons": true} is ignored and still sends the single test notification
        self.req("POST", "/api/push/subscribe", SUB("1"))
        for body in ({}, {"icons": True}):
            self.calls.clear()
            r, d = self.req("POST", "/api/push/test", body)
            self.assertEqual(r, 200)
            self.assertNotIn("total", d)
            self.assertEqual([p["tag"] for _, p in self.calls], ["zbs-test"])
        self.assertFalse(hasattr(push.Push, "send_icon_test"))

    def test_guest_whitelist_has_devices(self):
        self.assertTrue(server.guest_api_path("/api/push/devices"))


if __name__ == "__main__":
    unittest.main()
