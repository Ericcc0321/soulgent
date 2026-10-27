import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET; signs hand-written requests/results

from helper import outbox

SID = "8bbbbbbb-2222-4222-8222-222222222222"
SID2 = "11111111-2222-3333-4444-555555555555"

MD = """## Context Usage

**Model:** claude-fable-5-1  
**Tokens:** 191.2k / 1m (19%)

### Estimated usage by category

| Category | Tokens | Percentage |
|----------|--------|------------|
| System prompt | 6k | 0.6% |
| System tools | 3.5k | 0.3% |
| MCP tools | 647 | 0.1% |
| Custom agents | 85 | 0.0% |
| Messages | 169.1k | 16.9% |
| Compact buffer | 1.2k | 0.3% |
| Free space | 805.8k | 80.6% |

### MCP Tools

| Tool | Server | Tokens |
|------|--------|--------|
| mcp__netbox__netbox_get_objects | netbox | 2k |
| mcp__netbox__netbox_get_changelogs | netbox | 155 |

### Custom Agents

| Agent Type | Source | Tokens |
|------------|--------|--------|
| codex:codex-rescue | Plugin | 85 |

### Memory Files

| Type | Path | Tokens |
|------|------|--------|
| User | /Users/x/.claude/CLAUDE.md | 2.6k |

### Skills

| Skill | Source | Tokens |
|-------|--------|--------|
| handoff | User | ~50 |
| code-review:code-review | Plugin (code-review) | < 20 |
"""

FAKE_CLAUDE = r"""#!/usr/bin/python3
import json, os, sys, time
d = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
fork = args[args.index("--session-id") + 1]
with open(os.path.join(d, "calls"), "a") as f:
    f.write(json.dumps({"args": args, "cwd": os.getcwd()}) + "\n")
proj = os.path.join(d, "projects", "-x")
os.makedirs(proj, exist_ok=True)
open(os.path.join(proj, fork + ".jsonl"), "w").write("{}\n")
mode = open(os.path.join(d, "mode")).read().strip()
if mode == "hang":
    time.sleep(60)
if mode == "fail":
    sys.exit(3)
if mode == "garbage":
    print("not json"); sys.exit(0)
md = open(os.path.join(d, "md")).read()
print(json.dumps({"type": "result", "is_error": False, "session_id": "other", "result": md}))
"""


class ParseTest(unittest.TestCase):
    def test_tokens(self):
        p = outbox._parse_tokens
        self.assertEqual(p("6k"), 6000)
        self.assertEqual(p("649"), 649)
        self.assertEqual(p("95k"), 95000)
        self.assertEqual(p("1.2k"), 1200)
        self.assertEqual(p("191.2k"), 191200)
        self.assertEqual(p("1m"), 1000000)
        self.assertEqual(p("~60"), 60)
        self.assertEqual(p("< 20"), 20)
        self.assertIsNone(p("abc"))
        self.assertIsNone(p(None))

    def test_parse(self):
        d = outbox.parse_context_md(MD)
        self.assertEqual(d["model"], "claude-fable-5-1")
        self.assertEqual((d["used"], d["window"], d["pct"]), (191200, 1000000, 19.0))
        names = [c["name"] for c in d["categories"]]
        self.assertEqual(names[0], "System prompt")
        self.assertEqual(names[-1], "Free space")
        self.assertEqual(d["categories"][0], {"name": "System prompt", "tokens": 6000, "pct": 0.6})
        self.assertEqual(d["categories"][5]["tokens"], 1200)
        det = d["details"]
        self.assertEqual(det["mcpTools"][0], {"name": "mcp__netbox__netbox_get_objects", "server": "netbox",
                                              "tokens": 2000, "label": "2k"})
        self.assertEqual(det["agents"][0]["name"], "codex:codex-rescue")
        self.assertEqual(det["memory"][0]["name"], "/Users/x/.claude/CLAUDE.md")
        self.assertEqual(det["memory"][0]["type"], "User")
        self.assertEqual(det["memory"][0]["tokens"], 2600)
        self.assertEqual([s["tokens"] for s in det["skills"]], [50, 20])
        self.assertEqual(det["skills"][1]["label"], "< 20")

    def test_parse_missing_details(self):
        md = MD.split("### MCP Tools")[0]
        d = outbox.parse_context_md(md)
        self.assertEqual(d["details"], {"mcpTools": [], "agents": [], "memory": [], "skills": []})

    def test_parse_bad(self):
        with self.assertRaises(ValueError):
            outbox.parse_context_md("hello")
        with self.assertRaises(ValueError):
            outbox.parse_context_md(None)


