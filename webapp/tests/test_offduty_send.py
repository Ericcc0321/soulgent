"""Helper: send-off-duty from the phone (outbox type offduty) and mark-as-unread (mark unseen).
Everything uses fake scripts / mocks: no real roster, no real offduty.py, no real defaults writes."""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET; signs hand-written requests/results

from helper import outbox

NOW = 1792400000.0

FAKE_OFF = """#!/usr/bin/python3
import os, sys, time
d = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(d, "off-calls"), "a") as f:
    f.write(repr(sys.argv[1:]) + "\\n")
mode = open(os.path.join(d, "mode")).read().strip()
if mode == "fail":
    sys.stderr.write("Lab-a 状态是 waiting，不是空闲，不送（加 --force 强制）\\n")
    sys.exit(1)
elif mode == "locked":
    sys.exit(3)
elif mode == "hang":
    time.sleep(60)
"""

LIVE = {"s1": {"id": "s1", "kind": "claude", "name": "Lab-a"}}


class OffdutyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.ob = os.path.join(t, "outbox")
        self.sdir = os.path.join(t, "sessions")
        os.makedirs(self.ob)
        os.makedirs(self.sdir)
        self.script = os.path.join(t, "fakeoff")
        with open(self.script, "w") as f:
            f.write(FAKE_OFF)
        os.chmod(self.script, 0o755)
        self.log = os.path.join(t, "send.log")
        self.mode("ok")
        outbox._OFFS.clear()
        self.addCleanup(self.kill_all)

    def kill_all(self):
        for w in list(outbox._OFFS.values()):
            w["proc"].kill()
            w["proc"].wait()
            w["err"].close()
        outbox._OFFS.clear()

    def mode(self, m):
        with open(os.path.join(self.tmp.name, "mode"), "w") as f:
            f.write(m)

    def put(self, rid, sid="s1", name="Lab-a", **kw):
        body = {"id": rid, "sessionId": sid, "type": "offduty", "name": name, "createdAt": NOW}
        body.update(kw)
        with open(os.path.join(self.ob, rid + ".req.json"), "w") as f:
            json.dump(_sig.req(body), f)

    def run_once(self, sessions=None):
        return outbox.process_once(self.ob, LIVE if sessions is None else sessions, self.sdir, [], self.log,
                                   NOW + 1, off_cmd=[self.script])

    def res(self, rid):
        with open(os.path.join(self.ob, rid + ".res.json")) as f:
            return json.load(f)

    def wait_res(self, rid, sessions=None, secs=5):
        end = time.time() + secs
        while time.time() < end:
            self.run_once(sessions)
            if os.path.exists(os.path.join(self.ob, rid + ".res.json")):
                return self.res(rid)
            time.sleep(0.05)
        self.fail("no result")

    def calls(self):
        p = os.path.join(self.tmp.name, "off-calls")
        return open(p).read().splitlines() if os.path.exists(p) else []

    def test_success_runs_script_with_name_as_list_arg(self):
        self.put("a")
        self.run_once()  # the session is still in the snapshot when the request is claimed
        r = self.wait_res("a", sessions={})  # after the run the session is gone from the snapshot
        self.assertEqual(r["status"], "done")
        self.assertEqual(self.calls(), [repr(["Lab-a"])])
        self.assertIn("\toffduty\t", open(self.log).read())

    def test_failure_reports_reason_as_code(self):
        """The script's own (Chinese) wording is mapped to a code instead of being echoed back to the frontend."""
        self.mode("fail")
        self.put("a")
        r = self.wait_res("a")
        self.assertEqual((r["status"], r["error"]), ("failed", "offduty-not-idle"))
        self.assertNotIn("message", r)

    def test_restart_lock_exit_3_has_code(self):
        self.mode("locked")
        self.put("a")
        r = self.wait_res("a")
        self.assertEqual(r["error"], "offduty-restarting")
        self.assertNotIn("message", r)

    def test_unknown_session_rejected_without_running(self):
        self.put("a", sid="nope")
        self.run_once()
        self.assertEqual(self.res("a")["error"], "session-gone")
        self.assertEqual(self.calls(), [])

    def test_name_must_match_snapshot(self):
        # name in the request does not match the session name in the snapshot (or tries to smuggle arguments): reject, do not run the script
        for i, bad in enumerate(["Lab-b", "--force", "Lab-a; rm -rf /", None]):
            self.put("b%d" % i, name=bad)
        self.run_once()
        for i in range(4):
            self.assertEqual(self.res("b%d" % i)["error"], "bad-request")
        self.assertEqual(self.calls(), [])

    def test_dash_name_in_snapshot_rejected(self):
        self.put("a", name="-x")
        self.run_once({"s1": {"id": "s1", "kind": "claude", "name": "-x"}})
        self.assertEqual(self.res("a")["error"], "bad-request")
        self.assertEqual(self.calls(), [])

    def test_timeout_kills_and_fails_if_still_awake(self):
        self.mode("hang")
        self.put("a")
        with mock.patch.object(outbox, "OFF_TIMEOUT", 0.3):
            r = self.wait_res("a")
        self.assertEqual((r["status"], r["error"]), ("failed", "offduty-timeout"))
        self.assertEqual(outbox._OFFS, {})

    def test_dedupes_same_name_and_not_treated_as_leftover(self):
        self.mode("hang")
        self.put("a")
        self.run_once()
        self.put("b", createdAt=NOW + 1)
        self.run_once()
        self.assertTrue(os.path.exists(os.path.join(self.ob, "a.claimed")))
        self.assertTrue(os.path.exists(os.path.join(self.ob, "b.claimed")))
        end = time.time() + 3
        while not self.calls() and time.time() < end:
            time.sleep(0.05)  # the fake script needs a moment to start
        self.assertEqual(len(self.calls()), 1)

    def test_constants(self):
        if outbox.OFF_CMD:  # the script is an optional extension: empty when SOULGENT_OFFDUTY is not configured
            self.assertEqual(outbox.OFF_CMD[0], "/usr/bin/python3")
            self.assertEqual(outbox.OFF_CMD[1], outbox.offduty_script())  # path is configurable (SOULGENT_OFFDUTY)
            self.assertEqual(outbox.OFF_CMD[-1], "--off")
        else:
            self.assertEqual(outbox.offduty_script(), "")
        self.assertLessEqual(outbox.OFF_TIMEOUT, 80)


