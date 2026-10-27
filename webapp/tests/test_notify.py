import unittest

from api import notify as N


def sess(sid="a", status="waiting", since=100.0, unread=False, name="工作A", summary=""):
    return {"id": sid, "name": name, "status": status, "since": since, "unread": unread, "summary": summary}


def body(s, kind):
    return "B-" + kind


def run(state, sessions, now):
    return N.step(state, sessions, now, body)


class StepTest(unittest.TestCase):
    def test_baseline_no_push_then_no_recall(self):
        st, acts = run(N.new_state(), [sess(status="waiting"), sess("u", "idle", unread=True)], 1000)
        self.assertEqual(acts, [])
        st, acts = run(st, [sess(status="waiting"), sess("u", "idle", unread=True)], 1100)
        self.assertEqual(acts, [])
        st, acts = run(st, [sess(status="busy", since=1200)], 1201)  # all baseline sessions have finished: nothing was pushed, so nothing is recalled
        self.assertEqual(acts, [])

    def test_wait_delay(self):
        st, _ = run(N.new_state(), [], 0)
        st, acts = run(st, [sess()], 10)
        self.assertEqual(acts, [])
        st, acts = run(st, [sess()], 12.9)
        self.assertEqual(acts, [])
        st, acts = run(st, [sess()], 13)
        self.assertEqual(acts, [{"kind": "show", "tag": "s-a", "title": "🔥 工作A", "body": "B-wait",
                                 "text": "B-wait", "url": "/#s/a", "timestamp": 100000, "ev": "wait", "name": "工作A",
                                 "untitled": False, "fb": False, "av": {"id": "a", "st": "wait"}, "emoji": "🔥"}])
        # rebuilt in the subscription language before sending; title = emoji + session name, body = the message itself
        self.assertEqual(N.localize(acts[0], None), {"kind": "show", "tag": "s-a", "title": "🔥 工作A",
                                                     "body": "B-wait", "url": "/#s/a", "timestamp": 100000})

    def test_same_round_once(self):
        st, _ = run(N.new_state(), [], 0)
        st, _ = run(st, [sess()], 10)
        st, acts = run(st, [sess()], 14)
        self.assertEqual(len(acts), 1)
        for t in (15, 30, 300):
            st, acts = run(st, [sess()], t)
            self.assertEqual(acts, [])

    def test_new_round_pushes_again(self):
        st, _ = run(N.new_state(), [], 0)
        st, _ = run(st, [sess()], 10)
        st, acts = run(st, [sess()], 14)
        st, acts = run(st, [sess(status="busy", since=20)], 20)
        self.assertEqual(acts, [])  # no recall push
        st, acts = run(st, [sess(since=30)], 30)
        self.assertEqual(acts, [])
        st, acts = run(st, [sess(since=30)], 33)
        self.assertEqual([a["kind"] for a in acts], ["show"])

    def test_short_wait_never_pushed_no_recall(self):
        st, _ = run(N.new_state(), [], 0)
        st, _ = run(st, [sess()], 10)
        st, acts = run(st, [sess(status="busy", since=11)], 11)
        self.assertEqual(acts, [])
        st, acts = run(st, [sess(since=12)], 20)  # a new round restarts the timer
        self.assertEqual(acts, [])

    def test_since_change_while_waiting_restarts_timer(self):
        st, _ = run(N.new_state(), [], 0)
        st, _ = run(st, [sess(since=1)], 10)
        st, acts = run(st, [sess(since=2)], 12)
        st, acts = run(st, [sess(since=2)], 14)
        self.assertEqual(acts, [])
        st, acts = run(st, [sess(since=2)], 15)
        self.assertEqual(len(acts), 1)

    def test_unread_delay_and_text(self):
        st, _ = run(N.new_state(), [], 0)
        u = sess(status="idle", unread=True, since=50)
        st, acts = run(st, [u], 100)
        st, acts = run(st, [u], 109.9)
        self.assertEqual(acts, [])
        st, acts = run(st, [u], 110)
        self.assertEqual(acts, [{"kind": "show", "tag": "s-a", "title": "🔥 工作A", "body": "B-done", "text": "B-done",
                                 "url": "/#s/a", "timestamp": 50000, "ev": "done", "name": "工作A", "untitled": False,
                                 "fb": False, "av": {"id": "a", "st": "done"}, "emoji": "🔥"}])
        self.assertEqual(N.localize(acts[0], "en")["title"], "🔥 工作A")
        self.assertEqual(N.localize(acts[0], "en")["body"], "B-done")  # "done" gets no label
        st, acts = run(st, [u], 200)
        self.assertEqual(acts, [])

    def test_idle_not_unread_never_pushes(self):
        st, _ = run(N.new_state(), [], 0)
        st, acts = run(st, [sess(status="idle", unread=False)], 10)
        st, acts = run(st, [sess(status="idle", unread=False)], 100)
        self.assertEqual(acts, [])

    def test_unread_recall_once_when_seen(self):
        st, _ = run(N.new_state(), [], 0)
        u = sess(status="idle", unread=True, since=50)
        st, _ = run(st, [u], 100)
        st, acts = run(st, [u], 110)
        seen = sess(status="idle", unread=False, since=50)
        st, acts = run(st, [seen], 111)
        self.assertEqual(acts, [])  # no recall push
        st, acts = run(st, [seen], 112)
        self.assertEqual(acts, [])
        st, acts = run(st, [u], 200)  # same round turns unread again: no re-push
        st, acts = run(st, [u], 300)
        self.assertEqual(acts, [])

    def test_new_unread_round(self):
        st, _ = run(N.new_state(), [], 0)
        u = sess(status="idle", unread=True, since=50)
        st, _ = run(st, [u], 100)
        st, _ = run(st, [u], 110)
        u2 = sess(status="idle", unread=True, since=500)
        st, acts = run(st, [u2], 500)
        self.assertEqual(acts, [])  # no recall push
        st, acts = run(st, [u2], 510)
        self.assertEqual([a["kind"] for a in acts], ["show"])

    def test_wait_then_done_recalls_then_pushes(self):
        st, _ = run(N.new_state(), [], 0)
        st, _ = run(st, [sess()], 10)
        st, acts = run(st, [sess()], 14)
        d = sess(status="idle", unread=True, since=20)
        st, acts = run(st, [d], 20)
        self.assertEqual(acts, [])  # no recall push
        st, acts = run(st, [d], 30)
        self.assertEqual([(a["kind"], a["title"]) for a in acts], [("show", "🔥 工作A")])

    def test_session_vanishes_recalls_once(self):
        st, _ = run(N.new_state(), [], 0)
        st, _ = run(st, [sess()], 10)
        st, _ = run(st, [sess()], 14)
        st, acts = run(st, [], 15)
        self.assertEqual(acts, [])  # no recall push
        st, acts = run(st, [], 16)
        self.assertEqual(acts, [])

    def test_vanish_unpushed_silent(self):
        st, _ = run(N.new_state(), [], 0)
        st, _ = run(st, [sess()], 10)
        st, acts = run(st, [], 11)
        self.assertEqual(acts, [])

    def test_sid_url_quoted_and_name_fallback(self):
        st, _ = run(N.new_state(), [], 0)
        s = sess("a b/c", name="")
        s["project"] = "Proj"
        st, _ = run(st, [s], 10)
        st, acts = run(st, [s], 13)
        self.assertEqual(acts[0]["url"], "/#s/a%20b%2Fc")
        self.assertEqual(acts[0]["tag"], "s-a b/c")
        self.assertEqual(acts[0]["title"], "🔥 Proj")

    def test_does_not_mutate_input_state(self):
        st0, _ = run(N.new_state(), [], 0)
        st1, _ = run(st0, [sess()], 10)
        self.assertEqual(st0["e"], {})
        self.assertIn("a", st1["e"])

    def test_body_only_computed_when_pushing(self):
        calls = []
        st, _ = N.step(N.new_state(), [], 0, lambda s, k: calls.append(k) or "x")
        st, _ = N.step(st, [sess()], 10, lambda s, k: calls.append(k) or "x")
        self.assertEqual(calls, [])
        N.step(st, [sess()], 13, lambda s, k: calls.append(k) or "x")
        self.assertEqual(calls, ["wait"])

    def test_body_error_falls_back(self):
        def boom(s, k):
            raise OSError("x")
        st, _ = N.step(N.new_state(), [], 0, boom)
        st, _ = N.step(st, [sess()], 10, boom)
        st, acts = N.step(st, [sess()], 13, boom)
        self.assertEqual(acts[0]["body"], "在等你决定")
        d = sess(status="idle", unread=True, since=50)
        st, _ = N.step(st, [d], 50, boom)
        st, acts = N.step(st, [d], 60, boom)
        self.assertEqual(acts[-1]["body"], "干完了")


