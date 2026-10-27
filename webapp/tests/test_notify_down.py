"""Server push when the Mac disconnects / the snapshot goes stale, helper heartbeat, and WorkBuddy error / stopped push texts.
Thresholds (internal convention with the mobile client): a stale page snapshot greys out the whole page after 30s; the server pushes "Mac disconnected" once after 90s of staleness, once per outage,
and the round right after the server itself wakes does not count; after an outage longer than 5 minutes, recovery (10s of continuous freshness) pushes "Mac recovered" once."""
import json
import os
import tempfile
import time
import unittest
from unittest import mock

from api import notify as N
from api import server
from helper import snapshot as H

NOW = time.time() + 1000


class LinkStepTest(unittest.TestCase):
    """Pure state machine: notify.link_step(state, now, stale, woke) -> (state, ev), ev in None / "down" / "up"."""

    def run_seq(self, seq):
        st, evs = N.new_link(), []
        for t, stale, woke in seq:
            st, ev = N.link_step(st, t, stale, woke)
            evs.append(ev)
        return st, evs

    def test_down_after_90s_once(self):
        st = N.new_link()
        st, ev = N.link_step(st, 0, True, False)
        self.assertIsNone(ev)
        st, ev = N.link_step(st, 89, True, False)
        self.assertIsNone(ev)
        st, ev = N.link_step(st, 90, True, False)
        self.assertEqual(ev, "down")
        for t in (91, 300, 900):
            st, ev = N.link_step(st, t, True, False)
            self.assertIsNone(ev)  # only one push per outage

    def test_up_needs_10s_fresh_and_5min_outage(self):
        st = N.new_link()
        for t in (0, 90, 400):
            st, _ = N.link_step(st, t, True, False)
        st, ev = N.link_step(st, 401, False, False)
        self.assertIsNone(ev)
        st, ev = N.link_step(st, 410, False, False)  # fresh for 9s: not recovered yet
        self.assertIsNone(ev)
        self.assertIsNotNone(st["since"])
        st, ev = N.link_step(st, 411, False, False)  # fresh for a full 10s, outage 401s >= 300
        self.assertEqual(ev, "up")
        self.assertIsNone(st["since"])

    def test_short_outage_no_up_push(self):
        st = N.new_link()
        for t in (0, 90, 200):
            st, _ = N.link_step(st, t, True, False)
        st, ev = N.link_step(st, 201, False, False)
        st, ev = N.link_step(st, 211, False, False)
        self.assertIsNone(ev)  # outage 201s < 300: no recovery push
        self.assertIsNone(st["since"])

    def test_flap_during_recovery_keeps_outage(self):
        st = N.new_link()
        for t in (0, 90):
            st, _ = N.link_step(st, t, True, False)
        st, _ = N.link_step(st, 95, False, False)
        st, ev = N.link_step(st, 100, True, False)  # stale again: still the same outage, no re-push
        self.assertIsNone(ev)
        self.assertEqual(st["since"], 0)

    def test_never_pushed_short_blip_clears(self):
        st = N.new_link()
        st, _ = N.link_step(st, 0, True, False)
        st, _ = N.link_step(st, 5, False, False)
        st, ev = N.link_step(st, 15, False, False)
        self.assertIsNone(ev)
        self.assertEqual(st, N.new_link())

    def test_woke_round_does_not_count(self):
        # the server itself just woke up (Mac lid reopened): this round is not an outage start and does not push
        st = N.new_link()
        st, ev = N.link_step(st, 0, True, True)
        self.assertIsNone(ev)
        self.assertIsNone(st["since"])
        st, ev = N.link_step(st, 1, True, False)
        self.assertIsNone(ev)
        st, ev = N.link_step(st, 60, True, False)
        self.assertIsNone(ev)  # only 59s since the first round after waking

    def test_woke_after_pushed_keeps_outage_for_up(self):
        st = N.new_link()
        for t in (0, 90):
            st, _ = N.link_step(st, t, True, False)
        st, ev = N.link_step(st, 2000, False, True)  # slept after an outage push: no action on the round after waking
        self.assertIsNone(ev)
        self.assertTrue(st["pushed"])
        st, ev = N.link_step(st, 2001, False, False)
        st, ev = N.link_step(st, 2011, False, False)
        self.assertEqual(ev, "up")


