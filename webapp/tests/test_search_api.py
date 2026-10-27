"""Global (outer) search GET /api/search (reads data/textidx/ only, grouped by session, previous windows attributed to the current session name)."""
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

from api import server, textsearch
from tests._guests import guests_for  # noqa: E402

CUR = "4aaaaaaa-1111-4111-8111-111111111111"
P1 = "8bbbbbbb-2222-4222-8222-222222222222"
OFF = "6ddddddd-4444-4444-8444-444444444444"
B = "99999999-8888-7777-6666-555555555555"
GONE = "11111111-2222-3333-4444-555555555555"
KEY = "admin-key-0123456789abcdef"
GUEST = "guest-key-0123456789abcdef"
ADMIN_COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GUEST_COOKIE = "zbs=" + hmac.new(GUEST.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


def idx(d, sid, rows, tail=b""):
    with open(os.path.join(d, sid + ".jsonl"), "wb") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False).encode() + b"\n")
        f.write(tail)


def r(seq, ts, text, role="user", frm=""):
    return {"seq": seq, "ts": ts, "role": role, "from": frm, "text": text}


SNAP = {"generatedAt": 0, "usage": {}, "zones": [], "sessions": [
    {"id": CUR, "name": "Web-api-spec", "zone": "Web", "kind": "claude", "status": "idle", "since": 1, "transcript": "p/x.jsonl"},
    {"id": B, "name": "Docs-notes-demo", "zone": "Docs", "kind": "claude", "status": "idle", "since": 1, "transcript": "p/y.jsonl"},
], "offduty": [{"sid": OFF, "name": "Infra-offduty", "zone": "Infra", "transcript": "p/z.jsonl"}]}


class SearchFnTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = os.path.join(self.tmp.name, "textidx")
        os.makedirs(self.d)
        idx(self.d, CUR, [r(0, "2026-10-22T01:00:00Z", "本窗 模拟器 一"), r(10, "2026-10-22T03:00:00Z", "本窗 模拟器 二", "assistant"),
                          r(20, "2026-10-22T04:00:00Z", "无关")])
        idx(self.d, P1, [r(5, "2026-10-20T01:00:00Z", "前窗 模拟器")], tail=b'{"seq":9,"ts":"x","ro')  # a trailing half line must be tolerated
        idx(self.d, B, [r(7, "2026-10-22T05:00:00Z", "看板 Simulator 模拟器")])
        idx(self.d, OFF, [r(3, "2026-10-21T01:00:00Z", "下班 模拟器", "peer", "Web-api-demo")])
        idx(self.d, GONE, [r(1, "2026-10-22T09:00:00Z", "已不在快照 模拟器")])
        with open(os.path.join(self.d, "_state.json"), "w") as f:
            json.dump({"files": {}, "owners": {CUR: CUR, P1: CUR, B: B, OFF: OFF, GONE: GONE}}, f)

    def test_groups_by_owner_sorted_by_latest(self):
        out = textsearch.search(self.d, "模拟器", 60, SNAP)
        res = out["results"]
        self.assertEqual([g["sid"] for g in res], [B, CUR, OFF])  # most recent hit first; sessions not in the snapshot are dropped
        cur = res[1]
        self.assertEqual(cur["name"], "Web-api-spec")
        self.assertEqual(cur["zone"], "Web")
        self.assertEqual(cur["count"], 3)  # 2 from this window + 1 from the previous window
        self.assertEqual([h["seq"] for h in cur["hits"]], [10, 0, 5])  # newest first
        self.assertEqual(cur["hits"][2]["sid"], P1)  # each hit carries the window it belongs to
        self.assertIn("模拟器", cur["hits"][0]["snippet"])
        self.assertEqual(cur["hits"][0]["role"], "assistant")
        self.assertFalse(cur["off"])
        self.assertTrue(res[2]["off"])
        self.assertEqual(res[2]["hits"][0]["from"], "Web-api-demo")
        self.assertIn("ms", out)

    def test_case_insensitive_and_limit(self):
        self.assertEqual([g["sid"] for g in textsearch.search(self.d, "simulator", 60, SNAP)["results"]], [B])
        idx(self.d, CUR, [r(i, "2026-10-22T01:%02d:00Z" % i, "重复 关键 %d" % i) for i in range(30)])
        out = textsearch.search(self.d, "关键", 60, SNAP)["results"]
        self.assertEqual(out[0]["count"], 30)
        self.assertLessEqual(len(out[0]["hits"]), textsearch.HITS_PER)
        self.assertEqual(out[0]["hits"][0]["seq"], 29)
        self.assertEqual(len(textsearch.search(self.d, "模拟器", 2, SNAP)["results"]), 2)

    def test_missing_dir_or_state(self):
        self.assertEqual(textsearch.search(os.path.join(self.tmp.name, "nope"), "x", 60, SNAP)["results"], [])
        os.unlink(os.path.join(self.d, "_state.json"))  # no owners: group by the file's own sid
        self.assertEqual({g["sid"] for g in textsearch.search(self.d, "模拟器", 60, SNAP)["results"]}, {CUR, B, OFF})

    def test_ignores_non_uuid_files(self):
        idx(self.d, "evil", [r(1, "2026-10-23T00:00:00Z", "模拟器")])
        self.assertNotIn("evil", [g["sid"] for g in textsearch.search(self.d, "模拟器", 60, SNAP)["results"]])


    def test_parts_of_one_message_counted_once(self):
        """Long messages are indexed in segments (several lines with the same seq carry a part); results are deduplicated by seq and the snippet comes from the matching segment."""
        idx(self.d, CUR, [
            dict(r(100, "2026-10-22T06:00:00Z", "第一段 关键 开头", "assistant"), part=0),
            dict(r(100, "2026-10-22T06:00:00Z", "第二段 没有", "assistant"), part=1),
            dict(r(100, "2026-10-22T06:00:00Z", "第三段 关键 结尾", "assistant"), part=2),
            r(200, "2026-10-22T07:00:00Z", "另一条 关键"),
        ])
        idx(self.d, P1, [dict(r(100, "2026-10-20T01:00:00Z", "前窗同 seq 关键", "user"), part=0)])  # the same seq in another window is not a duplicate
        g = textsearch.search(self.d, "关键", 60, SNAP)["results"][0]
        self.assertEqual(g["count"], 3)
        self.assertEqual([(h["sid"], h["seq"]) for h in g["hits"]], [(CUR, 200), (CUR, 100), (P1, 100)])
        self.assertIn("第一段", g["hits"][1]["snippet"])
        self.assertEqual(textsearch.search(self.d, "结尾", 60, SNAP)["results"][0]["hits"][0]["snippet"].strip("…")[:3], "第三段")


class SearchRouteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = os.path.join(self.tmp.name, "textidx")
        os.makedirs(d)
        idx(d, CUR, [r(0, "2026-10-22T01:00:00Z", "本窗 模拟器")])
        self.snap = os.path.join(self.tmp.name, "snapshot.json")
        snap = dict(SNAP, generatedAt=time.time())
        snap["sessions"][0] = dict(snap["sessions"][0], name="Web-api-spec")
        with open(self.snap, "w") as f:
            json.dump(snap, f)
        os.makedirs(os.path.join(self.tmp.name, "projects"))
        p = mock.patch.object(server.Handler, "log_message", lambda *a, **k: None)
        p.start()
        self.addCleanup(p.stop)
        self.httpd = server.make_server("127.0.0.1", 0, key=KEY, snapshot=self.snap,
                                        projects=os.path.join(self.tmp.name, "projects"),
                                        state=os.path.join(self.tmp.name, "st", "state.json"),
                                        outbox_dir=os.path.join(self.tmp.name, "ob"), guests=guests_for(KEY, GUEST, "Web-api-spec"))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def get(self, path, cookie=ADMIN_COOKIE):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", path, headers={"Cookie": cookie})
        resp = c.getresponse()
        out = resp.read()
        c.close()
        return resp.status, (json.loads(out) if out else None)

    def test_admin_ok(self):
        st, d = self.get("/api/search?q=%E6%A8%A1%E6%8B%9F%E5%99%A8&limit=60")
        self.assertEqual(st, 200)
        self.assertEqual(d["results"][0]["sid"], CUR)
        self.assertEqual(d["results"][0]["name"], "Web-api-spec")

    def test_guest_forbidden(self):
        self.assertEqual(self.get("/api/search?q=abc", GUEST_COOKIE)[0], 403)

    def test_bad_query(self):
        self.assertEqual(self.get("/api/search?q=")[0], 400)
        self.assertEqual(self.get("/api/search?q=" + "a" * 200)[0], 400)
        self.assertEqual(self.get("/api/search?q=ab&limit=x")[0], 400)

    def test_no_cookie(self):
        self.assertIn(self.get("/api/search?q=ab", "")[0], (401, 403))


if __name__ == "__main__":
    unittest.main()
