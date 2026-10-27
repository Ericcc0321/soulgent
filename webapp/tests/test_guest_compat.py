"""Compatibility after generalizing the guest account: old deployments (legacy guest account name, legacy message prefix, old files in the state volume) keep working.

The legacy name is only read from GUEST_LEGACY_ACCOUNT in .env (not configured = no legacy-name compatibility at all); tests use the made-up legacy name oldguest.
The legacy message prefix is configured directly in GUEST_TAG and is no longer derived from the legacy name."""
import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import guestcfg, history, push, server
from tests._guests import guests_for  # noqa: E402
from tests import _sig  # noqa: E402,F401  sets OUTBOX_SECRET (sending requires a signature)

KEY = "admin-key-0123456789abcdef"
GUEST = "guest-key-0123456789abcdef"
BOUND = "Web-guest-demo"
LEGACY = "oldguest"        # made-up legacy account name (GUEST_LEGACY_ACCOUNT)
LEGACY_TAG = "[OLDGUEST]"  # made-up legacy prefix (configured in GUEST_TAG)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JPEG = b"\xff\xd8\xff\xe0" + b"z" * 50


def v82_cookie(key):
    """Cookie issued by an old version: hmac(key, 'zbs-v1'), independent of the account name."""
    return "zbs=" + hmac.new(key.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


class Base(unittest.TestCase):
    tag = guestcfg.DEFAULT_TAG
    admin_only = ()
    legacy = ""  # GUEST_LEGACY_ACCOUNT; empty = not configured

    def setUp(self):
        # store_id is read when the App is built and normalize_account at request time, so this must hold for the whole test
        p = mock.patch.dict(os.environ)
        p.start()
        self.addCleanup(p.stop)
        os.environ.pop("GUEST_LEGACY_ACCOUNT", None)
        if self.legacy:
            os.environ["GUEST_LEGACY_ACCOUNT"] = self.legacy
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.projects = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(self.projects, "p"))
        with open(os.path.join(self.projects, "p", "c1.jsonl"), "w") as f:
            f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "hi"},
                                "timestamp": "2026-10-19T01:00:00Z"}) + "\n")
        self.snap = os.path.join(self.tmp.name, "snapshot.json")
        now = time.time()
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": now, "zones": [], "sessions": [
                {"id": "c1", "kind": "claude", "name": BOUND, "plate": "guest-demo", "zone": "Web", "status": "idle",
                 "since": now, "transcript": "p/c1.jsonl"}]}, f)
        self.outbox = os.path.join(self.tmp.name, "outbox")
        self.uploads = os.path.join(self.tmp.name, "uploads")
        os.makedirs(self.outbox)
        os.makedirs(self.uploads)
        self.stdir = os.path.join(self.tmp.name, "st")
        os.makedirs(self.stdir)
        self.prepare_state()
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap, projects=self.projects,
                                        state=os.path.join(self.stdir, "state.json"), outbox_dir=self.outbox,
                                        uploads_dir=self.uploads, guests=guests_for(KEY, GUEST, BOUND, self.tag),
                                        admin_only=self.admin_only)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def prepare_state(self):
        pass

    def req(self, method, path, headers=None, body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        data = None
        if body is not None:
            data = json.dumps(body)
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        raw = r.read()
        c.close()
        return r, raw

    def guest(self, method, path, body=None):
        r, raw = self.req(method, path, {"Cookie": v82_cookie(GUEST)}, body)
        try:
            return r.status, json.loads(raw)
        except ValueError:
            return r.status, raw

    def check(self, uri, cookie=None):
        h = {"X-Forwarded-Uri": uri, "Accept": "text/html"}
        if cookie:
            h["Cookie"] = cookie
        return self.req("GET", "/api/auth/check", h)

    def outbox_texts(self):
        out = []
        for n in sorted(os.listdir(self.outbox)):
            if n.endswith(".req.json"):
                with open(os.path.join(self.outbox, n)) as f:
                    q = json.load(f)
                out.append((q["type"], q["text"]))
        return out

    def queue(self, *texts):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 20)) + ".000Z"
        with open(os.path.join(self.projects, "p", "c1.jsonl"), "a") as f:
            for t in texts:
                f.write(json.dumps({"type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": t},
                                   ensure_ascii=False, separators=(",", ":")) + "\n")  # same compact format as Claude Code transcripts