class UnseenMarkTest(unittest.TestCase):
    """Mark as unread: writes seenAt backwards, bypassing the "only write when the new value is larger" rule."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ob = os.path.join(self.tmp.name, "ob")
        os.makedirs(self.ob)
        self.calls = []
        self.domain = {"seenAt": {"a": 1792431352.0}, "pinned": []}
        for k, v in (("PANEL_DOMAIN", "io.github.ericcc0321.soulgent"), ("PANEL_DOMAIN_LEGACY", "")):
            p = mock.patch.object(outbox, k, v)
            p.start()
            self.addCleanup(p.stop)

    def fake_run(self, cmd, **kw):
        self.calls.append(cmd)
        if cmd[:2] == ["defaults", "export"]:
            return subprocess.CompletedProcess(cmd, 0, stdout=plistlib.dumps(self.domain))
        return subprocess.CompletedProcess(cmd, 0)

    def run_req(self, req):
        with open(os.path.join(self.ob, "r1.req.json"), "w") as f:
            json.dump(_sig.req(dict(req, id="r1", type="mark", createdAt=NOW)), f)
        with mock.patch.object(outbox.subprocess, "run", self.fake_run):
            outbox.process_once(self.ob, {}, self.tmp.name, [], os.path.join(self.tmp.name, "l"), NOW)
        return [c for c in self.calls if c[:2] == ["defaults", "write"]]

    def test_unseen_writes_older_value_as_plist_real(self):
        w = self.run_req({"unseen": {"a": 1792431000.25}})
        self.assertEqual(w, [["defaults", "write", "io.github.ericcc0321.soulgent", "seenAt",
                              "-dict-add", "a", "<real>1792431000.25</real>"]])

    def test_unseen_rejects_bad_values(self):
        w = self.run_req({"unseen": {"-x": 1.0, "b": True, "c": "1", "d": -5, "e": float("nan")}})
        self.assertEqual(w, [])


if __name__ == "__main__":
    unittest.main()
