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
from tests import _sig  # noqa: E402  sets OUTBOX_SECRET; signs hand-written results

KEY = "secret-key-123"
COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
SID = "8bbbbbbb-2222-4222-8222-222222222222"
DATA = {"model": "m", "used": 1000, "window": 2000, "pct": 50.0,
        "categories": [{"name": "Messages", "tokens": 1000, "pct": 50.0}], "details": {}}


class ContextApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.outbox = os.path.join(t, "outbox")
        os.makedirs(self.outbox)
        self.snap = os.path.join(t, "snapshot.json")
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": time.time(), "usage": {}, "zones": [], "sessions": [
                {"id": SID, "kind": "claude", "status": "idle", "since": 1},
                {"id": "11111111-2222-3333-4444-555555555555", "kind": "shell", "status": "idle", "since": 1}]}, f)
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.state_dir = os.path.join(t, "st")
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap, projects=t,
                                        state=os.path.join(self.state_dir, "state.json"), outbox_dir=self.outbox)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", path, headers={"Cookie": COOKIE})
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def finish(self, rid, **res):
        body = {"id": rid, "status": "done", "finishedAt": time.time(), "type": "context", "sessionId": SID}
        body.update(res)
        with open(os.path.join(self.outbox, rid + ".res.json"), "w") as f:
            json.dump(_sig.res(body), f)
        os.unlink(os.path.join(self.outbox, rid + ".req.json"))

    def test_pending_reuse_done_cache(self):
        r, d = self.get("/api/session/%s/context" % SID)
        self.assertEqual(r, 200)
        self.assertEqual(d["status"], "pending")
        rid = d["rid"]
        with open(os.path.join(self.outbox, rid + ".req.json")) as f:
            req = json.load(f)
        self.assertEqual((req["type"], req["sessionId"]), ("context", SID))
        r, d2 = self.get("/api/session/%s/context" % SID)
        self.assertEqual(d2, {"status": "pending", "rid": rid})  # reused
        self.assertEqual(len(os.listdir(self.outbox)), 1)
        self.finish(rid, data=DATA)
        r, st = self.get("/api/requests/" + rid)
        self.assertEqual(st["status"], "done")
        self.assertEqual(st["data"], DATA)
        self.assertNotIn("sessionId", st)
        self.assertTrue(os.path.exists(os.path.join(self.state_dir, "context", SID + ".json")))
        r, d3 = self.get("/api/session/%s/context" % SID)
        self.assertEqual(d3["status"], "done")
        self.assertEqual(d3["data"], DATA)
        self.assertAlmostEqual(d3["at"], st["at"], places=3)

    def test_cache_expires(self):
        os.makedirs(os.path.join(self.state_dir, "context"))
        with open(os.path.join(self.state_dir, "context", SID + ".json"), "w") as f:
            json.dump({"at": time.time() - server.CONTEXT_CACHE_TTL - 5, "data": DATA}, f)
        r, d = self.get("/api/session/%s/context" % SID)
        self.assertEqual(d["status"], "pending")

    def test_done_without_poll_still_served(self):
        r, d = self.get("/api/session/%s/context" % SID)
        self.finish(d["rid"], data=DATA)
        r, d2 = self.get("/api/session/%s/context" % SID)
        self.assertEqual(d2["status"], "done")

    def test_failed_reenqueues(self):
        r, d = self.get("/api/session/%s/context" % SID)
        self.finish(d["rid"], status="failed", error="context-timeout")
        r, st = self.get("/api/requests/" + d["rid"])
        self.assertEqual((st["status"], st["error"]), ("failed", "context-timeout"))
        r, d2 = self.get("/api/session/%s/context" % SID)
        self.assertEqual(d2["status"], "pending")
        self.assertNotEqual(d2["rid"], d["rid"])

    def test_bad_ids(self):
        self.assertEqual(self.get("/api/session/c1/context")[0], 400)
        self.assertEqual(self.get("/api/session/99999999-2222-3333-4444-555555555555/context")[0], 404)
        self.assertEqual(self.get("/api/session/11111111-2222-3333-4444-555555555555/context")[0], 409)

    def test_claimed_limit(self):
        rid = "a" * 32
        p = os.path.join(self.outbox, rid + ".claimed")
        with open(p, "w") as f:
            json.dump({"type": "context", "sessionId": SID, "createdAt": time.time() - 70}, f)
        self.assertEqual(outbox.request_status(self.outbox, rid, time.time())["status"], "pending")
        with open(p, "w") as f:
            json.dump({"type": "context", "sessionId": SID, "createdAt": time.time() - 100}, f)
        self.assertEqual(outbox.request_status(self.outbox, rid, time.time())["error"], "helper-timeout")


if __name__ == "__main__":
    unittest.main()