class BackgroundPushTest(unittest.TestCase):
    """Timing of the "done" notification for background tasks. Runs the real pipeline: snapshot session -> state.flags_for (computes unread / finishedAt) -> notify.step."""

    def setUp(self):
        import os
        import tempfile
        from api.state import State
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = State(os.path.join(self.tmp.name, "state.json"))
        self.t0 = self.state.installed_at
        self.st, _ = N.step(N.new_state(), [], self.t0, body)  # baseline: empty table
        self.pushed = []

    def tick(self, at, status="idle", since=0, origin="user", **kw):
        from api.state import flags_for
        s = {"id": "a", "name": "工作A", "status": status, "since": self.t0 + since, "origin": origin}
        for k, v in kw.items():
            s[k] = self.t0 + v if k == "bgEndedAt" and v is not None else v
        item = dict(s)
        item.update(flags_for(self.state, s, self.t0 + at))
        self.st, acts = N.step(self.st, [item], self.t0 + at, body)
        shows = [x for x in acts if x["kind"] == "show"]
        self.pushed += shows
        return shows

    def test_main_turn_stops_bg_running_no_push(self):
        """Race 1: the main turn stops but background tasks are still running -> no push (pushing "done" after 10s would be too early)."""
        for t in (10, 15, 21, 60, 600):
            self.tick(t, since=10, bgTasks=2, bgStale=False)
        self.assertEqual(self.pushed, [])

    def test_t0_t3_push_once_at_end(self):
        self.tick(5, status="busy", since=5)                                      # T0 user speaks
        for t in (10, 25):
            self.tick(t, since=10, bgTasks=2)                                     # T1 main turn stops, 2 background tasks
        self.tick(30, status="busy", since=30, origin="agent", bgOwned=True, bgTasks=1, bgEndedAt=29)
        for t in (35, 50):
            self.tick(t, since=35, origin="agent", bgOwned=True, bgTasks=1, bgEndedAt=29)  # T2 one task left
        self.assertEqual(self.pushed, [])
        self.tick(60, status="busy", since=60, origin="agent", bgOwned=True, bgTasks=0, bgEndedAt=59)
        for t in (65, 70, 75, 80, 200):
            self.tick(t, since=65, origin="agent", bgOwned=True, bgTasks=0, bgEndedAt=59)  # T3 the last one ends
        self.assertEqual(len(self.pushed), 1)
        self.assertEqual(self.pushed[0]["ev"], "done")
        self.assertEqual(self.pushed[0]["timestamp"], int(round((self.t0 + 65) * 1000)))  # round = finishedAt

    def test_race_bg_zero_before_notify_turn(self):
        """Race 2: bgTasks drops to 0 first, the notification turn starts (busy) 1s later -> no push at that moment; only one push after the notification turn stops."""
        self.tick(10, since=10, bgTasks=1)
        self.tick(100, since=10, bgTasks=0, bgEndedAt=100)                         # drops to 0 first, still the T1 round
        self.tick(101, status="busy", since=101, origin="agent", bgOwned=True, bgTasks=0, bgEndedAt=100)
        self.tick(110, status="busy", since=101, origin="agent", bgOwned=True, bgTasks=0, bgEndedAt=100)
        self.assertEqual(self.pushed, [])
        for t in (112, 118, 122, 130):
            self.tick(t, since=112, origin="agent", bgOwned=True, bgTasks=0, bgEndedAt=100)
        self.assertEqual(len(self.pushed), 1)
        self.assertEqual(self.pushed[0]["timestamp"], int(round((self.t0 + 112) * 1000)))

    def test_seen_midway_still_pushes_at_end(self):
        self.tick(10, since=10, bgTasks=1)
        self.state.mark_seen("a", self.t0 + 15)                                    # the user opened it in between
        self.tick(20, since=10, bgTasks=1)
        for t in (60, 65, 75):
            self.tick(t, since=60, origin="agent", bgOwned=True, bgTasks=0, bgEndedAt=59)
        self.assertEqual(len(self.pushed), 1)

    def test_agent_report_without_bg_owned_no_push(self):
        for t in (60, 65, 75):
            self.tick(t, since=60, origin="agent", bgOwned=False, bgTasks=0)
        self.assertEqual(self.pushed, [])

    def test_tasks_kill_last_bg_no_new_turn(self):
        """/tasks kills the last background task: no new turn, since unchanged, bgEndedAt is newer -> red dot plus one push."""
        self.tick(10, since=10, bgTasks=1)
        self.state.mark_seen("a", self.t0 + 15)
        self.tick(50, since=10, bgTasks=1)
        for t in (100, 105, 111, 150):
            self.tick(t, since=10, bgTasks=0, bgEndedAt=100)
        self.assertEqual(len(self.pushed), 1)
        self.assertEqual(self.pushed[0]["timestamp"], int(round((self.t0 + 100) * 1000)))

    def test_stale_releases_once(self):
        """Stuck for a full 2 hours: treated as plain idle and "done" is allowed once; staying stuck afterwards does not re-push."""
        self.tick(10, since=10, bgTasks=1, bgStale=False)
        self.tick(3600, since=10, bgTasks=1, bgStale=False)
        self.assertEqual(self.pushed, [])
        for t in (7210, 7215, 7221, 7300, 9000, 20000):
            self.tick(t, since=10, bgTasks=1, bgStale=True)
        self.assertEqual(len(self.pushed), 1)
        self.assertEqual(self.pushed[0]["ev"], "done")

    def test_stale_already_seen_no_push(self):
        self.tick(10, since=10, bgTasks=1)
        self.state.mark_seen("a", self.t0 + 15)
        for t in (7210, 7221, 7300):
            self.tick(t, since=10, bgTasks=1, bgStale=True)
        self.assertEqual(self.pushed, [])

    def test_round_key_falls_back_to_since(self):
        """Session items without finishedAt (old callers / guest table) still use since as the round."""
        st, _ = N.step(N.new_state(), [], 0, body)
        d = sess(status="idle", unread=True, since=50)
        st, _ = N.step(st, [d], 50, body)
        st, acts = N.step(st, [d], 60, body)
        self.assertEqual(acts[-1]["timestamp"], 50000)
        d2 = dict(d, finishedAt=70)  # same since, newer finishedAt = a new round
        st, acts = N.step(st, [d2], 70, body)
        st, acts = N.step(st, [d2], 80, body)
        self.assertEqual(acts[-1]["timestamp"], 70000)


