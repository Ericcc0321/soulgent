"""Regression cases for medium/low severity security findings (module level): push subscriptions, panel path, VAPID generation, long-line paging, upload file names."""
import base64
import json
import os
import subprocess
import sys
import tempfile
import tracemalloc
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from api import outbox, push, transcript  # noqa: E402
from helper import snapshot  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sub(n, host="fcm.googleapis.com"):
    return {"endpoint": "https://%s/fcm/send/%s" % (host, n), "keys": {"p256dh": "P" + n, "auth": "A" + n}}


class PushTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "push.json")
        self.sent = []

    def mk(self, fps=None):
        p = push.Push(self.path, sender=lambda s, *a: self.sent.append(s["endpoint"]) or 201,
                      accounts=["admin", "guest", "carol"], fps=fps)
        return p

    # Web Push endpoints are only accepted from a few push services (SSRF protection)
    def test_endpoint_host_allowlist(self):
        for host in ("fcm.googleapis.com", "web.push.apple.com", "updates.push.services.mozilla.com",
                     "wns2-sg2p.notify.windows.com"):
            self.assertIsNotNone(push.clean_subscription(sub("1", host)), host)
        for bad in ("https://10.0.0.1/x", "https://localhost/x", "https://api:8080/x",
                    "https://fcm.googleapis.com.evil.example/x", "https://user@fcm.googleapis.com/x",
                    "https://fcm.googleapis.com:8443/x", "http://fcm.googleapis.com/x"):
            self.assertIsNone(push.clean_subscription({"endpoint": bad, "keys": {"p256dh": "p", "auth": "a"}}), bad)

    # quota is per account, so one guest cannot fill the whole site
    def test_per_account_quota(self):
        p = self.mk()
        for i in range(push.GUEST_MAX_SUBS):
            self.assertTrue(p.subscribe(sub("g%d" % i), "guest"))
        self.assertFalse(p.subscribe(sub("g-extra"), "guest"))
        self.assertTrue(p.subscribe(sub("z1"), "carol"))
        self.assertTrue(p.subscribe(sub("a1"), "admin"))  # admin is unaffected by guests
        self.assertTrue(p.subscribe(sub("g0"), "guest"))  # overwriting the same endpoint does not count as a new one

    def test_orphan_subscriptions_dont_take_slots(self):
        with open(self.path, "w") as f:
            json.dump({"subscriptions": [dict(sub("o%d" % i), account="gone") for i in range(30)]}, f)
        p = self.mk()
        self.assertTrue(p.subscribe(sub("a1"), "admin"))
        self.assertNotIn("gone", json.dumps(p.subscriptions()))  # orphan subscriptions are cleaned up on registration

    # after the key changes, subscriptions from old devices no longer receive pushes
    def test_key_rotation_revokes_old_subscriptions(self):
        p = self.mk(fps={"admin": "fp-old", "guest": "g-old"})
        p.subscribe(sub("a1"), "admin")
        p.subscribe(sub("g1"), "guest")
        p2 = self.mk(fps={"admin": "fp-new", "guest": "g-old"})  # admin changed WEBAPP_KEY
        r = p2.send_all({"kind": "show", "title": "t", "body": "b"}, "admin")
        self.assertEqual((r["sent"], self.sent), (0, []))
        self.assertEqual([s["endpoint"] for s in p2.subscriptions()], [sub("g1")["endpoint"]])  # old ones are removed
        p2.send_all({"kind": "show", "title": "t", "body": "b"}, "guest")
        self.assertEqual(self.sent, [sub("g1")["endpoint"]])

    def test_legacy_subscription_without_fp_not_adopted(self):
        with open(self.path, "w") as f:
            json.dump({"subscriptions": [sub("a1"), dict(sub("g1"), account="guest")]}, f)  # legacy subscription without fp
        p = self.mk(fps={"admin": "fp1", "guest": "g1"})
        self.assertEqual(p.send_all({"kind": "show", "title": "t", "body": "b"}, "admin")["sent"], 0)  # not claimed, not pushed
        self.assertEqual(p.send_all({"kind": "show", "title": "t", "body": "b"}, "guest")["sent"], 0)
        self.assertEqual(p.subscriptions(), [])  # removed; wait for the frontend to re-register
        self.assertEqual(self.sent, [])
        p.subscribe(sub("a1"), "admin")  # the frontend re-registers the same endpoint on startup: with the current fingerprint it is pushed as usual
        self.assertEqual(p.subscriptions()[0]["fp"], "fp1")
        self.assertEqual(p.send_all({"kind": "show", "title": "t", "body": "b"}, "admin")["sent"], 1)