class CookieCompatTest(Base):
    """A guest cookie issued by an old version (the one already on a logged-in phone) needs no re-login and is still recognized as guest."""

    def test_legacy_cookie_is_guest(self):
        self.assertEqual(server._token(GUEST), v82_cookie(GUEST)[4:])  # the cookie formula is unchanged
        code, me = self.guest("GET", "/api/auth/me")
        self.assertEqual((code, me["user"], me["account"], me["session"]), (200, "guest", "guest", BOUND))
        r, _ = self.check("/", v82_cookie(GUEST))
        self.assertEqual((r.status, r.getheader("X-ZBS-User")), (200, "guest"))
        # a new login issues a per-device token instead of the legacy value (the legacy one keeps working, see test_devices)
        r, _ = self.req("POST", "/api/auth", {"X-Forwarded-For": "10.0.0.9"}, {"key": GUEST})
        self.assertRegex(r.getheader("Set-Cookie"), r"^zbs=[0-9a-f]{64}; ")
        self.assertFalse(r.getheader("Set-Cookie").startswith(v82_cookie(GUEST) + ";"))


class EnvTest(unittest.TestCase):
    """Only the generic name is read; the legacy account name only comes from GUEST_LEGACY_ACCOUNT, and an invalid value counts as not configured."""

    def test_env_strips(self):
        self.assertEqual(guestcfg.env("GUEST_KEY", {"GUEST_KEY": " k1 "}), "k1")
        self.assertEqual(guestcfg.env("GUEST_KEY", {"GUEST_KEY": " "}), "")
        self.assertEqual(guestcfg.env("GUEST_KEY", {}), "")

    def test_legacy_account(self):
        self.assertEqual(guestcfg.legacy_account({}), "")
        self.assertEqual(guestcfg.legacy_account({"GUEST_LEGACY_ACCOUNT": " %s " % LEGACY}), LEGACY)
        for bad in ("", " ", "guest", "admin", "a/b", "../x", "a b", "x" * 33, "a.json"):
            self.assertEqual(guestcfg.legacy_account({"GUEST_LEGACY_ACCOUNT": bad}), "", repr(bad))
        on = {"GUEST_LEGACY_ACCOUNT": LEGACY}
        self.assertEqual(guestcfg.normalize_account(LEGACY, on), "guest")
        self.assertEqual(guestcfg.normalize_account("admin", on), "admin")
        self.assertEqual(guestcfg.normalize_account(LEGACY, {}), LEGACY)  # not configured: the legacy name is not recognized
        self.assertEqual(guestcfg.normalize_account("admin", {"GUEST_LEGACY_ACCOUNT": "admin"}), "admin")

    def test_main_reads_generic_env(self):
        """main reads GUEST_KEY / GUEST_SESSION / GUEST_TAG / ADMIN_ONLY_PREFIXES."""
        got = {}

        class Stop(Exception):
            pass

        def fake(*a, **k):
            got["a"], got["k"] = a, k
            raise Stop()
        env = {"WEBAPP_KEY": KEY, "GUEST_KEY": " %s " % GUEST, "GUEST_SESSION": BOUND,
               "GUEST_TAG": LEGACY_TAG, "ADMIN_ONLY_PREFIXES": "/docs", "GUEST_SLASH_COMMANDS": " /window , /foo "}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(server, "make_server", fake), \
                mock.patch("sys.stderr"):
            with self.assertRaises(Stop):
                server.main()
        # main reads this into the guest list (guests=); the legacy key is still the first guest
        gs = got["k"]["guests"]
        self.assertEqual([(g.account, g.key, g.session, g.tag) for g in gs], [("guest", GUEST, BOUND, LEGACY_TAG)])
        self.assertEqual(got["k"]["admin_only"], ("/docs",))
        self.assertEqual(got["k"]["guest_slash"], ("/window", "/foo"))  # read once at startup and handed to the server


