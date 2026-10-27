"""In-session search, locating a page by seq, window-switch lineage, do-not-disturb (api/history.py, state.MuteStore, notify, server routes)."""
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

from api import history, notify, server
from tests._guests import guests_for  # noqa: E402
from api.state import MuteStore, TopStore

CUR = "4aaaaaaa-1111-4111-8111-111111111111"
P1 = "8bbbbbbb-2222-4222-8222-222222222222"
P2 = "accccccc-3333-4333-8333-333333333333"
P3 = "6ddddddd-4444-4444-8444-444444444444"
P4 = "11111111-2222-3333-4444-555555555555"
OTHER = "99999999-8888-7777-6666-555555555555"
KEY = "admin-key-0123456789abcdef"
GUEST = "guest-key-0123456789abcdef"
ADMIN_COOKIE = "zbs=" + hmac.new(KEY.encode(), b"zbs-v1", hashlib.sha256).hexdigest()
GUEST_COOKIE = "zbs=" + hmac.new(GUEST.encode(), b"zbs-v1", hashlib.sha256).hexdigest()


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


def write(path, objs, title=None):
    with open(path, "wb") as f:
        if title:
            f.write(line({"type": "custom-title", "customTitle": title, "sessionId": "x"}))
        for o in objs:
            f.write(line(o))


class SearchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, CUR + ".jsonl")

    def test_finds_user_assistant_peer_not_tool_output(self):
        write(self.path, [
            u("第一条 关键词 在这里", ts="2026-10-19T01:00:00Z"),
            a("我来看看关键词", ts="2026-10-19T01:00:01Z", tool="t1"),
            result("t1", "工具输出 关键词 不该搜到"),
            u('<cross-session-message from-name="Web-api-demo">别处说 关键词</cross-session-message>', ts="2026-10-19T01:00:03Z"),
            u("无关"),
        ])
        hits = history.search_file(self.path, "关键词", 50)
        self.assertEqual([h["role"] for h in hits], ["peer", "assistant", "user"])  # newest first
        self.assertEqual(hits[0]["from"], "Web-api-demo")
        self.assertTrue(all("关键词" in h["snippet"] for h in hits))
        with open(self.path, "rb") as f:
            data = f.read()
        for h in hits:  # seq is the byte offset of the start of that line
            self.assertTrue(h["seq"] == 0 or data[h["seq"] - 1:h["seq"]] == b"\n")
            self.assertTrue(data[h["seq"]:h["seq"] + 1] == b"{")

    def test_case_insensitive_ascii_and_limit(self):
        write(self.path, [u("Hello World %d" % i, ts="2026-10-19T01:%02d:00Z" % i) for i in range(10)])
        hits = history.search_file(self.path, "hello", 3)
        self.assertEqual(len(hits), 3)
        self.assertIn("9", hits[0]["snippet"])  # the 3 newest

    def test_chunk_boundary_and_huge_line_skipped(self):
        objs = [u("填充" * 50, ts="2026-10-19T01:00:%02dZ" % (i % 60)) for i in range(40)]
        objs.insert(20, u("目标 needle 在中间"))
        objs.insert(5, a("巨行 needle " + "x" * 5000))
        write(self.path, objs)
        with mock.patch.object(history, "SCAN_CHUNK", 1000), mock.patch.object(history, "LINE_CAP", 2000):
            hits = history.search_file(self.path, "needle", 50)
        self.assertEqual([h["snippet"].strip() for h in hits], ["目标 needle 在中间"])

    def test_empty_query(self):
        write(self.path, [u("x")])
        self.assertEqual(history.search_file(self.path, "  ", 50), [])

    def test_guest_user_marked_even_when_snippet_cut(self):
        """A guest's message has from=guest, recognised even when the snippet window of a long message cuts off [Guest]; the admin's messages keep an empty from."""
        write(self.path, [u("[Guest] " + "前" * 100 + "命中"), u("管理员 命中")])
        hits = history.search_file(self.path, "命中", 5)
        self.assertEqual([h["from"] for h in hits], ["", "guest"])
        self.assertTrue(hits[1]["snippet"].startswith("…"))
        self.assertNotIn("[Guest]", hits[1]["snippet"])

    def test_guest_user_marked_with_image_prefix(self):
        """A message starting with [Image #1] [Guest] (with images) is also a guest's; one starting with [Image #1] but no [Guest] is the admin's."""
        write(self.path, [u("[Image #1] [Image #2] [Guest] 带图 命中"), u("[Image #1] 管理员 命中")])
        hits = history.search_file(self.path, "命中", 5)
        self.assertEqual([h["from"] for h in hits], ["", "guest"])

    def test_snippet_window(self):
        write(self.path, [u("前" * 100 + "命中" + "后" * 200)])
        sn = history.search_file(self.path, "命中", 5)[0]["snippet"]
        self.assertTrue(sn.startswith("…") and sn.endswith("…"))
        self.assertLess(len(sn), 120)
        self.assertIn("命中", sn)

    def test_around_page_ends_at_hit(self):
        objs = [u("消息 %d" % i, ts="2026-10-19T01:%02d:00Z" % i) for i in range(50)]
        write(self.path, objs)
        hit = [h for h in history.search_file(self.path, "消息 10", 5) if h["snippet"] == "消息 10"][0]
        page = history.around(self.path, hit["seq"], limit=5, after=0)
        self.assertEqual(page["items"][-1]["text"], "消息 10")
        self.assertEqual(len(page["items"]), 5)
        self.assertIsNotNone(page["next"])
        page = history.around(self.path, hit["seq"], limit=5, after=3)  # 3 more items after the hit line
        self.assertEqual([x["text"] for x in page["items"]][-4:], ["消息 10", "消息 11", "消息 12", "消息 13"])
        self.assertIn("消息 6", [x["text"] for x in page["items"]])
        last = history.around(self.path, [h for h in history.search_file(self.path, "消息 49", 5)][0]["seq"], limit=5)
        self.assertEqual(last["items"][-1]["text"], "消息 49")  # fewer than `after` items at the end is fine

    def test_around_rejects_mid_line(self):
        write(self.path, [u("消息一"), u("消息二")])
        self.assertIsNone(history.around(self.path, 3))
        self.assertIsNone(history.around(self.path, 10 ** 9))
        self.assertIsNone(history.around(self.path, -1))


class LineageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.join(self.tmp.name, "projects")
        self.dir = os.path.join(self.root, "p")
        os.makedirs(self.dir)
        self.lfile = os.path.join(self.tmp.name, "lineage.jsonl")
        history._cache_clear()

    def mk(self, sid, title="Docs-panel-demo", mtime=None, objs=None, d=None):
        p = os.path.join(d or self.dir, sid + ".jsonl")
        write(p, objs or [u("hi " + sid[:4], ts="2026-10-19T01:00:00Z")], title)
        if mtime:
            os.utime(p, (mtime, mtime))
        return p

    def lin(self, rows):
        with open(self.lfile, "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    def test_chain_from_file(self):
        cur = self.mk(CUR)
        self.mk(P1)
        other_dir = os.path.join(self.root, "q")
        os.makedirs(other_dir)
        self.mk(P2, d=other_dir)  # a previous window in another directory is found too
        self.lin([
            {"name": "Docs-panel-demo", "prev_session_id": P2, "new_session_id": P1, "at": "2026-10-20T10:00:00+08:00", "via": "window"},
            {"name": "别的", "prev_session_id": OTHER, "new_session_id": "zzz", "at": "2026-10-20T11:00:00+08:00", "via": "window"},
            {"name": "Docs-panel-demo", "prev_session_id": P1, "new_session_id": CUR, "at": "2026-10-21T14:38:27+08:00", "via": "backfill"},
        ])
        ch = history.chain(CUR, cur, self.root, "Docs-panel-demo", self.lfile)
        self.assertEqual([c["sid"] for c in ch], [P1, P2])
        self.assertEqual([c["via"] for c in ch], ["backfill", "window"])
        self.assertEqual(ch[0]["at"], "2026-10-21T14:38:27+08:00")
        self.assertTrue(ch[1]["path"].endswith(os.path.join("q", P2 + ".jsonl")))

    def test_chain_max_three_and_no_loop(self):
        cur = self.mk(CUR)
        for s in (P1, P2, P3, P4):
            self.mk(s)
        rows = []
        for new, prev in ((CUR, P1), (P1, P2), (P2, P3), (P3, P4), (P4, CUR)):
            rows.append({"name": "n", "prev_session_id": prev, "new_session_id": new, "at": "2026-10-20T10:00:00+08:00", "via": "window"})
        self.lin(rows)
        ch = history.chain(CUR, cur, self.root, "n", self.lfile)
        self.assertEqual([c["sid"] for c in ch], [P1, P2, P3])

    def test_continued_in(self):
        cur = self.mk(CUR)
        self.mk(P1, objs=[u("压缩前"), {"type": "continued-in", "timestamp": "2026-10-19T19:11:38.086Z",
                                        "sessionId": P1, "continuedInSessionId": CUR}])
        ch = history.chain(CUR, cur, self.root, "Docs-panel-demo", self.lfile)
        self.assertEqual(ch[0]["sid"], P1)
        self.assertEqual(ch[0]["via"], "continued")
        self.assertEqual(ch[0]["at"], "2026-10-19T19:11:38.086Z")

    def test_guess_same_name_ended_before(self):
        now = time.time()
        cur = self.mk(CUR, objs=[u("新窗", ts=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 100)))])
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
        self.mk(P1, mtime=now - 200, objs=[u("前窗", ts=iso(now - 1000))])  # same name, earlier than this window's start: pick it (most recent)
        self.mk(P2, mtime=now - 5000)         # same name but older
        self.mk(P3, title="别的名字", mtime=now - 150)
        self.mk(P4, mtime=now - 10)           # same name but later than this window's start (a parallel one)
        ch = history.chain(CUR, cur, self.root, "Docs-panel-demo", self.lfile)
        self.assertEqual(ch[0]["sid"], P1)
        self.assertEqual(ch[0]["via"], "guess")
        self.assertEqual([c["sid"] for c in ch], [P1, P2])

    def test_guess_reads_agent_name(self):
        now = time.time()
        cur = self.mk(CUR, title=None, objs=[u("x", ts=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 100)))])
        p = os.path.join(self.dir, P1 + ".jsonl")
        write(p, [u("old"), {"type": "agent-name", "agentName": "Web-guest-demo", "sessionId": P1}])
        os.utime(p, (now - 500, now - 500))
        ch = history.chain(CUR, cur, self.root, "Web-guest-demo", self.lfile)
        self.assertEqual([c["sid"] for c in ch], [P1])

    def test_no_name_no_guess(self):
        cur = self.mk(CUR)
        self.mk(P1, mtime=time.time() - 9999)
        self.assertEqual(history.chain(CUR, cur, self.root, "", self.lfile), [])

    def test_file_entry_missing_jsonl_skipped(self):
        cur = self.mk(CUR)
        self.lin([{"name": "n", "prev_session_id": P1, "new_session_id": CUR, "at": "x", "via": "window"}])
        self.assertEqual(history.chain(CUR, cur, self.root, "", self.lfile), [])

    def test_lineage_file_too_big_reads_tail(self):
        cur = self.mk(CUR)
        self.mk(P1)
        pad = {"name": "pad" * 100, "prev_session_id": OTHER, "new_session_id": OTHER, "at": "x", "via": "window"}
        with open(self.lfile, "w") as f:
            for _ in range(50):
                f.write(json.dumps(pad) + "\n")
            f.write(json.dumps({"name": "n", "prev_session_id": P1, "new_session_id": CUR, "at": "x", "via": "window"}) + "\n")
        with mock.patch.object(history, "LINEAGE_MAX", 2000):
            ch = history.chain(CUR, cur, self.root, "", self.lfile)
        self.assertEqual([c["sid"] for c in ch], [P1])