class ErrorPushTest(unittest.TestCase):
    """With errorKind, push "error" (not "done"), after 3 seconds; rate_limit is labelled "quota exhausted";
    disconnected does not push "done" but pushes "unexpected exit" once. Runs the real pipeline flags_for -> step, with the body from wait_body (same as server._notify_body)."""

    setUp = BackgroundPushTest.setUp

    def tick(self, at, status="idle", since=0, origin="user", **kw):
        from api.state import flags_for
        s = {"id": "a", "name": "工作A", "status": status, "since": self.t0 + since, "origin": origin, "summary": "原文"}
        for k, v in kw.items():
            s[k] = self.t0 + v if k in ("errorSince", "disconnectedSince") and v is not None else v
        item = dict(s)
        item.update(flags_for(self.state, s, self.t0 + at))
        self.st, acts = N.step(self.st, [item], self.t0 + at, lambda x, k: N.wait_body(x, []))
        shows = [x for x in acts if x["kind"] == "show"]
        self.pushed += shows
        return shows

    API = {"errorKind": "api", "errorStatus": 529, "errorText": "API Error: 529 Overloaded", "errorSince": 10,
           "summaryCode": "state.apiError", "summaryArgs": {"kind": "api", "status": 529, "text": "Overloaded"}}

    def test_api_error_pushes_err_after_3s_not_done(self):
        self.tick(10, since=10, **self.API)
        self.assertEqual(self.tick(10 + N.WAIT_DELAY - 0.5, since=10, **self.API), [])
        shows = self.tick(10 + N.WAIT_DELAY, since=10, **self.API)
        self.assertEqual(len(shows), 1)
        self.assertEqual(shows[0]["ev"], "err")
        self.assertEqual(N.localize(shows[0], "hans")["body"], "出错 529：Overloaded")
        self.assertEqual(N.localize(shows[0], "en")["body"], "Error 529: Overloaded")
        self.assertEqual(N.localize(shows[0], "hant")["body"], "出錯 529：Overloaded")
        for t in (20, 60, 600):
            self.tick(t, since=10, **self.API)
        self.assertEqual(len(self.pushed), 1)
        self.assertNotIn("done", [a["ev"] for a in self.pushed])

    def test_rate_limit_uses_limit_label_and_cc_words(self):
        kw = {"errorKind": "rate_limit", "errorStatus": 429, "errorText": "You've hit your limit · resets 1pm", "errorSince": 10,
              "summaryCode": "state.apiError", "summaryArgs": {"kind": "rate_limit", "status": 429, "text": "You've hit your limit · resets 1pm"}}
        for t in (10, 14):
            self.tick(t, since=10, **kw)
        self.assertEqual(len(self.pushed), 1)
        a = self.pushed[0]
        self.assertEqual(a["ev"], "limit")
        self.assertEqual(N.localize(a, "hans")["body"], "额度用完：You've hit your limit · resets 1pm")
        self.assertEqual(N.localize(a, "en")["body"], "Limit reached: You've hit your limit · resets 1pm")
        self.assertEqual(N.localize(a, "hant")["body"], "額度用完：You've hit your limit · resets 1pm")

    def test_auth(self):
        kw = {"errorKind": "auth", "errorStatus": 401, "errorSince": 10, "summaryCode": "state.apiError",
              "summaryArgs": {"kind": "auth", "status": 401, "text": "OAuth token expired"}}
        for t in (10, 14):
            self.tick(t, since=10, **kw)
        self.assertEqual(N.localize(self.pushed[0], "hans")["body"], "出错：要重新登录")
        self.assertEqual(N.localize(self.pushed[0], "en")["body"], "Error: Needs sign-in again")

    def test_error_after_seen_still_pushes(self):
        """The round was already seen (seen after since) and the error comes later: errorSince updates the round and "error" is still pushed."""
        self.state.mark_seen("a", self.t0 + 15)
        for t in (30, 34):
            self.tick(t, since=10, **dict(self.API, errorSince=30))
        self.assertEqual([a["ev"] for a in self.pushed], ["err"])
        self.assertEqual(self.pushed[0]["timestamp"], int(round((self.t0 + 30) * 1000)))

    def test_workbuddy_error_kind(self):
        """errorKind=wb_error / wb_stopped takes priority (summary unchanged; recognized even without summaryCode)."""
        for t in (10, 14):
            self.tick(t, since=10, kind="workbuddy", errorKind="wb_error", errorSince=10, summary="出错")
        self.assertEqual([a["ev"] for a in self.pushed], ["err"])
        self.assertEqual(N.localize(self.pushed[0], "hans")["body"], "出错了")  # the summary is itself the status word: write the full word only, never "[出错了] 出错"
        self.pushed = []
        self.st, _ = N.step(N.new_state(), [], self.t0, body)
        for t in (10, 15, 21):
            self.tick(t, since=10, kind="workbuddy", errorKind="wb_stopped", errorSince=10, summary="已中止")
        self.assertEqual([a["ev"] for a in self.pushed], ["stopped"])

    def test_error_kind_beats_summary_code(self):
        """errorKind says quota exhausted while summaryCode is still the old state.error: errorKind wins."""
        for t in (10, 14):
            self.tick(t, since=10, errorKind="rate_limit", errorSince=10, summaryCode="state.error")
        self.assertEqual([a["ev"] for a in self.pushed], ["limit"])

    def test_disconnected_pushes_lost_once_not_done(self):
        kw = {"disconnected": True, "disconnectedSince": 20, "summaryCode": "state.disconnected", "summaryArgs": {}}
        self.tick(20, since=10, **kw)
        self.assertEqual(self.tick(20 + N.WAIT_DELAY - 0.5, since=10, **kw), [])
        shows = self.tick(20 + N.WAIT_DELAY, since=10, **kw)
        self.assertEqual([a["ev"] for a in shows], ["lost"])
        self.assertEqual({lg: N.localize(shows[0], lg)["body"] for lg in N.PUSH_LANGS},
                         {"en": "Exited unexpectedly", "hans": "意外退出", "hant": "意外結束"})
        self.assertEqual(N.localize(shows[0], "hans")["title"], "🔥 工作A")
        for t in (60, 300, 590):
            self.tick(t, since=10, **kw)
        self.assertEqual(len(self.pushed), 1)
        self.assertNotIn("done", [a["ev"] for a in self.pushed])

    def test_disconnected_after_done_no_extra_done(self):
        """Finishes first ("done" was pushed), then exits unexpectedly: only one extra unexpected-exit push."""
        for t in (10, 21):
            self.tick(t, since=10)
        self.assertEqual([a["ev"] for a in self.pushed], ["done"])
        for t in (30, 34, 100):
            self.tick(t, since=10, disconnected=True, disconnectedSince=30)
        self.assertEqual([a["ev"] for a in self.pushed], ["done", "lost"])

    def test_disconnected_muted_no_push(self):
        from api.state import flags_for
        for t in (20, 25, 40):
            s = {"id": "a", "name": "工作A", "status": "idle", "since": self.t0 + 10, "disconnected": True,
                 "disconnectedSince": self.t0 + 20, "muted": True}
            item = dict(s)
            item.update(flags_for(self.state, s, self.t0 + t))
            self.st, acts = N.step(self.st, [item], self.t0 + t, body)
            self.assertEqual(acts, [])

    def test_retrying_busy_no_push(self):
        for t in (10, 20, 60):
            self.tick(t, status="busy", since=10, retryAttempt=3, retryMax=10, summaryCode="state.retrying",
                      summaryArgs={"attempt": 3, "max": 10})
        self.assertEqual(self.pushed, [])


