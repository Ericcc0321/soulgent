import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from helper import orca_stats, outbox, settings, snapshot  # noqa: E402

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")


class DefaultsTest(unittest.TestCase):
    """With no env vars and no .env, every setting equals the original hard-coded location."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.webapp = self.tmp.name  # empty directory, no .env

    def tearDown(self):
        self.tmp.cleanup()

    def test_claude_paths(self):
        p = settings.claude_paths({}, self.webapp)
        self.assertEqual(p, {
            "sessions_dir": os.path.join(CLAUDE, "sessions"),
            "projects_dir": os.path.join(CLAUDE, "projects"),
            "workzones": os.path.join(CLAUDE, "workzones.json"),
            "roster": "",       # optional extension: disabled by default
            "lineage_src": "",
        })

    def test_others(self):
        e, w = {}, self.webapp
        self.assertEqual(settings.claude_dir(e, w), CLAUDE)
        self.assertEqual(settings.statusline_dir(e, w), "/tmp/claude-statusline")
        self.assertIsNone(settings.orca_bin(e, w))
        self.assertIsNone(settings.claude_bin(e, w))
        self.assertEqual(settings.orca_stats_dir(e, w), os.path.join(HOME, "Library", "Application Support", "orca"))
        self.assertEqual(settings.petdex_dir(e, w), os.path.join(HOME, ".petdex", "pets"))
        self.assertEqual(settings.panel_domain(e, w), "io.github.ericcc0321.soulgent")
        self.assertEqual(settings.panel_domain_legacy(e, w), "")
        self.assertEqual(outbox.offduty_script(e, w), outbox.OFFDUTY_DEFAULT)

    def test_blank_counts_as_unset(self):
        self.assertEqual(settings.statusline_dir({"SOULGENT_STATUSLINE_DIR": "  "}, self.webapp), "/tmp/claude-statusline")
        with open(os.path.join(self.webapp, ".env"), "w") as f:
            f.write("SOULGENT_PANEL_DOMAIN=\n")
        self.assertEqual(settings.panel_domain({}, self.webapp), "io.github.ericcc0321.soulgent")

    def test_module_constants(self):
        # the local .env does not set these fields: the values actually used by the modules stay at their defaults
        names = ("SOULGENT_CLAUDE_DIR", "SOULGENT_WORKZONES", "SOULGENT_ROSTER", "SOULGENT_LINEAGE",
                 "SOULGENT_STATUSLINE_DIR", "SOULGENT_ORCA_BIN", "SOULGENT_CLAUDE_BIN", "SOULGENT_ORCA_STATS_DIR",
                 "SOULGENT_PANEL_DOMAIN", "SOULGENT_PANEL_DOMAIN_LEGACY")
        if any(settings.setting(n) for n in names):
            self.skipTest("local override configured")
        d = snapshot.DEFAULT_PATHS
        self.assertEqual(d["sessions_dir"], os.path.join(CLAUDE, "sessions"))
        self.assertEqual(d["projects_dir"], os.path.join(CLAUDE, "projects"))
        self.assertEqual(d["workzones"], os.path.join(CLAUDE, "workzones.json"))
        self.assertEqual(d["roster"], "")
        self.assertEqual(d["lineage_src"], "")
        self.assertEqual(d["usage_dir"], "/tmp/claude-statusline")
        self.assertEqual(outbox.PANEL_DOMAIN_LEGACY, "")
        self.assertEqual(outbox.PANEL_DOMAIN, "io.github.ericcc0321.soulgent")
        self.assertEqual(outbox.ROSTER_PATH, d["roster"])
        self.assertEqual(outbox.OFFDUTY_DEFAULT, "")
        self.assertEqual(outbox.PROJECTS_DIR, d["projects_dir"])
        self.assertEqual(outbox.SESSIONS_DIR, d["sessions_dir"])
        self.assertIsNone(outbox.ORCA_BIN)
        self.assertIsNone(outbox.CLAUDE_BIN)
        self.assertEqual(outbox.ORCA_PATHS, ["/usr/local/bin/orca", "/Applications/Orca.app/Contents/Resources/bin/orca"])
        self.assertEqual(outbox.CLAUDE_EXTRA_PATHS,
                         [os.path.join(HOME, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin"])
        self.assertEqual(orca_stats.ORCA_DIR, os.path.join(HOME, "Library", "Application Support", "orca"))


class OverrideTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.webapp = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write_env(self, text):
        with open(os.path.join(self.webapp, ".env"), "w", encoding="utf-8") as f:
            f.write(text)

    ENV = {
        "SOULGENT_STATUSLINE_DIR": "/s/line",
        "SOULGENT_ORCA_BIN": "/o/orca",
        "SOULGENT_CLAUDE_BIN": "/c/claude",
        "SOULGENT_ORCA_STATS_DIR": "/o/data",
        "SOULGENT_PETDEX_DIR": "/p/pets",
        "SOULGENT_PANEL_DOMAIN": "org.example.panel",
        "SOULGENT_PANEL_DOMAIN_LEGACY": "org.example.old-panel",
    }

    def check_all(self, env):
        w = self.webapp
        self.assertEqual(settings.statusline_dir(env, w), "/s/line")
        self.assertEqual(settings.orca_bin(env, w), "/o/orca")
        self.assertEqual(settings.claude_bin(env, w), "/c/claude")
        self.assertEqual(settings.orca_stats_dir(env, w), "/o/data")
        self.assertEqual(settings.petdex_dir(env, w), "/p/pets")
        self.assertEqual(settings.panel_domain(env, w), "org.example.panel")
        self.assertEqual(settings.panel_domain_legacy(env, w), "org.example.old-panel")

    def test_environment(self):
        self.check_all(self.ENV)

    def test_dotenv(self):
        self.write_env("WEBAPP_KEY=x\n" + "".join('%s="%s"\n' % kv for kv in self.ENV.items()))
        self.check_all({})

    def test_environment_beats_dotenv(self):
        self.write_env("SOULGENT_STATUSLINE_DIR=/from/dotenv\n")
        self.assertEqual(settings.statusline_dir({}, self.webapp), "/from/dotenv")
        self.assertEqual(settings.statusline_dir({"SOULGENT_STATUSLINE_DIR": "/from/env"}, self.webapp), "/from/env")

    def test_claude_dir_moves_everything_below(self):
        p = settings.claude_paths({"SOULGENT_CLAUDE_DIR": "/cc"}, self.webapp)
        self.assertEqual(p["sessions_dir"], "/cc/sessions")
        self.assertEqual(p["projects_dir"], "/cc/projects")
        self.assertEqual(p["workzones"], "/cc/workzones.json")
        self.assertEqual(p["roster"], "")  # roster and lineage are optional extensions; changing the Claude dir does not make them auto-discovered
        self.assertEqual(p["lineage_src"], "")

    def test_single_files_and_tilde(self):
        self.write_env("SOULGENT_CLAUDE_DIR=/cc\nSOULGENT_ROSTER=~/r.json\n")
        p = settings.claude_paths({"SOULGENT_WORKZONES": "/z.json", "SOULGENT_LINEAGE": "/l.jsonl"}, self.webapp)
        self.assertEqual(p["workzones"], "/z.json")
        self.assertEqual(p["roster"], os.path.join(HOME, "r.json"))
        self.assertEqual(p["lineage_src"], "/l.jsonl")
        self.assertEqual(p["sessions_dir"], "/cc/sessions")

    def test_find_orca_and_claude_use_override(self):
        orig = (outbox.ORCA_BIN, outbox.CLAUDE_BIN)
        try:
            exe = os.path.join(self.webapp, "claude")
            open(exe, "w").close()
            outbox.ORCA_BIN, outbox.CLAUDE_BIN = "/o/orca", exe
            self.assertEqual(outbox.find_orca(), ["/o/orca"])
            self.assertEqual(outbox.find_claude(), exe)
            outbox.CLAUDE_BIN = os.path.join(self.webapp, "missing")
            self.assertIsNone(outbox.find_claude())  # the specified one does not exist -> the context detail reports claude-not-found
        finally:
            outbox.ORCA_BIN, outbox.CLAUDE_BIN = orig

    def test_sidecar_lineage(self):
        sc = orca_stats.Sidecar(["orca"], "/z.json", "/h", os.path.join(self.webapp, "taskboards"),
                                lineage_src="/l.jsonl")
        self.assertEqual(sc.lineage_src, "/l.jsonl")
        sc = orca_stats.Sidecar(["orca"], "/z.json", "/h", os.path.join(self.webapp, "taskboards"))
        self.assertEqual(sc.lineage_src, "")  # not configured = no sync


if __name__ == "__main__":
    unittest.main()
