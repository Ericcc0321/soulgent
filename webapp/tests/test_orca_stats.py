import json
import os
import tempfile
import unittest

from helper import orca_stats as o
from helper.snapshot import add_sidecar
from helper.zones import ZoneConfig


def R(day, model="claude-opus-5-5", key="worktree:r1::/p/A", label="A", **kw):
    row = {"day": day, "model": model, "projectKey": key, "projectLabel": label,
           "inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheWriteTokens": 0, "cacheWrite1hTokens": 0}
    row.update(kw)
    return row


class PriceTests(unittest.TestCase):
    def test_exact_and_dated_ids(self):
        self.assertEqual(o.price_for("claude-opus-5-5")["in"], 4.0)
        self.assertEqual(o.price_for("claude-opus-5")["in"], 5.0)  # must not be captured by the opus-5-5 entry
        self.assertEqual(o.price_for("claude-haiku-4-5-20251001")["out"], 5.0)

    def test_unknown_falls_back_to_family_or_none(self):
        self.assertEqual(o.price_for("claude-sonnet-6"), o.PRICES["claude-sonnet-5-5"])
        self.assertEqual(o.price_for("claude-mythos-5-1"), o.PRICES["claude-fable-5-1"])
        self.assertIsNone(o.price_for("gpt-9"))

    def test_row_cost_splits_1h_and_5m_writes(self):
        r = R("2026-10-20", inputTokens=1_000_000, outputTokens=1_000_000, cacheReadTokens=1_000_000,
              cacheWriteTokens=3_000_000, cacheWrite1hTokens=1_000_000)
        # opus-5-5: 4 + 20 + 0.20 + 1M×4×2 + 2M×4×1.25 = 24.2 + 8 + 10
        self.assertAlmostEqual(o.row_cost(r), 42.2)
        self.assertIsNone(o.row_cost(R("2026-10-20", model="other")))


class SummaryTests(unittest.TestCase):
    def test_summary(self):
        rows = [
            R("2026-10-20", inputTokens=100, outputTokens=50),
            R("2026-10-20", key="cwd:/p/B", label="B", outputTokens=500),
            R("2026-10-18", model="weird", outputTokens=10),
            R("2026-09-01", cacheReadTokens=1000),
            {"bad": True}, "x",
        ]
        s = o.summarize_usage(rows, "2026-10-20")
        self.assertEqual(s["totalTokens"], 1660)
        self.assertEqual(s["todayTokens"], 650)
        self.assertEqual(s["activeDays"], 3)
        self.assertEqual(s["peakDay"], {"day": "2026-09-01", "tokens": 1000})
        self.assertEqual(s["unpricedTokens"], 10)
        self.assertEqual(len(s["days"]), o.HEAT_DAYS)
        self.assertEqual(s["days"][-1], {"day": "2026-10-20", "tokens": 650})
        self.assertEqual(s["days"][-3], {"day": "2026-10-18", "tokens": 10})
        self.assertEqual([p["label"] for p in s["todayByProject"]], ["B", "A"])
        self.assertEqual(s["todayByProject"][1]["path"], "/p/A")
        self.assertFalse([m for m in s["byModel"] if m["model"] == "weird"][0]["priced"])

    def test_missing_model_is_empty_string(self):
        """A missing model yields an empty string (not a localized "unknown"); the frontend renders it per language."""
        s = o.summarize_usage([R("2026-10-20", model=None, outputTokens=5)], "2026-10-20")
        self.assertEqual([m["model"] for m in s["byModel"]], [""])

    def test_empty(self):
        s = o.summarize_usage([], "2026-10-20")
        self.assertEqual(s["totalTokens"], 0)
        self.assertIsNone(s["peakDay"])
        self.assertEqual(s["activeDays"], 0)

    def test_project_path(self):
        self.assertEqual(o.project_path("worktree:id::/a/b::workspace:xyz"), "/a/b")
        self.assertEqual(o.project_path("cwd:/tmp"), "/tmp")
        self.assertIsNone(o.project_path("other"))

    def test_stats_from(self):
        s = o.stats_from({"aggregates": {"totalAgentsSpawned": 5, "totalAgentTimeMs": 7200000, "totalPRsCreated": 1,
                                         "firstEventAt": 1784598494117}})
        self.assertEqual(s, {"agents": 5, "agentTimeMs": 7200000, "prs": 1, "firstEventAt": 1784598494.117})
        self.assertIsNone(o.stats_from({}))