class TextTest(unittest.TestCase):
    def test_strip_markdown(self):
        t = "## 标题\n**粗体** 和 `code` 与 [链接](http://x.y)\n- 项目一\n> 引用\n```py\nprint(1)\n```\n结尾"
        out = N.strip_markdown(t)
        for ch in ("#", "*", "`", "](", ">"):
            self.assertNotIn(ch, out)
        self.assertIn("粗体", out)
        self.assertIn("链接", out)
        self.assertIn("结尾", out)
        self.assertNotIn("\n", out)

    def test_clip(self):
        self.assertEqual(N.clip("a" * 120), "a" * 120)
        self.assertEqual(len(N.clip("a" * 500)), 120)
        self.assertTrue(N.clip("a" * 500).endswith("…"))

    def test_done_body_last_assistant(self):
        items = [{"role": "assistant", "text": "旧的"}, {"role": "user", "text": "hi"},
                 {"role": "assistant", "text": "**好了**，" + "字" * 200}, {"role": "tool", "text": "Bash"}]
        b = N.done_body(items)
        self.assertTrue(b.startswith("好了，"))
        self.assertEqual(len(b), 120)
        self.assertEqual(N.done_body([]), "干完了")
        self.assertEqual(N.done_body([{"role": "user", "text": "x"}]), "干完了")

    def test_wait_body_priority(self):
        self.assertEqual(N.wait_body({"summary": "问你：改不改？"}, []), "问你：改不改？")
        items = [{"role": "ask", "text": "旧", "questions": [{"question": "旧题"}]},
                 {"role": "ask", "text": "新题（A / B）", "questions": [{"question": "新题"}, {"question": "二题"}]}]
        self.assertEqual(N.wait_body({}, items), "新题 二题")
        items = [{"role": "ask", "text": "题", "questions": []}]
        self.assertEqual(N.wait_body({}, items), "题")
        items = [{"role": "assistant", "text": "x"}, {"role": "tool", "text": "Bash rm x", "pending": True}]
        self.assertEqual(N.wait_body({}, items), "Bash rm x")
        items = [{"role": "tool", "text": "Bash done", "pending": False}]
        self.assertEqual(N.wait_body({}, items), "有事要你定")
        self.assertEqual(N.wait_body({}, []), "有事要你定")
        self.assertEqual(len(N.wait_body({"summary": "x" * 300}, [])), 120)


if __name__ == "__main__":
    unittest.main()



class TitleTest(unittest.TestCase):
    def test_title_is_session_name_no_zone_head_no_star(self):
        """The title is the full session name, not composed as "zone * short name"."""
        zones = [{"code": "Docs", "color": "#E0A040", "lead": "Docs-Lead"}]
        st = N.new_state()
        sess = [{"id": "a", "name": "Docs-Lead", "zone": "Docs", "status": "idle", "since": 1, "unread": False},
                {"id": "b", "name": "Docs-X", "zone": "Docs", "status": "idle", "since": 1, "unread": False},
                {"id": "c", "name": "散会话", "zone": "未分区", "status": "idle", "since": 1, "unread": False}]
        st, _ = N.step(st, sess, 0, lambda s, k: "q", zones)
        sess = [dict(x, status="waiting", since=2) for x in sess]
        st, _ = N.step(st, sess, 1, lambda s, k: "q", zones)
        st, acts = N.step(st, sess, 1 + N.WAIT_DELAY, lambda s, k: "q", zones)
        titles = sorted(a["title"] for a in acts if a["kind"] == "show")
        self.assertEqual(titles, ["🔥 Docs-Lead", "🔥 Docs-X", "🔥 散会话"])
