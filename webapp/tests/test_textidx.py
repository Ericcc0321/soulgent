"""The helper builds a small index of chat text (helper/textidx.py -> data/textidx/<sid>.jsonl + _state.json)."""
import json
import os
import tempfile
import time
import unittest
from unittest import mock

from helper import textidx

CUR = "4aaaaaaa-1111-4111-8111-111111111111"
P1 = "8bbbbbbb-2222-4222-8222-222222222222"
OFF = "6ddddddd-4444-4444-8444-444444444444"
GONE = "11111111-2222-3333-4444-555555555555"


def line(o):
    return json.dumps(o, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"


def u(text, ts="2026-10-19T01:00:00Z", **kw):
    d = {"type": "user", "message": {"role": "user", "content": text}, "timestamp": ts}
    d.update(kw)
    return d


def a(text, ts="2026-10-19T01:00:01Z", tool=None):
    content = [{"type": "text", "text": text}]
    if tool:
        content.append({"type": "tool_use", "id": tool, "name": "Bash", "input": {"command": "echo 关键词"}})
    return {"type": "assistant", "message": {"role": "assistant", "content": content}, "timestamp": ts}


def result(tid, out):
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tid, "content": out}]}, "timestamp": "2026-10-19T01:00:02Z"}


def write(path, objs, title=None, mode="wb"):
    with open(path, mode) as f:
        if title:
            f.write(line({"type": "custom-title", "customTitle": title, "sessionId": "x"}))
        for o in objs:
            f.write(line(o))


def rows(path):
    with open(path, "rb") as f:
        return [json.loads(x) for x in f.read().splitlines() if x.strip()]


def load_state(out):
    with open(os.path.join(out, "_state.json"), encoding="utf-8") as f:
        return json.load(f)


class HookTest(unittest.TestCase):
    def test_snapshot_main_starts_indexer(self):
        from helper import snapshot
        self.assertIn("textidx_dir", snapshot.DEFAULT_PATHS)
        self.assertTrue(snapshot.DEFAULT_PATHS["textidx_dir"].endswith(os.path.join("data", "textidx")))
        src = open(snapshot.__file__, encoding="utf-8").read()
        self.assertRegex(src, r"textidx\.TextIndexer\(")


class CleanTextTest(unittest.TestCase):
    def test_strips_markdown_and_caps(self):
        s = textidx.clean_text("## 标题\n\n**加粗** 和 `代码` 还有 [链接](http://x.y/z)\n```py\nprint(1)\n```\n- 列表项\n> 引用")
        self.assertNotIn("#", s)
        self.assertNotIn("*", s)
        self.assertNotIn("`", s)
        self.assertNotIn("http://x.y/z", s)
        self.assertIn("链接", s)
        self.assertIn("print(1)", s)
        self.assertIn("列表项", s)
        self.assertNotIn("\n", s)
        self.assertEqual(len(textidx.clean_text("字" * 1000)), textidx.MAX_TEXT)
        self.assertEqual(textidx.MAX_TEXT, 400)
        self.assertIn("snake_case_name", textidx.clean_text("snake_case_name"))


class IndexFileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, CUR + ".jsonl")
        self.out = os.path.join(self.tmp.name, "textidx")
        self.idx = os.path.join(self.out, CUR + ".jsonl")

    def test_roles_filter_seq_and_no_tool_or_notice(self):
        write(self.src, [
            u("你好 **模拟器**", ts="2026-10-19T01:00:00Z"),
            a("我看看", tool="t1"),
            result("t1", "工具输出 模拟器 不该进索引"),
            u('<cross-session-message from-name="Web-api-demo">别处 说</cross-session-message>', ts="2026-10-19T01:00:03Z"),
            u("<task-notification><task-id>x</task-id><summary>后台 模拟器 完成</summary></task-notification>"),
        ])
        ent, n = textidx.index_file(CUR, self.src, self.out, {}, 10 ** 9)
        got = rows(self.idx)
        self.assertEqual([r["role"] for r in got], ["user", "assistant", "peer"])
        self.assertEqual(got[0]["text"], "你好 模拟器")
        self.assertEqual(got[2]["from"], "Web-api-demo")
        self.assertEqual(got[0]["ts"], "2026-10-19T01:00:00Z")
        with open(self.src, "rb") as f:
            data = f.read()
        for r in got:  # seq is the byte offset of the line start in the source transcript (consistent with in-session search / around)
            self.assertTrue(r["seq"] == 0 or data[r["seq"] - 1:r["seq"]] == b"\n")
        self.assertEqual(ent["offset"], len(data))
        self.assertEqual(n, len(data))
        self.assertTrue(all("工具输出" not in r["text"] for r in got))

    def test_incremental_and_partial_line(self):
        write(self.src, [u("第一条")])
        ent, _ = textidx.index_file(CUR, self.src, self.out, {}, 10 ** 9)
        with open(self.src, "ab") as f:
            f.write(line(u("第二条")))
            f.write('{"type":"user","message":{"role":"user","content":"半行'.encode())  # a half-written line
        ent, _ = textidx.index_file(CUR, self.src, self.out, ent, 10 ** 9)
        self.assertEqual([r["text"] for r in rows(self.idx)], ["第一条", "第二条"])
        with open(self.src, "ab") as f:
            f.write('写完"},"timestamp":"2026-10-19T02:00:00Z"}\n'.encode())
        ent, _ = textidx.index_file(CUR, self.src, self.out, ent, 10 ** 9)
        self.assertEqual([r["text"] for r in rows(self.idx)], ["第一条", "第二条", "半行写完"])
        ent2, n = textidx.index_file(CUR, self.src, self.out, ent, 10 ** 9)
        self.assertEqual(n, 0)  # unchanged: not read

    def test_shrink_rebuilds(self):
        write(self.src, [u("旧一"), u("旧二"), u("旧三")])
        ent, _ = textidx.index_file(CUR, self.src, self.out, {}, 10 ** 9)
        write(self.src, [u("新")])
        ent, _ = textidx.index_file(CUR, self.src, self.out, ent, 10 ** 9)
        self.assertEqual([r["text"] for r in rows(self.idx)], ["新"])

    def test_max_read_resumes(self):
        write(self.src, [u("消息 %03d" % i) for i in range(100)])
        size = os.path.getsize(self.src)
        ent, n = textidx.index_file(CUR, self.src, self.out, {}, size // 4)
        self.assertLessEqual(n, size // 4)
        self.assertLess(ent["offset"], size)
        while ent["offset"] < size:
            ent, n = textidx.index_file(CUR, self.src, self.out, ent, size // 4)
            self.assertGreater(n, 0)
        self.assertEqual([r["text"] for r in rows(self.idx)], ["消息 %03d" % i for i in range(100)])

    def test_huge_lines_skipped(self):
        write(self.src, [u("前"), a("巨行 " + "x" * 5000), u("后")])
        with mock.patch.object(textidx, "LINE_CAP", 2000):
            textidx.index_file(CUR, self.src, self.out, {}, 10 ** 9)
        self.assertEqual([r["text"] for r in rows(self.idx)], ["前", "后"])

    def test_index_cap_keeps_tail(self):
        write(self.src, [u("消息 %04d " % i + "填" * 100) for i in range(400)])
        with mock.patch.object(textidx, "IDX_MAX", 20000), mock.patch.object(textidx, "IDX_KEEP", 15000):
            textidx.index_file(CUR, self.src, self.out, {}, 10 ** 9)
            size = os.path.getsize(self.idx)
        self.assertLessEqual(size, 20000)
        got = rows(self.idx)  # every line is complete JSON
        self.assertTrue(got[-1]["text"].startswith("消息 0399"))
        self.assertFalse(any(r["text"].startswith("消息 0000") for r in got))


class IndexerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.projects = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(self.projects, "p"))
        write(os.path.join(self.projects, "p", CUR + ".jsonl"), [u("本窗 模拟器")], "Web-api-demo")
        write(os.path.join(self.projects, "p", P1 + ".jsonl"), [u("前窗 模拟器")], "Web-api-demo")
        write(os.path.join(self.projects, "p", OFF + ".jsonl"), [u("下班的 模拟器")], "Lab-X")
        self.lineage = os.path.join(self.tmp.name, "window-lineage.jsonl")
        with open(self.lineage, "w") as f:
            f.write(json.dumps({"name": "Web-api-demo", "prev_session_id": P1, "new_session_id": CUR,
                                "at": "2026-10-21T18:54:59+08:00", "via": "window"}) + "\n")
        self.snap = os.path.join(self.tmp.name, "snapshot.json")
        self.out = os.path.join(self.tmp.name, "data", "textidx")
        self.write_snap([{"id": CUR, "name": "Web-api-demo", "kind": "claude", "transcript": "p/" + CUR + ".jsonl"},
                         {"id": "term-1", "name": "终端", "kind": "terminal"}],
                        [{"sid": OFF, "name": "Lab-X", "transcript": "p/" + OFF + ".jsonl"}])
        from api import history
        history._cache_clear()

    def write_snap(self, sessions, offduty):
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": time.time(), "sessions": sessions, "offduty": offduty}, f)

    def mk(self, **kw):
        return textidx.TextIndexer(self.snap, self.projects, self.lineage, self.out, **kw)

    def test_indexes_live_offduty_and_prev_windows_with_owners(self):
        ix = self.mk()
        ix.tick()
        for sid in (CUR, P1, OFF):
            self.assertTrue(os.path.isfile(os.path.join(self.out, sid + ".jsonl")), sid)
        st = load_state(self.out)
        self.assertEqual(st["owners"][P1], CUR)
        self.assertEqual(st["owners"][CUR], CUR)
        self.assertEqual(st["owners"][OFF], OFF)
        self.assertIn("offset", st["files"][CUR])
        self.assertEqual(rows(os.path.join(self.out, P1 + ".jsonl"))[0]["text"], "前窗 模拟器")

    def test_round_budget_and_state_resume(self):
        big = os.path.join(self.projects, "p", CUR + ".jsonl")
        write(big, [u("消息 %03d " % i + "填" * 50) for i in range(300)], "Web-api-demo")
        size = os.path.getsize(big)
        ix = self.mk(budget=size // 3, per_file=size // 3)
        ix.tick()
        st = load_state(self.out)
        self.assertLess(st["files"][CUR]["offset"], size)
        ix2 = self.mk(budget=size // 3, per_file=size // 3)  # after a restart, resume from _state.json
        for _ in range(5):
            ix2.tick()
        st = load_state(self.out)
        self.assertEqual(st["files"][CUR]["offset"], size)
        self.assertEqual(len(rows(os.path.join(self.out, CUR + ".jsonl"))), 300)

    def test_per_file_cap_lets_small_sessions_go_first(self):
        big = os.path.join(self.projects, "p", CUR + ".jsonl")
        write(big, [u("消息 %03d " % i + "填" * 50) for i in range(300)], "Web-api-demo")
        ix = self.mk(budget=10 ** 9, per_file=2000)
        ix.tick()
        self.assertTrue(os.path.isfile(os.path.join(self.out, OFF + ".jsonl")))

    def test_prunes_sessions_no_longer_listed(self):
        ix = self.mk()
        ix.tick()
        self.write_snap([{"id": CUR, "name": "Web-api-demo", "kind": "claude", "transcript": "p/" + CUR + ".jsonl"}], [])
        ix.tick()
        self.assertFalse(os.path.exists(os.path.join(self.out, OFF + ".jsonl")))
        self.assertTrue(os.path.exists(os.path.join(self.out, CUR + ".jsonl")))
        st = load_state(self.out)
        self.assertNotIn(OFF, st["files"])

    def test_bad_snapshot_does_nothing(self):
        ix = self.mk()
        ix.tick()
        with open(self.snap, "w") as f:
            f.write("{坏")
        ix.tick()
        self.assertTrue(os.path.exists(os.path.join(self.out, OFF + ".jsonl")))

    def test_rejects_paths_outside_projects(self):
        self.write_snap([{"id": CUR, "name": "Web-api-demo", "kind": "claude", "transcript": "../../etc/passwd"},
                         {"id": GONE, "name": "坏", "kind": "claude", "transcript": "p/不存在.jsonl"}], [])
        ix = self.mk()
        ix.tick()  # no exception, no file created
        self.assertFalse(os.path.exists(os.path.join(self.out, GONE + ".jsonl")))

    def test_files_readable_by_container(self):
        ix = self.mk()
        ix.tick()
        mode = os.stat(os.path.join(self.out, CUR + ".jsonl")).st_mode & 0o777
        self.assertEqual(mode & 0o044, 0o044)
        self.assertEqual(os.stat(self.out).st_mode & 0o055, 0o055)


class SplitTest(unittest.TestCase):
    """Messages longer than MAX_TEXT are indexed in segments of at most 400 characters (split at sentence ends / newlines); segments of one message share seq/ts and carry a part field."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = os.path.join(self.tmp.name, CUR + ".jsonl")
        self.out = os.path.join(self.tmp.name, "textidx")
        self.idx = os.path.join(self.out, CUR + ".jsonl")

    def test_split_text_breaks_at_sentence_or_newline(self):
        para = "这是一句话。" * 50  # 300 characters
        segs = textidx.split_text(para + "\n" + "第二段的内容，" * 40 + "\n## 尾巴 **加粗**")
        self.assertGreater(len(segs), 1)
        for s in segs:
            self.assertLessEqual(len(s), textidx.MAX_TEXT)
            self.assertNotIn("\n", s)
            self.assertNotIn("**", s)
            self.assertNotIn("#", s)
        self.assertTrue(segs[0].endswith("。"))  # split at a sentence end, never mid-sentence
        self.assertIn("尾巴 加粗", segs[-1])
        joined = "".join(segs).replace(" ", "")
        self.assertIn("第二段的内容", joined)

    def test_split_text_hard_cut_without_breaks(self):
        segs = textidx.split_text("字" * 1000)
        self.assertEqual([len(s) for s in segs], [400, 400, 200])

    def test_short_text_single_segment(self):
        self.assertEqual(textidx.split_text("短消息 **一句**"), ["短消息 一句"])
        self.assertEqual(textidx.split_text("  \n "), [])

    def test_long_message_written_as_parts_sharing_seq_ts(self):
        tail = "末尾独有的关键词XYZ"
        body = "前面很长的回复内容。" * 120 + tail  # far beyond 400 characters
        write(self.src, [u("短问题"), a(body, ts="2026-10-19T01:00:05Z")])
        textidx.index_file(CUR, self.src, self.out, {}, 10 ** 9)
        got = rows(self.idx)
        self.assertEqual(got[0]["text"], "短问题")
        self.assertNotIn("part", got[0])  # short messages carry no part, so the index does not grow
        parts = got[1:]
        self.assertGreater(len(parts), 2)
        self.assertEqual({r["seq"] for r in parts}, {parts[0]["seq"]})
        self.assertEqual({r["ts"] for r in parts}, {"2026-10-19T01:00:05Z"})
        self.assertEqual([r["part"] for r in parts], list(range(len(parts))))
        self.assertTrue(all(r["role"] == "assistant" for r in parts))
        self.assertTrue(all(len(r["text"]) <= textidx.MAX_TEXT for r in parts))
        self.assertIn(tail, parts[-1]["text"])  # the later segment is searchable too

    def test_parts_capped(self):
        write(self.src, [a("很长。" * 20000)])
        textidx.index_file(CUR, self.src, self.out, {}, 10 ** 9)
        self.assertEqual(len(rows(self.idx)), textidx.MAX_PARTS)

    def test_old_format_state_forces_rebuild(self):
        projects = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(projects, "p"))
        src = os.path.join(projects, "p", CUR + ".jsonl")
        write(src, [a("旧格式只截了前 400 字。" * 60 + "后半段关键词")], "Web-api-demo")
        snap = os.path.join(self.tmp.name, "snapshot.json")
        with open(snap, "w") as f:
            json.dump({"sessions": [{"id": CUR, "name": "Web-api-demo", "kind": "claude", "transcript": "p/" + CUR + ".jsonl"}]}, f)
        os.makedirs(self.out)
        st = os.stat(src)
        with open(self.idx, "w") as f:  # old index: one entry holding only the first 400 characters
            f.write(json.dumps({"seq": 0, "ts": "", "role": "assistant", "from": "", "text": "旧"}) + "\n")
        with open(os.path.join(self.out, "_state.json"), "w") as f:  # old state has no v field, offset already at the end
            json.dump({"files": {CUR: {"path": src, "ino": st.st_ino, "offset": st.st_size, "size": st.st_size}},
                       "owners": {CUR: CUR}, "pending": 0}, f)
        lineage = os.path.join(self.tmp.name, "lineage.jsonl")
        open(lineage, "w").close()
        ix = textidx.TextIndexer(snap, projects, lineage, self.out)
        ix.tick()
        got = rows(self.idx)
        self.assertTrue(any("后半段关键词" in r["text"] for r in got))
        self.assertEqual(load_state(self.out)["v"], textidx.FORMAT)
        ix2 = textidx.TextIndexer(snap, projects, lineage, self.out)  # no rebuild on restart with the new format
        self.assertIn(CUR, ix2.files)


if __name__ == "__main__":
    unittest.main()
