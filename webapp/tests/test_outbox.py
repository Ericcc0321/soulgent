import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET; signs hand-written requests/results

from helper import outbox

FAKE_ORCA = """#!/usr/bin/python3
import json, os, sys
d = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
if os.path.exists(os.path.join(d, "fail")):
    sys.exit(3)
if os.path.exists(os.path.join(d, "failn")):
    n = int(open(os.path.join(d, "failn")).read())
    if len(open(os.path.join(d, "calls.jsonl")).read().splitlines()) == n:
        sys.exit(3)
up = os.path.join(d, "up_append.json")  # recall tests: when ↑ is received, append a popAll line to the log
if os.path.exists(up) and "--text" in sys.argv and sys.argv[sys.argv.index("--text") + 1] == "\\x1b[A":
    spec = json.load(open(up))
    with open(spec["path"], "a") as f:
        for ln in spec["lines"]:
            f.write(json.dumps(ln, ensure_ascii=False, separators=(",", ":")) + "\\n")
scr = os.path.join(d, "screen.json")
if sys.argv[1] == "terminal" and sys.argv[2] == "read" and "--screen" in sys.argv and os.path.exists(scr):
    print(json.dumps({"ok": True, "result": {"terminal": {"tail": json.load(open(scr))}}}))
elif sys.argv[1] == "terminal" and sys.argv[2] == "read":
    print(json.dumps({"ok": True, "result": {"terminal": {"tail": ["l%d" % i if i % 2 else "\\x1b[31mred%d\\x1b[0m" % i for i in range(40)]}}}))
else:
    print(json.dumps({"ok": True, "result": {"send": {"accepted": True}}}))
"""

NOW = 1792400000.0


