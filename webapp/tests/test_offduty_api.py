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

from api import outbox, server
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET so hand-written results can be signed

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
RID = "0123456789abcdef0123456789abcdef"
QS = [{"question": "选哪个？", "header": "h", "multiSelect": False, "options": [{"label": "alice"}]}]


def line(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"


class OffdutyApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.outbox = os.path.join(t, "outbox")
        self.projects = os.path.join(t, "projects")
        os.makedirs(self.outbox)
        os.makedirs(os.path.join(self.projects, "p"))
        with open(os.path.join(self.projects, "p", "o1.jsonl"), "w", encoding="utf-8") as f:
            f.write(line({"type": "user", "message": {"role": "user", "content": "你好"},
                          "timestamp": "2026-10-19T01:00:00Z"}))
            f.write(line({"type": "assistant", "isSidechain": False, "timestamp": "2026-10-19T01:00:01Z",
                          "message": {"role": "assistant", "content": [
                              {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}, "id": "toolu_T"}]}}))
            f.write(line({"type": "assistant", "isSidechain": False, "timestamp": "2026-10-19T01:00:02Z",
                          "message": {"role": "assistant", "content": [
                              {"type": "tool_use", "name": "AskUserQuestion", "input": {"questions": QS},
                               "id": "toolu_A"}]}}))
        self.snap_path = os.path.join(t, "snapshot.json")
        now = time.time()
        with open(self.snap_path, "w") as f:
            json.dump({"generatedAt": now, "usage": {}, "zones": [], "sessions": [
                {"id": "c1", "kind": "claude", "status": "idle", "since": now}],
                "offduty": [
                    {"name": "Lab-off", "sid": "o1", "zone": "Lab", "lastActive": 1, "offAt": 2,
                     "transcript": "p/o1.jsonl"},
                    {"name": "Lab-nofile", "sid": "o2", "zone": "Lab", "lastActive": 1, "offAt": 1,
                     "transcript": None}]}, f)
        patcher = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap_path,
                                        projects=self.projects,
                                        state=os.path.join(t, "st", "state.json"), outbox_dir=self.outbox)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def req(self, method, path, auth=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request(method, path, headers={"Cookie": COOKIE} if auth else {})
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def test_snapshot_carries_offduty(self):
        r, d = self.req("GET", "/api/snapshot")
        self.assertEqual(r, 200)
        self.assertEqual([o["name"] for o in d["offduty"]], ["Lab-off", "Lab-nofile"])

    def test_wake_enqueues(self):
        r, d = self.req("POST", "/api/offduty/o1/wake")
        self.assertEqual(r, 202)
        self.assertTrue(outbox.RID_RE.match(d["requestId"]))
        with open(os.path.join(self.outbox, d["requestId"] + ".req.json")) as f:
            body = json.load(f)
        self.assertEqual((body["type"], body["name"], body["sessionId"]), ("wake", "Lab-off", "o1"))
        self.assertIsInstance(body["createdAt"], float)

    def test_wake_unknown_or_awake_404(self):
        for sid in ("nope", "c1"):
            self.assertEqual(self.req("POST", "/api/offduty/%s/wake" % sid),
                             (404, {"error": "not-offduty"}))
        self.assertEqual(os.listdir(self.outbox), [])

    def test_wake_needs_auth(self):
        self.assertEqual(self.req("POST", "/api/offduty/o1/wake", auth=False)[0], 401)
        self.assertEqual(self.req("GET", "/api/offduty/o1/transcript", auth=False)[0], 401)

    def test_wake_outbox_missing_500(self):
        os.rmdir(self.outbox)
        self.assertEqual(self.req("POST", "/api/offduty/o1/wake")[0], 500)

    def test_transcript_closed_semantics(self):
        r, d = self.req("GET", "/api/offduty/o1/transcript")
        self.assertEqual(r, 200)
        asks = [i for i in d["items"] if i["role"] == "ask"]
        tools = [i for i in d["items"] if i["role"] == "tool"]
        self.assertTrue(asks and tools)
        self.assertTrue(all(i["answered"] is True for i in asks))
        self.assertTrue(all(i["pending"] is False for i in tools))

    def test_transcript_live_session_endpoint_unchanged_semantics(self):
        # control: the same read_page without closed leaves ask unanswered and the tool pending
        from api import transcript
        d = transcript.read_page(os.path.join(self.projects, "p", "o1.jsonl"), None)
        self.assertTrue(any(i["role"] == "ask" and i["answered"] is False for i in d["items"]))
        self.assertTrue(any(i["role"] == "tool" and i["pending"] is True for i in d["items"]))

    def test_transcript_errors(self):
        self.assertEqual(self.req("GET", "/api/offduty/nope/transcript"), (404, {"error": "not-offduty"}))
        self.assertEqual(self.req("GET", "/api/offduty/c1/transcript")[0], 404)
        self.assertEqual(self.req("GET", "/api/offduty/o2/transcript"), (404, {"error": "transcript not found"}))
        self.assertEqual(self.req("GET", "/api/offduty/o1/transcript?before=abc")[0], 400)
        self.assertEqual(self.req("GET", "/api/offduty/o1/transcript?before=0")[0], 200)

    def test_transcript_cannot_escape_projects(self):
        with open(self.snap_path, "w") as f:
            json.dump({"generatedAt": time.time(), "sessions": [], "offduty": [
                {"name": "E", "sid": "e", "zone": "Lab", "transcript": "../../etc/passwd"}]}, f)
        os.utime(self.snap_path, (time.time() + 5, time.time() + 5))
        self.assertEqual(self.req("GET", "/api/offduty/e/transcript")[0], 404)

    def test_status_wake_timeout_is_150(self):
        self.assertEqual(outbox.WAKE_HELPER_TIMEOUT, 150)
        for suffix in (".req.json", ".claimed"):
            p = os.path.join(self.outbox, RID + suffix)
            with open(p, "w") as f:
                json.dump({"id": RID, "type": "wake", "createdAt": time.time() - 100}, f)
            self.assertEqual(self.req("GET", "/api/requests/" + RID), (200, {"status": "pending"}))
            with open(p, "w") as f:
                json.dump({"id": RID, "type": "wake", "createdAt": time.time() - 151}, f)
            self.assertEqual(self.req("GET", "/api/requests/" + RID),
                             (200, {"status": "failed", "error": "helper-timeout"}))
            os.unlink(p)

    def test_status_other_types_keep_old_limits(self):
        p = os.path.join(self.outbox, RID + ".req.json")
        with open(p, "w") as f:
            json.dump({"id": RID, "type": "text", "createdAt": time.time() - 31}, f)
        self.assertEqual(self.req("GET", "/api/requests/" + RID)[1],
                         {"status": "failed", "error": "helper-timeout"})

    def test_status_result_carries_message(self):
        with open(os.path.join(self.outbox, RID + ".res.json"), "w") as f:
            json.dump(_sig.res({"id": RID, "status": "failed", "error": "wake-failed", "message": "boom"}), f)
        self.assertEqual(self.req("GET", "/api/requests/" + RID),
                         (200, {"status": "failed", "error": "wake-failed", "message": "boom"}))


if __name__ == "__main__":
    unittest.main()
