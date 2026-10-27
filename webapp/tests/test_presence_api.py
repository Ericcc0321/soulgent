"""In-use registration (foreground snapshot request headers X-Zbs-Dev / X-Zbs-Act / X-Zbs-Seen, sendBeacon /api/presence when switching away),
notify_round passing in-use state per account, dead-subscription cleanup wiring (once a day, deletes only after 14 days from the wiring time, the start point is stored in push.json and survives restarts),
the device list (key / this device / last active) and per-account deletion."""
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

from api import notify, presence, push, server
from tests._guests import guests_for  # noqa: E402

KEY = "secret-key-123"
GKEY = "guest-key-0123456789abcdef"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GCOOKIE = "zbs=" + hmac.new(GKEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
DAY = 86400
DEV1 = "devAAAA111122223333"[:16]
DEV2 = "devBBBB444455556666"[:16]


def SUB(n, host="fcm.googleapis.com"):
    return {"endpoint": "https://%s/%s" % (host, n), "keys": {"p256dh": "P" + n, "auth": "A" + n}}


class PresenceUnitTest(unittest.TestCase):
    def setUp(self):
        self.p = presence.Presence()

    def test_active_with_ttl(self):
        self.assertFalse(self.p.active("admin", 100))
        self.p.touch("admin", DEV1, True, 100)
        self.assertTrue(self.p.active("admin", 100 + presence.ACTIVE_TTL))
        self.assertFalse(self.p.active("admin", 100 + presence.ACTIVE_TTL + 0.5))  # about 4 missed polls count as gone

    def test_act_zero_not_active_and_leave(self):
        self.p.touch("admin", DEV1, False, 100)
        self.assertFalse(self.p.active("admin", 101))
        self.p.touch("admin", DEV1, True, 102)
        self.p.leave("admin", DEV1, 103)
        self.assertFalse(self.p.active("admin", 103))
        self.assertEqual(self.p.last("admin", DEV1), 102)  # last active = the most recent act=1

    def test_accounts_separate(self):
        self.p.touch("admin", DEV1, True, 100)
        self.assertFalse(self.p.active("guest", 100))

    def test_parse_seen(self):
        ok = presence.parse_seen("s-abc:wait, s-%E4%B8%AD-1:done ,s-x.y_z:err")
        self.assertEqual(ok, ["s-abc:wait", "s-中-1:done", "s-x.y_z:err"])
        self.assertEqual(presence.parse_seen("abc:wait,s-a:nope,s-:wait,s-a b:wait,s-a:wait:x"), [])
        self.assertEqual(presence.parse_seen(None), [])
        self.assertEqual(len(presence.parse_seen(",".join("s-%d:wait" % i for i in range(50)))), presence.MAX_SEEN)
        self.assertEqual(presence.parse_seen("s-%0A:wait"), [])  # decodes to a control character

    def test_seen_records_time(self):
        self.p.report("admin", ["s-a:wait"], 100)
        self.assertEqual(self.p.seen("admin", 101), {"s-a:wait": 100})
        self.assertEqual(self.p.seen("guest", 101), {})
        self.assertEqual(self.p.seen("admin", 100 + presence.SEEN_KEEP + 1), {})  # expired entries are dropped so it does not grow without bound

    def test_rate_limit(self):
        for i in range(presence.RATE_MAX):
            self.assertTrue(self.p.allow("admin", 100 + i * 0.01))
        self.assertFalse(self.p.allow("admin", 101))
        self.assertTrue(self.p.allow("guest", 101))
        self.assertTrue(self.p.allow("admin", 100 + presence.RATE_WINDOW + 1))

    def test_device_cap(self):
        for i in range(presence.MAX_DEVS + 10):
            self.p.touch("admin", "dev%013d" % i, True, 100 + i)
        self.assertLessEqual(len(self.p._dev), presence.MAX_DEVS)
        self.assertTrue(self.p.active("admin", 100 + presence.MAX_DEVS + 9))


class ApiBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.snap = os.path.join(t, "snapshot.json")
        self.write_snap([])
        env = mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUBKEY", "VAPID_PRIVATE_KEY": "PRIV"})
        env.start()
        self.addCleanup(env.stop)
        lg = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        lg.start()
        self.addCleanup(lg.stop)
        err = mock.patch("sys.stderr")
        err.start()
        self.addCleanup(err.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap, projects=t,
                                        state=os.path.join(t, "st", "state.json"), outbox_dir=os.path.join(t, "ob"),
                                        guests=guests_for(KEY, GKEY, "Bound"))
        self.app = self.httpd.app
        self.calls = []
        self.app.push.sender = lambda s, payload, priv, subject: self.calls.append((s["endpoint"], payload)) or 201
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.store = os.path.join(t, "st", "push.json")

    def write_snap(self, sessions, gen=None):
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": time.time() if gen is None else gen, "sessions": sessions}, f)

    def req(self, method, path, body=None, headers=None, cookie=COOKIE, raw=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Cookie": cookie, "Content-Type": "application/json"}
        h.update(headers or {})
        data = raw if raw is not None else (json.dumps(body) if body is not None else None)
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        try:
            return r.status, (json.loads(out) if out else None)
        except ValueError:
            return r.status, None


class SnapshotHeaderTest(ApiBase):
    def test_snapshot_headers_mark_active(self):
        r, _ = self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": DEV1, "X-Zbs-Act": "1"})
        self.assertEqual(r, 200)
        self.assertTrue(self.app.presence.active("admin", time.time()))
        self.assertFalse(self.app.presence.active(server.GUEST, time.time()))

    def test_act_zero_or_no_header(self):
        self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": DEV1, "X-Zbs-Act": "0"})
        self.assertFalse(self.app.presence.active("admin", time.time()))
        self.req("GET", "/api/snapshot")  # fetched by an old frontend / the service worker itself: does not count
        self.assertFalse(self.app.presence.active("admin", time.time()))
        self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": "bad dev!", "X-Zbs-Act": "1"})
        self.assertFalse(self.app.presence.active("admin", time.time()))

    def test_seen_header_only_valid_format(self):
        self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": DEV1, "X-Zbs-Act": "1",
                                                  "X-Zbs-Seen": "s-a:wait,junk,s-b:what"})
        self.assertEqual(list(self.app.presence.seen("admin", time.time())), ["s-a:wait"])

    def test_guest_snapshot_marks_guest(self):
        self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": DEV2, "X-Zbs-Act": "1"}, cookie=GCOOKIE)
        self.assertTrue(self.app.presence.active(server.GUEST, time.time()))
        self.assertFalse(self.app.presence.active("admin", time.time()))