class OutboxTest(unittest.TestCase):
    """macOS only: fakes the session process with ps / codesign / a re-signed copy of sleep."""

    def setUp(self):
        # the fake process is not named claude, so patch out the comm check; dedicated tests restore it
        patcher = mock.patch.object(outbox, "proc_comm", lambda pid: "claude")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.outbox = os.path.join(t, "outbox")
        self.sdir = os.path.join(t, "sessions")
        os.makedirs(self.outbox)
        os.makedirs(self.sdir)
        self.orca = os.path.join(t, "orca")
        with open(self.orca, "w") as f:
            f.write(FAKE_ORCA)
        os.chmod(self.orca, 0o755)
        self.log = os.path.join(t, "send.log")
        # ps cannot see the environment of system binaries, so a re-signed copy stands in for the session process
        self.sleeper = os.path.join(t, "fakeclaude")
        shutil.copy("/bin/sleep", self.sleeper)
        if sys.platform == "darwin":  # only macOS needs the re-sign (SIP hides env of system binaries from ps)
            subprocess.run(["codesign", "-s", "-", "-f", self.sleeper], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True)
        self.procs = []
        self.sessions = {"s1": {"id": "s1", "kind": "claude", "name": "Lab-test"},
                         "sh": {"id": "sh", "kind": "shell", "name": "shell"}}

    def tearDown(self):
        for p in self.procs:
            p.kill()
            p.wait()
        self.tmp.cleanup()

    def spawn(self, sid, handle="term_abc"):
        env = {k: v for k, v in os.environ.items() if k != "ORCA_TERMINAL_HANDLE"}
        if handle:
            env["ORCA_TERMINAL_HANDLE"] = handle
        p = subprocess.Popen([self.sleeper, "60"], env=env)
        self.procs.append(p)
        with open(os.path.join(self.sdir, "%d.json" % p.pid), "w") as f:
            json.dump({"sessionId": sid, "cwd": "/tmp"}, f)
        time.sleep(0.2)
        return p

    def req(self, rid, **kw):
        body = {"id": rid, "sessionId": "s1", "type": "text", "text": "hi", "enter": True, "createdAt": NOW}
        body.update(kw)
        with open(os.path.join(self.outbox, rid + ".req.json"), "w") as f:
            json.dump(_sig.req(body), f)

    def run_once(self, now=NOW + 1):
        return outbox.process_once(self.outbox, self.sessions, self.sdir, [self.orca], self.log, now)

    def res(self, rid):
        with open(os.path.join(self.outbox, rid + ".res.json")) as f:
            return json.load(f)

    def calls(self):
        p = os.path.join(os.path.dirname(self.orca), "calls.jsonl")
        if not os.path.exists(p):
            return []
        with open(p) as f:
            return [json.loads(l) for l in f]

    def test_text_send(self):
        self.spawn("s1")
        self.req("a" * 32, text="  hello\nworld\x07  ")
        with mock.patch.object(outbox, "_pause") as pause:
            self.assertEqual(self.run_once(), 1)
        # text and Enter are sent separately: orca's --enter waits for submit confirmation (about 1.8 s); sending separately takes about 0.9 s
        # a menu re-check (screen read) runs before delivery and again before Enter, for every account
        read = ["terminal", "read", "--terminal", "term_abc", "--screen", "--json"]
        self.assertEqual(self.calls(), [read, ["terminal", "send", "--terminal", "term_abc", "--text", "hello world", "--json"],
                                        read, ["terminal", "send", "--terminal", "term_abc", "--text", "\r", "--json"]])
        self.assertEqual(pause.call_count, 1)
        r = self.res("a" * 32)
        self.assertEqual(r["status"], "done")
        self.assertAlmostEqual(r["finishedAt"], NOW + 1, delta=2)
        self.assertFalse(os.path.exists(os.path.join(self.outbox, "a" * 32 + ".req.json")))

    def test_text_no_enter(self):
        self.spawn("s1")
        self.req("a" * 32, enter=False)
        self.run_once()
        self.assertEqual(len(self.sent()), 1)  # (the menu re-check reads the screen first; that is not a send)
        self.assertNotIn("--enter", self.calls()[-1])

    def test_key_esc(self):
        self.spawn("s1")
        self.req("b" * 32, type="key", key="esc")
        self.run_once()
        self.assertEqual(self.calls(), [["terminal", "send", "--terminal", "term_abc", "--text", "\x1b", "--json"]])
        self.assertEqual(self.res("b" * 32)["status"], "done")

    def steps_req(self, rid, steps, **kw):
        self.req(rid, type="steps", steps=steps, **kw)

    def sent(self):
        return [c[c.index("--text") + 1] for c in self.calls() if "--text" in c]

    def test_steps_right_key_and_24_steps(self):
        self.spawn("s1")
        self.steps_req("a" * 32, [{"key": "1"}, {"key": "right"}] + [{"key": "down"}] * 22)
        with mock.patch.object(outbox, "_pause"):
            self.assertEqual(self.run_once(), 1)
        self.assertEqual(self.sent()[:3], ["1", "\x1b[C", "\x1b[B"])
        self.assertEqual(len(self.sent()), 24)
        self.assertEqual(self.res("a" * 32)["status"], "done")

    def test_steps_sent_in_order_with_pauses(self):
        self.spawn("s1")
        self.steps_req("a" * 32, [{"key": "2"}, {"key": "3"}, {"text": " 芒果\n汁 "}, {"key": "enter"}, {"key": "1"}])
        with mock.patch.object(outbox, "_pause") as pause:
            self.assertEqual(self.run_once(), 1)
        self.assertEqual(self.sent(), ["2", "3", "芒果 汁", "\r", "1"])
        self.assertTrue(all("--enter" not in c for c in self.calls()))
        self.assertEqual(pause.call_count, 4)
        self.assertEqual(self.res("a" * 32)["status"], "done")

    def test_step_delay_value(self):
        self.assertEqual(outbox.STEP_DELAY, 0.15)
        self.assertEqual(outbox.PASTE_DELAY, 0.35)

    def test_steps_key_map_extended(self):
        self.spawn("s1")
        self.steps_req("a" * 32, [{"key": k} for k in "56789"] + [{"key": "esc"}])
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        self.assertEqual(self.sent(), ["5", "6", "7", "8", "9", "\x1b"])

    def test_steps_key_n(self):
        """Preview question with a note: the n in steps is sent as the letter n; n is the only letter on the allowlist."""
        self.spawn("s1")
        self.steps_req("a" * 32, [{"key": "2"}, {"key": "1"}, {"key": "n"}, {"text": "备注"}, {"key": "enter"}])
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        self.assertEqual(self.sent(), ["2", "1", "n", "备注", "\r"])
        self.assertEqual(self.res("a" * 32)["status"], "done")
        self.assertEqual([k for k in outbox.KEYS if len(k) == 1 and k.isalpha()], ["n"])
        self.assertIsNone(outbox._steps_payloads([{"key": "m"}]))
        self.assertIsNone(outbox._steps_payloads([{"key": "N"}]))

    def test_steps_stop_on_failure(self):
        self.spawn("s1")
        self.steps_req("a" * 32, [{"key": "1"}, {"key": "2"}, {"key": "3"}])
        with open(os.path.join(os.path.dirname(self.orca), "failn"), "w") as f:
            f.write("2")
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        self.assertEqual(len(self.calls()), 2)
        r = self.res("a" * 32)
        self.assertEqual((r["status"], r["error"]), ("failed", "orca-failed"))
        self.assertEqual(r["sentSteps"], 1)
        with open(self.log, encoding="utf-8") as f:
            self.assertTrue(f.read().rstrip("\n").endswith("failed:orca-failed sent=1"))

    def test_steps_first_step_failure_has_no_sent_steps(self):
        self.spawn("s1")
        self.steps_req("a" * 32, [{"key": "1"}, {"key": "2"}])
        with open(os.path.join(os.path.dirname(self.orca), "failn"), "w") as f:
            f.write("1")
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        self.assertNotIn("sentSteps", self.res("a" * 32))

    def test_steps_bad_sends_nothing(self):
        self.spawn("s1")
        bad = [[], [{"key": "1"}] * 25, [{"key": "x"}], [{"text": " "}], [{"key": "1"}, {"text": 5}], "1", None,
               [{"key": "1", "text": "a"}], ["1"]]
        for i, steps in enumerate(bad):
            self.steps_req("%032x" % i, steps)
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        self.assertEqual(self.calls(), [])
        for i in range(len(bad)):
            self.assertEqual(self.res("%032x" % i)["error"], "bad-request")

    def test_steps_log_summary(self):
        self.spawn("s1")
        self.steps_req("a" * 32, [{"key": "2"}, {"key": "3"}, {"text": "芒果"}, {"key": "enter"}, {"key": "1"}])
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        with open(self.log, encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0].split("\t")[2:], ["steps", "2 | 3 芒果 ⏎ | 1", "done"])

    def test_steps_session_gone(self):
        self.steps_req("a" * 32, [{"key": "1"}])
        self.run_once()
        self.assertEqual(self.res("a" * 32)["error"], "session-gone")

    def test_bad_requests(self):
        self.spawn("s1")
        self.req("c" * 32, type="key", key="f5")
        self.req("d" * 32, text="\n \x01")
        self.req("e" * 32, text="x" * 4001)
        self.run_once()
        for c in "cde":
            self.assertEqual(self.res(c * 32)["error"], "bad-request")
        self.assertEqual(self.calls(), [])

    def test_not_claude(self):
        self.spawn("sh")
        self.req("a" * 32, sessionId="sh")
        self.run_once()
        self.assertEqual(self.res("a" * 32)["error"], "not-claude")
        self.assertEqual(self.calls(), [])

    def test_session_gone(self):
        p = self.spawn("s1")
        p.kill()
        p.wait()
        self.req("a" * 32)
        self.req("b" * 32, sessionId="unknown")
        self.run_once()
        self.assertEqual(self.res("a" * 32)["error"], "session-gone")
        self.assertEqual(self.res("b" * 32)["error"], "session-gone")
        self.assertEqual(self.calls(), [])

    def test_no_terminal(self):
        self.spawn("s1", handle=None)
        self.req("a" * 32)
        self.run_once()
        self.assertEqual(self.res("a" * 32)["error"], "no-terminal")
        self.assertEqual(self.calls(), [])

    def test_orca_failed(self):
        self.spawn("s1")
        open(os.path.join(os.path.dirname(self.orca), "fail"), "w").close()
        self.req("a" * 32)
        self.run_once()
        self.assertEqual(self.res("a" * 32)["error"], "orca-failed")

    def test_screen(self):
        self.spawn("s1")
        self.req("a" * 32, type="screen")
        self.run_once()
        r = self.res("a" * 32)
        self.assertEqual(r["status"], "done")
        self.assertEqual(len(r["lines"]), 30)
        self.assertEqual(r["lines"][-1], "l39")
        self.assertEqual(r["lines"][-2], "red38")
        self.assertEqual(self.calls(), [["terminal", "read", "--terminal", "term_abc", "--json"]])

    def test_stale_request_not_executed(self):
        self.spawn("s1")
        self.req("a" * 32)
        self.run_once(now=NOW + 31)
        self.assertEqual(self.res("a" * 32)["error"], "helper-timeout")
        self.assertEqual(self.calls(), [])

    def test_old_results_cleaned(self):
        old = os.path.join(self.outbox, "f" * 32 + ".res.json")
        new = os.path.join(self.outbox, "0" * 32 + ".res.json")
        for p in (old, new):
            with open(p, "w") as f:
                f.write("{}")
        os.utime(old, (NOW - 601, NOW - 601))
        os.utime(new, (NOW - 10, NOW - 10))
        self.run_once()
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(new))

    def test_log_line(self):
        self.spawn("s1")
        self.req("a" * 32, text="x" * 300)
        self.req("b" * 32, type="key", key="1", createdAt=NOW + 0.1)
        self.run_once()
        with open(self.log, encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertEqual(len(lines), 2)
        fields = lines[0].split("\t")
        self.assertEqual(len(fields), 5)
        self.assertEqual(fields[1:], ["Lab-test", "text", "x" * 200, "done"])
        self.assertEqual(lines[1].split("\t")[2:], ["key", "1", "done"])

    def test_pid_reuse_comm_mismatch(self):
        p = self.spawn("s1")
        with mock.patch.object(outbox, "proc_comm", lambda pid: "bash"):
            self.assertIsNone(outbox.pid_for("s1", self.sdir))
        self.assertEqual(outbox.pid_for("s1", self.sdir), p.pid)

    def test_pid_for_accepts_versioned_claude_binary(self):
        p = self.spawn("s1")
        for comm, ok in (("/Users/u/.local/share/claude/versions/2.1.303", True),
                         ("/usr/local/bin/claude", True), ("claude", True),
                         ("/usr/bin/bash", False), ("claude bg-spare", False), (None, False)):
            with mock.patch.object(outbox, "proc_comm", lambda pid, c=comm: c):
                self.assertEqual(outbox.pid_for("s1", self.sdir), p.pid if ok else None, comm)

    def test_is_claude_comm(self):
        self.assertTrue(outbox.is_claude_comm("/Users/u/.local/share/claude/versions/2.1.303"))
        self.assertTrue(outbox.is_claude_comm("claude"))
        self.assertFalse(outbox.is_claude_comm("/opt/claudette"))
        self.assertFalse(outbox.is_claude_comm(""))

    def test_pid_reuse_procstart(self):
        p = self.spawn("s1")
        path = os.path.join(self.sdir, "%d.json" % p.pid)
        start = outbox.proc_lstart(p.pid)
        self.assertTrue(start)
        with open(path, "w") as f:
            json.dump({"sessionId": "s1", "procStart": start}, f)
        self.assertEqual(outbox.pid_for("s1", self.sdir), p.pid)
        with open(path, "w") as f:
            json.dump({"sessionId": "s1", "procStart": "Mon Jan  1 00:00:00 2024"}, f)
        self.assertIsNone(outbox.pid_for("s1", self.sdir))

    def test_pid_for_picks_passing_file(self):
        stale = self.spawn("s1")
        good = self.spawn("s1")
        with open(os.path.join(self.sdir, "%d.json" % stale.pid), "w") as f:
            json.dump({"sessionId": "s1", "procStart": "Mon Jan  1 00:00:00 2024"}, f)
        with open(os.path.join(self.sdir, "%d.json" % good.pid), "w") as f:
            json.dump({"sessionId": "s1", "procStart": outbox.proc_lstart(good.pid)}, f)
        self.assertEqual(outbox.pid_for("s1", self.sdir), good.pid)

    def test_result_write_failure_no_resend(self):
        self.spawn("s1")
        self.req("a" * 32)
        with mock.patch.object(outbox, "_write_atomic", side_effect=OSError("disk")):
            self.run_once()
        self.assertEqual(len(self.sent()), 2)  # one send = text + Enter
        self.run_once()
        self.assertEqual(len(self.sent()), 2)
        self.assertEqual(self.res("a" * 32)["error"], "helper-restarted")
        self.assertFalse(os.path.exists(os.path.join(self.outbox, "a" * 32 + ".claimed")))

    def test_leftover_claimed(self):
        self.spawn("s1")
        with open(os.path.join(self.outbox, "a" * 32 + ".claimed"), "w") as f:
            json.dump({"id": "a" * 32, "sessionId": "s1", "type": "text", "text": "x", "createdAt": NOW}, f)
        self.run_once()
        self.assertEqual(self.res("a" * 32)["error"], "helper-restarted")
        self.assertEqual(self.calls(), [])

    def test_malformed_and_tmp_ignored(self):
        with open(os.path.join(self.outbox, "a" * 32 + ".req.json"), "w") as f:
            f.write("{not json")
        with open(os.path.join(self.outbox, "b" * 32 + ".req.json"), "w") as f:
            f.write("[1]")
        with open(os.path.join(self.outbox, ".req-xyz.tmp"), "w") as f:
            f.write("{}")
        # unreadable JSON / not an object = unsigned: drop it, neither execute nor write a result (the api side will later report helper-timeout)
        self.assertEqual(self.run_once(), 0)
        for rid in ("a" * 32, "b" * 32):
            self.assertFalse(os.path.exists(os.path.join(self.outbox, rid + ".req.json")))
            self.assertFalse(os.path.exists(os.path.join(self.outbox, rid + ".res.json")))
        self.assertTrue(os.path.exists(os.path.join(self.outbox, ".req-xyz.tmp")))

    def test_text_cleaning_c1_and_separators(self):
        self.assertEqual(outbox.clean_text("a\u2028b\u2029c\x85d\x9fe"), "a b cde")

    def test_enter_must_be_bool(self):
        self.spawn("s1")
        self.req("a" * 32, enter="yes")
        self.run_once()
        self.assertEqual(self.res("a" * 32)["error"], "bad-request")

    def test_future_created_at_uses_mtime(self):
        self.spawn("s1")
        self.req("a" * 32, createdAt=NOW + 99999)
        os.utime(os.path.join(self.outbox, "a" * 32 + ".req.json"), (NOW, NOW))
        self.run_once(now=NOW + 1)
        self.assertEqual(self.res("a" * 32)["status"], "done")

    def test_strip_ansi(self):
        self.assertEqual(outbox.strip_ansi("\x1b[1;31mA\x1b[0m\x1b]0;title\x07B\x1b[?25h"), "AB")

    def test_terminal_handle_and_pid_for(self):
        p = self.spawn("s1", handle="term_zz")
        self.assertEqual(outbox.pid_for("s1", self.sdir), p.pid)
        self.assertEqual(outbox.terminal_handle(p.pid), "term_zz")
        self.assertIsNone(outbox.pid_for("nope", self.sdir))

    # ---------- multi-line quotes (sent as paste), recalling queued messages ----------
    def test_text_lines_sent_as_paste(self):
        self.spawn("s1")
        self.req("a" * 32, text="> 看板: 原文\n\n好的\x07", lines=True)
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        self.assertEqual(self.sent(), ["\x1b[200~> 看板: 原文\n\n好的\x1b[201~", "\r"])
        self.assertEqual(self.res("a" * 32)["status"], "done")

    def test_text_without_lines_still_one_line(self):
        self.spawn("s1")
        self.req("a" * 32, text="a\nb")
        with mock.patch.object(outbox, "_pause"):
            self.run_once()
        self.assertEqual(self.sent(), ["a b", "\r"])

    def test_message_lines_tail_pasted(self):
        up = os.path.realpath(os.path.join(self.tmp.name, "uploads"))
        os.makedirs(up)
        with open(os.path.join(up, "f.txt"), "w") as f:
            f.write("x")
        parts = outbox.attach_parts({"type": "message", "files": ["f.txt"], "text": "> 我: 原文\n\n看", "lines": True}, up)
        self.assertEqual(parts, ["\x1b[200~> 我: 原文\n\n看 （附件：" + os.path.join(up, "f.txt") + "）\x1b[201~"])

    def q(self, op, content=None):
        d = {"type": "queue-operation", "operation": op, "timestamp": "t"}
        if content is not None:
            d["content"] = content
        return d

    def recall_setup(self, queued, popped, screen_after=("❯ ",)):
        proj = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(proj, "p"), exist_ok=True)
        path = os.path.join(proj, "p", "s1.jsonl")
        with open(path, "w") as f:
            for c in queued:
                f.write(json.dumps(self.q("enqueue", c), ensure_ascii=False, separators=(",", ":")) + "\n")
        self.sessions["s1"]["transcript"] = "p/s1.jsonl"
        d = os.path.dirname(self.orca)
        with open(os.path.join(d, "up_append.json"), "w") as f:
            json.dump({"path": path, "lines": [self.q("popAll", c) for c in popped]}, f)
        with open(os.path.join(d, "screen.json"), "w") as f:
            json.dump(["⏺ 干活中", "─" * 20 + " Lab-test ─"] + list(screen_after) + ["─" * 40, "  状态栏"], f)
        p = mock.patch.object(outbox, "PROJECTS_DIR", proj)
        p.start()
        self.addCleanup(p.stop)
        return path

    def test_recall_pulls_back_clears_and_requeues_others(self):
        self.spawn("s1")
        self.recall_setup(["queued-alice", "queued-bob", "queued-carol"], ["queued-alice", "queued-bob", "queued-carol"])
        self.req("c" * 32, type="recall", text="queued-bob")
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01):
            self.run_once()
        sent = self.sent()
        self.assertEqual(sent[0], "\x1b[A")
        self.assertTrue(sent[1].startswith("\x15\x7f") and set(sent[1]) == {"\x15", "\x7f"})
        self.assertEqual(sent[2:], ["queued-alice", "\r", "queued-carol", "\r"])
        self.assertNotIn("\x1b", "".join(sent[1:]))  # never clear the input box with Esc (it would interrupt the turn)
        self.assertEqual(self.res("c" * 32)["status"], "done")

    def test_recall_multiline_target(self):
        self.spawn("s1")
        self.recall_setup(["alice", "> 我: 原文\n\nbob"], ["alice", "> 我: 原文\n\nbob"])
        self.req("c" * 32, type="recall", text="> 我: 原文\n\nbob")
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01):
            self.run_once()
        self.assertEqual(self.sent()[2:], ["alice", "\r"])
        self.assertEqual(self.res("c" * 32)["status"], "done")

    def test_recall_not_queued_sends_nothing(self):
        self.spawn("s1")
        self.recall_setup(["queued-alice"], ["queued-alice"])
        with open(os.path.join(self.tmp.name, "projects", "p", "s1.jsonl"), "a") as f:
            f.write(json.dumps(dict(self.q("remove", "queued-alice"), reason="absorbed_mid_turn"), ensure_ascii=False,
                               separators=(",", ":")) + "\n")
        self.req("c" * 32, type="recall", text="queued-alice")
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01):
            self.run_once()
        self.assertEqual(self.sent(), [])
        self.assertEqual(self.res("c" * 32)["error"], "already-read")

    def test_recall_slipped_through_reports_already_read(self):
        """Absorbed just before ↑ was pressed: no queued message is pulled back (↑ brings up history), the input box is still cleared, and it reports as read."""
        self.spawn("s1")
        self.recall_setup(["queued-alice"], [])
        self.req("c" * 32, type="recall", text="queued-alice")
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01):
            self.run_once()
        sent = self.sent()
        self.assertEqual(sent[0], "\x1b[A")
        self.assertEqual(set(sent[1]), {"\x15", "\x7f"})
        self.assertEqual(len(sent), 2)
        self.assertEqual(self.res("c" * 32)["error"], "already-read")

    def test_recall_target_slipped_but_others_pulled_back_are_resent(self):
        """Target absorbed just before ↑, others still queued: the other messages pulled back are re-sent, then it reports as read."""
        self.spawn("s1")
        self.recall_setup(["alice", "bob", "carol"], ["alice", "bob"])
        self.req("c" * 32, type="recall", text="carol")
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01):
            self.run_once()
        self.assertEqual(self.sent()[2:], ["alice", "\r", "bob", "\r"])
        self.assertEqual(self.res("c" * 32)["error"], "already-read")

    def _recall_with_gate(self, gates):
        """gates are the successive menu_gate return values; returns (keys sent, result error, number of menu_gate calls after the entry gate)."""
        self.spawn("s1")
        self.recall_setup(["alice", "bob", "carol"], ["alice", "bob", "carol"])
        self.req("c" * 32, type="recall", text="bob")
        g = mock.Mock(side_effect=[None] + list(gates))  # the first call is the entry gate every recall request passes
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01), \
                mock.patch.object(outbox, "menu_gate", g), mock.patch.object(outbox, "_warn") as w:
            self.run_once()
        return self.sent(), self.res("c" * 32).get("error"), g.call_count - 1, w

    def test_recall_resend_gates_before_typing_and_enter(self):
        sent, err, n, _ = self._recall_with_gate([None] * 4)
        self.assertEqual(sent[2:], ["alice", "\r", "carol", "\r"])
        self.assertEqual(n, 4)
        self.assertIsNone(err)

    def test_recall_resend_menu_before_enter_clears_and_stops(self):
        sent, err, n, w = self._recall_with_gate([None, "session-waiting"])
        self.assertEqual(sent[2], "alice")
        self.assertTrue(set(sent[3]) == {"\x15", "\x7f"})
        self.assertNotIn("\r", sent)
        self.assertNotIn("carol", sent)
        self.assertEqual(len(sent), 4)
        self.assertEqual(err, "session-waiting")
        self.assertIn("2 not sent back", w.call_args[0][0])
        self.assertNotIn("carol", w.call_args[0][0])

    def test_recall_resend_menu_before_typing_stops_without_typing(self):
        sent, err, n, _ = self._recall_with_gate(["session-waiting"])
        self.assertEqual(len(sent), 2)  # only ↑ and the input-box clear
        self.assertEqual(err, "session-waiting")

    def test_recall_resend_screen_unreadable_before_enter(self):
        sent, err, n, _ = self._recall_with_gate([None, "orca-failed"])
        self.assertNotIn("\r", sent)
        self.assertEqual(err, "orca-failed")

    def test_recall_resend_real_screen_menu_blocks_enter(self):
        """menu_gate is not mocked: when a menu appears on screen during re-send, the real screen-reading path must also block Enter."""
        self.spawn("s1")
        self.recall_setup(["alice", "bob"], ["alice", "bob"], screen_after=("❯ 1. 是", "  2. 否"))
        self.req("c" * 32, type="recall", text="bob")
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01):
            self.run_once()
        self.assertNotIn("\r", self.sent())
        self.assertIn(self.res("c" * 32).get("error"), ("session-waiting", "recall-uncertain"))

    def test_recall_input_not_cleared_fails_without_resend(self):
        self.spawn("s1")
        self.recall_setup(["queued-alice", "queued-bob"], ["queued-alice", "queued-bob"], screen_after=("❯ queued-alice",))
        self.req("c" * 32, type="recall", text="queued-bob")
        with mock.patch.object(outbox, "_pause"), mock.patch.object(outbox, "RECALL_POLL", 0.01):
            self.run_once()
        self.assertNotIn("\r", self.sent())
        self.assertEqual(self.res("c" * 32)["error"], "recall-uncertain")

    def test_jsonl_path_by_id_when_no_transcript_field(self):
        proj = os.path.join(self.tmp.name, "projects")
        sid = "eeeeeeee-5555-4555-8555-555555555555"
        os.makedirs(os.path.join(proj, "-tmp-x"))
        open(os.path.join(proj, "-tmp-x", sid + ".jsonl"), "w").close()
        with mock.patch.object(outbox, "PROJECTS_DIR", proj):
            self.assertTrue(outbox._jsonl_path({"id": sid}).endswith("/-tmp-x/" + sid + ".jsonl"))
            self.assertIsNone(outbox._jsonl_path({"id": "../../etc"}))
            self.assertIsNone(outbox._jsonl_path({"id": "00000000-0000-0000-0000-000000000000"}))

    def test_input_box_parse(self):
        self.assertEqual(outbox.input_box(["x", "──── A ─", "❯ 你好", "  第二行", "─────", "状态"]), "你好 第二行")
        self.assertEqual(outbox.input_box(["x", "──── A ─", "❯ ", "─────", "状态"]), "")
        self.assertIsNone(outbox.input_box(["没有边框"]))


