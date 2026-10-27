import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET, used to sign hand-written requests/results

from helper import outbox

NOW = 1792400000.0

FAKE_WAKE = """#!/usr/bin/python3
import os, sys, time
d = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(d, "wake-calls"), "a") as f:
    f.write(repr(sys.argv[1:]) + " HOME=%s PATH=%s\\n" % (os.environ.get("HOME"), os.environ.get("PATH")))
mode = open(os.path.join(d, "mode")).read().strip()
if mode == "fail":
    sys.stderr.write("first line\\n" + "boom " * 100 + "\\n")
    sys.exit(2)
elif mode == "hang":
    time.sleep(60)
elif mode == "wait":
    while not os.path.exists(os.path.join(d, "go")):
        time.sleep(0.05)
"""


class WakeTest(unittest.TestCase):
    """Everything uses fake wake scripts and a temporary roster; the real roster is untouched and the real offduty.py is never run."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.ob = os.path.join(t, "outbox")
        self.sdir = os.path.join(t, "sessions")
        os.makedirs(self.ob)
        os.makedirs(self.sdir)
        self.script = os.path.join(t, "fakewake")
        with open(self.script, "w") as f:
            f.write(FAKE_WAKE)
        os.chmod(self.script, 0o755)
        self.roster = os.path.join(t, "roster.json")
        with open(self.roster, "w") as f:
            json.dump({"Lab-off": {"cwd": "/tmp", "sid": "o1", "zone": "Lab", "offAt": 1}}, f)
        self.log = os.path.join(t, "send.log")
        self.mode("ok")
        outbox._WAKES.clear()
        self.addCleanup(self.kill_all)

    def kill_all(self):
        for w in list(outbox._WAKES.values()):
            w["proc"].kill()
            w["proc"].wait()
            w["err"].close()
        outbox._WAKES.clear()

    def mode(self, m):
        with open(os.path.join(self.tmp.name, "mode"), "w") as f:
            f.write(m)

    def put(self, rid, name="Lab-off", **kw):
        body = {"id": rid, "sessionId": "o1", "type": "wake", "name": name, "createdAt": NOW}
        body.update(kw)
        with open(os.path.join(self.ob, rid + ".req.json"), "w") as f:
            json.dump(_sig.req(body), f)

    def run_once(self, sessions=None, now=NOW + 1, cmd=None):
        return outbox.process_once(self.ob, sessions or {}, self.sdir, [], self.log, now,
                                   roster_path=self.roster, wake_cmd=cmd or [self.script])

    def exists(self, name):
        return os.path.exists(os.path.join(self.ob, name))

    def res(self, rid):
        with open(os.path.join(self.ob, rid + ".res.json")) as f:
            return json.load(f)

    def wait_res(self, rid, sessions=None, secs=5):
        end = time.time() + secs
        while time.time() < end:
            self.run_once(sessions)
            if self.exists(rid + ".res.json"):
                return self.res(rid)
            time.sleep(0.05)
        self.fail("no result")

    def calls(self):
        p = os.path.join(self.tmp.name, "wake-calls")
        if not os.path.exists(p):
            return []
        with open(p) as f:
            return f.read().splitlines()

    def test_success_done_with_env_and_log(self):
        self.put("a")
        r = self.wait_res("a")
        self.assertEqual(r["status"], "done")
        self.assertNotIn("error", r)
        c = self.calls()
        self.assertEqual(len(c), 1)
        self.assertTrue(c[0].startswith("['Lab-off']"))
        self.assertTrue(c[0].endswith("PATH=/usr/bin:/bin"))
        self.assertFalse(self.exists("a.claimed"))
        parts = open(self.log).read().rstrip("\n").split("\t")
        self.assertEqual(parts[1:], ["Lab-off", "wake", "Lab-off", "done"])

    def test_failure_code_only_no_raw_message(self):
        """An unrecognized failure returns only wake-failed; the script output does not go into the result (only logged to helper.log)."""
        self.mode("fail")
        self.put("a")
        r = self.wait_res("a")
        self.assertEqual((r["status"], r["error"]), ("failed", "wake-failed"))
        self.assertNotIn("message", r)
        self.assertIn("failed:wake-failed", open(self.log).read())

    def test_fail_code_mapping(self):
        """Chinese messages from offduty.py -> code (consistent with wakefail.* / offfail.* in web/i18n.js)."""
        f = outbox.job_fail_code
        self.assertEqual(f("wake", 1, "名册里没有 Lab-x"), "not-offduty")
        self.assertEqual(f("wake", 1, "Lab-x 已经醒着"), "wake-already-awake")
        self.assertEqual(f("wake", 1, "Orca 没开出终端：xx"), "wake-no-terminal")
        self.assertEqual(f("wake", 1, "发了启动命令（a）但 90 秒没注册，可能停在信任框/确认框上"), "wake-timeout")
        self.assertEqual(f("wake", 2, "boom"), "wake-failed")
        self.assertEqual(f("offduty", 3, ""), "offduty-restarting")
        self.assertEqual(f("offduty", 1, "没有醒着的 Lab-x"), "session-gone")
        self.assertEqual(f("offduty", 1, "Lab-a 状态是 waiting，不是空闲，不送（加 --force 强制）"), "offduty-not-idle")
        self.assertEqual(f("offduty", 1, "Lab-a 有后台子代理在跑：x，不送（加 --force 强制）"), "offduty-agents-running")
        self.assertEqual(f("offduty", 1, "?"), "offduty-failed")
        import re
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web", "i18n.js"), encoding="utf-8").read()
        for typ, pre in (("wake", "wakefail."), ("offduty", "offfail.")):
            for _, code in outbox._JOB_FAIL[typ]:
                self.assertIn('"%s%s":' % (pre, code), src)
        self.assertIn('"offfail.offduty-restarting":', src)

    def test_not_in_roster_is_not_offduty(self):
        self.put("a", name="Nobody")
        self.run_once()
        r = self.res("a")
        self.assertEqual((r["status"], r["error"]), ("failed", "not-offduty"))
        self.assertEqual(self.calls(), [])

    def test_not_in_roster_but_already_awake_is_done(self):
        self.put("a", name="Nobody")
        self.run_once({"s9": {"id": "s9", "kind": "claude", "name": "Nobody"}})
        self.assertEqual(self.res("a")["status"], "done")
        self.assertEqual(self.calls(), [])

    def test_awake_via_registry_file(self):
        with open(os.path.join(self.sdir, "5.json"), "w") as f:
            json.dump({"sessionId": "x", "name": "Nobody"}, f)
        self.put("a", name="Nobody")
        self.run_once()
        self.assertEqual(self.res("a")["status"], "done")

    def test_bad_name_rejected(self):
        for i, n in enumerate(["", "-x", 5, None]):
            self.put("b%d" % i, name=n)
        self.run_once()
        for i in range(4):
            self.assertEqual(self.res("b%d" % i)["error"], "bad-request")

    def test_missing_roster_is_not_offduty(self):
        os.unlink(self.roster)
        self.put("a")
        self.run_once()
        self.assertEqual(self.res("a")["error"], "not-offduty")

    def test_unconfigured_script_degrades_safely(self):
        """No wake / off-duty script configured (default): wake / off-duty fail explicitly and never try to execute the session name."""
        self.assertEqual(outbox.OFFDUTY_DEFAULT, "")
        from unittest import mock
        with mock.patch.object(outbox, "WAKE_CMD", []), mock.patch.object(outbox, "OFF_CMD", []), \
                mock.patch.object(outbox.subprocess, "Popen") as popen:
            r = outbox._wake_start("Lab-off", "r1", "p", 0, {}, self.sdir, self.roster, None)
            self.assertEqual(r[0], "wake-failed")
            r = outbox._off_start("Lab-off", "r2", "p", 0, None)
            self.assertEqual(r[0], "offduty-failed")
            popen.assert_not_called()

    def test_does_not_block_other_requests_and_dedupes(self):
        self.mode("wait")
        self.put("a")
        t0 = time.time()
        self.run_once()
        self.assertLess(time.time() - t0, 2)
        self.assertFalse(self.exists("a.res.json"))
        self.assertTrue(self.exists("a.claimed"))
        # a second wake for the same name starts no new process; other requests are handled as usual
        self.put("b", createdAt=NOW + 1)
        with open(os.path.join(self.ob, "c.req.json"), "w") as f:
            json.dump(_sig.req({"id": "c", "type": "text", "text": "hi", "sessionId": "nope", "createdAt": NOW + 1}), f)
        self.run_once()
        self.assertEqual(self.res("c")["error"], "session-gone")
        self.assertFalse(self.exists("b.res.json"))
        self.assertTrue(self.exists("a.claimed"))  # still running in the background, not treated as a leftover
        open(os.path.join(self.tmp.name, "go"), "w").close()
        ra = self.wait_res("a")
        rb = self.res("b")
        self.assertEqual((ra["status"], rb["status"]), ("done", "done"))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(open(self.log).read().count("\twake\t"), 2)

    def test_timeout_kills_and_fails(self):
        self.mode("hang")
        self.put("a")
        with mock.patch.object(outbox, "WAKE_TIMEOUT", 0.3):
            r = self.wait_res("a")
        self.assertEqual((r["status"], r["error"]), ("failed", "wake-timeout"))
        self.assertEqual(outbox._WAKES, {})

    def test_timeout_but_already_awake_is_done(self):
        self.mode("hang")
        self.put("a")
        with mock.patch.object(outbox, "WAKE_TIMEOUT", 0.3):
            self.run_once()
            time.sleep(0.4)
            self.run_once({"s9": {"id": "s9", "kind": "claude", "name": "Lab-off"}})
        self.assertEqual(self.res("a")["status"], "done")

    def test_popen_failure(self):
        self.put("a")
        self.run_once(cmd=[os.path.join(self.tmp.name, "does-not-exist")])
        r = self.res("a")
        self.assertEqual((r["error"], bool(r["message"])), ("wake-failed", True))

    def test_leftover_claimed_wake_is_helper_restarted_not_rerun(self):
        self.put("a")
        os.replace(os.path.join(self.ob, "a.req.json"), os.path.join(self.ob, "a.claimed"))
        self.run_once()
        self.assertEqual(self.res("a")["error"], "helper-restarted")
        self.assertEqual(self.calls(), [])

    def test_stale_wake_request_times_out(self):
        self.put("a", createdAt=NOW - 100)
        self.run_once()
        self.assertEqual(self.res("a")["error"], "helper-timeout")
        self.assertEqual(self.calls(), [])

    def test_constants(self):
        self.assertEqual(outbox.WAKE_TIMEOUT, 120)
        if outbox.WAKE_CMD:  # empty when no script is configured
            self.assertIn("--wake", outbox.WAKE_CMD)

    def test_offduty_script_configurable(self):
        """The wake script path is not hard-coded: environment variable -> webapp/.env -> empty (disabled)."""
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(outbox.offduty_script({}, d), outbox.OFFDUTY_DEFAULT)
            with open(os.path.join(d, ".env"), "w") as f:
                f.write("X=1\nSOULGENT_OFFDUTY=~/tools/offduty.py\n")
            self.assertEqual(outbox.offduty_script({}, d), os.path.expanduser("~/tools/offduty.py"))
            self.assertEqual(outbox.offduty_script({"SOULGENT_OFFDUTY": "/opt/o.py"}, d), "/opt/o.py")
            self.assertEqual(outbox.offduty_script({"SOULGENT_OFFDUTY": "  "}, d), os.path.expanduser("~/tools/offduty.py"))


if __name__ == "__main__":
    unittest.main()