class PresenceApiTest(ApiBase):
    def test_beacon_text_plain_leaves(self):
        self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": DEV1, "X-Zbs-Act": "1"})
        r, d = self.req("POST", "/api/presence", raw=json.dumps({"dev": DEV1, "act": 0, "seen": ["s-a:wait"]}),
                        headers={"Content-Type": "text/plain;charset=UTF-8"})
        self.assertEqual(r, 200)
        self.assertFalse(self.app.presence.active("admin", time.time()))
        self.assertIn("s-a:wait", self.app.presence.seen("admin", time.time()))

    def test_beacon_act_one(self):
        r, _ = self.req("POST", "/api/presence", {"dev": DEV1, "act": 1})
        self.assertEqual(r, 200)
        self.assertTrue(self.app.presence.active("admin", time.time()))

    def test_bad_fields(self):
        self.assertEqual(self.req("POST", "/api/presence", {"dev": "x", "act": 0})[0], 400)
        self.assertEqual(self.req("POST", "/api/presence", {"act": 0})[0], 400)
        self.assertEqual(self.req("POST", "/api/presence", raw="not json")[0], 400)
        self.assertEqual(self.req("POST", "/api/presence", {"dev": DEV1, "act": 0, "seen": "s-a:wait"})[0], 200)  # seen is not an array: ignored

    def test_unauthenticated(self):
        self.assertEqual(self.req("POST", "/api/presence", {"dev": DEV1, "act": 0}, cookie="")[0], 401)

    def test_rate_limited(self):
        codes = [self.req("POST", "/api/presence", {"dev": DEV1, "act": 0})[0] for _ in range(presence.RATE_MAX + 2)]
        self.assertEqual(codes[-1], 429)
        self.assertEqual(codes[0], 200)

    def test_guest_only_own_account(self):
        self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": DEV1, "X-Zbs-Act": "1"})
        r, _ = self.req("POST", "/api/presence", {"dev": DEV1, "act": 0}, cookie=GCOOKIE)  # a guest using the same device id only affects their own account
        self.assertEqual(r, 200)
        self.assertTrue(self.app.presence.active("admin", time.time()))

    def test_guest_whitelist(self):
        self.assertTrue(server.guest_api_path("/api/presence"))
        self.assertTrue(server.guest_api_path("/api/push/devices/delete"))