class SlashCommandsEnvTest(unittest.TestCase):
    """GUEST_SLASH_COMMANDS parsing: comma-separated, entries trimmed, must start with /, no inner whitespace; default empty."""

    def test_default_empty(self):
        self.assertEqual(guestcfg.slash_commands({}), ())
        self.assertEqual(guestcfg.slash_commands({"GUEST_SLASH_COMMANDS": "  "}), ())

    def test_configured(self):
        self.assertEqual(guestcfg.slash_commands({"GUEST_SLASH_COMMANDS": "/window"}), ("/window",))

    def test_trims_and_dedupes(self):
        self.assertEqual(guestcfg.slash_commands({"GUEST_SLASH_COMMANDS": " /window ,/foo,, /window "}), ("/window", "/foo"))

    def test_ignores_entries_without_slash(self):
        self.assertEqual(guestcfg.slash_commands({"GUEST_SLASH_COMMANDS": "window,/,/a b,foo/,/ok"}), ("/ok",))

    def test_server_rule_uses_the_list(self):
        self.assertIsNone(server.guest_slash("hi /window", ("/window",)))
        self.assertTrue(server.guest_slash("/window x", ("/window",)))
        self.assertFalse(server.guest_slash("/window", ()))  # default: nothing allowed
        self.assertFalse(server.guest_slash("/windows", ("/window",)))


class TagTest(unittest.TestCase):
    def test_clean_tag(self):
        self.assertEqual(guestcfg.tag({}), "[Guest]")
        self.assertEqual(guestcfg.tag({"GUEST_TAG": "  %s " % LEGACY_TAG}), LEGACY_TAG)
        for bad in ("", "   ", "[a b]", "[a\nb]", "x" * 25, "[\x01]"):
            self.assertEqual(guestcfg.clean_tag(bad), "[Guest]", repr(bad))
        self.assertEqual(guestcfg.clean_tag(None), "[Guest]")

    def test_own_re_escapes(self):
        r = guestcfg.own_re("(a+)")
        self.assertTrue(r.match("(a+) x"))
        self.assertTrue(r.match("[Image #2] (a+)"))
        self.assertFalse(r.match("aa x"))
        self.assertFalse(r.match("(a+)x"))


