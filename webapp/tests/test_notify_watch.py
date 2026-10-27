import json
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import server

NOW = time.time() + 1000  # later than State.installed_at, so that unread holds


class WatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.t = self.tmp.name
        self.snap = os.path.join(self.t, "snapshot.json")
        self.proj = os.path.join(self.t, "proj")
        os.makedirs(self.proj)
        env = mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUB", "VAPID_PRIVATE_KEY": "PRIV"})
        env.start()
        self.addCleanup(env.stop)
        self.app = server.App("k" * 24, self.snap, self.proj, os.path.join(self.t, "st", "state.json"),
                              os.path.join(self.t, "ob"))
        self.sent = []
        self.app.push.send_all = lambda payload, account="admin": self.sent.append(payload) or {}

    def write(self, sessions, gen=NOW):
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": gen, "sessions": sessions}, f)
        os.utime(self.snap, (gen, gen + len(self.sent) + self._n()))

    def _n(self):
        self._c = getattr(self, "_c", 0) + 1
        return self._c

    def transcript(self, lines):
        rel = "t.jsonl"
        with open(os.path.join(self.proj, rel), "w", encoding="utf-8") as f:
            for obj in lines:
                f.write(json.dumps(obj, ensure_ascii=False) + "\n")
        return rel

    def test_wait_flow_with_transcript_and_recall(self):
        rel = self.transcript([{"type": "assistant", "timestamp": "t", "message": {"content": [
            {"type": "tool_use", "id": "1", "name": "AskUserQuestion",
             "input": {"questions": [{"question": "改不改？", "options": [{"label": "改"}]}]}}]}}])
        w = {"id": "a", "kind": "claude", "name": "alice", "status": "waiting", "since": NOW,
             "transcript": rel}
        self.write([], NOW)
        self.assertEqual(self.app.notify_round(NOW), [])  # baseline
        self.write([w], NOW + 1)
        self.assertEqual(self.app.notify_round(NOW + 1), [])
        self.write([w], NOW + 5)
        acts = self.app.notify_round(NOW + 5)
        self.assertEqual(len(acts), 1)
        self.assertEqual(acts[0]["title"], "🔥 alice")
        self.assertEqual(acts[0]["body"], "问你：改不改？")  # transcript question reads "Asks: ..." (no "[waiting]" label)
        self.assertEqual([p.get("badge") for p in self.sent], [1])  # the payload carries the badge count (1 waiting)
        self.assertEqual([{k: v for k, v in p.items() if k != "badge"} for p in self.sent], acts)
        self.write([dict(w, status="busy", since=NOW + 6)], NOW + 6)
        acts = self.app.notify_round(NOW + 6)
        self.assertEqual(acts, [])  # no recall push

    def test_done_uses_last_assistant_text(self):
        rel = self.transcript([{"type": "assistant", "timestamp": "t", "message": {"content": [
            {"type": "text", "text": "## 结果\n**全部**完成"}]}}])
        u = {"id": "a", "kind": "claude", "name": "alice", "status": "idle", "since": NOW + 100,
             "transcript": rel}
        self.write([], NOW)
        self.app.notify_round(NOW)
        t = NOW + 100
        self.write([u], t)
        self.app.notify_round(t)
        self.write([u], t + 11)
        acts = self.app.notify_round(t + 11)
        self.assertEqual([(a["title"], a["body"]) for a in acts], [("🔥 alice", "结果 全部完成")])

    def test_title_emoji_from_pet_manifest_and_override(self):
        """The title emoji follows the list avatar: installed pets from data/pets/manifest.json, overrides from data/pet-emoji.json (re-read when changed)."""
        from api import notify as N
        os.makedirs(os.path.join(self.t, "pets"))
        with open(os.path.join(self.t, "pets", "manifest.json"), "w") as f:
            json.dump({"boba": {}, "akaza": {}}, f)
        u = {"id": "a", "name": "alice", "status": "idle", "since": NOW + 100, "pet": "boba"}
        v = {"id": "c", "name": "bob", "status": "idle", "since": NOW + 100}  # no assigned pet: hash pick from the sorted manifest
        self.write([], NOW)
        self.app.notify_round(NOW)
        self.write([u, v], NOW + 1)
        self.app.notify_round(NOW + 1)
        self.write([dict(u, unread=True), dict(v, unread=True)], NOW + 100)
        acts = self.app.notify_round(NOW + 100)
        self.write([dict(u, unread=True), dict(v, unread=True)], NOW + 111)
        acts += self.app.notify_round(NOW + 111)
        self.assertEqual(len(acts), 2)
        want_b = N.pet_emoji(["akaza", "boba"][N.js_hash("c") % 2])
        self.assertEqual(N.js_hash("c") % 2, 0)  # "c" picks akaza, so the two titles differ
        self.assertEqual(sorted(a["title"] for a in acts), sorted([N.pet_emoji("boba") + " alice", want_b + " bob"]))
        self.assertEqual(self.app.pet_info()["names"], ["akaza", "boba"])
        with open(os.path.join(self.t, "pet-emoji.json"), "w") as f:
            json.dump({"boba": "🧋"}, f)
        os.utime(os.path.join(self.t, "pet-emoji.json"), (NOW + 5, NOW + 5))
        self.assertEqual(self.app.pet_info()["emoji"], {"boba": "🧋"})
        with open(os.path.join(self.t, "pet-emoji.json"), "w") as f:
            f.write("{bad json")
        os.utime(os.path.join(self.t, "pet-emoji.json"), (NOW + 6, NOW + 6))
        self.assertIsNone(self.app.pet_info()["emoji"])  # invalid file -> no override, no crash

    def test_seen_on_phone_recalls(self):
        u = {"id": "a", "name": "alice", "status": "idle", "since": NOW + 100}
        self.write([], NOW)
        self.app.notify_round(NOW)
        self.write([u], NOW + 100)
        self.app.notify_round(NOW + 100)
        self.write([u], NOW + 111)
        self.assertEqual(len(self.app.notify_round(NOW + 111)), 1)
        self.app.state.mark_seen("a", NOW + 112)
        self.write([u], NOW + 113)
        self.assertEqual(self.app.notify_round(NOW + 113), [])  # no recall push

    def test_stale_or_missing_snapshot_skips_round(self):
        self.assertEqual(self.app.notify_round(NOW), [])  # no snapshot file
        w = {"id": "a", "name": "alice", "status": "waiting", "since": NOW}
        self.write([], NOW)
        self.app.notify_round(NOW)
        self.write([w], NOW)
        self.app.notify_round(NOW)
        self.assertEqual(self.app.notify_round(NOW + 100), [])  # stale: no action
        # once the snapshot is fresh again: state is kept, timing counts from the first sighting, the delay has passed, so push immediately
        self.write([w], NOW + 101)
        acts = self.app.notify_round(NOW + 101)
        self.assertEqual(len(acts), 1)

    def test_no_vapid_key_no_send_but_state_advances(self):
        w = {"id": "a", "name": "alice", "status": "waiting", "since": NOW}
        self.write([], NOW)
        self.app.notify_round(NOW)
        self.write([w], NOW + 1)
        self.app.notify_round(NOW + 1)
        with mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": ""}):
            self.write([w], NOW + 5)
            self.assertEqual(len(self.app.notify_round(NOW + 5)), 1)
        self.assertEqual(self.sent, [])

    def test_send_error_does_not_raise(self):
        def boom(payload, account="admin"):
            raise OSError("x")
        self.app.push.send_all = boom
        w = {"id": "a", "name": "alice", "status": "waiting", "since": NOW}
        self.write([], NOW)
        self.app.notify_round(NOW)
        self.write([w], NOW + 1)
        self.app.notify_round(NOW + 1)
        self.write([w], NOW + 5)
        with mock.patch("sys.stderr"):
            self.assertEqual(len(self.app.notify_round(NOW + 5)), 1)

    def test_loop_survives_round_exception_and_stops(self):
        stop = threading.Event()
        calls = []

        def rnd():
            calls.append(1)
            if len(calls) == 1:
                raise RuntimeError("boom")
            stop.set()

        self.app.notify_round = rnd
        with mock.patch.object(server, "NOTIFY_POLL", 0.01), mock.patch("sys.stderr"):
            self.app.notify_loop(stop)
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