class NotifyWiringTest(ApiBase):
    """notify_round passes in-use state per account: admin in use -> no push to admin; guests still get pushes."""

    def setUp(self):
        super().setUp()
        self.sent = []
        self.app.push.send_all = lambda payload, account="admin": self.sent.append((account, payload)) or {}

    def test_admin_active_holds_then_pushes_after_12s(self):
        t0 = time.time()
        self.app.notify_round(t0)  # baseline
        s = {"id": "a", "name": "alice", "status": "waiting", "since": t0}
        self.write_snap([s], gen=t0)
        for i in range(1, 16):
            self.app.presence.touch("admin", DEV1, True, t0 + i)
            self.app.notify_round(t0 + i)
        self.assertEqual(self.sent, [])  # held at the deadline (+4); only at +16 does it reach 12 seconds
        for i in range(16, 24):
            self.app.presence.touch("admin", DEV1, True, t0 + i)
            self.app.notify_round(t0 + i)
        self.assertEqual([a for a, _ in self.sent], ["admin"])

    def test_admin_active_seen_no_push(self):
        t0 = time.time()
        self.app.notify_round(t0)
        self.write_snap([{"id": "a", "name": "alice", "status": "waiting", "since": t0}], gen=t0)
        for i in range(1, 25):
            self.app.presence.touch("admin", DEV1, True, t0 + i)
            if i == 5:
                self.app.presence.report("admin", ["s-a:wait"], t0 + i)
            self.app.notify_round(t0 + i)
        self.assertEqual(self.sent, [])

    def test_mac_down_held_while_active(self):
        t0 = time.time()
        self.app.notify_round(t0)
        for i in range(1, 140):  # snapshot no longer updates: stale after 31s, the disconnect push is due after 90s of staleness
            self.app.presence.touch("admin", DEV1, True, t0 + i)
            self.app.notify_round(t0 + i)
        self.assertEqual(self.sent, [])
        self.app.notify_round(t0 + 140 + presence.ACTIVE_TTL + 1)  # user went away while still disconnected -> push belatedly
        self.assertEqual([p["tag"] for _, p in self.sent], ["mac-link"])


class PruneWiringTest(ApiBase):
    def seed(self):
        with open(self.store, "w") as f:
            json.dump({"subscriptions": [dict(SUB("old"), account="admin"),
                                         dict(SUB("new"), account="admin", dev=DEV1)], "devSince": 1}, f)

    def eps(self):
        return sorted(s["endpoint"].rsplit("/", 1)[1] for s in self.app.push.subscriptions())

    def test_first_round_marks_start_daily_and_deletes_after_14_days(self):
        os.makedirs(os.path.dirname(self.store), exist_ok=True)
        self.seed()
        t0 = time.time()
        self.app.notify_round(t0)
        with open(self.store) as f:
            self.assertEqual(json.load(f)["pruneSince"], t0)  # counted from the wiring time (devSince is not used)
        with mock.patch.object(self.app.push, "prune_dead", wraps=self.app.push.prune_dead) as pd:
            for i in range(1, 50):
                self.app.notify_round(t0 + i)
            self.assertEqual(pd.call_count, 0)  # once a day
            self.app.notify_round(t0 + DAY)
            self.assertEqual(pd.call_count, 1)
        self.assertEqual(self.eps(), ["new", "old"])
        self.app.notify_round(t0 + 14 * DAY)
        self.assertEqual(self.eps(), ["new"])

    def test_restart_keeps_start(self):
        os.makedirs(os.path.dirname(self.store), exist_ok=True)
        self.seed()
        t0 = time.time()
        self.app.notify_round(t0)
        app2 = server.App(KEY, self.snap, self.tmp.name, os.path.join(self.tmp.name, "st", "state.json"),
                          os.path.join(self.tmp.name, "ob"))
        app2.push.send_all = lambda payload, account="admin": {}
        app2.notify_round(t0 + 13 * DAY)  # first round after restart: the start point is not reset
        with open(self.store) as f:
            self.assertEqual(json.load(f)["pruneSince"], t0)
        self.assertEqual(self.eps(), ["new", "old"])
        app2.notify_round(t0 + 14 * DAY + 5)  # does not run again within a day of a restart; a fresh App simulates another restart
        app3 = server.App(KEY, self.snap, self.tmp.name, os.path.join(self.tmp.name, "st", "state.json"),
                          os.path.join(self.tmp.name, "ob"))
        app3.push.send_all = lambda payload, account="admin": {}
        app3.notify_round(t0 + 14 * DAY + 10)
        self.assertEqual(self.eps(), ["new"])