class ZoneTokenTests(unittest.TestCase):
    def test_match_by_session_cwd_then_dirs(self):
        projects = [{"path": "/p/Mac", "tokens": 10}, {"path": "/p/Mix", "tokens": 5},
                    {"path": "/p/Docs", "tokens": 7}, {"path": "/", "tokens": 3}, {"path": None, "tokens": 1}]
        sessions = [{"cwd": "/p/Mac/sub", "zone": "Lab"}, {"cwd": "/p/Mix", "zone": "Web"}, {"cwd": "/p/Mix/x", "zone": "Lab"}]
        res = o.zone_tokens_today(projects, sessions, lambda p: "Docs" if p.startswith("/p/Docs") else None)
        self.assertEqual(res["byZone"], {"Lab": 10, "Docs": 7})
        self.assertEqual(res["unmatched"], 5 + 3 + 1)


class ParseTests(unittest.TestCase):
    def test_diag(self):
        text = json.dumps({"result": {
            "app": {"cpu": 2.0, "memory": 100},
            "worktrees": [{"worktreeName": "A", "repoName": "r", "cpu": 1, "memory": 5, "sessions": [{}, {}]},
                          {"worktreeName": "B", "cpu": 3, "memory": 50, "sessions": []}],
            "host": {"totalMemory": 1000, "availableMemory": 400, "cpuCoreCount": 10},
            "totalCpu": 6, "totalMemory": 155}})
        d = o.parse_diag(text)
        self.assertEqual([w["name"] for w in d["worktrees"]], ["B", "A"])
        self.assertEqual(d["worktrees"][1]["terminals"], 2)
        self.assertEqual(d["worktreeMemory"], 55)
        self.assertEqual(d["host"]["available"], 400)
        self.assertIsNone(o.parse_diag("not json"))
        self.assertIsNone(o.parse_diag(None))

    def test_mac_parsers(self):
        self.assertEqual(o.parse_pressure("2\n"), "warn")
        self.assertEqual(o.parse_pressure("4"), "critical")
        self.assertIsNone(o.parse_pressure(None))
        sw = o.parse_swap("vm.swapusage: total = 2048.00M  used = 512.50M  free = 1535.50M  (encrypted)")
        self.assertEqual(sw["used"], 512.5 * 1024 * 1024)
        self.assertEqual(o.parse_load("{ 1.50 2.25 3.00 }"), [1.5, 2.25, 3.0])
        self.assertIsNone(o.parse_load(""))
        b = o.parse_batt("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%; AC attached; not charging present: true")
        self.assertEqual(b, {"pct": 80, "charging": False, "ac": True})
        b = o.parse_batt("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t55%; discharging; 3:10 remaining")
        self.assertEqual(b, {"pct": 55, "charging": False, "ac": False})
        b = o.parse_batt("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t60%; charging; 1:00 remaining")
        self.assertTrue(b["charging"])
        self.assertIsNone(o.parse_batt("Now drawing from 'AC Power'"))