class PushFingerprintTest(unittest.TestCase):
    """The guest subscription fingerprint includes the bound session: after rebinding, old devices stop receiving pushes; the admin fingerprint depends only on the key (existing subscriptions are unaffected)."""

    def mk_app(self, d, session):
        from api import guestcfg, server
        snap = os.path.join(d, "snap.json")
        with open(snap, "w") as f:
            json.dump({"generatedAt": 0, "zones": [], "sessions": []}, f)
        return server.App("k" * 24, snap, d, os.path.join(d, "st", "state.json"),
                          guests=[guestcfg.Guest("guest", "g" * 24, session, "GA")])

    def test_guest_fp_includes_bound_session(self):
        from api import server
        with tempfile.TemporaryDirectory() as d:
            a = self.mk_app(d, "Web-one").push.fps
            b = self.mk_app(d, "Web-two").push.fps
        self.assertNotEqual(a["guest"], b["guest"])  # session rebound: the fingerprint changes
        self.assertEqual(a["admin"], b["admin"])
        self.assertEqual(a["admin"], server.push_fp("k" * 24))  # admin formula unchanged (key only)
        self.assertEqual(a["guest"], server.push_fp("g" * 24, "Web-one"))
        self.assertNotEqual(server.push_fp("g" * 24, "Web-one"), server.push_fp("g" * 24))

    def test_rebind_revokes_old_guest_device(self):
        with tempfile.TemporaryDirectory() as d:
            sent = []
            app = self.mk_app(d, "Web-one")
            app.push.sender = lambda s, *a: sent.append(s["endpoint"]) or 201
            self.assertTrue(app.push.subscribe(sub("g1"), "guest"))
            app2 = self.mk_app(d, "Web-two")  # restart after changing GUEST_SESSION
            app2.push.sender = app.push.sender
            self.assertEqual(app2.push.send_all({"kind": "show", "title": "t", "body": "b"}, "guest")["sent"], 0)
            self.assertEqual(sent, [])


class PanelPathTest(unittest.TestCase):
    """SOULGENT_PANEL pointing at the Soulgent.app directory (as the README says) gets Contents/MacOS/Soulgent appended."""

    def test_app_dir_accepted(self):
        with tempfile.TemporaryDirectory() as t:
            app = os.path.join(t, "My Apps", "Soulgent.app")
            exe = os.path.join(app, "Contents", "MacOS", "Soulgent")
            os.makedirs(os.path.dirname(exe))
            open(exe, "w").close()
            self.assertEqual(snapshot.panel_path(env={"SOULGENT_PANEL": app}, webapp=t), exe)
            self.assertEqual(snapshot.panel_path(env={"SOULGENT_PANEL": app + "/"}, webapp=t), exe)
            self.assertEqual(snapshot.panel_path(env={"SOULGENT_PANEL": exe}, webapp=t), exe)  # a full path to the executable works as before