class DeviceListTest(ApiBase):
    def setUp(self):
        super().setUp()
        self.req("POST", "/api/push/subscribe", dict(SUB("1"), dev=DEV1, plat="iphone", standalone=True))
        self.req("POST", "/api/push/subscribe", SUB("2"))  # old subscription: no device info
        self.req("POST", "/api/push/subscribe", dict(SUB("g"), dev=DEV2, plat="windows", standalone=False), cookie=GCOOKIE)

    def devs(self, cookie=COOKIE, dev=DEV1):
        r, d = self.req("GET", "/api/push/devices", headers={"X-Zbs-Dev": dev}, cookie=cookie)
        self.assertEqual(r, 200)
        return d["devices"]

    def test_list_has_key_self_last(self):
        self.req("GET", "/api/snapshot", headers={"X-Zbs-Dev": DEV1, "X-Zbs-Act": "1"})
        ds = self.devs()
        self.assertEqual(len(ds), 2)
        mine = [d for d in ds if d.get("dev") == DEV1][0]
        old = [d for d in ds if "dev" not in d][0]
        self.assertTrue(mine["self"])
        self.assertFalse(old["self"])
        self.assertTrue(mine["active"])
        self.assertGreaterEqual(mine["lastActive"], mine["at"])
        self.assertEqual(old["lastActive"], old["at"])  # not recorded in memory: fall back to the last registration time
        self.assertEqual(len({d["key"] for d in ds}), 2)
        self.assertNotIn("endpoint", json.dumps(ds))
        self.assertNotIn("fcm.googleapis.com", json.dumps(ds))

    def test_delete_own_account(self):
        old = [d for d in self.devs() if "dev" not in d][0]
        r, d = self.req("POST", "/api/push/devices/delete", {"key": old["key"]})
        self.assertEqual((r, d), (200, {"ok": True}))
        self.assertEqual([d.get("dev") for d in self.devs()], [DEV1])

    def test_guest_cannot_delete_admin_device(self):
        k = self.devs()[0]["key"]
        r, _ = self.req("POST", "/api/push/devices/delete", {"key": k}, cookie=GCOOKIE)
        self.assertEqual(r, 404)
        self.assertEqual(len(self.devs()), 2)

    def test_guest_sees_and_deletes_own(self):
        g = self.devs(GCOOKIE, DEV2)
        self.assertEqual([(d["dev"], d["self"]) for d in g], [(DEV2, True)])
        r, _ = self.req("POST", "/api/push/devices/delete", {"key": g[0]["key"]}, cookie=GCOOKIE)
        self.assertEqual(r, 200)
        self.assertEqual(self.devs(GCOOKIE, DEV2), [])
        self.assertEqual(len(self.devs()), 2)

    def test_admin_cannot_delete_guest_device(self):
        k = self.devs(GCOOKIE, DEV2)[0]["key"]
        self.assertEqual(self.req("POST", "/api/push/devices/delete", {"key": k})[0], 404)

    def test_bad_key(self):
        self.assertEqual(self.req("POST", "/api/push/devices/delete", {"key": 5})[0], 400)
        self.assertEqual(self.req("POST", "/api/push/devices/delete", {})[0], 400)


if __name__ == "__main__":
    unittest.main()
