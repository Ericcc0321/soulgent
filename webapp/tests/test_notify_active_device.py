"""Active-device priority: if any device of the same account is active, no system notification is sent; it is held while waiting for that device's banner report.
No report within 12 s / all active devices gone -> push to everyone as usual; after delivery, if every device stays away for 2 full minutes and it is still the same round waiting on you / errored -> push once more (not for finished work).
Mac disconnect / recovery follow the same rules (link_gate). Pure functions; time, activity and reports are injected by the caller."""
import unittest

from api import notify as N


def W(**kw):
    d = {"id": "a", "name": "Ops-demo-calc", "status": "waiting", "since": 1000.0}
    d.update(kw)
    return d


def D(**kw):
    return W(status="idle", unread=True, **kw)


BODY = lambda s, k: "内容"  # noqa: E731


class Run:
    """Advances second by second: each round is passed the current active / seen, and the emitted actions are collected (with their timestamps)."""

    def __init__(self):
        self.st, _ = N.step(N.new_state(), [], 0, BODY)
        self.out = []

    def tick(self, sessions, t, active=False, seen=None):
        self.st, acts = N.step(self.st, sessions, t, BODY, None, active, seen or {})
        self.out += [(t, a) for a in acts]
        return acts

    def span(self, sessions, t0, t1, active=False, seen=None):
        for t in range(t0, t1 + 1):
            self.tick(sessions, t, active(t) if callable(active) else active,
                      seen(t) if callable(seen) else seen)


class HoldTest(unittest.TestCase):
    def test_no_active_pushes_as_before(self):
        r = Run()
        r.span([W()], 10, 20)
        self.assertEqual([t for t, _ in r.out], [13])

    def test_active_holds_no_push(self):
        r = Run()
        r.span([W()], 10, 20, active=True)
        self.assertEqual(r.out, [])

    def test_report_within_12s_ends_without_push(self):
        r = Run()
        r.span([W()], 10, 60, active=True, seen=lambda t: {"s-a:wait": 15} if t >= 15 else {})
        self.assertEqual(r.out, [])

    def test_no_report_in_12s_pushes_all(self):
        r = Run()
        r.span([W()], 10, 40, active=True)
        self.assertEqual([t for t, _ in r.out], [13 + 12])
        self.assertEqual(r.out[0][1]["tag"], "s-a")

    def test_active_leaves_pushes_immediately(self):
        r = Run()
        r.span([W()], 10, 30, active=lambda t: t < 16)
        self.assertEqual([t for t, _ in r.out], [16])

    def test_report_before_fire_counts(self):
        """Viewing that session (the bannerStep viewingId branch) or the banner appeared before the server: a report already exists when the deadline hits -> neither hold nor push."""
        r = Run()
        r.span([W()], 10, 40, active=True, seen={"s-a:wait": 11})
        self.assertEqual(r.out, [])

    def test_stale_report_from_previous_round_ignored(self):
        """A report from the previous round must not count as delivered for the new round."""
        r = Run()
        r.span([W(since=1000.0)], 10, 15, active=True, seen={"s-a:wait": 14})
        r.span([], 16, 20, active=True, seen={"s-a:wait": 14})
        r.span([W(since=2000.0)], 50, 80, active=True, seen={"s-a:wait": 14})
        self.assertEqual([t for t, _ in r.out], [53 + 12])

    def test_report_for_other_kind_ignored(self):
        r = Run()
        r.span([W()], 10, 40, active=True, seen={"s-a:done": 15})
        self.assertEqual([t for t, _ in r.out], [25])

    def test_resolved_while_held_no_push(self):
        r = Run()
        r.span([W()], 10, 18, active=True)
        r.span([W(status="busy")], 19, 60, active=True)
        self.assertEqual(r.out, [])

    def test_restart_empty_presence_pushes(self):
        """api restart: the active table is empty (active=False) -> push as usual."""
        r = Run()
        r.span([D()], 10, 30)
        self.assertEqual([t for t, _ in r.out], [20])

    def test_first_run_entries_not_held_or_pushed(self):
        st, acts = N.step(N.new_state(), [W()], 0, BODY, None, False, {})
        for t in range(1, 200):
            st, acts = N.step(st, [W()], t, BODY, None, t > 100, {})
            self.assertEqual(acts, [])


