"""A question card keeps showing as unanswered: single-choice questions with a preview use a different UI in Claude Code 2.1.310,
where number keys only move the cursor and Enter selects, so the [1] sent by the WebApp does not answer it. The server must mark such questions preview: True (the frontend switches key presses accordingly)
and pass the note in the answer (toolUseResult.annotations[question].notes) to the answered card.
The fixture fixtures/ask_preview_notes.jsonl is a made-up preview-question sample in the Claude Code 2.1.310 transcript format (only the needed fields are kept)."""
import json
import os
import shutil
import tempfile
import unittest

from api import transcript

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures", "ask_preview_notes.jsonl")
QPV = "手册整体结构怎么排？"


def ask_line(questions, tid):
    return {"type": "assistant", "isSidechain": False, "timestamp": "2026-10-24T05:54:22.893Z",
            "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": tid, "name": "AskUserQuestion", "input": {"questions": questions}}]}}


def answer_line(tid, text, tur):
    """A tool_result line as written by Claude Code 2.1.310: content is a sentence for the model, toolUseResult carries answers / annotations."""
    return {"type": "user", "isSidechain": False, "timestamp": "2026-10-24T06:03:54.485Z",
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": text}]},
            "toolUseResult": tur}


def opt(label, preview=None):
    o = {"label": label, "description": label + " 的说明"}
    if preview is not None:
        o["preview"] = preview
    return o


class AskPreviewNotes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "s.jsonl")
        transcript._index.clear()

    def write(self, *objs):
        with open(self.path, "w", encoding="utf-8") as f:
            for o in objs:
                f.write(json.dumps(o, ensure_ascii=False, separators=(",", ":")) + "\n")

    def asks(self, **kw):
        return [i for i in transcript.read_page(self.path, None, **kw)["items"] if i["role"] == "ask"]

    # ---- sample ----
    def test_preview_question_waiting_marks_preview(self):
        with open(FIX, encoding="utf-8") as f:
            first = f.readline()
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(first)
        it = self.asks()[0]
        self.assertIs(it["answered"], False)
        self.assertIs(it["questions"][0].get("preview"), True)  # the frontend uses this to send [digit, Enter] instead
        self.assertEqual(it["questions"][0]["options"], ["概览在前，背景介绍在后（推荐）", "背景介绍当开篇"])

    def test_preview_question_answered_with_notes(self):
        shutil.copy(FIX, self.path)
        items = transcript.read_page(self.path, None)["items"]
        it = items[-1]
        self.assertEqual(it["role"], "ask")
        self.assertIs(it["answered"], True)
        self.assertEqual(it["answers"], {QPV: "背景介绍当开篇"})
        self.assertEqual(it["notes"], {QPV: "背景部分放前面也行，但默认折叠起来，需要时再展开。"})
        self.assertFalse(transcript.menu_pending(items))
        self.assertNotIn("selected preview", json.dumps(items, ensure_ascii=False))  # the preview text is not passed through

    # ---- various ways of answering: the card counts as answered and the answer is passed through unchanged ----
    def test_plain_single_no_preview_flag(self):
        qs = [{"question": "选哪个？", "header": "h", "multiSelect": False, "options": [opt("alice"), opt("bob")]}]
        self.write(ask_line(qs, "t1"), answer_line("t1", 'User has answered your questions: "选哪个？"="bob".',
                                                   {"questions": qs, "answers": {"选哪个？": "bob"}}))
        it = self.asks()[0]
        self.assertNotIn("preview", it["questions"][0])
        self.assertIs(it["answered"], True)
        self.assertEqual(it["answers"], {"选哪个？": "bob"})
        self.assertNotIn("notes", it)

    def test_multiselect_and_multi_question_and_other(self):
        qs = [{"question": "多选？", "header": "m", "multiSelect": True, "options": [opt("alice"), opt("bob"), opt("carol")]},
              {"question": "单选？", "header": "s", "multiSelect": False, "options": [opt("A"), opt("B")]}]
        ans = {"多选？": "alice, carol, 我自己写的", "单选？": "都不要，换个思路"}
        self.write(ask_line(qs, "t2"), answer_line("t2", "The user answered: ...", {"questions": qs, "answers": ans}))
        it = self.asks()[0]
        self.assertIs(it["answered"], True)
        self.assertEqual(it["answers"], ans)
        self.assertNotIn("preview", it["questions"][0])
        self.assertNotIn("notes", it)

    def test_preview_notes_only(self):
        """Preview question with only a note and no option: answers is "(notes only)" and the result text is =(no option selected) notes: ..."""
        qs = [{"question": "排版？", "header": "p", "multiSelect": False,
               "options": [opt("左", "L\n|"), opt("右", "R\n|")]}]
        self.write(ask_line(qs, "t3"), answer_line(
            "t3", 'The user answered: "排版？"=(no option selected) notes: 两个都不好.',
            {"questions": qs, "answers": {"排版？": "(notes only)"}, "annotations": {"排版？": {"notes": "两个都不好"}}}))
        it = self.asks()[0]
        self.assertIs(it["answered"], True)
        self.assertIs(it["questions"][0]["preview"], True)
        self.assertEqual(it["answers"], {"排版？": "(notes only)"})
        self.assertEqual(it["notes"], {"排版？": "两个都不好"})

    def test_preview_selected_without_notes(self):
        """Option with a preview selected and no note: annotations only has preview, no notes."""
        qs = [{"question": "排版？", "header": "p", "multiSelect": False, "options": [opt("左", "L"), opt("右", "R")]}]
        self.write(ask_line(qs, "t4"), answer_line(
            "t4", 'The user answered: "排版？"="右" selected preview:\nR.',
            {"questions": qs, "answers": {"排版？": "右"}, "annotations": {"排版？": {"preview": "R"}}}))
        it = self.asks()[0]
        self.assertEqual(it["answers"], {"排版？": "右"})
        self.assertNotIn("notes", it)

    def test_multiselect_with_preview_is_not_preview_mode(self):
        """Claude Code only uses the preview UI for single-choice questions (preview is ignored on multi-select), so preview is not set."""
        qs = [{"question": "多选？", "header": "m", "multiSelect": True, "options": [opt("alice", "x"), opt("bob", "y")]}]
        self.write(ask_line(qs, "t5"))
        self.assertNotIn("preview", self.asks()[0]["questions"][0])

    def test_older_page_ask_gets_notes_from_index(self):
        qs = [{"question": "排版？", "header": "p", "multiSelect": False, "options": [opt("左", "L"), opt("右", "R")]}]
        user = lambda i: {"type": "user", "message": {"role": "user", "content": "话 %d" % i},
                          "timestamp": "2026-10-24T06:10:00Z"}
        objs = [ask_line(qs, "t6")] + [user(i) for i in range(35)] + [answer_line(
            "t6", "x", {"questions": qs, "answers": {"排版？": "左"}, "annotations": {"排版？": {"notes": "再窄点"}}})] + \
            [user(i) for i in range(35)]
        self.write(*objs)
        r = transcript.read_page(self.path, None, limit=30)
        asks = []
        nxt = r["next"]
        while nxt and not asks:
            r = transcript.read_page(self.path, nxt, limit=30)
            asks = [i for i in r["items"] if i["role"] == "ask"]
            nxt = r["next"]
        self.assertEqual(asks[0]["answers"], {"排版？": "左"})
        self.assertEqual(asks[0]["notes"], {"排版？": "再窄点"})


if __name__ == "__main__":
    unittest.main()
