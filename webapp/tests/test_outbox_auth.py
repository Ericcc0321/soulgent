"""outbox security: request/result signing, file permissions, and guest messages re-checking the on-screen menu before delivery."""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import _sig  # noqa: E402
from api import outbox as api_outbox  # noqa: E402
from helper import outbox as helper_outbox  # noqa: E402
from tests.test_outbox import FAKE_ORCA, NOW  # noqa: E402

RID = "c" * 32


class ApiSignTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ob = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, rid):
        with open(os.path.join(self.ob, rid + ".req.json")) as f:
            return json.load(f)

    def test_request_signed_with_account_and_private_mode(self):
        rid = api_outbox.enqueue(self.ob, "s1", {"type": "text", "text": "hi", "enter": True}, "guest")
        req = self.read(rid)
        self.assertEqual(req["account"], "guest")
        self.assertTrue(helper_outbox.verify("req", req, _sig.SECRET.encode()))  # the helper's copy verifies
        mode = stat.S_IMODE(os.stat(os.path.join(self.ob, rid + ".req.json")).st_mode)
        self.assertEqual(mode, 0o600)

    def test_no_secret_refuses_to_write(self):
        with mock.patch.dict(os.environ, {"OUTBOX_SECRET": ""}):
            with self.assertRaises(OSError):
                api_outbox.enqueue(self.ob, "s1", {"type": "text", "text": "hi", "enter": True}, "admin")
        with mock.patch.dict(os.environ, {"OUTBOX_SECRET": "short"}):
            with self.assertRaises(OSError):
                api_outbox.enqueue_mark(self.ob, seen={"s1": 1.0})
        self.assertEqual([n for n in os.listdir(self.ob) if not n.startswith(".")], [])

    def write_res(self, rid, obj):
        with open(os.path.join(self.ob, rid + ".res.json"), "w") as f:
            json.dump(obj, f)

    def test_forged_result_ignored(self):
        """Results forged by another local account (unsigned / signed for another request id / signed with the request domain) are all rejected."""
        self.write_res(RID, {"id": RID, "status": "done", "lines": ["假屏幕"]})
        self.assertIsNone(api_outbox.request_status(self.ob, RID, time.time()))
        other = _sig.res({"id": "d" * 32, "status": "done"})
        self.write_res(RID, other)
        self.assertIsNone(api_outbox.request_status(self.ob, RID, time.time()))
        self.write_res(RID, _sig.req({"id": RID, "status": "done"}, account=None))
        self.assertIsNone(api_outbox.request_status(self.ob, RID, time.time()))
        self.write_res(RID, _sig.res({"id": RID, "status": "done", "lines": ["真"]}))
        self.assertEqual(api_outbox.request_status(self.ob, RID, time.time()), {"status": "done", "lines": ["真"]})

    def test_helper_result_verifies_in_api(self):
        helper_outbox._write_result(self.ob, RID, "no-terminal", None, NOW)
        mode = stat.S_IMODE(os.stat(os.path.join(self.ob, RID + ".res.json")).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(api_outbox.request_status(self.ob, RID, time.time()),
                         {"status": "failed", "error": "no-terminal"})


class HelperAuthTest(unittest.TestCase):
    """macOS: fakes the session process with a re-signed copy of sleep (same as test_outbox)."""

    def setUp(self):
        p = mock.patch.object(helper_outbox, "proc_comm", lambda pid: "claude")
        p.start()
        self.addCleanup(p.stop)
        p2 = mock.patch.object(helper_outbox, "_pause", lambda *a: None)
        p2.start()
        self.addCleanup(p2.stop)
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.ob = os.path.join(t, "outbox")
        self.sdir = os.path.join(t, "sessions")
        os.makedirs(self.ob)
        os.makedirs(self.sdir)
        self.up = os.path.join(t, "uploads")
        os.makedirs(self.up)
        open(os.path.join(self.up, "x.pdf"), "w").close()
        self.orca = os.path.join(t, "orca")
        with open(self.orca, "w") as f:
            f.write(FAKE_ORCA)
        os.chmod(self.orca, 0o755)
        self.sleeper = os.path.join(t, "fakeclaude")
        shutil.copy("/bin/sleep", self.sleeper)
        if sys.platform == "darwin":  # only macOS needs the re-sign (SIP hides env of system binaries from ps)
            subprocess.run(["codesign", "-s", "-", "-f", self.sleeper], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True)
        env = dict(os.environ, ORCA_TERMINAL_HANDLE="term_abc")
        self.proc = subprocess.Popen([self.sleeper, "60"], env=env)
        with open(os.path.join(self.sdir, "%d.json" % self.proc.pid), "w") as f:
            json.dump({"sessionId": "s1", "cwd": "/tmp"}, f)
        time.sleep(0.2)
        self.sessions = {"s1": {"id": "s1", "kind": "claude", "name": "Lab-test", "status": "idle"}}

    def tearDown(self):
        self.proc.kill()
        self.proc.wait()
        self.tmp.cleanup()

    def put(self, body, rid=RID, raw=False):
        with open(os.path.join(self.ob, rid + ".req.json"), "w") as f:
            json.dump(body if raw else _sig.req(body, rid=rid, account=None), f)

    def run_once(self):
        return helper_outbox.process_once(self.ob, self.sessions, self.sdir, [self.orca],
                                          os.path.join(self.tmp.name, "send.log"), NOW + 1,
                                          uploads_dir=self.up)

    def sends(self):
        p = os.path.join(self.tmp.name, "calls.jsonl")
        if not os.path.exists(p):
            return []
        with open(p) as f:
            return [c for c in (json.loads(x) for x in f) if c[:2] == ["terminal", "send"]]

    def res(self, rid=RID):
        p = os.path.join(self.ob, rid + ".res.json")
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return json.load(f)

    def text(self, account, **kw):
        body = {"sessionId": "s1", "type": "text", "text": "[Guest] 你好", "enter": True, "createdAt": NOW}
        if account:
            body["account"] = account
        body.update(kw)
        return body

    def screen(self, lines):
        with open(os.path.join(self.tmp.name, "screen.json"), "w") as f:
            json.dump(lines, f)

    # ---- unsigned / badly signed / tampered requests are not executed ----
    def test_unsigned_request_dropped(self):
        self.put(dict(self.text("admin"), id=RID), raw=True)
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertIsNone(self.res())
        self.assertFalse(os.path.exists(os.path.join(self.ob, RID + ".req.json")))

    def test_tampered_request_dropped(self):
        body = _sig.req(self.text("guest"), rid=RID)
        body["account"] = "admin"  # a field was changed, so the signature no longer matches
        self.put(body, raw=True)
        self.run_once()
        self.assertEqual(self.sends(), [])

    def test_renamed_request_dropped(self):
        self.put(_sig.req(self.text("admin"), rid="e" * 32), raw=True)  # signed for a different request id
        self.run_once()
        self.assertEqual(self.sends(), [])

    def test_no_secret_executes_nothing(self):
        self.put(self.text("admin"))
        with mock.patch.dict(os.environ, {"OUTBOX_SECRET": ""}), \
                mock.patch.object(helper_outbox.settings, "dotenv_value", lambda *a: ""):
            self.run_once()
        self.assertEqual(self.sends(), [])

    def test_signed_admin_request_runs_and_result_signed(self):
        self.put(self.text("admin"))
        self.run_once()
        self.assertEqual(len(self.sends()), 2)
        r = self.res()
        self.assertEqual(r["status"], "done")
        self.assertTrue(api_outbox.verify("res", r, _sig.SECRET.encode()))

    # ---- guest text re-checks the menu before delivery; if the session sits at a menu, not a single byte is sent ----
    def test_guest_text_on_menu_screen_not_sent(self):
        self.screen(["Bash command", "  rm -rf build", "Do you want to proceed?", "❯ 1. Yes", "  2. No",
                     "Esc to cancel · Tab to amend"])
        self.put(self.text("guest"))
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_guest_message_on_ask_menu_not_sent(self):
        self.screen(["☐ 选哪个", "❯ 1. plan A", "  2. plan B", "Enter to select · ↑/↓ to navigate · Esc to cancel"])
        self.put({"sessionId": "s1", "type": "message", "text": "[Guest] 看", "files": ["x.pdf"],
                  "account": "carol", "createdAt": NOW})
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_guest_text_when_snapshot_waiting_not_sent(self):
        self.sessions["s1"]["status"] = "waiting"
        self.put(self.text("guest"))
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_missing_account_treated_as_guest(self):
        self.screen(["❯ 1. Yes", "  2. No"])
        self.put(self.text(None))
        self.run_once()
        self.assertEqual(self.sends(), [])

    def test_guest_key_request_forbidden(self):
        self.put({"sessionId": "s1", "type": "key", "key": "enter", "account": "guest", "createdAt": NOW})
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "forbidden")

    def test_guest_text_on_normal_prompt_sent(self):
        self.screen(["⏺ 好的", "────────", "❯ ", "────────", "  ? for shortcuts"])
        self.put(self.text("guest"))
        self.run_once()
        self.assertEqual([c[5] for c in self.sends()], ["[Guest] 你好", "\r"])
        self.assertEqual(self.res()["status"], "done")

    def test_admin_text_on_menu_screen_not_sent(self):
        """Plain text from the admin is gated exactly like a guest's: a menu on screen means nothing is sent."""
        self.screen(["❯ 1. Yes", "  2. No", "Esc to cancel"])
        self.put(self.text("admin", text="3"))
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_admin_text_when_snapshot_waiting_not_sent(self):
        self.sessions["s1"]["status"] = "waiting"
        self.put(self.text("admin"))
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_admin_message_on_menu_screen_not_sent(self):
        self.screen(["☐ 选哪个", "❯ 1. plan A", "  2. plan B", "Enter to select · Esc to cancel"])
        self.put({"sessionId": "s1", "type": "message", "text": "看", "files": ["x.pdf"],
                  "account": "admin", "createdAt": NOW})
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_admin_recall_on_menu_screen_not_sent(self):
        self.screen(["❯ 1. Yes", "  2. No", "Esc to cancel"])
        self.put({"sessionId": "s1", "type": "recall", "text": "x", "account": "admin", "createdAt": NOW})
        self.run_once()
        self.assertEqual(self.sends(), [])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_admin_key_and_steps_stay_ungated_on_menu(self):
        """Explicit approval/answer requests must still reach a menu."""
        self.screen(["❯ 1. Yes", "  2. No", "Esc to cancel"])
        self.put({"sessionId": "s1", "type": "key", "key": "enter", "account": "admin", "createdAt": NOW})
        self.run_once()
        self.assertEqual(len(self.sends()), 1)
        self.assertEqual(self.res()["status"], "done")
        os.unlink(os.path.join(self.ob, RID + ".res.json"))
        self.put({"sessionId": "s1", "type": "steps", "steps": [{"text": "1"}], "account": "admin", "createdAt": NOW})
        self.run_once()
        self.assertEqual(len(self.sends()), 2)

    # ---- read the screen again after text/attachments are typed and before Enter: if a menu has appeared, do not press Enter and clear the input box ----
    MENU = ["Bash command", "Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel"]
    NORMAL = ["⏺ 好的", "────────", "❯ ", "────────", "  ? for shortcuts"]

    def menu_after_first_pause(self):
        """At the first pause (text typed, before Enter) the session has moved to a menu."""
        def pause(*a):
            self.screen(self.MENU)
        return mock.patch.object(helper_outbox, "_pause", pause)

    def test_guest_text_menu_appears_before_enter(self):
        self.screen(self.NORMAL)
        self.put(self.text("guest"))
        with self.menu_after_first_pause():
            self.run_once()
        sent = [c[5] for c in self.sends()]
        self.assertEqual(sent[0], "[Guest] 你好")
        self.assertNotIn("\r", sent)  # Enter was not pressed
        self.assertTrue(len(sent) >= 2 and sent[1].startswith(helper_outbox.CLEAR_PAIR))  # the typed text is cleared
        self.assertEqual(set(sent[1]), set(helper_outbox.CLEAR_PAIR))
        self.assertEqual(self.res()["status"], "failed")
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_guest_message_menu_appears_before_enter(self):
        self.screen(self.NORMAL)
        self.put({"sessionId": "s1", "type": "message", "text": "[Guest] 看", "files": ["x.pdf"],
                  "account": "guest", "createdAt": NOW})
        with self.menu_after_first_pause():
            self.run_once()
        sent = [c[5] for c in self.sends()]
        self.assertNotIn("\r", sent)
        self.assertTrue(any(s.startswith(helper_outbox.CLEAR_PAIR) for s in sent))
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_guest_screen_unreadable_before_enter_not_sent(self):
        self.screen(self.NORMAL)
        self.put(self.text("guest"))

        def pause(*a):
            os.unlink(os.path.join(self.tmp.name, "screen.json"))  # the re-read of the screen cannot get the screen needed to judge a menu
            with open(os.path.join(self.tmp.name, "fail"), "w"):
                pass
        with mock.patch.object(helper_outbox, "_pause", pause):
            self.run_once()
        sent = [c[5] for c in self.sends()]
        self.assertNotIn("\r", sent)
        self.assertEqual(self.res()["status"], "failed")

    def test_admin_text_menu_appears_before_enter(self):
        self.screen(self.NORMAL)
        self.put(self.text("admin", text="3"))
        with self.menu_after_first_pause():
            self.run_once()
        sent = [c[5] for c in self.sends()]
        self.assertEqual(sent[0], "3")
        self.assertNotIn("\r", sent)  # Enter was not pressed
        self.assertEqual(self.res()["status"], "failed")
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_admin_message_menu_appears_before_enter(self):
        self.screen(self.NORMAL)
        self.put({"sessionId": "s1", "type": "message", "text": "看", "files": ["x.pdf"],
                  "account": "admin", "createdAt": NOW})
        with self.menu_after_first_pause():
            self.run_once()
        self.assertNotIn("\r", [c[5] for c in self.sends()])
        self.assertEqual(self.res()["error"], "session-waiting")

    def test_menu_detector(self):
        self.assertTrue(helper_outbox.menu_on_screen(["\x1b[36m❯\x1b[0m 1. Yes"]))
        self.assertTrue(helper_outbox.menu_on_screen(["│ ❯ 2. No, and tell Claude │"]))
        self.assertFalse(helper_outbox.menu_on_screen(["❯ 你好", "? for shortcuts"]))


if __name__ == "__main__":
    unittest.main()