class NagTest(unittest.TestCase):
    """After delivery, all devices inactive and still the same round: push once more after 2 full minutes."""

    def seen(self, t):
        return {"s-a:wait": 15, "s-a:err": 15, "s-a:done": 25} if t >= 15 else {}

    def test_wait_seen_then_away_2min_backfills_once(self):
        r = Run()
        r.span([W()], 10, 400, active=lambda t: t < 30, seen=self.seen)
        self.assertEqual([t for t, _ in r.out], [30 + 120])
        self.assertEqual(r.out[0][1]["tag"], "s-a")

    def test_err_backfills(self):
        r = Run()
        s = D(summaryCode="state.error")
        r.span([s], 10, 400, active=lambda t: t < 30, seen=self.seen)
        self.assertEqual([(t, a["ev"]) for t, a in r.out], [(150, "err")])

    def test_done_not_backfilled(self):
        r = Run()
        r.span([D()], 10, 400, active=lambda t: t < 30, seen=self.seen)
        self.assertEqual(r.out, [])

    def test_still_active_no_backfill(self):
        r = Run()
        r.span([W()], 10, 400, active=True, seen=self.seen)
        self.assertEqual(r.out, [])

    def test_come_back_resets_clock(self):
        r = Run()
        r.span([W()], 10, 400, active=lambda t: t < 30 or 100 <= t < 200, seen=self.seen)
        self.assertEqual([t for t, _ in r.out], [200 + 120])

    def test_answered_before_2min_no_backfill(self):
        r = Run()
        r.span([W()], 10, 100, active=lambda t: t < 30, seen=self.seen)
        r.span([W(status="busy")], 101, 400, seen=self.seen)
        self.assertEqual(r.out, [])

    def test_seen_while_not_active_then_backfill(self):
        """Already inactive at delivery (the report arrived before the hold, then the user left): the away timer starts at delivery."""
        r = Run()
        r.span([W()], 10, 400, active=False, seen={"s-a:wait": 11})
        self.assertEqual([t for t, _ in r.out], [13 + 120])


class AccountsTest(unittest.TestCase):
    def test_separate_states_separate_presence(self):
        """admin and guest each run their own step (the caller passes each account's activity): admin being active does not affect the guest."""
        admin, guest = Run(), Run()
        admin.span([D()], 10, 40, active=True)
        guest.span([D()], 10, 40, active=False)
        self.assertEqual(admin.out[0][0], 32)  # held at 20; no report for 12 s
        self.assertEqual([t for t, _ in guest.out], [20])


class LinkGateTest(unittest.TestCase):
    ACT_DOWN = {"kind": "show", "tag": "mac-link", "ev": "macDown"}
    ACT_UP = {"kind": "show", "tag": "mac-link", "ev": "macUp"}

    def test_down_not_active_sends(self):
        g, out = N.link_gate(N.new_link_gate(), "down", self.ACT_DOWN, True, True, False)
        self.assertEqual(out, [self.ACT_DOWN])
        self.assertTrue(g["sent"])

    def test_down_active_held_then_sent_when_away_and_still_down(self):
        g, out = N.link_gate(N.new_link_gate(), "down", self.ACT_DOWN, True, True, True)
        self.assertEqual(out, [])
        g, out = N.link_gate(g, None, None, True, True, True)
        self.assertEqual(out, [])
        g, out = N.link_gate(g, None, None, True, True, False)
        self.assertEqual(out, [self.ACT_DOWN])
        g, out = N.link_gate(g, None, None, True, True, False)
        self.assertEqual(out, [])

    def test_held_down_dropped_on_recovery(self):
        g, _ = N.link_gate(N.new_link_gate(), "down", self.ACT_DOWN, True, True, True)
        g, out = N.link_gate(g, None, None, False, True, False)  # no longer expired (recovering): do not send the missed disconnect
        self.assertEqual(out, [])
        g, out = N.link_gate(g, "up", self.ACT_UP, False, False, False)  # the disconnect was never pushed -> do not push the recovery either
        self.assertEqual(out, [])
        self.assertEqual(g, N.new_link_gate())

    def test_up_only_if_down_sent_and_not_active(self):
        g, _ = N.link_gate(N.new_link_gate(), "down", self.ACT_DOWN, True, True, False)
        g2, out = N.link_gate(g, "up", self.ACT_UP, False, False, False)
        self.assertEqual(out, [self.ACT_UP])
        g3, out = N.link_gate(g, "up", self.ACT_UP, False, False, True)
        self.assertEqual(out, [])  # active: the whole page recovers inside the app, no push
        self.assertEqual(g3, N.new_link_gate())

    def test_short_outage_reset(self):
        g, _ = N.link_gate(N.new_link_gate(), "down", self.ACT_DOWN, True, True, False)
        g, out = N.link_gate(g, None, None, False, False, False)  # recovered in under 5 minutes: link_step resets, no recovery push
        self.assertEqual(out, [])
        self.assertEqual(g, N.new_link_gate())


if __name__ == "__main__":
    unittest.main()
