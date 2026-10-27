"""Sub-agents: Agent tool entries carry an agent field (meta matching, reading the last step from the tail, incremental tokens) plus the /api/session/<sid>/agent/<agentId> route."""
import hashlib
import hmac
import http.client
import json
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import server, transcript
from tests._guests import guests_for  # noqa: E402
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET so hand-written results can be signed

SID = "8bbbbbbb-2222-4222-8222-222222222222"
AID = "a2c933d5dcabd2c73"
TU = "toolu_01AgentAAA"
KEY = "admin-key-0123456789abcdef"
GUEST = "guest-key-0123456789abcdef"
ADMIN_COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GUEST_COOKIE = "zbs=" + hmac.new(GUEST.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


def line(o):
    return (json.dumps(o, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def main_lines(extra=()):
    out = [
        {"type": "user", "message": {"role": "user", "content": "派几个子代理"}, "timestamp": "2026-10-21T01:00:00Z"},
        {"type": "assistant", "timestamp": "2026-10-21T01:00:01Z", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "好，派一个去做。"},
            {"type": "tool_use", "id": TU, "name": "Agent", "input": {
                "description": "闪电加强样稿", "subagent_type": "general-purpose", "model": "sonnet",
                "prompt": "在现有闪电上加两级分叉和余辉。然后出 3 张样稿放 out/fx/。"}}]}},
    ]
    return out + list(extra)


def sub_user(ts="2026-10-21T01:00:02Z", text="在现有闪电上加两级分叉和余辉。然后出 3 张样稿。"):
    return {"parentUuid": None, "isSidechain": True, "agentId": AID, "type": "user",
            "message": {"role": "user", "content": text}, "timestamp": ts}


def sub_asst(blocks, ts="2026-10-21T01:00:10Z", mid="msg_1", inp=3, out=100):
    return {"parentUuid": "x", "isSidechain": True, "agentId": AID,
            "message": {"model": "claude-sonnet", "id": mid, "type": "message", "role": "assistant",
                        "content": blocks, "usage": {"input_tokens": inp, "cache_creation_input_tokens": 500,
                                                     "cache_read_input_tokens": 9000, "output_tokens": out}},
            "type": "assistant", "timestamp": ts}


def sub_stop(ts="2026-10-21T01:05:00Z"):
    return {"parentUuid": "y", "isSidechain": True, "agentId": AID, "type": "attachment",
            "attachment": {"type": "hook_success", "hookName": "SubagentStop", "hookEvent": "SubagentStop"},
            "timestamp": ts}


def notice(status, summary, ts="2026-10-21T01:06:00Z"):
    body = ("<task-notification><task-id>%s</task-id><tool-use-id>%s</tool-use-id><status>%s</status>"
            "<summary>%s</summary></task-notification>" % (AID, TU, status, summary))
    return {"type": "user", "isMeta": True, "message": {"role": "user", "content": body}, "timestamp": ts}


class AgentFieldTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, SID + ".jsonl")
        self.sub = os.path.join(self.tmp.name, SID, "subagents")
        os.makedirs(self.sub)
        self.ajsonl = os.path.join(self.sub, "agent-%s.jsonl" % AID)
        transcript._meta_cache.clear()
        transcript._agent_cache.clear()

    def write_main(self, extra=()):
        with open(self.path, "wb") as f:
            for o in main_lines(extra):
                f.write(line(o))

    def write_meta(self, finished=None, tu=TU, aid=AID):
        m = {"agentType": "general-purpose", "description": "闪电加强样稿", "toolUseId": tu,
             "spawnDepth": 1, "model": "sonnet"}
        if finished is not None:
            m["finished"] = finished
        with open(os.path.join(self.sub, "agent-%s.meta.json" % aid), "w") as f:
            json.dump(m, f)

    def write_sub(self, objs, mode="wb"):
        with open(self.ajsonl, mode) as f:
            for o in objs:
                f.write(line(o))

    def agent_item(self):
        items = transcript.read_page(self.path, None)["items"]
        tools = [it for it in items if it["role"] == "tool"]
        self.assertEqual(len(tools), 1)
        for it in items:
            self.assertNotIn("_agent", it)
        return tools[0]

    def test_running_agent_fields(self):
        self.write_main()
        self.write_meta()
        self.write_sub([sub_user(), sub_asst([{"type": "tool_use", "id": "t1", "name": "Bash",
                                                "input": {"description": "跑测试", "command": "x"}}])])
        ag = self.agent_item()["agent"]
        self.assertEqual(ag["id"], AID)
        self.assertEqual(ag["description"], "闪电加强样稿")
        self.assertEqual(ag["model"], "sonnet")
        self.assertEqual(ag["agentType"], "general-purpose")
        self.assertEqual(ag["task"], "在现有闪电上加两级分叉和余辉。")
        self.assertEqual(ag["state"], "running")
        self.assertEqual(ag["startedAt"], "2026-10-21T01:00:02Z")
        self.assertIsNone(ag["endedAt"])
        self.assertAlmostEqual(ag["lastAt"], os.path.getmtime(self.ajsonl), places=2)
        self.assertEqual(ag["lastStep"], "Bash 跑测试")
        self.assertEqual(ag["tokens"], 103)

    def test_finished_meta_done_with_end_time_and_text_step(self):
        self.write_main()
        self.write_meta(finished=True)
        long = "闪电加强版 3 张样稿已出，放在 out/fx/ 目录里，" * 5
        self.write_sub([sub_user(), sub_asst([{"type": "text", "text": long}]), sub_stop()])
        ag = self.agent_item()["agent"]
        self.assertEqual(ag["state"], "done")
        self.assertEqual(ag["endedAt"], "2026-10-21T01:05:00Z")
        self.assertEqual(ag["lastStep"], long[:60])

    def test_task_notification_failed_wins_and_its_text(self):
        self.write_main([notice("failed", "Agent \"闪电加强样稿\" failed: 表格缺列")])
        self.write_meta(finished=True)
        self.write_sub([sub_user(), sub_asst([{"type": "text", "text": "读表"}]), sub_stop()])
        ag = self.agent_item()["agent"]
        self.assertEqual(ag["state"], "failed")
        self.assertIn("表格缺列", ag["lastStep"])

    def test_completed_notification_beats_unfinished_meta(self):
        self.write_main([notice("completed", "Agent \"闪电加强样稿\" completed")])
        self.write_meta()
        self.write_sub([sub_user(), sub_asst([{"type": "text", "text": "好了"}])])
        self.assertEqual(self.agent_item()["agent"]["state"], "done")

    def test_stale_running_is_gone(self):
        self.write_main()
        self.write_meta()
        self.write_sub([sub_user(), sub_asst([{"type": "text", "text": "在干"}])])
        old = time.time() - 31 * 60
        os.utime(self.ajsonl, (old, old))
        self.assertEqual(self.agent_item()["agent"]["state"], "gone")

    def test_no_meta_no_agent_field(self):
        self.write_main()
        it = self.agent_item()
        self.assertNotIn("agent", it)

    def test_meta_for_other_tool_ignored(self):
        self.write_main()
        self.write_meta(tu="toolu_other")
        self.assertNotIn("agent", self.agent_item())

    def test_meta_listing_cached_10s(self):
        self.write_main()
        self.write_meta()
        self.write_sub([sub_user()])
        real = os.listdir
        calls = []

        def spy(p):
            calls.append(p)
            return real(p)
        with mock.patch.object(transcript.os, "listdir", spy):
            self.agent_item()
            self.agent_item()
        self.assertEqual(len([c for c in calls if c.endswith("subagents")]), 1)

    def test_no_listing_when_page_has_no_agent_call(self):
        with open(self.path, "wb") as f:
            f.write(line({"type": "user", "message": {"role": "user", "content": "hi"}, "timestamp": "2026-10-21T01:00:00Z"}))
        with mock.patch.object(transcript.os, "listdir", side_effect=AssertionError("listed")):
            transcript.read_page(self.path, None)

    def test_tail_skips_huge_trailing_lines(self):
        """The last step is read from the tail only: a huge tool result (user line) at the end does not prevent finding the preceding assistant."""
        self.write_main()
        self.write_meta()
        big = {"type": "user", "isSidechain": True, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "x" * 3000}]}, "timestamp": "2026-10-21T01:00:20Z"}
        self.write_sub([sub_user(), sub_asst([{"type": "tool_use", "id": "t1", "name": "Read",
                                                "input": {"file_path": "/a/b/ZoneFX.swift"}}]), big])
        self.assertEqual(self.agent_item()["agent"]["lastStep"], "Read ZoneFX.swift")

    def test_tokens_incremental_dedupe_and_rescan(self):
        self.write_sub([sub_user(), sub_asst([{"type": "text", "text": "a"}], mid="m1", inp=2, out=10),
                        sub_asst([{"type": "tool_use", "id": "t", "name": "Bash", "input": {}}], mid="m1", inp=2, out=30)])
        self.assertEqual(transcript.agent_tokens(self.ajsonl), 32)  # the same message split over several lines: only the last copy counts
        ent = transcript._agent_cache[self.ajsonl]
        off = ent["offset"]
        self.assertEqual(off, os.path.getsize(self.ajsonl))
        self.write_sub([sub_asst([{"type": "text", "text": "b"}], mid="m2", inp=1, out=7)], mode="ab")
        real_open = open
        seeks = []

        class F:
            def __init__(self, f):
                self.f = f

            def __enter__(self):
                return self

            def __exit__(self, *a):
                self.f.close()

            def seek(self, n, *a):
                seeks.append(n)
                return self.f.seek(n, *a)

            def __getattr__(self, k):
                return getattr(self.f, k)
        with mock.patch("builtins.open", lambda p, m="r", *a, **k: F(real_open(p, m, *a, **k))):
            self.assertEqual(transcript.agent_tokens(self.ajsonl), 40)
        self.assertIn(off, seeks)  # only the newly appended part is read
        self.write_sub([sub_asst([{"type": "text", "text": "c"}], mid="m9", inp=1, out=1)])  # file got shorter: rescan
        self.assertEqual(transcript.agent_tokens(self.ajsonl), 2)

    def test_tokens_from_huge_line_tail(self):
        blk = {"type": "tool_use", "id": "t", "name": "Write", "input": {"file_path": "a", "content": "z" * 400000}}
        self.write_sub([sub_user(), sub_asst([blk], mid="m1", inp=5, out=900)])
        self.assertEqual(transcript.agent_tokens(self.ajsonl), 905)

    def test_token_cache_bounded(self):
        for i in range(transcript.AGENT_CACHE + 20):
            p = os.path.join(self.sub, "agent-%08x.jsonl" % i)
            with open(p, "wb") as f:
                f.write(line(sub_asst([{"type": "text", "text": "a"}], mid="m", inp=1, out=1)))
            transcript.agent_tokens(p)
        self.assertLessEqual(len(transcript._agent_cache), transcript.AGENT_CACHE)

    def test_agent_page_reads_sidechain(self):
        self.write_main()
        self.write_meta()
        self.write_sub([sub_user(), sub_asst([{"type": "text", "text": "先读代码"}]),
                        sub_asst([{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"description": "跑测试"}}],
                                 mid="m2")])
        page = transcript.agent_page(self.path, AID, None)
        roles = [it["role"] for it in page["items"]]
        self.assertEqual(roles, ["user", "assistant", "tool"])
        self.assertEqual(page["agent"]["id"], AID)
        self.assertEqual(page["agent"]["description"], "闪电加强样稿")
        self.assertIsNone(transcript.agent_page(self.path, "deadbeef00", None))
        self.assertIsNone(transcript.agent_page(self.path, "../../etc", None))


class AgentRouteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        projects = os.path.join(self.tmp.name, "projects")
        sub = os.path.join(projects, "p", SID, "subagents")
        os.makedirs(sub)
        with open(os.path.join(projects, "p", SID + ".jsonl"), "wb") as f:
            for o in main_lines():
                f.write(line(o))
        with open(os.path.join(sub, "agent-%s.meta.json" % AID), "w") as f:
            json.dump({"description": "闪电加强样稿", "toolUseId": TU, "model": "sonnet", "agentType": "general-purpose"}, f)
        with open(os.path.join(sub, "agent-%s.jsonl" % AID), "wb") as f:
            f.write(line(sub_user()))
            f.write(line(sub_asst([{"type": "text", "text": "先读代码"}])))
        # same-named file outside the directory: path escape is not allowed
        with open(os.path.join(projects, "p", "agent-%s.jsonl" % "abcdef1234"), "wb") as f:
            f.write(line(sub_user()))
        self.snap = os.path.join(self.tmp.name, "snapshot.json")
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": time.time(), "usage": {}, "zones": [], "sessions": [
                {"id": SID, "name": "Web-guest-demo", "kind": "claude", "status": "idle", "since": 1,
                 "transcript": "p/" + SID + ".jsonl"}]}, f)
        transcript._meta_cache.clear()
        transcript._agent_cache.clear()
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap, projects=projects,
                                        state=os.path.join(self.tmp.name, "st", "state.json"),
                                        outbox_dir=os.path.join(self.tmp.name, "ob"), guests=guests_for(KEY, GUEST, "Web-guest-demo"))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def get(self, path, cookie=ADMIN_COOKIE):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", path, headers={"Cookie": cookie})
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def test_ok(self):
        r, d = self.get("/api/session/%s/agent/%s" % (SID, AID))
        self.assertEqual(r, 200)
        self.assertEqual([it["role"] for it in d["items"]], ["user", "assistant"])
        self.assertEqual(d["agent"]["id"], AID)
        self.assertIn("next", d)

    def test_before_paging(self):
        r, d = self.get("/api/session/%s/agent/%s?before=0" % (SID, AID))
        self.assertEqual(r, 200)
        self.assertEqual(d["items"], [])
        self.assertEqual(self.get("/api/session/%s/agent/%s?before=x" % (SID, AID))[0], 400)

    def test_bad_ids(self):
        self.assertEqual(self.get("/api/session/%s/agent/ZZZZ1234" % SID)[0], 400)
        self.assertEqual(self.get("/api/session/%s/agent/abc" % SID)[0], 400)
        self.assertEqual(self.get("/api/session/%s/agent/..%%2F..%%2Fx1234567" % SID)[0], 400)
        self.assertEqual(self.get("/api/session/not-a-uuid/agent/%s" % AID)[0], 400)
        self.assertEqual(self.get("/api/session/%s/agent/abcdef1234" % SID)[0], 404)  # only files under sid/subagents are accepted
        self.assertEqual(self.get("/api/session/11111111-2222-3333-4444-555555555555/agent/%s" % AID)[0], 404)

    def test_guest_bound_session_ok(self):
        """A guest can view the bound session's sub-agent records and context details; other sessions give 403 (not 400/404, so existence cannot be probed)."""
        r, d = self.get("/api/session/%s/agent/%s" % (SID, AID), cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)
        self.assertEqual(d["agent"]["id"], AID)
        self.assertEqual(self.get("/api/session/%s/agent/ZZZZ1234" % SID, cookie=GUEST_COOKIE)[0], 400)
        other = "11111111-2222-3333-4444-555555555555"
        for p in ("/api/session/%s/agent/%s" % (other, AID), "/api/session/not-a-uuid/agent/%s" % AID,
                  "/api/session/%s/context" % other, "/api/session/x/context"):
            self.assertEqual(self.get(p, cookie=GUEST_COOKIE)[0], 403, p)
        os.makedirs(os.path.join(self.tmp.name, "ob"), exist_ok=True)
        r, d = self.get("/api/session/%s/context" % SID, cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)
        self.assertEqual(d["status"], "pending")
        r, st = self.get("/api/requests/%s" % d["rid"], cookie=GUEST_COOKIE)
        self.assertEqual((r, st["status"]), (200, "pending"))
        # the details contain the admin's memory file paths, skills and MCP tool names: guests get only the category bars, no details
        ob = os.path.join(self.tmp.name, "ob")
        data = {"model": "m", "used": 1, "window": 2, "pct": 50.0, "categories": [{"name": "Messages", "tokens": 1}],
                "details": {"memory": [{"name": "/Users/x/.claude/CLAUDE.md"}]}}
        with open(os.path.join(ob, d["rid"] + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": d["rid"], "status": "done", "finishedAt": time.time(), "type": "context",
                       "sessionId": SID, "data": data}), f)
        os.unlink(os.path.join(ob, d["rid"] + ".req.json"))
        r, st = self.get("/api/requests/%s" % d["rid"], cookie=GUEST_COOKIE)
        self.assertEqual((r, st["status"]), (200, "done"))
        self.assertNotIn("details", st["data"])
        self.assertEqual(st["data"]["categories"], data["categories"])
        r, c = self.get("/api/session/%s/context" % SID, cookie=GUEST_COOKIE)
        self.assertEqual(c["status"], "done")
        self.assertNotIn("details", c["data"])
        r, c = self.get("/api/session/%s/context" % SID)  # the admin still gets details (the cache holds the full data)
        self.assertIn("details", c["data"])


