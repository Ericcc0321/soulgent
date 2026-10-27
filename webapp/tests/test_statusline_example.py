import json
import os
import subprocess
import sys
import tempfile
import unittest

from helper.snapshot import read_meta, read_usage

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "examples", "statusline", "soulgent-statusline.py")


def run(payload, out_dir):
    env = dict(os.environ, SOULGENT_STATUSLINE_DIR=out_dir)
    stdin = payload if isinstance(payload, str) else json.dumps(payload)
    p = subprocess.run([sys.executable, SCRIPT], input=stdin, capture_output=True, text=True, env=env, timeout=20)
    assert p.returncode == 0, p.stderr
    return p.stdout


class StatuslineExampleTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.d = os.path.join(self._tmp.name, "sl")  # does not exist yet: the script must create it
        self.addCleanup(self._tmp.cleanup)

    def test_full_input_is_read_by_helper(self):
        out = run({
            "session_id": "abc-123_X", "model": {"id": "claude-x", "display_name": "Opus"},
            "context_window": {"context_window_size": 200000, "used_percentage": 12.4,
                               "current_usage": {"input_tokens": 100, "cache_creation_input_tokens": 400,
                                                 "cache_read_input_tokens": 24300, "output_tokens": 9}},
            "effort": {"level": "high"}, "fast_mode": True,
            "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": 1792500000},
                            "seven_day": {"used_percentage": 41, "resets_at": 1793000000}},
        }, self.d)
        self.assertIn("Opus", out)
        m = read_meta(self.d, "abc-123_X")
        self.assertEqual((m["model"], m["effort"], m["fast"]), ("Opus", "high", True))
        self.assertEqual((m["ctxPct"], m["ctxUsed"], m["ctxWindow"]), (12, 24800, 200000))
        self.assertIsNone(m["tps"])
        self.assertGreater(m["at"], 1e9)
        self.assertEqual(read_usage(self.d), {"fiveHour": {"pct": 23, "resetsAt": 1792500000},
                                              "sevenDay": {"pct": 41, "resetsAt": 1793000000}})

    def test_missing_fields_tolerated(self):
        run({"session_id": "s1"}, self.d)
        m = read_meta(self.d, "s1")
        self.assertIsNone(m["model"])
        self.assertIsNone(m["ctxPct"])
        self.assertIsNone(m["ctxWindow"])
        self.assertFalse(m["fast"])
        self.assertEqual(read_usage(self.d), {})

    def test_garbage_and_bad_session_id(self):
        run("not json", self.d)
        run({"session_id": "../evil", "model": "Opus"}, self.d)
        self.assertEqual([f for f in os.listdir(self.d) if f.startswith("meta.")], [])

    def test_percent_derived_from_tokens(self):
        run({"session_id": "s2", "model": "Sonnet", "context_window": {
            "context_window_size": 1000, "current_usage": {"input_tokens": 250}}}, self.d)
        m = read_meta(self.d, "s2")
        self.assertEqual((m["model"], m["ctxPct"], m["ctxUsed"]), ("Sonnet", 25, 250))


if __name__ == "__main__":
    unittest.main()
