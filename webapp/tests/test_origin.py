"""Turn origin: detection in the snapshot, unread/notes, notifications. See classify_user_text in api/transcript.py for the rules."""
import json
import os
import tempfile
import unittest
from unittest import mock

from api import notify as N
from api.state import State, flags_for
from helper import snapshot
from helper.snapshot import build_snapshot, read_origin
from tests.test_snapshot import CFG, DUMP


def rec(content, **kw):
    d = {"type": "user", "message": {"role": "user", "content": content}}
    d.update(kw)
    return json.dumps(d, ensure_ascii=False, separators=(",", ":"))


class OriginSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "a.jsonl")

    def write(self, lines, mode="w"):
        with open(self.path, mode) as f:
            f.write("\n".join(lines) + "\n")

    def origin(self):
        return read_origin(self.tmp.name, "a.jsonl")

    def test_peer_agent_user_and_tool_result_skipped(self):
        peer = ('Another Claude session sent a message:\n<cross-session-message from="x" '
                'from-name="Lab-config-demo" from-mode="prompting">\nhi\n</cross-session-message>')
        tool = rec([{"type": "tool_result", "tool_use_id": "t", "content": "x"}])
        self.write([rec("你好"), rec(peer), '{"type":"assistant","message":{"content":[]}}', tool])
        self.assertEqual(self.origin(), ("peer", "Lab-config-demo"))
        self.write([rec('<agent-message from="a">ok</agent-message>')], "a")
        self.assertEqual(self.origin(), ("agent", None))  # size changed, cache invalidated
        self.write([rec("接着干")], "a")
        self.assertEqual(self.origin(), ("user", None))

    def test_meta_cross_session_record_counts_other_meta_skipped(self):
        peer = ('Another Claude session sent a message:\n<cross-session-message from="x" '
                'from-name="Web-ui-demo" from-mode="prompting">\nhi\n</cross-session-message>')
        self.write([rec("你好"), rec(peer, isMeta=True), rec("系统注入", isMeta=True)])
        self.assertEqual(self.origin(), ("peer", "Web-ui-demo"))
        from api import transcript
        r = transcript._convert(rec(peer, isMeta=True).encode())
        self.assertEqual((r[0]["role"], r[0]["from"], r[0]["text"]), ("peer", "Web-ui-demo", "hi"))
        self.assertEqual(transcript._convert(rec("系统注入", isMeta=True).encode()), [])

    def test_handback_wrapped_in_peer_prefix_is_agent(self):
        t = 'Another Claude session sent a message:\n<agent-message from="sub1">做完了</agent-message>'
        self.write([rec("你好"), rec(t, isMeta=True)])
        self.assertEqual(self.origin(), ("agent", None))
        from api import transcript
        r = transcript._convert(rec(t, isMeta=True).encode())
        self.assertEqual((r[0]["role"], r[0]["text"]), ("agent", "做完了"))

    def test_missing_or_empty_is_user(self):
        self.assertEqual(read_origin(self.tmp.name, None), ("user", None))
        self.assertEqual(read_origin(self.tmp.name, "nope.jsonl"), ("user", None))
        self.write([])
        self.assertEqual(self.origin(), ("user", None))

    def test_window_grows_past_huge_tail_and_result_cached(self):
        peer = rec('<cross-session-message from-name="B">x</cross-session-message>')
        big = rec([{"type": "tool_result", "content": "z" * 1_500_000}])
        self.write([peer, big, big])
        self.assertEqual(self.origin(), ("peer", "B"))
        with mock.patch.object(snapshot, "_origin_in", side_effect=AssertionError):
            self.assertEqual(self.origin(), ("peer", "B"))

    def test_build_snapshot_has_origin_fields(self):
        sdir = os.path.join(self.tmp.name, "s")
        os.makedirs(sdir)
        os.makedirs(os.path.join(self.tmp.name, "proj"))
        with open(os.path.join(self.tmp.name, "proj", "id1.jsonl"), "w") as f:
            f.write(rec('<agent-message from="a">x</agent-message>') + "\n")
        s = build_snapshot(DUMP, sdir, self.tmp.name, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual((s["origin"], s["peer"]), ("agent", None))


class OriginFlagsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.s = State(os.path.join(self.tmp.name, "st.json"))

    def sess(self, sid="a", status="idle", **kw):
        d = {"id": sid, "status": status, "since": self.s.installed_at + 10}
        d.update(kw)
        return d

    def flags(self, **kw):
        return flags_for(self.s, self.sess(**kw), self.s.installed_at + 20)

    def test_peer_and_agent_idle_not_unread_with_note(self):
        # only the structured originTag is provided and the frontend composes the text per language; the legacy originNote field is always an empty string (no Chinese is sent)
        f = self.flags(origin="peer", peer="Lab-config-demo")
        self.assertEqual((f["unread"], f["originTag"], f["originNote"]), (False, {"kind": "peer", "peer": "Lab-config-demo"}, ""))
        self.assertEqual(self.flags(origin="peer")["originTag"], {"kind": "peer", "peer": ""})
        f = self.flags(origin="agent")
        self.assertEqual((f["unread"], f["originTag"], f["originNote"]), (False, {"kind": "agent"}, ""))

    def test_user_origin_unchanged(self):
        f = self.flags(origin="user")
        self.assertEqual((f["unread"], f["originNote"], f["originTag"]), (True, "", None))
        self.assertTrue(self.flags()["unread"])

    def test_pinned_unaffected_and_no_note_when_busy(self):
        self.s.set_pin("a", True, t=self.s.installed_at + 30)
        f = flags_for(self.s, self.sess(origin="peer"), self.s.installed_at + 40)
        self.assertTrue(f["pinned"])
        self.assertIsNone(self.flags(origin="agent", status="busy")["originTag"])

    def test_done_push_skips_peer_and_agent_turns(self):
        sessions = []
        for sid, origin in (("u", "user"), ("p", "peer"), ("g", "agent")):
            d = self.sess(sid=sid, origin=origin)
            d.update(flags_for(self.s, d, self.s.installed_at + 20))
            sessions.append(d)
        st, _ = N.step(N.new_state(), [], 0, lambda s, k: "x")
        st, _ = N.step(st, sessions, 100, lambda s, k: "x")
        _, acts = N.step(st, sessions, 120, lambda s, k: "x")
        self.assertEqual([a["tag"] for a in acts if a["kind"] == "show"], ["s-u"])


if __name__ == "__main__":
    unittest.main()