VM_STAT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                     6085.
Pages active:                                 475788.
Pages inactive:                               474033.
Pages speculative:                              1027.
Pages throttled:                                   0.
Pages wired down:                             318066.
Pages purgeable:                                 282.
"Translation faults":                     7414744893.
Pages copy-on-write:                       525798944.
Pages zero filled:                        3226577755.
Pages reactivated:                        1016099255.
Pages purged:                              202943642.
File-backed pages:                            291873.
Anonymous pages:                              658975.
Pages stored in compressor:                  1652401.
Pages occupied by compressor:                 767464.
Decompressions:                            831036820.
Compressions:                              907057425.
Pageins:                                    92307543.
Pageouts:                                      75894.
Swapins:                                      237029.
Swapouts:                                     611952.
"""


class VmStatTests(unittest.TestCase):
    def test_parse_vm_stat(self):
        P = 16384
        m = o.parse_vm_stat(VM_STAT)
        self.assertEqual(m, {"app": (658975 - 282) * P, "wired": 318066 * P,
                             "compressed": 767464 * P, "cached": (291873 + 282) * P})

    def test_fallback_without_anonymous_and_page_size(self):
        text = VM_STAT.replace("Anonymous pages:                              658975.\n", "")
        m = o.parse_vm_stat(text)
        self.assertEqual(m["app"], (475788 + 474033 + 1027 - 291873 - 282) * 16384)
        m4 = o.parse_vm_stat(VM_STAT.replace("16384", "4096"))
        self.assertEqual(m4["wired"], 318066 * 4096)
        nohdr = "\n".join(VM_STAT.splitlines()[1:])
        self.assertEqual(o.parse_vm_stat(nohdr)["wired"], 318066 * 16384)

    def test_bad_input(self):
        self.assertIsNone(o.parse_vm_stat(None))
        self.assertIsNone(o.parse_vm_stat("garbage"))

    def test_sample_monitor_has_mem(self):
        def fake(cmd):
            if cmd == ["vm_stat"]:
                return VM_STAT
            if cmd == ["sysctl", "-n", "hw.memsize"]:
                return "34359738368\n"
            if cmd == ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]:
                return "2"
            return None
        orig = o._run
        o._run = fake
        try:
            mac = o.sample_monitor(["orca"], now=1.0)["mac"]
        finally:
            o._run = orig
        P = 16384
        mem = mac["mem"]
        self.assertEqual(mem["total"], 34359738368)
        self.assertEqual(mem["compressed"], 767464 * P)
        self.assertEqual(mem["used"], mem["app"] + mem["wired"] + mem["compressed"])
        self.assertEqual(mac["pressure"], "warn")
        self.assertIn("memTotal", mac)
        self.assertIn("memAvailable", mac)

    def test_sample_monitor_mem_none_when_vm_stat_fails(self):
        orig = o._run
        o._run = lambda cmd: None
        try:
            mac = o.sample_monitor(["orca"], now=1.0)["mac"]
        finally:
            o._run = orig
        self.assertIsNone(mac["mem"])


class FileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = self.tmp.name

    def test_taskboards_only_from_workzones_and_capped(self):
        board = os.path.join(self.d, "home", "a.md")
        os.makedirs(os.path.dirname(board))
        with open(board, "w", encoding="utf-8") as f:
            f.write("# 板\n" + "x" * (o.TASKBOARD_MAX + 50))
        wz = os.path.join(self.d, "wz.json")
        with open(wz, "w", encoding="utf-8") as f:
            json.dump({"zones": {"A": {"taskboard": "~/a.md"}, "B": {"taskboard": "~/missing.md"}, "C": {},
                                 "../x": {"taskboard": "~/a.md"}}}, f)
        paths = o.taskboard_paths(wz, os.path.join(self.d, "home"))
        self.assertEqual(paths, {"A": board, "B": os.path.join(self.d, "home", "missing.md")})
        out = os.path.join(self.d, "out")
        cache = {}
        meta = o.sync_taskboards(paths, out, cache)
        self.assertEqual(list(meta), ["A"])
        self.assertTrue(meta["A"]["truncated"])
        with open(os.path.join(out, "A.md"), encoding="utf-8") as f:
            self.assertEqual(len(f.read().encode("utf-8")), o.TASKBOARD_MAX)
        os.unlink(board)
        self.assertEqual(o.sync_taskboards(paths, out, cache), {})
        self.assertFalse(os.path.exists(os.path.join(out, "A.md")))

    def test_stats_reader_caches(self):
        with open(os.path.join(self.d, o.STATS_FILE), "w") as f:
            json.dump({"aggregates": {"totalAgentsSpawned": 3}}, f)
        with open(os.path.join(self.d, o.USAGE_FILE), "w") as f:
            json.dump({"dailyAggregates": [R("2026-10-20", outputTokens=9)]}, f)
        rd = o.StatsReader(self.d)
        s = rd.read(1000.0, "2026-10-20")
        self.assertEqual(s["agents"], 3)
        self.assertEqual(s["usage"]["todayTokens"], 9)
        with open(os.path.join(self.d, o.STATS_FILE), "w") as f:
            json.dump({"aggregates": {"totalAgentsSpawned": 4, "x": "longer"}}, f)
        self.assertEqual(rd.read(1010.0, "2026-10-20")["agents"], 3)  # no re-read within 30 seconds
        self.assertEqual(rd.read(1040.0, "2026-10-20")["agents"], 4)
        self.assertIsNone(o.StatsReader(os.path.join(self.d, "none")).read(0, "2026-10-20"))


class AddSidecarTests(unittest.TestCase):
    def test_merges(self):
        cfg = ZoneConfig.parse({"zones": {"Web": {"order": 1}}, "dirs": {"/p/web": "Web"}}, "/h")
        snap = {"zones": cfg.zones_public(), "sessions": []}
        add_sidecar(snap, {"orcaStats": {"usage": {"todayByProject": [{"path": "/p/web/x", "tokens": 4}]}},
                           "monitor": {"at": 1}, "taskboards": {"Web": {"size": 1}}}, cfg)
        self.assertEqual(snap["zones"][0]["taskboard"], {"size": 1})
        self.assertEqual(snap["zoneTokens"], {"byZone": {"Web": 4}, "unmatched": 0})
        self.assertEqual(snap["monitor"], {"at": 1})
        plain = {"zones": []}
        add_sidecar(plain, None, cfg)
        self.assertEqual(plain, {"zones": []})


if __name__ == "__main__":
    unittest.main()
