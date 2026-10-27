import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET so hand-written requests/results can be signed

from helper import outbox

NOW = 1792400000.0


class FileHelperTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.up = os.path.join(self.tmp.name, "uploads")
        os.makedirs(self.up)
        self.real = os.path.realpath(self.up)

    def put(self, name, age=0):
        p = os.path.join(self.up, name)
        with open(p, "w") as f:
            f.write("x")
        os.utime(p, (NOW - age, NOW - age))
        return p

    def test_sentence_image_and_file(self):
        self.put("a.JPG")
        self.put("b.pdf")
        self.assertEqual(outbox.file_sentence({"file": "a.JPG"}, self.up),
                         "请看我从手机发来的图片：" + os.path.join(self.real, "a.JPG"))
        self.assertEqual(outbox.file_sentence({"file": "b.pdf", "caption": ""}, self.up),
                         "请看我从手机发来的文件：" + os.path.join(self.real, "b.pdf"))

    def test_caption_same_line(self):
        self.put("b.pdf")
        s = outbox.file_sentence({"file": "b.pdf", "caption": "帮我看看"}, self.up)
        self.assertEqual(s, "请看我从手机发来的文件：" + os.path.join(self.real, "b.pdf") + " （说明：帮我看看）")

    def test_rejects_path_tricks(self):
        self.put("ok.txt")
        outside = os.path.join(self.tmp.name, "secret.txt")
        with open(outside, "w") as f:
            f.write("s")
        os.symlink(outside, os.path.join(self.up, "link.txt"))
        os.makedirs(os.path.join(self.up, "sub"))
        for bad in ("../secret.txt", "/etc/passwd", "sub/../ok.txt", "link.txt", "sub", "missing.txt",
                    ".hidden", "", None, 5, "a\x00b", "..", "a\\b"):
            self.assertIsNone(outbox.file_sentence({"file": bad}, self.up), repr(bad))
        self.assertIsNone(outbox.file_sentence({"file": "ok.txt"}, None))

    def test_message_sentence(self):
        self.put("a.png")
        self.put("b.JPG")
        self.put("c.pdf")
        r = self.real
        pa, pb, pc = (os.path.join(r, n) for n in ("a.png", "b.JPG", "c.pdf"))
        ms = outbox.message_sentence
        self.assertEqual(ms({"text": "看看", "files": ["a.png", "c.pdf"]}, self.up),
                         "看看 （附件：%s；%s）" % (pa, pc))
        self.assertEqual(ms({"text": "", "files": ["a.png", "b.JPG"]}, self.up),
                         "请看我从手机发来的图片：%s；%s" % (pa, pb))
        self.assertEqual(ms({"files": ["a.png", "c.pdf"]}, self.up), "请看我从手机发来的文件：%s；%s" % (pa, pc))

    def test_prompts_follow_lang(self):
        """The prompt text follows the request's lang; a missing or unknown lang falls back to Simplified Chinese."""
        self.put("a.png")
        self.put("b.png")
        self.put("c.pdf")
        r = self.real
        pa, pb, pc = (os.path.join(r, n) for n in ("a.png", "b.png", "c.pdf"))
        ms, fs = outbox.message_sentence, outbox.file_sentence
        self.assertEqual(ms({"files": ["a.png"], "lang": "en"}, self.up), "Please look at the image I sent from my phone: " + pa)
        self.assertEqual(ms({"files": ["a.png", "b.png"], "lang": "en"}, self.up),
                         "Please look at the images I sent from my phone: %s; %s" % (pa, pb))
        self.assertEqual(ms({"files": ["c.pdf"], "lang": "en", "text": "see"}, self.up), "see (Attachments: %s)" % pc)
        self.assertEqual(ms({"files": ["c.pdf"], "lang": "hant"}, self.up), "請看我從手機傳來的檔案：" + pc)
        self.assertEqual(ms({"files": ["a.png"], "lang": "hant"}, self.up), "請看我從手機傳來的圖片：" + pa)
        self.assertEqual(ms({"files": ["c.pdf"], "lang": "hant", "text": "看"}, self.up), "看 （附件：%s）" % pc)
        self.assertEqual(fs({"file": "c.pdf", "caption": "note", "lang": "en"}, self.up),
                         "Please look at the file I sent from my phone: %s (Note: note)" % pc)
        self.assertEqual(fs({"file": "c.pdf", "caption": "看", "lang": "hant"}, self.up), "請看我從手機傳來的檔案：%s （說明：看）" % pc)
        for lang in (None, "fr", 3, ""):
            self.assertEqual(ms({"files": ["c.pdf"], "lang": lang}, self.up), "请看我从手机发来的文件：" + pc, repr(lang))
        # paths in all three forms are recognised by the server via the upload directory (api/transcript.py identifies attachments by path, not by prompt text)
        from api import files as F
        for s in (ms({"files": ["c.pdf", "a.png"], "lang": "en"}, self.up), ms({"files": ["c.pdf", "a.png"], "lang": "hant"}, self.up),
                  ms({"files": ["c.pdf", "a.png"]}, self.up)):
            self.assertEqual([p for p, _ in F.find_paths(s)], [pc, pa], s)

    def test_message_sentence_rejects(self):
        self.put("a.png")
        ms = outbox.message_sentence
        for files in ([], None, "a.png", ["a.png", "../x"], ["a.png", "gone.png"], ["a.png"] * 10, [".h"]):
            self.assertIsNone(ms({"text": "t", "files": files}, self.up), repr(files))
        self.assertIsNone(ms({"text": "x" * 5000, "files": ["a.png"]}, self.up))
        self.assertIsNone(ms({"text": "t", "files": ["a.png"]}, None))

    def test_cleanup_older_than_7_days(self):
        self.put("old.txt", age=7 * 86400 + 5)
        self.put("new.txt", age=7 * 86400 - 5)
        self.put(".tmp-old", age=8 * 86400)
        os.makedirs(os.path.join(self.up, "sub"))
        self.assertEqual(outbox.cleanup_uploads(self.up, NOW), 2)
        self.assertEqual(sorted(os.listdir(self.up)), ["new.txt", "sub"])
        self.assertEqual(outbox.cleanup_uploads(os.path.join(self.tmp.name, "nope"), NOW), 0)


