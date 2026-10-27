import json
import os
import tempfile
import unittest
from unittest import mock

from api import files, transcript


def u(text, ts="2026-10-19T01:00:00Z", **kw):
    d = {"type": "user", "message": {"role": "user", "content": text}, "timestamp": ts}
    d.update(kw)
    return d


def a(block, ts="2026-10-19T01:00:01Z", **kw):
    d = {"type": "assistant", "message": {"role": "assistant", "content": [block]},
         "timestamp": ts, "isSidechain": False}
    d.update(kw)
    return d


def text_block(t):
    return {"type": "text", "text": t}


def tool_block(name, inp, tid=None):
    b = {"type": "tool_use", "name": name, "input": inp}
    if tid:
        b["id"] = tid
    return b


def result_line(tid, answers=None, extra=None):
    """A tool_result line (compact JSON, same as Claude Code writes it)."""
    d = {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tid, "content": "SECRET"}]},
        "timestamp": "2026-10-19T01:00:05Z"}
    if answers is not None:
        d["toolUseResult"] = {"answers": answers, "secret": "SECRET2"}
    if extra:
        d["toolUseResult"] = dict(d.get("toolUseResult", {}), blob=extra)
    return json.dumps(d, ensure_ascii=False, separators=(",", ":"))


class TranscriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "s.jsonl")

    def write(self, objs, tail=b""):
        with open(self.path, "wb") as f:
            for o in objs:
                f.write(json.dumps(o, ensure_ascii=False).encode() + b"\n")
            f.write(tail)

    def test_converts_roles_and_hides_tool_output(self):
        self.write([
            u("你好"),
            u("meta", isMeta=True),
            {"type": "user", "message": {"role": "user", "content": [
                {"type": "tool_result", "content": "SECRET"}]}},
            a({"type": "thinking", "thinking": "SECRET"}),
            a(text_block("回答")),
            a(tool_block("Bash", {"command": "ls -la\nfoo"})),
            a(text_block("side"), isSidechain=True),
            {"type": "attachment", "message": {"role": "user", "content": "SECRET"}},
            {"type": "api-request-blob", "message": {"role": "assistant", "content": "SECRET"}},
        ])
        r = transcript.read_page(self.path, None)
        self.assertEqual([(i["role"], i["text"]) for i in r["items"]],
                         [("user", "你好"), ("assistant", "回答"), ("tool", "Bash ls -la")])
        self.assertEqual(r["items"][0]["ts"], "2026-10-19T01:00:00Z")
        self.assertNotIn("SECRET", json.dumps(r))
        self.assertIsNone(r["next"])

    def convert(self, obj):
        return transcript._convert(json.dumps(obj, ensure_ascii=False).encode())

    def test_drops_command_output_strings(self):
        for t in ("<bash-stdout>x</bash-stdout>", "  \n<bash-stderr>x", "<local-command-stdout>x",
                  "<local-command-stderr>x"):
            self.assertEqual(self.convert(u(t)), [], t)

    def test_peer_message_unwrapped(self):
        t = ('Another Claude session sent a message:\n<cross-session-message from="uds:/tmp/cc-socks/1.sock" '
             'from-name="Lab-config-demo" from-mode="prompting">\n帮我看下。第二句。\n</cross-session-message>\n\n解释段落')
        r = self.convert(u(t))
        self.assertEqual(r, [{"role": "peer", "from": "Lab-config-demo", "text": "帮我看下。第二句。",
                              "ts": "2026-10-19T01:00:00Z"}])
        r = self.convert(u("Another Claude session sent a message:\nhello"))
        self.assertEqual((r[0]["role"], r[0]["from"], r[0]["text"]), ("peer", "", "hello"))

    def test_agent_messages(self):
        r = self.convert(u('<agent-message from="a">做完了</agent-message>'))
        self.assertEqual((r[0]["role"], r[0]["text"]), ("agent", "做完了"))
        r = self.convert(u("<task-notification>\n<summary>后台任务完成</summary>\n</task-notification>"))
        self.assertEqual((r[0]["role"], r[0]["text"]), ("agent", "后台任务完成"))
        self.assertEqual(self.convert(u("普通话"))[0]["role"], "user")

    def launch_line(self, aid, desc, tid="toolu_x"):
        """Tool-result line for an async sub-agent launch: toolUseResult carries both agentId and description."""
        return {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tid, "content": "launched"}]},
            "toolUseResult": {"isAsync": True, "status": "async_launched", "agentId": aid, "description": desc},
            "timestamp": "2026-10-19T01:00:02Z"}

    def test_agent_name_from_launch(self):
        """A sub-agent report is matched to its launch description by id; the wrapper text is stripped and the body de-indented; unmatched gives an empty string; internal fields are not exposed."""
        hb = ('Another Claude session sent a message:\n<agent-message from="a111">\n[Subagent hand-back] '
              'The text below is the final report. The report follows:\n  第一行\n  - 第二行\n</agent-message>')
        self.write([
            a(tool_block("Agent", {"description": "核对示例清单", "prompt": "x"}, "toolu_x")),
            self.launch_line("a111", "核对示例清单"),
            u("中间的话"),
            u(hb, isMeta=True),
            u('Another Claude session sent a message:\n<agent-message from="a999">没派过的</agent-message>',
              isMeta=True),
            u("<task-notification>\n<task-id>a111</task-id>\n<output-file>/private/tmp/x.output</output-file>\n"
              "<summary>Agent \"核对示例清单\" finished</summary>\n<note>long note</note>\n</task-notification>"),
            u("<task-notification>\n<task-id>a777</task-id>\n<summary>Agent \"别的任务\" finished</summary>\n"
              "</task-notification>"),
        ])
        r = transcript.read_page(self.path, None)
        ag = [i for i in r["items"] if i["role"] == "agent"]
        self.assertEqual([(i["agentName"], i["text"]) for i in ag], [
            ("核对示例清单", "第一行\n- 第二行"),
            ("", "没派过的"),
            ("核对示例清单", 'Agent "核对示例清单" finished'),
            ("别的任务", 'Agent "别的任务" finished'),  # no launch record: use the task name carried by the notification
        ])
        self.assertNotIn("_aid", json.dumps(r))
        self.assertNotIn("/private/tmp", json.dumps(r))

    def test_agent_name_across_pages_and_growth(self):
        """Launch on an earlier page and report later still match; after the file is appended, the incremental scan picks up newly launched sub-agents."""
        objs = [a(tool_block("Agent", {"description": "alice"}, "t1")), self.launch_line("a1", "alice", "t1")]
        objs += [u("话 %d" % i) for i in range(40)]
        objs.append(u('<agent-message from="a1">alice done</agent-message>', isMeta=True))
        self.write(objs)
        r = transcript.read_page(self.path, None, limit=5)
        self.assertEqual([i["agentName"] for i in r["items"] if i["role"] == "agent"], ["alice"])
        with open(self.path, "ab") as f:
            for o in (self.launch_line("a2", "bob", "t2"), u('<agent-message from="a2">bob done</agent-message>')):
                f.write(json.dumps(o, ensure_ascii=False).encode() + b"\n")
        r = transcript.read_page(self.path, None, limit=5)
        self.assertEqual([i["agentName"] for i in r["items"] if i["role"] == "agent"], ["alice", "bob"])
        # file replaced by a shorter one: rescan from scratch, old ids are no longer recognised
        self.write([u('<agent-message from="a1">alice again</agent-message>')])
        r = transcript.read_page(self.path, None)
        self.assertEqual(r["items"][0]["agentName"], "")

    def test_slash_command_collapsed(self):
        t = ("<command-message>foo</command-message>\n<command-name>/foo</command-name>\n"
             "<command-args>bar baz</command-args>")
        self.assertEqual([i["text"] for i in self.convert(u(t))], ["/foo bar baz"])
        t = "<command-name>clear</command-name><command-args></command-args>"
        self.assertEqual([i["text"] for i in self.convert(u(t))], ["/clear"])
        t = "<command-name>/foo</command-name><command-args>%s</command-args>" % ("x" * 81)
        self.assertEqual([i["text"] for i in self.convert(u(t))], ["/foo"])

    def test_compact_summary_replaced(self):
        r = self.convert(u("很长的摘要 SECRET", isCompactSummary=True))
        self.assertEqual(r, [{"role": "notice", "code": "compacted", "ts": r[0]["ts"]}])  # only the code, no localized text

    def test_api_error_message_becomes_notice(self):
        """Synthetic errors CC writes into the transcript (isApiErrorMessage) are not assistant bubbles; they become a centered system line {role:notice, code:apiError}."""
        def err(text, error=None, **kw):
            o = {"type": "assistant", "isApiErrorMessage": True, "timestamp": "2026-10-19T01:00:00Z", "isSidechain": False,
                 "message": {"role": "assistant", "model": "<synthetic>", "content": [{"type": "text", "text": text}]}}
            if error:
                o["error"] = error
            o.update(kw)
            return o
        r = self.convert(err("You've hit your limit \u00b7 resets 1pm", "rate_limit"))
        self.assertEqual(r, [{"role": "notice", "code": "apiError", "kind": "rate_limit",
                              "text": "You've hit your limit \u00b7 resets 1pm", "ts": "2026-10-19T01:00:00Z"}])
        r = self.convert(err("API Error: 529 Overloaded"))
        self.assertEqual((r[0]["role"], r[0]["kind"], r[0]["text"]), ("notice", "api", "529 Overloaded"))  # the "API Error:" prefix is stripped
        r = self.convert(err("Failed to authenticate: OAuth session expired", "authentication_failed"))
        self.assertEqual((r[0]["role"], r[0]["kind"]), ("notice", "auth"))
        r = self.convert(err("You've hit your limit"))  # no error field: detect quota errors from the literal text
        self.assertEqual(r[0]["kind"], "rate_limit")
        a = {"type": "assistant", "timestamp": "2026-10-19T01:00:00Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "好"}]}}
        self.assertEqual(self.convert(a)[0]["role"], "assistant")

    def test_user_list_content(self):
        def lst(blocks):
            return {"type": "user", "message": {"role": "user", "content": blocks},
                    "timestamp": "2026-10-19T01:00:00Z"}
        r = self.convert(lst([text_block("看这个"), {"type": "image", "source": {}},
                              {"type": "tool_result", "content": "SECRET"},
                              text_block("<bash-stdout>SECRET</bash-stdout>"), text_block("还有")]))
        self.assertEqual([i["text"] for i in r], ["看这个\n还有"])  # images are attached via files; no "[image]" suffix is appended
        self.assertNotIn("SECRET", json.dumps(r))
        self.assertEqual(self.convert(lst([{"type": "tool_result", "content": "SECRET"}])), [])
        self.assertEqual(self.convert(lst([text_block("<task-notification>x")])), [])

    def test_ask_user_question_rendered(self):
        self.write([a(tool_block("AskUserQuestion", {"questions": [
            {"question": "选哪个？", "header": "h", "multiSelect": False,
             "options": [{"label": "alice", "description": "d"}, {"label": "bob", "description": "e"}]}]}))])
        it = transcript.read_page(self.path, None)["items"][0]
        self.assertEqual(it["role"], "ask")
        for s in ("选哪个？", "alice", "bob"):
            self.assertIn(s, it["text"])

    def test_tool_summary_truncated_to_80(self):
        self.write([a(tool_block("Bash", {"command": "x" * 500})),
                    a(tool_block("Read", {"file_path": "/a/b/c.txt"})),
                    a(tool_block("Grep", {"pattern": "p"}))])
        items = transcript.read_page(self.path, None)["items"]
        self.assertEqual(len(items[0]["text"]), 80)
        self.assertEqual(items[1]["text"], "Read c.txt")
        self.assertEqual(items[2]["text"], "Grep")

    def test_skips_partial_last_line(self):
        self.write([u("a"), u("b")], tail=b'{"type":"assist')
        items = transcript.read_page(self.path, None)["items"]
        self.assertEqual([i["text"] for i in items], ["a", "b"])

    def test_pagination_next_cursor(self):
        objs = [u("m%02d" % i) if i % 2 else a(text_block("m%02d" % i)) for i in range(70)]
        objs.insert(5, a(tool_block("Bash", {"command": "ls"})))
        self.write(objs)
        pages, before = [], None
        while True:
            r = transcript.read_page(self.path, before, limit=30)
            pages.append(r)
            before = r["next"]
            if before is None:
                break
        counts = [sum(1 for i in p["items"] if i["role"] != "tool") for p in pages]
        self.assertEqual(counts, [30, 30, 10])
        texts = [i["text"] for p in reversed(pages) for i in p["items"] if i["role"] != "tool"]
        self.assertEqual(texts, ["m%02d" % i for i in range(70)])

    def _paginate(self, limit):
        pages, before = [], None
        while True:
            r = transcript.read_page(self.path, before, limit=limit)
            pages.append(r)
            before = r["next"]
            if before is None:
                return pages

    def test_pagination_across_small_chunks(self):
        objs = []
        for i in range(60):
            t = "第%02d条" % i + "é汉" * (i % 7)
            objs.append(u(t) if i % 2 else a(text_block(t)))
        objs.insert(10, a(tool_block("Bash", {"command": "ls"})))
        objs.insert(20, {"type": "api-request-blob", "blob": "y" * 1000})  # a skipped line longer than several blocks
        objs.insert(30, a(text_block("长" * 700)))  # a conversation line longer than one block
        objs.insert(40, {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "content": "SECRET" * 300}]}})
        expected = []
        for o in objs:
            c = o.get("message", {}).get("content")
            if o["type"] == "user" and isinstance(c, str):
                expected.append(c)
            elif o["type"] == "assistant" and c[0]["type"] == "text":
                expected.append(c[0]["text"])
        self.write(objs, tail=b'{"type":"assist')
        for chunk in (7, 200, 1000):
            with mock.patch.object(transcript, "CHUNK", chunk):
                for limit in (1, 7, 30):
                    pages = self._paginate(limit)
                    got = [i["text"] for p in reversed(pages) for i in p["items"] if i["role"] != "tool"]
                    self.assertEqual(got, expected, (chunk, limit))
                    self.assertNotIn("SECRET", json.dumps(pages))

    def test_tail_reads_only_needed_bytes(self):
        with open(self.path, "wb") as f:
            junk = (b"x" * 1023 + b"\n") * 1024
            for _ in range(50):
                f.write(junk)
            for i in range(40):
                f.write(json.dumps(u("t%d" % i)).encode() + b"\n")
        total = [0]
        real_open = open

        class Counting:
            def __init__(self, f):
                self.f = f

            def read(self, n=-1):
                d = self.f.read(n)
                total[0] += len(d)
                return d

            def __getattr__(self, k):
                return getattr(self.f, k)

            def __enter__(self):
                return self

            def __exit__(self, *a):
                self.f.close()

        with mock.patch.object(transcript, "open", lambda *a, **k: Counting(real_open(*a, **k)),
                               create=True):
            r = transcript.read_page(self.path, None, limit=30)
        self.assertEqual(len(r["items"]), 30)
        self.assertLess(total[0], 2 * 1024 * 1024)