class LegacyTagTest(Base):
    """With the legacy prefix configured, the server's prefixing, recall, queue counting and search marking are byte-for-byte identical to the legacy behavior."""
    tag = LEGACY_TAG

    def test_whoami_has_tag_for_both_accounts(self):
        self.assertEqual(self.guest("GET", "/api/auth/me")[1]["tag"], LEGACY_TAG)
        r, raw = self.req("GET", "/api/auth/me", {"Cookie": v82_cookie(KEY)})
        self.assertEqual(json.loads(raw), {"user": "admin", "account": "admin", "tag": LEGACY_TAG,
                                           "guests": [{"account": "guest", "tag": LEGACY_TAG, "session": BOUND}]})

    def test_send_exact_text(self):
        T = LEGACY_TAG
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": "hi"})[0], 202)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"text": "好", "quote": "demo: 原文"})[0], 202)
        with open(os.path.join(self.uploads, "20261019-010000-abcdef-a.png"), "wb") as f:
            f.write(b"\x89PNG x")
        self.httpd.app.uploadlog.add("20261019-010000-abcdef-a.png", "guest")  # uploaded by the guest themself (upload log, required)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"files": ["20261019-010000-abcdef-a.png"]})[0], 202)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"files": ["20261019-010000-abcdef-a.png"], "text": "看图"})[0], 202)
        self.assertEqual(sorted(self.outbox_texts()), sorted([
            ("text", T + " hi"), ("text", T + " > demo: 原文\n\n好"), ("message", T), ("message", T + " 看图")]))

    def test_recall_and_queued_count(self):
        T = LEGACY_TAG
        self.queue(T + " 一", "[Image #1] " + T + " 图", T)
        code, page = self.guest("GET", "/api/sessions/c1/transcript")
        self.assertEqual((code, page["queued"]), (200, 3))
        for own in (T + " 一", "[Image #1] " + T + " 图", T):
            self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": own})[0], 202, own)
        # anything without the legacy prefix (including the default prefix [Guest]) counts as admin's
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "[Guest] 一"})[0], 403)
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": T + "x"})[0], 403)
        r, raw = self.req("GET", "/api/sessions/c1/transcript", {"Cookie": v82_cookie(KEY)})
        self.assertEqual(json.loads(raw)["queued"], 0)  # admin does not count the guest's

    def test_history_marks_guest(self):
        path = os.path.join(self.projects, "p", "c1.jsonl")
        with open(path, "a") as f:
            for t in (LEGACY_TAG + " 命中", "[Image #1] " + LEGACY_TAG + " 命中", "管理员 命中", "[Guest] 命中"):
                f.write(json.dumps({"type": "user", "message": {"role": "user", "content": t},
                                    "timestamp": "2026-10-19T02:00:00Z"}, ensure_ascii=False) + "\n")
        hits = history.search_file(path, "命中", 10, LEGACY_TAG)
        self.assertEqual([h["from"] for h in hits], ["", "", "guest", "guest"])
        # the in-session search endpoint passes the configured prefix to search_file
        with open(os.path.join(ROOT, "api", "server.py"), encoding="utf-8") as f:
            src = f.read()  # a guest searching passes their own prefix, the admin passes all guests' prefixes
            self.assertIn("tags = [guest.tag] if guest else self.app.guest_tags()", src)
            self.assertIn("history.search_file(path, q, limit - len(results), tags)", src)