class ContextJobTest(unittest.TestCase):
    """Fake claude script: never runs the real claude and never touches the real ~/.claude."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.ob = os.path.join(t, "outbox")
        self.sdir = os.path.join(t, "sessions")
        self.cwd = os.path.join(t, "work")
        self.proj = os.path.join(t, "projects")
        for d in (self.ob, self.sdir, self.cwd, self.proj):
            os.makedirs(d)
        self.claude = os.path.join(t, "claude")
        with open(self.claude, "w") as f:
            f.write(FAKE_CLAUDE)
        os.chmod(self.claude, 0o755)
        with open(os.path.join(t, "md"), "w") as f:
            f.write(MD)
        for sid, pid in ((SID, 111), (SID2, 222)):
            with open(os.path.join(self.sdir, "%d.json" % pid), "w") as f:
                json.dump({"sessionId": sid, "cwd": self.cwd}, f)
        self.sessions = {SID: {"id": SID, "kind": "claude", "name": "Docs-panel-demo"},
                         SID2: {"id": SID2, "kind": "claude", "name": "Other"}}
        self.mode("ok")
        self.log = os.path.join(t, "send.log")
        outbox._CTX_RUN = None
        del outbox._CTX_QUEUE[:]
        outbox._FORKS.clear()
        p1 = mock.patch.object(outbox, "find_claude", return_value=self.claude)
        p2 = mock.patch.object(outbox, "PROJECTS_DIR", self.proj)
        p3 = mock.patch.object(outbox, "_warn")
        p1.start(); p2.start(); self.warn = p3.start()
        self.addCleanup(mock.patch.stopall)
        self.addCleanup(self.kill_all)

    def kill_all(self):
        if outbox._CTX_RUN:
            outbox._CTX_RUN["proc"].kill()
            outbox._CTX_RUN["proc"].wait()
            outbox._CTX_RUN["out"].close()
            outbox._CTX_RUN["err"].close()
        outbox._CTX_RUN = None
        del outbox._CTX_QUEUE[:]

    def mode(self, m):
        with open(os.path.join(self.tmp.name, "mode"), "w") as f:
            f.write(m)

    def put(self, rid, sid=SID):
        with open(os.path.join(self.ob, rid + ".req.json"), "w") as f:
            json.dump(_sig.req({"id": rid, "sessionId": sid, "type": "context", "createdAt": time.time()}), f)

    def res(self, rid):
        p = os.path.join(self.ob, rid + ".res.json")
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return json.load(f)

    def run_until(self, rids, limit=10):
        end = time.time() + limit
        while time.time() < end:
            outbox.process_once(self.ob, self.sessions, self.sdir, ["/nonexistent-orca"], self.log, time.time())
            if all(self.res(r) for r in rids):
                return
            time.sleep(0.05)
        self.fail("timeout waiting for %s" % rids)

    def forks_left(self):
        out = []
        for root, _dirs, files in os.walk(self.proj):
            out += [f for f in files if f.endswith(".jsonl")]
        return out

    def calls(self):
        p = os.path.join(self.tmp.name, "calls")
        if not os.path.exists(p):
            return []
        with open(p) as f:
            return [json.loads(l) for l in f]

    def test_done_and_cleanup(self):
        self.put("a" * 32)
        outbox.process_once(self.ob, self.sessions, self.sdir, ["x"], self.log, time.time())
        self.assertTrue(os.path.exists(os.path.join(self.ob, "a" * 32 + ".claimed")))  # not treated as a leftover
        running = outbox.active_forks()
        self.assertEqual(len(running), 1)
        self.run_until(["a" * 32])
        r = self.res("a" * 32)
        self.assertEqual(r["status"], "done")
        self.assertEqual(r["sessionId"], SID)
        self.assertEqual(r["data"]["model"], "claude-fable-5-1")
        self.assertEqual(r["data"]["categories"][-1]["name"], "Free space")
        self.assertEqual(self.forks_left(), [])
        self.assertFalse(os.path.exists(os.path.join(self.ob, "a" * 32 + ".claimed")))
        c = self.calls()[0]
        self.assertEqual(os.path.realpath(c["cwd"]), os.path.realpath(self.cwd))
        fork = c["args"][c["args"].index("--session-id") + 1]
        self.assertEqual(c["args"][:6], ["-p", "--resume", SID, "--fork-session", "--session-id", fork])
        self.assertIn(fork, running)
        self.assertFalse(os.path.exists(self.log))  # not logged to send.log
        self.assertIn(fork, outbox.active_forks())  # just finished, stays hidden for a while
        self.assertNotIn(fork, outbox.active_forks(time.time() + 60))

    def test_same_session_merged_others_queued(self):
        self.put("a" * 32)
        self.put("b" * 32)
        self.put("c" * 32, SID2)
        self.run_until(["a" * 32, "b" * 32, "c" * 32])
        self.assertEqual([c["args"][2] for c in self.calls()], [SID, SID2])  # one at a time; same-session requests are merged
        self.assertEqual(self.res("b" * 32)["status"], "done")
        self.assertEqual(self.res("c" * 32)["sessionId"], SID2)
        self.assertEqual(self.forks_left(), [])

    def test_timeout_kills_and_cleans(self):
        self.mode("hang")
        self.put("a" * 32)
        with mock.patch.object(outbox, "CONTEXT_TIMEOUT", 0.5):
            self.run_until(["a" * 32])
        r = self.res("a" * 32)
        self.assertEqual((r["status"], r["error"]), ("failed", "context-timeout"))
        self.assertEqual(self.forks_left(), [])

    def test_failures(self):
        self.mode("garbage")
        self.put("a" * 32)
        self.run_until(["a" * 32])
        self.assertEqual(self.res("a" * 32)["error"], "context-parse")
        self.mode("fail")
        self.put("b" * 32)
        self.run_until(["b" * 32])
        self.assertEqual(self.res("b" * 32)["error"], "context-failed")
        self.assertEqual(self.forks_left(), [])

    def test_cwd_missing_and_no_claude_and_gone(self):
        os.rmdir(self.cwd)
        self.put("a" * 32)
        self.run_until(["a" * 32])
        self.assertEqual(self.res("a" * 32)["error"], "cwd-missing")
        os.makedirs(self.cwd)
        with mock.patch.object(outbox, "find_claude", return_value=None):
            self.put("b" * 32)
            self.run_until(["b" * 32])
        self.assertEqual(self.res("b" * 32)["error"], "claude-not-found")
        self.put("c" * 32, "99999999-2222-3333-4444-555555555555")
        self.run_until(["c" * 32])
        self.assertEqual(self.res("c" * 32)["error"], "session-gone")
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
