import json
import os
import tempfile
import time
import unittest
from unittest import mock

from helper.snapshot import (build_snapshot, find_transcript, read_cwds, meta_from, read_meta,
                             read_usage, run_once, write_atomic, sessions_signature,
                             should_refresh, INTERVAL, MIN_GAP)
from helper import snapshot, orca_cli, outbox
from helper.zones import ZoneConfig

HOME = "/Users/u"
CFG = ZoneConfig.parse({
    "zones": {"Web": {"name": "前端", "color": "#E67E22", "order": 1},
              "Lab": {"name": "个人", "color": "#8E44AD", "order": 2}},
    "dirs": {"~/projects/api-gateway": "Web"},
    "default": "Lab",
}, HOME)

DUMP = [{"id": "id1", "kind": "claude", "model": "", "name": "Gateway", "project": "api-gateway",
         "since": 5.5, "status": "waiting", "summary": "问你", "waitingFor": "input needed"}]


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sdir = os.path.join(self.tmp.name, "sessions")
        self.pdir = os.path.join(self.tmp.name, "projects")
        os.makedirs(self.sdir)
        os.makedirs(os.path.join(self.pdir, "proj"))
        with open(os.path.join(self.sdir, "11.json"), "w") as f:
            json.dump({"sessionId": "id1", "cwd": "/Users/u/projects/api-gateway"}, f)
        with open(os.path.join(self.sdir, "11.key"), "w") as f:
            f.write("not json")
        with open(os.path.join(self.sdir, "bad.json"), "w") as f:
            f.write("{")
        open(os.path.join(self.pdir, "proj", "id1.jsonl"), "w").close()

    def test_merges_cwd_zone_plate_pet_transcript(self):
        snap = build_snapshot(DUMP, self.sdir, self.pdir, CFG, {"id1": "test-pet"}, {}, now=100.0)
        s = snap["sessions"][0]
        self.assertEqual((s["cwd"], s["zone"], s["plate"], s["pet"]),
                         ("/Users/u/projects/api-gateway", "Web", "Gateway", "test-pet"))
        self.assertEqual(s["transcript"], "proj/id1.jsonl")
        self.assertEqual(snap["generatedAt"], 100.0)
        self.assertEqual(snap["zones"][0]["code"], "Web")
        self.assertEqual(s["since"], 5.5)

    def test_summary_fields_absent_in_old_dump(self):
        s = build_snapshot(DUMP, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        for k in ("summaryCode", "summaryArgs", "nameUntitled"):
            self.assertNotIn(k, s)

    def test_summary_fields_passthrough(self):
        d = [dict(DUMP[0], summaryCode="x.y", summaryArgs={"a": "长" * 500, "n": 1, "f": 1.5, "b": True, "z": None},
                  nameUntitled=True)]
        s = build_snapshot(d, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual(s["summaryCode"], "x.y")
        self.assertEqual(s["summaryArgs"], d[0]["summaryArgs"])  # kept as-is, not truncated
        self.assertIs(s["nameUntitled"], True)

    def test_summary_fields_bad_types_dropped(self):
        d = [dict(DUMP[0], summaryCode="", summaryArgs=["a"], nameUntitled="yes")]
        s = build_snapshot(d, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        for k in ("summaryCode", "summaryArgs", "nameUntitled"):
            self.assertNotIn(k, s)
        d = [dict(DUMP[0], summaryCode=5, nameUntitled=1)]
        s = build_snapshot(d, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertNotIn("summaryCode", s)
        self.assertNotIn("nameUntitled", s)
        # keys with the wrong value type are dropped, the rest are kept
        d = [dict(DUMP[0], summaryArgs={"ok": "v", "bad": {"x": 1}, "lst": [1], 3: "k"})]
        s = build_snapshot(d, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual(s["summaryArgs"], {"ok": "v"})

    BG_OK = {"bgTasks": 3, "bgAgents": 1, "bgSince": 1700000000.5, "bgStale": True, "bgEndedAt": 1700000100, "bgOwned": False}

    def test_bg_fields_absent_in_old_dump(self):
        s = build_snapshot(DUMP, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        for k in self.BG_OK:
            self.assertNotIn(k, s)

    def test_bg_fields_passthrough(self):
        s = build_snapshot([dict(DUMP[0], **self.BG_OK)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        for k, v in self.BG_OK.items():
            self.assertEqual(s[k], v)
            self.assertIs(type(s[k]), type(v))
        d = dict(DUMP[0], bgTasks=0, bgAgents=0, bgSince=None, bgStale=False, bgEndedAt=None, bgOwned=True)
        s = build_snapshot([d], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual((s["bgTasks"], s["bgSince"], s["bgEndedAt"], s["bgOwned"]), (0, None, None, True))

    def test_bg_fields_bad_types_dropped(self):
        bad = {"bgTasks": True, "bgAgents": -1, "bgSince": "1700", "bgStale": 1, "bgEndedAt": False, "bgOwned": "yes"}
        s = build_snapshot([dict(DUMP[0], **bad)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        for k in bad:
            self.assertNotIn(k, s)
        s = build_snapshot([dict(DUMP[0], bgTasks=1.5, bgAgents="2", bgSince=True)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        for k in ("bgTasks", "bgAgents", "bgSince"):
            self.assertNotIn(k, s)

    def test_bg_list_absent_in_old_dump(self):
        self.assertNotIn("bgList", build_snapshot(DUMP, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0])

    def test_bg_list_passthrough(self):
        lst = [{"kind": "cmd", "desc": "跑全量测试", "since": 1700000000.5, "id": "b1", "toolUseId": "tu1"},
               {"kind": "agent", "desc": "查资料", "since": 1700000100, "id": "a1234567", "toolUseId": "tu2"}]
        s = build_snapshot([dict(DUMP[0], bgList=lst)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual(s["bgList"], lst)
        s = build_snapshot([dict(DUMP[0], bgList=[])], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual(s["bgList"], [])

    def test_bg_list_not_list_dropped(self):
        for bad in ({"kind": "cmd"}, "x", None, 3):
            s = build_snapshot([dict(DUMP[0], bgList=bad)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
            self.assertNotIn("bgList", s)

    def test_bg_list_items_cleaned(self):
        ok = {"kind": "cmd", "desc": "a", "since": 1.0, "id": "b1", "toolUseId": "tu1"}
        lst = [dict(ok, kind="other"), dict(ok, since="1"), dict(ok, since=True), dict(ok, id=5),
               dict(ok, toolUseId=7), "x", None,
               dict(ok, desc="第一行\n第二行\r第三" + "长" * 100),  # newlines removed, cut to 80 characters
               dict(ok, desc=123),                                    # desc is coerced to a string
               {k: v for k, v in ok.items() if k != "toolUseId"},   # a missing toolUseId becomes an empty string
               {k: v for k, v in ok.items() if k != "desc"},        # a missing desc becomes an empty string
               dict(ok, extra="不透传")]
        s = build_snapshot([dict(DUMP[0], bgList=lst)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        out = s["bgList"]
        self.assertEqual(len(out), 5)
        self.assertEqual(out[0]["desc"], ("第一行 第二行 第三" + "长" * 100)[:80])
        self.assertEqual(len(out[0]["desc"]), 80)
        self.assertEqual(out[1]["desc"], "123")
        self.assertEqual(out[2]["toolUseId"], "")
        self.assertEqual(out[3]["desc"], "")
        self.assertEqual(out[4], ok)
        for it in out:
            self.assertEqual(set(it), {"kind", "desc", "since", "id", "toolUseId"})

    def test_bg_list_capped(self):
        lst = [{"kind": "cmd", "desc": "d", "since": i, "id": "b%d" % i, "toolUseId": "t%d" % i} for i in range(80)]
        s = build_snapshot([dict(DUMP[0], bgList=lst)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual(len(s["bgList"]), snapshot.BG_LIST_MAX)
        self.assertEqual(s["bgList"][0]["id"], "b0")  # keeps the leading ones in the order the Mac gave (since ascending)

    ERR_OK = {"errorKind": "api", "errorStatus": 529, "errorText": "API Error: 529 overloaded", "errorSince": 1700000000.5,
              "retryAttempt": 2, "retryMax": 10, "disconnected": True, "disconnectedSince": 1700000050,
              "compactedAt": 1700000060.25, "helpers": 3}

    def _one(self, **kw):
        return build_snapshot([dict(DUMP[0], **kw)], self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]

    def test_err_fields_absent_in_old_dump(self):
        s = build_snapshot(DUMP, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        for k in self.ERR_OK:
            self.assertNotIn(k, s)

    def test_err_fields_passthrough(self):
        s = self._one(**self.ERR_OK)
        for k, v in self.ERR_OK.items():
            self.assertEqual(s[k], v)
            self.assertIs(type(s[k]), type(v))
        nul = dict(errorKind=None, errorStatus=None, errorText=None, errorSince=None, retryAttempt=None, retryMax=None,
                   disconnected=False, disconnectedSince=None, compactedAt=None, helpers=0)
        s = self._one(**nul)
        for k, v in nul.items():
            self.assertIn(k, s)
            self.assertEqual(s[k], v)
        for kind in ("api", "rate_limit", "auth", "wb_error", "wb_stopped"):
            self.assertEqual(self._one(errorKind=kind)["errorKind"], kind)

    def test_err_fields_bad_types_dropped(self):
        bad = {"errorKind": "weird", "errorStatus": True, "errorText": 5, "errorSince": "1700", "retryAttempt": -1,
               "retryMax": 1.5, "disconnected": 1, "disconnectedSince": False, "compactedAt": "x", "helpers": True}
        s = self._one(**bad)
        for k in bad:
            self.assertNotIn(k, s)
        s = self._one(errorStatus=529.0, retryAttempt="2", helpers=-3, errorKind=7)
        for k in ("errorStatus", "retryAttempt", "helpers", "errorKind"):
            self.assertNotIn(k, s)

    def test_err_text_truncated(self):
        s = self._one(errorText="错" * 500)
        self.assertEqual(s["errorText"], "错" * 160)
        self.assertEqual(self._one(errorText="x" * 160)["errorText"], "x" * 160)

    def test_err_summary_code_passthrough(self):
        s = self._one(summaryCode="state.apiError", summaryArgs={"kind": "api", "status": 529, "text": "overloaded"})
        self.assertEqual(s["summaryCode"], "state.apiError")
        self.assertEqual(s["summaryArgs"], {"kind": "api", "status": 529, "text": "overloaded"})
        s = self._one(summaryCode="state.retrying", summaryArgs={"attempt": 2, "max": 10})
        self.assertEqual(s["summaryArgs"], {"attempt": 2, "max": 10})

    def test_summary_args_oversize_dropped(self):
        d = [dict(DUMP[0], summaryCode="x", summaryArgs={"a": "x" * 5000})]
        s = build_snapshot(d, self.sdir, self.pdir, CFG, {}, {}, now=1.0)["sessions"][0]
        self.assertEqual(s["summaryCode"], "x")
        self.assertNotIn("summaryArgs", s)

    def test_codex_session_has_no_cwd_or_transcript(self):
        s = build_snapshot([{"id": "c1", "kind": "codex", "name": "Lab-x", "status": "idle", "since": 1}],
                           self.sdir, self.pdir, CFG, {}, {}, 1)["sessions"][0]
        self.assertEqual((s["cwd"], s["transcript"], s["zone"]), (None, None, "Lab"))
        self.assertIsNone(s["pet"])

    def test_read_cwds_ignores_non_json_and_bad_files(self):
        self.assertEqual(read_cwds(self.sdir), {"id1": "/Users/u/projects/api-gateway"})

    def test_find_transcript_missing_returns_none(self):
        self.assertIsNone(find_transcript(self.pdir, "nope"))

    def test_read_usage_parses_two_line_files(self):
        d = os.path.join(self.tmp.name, "u")
        os.makedirs(d)
        with open(os.path.join(d, "shared.seven_day"), "w") as f:
            f.write("37\n1792645200\n")
        self.assertEqual(read_usage(d), {"sevenDay": {"pct": 37, "resetsAt": 1792645200}})

    def test_read_usage_survives_inf(self):
        d = os.path.join(self.tmp.name, "u2")
        os.makedirs(d)
        with open(os.path.join(d, "shared.five_hour"), "w") as f:
            f.write("inf\n1792645200\n")
        with open(os.path.join(d, "shared.seven_day"), "w") as f:
            f.write("37\n1792645200\n")
        self.assertEqual(read_usage(d), {"sevenDay": {"pct": 37, "resetsAt": 1792645200}})

    def test_write_atomic_never_leaves_partial(self):
        out = os.path.join(self.tmp.name, "out", "snapshot.json")
        write_atomic(out, {"a": 1})
        self.assertEqual(os.listdir(os.path.dirname(out)), ["snapshot.json"])
        self.assertEqual(json.load(open(out)), {"a": 1})

    def _paths(self, cmd):
        return {"dump_cmd": cmd, "sessions_dir": self.sdir, "projects_dir": self.pdir,
                "workzones": os.path.join(self.tmp.name, "wz.json"),
                "usage_dir": os.path.join(self.tmp.name, "nousage"),
                "out": os.path.join(self.tmp.name, "snapshot.json")}

    def test_dump_failure_keeps_previous_snapshot(self):
        paths = self._paths(["/usr/bin/false"])
        old = {"generatedAt": 1, "sessions": []}
        with open(paths["out"], "w") as f:
            json.dump(old, f)
        self.assertFalse(run_once(paths))
        self.assertEqual(json.load(open(paths["out"])), old)

    def test_run_once_success_writes_snapshot(self):
        paths = self._paths(["/bin/echo", json.dumps(DUMP)])
        self.assertTrue(run_once(paths))
        out = json.load(open(paths["out"]))
        self.assertEqual(out["sessions"][0]["id"], "id1")
        self.assertIsInstance(out["orca"]["running"], bool)


    def test_run_once_merges_private_zone_style(self):
        """Zone short names and avatar effects come from workzones.json + the machine-private zone-style.json into the snapshot zones."""
        paths = self._paths(["/bin/echo", json.dumps(DUMP)])
        with open(paths["workzones"], "w", encoding="utf-8") as f:
            json.dump({"zones": {"Web": {"name": "前端组", "order": 1, "fx": "circuit"}, "Lab": {"name": "实验", "order": 2}}}, f)
        paths["zone_style"] = os.path.join(self.tmp.name, "zone-style.json")
        with open(paths["zone_style"], "w", encoding="utf-8") as f:
            json.dump({"Lab": {"short": "实", "fx": "orbit"}}, f)
        self.assertTrue(run_once(paths))
        with open(paths["out"], encoding="utf-8") as f:
            zones = json.load(f)["zones"]
        self.assertEqual([(z["code"], z["short"], z["fx"]) for z in zones], [("Web", None, "circuit"), ("Lab", "实", "orbit")])


class ZoneStylePathTests(unittest.TestCase):
    """Private style file path: environment variable -> webapp/.env -> webapp/data/zone-style.json."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.webapp = self.tmp.name

    def test_default_under_data(self):
        self.assertEqual(snapshot.zone_style_path({}, self.webapp), os.path.join(self.webapp, "data", "zone-style.json"))

    def test_env_then_dotenv(self):
        with open(os.path.join(self.webapp, ".env"), "w") as f:
            f.write("SOULGENT_ZONE_STYLE=/opt/z.json\n")
        self.assertEqual(snapshot.zone_style_path({}, self.webapp), "/opt/z.json")
        self.assertEqual(snapshot.zone_style_path({"SOULGENT_ZONE_STYLE": "/x/y.json"}, self.webapp), "/x/y.json")

    def test_default_paths_have_zone_style(self):
        self.assertTrue(snapshot.DEFAULT_PATHS["zone_style"].endswith(".json"))

class DedupeTests(unittest.TestCase):
    """bg standby processes are hidden; the original session is hidden when it has been forked into a background clone (parkedJobId == clone jobId) and the clone is alive."""

    def setUp(self):
        import helper.snapshot as snap
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sdir = os.path.join(self.tmp.name, "sessions")
        self.pdir = os.path.join(self.tmp.name, "projects")
        os.makedirs(self.sdir)
        os.makedirs(self.pdir)
        self.alive = set()
        orig = snap._alive
        snap._alive = lambda pid: pid in self.alive
        self.addCleanup(setattr, snap, "_alive", orig)

    def _session(self, pid, sid, alive=True, **extra):
        data = {"pid": pid, "sessionId": sid, "cwd": "/x", "kind": "interactive"}
        data.update(extra)
        with open(os.path.join(self.sdir, "%d.json" % pid), "w") as f:
            json.dump(data, f)
        if alive:
            self.alive.add(pid)

    def _ids(self, dump):
        return [s["id"] for s in build_snapshot(dump, self.sdir, self.pdir, CFG, {}, {}, 1)["sessions"]]

    @staticmethod
    def _item(sid, kind="claude"):
        return {"id": sid, "kind": kind, "name": "Lab-a", "status": "busy", "since": 1}

    def test_drops_bg_spare(self):
        self._session(101, "spare1", kind="bg", spare=True, jobId="spare1")
        self._session(102, "keep1")
        self.assertEqual(self._ids([self._item("spare1"), self._item("keep1")]), ["keep1"])

    def test_drops_context_fork_in_flight(self):
        from helper import outbox
        self._session(104, "keep2")
        with mock.patch.dict(outbox._FORKS, {"ctxfork": None}, clear=True):
            self.assertEqual(self._ids([self._item("ctxfork"), self._item("keep2")]), ["keep2"])
        self.assertEqual(self._ids([self._item("ctxfork")]), ["ctxfork"])

    def test_keeps_bg_fork_that_is_not_spare(self):
        self._session(103, "fork1", kind="bg", jobId="j1")
        self.assertEqual(self._ids([self._item("fork1")]), ["fork1"])

    def test_parked_original_dropped_when_fork_alive(self):
        self._session(201, "orig", parkedJobId="j2")
        self._session(202, "fork", kind="bg", jobId="j2")
        self._session(203, "other")
        self.assertEqual(self._ids([self._item("orig"), self._item("other"), self._item("fork")]),
                         ["other", "fork"])

    def test_parked_original_kept_when_fork_dead_or_gone(self):
        self._session(301, "orig", parkedJobId="j3")
        self._session(302, "fork", alive=False, kind="bg", jobId="j3")
        self._session(303, "orig2", parkedJobId="j-missing")
        self.assertEqual(self._ids([self._item("orig"), self._item("orig2")]), ["orig", "orig2"])

    def test_no_parked_job_never_deduped(self):
        self._session(401, "a1", name="Lab-a")
        self._session(402, "a2", name="Lab-a", jobId="j4")
        self.assertEqual(self._ids([self._item("a1"), self._item("a2")]), ["a1", "a2"])

    def test_non_claude_items_untouched(self):
        self._session(501, "c1", parkedJobId="j5")
        self._session(502, "c2", kind="bg", jobId="j5")
        self._session(503, "x1", kind="bg", spare=True)
        dump = [self._item("c1", "codex"), self._item("c2"), self._item("x1", "codex")]
        self.assertEqual(self._ids(dump), ["c1", "c2", "x1"])


class RefreshTriggerTests(unittest.TestCase):
    def test_signature_changes_on_add_touch_remove(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(sessions_signature(os.path.join(d, "nope")), ())
            a = os.path.join(d, "1.json")
            with open(a, "w") as f:
                f.write("{}")
            os.utime(a, ns=(1_000_000_000, 1_000_000_000))
            s1 = sessions_signature(d)
            self.assertEqual(len(s1), 1)
            open(os.path.join(d, "x.key"), "w").close()  # non-json files are ignored
            self.assertEqual(sessions_signature(d), s1)
            os.utime(a, ns=(2_000_000_000, 2_000_000_000))
            s2 = sessions_signature(d)
            self.assertNotEqual(s2, s1)
            with open(os.path.join(d, "2.json"), "w") as f:
                f.write("{}")
            self.assertNotEqual(sessions_signature(d), s2)
            os.unlink(a)
            self.assertEqual(len(sessions_signature(d)), 1)

    def test_should_refresh(self):
        s1, s2 = (("a", 1, 1),), (("a", 2, 1),)
        self.assertFalse(should_refresh(100.0 + MIN_GAP - 0.1, 100.0, s2, s1, True))  # minimum interval
        self.assertTrue(should_refresh(100.0 + MIN_GAP, 100.0, s2, s1, False))  # directory changed
        self.assertTrue(should_refresh(100.0 + MIN_GAP, 100.0, s1, s1, True))  # triggered by the outbox
        self.assertFalse(should_refresh(101.0, 100.0, s1, s1, False))  # unchanged, deadline not reached
        self.assertTrue(should_refresh(100.0 + INTERVAL, 100.0, s1, s1, False))  # deadline reached


if __name__ == "__main__":
    unittest.main()


class PanelTests(unittest.TestCase):
    def test_panel_from_filters_to_known_ids(self):
        from helper.snapshot import panel_from, pets_from
        dom = {"seenAt": {"id1": 12.5, "gone": 1.0, "bad": "x"}, "pinned": ["id1", "gone", 3],
               "petBySession": {"id1": "test-pet"}}
        self.assertEqual(panel_from(dom, ["id1", "bad"]), {"seenAt": {"id1": 12.5}, "pinned": ["id1"]})
        self.assertEqual(pets_from(dom), {"id1": "test-pet"})
        self.assertEqual(panel_from({}, ["id1"]), {"seenAt": {}, "pinned": []})
        self.assertIsNone(panel_from(None, ["id1"]))

    def test_build_snapshot_panel_field_only_when_given(self):
        d = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, d)
        self.assertNotIn("panel", build_snapshot([], d, d, CFG, {}, {}, 1))
        p = {"seenAt": {}, "pinned": []}
        self.assertEqual(build_snapshot([], d, d, CFG, {}, {}, 1, p)["panel"], p)


class OffdutyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pdir = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(self.pdir, "proj"))
        open(os.path.join(self.pdir, "proj", "o1.jsonl"), "w").close()

    def test_read_roster_failure_is_empty(self):
        from helper.snapshot import read_roster
        p = os.path.join(self.tmp.name, "roster.json")
        self.assertEqual(read_roster(p), {})
        with open(p, "w") as f:
            f.write("{")
        self.assertEqual(read_roster(p), {})
        with open(p, "w") as f:
            f.write("[1]")
        self.assertEqual(read_roster(p), {})
        with open(p, "w") as f:
            json.dump({"A": {"sid": "x"}}, f)
        self.assertEqual(read_roster(p), {"A": {"sid": "x"}})

    def test_offduty_filter_sort_zone_transcript(self):
        from helper.snapshot import offduty_from
        roster = {
            "Lab-old": {"sid": "o1", "zone": "Lab", "lastActive": 10, "offAt": 100},
            "Lab-new": {"sid": "o2", "zone": "", "lastActive": 20, "offAt": 300},
            "Awake-sid": {"sid": "id1", "zone": "Lab", "offAt": 400},   # sid is already in sessions
            "Gateway": {"sid": "zz", "zone": "Web", "offAt": 500},      # name is already in sessions
            "Bad": "x",
            "NoSid": {"zone": "Lab", "offAt": 1},
            "Zone-int": {"sid": "o3", "zone": 5, "offAt": 200},
        }
        out = offduty_from(roster, DUMP, self.pdir)
        self.assertEqual([o["name"] for o in out], ["Lab-new", "Zone-int", "Lab-old"])
        self.assertEqual(out[0], {"name": "Lab-new", "sid": "o2", "zone": "", "lastActive": 20,
                                  "offAt": 300, "transcript": None})
        self.assertEqual(out[1]["zone"], "")
        self.assertEqual(out[2]["transcript"], "proj/o1.jsonl")

    def test_build_snapshot_has_offduty(self):
        d = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, d)
        self.assertEqual(build_snapshot([], d, d, CFG, {}, {}, 1)["offduty"], [])
        roster = {"Lab-a": {"sid": "o9", "zone": "Lab", "offAt": 5, "lastActive": 4}}
        snap = build_snapshot([], d, d, CFG, {}, {}, 1, roster=roster)
        self.assertEqual(snap["offduty"][0]["name"], "Lab-a")


class OrcaRunningTests(unittest.TestCase):
    """orca_running: pgrep -x Orca exit code 0 = running; the last result is reused for 10 seconds, and a pgrep error counts as running (no false alarm)."""

    def setUp(self):
        import helper.snapshot as snap
        self.snap = snap
        snap._orca_cache.update({"at": None, "running": True})
        self.addCleanup(snap._orca_cache.update, {"at": None, "running": True})

    def _run(self, codes):
        from unittest import mock
        calls = []

        def fake(cmd, **kw):
            calls.append(cmd)
            code = codes[len(calls) - 1]
            if isinstance(code, Exception):
                raise code
            return mock.Mock(returncode=code)
        return mock.patch.object(self.snap.subprocess, "run", side_effect=fake), calls

    def test_caches_for_10_seconds(self):
        p, calls = self._run([0, 1])
        with p:
            self.assertTrue(self.snap.orca_running(now=100.0))
            self.assertTrue(self.snap.orca_running(now=109.9))
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0], ["pgrep", "-x", "Orca"])
            self.assertFalse(self.snap.orca_running(now=110.0))
            self.assertEqual(len(calls), 2)
            self.assertFalse(self.snap.orca_running(now=115.0))
            self.assertEqual(len(calls), 2)

    def test_pgrep_error_counts_as_running(self):
        p, calls = self._run([OSError("no pgrep")])
        with p:
            self.assertTrue(self.snap.orca_running(now=1.0))


class MetaTests(unittest.TestCase):
    """Status line meta.<id>.json -> session.meta."""

    def setUp(self):
        self.d = tempfile.mkdtemp()

    def _write(self, sid, obj):
        with open(os.path.join(self.d, "meta.%s.json" % sid), "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))

    def test_meta_from_maps_fields(self):
        m = meta_from({"session_id": "x", "model": "Opus 5.5", "big": False, "effort": "medium", "fast": True,
                       "used_percentage": 41, "used_tokens": 414432, "window": 1000000,
                       "speed": 60.84, "ts": 1792491142})
        self.assertEqual(m, {"model": "Opus 5.5", "effort": "medium", "fast": True, "ctxPct": 41,
                             "ctxUsed": 414432, "ctxWindow": 1000000, "tps": 60.8, "at": 1792491142})

    def test_meta_from_nulls_and_junk(self):
        m = meta_from({"model": "", "effort": None, "fast": "yes", "used_percentage": 140,
                       "window": 0, "speed": None, "ts": True})
        self.assertEqual((m["model"], m["effort"], m["fast"], m["ctxPct"], m["ctxWindow"], m["tps"], m["at"]),
                         (None, None, False, 100, None, None, None))
        self.assertIsNone(meta_from([1, 2]))

    def test_read_meta_missing_bad_and_unsafe_id(self):
        self.assertIsNone(read_meta(self.d, "nope"))
        self._write("bad", "{")
        self.assertIsNone(read_meta(self.d, "bad"))
        self.assertIsNone(read_meta(self.d, "../x"))
        self.assertIsNone(read_meta(None, "abc"))

    def test_read_meta_cache_follows_mtime(self):
        self._write("s1", {"model": "Opus", "used_percentage": 10, "ts": 1})
        self.assertEqual(read_meta(self.d, "s1")["ctxPct"], 10)
        self._write("s1", {"model": "Opus", "used_percentage": 55, "ts": 2})
        os.utime(os.path.join(self.d, "meta.s1.json"), (9999, 9999))
        self.assertEqual(read_meta(self.d, "s1")["ctxPct"], 55)

    def test_build_snapshot_adds_meta_only_when_file_exists(self):
        self._write("c1", {"model": "Opus 5.5", "used_percentage": 3, "ts": 5})
        dump = [{"id": "c1", "kind": "claude", "name": "Lab-a", "status": "idle", "since": 1},
                {"id": "c2", "kind": "claude", "name": "Lab-b", "status": "idle", "since": 1}]
        ss = build_snapshot(dump, self.d, self.d, CFG, {}, {}, 1, meta_dir=self.d)["sessions"]
        self.assertEqual(ss[0]["meta"]["ctxPct"], 3)
        self.assertNotIn("meta", ss[1])
        self.assertNotIn("meta", build_snapshot(dump, self.d, self.d, CFG, {}, {}, 1)["sessions"][0])


class AgentCountTests(unittest.TestCase):
    """Sub-agent counts come from the Mac dump; the helper does not count the subagents directory itself.
    agents (the legacy field read by the live frontend and the guest allowlist) = helpers; an old snapshot without helpers falls back to bgAgents; nothing is written for 0 or when neither exists."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pdir = os.path.join(self.tmp.name, "projects")
        self.sub = os.path.join(self.pdir, "proj", "s1", "subagents")
        os.makedirs(self.sub)
        open(os.path.join(self.pdir, "proj", "s1.jsonl"), "w").close()
        self.sdir = os.path.join(self.tmp.name, "sessions")
        os.makedirs(self.sdir)
        # the transcript has one unfinished, recently active sub-agent: the dispatch count comes from the snapshot, the helper must not count it itself (must not become 1)
        with open(os.path.join(self.sub, "agent-a1111111.meta.json"), "w") as f:
            json.dump({"toolUseId": "tu_a", "description": "x"}, f)
        open(os.path.join(self.sub, "agent-a1111111.jsonl"), "w").close()

    def one(self, **kw):
        d = dict({"id": "s1", "kind": "claude", "name": "Lab-a", "status": "busy", "since": 1}, **kw)
        return build_snapshot([d], self.sdir, self.pdir, CFG, {}, {}, time.time())["sessions"][0]

    def test_count_agents_removed(self):
        for name in ("count_agents", "_meta_finished", "_agent_cache", "AGENT_META_MAX"):
            self.assertFalse(hasattr(snapshot, name), name)

    def test_no_fields_no_agents(self):
        self.assertNotIn("agents", self.one())

    def test_helpers_passthrough_and_agents(self):
        s = self.one(helpers=3, bgAgents=1, bgTasks=2)
        self.assertEqual((s["helpers"], s["agents"]), (3, 3))

    def test_fallback_bg_agents(self):
        s = self.one(bgAgents=2, bgTasks=2)
        self.assertNotIn("helpers", s)
        self.assertEqual(s["agents"], 2)

    def test_zero_not_written(self):
        self.assertNotIn("agents", self.one(helpers=0, bgAgents=2))  # helpers wins: 0 means 0
        self.assertNotIn("agents", self.one(bgAgents=0))

    def test_bad_helpers_falls_back(self):
        s = self.one(helpers=True, bgAgents=1)
        self.assertNotIn("helpers", s)
        self.assertEqual(s["agents"], 1)


class PanelPathTests(unittest.TestCase):
    """The panel program path is configurable (SOULGENT_PANEL env var -> webapp/.env -> repo-relative ../app -> /Applications -> ~/Applications)."""
    REL = os.path.join("app", "Soulgent.app", "Contents", "MacOS", "Soulgent")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.webapp = os.path.join(self.root, "webapp")
        self.home = os.path.join(self.root, "home")
        os.makedirs(self.webapp)
        os.makedirs(self.home)

    def mk(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").close()
        return path

    def resolve(self, env=None, apps=None):
        return snapshot.panel_path(env=env or {}, webapp=self.webapp, home=self.home,
                                   apps_dir=apps or os.path.join(self.root, "Applications"))

    def test_repo_relative_default(self):
        want = self.mk(os.path.join(self.root, self.REL))
        self.assertEqual(self.resolve(), want)

    def test_env_wins(self):
        self.mk(os.path.join(self.root, self.REL))
        self.assertEqual(self.resolve(env={"SOULGENT_PANEL": "/opt/x/Soulgent"}), "/opt/x/Soulgent")

    def test_dotenv_used_when_no_env(self):
        self.mk(os.path.join(self.root, self.REL))
        with open(os.path.join(self.webapp, ".env"), "w") as f:
            f.write("WEBAPP_KEY=abc\n# comment\nSOULGENT_PANEL = \"/opt/y/Soulgent\"\n")
        self.assertEqual(self.resolve(), "/opt/y/Soulgent")
        # an empty value means not configured; keep looking as usual
        with open(os.path.join(self.webapp, ".env"), "w") as f:
            f.write("SOULGENT_PANEL=\n")
        self.assertEqual(self.resolve(), os.path.join(self.root, self.REL))

    def test_applications_fallbacks(self):
        apps = os.path.join(self.root, "Applications")
        sub = os.path.join("Soulgent.app", "Contents", "MacOS", "Soulgent")
        user_app = self.mk(os.path.join(self.home, "Applications", sub))
        self.assertEqual(self.resolve(apps=apps), user_app)
        sys_app = self.mk(os.path.join(apps, sub))
        self.assertEqual(self.resolve(apps=apps), sys_app)

    def test_nothing_found_returns_repo_relative(self):
        self.assertEqual(self.resolve(), os.path.join(self.root, self.REL))

    def test_missing_panel_logged_clearly(self):
        missing = os.path.join(self.root, "nope", "Soulgent")
        paths = {"dump_cmd": [missing, "--dump"]}
        with mock.patch.object(snapshot, "log") as lg:
            self.assertFalse(run_once(paths))
        msg = lg.call_args[0][0]
        self.assertIn("Soulgent for Mac app not found", msg)
        self.assertIn(missing, msg)
        self.assertIn("SOULGENT_PANEL", msg)

    def exe(self, base, name):
        return self.mk(os.path.join(base, "Soulgent.app", "Contents", "MacOS", name))

    def test_env_app_dir_appends_executable(self):
        app = os.path.join(self.root, "X", "Soulgent.app")
        env = {"SOULGENT_PANEL": app}
        macos = os.path.join(app, "Contents", "MacOS")
        self.assertEqual(self.resolve(env=env), os.path.join(macos, "Soulgent"))  # nothing exists: expected path
        exe = self.mk(os.path.join(macos, "Soulgent"))
        self.assertEqual(self.resolve(env=env), exe)

    def test_default_paths_use_resolver(self):
        self.assertEqual(snapshot.DEFAULT_PATHS["dump_cmd"][1:], ["--dump"])
        self.assertTrue(snapshot.DEFAULT_PATHS["dump_cmd"][0].endswith(os.path.join("MacOS", "Soulgent")))


class LogTimestampTests(unittest.TestCase):
    def test_log_line_has_local_timestamp_prefix(self):
        import io
        import re
        snapshot._last_logged.clear()
        buf = io.StringIO()
        with mock.patch.object(snapshot.sys, "stderr", buf):
            snapshot.log("dump 失败：退出码 1")
            snapshot.log("dump 失败：退出码 1")  # the same line is not repeated within 60 seconds
            snapshot.log("另一条\n带换行")
        lines = buf.getvalue().splitlines()
        self.assertEqual(len(lines), 2)
        for ln in lines:
            self.assertRegex(ln, r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S")
        self.assertTrue(lines[0].endswith(" dump 失败：退出码 1"))
        self.assertTrue(lines[1].endswith(" 另一条 带换行"))
        snapshot._last_logged.clear()


class FormatWarningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sdir = os.path.join(self.tmp.name, "sessions")
        self.pdir = os.path.join(self.tmp.name, "projects")
        os.makedirs(self.sdir)
        os.makedirs(self.pdir)
        orca_cli.clear_format_warn("id1")
        self.addCleanup(orca_cli.clear_format_warn, "id1")

    def snap(self, dump, **kw):
        return build_snapshot(dump, self.sdir, self.pdir, CFG, {}, {}, now=1.0, **kw)

    def test_absent_by_default(self):
        snap = self.snap(DUMP)
        self.assertNotIn("formatWarnings", snap)
        for k in ("formatWarn", "formatWarnings"):
            self.assertNotIn(k, snap["sessions"][0])

    def test_top_level_and_per_session_passthrough(self):
        w = [{"source": "orca", "reason": "x" * 300, "extra": 1}, {"source": "codexCli", "reason": "ok"}]
        snap = self.snap([dict(DUMP[0], formatWarnings=w, futureField=[1])], format_warnings=w)
        want = [{"source": "orca", "reason": "x" * 200}, {"source": "codexCli", "reason": "ok"}]
        self.assertEqual(snap["formatWarnings"], want)
        self.assertEqual(snap["sessions"][0]["formatWarnings"], want)
        self.assertEqual(self.snap([dict(DUMP[0], formatWarnings=[])], format_warnings=[])["formatWarnings"], [])

    def test_malformed_dropped(self):
        w = ["str", None, {"source": 1, "reason": "r"}, {"source": "orca"}, {"source": "orca", "reason": 5},
             {"source": "workBuddy", "reason": "kept"}]
        snap = self.snap([dict(DUMP[0], formatWarnings=w)], format_warnings=w)
        self.assertEqual(snap["formatWarnings"], [{"source": "workBuddy", "reason": "kept"}])
        for bad in ("oops", {"source": "orca", "reason": "r"}, 7, None):
            snap = self.snap([dict(DUMP[0], formatWarnings=bad)], format_warnings=bad)
            self.assertNotIn("formatWarnings", snap)
            self.assertNotIn("formatWarnings", snap["sessions"][0])

    def test_capped_at_20(self):
        w = [{"source": "orca", "reason": str(i)} for i in range(30)]
        snap = self.snap(DUMP, format_warnings=w)
        self.assertEqual(len(snap["formatWarnings"]), 20)
        self.assertEqual(snap["formatWarnings"][-1]["reason"], "19")

    def test_dump_entry_missing_keys_warns(self):
        d = dict(DUMP[0])
        del d["status"]
        self.assertEqual(self.snap([d])["sessions"][0]["formatWarn"], "dump: session entry missing 'status'")

    def test_broken_orca_json_sets_formatwarn(self):
        item = dict(DUMP[0], status="idle")
        cases = ({"ok": True, "result": {"terminal": {}}}, {"ok": True, "result": {}}, {"ok": True})
        for data, miss in zip(cases, ("tail", "terminal", "result")):
            orca_cli.clear_format_warn("id1")
            self.assertEqual(outbox.cc_screen.menu_gate(item, "h", ["orca"], lambda *a: data), "orca-failed")
            self.assertEqual(self.snap([item])["sessions"][0]["formatWarn"],
                             "orca: terminal read JSON missing '%s'" % miss)

    def test_orca_failure_or_good_json_does_not_warn(self):
        item = dict(DUMP[0], status="idle")
        outbox.cc_screen.menu_gate(item, "h", ["orca"], lambda *a: None)  # orca not running / exit code != 0
        self.assertNotIn("formatWarn", self.snap([item])["sessions"][0])
        good = {"ok": True, "result": {"terminal": {"tail": ["hello"]}}}
        self.assertIsNone(outbox.cc_screen.menu_gate(item, "h", ["orca"], lambda *a: good))
        self.assertNotIn("formatWarn", self.snap([item])["sessions"][0])

    def test_orca_warning_expires_and_clears(self):
        orca_cli.note_format_warn("id1", "orca: x", now=time.time() - orca_cli.FORMAT_WARN_TTL - 1)
        self.assertNotIn("formatWarn", self.snap(DUMP)["sessions"][0])
        orca_cli.note_format_warn("id1", "orca: x")
        self.assertEqual(self.snap(DUMP)["sessions"][0]["formatWarn"], "orca: x")
        orca_cli.clear_format_warn("id1")
        self.assertNotIn("formatWarn", self.snap(DUMP)["sessions"][0])

    def test_dump_once_accepts_wrapped_top_level_form(self):
        import subprocess
        out = os.path.join(self.tmp.name, "snap.json")
        wrapped = {"sessions": DUMP, "formatWarnings": [{"source": "orca", "reason": "r"}]}
        paths = {"dump_cmd": ["x", "--dump"], "sessions_dir": self.sdir, "projects_dir": self.pdir,
                 "workzones": os.path.join(self.tmp.name, "wz.json"), "usage_dir": self.tmp.name, "out": out}
        proc = subprocess.CompletedProcess([], 0, stdout=json.dumps(wrapped).encode(), stderr=b"")
        with mock.patch.object(snapshot.subprocess, "run", return_value=proc), \
                mock.patch.object(snapshot, "read_panel_domain", return_value=None), \
                mock.patch.object(snapshot, "orca_running", return_value=True):
            self.assertEqual(snapshot._dump_once(paths), (True, None))
        with open(out) as f:
            snap = json.load(f)
        self.assertEqual(snap["formatWarnings"], [{"source": "orca", "reason": "r"}])
        self.assertEqual(snap["sessions"][0]["id"], "id1")