if __name__ == "__main__":
    unittest.main()


class MarkTest(unittest.TestCase):
    """mark requests: subprocess is fully mocked, never writes real defaults."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ob = os.path.join(self.tmp.name, "ob")
        os.makedirs(self.ob)
        self.log = os.path.join(self.tmp.name, "send.log")
        self.calls = []
        self.domain = {"seenAt": {"a": 100.0}, "pinned": ["p1", "p2"], "other": 1}
        for k, v in (("PANEL_DOMAIN", "io.github.ericcc0321.soulgent"), ("PANEL_DOMAIN_LEGACY", "")):
            p = mock.patch.object(outbox, k, v)  # an old domain configured in the local .env does not affect these cases
            p.start()
            self.addCleanup(p.stop)

    def fake_run(self, cmd, **kw):
        self.calls.append(cmd)
        if cmd[:2] == ["defaults", "export"]:
            return subprocess.CompletedProcess(cmd, 0, stdout=plistlib.dumps(self.domain))
        return subprocess.CompletedProcess(cmd, 0)

    def put(self, req, rid="r1"):
        with open(os.path.join(self.ob, rid + ".req.json"), "w") as f:
            json.dump(_sig.req(dict(req, id=rid, type="mark", createdAt=NOW)), f)

    def run_once(self):
        with mock.patch.object(outbox.subprocess, "run", self.fake_run):
            return outbox.process_once(self.ob, {}, self.tmp.name, ["orca-not-used"], self.log, NOW)

    def writes(self):
        return [c for c in self.calls if c[:2] == ["defaults", "write"]]

    def test_seen_written_only_when_newer(self):
        self.put({"seen": {"a": 100.0, "b": 1792431352.448}})
        self.assertEqual(self.run_once(), 1)
        # store full double precision via plist syntax; -float would store single precision, which quantizes to 128-second steps
        self.assertEqual(self.writes(), [["defaults", "write", "io.github.ericcc0321.soulgent", "seenAt",
                                          "-dict-add", "b", "<real>1792431352.448</real>"]])
        self.assertEqual(os.listdir(self.ob), [])
        self.assertFalse(os.path.exists(self.log))

    def test_pin_add_and_remove(self):
        self.put({"pin": {"p3": True, "p1": False}})
        self.run_once()
        self.assertEqual(self.writes(), [["defaults", "write", "io.github.ericcc0321.soulgent", "pinned",
                                          "-array", "p2", "p3"]])

    def test_pin_to_empty_array(self):
        self.put({"pin": {"p1": False, "p2": False}})
        self.run_once()
        self.assertEqual(self.writes(), [["defaults", "write", "io.github.ericcc0321.soulgent", "pinned", "-array"]])

    def test_pin_noop_still_writes_full_array(self):
        # writes the whole set whenever there are valid entries (even with no change), keeping pinned identical in both domains during the transition
        self.put({"pin": {"p1": True, "zz": False}})
        self.run_once()
        self.assertEqual(self.writes(), [["defaults", "write", "io.github.ericcc0321.soulgent", "pinned",
                                          "-array", "p1", "p2"]])

    def test_pin_all_invalid_writes_nothing(self):
        self.put({"pin": {"-bad": True, "p1": "yes", "": False}})
        self.run_once()
        self.assertEqual(self.writes(), [])

    def test_only_two_keys_ever_written(self):
        self.put({"seen": {"b": 5.0, "-x": 9.0}, "pin": {"p9": True}, "other": {"k": 1}})
        self.run_once()
        keys = {c[3] for c in self.writes()}
        self.assertTrue(keys <= {"seenAt", "pinned"})
        self.assertFalse(any("-x" in c for c in self.writes()))

    def test_export_failure_still_removes_request(self):
        self.put({"seen": {"b": 5.0}})

        def boom(cmd, **kw):
            self.calls.append(cmd)
            raise subprocess.CalledProcessError(1, cmd)
        with mock.patch.object(outbox.subprocess, "run", boom):
            outbox.process_once(self.ob, {}, self.tmp.name, [], self.log, NOW)
        self.assertEqual(self.writes(), [])
        self.assertEqual(os.listdir(self.ob), [])


class WarnTimestampTests(unittest.TestCase):
    """Lines outbox writes to stderr (into data/helper.log, e.g. "context ... done") also carry a local-time prefix, like snapshot.log()."""

    def test_warn_line_has_local_timestamp_prefix(self):
        import io
        buf = io.StringIO()
        with mock.patch.object(outbox.sys, "stderr", buf):
            outbox._warn("context Web-x done 1.2s fork=f removed=1 reqs=1")
            outbox._warn("mark 失败 X:\n带换行")
        lines = buf.getvalue().splitlines()
        self.assertEqual(len(lines), 2)
        for ln in lines:
            self.assertRegex(ln, r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S")
        self.assertTrue(lines[0].endswith(" context Web-x done 1.2s fork=f removed=1 reqs=1"))
        self.assertTrue(lines[1].endswith(" mark 失败 X: 带换行"))