QS = [{"question": "选哪个？", "header": "h", "multiSelect": False,
       "options": [{"label": "alice", "description": "d"}, {"label": "bob", "description": "e"}]},
      {"question": "多选？", "header": "m", "multiSelect": True, "options": [{"label": "carol"}]}]


class BubbleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "s.jsonl")

    def write(self, *lines):
        with open(self.path, "wb") as f:
            for ln in lines:
                if not isinstance(ln, str):
                    ln = json.dumps(ln, ensure_ascii=False, separators=(",", ":"))
                f.write(ln.encode() + b"\n")

    def items(self, **kw):
        return transcript.read_page(self.path, None, **kw)["items"]

    def test_ask_fields_unanswered(self):
        self.write(a(tool_block("AskUserQuestion", {"questions": QS}, "toolu_A")))
        it = self.items()[0]
        self.assertEqual(it["toolUseId"], "toolu_A")
        self.assertEqual(it["questions"], [
            {"question": "选哪个？", "header": "h", "multiSelect": False, "options": ["alice", "bob"], "descs": ["d", "e"]},
            {"question": "多选？", "header": "m", "multiSelect": True, "options": ["carol"], "descs": [""]}])
        self.assertIs(it["answered"], False)
        self.assertIsNone(it["answers"])

    def test_ask_answered_with_answers(self):
        self.write(a(tool_block("AskUserQuestion", {"questions": QS}, "toolu_A")),
                   result_line("toolu_A", {"选哪个？": "alice"}))
        it = self.items()[0]
        self.assertIs(it["answered"], True)
        self.assertEqual(it["answers"], {"选哪个？": "alice"})
        self.assertNotIn("SECRET", json.dumps(self.items()))

    def test_ask_answered_without_answers(self):
        self.write(a(tool_block("AskUserQuestion", {"questions": QS}, "toolu_A")), result_line("toolu_A"))
        it = self.items()[0]
        self.assertIs(it["answered"], True)
        self.assertIsNone(it["answers"])

    def test_only_matching_id_counts(self):
        self.write(a(tool_block("AskUserQuestion", {"questions": QS}, "toolu_A")), result_line("toolu_B", {"x": "y"}))
        self.assertIs(self.items()[0]["answered"], False)

    def test_tool_pending_flag(self):
        self.write(a(tool_block("Bash", {"command": "ls"}, "toolu_1")),
                   a(tool_block("Bash", {"command": "pwd"}, "toolu_2")),
                   result_line("toolu_1"))
        its = self.items()
        self.assertEqual([(i["toolUseId"], i["pending"]) for i in its],
                         [("toolu_1", False), ("toolu_2", True)])
        self.assertEqual([i["name"] for i in its], ["Bash", "Bash"])

    def test_tool_item_has_name(self):
        self.write(a(tool_block("mcp__x__y", {}, "toolu_9")), a(tool_block("Edit", {"file_path": "/a"}, "toolu_8")))
        self.assertEqual([i["name"] for i in self.items()], ["mcp__x__y", "Edit"])

    def test_huge_result_line_not_parsed_but_id_found(self):
        self.write(a(tool_block("AskUserQuestion", {"questions": QS}, "toolu_A")),
                   result_line("toolu_A", {"选哪个？": "alice"}, extra="x" * (300 * 1024)))
        with mock.patch.object(transcript.json, "loads", wraps=transcript.json.loads) as m:
            its = self.items()
        self.assertIs(its[0]["answered"], True)
        self.assertIsNone(its[0]["answers"])
        self.assertTrue(all(len(c.args[0]) < 256 * 1024 for c in m.call_args_list))

    def test_older_pages_default_answered(self):
        objs = [a(tool_block("AskUserQuestion", {"questions": QS}, "toolu_A")),
                a(tool_block("Bash", {"command": "ls"}, "toolu_1"))]
        objs += [u("m%02d" % i) for i in range(40)]
        self.write(*objs)
        r = transcript.read_page(self.path, None, limit=30)
        r2 = transcript.read_page(self.path, r["next"], limit=30)
        old = {i["role"]: i for i in r2["items"] if i["role"] in ("ask", "tool")}
        self.assertIs(old["ask"]["answered"], True)
        self.assertIsNone(old["ask"]["answers"])
        self.assertIs(old["tool"]["pending"], False)

    def err_line(self, tid, size=0):
        d = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tid, "content": "Error: Exit code 1" + "x" * size, "is_error": True}]},
            "timestamp": "2026-10-19T01:00:05Z"}
        return json.dumps(d, ensure_ascii=False, separators=(",", ":"))

    def test_tool_error_and_background_marks(self):
        """A result with is_error gives isError; async sub-agent / background command gives bg; large lines only honour a literal is_error; normal ones get no extra field."""
        bg_cmd = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t4", "content": "started"}]},
            "toolUseResult": {"stdout": "", "backgroundTaskId": "bx1"}, "timestamp": "2026-10-19T01:00:05Z"}
        launch = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t5", "content": "launched"}]},
            "toolUseResult": {"isAsync": True, "status": "async_launched", "agentId": "a5", "description": "查"},
            "timestamp": "2026-10-19T01:00:05Z"}
        self.write(a(tool_block("Bash", {"command": "ok"}, "t1")), result_line("t1"),
                   a(tool_block("Bash", {"command": "bad"}, "t2")), self.err_line("t2"),
                   a(tool_block("Bash", {"command": "big"}, "t3")), self.err_line("t3", 300 * 1024),
                   a(tool_block("Bash", {"command": "bg"}, "t4")), bg_cmd,
                   a(tool_block("Agent", {"description": "查"}, "t5")), launch)
        its = {i["toolUseId"]: i for i in self.items()}
        self.assertNotIn("isError", its["t1"])
        self.assertNotIn("bg", its["t1"])
        self.assertIs(its["t2"]["isError"], True)
        self.assertIs(its["t3"]["isError"], True)
        self.assertIs(its["t4"]["bg"], True)
        self.assertIs(its["t5"]["bg"], True)

    def test_marks_on_older_pages(self):
        """The error flag is scanned on every page (tool and result on the second page are on the same page)."""
        objs = [a(tool_block("Bash", {"command": "bad"}, "t2")), self.err_line("t2")]
        objs += [u("m%02d" % i) for i in range(40)]
        self.write(*objs)
        r = transcript.read_page(self.path, None, limit=30)
        r2 = transcript.read_page(self.path, r["next"], limit=30)
        tool = [i for i in r2["items"] if i["role"] == "tool"][0]
        self.assertIs(tool["isError"], True)
        self.assertIs(tool["pending"], False)

    def test_notice_and_handback_link_to_tool(self):
        """Task notifications carry notice/forTool/task; sub-agent reports are matched to forTool via the launch result line; unmatched gives an empty string."""
        launch = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t5", "content": "launched"}]},
            "toolUseResult": {"isAsync": True, "status": "async_launched", "agentId": "a5", "description": "查账"},
            "timestamp": "2026-10-19T01:00:05Z"}
        self.write(a(tool_block("Agent", {"description": "查账"}, "t5")), launch,
                   u('Another Claude session sent a message:\n<agent-message from="a5">\n[Subagent hand-back] x. '
                     'The report follows:\n  查完了\n</agent-message>', isMeta=True),
                   u('<agent-message from="a9">别的</agent-message>', isMeta=True),
                   u("<task-notification>\n<task-id>a5</task-id>\n<tool-use-id>t5</tool-use-id>\n"
                     "<status>failed</status>\n<summary>Agent \"查账\" finished</summary>\n</task-notification>"))
        ag = [i for i in self.items() if i["role"] == "agent"]
        self.assertEqual([(i["text"], i.get("forTool"), i.get("notice"), i.get("task")) for i in ag], [
            ("查完了", "t5", None, None),
            ("别的", "", None, None),
            ('Agent "查账" finished', "t5", True, "failed"),
        ])

    def test_first_page_without_tool_ignores_later_results(self):
        objs = [a(tool_block("Bash", {"command": "ls"}, "toolu_1"))]
        objs += [u("m%02d" % i) for i in range(40)]
        self.write(*objs)
        r = transcript.read_page(self.path, None, limit=30)
        self.assertFalse([i for i in r["items"] if i["role"] == "tool"])