class MuteTest(unittest.TestCase):
    def test_store_persists(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "mute.json")
            m = MuteStore(p)
            self.assertFalse(m.has("a"))
            m.set("a", True)
            self.assertTrue(MuteStore(p).has("a"))
            m.set("a", False)
            self.assertFalse(MuteStore(p).has("a"))

    def test_top_store_persists(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "top.json")
            t = TopStore(p)
            self.assertFalse(t.has("a"))
            t.set("a", True)
            self.assertTrue(TopStore(p).has("a"))
            with open(p) as f:
                self.assertEqual(json.load(f), {"topped": ["a"]})
            t.set("a", False)
            self.assertFalse(TopStore(p).has("a"))

    def test_top_store_follows_chain(self):
        # several window switches in a row: the pin walks to the newest id; unrelated pins stay
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "top.json")
            t = TopStore(p)
            t.set(P3, True)
            t.set(OTHER, True)
            self.assertTrue(t.follow({P1: P3, P2: P1, CUR: P2}))
            self.assertTrue(t.has(CUR))
            self.assertFalse(t.has(P3))
            self.assertTrue(t.has(OTHER))
            self.assertEqual(sorted(TopStore(p)._ids), sorted([CUR, OTHER]))
            self.assertFalse(t.follow({P1: P3, P2: P1, CUR: P2}))  # nothing left to move: no write

    def test_notify_skips_muted(self):
        def body(s, k):
            return "B"
        sess = {"id": "a", "name": "n", "status": "waiting", "since": 1.0, "unread": False, "muted": True}
        st, _ = notify.step(notify.new_state(), [], 0, body)
        st, acts = notify.step(st, [sess], 10, body)
        st, acts = notify.step(st, [sess], 20, body)
        self.assertEqual(acts, [])
        done = dict(sess, status="idle", unread=True, since=2.0)
        st, acts = notify.step(st, [done], 30, body)
        st, acts = notify.step(st, [done], 50, body)
        self.assertEqual(acts, [])
        st, acts = notify.step(st, [dict(done, muted=False, since=3.0)], 60, body)
        st, acts = notify.step(st, [dict(done, muted=False, since=3.0)], 80, body)
        self.assertEqual([x["kind"] for x in acts], ["show"])


class RouteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        history._cache_clear()
        projects = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(projects, "p"))
        write(os.path.join(projects, "p", CUR + ".jsonl"), [u("本窗 关键词"), a("回复")], "Web-guest-demo")
        write(os.path.join(projects, "p", P1 + ".jsonl"), [u("前窗 关键词"), a("前窗回复")], "Web-guest-demo")
        write(os.path.join(projects, "p", OTHER + ".jsonl"), [u("别人 关键词")], "别人")
        self.snap = os.path.join(self.tmp.name, "snapshot.json")
        with open(os.path.join(self.tmp.name, "lineage.jsonl"), "w") as f:
            f.write(json.dumps({"name": "Web-guest-demo", "prev_session_id": P1, "new_session_id": CUR,
                                "at": "2026-10-21T18:54:59+08:00", "via": "window"}) + "\n")
        with open(self.snap, "w") as f:
            json.dump({"generatedAt": time.time(), "usage": {}, "zones": [], "sessions": [
                {"id": CUR, "name": "Web-guest-demo", "kind": "claude", "status": "idle", "since": 1,
                 "transcript": "p/" + CUR + ".jsonl"}]}, f)
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

    def req(self, method, path, cookie=ADMIN_COOKIE, body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Cookie": cookie}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, (json.loads(out) if out else None)

    def test_lineage_route(self):
        r, d = self.req("GET", "/api/session/%s/lineage" % CUR)
        self.assertEqual(r, 200)
        self.assertEqual([x["sid"] for x in d["windows"]], [P1])
        self.assertEqual(d["windows"][0]["via"], "window")
        self.assertNotIn("path", d["windows"][0])

    def test_search_route_includes_prev_window(self):
        r, d = self.req("GET", "/api/session/%s/search?q=%s&limit=50" % (CUR, "%E5%85%B3%E9%94%AE%E8%AF%8D"))
        self.assertEqual(r, 200)
        self.assertEqual([x["snippet"] for x in d["results"]], ["本窗 关键词", "前窗 关键词"])
        self.assertEqual([x["sid"] for x in d["results"]], [CUR, P1])
        self.assertIn("ms", d)

    def test_search_bad(self):
        self.assertEqual(self.req("GET", "/api/session/%s/search?q=" % CUR)[0], 400)
        self.assertEqual(self.req("GET", "/api/session/nope/search?q=a")[0], 400)

    def test_transcript_from_prev_and_around(self):
        r, d = self.req("GET", "/api/sessions/%s/transcript?from=%s" % (CUR, P1))
        self.assertEqual(r, 200)
        self.assertEqual([x["text"] for x in d["items"]], ["前窗 关键词", "前窗回复"])
        r, d = self.req("GET", "/api/sessions/%s/transcript?from=%s" % (CUR, OTHER))  # not on the chain
        self.assertEqual(r, 404)
        r, s = self.req("GET", "/api/session/%s/search?q=%s" % (CUR, "%E5%89%8D%E7%AA%97"))
        hit = s["results"][-1]
        r, d = self.req("GET", "/api/sessions/%s/transcript?from=%s&around=%d" % (CUR, P1, hit["seq"]))
        self.assertEqual(r, 200)
        self.assertEqual([x["text"] for x in d["items"]], ["前窗 关键词", "前窗回复"])  # the hit line plus the items carried after it
        self.assertEqual(d["hit"], hit["seq"])
        self.assertEqual(self.req("GET", "/api/sessions/%s/transcript?around=3" % CUR)[0], 400)

    def test_mute_route_and_snapshot_flag(self):
        r, _ = self.req("POST", "/api/sessions/%s/mute" % CUR, body={"on": True})
        self.assertEqual(r, 200)
        r, snap = self.req("GET", "/api/snapshot")
        self.assertTrue(snap["sessions"][0]["muted"])
        self.req("POST", "/api/sessions/%s/mute" % CUR, body={"on": False})
        r, snap = self.req("GET", "/api/snapshot")
        self.assertFalse(snap["sessions"][0]["muted"])
        self.assertEqual(self.req("POST", "/api/sessions/%s/mute" % CUR, body={"on": "x"})[0], 400)
        self.assertEqual(self.req("POST", "/api/sessions/%s/mute" % OTHER, body={"on": True})[0], 404)

    def test_guest_forbidden(self):
        self.assertEqual(self.req("POST", "/api/sessions/%s/mute" % CUR, cookie=GUEST_COOKIE, body={"on": True})[0], 403)
        r, d = self.req("GET", "/api/sessions/%s/transcript" % CUR, cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)

    def add_foreign_prev(self):
        """P1's previous window P2 is a session with a different name (the lineage record's name does not match): the admin can page back to it, a guest only to P1."""
        projects = os.path.join(self.tmp.name, "projects")
        write(os.path.join(projects, "p", P2 + ".jsonl"), [u("外人前窗 关键词")], "Web-guest-demo")
        with open(os.path.join(self.tmp.name, "lineage.jsonl"), "a") as f:
            f.write(json.dumps({"name": "Web-other-session", "prev_session_id": P2, "new_session_id": P1,
                                "at": "2026-10-20T10:00:00+08:00", "via": "window"}) + "\n")
        history._cache_clear()

    def test_guest_search_and_prev_windows_bound_name_only(self):
        """A guest can use in-session search, the previous-window chain, previous-window paging and jumping for the bound session; the chain stops at the last window whose name matches."""
        self.add_foreign_prev()
        r, d = self.req("GET", "/api/session/%s/lineage" % CUR)
        self.assertEqual([x["sid"] for x in d["windows"]], [P1, P2])  # unchanged for the admin
        r, d = self.req("GET", "/api/session/%s/lineage" % CUR, cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)
        self.assertEqual([x["sid"] for x in d["windows"]], [P1])
        self.assertNotIn("name", d["windows"][0])
        r, d = self.req("GET", "/api/session/%s/search?q=%s" % (CUR, "%E5%85%B3%E9%94%AE%E8%AF%8D"), cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)
        self.assertEqual([x["sid"] for x in d["results"]], [CUR, P1])
        self.assertEqual([x["sid"] for x in d["windows"]], [P1])
        r, d = self.req("GET", "/api/sessions/%s/transcript?from=%s" % (CUR, P1), cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)
        self.assertEqual([x["text"] for x in d["items"]], ["前窗 关键词", "前窗回复"])
        hit = d["items"][0]
        r, s = self.req("GET", "/api/session/%s/search?q=%s" % (CUR, "%E5%89%8D%E7%AA%97"), cookie=GUEST_COOKIE)
        r, d = self.req("GET", "/api/sessions/%s/transcript?from=%s&around=%d" % (CUR, P1, s["results"][-1]["seq"]),
                        cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)
        # a previous window with a mismatched name, one not on the chain, or a malformed one: always 403
        for src in (P2, OTHER, "../x"):
            self.assertEqual(self.req("GET", "/api/sessions/%s/transcript?from=%s" % (CUR, src), cookie=GUEST_COOKIE)[0],
                             403, src)
        self.assertEqual(self.req("GET", "/api/sessions/%s/transcript?from=%s" % (CUR, P2))[0], 200)  # the admin may view it

    def test_guest_other_session_forbidden(self):
        for path in ("/api/session/%s/search?q=a" % OTHER, "/api/session/%s/lineage" % OTHER,
                     "/api/session/nope/lineage", "/api/sessions/%s/transcript?from=%s" % (OTHER, P1)):
            self.assertEqual(self.req("GET", path, cookie=GUEST_COOKIE)[0], 403, path)

    # persistent top pinning (top.json, separate from the board's pinned)
    def test_top_route_and_snapshot_flag(self):
        r, snap = self.req("GET", "/api/snapshot")
        self.assertFalse(snap["sessions"][0]["topped"])
        r, d = self.req("POST", "/api/sessions/%s/top" % CUR, body={"on": True})
        self.assertEqual(r, 200)
        self.assertEqual(d, {"ok": True, "topped": True})
        r, snap = self.req("GET", "/api/snapshot")
        self.assertTrue(snap["sessions"][0]["topped"])
        self.assertFalse(snap["sessions"][0]["pinned"])  # does not touch the board pin
        self.assertTrue(os.path.exists(os.path.join(self.tmp.name, "st", "top.json")))
        self.req("POST", "/api/sessions/%s/top" % CUR, body={"on": False})
        r, snap = self.req("GET", "/api/snapshot")
        self.assertFalse(snap["sessions"][0]["topped"])
        self.assertEqual(self.req("POST", "/api/sessions/%s/top" % CUR, body={"on": "x"})[0], 400)
        self.assertEqual(self.req("POST", "/api/sessions/%s/top" % OTHER, body={"on": True})[0], 404)

    def test_top_survives_busy(self):
        self.req("POST", "/api/sessions/%s/top" % CUR, body={"on": True})
        with open(self.snap) as f:
            data = json.load(f)
        data["sessions"][0].update(status="busy", since=time.time())
        with open(self.snap, "w") as f:
            json.dump(data, f)
        os.utime(self.snap, (time.time() + 5, time.time() + 5))
        r, snap = self.req("GET", "/api/snapshot")
        self.assertEqual(snap["sessions"][0]["status"], "busy")
        self.assertTrue(snap["sessions"][0]["topped"])  # not removed when working (a board pin would be)

    def test_top_follows_window_switch(self):
        # pinned on the previous window (P1); after the window switch P1 -> CUR the list must still show it pinned,
        # otherwise every device sees it unpinned and the user pins again
        self.httpd.app.top.set(P1, True)
        r, snap = self.req("GET", "/api/snapshot")
        self.assertTrue(snap["sessions"][0]["topped"])
        with open(os.path.join(self.tmp.name, "st", "top.json")) as f:
            self.assertEqual(json.load(f), {"topped": [CUR]})  # carried over to the new id, old id dropped
        self.req("POST", "/api/sessions/%s/top" % CUR, body={"on": False})  # unpin on the new id sticks
        r, snap = self.req("GET", "/api/snapshot")
        self.assertFalse(snap["sessions"][0]["topped"])

    def test_mute_follows_window_switch(self):
        # do-not-disturb set on the previous window (P1) must survive the window switch P1 -> CUR, like pins
        self.httpd.app.mute.set(P1, True)
        r, snap = self.req("GET", "/api/snapshot")
        self.assertTrue(snap["sessions"][0]["muted"])
        with open(os.path.join(self.tmp.name, "st", "mute.json")) as f:
            self.assertEqual(json.load(f), {"muted": [CUR]})
        self.req("POST", "/api/sessions/%s/mute" % CUR, body={"on": False})  # turning it off on the new id sticks
        r, snap = self.req("GET", "/api/snapshot")
        self.assertFalse(snap["sessions"][0]["muted"])

    def test_top_guest_forbidden_and_hidden(self):
        self.assertEqual(self.req("POST", "/api/sessions/%s/top" % CUR, cookie=GUEST_COOKIE, body={"on": True})[0], 403)
        self.req("POST", "/api/sessions/%s/top" % CUR, body={"on": True})
        r, snap = self.req("GET", "/api/snapshot", cookie=GUEST_COOKIE)
        self.assertEqual(r, 200)
        self.assertNotIn("topped", snap["sessions"][0])


if __name__ == "__main__":
    unittest.main()