SAMPLE_PROMPT = ("任务说明在 /Users/demo/projects/demo-app/docs/spec-example.md，你做「第二部分」。"
                 "先读计划开头的约定和 HANDOFF.md。")


class MarkdownStripTest(unittest.TestCase):
    """The back-of-card "latest step" and "one-line task" have Markdown stripped; the one-line task skips leading "project: / rules / read first" sentences and too-short sentences."""

    def test_strip_md(self):
        f = transcript.strip_md
        self.assertEqual(f("**改完了** `api/x.py`，见 [说明](http://a.b/c)"), "改完了 api/x.py，见 说明")
        self.assertEqual(f("## 标题\n> 引用一句"), "标题 引用一句")
        self.assertEqual(f("- 一项 **粗**"), "一项 粗")
        self.assertEqual(f("普通文字 a*b"), "普通文字 a*b")

    def test_task_skips_boilerplate(self):
        f = transcript.first_sentence
        self.assertTrue(f(SAMPLE_PROMPT).startswith("任务说明在 /Users/"))
        self.assertEqual(f("项目：示例应用。规矩：别动配置。先读 HANDOFF。把闪电样稿加两级分叉和余辉。"), "把闪电样稿加两级分叉和余辉。")
        self.assertEqual(f("短。**把全局搜索长消息分段入索引**。"), "把全局搜索长消息分段入索引。")
        self.assertEqual(f("项目：天地玄黄宇宙洪荒。先读 HANDOFF。"), "项目：天地玄黄宇宙洪荒。")  # no qualifying sentence: fall back to the original first sentence
        self.assertEqual(f("Working directory: /x/y (cd there). Read and follow the brief."), "Working directory: /x/y (cd there).")
        self.assertEqual(f(""), "")

    def test_step_text_stripped(self):
        import tempfile as tf
        with tf.TemporaryDirectory() as d:
            p = os.path.join(d, "agent-x.jsonl")
            body = "**已完成** `foo.py` 的修改，[详情](http://x.y/z)"
            with open(p, "wb") as fh:
                fh.write(line({"type": "assistant", "timestamp": "2026-10-21T01:03:00Z",
                               "message": {"role": "assistant", "content": [{"type": "text", "text": body}]}}))
            out = transcript._agent_tail(p, os.path.getsize(p))
            self.assertEqual(out["lastStep"], "已完成 foo.py 的修改，详情")


if __name__ == "__main__":
    unittest.main()