class IndexTest(unittest.TestCase):
    """The cross-page small index is built by streaming line by line, with bounded memory and capped tables; task notifications inside queue records are recognised too."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "s.jsonl")
        transcript._index.clear()

    def write(self, *lines, mode="wb"):
        with open(self.path, mode) as f:
            for ln in lines:
                if not isinstance(ln, (str, bytes)):
                    ln = json.dumps(ln, ensure_ascii=False, separators=(",", ":"))
                f.write((ln if isinstance(ln, bytes) else ln.encode()) + b"\n")

    @staticmethod
    def bg_result(tid, task):
        return {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tid, "content": "Command running in background", "is_error": False}]},
            "toolUseResult": {"stdout": "", "backgroundTaskId": task}, "timestamp": "2026-10-20T23:50:00Z"}

    @staticmethod
    def queued(task, tid, status, op="enqueue"):
        """A task notification arriving while the session is busy is recorded only as a queue record (queue-operation), not as a user message."""
        body = "<task-notification>\n<task-id>%s</task-id>\n" % task
        if tid:
            body += "<tool-use-id>%s</tool-use-id>\n" % tid
        body += "<status>%s</status>\n<summary>Background command \"x\" %s</summary>\n</task-notification>" % (status, status)
        return {"type": "queue-operation", "operation": op, "timestamp": "2026-10-20T23:50:46Z", "content": body}

    def test_big_file_bounded_memory(self):
        """A 20MB transcript (including a 2MB oversized line): index scan plus two page reads keep peak memory far below the file size."""
        filler = json.dumps(u("x" * 4000), separators=(",", ":")).encode()
        huge = json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "tbig", "content": "y" * (2 * 1024 * 1024), "is_error": True}]}},
            separators=(",", ":")).encode()
        with open(self.path, "wb") as f:
            f.write(json.dumps(a(tool_block("Bash", {"command": "big"}, "tbig")), separators=(",", ":")).encode() + b"\n")
            f.write(huge + b"\n")
            for _ in range(4500):
                f.write(filler + b"\n")
        self.assertGreater(os.path.getsize(self.path), 18 * 1024 * 1024)
        import tracemalloc
        tracemalloc.start()
        try:
            r = transcript.read_page(self.path, None)
            transcript.read_page(self.path, r["next"])
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertLess(peak, 8 * 1024 * 1024)
        self.assertEqual(transcript._index[self.path]["marks"]["tbig"], {"err": True, "bg": False})
        self.assertEqual(transcript._index[self.path]["pos"], os.path.getsize(self.path))

    def test_index_tables_capped(self):
        lines = []
        for i in range(transcript.INDEX_CAP + 50):
            lines.append(self.bg_result("t%d" % i, "b%d" % i))
        self.write(*lines)
        ent = transcript.file_index(self.path)
        for k in ("marks", "bgids"):
            self.assertEqual(len(ent[k]), transcript.INDEX_CAP)
        self.assertNotIn("t0", ent["marks"])  # the oldest is dropped first
        self.assertIn("t%d" % (transcript.INDEX_CAP + 49), ent["marks"])

    def test_index_files_capped(self):
        for i in range(transcript.INDEX_FILES + 3):
            p = os.path.join(self.tmp.name, "f%d.jsonl" % i)
            with open(p, "wb") as f:
                f.write(b"{}\n")
            transcript.file_index(p)
        self.assertEqual(len(transcript._index), transcript.INDEX_FILES)

    def test_half_line_waits(self):
        self.write(self.bg_result("t1", "b1"))
        with open(self.path, "ab") as f:
            f.write(b'{"type":"queue-operation","operation":"enq')  # a half line that is still being written
        ent = transcript.file_index(self.path)
        self.assertLess(ent["pos"], os.path.getsize(self.path))
        with open(self.path, "ab") as f:
            f.write(b'ueue"}\n')
        self.assertEqual(transcript.file_index(self.path)["pos"], os.path.getsize(self.path))

    def test_queued_notice_marks_tool_across_pages(self):
        """Real-world shape (reduced to a minimal sample): background Bash -> result "running in background" -> the notification appears only in queue records (absorbed_mid_turn);
        still matched when the tool is on the second page and the notification after the first; a notification with only a task-id is mapped back via backgroundTaskId; remove is not recorded twice."""
        objs = [a(tool_block("Bash", {"command": "serve", "run_in_background": True}, "tA")), self.bg_result("tA", "bA"),
                a(tool_block("Bash", {"command": "serve2", "run_in_background": True}, "tB")), self.bg_result("tB", "bB")]
        objs += [u("话 %d" % i) for i in range(40)]
        objs += [self.queued("bA", "tA", "failed"), self.queued("bA", "tA", "failed", op="remove"),
                 self.queued("bB", "", "completed")]
        self.write(*objs)
        r = transcript.read_page(self.path, None, limit=10)
        r2 = transcript.read_page(self.path, r["next"], limit=60)
        tools = {i["toolUseId"]: i for i in r2["items"] if i["role"] == "tool"}
        self.assertEqual((tools["tA"].get("bg"), tools["tA"].get("task")), (True, "failed"))
        self.assertEqual((tools["tB"].get("bg"), tools["tB"].get("task")), (True, "completed"))
        self.assertFalse([i for i in r["items"] if i["role"] == "agent"])  # the queue record itself does not appear in the conversation

    @staticmethod
    def task_stop(tid, task, task_type="local_bash", is_error=False):
        """The model stops a background task itself via TaskStop: no task-notification in the transcript, only the TaskStop tool result (toolUseResult with task_id, task_type, command)."""
        tur = {"message": "Successfully stopped task: %s (sleep 300)" % task, "task_id": task, "task_type": task_type,
               "command": "sleep 300"}
        return {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tid, "content": json.dumps(tur), "is_error": is_error}]},
            "toolUseResult": tur, "timestamp": "2026-10-20T23:55:00Z"}

    def test_task_stop_marks_bg_stopped(self):
        """A TaskStop result is mapped back to the tool that started it via backgroundTaskId (background command) or agentId (background sub-agent) -> stopped;
        a failed TaskStop does not count; unmatched ones are not recorded."""
        agent_res = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "tG", "content": "Async agent launched", "is_error": False}]},
            "toolUseResult": {"status": "async_launched", "agentId": "a1234567", "description": "查资料"}}
        self.write(a(tool_block("Bash", {"command": "sleep 300", "run_in_background": True}, "tA")), self.bg_result("tA", "bA"),
                   a(tool_block("Bash", {"command": "sleep 600", "run_in_background": True}, "tB")), self.bg_result("tB", "bB"),
                   a(tool_block("Agent", {"description": "查资料", "prompt": "x", "run_in_background": True}, "tG")), agent_res,
                   a(tool_block("TaskStop", {"task_id": "bA"}, "tS1")), self.task_stop("tS1", "bA"),
                   a(tool_block("TaskStop", {"task_id": "bB"}, "tS2")), self.task_stop("tS2", "bB", is_error=True),
                   a(tool_block("TaskStop", {"task_id": "a1234567"}, "tS3")), self.task_stop("tS3", "a1234567", "local_agent"),
                   a(tool_block("TaskStop", {"task_id": "zzz"}, "tS4")), self.task_stop("tS4", "zzz"))
        ent = transcript.file_index(self.path)
        self.assertEqual(ent["tasks"].get("tA"), "stopped")
        self.assertNotIn("tB", ent["tasks"])
        self.assertEqual(ent["tasks"].get("tG"), "stopped")
        self.assertNotIn("zzz", ent["tasks"])
        items = {i["toolUseId"]: i for i in transcript.read_page(self.path, None)["items"] if i.get("toolUseId")}
        self.assertEqual(items["tA"].get("task"), "stopped")

    def test_older_page_ask_gets_answers_from_index(self):
        """Question card on an old page: the answer on another page is filled in from the index; the answer table is capped."""
        ask = a(tool_block("AskUserQuestion", {"questions": QS}, "tq"))
        res = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "tq", "content": "ok"}]},
            "toolUseResult": {"answers": {"选哪个？": "alice"}}, "timestamp": "2026-10-20T23:50:00Z"}
        objs = [ask] + [u("话 %d" % i) for i in range(35)] + [res] + [u("后 %d" % i) for i in range(35)]
        self.write(*objs)
        r = transcript.read_page(self.path, None, limit=30)
        r2 = transcript.read_page(self.path, r["next"], limit=30)
        r3 = transcript.read_page(self.path, r2["next"], limit=30) if r2["next"] else r2
        asks = [i for i in r2["items"] + r3["items"] if i["role"] == "ask"]
        self.assertEqual(asks[0]["answers"], {"选哪个？": "alice"})
        self.assertIs(asks[0]["answered"], True)
        lines = [json.dumps(dict(res, toolUseResult={"answers": {"q": "a"}}, message={"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "q%d" % i, "content": "ok"}]}), separators=(",", ":"))
            for i in range(transcript.ANSWERS_CAP + 5)]
        self.write(*lines)
        transcript._index.clear()
        self.assertEqual(len(transcript.file_index(self.path)["answers"]), transcript.ANSWERS_CAP)

    def test_fake_notice_in_command_ignored(self):
        """Quoting notification text inside a command or reply does not make it a real notification."""
        self.write(a(tool_block("Bash", {"command": "<task-notification><tool-use-id>t1</tool-use-id><status>failed</status>"}, "t1")),
                   a(text_block("<task-notification>\n<tool-use-id>t1</tool-use-id>\n<status>killed</status>")))
        self.assertEqual(dict(transcript.file_index(self.path)["tasks"]), {})


# ---------- read receipts / queued messages / retraction (record formats observed in a test terminal) ----------
def q(op, content=None, ts="2026-10-22T06:52:29.456Z", reason=None):
    d = {"type": "queue-operation", "operation": op, "timestamp": ts, "sessionId": "s"}
    if content is not None:
        d["content"] = content
    if reason is not None:
        d["reason"] = reason
    return json.dumps(d, ensure_ascii=False, separators=(",", ":"))


def qc(prompt, ts="2026-10-22T06:52:29.400Z"):
    return json.dumps({"type": "attachment", "attachment": {"type": "queued_command", "prompt": prompt},
                       "timestamp": ts}, ensure_ascii=False, separators=(",", ":"))


def cj(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


class ReadReceiptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "r.jsonl")
        transcript._index.clear()

    def write(self, *lines):
        with open(self.path, "w", encoding="utf-8") as f:
            for ln in lines:
                f.write((ln if isinstance(ln, str) else cj(ln)) + "\n")
        transcript._index.clear()

    def users(self, r):
        return [(i["text"], i.get("read"), bool(i.get("recalled"))) for i in r["items"] if i["role"] == "user"]

    def test_formal_user_line_is_read(self):
        self.write(u("你好"), a(text_block("嗯")))
        self.assertEqual(self.users(transcript.read_page(self.path, None)), [("你好", True, False)])

    def test_absorbed_mid_turn_shows_and_is_read(self):
        """Absorbed mid-turn: only enqueue + queued_command attachment + remove(absorbed_mid_turn), no proper user line; it must still be shown."""
        self.write(u("跑命令"), a(tool_block("Bash", {"command": "sleep 40"}, "t1")),
                   q("enqueue", "吸收测试"), q("remove", "吸收测试", reason="absorbed_mid_turn"),
                   result_line("t1"), qc("吸收测试"), a(text_block("醒了")))
        r = transcript.read_page(self.path, None)
        self.assertEqual(self.users(r), [("跑命令", True, False), ("吸收测试", True, False)])
        roles = [i["role"] for i in r["items"]]
        self.assertLess(roles.index("tool"), [i.get("text") for i in r["items"]].index("吸收测试"))

    def test_only_enqueued_is_sent_not_read(self):
        self.write(u("跑命令"), a(tool_block("Bash", {"command": "sleep 40"}, "t1")), q("enqueue", "queued-alice"))
        it = [i for i in transcript.read_page(self.path, None)["items"] if i.get("text") == "queued-alice"][0]
        self.assertEqual((it["role"], it["read"], it.get("queued")), ("user", False, True))

    def test_dequeue_then_formal_line_no_duplicate(self):
        self.write(u("跑命令"), q("enqueue", "queued-carol"), q("dequeue"), u("[Request interrupted by user]"), u("queued-carol"))
        texts = [i["text"] for i in transcript.read_page(self.path, None)["items"] if i["role"] == "user"]
        self.assertEqual(texts.count("queued-carol"), 1)
        self.assertEqual(self.users(transcript.read_page(self.path, None))[-1], ("queued-carol", True, False))

    def test_dequeue_is_fifo_including_notifications(self):
        """dequeue without content: pops the earliest entry in FIFO order (possibly a task notification)."""
        self.write(u("跑"), q("enqueue", "<task-notification>\n<task-id>x</task-id>\n</task-notification>"),
                   q("enqueue", "queued-bob"), q("dequeue"))
        it = [i for i in transcript.read_page(self.path, None)["items"] if i.get("text") == "queued-bob"][0]
        self.assertIs(it["read"], False)

    def test_popall_is_recalled(self):
        """Pulling queued messages back into the input box: one popAll line per message (with the original text)."""
        self.write(u("跑"), q("enqueue", "queued-alice"), q("enqueue", "queued-bob"), q("popAll", "queued-alice"), q("popAll", "queued-bob"))
        self.assertEqual(self.users(transcript.read_page(self.path, None))[1:],
                         [("queued-alice", False, True), ("queued-bob", False, True)])

    def test_popall_then_reenqueued_hides_old_copy(self):
        """When one message is retracted the helper re-sends the rest to the queue: the old copy does not count as retracted and is not shown twice."""
        self.write(u("跑"), q("enqueue", "queued-alice"), q("enqueue", "queued-bob"), q("popAll", "queued-alice"), q("popAll", "queued-bob"),
                   q("enqueue", "queued-bob"))
        self.assertEqual(self.users(transcript.read_page(self.path, None))[1:],
                         [("queued-alice", False, True), ("queued-bob", False, False)])

    def test_popall_then_formal_line_hides_old_copy(self):
        self.write(u("跑"), q("enqueue", "queued-bob"), q("popAll", "queued-bob"), u("queued-bob"))
        self.assertEqual(self.users(transcript.read_page(self.path, None)), [("跑", True, False), ("queued-bob", True, False)])

    def test_queued_peer_and_notice_not_user(self):
        self.write(u("跑"), q("enqueue", "<task-notification>\n<task-id>x</task-id>\n<summary>s</summary>\n</task-notification>"),
                   q("enqueue", "<bash-stdout>x</bash-stdout>"))
        self.assertEqual(self.users(transcript.read_page(self.path, None)), [("跑", True, False)])

    def test_fate_on_older_page(self):
        """Queue record on an older page: its fate comes from the cross-page index."""
        self.write(u("跑"), q("enqueue", "老排队"), q("remove", "老排队", reason="absorbed_mid_turn"),
                   *[u("后 %d" % i) for i in range(40)])
        r = transcript.read_page(self.path, None, limit=30)
        r2 = transcript.read_page(self.path, r["next"], limit=30)
        it = [i for i in r2["items"] if i.get("text") == "老排队"][0]
        self.assertIs(it["read"], True)

    def test_long_enqueue_across_chunks(self):
        long = "长" * 300
        self.write(u("跑"), q("enqueue", long), q("remove", long, reason="absorbed_mid_turn"), u("后"))
        with mock.patch.object(transcript, "CHUNK", 97):
            r = transcript.read_page(self.path, None)
        self.assertIn((long, True, False), self.users(r))


NOTICE_IDLE = ('[Cross-session idle notice] "Web-mail-sync", which you asked to be notified about, is idle now. '
               "This is an automated notice from that session's harness \u2014 not a message from a person.")


class SystemNoticeTest(unittest.TestCase):
    """System notices the harness injects into the session are not user speech (via enqueue / queued_command / a proper user line)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "n.jsonl")
        transcript._index.clear()

    def users(self, *lines):
        with open(self.path, "w", encoding="utf-8") as f:
            for ln in lines:
                f.write((ln if isinstance(ln, str) else cj(ln)) + "\n")
        transcript._index.clear()
        return [i["text"] for i in transcript.read_page(self.path, None)["items"] if i["role"] == "user"]

    def test_classify(self):
        for t in (NOTICE_IDLE, "[Cross-session delivery notice] x", "[Cross-session foo] x", "<channel src=\"a\">x</channel>",
                  "[Artifact comment sent to Claude] x", "[SYSTEM NOTIFICATION] x", "hello. This is an automated notice from X",
                  "<system-reminder>x</system-reminder>", "<local-command-caveat>x</local-command-caveat>",
                  "<user-prompt-submit-hook>x</user-prompt-submit-hook>", "[Request interrupted by user]",
                  "[Request interrupted by user for tool use]"):
            self.assertEqual(transcript.classify_user_text(t)[0], "notice", t)
        self.assertEqual(transcript.classify_user_text("Another Claude session sent a message: hi")[0], "peer")
        self.assertEqual(transcript.classify_user_text("普通的话")[0], "user")

    def test_list_block_filter(self):
        """List-form content is filtered per block: system blocks are dropped, real user text in the same entry is kept; an entry with only system blocks is not shown."""
        self.assertEqual(transcript._user_text([{"type": "text", "text": "[Request interrupted by user]"},
                                                {"type": "text", "text": "用户真话"}]), "用户真话")
        self.assertEqual(transcript._user_text([{"type": "text", "text": "[Request interrupted by user for tool use]"}]), "")
        self.assertEqual(transcript._user_text([{"type": "text", "text": "  <system-reminder>x</system-reminder>"},
                                                {"type": "text", "text": "好"}]), "好")

    def test_interrupt_list_record_not_user(self):
        self.assertEqual(self.users(u("跑"), u([{"type": "text", "text": "[Request interrupted by user]"}])), ["跑"])

    def test_enqueue_route(self):
        self.assertEqual(self.users(u("跑"), q("enqueue", NOTICE_IDLE), q("remove", NOTICE_IDLE, reason="absorbed_mid_turn")), ["跑"])

    def test_queued_command_route(self):
        self.assertEqual(self.users(u("跑"), q("enqueue", NOTICE_IDLE), qc(NOTICE_IDLE), q("dequeue")), ["跑"])

    def test_formal_user_line_route(self):
        self.assertEqual(self.users(u("跑"), u(NOTICE_IDLE, isMeta=True), u(NOTICE_IDLE)), ["跑"])
        self.assertEqual(self.users(u("跑"), u([{"type": "text", "text": NOTICE_IDLE}])), ["跑"])