class FileExecuteTest(unittest.TestCase):
    """_execute goes through the text send path; orca and process checks are all mocked, no real keystrokes are sent."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.up = os.path.join(self.tmp.name, "uploads")
        os.makedirs(self.up)
        with open(os.path.join(self.up, "a.png"), "w") as f:
            f.write("x")
        self.sessions = {"s1": {"id": "s1", "kind": "claude", "name": "Lab-test"}}
        self.sent = []

        def fake_orca(cmd, args):
            if args[:2] == ["terminal", "read"]:  # menu re-check before delivery: a plain prompt, no menu
                return {"ok": True, "result": {"terminal": {"tail": ["❯ "]}}}
            self.sent.append(args)
            return {"ok": True, "result": {"send": {"accepted": True}}}
        for target, val in (("pid_for", lambda sid, d: 123), ("terminal_handle", lambda pid: "term_x"),
                            ("_orca_json", fake_orca), ("_pause", lambda *a: None)):
            p = mock.patch.object(outbox, target, val)
            p.start()
            self.addCleanup(p.stop)

    def run_req(self, **kw):
        req = {"sessionId": "s1", "type": "file", "file": "a.png", "caption": "看看", "account": "admin"}
        req.update(kw)
        return outbox._execute(req, self.sessions, "/nonexistent", ["orca"], self.up)

    def test_sends_with_enter_and_logs_name_and_caption(self):
        err, lines, content, sent = self.run_req()
        self.assertIsNone(err)
        self.assertEqual(content, "a.png 看看")
        self.assertEqual(self.sent[0][:4], ["terminal", "send", "--terminal", "term_x"])
        path = os.path.join(os.path.realpath(self.up), "a.png")
        # images: first "paste" the path (Claude Code turns it into [Image #N]), then the caption, then Enter
        self.assertEqual([a[5] for a in self.sent], ["\x1b[200~" + path + "\x1b[201~", " 看看", "\r"])

    def test_missing_file_sends_nothing(self):
        self.assertEqual(self.run_req(file="gone.png")[0], "bad-request")
        self.assertEqual(self.run_req(file="../x")[0], "bad-request")
        self.assertEqual(self.sent, [])

    def test_session_checks_still_apply(self):
        self.sessions["s1"]["kind"] = "shell"
        self.assertEqual(self.run_req()[0], "not-claude")
        self.assertEqual(self.run_req(sessionId="zz")[0], "session-gone")
        self.assertEqual(self.sent, [])

    def test_process_once_passes_uploads_dir(self):
        ob = os.path.join(self.tmp.name, "outbox")
        os.makedirs(ob)
        with open(os.path.join(ob, "r" * 32 + ".req.json"), "w") as f:
            json.dump(_sig.req({"id": "r" * 32, "sessionId": "s1", "type": "file", "file": "a.png",
                                "caption": "", "createdAt": NOW}), f)
        n = outbox.process_once(ob, self.sessions, "/nonexistent", ["orca"],
                                os.path.join(self.tmp.name, "send.log"), NOW + 1, uploads_dir=self.up)
        self.assertEqual(n, 1)
        with open(os.path.join(ob, "r" * 32 + ".res.json")) as f:
            self.assertEqual(json.load(f)["status"], "done")
        self.assertTrue(self.sent[0][5].startswith("\x1b[200~"))
        self.assertEqual(self.sent[-1][5], "\r")


if __name__ == "__main__":
    unittest.main()


class MessageExecuteTest(FileExecuteTest):
    def run_msg(self, **kw):
        req = {"sessionId": "s1", "type": "message", "text": "看看", "files": ["a.png"], "account": "admin"}
        req.update(kw)
        return outbox._execute(req, self.sessions, "/nonexistent", ["orca"], self.up)

    def test_pastes_images_then_text_then_enter(self):
        err, _, content, _ = self.run_msg()
        self.assertIsNone(err)
        self.assertEqual(content, "看看 [a.png]")
        path = os.path.join(os.path.realpath(self.up), "a.png")
        self.assertEqual([a[5] for a in self.sent], ["\x1b[200~" + path + "\x1b[201~", " 看看", "\r"])

    def test_other_files_stay_as_paths(self):
        with open(os.path.join(self.up, "b.pdf"), "w") as f:
            f.write("x")
        root = os.path.realpath(self.up)
        self.assertIsNone(self.run_msg(files=["a.png", "b.pdf"])[0])
        self.assertEqual([a[5] for a in self.sent],
                         ["\x1b[200~" + os.path.join(root, "a.png") + "\x1b[201~",
                          " 看看 （附件：" + os.path.join(root, "b.pdf") + "）", "\r"])
        self.sent.clear()
        self.assertIsNone(self.run_msg(text="", files=["b.pdf"])[0])
        self.assertEqual([a[5] for a in self.sent], ["请看我从手机发来的文件：" + os.path.join(root, "b.pdf"), "\r"])
        # sent from an English-language phone: the prompt and attachment note switch to English; images are still pasted
        self.sent.clear()
        self.assertIsNone(self.run_msg(text="", files=["b.pdf"], lang="en")[0])
        self.assertEqual([a[5] for a in self.sent], ["Please look at the file I sent from my phone: " + os.path.join(root, "b.pdf"), "\r"])
        self.sent.clear()
        self.assertIsNone(self.run_msg(text="[Guest] hi", files=["a.png", "b.pdf"], lang="en")[0])
        self.assertEqual([a[5] for a in self.sent],
                         ["\x1b[200~" + os.path.join(root, "a.png") + "\x1b[201~",
                          " [Guest] hi (Attachments: " + os.path.join(root, "b.pdf") + ")", "\r"])

    def test_bad_file_sends_nothing(self):
        self.assertEqual(self.run_msg(files=["a.png", "gone.png"])[0], "bad-request")
        self.assertEqual(self.sent, [])

    def test_session_checks(self):
        self.assertEqual(self.run_msg(sessionId="zz")[0], "session-gone")
        self.assertEqual(self.sent, [])