class LegacyStateTest(Base):
    """With GUEST_LEGACY_ACCOUNT configured, the legacy-named profile/avatar/push subscriptions in the state volume are read and written as before, without creating new-name files (a rollback to the old version can still read them)."""
    legacy = LEGACY

    def prepare_state(self):
        with open(os.path.join(self.stdir, "profile-%s.json" % LEGACY), "w") as f:
            json.dump({"name": "老昵称", "v": 7}, f, ensure_ascii=False)
        with open(os.path.join(self.stdir, "avatar-%s.jpg" % LEGACY), "wb") as f:
            f.write(JPEG)
        subs = [{"endpoint": "https://web.push.apple.com/a", "keys": {"p256dh": "a", "auth": "b"}, "fp": server.push_fp(KEY)},
                {"endpoint": "https://web.push.apple.com/y", "keys": {"p256dh": "a", "auth": "b"}, "account": LEGACY,
                 "fp": server.push_fp(GUEST, BOUND)},
                {"endpoint": "https://web.push.apple.com/m", "keys": {"p256dh": "a", "auth": "b"}, "account": "admin",
                 "fp": server.push_fp(KEY)}]
        with open(os.path.join(self.stdir, "push.json"), "w") as f:
            json.dump({"subscriptions": subs}, f)

    def test_store_id_legacy(self):
        self.assertEqual(self.httpd.app.guest_store, LEGACY)
        # the frontend derives the local read-state key from the store in /api/auth/me (old deployment = legacy name, so read state survives a version change)
        self.assertEqual(self.guest("GET", "/api/auth/me")[1]["store"], LEGACY)

    def test_profile_reads_and_writes_legacy_files(self):
        code, p = self.guest("GET", "/api/profile")
        self.assertEqual((code, p["name"], p["avatar"], p["v"]), (200, "老昵称", True, 7))
        r, raw = self.req("GET", "/api/avatar", {"Cookie": v82_cookie(GUEST)})
        self.assertEqual((r.status, raw), (200, JPEG))
        # admin viewing guest bubbles: the new frontend uses account=guest, and the legacy name cached by an old frontend is also accepted
        for acc in ("guest", LEGACY):
            r, raw = self.req("GET", "/api/profile?account=" + acc, {"Cookie": v82_cookie(KEY)})
            self.assertEqual(json.loads(raw)["name"], "老昵称", acc)
            r, raw = self.req("GET", "/api/avatar?account=%s&v=7" % acc, {"Cookie": v82_cookie(KEY)})
            self.assertEqual(raw, JPEG, acc)
        self.assertEqual(self.guest("POST", "/api/profile", {"name": "新昵称"})[0], 200)
        with open(os.path.join(self.stdir, "profile-%s.json" % LEGACY)) as f:
            self.assertEqual(json.load(f)["name"], "新昵称")
        self.assertEqual(sorted(n for n in os.listdir(self.stdir) if "-guest." in n), [])  # no new-name file was created

    def test_push_legacy_subscriptions(self):
        app = self.httpd.app
        got = []
        app.push.sender = lambda s, payload, *a: got.append(s["endpoint"][-1]) or 201
        self.assertEqual(app.push.send_all({"kind": "show"}, "guest")["sent"], 1)
        self.assertEqual(got, ["y"])  # legacy-name subscriptions belong to the guest and do not leak to admin
        got.clear()
        app.push.send_all({"kind": "show"})
        self.assertEqual(sorted(got), ["a", "m"])
        # new guest subscriptions are still stored under the legacy name (the new name never appears in push.json, so a rollback still works)
        sub = {"endpoint": "https://web.push.apple.com/z", "keys": {"p256dh": "a", "auth": "b"}}
        self.assertEqual(self.guest("POST", "/api/push/subscribe", sub)[0], 200)
        with open(os.path.join(self.stdir, "push.json")) as f:
            accs = {s["endpoint"][-1]: s.get("account") for s in json.load(f)["subscriptions"]}
        self.assertEqual(accs, {"a": None, "y": LEGACY, "m": "admin", "z": LEGACY})


class NoLegacyConfigTest(Base):
    """Same legacy-name data but GUEST_LEGACY_ACCOUNT not configured: no legacy-name compatibility, the guest uses the generic name."""
    prepare_state = LegacyStateTest.prepare_state

    def test_store_is_generic(self):
        self.assertEqual(self.httpd.app.guest_store, "guest")
        self.assertEqual(self.guest("GET", "/api/auth/me")[1]["store"], "guest")
        code, p = self.guest("GET", "/api/profile")
        self.assertEqual((code, p["avatar"]), (200, False))  # legacy-name profile is not read
        self.assertNotEqual(p.get("name"), "老昵称")

    def test_legacy_name_not_guest(self):
        # an unknown account is an orphan (nobody gets it) and does not fall back to admin, so a deleted guest does not receive admin pushes
        self.assertEqual(push.Push.account_of({"account": LEGACY}), LEGACY)
        r, raw = self.req("GET", "/api/profile?account=" + LEGACY, {"Cookie": v82_cookie(KEY)})
        self.assertNotEqual(json.loads(raw).get("name"), "老昵称")
        got = []
        self.httpd.app.push.sender = lambda s, payload, *a: got.append(s["endpoint"][-1]) or 201
        self.assertEqual(self.httpd.app.push.send_all({"kind": "show"}, "guest")["sent"], 0)