class GenVapidEmptyTest(unittest.TestCase):
    """Empty VAPID_*= lines copied from .env.example do not count as existing; keys must be generated and the empty lines replaced."""

    def test_fills_empty_placeholders(self):
        try:
            import cryptography  # noqa: F401
        except ImportError:
            self.skipTest("cryptography not installed")
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, ".env")
            with open(p, "w") as f:
                f.write("WEBAPP_KEY=abc\nVAPID_PRIVATE_KEY=\nVAPID_PUBLIC_KEY=\n# x\nVAPID_SUBJECT=mailto:me@demo.invalid\n")
            env = {k: v for k, v in os.environ.items() if k != "VAPID_SUBJECT"}
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "gen_vapid.py"), p],
                               capture_output=True, text=True, env=env)
            self.assertEqual((r.returncode, r.stdout.strip()), (0, "added"))
            lines = open(p).read().splitlines()
            kv = {}
            for ln in lines:
                if "=" in ln and not ln.startswith("#"):
                    k, v = ln.split("=", 1)
                    self.assertNotIn(k, kv, "duplicate %s" % k)
                    kv[k] = v
            self.assertEqual(len(kv["VAPID_PUBLIC_KEY"]), 87)
            self.assertTrue(kv["VAPID_PRIVATE_KEY"])
            self.assertEqual(kv["VAPID_SUBJECT"], "mailto:me@demo.invalid")
            self.assertEqual(lines[0], "WEBAPP_KEY=abc")

    def test_readme_command_has_env_path(self):
        with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as f:
            text = f.read()
        self.assertNotIn("`python3 tools/gen_vapid.py`", text)
        self.assertIn("tools/gen_vapid.py .env", text)


class LongLineTest(unittest.TestCase):
    """When paging hits an extra-long line containing a large image, the whole base64 is not parsed into a Python object (bounded peak memory), and text and image refs are still produced."""

    def test_big_image_line_bounded_memory(self):
        data = base64.b64encode(os.urandom(9 * 2**20)).decode()  # about 12 MiB of base64
        line = {"type": "user", "timestamp": "2026-10-25T01:00:00Z", "message": {"role": "user", "content": [
            {"type": "text", "text": "看这张大图"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": data}}]}}
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "s.jsonl")
            with open(p, "w") as f:
                f.write(json.dumps(line) + "\n")
            n = os.path.getsize(p)
            del data, line
            tracemalloc.start()
            page = transcript.read_page(p, None)
            _, peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()
        it = [i for i in page["items"] if i["role"] == "user"][0]
        self.assertEqual(it["text"], "看这张大图")
        self.assertEqual([f["kind"] for f in it["files"]], ["image"])
        self.assertLess(peak, 2.2 * n)  # about 3x or more when base64 is not cut off

    def test_oversize_line_skipped(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "s.jsonl")
            with open(p, "w") as f:
                f.write(json.dumps({"type": "user", "timestamp": "2026-10-25T01:00:00Z",
                                    "message": {"role": "user", "content": "前一句"}}) + "\n")
                f.write('{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"'
                        + "x" * (transcript.PAGE_LINE_MAX + 10) + '"}]}}\n')
            page = transcript.read_page(p, None)
        self.assertEqual([i["text"] for i in page["items"]], ["前一句"])


class FilenameTest(unittest.TestCase):
    def test_utf8_bytes_capped(self):
        """Long CJK names are truncated by UTF-8 bytes (with the 23-byte saved-name prefix staying within 255), and the extension is kept."""
        name = outbox.clean_filename("报" * 77 + ".md")
        self.assertTrue(name.endswith(".md"))
        saved = outbox.upload_name("报" * 77 + ".md", 1792400000.0)
        self.assertLessEqual(len(saved.encode("utf-8")), 255)
        self.assertTrue(outbox._SAVED_RE.match(saved))

    def test_double_dot_name_sendable(self):
        """A v1..txt upload must also be sendable."""
        with tempfile.TemporaryDirectory() as t:
            saved = outbox.upload_name("v1..txt", 1792400000.0)
            open(os.path.join(t, saved), "w").close()
            self.assertEqual(outbox.clean_files([saved], t), [saved])
            self.assertIsNone(outbox.clean_files(["../" + saved], t))
            self.assertIsNone(outbox.clean_files([".."], t))


if __name__ == "__main__":
    unittest.main()
