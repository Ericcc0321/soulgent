"""Per-device login tokens: issue, validate, logout, revoke, key change, 90-day expiry, 7-day renewal, legacy cookie upgrade,
file permissions, guest isolation, and devices.json never holding a raw token."""
import hashlib
import hmac
import http.client
import io
import json
import os
import re
import stat
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import devices, server
from tests._guests import guests_for  # noqa: E402
from tests import _sig  # noqa: E402,F401

KEY = "admin-key-0123456789abcdef"
GUEST = "guest-key-0123456789abcdef"
KEY2 = "admin-key-changed-0123456789"
LEGACY_ADMIN = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
LEGACY_GUEST = "zbs=" + hmac.new(GUEST.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
UA_IPHONE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
             "Version/18.0 Mobile/15E148 Safari/604.1")
UA_MAC_CHROME = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
                 "Chrome/130.0.0.0 Safari/537.36")
DAY = 86400


class Clock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def read_file(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "devices.json")
        self.clock = Clock()
        self.fps = {"admin": devices.key_fp(KEY), "guest": devices.key_fp(GUEST)}
        self.store = devices.DeviceStore(self.path, now=self.clock)

    def kfp(self, acc):
        return self.fps.get(acc)

    def test_issue_stores_hash_only_with_mode_600(self):
        raw = self.store.issue("admin", "iPhone Safari", self.fps["admin"])
        self.assertRegex(raw, r"^[0-9a-f]{64}$")
        text = read_file(self.path)
        self.assertNotIn(raw, text)
        self.assertIn(devices.token_hash(raw), text)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        row = json.loads(text)["tokens"][0]
        self.assertEqual(set(row), {"hash", "id", "account", "issuedAt", "lastSeen", "cookieAt", "desc", "kfp"})
        self.assertEqual((row["account"], row["desc"], row["kfp"]), ("admin", "iPhone Safari", self.fps["admin"]))
        self.assertNotIn(KEY, text)
        self.assertEqual([n for n in os.listdir(self.tmp.name) if n != "devices.json"], [])  # no temp file left behind

    def test_lookup_valid_unknown_and_reload(self):
        raw = self.store.issue("guest", "Mac Chrome", self.fps["guest"])
        self.assertEqual(self.store.lookup(raw, self.kfp)["account"], "guest")
        self.assertIsNone(self.store.lookup("0" * 64, self.kfp))
        self.assertIsNone(self.store.lookup("not-a-token", self.kfp))
        again = devices.DeviceStore(self.path, now=self.clock)  # survives a restart
        self.assertEqual(again.lookup(raw, self.kfp)["account"], "guest")

    def test_key_change_or_removed_account_invalidates(self):
        a = self.store.issue("admin", "x", self.fps["admin"])
        g = self.store.issue("guest", "x", self.fps["guest"])
        self.fps["admin"] = devices.key_fp(KEY2)
        del self.fps["guest"]
        self.assertIsNone(self.store.lookup(a, self.kfp))
        self.assertIsNone(self.store.lookup(g, self.kfp))
        self.assertEqual(json.loads(read_file(self.path))["tokens"], [])  # pruned
        self.fps["admin"] = devices.key_fp(KEY)  # changing the key back does not revive it
        self.assertIsNone(self.store.lookup(a, self.kfp))

    def test_unused_90_days_expires_and_is_pruned(self):
        old = self.store.issue("admin", "x", self.fps["admin"])
        used = self.store.issue("admin", "y", self.fps["admin"])
        self.clock.t += 80 * DAY
        self.assertIsNotNone(self.store.lookup(used, self.kfp))
        self.clock.t += 11 * DAY  # old: 91 days idle; used: 11 days
        self.assertIsNotNone(self.store.lookup(used, self.kfp))
        self.assertNotIn(devices.token_hash(old), read_file(self.path))  # pruned on the flush, before anyone presents it
        self.assertIsNone(self.store.lookup(old, self.kfp))

    def test_last_seen_persisted_at_most_every_few_minutes(self):
        raw = self.store.issue("admin", "x", self.fps["admin"])
        t0 = self.clock.t
        seen = lambda: json.loads(read_file(self.path))["tokens"][0]["lastSeen"]  # noqa: E731
        with mock.patch.object(self.store, "_write", wraps=self.store._write) as w:
            for i in range(50):
                self.clock.t = t0 + i
                self.store.lookup(raw, self.kfp)
            self.assertEqual(w.call_count, 0)  # no disk write per request
            self.assertEqual(seen(), t0)
            self.clock.t = t0 + devices.FLUSH_GAP + 1
            self.store.lookup(raw, self.kfp)
            self.assertEqual(w.call_count, 1)
        self.assertEqual(seen(), t0 + devices.FLUSH_GAP + 1)

    def test_revoke_by_id_own_account_only_and_list(self):
        a = self.store.issue("admin", "Mac Chrome", self.fps["admin"])
        g = self.store.issue("guest", "iPhone Safari", self.fps["guest"])
        rows = self.store.list("guest", self.fps["guest"])
        self.assertEqual([(r["desc"]) for r in rows], ["iPhone Safari"])
        gid = rows[0]["id"]
        self.assertRegex(gid, r"^[0-9a-f]{12}$")
        self.assertNotIn(gid, devices.token_hash(g))  # the id is not derived from the hash
        self.assertIsNone(self.store.revoke("admin", gid))  # another account's id
        self.assertIsNotNone(self.store.lookup(g, self.kfp))
        self.assertEqual(self.store.revoke("guest", gid), devices.token_hash(g))
        self.assertIsNone(self.store.lookup(g, self.kfp))
        self.assertIsNotNone(self.store.lookup(a, self.kfp))
        self.assertIsNone(self.store.revoke("guest", "../etc"))

    def test_per_account_cap_drops_least_recent(self):
        first = self.store.issue("admin", "x", self.fps["admin"])
        for _ in range(devices.PER_ACCOUNT_MAX):
            self.clock.t += 1
            self.store.issue("admin", "x", self.fps["admin"])
        self.assertEqual(len(self.store.list("admin", self.fps["admin"])), devices.PER_ACCOUNT_MAX)
        self.assertIsNone(self.store.lookup(first, self.kfp))

    def test_describe_uses_fixed_vocabulary(self):
        self.assertEqual(devices.describe(UA_IPHONE), "iPhone Safari")
        self.assertEqual(devices.describe(UA_MAC_CHROME), "Mac Chrome")
        self.assertEqual(devices.describe("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"),
                         "iPhone App")
        self.assertEqual(devices.describe("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130 Safari/537.36 Edg/130"),
                         "Windows Edge")
        self.assertEqual(devices.describe(None), "Unknown device")
        self.assertEqual(devices.describe("<script>" + "A" * 500), "Unknown device")  # nothing from the raw UA is copied


class HttpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.snap = os.path.join(self.tmp.name, "snapshot.json")
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": time.time(), "sessions": [], "zones": []}, f)
        os.makedirs(os.path.join(self.tmp.name, "projects"))
        self.state = os.path.join(self.tmp.name, "st", "state.json")
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.start(KEY)

    def start(self, key):
        httpd = server.make_server("127.0.0.1", 0, key=key, snapshot=self.snap, projects=os.path.join(self.tmp.name, "projects"),
                                   state=self.state, outbox_dir=self.tmp.name, uploads_dir=self.tmp.name,
                                   guests=guests_for(key, GUEST, "Web-guest"))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        self.httpd = httpd
        self.port = httpd.server_address[1]
        self.app = httpd.app
        self.clock = Clock(time.time())
        self.app.devices.now = self.clock

    def req(self, method, path, cookie=None, body=None, ua=UA_IPHONE, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"User-Agent": ua}
        h.update(headers or {})
        if cookie:
            h["Cookie"] = cookie
        data = None
        if body is not None:
            data = json.dumps(body)
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        raw = r.read()
        c.close()
        return r, (json.loads(raw) if raw and r.getheader("Content-Type", "").startswith("application/json") else None)

    def login(self, key, ua=UA_IPHONE):
        r, _ = self.req("POST", "/api/auth", body={"key": key}, ua=ua)
        self.assertIn(r.status, (200, 204))
        return r.getheader("Set-Cookie").split(";")[0]

    def devices_file(self):
        return read_file(os.path.join(self.tmp.name, "st", "devices.json"))

    def test_login_issues_distinct_tokens_with_same_attributes(self):
        a = self.login(KEY)
        b = self.login(KEY, ua=UA_MAC_CHROME)
        self.assertNotEqual(a, b)
        r, _ = self.req("POST", "/api/auth", body={"key": KEY})
        self.assertEqual(r.getheader("Set-Cookie").split(";", 1)[1],
                         " Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=%d" % server.COOKIE_MAX_AGE)
        text = self.devices_file()
        for c in (a, b):
            self.assertNotIn(c[4:], text)
        r, me = self.req("GET", "/api/auth/me", a)
        self.assertEqual((r.status, me["account"]), (200, "admin"))
        r, _ = self.req("GET", "/api/auth/check", a, headers={"X-Forwarded-Uri": "/"})
        self.assertEqual((r.status, r.getheader("X-ZBS-User")), (200, "admin"))

    def test_relogin_replaces_own_token(self):
        a = self.login(KEY)
        r, _ = self.req("POST", "/api/auth", a, body={"key": KEY})
        b = r.getheader("Set-Cookie").split(";")[0]
        self.assertEqual(self.req("GET", "/api/auth/me", a)[0].status, 401)
        self.assertEqual(self.req("GET", "/api/auth/me", b)[0].status, 200)

    def test_auto_login_409_rule_kept(self):
        g = self.login(GUEST)
        r, _ = self.req("POST", "/api/auth", g, body={"key": KEY, "auto": True})
        self.assertEqual((r.status, r.getheader("Set-Cookie")), (409, None))
        self.assertEqual(self.req("GET", "/api/auth/me", g)[1]["account"], "guest")

    def test_logout_deletes_token(self):
        a = self.login(KEY)
        b = self.login(KEY, ua=UA_MAC_CHROME)
        r, _ = self.req("POST", "/api/auth/logout", a, body={})
        self.assertEqual(r.status, 204)
        self.assertIn("Max-Age=0", r.getheader("Set-Cookie"))
        self.assertEqual(self.req("GET", "/api/auth/me", a)[0].status, 401)
        self.assertEqual(self.req("GET", "/api/auth/check", a, headers={"X-Forwarded-Uri": "/"})[0].status, 401)
        self.assertEqual(self.req("GET", "/api/auth/me", b)[0].status, 200)  # other devices stay signed in

    def test_devices_list_and_revoke_other_and_self(self):
        a = self.login(KEY)
        b = self.login(KEY, ua=UA_MAC_CHROME)
        r, d = self.req("GET", "/api/auth/devices", a)
        self.assertEqual(r.status, 200)
        rows = d["devices"]
        self.assertEqual(sorted((x["desc"], x["self"]) for x in rows), [("Mac Chrome", False), ("iPhone Safari", True)])
        for x in rows:
            self.assertEqual(set(x), {"id", "desc", "issuedAt", "lastSeen", "self"})
            self.assertNotIn(x["id"], self.devices_file().replace('"id": "%s"' % x["id"], ""))  # the id appears only as itself
        other = next(x["id"] for x in rows if not x["self"])
        mine = next(x["id"] for x in rows if x["self"])
        r, d = self.req("POST", "/api/auth/devices/revoke", a, body={"id": other})
        self.assertEqual((r.status, d), (200, {"ok": True, "self": False}))
        self.assertIsNone(r.getheader("Set-Cookie"))
        self.assertEqual(self.req("GET", "/api/auth/me", b)[0].status, 401)
        r, d = self.req("POST", "/api/auth/devices/revoke", a, body={"id": mine})
        self.assertEqual((r.status, d), (200, {"ok": True, "self": True}))
        self.assertIn("Max-Age=0", r.getheader("Set-Cookie"))
        self.assertEqual(self.req("GET", "/api/auth/me", a)[0].status, 401)
        self.assertEqual(self.req("POST", "/api/auth/devices/revoke", None, body={"id": mine})[0].status, 401)
        self.assertEqual(self.req("GET", "/api/auth/devices")[0].status, 401)

    def test_revoke_requires_json_same_origin_and_valid_id(self):
        a = self.login(KEY)
        r, _ = self.req("POST", "/api/auth/devices/revoke", a, body={"id": "zz"})
        self.assertEqual(r.status, 400)
        r, _ = self.req("POST", "/api/auth/devices/revoke", a, body={"id": "000000000000"})
        self.assertEqual(r.status, 404)
        r, _ = self.req("POST", "/api/auth/devices/revoke", a, body={"id": "000000000000"}, headers={"Origin": "https://evil.example"})
        self.assertEqual(r.status, 403)
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("POST", "/api/auth/devices/revoke", body='{"id":"000000000000"}', headers={"Cookie": a, "Content-Type": "text/plain"})
        self.assertEqual(c.getresponse().status, 415)
        c.close()

    def test_guests_isolated(self):
        a = self.login(KEY)
        g = self.login(GUEST, ua=UA_MAC_CHROME)
        _, ad = self.req("GET", "/api/auth/devices", a)
        _, gd = self.req("GET", "/api/auth/devices", g)
        self.assertEqual([x["desc"] for x in ad["devices"]], ["iPhone Safari"])
        self.assertEqual([x["desc"] for x in gd["devices"]], ["Mac Chrome"])
        r, _ = self.req("POST", "/api/auth/devices/revoke", g, body={"id": ad["devices"][0]["id"]})
        self.assertEqual(r.status, 404)
        r, _ = self.req("POST", "/api/auth/devices/revoke", a, body={"id": gd["devices"][0]["id"]})
        self.assertEqual(r.status, 404)  # admin also manages only its own devices
        self.assertEqual(self.req("GET", "/api/auth/me", a)[0].status, 200)
        self.assertEqual(self.req("GET", "/api/auth/me", g)[0].status, 200)
        # the caddy gate lets guests reach both endpoints
        for p in ("/api/auth/devices", "/api/auth/devices/revoke"):
            r, _ = self.req("GET", "/api/auth/check", g, headers={"X-Forwarded-Uri": p})
            self.assertEqual((r.status, r.getheader("X-ZBS-User")), (200, "guest"), p)

    def test_key_change_logs_out_that_accounts_devices(self):
        a = self.login(KEY)
        g = self.login(GUEST)
        self.start(KEY2)  # restart with a new admin key on the same state volume
        self.assertEqual(self.req("GET", "/api/auth/me", a)[0].status, 401)
        self.assertEqual(self.req("GET", "/api/auth/me", g)[0].status, 200)  # the guest's key did not change
        self.assertEqual(self.req("GET", "/api/auth/me", LEGACY_ADMIN)[0].status, 401)

    def test_unused_90_days_invalid(self):
        a = self.login(KEY)
        self.clock.t += 91 * DAY
        self.assertEqual(self.req("GET", "/api/auth/me", a)[0].status, 401)
        self.assertNotIn(devices.token_hash(a[4:]), self.devices_file())

    def test_renew_after_7_days_on_browser_facing_responses_only(self):
        a = self.login(KEY)
        self.clock.t += 6 * DAY
        r, _ = self.req("GET", "/api/snapshot", a)
        self.assertEqual((r.status, r.getheader("Set-Cookie")), (200, None))
        self.clock.t += 2 * DAY
        r, _ = self.req("GET", "/api/auth/check", a, headers={"X-Forwarded-Uri": "/"})  # forward_auth would drop it: not sent here
        self.assertEqual((r.status, r.getheader("Set-Cookie")), (200, None))
        r, _ = self.req("GET", "/api/snapshot", a)
        self.assertEqual(r.status, 200)
        self.assertEqual(r.getheader("Set-Cookie"), self.app.cookie_header(a[4:]))  # same token, fresh Max-Age
        r, _ = self.req("GET", "/api/snapshot", a)
        self.assertIsNone(r.getheader("Set-Cookie"))  # once per 7 days
        self.clock.t += 7 * DAY
        r, _ = self.req("GET", "/api/profile", a)
        self.assertEqual(r.getheader("Set-Cookie"), self.app.cookie_header(a[4:]))  # any /api response

    def test_legacy_cookie_upgraded_once_with_log_line(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            r, _ = self.req("GET", "/api/auth/check", LEGACY_GUEST, headers={"X-Forwarded-Uri": "/"})
            self.assertEqual((r.status, r.getheader("Set-Cookie")), (200, None))  # still accepted, but not upgraded on the gate
            r, me = self.req("GET", "/api/auth/me", LEGACY_GUEST)
            self.assertEqual((r.status, me["account"]), (200, "guest"))
            new = r.getheader("Set-Cookie")
            self.assertRegex(new, r"^zbs=[0-9a-f]{64}; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=%d$" % server.COOKIE_MAX_AGE)
            r, _ = self.req("GET", "/api/snapshot", LEGACY_GUEST)  # arrives together with /api/auth/me: the same new token
            self.assertEqual(r.getheader("Set-Cookie"), new)
            r, _ = self.req("GET", "/api/profile", LEGACY_GUEST)  # other endpoints accept it without upgrading
            self.assertEqual((r.status, r.getheader("Set-Cookie")), (200, None))
        log = err.getvalue()
        self.assertEqual(re.findall(r"legacy cookie upgraded.*", log), ["legacy cookie upgraded to device token account=guest device=iPhone Safari"])
        self.assertNotIn(LEGACY_GUEST[4:], log)
        self.assertNotIn(new.split(";")[0][4:], log)
        self.assertNotIn(GUEST, log)
        tok = new.split(";")[0]
        r, d = self.req("GET", "/api/auth/devices", tok)
        self.assertEqual([(x["desc"], x["self"]) for x in d["devices"]], [("iPhone Safari", True)])
        self.assertNotIn(tok[4:], self.devices_file())

    def test_legacy_cookie_devices_list_marks_upgraded_self(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO):
            r, d = self.req("GET", "/api/auth/devices", LEGACY_ADMIN, ua=UA_MAC_CHROME)
        self.assertEqual([(x["desc"], x["self"]) for x in d["devices"]], [("Mac Chrome", True)])
        self.assertRegex(r.getheader("Set-Cookie"), r"^zbs=[0-9a-f]{64}; ")

    def test_legacy_logout_and_no_upgrade_on_login_logout(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            r, _ = self.req("POST", "/api/auth/logout", LEGACY_ADMIN, body={})
            self.assertIn("Max-Age=0", r.getheader("Set-Cookie"))
        self.assertNotIn("upgraded", err.getvalue())
        self.assertEqual(json.loads(self.devices_file())["tokens"] if os.path.exists(
            os.path.join(self.tmp.name, "st", "devices.json")) else [], [])


if __name__ == "__main__":
    unittest.main()
