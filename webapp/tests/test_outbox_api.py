import hashlib
import hmac
import http.client
import json
import os
import stat
import tempfile
import threading
import time
import unittest
from unittest import mock

from api import outbox, server
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET so hand-written results can be signed

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
RID = "0123456789abcdef0123456789abcdef"


def ago(sec):
    """ISO timestamp from `sec` seconds ago (Claude Code transcript format)."""
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - sec)) + ".000Z"


class CleanTextTest(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(outbox.clean_text("  a\nb\r\nc\x00\x1b[d\x7f  "), "a b c[d")
        self.assertEqual(outbox.clean_text("中文"), "中文")

    def test_c1_and_unicode_separators(self):
        self.assertEqual(outbox.clean_text("a\x80b\x9fc"), "abc")
        self.assertEqual(outbox.clean_text("a b c"), "a b c")

    def test_rejects(self):
        for bad in ("", "  \n\t ", "\x00\x01", None, 5, "x" * 4001):
            self.assertIsNone(outbox.clean_text(bad), repr(bad)[:20])
        self.assertEqual(len(outbox.clean_text("x" * 4000)), 4000)


class OutboxApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.outbox = os.path.join(self.tmp.name, "outbox")
        os.makedirs(self.outbox)
        self.snap_path = os.path.join(self.tmp.name, "snapshot.json")
        now = time.time()
        with open(self.snap_path, "w") as f:
            json.dump({"generatedAt": now, "usage": {}, "zones": [], "sessions": [
                {"id": "c1", "kind": "claude", "status": "idle", "since": now},
                {"id": "x1", "kind": "codex", "status": "idle", "since": now},
            ]}, f)
        patcher = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap_path,
                                        projects=self.tmp.name,
                                        state=os.path.join(self.tmp.name, "st", "state.json"),
                                        outbox_dir=self.outbox)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def req(self, method, path, body=None, auth=True, raw=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Cookie": COOKIE} if auth else {}
        data = raw
        if body is not None:
            data = json.dumps(body)
        if data is not None:
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def files(self):
        return sorted(os.listdir(self.outbox))

    def read_req(self, rid):
        with open(os.path.join(self.outbox, rid + ".req.json")) as f:
            return json.load(f)

    def test_unauthorized(self):
        self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"text": "a"}, auth=False)[0], 401)
        self.assertEqual(self.req("POST", "/api/sessions/c1/screen", {}, auth=False)[0], 401)
        self.assertEqual(self.req("GET", "/api/requests/" + RID, auth=False)[0], 401)
        self.assertEqual(self.files(), [])

    def test_send_text_writes_request(self):
        before = time.time()
        st, body = self.req("POST", "/api/sessions/c1/send", {"text": " 你好\nworld\x00 "})
        self.assertEqual(st, 202)
        rid = body["requestId"]
        self.assertRegex(rid, r"^[0-9a-f]{32}$")
        self.assertEqual(self.files(), [rid + ".req.json"])
        d = self.read_req(rid)
        self.assertEqual(d["id"], rid)
        self.assertEqual(d["sessionId"], "c1")
        self.assertEqual(d["type"], "text")
        self.assertEqual(d["text"], "你好 world")
        self.assertIs(d["enter"], True)
        self.assertGreaterEqual(d["createdAt"], before)
        mode = stat.S_IMODE(os.stat(os.path.join(self.outbox, rid + ".req.json")).st_mode)
        self.assertEqual(mode, 0o600)  # host user only (other local accounts cannot read or write it)

    def test_send_text_enter_false(self):
        st, body = self.req("POST", "/api/sessions/c1/send", {"text": "y", "enter": False})
        self.assertEqual(st, 202)
        self.assertIs(self.read_req(body["requestId"])["enter"], False)

    def test_send_key(self):
        for k in ("1", "4", "5", "9", "enter", "esc", "up", "down", "tab", "right"):
            st, body = self.req("POST", "/api/sessions/c1/send", {"key": k})
            self.assertEqual(st, 202, k)
            d = self.read_req(body["requestId"])
            self.assertEqual((d["type"], d["key"]), ("key", k))

    def test_send_steps(self):
        steps = [{"key": "2"}, {"text": " 芒果\n汁 "}, {"key": "enter"}, {"key": "1"}]
        st, body = self.req("POST", "/api/sessions/c1/send", {"steps": steps})
        self.assertEqual(st, 202)
        d = self.read_req(body["requestId"])
        self.assertEqual((d["type"], d["sessionId"]), ("steps", "c1"))
        self.assertEqual(d["steps"], [{"key": "2"}, {"text": "芒果 汁"}, {"key": "enter"}, {"key": "1"}])

    def test_send_steps_limits(self):
        ok = [{"key": "1"}] * 24
        self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"steps": ok})[0], 202)
        bad = [[], [{"key": "1"}] * 25, [{"key": "x"}], [{"text": "  "}], [{"text": "a" * 4001}],
               [{"key": "1", "text": "a"}], [{}], ["1"], [{"key": 1}], "1", None, {"key": "1"}]
        for steps in bad:
            self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"steps": steps})[0], 400, steps)
        self.assertEqual(len(self.files()), 1)

    def test_steps_key_n(self):
        """Adding a note on a preview question requires pressing n to open the note box: the whitelist adds only n, other letters are still rejected."""
        steps = [{"key": "2"}, {"key": "1"}, {"key": "n"}, {"text": "折叠起来"}, {"key": "enter"}]
        st, body = self.req("POST", "/api/sessions/c1/send", {"steps": steps})
        self.assertEqual(st, 202)
        self.assertEqual(self.read_req(body["requestId"])["steps"], steps)
        self.assertIn("n", outbox.KEY_WHITELIST)
        self.assertEqual(outbox.clean_steps([{"key": "n"}]), [{"key": "n"}])
        for k in ("a", "m", "N", "y", "q", "nn", "ctrl+n", " n"):
            self.assertIsNone(outbox.clean_steps([{"key": k}]), k)
            self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"steps": [{"key": k}]})[0], 400, k)
            self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"key": k})[0], 400, k)
        letters = [k for k in outbox.KEY_WHITELIST if len(k) == 1 and k.isalpha()]
        self.assertEqual(letters, ["n"])
        self.assertEqual(len(self.files()), 1)

    def test_screen(self):
        st, body = self.req("POST", "/api/sessions/c1/screen", {})
        self.assertEqual(st, 202)
        d = self.read_req(body["requestId"])
        self.assertEqual((d["type"], d["sessionId"]), ("screen", "c1"))

    def test_bad_requests_400(self):
        cases = [{"text": ""}, {"text": "  \n "}, {"text": "x" * 4001}, {"text": 5}, {},
                 {"key": "0"}, {"key": "10"}, {"key": "rm -rf"}, {"key": "Enter"}, {"key": 1},
                 {"text": "a", "enter": "yes"}]
        for b in cases:
            self.assertEqual(self.req("POST", "/api/sessions/c1/send", b)[0], 400, b)
        self.assertEqual(self.req("POST", "/api/sessions/c1/send", raw="not json")[0], 400)
        self.assertEqual(self.files(), [])

    def test_non_claude_400_unknown_404(self):
        self.assertEqual(self.req("POST", "/api/sessions/x1/send", {"text": "a"})[0], 400)
        self.assertEqual(self.req("POST", "/api/sessions/x1/screen", {})[0], 400)
        self.assertEqual(self.req("POST", "/api/sessions/nope/send", {"text": "a"})[0], 404)
        self.assertEqual(self.req("POST", "/api/sessions/nope/screen", {})[0], 404)
        self.assertEqual(self.files(), [])

    def test_status_bad_and_unknown(self):
        self.assertEqual(self.req("GET", "/api/requests/xyz")[0], 400)
        self.assertEqual(self.req("GET", "/api/requests/" + RID.upper())[0], 400)
        self.assertEqual(self.req("GET", "/api/requests/" + RID + "0")[0], 400)
        self.assertEqual(self.req("GET", "/api/requests/" + RID + "%0A")[0], 400)
        self.assertEqual(self.req("GET", "/api/requests/" + RID)[0], 404)

    def test_key_wins_over_text(self):
        st, body = self.req("POST", "/api/sessions/c1/send", {"key": "esc", "text": "hi"})
        self.assertEqual(st, 202)
        d = self.read_req(body["requestId"])
        self.assertEqual((d["type"], d["key"]), ("key", "esc"))
        self.assertNotIn("text", d)

    def test_status_pending_then_done(self):
        _, body = self.req("POST", "/api/sessions/c1/send", {"text": "a"})
        rid = body["requestId"]
        self.assertEqual(self.req("GET", "/api/requests/" + rid), (200, {"status": "pending"}))
        with open(os.path.join(self.outbox, rid + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": rid, "status": "done", "finishedAt": 1.0}), f)
        os.unlink(os.path.join(self.outbox, rid + ".req.json"))
        self.assertEqual(self.req("GET", "/api/requests/" + rid), (200, {"status": "done"}))

    def test_status_failed_and_lines(self):
        with open(os.path.join(self.outbox, RID + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": RID, "status": "failed", "error": "no-terminal"}), f)
        self.assertEqual(self.req("GET", "/api/requests/" + RID),
                         (200, {"status": "failed", "error": "no-terminal"}))
        rid2 = "f" * 32
        with open(os.path.join(self.outbox, rid2 + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": rid2, "status": "done", "lines": ["a", "b"]}), f)
        self.assertEqual(self.req("GET", "/api/requests/" + rid2),
                         (200, {"status": "done", "lines": ["a", "b"]}))

    def test_status_failed_with_sent_steps(self):
        with open(os.path.join(self.outbox, RID + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": RID, "status": "failed", "error": "orca-failed", "sentSteps": 2}), f)
        self.assertEqual(self.req("GET", "/api/requests/" + RID),
                         (200, {"status": "failed", "error": "orca-failed", "sentSteps": 2}))

    def test_status_helper_timeout(self):
        p = os.path.join(self.outbox, RID + ".req.json")
        with open(p, "w") as f:
            json.dump({"id": RID, "createdAt": time.time() - 31}, f)
        self.assertEqual(self.req("GET", "/api/requests/" + RID),
                         (200, {"status": "failed", "error": "helper-timeout"}))

    def write_claim(self, age):
        with open(os.path.join(self.outbox, RID + ".claimed"), "w") as f:
            json.dump({"id": RID, "createdAt": time.time() - age}, f)

    def test_status_claimed_pending(self):
        self.write_claim(45)  # beyond the 30-second request rule, but a claim grants 60 seconds
        self.assertEqual(self.req("GET", "/api/requests/" + RID), (200, {"status": "pending"}))

    def test_status_claimed_timeout(self):
        self.write_claim(61)
        self.assertEqual(self.req("GET", "/api/requests/" + RID),
                         (200, {"status": "failed", "error": "helper-timeout"}))

    def test_status_claimed_mtime_fallback(self):
        p = os.path.join(self.outbox, RID + ".claimed")
        with open(p, "w") as f:
            f.write("garbage")
        self.assertEqual(self.req("GET", "/api/requests/" + RID), (200, {"status": "pending"}))
        os.utime(p, (time.time() - 90, time.time() - 90))
        self.assertEqual(self.req("GET", "/api/requests/" + RID)[1]["error"], "helper-timeout")

    def test_status_result_beats_claim(self):
        self.write_claim(5)
        with open(os.path.join(self.outbox, RID + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": RID, "status": "done", "lines": ["x"]}), f)
        self.assertEqual(self.req("GET", "/api/requests/" + RID),
                         (200, {"status": "done", "lines": ["x"]}))

    def test_status_result_beats_timeout(self):
        with open(os.path.join(self.outbox, RID + ".req.json"), "w") as f:
            json.dump({"id": RID, "createdAt": time.time() - 99}, f)
        with open(os.path.join(self.outbox, RID + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": RID, "status": "done"}), f)
        self.assertEqual(self.req("GET", "/api/requests/" + RID), (200, {"status": "done"}))

    def test_enqueue_is_atomic(self):
        # a failure midway through writing leaves neither a half-written req file nor a temp file
        with mock.patch.object(outbox.json, "dump", side_effect=OSError("disk")):
            with self.assertRaises(OSError):
                outbox.enqueue(self.outbox, "c1", {"type": "screen"})
        self.assertEqual(self.files(), [])
        # the success path uses os.replace to land on the final name
        with mock.patch.object(outbox.os, "replace", wraps=os.replace) as rep:
            rid = outbox.enqueue(self.outbox, "c1", {"type": "screen"})
        src, dst = rep.call_args[0]
        self.assertTrue(os.path.basename(src).startswith(".tmp-"))
        self.assertEqual(os.path.basename(dst), rid + ".req.json")

    def test_outbox_missing_500(self):
        os.rmdir(self.outbox)
        self.assertEqual(self.req("POST", "/api/sessions/c1/screen", {})[0], 500)

    # ---------- quotes (multi-line), recall ----------
    def test_send_quote_builds_multiline(self):
        st, body = self.req("POST", "/api/sessions/c1/send", {"text": "好的\n收到", "quote": "看板: 第一行\n第二行"})
        self.assertEqual(st, 202)
        d = self.read_req(body["requestId"])
        self.assertEqual(d["text"], "> 看板: 第一行 第二行\n\n好的 收到")
        self.assertIs(d["lines"], True)
        self.assertIs(d["enter"], True)

    def test_send_quote_truncated_300(self):
        st, body = self.req("POST", "/api/sessions/c1/send", {"text": "x", "quote": "我: " + "长" * 400})
        d = self.read_req(body["requestId"])
        head = d["text"].split("\n\n")[0]
        self.assertEqual(len(head), 2 + 300 + 1)
        self.assertTrue(head.endswith("…"))

    def test_send_quote_bad(self):
        self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"text": "x", "quote": 5})[0], 400)
        st, body = self.req("POST", "/api/sessions/c1/send", {"text": "x", "quote": "  "})
        self.assertEqual(self.read_req(body["requestId"])["text"], "x")  # an empty quote counts as none

    def test_send_quote_with_files(self):
        up = os.path.join(self.tmp.name, "uploads")
        os.makedirs(up, exist_ok=True)
        self.httpd.app.uploads = up
        name = "20261022-150000-abcdef-a.png"
        with open(os.path.join(up, name), "wb") as f:
            f.write(b"x")
        st, body = self.req("POST", "/api/sessions/c1/send", {"text": "看图", "files": [name], "quote": "我: 原文"})
        self.assertEqual(st, 202, body)
        d = self.read_req(body["requestId"])
        self.assertEqual((d["type"], d["text"], d.get("lines")), ("message", "> 我: 原文\n\n看图", True))

    def test_send_files_lang_from_query(self):
        """?lang= goes into the payload verbatim (the helper picks the prompt text by it); unknown or missing values add no lang; plain text messages without attachments carry none."""
        up = os.path.join(self.tmp.name, "uploads")
        os.makedirs(up, exist_ok=True)
        self.httpd.app.uploads = up
        name = "20261022-150000-abcdef-b.png"
        with open(os.path.join(up, name), "wb") as f:
            f.write(b"x")
        for q, want in (("?lang=en", "en"), ("?lang=hant", "hant"), ("?lang=hans", "hans"), ("?lang=fr", None), ("", None)):
            st, body = self.req("POST", "/api/sessions/c1/send" + q, {"text": "", "files": [name]})
            self.assertEqual(st, 202, body)
            self.assertEqual(self.read_req(body["requestId"]).get("lang"), want, q)

    def _recall_session(self, lines, status="busy"):
        rel = os.path.join("proj", "c2.jsonl")
        os.makedirs(os.path.join(self.tmp.name, "proj"), exist_ok=True)
        with open(os.path.join(self.tmp.name, rel), "w", encoding="utf-8") as f:
            for ln in lines:
                f.write(json.dumps(ln, ensure_ascii=False, separators=(",", ":")) + "\n")
        with open(self.snap_path) as f:
            snap = json.load(f)
        snap["sessions"].append({"id": "c2", "kind": "claude", "status": status, "since": time.time(), "transcript": rel})
        with open(self.snap_path, "w") as f:
            json.dump(snap, f)
        t = time.time() + 30
        os.utime(self.snap_path, (t, t))

    def test_recall_queued_message(self):
        self._recall_session([
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(30), "content": "queued-alice"},
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(20), "content": "queued-bob"}])
        st, body = self.req("POST", "/api/sessions/c2/send", {"recall": "queued-bob"})
        self.assertEqual(st, 202, body)
        d = self.read_req(body["requestId"])
        self.assertEqual((d["type"], d["text"]), ("recall", "queued-bob"))

    def test_recall_multiline_quote_message(self):
        """A quoted reply is multi-line: newlines in the original must be preserved on recall so it matches the queue record."""
        self._recall_session([
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(5), "content": "> 我: 原文\n\n正文"}])
        st, body = self.req("POST", "/api/sessions/c2/send", {"recall": "> 我: 原文\n\n正文"})
        self.assertEqual(st, 202, body)
        self.assertEqual(self.read_req(body["requestId"])["text"], "> 我: 原文\n\n正文")

    # ---- 2-minute recall time window ----
    def _read_lines(self, text, sec):
        """A message that was read: queued, then absorbed mid-turn (remove)."""
        return [{"type": "queue-operation", "operation": "enqueue", "timestamp": ago(sec), "content": text},
                {"type": "queue-operation", "operation": "remove", "timestamp": ago(sec - 1), "content": text,
                 "reason": "absorbed_mid_turn"}]

    def test_recall_too_old_409(self):
        """Same for queued messages: past 2 minutes gives 409 too-old and nothing is queued; old data without a timestamp counts as timed out."""
        self._recall_session([
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(200), "content": "老的"},
            {"type": "queue-operation", "operation": "enqueue", "timestamp": "t", "content": "没时间"}])
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"recall": "老的"}), (409, {"error": "too-old"}))
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"recall": "没时间"}), (409, {"error": "too-old"}))
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"recall": "记录里没有"}), (409, {"error": "too-old"}))
        self.assertEqual(self.files(), [])

    def test_recall_read_busy_last_sends_esc(self):
        """Read + busy + last user message: queues the ready-made esc key with mode=interrupted."""
        self._recall_session([
            {"type": "user", "timestamp": ago(90), "message": {"role": "user", "content": "更早的"}},
            {"type": "assistant", "timestamp": ago(80), "message": {"role": "assistant", "content": [{"type": "text", "text": "好"}]}}]
            + self._read_lines("刚才那句", 30))
        st, body = self.req("POST", "/api/sessions/c2/send", {"recall": "刚才那句"})
        self.assertEqual(st, 202, body)
        self.assertEqual(body.get("mode"), "interrupted")
        d = self.read_req(body["requestId"])
        self.assertEqual((d["type"], d["key"]), ("key", "esc"))

    def test_recall_read_formal_user_line_busy_last(self):
        """A message sent directly while idle (a proper user line) also counts as read; if the session is busy and it is the last one, it is interrupted all the same."""
        self._recall_session([{"type": "user", "timestamp": ago(10), "message": {"role": "user", "content": "直接发的"}}])
        st, body = self.req("POST", "/api/sessions/c2/send", {"recall": "直接发的"})
        self.assertEqual((st, body.get("mode")), (202, "interrupted"))

    def test_recall_read_busy_not_last_no_key(self):
        """Read + busy + more of my messages after it: no Esc is sent, 200 mode=processing."""
        self._recall_session(self._read_lines("第一句", 40) + [
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(20), "content": "第二句"}])
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"recall": "第一句"}), (200, {"mode": "processing"}))
        self.assertEqual(self.files(), [])

    def test_recall_read_idle_answered(self):
        """Read but the session is not busy (already answered): no key is sent, 200 mode=answered."""
        self._recall_session(self._read_lines("问一句", 60) + [
            {"type": "assistant", "timestamp": ago(50), "message": {"role": "assistant", "content": [{"type": "text", "text": "答"}]}}],
            status="idle")
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"recall": "问一句"}), (200, {"mode": "answered"}))
        self.assertEqual(self.files(), [])

    def test_recall_window_boundary(self):
        """2-minute window (120 s) plus network grace: recall works within 110 s but not beyond 200 s."""
        self._recall_session([
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(110), "content": "边上"}])
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"recall": "边上"})[0], 202)

    def test_transcript_queued_count(self):
        """Session detail (first page) carries the count of my still-queued messages; a guest's [Guest] messages are not counted as the admin's."""
        self._recall_session([
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(30), "content": "alice"},
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(20), "content": "bob"},
            {"type": "queue-operation", "operation": "enqueue", "timestamp": ago(10), "content": "[Guest] 访客的"}])
        st, page = self.req("GET", "/api/sessions/c2/transcript")
        self.assertEqual((st, page.get("queued")), (200, 2))
        st, page = self.req("GET", "/api/sessions/c2/transcript?before=99999")
        self.assertNotIn("queued", page)

    # ---- a plain admin send on a question/approval menu gives 409 ----
    def _menu_session(self, status, blocks, result=False):
        lines = [{"type": "assistant", "timestamp": "t", "message": {"role": "assistant", "content": blocks}}]
        if result:
            lines.append({"type": "user", "timestamp": "t", "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": blocks[0]["id"], "content": "ok"}]}})
        self._recall_session(lines)
        with open(self.snap_path) as f:
            snap = json.load(f)
        snap["sessions"][-1]["status"] = status
        with open(self.snap_path, "w") as f:
            json.dump(snap, f)
        t = time.time() + 40
        os.utime(self.snap_path, (t, t))

    ASK = {"type": "tool_use", "id": "tu_ask", "name": "AskUserQuestion", "input": {"questions": [
        {"question": "选哪个?", "header": "Q", "multiSelect": False,
         "options": [{"label": "alice", "description": ""}, {"label": "bob", "description": ""}]}]}}
    BASH = {"type": "tool_use", "id": "tu_bash", "name": "Bash", "input": {"command": "ls"}}

    def test_admin_send_at_ask_menu_409(self):
        self._menu_session("waiting", [self.ASK])
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"text": "随口一句"}), (409, {"error": "at-menu"}))
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"text": "x", "enter": False})[0], 409)
        self.assertEqual(self.files(), [])
        # the question card's own answer path (steps / key) is still allowed
        st, body = self.req("POST", "/api/sessions/c2/send", {"steps": [{"key": "1"}]})
        self.assertEqual(st, 202, body)
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"key": "esc"})[0], 202)

    def test_admin_recall_at_menu_409(self):
        self._menu_session("waiting", [self.ASK])
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"recall": "随口一句"}), (409, {"error": "at-menu"}))
        self.assertEqual(self.files(), [])

    def test_admin_send_at_approve_menu_409(self):
        self._menu_session("waiting", [self.BASH])
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"text": "hi"}), (409, {"error": "at-menu"}))
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"text": "hi", "files": ["a.png"]})[0], 409)
        self.assertEqual(self.files(), [])

    def test_admin_send_waiting_without_menu_ok(self):
        """waiting but no unanswered question / unfinished tool at the end (e.g. the tool already has a result): sends as usual."""
        self._menu_session("waiting", [self.BASH], result=True)
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"text": "hi"})[0], 202)

    def test_admin_send_busy_with_pending_tool_ok(self):
        """A tool without a result while working is normal running, not a menu (small gaps within the 3-second snapshot interval are still accepted)."""
        self._menu_session("busy", [self.ASK])
        self.assertEqual(self.req("POST", "/api/sessions/c2/send", {"text": "hi"})[0], 202)

    def test_admin_send_waiting_no_transcript_409(self):
        with open(self.snap_path) as f:
            snap = json.load(f)
        snap["sessions"][0]["status"] = "waiting"
        with open(self.snap_path, "w") as f:
            json.dump(snap, f)
        t = time.time() + 40
        os.utime(self.snap_path, (t, t))
        self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"text": "hi"})[0], 409)

    def test_recall_needs_transcript(self):
        self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"recall": "x"})[0], 409)
        self.assertEqual(self.req("POST", "/api/sessions/c1/send", {"recall": ""})[0], 400)


if __name__ == "__main__":
    unittest.main()
