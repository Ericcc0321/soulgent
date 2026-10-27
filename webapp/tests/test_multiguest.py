"""Multi-guest: roster config (GUEST_* + GUEST2_*), seamless migration of the first guest (guest A), an isolation matrix between two guests, and the slash-command whitelist.

All values here are fictional: Y = first guest (account guest, legacy name oldguest, tag [GA]), Z = second guest (account gb, tag [GB], nickname "访客B"),
A = a session only the admin can see. Every endpoint is tested with "Y takes Z's stuff" and "Z takes Y's stuff" -> 403/404."""
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
from urllib.parse import quote

from api import files, guestcfg, history, profile, push, server
from tests import _sig  # noqa: E402,F401  sets OUTBOX_SECRET (sending requires a signature)

KEY = "admin-key-0123456789abcdef"
YKEY = "guest-key-0123456789abcdef"
ZKEY = "gb-key-0123456789abcdefgh"
YSES, ZSES = "Web-guest-demo", "Ops-demo-proj"
YTAG, ZTAG = "[GA]", "[GB]"
Y = "1aaaaaaa-1111-4111-8111-111111111111"
Z = "2bbbbbbb-2222-4222-8222-222222222222"
A = "3ccccccc-3333-4333-8333-333333333333"
LEGACY = "oldguest"
UP_HOST = "/Users/zbs-test/webapp/data/uploads"
JPEG = b"\xff\xd8\xff\xe0" + b"j" * 40