class FreshStateTest(Base):
    """Fresh deployment: guest data is stored under the generic name."""

    def test_fresh_uses_generic_names(self):
        self.assertEqual(self.httpd.app.guest_store, "guest")
        self.assertEqual(self.guest("POST", "/api/profile", {"name": "a"})[0], 200)
        self.assertTrue(os.path.isfile(os.path.join(self.stdir, "profile-guest.json")))
        sub = {"endpoint": "https://web.push.apple.com/z", "keys": {"p256dh": "a", "auth": "b"}}
        self.assertEqual(self.guest("POST", "/api/push/subscribe", sub)[0], 200)
        self.assertEqual([s["account"] for s in self.httpd.app.push.subscriptions()], ["guest"])

    def test_store_id_rules(self):
        with tempfile.TemporaryDirectory() as d:
            on = {"GUEST_LEGACY_ACCOUNT": LEGACY}
            self.assertEqual(guestcfg.store_id(d, on), "guest")
            with open(os.path.join(d, "push.json"), "w") as f:
                json.dump({"subscriptions": [{"account": LEGACY}]}, f)
            self.assertEqual(guestcfg.store_id(d, on), LEGACY)  # having only a legacy subscription also counts as an old deployment
            self.assertEqual(guestcfg.store_id(d, {}), "guest")  # not recognized when no legacy name is configured
            self.assertEqual(guestcfg.labels(d, on), {"guest": LEGACY})
            with open(os.path.join(d, "profile-guest.json"), "w") as f:
                f.write("{}")
            self.assertEqual(guestcfg.store_id(d, on), "guest")  # existing new-name data means the new name is used
        with mock.patch.dict(os.environ, {"GUEST_LEGACY_ACCOUNT": LEGACY}):
            self.assertEqual(push.Push.account_of({"account": LEGACY}), "guest")
        self.assertEqual(push.Push.account_of({"account": "zzz"}), "zzz")  # orphan, not admin's
        self.assertEqual(push.Push.account_of({}), "admin")  # the earliest subscriptions without an account still belong to admin


class AdminOnlyPrefixTest(Base):
    """Private reverse-proxy prefixes (ADMIN_ONLY_PREFIXES): guests get 403, admin passes; none when not configured."""
    admin_only = ("/docs", "/tools")

    def test_parse(self):
        self.assertEqual(guestcfg.admin_only_prefixes({}), ())
        self.assertEqual(guestcfg.admin_only_prefixes({"ADMIN_ONLY_PREFIXES": " /docs/ ,/tools,docs,/a//b,/a/../b,/%2e,/docs"}),
                         ("/docs", "/tools"))

    def test_gate(self):
        for uri in ("/docs", "/docs/", "/docs/x.js?v=1", "/tools/a", "/docs/../api/snapshot"):
            self.assertEqual(self.check(uri, v82_cookie(GUEST))[0].status, 403, uri)
            if ".." not in uri:
                r, _ = self.check(uri, v82_cookie(KEY))
                self.assertEqual((r.status, r.getheader("X-ZBS-User")), (200, "admin"), uri)
        for uri in ("/docsx", "/toolsy/a", "/"):
            self.assertEqual(self.check(uri, v82_cookie(GUEST))[0].status, 200, uri)

    def test_not_configured_means_none(self):
        app = server.App(KEY, self.snap, self.projects, os.path.join(self.stdir, "s2.json"), guests=guests_for(KEY, GUEST))
        self.assertEqual(app.admin_only, ())


