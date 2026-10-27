import os
import tempfile
import time
import unittest

from api.state import PIN_HOLD, State, flags_for


def sess(status="idle", since=1000.0, sid="a"):
    return {"id": sid, "status": status, "since": since}


class StateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "sub", "state.json")

    def test_installed_at_created_once_and_persisted(self):
        a = State(self.path)
        b = State(self.path)
        self.assertEqual(a.installed_at, b.installed_at)
        self.assertTrue(os.path.exists(self.path))

    def test_seen_and_pin_persist(self):
        s = State(self.path)
        self.assertEqual(s.seen_at("x"), 0.0)
        s.mark_seen("x", 100.0)
        s.mark_all_seen(["y", "z"], 200.0)
        s.set_pin("x", True)
        s2 = State(self.path)
        self.assertEqual(s2.seen_at("x"), 100.0)
        self.assertEqual(s2.seen_at("z"), 200.0)
        self.assertTrue(s2.pinned("x"))
        s2.set_pin("x", False)
        self.assertFalse(State(self.path).pinned("x"))

    def test_corrupt_file_recovers(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as f:
            f.write("{bad")
        self.assertEqual(State(self.path).seen_at("x"), 0.0)

    def test_unread_lifecycle(self):
        s = State(self.path)
        t0 = s.installed_at
        self.assertTrue(flags_for(s, sess(since=t0 + 10), t0 + 20)["unread"])
        s.mark_seen("a", t0 + 15)
        self.assertFalse(flags_for(s, sess(since=t0 + 10), t0 + 20)["unread"])
        self.assertTrue(flags_for(s, sess(since=t0 + 30), t0 + 40)["unread"])

    def test_finished_before_install_not_unread(self):
        s = State(self.path)
        self.assertFalse(flags_for(s, sess(since=s.installed_at - 5), s.installed_at)["unread"])

    def test_busy_and_waiting_never_unread(self):
        s = State(self.path)
        for st in ("busy", "waiting"):
            self.assertFalse(flags_for(s, sess(st, s.installed_at + 5), s.installed_at + 9)["unread"])

    def test_busy_clears_pin(self):
        s = State(self.path)
        s.set_pin("a", True)
        f = flags_for(s, sess("busy"), 5000.0)
        self.assertFalse(f["pinned"])
        self.assertFalse(State(self.path).pinned("a"))

    def test_short_busy_turn_missed_by_polling_unpins(self):
        s = State(self.path)
        s.set_pin("a", True, t=1000.0)
        # pinned, then did another round of work (later since); polling never caught busy
        self.assertFalse(flags_for(s, sess("idle", 1500.0), 2000.0)["pinned"])
        self.assertFalse(State(self.path).pinned("a"))

    def test_pin_kept_when_waiting_or_not_newer(self):
        s = State(self.path)
        s.set_pin("a", True, t=1000.0)
        self.assertTrue(flags_for(s, sess("waiting", 1500.0), 2000.0)["pinned"])
        self.assertTrue(flags_for(s, sess("idle", 900.0), 2000.0)["pinned"])
        self.assertEqual(State(self.path).pinned_at("a"), 1000.0)

    def test_rest_threshold(self):
        s = State(self.path)
        since = s.installed_at - 100
        edge = since + 6 * 3600
        self.assertFalse(flags_for(s, sess(since=since), edge)["rest"])
        self.assertTrue(flags_for(s, sess(since=since), edge + 1)["rest"])
        s.set_pin("a", True)
        self.assertFalse(flags_for(s, sess(since=since), edge + 1)["rest"])

    def test_topped_never_auto_rest(self):
        """A topped session is not auto-rested after 6 idle hours; manual rest still works."""
        s = State(self.path)
        since = s.installed_at - 100
        far = since + 7 * 3600
        self.assertTrue(flags_for(s, sess(since=since), far)["rest"])
        self.assertFalse(flags_for(s, sess(since=since), far, topped=True)["rest"])
        s.set_rest("a", True)
        self.assertTrue(flags_for(s, sess(since=since), far, topped=True)["rest"])

    def test_unread_is_not_rest(self):
        s = State(self.path)
        since = s.installed_at + 1
        self.assertFalse(flags_for(s, sess(since=since), since + 7 * 3600)["rest"])


if __name__ == "__main__":
    unittest.main()


class PanelMergeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.s = State(os.path.join(self.tmp.name, "state.json"))

    def test_seen_takes_max_of_api_and_panel(self):
        t0 = self.s.installed_at
        panel = {"seenAt": {"a": t0 + 50}, "pinned": []}
        self.assertFalse(flags_for(self.s, sess(since=t0 + 30), t0 + 60, panel)["unread"])
        self.assertTrue(flags_for(self.s, sess(since=t0 + 70), t0 + 80, panel)["unread"])
        self.s.mark_seen("a", t0 + 100)
        self.assertFalse(flags_for(self.s, sess(since=t0 + 70), t0 + 110,
                                   {"seenAt": {"a": t0 + 5}, "pinned": []})["unread"])

    def test_panel_pins_followed_when_no_recent_phone_change(self):
        panel = {"seenAt": {}, "pinned": ["a"]}
        self.assertTrue(flags_for(self.s, sess("waiting", 900.0), 2000.0, panel)["pinned"])
        self.assertFalse(flags_for(self.s, sess("waiting", 900.0), 2001.0,
                                   {"seenAt": {}, "pinned": []})["pinned"])

    def test_phone_pin_wins_within_hold_then_panel(self):
        self.s.set_pin("a", True, by_phone=True)
        changed = self.s.pin_changed_at("a")
        empty = {"seenAt": {}, "pinned": []}
        self.assertTrue(flags_for(self.s, sess("waiting", 1.0), changed + PIN_HOLD - 1, empty)["pinned"])
        self.assertFalse(flags_for(self.s, sess("waiting", 1.0), changed + PIN_HOLD, empty)["pinned"])

    def test_phone_unpin_wins_within_hold(self):
        self.s.set_pin("a", True)
        self.s.set_pin("a", False, by_phone=True)
        changed = self.s.pin_changed_at("a")
        self.assertGreater(changed, 0)
        f = flags_for(self.s, sess("waiting", 1.0), changed + 5, {"seenAt": {}, "pinned": ["a"]})
        self.assertFalse(f["pinned"])

    def test_no_panel_uses_api_own(self):
        self.s.set_pin("a", True, by_phone=True)
        self.assertTrue(flags_for(self.s, sess("waiting", 1.0), time.time() + 100)["pinned"])

    def test_busy_still_unpins_panel_pin(self):
        f = flags_for(self.s, sess("busy"), 5000.0, {"seenAt": {}, "pinned": ["a"]})
        self.assertFalse(f["pinned"])

    def test_pin_changed_persists(self):
        self.s.set_pin("a", False, by_phone=True)
        self.assertGreater(State(self.s.path).pin_changed_at("a"), 0)


class BackgroundTest(unittest.TestCase):
    """Background tasks running count as working; finishedAt = max(since, bgEndedAt); an agent turn with bgOwned counts as the user's wrap-up; bgStale is treated as plain idle."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.s = State(os.path.join(self.tmp.name, "state.json"))
        self.t0 = self.s.installed_at

    def bg(self, since, origin="user", **kw):
        d = sess(since=self.t0 + since)
        d["origin"] = origin
        for k, v in kw.items():
            d[k] = self.t0 + v if k == "bgEndedAt" and v is not None else v
        return d

    def test_helpers(self):
        from api.state import bg_live, finished_at
        self.assertTrue(bg_live({"bgTasks": 2}))
        self.assertFalse(bg_live({"bgTasks": 2, "bgStale": True}))
        self.assertFalse(bg_live({"bgTasks": 0}))
        self.assertFalse(bg_live({}))
        self.assertFalse(bg_live({"bgTasks": "3"}))  # wrong type counts as none
        self.assertEqual(finished_at({"since": 10, "bgEndedAt": 30}), 30)
        self.assertEqual(finished_at({"since": 10, "bgEndedAt": None}), 10)
        self.assertEqual(finished_at({"since": 40, "bgEndedAt": 30}), 40)
        self.assertEqual(finished_at({"since": None}), 0)

    def test_bg_live_suppresses_unread(self):
        f = flags_for(self.s, self.bg(10, bgTasks=2, bgStale=False), self.t0 + 20)
        self.assertFalse(f["unread"])
        self.assertTrue(flags_for(self.s, self.bg(10, bgTasks=0), self.t0 + 20)["unread"])

    def test_bg_live_suppresses_manual_unread(self):
        self.s.mark_unseen("a", self.t0, t=self.t0 + 5)
        self.assertFalse(flags_for(self.s, self.bg(10, bgTasks=1), self.t0 + 20)["unread"])

    def test_bg_live_blocks_auto_rest(self):
        now = self.t0 + 10 + 7 * 3600
        self.s.mark_seen("a", self.t0 + 20)
        self.assertFalse(flags_for(self.s, self.bg(10, bgTasks=1), now)["rest"])
        self.assertTrue(flags_for(self.s, self.bg(10, bgTasks=0), now)["rest"])

    def test_auto_rest_counts_from_finished(self):
        """Background ended only 1 hour ago: the 6 hours are counted from finishedAt, not from since."""
        now = self.t0 + 10 + 7 * 3600
        self.s.mark_seen("a", now)
        self.assertFalse(flags_for(self.s, self.bg(10, bgTasks=0, bgEndedAt=10 + 6 * 3600), now)["rest"])

    def test_stale_counts_as_idle(self):
        """A hung task does not count as working: the red dot appears as usual, and it does not block auto-rest (otherwise an endless loop would keep the session stuck as working)."""
        self.assertTrue(flags_for(self.s, self.bg(10, bgTasks=1, bgStale=True), self.t0 + 20)["unread"])
        self.s.mark_seen("a", self.t0 + 20)
        self.assertTrue(flags_for(self.s, self.bg(10, bgTasks=1, bgStale=True), self.t0 + 10 + 7 * 3600)["rest"])

    def test_stale_already_seen_not_unread(self):
        self.s.mark_seen("a", self.t0 + 15)
        self.assertFalse(flags_for(self.s, self.bg(10, bgTasks=1, bgStale=True), self.t0 + 20)["unread"])

    def test_finished_at_written_and_bg_ended_refreshes(self):
        """/tasks kills the last background task: no new turn, since is unchanged, bgEndedAt refreshes the completion time -> the red dot reappears even if already read."""
        self.s.mark_seen("a", self.t0 + 15)
        f = flags_for(self.s, self.bg(10, bgTasks=1), self.t0 + 20)
        self.assertFalse(f["unread"])
        self.assertEqual(f["finishedAt"], self.t0 + 10)
        f = flags_for(self.s, self.bg(10, bgTasks=0, bgEndedAt=30), self.t0 + 40)
        self.assertTrue(f["unread"])
        self.assertEqual(f["finishedAt"], self.t0 + 30)

    def test_agent_turn_bg_owned(self):
        f = flags_for(self.s, self.bg(10, origin="agent", bgTasks=0, bgOwned=False), self.t0 + 20)
        self.assertFalse(f["unread"])
        self.assertEqual(f["originTag"], {"kind": "agent"})
        f = flags_for(self.s, self.bg(10, origin="agent", bgTasks=0, bgOwned=True), self.t0 + 20)
        self.assertTrue(f["unread"])
        self.assertIsNone(f["originTag"])  # a background wrap-up is an ordinary completion, not tagged "handled a sub-agent report"

    def test_peer_turn_bg_owned_still_not_unread(self):
        self.assertFalse(flags_for(self.s, self.bg(10, origin="peer", bgTasks=0, bgOwned=True), self.t0 + 20)["unread"])

    def test_t0_t3_only_t3_unread_even_if_seen_midway(self):
        """T1 main turn stops but 2 background tasks run -> no red dot; T1.5 opened and viewed; T2 first one ends (agent turn, bgOwned, 1 left) -> no red dot;
        T3 last one ends -> red dot."""
        self.assertFalse(flags_for(self.s, self.bg(10, bgTasks=2), self.t0 + 11)["unread"])
        self.s.mark_seen("a", self.t0 + 15)
        self.assertFalse(flags_for(self.s, self.bg(20, origin="agent", bgOwned=True, bgTasks=1, bgEndedAt=19),
                                   self.t0 + 21)["unread"])
        self.assertTrue(flags_for(self.s, self.bg(30, origin="agent", bgOwned=True, bgTasks=0, bgEndedAt=29),
                                  self.t0 + 31)["unread"])

    def test_old_snapshot_without_fields_unchanged(self):
        f = flags_for(self.s, self.bg(10), self.t0 + 20)
        self.assertTrue(f["unread"])
        self.assertEqual(f["finishedAt"], self.t0 + 10)


class ErrorStateTest(unittest.TestCase):
    """disconnected is neither unread nor rested; errorKind triggers the red dot, and the unread timestamp uses max(finishedAt, errorSince)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.s = State(os.path.join(self.tmp.name, "state.json"))
        self.t0 = self.s.installed_at

    def one(self, since, origin="user", **kw):
        d = sess(since=self.t0 + since)
        d["origin"] = origin
        for k, v in kw.items():
            d[k] = self.t0 + v if k in ("errorSince", "disconnectedSince") and v is not None else v
        return d

    def test_helpers(self):
        from api.state import error_kind, is_gone
        self.assertTrue(is_gone({"disconnected": True}))
        self.assertFalse(is_gone({"disconnected": 1}))
        self.assertFalse(is_gone({}))
        for k in ("api", "rate_limit", "auth", "wb_error", "wb_stopped"):
            self.assertEqual(error_kind({"errorKind": k}), k)
        self.assertIsNone(error_kind({"errorKind": "weird"}))
        self.assertIsNone(error_kind({"errorKind": None}))
        self.assertIsNone(error_kind({}))

    def test_disconnected_not_unread(self):
        f = flags_for(self.s, self.one(10, disconnected=True, disconnectedSince=12), self.t0 + 20)
        self.assertFalse(f["unread"])
        self.assertTrue(flags_for(self.s, self.one(10), self.t0 + 20)["unread"])  # control: the same session without the disconnect gets the red dot

    def test_disconnected_ignores_manual_unread(self):
        self.s.mark_unseen("a", self.t0, t=self.t0 + 5)
        self.assertFalse(flags_for(self.s, self.one(10, disconnected=True), self.t0 + 20)["unread"])

    def test_disconnected_not_rest(self):
        """A grey card is kept for 10 minutes: even with a very old since it does not drop into the rest group; manual rest does not move it either."""
        now = self.t0 + 10 + 7 * 3600
        self.s.mark_seen("a", self.t0 + 20)
        self.assertFalse(flags_for(self.s, self.one(10, disconnected=True), now)["rest"])
        self.assertTrue(flags_for(self.s, self.one(10), now)["rest"])
        self.s.set_rest("a", True, t=self.t0 + 30)
        self.assertFalse(flags_for(self.s, self.one(10, disconnected=True), now)["rest"])

    def test_error_unread_and_error_since_counts(self):
        """Viewed (seen after since) but the error is later -> still a red dot; the round key finishedAt follows errorSince."""
        self.s.mark_seen("a", self.t0 + 15)
        f = flags_for(self.s, self.one(10, errorKind="api", errorStatus=529, errorSince=30), self.t0 + 40)
        self.assertTrue(f["unread"])
        self.assertEqual(f["finishedAt"], self.t0 + 30)
        self.s.mark_seen("a", self.t0 + 35)
        self.assertFalse(flags_for(self.s, self.one(10, errorKind="api", errorSince=30), self.t0 + 40)["unread"])

    def test_error_kinds_all_red_dot(self):
        for k in ("api", "rate_limit", "auth", "wb_error", "wb_stopped"):
            self.assertTrue(flags_for(self.s, self.one(10, errorKind=k, errorSince=10), self.t0 + 20)["unread"], k)

    def test_error_overrides_agent_origin_and_bg(self):
        """An error takes priority over turn origin and running background tasks: an agent turn (without bgOwned) or background still running also gets the red dot."""
        self.assertTrue(flags_for(self.s, self.one(10, origin="agent", errorKind="api", errorSince=10), self.t0 + 20)["unread"])
        self.assertTrue(flags_for(self.s, self.one(10, errorKind="rate_limit", errorSince=10, bgTasks=1), self.t0 + 20)["unread"])

    def test_error_busy_not_unread(self):
        s = dict(self.one(10, errorKind="api", errorSince=10), status="busy")
        self.assertFalse(flags_for(self.s, s, self.t0 + 20)["unread"])

    def test_disconnected_beats_error(self):
        s = self.one(10, errorKind="api", errorSince=10, disconnected=True)
        self.assertFalse(flags_for(self.s, s, self.t0 + 20)["unread"])

    def test_bad_error_kind_ignored(self):
        self.s.mark_seen("a", self.t0 + 15)
        f = flags_for(self.s, self.one(10, errorKind="weird", errorSince=30), self.t0 + 40)
        self.assertFalse(f["unread"])
        self.assertEqual(f["finishedAt"], self.t0 + 10)