def cookie(key):
    return "zbs=" + hmac.new(key.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


ENV = {"GUEST_KEY": YKEY, "GUEST_SESSION": YSES, "GUEST_TAG": YTAG, "GUEST_NAME": "访客A",
       "GUEST2_ID": "gb", "GUEST2_KEY": ZKEY, "GUEST2_SESSION": ZSES, "GUEST2_TAG": ZTAG, "GUEST2_NAME": "访客B"}


class LoadGuestsTest(unittest.TestCase):
    """.env -> roster: the old keys unchanged still define the first guest; the new keys add the second; an invalid entry is disabled entirely."""

    def load(self, env):
        with mock.patch("sys.stderr"):
            return guestcfg.load_guests(KEY, env, profile.guest_name_of)

    def test_legacy_keys_only_is_first_guest(self):
        gs = self.load({"GUEST_KEY": YKEY, "GUEST_SESSION": YSES, "GUEST_TAG": YTAG, "GUEST_NAME": "访客A"})
        self.assertEqual([(g.account, g.key, g.session, g.tag, g.name) for g in gs], [("guest", YKEY, YSES, YTAG, "访客A")])
        self.assertEqual(self.load({}), [])

    def test_second_guest(self):
        gs = self.load(ENV)
        self.assertEqual([(g.account, g.session, g.tag, g.name) for g in gs],
                         [("guest", YSES, YTAG, "访客A"), ("gb", ZSES, ZTAG, "访客B")])
        self.assertNotIn(ZKEY, repr(gs))  # repr does not include the key

    def test_defaults_and_gaps(self):
        gs = self.load({"GUEST3_ID": "gb", "GUEST3_KEY": ZKEY})  # no first guest; gaps in the numbering are still read
        self.assertEqual([(g.account, g.tag, g.name, g.session) for g in gs], [("gb", "[GB]", "访客", "")])

    def test_rejects(self):
        bad = [
            {"GUEST2_ID": "GB"}, {"GUEST2_ID": "guest"}, {"GUEST2_ID": "admin"}, {"GUEST2_ID": ""},
            {"GUEST2_ID": "a-b"}, {"GUEST2_ID": "x" * 17}, {"GUEST2_ID": LEGACY, "GUEST_LEGACY_ACCOUNT": LEGACY},
            {"GUEST2_KEY": "short"}, {"GUEST2_KEY": KEY}, {"GUEST2_KEY": YKEY},  # too short / same as admin / same as the first guest
            {"GUEST2_TAG": YTAG},  # same tag as the first guest: cannot tell who spoke
        ]
        for extra in bad:
            env = dict(ENV, **extra)
            self.assertEqual([g.account for g in self.load(env)], ["guest"], extra)
        env = dict(ENV, GUEST3_ID="gb", GUEST3_KEY="another-key-0123456789abcdef", GUEST3_TAG="[Z3]")
        self.assertEqual([g.account for g in self.load(env)], ["guest", "gb"])  # duplicate ids are not enabled

    def test_example_documents_keys(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(root, ".env.example"), encoding="utf-8") as f:
            ex = f.read()
        for k in ("GUEST2_ID=", "GUEST2_KEY=", "GUEST2_SESSION=", "GUEST2_TAG=", "GUEST2_NAME="):
            self.assertIn("\n" + k + "\n", ex, k)  # values left empty, no real keys


class Base(unittest.TestCase):
    legacy = ""

    def setUp(self):
        p = mock.patch.dict(os.environ)
        p.start()
        self.addCleanup(p.stop)
        os.environ.pop("GUEST_LEGACY_ACCOUNT", None)
        if self.legacy:
            os.environ["GUEST_LEGACY_ACCOUNT"] = self.legacy
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = self.tmp.name
        self.projects = os.path.join(d, "projects")
        os.makedirs(os.path.join(self.projects, "p"))
        for sid, text in ((Y, "hi guesta"), (Z, "hi gb"), (A, "hi admin secret")):
            self.write(sid, {"type": "user", "message": {"role": "user", "content": text}, "timestamp": "2026-10-19T01:00:00Z"})
        self.snap = os.path.join(d, "snapshot.json")
        self.now = time.time()
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": self.now, "zones": [{"code": "Web"}, {"code": "Ops"}], "sessions": [
                {"id": Y, "kind": "claude", "name": YSES, "plate": "guest-demo", "zone": "Web", "status": "idle",
                 "since": self.now, "transcript": "p/%s.jsonl" % Y},
                {"id": Z, "kind": "claude", "name": ZSES, "plate": "demo-proj", "zone": "Ops", "status": "idle",
                 "since": self.now, "transcript": "p/%s.jsonl" % Z, "cwd": UP_HOST + "/proj"},  # cwd must not be the mount root itself
                {"id": A, "kind": "claude", "name": "Web-admin-only", "plate": "admin-only", "zone": "Web", "status": "idle",
                 "since": self.now, "transcript": "p/%s.jsonl" % A}]}, f, ensure_ascii=False)
        self.outbox = os.path.join(d, "outbox")
        self.uploads = os.path.join(d, "uploads")
        os.makedirs(self.outbox)
        os.makedirs(self.uploads)
        self.stdir = os.path.join(d, "st")
        os.makedirs(self.stdir)
        self.prepare_state()
        with mock.patch("sys.stderr"):
            guests = guestcfg.load_guests(KEY, dict(ENV, **self.env_extra()), profile.guest_name_of)
        roots = files.Roots([(UP_HOST, self.uploads)], home="/Users/zbs-test")
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap, projects=self.projects,
                                        state=os.path.join(self.stdir, "state.json"), outbox_dir=self.outbox,
                                        uploads_dir=self.uploads, file_roots=roots, guests=guests)
        self.app = self.httpd.app
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def env_extra(self):
        return {}

    def prepare_state(self):
        pass

    def write(self, sid, *rows):
        with open(os.path.join(self.projects, "p", sid + ".jsonl"), "a", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")

    def queue(self, sid, *texts):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 20)) + ".000Z"
        self.write(sid, *[{"type": "queue-operation", "operation": "enqueue", "timestamp": ts, "content": t} for t in texts])

    def raw(self, method, path, key=None, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        if key:
            h["Cookie"] = cookie(key)
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r, out

    def call(self, key, method, path, body=None, headers=None):
        r, out = self.raw(method, path, key, body, headers)
        try:
            return r.status, json.loads(out)
        except ValueError:
            return r.status, out

    def outbox_reqs(self):
        out = []
        for n in sorted(os.listdir(self.outbox)):
            if n.endswith(".req.json"):
                with open(os.path.join(self.outbox, n), encoding="utf-8") as f:
                    out.append(json.load(f))
        return out


class LoginTest(Base):
    """Each key logs in as its own account; guest A's old cookie keeps working without re-login."""

    def test_each_key_logs_in_as_own_account(self):
        for k, acc, ses, tag, store in ((YKEY, "guest", YSES, YTAG, "guest"), (ZKEY, "gb", ZSES, ZTAG, "gb")):
            r, out = self.raw("POST", "/api/auth", body={"key": k}, headers={"X-Forwarded-For": "10.0.0.7"})
            self.assertEqual((r.status, json.loads(out)["user"]), (200, acc))
            self.assertRegex(r.getheader("Set-Cookie"), r"^zbs=[0-9a-f]{64}; ")  # a new per-device token
            self.assertFalse(r.getheader("Set-Cookie").startswith(cookie(k) + ";"))  # not the legacy formula
            code, me = self.call(k, "GET", "/api/auth/me")
            self.assertEqual((code, me["account"], me["session"], me["tag"], me["store"]), (200, acc, ses, tag, store))
            self.assertNotIn("guests", me)  # guests cannot get the roster
            r, _ = self.raw("GET", "/api/auth/check", k, headers={"X-Forwarded-Uri": "/", "Accept": "text/html"})
            self.assertEqual((r.status, r.getheader("X-ZBS-User")), (200, acc))
            # a legacy ?key= link is moved to the login page fragment for every account, without logging in from the GET
            r, _ = self.raw("GET", "/api/auth/check", headers={"X-Forwarded-Uri": "/?key=" + quote(k), "X-Forwarded-For": "10.0.0.8"})
            self.assertEqual((r.status, r.getheader("Location")), (302, "/login.html#k=%s&legacy=1" % quote(k, safe="")))
            self.assertIsNone(r.getheader("Set-Cookie"))

    def test_admin_me_lists_guests_without_keys(self):
        code, me = self.call(KEY, "GET", "/api/auth/me")
        self.assertEqual((code, me["user"], me["tag"]), (200, "admin", YTAG))  # tag unchanged = the first guest's
        self.assertEqual(me["guests"], [{"account": "guest", "tag": YTAG, "session": YSES},
                                        {"account": "gb", "tag": ZTAG, "session": ZSES}])
        self.assertNotIn(YKEY, json.dumps(me))
        self.assertNotIn(ZKEY, json.dumps(me))

    def test_guest_gate_still_blocks_admin_paths(self):
        for k in (YKEY, ZKEY):
            for uri in ("/api/search?q=ab", "/lab/x.html", "/api/seen-all"):
                r, _ = self.raw("GET", "/api/auth/check", k, headers={"X-Forwarded-Uri": uri})
                self.assertEqual(r.status, 403, (k[:3], uri))


class IsolationTest(Base):
    """Isolation matrix: every endpoint rejects Y->Z, Z->Y and both->A (403/404); each guest's own still works."""
    PAIRS = ((YKEY, Y, YTAG, Z, ZTAG), (ZKEY, Z, ZTAG, Y, YTAG))

    def test_snapshot_says_whose_it_is(self):
        """Snapshot response header X-Zbs-Account = which account the snapshot belongs to (the service worker keys its cache by it so offline data never crosses accounts)."""
        for k, acc in ((KEY, "admin"), (YKEY, "guest"), (ZKEY, "gb")):
            r, _ = self.raw("GET", "/api/snapshot", k)
            self.assertEqual((r.status, r.getheader("X-Zbs-Account")), (200, acc))

    @mock.patch.dict(os.environ, {"GUEST_ROSTER": "all"})
    def test_snapshot_only_own_session(self):
        for k, mine, _t, other, _o in self.PAIRS:
            code, snap = self.call(k, "GET", "/api/snapshot")
            self.assertEqual([s["id"] for s in snap["sessions"]], [mine])
            names = [r["name"] for r in snap["roster"]]
            self.assertNotIn(YSES if mine == Z else ZSES, names)  # the other guest's session is not in the roster either
            self.assertIn("Web-admin-only", names)  # the rest of the roster is unchanged (needed for group-chat avatars)
            self.assertNotIn(YSES if mine == Z else ZSES, json.dumps(snap, ensure_ascii=False))

    def test_snapshot_roster_bound_only_own(self):
        with mock.patch.dict(os.environ, {"GUEST_ROSTER": "bound"}):
            for k, mine, _t, other, _o in self.PAIRS:
                code, snap = self.call(k, "GET", "/api/snapshot")
                names = [r["name"] for r in snap["roster"]]
                self.assertEqual(names, [YSES if mine == Y else ZSES])
                self.assertNotIn("Web-admin-only", json.dumps(snap, ensure_ascii=False))

    def test_transcript(self):
        for k, mine, _t, other, _o in self.PAIRS:
            code, page = self.call(k, "GET", "/api/sessions/%s/transcript" % mine)
            self.assertEqual(code, 200)
            self.assertIn("hi gb" if mine == Z else "hi guesta", json.dumps(page, ensure_ascii=False))
            for sid in (other, A):
                self.assertEqual(self.call(k, "GET", "/api/sessions/%s/transcript" % sid)[0], 403, sid)
                self.assertEqual(self.call(k, "GET", "/api/sessions/%s/transcript?around=0" % sid)[0], 403, sid)

    def test_send_and_recall(self):
        for k, mine, tag, other, otag in self.PAIRS:
            for sid in (other, A):
                self.assertEqual(self.call(k, "POST", "/api/sessions/%s/send" % sid, {"text": "x"})[0], 403)
                self.assertEqual(self.call(k, "POST", "/api/sessions/%s/send" % sid, {"recall": otag + " x"})[0], 403)
            # recalling someone else's (the other guest's) message in your own session gives 403
            self.assertEqual(self.call(k, "POST", "/api/sessions/%s/send" % mine, {"recall": otag + " x"})[0], 403)
            self.assertEqual(self.call(k, "POST", "/api/sessions/%s/send" % mine, {"text": "hello"})[0], 202)
        reqs = self.outbox_reqs()
        self.assertEqual(sorted((r["sessionId"], r["text"]) for r in reqs),
                         sorted([(Y, YTAG + " hello"), (Z, ZTAG + " hello")]))  # each with its own tag and own session

    def test_recall_own_queued(self):
        self.queue(Z, ZTAG + " 撤我")
        code, out = self.call(ZKEY, "POST", "/api/sessions/%s/send" % Z, {"recall": ZTAG + " 撤我"})
        self.assertEqual(code, 202)
        self.assertEqual([r["type"] for r in self.outbox_reqs()], ["recall"])
        # another party's (admin's) message in the queue is not allowed through
        self.queue(Z, "管理员的话")
        self.assertEqual(self.call(ZKEY, "POST", "/api/sessions/%s/send" % Z, {"recall": ZTAG + " 撤我"})[1]["error"],
                         "admin-queued")

    def test_queued_counts(self):
        self.queue(Z, ZTAG + " z1", YTAG + " y1", "管理员 1")
        self.assertEqual(self.call(ZKEY, "GET", "/api/sessions/%s/transcript" % Z)[1]["queued"], 1)
        self.assertEqual(self.call(KEY, "GET", "/api/sessions/%s/transcript" % Z)[1]["queued"], 1)  # neither guest's messages count as the admin's

    def test_history_context_agent(self):
        for k, mine, _t, other, _o in self.PAIRS:
            for sid in (other, A):
                for path in ("/api/session/%s/search?q=hi", "/api/session/%s/lineage", "/api/session/%s/context",
                             "/api/session/%s/agent/abcdef12"):
                    self.assertEqual(self.call(k, "GET", path % sid)[0], 403, (path, sid))
            self.assertEqual(self.call(k, "GET", "/api/session/%s/search?q=hi" % mine)[0], 200)
            self.assertEqual(self.call(k, "GET", "/api/session/%s/lineage" % mine)[0], 200)
            self.assertEqual(self.call(k, "GET", "/api/session/%s/agent/abcdef12" % mine)[0], 404)  # own session: gets past the gate, just no such sub-agent

    def test_request_status_owner(self):
        code, out = self.call(YKEY, "POST", "/api/sessions/%s/send" % Y, {"text": "a"})
        rid_y = out["requestId"]
        code, out = self.call(ZKEY, "GET", "/api/session/%s/context" % Z)
        rid_z = out["rid"]
        self.assertEqual(self.call(YKEY, "GET", "/api/requests/" + rid_y)[0], 200)
        self.assertEqual(self.call(ZKEY, "GET", "/api/requests/" + rid_z)[0], 200)
        self.assertEqual(self.call(ZKEY, "GET", "/api/requests/" + rid_y)[0], 404)
        self.assertEqual(self.call(YKEY, "GET", "/api/requests/" + rid_z)[0], 404)
        self.assertEqual(self.call(KEY, "GET", "/api/requests/" + rid_y)[0], 200)  # the admin is unrestricted

    def test_profile_and_avatar(self):
        av = "data:image/jpeg;base64," + __import__("base64").b64encode(JPEG).decode()
        self.assertEqual(self.call(ZKEY, "POST", "/api/profile", {"name": "Z改名", "avatar": av})[0], 200)
        code, p = self.call(YKEY, "GET", "/api/profile")
        self.assertEqual((p["name"], p["avatar"], p["default"]), ("访客A", False, "访客A"))  # guest A's profile was not touched
        code, p = self.call(ZKEY, "GET", "/api/profile")
        self.assertEqual((p["name"], p["avatar"], p["default"]), ("Z改名", True, "访客B"))
        # guests ignore ?account= (they only get their own profile)
        self.assertEqual(self.call(YKEY, "GET", "/api/profile?account=gb")[1]["name"], "访客A")
        self.assertEqual(self.raw("GET", "/api/avatar?account=gb", YKEY)[0].status, 404)
        self.assertEqual(self.raw("GET", "/api/avatar", ZKEY)[1], JPEG)
        # the admin reads each account's profile by account
        self.assertEqual(self.call(KEY, "GET", "/api/profile?account=gb")[1]["name"], "Z改名")
        self.assertEqual(self.call(KEY, "GET", "/api/profile?account=guest")[1]["name"], "访客A")
        self.assertEqual(self.raw("GET", "/api/avatar?account=gb&v=1", KEY)[1], JPEG)
        self.assertEqual(self.call(KEY, "GET", "/api/profile?account=nobody")[0], 400)
        self.assertTrue(os.path.isfile(os.path.join(self.stdir, "profile-gb.json")))
        self.assertTrue(os.path.isfile(os.path.join(self.stdir, "avatar-gb.jpg")))
        self.assertFalse(os.path.exists(os.path.join(self.stdir, "avatar-guest.jpg")))

    def sub(self, k, tag, dev):
        body = {"endpoint": "https://web.push.apple.com/" + tag, "keys": {"p256dh": "a", "auth": "b"}, "dev": dev}
        return self.call(k, "POST", "/api/push/subscribe", body)

    def test_push_devices_and_delete(self):
        self.assertEqual(self.sub(YKEY, "y", "devYYYY11112222")[0], 200)
        self.assertEqual(self.sub(ZKEY, "z", "devZZZZ11112222")[0], 200)
        self.assertEqual(self.sub(KEY, "a", "devAAAA11112222")[0], 200)
        accs = {s["endpoint"][-1]: s["account"] for s in self.app.push.subscriptions()}
        self.assertEqual(accs, {"y": "guest", "z": "gb", "a": "admin"})
        dy = self.call(YKEY, "GET", "/api/push/devices")[1]["devices"]
        dz = self.call(ZKEY, "GET", "/api/push/devices")[1]["devices"]
        self.assertEqual(([d["dev"] for d in dy], [d["dev"] for d in dz]), (["devYYYY11112222"], ["devZZZZ11112222"]))
        # deleting the other guest's device: 404, the subscription remains
        self.assertEqual(self.call(YKEY, "POST", "/api/push/devices/delete", {"key": dz[0]["key"]})[0], 404)
        self.assertEqual(self.call(ZKEY, "POST", "/api/push/devices/delete", {"key": dy[0]["key"]})[0], 404)
        self.assertEqual(len(self.app.push.subscriptions()), 3)
        # sending is separated per account
        got = []
        self.app.push.sender = lambda s, payload, *a: got.append(s["endpoint"][-1]) or 201
        for acc in ("gb", "guest", "admin"):
            self.app.push.send_all({"kind": "show"}, acc)
        self.assertEqual(got, ["z", "y", "a"])
        self.assertEqual(self.call(ZKEY, "POST", "/api/push/devices/delete", {"key": dz[0]["key"]})[0], 200)

    def test_presence_separate(self):
        h = {"X-Zbs-Dev": "devZZZZ11112222", "X-Zbs-Act": "1", "X-Zbs-Seen": "s-%s:done" % Z}
        self.assertEqual(self.call(ZKEY, "GET", "/api/snapshot", headers=h)[0], 200)
        t = time.time()
        self.assertTrue(self.app.presence.active("gb", t))
        self.assertFalse(self.app.presence.active("guest", t))
        self.assertFalse(self.app.presence.active("admin", t))
        self.assertEqual(self.app.presence.seen("guest", t), {})
        self.assertEqual(self.call(YKEY, "POST", "/api/presence", {"dev": "devYYYY11112222", "act": 1})[0], 200)
        self.assertTrue(self.app.presence.active_dev("guest", "devYYYY11112222", time.time()))
        self.assertFalse(self.app.presence.active_dev("gb", "devYYYY11112222", time.time()))

    def test_files_tok_and_upload_owner(self):
        r, out = self.raw("POST", "/api/uploads?name=a.png", YKEY, b"\x89PNG yy", {"Content-Type": "application/octet-stream"})
        saved = json.loads(out)["file"]
        # Z sends using a filename Y uploaded: 403, nothing queued
        self.assertEqual(self.call(ZKEY, "POST", "/api/sessions/%s/send" % Z, {"files": [saved]})[0], 403)
        self.assertEqual(self.outbox_reqs(), [])
        self.assertEqual(self.call(YKEY, "POST", "/api/sessions/%s/send" % Y, {"files": [saved]})[0], 202)
        # signed links: each uses its own key; A's tok in B's hands gives 404
        exp = int(time.time()) + 600
        host = UP_HOST + "/" + saved
        ty = files.sign(host, exp, self.app.file_secret_for("guest"))
        tz = files.sign(host, exp, self.app.file_secret_for("gb"))
        self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(ty, safe=""), YKEY)[0].status, 200)
        self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(ty, safe=""), ZKEY)[0].status, 404)
        # Z signing with its own key does not help: the upload record says Y uploaded it into Y's session (ownership is checked against the record)
        self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(tz, safe=""), ZKEY)[0].status, 404)
        self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(tz, safe=""), YKEY)[0].status, 404)
        self.assertEqual(ty, files.sign(host, exp, self.app.file_secret))  # guest A's link is still signed with the original key (old links still open)
        # embedded images: a sid from the other session is always 404
        for k, other in ((YKEY, Z), (ZKEY, Y), (YKEY, A)):
            self.assertEqual(self.raw("GET", "/api/file?sid=%s&ref=0:1:abcdef12" % other, k)[0].status, 404)
        # the tok given in the page is signed per account
        self.write(Z, {"type": "user", "timestamp": "2026-10-19T02:00:00Z", "message": {"role": "user", "content": [
            {"type": "text", "text": ZTAG + " 看图 " + host}]}})
        page = self.call(ZKEY, "GET", "/api/sessions/%s/transcript" % Z)[1]
        toks = [f.get("tok") for it in page["items"] for f in it.get("files") or [] if f.get("tok")]
        for t in toks:
            self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(t, safe=""), YKEY)[0].status, 404)

    def test_reply_file_tok_per_guest_and_session(self):
        """For files mentioned in an Agent reply, the guest page gets a signed tok carrying the session sid; it only works in the guest's own bound session under its own key."""
        os.makedirs(os.path.join(self.uploads, "proj"), exist_ok=True)
        with open(os.path.join(self.uploads, "proj", "rep.xlsx"), "wb") as f:
            f.write(b"PK\x03\x04 gb sheet")
        host = UP_HOST + "/proj/rep.xlsx"
        for sid in (Z, A):
            self.write(sid, {"type": "assistant", "timestamp": "2026-10-19T02:00:00Z", "message": {"role": "assistant",
                       "content": [{"type": "text", "text": "表在 " + host}]}})
        page = self.call(ZKEY, "GET", "/api/sessions/%s/transcript" % Z)[1]
        fl = [f for it in page["items"] if it["role"] == "assistant" for f in it.get("files") or []]
        self.assertEqual([f["name"] for f in fl], ["rep.xlsx"])
        self.assertNotIn("path", fl[0])
        tz = fl[0]["tok"]
        r, out = self.raw("GET", "/api/file?tok=" + quote(tz, safe="") + "&dl=1", ZKEY)
        self.assertEqual((r.status, out), (200, b"PK\x03\x04 gb sheet"))
        self.assertTrue(r.getheader("Content-Disposition").startswith("attachment;"))
        self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(tz, safe=""), YKEY)[0].status, 404)  # Z's tok presented by Y
        exp = int(time.time()) + 600
        # Y signs with its own key for Z's / the admin's session: the sid is not Y's bound session, 404
        for sid in (Z, A):
            ty = files.sign_msg(sid, host, exp, self.app.file_secret_for("guest"))
            self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(ty, safe=""), YKEY)[0].status, 404)
        # Z signs the admin session A with its own key (A's reply also mentions this file): 404
        ta = files.sign_msg(A, host, exp, self.app.file_secret_for("gb"))
        self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(ta, safe=""), ZKEY)[0].status, 404)
        # the file was never mentioned in Y's own session: 404
        ty = files.sign_msg(Y, host, exp, self.app.file_secret_for("guest"))
        self.assertEqual(self.raw("GET", "/api/file?tok=" + quote(ty, safe=""), YKEY)[0].status, 404)
        with open(os.path.join(self.stdir, "guest-file.log"), encoding="utf-8") as f:
            rows = [ln.rstrip("\n").split("\t") for ln in f]
        self.assertEqual(rows[0][1:], ["gb", Z, "rep.xlsx", "200:ok", "t=full", "dl=1"])
        self.assertEqual(rows[1][1:5], ["guest", "-", "-", "404:deny:sig"])
        self.assertEqual(rows[2][1:5], ["guest", Z, "rep.xlsx", "404:deny:sid"])

    def test_diag_labels_account(self):
        ev = {"session": "pg1", "events": [{"k": "err", "where": "w", "msg": "m"}]}
        self.assertEqual(self.call(ZKEY, "POST", "/api/diag", ev)[0], 200)
        with open(os.path.join(self.stdir, "diag.jsonl"), encoding="utf-8") as f:
            self.assertEqual(json.loads(f.readline())["account"], "gb")

    def test_admin_untouched(self):
        self.assertEqual(self.call(KEY, "GET", "/api/sessions/%s/transcript" % Z)[0], 200)
        self.assertEqual(len(self.call(KEY, "GET", "/api/snapshot")[1]["sessions"]), 3)
        self.assertEqual(self.call(KEY, "POST", "/api/sessions/%s/send" % Z, {"text": "/model opus"})[0], 202)
        self.assertEqual([r["text"] for r in self.outbox_reqs()], ["/model opus"])  # admin slash commands are unrestricted

    def test_admin_search_marks_both_guests(self):
        for sid, tag in ((Y, YTAG), (Z, ZTAG)):
            self.write(sid, {"type": "user", "message": {"role": "user", "content": tag + " 命中"}, "timestamp": "2026-10-19T03:00:00Z"})
        for sid in (Y, Z):
            res = self.call(KEY, "GET", "/api/session/%s/search?q=%s" % (sid, quote("命中")))[1]["results"]
            self.assertEqual([r["from"] for r in res], ["guest"])
        # guest searching their own: own messages are marked guest
        res = self.call(ZKEY, "GET", "/api/session/%s/search?q=%s" % (Z, quote("命中")))[1]["results"]
        self.assertEqual([r["from"] for r in res], ["guest"])
        hits = history.search_file(os.path.join(self.projects, "p", Z + ".jsonl"), "命中", 10, [YTAG])
        self.assertEqual([h["from"] for h in hits], [""])  # only the given tags are recognised

    def test_notify_each_guest_only_own(self):
        app = self.app
        sent = []
        app.push.send_all = lambda payload, account="admin": sent.append((account, payload)) or {}
        app.state.installed_at = 0
        t0 = time.time()

        def snap(y, z):
            with open(self.snap, "w") as f:
                json.dump({"generatedAt": t0, "zones": [], "sessions": [
                    dict({"id": Y, "kind": "claude", "name": YSES, "zone": "Web", "plate": "guest-demo"}, **y),
                    dict({"id": Z, "kind": "claude", "name": ZSES, "zone": "Ops", "plate": "demo-proj"}, **z)]}, f)
            app._cache = None

        def tick(t):
            with open(self.snap) as f:
                d = json.load(f)
            d["generatedAt"] = t
            with open(self.snap, "w") as f:
                json.dump(d, f)
            app._cache = None
            app.notify_round(t)

        with mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUB"}):
            snap({"status": "busy", "since": 1}, {"status": "busy", "since": 1})
            tick(t0 + 100)
            snap({"status": "busy", "since": 1}, {"status": "idle", "since": 3, "origin": "user"})  # only Z has finished
            tick(t0 + 101)
            tick(t0 + 115)
        shows = [(acc, a.get("tag")) for acc, a in sent if a.get("kind") == "show" and acc != "admin"]
        self.assertEqual(shows, [("gb", "s-" + Z)])

    def test_guest_push_carries_badge(self):
        """Guest pushes carry the badge (the guest's one finished session = 1), else the guest's app icon never shows a count while the app is closed."""
        app = self.app
        sent = []
        app.push.send_all = lambda payload, account="admin": sent.append((account, payload)) or {}
        app.state.installed_at = 0
        t0 = time.time()

        def tick(t, z):
            with open(self.snap, "w") as f:
                json.dump({"generatedAt": t, "zones": [], "sessions": [
                    dict({"id": Z, "kind": "claude", "name": ZSES, "zone": "Ops", "plate": "demo-proj"}, **z)]}, f)
            app._cache = None
            app.notify_round(t)

        with mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUB"}):
            tick(t0 + 100, {"status": "busy", "since": 1})
            tick(t0 + 101, {"status": "idle", "since": 3, "origin": "user"})
            tick(t0 + 115, {"status": "idle", "since": 3, "origin": "user"})
        guest = [a for acc, a in sent if acc == "gb" and a.get("kind") == "show"]
        self.assertEqual([a.get("badge") for a in guest], [1])

    def test_guest_notify_disconnected_and_error(self):
        """The guest push table behaves the same: an unexpected exit is not unread (notify handles the unexpected-exit push); errors count as unread, with the round key following errorSince."""
        app = self.app
        app.state.installed_at = 0
        g = app.guests["gb"]

        def z(**kw):
            with open(self.snap, "w") as f:
                json.dump({"generatedAt": self.now, "zones": [], "sessions": [
                    dict({"id": Z, "kind": "claude", "name": ZSES, "zone": "Ops", "plate": "demo-proj", "status": "idle",
                          "since": 10, "origin": "user"}, **kw)]}, f)
            app._cache = None
            return app.guest_notify_sessions(g)[0]

        self.assertTrue(z()["unread"])
        self.assertFalse(z(disconnected=True, disconnectedSince=20)["unread"])
        e = z(origin="agent", errorKind="api", errorSince=30)
        self.assertTrue(e["unread"])
        self.assertEqual(e["finishedAt"], 30)

    def test_guest_notify_never_lost(self):
        """An "unexpected exit" is pushed to the admin only: disconnected is cleared in the guest push table, so notify never emits lost."""
        from api import notify
        app = self.app
        app.state.installed_at = 0
        g = app.guests["gb"]
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": self.now, "zones": [], "sessions": [
                {"id": Z, "kind": "claude", "name": ZSES, "zone": "Ops", "plate": "demo-proj", "status": "idle",
                 "since": 10, "origin": "user", "disconnected": True, "disconnectedSince": 20}]}, f)
        app._cache = None
        item = app.guest_notify_sessions(g)[0]
        self.assertFalse(item.get("disconnected"))
        st = notify.new_state()
        st, _ = notify.step(st, [item], 1000, lambda s, k: "x")
        st, acts = notify.step(st, [item], 1100, lambda s, k: "x")
        self.assertNotIn("lost", [a.get("ev") for a in acts])
        # admin semantics unchanged: the same session passed straight to notify still yields lost
        adm = dict(item, disconnected=True, disconnectedSince=20)
        self.assertEqual(notify._trigger(adm)[0], "lost")


