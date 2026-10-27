"""Endpoints for the three swipe-left buttons: mark unread (unseen), rest, and off duty (offduty); plus the auto-release rules for manual rest."""
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

from api import outbox, server
from tests import _sig  # noqa: E402,F401  sets OUTBOX_SECRET (sending requires a signature)
from api.state import State, flags_for

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


class SwipeApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.outbox = os.path.join(t, "outbox")
        os.makedirs(self.outbox)
        self.snap_path = os.path.join(t, "snapshot.json")
        self.now = time.time()
        self.write_snap([
            {"id": "c1", "kind": "claude", "name": "Lab-a", "status": "idle", "since": self.now + 100},
            {"id": "c2", "kind": "claude", "name": "Lab-b", "status": "waiting", "since": self.now + 100},
            {"id": "c3", "kind": "claude", "name": "Lab-c", "status": "idle", "since": self.now + 100, "origin": "peer"},
            {"id": "c4", "kind": "shell", "name": "sh", "status": "idle", "since": self.now + 100},
            {"id": "c5", "kind": "claude", "name": "Lab-e", "status": "idle", "since": self.now - 50},
        ])
        patcher = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap_path, projects=t,
                                        state=os.path.join(t, "st", "state.json"), outbox_dir=self.outbox)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def write_snap(self, sessions):
        with open(self.snap_path, "w") as f:
            json.dump({"generatedAt": time.time(), "usage": {}, "zones": [], "sessions": sessions}, f)
        os.utime(self.snap_path, (time.time() + len(sessions), time.time() + len(sessions)))

    def req(self, method, path, body=None, auth=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Cookie": COOKIE} if auth else {}
        data = None
        if body is not None:
            data = json.dumps(body)
            headers["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=headers)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def reqs(self):
        out = []
        for n in sorted(os.listdir(self.outbox)):
            with open(os.path.join(self.outbox, n)) as f:
                out.append(json.load(f))
        return out

    def session(self, sid):
        _, d = self.req("GET", "/api/snapshot")
        return next(s for s in d["sessions"] if s["id"] == sid)

    def test_all_need_login(self):
        for p in ("unseen", "rest", "offduty"):
            self.assertEqual(self.req("POST", "/api/sessions/c1/" + p, {"on": True}, auth=False)[0], 401)
        self.assertEqual(os.listdir(self.outbox), [])

    def test_unseen_writes_seen_back_and_enqueues_mark(self):
        self.httpd.app.state.mark_seen("c1", self.now + 200)  # already seen (later than the last activity)
        self.assertFalse(self.session("c1")["unread"])
        r, d = self.req("POST", "/api/sessions/c1/unseen")
        self.assertEqual(r, 200)
        self.assertAlmostEqual(d["seenAt"], self.now + 99, places=3)
        self.assertTrue(self.session("c1")["unread"])
        marks = [q for q in self.reqs() if q.get("unseen")]
        self.assertEqual(len(marks), 1)
        self.assertEqual(marks[0]["type"], "mark")
        self.assertAlmostEqual(marks[0]["unseen"]["c1"], self.now + 99, places=3)

    def test_unseen_refuses_waiting_unknown(self):
        self.assertEqual(self.req("POST", "/api/sessions/c2/unseen"), (409, {"error": "not-markable"}))
        self.assertEqual(self.req("POST", "/api/sessions/zz/unseen")[0], 404)
        self.assertEqual(self.reqs(), [])

    def test_unseen_peer_and_agent_origin(self):
        """An idle session whose last activity is cross-session traffic / a sub-agent report can also be manually marked unread (the automatic red dot still ignores them), and no "finished" push is sent."""
        self.assertFalse(self.session("c3")["unread"])
        r, _ = self.req("POST", "/api/sessions/c3/unseen")
        self.assertEqual(r, 200)
        s = self.session("c3")
        self.assertTrue(s["unread"])
        self.assertTrue(s.get("manualUnread"))
        # mark read again: the red dot disappears
        self.assertEqual(self.req("POST", "/api/sessions/c3/seen")[0], 200)
        self.assertFalse(self.session("c3")["unread"])

    def test_rest_on_off(self):
        self.assertFalse(self.session("c5")["rest"])
        self.assertEqual(self.req("POST", "/api/sessions/c5/rest", {"on": True}), (200, {"ok": True}))
        self.assertTrue(self.session("c5")["rest"])
        self.assertEqual(self.req("POST", "/api/sessions/c5/rest", {"on": False}), (200, {"ok": True}))
        self.assertFalse(self.session("c5")["rest"])
        # last activity later than the rest moment (c1): the rest is invalidated immediately
        self.req("POST", "/api/sessions/c1/rest", {"on": True})
        self.assertFalse(self.session("c1")["rest"])

    def test_rest_bad_body_and_unknown(self):
        self.assertEqual(self.req("POST", "/api/sessions/c1/rest", {"on": "yes"})[0], 400)
        self.assertEqual(self.req("POST", "/api/sessions/zz/rest", {"on": True})[0], 404)

    def test_offduty_enqueues_with_snapshot_name(self):
        r, d = self.req("POST", "/api/sessions/c1/offduty")
        self.assertEqual(r, 202)
        q = self.reqs()
        self.assertEqual(len(q), 1)
        self.assertEqual((q[0]["type"], q[0]["sessionId"], q[0]["name"], q[0]["id"]),
                         ("offduty", "c1", "Lab-a", d["requestId"]))
        # the result query counts pending according to the off-duty timeout (90 seconds)
        st = outbox.request_status(self.outbox, d["requestId"], time.time() + 60)
        self.assertEqual(st, {"status": "pending"})

    def test_offduty_refuses_unknown_and_non_claude(self):
        self.assertEqual(self.req("POST", "/api/sessions/zz/offduty")[0], 404)
        self.assertEqual(self.req("POST", "/api/sessions/c4/offduty"), (409, {"error": "not-offdutyable"}))
        self.assertEqual(self.reqs(), [])


class ManualUnseenRuleTest(unittest.TestCase):
    """Mark unread: the Mac board writes back a larger seenAt, so the red dot must be held up by the api's marker."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.st = State(os.path.join(self.tmp.name, "state.json"))
        self.t = self.st.installed_at
        self.since = self.t + 100

    def flags(self, panel_seen=None, status="idle"):
        panel = {"seenAt": {"a": panel_seen} if panel_seen is not None else {}, "pinned": []}
        return flags_for(self.st, {"id": "a", "status": status, "since": self.since}, self.t + 1000, panel)

    def test_holds_even_if_panel_reverts(self):
        self.st.mark_unseen("a", self.since - 1, t=self.t + 300)
        self.assertTrue(self.flags(panel_seen=self.t + 200)["unread"])  # the board wrote back the old, larger value
        self.assertTrue(self.st.unseen_at("a"))

    def test_manual_flag_and_no_done_push(self):
        from api import notify
        self.st.mark_unseen("a", self.since - 1, t=self.t + 300)
        f = self.flags(panel_seen=self.t + 200)
        self.assertTrue(f.get("manualUnread"))
        s = dict({"id": "a", "name": "Lab-a", "status": "idle", "since": self.since}, **f)
        st, acts = notify.step(notify.new_state(), [], 0, lambda *_: "")  # run one round first: so this is not the first round
        st, acts = notify.step(st, [s], 1000, lambda *_: "")
        st, acts = notify.step(st, [s], 1000 + 60, lambda *_: "")
        self.assertEqual(acts, [])
        # really finished another round (since later than the read mark): counts as unread as usual, without manualUnread
        self.since = self.t + 400
        self.assertNotIn("manualUnread", self.flags(panel_seen=self.t + 200))

    def test_seen_on_mac_after_mark_clears(self):
        self.st.mark_unseen("a", self.since - 1, t=self.t + 300)
        self.assertFalse(self.flags(panel_seen=self.t + 400)["unread"])
        self.assertEqual(self.st.unseen_at("a"), 0.0)

    def test_seen_on_phone_clears(self):
        self.st.mark_unseen("a", self.since - 1, t=self.t + 300)
        self.st.mark_seen("a", self.t + 500)
        self.assertEqual(self.st.unseen_at("a"), 0.0)
        self.assertFalse(self.flags()["unread"])

    def test_busy_not_unread(self):
        self.st.mark_unseen("a", self.since - 1, t=self.t + 300)
        self.assertFalse(self.flags(status="busy")["unread"])

    def test_persisted(self):
        self.st.mark_unseen("a", self.since - 1, t=self.t + 300)
        self.assertEqual(State(self.st.path).unseen_at("a"), self.t + 300)


class ManualRestRuleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.st = State(os.path.join(self.tmp.name, "state.json"))
        self.t = self.st.installed_at

    def flags(self, status, since):
        return flags_for(self.st, {"id": "a", "status": status, "since": since}, self.t + 1000)

    def test_rest_holds_while_quiet(self):
        self.st.set_rest("a", True, t=self.t + 500)
        self.assertTrue(self.flags("idle", self.t + 400)["rest"])
        self.assertTrue(self.flags("idle", self.t + 500)["rest"])
        self.assertTrue(self.st.rest_at("a"))

    def test_new_activity_releases(self):
        self.st.set_rest("a", True, t=self.t + 500)
        f = self.flags("idle", self.t + 600)  # finished another round after resting (a new reply to you)
        self.assertFalse(f["rest"])
        self.assertTrue(f["unread"])
        self.assertEqual(self.st.rest_at("a"), 0.0)  # the record is deleted and will not come back

    def test_waiting_releases(self):
        self.st.set_rest("a", True, t=self.t + 500)
        self.assertFalse(self.flags("waiting", self.t + 400)["rest"])
        self.assertEqual(self.st.rest_at("a"), 0.0)

    def test_persisted(self):
        self.st.set_rest("a", True, t=self.t + 500)
        again = State(self.st.path)
        self.assertEqual(again.rest_at("a"), self.t + 500)


if __name__ == "__main__":
    unittest.main()