class DownReasonTest(unittest.TestCase):
    def test_reason_from_beat(self):
        self.assertEqual(N.down_reason(None, 100), "helper")                                    # no heartbeat file
        self.assertEqual(N.down_reason({"at": 10, "ok": False, "err": "timeout"}, 100), "helper")  # heartbeat is stale too
        self.assertEqual(N.down_reason({"at": 95, "ok": False, "err": "timeout"}, 100), "panel")   # heartbeat fresh, dump failed
        self.assertEqual(N.down_reason({"at": 95, "ok": False, "err": "missing"}, 100), "panel")
        self.assertEqual(N.down_reason({"at": 95, "ok": True}, 100), "helper")
        self.assertEqual(N.down_reason({"at": "x"}, 100), "helper")


class LocalizeLinkTest(unittest.TestCase):
    def test_mac_down_and_up_per_lang(self):
        a = N.link_action("down", "panel", "10:05")
        self.assertEqual(a["tag"], "mac-link")
        self.assertEqual(a["url"], "/")
        self.assertEqual(a["title"], "Mac 已断开")
        self.assertEqual(a["body"], "Soulgent 没响应，数据截至 10:05")
        en = N.localize(a, "en")
        self.assertEqual(en["title"], "Mac disconnected")
        self.assertEqual(en["body"], "Soulgent isn't responding. Data as of 10:05")
        self.assertEqual(N.localize(N.link_action("down", "helper", "09:00"), "hant")["body"], "小幫手停了，資料截至 09:00")
        up = N.link_action("up", None, None)
        self.assertEqual(up["tag"], "mac-link")  # same tag replaces the disconnect notification
        self.assertEqual(N.localize(up, "en")["title"], "Mac reconnected")
        self.assertEqual(N.localize(up, "hans")["title"], "Mac 已恢复")
        for k in ("ev", "reason", "at"):
            self.assertNotIn(k, N.localize(a, "en"))


class WorkBuddyPushTest(unittest.TestCase):
    def wb(self, code, **kw):
        s = {"id": "w", "kind": "workbuddy", "name": "alice", "status": "idle", "since": 50, "unread": True,
             "summary": {"state.error": "出错", "state.stopped": "已中止", "state.paused": "已暂停"}[code],
             "summaryCode": code, "summaryArgs": {}}
        s.update(kw)
        return s

    def fire(self, s, at):
        body = lambda sess, kind: N.wait_body(sess, []) if kind in ("err", "stopped") else N.FALLBACK_DONE
        st, _ = N.step(N.new_state(), [], 0, body)
        st, acts = N.step(st, [s], 1, body)
        self.assertEqual(acts, [])
        st, acts = N.step(st, [s], at, body)
        return acts

    def test_error_pushes_err_after_3s(self):
        acts = self.fire(self.wb("state.error"), 4)
        self.assertEqual(len(acts), 1)
        self.assertEqual(acts[0]["title"], "🔥 alice")
        self.assertEqual(acts[0]["body"], "出错了")  # the summary "出错" is synonymous with the label -> write the full word only
        self.assertEqual(N.localize(acts[0], "en")["title"], "🔥 alice")
        self.assertEqual(N.localize(acts[0], "en")["body"], "Error")

    def test_stopped_pushes_stopped(self):
        acts = self.fire(self.wb("state.stopped"), 11)
        self.assertEqual([(a["title"], a["body"]) for a in acts], [("🔥 alice", "已中止")])
        self.assertEqual(N.localize(acts[0], "en")["body"], "Stopped")

    def test_paused_is_plain_done(self):
        acts = self.fire(self.wb("state.paused"), 11)
        self.assertEqual([(a["ev"], a["title"]) for a in acts], [("done", "🔥 alice")])

    def test_not_unread_no_push(self):
        self.assertEqual(self.fire(self.wb("state.error", unread=False), 30), [])


class ServerDownTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.t = self.tmp.name
        self.snap = os.path.join(self.t, "snapshot.json")
        self.beat = os.path.join(self.t, "helper-beat.json")
        os.makedirs(os.path.join(self.t, "proj"))
        env = mock.patch.dict(os.environ, {"VAPID_PUBLIC_KEY": "PUB", "VAPID_PRIVATE_KEY": "PRIV"})
        env.start()
        self.addCleanup(env.stop)
        self.app = server.App("k" * 24, self.snap, os.path.join(self.t, "proj"), os.path.join(self.t, "st", "state.json"),
                              os.path.join(self.t, "ob"))
        self.sent = []
        self.app.push.send_all = lambda payload, account="admin": self.sent.append((account, payload)) or {}
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": NOW, "sessions": []}, f)

    def write_beat(self, at, ok, err=None):
        with open(self.beat, "w") as f:
            json.dump({"at": at, "ok": ok, "err": err, "tz": 8 * 3600}, f)

    def rounds(self, start, end):
        out = []
        t = start
        while t <= end:
            out += self.app.notify_round(t)
            t += 1
        return out

    def test_down_push_once_with_reason_and_local_time(self):
        self.write_beat(NOW + 200, False, "timeout")  # heartbeat always fresh (written forward in time below)
        self.assertEqual(self.rounds(NOW, NOW + 30), [])
        acts = []
        t = NOW + 31
        while t <= NOW + 31 + 95:
            self.write_beat(t, False, "timeout")
            acts += self.app.notify_round(t)
            t += 1
        self.assertEqual(len(acts), 1)
        a = acts[0]
        self.assertEqual(a["tag"], "mac-link")
        self.assertEqual(a["title"], "Mac 已断开")
        hm = time.strftime("%H:%M", time.gmtime(NOW + 8 * 3600))
        self.assertEqual(a["body"], "Soulgent 没响应，数据截至 " + hm)
        self.assertEqual([x[0] for x in self.sent], ["admin"])  # push to admin only
        # the round at 90s of staleness (staleness first noticed at NOW+31)
        self.assertEqual(self.rounds(NOW + 127, NOW + 400), [])  # no re-push (even a stale heartbeat does not push again)

    def test_snapshot_view_reports_down_reason(self):
        self.write_beat(NOW + 59, False, "missing")
        with mock.patch("api.server.time.time", return_value=NOW + 60):
            v = self.app.snapshot_view()
        self.assertTrue(v["stale"])
        self.assertEqual(v["down"], {"reason": "panel", "at": NOW})
        with mock.patch("api.server.time.time", return_value=NOW + 5):
            self.assertNotIn("down", self.app.snapshot_view())
        with mock.patch("api.server.time.time", return_value=NOW + 60):
            self.assertNotIn("down", self.app.snapshot_view_guest())  # not exposed to guests

    def test_recover_after_long_outage_pushes_up(self):
        self.rounds(NOW, NOW + 400)  # no heartbeat: the helper stopped
        self.assertEqual([p["title"] for _, p in self.sent], ["Mac 已断开"])
        self.assertIn("小帮手停了", self.sent[0][1]["body"])
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": NOW + 1000, "sessions": []}, f)
        os.utime(self.snap, (NOW + 1000, NOW + 1000))
        acts = []
        for t in range(int(NOW + 401), int(NOW + 413)):
            with open(self.snap, "w") as f:
                json.dump({"generatedAt": t, "sessions": []}, f)
            os.utime(self.snap, (t, t))
            acts += self.app.notify_round(t)
        self.assertEqual([a["title"] for a in acts], ["Mac 已恢复"])

    def test_server_sleep_gap_not_counted(self):
        self.app.notify_round(NOW)
        # the server slept for 10 minutes (Mac lid closed); the snapshot is not yet updated on waking
        self.assertEqual(self.app.notify_round(NOW + 600), [])
        self.assertEqual(self.rounds(NOW + 601, NOW + 680), [])  # less than 90s counted from waking
        self.assertEqual(self.sent, [])


class HelperBeatTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = self.tmp.name
        os.makedirs(os.path.join(self.d, "sessions"))
        os.makedirs(os.path.join(self.d, "projects"))

    def paths(self, cmd):
        return {"dump_cmd": cmd, "sessions_dir": os.path.join(self.d, "sessions"),
                "projects_dir": os.path.join(self.d, "projects"),
                "workzones": os.path.join(self.d, "wz.json"), "usage_dir": os.path.join(self.d, "nousage"),
                "out": os.path.join(self.d, "snapshot.json")}

    def beat(self):
        with open(os.path.join(self.d, "helper-beat.json")) as f:
            return json.load(f)

    def test_ok_beat(self):
        t0 = time.time()
        self.assertTrue(H.run_once(self.paths(["/bin/echo", "[]"])))
        b = self.beat()
        self.assertTrue(b["ok"])
        self.assertIsNone(b["err"])
        self.assertGreaterEqual(b["at"], t0)
        self.assertIsInstance(b["tz"], int)

    def test_fail_reasons(self):
        self.assertFalse(H.run_once(self.paths(["/usr/bin/false"])))
        self.assertEqual(self.beat()["err"], "exit:1")
        self.assertFalse(self.beat()["ok"])
        self.assertFalse(H.run_once(self.paths([os.path.join(self.d, "no-such-panel")])))
        self.assertEqual(self.beat()["err"], "missing")
        self.assertFalse(H.run_once(self.paths(["/bin/echo", "not json"])))
        self.assertEqual(self.beat()["err"], "parse")
        with mock.patch.object(H, "DUMP_TIMEOUT", 0.2):
            self.assertFalse(H.run_once(self.paths(["/bin/sleep", "3"])))
        self.assertEqual(self.beat()["err"], "timeout")


if __name__ == "__main__":
    unittest.main()