class SlashTest(Base):
    """Guests may only use the commands in GUEST_SLASH_COMMANDS (here /window; arguments allowed, no tag prefix); other slash commands give 403 slash-forbidden and nothing is queued. The admin is unrestricted."""

    def setUp(self):
        super().setUp()
        self.app.guest_slash = ("/window",)

    def test_whitelist(self):
        for k, sid, tag in ((YKEY, Y, YTAG), (ZKEY, Z, ZTAG)):
            send = lambda b: self.call(k, "POST", "/api/sessions/%s/send" % sid, b)
            for t in ("/model opus", "/clear", "/compact x", "/windows", "/Window", " /exit "):
                code, out = send({"text": t})
                self.assertEqual((code, out.get("error")), (403, "slash-forbidden"), t)
            self.assertEqual(self.outbox_reqs(), [])
            self.assertEqual(send({"text": "/window"})[0], 202)
            self.assertEqual(send({"text": "  /window 换个窗  "})[0], 202)
            self.assertEqual(send({"text": "/tmp/a.png 看"})[0], 202)        # a path is not a command
            self.assertEqual(send({"text": "/x", "quote": "demo: 原文"})[0], 202)  # with a quote it is not a command
            self.assertEqual(send({"text": "说 /model"})[0], 202)              # the slash is not at the start
            self.assertEqual(send({"text": "/window/x"})[0], 202)              # a / inside the command name makes it a path, not a command
            got = sorted(r["text"] for r in self.outbox_reqs())
            self.assertEqual(got, sorted(["/window", "/window 换个窗", tag + " /tmp/a.png 看",
                                          tag + " > demo: 原文\n\n/x", tag + " 说 /model", tag + " /window/x"]))
            for n in os.listdir(self.outbox):
                os.unlink(os.path.join(self.outbox, n))

    def test_files_with_slash_text_tagged(self):
        with open(os.path.join(self.uploads, "20261019-010000-abcdef-a.png"), "wb") as f:
            f.write(b"\x89PNG x")
        self.app.uploadlog.add("20261019-010000-abcdef-a.png", "gb")  # uploaded by Z itself (upload record)
        self.assertEqual(self.call(ZKEY, "POST", "/api/sessions/%s/send" % Z,
                                   {"files": ["20261019-010000-abcdef-a.png"], "text": "/model"})[0], 202)
        self.assertEqual([r["text"] for r in self.outbox_reqs()], [ZTAG + " /model"])

    def test_list_delivered_to_each_guest(self):
        # the frontend blocks the same commands the server rejects: /api/auth/me gives every guest the list; the admin is unrestricted and gets none
        for k in (YKEY, ZKEY):
            self.assertEqual(self.call(k, "GET", "/api/auth/me")[1]["slash"], ["/window"])
        self.assertNotIn("slash", self.call(KEY, "GET", "/api/auth/me")[1])