class PublicFilesTest(unittest.TestCase):
    """The private reverse-proxy section is not in the public Caddyfile / compose; the public Caddyfile pulls in private snippets via a glob import (starts fine with zero matches)."""

    def read(self, name):
        with open(os.path.join(ROOT, name), encoding="utf-8") as f:
            return f.read()

    def test_caddyfile_imports_private_glob(self):
        c = self.read("Caddyfile")
        self.assertNotIn("Proxy-Secret}", c)  # the shared secret is only referenced in private snippets
        m = re.search(r"^\s*import\s+(\S+)\s*$", c, re.M)
        self.assertIsNotNone(m)
        self.assertIn("*", m.group(1))  # Caddy fails to start when a single-file import is missing, but a glob with zero matches is fine
        # after the gate (private reverse proxies must pass the cookie gate first)
        self.assertLess(c.index("forward_auth"), c.index(m.group(0).strip()))

    def test_compose_mounts_private_dir(self):
        c = self.read("docker-compose.yml")
        self.assertRegex(c, r"- \./caddy-private:/etc/caddy/private:ro")

    def test_gitignore_and_example(self):
        g = self.read(".gitignore")
        self.assertIn("caddy-private/*.caddy", g)
        self.assertTrue(os.path.isfile(os.path.join(ROOT, "caddy-private", "proxy.caddy.example")))
        ex = self.read("caddy-private/proxy.caddy.example")
        self.assertIn("X-ZBS-User", ex)  # the snippet itself also only admits admin


class SlashCommandTest(Base):
    """Guest plain text starting with /: only GUEST_SLASH_COMMANDS entries pass (here /window; sent as-is without a prefix so Claude Code executes it), anything else gets 403 slash-forbidden;
    text with a quote or attachments gets the prefix as usual (it is not a command)."""

    def setUp(self):
        super().setUp()
        self.httpd.app.guest_slash = ("/window",)

    def test_slash_text_has_no_tag(self):
        T = guestcfg.DEFAULT_TAG
        send = lambda b: self.guest("POST", "/api/sessions/c1/send", b)[0]
        self.assertEqual(send({"text": "/window"}), 202)
        self.assertEqual(send({"text": "  /model opus  "}), 403)             # other commands are blocked
        self.assertEqual(send({"text": "/clear", "quote": ""}), 403)          # an empty quote equals no quote (still a command)
        self.assertEqual(send({"text": "/window 参数", "quote": ""}), 202)
        self.assertEqual(send({"text": "/x", "quote": "demo: 原文"}), 202)    # with a quote, the prefix is added as usual
        self.assertEqual(send({"text": "hi /window"}), 202)                   # slash not at the start: prefix added as usual
        self.assertEqual(send({"text": "/tmp/a.png 看"}), 202)             # a path is not a command: prefix added as usual
        with open(os.path.join(self.uploads, "20261019-010000-abcdef-a.png"), "wb") as f:
            f.write(b"\x89PNG x")
        self.httpd.app.uploadlog.add("20261019-010000-abcdef-a.png", "guest")  # uploaded by the guest themself (upload log, required)
        self.assertEqual(send({"files": ["20261019-010000-abcdef-a.png"], "text": "/window"}), 202)  # attachments: prefix added as usual
        self.assertEqual(sorted(self.outbox_texts()), sorted([
            ("text", "/window"), ("text", "/window 参数"),
            ("text", T + " > demo: 原文\n\n/x"), ("text", T + " hi /window"), ("text", T + " /tmp/a.png 看"), ("message", T + " /window")]))

    def test_default_empty_rejects_every_command(self):
        # GUEST_SLASH_COMMANDS unset: no slash command is allowed, /window included; non-commands still go out with the prefix
        self.httpd.app.guest_slash = ()
        send = lambda b: self.guest("POST", "/api/sessions/c1/send", b)
        self.assertEqual(send({"text": "/window"}), (403, {"error": "slash-forbidden"}))
        self.assertEqual(send({"text": "/tmp/a.png 看"})[0], 202)
        self.assertEqual(self.outbox_texts(), [("text", guestcfg.DEFAULT_TAG + " /tmp/a.png 看")])

    def test_slash_text_not_recallable_but_no_crash(self):
        # text without the prefix counts as admin's: recall gets 403, not 500
        self.assertEqual(self.guest("POST", "/api/sessions/c1/send", {"recall": "/window"})[0], 403)


if __name__ == "__main__":
    unittest.main()