def a_multi(blocks, ts="2026-10-19T01:00:01Z", **kw):
    d = {"type": "assistant", "message": {"role": "assistant", "content": blocks},
         "timestamp": ts, "isSidechain": False}
    d.update(kw)
    return d


class FilesTest(unittest.TestCase):
    """Messages carry files: paths in assistant text, Bash open, user-embedded images / uploaded files."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "s.jsonl")

    def page_with_offsets(self, *recs, **kw):
        offsets, pos = [], 0
        with open(self.path, "wb") as f:
            for r in recs:
                offsets.append(pos)
                b = json.dumps(r, ensure_ascii=False).encode() + b"\n"
                f.write(b)
                pos += len(b)
        return transcript.read_page(self.path, None, limit=50, **kw)["items"], offsets

    def page(self, *recs, **kw):
        return self.page_with_offsets(*recs, **kw)[0]

    def test_assistant_text_paths(self):
        items = self.page(a({"type": "text", "text": "样张在 /tmp/soulgent/faces3.png，报告 ~/Desktop/r.pdf"}))
        self.assertEqual([(f["path"], f["kind"], f["src"]) for f in items[-1]["files"]],
                         [("/tmp/soulgent/faces3.png", "image", "text"), ("~/Desktop/r.pdf", "pdf", "text")])
        self.assertEqual(items[-1]["files"][0]["name"], "faces3.png")

    def test_code_and_log_paths_ignored(self):
        items = self.page(a({"type": "text", "text": "错在 /Users/demo/x/app.py:12，日志 /tmp/a.log，配置 /tmp/c.json"}))
        self.assertNotIn("files", items[-1])

    # Real Claude Code transcripts: an assistant record has a single content block, so text and tool_use are always on separate lines
    @staticmethod
    def bash_open(cmd, tid="t1", ts="2026-10-19T01:00:02Z"):
        return a(tool_block("Bash", {"command": cmd}, tid), ts=ts)

    def test_open_attaches_to_last_text_of_turn(self):
        items = self.page(u("给我看样张"),
                          a(text_block("我先打开给你看")),
                          self.bash_open('open "/tmp/soulgent/faces3.png"'),
                          a(text_block("已打开，选一张"), ts="2026-10-19T01:00:03Z"))
        roles = [i["role"] for i in items]
        self.assertEqual(roles, ["user", "assistant", "tool", "assistant"])
        self.assertNotIn("files", items[1])
        self.assertNotIn("files", items[2])
        self.assertEqual([(f["path"], f["src"]) for f in items[3]["files"]], [("/tmp/soulgent/faces3.png", "open")])
        self.assertFalse([k for it in items for k in it if k.startswith("_")])

    def test_open_after_last_text_still_goes_to_that_text(self):
        items = self.page(u("看"), a(text_block("马上打开")), self.bash_open("open /tmp/a.pdf"))
        self.assertEqual(items[1]["files"][0]["path"], "/tmp/a.pdf")
        self.assertNotIn("files", items[2])

    def test_open_without_text_lands_on_tool(self):
        items = self.page(u("看"), self.bash_open("open /tmp/a.pdf"))
        self.assertEqual(items[1]["role"], "tool")
        self.assertEqual(items[1]["files"][0]["path"], "/tmp/a.pdf")
        self.assertFalse([k for it in items for k in it if k.startswith("_")])

    def test_open_not_carried_across_user_boundary(self):
        items = self.page(u("先问一次"), self.bash_open("open /tmp/a.pdf"),
                          u("再问一次", ts="2026-10-19T01:00:04Z"),
                          a(text_block("再问一次的回复"), ts="2026-10-19T01:00:05Z"))
        self.assertEqual([i["role"] for i in items], ["user", "tool", "user", "assistant"])
        self.assertEqual(items[1]["files"][0]["path"], "/tmp/a.pdf")  # no text in this turn: stays on the tool item
        self.assertNotIn("files", items[3])  # does not leak into the next turn

    def test_open_merges_with_text_paths(self):
        items = self.page(u("看"), self.bash_open("open /tmp/a.png"),
                          a(text_block("图在 /tmp/a.png，另有 /tmp/b.pdf"), ts="2026-10-19T01:00:03Z"))
        self.assertEqual([(f["path"], f["src"]) for f in items[2]["files"]],
                         [("/tmp/a.png", "open"), ("/tmp/b.pdf", "text")])

    def test_open_multi_block_line_still_works(self):
        items = self.page(a_multi([{"type": "text", "text": "打开给你看"},
                                   {"type": "tool_use", "id": "t1", "name": "Bash",
                                    "input": {"command": 'open "/tmp/soulgent/faces3.png"'}}]))
        self.assertEqual(items[0]["files"][0]["src"], "open")
        self.assertNotIn("files", items[1])

    def test_cap_nine(self):
        text = " ".join("/tmp/p%d.png" % i for i in range(12))
        f = self.page(a({"type": "text", "text": text}))[-1]
        self.assertEqual(len(f["files"]), 9)
        self.assertEqual(f["more"], 3)

    def test_user_embedded_image_ref(self):
        rec = u([{"type": "text", "text": "看这个"}, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="}}])
        items, offsets = self.page_with_offsets(u("前一条"), rec)
        fp = files.line_fp(json.dumps(rec, ensure_ascii=False).encode())  # first 8 hex chars of the sha1 of the first 256 bytes of the line
        self.assertEqual(items[1]["files"], [{"ref": "%d:1:%s" % (offsets[1], fp), "n": 1, "name": "图片 1", "kind": "image", "src": "upload", "mime": "image/png"}])
        self.assertEqual(items[1]["text"], "看这个")  # no "[image]" suffix is appended
        self.assertNotIn("_img", items[1])

    def test_user_embedded_images_numbered(self):
        # n is the 1-based image count; name keeps the legacy form (old frontends display it as-is), new frontends build a localized label from n
        img = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="}}
        items, _ = self.page_with_offsets(u([img, img, {"type": "text", "text": "两张"}]))
        self.assertEqual([(f["n"], f["name"]) for f in items[0]["files"]], [(1, "图片 1"), (2, "图片 2")])

    def test_user_image_only_kept(self):
        rec = u([{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "AAAA"}}])
        items, offsets = self.page_with_offsets(rec)
        self.assertEqual(items[0]["text"], "")
        self.assertEqual(items[0]["files"][0]["mime"], "image/jpeg")

    def test_user_upload_file_path(self):
        items = self.page(u("请看我从手机发来的文件：/Users/demo/projects/soulgent/webapp/data/uploads/20261023-1.pdf"))
        self.assertEqual(items[0]["files"][0]["src"], "upload")

    def test_user_upload_file_path_any_prompt_language(self):
        """Uploaded attachments are recognised under all three prompt languages (and the legacy form), by upload-directory path rather than by the prompt text."""
        p = "/Users/demo/projects/soulgent/webapp/data/uploads/20261023-1.pdf"
        q = "/Users/demo/projects/soulgent/webapp/data/uploads/20261023-2.png"
        for text in ("请看我从手机发来的文件：%s；%s" % (p, q), "請看我從手機傳來的檔案：%s；%s" % (p, q),
                     "Please look at the files I sent from my phone: %s; %s" % (p, q),
                     "see (Attachments: %s; %s)" % (p, q), "[Guest] hi （附件：%s；%s）" % (p, q)):
            items = self.page(u(text))
            self.assertEqual([(f["path"], f["src"]) for f in items[0]["files"]], [(p, "upload"), (q, "upload")], text)

    def test_user_plain_path_not_attached(self):
        items = self.page(u("看下 /tmp/x.png"))
        self.assertNotIn("files", items[0])

    def test_missing_file_dropped_when_stat_given(self):
        items = self.page(a({"type": "text", "text": "/tmp/gone.png /tmp/here.png"}),
                          stat=lambda p: 10 if p.endswith("here.png") else None)
        self.assertEqual([f["path"] for f in items[-1]["files"]], ["/tmp/here.png"])
        self.assertEqual(items[-1]["files"][0]["size"], 10)

    def test_all_missing_removes_files_key(self):
        items = self.page(a({"type": "text", "text": "/tmp/gone.png"}), stat=lambda p: None)
        self.assertNotIn("files", items[-1])

    def test_oversize_dropped(self):
        items = self.page(a({"type": "text", "text": "/tmp/big.png"}), stat=lambda p: 31 * 2**20)
        self.assertNotIn("files", items[-1])

    def test_real_stat_uses_roots_and_cache(self):
        from api import files
        import shutil
        root = tempfile.mkdtemp(dir="/tmp", prefix="t2files")  # path detection only accepts prefixes such as /tmp
        self.addCleanup(shutil.rmtree, root, True)
        real = os.path.realpath(root)  # /private/tmp/...
        with open(os.path.join(root, "ok.png"), "wb") as f:
            f.write(b"x" * 7)
        roots = files.Roots.from_spec("/private" + root + "=" + real)  # host side is always /private/tmp (macOS view); container side is the real dir here
        transcript._stat_cache.clear()
        items = self.page(a({"type": "text", "text": "%s/ok.png %s/no.png" % (root, root)}), roots=roots)
        self.assertEqual([(f["name"], f["size"]) for f in items[-1]["files"]], [("ok.png", 7)])
        self.assertIn(root + "/ok.png", transcript._stat_cache)

    def _stat_root(self):
        import shutil
        root = tempfile.mkdtemp(dir="/tmp", prefix="t2files")
        self.addCleanup(shutil.rmtree, root, True)
        real = os.path.realpath(root)
        return root, files.Roots.from_spec("/private" + root + "=" + real)  # host /private/tmp/... (api maps /tmp that way), container = real dir on any OS

    def test_real_stat_gives_version_that_follows_mtime(self):
        root, roots = self._stat_root()
        fp = os.path.join(root, "v.png")
        with open(fp, "wb") as f:
            f.write(b"x" * 5)
        os.utime(fp, ns=(1_700_000_000_000_000_000, 1_700_000_000_000_000_000))
        transcript._stat_cache.clear()
        rec = a({"type": "text", "text": "%s/v.png" % root})
        v1 = self.page(rec, roots=roots)[-1]["files"][0]
        self.assertEqual(v1["v"], "1700000000000000000")
        os.utime(fp, ns=(1_700_000_000_123_000_000, 1_700_000_000_123_000_000))
        transcript._stat_cache.clear()
        v2 = self.page(rec, roots=roots)[-1]["files"][0]
        self.assertEqual(v2["v"], "1700000000123000000")
        self.assertNotEqual(v1["v"], v2["v"])

    def test_stat_lambda_int_has_no_version(self):
        f = self.page(a({"type": "text", "text": "/tmp/here.png"}), stat=lambda p: 3)[-1]["files"][0]
        self.assertEqual(f["size"], 3)
        self.assertNotIn("v", f)

    def test_stat_negative_cached_shorter(self):
        root, roots = self._stat_root()
        host = root + "/late.png"
        transcript._stat_cache.clear()
        t0 = 1000.0
        with mock.patch.object(transcript.time, "time", return_value=t0):
            self.assertIsNone(transcript._real_stat(roots, host))
        with open(host, "wb") as f:
            f.write(b"x" * 4)
        with mock.patch.object(transcript.time, "time", return_value=t0 + transcript.STAT_TTL_MISS - 1):
            self.assertIsNone(transcript._real_stat(roots, host))  # the negative result is still cached
        with mock.patch.object(transcript.time, "time", return_value=t0 + transcript.STAT_TTL_MISS + 1):
            got = transcript._real_stat(roots, host)
        self.assertEqual(got[0], 4)  # re-stat after 10 seconds: the file has appeared
        os.remove(host)
        with mock.patch.object(transcript.time, "time", return_value=t0 + transcript.STAT_TTL_MISS + 30):
            self.assertEqual(transcript._real_stat(roots, host)[0], 4)  # positive results stay cached for 60 seconds
        self.assertEqual(transcript.STAT_TTL, 60.0)
        self.assertEqual(transcript.STAT_TTL_MISS, 10.0)

    def test_convert_direct_leaves_no_crash(self):
        line = json.dumps(a_multi([{"type": "text", "text": "x /tmp/a.png"}])).encode()
        r = transcript._convert(line)
        self.assertEqual(r[0]["role"], "assistant")


if __name__ == "__main__":
    unittest.main()