class LegacyMigrationTest(Base):
    """Seamless migration of guest A: after an old deployment (GUEST_LEGACY_ACCOUNT = legacy name, the state volume holds legacy-named files) adds a second guest, guest A's profile, avatar and push subscriptions stay as they were,
    with no rename and no new file; GB's data goes under the gb name; subscriptions of an unconfigured legacy account become orphans (sent to nobody, not falling back to the admin)."""
    legacy = LEGACY

    def prepare_state(self):
        with open(os.path.join(self.stdir, "profile-%s.json" % LEGACY), "w") as f:
            json.dump({"name": "访客A自己改的", "v": 7}, f, ensure_ascii=False)
        with open(os.path.join(self.stdir, "avatar-%s.jpg" % LEGACY), "wb") as f:
            f.write(JPEG)
        subs = [{"endpoint": "https://web.push.apple.com/a", "keys": {"p256dh": "a", "auth": "b"}, "fp": server.push_fp(KEY)},
                {"endpoint": "https://web.push.apple.com/y", "keys": {"p256dh": "a", "auth": "b"}, "account": LEGACY,
                 "fp": server.push_fp(YKEY, YSES)},
                {"endpoint": "https://web.push.apple.com/o", "keys": {"p256dh": "a", "auth": "b"}, "account": "removedguest"}]
        with open(os.path.join(self.stdir, "push.json"), "w") as f:
            json.dump({"subscriptions": subs}, f)

    def test_guesta_unchanged(self):
        self.assertEqual(self.app.guests["guest"].store, LEGACY)
        code, me = self.call(YKEY, "GET", "/api/auth/me")
        self.assertEqual((me["user"], me["account"], me["store"], me["tag"]), ("guest", "guest", LEGACY, YTAG))
        code, p = self.call(YKEY, "GET", "/api/profile")
        self.assertEqual((p["name"], p["avatar"], p["v"]), ("访客A自己改的", True, 7))
        self.assertEqual(self.call(KEY, "GET", "/api/profile?account=" + LEGACY)[1]["name"], "访客A自己改的")  # old frontend, legacy name
        self.assertEqual(self.call(ZKEY, "GET", "/api/profile")[1]["name"], "访客B")
        self.assertEqual(self.call(ZKEY, "POST", "/api/profile", {"name": "z"})[0], 200)
        self.assertEqual(sorted(n for n in os.listdir(self.stdir) if n.startswith(("profile-", "avatar-"))),
                         ["avatar-%s.jpg" % LEGACY, "profile-gb.json", "profile-%s.json" % LEGACY])

    def test_push_routes(self):
        got = []
        self.app.push.sender = lambda s, payload, *a: got.append(s["endpoint"][-1]) or 201
        for acc in ("guest", "gb", "admin"):
            got.append(acc)
            self.app.push.send_all({"kind": "show"}, acc)
        self.assertEqual(got, ["guest", "y", "gb", "admin", "a"])  # the orphan o is sent to nobody
        self.assertEqual(self.sub_store(), {"a": None, "y": LEGACY, "o": "removedguest"})
        body = {"endpoint": "https://web.push.apple.com/z", "keys": {"p256dh": "a", "auth": "b"}}
        self.assertEqual(self.call(ZKEY, "POST", "/api/push/subscribe", body)[0], 200)
        body = dict(body, endpoint="https://web.push.apple.com/w")
        self.assertEqual(self.call(YKEY, "POST", "/api/push/subscribe", body)[0], 200)
        self.assertEqual(self.sub_store()["z"], "gb")
        self.assertEqual(self.sub_store()["w"], LEGACY)  # guest A's new subscription is still stored under the legacy name

    def sub_store(self):
        with open(os.path.join(self.stdir, "push.json")) as f:
            return {s["endpoint"][-1]: s.get("account") for s in json.load(f)["subscriptions"]}

    def test_account_of(self):
        p = self.app.push
        self.assertEqual([p._acc({"account": a}) for a in (None, "admin", LEGACY, "guest", "gb", "removedguest")],
                         ["admin", "admin", "guest", "guest", "gb", "removedguest"])
        self.assertFalse(p.subscribe({"endpoint": "https://web.push.apple.com/q", "keys": {"p256dh": "a", "auth": "b"}},
                                     "nobody"))


class SingleGuestCompatTest(unittest.TestCase):
    """A single guest configured with only the old GUEST_* keys (the startup path: guestcfg.load_guests) is the first guest."""

    def test_old_keys(self):
        with tempfile.TemporaryDirectory() as d:
            snap = os.path.join(d, "s.json")
            with open(snap, "w") as f:
                json.dump({"sessions": []}, f)
            env = {"GUEST_KEY": YKEY, "GUEST_SESSION": YSES, "GUEST_TAG": YTAG}
            app = server.App(KEY, snap, d, os.path.join(d, "st", "state.json"),
                             guests=guestcfg.load_guests(KEY, env, profile.guest_name_of))
            self.assertEqual(list(app.guests), ["guest"])
            self.assertEqual((app.guest_session, app.guest_tag, app.keys["guest"]), (YSES, YTAG, YKEY))
            app2 = server.App(KEY, snap, d, os.path.join(d, "st", "state.json"),
                              guests=guestcfg.load_guests(KEY, dict(env, GUEST_KEY=KEY), profile.guest_name_of))
            self.assertEqual(list(app2.guests), [])  # not enabled when it is the same key as admin


if __name__ == "__main__":
    unittest.main()
